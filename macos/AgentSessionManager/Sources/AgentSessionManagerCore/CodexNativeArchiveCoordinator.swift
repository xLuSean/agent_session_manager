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

    public init(
        managerKey: String,
        nativeSessionID: String,
        title: String,
        projectName: String? = nil,
        workingDirectory: String? = nil,
        outcome: PersistentItemOutcome,
        observedNativeState: NativeSessionState,
        errorCode: String? = nil,
        message: String? = nil
    ) {
        self.managerKey = managerKey
        self.nativeSessionID = nativeSessionID
        self.title = title
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.outcome = outcome
        self.observedNativeState = observedNativeState
        self.errorCode = errorCode
        self.message = message
    }
}

public struct NativeArchiveReport: Identifiable, Sendable {
    public let id: UUID
    public let previewID: UUID
    public let operation: SessionOperation
    public let outcome: PersistentReportOutcome
    public let completedAt: Date
    public let items: [NativeArchiveReportItem]
    public let recoveredAfterInterruption: Bool
    public let preservedTrashIntent: Bool

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
        recoveredAfterInterruption: Bool,
        preservedTrashIntent: Bool = false
    ) {
        self.id = id
        self.previewID = previewID
        self.operation = operation
        self.outcome = outcome
        self.completedAt = completedAt
        self.items = items
        self.recoveredAfterInterruption = recoveredAfterInterruption
        self.preservedTrashIntent = preservedTrashIntent
    }
}

/// Production-facing boundary for single-session native Archive. The App can
/// construct this facade, but it cannot access the underlying mutation
/// transport directly. Preview creation still fails closed unless the frozen
/// provider snapshot contains known pin/pinned-descendant evidence and no
/// positive lifecycle protection.
public actor CodexNativeArchiveCoordinator {
    private let store: SQLiteStateStore
    private let authorization: ArchiveAuthorizationCoordinator
    private let executionGate: any CodexLifecycleExecutionChecking
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
        self.executionGate = CodexDesktopLifecycleExecutionGate()
        self.now = { Date() }
        self.makePreviewID = { UUID() }
    }

    init(
        store: SQLiteStateStore,
        transport: any ArchiveMutationTransport,
        executionGate: any CodexLifecycleExecutionChecking,
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
        self.executionGate = executionGate
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
        let session = try validateArchiveContext(
            managerKey: managerKey,
            snapshot: snapshot,
            checkpoint: checkpoint,
            lifetime: lifetime
        )
        guard operation == .archive || operation == .moveToTrash else {
            throw SessionManagerError.unsupportedOperation(
                "Native Archive accepts Archive or Active to Trash intent."
            )
        }
        guard session.nativeState == .active, !session.isTrashMember else {
            throw SessionManagerError.invalidTransition(
                session.nativeID,
                session.collection,
                .archive
            )
        }
        let membershipMutation: TrashMembershipMutation? = operation == .moveToTrash
            ? .add
            : nil
        return try await makePreparedPreview(
            session: session,
            snapshot: snapshot,
            checkpoint: checkpoint,
            operation: operation,
            membershipMutation: membershipMutation,
            expectedTrashMembershipSetHash: nil,
            beforeCollection: .active,
            targetCollection: operation == .moveToTrash ? .trash : .archive,
            lifetime: lifetime
        )
    }

    /// Reapplies an existing manager Trash intent by sending the same audited
    /// one-shot official Archive request used by normal Archive. The complete
    /// manager Trash intent set is frozen and must remain intent-equivalent at
    /// Preview persistence, execution claim, and Report commit.
    public func prepareReapplyTrashIntent(
        state: ReconciledSessionState,
        snapshot: ProviderInventorySnapshot,
        checkpoint: ProviderCheckpointRecord,
        lifetime: TimeInterval = 5 * 60
    ) async throws -> OperationPreview {
        guard state.status == .nativeActiveTrashConflict,
              let liveSession = state.liveSession,
              let membership = state.trashMembership,
              liveSession.system == .codex,
              liveSession.nativeState == .active,
              membership.provider == .codex,
              membership.managerKey == liveSession.id,
              membership.nativeSessionID == liveSession.nativeID,
              state.managerKey == liveSession.id else {
            throw PersistentStateError.invalidRecord(
                "Reapply Trash Intent requires one exact Active plus manager Trash conflict."
            )
        }
        let session = try validateArchiveContext(
            managerKey: state.managerKey,
            snapshot: snapshot,
            checkpoint: checkpoint,
            lifetime: lifetime
        )
        guard session.nativeID == liveSession.nativeID,
              session.nativeState == .active else {
            throw PersistentStateError.invalidRecord(
                "Reapply Trash Intent snapshot differs from the reconciled conflict."
            )
        }
        let memberships = try store.trashMemberships(for: .codex)
        guard let storedMembership = memberships.first(where: {
            $0.managerKey == membership.managerKey
        }),
        ConflictResolutionHasher.sameTrashIntent(storedMembership, membership) else {
            throw PersistentStateError.invalidRecord(
                "The authoritative Trash intent changed before Reapply Preview persistence."
            )
        }
        return try await makePreparedPreview(
            session: session,
            snapshot: snapshot,
            checkpoint: checkpoint,
            operation: .archive,
            membershipMutation: nil,
            expectedTrashMembershipSetHash: try ConflictResolutionHasher.membershipSetHash(
                memberships
            ),
            beforeCollection: .trash,
            targetCollection: .trash,
            lifetime: lifetime
        )
    }

    private func validateArchiveContext(
        managerKey: String,
        snapshot: ProviderInventorySnapshot,
        checkpoint: ProviderCheckpointRecord,
        lifetime: TimeInterval
    ) throws -> AgentSession {
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
        if let reason = CodexLifecycleMutationKind.archive
            .compatibilityBlockedReason(runtimeVersion: snapshot.runtimeVersion, binding: checkpoint.compatibilityBinding) {
            throw SessionManagerError.unsupportedOperation(reason)
        }
        guard try store.providerCheckpoint(for: .codex) == checkpoint else {
            throw PersistentStateError.invalidRecord(
                "The authoritative checkpoint changed before native Archive Preview persistence."
            )
        }
        guard let session = snapshot.sessions.first(where: { $0.id == managerKey }) else {
            throw SessionManagerError.sessionNotFound(managerKey)
        }
        guard session.descendantCountKnown, session.descendantCount == 0 else {
            throw SessionManagerError.unsupportedOperation(
                "Archive requires a session with verified zero descendants."
            )
        }

        return session
    }

    private func makePreparedPreview(
        session: AgentSession,
        snapshot: ProviderInventorySnapshot,
        checkpoint: ProviderCheckpointRecord,
        operation: SessionOperation,
        membershipMutation: TrashMembershipMutation?,
        expectedTrashMembershipSetHash: String?,
        beforeCollection: SessionCollection,
        targetCollection: SessionCollection,
        lifetime: TimeInterval
    ) async throws -> OperationPreview {
        let createdAt = PersistentTimestamp.canonical(now())
        let expiresAt = PersistentTimestamp.canonical(
            createdAt.addingTimeInterval(lifetime)
        )
        let tokenPrefix = expectedTrashMembershipSetHash != nil
            ? "REAPPLY-TRASH"
            : operation == .moveToTrash ? "MOVE-TO-TRASH" : "ARCHIVE"
        let confirmationToken = "\(tokenPrefix)-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let persistentOperation = PersistentOperation(operation)
        let persistentPreview = try ArchiveAffectedSetPreviewFactory.makePreparedPreview(
            selectedRootNativeSessionID: session.nativeID,
            snapshot: snapshot,
            operation: persistentOperation,
            trashMembershipMutation: membershipMutation,
            expectedTrashMembershipSetHash: expectedTrashMembershipSetHash,
            confirmationToken: confirmationToken,
            previewID: makePreviewID(),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        guard persistentPreview.items.count == 1 else {
            throw SessionManagerError.unsupportedOperation(
                "Archive does not support an affected descendant set."
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
                    beforeCollection: beforeCollection,
                    targetCollection: targetCollection,
                    sizeBytes: session.sizeBytes
                ),
            ],
            warnings: [
                "Codex may reject this one-shot Archive request as Busy. The app will perform one fresh readback and will not retry automatically.",
                operation == .moveToTrash
                    ? "Manager Trash membership is added only after official readback verifies Archived."
                    : expectedTrashMembershipSetHash == nil
                        ? "Codex Archive does not create Manager Trash membership."
                        : "The complete existing Manager Trash intent is frozen and must remain unchanged before and after Archive.",
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
              let frozenItem = persistentPreview.items.first else {
            throw PersistentStateError.invalidRecord(
                "Displayed Archive Preview differs from its frozen SQLite record."
            )
        }
        let preservesTrashIntent = persistentPreview.expectedTrashMembershipSetHash != nil
        guard
              preview.generatedAt == persistentPreview.createdAt,
              frozenItem.managerKey == displayItem.managerKey,
              frozenItem.nativeSessionID == displayItem.nativeID,
              frozenItem.expectedTitle == displayItem.title,
              frozenItem.expectedProjectID == displayItem.projectID,
              frozenItem.expectedWorkingDirectory == displayItem.workingDirectory,
              displayItem.beforeCollection == (preservesTrashIntent ? .trash : .active),
              displayItem.targetCollection == (preservesTrashIntent
                ? .trash
                : preview.operation.targetCollection(from: .active)) else {
            throw PersistentStateError.invalidRecord(
                "Displayed Archive Preview differs from its frozen SQLite record."
            )
        }
        guard let checkpoint = try store.providerCheckpoint(for: .codex) else {
            throw PersistentStateError.invalidRecord(
                "The persisted Archive Preview has no authoritative Codex checkpoint."
            )
        }
        if let reason = CodexLifecycleMutationKind.archive
            .compatibilityBlockedReason(runtimeVersion: checkpoint.runtimeVersion, binding: checkpoint.compatibilityBinding) {
            throw SessionManagerError.unsupportedOperation(reason)
        }

        try await executionGate.requireCodexDesktopExited()

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
            recoveredAfterInterruption: false,
            preservedTrashIntent: preservesTrashIntent
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
            recoveredAfterInterruption: true,
            preservedTrashIntent: preview.expectedTrashMembershipSetHash != nil
        )
    }
}
