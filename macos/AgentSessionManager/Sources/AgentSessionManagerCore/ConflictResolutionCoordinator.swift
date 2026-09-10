import CryptoKit
import Foundation

public struct ConflictResolutionExecutionPreview: Identifiable, Equatable, Sendable {
    public let proposal: ConflictResolutionPreview
    public let operationPreview: OperationPreview?

    public var id: String { proposal.id }

    public init(
        proposal: ConflictResolutionPreview,
        operationPreview: OperationPreview?
    ) {
        self.proposal = proposal
        self.operationPreview = operationPreview
    }
}

public struct PreparedExternalDeletionResolution: Equatable, Sendable {
    public let operationPreview: OperationPreview
    public let evidence: ExternalDeletionReadbackEvidence

    public init(
        operationPreview: OperationPreview,
        evidence: ExternalDeletionReadbackEvidence
    ) {
        self.operationPreview = operationPreview
        self.evidence = evidence
    }
}

/// Applies only the manager-owned side of a reconciled conflict. Its readback
/// dependency exposes inventory and exact reads only, so neither resolution
/// path can send a Codex lifecycle request.
public actor ConflictResolutionCoordinator {
    private let store: SQLiteStateStore
    private let externalDeletionReadback: any ExternalDeletionReadback
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
        self.externalDeletionReadback = CodexExternalDeletionReadback()
        self.now = now
        self.makePreviewID = makePreviewID
        self.makeReportID = makeReportID
    }

    init(
        store: SQLiteStateStore,
        externalDeletionReadback: any ExternalDeletionReadback,
        now: @escaping @Sendable () -> Date = { Date() },
        makePreviewID: @escaping @Sendable () -> UUID = { UUID() },
        makeReportID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.externalDeletionReadback = externalDeletionReadback
        self.now = now
        self.makePreviewID = makePreviewID
        self.makeReportID = makeReportID
    }

    public func prepareAcceptNativeRestore(
        state: ReconciledSessionState,
        checkpoint: ProviderCheckpointRecord,
        lifetime: TimeInterval = 10 * 60
    ) throws -> OperationPreview {
        guard checkpoint.provider == .codex, checkpoint.inventoryComplete else {
            throw PersistentStateError.invalidRecord(
                "Accept Native Restore requires a complete Codex inventory checkpoint."
            )
        }
        guard let runtimeVersion = checkpoint.runtimeVersion, !runtimeVersion.isEmpty else {
            throw PersistentStateError.invalidRecord(
                "Accept Native Restore requires a runtime-bound checkpoint."
            )
        }
        guard state.status == .nativeActiveTrashConflict,
              let session = state.liveSession,
              session.system == .codex,
              session.nativeState == .active,
              let membership = state.trashMembership,
              membership.provider == .codex,
              membership.nativeSessionID == session.nativeID,
              membership.managerKey == session.id,
              state.managerKey == session.id else {
            throw PersistentStateError.invalidRecord(
                "Accept Native Restore requires an exact Active plus manager Trash conflict."
            )
        }
        guard lifetime > 0 else {
            throw PersistentStateError.invalidRecord(
                "Conflict resolution Preview lifetime must be positive."
            )
        }
        guard try store.providerCheckpoint(for: .codex) == checkpoint else {
            throw PersistentStateError.invalidRecord(
                "The authoritative checkpoint changed before conflict Preview persistence."
            )
        }
        let storedMemberships = try store.trashMemberships(for: .codex)
        let storedMembership = storedMemberships.first {
            $0.managerKey == membership.managerKey
        }
        guard let storedMembership,
              ConflictResolutionHasher.sameTrashIntent(
                storedMembership,
                membership
              ) else {
            throw PersistentStateError.invalidRecord(
                "The authoritative Trash membership changed before conflict Preview persistence."
            )
        }

        let createdAt = PersistentTimestamp.canonical(now())
        let expiresAt = PersistentTimestamp.canonical(
            createdAt.addingTimeInterval(lifetime)
        )
        let confirmationToken = "ACCEPT-NATIVE-RESTORE-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let item = PersistentPreviewItem(
            managerKey: state.managerKey,
            nativeSessionID: session.nativeID,
            expectedNativeState: .active,
            expectedProtectionHash: try ConflictResolutionHasher.membershipSetHash(
                storedMemberships
            ),
            expectedTitle: session.title,
            expectedProjectID: session.project?.id,
            expectedWorkingDirectory: session.workingDirectory,
            knownSizeBytes: session.sizeBytes
        )
        let persistentPreview = PersistentOperationPreview(
            id: makePreviewID(),
            provider: .codex,
            operation: .restore,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            ),
            manifestHash: try ConflictResolutionHasher.manifestHash(
                operation: .restore,
                providerInventoryHash: checkpoint.inventoryHash,
                runtimeVersion: runtimeVersion,
                createdAt: createdAt,
                expiresAt: expiresAt,
                items: [item]
            ),
            providerInventoryHash: checkpoint.inventoryHash,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: [item]
        )
        try store.saveConflictResolutionPreview(
            persistentPreview,
            checkpoint: checkpoint
        )
        guard try store.operationPreview(id: persistentPreview.id) == persistentPreview else {
            throw PersistentStateError.invalidRecord(
                "Persisted conflict Preview differs from its frozen input."
            )
        }

        return OperationPreview(
            id: persistentPreview.id,
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
                    beforeCollection: .trash,
                    targetCollection: .active,
                    sizeBytes: session.sizeBytes
                )
            ],
            warnings: [
                "Manager-only conflict resolution: remove this app's Trash marker because Codex already reports Active.",
                "No thread/archive, thread/unarchive, or thread/delete request will be sent."
            ]
        )
    }

    public func executeAcceptNativeRestore(
        previewID: UUID,
        confirmationToken: String
    ) throws -> PersistentOperationReport {
        try store.commitAcceptNativeRestore(
            previewID: previewID,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            ),
            completedAt: now(),
            reportID: makeReportID()
        )
    }

    public func prepareAcknowledgeExternalDeletion(
        state: ReconciledSessionState,
        checkpoint: ProviderCheckpointRecord,
        lifetime: TimeInterval = 10 * 60
    ) async throws -> PreparedExternalDeletionResolution {
        guard checkpoint.provider == .codex, checkpoint.inventoryComplete else {
            throw PersistentStateError.invalidRecord(
                "External deletion acknowledgement requires a complete Codex inventory checkpoint."
            )
        }
        guard let runtimeVersion = checkpoint.runtimeVersion,
              CodexAppServerProvider.supportsVerifiedExternalDeletionReadbackContract(
                runtimeVersion
              ) else {
            throw PersistentStateError.invalidRecord(
                "The observed Codex runtime is outside the audited external-deletion readback allow-list."
            )
        }
        guard state.status == .externallyMissing,
              state.liveSession == nil,
              let membership = state.trashMembership,
              membership.provider == .codex,
              membership.managerKey == state.managerKey,
              state.managerKey == "codex:\(membership.nativeSessionID)" else {
            throw PersistentStateError.invalidRecord(
                "External deletion acknowledgement requires one exact Externally Missing Trash membership."
            )
        }
        guard lifetime > 0 else {
            throw PersistentStateError.invalidRecord(
                "Conflict resolution Preview lifetime must be positive."
            )
        }
        guard try store.providerCheckpoint(for: .codex) == checkpoint else {
            throw PersistentStateError.invalidRecord(
                "The authoritative checkpoint changed before conflict Preview persistence."
            )
        }

        let freshInventory = try await externalDeletionReadback.inventorySnapshot()
        try validateExternalDeletionInventory(
            freshInventory,
            frozenCheckpoint: checkpoint,
            membership: membership
        )
        let exact = await externalDeletionReadback.exactReadObservation(
            nativeSessionID: membership.nativeSessionID,
            auditedRuntimeVersion: runtimeVersion
        )
        let evidence = try externalDeletionEvidence(
            from: exact,
            inventory: freshInventory,
            membership: membership,
            runtimeVersion: runtimeVersion
        )

        let storedMemberships = try store.trashMemberships(for: .codex)
        guard let authoritativeMembership = storedMemberships.first(where: {
            $0.managerKey == membership.managerKey
        }),
              ConflictResolutionHasher.sameTrashIntent(
                authoritativeMembership,
                membership
              ) else {
            throw PersistentStateError.invalidRecord(
                "The authoritative Trash membership changed before conflict Preview persistence."
            )
        }
        let createdAt = PersistentTimestamp.canonical(now())
        let expiresAt = PersistentTimestamp.canonical(
            createdAt.addingTimeInterval(lifetime)
        )
        let confirmationToken = "ACK-EXTERNAL-DELETION-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let item = PersistentPreviewItem(
            managerKey: authoritativeMembership.managerKey,
            nativeSessionID: authoritativeMembership.nativeSessionID,
            expectedNativeState: .absent,
            expectedProtectionHash: try ConflictResolutionHasher.membershipSetHash(
                storedMemberships
            ),
            expectedTitle: authoritativeMembership.titleAtEntry,
            expectedProjectID: authoritativeMembership.projectIDAtEntry,
            expectedWorkingDirectory: authoritativeMembership.workingDirectoryAtEntry
        )
        let persistentPreview = PersistentOperationPreview(
            id: makePreviewID(),
            provider: .codex,
            operation: .permanentlyDelete,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            ),
            manifestHash: try ConflictResolutionHasher.manifestHash(
                operation: .permanentlyDelete,
                providerInventoryHash: checkpoint.inventoryHash,
                runtimeVersion: runtimeVersion,
                createdAt: createdAt,
                expiresAt: expiresAt,
                items: [item]
            ),
            providerInventoryHash: checkpoint.inventoryHash,
            trashMembershipMutation: .remove,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: [item]
        )
        try store.saveConflictResolutionPreview(
            persistentPreview,
            checkpoint: checkpoint
        )
        guard try store.operationPreview(id: persistentPreview.id) == persistentPreview else {
            throw PersistentStateError.invalidRecord(
                "Persisted conflict Preview differs from its frozen input."
            )
        }

        return PreparedExternalDeletionResolution(
            operationPreview: OperationPreview(
                id: persistentPreview.id,
                provider: .codex,
                operation: .emptyTrash,
                confirmationToken: confirmationToken,
                generatedAt: createdAt,
                items: [
                    OperationPreviewItem(
                        managerKey: authoritativeMembership.managerKey,
                        nativeID: authoritativeMembership.nativeSessionID,
                        title: authoritativeMembership.titleAtEntry,
                        projectID: authoritativeMembership.projectIDAtEntry,
                        projectName: nil,
                        workingDirectory: authoritativeMembership.workingDirectoryAtEntry ?? "",
                        beforeCollection: .trash,
                        targetCollection: .deleted,
                        sizeBytes: nil
                    )
                ],
                warnings: [
                    "Readback-only conflict resolution: Codex already reports this exact task absent.",
                    "No thread/archive, thread/unarchive, or thread/delete request will be sent."
                ]
            ),
            evidence: evidence
        )
    }

    public func executeAcknowledgeExternalDeletion(
        previewID: UUID,
        confirmationToken: String
    ) async throws -> PersistentOperationReport {
        guard let preview = try store.operationPreview(id: previewID),
              preview.status == .prepared,
              preview.provider == .codex,
              preview.operation == .permanentlyDelete,
              preview.trashMembershipMutation == .remove,
              preview.items.count == 1,
              let item = preview.items.first,
              item.expectedNativeState == .absent,
              let runtimeVersion = try store.providerCheckpoint(for: .codex)?.runtimeVersion,
              CodexAppServerProvider.supportsVerifiedExternalDeletionReadbackContract(
                runtimeVersion
              ) else {
            throw PersistentStateError.invalidRecord(
                "Preview is not a prepared external-deletion acknowledgement."
            )
        }
        let startedAt = PersistentTimestamp.canonical(now())
        guard preview.expiresAt > startedAt else {
            throw PersistentStateError.invalidRecord(
                "Conflict resolution Preview expired before confirmation."
            )
        }
        guard preview.confirmationTokenHash
                == ArchiveExecutionHasher.confirmationTokenHash(confirmationToken) else {
            throw PersistentStateError.confirmationMismatch
        }
        let membership = TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: item.nativeSessionID,
            managerKey: item.managerKey,
            titleAtEntry: item.expectedTitle,
            projectIDAtEntry: item.expectedProjectID,
            workingDirectoryAtEntry: item.expectedWorkingDirectory,
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: preview.providerInventoryHash,
            enteredAt: preview.createdAt,
            lastReconciledAt: preview.createdAt
        )
        let freshInventory = try await externalDeletionReadback.inventorySnapshot()
        try validateExternalDeletionInventory(
            freshInventory,
            frozenCheckpoint: ProviderCheckpointRecord(
                provider: .codex,
                runtimeVersion: runtimeVersion,
                inventoryHash: preview.providerInventoryHash,
                refreshedAt: preview.createdAt,
                inventoryComplete: true,
                protectionComplete: false
            ),
            membership: membership,
            requireTimestampOrdering: false
        )
        let exact = await externalDeletionReadback.exactReadObservation(
            nativeSessionID: item.nativeSessionID,
            auditedRuntimeVersion: runtimeVersion
        )
        let evidence = try externalDeletionEvidence(
            from: exact,
            inventory: freshInventory,
            membership: membership,
            runtimeVersion: runtimeVersion
        )
        return try store.commitAcknowledgeExternalDeletion(
            previewID: previewID,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            ),
            startedAt: startedAt,
            completedAt: evidence.exactReadObservedAt,
            observedInventoryHash: evidence.inventoryHash,
            reportID: makeReportID()
        )
    }

    private func validateExternalDeletionInventory(
        _ inventory: ProviderInventorySnapshot,
        frozenCheckpoint: ProviderCheckpointRecord,
        membership: TrashMembershipRecord,
        requireTimestampOrdering: Bool = true
    ) throws {
        guard inventory.provider == .codex,
              inventory.inventoryComplete,
              inventory.runtimeVersion == frozenCheckpoint.runtimeVersion,
              (!requireTimestampOrdering
                  || inventory.observedAt >= frozenCheckpoint.refreshedAt) else {
            throw PersistentStateError.invalidRecord(
                "Fresh complete inventory drifted from the frozen conflict evidence."
            )
        }
        guard !inventory.sessions.contains(where: {
            $0.id == membership.managerKey || $0.nativeID == membership.nativeSessionID
        }) else {
            throw PersistentStateError.invalidRecord(
                "The exact task exists in the fresh provider inventory."
            )
        }
    }

    private func externalDeletionEvidence(
        from observation: ExternalDeletionExactObservation,
        inventory: ProviderInventorySnapshot,
        membership: TrashMembershipRecord,
        runtimeVersion: String
    ) throws -> ExternalDeletionReadbackEvidence {
        guard case let .absent(nativeSessionID, observedAt, observedRuntime, rpcCode, message)
                = observation,
              nativeSessionID == membership.nativeSessionID,
              observedRuntime == runtimeVersion,
              observedAt >= inventory.observedAt else {
            throw PersistentStateError.invalidRecord(
                "Exact-ID readback did not prove absence after the fresh complete inventory."
            )
        }
        let evidence = ExternalDeletionReadbackEvidence(
            provider: .codex,
            nativeSessionID: nativeSessionID,
            runtimeVersion: observedRuntime,
            inventoryHash: inventory.inventoryHash,
            inventoryObservedAt: inventory.observedAt,
            exactReadObservedAt: observedAt,
            rpcCode: rpcCode,
            message: message
        )
        guard evidence.provesAbsence else {
            throw PersistentStateError.invalidRecord(
                "External-deletion evidence did not satisfy the audited dual-readback contract."
            )
        }
        return evidence
    }
}

enum ConflictResolutionHasher {
    /// Normal reconciliation advances only `lastReconciledAt`; that timestamp
    /// is observation metadata, not user Trash intent or selection authority.
    static func sameTrashIntent(
        _ lhs: TrashMembershipRecord,
        _ rhs: TrashMembershipRecord
    ) -> Bool {
        lhs.provider == rhs.provider
            && lhs.nativeSessionID == rhs.nativeSessionID
            && lhs.managerKey == rhs.managerKey
            && lhs.titleAtEntry == rhs.titleAtEntry
            && lhs.projectIDAtEntry == rhs.projectIDAtEntry
            && lhs.workingDirectoryAtEntry == rhs.workingDirectoryAtEntry
            && lhs.nativeStateAtEntry == rhs.nativeStateAtEntry
            && lhs.providerInventoryHashAtEntry == rhs.providerInventoryHashAtEntry
            && lhs.enteredAt == rhs.enteredAt
    }

    static func manifestHash(
        operation: PersistentOperation,
        providerInventoryHash: String,
        runtimeVersion: String,
        createdAt: Date,
        expiresAt: Date,
        items: [PersistentPreviewItem]
    ) throws -> String {
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

    static func membershipSetHash(
        _ memberships: [TrashMembershipRecord]
    ) throws -> String {
        let payload = memberships
            .sorted { $0.managerKey < $1.managerKey }
            .map {
                FrozenTrashMembership(
                    provider: $0.provider,
                    nativeSessionID: $0.nativeSessionID,
                    managerKey: $0.managerKey,
                    titleAtEntry: $0.titleAtEntry,
                    projectIDAtEntry: $0.projectIDAtEntry,
                    workingDirectoryAtEntry: $0.workingDirectoryAtEntry,
                    nativeStateAtEntry: $0.nativeStateAtEntry,
                    providerInventoryHashAtEntry: $0.providerInventoryHashAtEntry,
                    enteredAt: $0.enteredAt
                )
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct FrozenTrashMembership: Encodable {
    let provider: AgentSystem
    let nativeSessionID: String
    let managerKey: String
    let titleAtEntry: String
    let projectIDAtEntry: String?
    let workingDirectoryAtEntry: String?
    let nativeStateAtEntry: NativeSessionState
    let providerInventoryHashAtEntry: String
    let enteredAt: Date
}
