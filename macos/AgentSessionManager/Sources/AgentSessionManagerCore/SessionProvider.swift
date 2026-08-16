import Foundation

public protocol SessionProvider: Sendable {
    var system: AgentSystem { get }
    var capabilities: SessionCapabilities { get }

    func sessions() async throws -> [AgentSession]
    func projects() async -> [SessionProject]
    func diagnostics() async -> ProviderDiagnostics
    func preview(operation: SessionOperation, managerKeys: [String]) async throws -> OperationPreview
    func execute(preview: OperationPreview, confirmationToken: String) async throws -> OperationReport
}

public struct ArchiveScopeSnapshot: Equatable, Sendable {
    public let nodes: [ArchiveScopeNode]
    public let isComplete: Bool

    public init(nodes: [ArchiveScopeNode], isComplete: Bool) {
        self.nodes = nodes
        self.isComplete = isComplete
    }
}

public protocol ArchiveScopeSnapshotProviding: Sendable {
    func archiveScopeSnapshot() async -> ArchiveScopeSnapshot
}

public actor AgentSessionManagerService {
    private let providers: [AgentSystem: any SessionProvider]

    public init(providers: [any SessionProvider]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.system, $0) })
    }

    public func sessions() async throws -> [AgentSession] {
        var combined: [AgentSession] = []
        for system in providers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let provider = providers[system] else { continue }
            combined.append(contentsOf: try await provider.sessions())
        }
        return combined.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    public func projects() async -> [SessionProject] {
        var combined: [SessionProject] = []
        var seenIDs: Set<String> = []
        for system in providers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let provider = providers[system] else { continue }
            for project in await provider.projects() where seenIDs.insert(project.id).inserted {
                combined.append(project)
            }
        }
        return combined
    }

    public func capabilities(for system: AgentSystem) throws -> SessionCapabilities {
        guard let provider = providers[system] else {
            throw SessionManagerError.providerUnavailable(system)
        }
        return provider.capabilities
    }

    public func diagnostics() async -> [ProviderDiagnostics] {
        var values: [ProviderDiagnostics] = []
        for system in providers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let provider = providers[system] else { continue }
            values.append(await provider.diagnostics())
        }
        return values
    }

    public func preview(operation: SessionOperation, managerKeys: [String]) async throws -> OperationPreview {
        guard !managerKeys.isEmpty else { throw SessionManagerError.emptySelection }
        let systems = Set(managerKeys.compactMap(Self.system(from:)))
        guard systems.count == 1, let system = systems.first else {
            throw SessionManagerError.mixedProviders
        }
        guard let provider = providers[system] else {
            throw SessionManagerError.providerUnavailable(system)
        }
        return try await provider.preview(operation: operation, managerKeys: managerKeys)
    }

    public func execute(preview: OperationPreview, confirmationToken: String) async throws -> OperationReport {
        guard let provider = providers[preview.provider] else {
            throw SessionManagerError.providerUnavailable(preview.provider)
        }
        return try await provider.execute(preview: preview, confirmationToken: confirmationToken)
    }

    private static func system(from managerKey: String) -> AgentSystem? {
        guard let prefix = managerKey.split(separator: ":", maxSplits: 1).first else { return nil }
        return AgentSystem(rawValue: String(prefix))
    }
}
