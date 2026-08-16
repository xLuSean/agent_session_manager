import AgentSessionManagerCore
import Foundation

public actor FixtureSessionProvider: SessionProvider {
    public nonisolated let system: AgentSystem
    public nonisolated let capabilities: SessionCapabilities

    private var records: [String: AgentSession]
    private let now: @Sendable () -> Date

    public init(
        system: AgentSystem,
        capabilities: SessionCapabilities,
        sessions: [AgentSession],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.system = system
        self.capabilities = capabilities
        self.records = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        self.now = now
    }

    public func sessions() -> [AgentSession] {
        records.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    public func projects() -> [SessionProject] {
        Dictionary(
            records.values.compactMap(\.project).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            if $0.name != $1.name {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    public func diagnostics() -> ProviderDiagnostics {
        ProviderDiagnostics(
            system: system,
            connectionState: .ready,
            runtimeVersion: "in-memory",
            inventoryComplete: true,
            protectionComplete: records.values.allSatisfy {
                !$0.protection.hasUnavailableState && $0.descendantCountKnown
            },
            capabilities: capabilities,
            messages: ["Fixture provider only; no real agent session is accessed."]
        )
    }

    public func preview(operation: SessionOperation, managerKeys: [String]) throws -> OperationPreview {
        let uniqueKeys = Array(Set(managerKeys)).sorted()
        guard !uniqueKeys.isEmpty else { throw SessionManagerError.emptySelection }

        var items: [OperationPreviewItem] = []
        var warnings: [String] = []
        for key in uniqueKeys {
            guard let session = records[key] else { throw SessionManagerError.sessionNotFound(key) }
            guard session.system == system else { throw SessionManagerError.mixedProviders }
            let plan = try operation.plan(
                from: session.collection,
                nativeSessionID: session.nativeID
            )
            try requireCapability(for: plan)
            try validateProtection(session, operation: operation)

            if session.descendantCount > 0 {
                warnings.append("\(session.nativeID) includes \(session.descendantCount) descendant session(s).")
            }
            items.append(
                OperationPreviewItem(
                    managerKey: session.id,
                    nativeID: session.nativeID,
                    title: session.title,
                    projectID: session.project?.id,
                    projectName: session.project?.name,
                    workingDirectory: session.workingDirectory,
                    beforeCollection: session.collection,
                    targetCollection: operation.targetCollection(from: session.collection),
                    sizeBytes: session.sizeBytes
                )
            )
        }

        let tokenPrefix = operation.rawValue
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression)
            .uppercased()
        let token = "\(tokenPrefix)-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        return OperationPreview(
            id: UUID(),
            provider: system,
            operation: operation,
            confirmationToken: token,
            generatedAt: now(),
            items: items,
            warnings: warnings
        )
    }

    public func execute(preview: OperationPreview, confirmationToken: String) throws -> OperationReport {
        guard preview.provider == system else { throw SessionManagerError.mixedProviders }
        guard preview.confirmationToken == confirmationToken else {
            throw SessionManagerError.confirmationMismatch
        }
        for item in preview.items {
            guard let session = records[item.managerKey] else {
                throw SessionManagerError.sessionNotFound(item.managerKey)
            }
            guard session.collection == item.beforeCollection else {
                throw SessionManagerError.previewDrift(session.nativeID)
            }
            let plan = try preview.operation.plan(
                from: session.collection,
                nativeSessionID: session.nativeID
            )
            try requireCapability(for: plan)
            try validateProtection(session, operation: preview.operation)
        }

        var results: [OperationResultItem] = []
        for item in preview.items {
            guard var session = records[item.managerKey] else { continue }
            let before = session.collection
            apply(preview.operation, to: &session)
            session.updatedAt = now()
            records[item.managerKey] = session
            results.append(
                OperationResultItem(
                    managerKey: session.id,
                    nativeID: session.nativeID,
                    title: session.title,
                    projectName: session.project?.name,
                    workingDirectory: session.workingDirectory,
                    beforeCollection: before,
                    observedFinalCollection: session.collection,
                    success: session.collection == preview.operation.targetCollection(from: before),
                    note: "Verified in fixture provider; no real agent session was changed."
                )
            )
        }

        return OperationReport(
            id: UUID(),
            previewID: preview.id,
            provider: system,
            operation: preview.operation,
            completedAt: now(),
            items: results
        )
    }

    /// Fixture-only simulation of accepting a provider-native restore. It is
    /// deliberately separate from the normal lifecycle operation planner
    /// because an Active + Trash conflict is not a normal collection state.
    public func previewAcceptNativeRestore(managerKey: String) throws -> OperationPreview {
        guard let session = records[managerKey] else {
            throw SessionManagerError.sessionNotFound(managerKey)
        }
        guard session.nativeState == .active, session.isTrashMember else {
            throw SessionManagerError.unsupportedOperation(
                "Fixture Accept Native Restore requires an Active plus Trash conflict."
            )
        }
        let token = "ACCEPT-NATIVE-RESTORE-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        return OperationPreview(
            id: UUID(),
            provider: system,
            operation: .restore,
            confirmationToken: token,
            generatedAt: now(),
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
                "Fixture demo only: this changes process-local memory and never opens production SQLite or contacts Codex."
            ]
        )
    }

    public func executeAcceptNativeRestore(
        preview: OperationPreview,
        confirmationToken: String
    ) throws -> OperationReport {
        guard preview.provider == system,
              preview.operation == .restore,
              preview.items.count == 1,
              let item = preview.items.first,
              item.beforeCollection == .trash,
              item.targetCollection == .active else {
            throw SessionManagerError.unsupportedOperation(
                "This is not a Fixture Accept Native Restore Preview."
            )
        }
        guard preview.confirmationToken == confirmationToken else {
            throw SessionManagerError.confirmationMismatch
        }
        guard var session = records[item.managerKey] else {
            throw SessionManagerError.sessionNotFound(item.managerKey)
        }
        guard session.nativeID == item.nativeID,
              session.nativeState == .active,
              session.isTrashMember else {
            throw SessionManagerError.previewDrift(item.nativeID)
        }

        session.isTrashMember = false
        session.updatedAt = now()
        records[item.managerKey] = session
        return OperationReport(
            id: UUID(),
            previewID: preview.id,
            provider: system,
            operation: .restore,
            completedAt: now(),
            items: [
                OperationResultItem(
                    managerKey: session.id,
                    nativeID: session.nativeID,
                    title: session.title,
                    projectName: session.project?.name,
                    workingDirectory: session.workingDirectory,
                    beforeCollection: .trash,
                    observedFinalCollection: .active,
                    success: true,
                    note: "Fixture conflict resolved in process-local memory; no real Codex session or SQLite state changed."
                )
            ]
        )
    }

    private func requireCapability(for plan: SessionOperationPlan) throws {
        if plan.trashMembershipMutation != nil,
           !capabilities.canWriteManagerTrashMembership {
            throw SessionManagerError.unsupportedOperation(
                "\(system.label) manager state cannot update Trash membership."
            )
        }
        let supported: Bool
        switch plan.nativeMutation {
        case .archive:
            supported = capabilities.canArchive
        case .unarchive:
            supported = capabilities.canUnarchive
        case nil:
            supported = capabilities.canList
        case .delete:
            supported = capabilities.canDelete
        }
        guard supported else {
            throw SessionManagerError.unsupportedOperation(
                "\(system.label) does not support \(plan.operation.label) in this POC adapter."
            )
        }
    }

    private func validateProtection(_ session: AgentSession, operation: SessionOperation) throws {
        let blocked: Bool
        switch operation {
        case .archive, .moveToTrash, .emptyTrash:
            blocked = session.protection.blocksLifecycleMutation
        case .restore, .moveToArchive:
            blocked = false
        }
        if blocked {
            throw SessionManagerError.protectedSession(session.nativeID, session.protection.labels)
        }
    }

    private func apply(_ operation: SessionOperation, to session: inout AgentSession) {
        switch operation {
        case .archive:
            session.nativeState = .archived
            session.isTrashMember = false
        case .moveToTrash:
            session.nativeState = .archived
            session.isTrashMember = true
        case .restore:
            session.nativeState = .active
            session.isTrashMember = false
        case .moveToArchive:
            session.nativeState = .archived
            session.isTrashMember = false
        case .emptyTrash:
            session.nativeState = .absent
            session.isTrashMember = false
        }
    }
}

public enum FixtureData {
    public static func service(referenceDate: Date = Date()) -> AgentSessionManagerService {
        let day: TimeInterval = 86_400
        let codex = FixtureSessionProvider(
            system: .codex,
            capabilities: .codexFixture,
            sessions: [
                AgentSession(
                    system: .codex,
                    nativeID: "01900000-0000-7000-8000-000000000002",
                    title: "Example active task",
                    project: SessionProject(id: "fixture:sample_mail_project", name: "sample_mail_project", rootPath: "/Users/example/Projects/sample_mail_project"),
                    workingDirectory: "/Users/example/Projects/sample_mail_project",
                    trustFolderPath: "/Users/example/Projects/sample_mail_project",
                    folderTrustState: .trusted,
                    updatedAt: referenceDate.addingTimeInterval(-day),
                    sizeBytes: 452_608,
                    nativeState: .active
                ),
                AgentSession(
                    system: .codex,
                    nativeID: "00000000-0000-0000-0000-00000000c0de",
                    title: "[Demo Conflict] Restored outside Session Manager",
                    project: SessionProject(
                        id: "fixture:sample_session_project",
                        name: "sample_session_project",
                        rootPath: "/Users/example/Projects/sample_session_project"
                    ),
                    workingDirectory: "/Users/example/Projects/sample_session_project",
                    trustFolderPath: "/Users/example/Projects/sample_session_project",
                    folderTrustState: .trusted,
                    updatedAt: referenceDate.addingTimeInterval(-900),
                    sizeBytes: 64_000,
                    nativeState: .active,
                    isTrashMember: true
                ),
                AgentSession(
                    system: .codex,
                    nativeID: "01900000-0000-7000-8000-000000000003",
                    title: "Example archived task",
                    project: SessionProject(id: "fixture:sample_presentation_project", name: "sample_presentation_project", rootPath: "/Users/example/Projects/sample_presentation_project"),
                    workingDirectory: "/Users/example/Projects/sample_presentation_project",
                    trustFolderPath: "/Users/example/Projects/sample_presentation_project",
                    folderTrustState: .trusted,
                    updatedAt: referenceDate.addingTimeInterval(-day * 26),
                    sizeBytes: 47_431,
                    nativeState: .archived
                ),
                AgentSession(
                    system: .codex,
                    nativeID: "01900000-0000-7000-8000-000000000004",
                    title: "Old experiment",
                    project: SessionProject(id: "fixture:playground", name: "playground", rootPath: "/Users/example/Projects/playground"),
                    workingDirectory: "/Users/example/Projects/playground",
                    trustFolderPath: "/Users/example/Projects/playground",
                    folderTrustState: .trusted,
                    updatedAt: referenceDate.addingTimeInterval(-day * 18),
                    sizeBytes: 128_400,
                    nativeState: .archived,
                    isTrashMember: true,
                    descendantCount: 2
                ),
                AgentSession(
                    system: .codex,
                    nativeID: "01900000-0000-7000-8000-000000000005",
                    title: "Example pinned task",
                    project: SessionProject(id: "fixture:sample_skill_project", name: "sample_skill_project", rootPath: "/Users/example/Projects/sample_skill_project"),
                    workingDirectory: "/Users/example/Projects/sample_skill_project",
                    trustFolderPath: "/Users/example/Projects/sample_skill_project",
                    folderTrustState: .trusted,
                    updatedAt: referenceDate.addingTimeInterval(-3_600),
                    sizeBytes: 934_211,
                    nativeState: .active,
                    protection: SessionProtection(isPinned: true)
                ),
                AgentSession(
                    system: .codex,
                    nativeID: "01900000-0000-7000-8000-000000000006",
                    title: "Example running task",
                    project: SessionProject(id: "fixture:sample_mail_project", name: "sample_mail_project", rootPath: "/Users/example/Projects/sample_mail_project"),
                    workingDirectory: "/Users/example/Projects/sample_mail_project",
                    trustFolderPath: "/Users/example/Projects/sample_mail_project",
                    folderTrustState: .trusted,
                    updatedAt: referenceDate,
                    sizeBytes: 1_820_500,
                    nativeState: .active,
                    protection: SessionProtection(isRunning: true, isCurrent: true)
                ),
            ]
        )

        let claude = FixtureSessionProvider(
            system: .claudeCode,
            capabilities: .readOnlyFixture,
            sessions: [
                AgentSession(
                    system: .claudeCode,
                    nativeID: "claude-demo-2026-08-01-001",
                    title: "Future provider example",
                    project: SessionProject(id: "fixture:example", name: "example", rootPath: "/Users/example/Projects/example"),
                    workingDirectory: "/Users/example/Projects/example",
                    folderTrustState: .unavailable,
                    updatedAt: referenceDate.addingTimeInterval(-day * 10),
                    sizeBytes: nil,
                    nativeState: .unavailable
                ),
            ]
        )

        return AgentSessionManagerService(providers: [codex, claude])
    }
}
