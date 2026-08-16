import Foundation

enum RestoreAuthorizationCoordinatorError: Error, Equatable, LocalizedError {
    case reportPersistenceFailed(
        previewID: UUID,
        executorOutcome: ArchiveExecutionOutcome,
        message: String
    )

    var errorDescription: String? {
        switch self {
        case let .reportPersistenceFailed(previewID, outcome, message):
            "Restore completed with executor outcome \(outcome.rawValue), but its audit Report could not be persisted for Preview \(previewID.uuidString): \(message). The executing Preview must be reconciled; never retry Restore blindly."
        }
    }
}

actor RestoreAuthorizationCoordinator {
    private let store: SQLiteStateStore
    private let executor: RestoreMutationExecutor
    private let now: @Sendable () -> Date
    private let makeReportID: @Sendable () -> UUID

    init(
        store: SQLiteStateStore,
        executor: RestoreMutationExecutor,
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
              preparedPreview.operation == .restore,
              preparedPreview.items.count == 1,
              preparedPreview.items[0].expectedNativeState == .archived else {
            throw PersistentStateError.invalidRecord(
                "Native Restore requires one prepared Archived Codex item."
            )
        }
        try store.saveOperationPreview(preparedPreview, checkpoint: checkpoint)
        guard let persisted = try store.operationPreview(id: preparedPreview.id),
              persisted == preparedPreview else {
            throw PersistentStateError.invalidRecord(
                "Persisted Restore Preview readback differs from the frozen Preview."
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

        let executionResult: RestoreExecutionResult
        do {
            executionResult = try await executor.execute(
                preview: claimed.preview,
                checkpoint: claimed.checkpoint,
                confirmationToken: confirmationToken
            )
        } catch {
            executionResult = RestoreExecutionResult(
                previewID: claimed.preview.id,
                managerKey: claimed.preview.items[0].managerKey,
                nativeSessionID: claimed.preview.items[0].nativeSessionID,
                outcome: .failure,
                restoreRequestAcknowledged: false,
                observedNativeState: .unavailable,
                completedAt: now(),
                errorCode: executionErrorCode(error),
                message: error.localizedDescription
            )
        }

        let report = makeReport(
            from: executionResult,
            preview: claimed.preview,
            startedAt: startedAt
        )
        do {
            try store.saveOperationReport(report, requiringPreviewStatus: .executing)
        } catch {
            throw RestoreAuthorizationCoordinatorError.reportPersistenceFailed(
                previewID: claimed.preview.id,
                executorOutcome: executionResult.outcome,
                message: error.localizedDescription
            )
        }
        return report
    }

    private func makeReport(
        from result: RestoreExecutionResult,
        preview: PersistentOperationPreview,
        startedAt: Date
    ) -> PersistentOperationReport {
        let reportOutcome: PersistentReportOutcome
        let itemOutcome: PersistentItemOutcome
        switch result.outcome {
        case .success:
            reportOutcome = .success
            itemOutcome = .success
        case .failure:
            reportOutcome = .failure
            itemOutcome = .failure
        case .unknown:
            reportOutcome = .unknown
            itemOutcome = .unknown
        }
        return PersistentOperationReport(
            id: makeReportID(),
            previewID: preview.id,
            provider: preview.provider,
            operation: preview.operation,
            outcome: reportOutcome,
            startedAt: startedAt,
            completedAt: max(startedAt, result.completedAt),
            releasedBytesComplete: true,
            errorCode: result.errorCode,
            errorMessage: result.outcome == .success ? nil : result.message,
            items: [
                PersistentReportItem(
                    managerKey: result.managerKey,
                    outcome: itemOutcome,
                    observedNativeState: result.observedNativeState,
                    verifiedReleasedBytes: 0,
                    evidenceAt: max(startedAt, result.completedAt),
                    errorCode: result.errorCode,
                    errorMessage: result.outcome == .success ? nil : result.message
                ),
            ]
        )
    }

    private func executionErrorCode(_ error: Error) -> String {
        guard let executionError = error as? RestoreExecutionError else {
            return "restore_preflight_unknown"
        }
        switch executionError {
        case .expired: return "restore_preview_expired"
        case .confirmationMismatch: return "restore_confirmation_mismatch"
        case .invalidPreview: return "restore_preview_invalid"
        case .checkpointMismatch: return "restore_checkpoint_mismatch"
        case .preflightUnavailable: return "restore_preflight_unavailable"
        case .stateDrift: return "restore_state_drift"
        }
    }
}

public typealias NativeRestoreReportItem = NativeArchiveReportItem

public struct NativeRestoreReport: Identifiable, Sendable {
    public let id: UUID
    public let previewID: UUID
    public let outcome: PersistentReportOutcome
    public let completedAt: Date
    public let items: [NativeRestoreReportItem]
    public let recoveredAfterInterruption: Bool

    public var successCount: Int { items.filter { $0.outcome == .success }.count }
    public var failureCount: Int { items.filter { $0.outcome == .failure }.count }
    public var unknownCount: Int { items.filter { $0.outcome == .unknown }.count }

    public init(
        id: UUID,
        previewID: UUID,
        outcome: PersistentReportOutcome,
        completedAt: Date,
        items: [NativeRestoreReportItem],
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

/// Production boundary for one native Restore. Manager Trash removal is frozen
/// in SQLite and committed atomically only after Active readback succeeds.
public actor CodexNativeRestoreCoordinator {
    private let store: SQLiteStateStore
    private let authorization: RestoreAuthorizationCoordinator
    private let now: @Sendable () -> Date
    private let makePreviewID: @Sendable () -> UUID

    public init(
        store: SQLiteStateStore,
        configuration: CodexAppServerConfiguration = CodexAppServerConfiguration()
    ) {
        let transport = CodexRestoreMutationTransport(
            source: CodexAppServerClient(configuration: configuration)
        )
        self.store = store
        self.authorization = RestoreAuthorizationCoordinator(
            store: store,
            executor: RestoreMutationExecutor(transport: transport)
        )
        self.now = { Date() }
        self.makePreviewID = { UUID() }
    }

    init(
        store: SQLiteStateStore,
        transport: any RestoreMutationTransport,
        now: @escaping @Sendable () -> Date,
        makePreviewID: @escaping @Sendable () -> UUID,
        makeReportID: @escaping @Sendable () -> UUID
    ) {
        self.store = store
        self.authorization = RestoreAuthorizationCoordinator(
            store: store,
            executor: RestoreMutationExecutor(transport: transport, now: now),
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
                "Native Restore Preview lifetime must be positive."
            )
        }
        guard snapshot.provider == .codex, checkpoint.provider == .codex else {
            throw PersistentStateError.providerMismatch(
                expected: .codex,
                found: snapshot.provider
            )
        }
        guard snapshot.checkpoint == checkpoint else {
            throw PersistentStateError.invalidRecord(
                "Native Restore Preview requires the exact coordinated snapshot checkpoint."
            )
        }
        guard let runtimeVersion = snapshot.runtimeVersion,
              CodexAppServerProvider.supportsVerifiedLifecycleContract(
                  runtimeVersion
              ) else {
            throw PersistentStateError.invalidRecord(
                "The observed Codex runtime is outside the audited native Restore allow-list."
            )
        }
        guard try store.providerCheckpoint(for: .codex) == checkpoint else {
            throw PersistentStateError.invalidRecord(
                "The authoritative checkpoint changed before native Restore Preview persistence."
            )
        }
        let trashMemberships = try store.trashMemberships(for: .codex)
        guard let session = snapshot.sessions.first(where: { $0.id == managerKey }) else {
            throw SessionManagerError.sessionNotFound(managerKey)
        }
        guard session.nativeState == .archived else {
            throw SessionManagerError.invalidTransition(
                session.nativeID,
                session.collection,
                .restore
            )
        }
        let isTrashRestore = trashMemberships.contains {
            $0.managerKey == managerKey && $0.nativeSessionID == session.nativeID
        }
        let membershipMutation: TrashMembershipMutation? = isTrashRestore ? .remove : nil

        let createdAt = PersistentTimestamp.canonical(now())
        let expiresAt = PersistentTimestamp.canonical(
            createdAt.addingTimeInterval(lifetime)
        )
        let previewID = makePreviewID()
        let confirmationToken = "RESTORE-\(previewID.uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let item = PersistentPreviewItem(
            managerKey: session.id,
            nativeSessionID: session.nativeID,
            expectedNativeState: .archived,
            expectedProtectionHash: isTrashRestore
                ? try ConflictResolutionHasher.membershipSetHash(trashMemberships)
                : try ArchiveExecutionHasher.protectionHash(for: session),
            expectedTitle: session.title,
            expectedProjectID: session.project?.id,
            expectedWorkingDirectory: session.workingDirectory,
            knownSizeBytes: session.sizeBytes
        )
        let manifestHash = try ArchiveExecutionHasher.manifestHash(
            provider: .codex,
            operation: .restore,
            providerInventoryHash: checkpoint.inventoryHash,
            runtimeVersion: runtimeVersion,
            reconciliationTimestamp: checkpoint.refreshedAt,
            createdAt: createdAt,
            expiresAt: expiresAt,
            trashMembershipMutation: membershipMutation,
            items: [item]
        )
        let persistentPreview = PersistentOperationPreview(
            id: previewID,
            provider: .codex,
            operation: .restore,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            ),
            manifestHash: manifestHash,
            providerInventoryHash: checkpoint.inventoryHash,
            trashMembershipMutation: membershipMutation,
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
            operation: .restore,
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
                    beforeCollection: isTrashRestore ? .trash : .archive,
                    targetCollection: .active,
                    sizeBytes: session.sizeBytes
                ),
            ],
            warnings: [
                "Confirm sends one official thread/unarchive request and then performs one fresh exact-ID inventory readback. It never retries automatically.",
                isTrashRestore
                    ? "Manager Trash membership is removed only after official readback verifies Active."
                    : "This Archive Restore does not change Manager Trash membership.",
            ]
        )
    }

    public func execute(
        preview: OperationPreview,
        confirmationToken: String
    ) async throws -> NativeRestoreReport {
        guard preview.provider == .codex,
              preview.operation == .restore,
              preview.items.count == 1,
              let displayItem = preview.items.first else {
            throw SessionManagerError.unsupportedOperation(
                "Native Restore execution requires one exact Codex Restore Preview."
            )
        }
        guard let persistentPreview = try store.operationPreview(id: preview.id),
              persistentPreview.status == .prepared,
              persistentPreview.items.count == 1,
              let frozenItem = persistentPreview.items.first,
              preview.generatedAt == persistentPreview.createdAt,
              frozenItem.managerKey == displayItem.managerKey,
              frozenItem.nativeSessionID == displayItem.nativeID,
              frozenItem.expectedTitle == displayItem.title,
              frozenItem.expectedProjectID == displayItem.projectID,
              frozenItem.expectedWorkingDirectory == displayItem.workingDirectory,
              (displayItem.beforeCollection == .archive || displayItem.beforeCollection == .trash),
              displayItem.targetCollection == .active else {
            throw PersistentStateError.invalidRecord(
                "Displayed Restore Preview differs from its frozen SQLite record."
            )
        }
        guard let checkpoint = try store.providerCheckpoint(for: .codex),
              CodexAppServerProvider.supportsVerifiedLifecycleContract(
                  checkpoint.runtimeVersion
              ) else {
            throw PersistentStateError.invalidRecord(
                "The persisted Codex runtime is outside the audited native Restore allow-list."
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
        if displayItem.beforeCollection == .trash,
           persistentReport.outcome == .success {
            let membershipKeys = Set(try store.trashMemberships(for: .codex).map(\.managerKey))
            guard !membershipKeys.contains(displayItem.managerKey) else {
                throw PersistentStateError.invalidRecord(
                    "Trash to Active succeeded, but Trash membership readback failed."
                )
            }
        }
        return NativeRestoreReport(
            id: persistentReport.id,
            previewID: persistentReport.previewID,
            outcome: persistentReport.outcome,
            completedAt: persistentReport.completedAt,
            items: [
                NativeRestoreReportItem(
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

/// Readback-only recovery for a claimed Restore whose Report was not committed
/// before interruption. It cannot issue or retry `thread/unarchive`.
public actor CodexNativeRestoreRecoveryCoordinator {
    private let store: SQLiteStateStore
    private let reconciler: ArchiveExecutionRecoveryReconciler

    public init(
        store: SQLiteStateStore,
        configuration: CodexAppServerConfiguration = CodexAppServerConfiguration()
    ) {
        self.store = store
        self.reconciler = ArchiveExecutionRecoveryReconciler(
            store: store,
            readback: CodexArchiveExecutionRecoveryReadback(
                source: CodexAppServerClient(configuration: configuration)
            )
        )
    }

    init(
        store: SQLiteStateStore,
        reconciler: ArchiveExecutionRecoveryReconciler
    ) {
        self.store = store
        self.reconciler = reconciler
    }

    public func recoverPending(
        using snapshot: ProviderInventorySnapshot
    ) async throws -> NativeRestoreReport? {
        let previews = try store.executingOperationPreviews(for: .codex)
        guard !previews.isEmpty else { return nil }
        guard previews.count == 1, let preview = previews.first else {
            throw SessionManagerError.unsupportedOperation(
                "Native Restore recovery found multiple executing Previews; automatic recovery will not choose or shrink the set."
            )
        }
        guard preview.operation == .restore else { return nil }
        guard preview.provider == .codex,
              preview.items.count == 1,
              let frozenItem = preview.items.first else {
            throw SessionManagerError.unsupportedOperation(
                "Native Restore recovery supports one exact Codex Restore item."
            )
        }

        let persistentReport = try await reconciler.reconcile(
            previewID: preview.id,
            snapshot: snapshot
        )
        guard persistentReport.items.count == 1,
              let reportItem = persistentReport.items.first,
              reportItem.managerKey == frozenItem.managerKey else {
            throw PersistentStateError.previewItemSetMismatch
        }
        return NativeRestoreReport(
            id: persistentReport.id,
            previewID: persistentReport.previewID,
            outcome: persistentReport.outcome,
            completedAt: persistentReport.completedAt,
            items: [
                NativeRestoreReportItem(
                    managerKey: frozenItem.managerKey,
                    nativeSessionID: frozenItem.nativeSessionID,
                    title: frozenItem.expectedTitle,
                    projectName: nil,
                    workingDirectory: nil,
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
