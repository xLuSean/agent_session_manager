@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class CodexGhostRepairBulkPreviewRepositoryTests: XCTestCase {
    private let requestID = UUID(
        uuidString: "11111111-2222-4333-8444-555555555555"
    )!
    private let previewID = UUID(
        uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!
    private let snapshotReference =
        "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"

    func testExact148PreviewPersistsWithImmediateAndColdReadback() throws {
        let databaseURL = try makeDatabaseURL()
        let preview = try makePreview(ordinary: 48, automation: 97, blocked: 3)
        let store = try SQLiteStateStore(databaseURL: databaseURL)

        let stored = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview
        )

        XCTAssertEqual(stored.preview.selectedItems.count, 145)
        XCTAssertEqual(stored.preview.blockedItems.count, 3)
        XCTAssertEqual(stored.preview, preview)
        XCTAssertTrue(stored.persistsPreview)
        XCTAssertFalse(stored.confirmationAuthority)
        XCTAssertFalse(stored.repairMutationAuthority)
        XCTAssertEqual(
            try store.codexGhostRepairBulkPreview(requestID: requestID),
            stored
        )
        store.close()

        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        defer { reopened.close() }
        XCTAssertEqual(
            try reopened.codexGhostRepairBulkPreview(requestID: requestID),
            stored
        )
    }

    func testSelectedOnlySourcePersistsAtomicallyAndColdReadsExactly()
        async throws
    {
        let databaseURL = try makeDatabaseURL()
        let inventory = try makeFrozenInventory(
            ordinary: 48,
            automation: 97,
            blocked: 3
        )
        let preview = try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: inventory.eligibleThreadIDs,
            previewID: previewID,
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 901_000
        )
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let stored = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            inventory: inventory
        )

        let source = try XCTUnwrap(stored.frozenSource)
        XCTAssertEqual(source.selectedThreadIDs, preview.selectedThreadIDs)
        XCTAssertEqual(source.selectedCount, 145)
        XCTAssertEqual(source.blockedOutsideBatchCount, 3)
        XCTAssertFalse(source.storesFullObservedCatalog)
        XCTAssertFalse(source.exposesPrivateRowValues)
        XCTAssertFalse(source.acceptsCallerPath)
        XCTAssertFalse(source.confirmationAuthority)
        XCTAssertFalse(source.repairMutationAuthority)
        XCTAssertTrue(source.selectedItems.allSatisfy {
            !$0.exposesPrivateRowValues
        })
        XCTAssertEqual(
            try tableRowCount(
                "codex_ghost_repair_bulk_frozen_plan_sources",
                at: databaseURL
            ),
            1
        )
        let publicInventory = String(
            data: try JSONEncoder().encode(inventory),
            encoding: .utf8
        )!
        XCTAssertFalse(publicInventory.contains("sourceFingerprintHash"))
        XCTAssertFalse(publicInventory.contains("catalogRowDigests"))
        store.close()

        let coordinator = CodexGhostRepairBulkPreviewLiveReadbackCoordinator(
            databaseURLProvider: { databaseURL }
        )
        guard case let .observed(evidence) =
            await coordinator.readback(requestID: requestID) else {
            return XCTFail("Expected selected-only cold readback")
        }
        XCTAssertEqual(evidence.preview, preview)
        XCTAssertEqual(evidence.frozenSourceDigest, source.sourceDigest)
        XCTAssertTrue(evidence.durableReadbackMatched)
        XCTAssertFalse(evidence.readsCodexData)
        XCTAssertFalse(evidence.writesFilesystem)
    }

    func testCurrentV152Exact135PreviewPersistsReadsAndPreparesChallenge()
        async throws
    {
        let databaseURL = try makeDatabaseURL()
        let inventory = try makeFrozenInventory(
            ordinary: 48,
            automation: 87,
            blocked: 4,
            unconfirmed: 5,
            notGhost: 231,
            blockedRowsAreUnsupported: true,
            sourceLayoutIdentifier:
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v152SourceLayoutIdentifier,
            desktopSchemaVersion: 34
        )
        let preview = try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: inventory.eligibleThreadIDs,
            previewID: previewID,
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 901_000
        )
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            inventory: inventory
        )
        store.close()

        let reader = CodexGhostRepairBulkPreviewLiveReadbackCoordinator(
            databaseURLProvider: { databaseURL }
        )
        guard case let .observed(evidence) =
            await reader.readback(requestID: requestID) else {
            return XCTFail("Expected current v152 exact Preview readback")
        }
        XCTAssertEqual(inventory.observedCatalogItemCount, 375)
        XCTAssertEqual(inventory.confirmedGhostCount, 139)
        XCTAssertEqual(inventory.eligibleItemCount, 135)
        XCTAssertEqual(inventory.blockedItemCount, 9)
        XCTAssertEqual(inventory.notGhostItemCount, 231)
        XCTAssertEqual(evidence.preview.selectedItems.count, 135)
        XCTAssertEqual(evidence.preview.blockedItems.count, 9)
        XCTAssertNotNil(evidence.frozenSourceDigest)
        XCTAssertTrue(evidence.durableReadbackMatched)

        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        defer { reopened.close() }
        let challenge = try reopened.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: requestID,
            generatedAtMilliseconds: 2_000
        )
        XCTAssertEqual(challenge.selectedCount, 135)
        XCTAssertEqual(challenge.ordinaryCount, 48)
        XCTAssertEqual(challenge.automationCount, 87)
        XCTAssertEqual(challenge.blockedOutsideBatchCount, 9)
        XCTAssertTrue(challenge.confirmationPhrase.hasPrefix(
            "CONFIRM BULK DELETE 135 "
        ))
        XCTAssertFalse(challenge.confirmationAuthority)
        XCTAssertFalse(challenge.repairClaimCreated)
        XCTAssertFalse(challenge.repairMutationAuthority)

        let consumption = try reopened
            .consumeCodexGhostRepairBulkConfirmation(
                savedPreviewRequestID: requestID,
                exactConfirmationPhrase: challenge.confirmationPhrase,
                confirmedAtMilliseconds: 3_000
            )
        XCTAssertTrue(consumption.newlyConfirmed)
        XCTAssertEqual(consumption.receipt.selectedCount, 135)
        XCTAssertTrue(consumption.receipt.wholeBatchConfirmationRecorded)
        XCTAssertFalse(consumption.receipt.createsRepairClaim)
        XCTAssertFalse(consumption.receipt.repairClaimCreated)
        XCTAssertFalse(consumption.receipt.repairMutationAuthority)
    }

    func testMissingSourceRejectsWholeSaveWithoutPreviewRow() throws {
        let databaseURL = try makeDatabaseURL()
        let inventory = makeInventory(ordinary: 2, automation: 0, blocked: 0)
        let preview = try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: inventory.eligibleThreadIDs,
            previewID: previewID,
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 901_000
        )
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        XCTAssertThrowsError(try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            inventory: inventory
        ))
        XCTAssertEqual(try rowCount(at: databaseURL), 0)
        XCTAssertEqual(
            try tableRowCount(
                "codex_ghost_repair_bulk_frozen_plan_sources",
                at: databaseURL
            ),
            0
        )
    }

    func testFrozenSourceTamperingFailsPreviewReadbackClosed() throws {
        let databaseURL = try makeDatabaseURL()
        let inventory = try makeFrozenInventory()
        let preview = try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: inventory.eligibleThreadIDs,
            previewID: previewID,
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 901_000
        )
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            inventory: inventory
        )

        try execute(
            "UPDATE codex_ghost_repair_bulk_frozen_plan_sources SET payload_json = '{}'",
            at: databaseURL
        )
        XCTAssertThrowsError(
            try store.codexGhostRepairBulkPreview(requestID: requestID)
        )
    }

    func testExactReplayIsIdempotentAndChangedIdentityFailsClosed()
        throws
    {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        let preview = try makePreview(
            ordinary: 3,
            automation: 2,
            blocked: 1
        )

        let first = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview
        )
        XCTAssertEqual(
            try store.saveCodexGhostRepairBulkPreview(
                requestID: requestID,
                preview: preview
            ),
            first
        )

        let changed = try makePreview(
            ordinary: 2,
            automation: 2,
            blocked: 1,
            previewID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!
        )
        XCTAssertThrowsError(try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: changed
        ))
        XCTAssertThrowsError(try store.saveCodexGhostRepairBulkPreview(
            requestID: UUID(
                uuidString: "22222222-3333-4444-8555-666666666666"
            )!,
            preview: preview
        ))
        XCTAssertEqual(try rowCount(at: databaseURL), 1)
    }

    func testTamperedPayloadAndColumnsFailDurableReadback() throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 1)
        )

        try execute(
            "UPDATE codex_ghost_repair_bulk_previews SET payload_json = '{}'",
            at: databaseURL
        )
        XCTAssertThrowsError(
            try store.codexGhostRepairBulkPreview(requestID: requestID)
        )
    }

    func testSchemaForbidsAuthorityAndSelectionAboveProductLimit()
        throws
    {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 0)
        )

        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_bulk_previews SET confirmation_authority = 1",
            at: databaseURL
        ))
        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_bulk_previews SET repair_mutation_authority = 1",
            at: databaseURL
        ))
        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_bulk_previews SET selected_count = 501",
            at: databaseURL
        ))
        XCTAssertEqual(try rowCount(at: databaseURL), 1)
    }

    func testExplicitColdReadbackIsReadOnlyAndExact() async throws {
        let databaseURL = try makeDatabaseURL()
        let preview = try makePreview(
            ordinary: 48,
            automation: 97,
            blocked: 3
        )
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let stored = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview
        )
        store.close()
        let bytesBefore = try Data(contentsOf: databaseURL)
        let modificationBefore = try FileManager.default
            .attributesOfItem(atPath: databaseURL.path)[.modificationDate]
            as? Date

        let coordinator = CodexGhostRepairBulkPreviewLiveReadbackCoordinator(
            databaseURLProvider: { databaseURL }
        )
        let outcome = await coordinator.readback(requestID: requestID)

        guard case let .observed(evidence) = outcome else {
            return XCTFail("Expected exact bulk Preview readback")
        }
        XCTAssertEqual(evidence.requestID, requestID)
        XCTAssertEqual(evidence.preview, preview)
        XCTAssertEqual(evidence.payloadHash, stored.payloadHash)
        XCTAssertTrue(evidence.durableReadbackMatched)
        XCTAssertTrue(evidence.readsManagerOwnedState)
        XCTAssertFalse(evidence.readsPublishedSnapshot)
        XCTAssertFalse(evidence.readsCodexData)
        XCTAssertFalse(evidence.writesFilesystem)
        XCTAssertFalse(evidence.confirmationAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)
        XCTAssertEqual(try Data(contentsOf: databaseURL), bytesBefore)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: databaseURL.path
            )[.modificationDate] as? Date,
            modificationBefore
        )
    }

    func testNotFoundDoesNotCreateDatabaseOrFallback() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        store.close()
        let coordinator = CodexGhostRepairBulkPreviewLiveReadbackCoordinator(
            databaseURLProvider: { databaseURL }
        )
        let notFound = await coordinator.readback(requestID: requestID)
        XCTAssertEqual(notFound, .notFound(requestID: requestID))

        let missingURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("missing.sqlite")
        let missing = CodexGhostRepairBulkPreviewLiveReadbackCoordinator(
            databaseURLProvider: { missingURL }
        )
        guard case let .unavailable(returnedID, message) =
            await missing.readback(requestID: requestID) else {
            return XCTFail("Expected path-redacted unavailable outcome")
        }
        XCTAssertEqual(returnedID, requestID)
        XCTAssertFalse(message.contains(missingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
    }

    func testExact148WholeBatchChallengeIsSingleAndColdReadable() throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let preview = try makePreview(
            ordinary: 48,
            automation: 97,
            blocked: 3
        )
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview
        )

        let challenge = try store.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: requestID,
            generatedAtMilliseconds: 2_000
        )

        XCTAssertEqual(challenge.selectedCount, 145)
        XCTAssertEqual(challenge.ordinaryCount, 48)
        XCTAssertEqual(challenge.automationCount, 97)
        XCTAssertEqual(challenge.blockedOutsideBatchCount, 3)
        XCTAssertTrue(challenge.allOrNothing)
        XCTAssertTrue(challenge.singleWholeBatchConfirmation)
        XCTAssertFalse(challenge.perItemConfirmation)
        XCTAssertFalse(challenge.confirmationAuthority)
        XCTAssertFalse(challenge.repairClaimCreated)
        XCTAssertFalse(challenge.repairMutationAuthority)
        XCTAssertTrue(challenge.confirmationPhrase.hasPrefix(
            "CONFIRM BULK DELETE 145 "
        ))
        XCTAssertEqual(
            try store.prepareCodexGhostRepairBulkChallenge(
                savedPreviewRequestID: requestID,
                generatedAtMilliseconds: 3_000
            ),
            challenge
        )
        XCTAssertThrowsError(
            try store.prepareCodexGhostRepairBulkChallenge(
                savedPreviewRequestID: requestID,
                generatedAtMilliseconds: 901_000
            )
        )
        store.close()

        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        defer { reopened.close() }
        XCTAssertEqual(
            try reopened.codexGhostRepairBulkChallenge(
                savedPreviewRequestID: requestID
            ),
            challenge
        )
    }

    func testChallengeRequiresExistingUnexpiredPreview() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        store.close()
        let coordinator = CodexGhostRepairBulkConfirmationLiveCoordinator(
            databaseURLProvider: { databaseURL },
            nowMilliseconds: { 2_000 }
        )
        let missing = await coordinator.prepareChallenge(
            savedPreviewRequestID: requestID
        )
        XCTAssertEqual(missing, .notFound(requestID: requestID))

        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        _ = try reopened.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 0)
        )
        reopened.close()
        let expired = CodexGhostRepairBulkConfirmationLiveCoordinator(
            databaseURLProvider: { databaseURL },
            nowMilliseconds: { 901_000 }
        )
        guard case let .unavailable(returnedID, _) =
            await expired.prepareChallenge(savedPreviewRequestID: requestID)
        else {
            return XCTFail("Expected expired Preview to fail closed")
        }
        XCTAssertEqual(returnedID, requestID)
    }

    func testChallengeTamperingAndAuthorityColumnsFailClosed() throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 1)
        )
        _ = try store.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: requestID,
            generatedAtMilliseconds: 2_000
        )

        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_challenges SET confirmation_authority = 1",
            at: databaseURL
        ))
        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_challenges SET repair_claim_created = 1",
            at: databaseURL
        ))
        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_challenges SET repair_mutation_authority = 1",
            at: databaseURL
        ))
        try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_challenges SET confirmation_phrase = 'tampered'",
            at: databaseURL
        )
        XCTAssertThrowsError(
            try store.codexGhostRepairBulkChallenge(
                savedPreviewRequestID: requestID
            )
        )
    }

    func testExact148ConfirmationCreatesOneReceiptAndReplayIsReadOnly()
        throws
    {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let preview = try makePreview(
            ordinary: 48,
            automation: 97,
            blocked: 3
        )
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview
        )
        let challenge = try store.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: requestID,
            generatedAtMilliseconds: 2_000
        )

        let first = try store.consumeCodexGhostRepairBulkConfirmation(
            savedPreviewRequestID: requestID,
            exactConfirmationPhrase: challenge.confirmationPhrase,
            confirmedAtMilliseconds: 3_000
        )
        XCTAssertTrue(first.newlyConfirmed)
        XCTAssertEqual(first.receipt.selectedCount, 145)
        XCTAssertTrue(first.receipt.wholeBatchConfirmationRecorded)
        XCTAssertFalse(first.receipt.createsRepairClaim)
        XCTAssertFalse(first.receipt.repairClaimCreated)
        XCTAssertFalse(first.receipt.repairMutationAuthority)
        XCTAssertFalse(first.receipt.automaticRetryAllowed)
        XCTAssertEqual(
            try store.codexGhostRepairBulkConfirmationReceipt(
                savedPreviewRequestID: requestID
            ),
            first.receipt
        )
        XCTAssertEqual(
            try store.codexGhostRepairBulkConfirmationReceipt(
                receiptID: first.receipt.receiptID
            ),
            first.receipt
        )
        XCTAssertNil(
            try store.codexGhostRepairBulkConfirmationReceipt(
                receiptID: UUID()
            )
        )

        let replay = try store.consumeCodexGhostRepairBulkConfirmation(
            savedPreviewRequestID: requestID,
            exactConfirmationPhrase: challenge.confirmationPhrase,
            confirmedAtMilliseconds: 999_000
        )
        XCTAssertFalse(replay.newlyConfirmed)
        XCTAssertEqual(replay.receipt, first.receipt)
        store.close()

        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        defer { reopened.close() }
        XCTAssertEqual(
            try reopened.codexGhostRepairBulkConfirmationReceipt(
                savedPreviewRequestID: requestID
            ),
            first.receipt
        )
        XCTAssertEqual(
            try reopened.codexGhostRepairBulkConfirmationReceipt(
                receiptID: first.receipt.receiptID
            ),
            first.receipt
        )
        XCTAssertEqual(
            try tableRowCount(
                "codex_ghost_repair_bulk_confirmation_receipts",
                at: databaseURL
            ),
            1
        )
    }

    func testWrongOrExpiredConfirmationCreatesNoReceipt() throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 0)
        )
        let challenge = try store.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: requestID,
            generatedAtMilliseconds: 2_000
        )

        XCTAssertThrowsError(
            try store.consumeCodexGhostRepairBulkConfirmation(
                savedPreviewRequestID: requestID,
                exactConfirmationPhrase: "CONFIRM SOMETHING ELSE",
                confirmedAtMilliseconds: 3_000
            )
        ) { error in
            guard case PersistentStateError.confirmationMismatch = error else {
                return XCTFail("Expected exact-phrase mismatch")
            }
        }
        XCTAssertThrowsError(
            try store.consumeCodexGhostRepairBulkConfirmation(
                savedPreviewRequestID: requestID,
                exactConfirmationPhrase: challenge.confirmationPhrase,
                confirmedAtMilliseconds: 901_000
            )
        ) { error in
            guard case CodexGhostRepairError.previewExpired = error else {
                return XCTFail("Expected expired whole-batch challenge")
            }
        }
        XCTAssertNil(try store.codexGhostRepairBulkConfirmationReceipt(
            savedPreviewRequestID: requestID
        ))
        XCTAssertEqual(
            try tableRowCount(
                "codex_ghost_repair_bulk_confirmation_receipts",
                at: databaseURL
            ),
            0
        )
    }

    func testReceiptCoordinatorSeparatesDefinitiveRejectionFromUnknownOutcome()
        async throws
    {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 0)
        )
        let challenge = try store.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: requestID,
            generatedAtMilliseconds: 2_000
        )
        store.close()
        let coordinator =
            CodexGhostRepairBulkConfirmationReceiptLiveCoordinator(
                databaseURLProvider: { databaseURL },
                nowMilliseconds: { 3_000 }
            )

        guard case let .rejected(rejectedRequestID, _) = await coordinator
            .confirm(
                savedPreviewRequestID: requestID,
                exactConfirmationPhrase: "WRONG PHRASE"
            ) else {
            return XCTFail("Expected a definitive phrase rejection")
        }
        XCTAssertEqual(rejectedRequestID, requestID)
        guard case let .confirmed(receipt) = await coordinator.confirm(
            savedPreviewRequestID: requestID,
            exactConfirmationPhrase: challenge.confirmationPhrase
        ) else {
            return XCTFail("Expected corrected phrase to confirm exactly once")
        }
        XCTAssertEqual(receipt.savedPreviewRequestID, requestID)

        let failingCoordinator =
            CodexGhostRepairBulkConfirmationReceiptLiveCoordinator(
                databaseURLProvider: {
                    throw CocoaError(.fileNoSuchFile)
                },
                nowMilliseconds: { 3_000 }
            )
        guard case let .outcomeUnknown(unknownRequestID, message) =
            await failingCoordinator.confirm(
                savedPreviewRequestID: requestID,
                exactConfirmationPhrase: challenge.confirmationPhrase
            ) else {
            return XCTFail("Expected an indeterminate storage failure")
        }
        XCTAssertEqual(unknownRequestID, requestID)
        XCTAssertTrue(message.contains("outcome is unknown"))
    }

    func testReceiptRecoveryReadsExactDurableReceiptAfterChallengeExpiry()
        async throws
    {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 0)
        )
        let challenge = try store.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: requestID,
            generatedAtMilliseconds: 2_000
        )
        let consumption = try store.consumeCodexGhostRepairBulkConfirmation(
            savedPreviewRequestID: requestID,
            exactConfirmationPhrase: challenge.confirmationPhrase,
            confirmedAtMilliseconds: 3_000
        )
        store.close()
        let countsBefore = try [
            "codex_ghost_repair_bulk_previews",
            "codex_ghost_repair_bulk_confirmation_challenges",
            "codex_ghost_repair_bulk_confirmation_receipts",
            "codex_ghost_repair_bulk_execution_journal",
            "codex_ghost_repair_bulk_live_execution_journal",
        ].map { try tableRowCount($0, at: databaseURL) }
        let coordinator =
            CodexGhostRepairBulkConfirmationReceiptRecoveryLiveCoordinator(
                databaseURLProvider: { databaseURL },
                nowMilliseconds: { 999_000 }
            )
        let request = CodexGhostRepairBulkConfirmationReceiptRecoveryRequest(
            challenge: challenge
        )

        let recovered = await coordinator.recoverReceipt(request: request)
        XCTAssertEqual(
            recovered,
            .confirmed(request: request, receipt: consumption.receipt)
        )
        XCTAssertEqual(
            try [
                "codex_ghost_repair_bulk_previews",
                "codex_ghost_repair_bulk_confirmation_challenges",
                "codex_ghost_repair_bulk_confirmation_receipts",
                "codex_ghost_repair_bulk_execution_journal",
                "codex_ghost_repair_bulk_live_execution_journal",
            ].map { try tableRowCount($0, at: databaseURL) },
            countsBefore
        )
    }

    func testReceiptRecoveryDistinguishesMissingAbsentExpiredAndBadPreview()
        async throws
    {
        let missingURL = try makeDatabaseURL()
        let challengeDatabaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: challengeDatabaseURL)
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 0)
        )
        let challenge = try store.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: requestID,
            generatedAtMilliseconds: 2_000
        )
        store.close()
        let request = CodexGhostRepairBulkConfirmationReceiptRecoveryRequest(
            challenge: challenge
        )

        let missing =
            CodexGhostRepairBulkConfirmationReceiptRecoveryLiveCoordinator(
                databaseURLProvider: { missingURL },
                fileExists: { _ in false }
            )
        guard case let .recoveryRequired(_, missingReason, _) =
                await missing.recoverReceipt(request: request) else {
            return XCTFail("Expected missing database to remain unresolved")
        }
        XCTAssertEqual(missingReason, .databaseMissing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))

        let missingChallengeURL = try makeDatabaseURL()
        let missingChallengeStore = try SQLiteStateStore(
            databaseURL: missingChallengeURL
        )
        _ = try missingChallengeStore.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 0)
        )
        missingChallengeStore.close()
        let missingChallenge =
            CodexGhostRepairBulkConfirmationReceiptRecoveryLiveCoordinator(
                databaseURLProvider: { missingChallengeURL }
            )
        guard case let .recoveryRequired(_, missingChallengeReason, _) =
                await missingChallenge.recoverReceipt(request: request) else {
            return XCTFail("Expected missing challenge to remain unresolved")
        }
        XCTAssertEqual(missingChallengeReason, .challengeMissing)

        let absent =
            CodexGhostRepairBulkConfirmationReceiptRecoveryLiveCoordinator(
                databaseURLProvider: { challengeDatabaseURL },
                nowMilliseconds: { 3_000 }
            )
        guard case let .recoveryRequired(_, absentReason, _) =
                await absent.recoverReceipt(request: request) else {
            return XCTFail("Expected absent receipt to remain unresolved")
        }
        XCTAssertEqual(absentReason, .receiptAbsent)

        let expired =
            CodexGhostRepairBulkConfirmationReceiptRecoveryLiveCoordinator(
                databaseURLProvider: { challengeDatabaseURL },
                nowMilliseconds: { 999_000 }
            )
        guard case let .recoveryRequired(_, expiredReason, _) =
                await expired.recoverReceipt(request: request) else {
            return XCTFail("Expected expired challenge to remain unresolved")
        }
        XCTAssertEqual(expiredReason, .challengeExpiredWithoutReceipt)

        try execute(
            "UPDATE codex_ghost_repair_bulk_previews SET payload_hash = 'tampered'",
            at: challengeDatabaseURL
        )
        guard case let .recoveryRequired(_, tamperedReason, _) =
                await absent.recoverReceipt(request: request) else {
            return XCTFail("Expected tampered Preview to fail closed")
        }
        XCTAssertEqual(tamperedReason, .evidenceInvalid)
        try execute(
            "DELETE FROM codex_ghost_repair_bulk_previews",
            at: challengeDatabaseURL
        )
        guard case let .recoveryRequired(_, missingPreviewReason, _) =
                await absent.recoverReceipt(request: request) else {
            return XCTFail("Expected missing Preview to fail closed")
        }
        XCTAssertEqual(missingPreviewReason, .evidenceInvalid)
    }

    func testReceiptRecoveryHandsExecutionOwnedReceiptToRecoveryOnly()
        async throws
    {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 0)
        )
        let challenge = try store.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: requestID,
            generatedAtMilliseconds: 2_000
        )
        let receipt = try store.consumeCodexGhostRepairBulkConfirmation(
            savedPreviewRequestID: requestID,
            exactConfirmationPhrase: challenge.confirmationPhrase,
            confirmedAtMilliseconds: 3_000
        ).receipt
        store.close()
        try execute(
            """
            INSERT INTO codex_ghost_repair_bulk_execution_journal (
                operation_id, plan_digest, confirmation_receipt_digest,
                draft_digest, selected_count, phase, payload_json,
                payload_hash, mutation_attempt_count,
                automatic_retry_allowed, automatic_restore_allowed,
                silent_selection_shrink_allowed
            ) VALUES (
                '\(receipt.operationID.uuidString.lowercased())',
                'plan', '\(receipt.receiptDigest)', 'draft',
                \(receipt.selectedCount), 'claimed', '{}', 'payload',
                0, 0, 0, 0
            )
            """,
            at: databaseURL
        )
        let coordinator =
            CodexGhostRepairBulkConfirmationReceiptRecoveryLiveCoordinator(
                databaseURLProvider: { databaseURL },
                nowMilliseconds: { 3_000 }
            )
        let request = CodexGhostRepairBulkConfirmationReceiptRecoveryRequest(
            challenge: challenge
        )

        guard case let .executionRecoveryRequired(
            returnedRequest,
            returnedReceipt,
            phase,
            _
        ) = await coordinator.recoverReceipt(request: request) else {
            return XCTFail("Expected execution-owned recovery evidence")
        }
        XCTAssertEqual(returnedRequest, request)
        XCTAssertEqual(returnedReceipt, receipt)
        XCTAssertEqual(phase, .claimed)

        try execute(
            "UPDATE codex_ghost_repair_bulk_execution_journal SET phase = 'attempted', mutation_attempt_count = 1",
            at: databaseURL
        )
        guard case let .executionRecoveryRequired(_, attemptedReceipt, attemptedPhase, _) =
                await coordinator.recoverReceipt(request: request) else {
            return XCTFail("Expected attempted journal to remain recovery-only")
        }
        XCTAssertEqual(attemptedReceipt, receipt)
        XCTAssertEqual(attemptedPhase, .attempted)
    }

    func testReceiptTamperingAndAuthorityColumnsFailClosed() throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: makePreview(ordinary: 2, automation: 1, blocked: 1)
        )
        let challenge = try store.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: requestID,
            generatedAtMilliseconds: 2_000
        )
        _ = try store.consumeCodexGhostRepairBulkConfirmation(
            savedPreviewRequestID: requestID,
            exactConfirmationPhrase: challenge.confirmationPhrase,
            confirmedAtMilliseconds: 3_000
        )

        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_receipts SET repair_claim_created = 1",
            at: databaseURL
        ))
        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_receipts SET repair_mutation_authority = 1",
            at: databaseURL
        ))
        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_receipts SET automatic_retry_allowed = 1",
            at: databaseURL
        ))
        try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_receipts SET confirmation_phrase_hash = 'sha256:0000000000000000000000000000000000000000000000000000000000000000'",
            at: databaseURL
        )
        XCTAssertThrowsError(
            try store.codexGhostRepairBulkConfirmationReceipt(
                savedPreviewRequestID: requestID
            )
        )
    }

    private func makePreview(
        ordinary: Int,
        automation: Int,
        blocked: Int,
        previewID: UUID? = nil
    ) throws -> CodexGhostRepairBulkPreview {
        let inventory = makeInventory(
            ordinary: ordinary,
            automation: automation,
            blocked: blocked
        )
        return try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: inventory.eligibleThreadIDs,
            previewID: previewID ?? self.previewID,
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 901_000
        )
    }

    private func makeFrozenInventory(
        ordinary: Int = 1,
        automation: Int = 1,
        blocked: Int = 1,
        unconfirmed: Int = 0,
        notGhost: Int = 0,
        blockedRowsAreUnsupported: Bool = false,
        sourceLayoutIdentifier: String =
            CodexGhostRepairSnapshotSourceLayout.identifier,
        desktopSchemaVersion: Int32 = 32
    ) throws
        -> CodexGhostRepairBulkInventory
    {
        let itemCount = ordinary + automation + blocked
            + unconfirmed + notGhost
        let identifiers = (1...itemCount).map { index in
            String(
                format: "00000000-0000-4000-8000-%012llx",
                Int64(index)
            )
        }
        let targets = identifiers.enumerated().map { index, threadID in
            let isAutomation = index >= ordinary
                && index < ordinary + automation
            let isBlocked = index >= ordinary + automation
                && index < ordinary + automation + blocked
            let rowContract: CodexGhostRepairSnapshotAnalysisRowContract =
                if blockedRowsAreUnsupported && isBlocked {
                    .unsupported
                } else if isAutomation {
                    .categoryBEligible
                } else {
                    .categoryAEligible
                }
            return CodexGhostRepairSnapshotAnalysisTargetEvidence(
                threadID: threadID,
                catalogRowDigests: [hash(index + 101)],
                automationRunRowDigests: isAutomation
                    ? [hash(index + 1_001)] : [],
                automationStableFieldsDigests: isAutomation
                    ? [hash(index + 1_501)] : [],
                automationDefinitionRowDigests: isAutomation
                    ? [hash(index + 2_001)] : [],
                references: .init(
                    inbox: 0, timeline: 0, summaries: 0,
                    canonicalState: 0, threadTurns: 0,
                    threadItems: 0, historyProjection: 0
                ),
                rowContract: rowContract
            )
        }
        let protections = identifiers.enumerated().map { index, threadID in
            let isBlocked = index >= ordinary + automation
                && index < ordinary + automation + blocked
            let isUnconfirmed = index >= ordinary + automation + blocked
                && index < ordinary + automation + blocked + unconfirmed
            let isNotGhost = index
                >= ordinary + automation + blocked + unconfirmed
            return CodexGhostRepairProtectionEvidence(
                threadID: threadID,
                inventoryComplete: true,
                activeInventoryPresent: isNotGhost,
                archivedInventoryPresent: false,
                exactReadNotLoaded: !isUnconfirmed && !isNotGhost,
                exactReadErrorCode: isUnconfirmed || isNotGhost ? 0 : -32600,
                pinned: isBlocked && !blockedRowsAreUnsupported,
                descendantCount: 0
            )
        }
        let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence] = [
            .init(database: .desktop, schemaVersion: desktopSchemaVersion,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
            .init(database: .summaries, schemaVersion: 2,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
            .init(database: .state, schemaVersion: 0,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
            .init(database: .threadHistory, schemaVersion: 0,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
        ]
        return try CodexGhostRepairBulkInventoryBuilder.build(input: .init(
            snapshotReference: snapshotReference,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            sourceFingerprintHash: hash(700_001),
            manifestHash: hash(700_002),
            databases: databases,
            targets: targets,
            protectionEvidence: protections,
            authority: .init(
                catalogRevision: 10,
                observationSequence: 20,
                watermarkUpdatedAt: 30,
                metadataRowDigest: hash(700_003),
                localSyncRowDigest: hash(700_004)
            )
        ))
    }

    private func makeInventory(
        ordinary: Int,
        automation: Int,
        blocked: Int
    ) -> CodexGhostRepairBulkInventory {
        var items: [CodexGhostRepairBulkInventoryItem] = []
        var next = 1
        for _ in 0..<ordinary {
            items.append(item(
                next,
                disposition: .eligible,
                category: .ordinary,
                blockers: []
            ))
            next += 1
        }
        for _ in 0..<automation {
            items.append(item(
                next,
                disposition: .eligible,
                category: .automation,
                blockers: []
            ))
            next += 1
        }
        for _ in 0..<blocked {
            items.append(item(
                next,
                disposition: .blocked,
                category: .ordinary,
                blockers: [.sideReferencesPresent]
            ))
            next += 1
        }
        items.sort { $0.threadID < $1.threadID }
        return .init(
            snapshotReference: snapshotReference,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            items: items,
            inventoryDigest: hash(800_000)
        )
    }

    private func item(
        _ index: Int,
        disposition: CodexGhostRepairBulkInventoryDisposition,
        category: CodexGhostRepairCategory?,
        blockers: [CodexGhostRepairBulkInventoryBlocker]
    ) -> CodexGhostRepairBulkInventoryItem {
        .init(
            threadID: String(
                format: "00000000-0000-4000-8000-%012llx",
                Int64(index)
            ),
            disposition: disposition,
            category: category,
            blockers: blockers,
            evidenceDigest: hash(index)
        )
    }

    private func hash(_ value: Int) -> String {
        String(format: "sha256:%064llx", Int64(value))
    }

    private func makeDatabaseURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root.appendingPathComponent("manager.sqlite3")
    }

    private func rowCount(at databaseURL: URL) throws -> Int {
        try tableRowCount(
            "codex_ghost_repair_bulk_previews",
            at: databaseURL
        )
    }

    private func tableRowCount(
        _ table: String,
        at databaseURL: URL
    ) throws -> Int {
        precondition(table.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
        return try withDatabase(at: databaseURL) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT COUNT(*) FROM \(table)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw sqliteError(database)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(database)
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func execute(_ sql: String, at databaseURL: URL) throws {
        try withDatabase(at: databaseURL) { database in
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw sqliteError(database)
            }
        }
    }

    private func withDatabase<T>(
        at databaseURL: URL,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "SQLite", code: Int(result))
        }
        defer { sqlite3_close_v2(database) }
        return try body(database)
    }

    private func sqliteError(_ database: OpaquePointer) -> NSError {
        NSError(
            domain: "SQLite",
            code: Int(sqlite3_errcode(database)),
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(cString: sqlite3_errmsg(database)),
            ]
        )
    }
}
