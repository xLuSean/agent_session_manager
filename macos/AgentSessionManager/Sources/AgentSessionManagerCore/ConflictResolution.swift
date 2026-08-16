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
        exactReadback: ExactSessionReadbackEvidence? = nil
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

        let options: [ConflictResolutionOption]
        switch state.status {
        case .nativeActiveTrashConflict:
            guard state.liveSession?.nativeState == .active,
                  state.trashMembership != nil else {
                throw ConflictResolutionPlanningError.inconsistentEvidence
            }
            options = activeTrashOptions(protectionComplete: checkpoint.protectionComplete)
        case .externallyMissing:
            guard state.trashMembership != nil,
                  state.liveSession == nil || state.liveSession?.nativeState == .absent else {
                throw ConflictResolutionPlanningError.inconsistentEvidence
            }
            options = externallyMissingOptions(exactReadback: exactReadback)
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
            options: options,
            warnings: [
                state.status == .nativeActiveTrashConflict
                    ? "Accept Native Restore changes only manager-owned Trash state; no provider lifecycle request is sent."
                    : "Externally Missing resolution remains read-only in the current build.",
                "Apply uses a frozen confirmation token and fails closed if the provider checkpoint or Trash membership drifts.",
            ]
        )
    }

    private static func activeTrashOptions(
        protectionComplete: Bool
    ) -> [ConflictResolutionOption] {
        let reapplyReason = protectionComplete
            ? "Provider archive execution and exact readback are not enabled."
            : "Lifecycle protection evidence is incomplete, and provider archive execution is not enabled."
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
                readiness: .blocked,
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
        exactReadback: ExactSessionReadbackEvidence?
    ) -> [ConflictResolutionOption] {
        let acknowledgementReadiness: ConflictResolutionReadiness
        let acknowledgementReason: String
        switch exactReadback {
        case let evidence? where evidence.provesAbsence:
            acknowledgementReadiness = .previewOnly
            acknowledgementReason = "An official, version-compatible exact-ID readback proved absence; Apply is still not implemented."
        case let evidence? where evidence.provesExistence:
            acknowledgementReadiness = .blocked
            acknowledgementReason = "Official exact-ID readback found the session still exists, so it cannot be acknowledged as deleted."
        case .some, nil:
            acknowledgementReadiness = .blocked
            acknowledgementReason = "No documented authoritative exact-ID absence result is available."
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
                    "An official exact-ID lifecycle read confirms the session is absent.",
                    "The provider checkpoint and Trash membership set have not drifted.",
                    "The membership closure and audit evidence are committed atomically and read back.",
                ]
            ),
        ]
    }
}
