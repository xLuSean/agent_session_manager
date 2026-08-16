import Foundation

public struct NativeArchiveReportItem: Identifiable, Sendable {
    public let managerKey: String
    public let nativeSessionID: String
    public let title: String
    public let projectName: String?
    public let workingDirectory: String?
    public let outcome: PersistentItemOutcome
    public let observedNativeState: NativeSessionState
    public let errorCode: String?
    public let message: String?

    public var id: String { managerKey }
}

public struct NativeArchiveReport: Identifiable, Sendable {
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

    public init(
        id: UUID,
        previewID: UUID,
        operation: SessionOperation,
        outcome: PersistentReportOutcome,
        completedAt: Date,
        items: [NativeArchiveReportItem],
        recoveredAfterInterruption: Bool
    ) {
        self.id = id
        self.previewID = previewID
        self.operation = operation
        self.outcome = outcome
        self.completedAt = completedAt
        self.items = items
        self.recoveredAfterInterruption = recoveredAfterInterruption
    }
}

/// Production-facing boundary for the first native Archive slice. The App can
/// construct this facade, but it cannot access the underlying mutation
/// transport directly. Preview creation still fails closed unless the frozen
/// provider snapshot contains known pin/pinned-descendant evidence and no
/// positive lifecycle protection.
public actor CodexNativeArchiveCoordinator {
    private let store: SQLiteStateStore
    private let authorization: ArchiveAuthorizationCoordinator
    private let now: @Sendable () -> Date
    private let makePreviewID: @Sendable () -> UUID

    public init(
        store: SQLiteStateStore,
        configuration: CodexAppServerConfiguration = CodexAppServerConfiguration()
    ) {
        let transport = CodexArchiveMutationTransport(
            source: CodexAppServerClient(configuration: configuration)
        )
        self.store = store
        self.authorization = ArchiveAuthorizationCoordinator(
            store: store,
            executor: ArchiveMutationExecutor(transport: transport)
        )
        self.now = { Date() }
        self.makePreviewID = { UUID() }
    }

    init(
        store: SQLiteStateStore,
        transport: any ArchiveMutationTransport,
        now: @escaping @Sendable () -> Date,
        makePreviewID: @escaping @Sendable () -> UUID,
        makeReportID: @escaping @Sendable () -> UUID
    ) {
        self.store = store
        self.authorization = ArchiveAuthorizationCoordinator(
            store: store,
            executor: ArchiveMutationExecutor(transport: transport, now: now),
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
        operation: SessionOperation = .archive,
        lifetime: TimeInterval = 5 * 60
    ) async throws -> OperationPreview {
        guard lifetime > 0 else {
            throw PersistentStateError.invalidRecord(
                "Native Archive Preview lifetime must be positive."
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
                "Native Archive Preview requires the exact coordinated snapshot checkpoint."
            )
        }
        guard CodexAppServerProvider.supportsVerifiedLifecycleContract(
            snapshot.runtimeVersion
        ) else {
            throw PersistentStateError.invalidRecord(
                "The observed Codex runtime is outside the audited native Archive allow-list."
            )
        }
        guard try store.providerCheckpoint(for: .codex) == checkpoint else {
            throw PersistentStateError.invalidRecord(
                "The authoritative checkpoint changed before native Archive Preview persistence."
            )
        }
        guard operation == .archive || operation == .moveToTrash else {
            throw SessionManagerError.unsupportedOperation(
                "Native Archive accepts Archive or Active to Trash intent."
            )
        }
        guard let session = snapshot.sessions.first(where: { $0.id == managerKey }) else {
            throw SessionManagerError.sessionNotFound(managerKey)
        }
        guard session.nativeState == .active, !session.isTrashMember else {
            throw SessionManagerError.invalidTransition(
                session.nativeID,
                session.collection,
                .archive
            )
        }
        guard session.descendantCountKnown, session.descendantCount == 0 else {
            throw SessionManagerError.unsupportedOperation(
                "The first production Archive slice accepts only a verified zero-descendant session."
            )
        }

        let createdAt = PersistentTimestamp.canonical(now())
        let expiresAt = PersistentTimestamp.canonical(
            createdAt.addingTimeInterval(lifetime)
        )
        let tokenPrefix = operation == .moveToTrash ? "MOVE-TO-TRASH" : "ARCHIVE"
        let confirmationToken = "\(tokenPrefix)-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let persistentOperation = PersistentOperation(operation)
        let membershipMutation: TrashMembershipMutation? = operation == .moveToTrash
            ? .add
            : nil
        let persistentPreview = try ArchiveAffectedSetPreviewFactory.makePreparedPreview(
            selectedRootNativeSessionID: session.nativeID,
            snapshot: snapshot,
            operation: persistentOperation,
            trashMembershipMutation: membershipMutation,
            confirmationToken: confirmationToken,
            previewID: makePreviewID(),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        guard persistentPreview.items.count == 1 else {
            throw SessionManagerError.unsupportedOperation(
                "The first production Archive slice cannot execute an affected descendant set."
            )
        }
        _ = try await authorization.prepare(
            persistentPreview,
            checkpoint: checkpoint
        )

        return OperationPreview(
            id: persistentPreview.id,
            provider: .codex,
            operation: operation,
            confirmationToken: confirmationToken,
            generatedAt: persistentPreview.createdAt,
            items: [
                OperationPreviewItem(
                    managerKey: session.id,
                    nativeID: session.nativeID,
                    title: session.title,
                    projectID: session.project?.id,
                    projectName: session.project?.name,
                    workingDirectory: session.workingDirectory,
                    beforeCollection: .active,
                    targetCollection: operation == .moveToTrash ? .trash : .archive,
                    sizeBytes: session.sizeBytes
                ),
            ],
            warnings: [
                "Codex may reject this one-shot Archive request as Busy. The app will perform one fresh readback and will not retry automatically.",
                operation == .moveToTrash
                    ? "Manager Trash membership is added only after official readback verifies Archived."
                    : "Codex Archive does not create Manager Trash membership.",
            ]
        )
    }

    public func execute(
        preview: OperationPreview,
        confirmationToken: String
    ) async throws -> NativeArchiveReport {
        guard preview.provider == .codex,
              (preview.operation == .archive || preview.operation == .moveToTrash),
              preview.items.count == 1,
              let displayItem = preview.items.first else {
            throw SessionManagerError.unsupportedOperation(
                "Native Archive execution requires one exact Codex Archive Preview."
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
              displayItem.beforeCollection == .active,
              displayItem.targetCollection == preview.operation.targetCollection(from: .active) else {
            throw PersistentStateError.invalidRecord(
                "Displayed Archive Preview differs from its frozen SQLite record."
            )
        }
        guard let checkpoint = try store.providerCheckpoint(for: .codex),
              CodexAppServerProvider.supportsVerifiedLifecycleContract(
                  checkpoint.runtimeVersion
              ) else {
            throw PersistentStateError.invalidRecord(
                "The persisted Codex runtime is outside the audited native Archive allow-list."
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
        if preview.operation == .moveToTrash,
           persistentReport.outcome == .success {
            let membershipKeys = Set(try store.trashMemberships(for: .codex).map(\.managerKey))
            guard membershipKeys.contains(displayItem.managerKey) else {
                throw PersistentStateError.invalidRecord(
                    "Active to Trash succeeded, but Trash membership readback failed."
                )
            }
        }

        return NativeArchiveReport(
            id: persistentReport.id,
            previewID: persistentReport.previewID,
            operation: preview.operation,
            outcome: persistentReport.outcome,
            completedAt: persistentReport.completedAt,
            items: [
                NativeArchiveReportItem(
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

/// Production recovery boundary for durable Archive work that was claimed but
/// did not finish its Report commit before the app stopped. This facade owns
/// readback capability only and cannot issue or retry `thread/archive`.
public actor CodexNativeArchiveRecoveryCoordinator {
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

    /// Resolves the one production-supported single-root executing Preview
    /// using the already completed official Live snapshot. Zero work is a
    /// no-op; multiple records fail closed instead of choosing one silently.
    public func recoverPending(
        using snapshot: ProviderInventorySnapshot
    ) async throws -> NativeArchiveReport? {
        let previews = try store.executingOperationPreviews(for: .codex)
        guard !previews.isEmpty else { return nil }
        guard previews.count == 1, let preview = previews.first else {
            throw SessionManagerError.unsupportedOperation(
                "Native Archive recovery found multiple executing Previews; automatic recovery will not choose or shrink the set."
            )
        }
        guard preview.operation == .archive || preview.operation == .moveToTrash else { return nil }
        guard preview.provider == .codex,
              preview.items.count == 1,
              let frozenItem = preview.items.first else {
            throw SessionManagerError.unsupportedOperation(
                "Native Archive recovery supports one exact Codex Archive item."
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
        return NativeArchiveReport(
            id: persistentReport.id,
            previewID: persistentReport.previewID,
            operation: preview.operation == .moveToTrash ? .moveToTrash : .archive,
            outcome: persistentReport.outcome,
            completedAt: persistentReport.completedAt,
            items: [
                NativeArchiveReportItem(
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
