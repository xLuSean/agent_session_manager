import Foundation

struct CodexGhostRepairBulkFreshMaintenanceCollectorCapabilities:
    Equatable,
    Sendable
{
    let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems
    let exactBundleRequired = true
    let freshObservationPerCall = true
    let processEvidenceRequired = true
    let fiveDatabaseHandleOwnerEvidenceRequired = true
    let supportedRuntimeRequired = true
    let sourceFingerprintRequired = true
    let authorityDigestRequired = true
    let beforeAfterDriftRejected = true
    let acceptsCallerPath = false
    let acceptsLiveCodexRoot = false
    let createsBackup = false
    let createsClaim = false
    let opensSQLite = false
    let appWiringAvailable = false
    let automaticRetryAllowed = false
    let repairMutationAuthority = false
}

struct CodexGhostRepairBulkFreshMaintenanceObservation: Sendable {
    let runtimeVersion: String
    let executionGate: CodexGhostRepairExecutionGate
    let sourceFingerprintHash: String
    let authorityDigest: String
    let observedAtMilliseconds: Int64
}

protocol CodexGhostRepairBulkFreshMaintenanceObserving: Sendable {
    /// The backend receives only the already validated M4f-12 test-owned
    /// resolution. This research slice supplies no production factory.
    func observeFreshMaintenance(
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        phase: CodexGhostRepairBulkMaintenanceCollectionPhase
    ) async throws -> CodexGhostRepairBulkFreshMaintenanceObservation
}

private struct CodexGhostRepairBulkFreshMaintenanceReadbackPayload:
    Codable,
    Hashable
{
    let collectionID: UUID
    let phase: CodexGhostRepairBulkMaintenanceCollectionPhase
    let bundleDigest: String
    let requestID: UUID
    let previewID: UUID
    let selectedCount: Int
    let ordinaryCount: Int
    let automationCount: Int
    let blockedOutsideBatchCount: Int
    let selectedThreadIDsDigest: String
    let databaseContracts:
        [CodexGhostRepairBulkProductionBundleDatabaseContract]
    let maintenance: CodexGhostRepairBulkMaintenanceEvidence
}

struct CodexGhostRepairBulkFreshMaintenanceReadback:
    Equatable,
    Sendable
{
    let collectionID: UUID
    let phase: CodexGhostRepairBulkMaintenanceCollectionPhase
    let bundleDigest: String
    let requestID: UUID
    let previewID: UUID
    let selectedCount: Int
    let ordinaryCount: Int
    let automationCount: Int
    let blockedOutsideBatchCount: Int
    let selectedThreadIDsDigest: String
    let databaseContracts:
        [CodexGhostRepairBulkProductionBundleDatabaseContract]
    let maintenance: CodexGhostRepairBulkMaintenanceEvidence
    let readbackDigest: String

    var pathRedacted: Bool { true }
    var allOrNothing: Bool { true }
    var createsBackup: Bool { false }
    var createsClaim: Bool { false }
    var repairMutationAuthority: Bool { false }

    init(
        collectionID: UUID,
        phase: CodexGhostRepairBulkMaintenanceCollectionPhase,
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        maintenance: CodexGhostRepairBulkMaintenanceEvidence
    ) throws {
        let selectedThreadIDsDigest = try CodexGhostRepairHasher.hash(
            resolution.selectedThreadIDs
        )
        let payload = CodexGhostRepairBulkFreshMaintenanceReadbackPayload(
            collectionID: collectionID,
            phase: phase,
            bundleDigest: resolution.bundleDigest,
            requestID: resolution.requestID,
            previewID: resolution.previewID,
            selectedCount: resolution.selectedCount,
            ordinaryCount: resolution.ordinaryCount,
            automationCount: resolution.automationCount,
            blockedOutsideBatchCount: resolution.blockedOutsideBatchCount,
            selectedThreadIDsDigest: selectedThreadIDsDigest,
            databaseContracts: resolution.databaseContracts,
            maintenance: maintenance
        )
        self.collectionID = collectionID
        self.phase = phase
        bundleDigest = resolution.bundleDigest
        requestID = resolution.requestID
        previewID = resolution.previewID
        selectedCount = resolution.selectedCount
        ordinaryCount = resolution.ordinaryCount
        automationCount = resolution.automationCount
        blockedOutsideBatchCount = resolution.blockedOutsideBatchCount
        self.selectedThreadIDsDigest = selectedThreadIDsDigest
        databaseContracts = resolution.databaseContracts
        self.maintenance = maintenance
        readbackDigest = try CodexGhostRepairHasher.hash(payload)
        try validate()
    }

    func validate() throws {
        try maintenance.validate()
        let payload = CodexGhostRepairBulkFreshMaintenanceReadbackPayload(
            collectionID: collectionID,
            phase: phase,
            bundleDigest: bundleDigest,
            requestID: requestID,
            previewID: previewID,
            selectedCount: selectedCount,
            ordinaryCount: ordinaryCount,
            automationCount: automationCount,
            blockedOutsideBatchCount: blockedOutsideBatchCount,
            selectedThreadIDsDigest: selectedThreadIDsDigest,
            databaseContracts: databaseContracts,
            maintenance: maintenance
        )
        let expectedDatabases =
            CodexGhostRepairBulkProductionDatabase.allCases
        guard selectedCount > 0,
              selectedCount <= CodexGhostRepairBulkPreview.maximumSelectedItems,
              ordinaryCount >= 0,
              automationCount >= 0,
              ordinaryCount + automationCount == selectedCount,
              blockedOutsideBatchCount >= 0,
              databaseContracts.map(\.database) == expectedDatabases,
              databaseContracts.count == 5,
              databaseContracts.filter(\.required).count == 4,
              maintenance.executionGate.stateOpenHandleCount != nil,
              maintenance.executionGate.threadHistoryOpenHandleCount != nil,
              Self.isSHA256(bundleDigest),
              Self.isSHA256(selectedThreadIDsDigest),
              Self.isSHA256(readbackDigest),
              try CodexGhostRepairHasher.hash(payload) == readbackDigest,
              pathRedacted,
              allOrNothing,
              !createsBackup,
              !createsClaim,
              !repairMutationAuthority else {
            throw CodexGhostRepairError.executionGateBlocked
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

private struct CodexGhostRepairBulkMaintenanceWindowPayload:
    Codable,
    Hashable
{
    let bundleDigest: String
    let sourceFingerprintHash: String
    let authorityDigest: String
    let runtimeVersion: String
}

/// Exact before/after identity used by the next backup slice. It grants no
/// authority and exists only when the same bundle, runtime, source and
/// authority survived two fresh clear observations.
struct CodexGhostRepairBulkMaintenanceWindow:
    Equatable,
    Sendable
{
    let bundleDigest: String
    let before: CodexGhostRepairBulkFreshMaintenanceReadback
    let after: CodexGhostRepairBulkFreshMaintenanceReadback
    let windowDigest: String

    var driftDetected: Bool { false }
    var createsBackup: Bool { false }
    var createsClaim: Bool { false }
    var repairMutationAuthority: Bool { false }

    init(
        before: CodexGhostRepairBulkFreshMaintenanceReadback,
        after: CodexGhostRepairBulkFreshMaintenanceReadback
    ) throws {
        try before.validate()
        try after.validate()
        guard before.phase == .beforeBackup,
              (after.phase == .afterBackup
                || after.phase == .beforeBackupRepeat),
              before.bundleDigest == after.bundleDigest,
              before.requestID == after.requestID,
              before.previewID == after.previewID,
              before.selectedCount == after.selectedCount,
              before.ordinaryCount == after.ordinaryCount,
              before.automationCount == after.automationCount,
              before.blockedOutsideBatchCount
                == after.blockedOutsideBatchCount,
              before.selectedThreadIDsDigest
                == after.selectedThreadIDsDigest,
              before.databaseContracts == after.databaseContracts,
              before.maintenance.runtimeVersion
                == after.maintenance.runtimeVersion,
              before.maintenance.sourceFingerprintHash
                == after.maintenance.sourceFingerprintHash,
              before.maintenance.authorityDigest
                == after.maintenance.authorityDigest,
              before.maintenance.observedAtMilliseconds
                <= after.maintenance.observedAtMilliseconds else {
            throw CodexGhostRepairError.authorityDrift
        }
        let payload = CodexGhostRepairBulkMaintenanceWindowPayload(
            bundleDigest: before.bundleDigest,
            sourceFingerprintHash:
                before.maintenance.sourceFingerprintHash,
            authorityDigest: before.maintenance.authorityDigest,
            runtimeVersion: before.maintenance.runtimeVersion
        )
        bundleDigest = before.bundleDigest
        self.before = before
        self.after = after
        windowDigest = try CodexGhostRepairHasher.hash(payload)
        guard !driftDetected,
              !createsBackup,
              !createsClaim,
              !repairMutationAuthority else {
            throw CodexGhostRepairError.authorityDrift
        }
    }
}

/// M4f-13's repeatable, fresh, test-owned collector. Every explicit call asks
/// the injected backend for a new observation; it never caches a green gate.
actor CodexGhostRepairBulkFreshMaintenanceCollector {
    nonisolated let capabilities =
        CodexGhostRepairBulkFreshMaintenanceCollectorCapabilities()

    private let resolution:
        CodexGhostRepairBulkProductionBundle.Resolution
    private let observer: any CodexGhostRepairBulkFreshMaintenanceObserving
    private let collectionID: @Sendable () -> UUID
    private var collectionInProgress = false

    init(
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        observer: any CodexGhostRepairBulkFreshMaintenanceObserving,
        collectionID: @escaping @Sendable () -> UUID = { UUID() }
    ) throws {
        guard resolution.selectedCount > 0,
              resolution.selectedCount
                <= CodexGhostRepairBulkPreview.maximumSelectedItems,
              resolution.databaseContracts.map(\.database)
                == CodexGhostRepairBulkProductionDatabase.allCases,
              !resolution.createsBackup,
              !resolution.createsClaim,
              !resolution.repairMutationAuthority else {
            throw CodexGhostRepairError.invalidPlan(
                "Fresh maintenance requires an exact M4f-12 bundle."
            )
        }
        self.resolution = resolution
        self.observer = observer
        self.collectionID = collectionID
    }

    func collectFresh(
        phase: CodexGhostRepairBulkMaintenanceCollectionPhase
    ) async throws -> CodexGhostRepairBulkFreshMaintenanceReadback {
        guard !collectionInProgress else {
            throw CodexGhostRepairError.recoveryRequired
        }
        collectionInProgress = true
        defer { collectionInProgress = false }

        let observation = try await observer.observeFreshMaintenance(
            resolution: resolution,
            phase: phase
        )
        guard let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
                  sourceLayoutIdentifier: resolution.sourceLayoutIdentifier
              ),
              profile.supports(runtimeVersion: observation.runtimeVersion)
        else {
            throw CodexGhostRepairError.executionGateBlocked
        }
        let maintenance = try CodexGhostRepairBulkMaintenanceEvidence(
            runtimeVersion: observation.runtimeVersion,
            executionGate: observation.executionGate,
            sourceFingerprintHash: observation.sourceFingerprintHash,
            authorityDigest: observation.authorityDigest,
            observedAtMilliseconds: observation.observedAtMilliseconds
        )
        guard observation.executionGate.stateOpenHandleCount != nil,
              observation.executionGate.threadHistoryOpenHandleCount != nil
        else {
            throw CodexGhostRepairError.executionGateBlocked
        }
        return try CodexGhostRepairBulkFreshMaintenanceReadback(
            collectionID: collectionID(),
            phase: phase,
            resolution: resolution,
            maintenance: maintenance
        )
    }
}
