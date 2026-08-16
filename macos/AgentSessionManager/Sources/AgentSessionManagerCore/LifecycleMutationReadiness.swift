import Foundation

public enum LifecycleReadinessVerdict: String, Codable, Hashable, Sendable {
    case satisfied
    /// The evidence is sufficient for a bounded official attempt, but the
    /// provider may safely reject it (for example, because a writer is busy).
    /// This is not equivalent to verified clearance.
    case attemptMayFail
    case blocked
    case unavailable

    fileprivate var permitsAttempt: Bool {
        self == .satisfied || self == .attemptMayFail
    }
}

public enum LifecycleReadinessRequirement: String, CaseIterable, Codable, Hashable, Sendable {
    case exactSelection
    case provider
    case nativeState
    case stableReconciliation
    case completeInventory
    case runtimeBinding
    case archiveInterface
    case exactReadbackInterface
    case writerAuthority
    case pinned
    case running
    case current
    case descendants
    case pinnedDescendant
    case executor

    public var label: String {
        switch self {
        case .exactSelection: "Exact selection"
        case .provider: "Provider"
        case .nativeState: "Native state"
        case .stableReconciliation: "Reconciliation"
        case .completeInventory: "Inventory coverage"
        case .runtimeBinding: "Runtime binding"
        case .archiveInterface: "Archive interface"
        case .exactReadbackInterface: "Exact-ID readback"
        case .writerAuthority: "Writer authority"
        case .pinned: "Pinned protection"
        case .running: "Running protection"
        case .current: "Current-task protection"
        case .descendants: "Descendant scope"
        case .pinnedDescendant: "Pinned descendants"
        case .executor: "Manager executor"
        }
    }
}

public enum LifecycleWriterAuthorityStatus: String, Codable, Hashable, Sendable {
    case verifiedClear
    case writerPresent
    case unavailable
}

public enum LifecycleWriterAuthoritySource: String, Codable, Hashable, Sendable {
    /// Evidence supplied by the official lifecycle host that owns the target
    /// thread's writer domain. Merely starting another App Server process does
    /// not qualify.
    case officialLifecycleHost
    /// Test-only or future provider authority that covers every relevant host.
    case allRelevantHosts
}

/// Exact-session, snapshot-bound evidence for the rollout writer lock. Writer
/// authority is deliberately separate from runtime `status`: an idle thread
/// can still have a writer owned by another Codex host.
public struct LifecycleWriterAuthorityEvidence: Codable, Hashable, Sendable {
    public let nativeSessionID: String
    public let runtimeVersion: String
    public let inventoryHash: String
    public let observedAt: Date
    public let status: LifecycleWriterAuthorityStatus
    public let source: LifecycleWriterAuthoritySource
    public let explanation: String

    public init(
        nativeSessionID: String,
        runtimeVersion: String,
        inventoryHash: String,
        observedAt: Date,
        status: LifecycleWriterAuthorityStatus,
        source: LifecycleWriterAuthoritySource,
        explanation: String
    ) {
        self.nativeSessionID = nativeSessionID
        self.runtimeVersion = runtimeVersion
        self.inventoryHash = inventoryHash
        self.observedAt = observedAt
        self.status = status
        self.source = source
        self.explanation = explanation
    }
}

public struct LifecycleReadinessItem: Identifiable, Codable, Hashable, Sendable {
    public let requirement: LifecycleReadinessRequirement
    public let verdict: LifecycleReadinessVerdict
    public let explanation: String

    public var id: LifecycleReadinessRequirement { requirement }

    public init(
        requirement: LifecycleReadinessRequirement,
        verdict: LifecycleReadinessVerdict,
        explanation: String
    ) {
        self.requirement = requirement
        self.verdict = verdict
        self.explanation = explanation
    }
}

public struct LifecycleMutationReadiness: Identifiable, Codable, Hashable, Sendable {
    public let operation: SessionOperation
    public let managerKey: String?
    public let nativeSessionID: String?
    public let items: [LifecycleReadinessItem]

    public var id: String {
        "\(operation.rawValue):\(managerKey ?? "unselected")"
    }

    public init(
        operation: SessionOperation,
        managerKey: String?,
        nativeSessionID: String? = nil,
        items: [LifecycleReadinessItem]
    ) {
        self.operation = operation
        self.managerKey = managerKey
        self.nativeSessionID = nativeSessionID
        self.items = items
    }

    /// Safety evidence excludes the executor implementation itself. A runtime
    /// can become evidence-ready before this app is authorized to mutate it.
    public var isEvidenceReady: Bool {
        items
            .filter { $0.requirement != .executor }
            .allSatisfy { $0.verdict.permitsAttempt }
    }

    public var isExecutionEnabled: Bool {
        items.allSatisfy { $0.verdict.permitsAttempt }
    }

    public var hasAttemptRisk: Bool {
        items.contains { $0.verdict == .attemptMayFail }
    }

    public var primaryBlockedReason: String? {
        items.first { !$0.verdict.permitsAttempt }?.explanation
    }
}

/// Typed, read-only gate for the first planned native mutation slice: exactly
/// one active Codex root thread archived through official App Server APIs.
/// This assessor never invokes a lifecycle method.
public enum ArchiveMutationReadinessAssessor {
    public static func assess(
        session: AgentSession?,
        selectionCount: Int,
        diagnostics: ProviderDiagnostics?,
        checkpoint: ProviderCheckpointRecord?,
        reconciliationStable: Bool,
        writerAuthority: LifecycleWriterAuthorityEvidence? = nil,
        executorAvailable: Bool = false
    ) -> LifecycleMutationReadiness {
        var items: [LifecycleReadinessItem] = []
        let capabilities = diagnostics?.capabilities

        items.append(item(
            .exactSelection,
            selectionCount == 1 ? .satisfied : .blocked,
            selectionCount == 1
                ? "Exactly one frozen manager key is selected."
                : "The first live Archive slice accepts exactly one session."
        ))
        items.append(item(
            .provider,
            session?.system == .codex ? .satisfied : (session == nil ? .unavailable : .blocked),
            session?.system == .codex
                ? "The selected session belongs to Codex."
                : "A live Codex session is required."
        ))
        items.append(item(
            .nativeState,
            session?.nativeState == .active ? .satisfied : (session == nil ? .unavailable : .blocked),
            session?.nativeState == .active
                ? "The official inventory reports the session as active."
                : "Only a natively active session can enter the first Archive slice."
        ))
        items.append(item(
            .stableReconciliation,
            reconciliationStable ? .satisfied : .blocked,
            reconciliationStable
                ? "The row has no manager/native reconciliation conflict."
                : "Resolve or refresh the reconciliation conflict before Archive."
        ))

        let inventoryComplete = diagnostics?.inventoryComplete == true
            && checkpoint?.inventoryComplete == true
        items.append(item(
            .completeInventory,
            inventoryComplete ? .satisfied : .unavailable,
            inventoryComplete
                ? "The live inventory and authoritative checkpoint are complete."
                : "A complete live inventory and authoritative checkpoint are required."
        ))

        let runtimeBound = diagnostics?.runtimeVersion != nil
            && diagnostics?.runtimeVersion == checkpoint?.runtimeVersion
            && checkpoint?.inventoryHash.isEmpty == false
        items.append(item(
            .runtimeBinding,
            runtimeBound ? .satisfied : .unavailable,
            runtimeBound
                ? "The checkpoint is bound to the currently observed runtime version."
                : "The current runtime version must match a non-empty authoritative checkpoint."
        ))
        items.append(item(
            .archiveInterface,
            capabilities?.hasNativeArchiveInterface == true ? .satisfied : .unavailable,
            capabilities?.hasNativeArchiveInterface == true
                ? "The runtime schema exposes official thread/archive."
                : "Official thread/archive is unavailable in the observed runtime contract."
        ))
        items.append(item(
            .exactReadbackInterface,
            capabilities?.canReadExactSession == true ? .satisfied : .unavailable,
            capabilities?.canReadExactSession == true
                ? "Official thread/read is available for preflight and post-operation readback."
                : "Official exact-ID readback is required."
        ))

        appendWriterAuthority(
            to: &items,
            session: session,
            checkpoint: checkpoint,
            evidence: writerAuthority
        )

        appendProtection(
            to: &items,
            requirement: .pinned,
            value: session?.protection.isPinned,
            known: session?.protection.isPinnedKnown,
            protectedExplanation: "Pinned sessions cannot be archived.",
            unavailableExplanation: "Pin state must be authoritatively known before Archive.",
            clearExplanation: "Pin state is authoritatively clear."
        )
        appendProtection(
            to: &items,
            requirement: .running,
            value: session?.protection.isRunning,
            known: session?.protection.isRunningKnown,
            protectedExplanation: "Running sessions cannot be archived.",
            unavailableExplanation: "Cross-host running state is unavailable and is not claimed clear. The allow-listed one-shot Archive attempt may be rejected as Busy.",
            clearExplanation: "Running state is authoritatively clear.",
            unknownVerdict: .attemptMayFail
        )
        appendProtection(
            to: &items,
            requirement: .current,
            value: session?.protection.isCurrent,
            known: session?.protection.isCurrentKnown,
            protectedExplanation: "The current task cannot archive itself.",
            unavailableExplanation: "Cross-host current-task identity is unavailable and is not claimed clear. The allow-listed one-shot Archive attempt may be rejected as Busy.",
            clearExplanation: "Current-task protection is authoritatively clear.",
            unknownVerdict: .attemptMayFail
        )

        let descendantsKnown = session?.descendantCountKnown == true
        let descendantCount = session?.descendantCount
        let descendantVerdict: LifecycleReadinessVerdict = !descendantsKnown
            ? .unavailable
            : (descendantCount == 0 ? .satisfied : .blocked)
        items.append(item(
            .descendants,
            descendantVerdict,
            descendantVerdict == .satisfied
                ? "The complete graph shows no descendants."
                : (descendantVerdict == .blocked
                    ? "The first Archive slice excludes sessions with descendants because thread/archive can affect them too."
                    : "A complete descendant graph is required before Archive.")
        ))
        appendProtection(
            to: &items,
            requirement: .pinnedDescendant,
            value: session?.protection.hasPinnedDescendant,
            known: session?.protection.hasPinnedDescendantKnown,
            protectedExplanation: "A session with a pinned descendant cannot be archived.",
            unavailableExplanation: "Pinned-descendant state must be authoritatively known before Archive.",
            clearExplanation: "Pinned-descendant protection is authoritatively clear."
        )

        items.append(item(
            .executor,
            executorAvailable ? .satisfied : .blocked,
            executorAvailable
                ? "The manager Archive executor is enabled."
                : "The manager Archive executor is not implemented or authorized yet; no native mutation will run."
        ))

        return LifecycleMutationReadiness(
            operation: .archive,
            managerKey: session?.id,
            nativeSessionID: session?.nativeID,
            items: items
        )
    }

    private static func appendProtection(
        to items: inout [LifecycleReadinessItem],
        requirement: LifecycleReadinessRequirement,
        value: Bool?,
        known: Bool?,
        protectedExplanation: String,
        unavailableExplanation: String,
        clearExplanation: String,
        unknownVerdict: LifecycleReadinessVerdict = .unavailable
    ) {
        let verdict: LifecycleReadinessVerdict
        let explanation: String
        if known != true {
            verdict = unknownVerdict
            explanation = unavailableExplanation
        } else if value == true {
            verdict = .blocked
            explanation = protectedExplanation
        } else {
            verdict = .satisfied
            explanation = clearExplanation
        }
        items.append(item(requirement, verdict, explanation))
    }

    private static func appendWriterAuthority(
        to items: inout [LifecycleReadinessItem],
        session: AgentSession?,
        checkpoint: ProviderCheckpointRecord?,
        evidence: LifecycleWriterAuthorityEvidence?
    ) {
        guard let evidence else {
            items.append(item(
                .writerAuthority,
                .attemptMayFail,
                "The manager uses a separate App Server process and cannot predict whether the target writer is released. This is not verified clearance; the allow-listed one-shot Archive attempt may be rejected as Busy."
            ))
            return
        }

        guard let nativeSessionID = session?.nativeID,
              evidence.nativeSessionID == nativeSessionID,
              let checkpoint,
              evidence.runtimeVersion == checkpoint.runtimeVersion,
              !evidence.inventoryHash.isEmpty,
              evidence.inventoryHash == checkpoint.inventoryHash,
              evidence.observedAt >= checkpoint.refreshedAt
        else {
            items.append(item(
                .writerAuthority,
                .attemptMayFail,
                "Writer-clearance evidence does not match the exact native ID, runtime, inventory hash, and checkpoint, so it is not accepted as clearance. The allow-listed one-shot Archive attempt may be rejected as Busy."
            ))
            return
        }

        switch evidence.status {
        case .verifiedClear:
            items.append(item(
                .writerAuthority,
                .satisfied,
                evidence.explanation
            ))
        case .writerPresent:
            items.append(item(
                .writerAuthority,
                .blocked,
                evidence.explanation
            ))
        case .unavailable:
            items.append(item(
                .writerAuthority,
                .attemptMayFail,
                "\(evidence.explanation) This is not verified clearance; the allow-listed one-shot Archive attempt may be rejected as Busy."
            ))
        }
    }

    private static func item(
        _ requirement: LifecycleReadinessRequirement,
        _ verdict: LifecycleReadinessVerdict,
        _ explanation: String
    ) -> LifecycleReadinessItem {
        LifecycleReadinessItem(
            requirement: requirement,
            verdict: verdict,
            explanation: explanation
        )
    }
}
