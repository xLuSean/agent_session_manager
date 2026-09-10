@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class CodexGhostRepairStateRepositoryTests: XCTestCase {
    func testPreviewRoundTripsExactlyAcrossStoreRestart() throws {
        let fixture = try makeFixture()
        let databaseURL = try makeDatabaseURL()
        var store: SQLiteStateStore? = try SQLiteStateStore(databaseURL: databaseURL)

        try store?.saveCodexGhostRepairPreview(fixture.plan)
        XCTAssertEqual(
            try store?.codexGhostRepairPreview(id: fixture.plan.id),
            CodexGhostRepairStoredPreview(status: .prepared, plan: fixture.plan)
        )
        store?.close()
        store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store?.close() }

        XCTAssertEqual(
            try store?.codexGhostRepairPreview(id: fixture.plan.id),
            CodexGhostRepairStoredPreview(status: .prepared, plan: fixture.plan)
        )
        XCTAssertNil(try store?.codexGhostRepairClaim(planID: fixture.plan.id))
        XCTAssertNil(try store?.codexGhostRepairReport(planID: fixture.plan.id))
    }

    func testWrongTokenLeavesPreviewPreparedWithoutClaim() throws {
        let fixture = try makeFixture()
        let store = try SQLiteStateStore(databaseURL: makeDatabaseURL())
        defer { store.close() }
        try store.saveCodexGhostRepairPreview(fixture.plan)

        XCTAssertThrowsError(try store.beginCodexGhostRepair(
            plan: fixture.plan,
            confirmationToken: "wrong",
            claim: fixture.claim
        ))

        XCTAssertEqual(
            try store.codexGhostRepairPreview(id: fixture.plan.id)?.status,
            .prepared
        )
        XCTAssertNil(try store.codexGhostRepairClaim(planID: fixture.plan.id))
    }

    func testPersistenceRejectsRawPrivateFieldEvenWithValidManifest() throws {
        let fixture = try makeFixture()
        let original = fixture.plan.frozenTargets[0]
        let unsafePlan = try CodexGhostRepairPlan(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000025")!,
            createdAtMilliseconds: fixture.plan.createdAtMilliseconds,
            expiresAtMilliseconds: fixture.plan.expiresAtMilliseconds,
            category: fixture.plan.category,
            targetIDs: fixture.plan.targetIDs,
            frozenTargets: [CodexGhostRepairTargetEvidence(
                threadID: original.threadID,
                catalogRow: CodexGhostRepairSQLiteRow(fields: original.catalogRow.fields + [
                    .init(name: "private_title", value: .text("must-not-persist")),
                ]),
                automationRow: nil,
                automationDefinitionRow: nil
            )],
            previewAuthorityAudit: fixture.plan.previewAuthorityAudit,
            protectionEvidence: fixture.plan.protectionEvidence,
            desktopSchemaVersion: fixture.plan.desktopSchemaVersion,
            summariesSchemaVersion: fixture.plan.summariesSchemaVersion,
            historySchemaVersion: fixture.plan.historySchemaVersion
        )
        let store = try SQLiteStateStore(databaseURL: makeDatabaseURL())
        defer { store.close() }

        XCTAssertThrowsError(try store.saveCodexGhostRepairPreview(unsafePlan))
        XCTAssertNil(try store.codexGhostRepairPreview(id: unsafePlan.id))
    }

    func testClaimIsAtomicAndSecondInvocationRequiresRecovery() throws {
        let fixture = try makeFixture()
        let store = try SQLiteStateStore(databaseURL: makeDatabaseURL())
        defer { store.close() }
        try store.saveCodexGhostRepairPreview(fixture.plan)

        XCTAssertEqual(
            try store.beginCodexGhostRepair(
                plan: fixture.plan,
                confirmationToken: fixture.plan.confirmationToken,
                claim: fixture.claim
            ),
            .claimed(fixture.claim)
        )
        XCTAssertEqual(
            try store.codexGhostRepairPreview(id: fixture.plan.id)?.status,
            .executing
        )
        XCTAssertEqual(
            try store.codexGhostRepairClaim(planID: fixture.plan.id),
            fixture.claim
        )
        XCTAssertEqual(
            try store.beginCodexGhostRepair(
                plan: fixture.plan,
                confirmationToken: fixture.plan.confirmationToken,
                claim: fixture.claim
            ),
            .recoveryRequired(fixture.claim)
        )
    }

    func testFinalizeAtomicallyPersistsReportConsumesPreviewAndPreventsReplay() throws {
        let fixture = try makeFixture()
        let store = try SQLiteStateStore(databaseURL: makeDatabaseURL())
        defer { store.close() }
        try store.saveCodexGhostRepairPreview(fixture.plan)
        _ = try store.beginCodexGhostRepair(
            plan: fixture.plan,
            confirmationToken: fixture.plan.confirmationToken,
            claim: fixture.claim
        )

        try store.finalizeCodexGhostRepair(
            report: fixture.report,
            expectedClaimHash: fixture.claim.claimHash
        )

        XCTAssertEqual(try store.codexGhostRepairReport(planID: fixture.plan.id), fixture.report)
        XCTAssertEqual(try store.codexGhostRepairPreview(id: fixture.plan.id)?.status, .consumed)
        XCTAssertEqual(
            try store.beginCodexGhostRepair(
                plan: fixture.plan,
                confirmationToken: fixture.plan.confirmationToken,
                claim: fixture.claim
            ),
            .existingReport(fixture.report)
        )
        try store.finalizeCodexGhostRepair(
            report: fixture.report,
            expectedClaimHash: fixture.claim.claimHash
        )
    }

    func testInjectedFinalizeFailureRollsBackReportAndLeavesRecoveryState() throws {
        let fixture = try makeFixture()
        let store = try SQLiteStateStore(databaseURL: makeDatabaseURL())
        defer { store.close() }
        try store.saveCodexGhostRepairPreview(fixture.plan)
        _ = try store.beginCodexGhostRepair(
            plan: fixture.plan,
            confirmationToken: fixture.plan.confirmationToken,
            claim: fixture.claim
        )
        try store.withLockedDatabase { database in
            try rawExecute(
                """
                CREATE TRIGGER fail_ghost_finalize
                BEFORE UPDATE OF status ON codex_ghost_repair_previews
                WHEN NEW.status = 'consumed'
                BEGIN SELECT RAISE(ABORT, 'injected finalize failure'); END
                """,
                database: database
            )
        }

        XCTAssertThrowsError(try store.finalizeCodexGhostRepair(
            report: fixture.report,
            expectedClaimHash: fixture.claim.claimHash
        ))

        XCTAssertNil(try store.codexGhostRepairReport(planID: fixture.plan.id))
        XCTAssertEqual(try store.codexGhostRepairPreview(id: fixture.plan.id)?.status, .executing)
        XCTAssertEqual(
            try store.beginCodexGhostRepair(
                plan: fixture.plan,
                confirmationToken: fixture.plan.confirmationToken,
                claim: fixture.claim
            ),
            .recoveryRequired(fixture.claim)
        )
    }

    func testReportWithDifferentExactItemSetIsRejectedWithoutPartialWrite() throws {
        let fixture = try makeFixture()
        let store = try SQLiteStateStore(databaseURL: makeDatabaseURL())
        defer { store.close() }
        try store.saveCodexGhostRepairPreview(fixture.plan)
        _ = try store.beginCodexGhostRepair(
            plan: fixture.plan,
            confirmationToken: fixture.plan.confirmationToken,
            claim: fixture.claim
        )
        let mismatched = CodexGhostRepairReport(
            planID: fixture.plan.id,
            planManifestHash: fixture.plan.manifestHash,
            completedAtMilliseconds: 3_000,
            outcome: .success,
            items: [CodexGhostRepairReportItem(threadID: "different", outcome: .repaired)],
            recoveredByReadback: false,
            mutationAttemptedOnce: true,
            mutationRetryAllowed: false,
            backupManifestHash: fixture.claim.backupManifestHash
        )

        XCTAssertThrowsError(try store.finalizeCodexGhostRepair(
            report: mismatched,
            expectedClaimHash: fixture.claim.claimHash
        ))
        XCTAssertNil(try store.codexGhostRepairReport(planID: fixture.plan.id))
        XCTAssertEqual(try store.codexGhostRepairPreview(id: fixture.plan.id)?.status, .executing)
    }

    private struct Fixture {
        let plan: CodexGhostRepairPlan
        let claim: CodexGhostRepairExecutionClaim
        let report: CodexGhostRepairReport
    }

    private func makeFixture() throws -> Fixture {
        let catalog = CodexGhostRepairSQLiteRow(fields: [
            .init(name: "thread_id", value: .text("thread-a")),
        ])
        let authority = CodexGhostRepairAuthorityEvidence(
            metadataRow: CodexGhostRepairSQLiteRow(fields: [
                .init(name: "catalog_revision", value: .integer(7)),
            ]),
            localSyncRow: CodexGhostRepairSQLiteRow(fields: [
                .init(name: "host_id", value: .text("local")),
                .init(name: "observation_sequence", value: .integer(11)),
            ])
        )
        let protection = CodexGhostRepairProtectionEvidence(
            threadID: "thread-a",
            inventoryComplete: true,
            activeInventoryPresent: false,
            archivedInventoryPresent: false,
            exactReadNotLoaded: true,
            exactReadErrorCode: -32600,
            pinned: false,
            descendantCount: 0
        )
        let plan = try CodexGhostRepairPlan(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000024")!,
            createdAtMilliseconds: 1_000,
            expiresAtMilliseconds: 10_000,
            category: .ordinary,
            targetIDs: ["thread-a"],
            frozenTargets: [CodexGhostRepairTargetEvidence(
                threadID: "thread-a",
                catalogRow: catalog,
                automationRow: nil,
                automationDefinitionRow: nil
            )],
            previewAuthorityAudit: authority,
            protectionEvidence: [protection],
            desktopSchemaVersion: 32,
            summariesSchemaVersion: 2,
            historySchemaVersion: 3
        )
        let gate = CodexGhostRepairExecutionGate(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: true
        )
        let claim = try CodexGhostRepairExecutionClaim(
            planID: plan.id,
            planManifestHash: plan.manifestHash,
            claimedAtMilliseconds: 2_000,
            executionAtMilliseconds: 2_500,
            freshAuthority: authority,
            freshProtectionEvidenceHash: try CodexGhostRepairHasher.hash([protection]),
            executionGate: gate,
            backupManifestHash: "sha256:backup"
        )
        let report = CodexGhostRepairReport(
            planID: plan.id,
            planManifestHash: plan.manifestHash,
            completedAtMilliseconds: 3_000,
            outcome: .success,
            items: [CodexGhostRepairReportItem(threadID: "thread-a", outcome: .repaired)],
            recoveredByReadback: false,
            mutationAttemptedOnce: true,
            mutationRetryAllowed: false,
            backupManifestHash: claim.backupManifestHash
        )
        return Fixture(plan: plan, claim: claim, report: report)
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghost-repair-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("manager.sqlite3")
    }

    private func rawExecute(_ sql: String, database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw SQLiteStateStoreError.sqlite(
                operation: "test injection",
                code: result,
                message: text
            )
        }
    }
}
