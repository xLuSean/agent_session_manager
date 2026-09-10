import Foundation

public enum AgentSystem: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case codex
    case claudeCode

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

public enum NativeSessionState: String, Codable, Hashable, Sendable {
    case active
    case archived
    case absent
    case unavailable
}

public enum SessionCollection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case active
    case archive
    case trash
    case deleted
    case unavailable

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .active: "Active"
        case .archive: "Archive"
        case .trash: "Trash Bin"
        case .deleted: "Deleted"
        case .unavailable: "Unavailable"
        }
    }

    public var symbol: String {
        switch self {
        case .active: "bubble.left.and.bubble.right"
        case .archive: "archivebox"
        case .trash: "trash"
        case .deleted: "xmark.bin"
        case .unavailable: "questionmark.folder"
        }
    }
}

public enum CollectionFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case active
    case archive
    case trash
    case pinned
    case deleted

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All Sessions"
        case .active: "Active"
        case .archive: "Archive"
        case .trash: "Trash Bin"
        case .pinned: "Pinned"
        case .deleted: "Deleted"
        }
    }

    public var symbol: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .active: "bubble.left.and.bubble.right"
        case .archive: "archivebox"
        case .trash: "trash"
        case .pinned: "pin"
        case .deleted: "xmark.bin"
        }
    }
}

public struct SessionProtection: Codable, Hashable, Sendable {
    public var isPinned: Bool
    public var isRunning: Bool
    public var isCurrent: Bool
    public var hasPinnedDescendant: Bool
    public var isPinnedKnown: Bool
    public var isRunningKnown: Bool
    public var isCurrentKnown: Bool
    public var hasPinnedDescendantKnown: Bool

    public init(
        isPinned: Bool = false,
        isRunning: Bool = false,
        isCurrent: Bool = false,
        hasPinnedDescendant: Bool = false,
        isPinnedKnown: Bool = true,
        isRunningKnown: Bool = true,
        isCurrentKnown: Bool = true,
        hasPinnedDescendantKnown: Bool = true
    ) {
        self.isPinned = isPinned
        self.isRunning = isRunning
        self.isCurrent = isCurrent
        self.hasPinnedDescendant = hasPinnedDescendant
        self.isPinnedKnown = isPinnedKnown
        self.isRunningKnown = isRunningKnown
        self.isCurrentKnown = isCurrentKnown
        self.hasPinnedDescendantKnown = hasPinnedDescendantKnown
    }

    public var blocksLifecycleMutation: Bool {
        isPinned || isRunning || isCurrent || hasPinnedDescendant || hasUnavailableState
    }

    /// Protection evidence that must stop an official Archive request before
    /// it reaches the provider. Unknown running/current state is intentionally
    /// absent: Codex may reject that bounded request as busy, after which the
    /// caller must read back once and must not retry blindly.
    public var archiveAttemptBlockingLabels: [String] {
        var values: [String] = []
        if isPinned { values.append("Pinned") }
        if isRunning { values.append("Running") }
        if isCurrent { values.append("Current") }
        if hasPinnedDescendant { values.append("Pinned descendant") }
        if !isPinnedKnown { values.append("Pin state unavailable") }
        if !hasPinnedDescendantKnown { values.append("Pinned descendant state unavailable") }
        return values
    }

    public var blocksArchiveAttempt: Bool {
        !archiveAttemptBlockingLabels.isEmpty
    }

    public var archiveAttemptMayFail: Bool {
        !isRunningKnown || !isCurrentKnown
    }

    /// Permanent Delete uses the same positive protection boundary as the
    /// audited Archive attempt: pinned roots, known running/current roots,
    /// pinned descendants, and unavailable pin/descendant evidence block.
    /// Cross-host running/current evidence may remain unavailable; that is a
    /// disclosed one-shot failure risk rather than proof that the target is
    /// protected.
    public var deleteAttemptBlockingLabels: [String] {
        archiveAttemptBlockingLabels
    }

    public var blocksDeleteAttempt: Bool {
        !deleteAttemptBlockingLabels.isEmpty
    }

    public var deleteAttemptMayFail: Bool {
        !isRunningKnown || !isCurrentKnown
    }

    public var hasUnavailableState: Bool {
        !isPinnedKnown || !isRunningKnown || !isCurrentKnown || !hasPinnedDescendantKnown
    }

    public var labels: [String] {
        var values: [String] = []
        if isPinned { values.append("Pinned") }
        if isRunning { values.append("Running") }
        if isCurrent { values.append("Current") }
        if hasPinnedDescendant { values.append("Pinned descendant") }
        if !isPinnedKnown { values.append("Pin state unavailable") }
        if !isRunningKnown { values.append("Running state unavailable") }
        if !isCurrentKnown { values.append("Current state unavailable") }
        if !hasPinnedDescendantKnown { values.append("Pinned descendant state unavailable") }
        return values
    }
}

public struct SessionProject: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let rootPath: String

    public init(id: String, name: String, rootPath: String) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
    }
}

public enum FolderTrustState: String, Codable, Hashable, Sendable {
    case trusted
    case untrusted
    case unconfigured
    case unavailable

    public var label: String {
        switch self {
        case .trusted: "Trusted"
        case .untrusted: "Untrusted"
        case .unconfigured: "Not configured"
        case .unavailable: "Unavailable"
        }
    }
}

public struct AgentSession: Identifiable, Codable, Hashable, Sendable {
    /// Presentation provenance, not a lifecycle authorization shortcut.
    public var supplementalSourceLabel: String? = nil
    public let system: AgentSystem
    public let nativeID: String
    public var title: String
    public var project: SessionProject?
    public var workingDirectory: String
    public var trustFolderPath: String?
    public var folderTrustState: FolderTrustState
    public var updatedAt: Date
    public var sizeBytes: Int64?
    public var nativeState: NativeSessionState
    public var isTrashMember: Bool
    public var protection: SessionProtection
    public var descendantCount: Int
    public var descendantCountKnown: Bool

    public var id: String { "\(system.rawValue):\(nativeID)" }

    public var collection: SessionCollection {
        switch nativeState {
        case .active:
            return .active
        case .archived:
            return isTrashMember ? .trash : .archive
        case .absent:
            return .deleted
        case .unavailable:
            return .unavailable
        }
    }

    public init(
        system: AgentSystem,
        nativeID: String,
        title: String,
        project: SessionProject? = nil,
        workingDirectory: String,
        trustFolderPath: String? = nil,
        folderTrustState: FolderTrustState = .unavailable,
        updatedAt: Date,
        sizeBytes: Int64?,
        nativeState: NativeSessionState,
        isTrashMember: Bool = false,
        protection: SessionProtection = SessionProtection(),
        descendantCount: Int = 0,
        descendantCountKnown: Bool = true
    ) {
        self.system = system
        self.nativeID = nativeID
        self.title = title
        self.project = project
        self.workingDirectory = workingDirectory
        self.trustFolderPath = trustFolderPath
        self.folderTrustState = folderTrustState
        self.updatedAt = updatedAt
        self.sizeBytes = sizeBytes
        self.nativeState = nativeState
        self.isTrashMember = isTrashMember
        self.protection = protection
        self.descendantCount = descendantCount
        self.descendantCountKnown = descendantCountKnown
    }
}

public struct SessionCapabilities: Codable, Hashable, Sendable {
    public var canList: Bool
    public var canArchive: Bool
    public var canUnarchive: Bool
    public var canDelete: Bool
    public var canReadPinnedState: Bool
    public var canReadRunningState: Bool
    public var canReadCurrentState: Bool
    public var canReadDescendants: Bool
    public var canReadFolderTrust: Bool
    public var canReadExactSession: Bool
    /// The manager-owned state store is available for Trash membership writes.
    /// This is not a provider-native lifecycle capability.
    public var canWriteManagerTrashMembership: Bool
    /// The runtime exposes the official native lifecycle method. This is
    /// intentionally separate from `canArchive`: an interface can exist while
    /// manager execution remains locked behind incomplete safety evidence.
    public var hasNativeArchiveInterface: Bool?
    public var hasNativeUnarchiveInterface: Bool?
    public var hasNativeDeleteInterface: Bool?

    public init(
        canList: Bool = true,
        canArchive: Bool,
        canUnarchive: Bool,
        canDelete: Bool,
        canReadPinnedState: Bool,
        canReadRunningState: Bool,
        canReadCurrentState: Bool = false,
        canReadDescendants: Bool,
        canReadFolderTrust: Bool = false,
        canReadExactSession: Bool = false,
        canWriteManagerTrashMembership: Bool = false,
        hasNativeArchiveInterface: Bool? = nil,
        hasNativeUnarchiveInterface: Bool? = nil,
        hasNativeDeleteInterface: Bool? = nil
    ) {
        self.canList = canList
        self.canArchive = canArchive
        self.canUnarchive = canUnarchive
        self.canDelete = canDelete
        self.canReadPinnedState = canReadPinnedState
        self.canReadRunningState = canReadRunningState
        self.canReadCurrentState = canReadCurrentState
        self.canReadDescendants = canReadDescendants
        self.canReadFolderTrust = canReadFolderTrust
        self.canReadExactSession = canReadExactSession
        self.canWriteManagerTrashMembership = canWriteManagerTrashMembership
        self.hasNativeArchiveInterface = hasNativeArchiveInterface ?? canArchive
        self.hasNativeUnarchiveInterface = hasNativeUnarchiveInterface ?? canUnarchive
        self.hasNativeDeleteInterface = hasNativeDeleteInterface ?? canDelete
    }

    public static let codexFixture = SessionCapabilities(
        canArchive: true,
        canUnarchive: true,
        canDelete: true,
        canReadPinnedState: true,
        canReadRunningState: true,
        canReadCurrentState: true,
        canReadDescendants: true,
        canReadFolderTrust: true,
        canReadExactSession: false,
        canWriteManagerTrashMembership: true
    )

    public static let readOnlyFixture = SessionCapabilities(
        canArchive: false,
        canUnarchive: false,
        canDelete: false,
        canReadPinnedState: false,
        canReadRunningState: false,
        canReadCurrentState: false,
        canReadDescendants: false
    )

    public static let codexLiveReadOnly = SessionCapabilities(
        canArchive: false,
        canUnarchive: false,
        canDelete: false,
        canReadPinnedState: false,
        canReadRunningState: false,
        canReadCurrentState: false,
        canReadDescendants: false,
        canReadExactSession: true
    )
}

public enum ProviderConnectionState: String, Codable, Hashable, Sendable {
    case ready
    case degraded
    case unavailable

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .degraded: "Degraded"
        case .unavailable: "Unavailable"
        }
    }
}

public struct ProviderDiagnostics: Identifiable, Codable, Hashable, Sendable {
    public let system: AgentSystem
    public let connectionState: ProviderConnectionState
    public let runtimeVersion: String?
    public let userAgent: String?
    public let lastRefreshedAt: Date?
    public let inventoryComplete: Bool
    public let protectionComplete: Bool
    public let capabilities: SessionCapabilities
    public let messages: [String]

    public var id: String { system.rawValue }

    public init(
        system: AgentSystem,
        connectionState: ProviderConnectionState,
        runtimeVersion: String? = nil,
        userAgent: String? = nil,
        lastRefreshedAt: Date? = nil,
        inventoryComplete: Bool = false,
        protectionComplete: Bool = false,
        capabilities: SessionCapabilities,
        messages: [String] = []
    ) {
        self.system = system
        self.connectionState = connectionState
        self.runtimeVersion = runtimeVersion
        self.userAgent = userAgent
        self.lastRefreshedAt = lastRefreshedAt
        self.inventoryComplete = inventoryComplete
        self.protectionComplete = protectionComplete
        self.capabilities = capabilities
        self.messages = messages
    }
}

public enum SessionOperation: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case archive
    case moveToTrash
    case restore
    case moveToArchive
    case emptyTrash

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .archive: "Archive"
        case .moveToTrash: "Move to Trash"
        case .restore: "Restore"
        case .moveToArchive: "Move to Archive"
        case .emptyTrash: "Delete Permanently"
        }
    }

    public var symbol: String {
        switch self {
        case .archive: "archivebox"
        case .moveToTrash: "trash"
        case .restore: "arrow.uturn.backward"
        case .moveToArchive: "archivebox.fill"
        case .emptyTrash: "trash.slash"
        }
    }

    public var isDestructive: Bool { self == .emptyTrash }

    /// Typing the one-time token is deliberate friction reserved for
    /// irreversible user-visible deletion. Reversible lifecycle operations
    /// still require a frozen Preview and an explicit Confirm action; their
    /// internal Preview credential remains bound to the exact selection.
    public var requiresTypedConfirmation: Bool { self == .emptyTrash }

    public func targetCollection(from collection: SessionCollection) -> SessionCollection {
        switch self {
        case .archive, .moveToArchive:
            return .archive
        case .moveToTrash:
            return .trash
        case .restore:
            return .active
        case .emptyTrash:
            return .deleted
        }
    }

    public func plan(
        from collection: SessionCollection,
        nativeSessionID: String = "unknown"
    ) throws -> SessionOperationPlan {
        let nativeMutation: NativeLifecycleMutation?
        let trashMembershipMutation: TrashMembershipMutation?

        switch (self, collection) {
        case (.archive, .active):
            nativeMutation = .archive
            trashMembershipMutation = nil
        case (.moveToTrash, .active):
            nativeMutation = .archive
            trashMembershipMutation = .add
        case (.moveToTrash, .archive):
            nativeMutation = nil
            trashMembershipMutation = .add
        case (.restore, .archive):
            nativeMutation = .unarchive
            trashMembershipMutation = nil
        case (.restore, .trash):
            nativeMutation = .unarchive
            trashMembershipMutation = .remove
        case (.moveToArchive, .trash):
            nativeMutation = nil
            trashMembershipMutation = .remove
        case (.emptyTrash, .trash):
            nativeMutation = .delete
            trashMembershipMutation = .remove
        default:
            throw SessionManagerError.invalidTransition(nativeSessionID, collection, self)
        }

        return SessionOperationPlan(
            operation: self,
            sourceCollection: collection,
            targetCollection: targetCollection(from: collection),
            nativeMutation: nativeMutation,
            trashMembershipMutation: trashMembershipMutation
        )
    }
}

public enum NativeLifecycleMutation: String, Codable, Hashable, Sendable {
    case archive
    case unarchive
    case delete
}

public enum TrashMembershipMutation: String, Codable, Hashable, Sendable {
    case add
    case remove
}

/// Separates the user's manager intent from the Codex lifecycle request.
/// Archive <-> Trash can be manager-only because both are natively archived.
public struct SessionOperationPlan: Codable, Hashable, Sendable {
    public let operation: SessionOperation
    public let sourceCollection: SessionCollection
    public let targetCollection: SessionCollection
    public let nativeMutation: NativeLifecycleMutation?
    public let trashMembershipMutation: TrashMembershipMutation?

    /// Membership is never committed before a required provider mutation has
    /// an exact successful readback.
    public var membershipMutationRequiresNativeReadback: Bool {
        nativeMutation != nil && trashMembershipMutation != nil
    }

    public init(
        operation: SessionOperation,
        sourceCollection: SessionCollection,
        targetCollection: SessionCollection,
        nativeMutation: NativeLifecycleMutation?,
        trashMembershipMutation: TrashMembershipMutation?
    ) {
        self.operation = operation
        self.sourceCollection = sourceCollection
        self.targetCollection = targetCollection
        self.nativeMutation = nativeMutation
        self.trashMembershipMutation = trashMembershipMutation
    }
}

public struct OperationPreviewItem: Identifiable, Codable, Hashable, Sendable {
    public let managerKey: String
    public let nativeID: String
    public let title: String
    public let projectID: String?
    public let projectName: String?
    public let workingDirectory: String
    public let beforeCollection: SessionCollection
    public let targetCollection: SessionCollection
    public let sizeBytes: Int64?

    public var id: String { managerKey }

    public init(
        managerKey: String,
        nativeID: String,
        title: String,
        projectID: String?,
        projectName: String?,
        workingDirectory: String,
        beforeCollection: SessionCollection,
        targetCollection: SessionCollection,
        sizeBytes: Int64?
    ) {
        self.managerKey = managerKey
        self.nativeID = nativeID
        self.title = title
        self.projectID = projectID
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.beforeCollection = beforeCollection
        self.targetCollection = targetCollection
        self.sizeBytes = sizeBytes
    }
}

public struct OperationPreview: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let provider: AgentSystem
    public let operation: SessionOperation
    public let confirmationToken: String
    public let generatedAt: Date
    public let items: [OperationPreviewItem]
    public let warnings: [String]

    public var measurableBytes: Int64 {
        items.compactMap(\.sizeBytes).reduce(0, +)
    }

    public init(
        id: UUID,
        provider: AgentSystem,
        operation: SessionOperation,
        confirmationToken: String,
        generatedAt: Date,
        items: [OperationPreviewItem],
        warnings: [String]
    ) {
        self.id = id
        self.provider = provider
        self.operation = operation
        self.confirmationToken = confirmationToken
        self.generatedAt = generatedAt
        self.items = items
        self.warnings = warnings
    }
}

public struct OperationResultItem: Identifiable, Codable, Hashable, Sendable {
    public let managerKey: String
    public let nativeID: String
    public let title: String
    public let projectName: String?
    public let workingDirectory: String
    public let beforeCollection: SessionCollection
    public let observedFinalCollection: SessionCollection
    public let success: Bool
    public let note: String

    public var id: String { managerKey }

    public init(
        managerKey: String,
        nativeID: String,
        title: String,
        projectName: String?,
        workingDirectory: String,
        beforeCollection: SessionCollection,
        observedFinalCollection: SessionCollection,
        success: Bool,
        note: String
    ) {
        self.managerKey = managerKey
        self.nativeID = nativeID
        self.title = title
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.beforeCollection = beforeCollection
        self.observedFinalCollection = observedFinalCollection
        self.success = success
        self.note = note
    }
}

public struct OperationReport: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let previewID: UUID
    public let provider: AgentSystem
    public let operation: SessionOperation
    public let completedAt: Date
    public let items: [OperationResultItem]

    public var successCount: Int { items.filter(\.success).count }
    public var failureCount: Int { items.count - successCount }

    public init(
        id: UUID,
        previewID: UUID,
        provider: AgentSystem,
        operation: SessionOperation,
        completedAt: Date,
        items: [OperationResultItem]
    ) {
        self.id = id
        self.previewID = previewID
        self.provider = provider
        self.operation = operation
        self.completedAt = completedAt
        self.items = items
    }
}

public enum SessionManagerError: Error, LocalizedError, Equatable {
    case emptySelection
    case mixedProviders
    case providerUnavailable(AgentSystem)
    case unsupportedOperation(String)
    case sessionNotFound(String)
    case protectedSession(String, [String])
    case invalidTransition(String, SessionCollection, SessionOperation)
    case confirmationMismatch
    case previewDrift(String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Select at least one session."
        case .mixedProviders:
            "One operation cannot mix sessions from different agent systems."
        case .providerUnavailable(let system):
            "The \(system.label) provider is unavailable."
        case .unsupportedOperation(let message):
            message
        case .sessionNotFound(let key):
            "Session not found: \(key)"
        case .protectedSession(let id, let reasons):
            "Session \(id) is protected: \(reasons.joined(separator: ", "))."
        case .invalidTransition(let id, let collection, let operation):
            "Cannot perform \(operation.label) on \(id) while it is in \(collection.label)."
        case .confirmationMismatch:
            "Confirmation token mismatch; no mutation was applied."
        case .previewDrift(let id):
            "Session state changed after Preview: \(id). Create a new Preview."
        }
    }
}
