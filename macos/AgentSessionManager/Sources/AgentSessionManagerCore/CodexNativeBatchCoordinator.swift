import Foundation

public struct NativeBatchReport: Identifiable, Sendable {
    public let id: UUID
    public let previewID: UUID
    public let operation: SessionOperation
    public let outcome: PersistentReportOutcome
    public let completedAt: Date
    public let items: [NativeArchiveReportItem]
    public let recoveredAfterInterruption: Bool

    public var successCount: Int { items.filter { $0.outcome == .success }.count }
    public var failureCount: Int { items.filter { $0.outcome == .failure }.count }
    public var unknownCount: Int { items.filter { $0.outcome == .unknown }.count }
}

protocol CodexNativeBatchMutationTransport: Sendable {
    func inventorySnapshot() async throws -> ProviderInventorySnapshot
    func archive(_ nativeSessionID: String) async throws
    func restore(_ nativeSessionID: String) async throws
    func delete(_ nativeSessionID: String) async throws
    func exactDeleteRead(
        _ nativeSessionID: String,
        auditedRuntimeVersion: String
    ) async -> DeleteExactReadObservation
}

private actor CodexNativeBatchTransport: CodexNativeBatchMutationTransport {
    private let source: any CodexArchiveSource & CodexRestoreSource & CodexDeleteSource

    init(source: any CodexArchiveSource & CodexRestoreSource & CodexDeleteSource) {
        self.source = source
    }

    func inventorySnapshot() async throws -> ProviderInventorySnapshot {
        try CodexProviderInventorySnapshotBuilder.make(from: await source.inventory())
    }

    func archive(_ nativeSessionID: String) async throws {
        try await source.archive(threadID: nativeSessionID)
    }

    func restore(_ nativeSessionID: String) async throws {
        try await source.unarchive(threadID: nativeSessionID)
    }

    func delete(_ nativeSessionID: String) async throws {
        try await source.delete(threadID: nativeSessionID)
    }

    func exactDeleteRead(
        _ nativeSessionID: String,
        auditedRuntimeVersion: String
    ) async -> DeleteExactReadObservation {
        do {
            let snapshot = try await source.exactRead(threadID: nativeSessionID)
            guard snapshot.thread.id == nativeSessionID else {
                return .unavailable(
                    observedAt: snapshot.observedAt,
                    errorCode: "delete_exact_read_identity_mismatch",
                    message: "thread/read returned a different native session ID."
                )
            }
            return .present(
                nativeSessionID: snapshot.thread.id,
                observedAt: snapshot.observedAt,
                runtimeVersion: snapshot.runtimeVersion
            )
        } catch let CodexAppServerError.rpcError(code, message)
            where code == -32600
                && message == "thread not loaded: \(nativeSessionID)"
                && CodexAppServerProvider.supportsVerifiedDeleteContract(
                    auditedRuntimeVersion
                ) {
            return .absent(
                nativeSessionID: nativeSessionID,
                observedAt: Date(),
                runtimeVersion: auditedRuntimeVersion
            )
        } catch {
            return .unavailable(
                observedAt: Date(),
                errorCode: "delete_exact_read_unavailable",
                message: error.localizedDescription
            )
        }
    }
}

/// One durable, exact-selection batch authorization boundary for Codex native
/// lifecycle operations. Codex has no cross-thread transaction, so all items
/// are preflighted before the first request and requests are sent in frozen
/// manager-key order. A failure or unknown result stops the remaining prefix.
public actor CodexNativeBatchCoordinator {
    private let store: SQLiteStateStore
    private let transport: any CodexNativeBatchMutationTransport
    private let now: @Sendable () -> Date
    private let makePreviewID: @Sendable () -> UUID
    private let makeReportID: @Sendable () -> UUID

    public init(
        store: SQLiteStateStore,
        configuration: CodexAppServerConfiguration = CodexAppServerConfiguration()
    ) {
        self.store = store
        self.transport = CodexNativeBatchTransport(
            source: CodexAppServerClient(configuration: configuration)
        )
        self.now = { Date() }
        self.makePreviewID = { UUID() }
        self.makeReportID = { UUID() }
    }

    init(
        store: SQLiteStateStore,
        transport: any CodexNativeBatchMutationTransport,
        now: @escaping @Sendable () -> Date,
        makePreviewID: @escaping @Sendable () -> UUID,
        makeReportID: @escaping @Sendable () -> UUID
    ) {
        self.store = store
        self.transport = transport
        self.now = now
        self.makePreviewID = makePreviewID
        self.makeReportID = makeReportID
    }

    public func prepare(
        managerKeys: Set<String>,
        operation: SessionOperation,
        snapshot: ProviderInventorySnapshot,
        checkpoint: ProviderCheckpointRecord,
        lifetime: TimeInterval = 5 * 60
    ) throws -> OperationPreview {
        guard managerKeys.count > 1 else {
            throw SessionManagerError.unsupportedOperation(
                "Native batch Preview requires at least two exact sessions."
            )
        }
        guard lifetime > 0,
              snapshot.provider == .codex,
              checkpoint.provider == .codex,
              snapshot.checkpoint == checkpoint,
              checkpoint.inventoryComplete,
              try store.providerCheckpoint(for: .codex) == checkpoint else {
            throw PersistentStateError.invalidRecord(
                "Native batch Preview requires the exact authoritative Codex checkpoint."
            )
        }
        guard [.archive, .moveToTrash, .restore, .emptyTrash].contains(operation) else {
            throw SessionManagerError.unsupportedOperation(
                "This operation has no Codex native batch path."
            )
        }
        guard let runtimeVersion = checkpoint.runtimeVersion,
              operation == .emptyTrash
                ? CodexAppServerProvider.supportsVerifiedDeleteContract(runtimeVersion)
                : CodexAppServerProvider.supportsVerifiedLifecycleContract(runtimeVersion) else {
            throw PersistentStateError.invalidRecord(
                "The observed Codex runtime is outside the audited native batch allow-list."
            )
        }

        let sessionsByKey = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        let sessions = try managerKeys.sorted().map { managerKey in
            guard let session = sessionsByKey[managerKey] else {
                throw SessionManagerError.sessionNotFound(managerKey)
            }
            return session
        }
        let memberships = try store.trashMemberships(for: .codex)
        let membershipKeys = Set(memberships.map(\.managerKey))
        let persistentOperation = PersistentOperation(operation)
        let membershipMutation: TrashMembershipMutation?
        let beforeCollection: SessionCollection
        let targetCollection: SessionCollection

        switch operation {
        case .archive:
            try validateArchiveCandidates(sessions)
            membershipMutation = nil
            beforeCollection = .active
            targetCollection = .archive
        case .moveToTrash:
            try validateArchiveCandidates(sessions)
            guard membershipKeys.isDisjoint(with: managerKeys) else {
                throw PersistentStateError.invalidRecord(
                    "Active to Trash batch found existing manager Trash membership."
                )
            }
            membershipMutation = .add
            beforeCollection = .active
            targetCollection = .trash
        case .restore:
            guard sessions.allSatisfy({ $0.nativeState == .archived }) else {
                throw SessionManagerError.unsupportedOperation(
                    "Restore batch accepts only stable native Archived sessions."
                )
            }
            let trashCount = managerKeys.intersection(membershipKeys).count
            guard trashCount == 0 || trashCount == managerKeys.count else {
                throw SessionManagerError.unsupportedOperation(
                    "Archive and Trash cannot be mixed in one Restore batch."
                )
            }
            membershipMutation = trashCount == managerKeys.count ? .remove : nil
            beforeCollection = trashCount == managerKeys.count ? .trash : .archive
            targetCollection = .active
        case .emptyTrash:
            guard managerKeys.isSubset(of: membershipKeys),
                  sessions.allSatisfy({
                      $0.nativeState == .archived
                          && $0.descendantCountKnown
                          && $0.descendantCount == 0
                          && !$0.protection.blocksDeleteAttempt
                  }) else {
                throw SessionManagerError.unsupportedOperation(
                    "Permanent Delete batch requires only stable manager Trash sessions with known-clear pin/descendant protection, no positive running/current signal, and zero descendants."
                )
            }
            membershipMutation = .remove
            beforeCollection = .trash
            targetCollection = .deleted
        case .moveToArchive:
            throw SessionManagerError.unsupportedOperation(
                "Trash to Archive is manager-only and uses its existing atomic batch."
            )
        }

        let createdAt = PersistentTimestamp.canonical(now())
        let expiresAt = PersistentTimestamp.canonical(
            createdAt.addingTimeInterval(lifetime)
        )
        let previewID = makePreviewID()
        let tokenPrefix = switch operation {
        case .archive: "ARCHIVE-BATCH"
        case .moveToTrash: "MOVE-TO-TRASH-BATCH"
        case .restore: "RESTORE-BATCH"
        case .emptyTrash: "DELETE-BATCH"
        case .moveToArchive: "MOVE-TO-ARCHIVE-BATCH"
        }
        let confirmationToken = "\(tokenPrefix)-\(previewID.uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let membershipHash = try ConflictResolutionHasher.membershipSetHash(memberships)
        let items = try sessions.map { session in
            PersistentPreviewItem(
                managerKey: session.id,
                nativeSessionID: session.nativeID,
                expectedNativeState: operation == .archive || operation == .moveToTrash
                    ? .active : .archived,
                expectedProtectionHash: membershipMutation == .remove
                    ? membershipHash
                    : try ArchiveExecutionHasher.protectionHash(for: session),
                expectedTitle: session.title,
                expectedProjectID: session.project?.id,
                expectedWorkingDirectory: session.workingDirectory,
                knownSizeBytes: session.sizeBytes
            )
        }
        let manifestHash = try ArchiveExecutionHasher.manifestHash(
            provider: .codex,
            operation: persistentOperation,
            providerInventoryHash: checkpoint.inventoryHash,
            runtimeVersion: runtimeVersion,
            reconciliationTimestamp: checkpoint.refreshedAt,
            createdAt: createdAt,
            expiresAt: expiresAt,
            trashMembershipMutation: membershipMutation,
            items: items
        )
        let persistentPreview = PersistentOperationPreview(
            id: previewID,
            provider: .codex,
            operation: persistentOperation,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            ),
            manifestHash: manifestHash,
            providerInventoryHash: checkpoint.inventoryHash,
            trashMembershipMutation: membershipMutation,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: items
        )
        try store.saveOperationPreview(persistentPreview, checkpoint: checkpoint)
        guard try store.operationPreview(id: previewID) == persistentPreview else {
            throw PersistentStateError.invalidRecord(
                "Persisted native batch Preview differs from the frozen record."
            )
        }

        return OperationPreview(
            id: previewID,
            provider: .codex,
            operation: operation,
            confirmationToken: confirmationToken,
            generatedAt: createdAt,
            items: sessions.map { session in
                OperationPreviewItem(
                    managerKey: session.id,
                    nativeID: session.nativeID,
                    title: session.title,
                    projectID: session.project?.id,
                    projectName: session.project?.name,
                    workingDirectory: session.workingDirectory,
                    beforeCollection: beforeCollection,
                    targetCollection: targetCollection,
                    sizeBytes: session.sizeBytes
                )
            },
            warnings: batchWarnings(operation: operation)
        )
    }

    public func execute(
        preview: OperationPreview,
        confirmationToken: String
    ) async throws -> NativeBatchReport {
        guard preview.provider == .codex, preview.items.count > 1 else {
            throw SessionManagerError.unsupportedOperation(
                "Native batch execution requires at least two exact Codex items."
            )
        }
        guard let stored = try store.operationPreview(id: preview.id),
              stored.status == .prepared,
              stored.operation == PersistentOperation(preview.operation),
              stored.createdAt == preview.generatedAt,
              stored.items.map(\.managerKey) == preview.items.map(\.managerKey),
              zip(stored.items, preview.items).allSatisfy({ frozen, displayed in
                  frozen.nativeSessionID == displayed.nativeID
                      && frozen.expectedTitle == displayed.title
                      && frozen.expectedProjectID == displayed.projectID
                      && frozen.expectedWorkingDirectory == displayed.workingDirectory
              }) else {
            throw PersistentStateError.invalidRecord(
                "Displayed native batch Preview differs from its frozen SQLite record."
            )
        }

        let startedAt = now()
        let claimed = try store.claimOperationPreviewForExecution(
            id: preview.id,
            now: startedAt,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            )
        )
        let results: [PersistentReportItem]
        do {
            let preflight = try await transport.inventorySnapshot()
            try validateWholeBatchPreflight(
                preflight,
                preview: claimed.preview,
                checkpoint: claimed.checkpoint
            )
            results = await executeFrozenPrefix(
                preview: claimed.preview,
                checkpoint: claimed.checkpoint
            )
        } catch {
            let completedAt = max(startedAt, now())
            results = claimed.preview.items.map {
                PersistentReportItem(
                    managerKey: $0.managerKey,
                    outcome: .failure,
                    observedNativeState: .unavailable,
                    verifiedReleasedBytes: nil,
                    evidenceAt: completedAt,
                    errorCode: "batch_preflight_rejected",
                    errorMessage: "No provider request was sent: \(error.localizedDescription)"
                )
            }
        }
        return try persistAndPresent(
            claimed.preview,
            displayed: preview,
            startedAt: startedAt,
            results: results,
            recovered: false
        )
    }

    /// Resolves a multi-item executing Preview by readback only. It never
    /// invokes archive, unarchive, or delete, so an interrupted item is not
    /// replayed and the remaining prefix is not guessed as authorized.
    public func recoverPending(
        using snapshot: ProviderInventorySnapshot
    ) async throws -> NativeBatchReport? {
        let candidates = try store.executingOperationPreviews(for: .codex)
            .filter { $0.items.count > 1 }
        guard candidates.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Native batch recovery found multiple executing batches and will not choose one."
            )
        }
        guard let preview = candidates.first,
              let checkpoint = try store.providerCheckpoint(for: .codex) else {
            return nil
        }
        let startedAt = now()
        let sessionsByKey = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        var results: [PersistentReportItem] = []
        for item in preview.items {
            let result = await recoveryResult(
                item: item,
                operation: preview.operation,
                snapshot: snapshot,
                session: sessionsByKey[item.managerKey],
                runtimeVersion: checkpoint.runtimeVersion ?? ""
            )
            results.append(result)
        }
        let displayed = displayPreview(from: preview, confirmationToken: "")
        return try persistAndPresent(
            preview,
            displayed: displayed,
            startedAt: startedAt,
            results: results,
            recovered: true
        )
    }

    private func validateArchiveCandidates(_ sessions: [AgentSession]) throws {
        guard sessions.allSatisfy({
            $0.nativeState == .active
                && $0.descendantCountKnown
                && $0.descendantCount == 0
                && !$0.protection.blocksArchiveAttempt
        }) else {
            throw SessionManagerError.unsupportedOperation(
                "Archive batch requires stable Active sessions with verified clear Archive protection and zero descendants."
            )
        }
    }

    private func validateWholeBatchPreflight(
        _ snapshot: ProviderInventorySnapshot,
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord
    ) throws {
        guard snapshot.provider == .codex,
              snapshot.inventoryComplete,
              snapshot.runtimeVersion == checkpoint.runtimeVersion,
              snapshot.observedAt >= checkpoint.refreshedAt else {
            throw PersistentStateError.invalidRecord(
                "The complete Codex batch preflight is unavailable or predates the Preview."
            )
        }
        let sessionsByKey = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        for item in preview.items {
            guard let session = sessionsByKey[item.managerKey],
                  session.nativeID == item.nativeSessionID,
                  session.nativeState == item.expectedNativeState else {
                throw PersistentStateError.invalidRecord(
                    "Batch target drifted before the first request: \(item.nativeSessionID)."
                )
            }
            switch preview.operation {
            case .archive, .moveToTrash:
                guard session.descendantCountKnown,
                      session.descendantCount == 0,
                      !session.protection.blocksArchiveAttempt else {
                    throw PersistentStateError.invalidRecord(
                        "Archive protection drifted before the first request: \(item.nativeSessionID)."
                    )
                }
            case .permanentlyDelete:
                guard session.descendantCountKnown,
                      session.descendantCount == 0,
                      !session.protection.blocksDeleteAttempt else {
                    throw PersistentStateError.invalidRecord(
                        "Delete protection drifted before the first request: \(item.nativeSessionID)."
                    )
                }
            case .restore:
                break
            case .moveToArchive:
                throw PersistentStateError.invalidRecord(
                    "Manager-only operations cannot enter native batch execution."
                )
            }
        }
    }

    private func executeFrozenPrefix(
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord
    ) async -> [PersistentReportItem] {
        var results: [PersistentReportItem] = []
        var stopped = false
        for item in preview.items {
            if stopped {
                results.append(notAttempted(item.managerKey))
                continue
            }
            let result = await executeOne(
                item,
                operation: preview.operation,
                checkpoint: checkpoint
            )
            results.append(result)
            stopped = result.outcome != .success
        }
        return results
    }

    private func executeOne(
        _ item: PersistentPreviewItem,
        operation: PersistentOperation,
        checkpoint: ProviderCheckpointRecord
    ) async -> PersistentReportItem {
        var acknowledgementError: Error?
        do {
            switch operation {
            case .archive, .moveToTrash:
                try await transport.archive(item.nativeSessionID)
            case .restore:
                try await transport.restore(item.nativeSessionID)
            case .permanentlyDelete:
                try await transport.delete(item.nativeSessionID)
            case .moveToArchive:
                throw PersistentStateError.invalidRecord(
                    "Manager-only operation entered native execution."
                )
            }
        } catch {
            acknowledgementError = error
        }

        let evidenceAt = now()
        do {
            if operation == .permanentlyDelete {
                async let exactRead = transport.exactDeleteRead(
                    item.nativeSessionID,
                    auditedRuntimeVersion: checkpoint.runtimeVersion ?? ""
                )
                let inventory = try await transport.inventorySnapshot()
                return classifyDelete(
                    item,
                    inventory: inventory,
                    exactRead: await exactRead,
                    acknowledgementError: acknowledgementError,
                    evidenceAt: evidenceAt
                )
            }
            let inventory = try await transport.inventorySnapshot()
            let desiredState: NativeSessionState = operation == .restore ? .active : .archived
            guard inventory.provider == .codex,
                  inventory.inventoryComplete,
                  inventory.runtimeVersion == checkpoint.runtimeVersion,
                  inventory.observedAt >= evidenceAt else {
                return unknown(
                    item.managerKey,
                    code: "batch_readback_unavailable",
                    message: "Fresh complete exact-ID readback was unavailable; no retry was sent."
                )
            }
            guard let observed = inventory.sessions.first(where: { $0.id == item.managerKey }) else {
                return unknown(
                    item.managerKey,
                    code: "batch_readback_identity_missing",
                    message: "The exact session was missing from lifecycle readback."
                )
            }
            if observed.nativeID == item.nativeSessionID,
               observed.nativeState == desiredState {
                return success(item.managerKey, state: desiredState, at: inventory.observedAt)
            }
            let message = acknowledgementError.map { $0.localizedDescription }
                ?? "Codex acknowledged the request, but exact-ID readback did not reach the requested state."
            return failure(
                item.managerKey,
                state: observed.nativeState,
                at: inventory.observedAt,
                code: "batch_native_request_rejected",
                message: message
            )
        } catch {
            return unknown(
                item.managerKey,
                code: "batch_readback_failed",
                message: "Post-operation readback failed; no retry was sent: \(error.localizedDescription)"
            )
        }
    }

    private func classifyDelete(
        _ item: PersistentPreviewItem,
        inventory: ProviderInventorySnapshot,
        exactRead: DeleteExactReadObservation,
        acknowledgementError: Error?,
        evidenceAt: Date
    ) -> PersistentReportItem {
        guard inventory.provider == .codex,
              inventory.inventoryComplete,
              inventory.observedAt >= evidenceAt else {
            return unknown(
                item.managerKey,
                code: "delete_batch_inventory_unavailable",
                message: "Fresh complete Delete inventory readback was unavailable."
            )
        }
        if let observed = inventory.sessions.first(where: { $0.id == item.managerKey }) {
            return failure(
                item.managerKey,
                state: observed.nativeState,
                at: inventory.observedAt,
                code: "delete_batch_target_present",
                message: acknowledgementError?.localizedDescription
                    ?? "Exact-ID readback still found the session after Delete."
            )
        }
        if case let .absent(nativeID, exactAt, _) = exactRead,
           nativeID == item.nativeSessionID {
            return success(
                item.managerKey,
                state: .absent,
                at: max(inventory.observedAt, exactAt)
            )
        }
        return unknown(
            item.managerKey,
            code: "delete_batch_exact_absence_unproven",
            message: "The complete inventory omitted the ID, but audited exact-read absence was not also proven."
        )
    }

    private func recoveryResult(
        item: PersistentPreviewItem,
        operation: PersistentOperation,
        snapshot: ProviderInventorySnapshot,
        session: AgentSession?,
        runtimeVersion: String
    ) async -> PersistentReportItem {
        guard snapshot.inventoryComplete else {
            return unknown(
                item.managerKey,
                code: "batch_recovery_inventory_incomplete",
                message: "Recovery requires a complete inventory and never resends the mutation."
            )
        }
        switch operation {
        case .archive, .moveToTrash:
            if session?.nativeID == item.nativeSessionID,
               session?.nativeState == .archived {
                return success(item.managerKey, state: .archived, at: snapshot.observedAt)
            }
        case .restore:
            if session?.nativeID == item.nativeSessionID,
               session?.nativeState == .active {
                return success(item.managerKey, state: .active, at: snapshot.observedAt)
            }
        case .permanentlyDelete:
            if session == nil {
                let exact = await transport.exactDeleteRead(
                    item.nativeSessionID,
                    auditedRuntimeVersion: runtimeVersion
                )
                if case let .absent(nativeID, exactAt, _) = exact,
                   nativeID == item.nativeSessionID {
                    return success(
                        item.managerKey,
                        state: .absent,
                        at: max(snapshot.observedAt, exactAt)
                    )
                }
                return unknown(
                    item.managerKey,
                    code: "delete_batch_recovery_absence_unproven",
                    message: "Recovery could not prove both inventory and exact-read absence."
                )
            }
        case .moveToArchive:
            break
        }
        return failure(
            item.managerKey,
            state: session?.nativeState ?? .unavailable,
            at: snapshot.observedAt,
            code: "batch_recovery_target_state_not_reached",
            message: "Readback did not prove the requested state. No provider request was resent."
        )
    }

    private func persistAndPresent(
        _ preview: PersistentOperationPreview,
        displayed: OperationPreview,
        startedAt: Date,
        results: [PersistentReportItem],
        recovered: Bool
    ) throws -> NativeBatchReport {
        let outcome = reportOutcome(results)
        let completedAt = max(startedAt, results.map(\.evidenceAt).max() ?? now())
        let report = PersistentOperationReport(
            id: makeReportID(),
            previewID: preview.id,
            provider: preview.provider,
            operation: preview.operation,
            outcome: outcome,
            startedAt: startedAt,
            completedAt: completedAt,
            releasedBytesComplete: preview.operation != .permanentlyDelete,
            errorCode: outcome == .success ? nil : "native_batch_incomplete",
            errorMessage: outcome == .success
                ? nil
                : "The frozen batch did not complete successfully. Unattempted items were never sent.",
            items: results
        )
        try store.saveOperationReport(report, requiringPreviewStatus: .executing)
        let displayedByKey = Dictionary(uniqueKeysWithValues: displayed.items.map { ($0.managerKey, $0) })
        let reportItems = results.compactMap { result -> NativeArchiveReportItem? in
            guard let item = displayedByKey[result.managerKey] else { return nil }
            return NativeArchiveReportItem(
                managerKey: item.managerKey,
                nativeSessionID: item.nativeID,
                title: item.title,
                projectName: item.projectName,
                workingDirectory: item.workingDirectory,
                outcome: result.outcome,
                observedNativeState: result.observedNativeState,
                errorCode: result.errorCode,
                message: result.errorMessage
            )
        }
        guard reportItems.count == displayed.items.count else {
            throw PersistentStateError.previewItemSetMismatch
        }
        return NativeBatchReport(
            id: report.id,
            previewID: report.previewID,
            operation: displayed.operation,
            outcome: report.outcome,
            completedAt: report.completedAt,
            items: reportItems,
            recoveredAfterInterruption: recovered
        )
    }

    private func reportOutcome(_ items: [PersistentReportItem]) -> PersistentReportOutcome {
        if items.allSatisfy({ $0.outcome == .success }) { return .success }
        if items.contains(where: { $0.outcome == .unknown }) { return .unknown }
        if items.contains(where: { $0.outcome == .success }) { return .partial }
        return .failure
    }

    private func success(
        _ managerKey: String,
        state: NativeSessionState,
        at: Date
    ) -> PersistentReportItem {
        PersistentReportItem(
            managerKey: managerKey,
            outcome: .success,
            observedNativeState: state,
            verifiedReleasedBytes: state == .absent ? nil : 0,
            evidenceAt: at
        )
    }

    private func failure(
        _ managerKey: String,
        state: NativeSessionState,
        at: Date,
        code: String,
        message: String
    ) -> PersistentReportItem {
        PersistentReportItem(
            managerKey: managerKey,
            outcome: .failure,
            observedNativeState: state,
            verifiedReleasedBytes: nil,
            evidenceAt: at,
            errorCode: code,
            errorMessage: message
        )
    }

    private func unknown(
        _ managerKey: String,
        code: String,
        message: String
    ) -> PersistentReportItem {
        PersistentReportItem(
            managerKey: managerKey,
            outcome: .unknown,
            observedNativeState: .unavailable,
            verifiedReleasedBytes: nil,
            evidenceAt: now(),
            errorCode: code,
            errorMessage: message
        )
    }

    private func notAttempted(_ managerKey: String) -> PersistentReportItem {
        failure(
            managerKey,
            state: .unavailable,
            at: now(),
            code: "batch_not_attempted",
            message: "No provider request was sent because an earlier batch item failed or became unknown."
        )
    }

    private func displayPreview(
        from preview: PersistentOperationPreview,
        confirmationToken: String
    ) -> OperationPreview {
        let operation: SessionOperation = switch preview.operation {
        case .archive: .archive
        case .moveToTrash: .moveToTrash
        case .restore: .restore
        case .moveToArchive: .moveToArchive
        case .permanentlyDelete: .emptyTrash
        }
        let source: SessionCollection = switch preview.operation {
        case .archive, .moveToTrash: .active
        case .restore: preview.trashMembershipMutation == .remove ? .trash : .archive
        case .moveToArchive, .permanentlyDelete: .trash
        }
        let target: SessionCollection = switch preview.operation {
        case .archive, .moveToArchive: .archive
        case .moveToTrash: .trash
        case .restore: .active
        case .permanentlyDelete: .deleted
        }
        return OperationPreview(
            id: preview.id,
            provider: preview.provider,
            operation: operation,
            confirmationToken: confirmationToken,
            generatedAt: preview.createdAt,
            items: preview.items.map {
                OperationPreviewItem(
                    managerKey: $0.managerKey,
                    nativeID: $0.nativeSessionID,
                    title: $0.expectedTitle,
                    projectID: $0.expectedProjectID,
                    projectName: nil,
                    workingDirectory: $0.expectedWorkingDirectory ?? "",
                    beforeCollection: source,
                    targetCollection: target,
                    sizeBytes: $0.knownSizeBytes
                )
            },
            warnings: batchWarnings(operation: operation)
        )
    }

    private func batchWarnings(operation: SessionOperation) -> [String] {
        var warnings = [
            "Every selected session is frozen and preflighted before the first request.",
            "Codex has no cross-session transaction. Requests run in exact sorted order and stop after the first failure or unknown result; no request is retried automatically.",
        ]
        if operation == .emptyTrash {
            warnings.insert(
                "Permanent Delete is irreversible and accepts only Manager Trash sessions; Archive cannot be deleted directly.",
                at: 0
            )
            warnings.insert(
                "Cross-host running/current evidence may be unavailable. Each Delete is attempted once; failure or unknown stops the batch, keeps unresolved sessions in Trash, and is never retried automatically.",
                at: 1
            )
        }
        return warnings
    }
}
