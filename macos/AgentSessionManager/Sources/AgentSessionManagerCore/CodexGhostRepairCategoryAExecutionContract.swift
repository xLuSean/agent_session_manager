import Foundation

enum CodexGhostRepairCategoryAExecutionDraftBlocker:
    String,
    Codable,
    Equatable,
    Sendable
{
    case invalidPreview
    case previewExpired
    case categoryUnavailable
    case invalidDatabaseScope
    case invalidLogicalEffects
}

enum CodexGhostRepairCategoryAItemOutcome:
    String,
    Codable,
    Equatable,
    Sendable
{
    case success
    case alreadyAbsent
    case explicitFailure
    case unknown
    case notAttempted
}

enum CodexGhostRepairCategoryABatchOutcome:
    String,
    Codable,
    Equatable,
    Sendable
{
    case success
    case explicitFailure
    case unknown
    case notAttempted

    var itemOutcome: CodexGhostRepairCategoryAItemOutcome {
        switch self {
        case .success: .success
        case .explicitFailure: .explicitFailure
        case .unknown: .unknown
        case .notAttempted: .notAttempted
        }
    }
}

struct CodexGhostRepairCategoryADatabaseExpectation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let database: CodexGhostRepairProductionRepairDatabase
    let required: Bool
    let role: CodexGhostRepairProductionRepairDatabaseRole
    let admittedSchemaVersion: Int32?
}

struct CodexGhostRepairCategoryAItemChange:
    Codable,
    Equatable,
    Sendable
{
    let threadID: String
    let catalogRowDigest: String
    let effect: CodexGhostRepairSnapshotDryRunLogicalEffect
}

private struct CodexGhostRepairCategoryAExecutionDraftPayload:
    Codable,
    Equatable
{
    let operationID: UUID
    let sourcePreviewID: UUID
    let sourcePreviewDigest: String
    let sourceDryRunToken: String
    let snapshotReference: String
    let snapshotPublishedAtMilliseconds: Int64
    let snapshotSourceFingerprintHash: String
    let snapshotDestinationBindingHash: String
    let snapshotAcquisitionRecordHash: String
    let snapshotManifestHash: String
    let snapshotPublicationReceiptHash: String
    let sourceLayoutIdentifier: String
    let targetThreadIDs: [String]
    let itemChanges: [CodexGhostRepairCategoryAItemChange]
    let authorityAudit: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let databaseExpectations:
        [CodexGhostRepairCategoryADatabaseExpectation]
    let expectedBatchEffects:
        [CodexGhostRepairSnapshotDryRunLogicalEffect]
    let preparedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
}

/// Frozen, authority-free input for later M3 execution preparation.
///
/// This is not the final executable Preview: it intentionally has no execution
/// snapshot/backup binding, confirmation token, claim or mutation authority.
struct CodexGhostRepairCategoryAExecutionDraft:
    Codable,
    Equatable,
    Sendable
{
    let operationID: UUID
    let sourcePreviewID: UUID
    let sourcePreviewDigest: String
    let sourceDryRunToken: String
    let snapshotReference: String
    let snapshotPublishedAtMilliseconds: Int64
    let snapshotSourceFingerprintHash: String
    let snapshotDestinationBindingHash: String
    let snapshotAcquisitionRecordHash: String
    let snapshotManifestHash: String
    let snapshotPublicationReceiptHash: String
    let sourceLayoutIdentifier: String
    let targetThreadIDs: [String]
    let itemChanges: [CodexGhostRepairCategoryAItemChange]
    let authorityAudit: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let databaseExpectations:
        [CodexGhostRepairCategoryADatabaseExpectation]
    let expectedBatchEffects:
        [CodexGhostRepairSnapshotDryRunLogicalEffect]
    let preparedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let draftDigest: String

    var category: CodexGhostRepairCategory { .ordinary }
    var allOrNothing: Bool { true }
    var silentSelectionShrinkAllowed: Bool { false }
    var partialLogicalOutcomeAllowed: Bool { false }
    var requiresFreshExecutionSnapshotBinding: Bool { true }
    var requiresNewExactConfirmation: Bool { true }
    var filesystemAuthority: Bool { false }
    var opensSQLite: Bool { false }
    var createsBackup: Bool { false }
    var createsClaim: Bool { false }
    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }
    var automaticRetry: Bool { false }

    fileprivate init(
        operationID: UUID,
        sourcePreview: CodexGhostRepairSnapshotDryRunPreview,
        itemChanges: [CodexGhostRepairCategoryAItemChange],
        databaseExpectations:
            [CodexGhostRepairCategoryADatabaseExpectation],
        preparedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairCategoryAExecutionDraftPayload(
            operationID: operationID,
            sourcePreviewID: sourcePreview.previewID,
            sourcePreviewDigest: sourcePreview.previewDigest,
            sourceDryRunToken: sourcePreview.dryRunToken,
            snapshotReference:
                sourcePreview.snapshotIdentity.snapshotReference,
            snapshotPublishedAtMilliseconds:
                sourcePreview.snapshotIdentity.publishedAtMilliseconds,
            snapshotSourceFingerprintHash:
                sourcePreview.snapshotIdentity.sourceFingerprintHash,
            snapshotDestinationBindingHash:
                sourcePreview.snapshotIdentity.destinationBindingHash,
            snapshotAcquisitionRecordHash:
                sourcePreview.snapshotIdentity.acquisitionRecordHash,
            snapshotManifestHash:
                sourcePreview.snapshotIdentity.manifestHash,
            snapshotPublicationReceiptHash:
                sourcePreview.snapshotIdentity.publicationReceiptHash,
            sourceLayoutIdentifier: sourcePreview.sourceLayoutIdentifier,
            targetThreadIDs: sourcePreview.targetThreadIDs,
            itemChanges: itemChanges,
            authorityAudit: sourcePreview.authorityAudit,
            databaseExpectations: databaseExpectations,
            expectedBatchEffects: sourcePreview.expectedBatchEffects,
            preparedAtMilliseconds: preparedAtMilliseconds,
            expiresAtMilliseconds: sourcePreview.expiresAtMilliseconds
        )
        self.operationID = payload.operationID
        self.sourcePreviewID = payload.sourcePreviewID
        self.sourcePreviewDigest = payload.sourcePreviewDigest
        self.sourceDryRunToken = payload.sourceDryRunToken
        self.snapshotReference = payload.snapshotReference
        self.snapshotPublishedAtMilliseconds =
            payload.snapshotPublishedAtMilliseconds
        self.snapshotSourceFingerprintHash =
            payload.snapshotSourceFingerprintHash
        self.snapshotDestinationBindingHash =
            payload.snapshotDestinationBindingHash
        self.snapshotAcquisitionRecordHash =
            payload.snapshotAcquisitionRecordHash
        self.snapshotManifestHash = payload.snapshotManifestHash
        self.snapshotPublicationReceiptHash =
            payload.snapshotPublicationReceiptHash
        self.sourceLayoutIdentifier = payload.sourceLayoutIdentifier
        self.targetThreadIDs = payload.targetThreadIDs
        self.itemChanges = payload.itemChanges
        self.authorityAudit = payload.authorityAudit
        self.databaseExpectations = payload.databaseExpectations
        self.expectedBatchEffects = payload.expectedBatchEffects
        self.preparedAtMilliseconds = payload.preparedAtMilliseconds
        self.expiresAtMilliseconds = payload.expiresAtMilliseconds
        draftDigest = try CodexGhostRepairHasher.hash(payload)
    }

    func validateDigest() throws {
        let payload = CodexGhostRepairCategoryAExecutionDraftPayload(
            operationID: operationID,
            sourcePreviewID: sourcePreviewID,
            sourcePreviewDigest: sourcePreviewDigest,
            sourceDryRunToken: sourceDryRunToken,
            snapshotReference: snapshotReference,
            snapshotPublishedAtMilliseconds:
                snapshotPublishedAtMilliseconds,
            snapshotSourceFingerprintHash: snapshotSourceFingerprintHash,
            snapshotDestinationBindingHash: snapshotDestinationBindingHash,
            snapshotAcquisitionRecordHash: snapshotAcquisitionRecordHash,
            snapshotManifestHash: snapshotManifestHash,
            snapshotPublicationReceiptHash: snapshotPublicationReceiptHash,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            targetThreadIDs: targetThreadIDs,
            itemChanges: itemChanges,
            authorityAudit: authorityAudit,
            databaseExpectations: databaseExpectations,
            expectedBatchEffects: expectedBatchEffects,
            preparedAtMilliseconds: preparedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
        guard try CodexGhostRepairHasher.hash(payload) == draftDigest else {
            throw CodexGhostRepairError.invalidPlan(
                "Category A execution draft digest mismatch."
            )
        }
    }
}

enum CodexGhostRepairCategoryAExecutionDraftOutcome:
    Equatable,
    Sendable
{
    case draft(CodexGhostRepairCategoryAExecutionDraft)
    case blocked(CodexGhostRepairCategoryAExecutionDraftBlocker)
}

struct CodexGhostRepairCategoryAExecutionContractCapabilities:
    Equatable,
    Sendable
{
    let pureDeterministicFreezeAvailable = true
    let maximumTargetCount = 2
    let categoryAOnly = true
    let acceptsCallerPath = false
    let opensFilesystem = false
    let opensSQLite = false
    let persistsDraft = false
    let createsBackup = false
    let createsClaim = false
    let confirmationAuthority = false
    let repairMutationAuthority = false
    let automaticRetry = false
}

/// Pure M3b transformation from a valid M2 Preview to an authority-free draft.
enum CodexGhostRepairCategoryAExecutionContract {
    private static let maximumExecutionSnapshotAgeMilliseconds: Int64 =
        15 * 60 * 1_000

    static let capabilities =
        CodexGhostRepairCategoryAExecutionContractCapabilities()

    static func freeze(
        preview: CodexGhostRepairSnapshotDryRunPreview,
        operationID: UUID,
        observedAtMilliseconds: Int64
    ) -> CodexGhostRepairCategoryAExecutionDraftOutcome {
        do {
            try preview.validateForPersistence()
        } catch {
            return .blocked(.invalidPreview)
        }
        guard observedAtMilliseconds >= preview.generatedAtMilliseconds,
              observedAtMilliseconds < preview.expiresAtMilliseconds else {
            return .blocked(.previewExpired)
        }
        guard preview.snapshotIdentity.publishedAtMilliseconds
                <= observedAtMilliseconds,
              observedAtMilliseconds
                - preview.snapshotIdentity.publishedAtMilliseconds
                <= maximumExecutionSnapshotAgeMilliseconds else {
            return .blocked(.previewExpired)
        }
        guard preview.category == .ordinary,
              preview.liveCapability == .requiresMilestone3FreshAuthority,
              (1...capabilities.maximumTargetCount)
                .contains(preview.targetThreadIDs.count) else {
            return .blocked(.categoryUnavailable)
        }

        let schemaVersions = Dictionary(uniqueKeysWithValues:
            preview.databases.map { ($0.database, $0.schemaVersion) }
        )
        let expectations =
            CodexGhostRepairProductionRepairDatabase.allCases.map { database in
                CodexGhostRepairCategoryADatabaseExpectation(
                    database: database,
                    required: database.isRequired,
                    role: database.role,
                    admittedSchemaVersion: schemaVersion(
                        for: database,
                        schemaVersions: schemaVersions
                    )
                )
            }
        guard expectations.count == 5,
              expectations.filter(\.required).count == 4,
              expectations.filter({
                  $0.role == .futureSingleTransactionMutation
              }).map(\.database) == [.desktop],
              expectations.filter(\.required).allSatisfy({
                  $0.admittedSchemaVersion != nil
              }),
              expectations.first(where: {
                  $0.database == .legacyHistory
              })?.admittedSchemaVersion == nil else {
            return .blocked(.invalidDatabaseScope)
        }

        guard preview.items.allSatisfy({
                  $0.expectedLogicalEffects.count == 1
              }) else {
            return .blocked(.invalidLogicalEffects)
        }
        let itemChanges = preview.items.map { item in
            CodexGhostRepairCategoryAItemChange(
                threadID: item.threadID,
                catalogRowDigest: item.catalogRowDigest,
                effect: item.expectedLogicalEffects[0]
            )
        }
        let expectedItemEffects = zip(
            preview.targetThreadIDs,
            itemChanges
        ).allSatisfy { threadID, change in
            change.threadID == threadID
                && change.effect == .init(
                    kind: .removeCatalogRow,
                    threadID: threadID,
                    amount: 1
                )
        }
        let count = preview.targetThreadIDs.count
        guard expectedItemEffects,
              preview.expectedBatchEffects == [
                  .init(kind: .incrementCatalogRevision, amount: count),
                  .init(
                      kind: .incrementObservationSequence,
                      amount: count
                  ),
              ] else {
            return .blocked(.invalidLogicalEffects)
        }

        do {
            return .draft(try .init(
                operationID: operationID,
                sourcePreview: preview,
                itemChanges: itemChanges,
                databaseExpectations: expectations,
                preparedAtMilliseconds: observedAtMilliseconds
            ))
        } catch {
            return .blocked(.invalidPreview)
        }
    }

    private static func schemaVersion(
        for database: CodexGhostRepairProductionRepairDatabase,
        schemaVersions:
            [CodexGhostRepairSnapshotAnalysisDatabase: Int32]
    ) -> Int32? {
        switch database {
        case .desktop: schemaVersions[.desktop]
        case .summaries: schemaVersions[.summaries]
        case .state: schemaVersions[.state]
        case .threadHistory: schemaVersions[.threadHistory]
        case .legacyHistory: nil
        }
    }
}
