import Foundation

public struct CodexGhostRepairBulkPreviewItem:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let threadID: String
    public let category: CodexGhostRepairCategory
    public let evidenceDigest: String
    public let expectedLogicalEffects:
        [CodexGhostRepairSnapshotDryRunLogicalEffect]
    public var initiallyAbsent: Bool? = nil
    public var reviewedResidue: CodexGhostRepairReviewedSessionResidue? = nil

    public var exposesPrivateRowValues: Bool { false }
}

public struct CodexGhostRepairBulkPreviewBlockedItem:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let threadID: String
    public let disposition: CodexGhostRepairBulkInventoryDisposition
    public let blockers: [CodexGhostRepairBulkInventoryBlocker]
    public let evidenceDigest: String

    public var selectedForRepair: Bool { false }
    public var exposesPrivateRowValues: Bool { false }
}

private struct CodexGhostRepairBulkPreviewPayload:
    Encodable,
    Hashable
{
    let previewID: UUID
    let generatedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let snapshotReference: String
    let sourceLayoutIdentifier: String
    let inventoryDigest: String
    let observedCatalogItemCount: Int
    let confirmedGhostCount: Int
    let selectedItems: [CodexGhostRepairBulkPreviewItem]
    let blockedItems: [CodexGhostRepairBulkPreviewBlockedItem]
    let unselectedEligibleThreadIDs: [String]
    let expectedBatchEffects:
        [CodexGhostRepairSnapshotDryRunLogicalEffect]
}

public struct CodexGhostRepairBulkPreview:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    /// A bounded first product limit with headroom above the historical
    /// 148-item incident. Increasing it requires new deterministic acceptance.
    public static let maximumSelectedItems = 500
    public static let maximumLifetimeMilliseconds: Int64 = 15 * 60 * 1_000

    public let previewID: UUID
    public let generatedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let snapshotReference: String
    public let sourceLayoutIdentifier: String
    public let inventoryDigest: String
    public let observedCatalogItemCount: Int
    public let confirmedGhostCount: Int
    public let selectedItems: [CodexGhostRepairBulkPreviewItem]
    public let blockedItems: [CodexGhostRepairBulkPreviewBlockedItem]
    public let unselectedEligibleThreadIDs: [String]
    public let expectedBatchEffects:
        [CodexGhostRepairSnapshotDryRunLogicalEffect]
    public let manifestDigest: String

    public var selectedThreadIDs: [String] {
        selectedItems.map(\.threadID)
    }
    public var ordinarySelectedCount: Int {
        selectedItems.count { $0.category == .ordinary }
    }
    public var automationSelectedCount: Int {
        selectedItems.count { $0.category == .automation }
    }
    public var allOrNothing: Bool { true }
    public var singleWholeBatchConfirmationRequired: Bool { true }
    public var perItemConfirmationRequired: Bool { false }
    public var silentSelectionShrinkAllowed: Bool { false }
    public var exposesPrivateRowValues: Bool { false }
    public var persistsPreview: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    fileprivate init(
        previewID: UUID,
        generatedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        snapshotReference: String,
        sourceLayoutIdentifier: String,
        inventoryDigest: String,
        observedCatalogItemCount: Int,
        confirmedGhostCount: Int,
        selectedItems: [CodexGhostRepairBulkPreviewItem],
        blockedItems: [CodexGhostRepairBulkPreviewBlockedItem],
        unselectedEligibleThreadIDs: [String],
        expectedBatchEffects:
            [CodexGhostRepairSnapshotDryRunLogicalEffect]
    ) throws {
        let payload = CodexGhostRepairBulkPreviewPayload(
            previewID: previewID,
            generatedAtMilliseconds: generatedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds,
            snapshotReference: snapshotReference,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            inventoryDigest: inventoryDigest,
            observedCatalogItemCount: observedCatalogItemCount,
            confirmedGhostCount: confirmedGhostCount,
            selectedItems: selectedItems,
            blockedItems: blockedItems,
            unselectedEligibleThreadIDs: unselectedEligibleThreadIDs,
            expectedBatchEffects: expectedBatchEffects
        )
        self.previewID = previewID
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.snapshotReference = snapshotReference
        self.sourceLayoutIdentifier = sourceLayoutIdentifier
        self.inventoryDigest = inventoryDigest
        self.observedCatalogItemCount = observedCatalogItemCount
        self.confirmedGhostCount = confirmedGhostCount
        self.selectedItems = selectedItems
        self.blockedItems = blockedItems
        self.unselectedEligibleThreadIDs = unselectedEligibleThreadIDs
        self.expectedBatchEffects = expectedBatchEffects
        manifestDigest = try CodexGhostRepairHasher.hash(payload)
    }

    public func validateIntegrity() throws {
        let rebuilt = try Self(
            previewID: previewID,
            generatedAtMilliseconds: generatedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds,
            snapshotReference: snapshotReference,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            inventoryDigest: inventoryDigest,
            observedCatalogItemCount: observedCatalogItemCount,
            confirmedGhostCount: confirmedGhostCount,
            selectedItems: selectedItems,
            blockedItems: blockedItems,
            unselectedEligibleThreadIDs: unselectedEligibleThreadIDs,
            expectedBatchEffects: expectedBatchEffects
        )
        guard rebuilt.manifestDigest == manifestDigest else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk Preview manifest digest mismatch."
            )
        }
    }

    /// Validates the complete semantic shape before persistence or cold
    /// readback. The manifest digest alone proves byte-level consistency; this
    /// additionally rejects a self-consistent but invalid authority payload.
    func validateForPersistence() throws {
        try validateIntegrity()
        let selectedIDs = selectedThreadIDs
        let blockedIDs = blockedItems.map(\.threadID)
        let selectedSet = Set(selectedIDs)
        let blockedSet = Set(blockedIDs)
        let unselectedSet = Set(unselectedEligibleThreadIDs)
        let expectedConfirmedCount = selectedItems.count
            + unselectedEligibleThreadIDs.count
            + blockedItems.count { $0.disposition == .blocked }

        guard expiresAtMilliseconds > generatedAtMilliseconds,
              expiresAtMilliseconds - generatedAtMilliseconds
                <= Self.maximumLifetimeMilliseconds,
              isCanonicalUUID(snapshotReference),
              CodexGhostRepairSnapshotSourceProfile.admitted(
                  sourceLayoutIdentifier: sourceLayoutIdentifier
              ) != nil,
              isSHA256(inventoryDigest),
              isSHA256(manifestDigest),
              (1...Self.maximumSelectedItems).contains(selectedItems.count),
              observedCatalogItemCount >= 0,
              confirmedGhostCount == expectedConfirmedCount,
              observedCatalogItemCount >= selectedItems.count
                + blockedItems.count
                + unselectedEligibleThreadIDs.count,
              selectedIDs == selectedIDs.sorted(),
              blockedIDs == blockedIDs.sorted(),
              unselectedEligibleThreadIDs
                == unselectedEligibleThreadIDs.sorted(),
              selectedSet.count == selectedIDs.count,
              blockedSet.count == blockedIDs.count,
              unselectedSet.count == unselectedEligibleThreadIDs.count,
              selectedSet.isDisjoint(with: blockedSet),
              selectedSet.isDisjoint(with: unselectedSet),
              blockedSet.isDisjoint(with: unselectedSet),
              selectedItems.allSatisfy({ item in
                  isCanonicalUUID(item.threadID)
                      && isSHA256(item.evidenceDigest)
                      && (item.reviewedResidue == nil || (item.reviewedResidue!.isValid
                          && item.initiallyAbsent != true
                          && (!item.reviewedResidue!.pausedAutomation || item.category == .automation)))
                      && (item.initiallyAbsent == nil || (item.initiallyAbsent == true && item.category == .ordinary))
                      && item.expectedLogicalEffects
                          == Self.expectedItemEffects(
                              threadID: item.threadID,
                              category: item.category,
                              initiallyAbsent: item.initiallyAbsent == true,
                              summaryCount: item.reviewedResidue?.summaryRowDigests.count ?? 0
                          )
              }),
              blockedItems.allSatisfy({ item in
                  isCanonicalUUID(item.threadID)
                      && isSHA256(item.evidenceDigest)
                      && (item.disposition == .blocked
                          || item.disposition == .unconfirmed)
                      && !item.blockers.isEmpty
                      && item.blockers == Self.canonical(item.blockers)
              }),
              unselectedEligibleThreadIDs.allSatisfy(isCanonicalUUID),
              expectedBatchEffects == [
                  .init(
                      kind: .incrementCatalogRevision,
                      amount: selectedItems.count { $0.initiallyAbsent != true }
                  ),
                  .init(
                      kind: .incrementObservationSequence,
                      amount: selectedItems.count { $0.initiallyAbsent != true }
                  ),
              ] else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk Preview persistence contract is invalid."
            )
        }
    }

    private static func expectedItemEffects(
        threadID: String,
        category: CodexGhostRepairCategory,
        initiallyAbsent: Bool = false,
        summaryCount: Int = 0
    ) -> [CodexGhostRepairSnapshotDryRunLogicalEffect] {
        var effects: [CodexGhostRepairSnapshotDryRunLogicalEffect] = [
            .init(kind: .removeCatalogRow, threadID: threadID, amount: initiallyAbsent ? 0 : 1),
        ]
        if category == .automation {
            effects.append(.init(
                kind: .archiveAutomationRun,
                threadID: threadID,
                amount: 1
            ))
        }
        if summaryCount > 0 {
            effects.append(.init(kind: .removeReviewedSessionSummaries, threadID: threadID, amount: summaryCount))
        }
        return effects
    }

    private static func canonical(
        _ blockers: [CodexGhostRepairBulkInventoryBlocker]
    ) -> [CodexGhostRepairBulkInventoryBlocker] {
        CodexGhostRepairBulkInventoryBlocker.allCases.filter {
            blockers.contains($0)
        }
    }

    private func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }

    private enum CodingKeys: String, CodingKey {
        case previewID
        case generatedAtMilliseconds
        case expiresAtMilliseconds
        case snapshotReference
        case sourceLayoutIdentifier
        case inventoryDigest
        case observedCatalogItemCount
        case confirmedGhostCount
        case selectedItems
        case blockedItems
        case unselectedEligibleThreadIDs
        case expectedBatchEffects
        case manifestDigest
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let suppliedDigest = try values.decode(
            String.self,
            forKey: .manifestDigest
        )
        try self.init(
            previewID: values.decode(UUID.self, forKey: .previewID),
            generatedAtMilliseconds: values.decode(
                Int64.self,
                forKey: .generatedAtMilliseconds
            ),
            expiresAtMilliseconds: values.decode(
                Int64.self,
                forKey: .expiresAtMilliseconds
            ),
            snapshotReference: values.decode(
                String.self,
                forKey: .snapshotReference
            ),
            sourceLayoutIdentifier: values.decode(
                String.self,
                forKey: .sourceLayoutIdentifier
            ),
            inventoryDigest: values.decode(
                String.self,
                forKey: .inventoryDigest
            ),
            observedCatalogItemCount: values.decode(
                Int.self,
                forKey: .observedCatalogItemCount
            ),
            confirmedGhostCount: values.decode(
                Int.self,
                forKey: .confirmedGhostCount
            ),
            selectedItems: values.decode(
                [CodexGhostRepairBulkPreviewItem].self,
                forKey: .selectedItems
            ),
            blockedItems: values.decode(
                [CodexGhostRepairBulkPreviewBlockedItem].self,
                forKey: .blockedItems
            ),
            unselectedEligibleThreadIDs: values.decode(
                [String].self,
                forKey: .unselectedEligibleThreadIDs
            ),
            expectedBatchEffects: values.decode(
                [CodexGhostRepairSnapshotDryRunLogicalEffect].self,
                forKey: .expectedBatchEffects
            )
        )
        guard suppliedDigest == manifestDigest else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk Preview decoded manifest digest mismatch."
            )
        }
    }
}

public enum CodexGhostRepairBulkPreviewFactory {
    /// Builds one authority-free, in-memory manifest from an already verified
    /// Bulk Inventory. This call performs no I/O and grants no confirmation or
    /// repair authority.
    public static func buildAuthorityFree(
        inventory: CodexGhostRepairBulkInventory,
        selectedThreadIDs: [String],
        generatedAtMilliseconds: Int64,
        lifetimeMilliseconds: Int64 =
            CodexGhostRepairBulkPreview.maximumLifetimeMilliseconds
    ) throws -> CodexGhostRepairBulkPreview {
        let expiry = generatedAtMilliseconds.addingReportingOverflow(
            lifetimeMilliseconds
        )
        guard !expiry.overflow else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk Preview lifetime overflowed."
            )
        }
        return try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: selectedThreadIDs,
            previewID: UUID(),
            generatedAtMilliseconds: generatedAtMilliseconds,
            expiresAtMilliseconds: expiry.partialValue
        )
    }
}

enum CodexGhostRepairBulkPreviewBuilder {
    static func build(
        inventory: CodexGhostRepairBulkInventory,
        selectedThreadIDs: [String],
        previewID: UUID,
        generatedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkPreview {
        try validateInventory(inventory)
        guard expiresAtMilliseconds > generatedAtMilliseconds,
              expiresAtMilliseconds - generatedAtMilliseconds
                <= CodexGhostRepairBulkPreview.maximumLifetimeMilliseconds,
              (1...CodexGhostRepairBulkPreview.maximumSelectedItems)
                .contains(selectedThreadIDs.count),
              selectedThreadIDs == selectedThreadIDs.sorted(),
              Set(selectedThreadIDs).count == selectedThreadIDs.count,
              selectedThreadIDs.allSatisfy(isCanonicalUUID) else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk Preview selection or lifetime is invalid."
            )
        }

        let selectedSet = Set(selectedThreadIDs)
        let inventoryByID = Dictionary(
            uniqueKeysWithValues: inventory.items.map { ($0.threadID, $0) }
        )
        let selectedItems = try selectedThreadIDs.map { threadID in
            guard let item = inventoryByID[threadID],
                  item.disposition == .eligible,
                  item.blockers.isEmpty,
                  let category = item.category else {
                throw CodexGhostRepairError.invalidPlan(
                    "Bulk Preview selection contains a non-eligible item."
                )
            }
            var result = CodexGhostRepairBulkPreviewItem(
                threadID: threadID,
                category: category,
                evidenceDigest: item.evidenceDigest,
                expectedLogicalEffects: itemEffects(
                    threadID: threadID,
                    category: category,
                    initiallyAbsent: item.initiallyAbsent == true,
                    summaryCount: item.reviewedResidue?.summaryRowDigests.count ?? 0
                )
            )
            result.initiallyAbsent = item.initiallyAbsent
            result.reviewedResidue = item.reviewedResidue
            return result
        }

        let blockedItems: [CodexGhostRepairBulkPreviewBlockedItem] = inventory.items.compactMap { item -> CodexGhostRepairBulkPreviewBlockedItem? in
            guard item.disposition == .blocked
                    || item.disposition == .unconfirmed else {
                return nil
            }
            return CodexGhostRepairBulkPreviewBlockedItem(
                threadID: item.threadID,
                disposition: item.disposition,
                blockers: item.blockers,
                evidenceDigest: item.evidenceDigest
            )
        }
        let unselectedEligible = inventory.eligibleThreadIDs.filter {
            !selectedSet.contains($0)
        }
        let selectedCount = selectedItems.count { $0.initiallyAbsent != true }
        return try CodexGhostRepairBulkPreview(
            previewID: previewID,
            generatedAtMilliseconds: generatedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds,
            snapshotReference: inventory.snapshotReference,
            sourceLayoutIdentifier: inventory.sourceLayoutIdentifier,
            inventoryDigest: inventory.inventoryDigest,
            observedCatalogItemCount: inventory.observedCatalogItemCount,
            confirmedGhostCount: inventory.confirmedGhostCount,
            selectedItems: selectedItems,
            blockedItems: blockedItems,
            unselectedEligibleThreadIDs: unselectedEligible,
            expectedBatchEffects: [
                .init(kind: .incrementCatalogRevision, amount: selectedCount),
                .init(
                    kind: .incrementObservationSequence,
                    amount: selectedCount
                ),
            ]
        )
    }

    private static func itemEffects(
        threadID: String,
        category: CodexGhostRepairCategory,
        initiallyAbsent: Bool = false,
        summaryCount: Int = 0
    ) -> [CodexGhostRepairSnapshotDryRunLogicalEffect] {
        var effects: [CodexGhostRepairSnapshotDryRunLogicalEffect] = [
            .init(kind: .removeCatalogRow, threadID: threadID, amount: initiallyAbsent ? 0 : 1),
        ]
        if category == .automation {
            effects.append(.init(
                kind: .archiveAutomationRun,
                threadID: threadID,
                amount: 1
            ))
        }
        if summaryCount > 0 {
            effects.append(.init(kind: .removeReviewedSessionSummaries, threadID: threadID, amount: summaryCount))
        }
        return effects
    }

    private static func validateInventory(
        _ inventory: CodexGhostRepairBulkInventory
    ) throws {
        let ids = inventory.items.map(\.threadID)
        guard isCanonicalUUID(inventory.snapshotReference) else {
            throw invalidInventory("snapshot-reference-invalid")
        }
        guard CodexGhostRepairSnapshotSourceProfile.admitted(
            sourceLayoutIdentifier: inventory.sourceLayoutIdentifier
        ) != nil else {
            throw invalidInventory("source-layout-unadmitted")
        }
        guard isSHA256(inventory.inventoryDigest) else {
            throw invalidInventory("inventory-digest-invalid")
        }
        guard ids == ids.sorted() else {
            throw invalidInventory("item-order-noncanonical")
        }
        guard Set(ids).count == ids.count else {
            throw invalidInventory("duplicate-item-id")
        }
        guard ids.count <= CodexGhostRepairBulkInventory
            .maximumObservedCatalogItems else {
            throw invalidInventory("observed-item-limit-exceeded")
        }
        for item in inventory.items {
            guard isCanonicalUUID(item.threadID) else {
                throw invalidInventory(
                    "item-id-invalid",
                    item: item
                )
            }
            guard isSHA256(item.evidenceDigest) else {
                throw invalidInventory(
                    "item-evidence-digest-invalid",
                    item: item
                )
            }
            guard item.blockers == canonical(item.blockers) else {
                throw invalidInventory(
                    "item-blockers-noncanonical",
                    item: item
                )
            }
            guard (item.disposition == .eligible) == item.selectable else {
                throw invalidInventory(
                    "item-selectability-mismatch",
                    item: item
                )
            }
            guard itemShapeIsValid(item) else {
                throw invalidInventory(
                    "item-shape-invalid",
                    item: item
                )
            }
        }
    }

    private static func itemShapeIsValid(
        _ item: CodexGhostRepairBulkInventoryItem
    ) -> Bool {
        guard item.initiallyAbsent == nil || (item.initiallyAbsent == true
            && item.disposition == .eligible && item.category == .ordinary) else { return false }
        return switch item.disposition {
        case .eligible:
            item.category != nil && item.blockers.isEmpty
        case .blocked:
            !item.blockers.isEmpty
                && ((item.category == nil)
                    == item.blockers.contains(.unsupportedRowShape))
        case .unconfirmed:
            item.category == nil && !item.blockers.isEmpty
        case .notGhost:
            item.category == nil && item.blockers.isEmpty
        }
    }

    private static func invalidInventory(
        _ reason: String,
        item: CodexGhostRepairBulkInventoryItem? = nil
    ) -> CodexGhostRepairError {
        let itemDetail = item.map {
            let category = $0.category?.rawValue ?? "none"
            let blockers = $0.blockers.map(\.rawValue).joined(separator: ",")
            return " item=\($0.threadID) disposition=\($0.disposition.rawValue) category=\(category) blockers=\(blockers)"
        } ?? ""
        return .invalidPlan(
            "Bulk Preview inventory validation failed: \(reason).\(itemDetail)"
        )
    }

    private static func canonical(
        _ blockers: [CodexGhostRepairBulkInventoryBlocker]
    ) -> [CodexGhostRepairBulkInventoryBlocker] {
        CodexGhostRepairBulkInventoryBlocker.allCases.filter {
            blockers.contains($0)
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}
