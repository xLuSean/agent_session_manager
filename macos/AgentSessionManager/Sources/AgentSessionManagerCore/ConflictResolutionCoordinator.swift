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

/// Applies only the manager-owned side of a reconciled conflict. This type has
/// no provider or transport dependency, so accepting a native restore cannot
/// send a Codex lifecycle request.
public actor ConflictResolutionCoordinator {
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
        guard storedMembership == membership else {
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
}

enum ConflictResolutionHasher {
    static func manifestHash(
        providerInventoryHash: String,
        runtimeVersion: String,
        createdAt: Date,
        expiresAt: Date,
        items: [PersistentPreviewItem]
    ) throws -> String {
        try ArchiveExecutionHasher.manifestHash(
            provider: .codex,
            operation: .restore,
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
