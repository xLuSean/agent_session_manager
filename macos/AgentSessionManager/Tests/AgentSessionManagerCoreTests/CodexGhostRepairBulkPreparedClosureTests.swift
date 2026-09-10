@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class CodexGhostRepairBulkPreparedClosureTests: XCTestCase {
    func testExpiredExact148PreparedOperationClosesWithoutCodexIOOrReplay()
        async throws
    {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 148)
        let runner = fixture.liveCoordinator()
        _ = try await runner.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let codexBefore = try sourceBytes(fixture)
        let coordinator = makeCoordinator(fixture, now: 20_000)
        let identity = identity(fixture)

        guard case let .ready(preview) = await coordinator.reviewClosure(
            identity: identity
        ) else { return XCTFail("Expected an exact closure review.") }
        XCTAssertEqual(preview.selectedItems.count, 148)
        XCTAssertEqual(
            preview.selectedItems.map(\.threadID),
            fixture.livePlan.selectedThreadIDs
        )
        XCTAssertGreaterThan(20_000, fixture.livePlan.expiresAtMilliseconds)

        guard case let .closed(summary, closure, newlyClosed) =
            await coordinator.closePreparedOperation(preview) else {
            return XCTFail("Expected manager-only prepared closure.")
        }
        XCTAssertTrue(newlyClosed)
        XCTAssertEqual(summary.phase, .closedBeforeAttempt)
        XCTAssertEqual(summary.mutationAttemptCount, 0)
        XCTAssertFalse(summary.hasTerminalReport)
        XCTAssertEqual(closure.selectedItems, preview.selectedItems)
        XCTAssertEqual(closure.reviewDigest, preview.reviewDigest)
        XCTAssertEqual(
            closure.expectedPreparedJournalPayloadHash,
            preview.expectedJournalPayloadHash
        )
        XCTAssertEqual(try sourceBytes(fixture), codexBefore)

        let reader = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { fixture.managerStateURL }
        )
        guard case let .closedBeforeAttempt(readSummary, readClosure) =
            await reader.readOperation(identity: identity) else {
            return XCTFail("Expected durable typed closure readback.")
        }
        XCTAssertEqual(readSummary, summary)
        XCTAssertEqual(readClosure, closure)
        await XCTAssertThrowsErrorAsync {
            _ = try await runner.prepare(
                plan: fixture.livePlan,
                confirmationReceipt: fixture.confirmationReceipt
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await runner.execute(
                requestID: fixture.livePlan.requestID,
                expectedPlanDigest: fixture.livePlan.planDigest
            )
        }
        XCTAssertEqual(try sourceBytes(fixture), codexBefore)
    }

    func testClaimWinningAfterReviewMakesClosureNotClosable() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        let runner = fixture.liveCoordinator()
        _ = try await runner.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = makeCoordinator(fixture, now: 1_800)
        guard case let .ready(preview) = await coordinator.reviewClosure(
            identity: identity(fixture)
        ) else { return XCTFail("Expected review.") }
        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        _ = try store.claimCodexGhostRepairBulkLiveExecution(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest,
            claimID: UUID(),
            claimedAtMilliseconds: 1_900
        )
        store.close()

        guard case let .notClosable(summary, _) =
            await coordinator.closePreparedOperation(preview) else {
            return XCTFail("A real claim must win over stale closure review.")
        }
        XCTAssertEqual(summary.phase, .claimed)
        XCTAssertEqual(summary.mutationAttemptCount, 0)
    }

    func testClockRollbackAndLegacyConflictLeavePreparedUnchanged() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        _ = try await fixture.liveCoordinator().prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let reviewCoordinator = makeCoordinator(fixture, now: 1_800)
        guard case let .ready(preview) = await reviewCoordinator.reviewClosure(
            identity: identity(fixture)
        ) else { return XCTFail("Expected review.") }
        let rollback = makeCoordinator(fixture, now: 1_799)
        guard case .notClosable = await rollback.closePreparedOperation(preview)
        else { return XCTFail("Backward clock must fail closed.") }

        try execute(
            """
            INSERT INTO codex_ghost_repair_bulk_execution_journal (
              operation_id, plan_digest, confirmation_receipt_digest,
              draft_digest, selected_count, phase, payload_json, payload_hash
            ) VALUES (?, 'legacy-plan', ?, 'legacy-draft', 2,
                      'prepared', '{}', 'legacy-hash')
            """,
            bindings: [
                fixture.confirmationReceipt.operationID.uuidString.lowercased(),
                fixture.confirmationReceipt.receiptDigest,
            ],
            at: fixture.managerStateURL
        )
        guard case let .notClosable(summary, _) =
            await reviewCoordinator.reviewClosure(identity: identity(fixture))
        else { return XCTFail("Legacy ownership must block closure.") }
        XCTAssertEqual(summary.phase, .prepared)
        XCTAssertEqual(try phase(fixture), "prepared")
    }

    func testExactPayloadHashCASRejectsValidFormattingChangeAfterReview()
        async throws
    {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        _ = try await fixture.liveCoordinator().prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = makeCoordinator(fixture, now: 1_800)
        let receiptHash = try text(
            "SELECT payload_hash FROM codex_ghost_repair_bulk_confirmation_receipts",
            at: fixture.managerStateURL
        )
        try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_receipts SET payload_hash = 'tampered'",
            at: fixture.managerStateURL
        )
        guard case .unavailable = await coordinator.reviewClosure(
            identity: identity(fixture)
        ) else { return XCTFail("Prepared receipt tamper must block review.") }
        try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_receipts SET payload_hash = ?",
            bindings: [receiptHash],
            at: fixture.managerStateURL
        )
        guard case let .ready(preview) = await coordinator.reviewClosure(
            identity: identity(fixture)
        ) else { return XCTFail("Expected review.") }
        let original = try text(
            "SELECT payload_json FROM codex_ghost_repair_bulk_live_execution_journal",
            at: fixture.managerStateURL
        )
        let reformatted = " \n" + original
        let replacementHash = SQLiteStateStore.hashBulkPreviewPayload(reformatted)
        try execute(
            "UPDATE codex_ghost_repair_bulk_live_execution_journal SET payload_json = ?, payload_hash = ?",
            bindings: [reformatted, replacementHash],
            at: fixture.managerStateURL
        )

        guard case .notClosable = await coordinator.closePreparedOperation(preview)
        else { return XCTFail("Stale exact payload hash must reject closure.") }
        XCTAssertEqual(try phase(fixture), "prepared")
        XCTAssertEqual(
            try text(
                "SELECT payload_hash FROM codex_ghost_repair_bulk_live_execution_journal",
                at: fixture.managerStateURL
            ),
            replacementHash
        )
    }

    func testReceiptTamperBlocksReviewAndClosedColdReadback() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        _ = try await fixture.liveCoordinator().prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = makeCoordinator(fixture, now: 1_800)
        guard case let .ready(preview) = await coordinator.reviewClosure(
            identity: identity(fixture)
        ) else { return XCTFail("Expected review.") }
        guard case .closed = await coordinator.closePreparedOperation(preview)
        else { return XCTFail("Expected closure.") }
        try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_receipts SET payload_hash = 'tampered'",
            at: fixture.managerStateURL
        )
        guard case .unavailable = await coordinator.reviewClosure(
            identity: identity(fixture)
        ) else { return XCTFail("Tampered lineage must block review.") }
        let recovery = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { fixture.managerStateURL }
        )
        guard case .unavailable = await recovery.readOperation(
            identity: identity(fixture)
        ) else { return XCTFail("Tampered lineage must block cold closure readback.") }
    }

    func testPostCommitFailureReturnsPersistenceUncertainThenDurableClosure()
        async throws
    {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        _ = try await fixture.liveCoordinator().prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let normal = makeCoordinator(fixture, now: 1_800)
        guard case let .ready(preview) = await normal.reviewClosure(
            identity: identity(fixture)
        ) else { return XCTFail("Expected review.") }
        let faulted = CodexGhostRepairBulkPreparedClosureLiveCoordinator(
            databaseURLProvider: { fixture.managerStateURL },
            operationExclusion: .init(databaseURL: fixture.managerStateURL),
            nowMilliseconds: { 1_900 },
            makeUUID: { UUID() },
            afterFinalizationForTesting: {
                throw CodexGhostRepairError.injectedInterruption
            }
        )
        guard case .persistenceUncertain =
            await faulted.closePreparedOperation(preview) else {
            return XCTFail("Post-COMMIT fault must not claim no change.")
        }
        let recovery = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { fixture.managerStateURL }
        )
        guard case .closedBeforeAttempt = await recovery.readOperation(
            identity: identity(fixture)
        ) else { return XCTFail("Exact durable read must resolve committed closure.") }
    }

    func testWrongIdentityReceiptAndSelectedItemsNeverChangePreparedRow()
        async throws
    {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        _ = try await fixture.liveCoordinator().prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = makeCoordinator(fixture, now: 1_800)
        guard case let .ready(original) = await coordinator.reviewClosure(
            identity: identity(fixture)
        ) else { return XCTFail("Expected review.") }
        let hashBefore = try text(
            "SELECT payload_hash FROM codex_ghost_repair_bulk_live_execution_journal",
            at: fixture.managerStateURL
        )
        let wrongIdentity = try CodexGhostRepairBulkPreparedClosurePreview(
            identity: .init(
                requestID: original.identity.requestID,
                operationID: UUID()
            ),
            confirmationReceiptID: original.confirmationReceiptID,
            selectedItems: original.selectedItems,
            planDigest: original.planDigest,
            confirmationReceiptDigest: original.confirmationReceiptDigest,
            backupReceiptDigest: original.backupReceiptDigest,
            expectedJournalPayloadHash: original.expectedJournalPayloadHash,
            preparedAtMilliseconds: original.preparedAtMilliseconds,
            closureReviewID: original.closureReviewID,
            reviewedAtMilliseconds: original.reviewedAtMilliseconds
        )
        guard case .notFound = await coordinator.closePreparedOperation(
            wrongIdentity
        ) else { return XCTFail("Wrong operation identity must not close.") }
        let wrongReceipt = try CodexGhostRepairBulkPreparedClosurePreview(
            identity: original.identity,
            confirmationReceiptID: UUID(),
            selectedItems: original.selectedItems,
            planDigest: original.planDigest,
            confirmationReceiptDigest: original.confirmationReceiptDigest,
            backupReceiptDigest: original.backupReceiptDigest,
            expectedJournalPayloadHash: original.expectedJournalPayloadHash,
            preparedAtMilliseconds: original.preparedAtMilliseconds,
            closureReviewID: original.closureReviewID,
            reviewedAtMilliseconds: original.reviewedAtMilliseconds
        )
        guard case .notClosable = await coordinator.closePreparedOperation(
            wrongReceipt
        ) else { return XCTFail("Wrong receipt must not close.") }
        var wrongItems = original.selectedItems
        wrongItems[0] = .init(
            threadID: wrongItems[0].threadID + "-other",
            category: wrongItems[0].category
        )
        let wrongSelection = try CodexGhostRepairBulkPreparedClosurePreview(
            identity: original.identity,
            confirmationReceiptID: original.confirmationReceiptID,
            selectedItems: wrongItems,
            planDigest: original.planDigest,
            confirmationReceiptDigest: original.confirmationReceiptDigest,
            backupReceiptDigest: original.backupReceiptDigest,
            expectedJournalPayloadHash: original.expectedJournalPayloadHash,
            preparedAtMilliseconds: original.preparedAtMilliseconds,
            closureReviewID: original.closureReviewID,
            reviewedAtMilliseconds: original.reviewedAtMilliseconds
        )
        guard case .notClosable = await coordinator.closePreparedOperation(
            wrongSelection
        ) else { return XCTFail("Wrong selected item must not close.") }
        XCTAssertEqual(try phase(fixture), "prepared")
        XCTAssertEqual(
            try text(
                "SELECT payload_hash FROM codex_ghost_repair_bulk_live_execution_journal",
                at: fixture.managerStateURL
            ),
            hashBefore
        )
    }

    func testBusyLeaseLeavesPreparedRowUnchanged() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        _ = try await fixture.liveCoordinator().prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = makeCoordinator(fixture, now: 1_800)
        guard case let .ready(preview) = await coordinator.reviewClosure(
            identity: identity(fixture)
        ) else { return XCTFail("Expected review.") }
        let held = try CodexGhostRepairBulkOperationExclusion(
            databaseURL: fixture.managerStateURL
        ).acquire()
        defer { held.release() }
        guard case .unavailable = await coordinator.closePreparedOperation(preview)
        else { return XCTFail("Busy exclusion must fail closed.") }
        XCTAssertEqual(try phase(fixture), "prepared")
    }

    func testMissingDatabaseDoesNotBootstrapAndVersionNineteenIsNotMigrated()
        async throws
    {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("closure-missing-\(UUID().uuidString)")
        let missingDatabase = missingRoot.appendingPathComponent("state.sqlite")
        let missing = CodexGhostRepairBulkPreparedClosureLiveCoordinator(
            databaseURLProvider: { missingDatabase },
            operationExclusion: .init(databaseURL: missingDatabase)
        )
        let unknown = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: UUID(), operationID: UUID()
        )
        guard case .notFound = await missing.reviewClosure(identity: unknown)
        else { return XCTFail("Missing database must be not found.") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path))

        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        _ = try await fixture.liveCoordinator().prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        try execute("PRAGMA user_version = 19", at: fixture.managerStateURL)
        let currentOnly = makeCoordinator(fixture, now: 1_800)
        guard case .unavailable = await currentOnly.reviewClosure(
            identity: identity(fixture)
        ) else { return XCTFail("Read-only review must reject old schema.") }
        XCTAssertEqual(
            try integer("PRAGMA user_version", at: fixture.managerStateURL),
            19
        )
    }

    private func makeCoordinator(
        _ fixture: BulkShippingCompositionTestFixture.Value,
        now: Int64
    ) -> CodexGhostRepairBulkPreparedClosureLiveCoordinator {
        .init(
            databaseURLProvider: { fixture.managerStateURL },
            operationExclusion: .init(databaseURL: fixture.managerStateURL),
            nowMilliseconds: { now },
            makeUUID: { UUID() }
        )
    }

    private func identity(
        _ fixture: BulkShippingCompositionTestFixture.Value
    ) -> CodexGhostRepairBulkRecoveryOperationIdentity {
        .init(
            requestID: fixture.livePlan.requestID,
            operationID: fixture.confirmationReceipt.operationID
        )
    }

    private func phase(
        _ fixture: BulkShippingCompositionTestFixture.Value
    ) throws -> String {
        try text(
            "SELECT phase FROM codex_ghost_repair_bulk_live_execution_journal",
            at: fixture.managerStateURL
        )
    }

    private func sourceBytes(
        _ fixture: BulkShippingCompositionTestFixture.Value
    ) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for member in CodexGhostRepairSnapshotCanonicalFile.allCases {
            let url = member.sourceURL(
                codexHomeURL: fixture.codexHome,
                sqliteRootURL: fixture.codexHome.appendingPathComponent("sqlite")
            )
            if FileManager.default.fileExists(atPath: url.path) {
                result[member.rawValue] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func execute(
        _ sql: String,
        bindings: [String] = [],
        at url: URL
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                url.path, &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            XCTAssertEqual(binding.withCString { pointer in
                sqlite3_bind_text(
                    statement, Int32(offset + 1), pointer, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }, SQLITE_OK)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CodexGhostRepairError.recoveryRequired
        }
    }

    private func text(_ sql: String, at url: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
                == SQLITE_OK, let database else {
            throw CodexGhostRepairError.recoveryRequired
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CodexGhostRepairError.recoveryRequired }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return String(cString: value)
    }

    private func integer(_ sql: String, at url: URL) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
                == SQLITE_OK, let database else {
            throw CodexGhostRepairError.recoveryRequired
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CodexGhostRepairError.recoveryRequired }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return sqlite3_column_int64(statement, 0)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
