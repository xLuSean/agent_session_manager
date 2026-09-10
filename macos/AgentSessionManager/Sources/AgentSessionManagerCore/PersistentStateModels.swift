import Foundation

/// SQLite stores ISO-8601 timestamps at millisecond precision. Values that
/// participate in frozen manifests must use the same precision before hashing
/// and equality readback, otherwise a normal `Date()` loses sub-millisecond
/// data during persistence and appears to drift.
enum PersistentTimestamp {
    static func canonical(_ date: Date) -> Date {
        Date(
            timeIntervalSince1970:
                (date.timeIntervalSince1970 * 1_000).rounded() / 1_000
        )
    }
}

public enum PersistentStateError: Error, Equatable, LocalizedError {
    case invalidRecord(String)
    case duplicateManagerKey(String)
    case providerMismatch(expected: AgentSystem, found: AgentSystem)
    case recordNotFound(String)
    case previewItemSetMismatch
    case confirmationMismatch

    public var errorDescription: String? {
        switch self {
        case let .invalidRecord(message):
            "Invalid persistent state record: \(message)"
        case let .duplicateManagerKey(managerKey):
            "Duplicate manager key: \(managerKey)"
        case let .providerMismatch(expected, found):
            "Provider mismatch: expected \(expected.rawValue), found \(found.rawValue)."
        case let .recordNotFound(identifier):
            "Persistent state record not found: \(identifier)"
        case .previewItemSetMismatch:
            "Report items do not exactly match the frozen Preview item set."
        case .confirmationMismatch:
            "Confirmation does not match the persisted Preview."
        }
    }
}

public struct ProviderCheckpointRecord: Codable, Equatable, Sendable {
    public let provider: AgentSystem
    public let runtimeVersion: String?
    public let compatibilityBinding: CodexCompatibilityBinding?
    public let inventoryHash: String
    public let refreshedAt: Date
    public let inventoryComplete: Bool
    public let protectionComplete: Bool
    public let lastErrorCode: String?
    public let lastErrorMessage: String?

    public init(
        provider: AgentSystem,
        runtimeVersion: String? = nil,
        compatibilityBinding: CodexCompatibilityBinding? = nil,
        inventoryHash: String,
        refreshedAt: Date,
        inventoryComplete: Bool,
        protectionComplete: Bool,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.provider = provider
        self.runtimeVersion = runtimeVersion
        self.compatibilityBinding = compatibilityBinding
        self.inventoryHash = inventoryHash
        self.refreshedAt = PersistentTimestamp.canonical(refreshedAt)
        self.inventoryComplete = inventoryComplete
        self.protectionComplete = protectionComplete
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
    }
}

public struct TrashMembershipRecord: Codable, Equatable, Sendable {
    public let provider: AgentSystem
    public let nativeSessionID: String
    public let managerKey: String
    public let titleAtEntry: String
    public let projectIDAtEntry: String?
    public let workingDirectoryAtEntry: String?
    public let nativeStateAtEntry: NativeSessionState
    public let providerInventoryHashAtEntry: String
    public let enteredAt: Date
    public let lastReconciledAt: Date

    public init(
        provider: AgentSystem,
        nativeSessionID: String,
        managerKey: String,
        titleAtEntry: String,
        projectIDAtEntry: String? = nil,
        workingDirectoryAtEntry: String? = nil,
        nativeStateAtEntry: NativeSessionState,
        providerInventoryHashAtEntry: String,
        enteredAt: Date,
        lastReconciledAt: Date
    ) {
        self.provider = provider
        self.nativeSessionID = nativeSessionID
        self.managerKey = managerKey
        self.titleAtEntry = titleAtEntry
        self.projectIDAtEntry = projectIDAtEntry
        self.workingDirectoryAtEntry = workingDirectoryAtEntry
        self.nativeStateAtEntry = nativeStateAtEntry
        self.providerInventoryHashAtEntry = providerInventoryHashAtEntry
        self.enteredAt = enteredAt
        self.lastReconciledAt = lastReconciledAt
    }
}

/// Durable manager tombstone created only after the native provider is
/// authoritatively read back as absent. It is independent from operation
/// history so clearing Reports never erases the Deleted collection.
public struct DeletedSessionRecord: Codable, Equatable, Sendable {
    public let provider: AgentSystem
    public let nativeSessionID: String
    public let managerKey: String
    public let titleAtDeletion: String
    public let projectIDAtDeletion: String?
    public let workingDirectoryAtDeletion: String?
    public let knownSizeBytes: Int64?
    public let providerInventoryHashAtDeletion: String
    public let deletedAt: Date
    public let deleteReportID: UUID?

    public init(
        provider: AgentSystem,
        nativeSessionID: String,
        managerKey: String,
        titleAtDeletion: String,
        projectIDAtDeletion: String? = nil,
        workingDirectoryAtDeletion: String? = nil,
        knownSizeBytes: Int64? = nil,
        providerInventoryHashAtDeletion: String,
        deletedAt: Date,
        deleteReportID: UUID? = nil
    ) {
        self.provider = provider
        self.nativeSessionID = nativeSessionID
        self.managerKey = managerKey
        self.titleAtDeletion = titleAtDeletion
        self.projectIDAtDeletion = projectIDAtDeletion
        self.workingDirectoryAtDeletion = workingDirectoryAtDeletion
        self.knownSizeBytes = knownSizeBytes
        self.providerInventoryHashAtDeletion = providerInventoryHashAtDeletion
        self.deletedAt = deletedAt
        self.deleteReportID = deleteReportID
    }
}

/// Persistent manager intent. `moveToArchive` remains distinct from `archive`
/// even though both have the same native archived state.
public enum PersistentOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case archive
    case moveToTrash = "move_to_trash"
    case restore
    case moveToArchive = "move_to_archive"
    case permanentlyDelete = "permanently_delete"

    public init(_ operation: SessionOperation) {
        switch operation {
        case .archive:
            self = .archive
        case .moveToTrash:
            self = .moveToTrash
        case .restore:
            self = .restore
        case .moveToArchive:
            self = .moveToArchive
        case .emptyTrash:
            self = .permanentlyDelete
        }
    }

    /// Schema v1-v3 stored the native lifecycle primitive in `operation`.
    /// V4 adds `manager_intent` while retaining this compatible column.
    var legacyOperationRawValue: String {
        self == .moveToArchive ? PersistentOperation.archive.rawValue : rawValue
    }

    /// Only Archived -> Trash adds a destructive manager intent without an
    /// operation-specific native coordinator, so it retains the aggregate
    /// protection requirement. Archive/Delete validate exact protection in
    /// their own coordinators; Restore and Trash -> Archive move away from a
    /// dangerous state and need only a complete inventory checkpoint.
    var requiresCompleteProtectionCheckpoint: Bool {
        self == .moveToTrash
    }
}

public enum PersistentPreviewStatus: String, Codable, Sendable {
    case prepared
    case executing
    case consumed
    case expired
    case cancelled
}

public struct PersistentPreviewItem: Codable, Equatable, Sendable {
    public let managerKey: String
    public let nativeSessionID: String
    public let expectedNativeState: NativeSessionState
    public let expectedProtectionHash: String
    public let expectedTitle: String
    public let expectedProjectID: String?
    public let expectedWorkingDirectory: String?
    public let knownSizeBytes: Int64?
    public let archiveAffectedRole: ArchiveAffectedRole?
    public let parentNativeSessionID: String?
    public let archiveAffectedDepth: Int?

    public init(
        managerKey: String,
        nativeSessionID: String,
        expectedNativeState: NativeSessionState,
        expectedProtectionHash: String,
        expectedTitle: String,
        expectedProjectID: String? = nil,
        expectedWorkingDirectory: String? = nil,
        knownSizeBytes: Int64? = nil,
        archiveAffectedRole: ArchiveAffectedRole? = nil,
        parentNativeSessionID: String? = nil,
        archiveAffectedDepth: Int? = nil
    ) {
        self.managerKey = managerKey
        self.nativeSessionID = nativeSessionID
        self.expectedNativeState = expectedNativeState
        self.expectedProtectionHash = expectedProtectionHash
        self.expectedTitle = expectedTitle
        self.expectedProjectID = expectedProjectID
        self.expectedWorkingDirectory = expectedWorkingDirectory
        self.knownSizeBytes = knownSizeBytes
        self.archiveAffectedRole = archiveAffectedRole
        self.parentNativeSessionID = parentNativeSessionID
        self.archiveAffectedDepth = archiveAffectedDepth
    }
}

public struct PersistentOperationPreview: Codable, Equatable, Sendable {
    public let id: UUID
    public let provider: AgentSystem
    public let operation: PersistentOperation
    public let status: PersistentPreviewStatus
    public let confirmationTokenHash: String
    public let manifestHash: String
    public let providerInventoryHash: String
    public let affectedSetHash: String?
    /// Manager-owned effect committed only after successful native readback.
    /// `nil` preserves schema v1-v4 Preview semantics.
    public let trashMembershipMutation: TrashMembershipMutation?
    /// Frozen hash of the complete manager Trash membership set when a native
    /// Archive is reapplying an already-existing Trash intent. This is not a
    /// mutation instruction: claim and Report persistence must prove the exact
    /// manager-owned intent remains unchanged.
    public let expectedTrashMembershipSetHash: String?
    public let createdAt: Date
    public let expiresAt: Date
    public let items: [PersistentPreviewItem]

    public init(
        id: UUID,
        provider: AgentSystem,
        operation: PersistentOperation,
        status: PersistentPreviewStatus = .prepared,
        confirmationTokenHash: String,
        manifestHash: String,
        providerInventoryHash: String,
        affectedSetHash: String? = nil,
        trashMembershipMutation: TrashMembershipMutation? = nil,
        expectedTrashMembershipSetHash: String? = nil,
        createdAt: Date,
        expiresAt: Date,
        items: [PersistentPreviewItem]
    ) {
        self.id = id
        self.provider = provider
        self.operation = operation
        self.status = status
        self.confirmationTokenHash = confirmationTokenHash
        self.manifestHash = manifestHash
        self.providerInventoryHash = providerInventoryHash
        self.affectedSetHash = affectedSetHash
        self.trashMembershipMutation = trashMembershipMutation
        self.expectedTrashMembershipSetHash = expectedTrashMembershipSetHash
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.items = items
    }

    public var knownSizeBytes: Int64 {
        items.compactMap(\.knownSizeBytes).reduce(0, +)
    }

    public var unknownSizeCount: Int {
        items.filter { $0.knownSizeBytes == nil }.count
    }

    /// Active -> Trash uses the same audited native Archive protection gate as
    /// plain Archive. Archived -> Trash remains manager-only and conservative.
    var requiresCompleteProtectionCheckpoint: Bool {
        if operation == .moveToTrash,
           trashMembershipMutation == .add,
           items.allSatisfy({ $0.expectedNativeState == .active }) {
            return false
        }
        return operation.requiresCompleteProtectionCheckpoint
    }
}

public enum PersistentReportOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case warning
    case failure
    case partial
    case unknown
}

public enum PersistentItemOutcome: String, Codable, Sendable {
    case success
    case failure
    case unknown
}

public struct PersistentReportItem: Codable, Equatable, Sendable {
    public let managerKey: String
    public let outcome: PersistentItemOutcome
    public let observedNativeState: NativeSessionState
    public let verifiedReleasedBytes: Int64?
    public let evidenceAt: Date
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        managerKey: String,
        outcome: PersistentItemOutcome,
        observedNativeState: NativeSessionState,
        verifiedReleasedBytes: Int64? = nil,
        evidenceAt: Date,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.managerKey = managerKey
        self.outcome = outcome
        self.observedNativeState = observedNativeState
        self.verifiedReleasedBytes = verifiedReleasedBytes
        self.evidenceAt = evidenceAt
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public struct PersistentOperationReport: Codable, Equatable, Sendable {
    public let id: UUID
    public let previewID: UUID
    public let provider: AgentSystem
    public let operation: PersistentOperation
    public let outcome: PersistentReportOutcome
    public let startedAt: Date
    public let completedAt: Date
    public let releasedBytesComplete: Bool
    public let errorCode: String?
    public let errorMessage: String?
    public let items: [PersistentReportItem]

    public init(
        id: UUID,
        previewID: UUID,
        provider: AgentSystem,
        operation: PersistentOperation,
        outcome: PersistentReportOutcome,
        startedAt: Date,
        completedAt: Date,
        releasedBytesComplete: Bool,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        items: [PersistentReportItem]
    ) {
        self.id = id
        self.previewID = previewID
        self.provider = provider
        self.operation = operation
        self.outcome = outcome
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.releasedBytesComplete = releasedBytesComplete
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.items = items
    }

    public var successCount: Int { items.filter { $0.outcome == .success }.count }
    public var failureCount: Int { items.filter { $0.outcome == .failure }.count }
    public var unknownCount: Int { items.filter { $0.outcome == .unknown }.count }
    public var verifiedReleasedBytes: Int64 {
        items.compactMap(\.verifiedReleasedBytes).reduce(0, +)
    }
}

public struct OperationHistoryRetentionPolicy: Codable, Equatable, Sendable {
    public static let production = OperationHistoryRetentionPolicy(
        maximumReportsPerProvider: 500
    )

    public let maximumReportsPerProvider: Int

    public init(maximumReportsPerProvider: Int) {
        self.maximumReportsPerProvider = maximumReportsPerProvider
    }
}

public struct OperationHistoryPruneResult: Equatable, Sendable {
    public let provider: AgentSystem
    public let retainedReportCount: Int
    public let deletedReportIDs: [UUID]
    public let deletedPreviewIDs: [UUID]
    public let deletedItemCount: Int

    public init(
        provider: AgentSystem,
        retainedReportCount: Int,
        deletedReportIDs: [UUID],
        deletedPreviewIDs: [UUID],
        deletedItemCount: Int
    ) {
        self.provider = provider
        self.retainedReportCount = retainedReportCount
        self.deletedReportIDs = deletedReportIDs
        self.deletedPreviewIDs = deletedPreviewIDs
        self.deletedItemCount = deletedItemCount
    }
}

public struct OperationHistoryClearResult: Equatable, Sendable {
    public let provider: AgentSystem?
    public let deletedReportIDs: [UUID]
    public let deletedPreviewIDs: [UUID]
    public let deletedItemCount: Int

    public init(
        provider: AgentSystem?,
        deletedReportIDs: [UUID],
        deletedPreviewIDs: [UUID],
        deletedItemCount: Int
    ) {
        self.provider = provider
        self.deletedReportIDs = deletedReportIDs
        self.deletedPreviewIDs = deletedPreviewIDs
        self.deletedItemCount = deletedItemCount
    }
}
