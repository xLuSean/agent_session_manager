@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexDesktopExtendedCleanupTests: XCTestCase {
    func testV156Mixed148CleanupPreservesExtendedSettingsAndColdReadback() async throws {
        try await verifyMixed148Cleanup(runtimeVersion: "0.156.1")
    }

    func testV157Mixed148CleanupPreservesExtendedSettingsAndColdReadback() async throws {
        try await verifyMixed148Cleanup(runtimeVersion: "0.157.1")
    }

    func testV160Mixed148CleanupPreservesAsyncStatusNominalScheduleAndColdReadback() async throws {
        try await verifyMixed148Cleanup(runtimeVersion: "0.157.1", profile: .v160DesktopV34Async)
    }

    func testV166Mixed148CleanupPreservesSettingsAndColdReadback() async throws {
        for runtime in ["0.164.0", "0.166.0-alpha.5.1"] {
            try await verifyMixed148Cleanup(runtimeVersion: runtime, profile: .v166DesktopV34Realtime)
        }
    }

    private func verifyMixed148Cleanup(runtimeVersion: String,
                                      profile: CodexGhostRepairSnapshotSourceProfile = .v156DesktopV34Extended) async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 148, desktopSchema: 34,
            profile: profile, runtimeVersion: runtimeVersion)
        let before = try CodexGhostRepairProductionSQLite(url: fixture.desktopURL, readOnly: true)
        let definitions = try before.query("SELECT * FROM automations ORDER BY id", maximumRows: 200)
        let kept = try before.query("SELECT * FROM local_thread_catalog WHERE host_id = 'remote'", maximumRows: 2)
        before.close()
        XCTAssertEqual(try CodexGhostRepairBulkBackupBoundOperationPlan.decodeValidated(fixture.livePlan.encodedForPersistence()), fixture.livePlan)
        XCTAssertTrue(fixture.livePlan.databaseEvidence.allSatisfy { $0.schemaProfileIdentifier == profile.databaseSchemaProfileIdentifier })
        XCTAssertFalse(CodexGhostRepairSnapshotSourceProfile.v1534DesktopV34.admits(databases: fixture.livePlan.databaseEvidence))
        let result = try await fixture.liveMutator().executeOnce(plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(result, .success)
        let after = try CodexGhostRepairProductionSQLite(url: fixture.desktopURL, readOnly: true)
        XCTAssertEqual(try after.query("SELECT * FROM automations ORDER BY id", maximumRows: 200), definitions)
        XCTAssertEqual(try after.query("SELECT * FROM local_thread_catalog WHERE host_id = 'remote'", maximumRows: 2), kept)
        after.close()
        XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog WHERE host_id = 'local'", at: fixture.desktopURL), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM automation_runs WHERE status = 'ARCHIVED' AND archived_reason = 'auto'", at: fixture.desktopURL), 74)
        XCTAssertEqual(try scalar("SELECT count(*) FROM automations WHERE auto_archive = 1", at: fixture.desktopURL), 74)
        XCTAssertEqual(try scalar("SELECT catalog_revision FROM local_thread_catalog_metadata WHERE id = 1", at: fixture.desktopURL), 1148)
        let recovered = try await fixture.liveMutator().recoverByReadback(plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(recovered, .success)
    }

    func testV160RollbackAndUnreviewedSchemaCannotChangeRows() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, desktopSchema: 34,
            profile: .v160DesktopV34Async, runtimeVersion: "0.157.1")
        let result = try await fixture.liveMutator(fault: .beforeCommit).executeOnce(
            plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(result, .explicitFailure)
        XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog WHERE host_id = 'local'", at: fixture.desktopURL), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM automation_runs WHERE status = 'PENDING_REVIEW'", at: fixture.desktopURL), 1)
        for sql in ["ALTER TABLE automations ADD COLUMN unreviewed TEXT",
                    "CREATE TRIGGER unexpected AFTER DELETE ON local_thread_catalog BEGIN UPDATE automations SET next_run_nominal_at = 0; END"] {
            let changed = try BulkShippingCompositionTestFixture.make(itemCount: 2, desktopSchema: 34,
                profile: .v160DesktopV34Async, runtimeVersion: "0.157.1")
            try execute(sql, at: changed.desktopURL)
            XCTAssertThrowsError(try CodexGhostRepairBulkLiveMixedMutator.inspect(
                selectedItems: changed.livePlan.selectedItems, resolution: changed.bundle.resolveForPreflight()))
            XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog WHERE host_id = 'local'", at: changed.desktopURL), 2)
        }
    }

    func testV156FailureRollsBackCatalogAndAutomationRunTogether() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, desktopSchema: 34,
            profile: .v156DesktopV34Extended, runtimeVersion: "0.156.1")
        let result = try await fixture.liveMutator(fault: .beforeCommit).executeOnce(
            plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(result, .explicitFailure)
        XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog WHERE host_id = 'local'", at: fixture.desktopURL), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM automation_runs WHERE status = 'PENDING_REVIEW'", at: fixture.desktopURL), 1)
    }

    func testV156SchemaDriftBlocksCleanupEvenWhenUserVersionIsUnchanged() async throws {
        for sql in ["ALTER TABLE automations ADD COLUMN unreviewed TEXT", "CREATE TRIGGER unexpected AFTER DELETE ON local_thread_catalog BEGIN UPDATE automations SET auto_archive = 0; END"] {
            let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, desktopSchema: 34,
                profile: .v156DesktopV34Extended, runtimeVersion: "0.156.1")
            try execute(sql, at: fixture.desktopURL)
            XCTAssertThrowsError(try CodexGhostRepairBulkLiveMixedMutator.inspect(selectedItems: fixture.livePlan.selectedItems, resolution: fixture.bundle.resolveForPreflight()))
            XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog WHERE host_id = 'local'", at: fixture.desktopURL), 2)
        }
    }


    func testV166NewRealtimeReferenceBlocksFrozenCleanupAndIsPreserved() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, desktopSchema: 34,
            profile: .v166DesktopV34Realtime, runtimeVersion: "0.164.0")
        let history = fixture.codexHome.appendingPathComponent("thread_history_1.sqlite")
        let id = try XCTUnwrap(fixture.livePlan.selectedItems.first?.threadID)
        try execute("INSERT INTO thread_realtime_items VALUES ('\(id)', 'item', 0, 0, 'realtime_session_started', '{}')", at: history)
        let historyBefore = try Data(contentsOf: history)
        let observed = try CodexGhostRepairBulkLiveMixedMutator.inspect(selectedItems: fixture.livePlan.selectedItems,
            resolution: fixture.bundle.resolveForPreflight())
        XCTAssertEqual(observed.items.first { $0.threadID == id }?.referenceCount, 1)
        let result = try await fixture.liveMutator().executeOnce(plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(result, .notAttempted)
        XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog WHERE host_id = 'local'", at: fixture.desktopURL), 2)
        XCTAssertEqual(try Data(contentsOf: history), historyBefore)
    }

    func testV166FailureRollsBackAndChangedHistoryTriggerFailsClosed() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, desktopSchema: 34,
            profile: .v166DesktopV34Realtime, runtimeVersion: "0.164.0")
        let result = try await fixture.liveMutator(fault: .beforeCommit).executeOnce(plan: fixture.livePlan,
            claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(result, .explicitFailure)
        XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog WHERE host_id = 'local'", at: fixture.desktopURL), 2)
        let history = fixture.codexHome.appendingPathComponent("thread_history_1.sqlite")
        try execute("DROP TRIGGER thread_realtime_items_projection_cleanup; CREATE TRIGGER thread_realtime_items_projection_cleanup AFTER DELETE ON thread_history_projection_state BEGIN DELETE FROM thread_realtime_items; END", at: history)
        XCTAssertThrowsError(try CodexGhostRepairBulkLiveMixedMutator.inspect(selectedItems: fixture.livePlan.selectedItems,
            resolution: fixture.bundle.resolveForPreflight()))
    }

    private func scalar(_ sql: String, at url: URL) throws -> Int {
        try BulkShippingCompositionTestFixture.scalar(sql, at: url)
    }
    private func execute(_ sql: String, at url: URL) throws {
        try BulkShippingCompositionTestFixture.execute(sql, at: url)
    }
}
