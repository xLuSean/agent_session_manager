import Foundation

public enum SessionDisplayState: String, CaseIterable, Codable, Sendable {
    case active
    case archive
    case trash
    case deleted
    case conflict
    case externallyMissing
    case unavailable

    public var label: String {
        switch self {
        case .active: "Active"
        case .archive: "Archive"
        case .trash: "Trash Bin"
        case .deleted: "Deleted"
        case .conflict: "Conflict"
        case .externallyMissing: "Externally Missing"
        case .unavailable: "Unavailable"
        }
    }

    public var symbol: String {
        switch self {
        case .active: "bubble.left.and.bubble.right"
        case .archive: "archivebox"
        case .trash: "trash"
        case .deleted: "xmark.bin"
        case .conflict: "exclamationmark.triangle"
        case .externallyMissing: "questionmark.folder"
        case .unavailable: "wifi.exclamationmark"
        }
    }

    public var filterCollection: SessionCollection {
        switch self {
        case .active: .active
        case .archive: .archive
        case .trash: .trash
        case .deleted: .deleted
        case .conflict, .externallyMissing, .unavailable: .unavailable
        }
    }
}

/// UI-safe lifecycle presentation. It preserves reconciliation conflicts and
/// membership-only rows instead of forcing them into a normal collection.
public struct SessionPresentation: Identifiable, Equatable, Sendable {
    public let managerKey: String
    public let system: AgentSystem
    public let nativeID: String
    public let title: String
    public let project: SessionProject?
    public let workingDirectory: String?
    public let trustFolderPath: String?
    public let folderTrustState: FolderTrustState
    public let updatedAt: Date
    public let sizeBytes: Int64?
    public let nativeState: NativeSessionState?
    public let protection: SessionProtection
    public let descendantCount: Int
    public let descendantCountKnown: Bool
    public let displayState: SessionDisplayState
    public let stateExplanation: String
    public let isStableForLifecyclePreview: Bool
    public let liveSession: AgentSession?
    public let trashMembership: TrashMembershipRecord?

    public var id: String { managerKey }

    public var protectionEvidence: [ProtectionEvidence] {
        ProtectionEvidenceBuilder.evidence(for: protection, system: system)
    }

    public init(session: AgentSession) {
        managerKey = session.id
        system = session.system
        nativeID = session.nativeID
        title = session.title
        project = session.project
        workingDirectory = session.workingDirectory
        trustFolderPath = session.trustFolderPath
        folderTrustState = session.folderTrustState
        updatedAt = session.updatedAt
        sizeBytes = session.sizeBytes
        nativeState = session.nativeState
        protection = session.protection
        descendantCount = session.descendantCount
        descendantCountKnown = session.descendantCountKnown
        displayState = Self.displayState(for: session.collection)
        stateExplanation = "Fixture state is provided by the in-memory reference provider."
        isStableForLifecyclePreview = !session.protection.blocksLifecycleMutation
        liveSession = session
        trashMembership = nil
    }

    public init(
        reconciled state: ReconciledSessionState,
        projectCatalog: [SessionProject] = []
    ) {
        let live = state.liveSession
        let membership = state.trashMembership
        let provider = live?.system ?? membership?.provider
        let nativeID = live?.nativeID ?? membership?.nativeSessionID

        // Reconciler validation guarantees at least one side exists and both
        // identities agree. Keep defensive fallbacks fail-closed for UI safety.
        system = provider ?? .codex
        self.nativeID = nativeID ?? state.managerKey
        managerKey = state.managerKey
        title = live?.title ?? membership?.titleAtEntry ?? "Unavailable session"
        workingDirectory = live?.workingDirectory ?? membership?.workingDirectoryAtEntry
        project = Self.resolvedProject(
            live: live,
            membership: membership,
            workingDirectory: workingDirectory,
            catalog: projectCatalog
        )
        trustFolderPath = live?.trustFolderPath
        folderTrustState = live?.folderTrustState ?? .unavailable
        updatedAt = live?.updatedAt ?? membership?.lastReconciledAt ?? .distantPast
        sizeBytes = live?.sizeBytes
        nativeState = live?.nativeState
        protection = live?.protection ?? SessionProtection(
            isPinnedKnown: false,
            isRunningKnown: false,
            isCurrentKnown: false,
            hasPinnedDescendantKnown: false
        )
        descendantCount = live?.descendantCount ?? 0
        descendantCountKnown = live?.descendantCountKnown ?? false
        displayState = Self.displayState(for: state.status)
        stateExplanation = Self.explanation(for: state.status)
        isStableForLifecyclePreview = state.isStableForLifecyclePreview
        liveSession = live
        trashMembership = membership
    }

    public init(
        deleted record: DeletedSessionRecord,
        projectCatalog: [SessionProject] = []
    ) {
        managerKey = record.managerKey
        system = record.provider
        nativeID = record.nativeSessionID
        title = record.titleAtDeletion
        workingDirectory = record.workingDirectoryAtDeletion
        if let projectID = record.projectIDAtDeletion,
           let exactProject = projectCatalog.first(where: { $0.id == projectID }) {
            project = exactProject
        } else if let workingDirectory = record.workingDirectoryAtDeletion {
            let folderName = URL(fileURLWithPath: workingDirectory).lastPathComponent
            let matches = projectCatalog.filter {
                $0.name.caseInsensitiveCompare(folderName) == .orderedSame
                    || URL(fileURLWithPath: $0.rootPath).lastPathComponent
                        .caseInsensitiveCompare(folderName) == .orderedSame
            }
            project = matches.count == 1 ? matches[0] : nil
        } else {
            project = nil
        }
        trustFolderPath = nil
        folderTrustState = .unavailable
        updatedAt = record.deletedAt
        sizeBytes = record.knownSizeBytes
        nativeState = .absent
        protection = SessionProtection()
        descendantCount = 0
        descendantCountKnown = true
        displayState = .deleted
        stateExplanation = "Official Delete readback verified the native session is absent. This durable tombstone is independent from Report History."
        isStableForLifecyclePreview = false
        liveSession = nil
        trashMembership = nil
    }

    private static func resolvedProject(
        live: AgentSession?,
        membership: TrashMembershipRecord?,
        workingDirectory: String?,
        catalog: [SessionProject]
    ) -> SessionProject? {
        if let project = live?.project { return project }
        if let projectID = membership?.projectIDAtEntry,
           let project = catalog.first(where: { $0.id == projectID }) {
            return project
        }

        // Older sessions may retain an original cwd after a Desktop project
        // is moved. Use this fallback only for a Trash membership and only
        // when the cwd basename identifies exactly one current project.
        guard membership != nil, let workingDirectory else { return nil }
        let folderName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        let matches = catalog.filter { project in
            project.name.caseInsensitiveCompare(folderName) == .orderedSame
                || URL(fileURLWithPath: project.rootPath).lastPathComponent
                    .caseInsensitiveCompare(folderName) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func displayState(for collection: SessionCollection) -> SessionDisplayState {
        switch collection {
        case .active: .active
        case .archive: .archive
        case .trash: .trash
        case .deleted: .deleted
        case .unavailable: .unavailable
        }
    }

    private static func displayState(for status: ReconciliationStatus) -> SessionDisplayState {
        switch status {
        case .active: .active
        case .archive: .archive
        case .trash: .trash
        case .nativeActiveTrashConflict: .conflict
        case .externallyMissing: .externallyMissing
        case .unavailable: .unavailable
        }
    }

    private static func explanation(for status: ReconciliationStatus) -> String {
        switch status {
        case .active:
            "Native provider reports Active and SQLite has no Trash intent."
        case .archive:
            "Native provider reports Archived and SQLite has no Trash intent."
        case .trash:
            "Native provider reports Archived and SQLite retains manager Trash intent."
        case .nativeActiveTrashConflict:
            "Native provider reports Active while SQLite still retains Trash intent. No lifecycle action is allowed until this conflict is resolved."
        case .externallyMissing:
            "A complete provider inventory did not observe this SQLite Trash member. It is not declared Deleted without authoritative exact-ID readback."
        case .unavailable:
            "Provider evidence is incomplete or unavailable, so lifecycle state is not inferred."
        }
    }
}
