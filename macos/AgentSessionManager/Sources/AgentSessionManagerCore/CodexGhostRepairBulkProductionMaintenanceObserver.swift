import Foundation

/// Fresh production observation used before an operation backup is admitted.
/// The operational gate runs before any source or SQLite read. The fixed raw
/// source fingerprint and mutation-authority rows must be stable across the
/// two fresh observations. They are not compared with the older Preview:
/// target-scoped revalidation after backup owns that separate decision.
actor CodexGhostRepairBulkProductionMaintenanceObserver:
    CodexGhostRepairBulkFreshMaintenanceObserving
{
    typealias FingerprintReader = @Sendable () throws
        -> CodexGhostRepairSnapshotCanonicalFingerprint
    typealias AuthorityReader = @Sendable (
        CodexGhostRepairBulkProductionBundle.Resolution
    ) throws -> CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    typealias SourceAdmission = @Sendable (
        CodexGhostRepairBulkProductionBundle.Resolution
    ) -> Bool

    private let profile: CodexGhostRepairSnapshotSourceProfile
    private let gateSource: any CodexGhostRepairExecutionGateSource
    private let fingerprintReader: FingerprintReader
    private let authorityReader: AuthorityReader
    private let sourceAdmission: SourceAdmission
    private let nowMilliseconds: @Sendable () -> Int64

    static func production(
        profile: CodexGhostRepairSnapshotSourceProfile
    ) -> Self {
        let source = CodexGhostRepairSnapshotCanonicalSource.production(
            profile: profile
        )
        return Self(
            profile: profile,
            gateSource: CodexGhostRepairSnapshotOperationalGateSource
                .production(),
            fingerprintReader: { try source.fingerprint() },
            authorityReader: { resolution in
                try Self.readAuthority(resolution: resolution)
            },
            sourceAdmission: { $0.acceptsLiveCodexRoot },
            nowMilliseconds: {
                Int64(Date().timeIntervalSince1970 * 1_000)
            }
        )
    }

    init(
        profile: CodexGhostRepairSnapshotSourceProfile,
        gateSource: any CodexGhostRepairExecutionGateSource,
        fingerprintReader: @escaping FingerprintReader,
        authorityReader: @escaping AuthorityReader,
        sourceAdmission: @escaping SourceAdmission = {
            $0.acceptsLiveCodexRoot
        },
        nowMilliseconds: @escaping @Sendable () -> Int64
    ) {
        self.profile = profile
        self.gateSource = gateSource
        self.fingerprintReader = fingerprintReader
        self.authorityReader = authorityReader
        self.sourceAdmission = sourceAdmission
        self.nowMilliseconds = nowMilliseconds
    }

    func observeFreshMaintenance(
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        phase _: CodexGhostRepairBulkMaintenanceCollectionPhase
    ) async throws -> CodexGhostRepairBulkFreshMaintenanceObservation {
        guard sourceAdmission(resolution),
              resolution.sourceLayoutIdentifier == profile.identifier else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk maintenance source profile changed."
            )
        }
        let gate = try await gateSource.ghostRepairExecutionGate()
        guard gate.isClear,
              gate.stateOpenHandleCount == 0,
              gate.threadHistoryOpenHandleCount == 0 else {
            throw CodexGhostRepairError.executionGateBlocked
        }
        let fingerprint = try fingerprintReader()
        try fingerprint.validateHash()
        guard fingerprint.sourceLayoutIdentifier == profile.identifier else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk maintenance source profile changed."
            )
        }
        let authority = try authorityReader(resolution)
        return CodexGhostRepairBulkFreshMaintenanceObservation(
            runtimeVersion: Self.runtimeVersion(profile: profile),
            executionGate: gate,
            sourceFingerprintHash: fingerprint.fingerprintHash,
            authorityDigest: try CodexGhostRepairHasher.hash(authority),
            observedAtMilliseconds: nowMilliseconds()
        )
    }

    private static func runtimeVersion(
        profile: CodexGhostRepairSnapshotSourceProfile
    ) -> String {
        switch profile.identifier {
        case CodexGhostRepairSnapshotSourceProfile.v1534DesktopV34.identifier:
            "0.153.4"
        case CodexGhostRepairSnapshotSourceProfile.v153DesktopV34.identifier:
            "0.153.2"
        case CodexGhostRepairSnapshotSourceProfile.v152DesktopV34.identifier:
            "0.152.1"
        case CodexGhostRepairSnapshotSourceProfile.v151DesktopV33.identifier:
            "0.151.0"
        default:
            "0.149.0"
        }
    }

    private static func readAuthority(
        resolution: CodexGhostRepairBulkProductionBundle.Resolution
    ) throws -> CodexGhostRepairSnapshotAnalysisAuthorityEvidence {
        let desktop = try CodexGhostRepairProductionSQLite(
            url: resolution.databaseURL(for: .desktop),
            readOnly: true
        )
        defer { desktop.close() }
        let metadataRows = try desktop.query(
            "SELECT * FROM local_thread_catalog_metadata WHERE id = 1",
            maximumRows: 2
        )
        let syncRows = try desktop.query(
            "SELECT * FROM local_thread_catalog_sync_state "
                + "WHERE host_id = 'local'",
            maximumRows: 2
        )
        guard metadataRows.count == 1,
              syncRows.count == 1,
              case let .integer(revision)? = metadataRows[0].value(
                  named: "catalog_revision"
              ),
              case let .integer(sequence)? = syncRows[0].value(
                  named: "observation_sequence"
              ) else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Bulk authority rows are unavailable."
            )
        }
        let metadata = try metadataRows[0].privacyPreserving(
            cleartextFields: CodexGhostRepairPrivacyContract.metadata
        )
        let sync = try syncRows[0].privacyPreserving(
            cleartextFields: CodexGhostRepairPrivacyContract.localSync
        )
        let watermark: Double?
        switch sync.value(named: "watermark_updated_at") {
        case let .integer(value): watermark = Double(value)
        case let .real(value): watermark = value
        case .null: watermark = nil
        default:
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Bulk authority watermark is invalid."
            )
        }
        return CodexGhostRepairSnapshotAnalysisAuthorityEvidence(
            catalogRevision: revision,
            observationSequence: sequence,
            watermarkUpdatedAt: watermark,
            metadataRowDigest: try CodexGhostRepairHasher.hash(metadata),
            localSyncRowDigest: try CodexGhostRepairHasher.hash(sync)
        )
    }
}
