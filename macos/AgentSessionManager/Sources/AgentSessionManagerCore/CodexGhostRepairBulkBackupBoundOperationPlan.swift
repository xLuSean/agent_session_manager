import Foundation

struct CodexGhostRepairBulkBackupBoundOperationPlanCapabilities:
    Equatable,
    Sendable
{
    let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems
    let exactColdReadbackSourceRequired = true
    let exactProductionBundleRequired = true
    let exactVerifiedBackupRequired = true
    let mixedOrdinaryAndAutomation = true
    let allOrNothing = true
    let deterministicPersistencePayload = true
    let acceptsCallerPath = false
    let performsIO = false
    let opensSQLite = false
    let createsBackup = false
    let createsClaim = false
    let invokesMutator = false
    let appWiringAvailable = false
    let liveExecutionAuthorized = false
    let repairMutationAuthority = false
}

enum CodexGhostRepairBulkBackupBoundExpectedEffect:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case removeCatalogRow
    case removeCatalogRowAndArchiveAutomation
    case archiveAutomation
    case alreadyAbsent
}

struct CodexGhostRepairBulkBackupBoundOperationItem:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let threadID: String
    let category: CodexGhostRepairCategory
    let inventoryEvidenceDigest: String
    let catalogRowDigest: String?
    let automationRunRowDigest: String?
    let automationStableFieldsDigest: String?
    let automationDefinitionRowDigest: String?
    let expectedEffect: CodexGhostRepairBulkBackupBoundExpectedEffect
    var reviewedResidue: CodexGhostRepairReviewedSessionResidue? = nil

    init(
        frozen item: CodexGhostRepairBulkFrozenPlanSourceItem,
        alreadyAbsent: Bool = false
    ) {
        threadID = item.threadID
        category = item.category
        inventoryEvidenceDigest = item.inventoryEvidenceDigest
        catalogRowDigest = item.catalogRowDigest
        automationRunRowDigest = item.automationRunRowDigest
        automationStableFieldsDigest = item.automationStableFieldsDigest
        automationDefinitionRowDigest = item.automationDefinitionRowDigest
        reviewedResidue = item.reviewedResidue
        expectedEffect = if alreadyAbsent || item.catalogRowDigest == nil {
            item.category == .ordinary ? .alreadyAbsent : .archiveAutomation
        } else if item.category == .ordinary {
            .removeCatalogRow
        } else {
            .removeCatalogRowAndArchiveAutomation
        }
    }
}

private struct CodexGhostRepairBulkBackupBoundOperationPlanPayload:
    Codable,
    Hashable
{
    let formatVersion: Int
    let requestID: UUID
    let previewID: UUID
    let previewManifestDigest: String
    let previewPayloadHash: String
    let frozenSourceDigest: String
    let snapshotReference: String
    let snapshotManifestHash: String
    let sourceLayoutIdentifier: String
    let inventoryDigest: String
    let selectedItems: [CodexGhostRepairBulkBackupBoundOperationItem]
    let blockedOutsideBatchCount: Int
    let databaseEvidence: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let databaseContracts:
        [CodexGhostRepairBulkProductionBundleDatabaseContract]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let bundleDigest: String
    let destination: CodexGhostRepairBulkFixedBackupDestinationRecord
    let backup: CodexGhostRepairBulkLiveBackupReceipt
    let liveRevalidation: CodexGhostRepairBulkLiveTargetRevalidation
    let plannedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
}

/// Complete, path-free description of the planned whole-batch effect.
/// It joins the exact cold source, database bundle and durable
/// backup readback. The result is evidence only: it performs no I/O, creates no
/// claim, and cannot invoke the mixed mutator or the shipping App.
struct CodexGhostRepairBulkBackupBoundOperationPlan:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    static let formatVersion = 3

    let formatVersion: Int
    let requestID: UUID
    let previewID: UUID
    let previewManifestDigest: String
    let previewPayloadHash: String
    let frozenSourceDigest: String
    let snapshotReference: String
    let snapshotManifestHash: String
    let sourceLayoutIdentifier: String
    let inventoryDigest: String
    let selectedItems: [CodexGhostRepairBulkBackupBoundOperationItem]
    let blockedOutsideBatchCount: Int
    let databaseEvidence: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let databaseContracts:
        [CodexGhostRepairBulkProductionBundleDatabaseContract]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let bundleDigest: String
    let destination: CodexGhostRepairBulkFixedBackupDestinationRecord
    let backup: CodexGhostRepairBulkLiveBackupReceipt
    let liveRevalidation: CodexGhostRepairBulkLiveTargetRevalidation
    let plannedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let planDigest: String

    var selectedThreadIDs: [String] { selectedItems.map(\.threadID) }
    var selectedCount: Int { selectedItems.count }
    var ordinaryCount: Int {
        selectedItems.count { $0.category == .ordinary }
    }
    var automationCount: Int {
        selectedItems.count { $0.category == .automation }
    }
    var alreadyAbsentCount: Int {
        selectedItems.count {
            [.alreadyAbsent, .archiveAutomation].contains($0.expectedEffect)
        }
    }
    var actionableCount: Int {
        selectedItems.count { $0.expectedEffect != .alreadyAbsent }
    }
    var catalogDeletionCount: Int {
        selectedItems.count {
            [.removeCatalogRow, .removeCatalogRowAndArchiveAutomation]
                .contains($0.expectedEffect)
        }
    }
    var catalogRevisionIncrement: Int { catalogDeletionCount }
    var observationSequenceIncrement: Int { catalogDeletionCount }
    var allOrNothing: Bool { true }
    var silentSelectionShrinkAllowed: Bool { false }
    var pathRedacted: Bool { true }
    var createsClaim: Bool { false }
    var invokesMutator: Bool { false }
    var appWiringAvailable: Bool { false }
    var liveExecutionAuthorized: Bool { false }
    var repairMutationAuthority: Bool { false }

    static func prepare(
        coldReadback storedPreview: CodexGhostRepairBulkStoredPreview,
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        destination: CodexGhostRepairBulkFixedBackupDestinationRecord,
        verifiedBackup: CodexGhostRepairBulkLiveBackupReceipt,
        liveRevalidation: CodexGhostRepairBulkLiveTargetRevalidation,
        plannedAtMilliseconds: Int64
    ) throws -> Self {
        try storedPreview.preview.validateForPersistence()
        guard let source = storedPreview.frozenSource else {
            throw CodexGhostRepairError.invalidPlan(
                "M4f-16 requires the exact M4f-11 cold source."
            )
        }
        try source.validate(preview: storedPreview.preview)
        try destination.validate()
        try verifiedBackup.validate()

        let revalidation = liveRevalidation
        try revalidation.validate()
        let alreadyAbsent = Set(revalidation.alreadyAbsentThreadIDs)
        let selectedItems = source.selectedItems.map {
            CodexGhostRepairBulkBackupBoundOperationItem(
                frozen: $0,
                alreadyAbsent: alreadyAbsent.contains($0.threadID)
            )
        }
        guard storedPreview.requestID == resolution.requestID,
              storedPreview.preview.previewID == resolution.previewID,
              storedPreview.preview.manifestDigest
                == resolution.previewManifestDigest,
              source.sourceDigest == resolution.frozenSourceDigest,
              source.snapshotReference == resolution.snapshotReference,
              source.snapshotManifestHash
                == resolution.snapshotManifestHash,
              source.sourceLayoutIdentifier
                == resolution.sourceLayoutIdentifier,
              source.inventoryDigest == resolution.inventoryDigest,
              source.selectedThreadIDs == resolution.selectedThreadIDs,
              source.blockedOutsideBatchCount
                == resolution.blockedOutsideBatchCount,
              source.databases.map(\.database)
                == CodexGhostRepairSnapshotAnalysisDatabase.allCases,
              resolution.databaseContracts.map(\.database)
                == CodexGhostRepairBulkProductionDatabase.allCases,
              destination.requestID == resolution.requestID,
              destination.previewID == resolution.previewID,
              destination.bundleDigest == resolution.bundleDigest,
              destination.selectedCount == resolution.selectedCount,
              destination.ordinaryCount == resolution.ordinaryCount,
              destination.automationCount == resolution.automationCount,
              destination.blockedOutsideBatchCount
                == resolution.blockedOutsideBatchCount,
              verifiedBackup.destinationRecordDigest
                == destination.recordDigest,
              verifiedBackup.bundleDigest == resolution.bundleDigest,
              verifiedBackup.maintenanceWindowDigest
                == destination.maintenanceWindowDigest,
              verifiedBackup.capturedAtMilliseconds
                <= plannedAtMilliseconds,
              revalidation.frozenSourceDigest == source.sourceDigest,
              revalidation.backupReceiptDigest
                == verifiedBackup.receiptDigest,
              revalidation.selectedThreadIDsDigest
                == (try CodexGhostRepairHasher.hash(source.selectedThreadIDs)),
              Set(revalidation.alreadyAbsentThreadIDs).isSubset(
                of: Set(source.selectedThreadIDs)
              ),
              plannedAtMilliseconds >= storedPreview.preview.generatedAtMilliseconds,
              plannedAtMilliseconds
                < storedPreview.preview.expiresAtMilliseconds,
              Self.isSHA256(storedPreview.payloadHash),
              !storedPreview.confirmationAuthority,
              !storedPreview.repairMutationAuthority else {
            throw CodexGhostRepairError.authorityDrift
        }

        let payload = CodexGhostRepairBulkBackupBoundOperationPlanPayload(
            formatVersion: Self.formatVersion,
            requestID: storedPreview.requestID,
            previewID: storedPreview.preview.previewID,
            previewManifestDigest: storedPreview.preview.manifestDigest,
            previewPayloadHash: storedPreview.payloadHash,
            frozenSourceDigest: source.sourceDigest,
            snapshotReference: source.snapshotReference,
            snapshotManifestHash: source.snapshotManifestHash,
            sourceLayoutIdentifier: source.sourceLayoutIdentifier,
            inventoryDigest: source.inventoryDigest,
            selectedItems: selectedItems,
            blockedOutsideBatchCount: source.blockedOutsideBatchCount,
            databaseEvidence: revalidation.databaseEvidence,
            databaseContracts: resolution.databaseContracts,
            authority: revalidation.authority,
            bundleDigest: resolution.bundleDigest,
            destination: destination,
            backup: verifiedBackup,
            liveRevalidation: revalidation,
            plannedAtMilliseconds: plannedAtMilliseconds,
            expiresAtMilliseconds: storedPreview.preview.expiresAtMilliseconds
        )
        return try Self(payload: payload)
    }

    func encodedForPersistence() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decodeValidated(_ data: Data) throws -> Self {
        let plan = try JSONDecoder().decode(Self.self, from: data)
        try plan.validate()
        return plan
    }

    func validate() throws {
        try destination.validate()
        try backup.validate()
        try liveRevalidation.validate()
        let payload = CodexGhostRepairBulkBackupBoundOperationPlanPayload(
            formatVersion: formatVersion,
            requestID: requestID,
            previewID: previewID,
            previewManifestDigest: previewManifestDigest,
            previewPayloadHash: previewPayloadHash,
            frozenSourceDigest: frozenSourceDigest,
            snapshotReference: snapshotReference,
            snapshotManifestHash: snapshotManifestHash,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            inventoryDigest: inventoryDigest,
            selectedItems: selectedItems,
            blockedOutsideBatchCount: blockedOutsideBatchCount,
            databaseEvidence: databaseEvidence,
            databaseContracts: databaseContracts,
            authority: authority,
            bundleDigest: bundleDigest,
            destination: destination,
            backup: backup,
            liveRevalidation: liveRevalidation,
            plannedAtMilliseconds: plannedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
        guard [2, Self.formatVersion].contains(formatVersion),
              formatVersion == Self.formatVersion || alreadyAbsentCount == 0,
              (1...CodexGhostRepairBulkPreview.maximumSelectedItems)
                .contains(selectedCount),
              selectedThreadIDs == selectedThreadIDs.sorted(),
              Set(selectedThreadIDs).count == selectedThreadIDs.count,
              ordinaryCount + automationCount == selectedCount,
              selectedItems.allSatisfy(Self.validItem),
              blockedOutsideBatchCount >= 0,
              CodexGhostRepairDatabaseSchemaProfile.admitted(
                  databases: databaseEvidence
              ) != nil,
              databaseContracts.map(\.database)
                == CodexGhostRepairBulkProductionDatabase.allCases,
              databaseContracts.count == 5,
              databaseContracts.filter(\.required).count == 4,
              databaseContracts.filter({
                  $0.role == .futureSingleTransactionMutation
              }).map(\.database) == [.desktop],
              destination.requestID == requestID,
              destination.previewID == previewID,
              destination.bundleDigest == bundleDigest,
              destination.selectedCount == selectedCount,
              destination.ordinaryCount == ordinaryCount,
              destination.automationCount == automationCount,
              destination.blockedOutsideBatchCount
                == blockedOutsideBatchCount,
              backup.destinationRecordDigest == destination.recordDigest,
              backup.bundleDigest == bundleDigest,
              backup.maintenanceWindowDigest
                == destination.maintenanceWindowDigest,
              liveRevalidation.frozenSourceDigest == frozenSourceDigest,
              liveRevalidation.backupReceiptDigest == backup.receiptDigest,
              liveRevalidation.selectedThreadIDsDigest
                == (try CodexGhostRepairHasher.hash(selectedThreadIDs)),
              liveRevalidation.alreadyAbsentThreadIDs
                == selectedItems.compactMap({
                    [.alreadyAbsent, .archiveAutomation]
                        .contains($0.expectedEffect) ? $0.threadID : nil
                }),
              liveRevalidation.databaseEvidence == databaseEvidence,
              liveRevalidation.authority == authority,
              backup.capturedAtMilliseconds <= plannedAtMilliseconds,
              plannedAtMilliseconds < expiresAtMilliseconds,
              Self.isSHA256(previewManifestDigest),
              Self.isSHA256(previewPayloadHash),
              Self.isSHA256(frozenSourceDigest),
              Self.isSHA256(snapshotManifestHash),
              Self.isSHA256(inventoryDigest),
              Self.isSHA256(authority.metadataRowDigest),
              Self.isSHA256(authority.localSyncRowDigest),
              Self.isSHA256(bundleDigest),
              Self.isSHA256(planDigest),
              try CodexGhostRepairHasher.hash(payload) == planDigest,
              catalogRevisionIncrement == catalogDeletionCount,
              observationSequenceIncrement == catalogDeletionCount,
              allOrNothing,
              !silentSelectionShrinkAllowed,
              pathRedacted,
              !createsClaim,
              !invokesMutator,
              !appWiringAvailable,
              !liveExecutionAuthorized,
              !repairMutationAuthority else {
            throw CodexGhostRepairError.invalidPlan(
                "M4f-16 backup-bound operation plan is invalid."
            )
        }
    }

    private init(
        payload: CodexGhostRepairBulkBackupBoundOperationPlanPayload
    ) throws {
        formatVersion = payload.formatVersion
        requestID = payload.requestID
        previewID = payload.previewID
        previewManifestDigest = payload.previewManifestDigest
        previewPayloadHash = payload.previewPayloadHash
        frozenSourceDigest = payload.frozenSourceDigest
        snapshotReference = payload.snapshotReference
        snapshotManifestHash = payload.snapshotManifestHash
        sourceLayoutIdentifier = payload.sourceLayoutIdentifier
        inventoryDigest = payload.inventoryDigest
        selectedItems = payload.selectedItems
        blockedOutsideBatchCount = payload.blockedOutsideBatchCount
        databaseEvidence = payload.databaseEvidence
        databaseContracts = payload.databaseContracts
        authority = payload.authority
        bundleDigest = payload.bundleDigest
        destination = payload.destination
        backup = payload.backup
        liveRevalidation = payload.liveRevalidation
        plannedAtMilliseconds = payload.plannedAtMilliseconds
        expiresAtMilliseconds = payload.expiresAtMilliseconds
        planDigest = try CodexGhostRepairHasher.hash(payload)
        try validate()
    }

    private static func validItem(
        _ item: CodexGhostRepairBulkBackupBoundOperationItem
    ) -> Bool {
        if let scope = item.reviewedResidue {
            guard scope.isValid, item.expectedEffect != .alreadyAbsent,
                  !scope.pausedAutomation || item.category == .automation else { return false }
        }
        guard Self.isSHA256(item.inventoryEvidenceDigest),
              (Self.isSHA256(item.catalogRowDigest)
                || (item.catalogRowDigest == nil && item.category == .ordinary
                    && item.expectedEffect == .alreadyAbsent)) else { return false }
        switch item.category {
        case .ordinary:
            return [.removeCatalogRow, .alreadyAbsent]
                .contains(item.expectedEffect)
                && item.automationRunRowDigest == nil
                && item.automationStableFieldsDigest == nil
                && item.automationDefinitionRowDigest == nil
        case .automation:
            return [
                .removeCatalogRowAndArchiveAutomation,
                .archiveAutomation,
            ].contains(item.expectedEffect)
                && Self.isSHA256(item.automationRunRowDigest)
                && Self.isSHA256(item.automationStableFieldsDigest)
                && Self.isSHA256(item.automationDefinitionRowDigest)
        }
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value,
              value.hasPrefix("sha256:"),
              value == value.lowercased() else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}
