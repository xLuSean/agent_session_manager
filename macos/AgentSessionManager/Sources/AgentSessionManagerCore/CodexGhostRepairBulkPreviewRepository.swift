import CryptoKit
import CSQLite3
import Foundation

struct CodexGhostRepairBulkPreviewPersistedPayload:
    Codable,
    Hashable
{
    let requestID: UUID
    let preview: CodexGhostRepairBulkPreview
}

struct CodexGhostRepairBulkPreviewPersistedRow {
    let previewID: UUID
    let snapshotReference: String
    let inventoryDigest: String
    let manifestDigest: String
    let generatedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let selectedCount: Int
    let blockedCount: Int
    let unselectedEligibleCount: Int
    let encodedPayload: String
    let payloadHash: String
    let confirmationAuthority: Int64
    let repairMutationAuthority: Int64

    func decodeValidated(
        requestID: UUID
    ) throws -> CodexGhostRepairBulkStoredPreview {
        guard payloadHash == SQLiteStateStore.hashBulkPreviewPayload(
            encodedPayload
        ) else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview payload hash does not match."
            )
        }
        let payload: CodexGhostRepairBulkPreviewPersistedPayload =
            try SQLiteStateStore.decodeBulkPreviewPayload(encodedPayload)
        try payload.preview.validateForPersistence()
        guard payload.requestID == requestID,
              payload.preview.previewID == previewID,
              payload.preview.snapshotReference == snapshotReference,
              payload.preview.inventoryDigest == inventoryDigest,
              payload.preview.manifestDigest == manifestDigest,
              payload.preview.generatedAtMilliseconds
                == generatedAtMilliseconds,
              payload.preview.expiresAtMilliseconds
                == expiresAtMilliseconds,
              payload.preview.selectedItems.count == selectedCount,
              payload.preview.blockedItems.count == blockedCount,
              payload.preview.unselectedEligibleThreadIDs.count
                == unselectedEligibleCount,
              confirmationAuthority == 0,
              repairMutationAuthority == 0 else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview columns and payload disagree."
            )
        }
        return .init(
            requestID: requestID,
            preview: payload.preview,
            payloadHash: payloadHash,
            frozenSource: nil
        )
    }
}

private struct CodexGhostRepairBulkFrozenPlanSourcePersistedPayload:
    Codable,
    Hashable
{
    let requestID: UUID
    let source: CodexGhostRepairBulkFrozenPlanSource
}

private struct CodexGhostRepairBulkFrozenPlanSourcePayload:
    Encodable,
    Hashable
{
    let previewID: UUID
    let previewManifestDigest: String
    let snapshotReference: String
    let sourceLayoutIdentifier: String
    let sourceFingerprintHash: String
    let snapshotManifestHash: String
    let inventoryDigest: String
    let selectedItems: [CodexGhostRepairBulkFrozenPlanSourceItem]
    let blockedOutsideBatchCount: Int
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
}

struct CodexGhostRepairBulkFrozenPlanSourceItem:
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
    var reviewedResidue: CodexGhostRepairReviewedSessionResidue? = nil

    var exposesPrivateRowValues: Bool { false }
}

/// Privacy-safe, selected-only mutation evidence frozen at the same moment as
/// the public Preview. It is manager-owned evidence, not a claim or mutation
/// authority, and contains no raw row values, paths or conversation content.
struct CodexGhostRepairBulkFrozenPlanSource:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let previewID: UUID
    let previewManifestDigest: String
    let snapshotReference: String
    let sourceLayoutIdentifier: String
    let sourceFingerprintHash: String
    let snapshotManifestHash: String
    let inventoryDigest: String
    let selectedItems: [CodexGhostRepairBulkFrozenPlanSourceItem]
    let blockedOutsideBatchCount: Int
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let sourceDigest: String

    var selectedThreadIDs: [String] { selectedItems.map(\.threadID) }
    var selectedCount: Int { selectedItems.count }
    var storesFullObservedCatalog: Bool { false }
    var exposesPrivateRowValues: Bool { false }
    var acceptsCallerPath: Bool { false }
    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }

    fileprivate init(
        previewID: UUID,
        previewManifestDigest: String,
        snapshotReference: String,
        sourceLayoutIdentifier: String,
        sourceFingerprintHash: String,
        snapshotManifestHash: String,
        inventoryDigest: String,
        selectedItems: [CodexGhostRepairBulkFrozenPlanSourceItem],
        blockedOutsideBatchCount: Int,
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence],
        authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    ) throws {
        let payload = CodexGhostRepairBulkFrozenPlanSourcePayload(
            previewID: previewID,
            previewManifestDigest: previewManifestDigest,
            snapshotReference: snapshotReference,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            sourceFingerprintHash: sourceFingerprintHash,
            snapshotManifestHash: snapshotManifestHash,
            inventoryDigest: inventoryDigest,
            selectedItems: selectedItems,
            blockedOutsideBatchCount: blockedOutsideBatchCount,
            databases: databases,
            authority: authority
        )
        self.previewID = previewID
        self.previewManifestDigest = previewManifestDigest
        self.snapshotReference = snapshotReference
        self.sourceLayoutIdentifier = sourceLayoutIdentifier
        self.sourceFingerprintHash = sourceFingerprintHash
        self.snapshotManifestHash = snapshotManifestHash
        self.inventoryDigest = inventoryDigest
        self.selectedItems = selectedItems
        self.blockedOutsideBatchCount = blockedOutsideBatchCount
        self.databases = databases
        self.authority = authority
        sourceDigest = try CodexGhostRepairHasher.hash(payload)
    }

    func validate(preview: CodexGhostRepairBulkPreview) throws {
        let rebuilt = try Self(
            previewID: previewID,
            previewManifestDigest: previewManifestDigest,
            snapshotReference: snapshotReference,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            sourceFingerprintHash: sourceFingerprintHash,
            snapshotManifestHash: snapshotManifestHash,
            inventoryDigest: inventoryDigest,
            selectedItems: selectedItems,
            blockedOutsideBatchCount: blockedOutsideBatchCount,
            databases: databases,
            authority: authority
        )
        let previewByID = Dictionary(
            uniqueKeysWithValues: preview.selectedItems.map { ($0.threadID, $0) }
        )
        guard rebuilt.sourceDigest == sourceDigest,
              previewID == preview.previewID,
              previewManifestDigest == preview.manifestDigest,
              snapshotReference == preview.snapshotReference,
              sourceLayoutIdentifier == preview.sourceLayoutIdentifier,
              inventoryDigest == preview.inventoryDigest,
              blockedOutsideBatchCount == preview.blockedItems.count,
              selectedThreadIDs == preview.selectedThreadIDs,
              selectedThreadIDs == selectedThreadIDs.sorted(),
              Set(selectedThreadIDs).count == selectedThreadIDs.count,
              (1...CodexGhostRepairBulkPreview.maximumSelectedItems)
                .contains(selectedItems.count),
              Self.isSHA256(sourceFingerprintHash),
              Self.isSHA256(snapshotManifestHash),
              Self.isSHA256(sourceDigest),
              CodexGhostRepairDatabaseSchemaProfile.admitted(
                  databases: databases
              ) != nil,
              Self.isSHA256(authority.metadataRowDigest),
              Self.isSHA256(authority.localSyncRowDigest),
              selectedItems.allSatisfy({ item in
                  guard let previewItem = previewByID[item.threadID],
                        previewItem.category == item.category,
                        previewItem.reviewedResidue == item.reviewedResidue,
                        previewItem.evidenceDigest
                            == item.inventoryEvidenceDigest,
                        Self.isSHA256(item.inventoryEvidenceDigest),
                        (previewItem.initiallyAbsent == true
                            ? item.catalogRowDigest == nil && item.category == .ordinary
                            : Self.isSHA256(item.catalogRowDigest)) else {
                      return false
                  }
                  switch item.category {
                  case .ordinary:
                      return item.automationRunRowDigest == nil
                          && item.automationStableFieldsDigest == nil
                          && item.automationDefinitionRowDigest == nil
                  case .automation:
                      return Self.isSHA256(item.automationRunRowDigest)
                          && Self.isSHA256(
                              item.automationStableFieldsDigest
                          )
                          && Self.isSHA256(
                              item.automationDefinitionRowDigest
                          )
                  }
              }) else {
            throw PersistentStateError.invalidRecord(
                "Bulk frozen plan source does not match the exact Preview."
            )
        }
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("sha256:"),
              value == value.lowercased() else { return false }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }

    private enum CodingKeys: String, CodingKey {
        case previewID
        case previewManifestDigest
        case snapshotReference
        case sourceLayoutIdentifier
        case sourceFingerprintHash
        case snapshotManifestHash
        case inventoryDigest
        case selectedItems
        case blockedOutsideBatchCount
        case databases
        case authority
        case sourceDigest
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let suppliedDigest = try values.decode(
            String.self,
            forKey: .sourceDigest
        )
        try self.init(
            previewID: values.decode(UUID.self, forKey: .previewID),
            previewManifestDigest: values.decode(
                String.self,
                forKey: .previewManifestDigest
            ),
            snapshotReference: values.decode(
                String.self,
                forKey: .snapshotReference
            ),
            sourceLayoutIdentifier: values.decode(
                String.self,
                forKey: .sourceLayoutIdentifier
            ),
            sourceFingerprintHash: values.decode(
                String.self,
                forKey: .sourceFingerprintHash
            ),
            snapshotManifestHash: values.decode(
                String.self,
                forKey: .snapshotManifestHash
            ),
            inventoryDigest: values.decode(
                String.self,
                forKey: .inventoryDigest
            ),
            selectedItems: values.decode(
                [CodexGhostRepairBulkFrozenPlanSourceItem].self,
                forKey: .selectedItems
            ),
            blockedOutsideBatchCount: values.decode(
                Int.self,
                forKey: .blockedOutsideBatchCount
            ),
            databases: values.decode(
                [CodexGhostRepairSnapshotAnalysisDatabaseEvidence].self,
                forKey: .databases
            ),
            authority: values.decode(
                CodexGhostRepairSnapshotAnalysisAuthorityEvidence.self,
                forKey: .authority
            )
        )
        guard sourceDigest == suppliedDigest else {
            throw PersistentStateError.invalidRecord(
                "Bulk frozen plan source digest does not match."
            )
        }
    }
}

enum CodexGhostRepairBulkFrozenPlanSourceBuilder {
    static func build(
        inventory: CodexGhostRepairBulkInventory,
        preview: CodexGhostRepairBulkPreview
    ) throws -> CodexGhostRepairBulkFrozenPlanSource {
        try preview.validateForPersistence()
        guard let input = inventory.sourceEvidence else {
            throw PersistentStateError.invalidRecord(
                "Bulk inventory does not carry exact source evidence."
            )
        }
        let rebuilt = try CodexGhostRepairBulkInventoryBuilder.build(
            input: input
        )
        guard rebuilt == inventory,
              inventory.snapshotReference == preview.snapshotReference,
              inventory.sourceLayoutIdentifier
                == preview.sourceLayoutIdentifier,
              inventory.inventoryDigest == preview.inventoryDigest else {
            throw PersistentStateError.invalidRecord(
                "Bulk inventory source drifted before Preview persistence."
            )
        }
        let targets = Dictionary(
            uniqueKeysWithValues: input.targets.map { ($0.threadID, $0) }
        )
        let items = try preview.selectedItems.map { previewItem in
            guard let target = targets[previewItem.threadID],
                  (previewItem.initiallyAbsent == true
                    ? target.hasNoResidue : target.catalogRowDigests.count == 1),
                  target.references.total == (previewItem.reviewedResidue?.summaryRowDigests.count ?? 0),
                  target.references.summaries == (previewItem.reviewedResidue?.summaryRowDigests.count ?? 0),
                  (previewItem.reviewedResidue == nil
                    || (previewItem.reviewedResidue?.summaryRowDigests == (target.summaryRowDigests ?? [])
                        && previewItem.reviewedResidue?.pausedAutomation == (target.pausedAutomationReviewable == true))) else {
                throw PersistentStateError.invalidRecord(
                    "Bulk selected source evidence is incomplete."
                )
            }
            switch previewItem.category {
            case .ordinary:
                guard (target.rowContract == .categoryAEligible || (previewItem.initiallyAbsent == true && target.hasNoResidue)),
                      target.automationRunRowDigests.isEmpty,
                      target.automationStableFieldsDigests.isEmpty,
                      target.automationDefinitionRowDigests.isEmpty else {
                    throw PersistentStateError.invalidRecord(
                        "Bulk ordinary source evidence is invalid."
                    )
                }
            case .automation:
                guard (target.rowContract == .categoryBEligible
                        || (target.pausedAutomationReviewable == true && previewItem.reviewedResidue?.pausedAutomation == true)),
                      target.automationRunRowDigests.count == 1,
                      target.automationStableFieldsDigests.count == 1,
                      target.automationDefinitionRowDigests.count == 1 else {
                    throw PersistentStateError.invalidRecord(
                        "Bulk automation source evidence is invalid."
                    )
                }
            }
            var result = CodexGhostRepairBulkFrozenPlanSourceItem(
                threadID: previewItem.threadID,
                category: previewItem.category,
                inventoryEvidenceDigest: previewItem.evidenceDigest,
                catalogRowDigest: target.catalogRowDigests.first,
                automationRunRowDigest: target.automationRunRowDigests.first,
                automationStableFieldsDigest:
                    target.automationStableFieldsDigests.first,
                automationDefinitionRowDigest:
                    target.automationDefinitionRowDigests.first
            )
            result.reviewedResidue = previewItem.reviewedResidue
            return result
        }
        let source = try CodexGhostRepairBulkFrozenPlanSource(
            previewID: preview.previewID,
            previewManifestDigest: preview.manifestDigest,
            snapshotReference: input.snapshotReference,
            sourceLayoutIdentifier: input.sourceLayoutIdentifier,
            sourceFingerprintHash: input.sourceFingerprintHash,
            snapshotManifestHash: input.manifestHash,
            inventoryDigest: inventory.inventoryDigest,
            selectedItems: items,
            blockedOutsideBatchCount: preview.blockedItems.count,
            databases: input.databases,
            authority: input.authority
        )
        try source.validate(preview: preview)
        return source
    }
}

struct CodexGhostRepairBulkStoredPreview: Hashable, Sendable {
    let requestID: UUID
    let preview: CodexGhostRepairBulkPreview
    let payloadHash: String
    let frozenSource: CodexGhostRepairBulkFrozenPlanSource?

    var persistsPreview: Bool { true }
    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }
}

public struct CodexGhostRepairBulkPreviewPersistenceReceipt:
    Codable,
    Hashable,
    Sendable
{
    public let requestID: UUID
    public let previewID: UUID
    public let payloadHash: String
    public let frozenSourceDigest: String?
    public let durableReadbackMatched: Bool

    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public init(
        requestID: UUID,
        previewID: UUID,
        payloadHash: String,
        frozenSourceDigest: String? = nil,
        durableReadbackMatched: Bool
    ) {
        self.requestID = requestID
        self.previewID = previewID
        self.payloadHash = payloadHash
        self.frozenSourceDigest = frozenSourceDigest
        self.durableReadbackMatched = durableReadbackMatched
    }
}

public struct CodexGhostRepairBulkPreviewReadbackEvidence:
    Codable,
    Hashable,
    Sendable
{
    public let requestID: UUID
    public let preview: CodexGhostRepairBulkPreview
    public let payloadHash: String
    public let frozenSourceDigest: String?
    public let durableReadbackMatched: Bool

    public var readsManagerOwnedState: Bool { true }
    public var readsPublishedSnapshot: Bool { false }
    public var readsCodexData: Bool { false }
    public var writesFilesystem: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public init(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        payloadHash: String,
        frozenSourceDigest: String? = nil,
        durableReadbackMatched: Bool
    ) {
        self.requestID = requestID
        self.preview = preview
        self.payloadHash = payloadHash
        self.frozenSourceDigest = frozenSourceDigest
        self.durableReadbackMatched = durableReadbackMatched
    }
}

public enum CodexGhostRepairBulkPreviewReadbackOutcome:
    Hashable,
    Sendable
{
    case observed(CodexGhostRepairBulkPreviewReadbackEvidence)
    case notFound(requestID: UUID)
    case unavailable(requestID: UUID, message: String)

    public var requestID: UUID {
        switch self {
        case let .observed(evidence): evidence.requestID
        case let .notFound(requestID), let .unavailable(requestID, _):
            requestID
        }
    }
}

public struct CodexGhostRepairBulkPreviewReadbackCapabilities:
    Hashable,
    Sendable
{
    public let explicitReadbackAvailable: Bool

    public var readsManagerOwnedState: Bool { explicitReadbackAvailable }
    public var readsPublishedSnapshot: Bool { false }
    public var readsCodexData: Bool { false }
    public var writesFilesystem: Bool { false }
    public var automaticReadback: Bool { false }
    public var retryAuthority: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let unavailable = Self(explicitReadbackAvailable: false)
    public static let packagedReadOnly = Self(explicitReadbackAvailable: true)
}

public protocol CodexGhostRepairBulkPreviewReadbackCoordinating: Sendable {
    var capabilities: CodexGhostRepairBulkPreviewReadbackCapabilities { get }

    func readback(
        requestID: UUID
    ) async -> CodexGhostRepairBulkPreviewReadbackOutcome
}

public actor CodexGhostRepairBulkPreviewUnavailableReadbackCoordinator:
    CodexGhostRepairBulkPreviewReadbackCoordinating
{
    public nonisolated let capabilities =
        CodexGhostRepairBulkPreviewReadbackCapabilities.unavailable

    public init() {}

    public func readback(
        requestID: UUID
    ) async -> CodexGhostRepairBulkPreviewReadbackOutcome {
        .unavailable(
            requestID: requestID,
            message: "Saved bulk Preview readback is unavailable in this build."
        )
    }
}

actor CodexGhostRepairBulkPreviewLiveReadbackCoordinator:
    CodexGhostRepairBulkPreviewReadbackCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkPreviewReadbackCapabilities.packagedReadOnly
    private let databaseURLProvider: @Sendable () throws -> URL

    init(
        databaseURLProvider: @escaping @Sendable () throws -> URL = {
            try StateStoreLocation.applicationSupportDatabaseURL()
        }
    ) {
        self.databaseURLProvider = databaseURLProvider
    }

    func readback(
        requestID: UUID
    ) async -> CodexGhostRepairBulkPreviewReadbackOutcome {
        do {
            let databaseURL = try databaseURLProvider()
            let reader = try CodexGhostRepairBulkPreviewReadOnlyStore(
                databaseURL: databaseURL
            )
            defer { reader.close() }
            guard let stored = try reader.preview(requestID: requestID) else {
                return .notFound(requestID: requestID)
            }
            guard stored.requestID == requestID,
                  Self.isSHA256(stored.payloadHash),
                  !stored.confirmationAuthority,
                  !stored.repairMutationAuthority,
                  !stored.preview.confirmationAuthority,
                  !stored.preview.repairMutationAuthority else {
                return .unavailable(
                    requestID: requestID,
                    message:
                        "Saved bulk Preview did not match the exact authority-free record."
                )
            }
            return .observed(.init(
                requestID: stored.requestID,
                preview: stored.preview,
                payloadHash: stored.payloadHash,
                frozenSourceDigest: stored.frozenSource?.sourceDigest,
                durableReadbackMatched: true
            ))
        } catch {
            return .unavailable(
                requestID: requestID,
                message:
                    "Saved bulk Preview readback could not produce exact manager-owned evidence."
            )
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

private final class CodexGhostRepairBulkPreviewReadOnlyStore {
    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &pointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw PersistentStateError.invalidRecord(
                "Bulk Preview state store could not be opened read-only."
            )
        }
        database = pointer
        do {
            guard sqlite3_db_readonly(pointer, "main") == 1,
                  sqlite3_exec(
                      pointer,
                      "PRAGMA query_only=ON",
                      nil,
                      nil,
                      nil
                  ) == SQLITE_OK,
                  try scalar("PRAGMA query_only") == 1,
                  try scalar("PRAGMA application_id")
                    == Int64(SQLiteStateStore.applicationID),
                  try scalar("PRAGMA user_version")
                    == Int64(SQLiteStateStore.currentSchemaVersion) else {
                throw PersistentStateError.invalidRecord(
                    "Bulk Preview state database contract did not match."
                )
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    func preview(
        requestID: UUID
    ) throws -> CodexGhostRepairBulkStoredPreview? {
        guard let database else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview state connection is closed."
            )
        }
        let sql =
            """
            SELECT preview_id, snapshot_reference, inventory_digest,
                   manifest_digest, generated_at_ms, expires_at_ms,
                   selected_count, blocked_count,
                   unselected_eligible_count, payload_json, payload_hash,
                   confirmation_authority, repair_mutation_authority
            FROM codex_ghost_repair_bulk_previews
            WHERE request_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview fixed query could not be prepared."
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview fixed query was not read-only."
            )
        }
        let requestText = requestID.uuidString.lowercased()
        let bindResult = requestText.withCString { pointer in
            sqlite3_bind_text(
                statement,
                1,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard bindResult == SQLITE_OK else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview request ID could not be bound."
            )
        }

        let firstStep = sqlite3_step(statement)
        if firstStep == SQLITE_DONE { return nil }
        guard firstStep == SQLITE_ROW else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview fixed query did not complete."
            )
        }
        let stored = try decodeRow(statement, requestID: requestID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview fixed query returned duplicate rows."
            )
        }
        return stored
    }

    private func decodeRow(
        _ statement: OpaquePointer,
        requestID: UUID
    ) throws -> CodexGhostRepairBulkStoredPreview {
        let previewID = try Self.canonicalUUID(requiredText(statement, 0))
        let snapshotReference = try requiredText(statement, 1)
        let inventoryDigest = try requiredText(statement, 2)
        let manifestDigest = try requiredText(statement, 3)
        let generatedAt = sqlite3_column_int64(statement, 4)
        let expiresAt = sqlite3_column_int64(statement, 5)
        let selectedCount = Int(sqlite3_column_int64(statement, 6))
        let blockedCount = Int(sqlite3_column_int64(statement, 7))
        let unselectedCount = Int(sqlite3_column_int64(statement, 8))
        let encoded = try requiredText(statement, 9)
        let payloadHash = try requiredText(statement, 10)
        let confirmationAuthority = sqlite3_column_int64(statement, 11)
        let repairMutationAuthority = sqlite3_column_int64(statement, 12)

        guard payloadHash == SQLiteStateStore.hashBulkPreviewPayload(encoded)
        else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview payload hash does not match."
            )
        }
        let payload: CodexGhostRepairBulkPreviewPersistedPayload =
            try SQLiteStateStore.decodeBulkPreviewPayload(encoded)
        try payload.preview.validateForPersistence()
        guard payload.requestID == requestID,
              payload.preview.previewID == previewID,
              payload.preview.snapshotReference == snapshotReference,
              payload.preview.inventoryDigest == inventoryDigest,
              payload.preview.manifestDigest == manifestDigest,
              payload.preview.generatedAtMilliseconds == generatedAt,
              payload.preview.expiresAtMilliseconds == expiresAt,
              payload.preview.selectedItems.count == selectedCount,
              payload.preview.blockedItems.count == blockedCount,
              payload.preview.unselectedEligibleThreadIDs.count
                == unselectedCount,
              confirmationAuthority == 0,
              repairMutationAuthority == 0 else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview columns and payload disagree."
            )
        }
        return .init(
            requestID: requestID,
            preview: payload.preview,
            payloadHash: payloadHash,
            frozenSource: try frozenSource(
                requestID: requestID,
                preview: payload.preview
            )
        )
    }

    private func frozenSource(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview
    ) throws -> CodexGhostRepairBulkFrozenPlanSource? {
        guard let database else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview state connection is closed."
            )
        }
        let sql =
            """
            SELECT preview_id, preview_manifest_digest, snapshot_reference,
                   snapshot_manifest_hash, inventory_digest,
                   frozen_source_digest, selected_count,
                   blocked_outside_batch_count, payload_json, payload_hash,
                   confirmation_authority, repair_mutation_authority
            FROM codex_ghost_repair_bulk_frozen_plan_sources
            WHERE request_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw PersistentStateError.invalidRecord(
                "Bulk frozen source fixed query could not be prepared."
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw PersistentStateError.invalidRecord(
                "Bulk frozen source fixed query was not read-only."
            )
        }
        let requestText = requestID.uuidString.lowercased()
        guard requestText.withCString({ pointer in
            sqlite3_bind_text(
                statement,
                1,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }) == SQLITE_OK else {
            throw PersistentStateError.invalidRecord(
                "Bulk frozen source request ID could not be bound."
            )
        }
        let firstStep = sqlite3_step(statement)
        if firstStep == SQLITE_DONE { return nil }
        guard firstStep == SQLITE_ROW else {
            throw PersistentStateError.invalidRecord(
                "Bulk frozen source fixed query did not complete."
            )
        }
        let source = try decodeFrozenSourceRow(
            statement,
            requestID: requestID,
            preview: preview
        )
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistentStateError.invalidRecord(
                "Bulk frozen source fixed query returned duplicate rows."
            )
        }
        return source
    }

    private func decodeFrozenSourceRow(
        _ statement: OpaquePointer,
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview
    ) throws -> CodexGhostRepairBulkFrozenPlanSource {
        let previewID = try Self.canonicalUUID(requiredText(statement, 0))
        let previewManifestDigest = try requiredText(statement, 1)
        let snapshotReference = try requiredText(statement, 2)
        let snapshotManifestHash = try requiredText(statement, 3)
        let inventoryDigest = try requiredText(statement, 4)
        let sourceDigest = try requiredText(statement, 5)
        let selectedCount = Int(sqlite3_column_int64(statement, 6))
        let blockedCount = Int(sqlite3_column_int64(statement, 7))
        let encoded = try requiredText(statement, 8)
        let payloadHash = try requiredText(statement, 9)
        let confirmationAuthority = sqlite3_column_int64(statement, 10)
        let repairMutationAuthority = sqlite3_column_int64(statement, 11)
        guard payloadHash == SQLiteStateStore.hashBulkPreviewPayload(encoded)
        else {
            throw PersistentStateError.invalidRecord(
                "Bulk frozen source payload hash does not match."
            )
        }
        let payload: CodexGhostRepairBulkFrozenPlanSourcePersistedPayload =
            try SQLiteStateStore.decodeBulkPreviewPayload(encoded)
        try payload.source.validate(preview: preview)
        guard payload.requestID == requestID,
              payload.source.previewID == previewID,
              payload.source.previewManifestDigest == previewManifestDigest,
              payload.source.snapshotReference == snapshotReference,
              payload.source.snapshotManifestHash == snapshotManifestHash,
              payload.source.inventoryDigest == inventoryDigest,
              payload.source.sourceDigest == sourceDigest,
              payload.source.selectedCount == selectedCount,
              payload.source.blockedOutsideBatchCount == blockedCount,
              confirmationAuthority == 0,
              repairMutationAuthority == 0 else {
            throw PersistentStateError.invalidRecord(
                "Bulk frozen source columns and payload disagree."
            )
        }
        return payload.source
    }

    private func scalar(_ sql: String) throws -> Int64 {
        guard let database else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview state connection is closed."
            )
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview database contract query failed."
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview database contract could not be read."
            )
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func requiredText(
        _ statement: OpaquePointer,
        _ column: Int32
    ) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let text = sqlite3_column_text(statement, column) else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview fixed query returned invalid text."
            )
        }
        return String(cString: text)
    }

    private static func canonicalUUID(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview ID is not canonical."
            )
        }
        return uuid
    }
}

public enum CodexGhostRepairBulkPreviewReadbackCoordinatorFactory {
    /// Construction is zero-I/O. The manager-owned state database is opened
    /// only after an explicit readback for one exact request ID.
    public static func packagedReadOnly()
        -> any CodexGhostRepairBulkPreviewReadbackCoordinating
    {
        CodexGhostRepairBulkPreviewLiveReadbackCoordinator()
    }
}

public protocol CodexGhostRepairBulkPreviewPersisting: Sendable {
    func persist(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        inventory: CodexGhostRepairBulkInventory
    ) async throws -> CodexGhostRepairBulkPreviewPersistenceReceipt
}

public enum CodexGhostRepairBulkPreviewPersistenceFactory {
    /// Construction performs no I/O. Persistence opens only Agent Session
    /// Manager's own state database after an explicit Preview request.
    public static func packaged()
        -> any CodexGhostRepairBulkPreviewPersisting
    {
        CodexGhostRepairBulkPreviewLivePersister()
    }
}

actor CodexGhostRepairBulkPreviewLivePersister:
    CodexGhostRepairBulkPreviewPersisting
{
    func persist(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        inventory: CodexGhostRepairBulkInventory
    ) async throws -> CodexGhostRepairBulkPreviewPersistenceReceipt {
        let databaseURL = try StateStoreLocation
            .applicationSupportDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        let stored = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            inventory: inventory
        )
        guard stored.requestID == requestID,
              stored.preview == preview,
              stored.frozenSource != nil,
              !stored.confirmationAuthority,
              !stored.repairMutationAuthority else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview persistence receipt did not match exactly."
            )
        }
        return .init(
            requestID: stored.requestID,
            previewID: stored.preview.previewID,
            payloadHash: stored.payloadHash,
            frozenSourceDigest: stored.frozenSource?.sourceDigest,
            durableReadbackMatched: true
        )
    }
}

extension SQLiteStateStore {
    /// Exact replay is an idempotent readback. A reused request ID, Preview ID,
    /// or manifest digest with different evidence fails closed.
    @discardableResult
    func saveCodexGhostRepairBulkPreview(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview
    ) throws -> CodexGhostRepairBulkStoredPreview {
        try saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            frozenSource: nil
        )
    }

    /// Product persistence freezes only the exact selected source rows. The
    /// public Preview and private selected-only source are inserted in one
    /// transaction and must read back as one exact record.
    @discardableResult
    func saveCodexGhostRepairBulkPreview(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        inventory: CodexGhostRepairBulkInventory
    ) throws -> CodexGhostRepairBulkStoredPreview {
        let source = try CodexGhostRepairBulkFrozenPlanSourceBuilder.build(
            inventory: inventory,
            preview: preview
        )
        return try saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            frozenSource: source
        )
    }

    private func saveCodexGhostRepairBulkPreview(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        frozenSource: CodexGhostRepairBulkFrozenPlanSource?
    ) throws -> CodexGhostRepairBulkStoredPreview {
        try preview.validateForPersistence()
        try frozenSource?.validate(preview: preview)
        let payload = CodexGhostRepairBulkPreviewPersistedPayload(
            requestID: requestID,
            preview: preview
        )
        let encoded = try Self.encodeBulkPreviewPayload(payload)
        let payloadHash = Self.hashBulkPreviewPayload(encoded)
        let sourceEncoded = try frozenSource.map { source in
            try Self.encodeBulkPreviewPayload(
                CodexGhostRepairBulkFrozenPlanSourcePersistedPayload(
                    requestID: requestID,
                    source: source
                )
            )
        }
        let sourcePayloadHash = sourceEncoded.map(
            Self.hashBulkPreviewPayload
        )
        let expected = CodexGhostRepairBulkStoredPreview(
            requestID: requestID,
            preview: preview,
            payloadHash: payloadHash,
            frozenSource: frozenSource
        )

        try withLockedDatabase { database in
            try transaction(database) {
                if let existing = try loadCodexGhostRepairBulkPreview(
                    requestID: requestID,
                    database: database
                ) {
                    guard existing == expected else {
                        throw PersistentStateError.invalidRecord(
                            "Bulk Preview request ID already belongs to different evidence."
                        )
                    }
                    return
                }
                try execute(
                    """
                    INSERT INTO codex_ghost_repair_bulk_previews (
                        request_id, preview_id, snapshot_reference,
                        inventory_digest, manifest_digest, generated_at_ms,
                        expires_at_ms, selected_count, blocked_count,
                        unselected_eligible_count, payload_json, payload_hash,
                        confirmation_authority, repair_mutation_authority
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
                    """,
                    values: [
                        .text(requestID.uuidString.lowercased()),
                        .text(preview.previewID.uuidString.lowercased()),
                        .text(preview.snapshotReference),
                        .text(preview.inventoryDigest),
                        .text(preview.manifestDigest),
                        .int64(preview.generatedAtMilliseconds),
                        .int64(preview.expiresAtMilliseconds),
                        .int64(Int64(preview.selectedItems.count)),
                        .int64(Int64(preview.blockedItems.count)),
                        .int64(Int64(
                            preview.unselectedEligibleThreadIDs.count
                        )),
                        .text(encoded),
                        .text(payloadHash),
                    ],
                    database: database
                )
                if let frozenSource, let sourceEncoded,
                   let sourcePayloadHash {
                    try execute(
                        """
                        INSERT INTO codex_ghost_repair_bulk_frozen_plan_sources (
                            request_id, preview_id,
                            preview_manifest_digest, snapshot_reference,
                            snapshot_manifest_hash, inventory_digest,
                            frozen_source_digest, selected_count,
                            blocked_outside_batch_count, payload_json,
                            payload_hash, confirmation_authority,
                            repair_mutation_authority
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
                        """,
                        values: [
                            .text(requestID.uuidString.lowercased()),
                            .text(preview.previewID.uuidString.lowercased()),
                            .text(preview.manifestDigest),
                            .text(preview.snapshotReference),
                            .text(frozenSource.snapshotManifestHash),
                            .text(preview.inventoryDigest),
                            .text(frozenSource.sourceDigest),
                            .int64(Int64(frozenSource.selectedCount)),
                            .int64(Int64(
                                frozenSource.blockedOutsideBatchCount
                            )),
                            .text(sourceEncoded),
                            .text(sourcePayloadHash),
                        ],
                        database: database
                    )
                }
            }
        }
        guard try codexGhostRepairBulkPreview(requestID: requestID)
                == expected else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview durable readback did not match exactly."
            )
        }
        return expected
    }

    func codexGhostRepairBulkPreview(
        requestID: UUID
    ) throws -> CodexGhostRepairBulkStoredPreview? {
        try withLockedDatabase { database in
            try loadCodexGhostRepairBulkPreview(
                requestID: requestID,
                database: database
            )
        }
    }
}

extension SQLiteStateStore {
    func loadCodexGhostRepairBulkPreview(
        requestID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkStoredPreview? {
        let rows = try query(
            """
            SELECT preview_id, snapshot_reference, inventory_digest,
                   manifest_digest, generated_at_ms, expires_at_ms,
                   selected_count, blocked_count,
                   unselected_eligible_count, payload_json, payload_hash,
                   confirmation_authority, repair_mutation_authority
            FROM codex_ghost_repair_bulk_previews
            WHERE request_id = ?
            """,
            values: [.text(requestID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairBulkStoredPreview in
            try CodexGhostRepairBulkPreviewPersistedRow(
                previewID: Self.bulkCanonicalUUID(requiredText(statement, 0)),
                snapshotReference: requiredText(statement, 1),
                inventoryDigest: requiredText(statement, 2),
                manifestDigest: requiredText(statement, 3),
                generatedAtMilliseconds: sqlite3_column_int64(statement, 4),
                expiresAtMilliseconds: sqlite3_column_int64(statement, 5),
                selectedCount: Int(sqlite3_column_int64(statement, 6)),
                blockedCount: Int(sqlite3_column_int64(statement, 7)),
                unselectedEligibleCount:
                    Int(sqlite3_column_int64(statement, 8)),
                encodedPayload: requiredText(statement, 9),
                payloadHash: requiredText(statement, 10),
                confirmationAuthority: sqlite3_column_int64(statement, 11),
                repairMutationAuthority: sqlite3_column_int64(statement, 12)
            ).decodeValidated(requestID: requestID)
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate bulk Preview rows."
            )
        }
        guard let stored = rows.first else { return nil }
        return .init(
            requestID: stored.requestID,
            preview: stored.preview,
            payloadHash: stored.payloadHash,
            frozenSource: try loadCodexGhostRepairBulkFrozenSource(
                requestID: requestID,
                preview: stored.preview,
                database: database
            )
        )
    }

    private func loadCodexGhostRepairBulkFrozenSource(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkFrozenPlanSource? {
        let rows = try query(
            """
            SELECT preview_id, preview_manifest_digest, snapshot_reference,
                   snapshot_manifest_hash, inventory_digest,
                   frozen_source_digest, selected_count,
                   blocked_outside_batch_count, payload_json, payload_hash,
                   confirmation_authority, repair_mutation_authority
            FROM codex_ghost_repair_bulk_frozen_plan_sources
            WHERE request_id = ?
            """,
            values: [.text(requestID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairBulkFrozenPlanSource in
            let previewID = try Self.bulkCanonicalUUID(
                requiredText(statement, 0)
            )
            let previewManifestDigest = try requiredText(statement, 1)
            let snapshotReference = try requiredText(statement, 2)
            let snapshotManifestHash = try requiredText(statement, 3)
            let inventoryDigest = try requiredText(statement, 4)
            let sourceDigest = try requiredText(statement, 5)
            let selectedCount = Int(sqlite3_column_int64(statement, 6))
            let blockedCount = Int(sqlite3_column_int64(statement, 7))
            let encoded = try requiredText(statement, 8)
            let payloadHash = try requiredText(statement, 9)
            let confirmationAuthority = sqlite3_column_int64(statement, 10)
            let repairMutationAuthority = sqlite3_column_int64(statement, 11)
            guard payloadHash == Self.hashBulkPreviewPayload(encoded) else {
                throw PersistentStateError.invalidRecord(
                    "Bulk frozen source payload hash does not match."
                )
            }
            let payload: CodexGhostRepairBulkFrozenPlanSourcePersistedPayload =
                try Self.decodeBulkPreviewPayload(encoded)
            try payload.source.validate(preview: preview)
            guard payload.requestID == requestID,
                  payload.source.previewID == previewID,
                  payload.source.previewManifestDigest
                    == previewManifestDigest,
                  payload.source.snapshotReference == snapshotReference,
                  payload.source.snapshotManifestHash
                    == snapshotManifestHash,
                  payload.source.inventoryDigest == inventoryDigest,
                  payload.source.sourceDigest == sourceDigest,
                  payload.source.selectedCount == selectedCount,
                  payload.source.blockedOutsideBatchCount == blockedCount,
                  confirmationAuthority == 0,
                  repairMutationAuthority == 0 else {
                throw PersistentStateError.invalidRecord(
                    "Bulk frozen source columns and payload disagree."
                )
            }
            return payload.source
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate bulk frozen source rows."
            )
        }
        return rows.first
    }

    static func encodeBulkPreviewPayload<T: Encodable>(
        _ value: T
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview payload is not valid UTF-8."
            )
        }
        return encoded
    }

    static func decodeBulkPreviewPayload<T: Decodable>(
        _ encoded: String
    ) throws -> T {
        guard let data = encoded.data(using: .utf8) else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview payload is not valid UTF-8."
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func hashBulkPreviewPayload(_ encoded: String) -> String {
        let digest = SHA256.hash(data: Data(encoded.utf8))
        return "sha256:"
            + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func bulkCanonicalUUID(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw PersistentStateError.invalidRecord(
                "Bulk Preview ID is not canonical."
            )
        }
        return uuid
    }
}
