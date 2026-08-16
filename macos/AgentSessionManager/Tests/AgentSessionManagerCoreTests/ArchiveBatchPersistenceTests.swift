import XCTest
@testable import AgentSessionManagerCore

final class ArchiveBatchPersistenceTests: XCTestCase {
    func testBatchPlanAndFailureReportRoundTripPreserveNotAttempted() throws {
        let fixture = try makeFixture()
        defer { fixture.store.close() }

        try fixture.store.saveArchiveBatchPlan(fixture.plan)
        XCTAssertEqual(
            try fixture.store.archiveBatchPlan(id: fixture.plan.id),
            fixture.plan
        )
        let claim = try fixture.store.claimArchiveBatchPlanForExecution(
            id: fixture.plan.id,
            now: Date(timeIntervalSince1970: 35),
            confirmationTokenHash: fixture.plan.confirmationTokenHash
        )
        XCTAssertEqual(claim.plan.status, .executing)
        XCTAssertEqual(claim.checkpoint.inventoryHash, fixture.plan.providerInventoryHash)
        XCTAssertTrue(try fixture.plan.units.allSatisfy {
            try fixture.store.operationPreview(id: $0.previewID)?.status == .executing
        })

        let executionPlan = try ArchiveBatchAtomicityPolicy.plan(
            affectedSets: fixture.affectedSets
        )
        let first = executionPlan.units[0]
        let finalization = try ArchiveBatchAtomicityPolicy.finalize(
            plan: executionPlan,
            attempts: [
                ArchiveBatchAttempt(
                    selectedRootManagerKey: first.selectedRootManagerKey,
                    outcome: .failure,
                    errorCode: "archive_rejected",
                    items: first.affectedItems.map {
                        ArchiveBatchAttemptItem(
                            managerKey: $0.managerKey,
                            outcome: .failure,
                            observedNativeState: .active,
                            errorCode: "archive_rejected",
                            evidenceAt: Date(timeIntervalSince1970: 50)
                        )
                    }
                ),
            ]
        )
        let report = PersistentArchiveBatchReport(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
            batchID: fixture.plan.id,
            startedAt: Date(timeIntervalSince1970: 40),
            completedAt: Date(timeIntervalSince1970: 50),
            finalization: finalization
        )

        try fixture.store.saveArchiveBatchReport(report)
        XCTAssertEqual(try fixture.store.archiveBatchReport(id: report.id), report)
        XCTAssertEqual(
            try fixture.store.archiveBatchPlan(id: fixture.plan.id)?.status,
            .consumed
        )
        XCTAssertTrue(try fixture.plan.units.allSatisfy {
            try fixture.store.operationPreview(id: $0.previewID)?.status == .consumed
        })
        XCTAssertEqual(report.finalization.notAttemptedUnitCount, 1)
        XCTAssertTrue(report.finalization.units[1].items.allSatisfy {
            $0.disposition == .notAttempted
                && $0.evidenceAt == nil
                && $0.observedNativeState == .unavailable
        })
    }

    func testTamperedBatchManifestLeavesNoPartialRows() throws {
        let fixture = try makeFixture()
        defer { fixture.store.close() }
        let tampered = PersistentArchiveBatchPlan(
            id: fixture.plan.id,
            provider: fixture.plan.provider,
            status: fixture.plan.status,
            providerInventoryHash: fixture.plan.providerInventoryHash,
            confirmationTokenHash: fixture.plan.confirmationTokenHash,
            manifestHash: "sha256:tampered",
            createdAt: fixture.plan.createdAt,
            expiresAt: fixture.plan.expiresAt,
            units: fixture.plan.units
        )

        XCTAssertThrowsError(try fixture.store.saveArchiveBatchPlan(tampered))
        XCTAssertNil(try fixture.store.archiveBatchPlan(id: fixture.plan.id))
    }

    func testIncompleteReportRollsBackAndKeepsPreparedPlan() throws {
        let fixture = try makeFixture()
        defer { fixture.store.close() }
        try fixture.store.saveArchiveBatchPlan(fixture.plan)
        let invalidFinalization = ArchiveBatchFinalization(
            outcome: .failure,
            units: []
        )
        let report = PersistentArchiveBatchReport(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!,
            batchID: fixture.plan.id,
            startedAt: Date(timeIntervalSince1970: 40),
            completedAt: Date(timeIntervalSince1970: 50),
            finalization: invalidFinalization
        )

        XCTAssertThrowsError(try fixture.store.saveArchiveBatchReport(report))
        XCTAssertNil(try fixture.store.archiveBatchReport(id: report.id))
        XCTAssertEqual(
            try fixture.store.archiveBatchPlan(id: fixture.plan.id)?.status,
            .prepared
        )
    }

    func testBatchClaimIsAtomicAndCannotReplay() throws {
        let fixture = try makeFixture()
        defer { fixture.store.close() }
        try fixture.store.saveArchiveBatchPlan(fixture.plan)

        XCTAssertThrowsError(try fixture.store.claimOperationPreviewForExecution(
            id: fixture.plan.units[0].previewID,
            now: Date(timeIntervalSince1970: 35),
            confirmationTokenHash: fixture.plan.confirmationTokenHash
        ))

        XCTAssertThrowsError(try fixture.store.claimArchiveBatchPlanForExecution(
            id: fixture.plan.id,
            now: Date(timeIntervalSince1970: 35),
            confirmationTokenHash: "sha256:wrong"
        ))
        XCTAssertEqual(
            try fixture.store.archiveBatchPlan(id: fixture.plan.id)?.status,
            .prepared
        )
        XCTAssertTrue(try fixture.plan.units.allSatisfy {
            try fixture.store.operationPreview(id: $0.previewID)?.status == .prepared
        })

        _ = try fixture.store.claimArchiveBatchPlanForExecution(
            id: fixture.plan.id,
            now: Date(timeIntervalSince1970: 35),
            confirmationTokenHash: fixture.plan.confirmationTokenHash
        )
        XCTAssertThrowsError(try fixture.store.claimArchiveBatchPlanForExecution(
            id: fixture.plan.id,
            now: Date(timeIntervalSince1970: 36),
            confirmationTokenHash: fixture.plan.confirmationTokenHash
        ))
    }

    func testBatchPlanRequiresPersistedExactPreviewReferences() throws {
        let fixture = try makeFixture(saveSecondPreview: false)
        defer { fixture.store.close() }

        XCTAssertThrowsError(try fixture.store.saveArchiveBatchPlan(fixture.plan))
        XCTAssertNil(try fixture.store.archiveBatchPlan(id: fixture.plan.id))
    }

    private func makeFixture(
        saveSecondPreview: Bool = true
    ) throws -> (
        store: SQLiteStateStore,
        plan: PersistentArchiveBatchPlan,
        affectedSets: [ArchiveAffectedSet]
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-batch-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(
            databaseURL: directory.appendingPathComponent("manager.sqlite3")
        )
        let observedAt = Date(timeIntervalSince1970: 20)
        let nodes = [
            node("a-root"),
            node("a-child", parent: "a-root"),
            node("b-root"),
        ]
        let snapshot = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: "batch-inventory-hash",
            observedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [],
            archiveScopeNodes: nodes,
            archiveScopeComplete: true
        )
        let createdAt = Date(timeIntervalSince1970: 30)
        let expiresAt = Date(timeIntervalSince1970: 90)
        let previews = try ["a-root", "b-root"].enumerated().map { index, root in
            try ArchiveAffectedSetPreviewFactory.makePreparedPreview(
                selectedRootNativeSessionID: root,
                snapshot: snapshot,
                confirmationToken: "BATCH-TOKEN",
                previewID: UUID(uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    410 + index
                ))!,
                createdAt: createdAt,
                expiresAt: expiresAt
            )
        }
        try store.saveOperationPreview(previews[0], checkpoint: snapshot.checkpoint)
        if saveSecondPreview {
            try store.saveOperationPreview(previews[1], checkpoint: snapshot.checkpoint)
        }
        let plan = try ArchiveBatchPersistenceFactory.makePreparedPlan(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            previews: previews,
            confirmationToken: "BATCH-TOKEN",
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        let affectedSets = try ["a-root", "b-root"].map {
            try ArchiveAffectedSetPlanner.plan(
                selectedRootNativeSessionID: $0,
                nodes: nodes,
                graphComplete: true
            )
        }
        return (store, plan, affectedSets)
    }

    private func node(_ id: String, parent: String? = nil) -> ArchiveScopeNode {
        ArchiveScopeNode(
            managerKey: "codex:\(id)",
            nativeSessionID: id,
            parentNativeSessionID: parent,
            title: id,
            nativeState: .active,
            protection: SessionProtection()
        )
    }
}
