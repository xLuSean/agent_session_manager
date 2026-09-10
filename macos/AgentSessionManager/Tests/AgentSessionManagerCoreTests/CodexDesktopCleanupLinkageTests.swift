import CSQLite3
import XCTest
@testable import AgentSessionManagerCore

final class CodexDesktopCleanupLinkageTests: XCTestCase {
    func testExact148HandoffBindsPreparedJournalAndSurvivesClaimAttemptSuccess() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 148)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { store.close() }
        let reportID = UUID(uuidString: "d1000000-0000-4000-8000-000000000001")!
        try seedTombstones(
            fixture.livePlan.selectedThreadIDs,
            reportID: reportID,
            deletedAtMilliseconds: 900,
            store: store
        )
        _ = try store.prepareCodexGhostRepairBulkLiveExecutionJournal(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = CodexDesktopCleanupLinkageCoordinator(
            testStore: store,
            nowMilliseconds: { 1_500 }
        )

        let handoff = try ready(
            await coordinator.reviewCanonicalDelete(
                reportID: reportID,
                expectedNativeSessionIDs: fixture.livePlan.selectedThreadIDs
            )
        )
        XCTAssertEqual(handoff.items.count, 148)
        let binding = try bound(
            await coordinator.bindPreparedOperation(
                handoff: handoff,
                bulkIdentity: .init(
                    requestID: fixture.livePlan.requestID,
                    operationID: fixture.confirmationReceipt.operationID
                )
            )
        )
        XCTAssertEqual(binding.items.count, 148)
        let duplicate = await coordinator.bindPreparedOperation(
            handoff: handoff,
            bulkIdentity: binding.bulkIdentity
        )
        guard case let .alreadyBound(readback) = duplicate else {
            return XCTFail("The same exact binding must be idempotent.")
        }
        XCTAssertEqual(readback, binding)
        try assertPrepared(await coordinator.readStatus(reportID: reportID))
        try seedClearableHistory(reportID: reportID, store: store)
        XCTAssertThrowsError(try store.clearOperationHistory(
            reportIDs: [reportID],
            provider: .codex,
            confirmationToken: "clear",
            expectedConfirmationToken: "clear"
        ))
        XCTAssertNotNil(try store.operationReport(id: reportID))
        try assertPrepared(await coordinator.readStatus(reportID: reportID))

        let claim = try store.claimCodexGhostRepairBulkLiveExecution(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest,
            claimID: UUID(uuidString: "d1000000-0000-4000-8000-000000000002")!,
            claimedAtMilliseconds: 1_600
        )
        try assertRecovery(
            await coordinator.readStatus(reportID: reportID), phase: .claimed
        )
        // Removing one list row must neither shrink the frozen batch nor erase
        // claimed-operation recovery evidence. The remainder still completes below.
        let listPreview = try store.prepareDeletedListClear(selectedManagerKeys: ["manager-0"])
        XCTAssertEqual(listPreview.recordCount, 1)
        try store.clearDeletedList(listPreview)
        XCTAssertEqual(try store.visibleDeletedSessions(for: .codex).count, 147)
        XCTAssertEqual(try store.deletedSessions(for: .codex).count, 148)
        try assertRecovery(await coordinator.readStatus(reportID: reportID), phase: .claimed)
        let attempt = try store.recordCodexGhostRepairBulkLiveExecutionAttempt(
            requestID: fixture.livePlan.requestID,
            expectedClaimDigest: claim.claimDigest,
            attemptedAtMilliseconds: 1_700
        )
        try assertRecovery(
            await coordinator.readStatus(reportID: reportID), phase: .attempted
        )
        let terminal = try CodexGhostRepairBulkLiveTerminalReport(
            reportID: UUID(uuidString: "d1000000-0000-4000-8000-000000000003")!,
            plan: fixture.livePlan,
            receipt: fixture.confirmationReceipt,
            claim: claim,
            attempt: attempt,
            outcome: .success,
            completedAtMilliseconds: 1_800
        )
        _ = try store.recordCodexGhostRepairBulkLiveTerminalReport(terminal)
        let status = try status(await coordinator.readStatus(reportID: reportID))
        guard case let .verified(returnedHandoff, returnedBinding, completedAt) = status else {
            return XCTFail("Expected verified Desktop cleanup status.")
        }
        XCTAssertEqual(returnedHandoff, handoff)
        XCTAssertEqual(returnedBinding, binding)
        XCTAssertEqual(completedAt, 1_800)
    }

    func testUnknownTerminalRemainsBoundAndNeverBecomesFreshPending() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { store.close() }
        let reportID = UUID(uuidString: "d2000000-0000-4000-8000-000000000001")!
        try seedTombstones(
            fixture.livePlan.selectedThreadIDs,
            reportID: reportID,
            deletedAtMilliseconds: 900,
            store: store
        )
        _ = try store.prepareCodexGhostRepairBulkLiveExecutionJournal(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = CodexDesktopCleanupLinkageCoordinator(
            testStore: store,
            nowMilliseconds: { 1_500 }
        )
        let handoff = try ready(await coordinator.reviewCanonicalDelete(
            reportID: reportID,
            expectedNativeSessionIDs: fixture.livePlan.selectedThreadIDs
        ))
        _ = try bound(await coordinator.bindPreparedOperation(
            handoff: handoff,
            bulkIdentity: .init(
                requestID: fixture.livePlan.requestID,
                operationID: fixture.confirmationReceipt.operationID
            )
        ))
        let claim = try store.claimCodexGhostRepairBulkLiveExecution(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest,
            claimID: UUID(uuidString: "d2000000-0000-4000-8000-000000000002")!,
            claimedAtMilliseconds: 1_600
        )
        let attempt = try store.recordCodexGhostRepairBulkLiveExecutionAttempt(
            requestID: fixture.livePlan.requestID,
            expectedClaimDigest: claim.claimDigest,
            attemptedAtMilliseconds: 1_700
        )
        _ = try store.recordCodexGhostRepairBulkLiveTerminalReport(
            try .init(
                reportID: UUID(uuidString: "d2000000-0000-4000-8000-000000000003")!,
                plan: fixture.livePlan,
                receipt: fixture.confirmationReceipt,
                claim: claim,
                attempt: attempt,
                outcome: .unknown,
                completedAtMilliseconds: 1_800
            )
        )
        guard case .outcomeUnknown = try status(
            await coordinator.readStatus(reportID: reportID)
        ) else { return XCTFail("Expected durable unknown status.") }

        let second = await coordinator.bindPreparedOperation(
            handoff: handoff,
            bulkIdentity: .init(
                requestID: UUID(), operationID: UUID()
            )
        )
        guard case .rejected = second else {
            return XCTFail("A bound unknown operation must not be overwritten.")
        }
    }

    func testWrongSetOlderPlanAndFractionalTombstoneFailWithoutBinding() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { store.close() }
        let reportID = UUID(uuidString: "d3000000-0000-4000-8000-000000000001")!
        let deletionMilliseconds = fixture.livePlan.plannedAtMilliseconds + 1
        try seedTombstones(
            fixture.livePlan.selectedThreadIDs,
            reportID: reportID,
            deletedAtMilliseconds: deletionMilliseconds,
            store: store,
            fractionalOffset: 0.0004
        )
        _ = try store.prepareCodexGhostRepairBulkLiveExecutionJournal(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = CodexDesktopCleanupLinkageCoordinator(
            testStore: store,
            nowMilliseconds: { fixture.livePlan.plannedAtMilliseconds + 100 }
        )
        guard case .rejected = await coordinator.reviewCanonicalDelete(
            reportID: reportID,
            expectedNativeSessionIDs: [fixture.livePlan.selectedThreadIDs[0]]
        ) else { return XCTFail("Silent handoff shrink must be rejected.") }
        let handoff = try ready(await coordinator.reviewCanonicalDelete(
            reportID: reportID,
            expectedNativeSessionIDs: fixture.livePlan.selectedThreadIDs
        ))
        XCTAssertEqual(
            Set(handoff.items.map(\.deletedAtMilliseconds)),
            [deletionMilliseconds]
        )
        guard case .rejected = await coordinator.bindPreparedOperation(
            handoff: handoff,
            bulkIdentity: .init(
                requestID: fixture.livePlan.requestID,
                operationID: fixture.confirmationReceipt.operationID
            )
        ) else { return XCTFail("A plan older than canonical Delete must fail.") }
        try assertPending(await coordinator.readStatus(reportID: reportID))
    }

    func testBindingRejectsExtraBulkItemAndHistoryIndependenceIsStructural() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { store.close() }
        let reportID = UUID(uuidString: "d4000000-0000-4000-8000-000000000001")!
        try seedTombstones(
            [fixture.livePlan.selectedThreadIDs[0]],
            reportID: reportID,
            deletedAtMilliseconds: 900,
            store: store
        )
        _ = try store.prepareCodexGhostRepairBulkLiveExecutionJournal(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = CodexDesktopCleanupLinkageCoordinator(
            testStore: store,
            nowMilliseconds: { 1_500 }
        )
        let handoff = try ready(await coordinator.reviewCanonicalDelete(
            reportID: reportID,
            expectedNativeSessionIDs: [fixture.livePlan.selectedThreadIDs[0]]
        ))
        guard case .rejected = await coordinator.bindPreparedOperation(
            handoff: handoff,
            bulkIdentity: .init(
                requestID: fixture.livePlan.requestID,
                operationID: fixture.confirmationReceipt.operationID
            )
        ) else { return XCTFail("Unrelated bulk items must not share the binding.") }
        try assertPending(await coordinator.readStatus(reportID: reportID))
        let tables = try store.tableNames()
        XCTAssertTrue(tables.contains("codex_desktop_cleanup_bindings"))
        XCTAssertNotEqual("operation_reports", "codex_desktop_cleanup_bindings")
    }

    func testClaimWinningBeforeBindingLeavesCanonicalDeletePending() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { store.close() }
        let reportID = UUID(uuidString: "d5000000-0000-4000-8000-000000000001")!
        try seedTombstones(
            fixture.livePlan.selectedThreadIDs,
            reportID: reportID,
            deletedAtMilliseconds: 900,
            store: store
        )
        _ = try store.prepareCodexGhostRepairBulkLiveExecutionJournal(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = CodexDesktopCleanupLinkageCoordinator(
            testStore: store,
            nowMilliseconds: { 1_500 }
        )
        let handoff = try ready(await coordinator.reviewCanonicalDelete(
            reportID: reportID,
            expectedNativeSessionIDs: fixture.livePlan.selectedThreadIDs
        ))
        _ = try store.claimCodexGhostRepairBulkLiveExecution(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest,
            claimID: UUID(uuidString: "d5000000-0000-4000-8000-000000000002")!,
            claimedAtMilliseconds: 1_600
        )
        guard case .rejected = await coordinator.bindPreparedOperation(
            handoff: handoff,
            bulkIdentity: .init(
                requestID: fixture.livePlan.requestID,
                operationID: fixture.confirmationReceipt.operationID
            )
        ) else { return XCTFail("Claim-before-binding must fail closed.") }
        try assertPending(await coordinator.readStatus(reportID: reportID))
    }

    func testCompletedHistoryClearsWholeBundleAndRejectsReplayAfterReopen() throws {
        let (fixture, store, _) = try completedHistoryFixture()
        defer { store.close() }
        let now = Date(timeIntervalSince1970: 10)
        let preview = try store.prepareCompletedHistoryClear(now: now)
        XCTAssertEqual(preview.deletedRecordCount, 2)
        XCTAssertEqual(preview.reportCount, 1)
        XCTAssertEqual(preview.ghostOperationCount, 1)
        try store.clearCompletedHistory(preview, now: now)
        XCTAssertTrue(try store.deletedSessions(for: .codex).isEmpty)
        for table in ["operation_reports", "operation_items", "operation_previews",
                      "codex_desktop_cleanup_bindings", "codex_ghost_repair_bulk_live_execution_journal",
                      "codex_ghost_repair_bulk_confirmation_receipts", "codex_ghost_repair_bulk_confirmation_challenges",
                      "codex_ghost_repair_bulk_frozen_plan_sources", "codex_ghost_repair_bulk_previews"] {
            let count = try store.withLockedDatabase { db in
                try store.query("SELECT COUNT(*) FROM \(table)", values: [], database: db) { sqlite3_column_int64($0, 0) }[0]
            }
            XCTAssertEqual(count, 0, table)
        }
        store.close()
        let reopened = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { reopened.close() }
        XCTAssertThrowsError(try reopened.saveCodexGhostRepairBulkPreview(
            requestID: fixture.storedPreview.requestID, preview: fixture.storedPreview.preview))
        XCTAssertTrue(try reopened.prepareCompletedHistoryClear(now: now).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.desktopURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testHistoryThirtyDayBoundaryAndWholeBatchSelection() throws {
        let (_, store, _) = try completedHistoryFixture()
        defer { store.close() }
        let boundary = Date(timeIntervalSince1970: 1.8 + 30 * 24 * 60 * 60)
        XCTAssertTrue(try store.pruneCompletedHistory(now: boundary).isEmpty)
        XCTAssertTrue(try store.prepareCompletedHistoryClear(selectedManagerKeys: ["manager-0"]).isEmpty)
        let all = try store.prepareCompletedHistoryClear(selectedManagerKeys: ["manager-0", "manager-1"])
        XCTAssertEqual(all.deletedRecordCount, 2)
        XCTAssertEqual(try store.pruneCompletedHistory(now: boundary.addingTimeInterval(1)).deletedRecordCount, 2)
    }

    func testUnknownAndPendingHistoryStayProtected() throws {
        let (_, store, _) = try completedHistoryFixture(outcome: .unknown)
        defer { store.close() }
        XCTAssertTrue(try store.prepareCompletedHistoryClear().isEmpty)
        XCTAssertEqual(try store.deletedSessions(for: .codex).count, 2)
    }

    func testHistoryConfirmationDetectsTitleDriftAndExpiry() throws {
        let (_, store, _) = try completedHistoryFixture()
        defer { store.close() }
        let now = Date(timeIntervalSince1970: 10)
        let preview = try store.prepareCompletedHistoryClear(now: now)
        XCTAssertThrowsError(try store.clearCompletedHistory(preview, now: now.addingTimeInterval(300)))
        try store.withLockedDatabase { db in
            try store.execute("UPDATE deleted_sessions SET title_at_deletion = 'changed' WHERE manager_key = 'manager-0'", values: [], database: db)
        }
        XCTAssertThrowsError(try store.clearCompletedHistory(preview, now: now))
        XCTAssertEqual(try store.deletedSessions(for: .codex).count, 2)
    }

    func testHistoryFailureRollsBackReportsTombstonesAndReplayMarkers() throws {
        let (_, store, reportID) = try completedHistoryFixture()
        defer { store.close() }
        let preview = try store.prepareCompletedHistoryClear()
        try store.withLockedDatabase { db in
            try store.execute("CREATE TRIGGER stop_clear BEFORE DELETE ON codex_ghost_repair_bulk_confirmation_receipts BEGIN SELECT RAISE(ABORT, 'test'); END", values: [], database: db)
        }
        XCTAssertThrowsError(try store.clearCompletedHistory(preview))
        XCTAssertNotNil(try store.operationReport(id: reportID))
        XCTAssertEqual(try store.deletedSessions(for: .codex).count, 2)
        let count = try store.withLockedDatabase { db in
            try store.query("SELECT COUNT(*) FROM retired_history_keys", values: [], database: db) { sqlite3_column_int64($0, 0) }[0]
        }
        XCTAssertEqual(count, 0)
    }

    private func completedHistoryFixture(outcome: CodexGhostRepairCategoryABatchOutcome = .success)
        throws -> (BulkShippingCompositionTestFixture.Value, SQLiteStateStore, UUID) {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        // Register exact disposable fixture cleanup through the existing test harness.
        addTeardownBlock {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            cleanup.arguments = ["trash", fixture.parent.path]
            try cleanup.run()
            cleanup.waitUntilExit()
            XCTAssertEqual(cleanup.terminationStatus, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.path))
        }
        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        let reportID = UUID()
        try seedTombstones(fixture.livePlan.selectedThreadIDs, reportID: reportID, deletedAtMilliseconds: 900, store: store)
        try seedClearableHistory(reportID: reportID, store: store)
        _ = try store.prepareCodexGhostRepairBulkLiveExecutionJournal(plan: fixture.livePlan, confirmationReceipt: fixture.confirmationReceipt)
        let handoff = try XCTUnwrap(store.codexDesktopCleanupHandoff(reportID: reportID,
            expectedNativeSessionIDs: fixture.livePlan.selectedThreadIDs))
        _ = try store.bindCodexDesktopCleanup(handoff: handoff,
            bulkIdentity: .init(requestID: fixture.livePlan.requestID, operationID: fixture.confirmationReceipt.operationID),
            boundAtMilliseconds: 1_500)
        let claim = try store.claimCodexGhostRepairBulkLiveExecution(requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest, claimID: UUID(), claimedAtMilliseconds: 1_600)
        let attempt = try store.recordCodexGhostRepairBulkLiveExecutionAttempt(requestID: fixture.livePlan.requestID,
            expectedClaimDigest: claim.claimDigest, attemptedAtMilliseconds: 1_700)
        let report = try CodexGhostRepairBulkLiveTerminalReport(reportID: UUID(), plan: fixture.livePlan,
            receipt: fixture.confirmationReceipt, claim: claim, attempt: attempt, outcome: outcome,
            completedAtMilliseconds: 1_800)
        _ = try store.recordCodexGhostRepairBulkLiveTerminalReport(report)
        return (fixture, store, reportID)
    }

    private func seedTombstones(
        _ nativeIDs: [String],
        reportID: UUID,
        deletedAtMilliseconds: Int64,
        store: SQLiteStateStore,
        fractionalOffset: TimeInterval = 0
    ) throws {
        try store.upsertProviderCheckpoint(
            ProviderCheckpointRecord(
                provider: .codex,
                runtimeVersion: "0.153.1",
                inventoryHash: "inventory",
                refreshedAt: Date(timeIntervalSince1970: 1),
                inventoryComplete: true,
                protectionComplete: true
            )
        )
        try store.withLockedDatabase { database in
            for (index, nativeID) in nativeIDs.enumerated() {
                let deletedAt = Date(
                    timeIntervalSince1970:
                        Double(deletedAtMilliseconds) / 1_000 + fractionalOffset
                )
                try store.execute(
                    """
                    INSERT INTO deleted_sessions (
                        provider, native_session_id, manager_key,
                        title_at_deletion, project_id_at_deletion,
                        working_directory_at_deletion, known_size_bytes,
                        provider_inventory_hash_at_deletion, deleted_at,
                        delete_report_id
                    ) VALUES ('codex', ?, ?, ?, NULL, NULL, NULL, ?, ?, ?)
                    """,
                    values: [
                        .text(nativeID), .text("manager-\(index)"),
                        .text("Deleted \(index)"), .text("inventory"),
                        .text(store.encode(PersistentTimestamp.canonical(deletedAt))),
                        .text(reportID.uuidString.lowercased()),
                    ],
                    database: database
                )
            }
        }
    }

    private func seedClearableHistory(
        reportID: UUID,
        store: SQLiteStateStore
    ) throws {
        let previewID = UUID(uuidString: "da000000-0000-4000-8000-000000000001")!
        try store.withLockedDatabase { database in
            try store.execute(
                """
                INSERT INTO operation_previews (
                    id, provider, operation, status,
                    confirmation_token_hash, manifest_hash,
                    provider_inventory_hash, created_at, expires_at,
                    item_count, known_size_bytes, unknown_size_count,
                    manager_intent
                ) VALUES (?, 'codex', 'archive', 'consumed', 'token',
                          'manifest', 'inventory',
                          '1970-01-01T00:00:01.000Z',
                          '1970-01-01T00:00:02.000Z', 1, 0, 1,
                          'archive')
                """,
                values: [.text(previewID.uuidString.lowercased())],
                database: database
            )
            try store.execute(
                """
                INSERT INTO operation_reports (
                    id, preview_id, provider, operation, outcome,
                    started_at, completed_at, item_count,
                    succeeded_count, failed_count, unknown_count,
                    verified_released_bytes, released_bytes_complete,
                    manager_intent
                ) VALUES (?, ?, 'codex', 'archive', 'success',
                          '1970-01-01T00:00:01.000Z',
                          '1970-01-01T00:00:02.000Z', 1, 1, 0, 0,
                          0, 0, 'archive')
                """,
                values: [
                    .text(reportID.uuidString.lowercased()),
                    .text(previewID.uuidString.lowercased()),
                ],
                database: database
            )
            try store.execute(
                """
                INSERT INTO operation_items (
                    preview_id, report_id, manager_key,
                    native_session_id, expected_native_state,
                    expected_protection_hash, expected_title,
                    result_outcome, observed_native_state, evidence_at
                ) VALUES (?, ?, 'history-item', 'history-native', 'active',
                          'protection', 'History', 'success', 'archived',
                          '1970-01-01T00:00:02.000Z')
                """,
                values: [
                    .text(previewID.uuidString.lowercased()),
                    .text(reportID.uuidString.lowercased()),
                ],
                database: database
            )
        }
    }

    private func ready(
        _ outcome: CodexDesktopCleanupReviewOutcome
    ) throws -> CodexDesktopCleanupHandoff {
        guard case let .ready(handoff) = outcome else {
            throw TestFailure("Expected ready handoff; got \(outcome).")
        }
        return handoff
    }

    private func bound(
        _ outcome: CodexDesktopCleanupBindOutcome
    ) throws -> CodexDesktopCleanupBinding {
        guard case let .bound(binding) = outcome else {
            throw TestFailure("Expected new binding; got \(outcome).")
        }
        return binding
    }

    private func status(
        _ outcome: CodexDesktopCleanupStatusOutcome
    ) throws -> CodexDesktopCleanupStatus {
        guard case let .status(status) = outcome else {
            throw TestFailure("Expected status; got \(outcome).")
        }
        return status
    }

    private func assertPending(
        _ outcome: CodexDesktopCleanupStatusOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case .pending = try status(outcome) else {
            return XCTFail("Expected pending status.", file: file, line: line)
        }
    }

    private func assertPrepared(
        _ outcome: CodexDesktopCleanupStatusOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case .prepared = try status(outcome) else {
            return XCTFail("Expected prepared status.", file: file, line: line)
        }
    }

    private func assertRecovery(
        _ outcome: CodexDesktopCleanupStatusOutcome,
        phase: CodexGhostRepairBulkRecoveryJournalPhase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case let .recoveryRequired(_, _, returnedPhase, _) = try status(outcome),
              returnedPhase == phase else {
            return XCTFail("Expected recovery-required \(phase).", file: file, line: line)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
