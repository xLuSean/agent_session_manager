import Foundation

/// Scope of the source that supplied a lifecycle-protection observation.
/// A positive observation can always protect a session. A negative observation
/// is only a clearance when its scope covers the entire relevant authority.
public enum ProtectionAuthorityScope: String, Codable, Hashable, Sendable {
    case fixtureProvider
    case providerPersistentState
    case managerProcess
    case completeProviderGraph
    case allRelevantHosts
}

public enum ProtectionAuthoritySource: String, Codable, Hashable, Sendable {
    case fixtureProvider
    case codexThreadListPin
    case codexDesktopPinnedThreadIDs
    case codexThreadListStatus
    case codexCompleteDescendantGraph
    case explicitCrossHostAuthority
}

public struct ProtectionAuthorityObservation: Codable, Hashable, Sendable {
    public let kind: ProtectionEvidenceKind
    public let isProtected: Bool
    public let source: ProtectionAuthoritySource
    public let scope: ProtectionAuthorityScope

    public init(
        kind: ProtectionEvidenceKind,
        isProtected: Bool,
        source: ProtectionAuthoritySource,
        scope: ProtectionAuthorityScope
    ) {
        self.kind = kind
        self.isProtected = isProtected
        self.source = source
        self.scope = scope
    }
}

public enum ProtectionAuthorityError: Error, Equatable, LocalizedError {
    case duplicateObservation(ProtectionEvidenceKind)
    case incompatibleSource(
        kind: ProtectionEvidenceKind,
        source: ProtectionAuthoritySource,
        scope: ProtectionAuthorityScope
    )

    public var errorDescription: String? {
        switch self {
        case let .duplicateObservation(kind):
            "Protection authority supplied duplicate \(kind.rawValue) observations."
        case let .incompatibleSource(kind, source, scope):
            "Protection authority source \(source.rawValue) with scope \(scope.rawValue) cannot describe \(kind.rawValue)."
        }
    }
}

/// Converts scoped observations into the existing fail-closed protection model.
/// `true` from a valid narrow source is sufficient to block. `false` is only
/// marked known when the source scope can prove clearance for that field.
public enum ProtectionAuthorityPolicy {
    public static func resolve(
        system: AgentSystem,
        observations: [ProtectionAuthorityObservation]
    ) throws -> SessionProtection {
        var byKind: [ProtectionEvidenceKind: ProtectionAuthorityObservation] = [:]
        for observation in observations {
            guard byKind.updateValue(observation, forKey: observation.kind) == nil else {
                throw ProtectionAuthorityError.duplicateObservation(observation.kind)
            }
            guard sourceIsCompatible(observation, system: system) else {
                throw ProtectionAuthorityError.incompatibleSource(
                    kind: observation.kind,
                    source: observation.source,
                    scope: observation.scope
                )
            }
        }

        let pinned = fact(.pinned, system: system, observations: byKind)
        let running = fact(.running, system: system, observations: byKind)
        let current = fact(.current, system: system, observations: byKind)
        let pinnedDescendant = fact(
            .pinnedDescendant,
            system: system,
            observations: byKind
        )
        return SessionProtection(
            isPinned: pinned.value,
            isRunning: running.value,
            isCurrent: current.value,
            hasPinnedDescendant: pinnedDescendant.value,
            isPinnedKnown: pinned.known,
            isRunningKnown: running.known,
            isCurrentKnown: current.known,
            hasPinnedDescendantKnown: pinnedDescendant.known
        )
    }

    private static func fact(
        _ kind: ProtectionEvidenceKind,
        system: AgentSystem,
        observations: [ProtectionEvidenceKind: ProtectionAuthorityObservation]
    ) -> (value: Bool, known: Bool) {
        guard let observation = observations[kind] else { return (false, false) }
        if observation.isProtected { return (true, true) }
        return (false, clearanceIsAuthoritative(observation, system: system))
    }

    private static func clearanceIsAuthoritative(
        _ observation: ProtectionAuthorityObservation,
        system: AgentSystem
    ) -> Bool {
        if system == .claudeCode {
            return observation.scope == .fixtureProvider
        }
        switch observation.kind {
        case .pinned:
            return observation.scope == .providerPersistentState
                || observation.scope == .allRelevantHosts
        case .running, .current:
            return observation.scope == .allRelevantHosts
        case .pinnedDescendant:
            return observation.scope == .completeProviderGraph
                || observation.scope == .allRelevantHosts
        }
    }

    private static func sourceIsCompatible(
        _ observation: ProtectionAuthorityObservation,
        system: AgentSystem
    ) -> Bool {
        if system == .claudeCode {
            return observation.source == .fixtureProvider
                && observation.scope == .fixtureProvider
        }
        switch observation.source {
        case .fixtureProvider:
            return false
        case .codexThreadListPin:
            return observation.kind == .pinned
                && observation.scope == .providerPersistentState
        case .codexDesktopPinnedThreadIDs:
            return observation.kind == .pinned
                && observation.scope == .providerPersistentState
        case .codexThreadListStatus:
            return observation.kind == .running
                && observation.scope == .managerProcess
        case .codexCompleteDescendantGraph:
            return observation.kind == .pinnedDescendant
                && observation.scope == .completeProviderGraph
        case .explicitCrossHostAuthority:
            return observation.scope == .allRelevantHosts
        }
    }
}
