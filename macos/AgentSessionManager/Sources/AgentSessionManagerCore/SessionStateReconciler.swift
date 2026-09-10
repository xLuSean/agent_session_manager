import Foundation

public struct ProviderInventorySnapshot: Equatable, Sendable {
    public let provider: AgentSystem
    public let runtimeVersion: String?
    public let compatibilityBinding: CodexCompatibilityBinding?
    public let inventoryHash: String
    public let observedAt: Date
    public let inventoryComplete: Bool
    public let protectionComplete: Bool
    public let sessions: [AgentSession]
    public let archiveScopeNodes: [ArchiveScopeNode]
    public let archiveScopeComplete: Bool
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        provider: AgentSystem,
        runtimeVersion: String? = nil,
        compatibilityBinding: CodexCompatibilityBinding? = nil,
        inventoryHash: String,
        observedAt: Date,
        inventoryComplete: Bool,
        protectionComplete: Bool,
        sessions: [AgentSession],
        archiveScopeNodes: [ArchiveScopeNode] = [],
        archiveScopeComplete: Bool = false,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.provider = provider
        self.runtimeVersion = runtimeVersion
        self.compatibilityBinding = compatibilityBinding
        self.inventoryHash = inventoryHash
        self.observedAt = observedAt
        self.inventoryComplete = inventoryComplete
        self.protectionComplete = protectionComplete
        self.sessions = sessions
        self.archiveScopeNodes = archiveScopeNodes
        self.archiveScopeComplete = archiveScopeComplete
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    public var checkpoint: ProviderCheckpointRecord {
        ProviderCheckpointRecord(
            provider: provider,
            runtimeVersion: runtimeVersion,
            compatibilityBinding: compatibilityBinding,
            inventoryHash: inventoryHash,
            refreshedAt: observedAt,
            inventoryComplete: inventoryComplete,
            protectionComplete: protectionComplete,
            lastErrorCode: errorCode,
            lastErrorMessage: errorMessage
        )
    }
}

public enum ReconciliationStatus: String, Codable, Sendable {
    case active
    case archive
    case trash
    case nativeActiveTrashConflict
    case externallyMissing
    case unavailable

    public var isConflict: Bool {
        self == .nativeActiveTrashConflict || self == .externallyMissing
    }
}

public struct ReconciledSessionState: Equatable, Sendable {
    public let managerKey: String
    public let liveSession: AgentSession?
    public let trashMembership: TrashMembershipRecord?
    public let status: ReconciliationStatus
    public let isStableForLifecyclePreview: Bool

    public init(
        managerKey: String,
        liveSession: AgentSession?,
        trashMembership: TrashMembershipRecord?,
        status: ReconciliationStatus,
        isStableForLifecyclePreview: Bool
    ) {
        self.managerKey = managerKey
        self.liveSession = liveSession
        self.trashMembership = trashMembership
        self.status = status
        self.isStableForLifecyclePreview = isStableForLifecyclePreview
    }
}

public struct ReconciliationResult: Equatable, Sendable {
    public let checkpoint: ProviderCheckpointRecord
    public let entries: [ReconciledSessionState]

    public init(checkpoint: ProviderCheckpointRecord, entries: [ReconciledSessionState]) {
        self.checkpoint = checkpoint
        self.entries = entries
    }
}

/// Pure, read-only state reconciliation. It never writes SQLite and never calls
/// a provider lifecycle method.
public enum SessionStateReconciler {
    public static func reconcile(
        snapshot: ProviderInventorySnapshot,
        trashMemberships: [TrashMembershipRecord]
    ) throws -> ReconciliationResult {
        var sessionsByKey: [String: AgentSession] = [:]
        for var session in snapshot.sessions {
            guard session.system == snapshot.provider else {
                throw PersistentStateError.providerMismatch(
                    expected: snapshot.provider,
                    found: session.system
                )
            }
            guard sessionsByKey[session.id] == nil else {
                throw PersistentStateError.duplicateManagerKey(session.id)
            }
            // Provider inventory must not decide manager Trash intent.
            session.isTrashMember = false
            sessionsByKey[session.id] = session
        }

        var membershipsByKey: [String: TrashMembershipRecord] = [:]
        for membership in trashMemberships {
            guard membership.provider == snapshot.provider else {
                throw PersistentStateError.providerMismatch(
                    expected: snapshot.provider,
                    found: membership.provider
                )
            }
            let expectedKey = "\(membership.provider.rawValue):\(membership.nativeSessionID)"
            guard membership.managerKey == expectedKey else {
                throw PersistentStateError.invalidRecord(
                    "Trash membership manager key does not match provider and native ID."
                )
            }
            guard membershipsByKey[membership.managerKey] == nil else {
                throw PersistentStateError.duplicateManagerKey(membership.managerKey)
            }
            membershipsByKey[membership.managerKey] = membership
        }

        let allKeys = Set(sessionsByKey.keys).union(membershipsByKey.keys)
        let entries = allKeys.sorted().map { managerKey -> ReconciledSessionState in
            var session = sessionsByKey[managerKey]
            let membership = membershipsByKey[managerKey]
            if membership != nil { session?.isTrashMember = true }

            let status: ReconciliationStatus
            switch (session?.nativeState, membership != nil) {
            case (.active?, false):
                status = .active
            case (.archived?, false):
                status = .archive
            case (.archived?, true):
                status = .trash
            case (.active?, true):
                status = .nativeActiveTrashConflict
            case (.absent?, _):
                status = .externallyMissing
            case (.unavailable?, _):
                status = .unavailable
            case (nil, true):
                status = snapshot.inventoryComplete ? .externallyMissing : .unavailable
            case (nil, false):
                status = .unavailable
            }

            let isNormalState = status == .active || status == .archive || status == .trash
            let protectionAllowsPreview = session.map { !$0.protection.blocksLifecycleMutation } ?? false
            let stable = snapshot.inventoryComplete
                && snapshot.protectionComplete
                && isNormalState
                && protectionAllowsPreview

            return ReconciledSessionState(
                managerKey: managerKey,
                liveSession: session,
                trashMembership: membership,
                status: status,
                isStableForLifecyclePreview: stable
            )
        }

        return ReconciliationResult(checkpoint: snapshot.checkpoint, entries: entries)
    }
}
