import Foundation

public enum ProtectionEvidenceKind: String, CaseIterable, Codable, Hashable, Sendable {
    case pinned
    case running
    case current
    case pinnedDescendant

    public var label: String {
        switch self {
        case .pinned: "Pinned"
        case .running: "Running"
        case .current: "Current task"
        case .pinnedDescendant: "Pinned descendant"
        }
    }
}

public enum ProtectionEvidenceVerdict: String, Codable, Hashable, Sendable {
    case protected
    case clear
    case unavailable

    public var label: String {
        switch self {
        case .protected: "Protected"
        case .clear: "Verified clear"
        case .unavailable: "Unavailable"
        }
    }

    public var blocksLifecycleMutation: Bool { self != .clear }
}

public enum ProtectionEvidenceSource: String, Codable, Hashable, Sendable {
    case fixtureProvider
    case codexThreadListPin
    case codexDesktopPinnedThreadIDs
    case codexThreadListStatus
    case codexCompleteDescendantGraph
    case unavailable

    public var label: String {
        switch self {
        case .fixtureProvider: "Fixture provider"
        case .codexThreadListPin: "thread/list isPinned"
        case .codexDesktopPinnedThreadIDs: "Codex Desktop pinned-thread-ids"
        case .codexThreadListStatus: "thread/list runtime status"
        case .codexCompleteDescendantGraph: "Complete thread/list descendant graph"
        case .unavailable: "No authoritative source"
        }
    }
}

/// One protection fact with an explicit three-state verdict. A false value is
/// only `clear` when the provider also marks that field as known.
public struct ProtectionEvidence: Identifiable, Codable, Hashable, Sendable {
    public let kind: ProtectionEvidenceKind
    public let verdict: ProtectionEvidenceVerdict
    public let source: ProtectionEvidenceSource
    public let explanation: String

    public var id: ProtectionEvidenceKind { kind }

    public init(
        kind: ProtectionEvidenceKind,
        verdict: ProtectionEvidenceVerdict,
        source: ProtectionEvidenceSource,
        explanation: String
    ) {
        self.kind = kind
        self.verdict = verdict
        self.source = source
        self.explanation = explanation
    }
}

public enum ProtectionEvidenceBuilder {
    public static func evidence(
        for protection: SessionProtection,
        system: AgentSystem
    ) -> [ProtectionEvidence] {
        switch system {
        case .codex:
            codexEvidence(for: protection)
        case .claudeCode:
            fixtureEvidence(for: protection)
        }
    }

    private static func codexEvidence(for protection: SessionProtection) -> [ProtectionEvidence] {
        [
            item(
                kind: .pinned,
                value: protection.isPinned,
                known: protection.isPinnedKnown,
                knownSource: .codexDesktopPinnedThreadIDs,
                knownExplanation: "The persisted pin value was resolved from a consistent Codex Desktop pinned-thread-ids snapshot.",
                unavailableExplanation: "Neither Codex Desktop pinned-thread-ids nor thread/list supplied a complete, non-conflicting pin value."
            ),
            positiveOnlyItem(
                kind: .running,
                value: protection.isRunning,
                known: protection.isRunningKnown,
                knownSource: .codexThreadListStatus,
                protectedExplanation: "Official thread/list reported active in this manager-owned App Server process.",
                unavailableExplanation: "A non-active status in this process cannot rule out activity in another Codex host."
            ),
            ProtectionEvidence(
                kind: .current,
                verdict: .unavailable,
                source: .unavailable,
                explanation: "App Server exposes no authoritative cross-host current-task identity."
            ),
            item(
                kind: .pinnedDescendant,
                value: protection.hasPinnedDescendant,
                known: protection.hasPinnedDescendantKnown,
                knownSource: .codexCompleteDescendantGraph,
                knownExplanation: "The all-source descendant graph reached its final cursor and every descendant was checked against the complete pin snapshot.",
                unavailableExplanation: "The descendant graph or at least one descendant pin value is incomplete."
            ),
        ]
    }

    private static func fixtureEvidence(for protection: SessionProtection) -> [ProtectionEvidence] {
        [
            item(kind: .pinned, value: protection.isPinned, known: protection.isPinnedKnown),
            item(kind: .running, value: protection.isRunning, known: protection.isRunningKnown),
            item(kind: .current, value: protection.isCurrent, known: protection.isCurrentKnown),
            item(
                kind: .pinnedDescendant,
                value: protection.hasPinnedDescendant,
                known: protection.hasPinnedDescendantKnown
            ),
        ]
    }

    private static func item(
        kind: ProtectionEvidenceKind,
        value: Bool,
        known: Bool,
        knownSource: ProtectionEvidenceSource = .fixtureProvider,
        knownExplanation: String = "The fixture provider supplied this protection value.",
        unavailableExplanation: String = "The provider did not supply this protection value."
    ) -> ProtectionEvidence {
        guard known else {
            return ProtectionEvidence(
                kind: kind,
                verdict: .unavailable,
                source: .unavailable,
                explanation: unavailableExplanation
            )
        }
        return ProtectionEvidence(
            kind: kind,
            verdict: value ? .protected : .clear,
            source: knownSource,
            explanation: knownExplanation
        )
    }

    private static func positiveOnlyItem(
        kind: ProtectionEvidenceKind,
        value: Bool,
        known: Bool,
        knownSource: ProtectionEvidenceSource,
        protectedExplanation: String,
        unavailableExplanation: String
    ) -> ProtectionEvidence {
        guard known, value else {
            return ProtectionEvidence(
                kind: kind,
                verdict: .unavailable,
                source: .unavailable,
                explanation: unavailableExplanation
            )
        }
        return ProtectionEvidence(
            kind: kind,
            verdict: .protected,
            source: knownSource,
            explanation: protectedExplanation
        )
    }
}
