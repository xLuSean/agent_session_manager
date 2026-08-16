import Foundation

enum DeleteAuthorizationCoordinatorError: Error, Equatable, LocalizedError {
    case reportPersistenceFailed(
        previewID: UUID,
        executorOutcome: ArchiveExecutionOutcome,
        message: String
    )

    var errorDescription: String? {
        switch self {
        case let .reportPersistenceFailed(previewID, outcome, message):
            "Permanent Delete completed with executor outcome \(outcome.rawValue), but its audit Report could not be persisted for Preview \(previewID.uuidString): \(message). The executing Preview must be reconciled; never retry Delete blindly."
        }
    }
}

actor DeleteAuthorizationCoordinator {
    private let store: SQLiteStateStore
    private let executor: DeleteMutationExecutor
    private let now: @Sendable () -> Date
    private let makeReportID: @Sendable () -> UUID

    init(
        store: SQLiteStateStore,
        executor: DeleteMutationExecutor,
        now: @escaping @Sendable () -> Date = { Date() },
        makeReportID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.executor = executor
        self.now = now
        self.makeReportID = makeReportID
    }

    func prepare(
        _ preparedPreview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord
    ) throws -> PersistentOperationPreview {
        guard preparedPreview.status == .prepared,
              preparedPreview.provider == .codex,
              preparedPreview.operation == .permanentlyDelete,
              preparedPreview.trashMembershipMutation == .remove,
              preparedPreview.items.count == 1,
              preparedPreview.items[0].expectedNativeState == .archived else {
            throw PersistentStateError.invalidRecord(
                "Permanent Delete requires one prepared Archived Codex Trash item."
            )
        }
        try store.saveOperationPreview(preparedPreview, checkpoint: checkpoint)
        guard let persisted = try store.operationPreview(id: preparedPreview.id),
              persisted == preparedPreview else {
            throw PersistentStateError.invalidRecord(
                "Persisted Permanent Delete Preview readback differs from the frozen Preview."
            )
        }
        return persisted
    }

    func execute(
        previewID: UUID,
        confirmationToken: String
    ) async throws -> PersistentOperationReport {
        let startedAt = now()
        let claimed = try store.claimOperationPreviewForExecution(
            id: previewID,
            now: startedAt,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            )
        )

        let result: DeleteExecutionResult
        do {
            result = try await executor.execute(
                preview: claimed.preview,
                checkpoint: claimed.checkpoint,
                confirmationToken: confirmationToken
            )
        } catch {
            result = DeleteExecutionResult(
                previewID: claimed.preview.id,
                managerKey: claimed.preview.items[0].managerKey,
                nativeSessionID: claimed.preview.items[0].nativeSessionID,
                outcome: .failure,
                deleteRequestAcknowledged: false,
                observedNativeState: .unavailable,
                completedAt: now(),
                errorCode: executionErrorCode(error),
                message: error.localizedDescription
            )
        }

        let outcome: PersistentReportOutcome = switch result.outcome {
        case .success: .success
        case .failure: .failure
        case .unknown: .unknown
        }
        let itemOutcome: PersistentItemOutcome = switch result.outcome {
        case .success: .success
        case .failure: .failure
        case .unknown: .unknown
        }
        let completedAt = max(startedAt, result.completedAt)
        let report = PersistentOperationReport(
            id: makeReportID(),
            previewID: claimed.preview.id,
            provider: .codex,
            operation: .permanentlyDelete,
            outcome: outcome,
            startedAt: startedAt,
            completedAt: completedAt,
            // The lifecycle API proves identity absence, not filesystem bytes.
            releasedBytesComplete: false,
            errorCode: result.errorCode,
            errorMessage: result.outcome == .success ? nil : result.message,
            items: [
                PersistentReportItem(
                    managerKey: result.managerKey,
                    outcome: itemOutcome,
                    observedNativeState: result.observedNativeState,
                    verifiedReleasedBytes: nil,
                    evidenceAt: completedAt,
                    errorCode: result.errorCode,
                    errorMessage: result.outcome == .success ? nil : result.message
                ),
            ]
        )
        do {
            try store.saveOperationReport(report, requiringPreviewStatus: .executing)
        } catch {
            throw DeleteAuthorizationCoordinatorError.reportPersistenceFailed(
                previewID: claimed.preview.id,
                executorOutcome: result.outcome,
                message: error.localizedDescription
            )
        }
        return report
    }

    private func executionErrorCode(_ error: Error) -> String {
        guard let executionError = error as? DeleteExecutionError else {
            return "delete_preflight_unknown"
        }
        switch executionError {
        case .expired: return "delete_preview_expired"
        case .confirmationMismatch: return "delete_confirmation_mismatch"
        case .invalidPreview: return "delete_preview_invalid"
        case .checkpointMismatch: return "delete_checkpoint_mismatch"
        case .preflightUnavailable: return "delete_preflight_unavailable"
        case .stateDrift: return "delete_state_drift"
        case .protectedSession: return "delete_session_protected"
        case .descendantScopeChanged: return "delete_descendant_scope_changed"
        }
    }
}

public typealias NativeDeleteReportItem = NativeArchiveReportItem

public struct NativeDeleteReport: Identifiable, Sendable {
    public let id: UUID
    public let previewID: UUID
    public let outcome: PersistentReportOutcome
    public let completedAt: Date
    public let items: [NativeDeleteReportItem]
    public let recoveredAfterInterruption: Bool

    public var successCount: Int { items.filter { $0.outcome == .success }.count }
    public var failureCount: Int { items.filter { $0.outcome == .failure }.count }
    public var unknownCount: Int { items.filter { $0.outcome == .unknown }.count }

    public init(
        id: UUID,
        previewID: UUID,
        outcome: PersistentReportOutcome,
        completedAt: Date,
        items: [NativeDeleteReportItem],
        recoveredAfterInterruption: Bool
    ) {
        self.id = id
        self.previewID = previewID
        self.outcome = outcome
        self.completedAt = completedAt
        self.items = items
        self.recoveredAfterInterruption = recoveredAfterInterruption
    }
}

/// Production boundary for one exact manager Trash -> Deleted transition.
/// Archive sessions are intentionally rejected until manager Trash intent has
/// first been created in a separate frozen operation.
public actor CodexNativeDeleteCoordinator {
    private let store: SQLiteStateStore
    private let authorization: DeleteAuthorizationCoordinator
    private let now: @Sendable () -> Date
    private let makePreviewID: @Sendable () -> UUID

    public init(
        store: SQLiteStateStore,
        configuration: CodexAppServerConfiguration = CodexAppServerConfiguration()
    ) {
        let transport = CodexDeleteMutationTransport(
            source: CodexAppServerClient(configuration: configuration)
        )
        self.store = store
        self.authorization = DeleteAuthorizationCoordinator(
            store: store,
            executor: DeleteMutationExecutor(transport: transport)
        )
        self.now = { Date() }
        self.makePreviewID = { UUID() }
    }

    init(
        store: SQLiteStateStore,
        transport: any DeleteMutationTransport,
        now: @escaping @Sendable () -> Date,
        makePreviewID: @escaping @Sendable () -> UUID,
        makeReportID: @escaping @Sendable () -> UUID
    ) {
        self.store = store
        self.authorization = DeleteAuthorizationCoordinator(
            store: store,
            executor: DeleteMutationExecutor(transport: transport, now: now),
            now: now,
            makeReportID: makeReportID
        )
        self.now = now
        self.makePreviewID = makePreviewID
    }

    public func prepare(
        managerKey: String,
        snapshot: ProviderInventorySnapshot,
        checkpoint: ProviderCheckpointRecord,
        lifetime: TimeInterval = 5 * 60
    ) async throws -> OperationPreview {
        guard lifetime > 0 else {
            throw PersistentStateError.invalidRecord(
                "Permanent Delete Preview lifetime must be positive."
            )
        }
        guard snapshot.provider == .codex, checkpoint.provider == .codex else {
            throw PersistentStateError.providerMismatch(
                expected: .codex,
                found: snapshot.provider
            )
        }
        guard snapshot.checkpoint == checkpoint,
              checkpoint.inventoryComplete else {
            throw PersistentStateError.invalidRecord(
                "Permanent Delete requires the exact complete inventory checkpoint."
            )
        }
        guard let runtimeVersion = checkpoint.runtimeVersion,
              CodexAppServerProvider.supportsVerifiedDeleteContract(runtimeVersion) else {
            throw PersistentStateError.invalidRecord(
                "The observed Codex runtime is outside the audited Permanent Delete allow-list."
            )
        }
        guard try store.providerCheckpoint(for: .codex) == checkpoint else {
            throw PersistentStateError.invalidRecord(
                "The authoritative checkpoint changed before Permanent Delete Preview persistence."
            )
        }

        let memberships = try store.trashMemberships(for: .codex)
        guard let membership = memberships.first(where: { $0.managerKey == managerKey }),
              let session = snapshot.sessions.first(where: { $0.id == managerKey }),
              membership.nativeSessionID == session.nativeID else {
            throw SessionManagerError.unsupportedOperation(
                "Permanent Delete is available only for an exact manager Trash session. Archive must be moved to Trash first."
            )
        }
        guard session.nativeState == .archived,
              session.descendantCountKnown,
              session.descendantCount == 0,
              !session.protection.blocksDeleteAttempt else {
            throw SessionManagerError.unsupportedOperation(
                "Permanent Delete requires one stable Archived Trash session with known-clear pin/descendant protection, no positive running/current signal, and zero descendants."
            )
        }

        let createdAt = PersistentTimestamp.canonical(now())
        let expiresAt = PersistentTimestamp.canonical(
            createdAt.addingTimeInterval(lifetime)
        )
        let previewID = makePreviewID()
        let confirmationToken = "DELETE-\(previewID.uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let item = PersistentPreviewItem(
            managerKey: session.id,
            nativeSessionID: session.nativeID,
            expectedNativeState: .archived,
            expectedProtectionHash: try ConflictResolutionHasher.membershipSetHash(memberships),
            expectedTitle: session.title,
            expectedProjectID: session.project?.id,
            expectedWorkingDirectory: session.workingDirectory,
            knownSizeBytes: session.sizeBytes
        )
        let manifestHash = try ArchiveExecutionHasher.manifestHash(
            provider: .codex,
            operation: .permanentlyDelete,
            providerInventoryHash: checkpoint.inventoryHash,
            runtimeVersion: runtimeVersion,
            reconciliationTimestamp: checkpoint.refreshedAt,
            createdAt: createdAt,
            expiresAt: expiresAt,
            trashMembershipMutation: .remove,
            items: [item]
        )
        let persistentPreview = PersistentOperationPreview(
            id: previewID,
            provider: .codex,
            operation: .permanentlyDelete,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            ),
            manifestHash: manifestHash,
            providerInventoryHash: checkpoint.inventoryHash,
            trashMembershipMutation: .remove,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: [item]
        )
        _ = try await authorization.prepare(
            persistentPreview,
            checkpoint: checkpoint
        )

        return OperationPreview(
            id: previewID,
            provider: .codex,
            operation: .emptyTrash,
            confirmationToken: confirmationToken,
            generatedAt: createdAt,
            items: [
                OperationPreviewItem(
                    managerKey: session.id,
                    nativeID: session.nativeID,
                    title: session.title,
                    projectID: session.project?.id,
                    projectName: session.project?.name,
                    workingDirectory: session.workingDirectory,
                    beforeCollection: .trash,
                    targetCollection: .deleted,
                    sizeBytes: session.sizeBytes
                ),
            ],
            warnings: [
                "Permanent Delete is irreversible. Archive sessions cannot be deleted directly; only this app's Trash membership is eligible.",
                "Codex may not expose running/current state from another lifecycle host. This one-shot Delete attempt may be rejected or remain unverified; failure or unknown keeps the session in Trash.",
                "Confirm sends at most one official thread/delete request. Success requires both a fresh complete inventory and exact-ID readback to prove absence.",
                "The app never retries Delete automatically, and it does not claim that filesystem bytes were released.",
            ]
        )
    }

    public func execute(
        preview: OperationPreview,
        confirmationToken: String
    ) async throws -> NativeDeleteReport {
        guard preview.provider == .codex,
              preview.operation == .emptyTrash,
              preview.items.count == 1,
              let displayItem = preview.items.first else {
            throw SessionManagerError.unsupportedOperation(
                "Permanent Delete execution requires one exact Codex Trash Preview."
            )
        }
        guard let persistentPreview = try store.operationPreview(id: preview.id),
              persistentPreview.status == .prepared,
              persistentPreview.operation == .permanentlyDelete,
              persistentPreview.trashMembershipMutation == .remove,
              persistentPreview.items.count == 1,
              let frozenItem = persistentPreview.items.first,
              preview.generatedAt == persistentPreview.createdAt,
              frozenItem.managerKey == displayItem.managerKey,
              frozenItem.nativeSessionID == displayItem.nativeID,
              frozenItem.expectedTitle == displayItem.title,
              frozenItem.expectedProjectID == displayItem.projectID,
              frozenItem.expectedWorkingDirectory == displayItem.workingDirectory,
              displayItem.beforeCollection == .trash,
              displayItem.targetCollection == .deleted else {
            throw PersistentStateError.invalidRecord(
                "Displayed Permanent Delete Preview differs from its frozen SQLite record."
            )
        }
        guard let checkpoint = try store.providerCheckpoint(for: .codex),
              CodexAppServerProvider.supportsVerifiedDeleteContract(
                  checkpoint.runtimeVersion
              ) else {
            throw PersistentStateError.invalidRecord(
                "The persisted Codex runtime is outside the audited Permanent Delete allow-list."
            )
        }

        let persistentReport = try await authorization.execute(
            previewID: preview.id,
            confirmationToken: confirmationToken
        )
        guard persistentReport.items.count == 1,
              let reportItem = persistentReport.items.first,
              reportItem.managerKey == displayItem.managerKey else {
            throw PersistentStateError.previewItemSetMismatch
        }
        if persistentReport.outcome == .success {
            let memberships = try store.trashMemberships(for: .codex)
            let tombstones = try store.deletedSessions(for: .codex)
            guard !memberships.contains(where: { $0.managerKey == displayItem.managerKey }),
                  tombstones.contains(where: {
                      $0.managerKey == displayItem.managerKey
                          && $0.nativeSessionID == displayItem.nativeID
                          && $0.deleteReportID == persistentReport.id
                  }) else {
                throw PersistentStateError.invalidRecord(
                    "Permanent Delete succeeded, but atomic Trash removal or Deleted tombstone readback failed."
                )
            }
        }

        return NativeDeleteReport(
            id: persistentReport.id,
            previewID: persistentReport.previewID,
            outcome: persistentReport.outcome,
            completedAt: persistentReport.completedAt,
            items: [
                NativeDeleteReportItem(
                    managerKey: displayItem.managerKey,
                    nativeSessionID: displayItem.nativeID,
                    title: displayItem.title,
                    projectName: displayItem.projectName,
                    workingDirectory: displayItem.workingDirectory,
                    outcome: reportItem.outcome,
                    observedNativeState: reportItem.observedNativeState,
                    errorCode: reportItem.errorCode,
                    message: reportItem.errorMessage
                ),
            ],
            recoveredAfterInterruption: false
        )
    }
}

enum DeleteRecoveryError: Error, Equatable, LocalizedError {
    case invalidPreview(String)
    case checkpointUnavailable(String)
    case evidenceUnavailable(String)
    case reportPersistenceFailed(previewID: UUID, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidPreview(message):
            "Permanent Delete recovery rejected the executing Preview: \(message)."
        case let .checkpointUnavailable(message):
            "Permanent Delete recovery checkpoint is unavailable: \(message)."
        case let .evidenceUnavailable(message):
            "Permanent Delete recovery evidence is unavailable: \(message). No Delete request was resent."
        case let .reportPersistenceFailed(previewID, message):
            "Permanent Delete recovery could not persist the readback Report for Preview \(previewID.uuidString): \(message)."
        }
    }
}

protocol DeleteExecutionRecoveryReadback: Sendable {
    func exactReadObservation(
        nativeSessionID: String,
        auditedRuntimeVersion: String
    ) async -> DeleteExactReadObservation
}

actor CodexDeleteExecutionRecoveryReadback: DeleteExecutionRecoveryReadback {
    private let source: any CodexInventorySource

    init(source: any CodexInventorySource) {
        self.source = source
    }

    func exactReadObservation(
        nativeSessionID: String,
        auditedRuntimeVersion: String
    ) async -> DeleteExactReadObservation {
        do {
            let snapshot = try await source.exactRead(threadID: nativeSessionID)
            guard snapshot.thread.id == nativeSessionID else {
                return .unavailable(
                    observedAt: snapshot.observedAt,
                    errorCode: "delete_recovery_exact_identity_mismatch",
                    message: "thread/read returned a different native session ID."
                )
            }
            return .present(
                nativeSessionID: nativeSessionID,
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
                errorCode: "delete_recovery_exact_unavailable",
                message: error.localizedDescription
            )
        }
    }
}

actor DeleteExecutionRecoveryReconciler {
    private let store: SQLiteStateStore
    private let readback: any DeleteExecutionRecoveryReadback
    private let makeReportID: @Sendable () -> UUID

    init(
        store: SQLiteStateStore,
        readback: any DeleteExecutionRecoveryReadback,
        makeReportID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.readback = readback
        self.makeReportID = makeReportID
    }

    func reconcile(
        previewID: UUID,
        snapshot: ProviderInventorySnapshot
    ) async throws -> PersistentOperationReport {
        let context = try loadContext(previewID: previewID)
        let exact = await readback.exactReadObservation(
            nativeSessionID: context.preview.items[0].nativeSessionID,
            auditedRuntimeVersion: context.runtimeVersion
        )
        let evidence = try classify(
            snapshot: snapshot,
            exact: exact,
            preview: context.preview,
            runtimeVersion: context.runtimeVersion
        )
        let completedAt = max(context.preview.createdAt, snapshot.observedAt)
        let report = PersistentOperationReport(
            id: makeReportID(),
            previewID: context.preview.id,
            provider: .codex,
            operation: .permanentlyDelete,
            outcome: evidence.outcome,
            startedAt: context.preview.createdAt,
            completedAt: completedAt,
            releasedBytesComplete: false,
            errorCode: evidence.errorCode,
            errorMessage: evidence.message,
            items: [
                PersistentReportItem(
                    managerKey: context.preview.items[0].managerKey,
                    outcome: evidence.itemOutcome,
                    observedNativeState: evidence.observedState,
                    verifiedReleasedBytes: nil,
                    evidenceAt: completedAt,
                    errorCode: evidence.errorCode,
                    errorMessage: evidence.message
                ),
            ]
        )
        do {
            try store.saveOperationReport(report, requiringPreviewStatus: .executing)
        } catch {
            throw DeleteRecoveryError.reportPersistenceFailed(
                previewID: context.preview.id,
                message: error.localizedDescription
            )
        }
        return report
    }

    private func loadContext(
        previewID: UUID
    ) throws -> (preview: PersistentOperationPreview, runtimeVersion: String) {
        guard let preview = try store.operationPreview(id: previewID),
              preview.status == .executing,
              preview.provider == .codex,
              preview.operation == .permanentlyDelete,
              preview.trashMembershipMutation == .remove,
              preview.items.count == 1,
              let item = preview.items.first,
              item.expectedNativeState == .archived,
              item.managerKey == "\(AgentSystem.codex.rawValue):\(item.nativeSessionID)" else {
            throw DeleteRecoveryError.invalidPreview(
                "one exact executing Codex Trash item is required"
            )
        }
        guard let checkpoint = try store.providerCheckpoint(for: .codex),
              checkpoint.inventoryComplete,
              checkpoint.inventoryHash == preview.providerInventoryHash,
              let runtimeVersion = checkpoint.runtimeVersion,
              CodexAppServerProvider.supportsVerifiedDeleteContract(runtimeVersion) else {
            throw DeleteRecoveryError.checkpointUnavailable(
                "the original complete claim checkpoint or audited runtime identity changed"
            )
        }
        let manifestHash = try ArchiveExecutionHasher.manifestHash(
            provider: preview.provider,
            operation: preview.operation,
            providerInventoryHash: preview.providerInventoryHash,
            runtimeVersion: runtimeVersion,
            reconciliationTimestamp: checkpoint.refreshedAt,
            createdAt: preview.createdAt,
            expiresAt: preview.expiresAt,
            trashMembershipMutation: preview.trashMembershipMutation,
            items: preview.items
        )
        guard manifestHash == preview.manifestHash else {
            throw DeleteRecoveryError.checkpointUnavailable(
                "the frozen manifest no longer matches the original claim checkpoint"
            )
        }
        let memberships = try store.trashMemberships(for: .codex)
        guard memberships.contains(where: {
            $0.managerKey == item.managerKey && $0.nativeSessionID == item.nativeSessionID
        }), try ConflictResolutionHasher.membershipSetHash(memberships)
            == item.expectedProtectionHash else {
            throw DeleteRecoveryError.checkpointUnavailable(
                "Manager Trash membership drifted before recovery"
            )
        }
        return (preview, runtimeVersion)
    }

    private func classify(
        snapshot: ProviderInventorySnapshot,
        exact: DeleteExactReadObservation,
        preview: PersistentOperationPreview,
        runtimeVersion: String
    ) throws -> RecoveryEvidence {
        guard snapshot.provider == .codex,
              snapshot.inventoryComplete,
              snapshot.runtimeVersion == runtimeVersion,
              snapshot.observedAt >= preview.createdAt else {
            throw DeleteRecoveryError.evidenceUnavailable(
                "fresh complete inventory from the original runtime is required"
            )
        }
        let item = preview.items[0]
        let matches = snapshot.sessions.filter {
            $0.id == item.managerKey && $0.nativeID == item.nativeSessionID
        }
        guard matches.count <= 1 else {
            throw DeleteRecoveryError.evidenceUnavailable(
                "inventory returned duplicate exact identities"
            )
        }
        if let session = matches.first {
            guard session.nativeState == .archived else {
                throw DeleteRecoveryError.evidenceUnavailable(
                    "the exact session returned an unexpected native state"
                )
            }
            guard case let .present(nativeID, observedAt, exactRuntime) = exact,
                  nativeID == item.nativeSessionID,
                  observedAt >= preview.createdAt,
                  exactRuntime == runtimeVersion else {
                throw DeleteRecoveryError.evidenceUnavailable(
                    "list and exact-ID readback disagree about continued presence"
                )
            }
            return RecoveryEvidence(
                outcome: .unknown,
                itemOutcome: .unknown,
                observedState: .archived,
                errorCode: "delete_recovery_still_archived",
                message: "Both official readbacks still return the Archived session. The earlier Delete outcome is unknown and no request was resent."
            )
        }

        guard case let .absent(nativeID, observedAt, exactRuntime) = exact,
              nativeID == item.nativeSessionID,
              observedAt >= preview.createdAt,
              exactRuntime == runtimeVersion else {
            throw DeleteRecoveryError.evidenceUnavailable(
                "inventory omission lacks the audited exact-ID absence discriminator"
            )
        }
        return RecoveryEvidence(
            outcome: .success,
            itemOutcome: .success,
            observedState: .absent,
            errorCode: nil,
            message: nil
        )
    }

    private struct RecoveryEvidence {
        let outcome: PersistentReportOutcome
        let itemOutcome: PersistentItemOutcome
        let observedState: NativeSessionState
        let errorCode: String?
        let message: String?
    }
}

/// Readback-only recovery for a claimed Delete. This type has no mutation
/// interface and therefore cannot resend `thread/delete` after interruption.
public actor CodexNativeDeleteRecoveryCoordinator {
    private let store: SQLiteStateStore
    private let reconciler: DeleteExecutionRecoveryReconciler

    public init(
        store: SQLiteStateStore,
        configuration: CodexAppServerConfiguration = CodexAppServerConfiguration()
    ) {
        self.store = store
        self.reconciler = DeleteExecutionRecoveryReconciler(
            store: store,
            readback: CodexDeleteExecutionRecoveryReadback(
                source: CodexAppServerClient(configuration: configuration)
            )
        )
    }

    init(
        store: SQLiteStateStore,
        reconciler: DeleteExecutionRecoveryReconciler
    ) {
        self.store = store
        self.reconciler = reconciler
    }

    public func recoverPending(
        using snapshot: ProviderInventorySnapshot
    ) async throws -> NativeDeleteReport? {
        let previews = try store.executingOperationPreviews(for: .codex)
        guard !previews.isEmpty else { return nil }
        guard previews.count == 1, let preview = previews.first else {
            throw SessionManagerError.unsupportedOperation(
                "Permanent Delete recovery found multiple executing Previews; it will not choose or shrink the set."
            )
        }
        guard preview.operation == .permanentlyDelete else { return nil }
        guard let item = preview.items.first, preview.items.count == 1 else {
            throw SessionManagerError.unsupportedOperation(
                "Permanent Delete recovery supports one exact Trash item."
            )
        }
        let report = try await reconciler.reconcile(
            previewID: preview.id,
            snapshot: snapshot
        )
        guard let reportItem = report.items.first,
              report.items.count == 1,
              reportItem.managerKey == item.managerKey else {
            throw PersistentStateError.previewItemSetMismatch
        }
        return NativeDeleteReport(
            id: report.id,
            previewID: report.previewID,
            outcome: report.outcome,
            completedAt: report.completedAt,
            items: [
                NativeDeleteReportItem(
                    managerKey: item.managerKey,
                    nativeSessionID: item.nativeSessionID,
                    title: item.expectedTitle,
                    projectName: nil,
                    workingDirectory: item.expectedWorkingDirectory,
                    outcome: reportItem.outcome,
                    observedNativeState: reportItem.observedNativeState,
                    errorCode: reportItem.errorCode,
                    message: reportItem.errorMessage
                ),
            ],
            recoveredAfterInterruption: true
        )
    }
}
