import Foundation

/// Durable execution path for collection changes whose Codex native state is
/// already Archived. It can only add or remove manager-owned Trash membership;
/// it has no provider transport or native lifecycle capability.
public actor ManagerOnlyOperationCoordinator {
    private let store: SQLiteStateStore
    private let now: @Sendable () -> Date
    private let makePreviewID: @Sendable () -> UUID
    private let makeReportID: @Sendable () -> UUID

    public init(
        store: SQLiteStateStore,
        now: @escaping @Sendable () -> Date = { Date() },
        makePreviewID: @escaping @Sendable () -> UUID = { UUID() },
        makeReportID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.now = now
        self.makePreviewID = makePreviewID
        self.makeReportID = makeReportID
    }

    public func prepare(
        operation: SessionOperation,
        sessions: [AgentSession],
        checkpoint: ProviderCheckpointRecord,
        lifetime: TimeInterval = 10 * 60
    ) throws -> OperationPreview {
        guard operation == .moveToTrash || operation == .moveToArchive else {
            throw SessionManagerError.unsupportedOperation(
                "The manager-only coordinator accepts only Archive to Trash or Trash to Archive."
            )
        }
        guard checkpoint.provider == .codex, checkpoint.inventoryComplete else {
            throw PersistentStateError.invalidRecord(
                "Manager-only Preview requires a complete Codex inventory checkpoint."
            )
        }
        if operation == .moveToTrash, !checkpoint.protectionComplete {
            throw PersistentStateError.invalidRecord(
                "Move to Trash requires complete lifecycle protection evidence."
            )
        }
        guard let runtimeVersion = checkpoint.runtimeVersion, !runtimeVersion.isEmpty else {
            throw PersistentStateError.invalidRecord(
                "Manager-only Preview requires a runtime-bound checkpoint."
            )
        }
        let ordered = sessions.sorted { $0.id < $1.id }
        guard !ordered.isEmpty else { throw SessionManagerError.emptySelection }
        guard Set(ordered.map(\.id)).count == ordered.count else {
            throw PersistentStateError.invalidRecord(
                "Manager-only Preview contains duplicate sessions."
            )
        }

        let source: SessionCollection = operation == .moveToTrash ? .archive : .trash
        for session in ordered {
            guard session.system == .codex else {
                throw SessionManagerError.mixedProviders
            }
            let plan = try operation.plan(
                from: session.collection,
                nativeSessionID: session.nativeID
            )
            guard session.collection == source,
                  session.nativeState == .archived,
                  plan.nativeMutation == nil,
                  plan.trashMembershipMutation != nil else {
                throw SessionManagerError.invalidTransition(
                    session.nativeID,
                    session.collection,
                    operation
                )
            }
            if operation == .moveToTrash,
               session.protection.blocksLifecycleMutation {
                throw SessionManagerError.protectedSession(
                    session.nativeID,
                    session.protection.labels
                )
            }
        }

        guard try store.providerCheckpoint(for: .codex) == checkpoint else {
            throw PersistentStateError.invalidRecord(
                "The authoritative checkpoint changed before Preview persistence."
            )
        }

        let createdAt = PersistentTimestamp.canonical(now())
        let expiresAt = PersistentTimestamp.canonical(
            createdAt.addingTimeInterval(lifetime)
        )
        guard lifetime > 0 else {
            throw PersistentStateError.invalidRecord(
                "Manager-only Preview lifetime must be positive."
            )
        }
        let tokenPrefix = operation == .moveToTrash
            ? "MOVE-TO-TRASH"
            : "MOVE-TO-ARCHIVE"
        let confirmationToken = "\(tokenPrefix)-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let persistentItems = try ordered.map { session in
            PersistentPreviewItem(
                managerKey: session.id,
                nativeSessionID: session.nativeID,
                expectedNativeState: .archived,
                expectedProtectionHash: try ArchiveExecutionHasher.protectionHash(for: session),
                expectedTitle: session.title,
                expectedProjectID: session.project?.id,
                expectedWorkingDirectory: session.workingDirectory,
                knownSizeBytes: session.sizeBytes
            )
        }
        let persistentOperation = PersistentOperation(operation)
        let persistentPreview = PersistentOperationPreview(
            id: makePreviewID(),
            provider: .codex,
            operation: persistentOperation,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            ),
            manifestHash: try ManagerOnlyOperationHasher.manifestHash(
                operation: persistentOperation,
                providerInventoryHash: checkpoint.inventoryHash,
                runtimeVersion: runtimeVersion,
                createdAt: createdAt,
                expiresAt: expiresAt,
                items: persistentItems
            ),
            providerInventoryHash: checkpoint.inventoryHash,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: persistentItems
        )
        try store.saveOperationPreview(persistentPreview, checkpoint: checkpoint)
        guard try store.operationPreview(id: persistentPreview.id) == persistentPreview else {
            throw PersistentStateError.invalidRecord(
                "Persisted manager-only Preview differs from its frozen input."
            )
        }

        return OperationPreview(
            id: persistentPreview.id,
            provider: .codex,
            operation: operation,
            confirmationToken: confirmationToken,
            generatedAt: createdAt,
            items: ordered.map { session in
                OperationPreviewItem(
                    managerKey: session.id,
                    nativeID: session.nativeID,
                    title: session.title,
                    projectID: session.project?.id,
                    projectName: session.project?.name,
                    workingDirectory: session.workingDirectory,
                    beforeCollection: source,
                    targetCollection: operation.targetCollection(from: source),
                    sizeBytes: session.sizeBytes
                )
            },
            warnings: [
                "Manager-only change: Codex remains Archived; no Codex lifecycle request will be sent."
            ]
        )
    }

    public func execute(
        previewID: UUID,
        confirmationToken: String,
        freshSnapshot: ProviderInventorySnapshot
    ) throws -> PersistentOperationReport {
        guard let preview = try store.operationPreview(id: previewID),
              preview.status == .prepared,
              preview.operation == .moveToTrash || preview.operation == .moveToArchive else {
            throw PersistentStateError.invalidRecord(
                "Manager-only execution requires its exact prepared Preview."
            )
        }
        let validatedCheckpoint = freshSnapshot.checkpoint
        guard freshSnapshot.provider == preview.provider,
              freshSnapshot.inventoryComplete,
              freshSnapshot.observedAt >= preview.createdAt,
              try store.providerCheckpoint(for: preview.provider) == validatedCheckpoint else {
            throw PersistentStateError.invalidRecord(
                "Fresh manager-only inventory evidence is incomplete or no longer authoritative."
            )
        }
        let sessionsByKey = Dictionary(
            grouping: freshSnapshot.sessions,
            by: \AgentSession.id
        )
        for item in preview.items {
            guard let matches = sessionsByKey[item.managerKey],
                  matches.count == 1,
                  let session = matches.first,
                  session.system == preview.provider,
                  session.nativeID == item.nativeSessionID,
                  session.nativeState == .archived,
                  session.title == item.expectedTitle,
                  session.project?.id == item.expectedProjectID,
                  session.workingDirectory == item.expectedWorkingDirectory,
                  try ArchiveExecutionHasher.protectionHash(for: session)
                    == item.expectedProtectionHash else {
                throw PersistentStateError.invalidRecord(
                    "The exact selected session drifted after manager-only Preview."
                )
            }
            if preview.operation == .moveToTrash,
               session.protection.blocksLifecycleMutation {
                throw SessionManagerError.protectedSession(
                    session.nativeID,
                    session.protection.labels
                )
            }
        }
        return try store.commitManagerOnlyOperation(
            previewID: previewID,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            ),
            validatedCheckpoint: validatedCheckpoint,
            completedAt: now(),
            reportID: makeReportID()
        )
    }
}

enum ManagerOnlyOperationHasher {
    static func manifestHash(
        operation: PersistentOperation,
        providerInventoryHash: String,
        runtimeVersion: String,
        createdAt: Date,
        expiresAt: Date,
        items: [PersistentPreviewItem]
    ) throws -> String {
        // Manager-only execution has no provider mutation timestamp. Reuse the
        // canonical persisted manifest encoding with the Preview creation time
        // as its stable reconciliation boundary; execute recomputes identically.
        try ArchiveExecutionHasher.manifestHash(
            provider: .codex,
            operation: operation,
            providerInventoryHash: providerInventoryHash,
            runtimeVersion: runtimeVersion,
            reconciliationTimestamp: createdAt,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: items
        )
    }
}
