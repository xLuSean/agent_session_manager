import Foundation

public enum ConflictResolutionAction: String, Codable, CaseIterable, Sendable {
    case acceptNativeRestore
    case reapplyTrashIntent
    case keepPending
    case acknowledgeExternalDeletion

    public var label: String {
        switch self {
        case .acceptNativeRestore: "Accept Native Restore"
        case .reapplyTrashIntent: "Reapply Trash Intent"
        case .keepPending: "Keep Pending"
        case .acknowledgeExternalDeletion: "Acknowledge External Deletion"
        }
    }

    public var summary: String {
        switch self {
        case .acceptNativeRestore:
            "Treat the provider's Active state as intentional and remove manager Trash membership."
        case .reapplyTrashIntent:
            "Keep manager Trash intent and archive the native session again through the provider lifecycle API."
        case .keepPending:
            "Keep the unresolved Trash membership and wait for stronger provider evidence."
        case .acknowledgeExternalDeletion:
            "After authoritative exact-ID absence readback, close the pending membership as externally deleted."
        }
    }

    public var changesManagerState: Bool {
        self == .acceptNativeRestore || self == .acknowledgeExternalDeletion
    }

    public var changesNativeState: Bool {
        self == .reapplyTrashIntent
    }
}

public enum ConflictResolutionReadiness: String, Codable, Sendable {
    case readyToApply
    case previewOnly
    case blocked

    public var label: String {
        switch self {
        case .readyToApply: "Ready to apply"
        case .previewOnly: "Preview only"
        case .blocked: "Blocked"
        }
    }
}

/// Operation-specific proof that a Codex task is absent. This is deliberately
/// separate from generic exact readback: the audited discriminator is accepted
/// only together with a complete inventory that omits the same exact ID.
public struct ExternalDeletionReadbackEvidence: Codable, Equatable, Sendable {
    public let provider: AgentSystem
    public let nativeSessionID: String
    public let runtimeVersion: String
    public let inventoryHash: String
    public let inventoryObservedAt: Date
    public let exactReadObservedAt: Date
    public let rpcCode: Int
    public let message: String

    public var provesAbsence: Bool {
        provider == .codex
            && rpcCode == -32600
            && message == "thread not loaded: \(nativeSessionID)"
            && exactReadObservedAt >= inventoryObservedAt
            && CodexAppServerProvider.supportsVerifiedExternalDeletionReadbackContract(
                runtimeVersion
            )
    }

    init(
        provider: AgentSystem,
        nativeSessionID: String,
        runtimeVersion: String,
        inventoryHash: String,
        inventoryObservedAt: Date,
        exactReadObservedAt: Date,
        rpcCode: Int,
        message: String
    ) {
        self.provider = provider
        self.nativeSessionID = nativeSessionID
        self.runtimeVersion = runtimeVersion
        self.inventoryHash = inventoryHash
        self.inventoryObservedAt = inventoryObservedAt
        self.exactReadObservedAt = exactReadObservedAt
        self.rpcCode = rpcCode
        self.message = message
    }
}

public struct ConflictResolutionOption: Identifiable, Codable, Equatable, Sendable {
    public let action: ConflictResolutionAction
    public let readiness: ConflictResolutionReadiness
    public let reason: String
    public let requiredEvidence: [String]

    public var id: ConflictResolutionAction { action }

    public init(
        action: ConflictResolutionAction,
        readiness: ConflictResolutionReadiness,
        reason: String,
        requiredEvidence: [String]
    ) {
        self.action = action
        self.readiness = readiness
        self.reason = reason
        self.requiredEvidence = requiredEvidence
    }
}

public struct ConflictResolutionPreview: Identifiable, Codable, Equatable, Sendable {
    public let provider: AgentSystem
    public let managerKey: String
    public let nativeSessionID: String
    public let title: String
    public let observedStatus: ReconciliationStatus
    public let observedNativeState: NativeSessionState?
    public let inventoryHash: String
    public let runtimeVersion: String?
    public let reconciledAt: Date
    public let exactReadback: ExactSessionReadbackEvidence?
    public let externalDeletionEvidence: ExternalDeletionReadbackEvidence?
    public let options: [ConflictResolutionOption]
    public let warnings: [String]

    public var id: String { managerKey }

    public init(
        provider: AgentSystem,
        managerKey: String,
        nativeSessionID: String,
        title: String,
        observedStatus: ReconciliationStatus,
        observedNativeState: NativeSessionState?,
        inventoryHash: String,
        runtimeVersion: String?,
        reconciledAt: Date,
        exactReadback: ExactSessionReadbackEvidence?,
        externalDeletionEvidence: ExternalDeletionReadbackEvidence? = nil,
        options: [ConflictResolutionOption],
        warnings: [String]
    ) {
        self.provider = provider
        self.managerKey = managerKey
        self.nativeSessionID = nativeSessionID
        self.title = title
        self.observedStatus = observedStatus
        self.observedNativeState = observedNativeState
        self.inventoryHash = inventoryHash
        self.runtimeVersion = runtimeVersion
        self.reconciledAt = reconciledAt
        self.exactReadback = exactReadback
        self.externalDeletionEvidence = externalDeletionEvidence
        self.options = options
        self.warnings = warnings
    }
}

public enum ConflictResolutionPlanningError: Error, Equatable, LocalizedError {
    case incompleteInventory
    case providerMismatch
    case identityMismatch
    case notAResolvableConflict(ReconciliationStatus)
    case inconsistentEvidence

    public var errorDescription: String? {
        switch self {
        case .incompleteInventory:
            "Conflict resolution Preview requires a complete provider inventory."
        case .providerMismatch:
            "Conflict evidence and checkpoint belong to different providers."
        case .identityMismatch:
            "Conflict evidence does not match the namespaced manager key."
        case let .notAResolvableConflict(status):
            "Reconciliation state \(status.rawValue) does not expose resolution options."
        case .inconsistentEvidence:
            "Reconciliation state and observed provider evidence are inconsistent."
        }
    }
}

/// Builds a read-only resolution proposal. It does not persist a Preview,
/// change Trash membership, or call a provider lifecycle method.
public enum ConflictResolutionPlanner {
    public static func preview(
        for state: ReconciledSessionState,
        checkpoint: ProviderCheckpointRecord,
        exactReadback: ExactSessionReadbackEvidence? = nil,
        externalDeletionEvidence: ExternalDeletionReadbackEvidence? = nil
    ) throws -> ConflictResolutionPreview {
        guard checkpoint.inventoryComplete else {
            throw ConflictResolutionPlanningError.incompleteInventory
        }
        guard let provider = state.liveSession?.system ?? state.trashMembership?.provider,
              provider == checkpoint.provider else {
            throw ConflictResolutionPlanningError.providerMismatch
        }
        let nativeID = state.liveSession?.nativeID ?? state.trashMembership?.nativeSessionID
        guard let nativeID,
              state.managerKey == "\(provider.rawValue):\(nativeID)" else {
            throw ConflictResolutionPlanningError.identityMismatch
        }
        if let live = state.liveSession,
           live.system != provider || live.nativeID != nativeID {
            throw ConflictResolutionPlanningError.identityMismatch
        }
        if let membership = state.trashMembership,
           membership.provider != provider
            || membership.nativeSessionID != nativeID
            || membership.managerKey != state.managerKey {
            throw ConflictResolutionPlanningError.identityMismatch
        }
        if let exactReadback,
           exactReadback.provider != provider
            || exactReadback.nativeSessionID != nativeID {
            throw ConflictResolutionPlanningError.identityMismatch
        }
        if let externalDeletionEvidence,
           externalDeletionEvidence.provider != provider
            || externalDeletionEvidence.nativeSessionID != nativeID
            || externalDeletionEvidence.runtimeVersion != checkpoint.runtimeVersion {
            throw ConflictResolutionPlanningError.identityMismatch
        }

        let options: [ConflictResolutionOption]
        switch state.status {
        case .nativeActiveTrashConflict:
            guard state.liveSession?.nativeState == .active,
                  state.trashMembership != nil else {
                throw ConflictResolutionPlanningError.inconsistentEvidence
            }
            options = activeTrashOptions(
                session: state.liveSession!,
                checkpoint: checkpoint
            )
        case .externallyMissing:
            guard state.trashMembership != nil,
                  state.liveSession == nil || state.liveSession?.nativeState == .absent else {
                throw ConflictResolutionPlanningError.inconsistentEvidence
            }
            options = externallyMissingOptions(
                exactReadback: exactReadback,
                externalDeletionEvidence: externalDeletionEvidence
            )
        case .active, .archive, .trash, .unavailable:
            throw ConflictResolutionPlanningError.notAResolvableConflict(state.status)
        }

        return ConflictResolutionPreview(
            provider: provider,
            managerKey: state.managerKey,
            nativeSessionID: nativeID,
            title: state.liveSession?.title
                ?? state.trashMembership?.titleAtEntry
                ?? "Unavailable session",
            observedStatus: state.status,
            observedNativeState: state.liveSession?.nativeState,
            inventoryHash: checkpoint.inventoryHash,
            runtimeVersion: checkpoint.runtimeVersion,
            reconciledAt: checkpoint.refreshedAt,
            exactReadback: exactReadback,
            externalDeletionEvidence: externalDeletionEvidence,
            options: options,
            warnings: [
                state.status == .nativeActiveTrashConflict
                    ? "Accept Native Restore changes only manager-owned Trash state. Reapply Trash Intent sends one official Archive request and preserves the existing manager Trash intent."
                    : "Acknowledge External Deletion changes only manager-owned Trash and Deleted state; no provider lifecycle request is sent.",
                "Apply uses a frozen confirmation token and fails closed if the provider checkpoint or Trash membership drifts.",
            ]
        )
    }

    private static func activeTrashOptions(
        session: AgentSession,
        checkpoint: ProviderCheckpointRecord
    ) -> [ConflictResolutionOption] {
        let runtimeAudited = CodexLifecycleMutationKind.archive.supports(
            runtimeVersion: checkpoint.runtimeVersion, binding: checkpoint.compatibilityBinding
        )
        let descendantsEligible = session.descendantCountKnown
            && session.descendantCount == 0
        let protectionEligible = !session.protection.blocksArchiveAttempt
        let reapplyReady = runtimeAudited && descendantsEligible && protectionEligible
        let reapplyReason: String
        if reapplyReady {
            reapplyReason = "The exact task is eligible for one official Archive attempt with fresh readback while the frozen manager Trash intent remains unchanged."
        } else if !runtimeAudited {
            reapplyReason = "The observed runtime is outside the audited official Archive contract."
        } else if !protectionEligible {
            reapplyReason = "Lifecycle protection evidence is incomplete or currently blocks Archive."
        } else {
            reapplyReason = "The descendant scope is unknown or non-empty."
        }
        return [
            ConflictResolutionOption(
                action: .acceptNativeRestore,
                readiness: .readyToApply,
                reason: "The complete inventory observed this exact session as Active. Apply can remove only the manager Trash membership and leave Codex unchanged.",
                requiredEvidence: [
                    "The same manager key remains Active at Apply time.",
                    "The provider checkpoint and Trash membership set have not drifted.",
                    "Removing membership is committed atomically and read back.",
                ]
            ),
            ConflictResolutionOption(
                action: .reapplyTrashIntent,
                readiness: reapplyReady ? .readyToApply : .blocked,
                reason: reapplyReason,
                requiredEvidence: [
                    "Pinned, running, current, and pinned-descendant protection are authoritative.",
                    "The provider supports archive through an official lifecycle API.",
                    "Archived state is confirmed by exact-ID readback before membership remains Trash.",
                ]
            ),
        ]
    }

    private static func externallyMissingOptions(
        exactReadback: ExactSessionReadbackEvidence?,
        externalDeletionEvidence: ExternalDeletionReadbackEvidence?
    ) -> [ConflictResolutionOption] {
        let acknowledgementReadiness: ConflictResolutionReadiness
        let acknowledgementReason: String
        switch (externalDeletionEvidence, exactReadback) {
        case let (evidence?, _) where evidence.provesAbsence:
            acknowledgementReadiness = .readyToApply
            acknowledgementReason = "A complete inventory and the audited exact-ID discriminator both prove this task is absent."
        case (_, let evidence?) where evidence.provesAbsence:
            acknowledgementReadiness = .previewOnly
            acknowledgementReason = "Generic exact-ID absence exists, but the operation-specific dual readback was not established."
        case (_, let evidence?) where evidence.provesExistence:
            acknowledgementReadiness = .blocked
            acknowledgementReason = "Official exact-ID readback found the session still exists, so it cannot be acknowledged as deleted."
        case (_, .some(_)), (_, nil):
            acknowledgementReadiness = .blocked
            acknowledgementReason = "The version-audited complete inventory plus exact-ID absence proof is unavailable."
        }
        return [
            ConflictResolutionOption(
                action: .keepPending,
                readiness: .previewOnly,
                reason: "Keeping pending makes no state change and preserves evidence for a later refresh.",
                requiredEvidence: [
                    "No additional evidence is required because this option performs no mutation."
                ]
            ),
            ConflictResolutionOption(
                action: .acknowledgeExternalDeletion,
                readiness: acknowledgementReadiness,
                reason: acknowledgementReason,
                requiredEvidence: [
                    "A complete fresh inventory omits the exact session ID.",
                    "A version-audited exact-ID read returns the expected not-loaded discriminator.",
                    "The provider checkpoint and Trash membership set have not drifted.",
                    "The membership closure and audit evidence are committed atomically and read back.",
                ]
            ),
        ]
    }
}
