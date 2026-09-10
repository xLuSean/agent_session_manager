import Foundation

private struct CodexGhostRepairBulkLiveTargetRevalidationPayload:
    Codable,
    Hashable
{
    let formatVersion: Int
    let frozenSourceDigest: String
    let selectedThreadIDsDigest: String
    let alreadyAbsentThreadIDs: [String]
    let backupReceiptDigest: String
    let databaseEvidence: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let observedAtMilliseconds: Int64
}

private struct CodexGhostRepairBulkLiveTargetRevalidationV1Payload:
    Codable,
    Hashable
{
    let formatVersion: Int
    let frozenSourceDigest: String
    let selectedThreadIDsDigest: String
    let backupReceiptDigest: String
    let databaseEvidence: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let observedAtMilliseconds: Int64
}

/// Target-scoped live evidence captured after the exact operation backup.
/// It deliberately allows unrelated Codex rows to differ from the older
/// Snapshot while requiring every still-present selected row and side reference
/// to remain identical to the frozen Preview. A selected catalog row that is
/// already absent is preserved in the exact batch: ordinary sessions become
/// explicit no-ops, while automation sessions still retain their required
/// archive action.
struct CodexGhostRepairBulkLiveTargetRevalidation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    static let formatVersion = 2

    let formatVersion: Int
    let frozenSourceDigest: String
    let selectedThreadIDsDigest: String
    let alreadyAbsentThreadIDs: [String]
    let backupReceiptDigest: String
    let databaseEvidence: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let observedAtMilliseconds: Int64
    let revalidationDigest: String

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case frozenSourceDigest
        case selectedThreadIDsDigest
        case alreadyAbsentThreadIDs
        case backupReceiptDigest
        case databaseEvidence
        case authority
        case observedAtMilliseconds
        case revalidationDigest
    }

    init(
        source: CodexGhostRepairBulkFrozenPlanSource,
        backup: CodexGhostRepairBulkLiveBackupReceipt,
        databaseEvidence: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence],
        authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence,
        alreadyAbsentThreadIDs: [String],
        observedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairBulkLiveTargetRevalidationPayload(
            formatVersion: Self.formatVersion,
            frozenSourceDigest: source.sourceDigest,
            selectedThreadIDsDigest: try CodexGhostRepairHasher.hash(
                source.selectedThreadIDs
            ),
            alreadyAbsentThreadIDs: alreadyAbsentThreadIDs,
            backupReceiptDigest: backup.receiptDigest,
            databaseEvidence: databaseEvidence,
            authority: authority,
            observedAtMilliseconds: observedAtMilliseconds
        )
        formatVersion = payload.formatVersion
        frozenSourceDigest = payload.frozenSourceDigest
        selectedThreadIDsDigest = payload.selectedThreadIDsDigest
        self.alreadyAbsentThreadIDs = payload.alreadyAbsentThreadIDs
        backupReceiptDigest = payload.backupReceiptDigest
        self.databaseEvidence = payload.databaseEvidence
        self.authority = payload.authority
        self.observedAtMilliseconds = payload.observedAtMilliseconds
        revalidationDigest = try CodexGhostRepairHasher.hash(payload)
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        frozenSourceDigest = try container.decode(
            String.self,
            forKey: .frozenSourceDigest
        )
        selectedThreadIDsDigest = try container.decode(
            String.self,
            forKey: .selectedThreadIDsDigest
        )
        alreadyAbsentThreadIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .alreadyAbsentThreadIDs
        ) ?? []
        backupReceiptDigest = try container.decode(
            String.self,
            forKey: .backupReceiptDigest
        )
        databaseEvidence = try container.decode(
            [CodexGhostRepairSnapshotAnalysisDatabaseEvidence].self,
            forKey: .databaseEvidence
        )
        authority = try container.decode(
            CodexGhostRepairSnapshotAnalysisAuthorityEvidence.self,
            forKey: .authority
        )
        observedAtMilliseconds = try container.decode(
            Int64.self,
            forKey: .observedAtMilliseconds
        )
        revalidationDigest = try container.decode(
            String.self,
            forKey: .revalidationDigest
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(frozenSourceDigest, forKey: .frozenSourceDigest)
        try container.encode(
            selectedThreadIDsDigest,
            forKey: .selectedThreadIDsDigest
        )
        if formatVersion >= Self.formatVersion {
            try container.encode(
                alreadyAbsentThreadIDs,
                forKey: .alreadyAbsentThreadIDs
            )
        }
        try container.encode(
            backupReceiptDigest,
            forKey: .backupReceiptDigest
        )
        try container.encode(databaseEvidence, forKey: .databaseEvidence)
        try container.encode(authority, forKey: .authority)
        try container.encode(
            observedAtMilliseconds,
            forKey: .observedAtMilliseconds
        )
        try container.encode(revalidationDigest, forKey: .revalidationDigest)
    }

    func validate() throws {
        let validDigest: Bool
        if formatVersion == 1, alreadyAbsentThreadIDs.isEmpty {
            validDigest = try CodexGhostRepairHasher.hash(
                CodexGhostRepairBulkLiveTargetRevalidationV1Payload(
                    formatVersion: formatVersion,
                    frozenSourceDigest: frozenSourceDigest,
                    selectedThreadIDsDigest: selectedThreadIDsDigest,
                    backupReceiptDigest: backupReceiptDigest,
                    databaseEvidence: databaseEvidence,
                    authority: authority,
                    observedAtMilliseconds: observedAtMilliseconds
                )
            ) == revalidationDigest
        } else if formatVersion == Self.formatVersion {
            validDigest = try CodexGhostRepairHasher.hash(
                CodexGhostRepairBulkLiveTargetRevalidationPayload(
                    formatVersion: formatVersion,
                    frozenSourceDigest: frozenSourceDigest,
                    selectedThreadIDsDigest: selectedThreadIDsDigest,
                    alreadyAbsentThreadIDs: alreadyAbsentThreadIDs,
                    backupReceiptDigest: backupReceiptDigest,
                    databaseEvidence: databaseEvidence,
                    authority: authority,
                    observedAtMilliseconds: observedAtMilliseconds
                )
            ) == revalidationDigest
        } else {
            validDigest = false
        }
        guard [1, Self.formatVersion].contains(formatVersion),
              Self.isSHA256(frozenSourceDigest),
              Self.isSHA256(selectedThreadIDsDigest),
              alreadyAbsentThreadIDs == alreadyAbsentThreadIDs.sorted(),
              Set(alreadyAbsentThreadIDs).count
                == alreadyAbsentThreadIDs.count,
              alreadyAbsentThreadIDs.allSatisfy({ !$0.isEmpty }),
              alreadyAbsentThreadIDs.count
                <= CodexGhostRepairBulkPreview.maximumSelectedItems,
              Self.isSHA256(backupReceiptDigest),
              CodexGhostRepairDatabaseSchemaProfile.admitted(
                  databases: databaseEvidence
              ) != nil,
              databaseEvidence.allSatisfy({
                  $0.integrityCheckPassed && $0.foreignKeyViolationCount == 0
              }),
              Self.isSHA256(authority.metadataRowDigest),
              Self.isSHA256(authority.localSyncRowDigest),
              observedAtMilliseconds >= 0,
              Self.isSHA256(revalidationDigest),
              validDigest else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Live target revalidation evidence is invalid."
            )
        }
    }

    #if AGENT_SESSION_MANAGER_RESEARCH
    /// Deterministic test seam. Shipping code must obtain this evidence from
    /// `CodexGhostRepairBulkLiveTargetRevalidator`.
    static func frozenTestEvidence(
        source: CodexGhostRepairBulkFrozenPlanSource,
        backup: CodexGhostRepairBulkLiveBackupReceipt,
        alreadyAbsentThreadIDs: [String] = [],
        observedAtMilliseconds: Int64
    ) throws -> Self {
        try Self(
            source: source,
            backup: backup,
            databaseEvidence: source.databases,
            authority: source.authority,
            alreadyAbsentThreadIDs: alreadyAbsentThreadIDs,
            observedAtMilliseconds: observedAtMilliseconds
        )
    }
    #endif

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

/// Rebinds a frozen whole-batch selection to the current live authority after
/// a verified full backup. Global source differences since Preview are allowed;
/// target eligibility, category, side-reference, schema, or within-window byte
/// drift is rejected before a claim can exist.
actor CodexGhostRepairBulkLiveTargetRevalidator {
    typealias FingerprintReader = @Sendable () throws
        -> CodexGhostRepairSnapshotCanonicalFingerprint

    private let repairResolution:
        CodexGhostRepairProductionRepairBundle.Resolution
    private let gateSource: any CodexGhostRepairExecutionGateSource
    private let fingerprintReader: FingerprintReader
    private let nowMilliseconds: @Sendable () -> Int64

    static func production(
        profile: CodexGhostRepairSnapshotSourceProfile
    ) throws -> Self {
        let canonical = CodexGhostRepairSnapshotCanonicalSource.production(
            profile: profile
        )
        return try Self(
            repairResolution: CodexGhostRepairProductionRepairBundle
                .production().resolveForPreflight(),
            gateSource: CodexGhostRepairSnapshotOperationalGateSource
                .production(),
            fingerprintReader: { try canonical.fingerprint() },
            nowMilliseconds: {
                Int64(Date().timeIntervalSince1970 * 1_000)
            }
        )
    }

    init(
        repairResolution: CodexGhostRepairProductionRepairBundle.Resolution,
        gateSource: any CodexGhostRepairExecutionGateSource,
        fingerprintReader: @escaping FingerprintReader,
        nowMilliseconds: @escaping @Sendable () -> Int64
    ) throws {
        self.repairResolution = repairResolution
        self.gateSource = gateSource
        self.fingerprintReader = fingerprintReader
        self.nowMilliseconds = nowMilliseconds
    }

    func revalidate(
        storedPreview: CodexGhostRepairBulkStoredPreview,
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        verifiedBackup: CodexGhostRepairBulkLiveBackupReceipt
    ) async throws -> CodexGhostRepairBulkLiveTargetRevalidation {
        guard let frozen = storedPreview.frozenSource,
              frozen.sourceDigest == resolution.frozenSourceDigest,
              Self.sameDatabaseLayout(
                  bulk: resolution,
                  repair: repairResolution
              ) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Live target revalidation source is not exact."
            )
        }
        try verifiedBackup.validate()
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            throw CodexGhostRepairError.executionGateBlocked
        }
        let before = try fingerprintReader()
        try before.validateHash()
        guard before.sourceLayoutIdentifier == resolution.sourceLayoutIdentifier
        else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Live target revalidation source layout changed."
            )
        }
        if let changedFile = verifiedBackup.firstStableSourceMismatch(
            in: before
        ) {
            throw CodexGhostRepairError.targetDrift(
                "Stable Codex source member \(changedFile) no longer matches "
                    + "the verified backup."
            )
        }

        let selectedItems = frozen.selectedItems.map {
            CodexGhostRepairBulkBackupBoundOperationItem(frozen: $0)
        }
        try CodexGhostRepairFreshPinProtection.requireUnpinned(
            selectedItems.map(\.threadID), codexHomeURL: repairResolution.codexHomeURL
        )
        let observed = try CodexGhostRepairBulkLiveMixedMutator.inspect(
            selectedItems: selectedItems,
            resolution: repairResolution
        )
        if let mismatch = CodexGhostRepairBulkLiveMixedMutator
            .frozenTargetMismatch(
                observed,
                selectedItems: selectedItems,
                allowAlreadyAbsent: true
            ) {
            throw CodexGhostRepairError.targetDrift(
                mismatch
            )
        }

        let after = try fingerprintReader()
        try after.validateHash()
        guard after.sourceLayoutIdentifier == before.sourceLayoutIdentifier,
              after.sourceRootDigest == before.sourceRootDigest else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Live target revalidation source identity changed."
            )
        }
        if let changedFile = verifiedBackup.firstStableSourceMismatch(
            in: after
        ) {
            throw CodexGhostRepairError.targetDrift(
                "Stable Codex source member \(changedFile) changed during "
                    + "target inspection."
            )
        }
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            throw CodexGhostRepairError.executionGateBlocked
        }
        try CodexGhostRepairFreshPinProtection.requireUnpinned(
            selectedItems.map(\.threadID), codexHomeURL: repairResolution.codexHomeURL
        )
        return try CodexGhostRepairBulkLiveTargetRevalidation(
            source: frozen,
            backup: verifiedBackup,
            databaseEvidence: observed.databases,
            authority: observed.authority,
            alreadyAbsentThreadIDs: observed.items.compactMap {
                $0.catalogRowDigest == nil ? $0.threadID : nil
            },
            observedAtMilliseconds: nowMilliseconds()
        )
    }

    private static func sameDatabaseLayout(
        bulk: CodexGhostRepairBulkProductionBundle.Resolution,
        repair: CodexGhostRepairProductionRepairBundle.Resolution
    ) -> Bool {
        bulk.databaseURL(for: .desktop)
            == repair.databaseURL(for: .desktop)
            && bulk.databaseURL(for: .summaries)
                == repair.databaseURL(for: .summaries)
            && bulk.databaseURL(for: .state)
                == repair.databaseURL(for: .state)
            && bulk.databaseURL(for: .threadHistory)
                == repair.databaseURL(for: .threadHistory)
            && bulk.databaseURL(for: .legacyHistory)
                == repair.databaseURL(for: .legacyHistory)
    }

}
