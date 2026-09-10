@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairBulkPreviewTests: XCTestCase {
    func testPublicFactoryBuildsAuthorityFreeInMemoryPreview() throws {
        let inventory = makeInventory(
            ordinary: 1,
            automation: 1,
            blocked: 0
        )
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: inventory,
                selectedThreadIDs: inventory.eligibleThreadIDs,
                generatedAtMilliseconds: 1_000,
                lifetimeMilliseconds: 5_000
            )

        XCTAssertEqual(preview.generatedAtMilliseconds, 1_000)
        XCTAssertEqual(preview.expiresAtMilliseconds, 6_000)
        XCTAssertEqual(preview.selectedItems.count, 2)
        XCTAssertFalse(preview.persistsPreview)
        XCTAssertFalse(preview.confirmationAuthority)
        XCTAssertFalse(preview.repairMutationAuthority)
    }

    private let snapshotReference =
        "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"

    func testSingleSelectedGhostPersistsWithoutSelectingOtherEligibleGhosts() throws {
        let inventory = makeInventory(ordinary: 48, automation: 100, blocked: 2)
        let selected = Array(inventory.eligibleThreadIDs.prefix(1))
        let preview = try makePreview(inventory: inventory, selected: selected)
        try preview.validateForPersistence()
        XCTAssertEqual(preview.selectedThreadIDs, selected)
        XCTAssertEqual(preview.unselectedEligibleThreadIDs.count, 147)
        XCTAssertEqual(preview.confirmedGhostCount, inventory.confirmedGhostCount)
        XCTAssertEqual(preview.expectedBatchEffects.map(\.amount), [1, 1])
    }

    func testExact148MixedPreviewFreezesEverySelectedAndBlockedItem()
        throws
    {
        let inventory = makeInventory(
            ordinary: 48,
            automation: 97,
            blocked: 3
        )
        let selected = inventory.eligibleThreadIDs

        let preview = try makePreview(
            inventory: inventory,
            selected: selected
        )

        XCTAssertEqual(inventory.observedCatalogItemCount, 148)
        XCTAssertEqual(preview.selectedItems.count, 145)
        XCTAssertEqual(preview.ordinarySelectedCount, 48)
        XCTAssertEqual(preview.automationSelectedCount, 97)
        XCTAssertEqual(preview.blockedItems.count, 3)
        XCTAssertTrue(preview.unselectedEligibleThreadIDs.isEmpty)
        XCTAssertEqual(preview.selectedThreadIDs, selected)
        XCTAssertEqual(
            preview.selectedItems.flatMap(\.expectedLogicalEffects)
                .count,
            48 + (97 * 2)
        )
        XCTAssertEqual(
            preview.expectedBatchEffects,
            [
                .init(kind: .incrementCatalogRevision, amount: 145),
                .init(kind: .incrementObservationSequence, amount: 145),
            ]
        )
        XCTAssertTrue(preview.allOrNothing)
        XCTAssertTrue(preview.singleWholeBatchConfirmationRequired)
        XCTAssertFalse(preview.perItemConfirmationRequired)
        XCTAssertFalse(preview.silentSelectionShrinkAllowed)
        XCTAssertFalse(preview.persistsPreview)
        XCTAssertFalse(preview.confirmationAuthority)
        XCTAssertFalse(preview.repairMutationAuthority)
        try preview.validateIntegrity()
    }

    func testPreviewRecordsEveryUnselectedEligibleIDWithoutShrinking()
        throws
    {
        let inventory = makeInventory(
            ordinary: 6,
            automation: 4,
            blocked: 2
        )
        let selected = Array(inventory.eligibleThreadIDs.prefix(2))

        let preview = try makePreview(
            inventory: inventory,
            selected: selected
        )

        XCTAssertEqual(preview.selectedThreadIDs, selected)
        XCTAssertEqual(
            preview.unselectedEligibleThreadIDs,
            Array(inventory.eligibleThreadIDs.dropFirst(2))
        )
        XCTAssertEqual(preview.blockedItems.count, 2)
        XCTAssertEqual(
            preview.selectedItems.count
                + preview.unselectedEligibleThreadIDs.count,
            inventory.eligibleItemCount
        )
    }

    func testProductLimitAccepts500AndRejects501() throws {
        let maximum = makeInventory(
            ordinary: CodexGhostRepairBulkPreview.maximumSelectedItems,
            automation: 0,
            blocked: 0
        )
        XCTAssertNoThrow(try makePreview(
            inventory: maximum,
            selected: maximum.eligibleThreadIDs
        ))

        let overLimit = makeInventory(
            ordinary: CodexGhostRepairBulkPreview.maximumSelectedItems + 1,
            automation: 0,
            blocked: 0
        )
        XCTAssertThrowsError(try makePreview(
            inventory: overLimit,
            selected: overLimit.eligibleThreadIDs
        ))
    }

    func testCurrentV152InventoryBuildsAndValidatesPreview() throws {
        let inventory = makeInventory(
            ordinary: 48,
            automation: 87,
            blocked: 0,
            unsupportedBlocked: 4,
            unconfirmed: 5,
            notGhost: 231,
            sourceLayoutIdentifier:
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v152SourceLayoutIdentifier
        )

        let preview = try makePreview(
            inventory: inventory,
            selected: inventory.eligibleThreadIDs
        )

        XCTAssertEqual(inventory.observedCatalogItemCount, 375)
        XCTAssertEqual(inventory.confirmedGhostCount, 139)
        XCTAssertEqual(inventory.eligibleItemCount, 135)
        XCTAssertEqual(inventory.blockedItemCount, 9)
        XCTAssertEqual(inventory.notGhostItemCount, 231)
        XCTAssertEqual(preview.selectedItems.count, 135)
        XCTAssertEqual(preview.blockedItems.count, 9)
        XCTAssertEqual(
            preview.blockedItems.count { $0.disposition == .blocked },
            4
        )
        XCTAssertEqual(
            preview.blockedItems.count {
                $0.blockers.contains(.unsupportedRowShape)
            },
            4
        )
        XCTAssertEqual(
            preview.blockedItems.count { $0.disposition == .unconfirmed },
            5
        )
        XCTAssertEqual(
            preview.sourceLayoutIdentifier,
            CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v152SourceLayoutIdentifier
        )
        XCTAssertNoThrow(try preview.validateForPersistence())
    }

    func testBlockedNotGhostDuplicateAndUnsortedSelectionsFailWholePreview() {
        let inventory = makeInventory(
            ordinary: 2,
            automation: 1,
            blocked: 1,
            notGhost: 1
        )
        let eligible = inventory.eligibleThreadIDs
        let blocked = inventory.items.first {
            $0.disposition == .blocked
        }!.threadID
        let notGhost = inventory.items.first {
            $0.disposition == .notGhost
        }!.threadID

        XCTAssertThrowsError(try makePreview(
            inventory: inventory,
            selected: [blocked]
        ))
        XCTAssertThrowsError(try makePreview(
            inventory: inventory,
            selected: [notGhost]
        ))
        XCTAssertThrowsError(try makePreview(
            inventory: inventory,
            selected: [eligible[0], eligible[0]]
        ))
        XCTAssertThrowsError(try makePreview(
            inventory: inventory,
            selected: [eligible[1], eligible[0]]
        ))
    }

    func testInvalidBlockedShapeReportsExactItemAndRule() {
        let invalidThreadID = threadID(2)
        let items = [
            item(
                index: 1,
                disposition: .eligible,
                category: .ordinary,
                blockers: [],
                evidenceSalt: 0
            ),
            item(
                index: 2,
                disposition: .blocked,
                category: nil,
                blockers: [.sideReferencesPresent],
                evidenceSalt: 0
            ),
        ]
        let inventory = CodexGhostRepairBulkInventory(
            snapshotReference: snapshotReference,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            items: items,
            inventoryDigest: hash(800_000)
        )

        XCTAssertThrowsError(try makePreview(
            inventory: inventory,
            selected: [items[0].threadID]
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid Ghost Repair Preview: Bulk Preview inventory validation failed: item-shape-invalid. item=\(invalidThreadID) disposition=blocked category=none blockers=side-references-present"
            )
        }
    }

    func testPreviewLifetimeMustBePositiveAndAtMost15Minutes() {
        let inventory = makeInventory(
            ordinary: 1,
            automation: 0,
            blocked: 0
        )
        let selected = inventory.eligibleThreadIDs
        XCTAssertThrowsError(try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: selected,
            previewID: UUID(),
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 1_000
        ))
        XCTAssertThrowsError(try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: selected,
            previewID: UUID(),
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 1_000
                + CodexGhostRepairBulkPreview.maximumLifetimeMilliseconds
                + 1
        ))
    }

    func testManifestDigestChangesWithSelectionAndEvidence() throws {
        let inventory = makeInventory(
            ordinary: 2,
            automation: 1,
            blocked: 1
        )
        let previewID = UUID(uuidString:
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!
        let first = try makePreview(
            inventory: inventory,
            selected: Array(inventory.eligibleThreadIDs.prefix(1)),
            previewID: previewID
        )
        let second = try makePreview(
            inventory: inventory,
            selected: Array(inventory.eligibleThreadIDs.prefix(2)),
            previewID: previewID
        )
        let changedEvidence = makeInventory(
            ordinary: 2,
            automation: 1,
            blocked: 1,
            evidenceSalt: 10_000
        )
        let third = try makePreview(
            inventory: changedEvidence,
            selected: Array(changedEvidence.eligibleThreadIDs.prefix(1)),
            previewID: previewID
        )

        XCTAssertNotEqual(first.manifestDigest, second.manifestDigest)
        XCTAssertNotEqual(first.manifestDigest, third.manifestDigest)
    }

    func testCodableRoundTripRequiresExactManifestDigest() throws {
        let inventory = makeInventory(
            ordinary: 2,
            automation: 2,
            blocked: 1
        )
        let preview = try makePreview(
            inventory: inventory,
            selected: inventory.eligibleThreadIDs
        )
        let data = try JSONEncoder().encode(preview)
        let decoded = try JSONDecoder().decode(
            CodexGhostRepairBulkPreview.self,
            from: data
        )
        XCTAssertEqual(decoded, preview)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["manifestDigest"] = hash(999_999)
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(
            CodexGhostRepairBulkPreview.self,
            from: tampered
        ))
    }

    private func makePreview(
        inventory: CodexGhostRepairBulkInventory,
        selected: [String],
        previewID: UUID = UUID(uuidString:
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!
    ) throws -> CodexGhostRepairBulkPreview {
        try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: selected,
            previewID: previewID,
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 901_000
        )
    }

    private func makeInventory(
        ordinary: Int,
        automation: Int,
        blocked: Int,
        unsupportedBlocked: Int = 0,
        unconfirmed: Int = 0,
        notGhost: Int = 0,
        evidenceSalt: Int = 0,
        sourceLayoutIdentifier: String =
            CodexGhostRepairSnapshotSourceLayout.identifier
    ) -> CodexGhostRepairBulkInventory {
        var items: [CodexGhostRepairBulkInventoryItem] = []
        var next = 1
        for _ in 0..<ordinary {
            items.append(item(
                index: next,
                disposition: .eligible,
                category: .ordinary,
                blockers: [],
                evidenceSalt: evidenceSalt
            ))
            next += 1
        }
        for _ in 0..<automation {
            items.append(item(
                index: next,
                disposition: .eligible,
                category: .automation,
                blockers: [],
                evidenceSalt: evidenceSalt
            ))
            next += 1
        }
        for _ in 0..<blocked {
            items.append(item(
                index: next,
                disposition: .blocked,
                category: .ordinary,
                blockers: [.sideReferencesPresent],
                evidenceSalt: evidenceSalt
            ))
            next += 1
        }
        for _ in 0..<unsupportedBlocked {
            items.append(item(
                index: next,
                disposition: .blocked,
                category: nil,
                blockers: [.unsupportedRowShape],
                evidenceSalt: evidenceSalt
            ))
            next += 1
        }
        for _ in 0..<unconfirmed {
            items.append(item(
                index: next,
                disposition: .unconfirmed,
                category: nil,
                blockers: [.exactReadUnavailable],
                evidenceSalt: evidenceSalt
            ))
            next += 1
        }
        for _ in 0..<notGhost {
            items.append(item(
                index: next,
                disposition: .notGhost,
                category: nil,
                blockers: [],
                evidenceSalt: evidenceSalt
            ))
            next += 1
        }
        items.sort { $0.threadID < $1.threadID }
        return CodexGhostRepairBulkInventory(
            snapshotReference: snapshotReference,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            items: items,
            inventoryDigest: hash(800_000 + evidenceSalt)
        )
    }

    private func item(
        index: Int,
        disposition: CodexGhostRepairBulkInventoryDisposition,
        category: CodexGhostRepairCategory?,
        blockers: [CodexGhostRepairBulkInventoryBlocker],
        evidenceSalt: Int
    ) -> CodexGhostRepairBulkInventoryItem {
        CodexGhostRepairBulkInventoryItem(
            threadID: threadID(index),
            disposition: disposition,
            category: category,
            blockers: blockers,
            evidenceDigest: hash(index + evidenceSalt)
        )
    }

    private func threadID(_ index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012llx", Int64(index))
    }

    private func hash(_ value: Int) -> String {
        String(format: "sha256:%064llx", Int64(value))
    }
}
