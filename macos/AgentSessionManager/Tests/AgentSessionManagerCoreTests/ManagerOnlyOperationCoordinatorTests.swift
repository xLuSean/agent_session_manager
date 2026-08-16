@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class ManagerOnlyOperationCoordinatorTests: XCTestCase {
    func testMoveToTrashCommitsMembershipReportAndConsumesPreview() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-trash", refreshedAt: date(100))
        try store.upsertProviderCheckpoint(checkpoint)
        let previewID = uuid("00000000-0000-0000-0000-000000001001")
        let reportID = uuid("00000000-0000-0000-0000-000000001002")
        let coordinator = makeCoordinator(
            store: store,
            now: date(110.123456),
            previewID: previewID,
            reportID: reportID
        )

        let preview = try await coordinator.prepare(
            operation: .moveToTrash,
            sessions: [makeArchivedSession(nativeID: "session-a")],
            checkpoint: checkpoint
        )
        let freshCheckpoint = makeCheckpoint(
            hash: checkpoint.inventoryHash,
            refreshedAt: date(120)
        )
        try store.upsertProviderCheckpoint(freshCheckpoint)
        let report = try await coordinator.execute(
            previewID: preview.id,
            confirmationToken: preview.confirmationToken,
            freshSnapshot: makeSnapshot(
                checkpoint: freshCheckpoint,
                sessions: [makeArchivedSession(nativeID: "session-a")]
            )
        )

        XCTAssertEqual(report.id, reportID)
        XCTAssertEqual(report.operation, .moveToTrash)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.map(\.observedNativeState), [.archived])
        XCTAssertEqual(try store.trashMemberships(for: .codex).map(\.managerKey), ["codex:session-a"])
        XCTAssertEqual(try store.operationPreview(id: previewID)?.status, .consumed)
        XCTAssertEqual(try store.operationReport(id: reportID), report)
    }

    func testMoveToArchiveRemovesOnlyManagerMembershipAndKeepsNativeArchivedEvidence() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-archive", refreshedAt: date(100))
        try store.saveTrashMembership(
            makeMembership(nativeID: "session-a", checkpoint: checkpoint),
            checkpoint: checkpoint
        )
        let coordinator = makeCoordinator(
            store: store,
            now: date(110.123456),
            previewID: uuid("00000000-0000-0000-0000-000000001011"),
            reportID: uuid("00000000-0000-0000-0000-000000001012")
        )

        let preview = try await coordinator.prepare(
            operation: .moveToArchive,
            sessions: [makeArchivedSession(nativeID: "session-a", isTrashMember: true)],
            checkpoint: checkpoint
        )
        let freshCheckpoint = makeCheckpoint(
            hash: checkpoint.inventoryHash,
            refreshedAt: date(120)
        )
        try store.upsertProviderCheckpoint(freshCheckpoint)
        let report = try await coordinator.execute(
            previewID: preview.id,
            confirmationToken: preview.confirmationToken,
            freshSnapshot: makeSnapshot(
                checkpoint: freshCheckpoint,
                sessions: [makeArchivedSession(nativeID: "session-a")]
            )
        )

        XCTAssertEqual(report.operation, .moveToArchive)
        XCTAssertEqual(
            report.completedAt,
            PersistentTimestamp.canonical(date(110.123456))
        )
        XCTAssertEqual(report.items.first?.observedNativeState, .archived)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        XCTAssertEqual(
            try store.operationHistory(OperationHistoryQuery(operation: .moveToArchive)).entries.count,
            1
        )
        XCTAssertTrue(
            try store.operationHistory(OperationHistoryQuery(operation: .archive)).entries.isEmpty
        )
    }

    func testMoveToArchiveDoesNotRequireAggregateProtectionCheckpoint() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(
            hash: "inventory-archive-protection-incomplete",
            refreshedAt: date(100),
            protectionComplete: false
        )
        try store.saveTrashMembership(
            makeMembership(nativeID: "session-a", checkpoint: checkpoint),
            checkpoint: checkpoint
        )
        let coordinator = makeCoordinator(
            store: store,
            now: date(110),
            previewID: uuid("00000000-0000-0000-0000-000000001015"),
            reportID: uuid("00000000-0000-0000-0000-000000001016")
        )

        let preview = try await coordinator.prepare(
            operation: .moveToArchive,
            sessions: [makeArchivedSession(nativeID: "session-a", isTrashMember: true)],
            checkpoint: checkpoint
        )
        let freshCheckpoint = makeCheckpoint(
            hash: checkpoint.inventoryHash,
            refreshedAt: date(120),
            protectionComplete: false
        )
        try store.upsertProviderCheckpoint(freshCheckpoint)
        let report = try await coordinator.execute(
            previewID: preview.id,
            confirmationToken: preview.confirmationToken,
            freshSnapshot: makeSnapshot(
                checkpoint: freshCheckpoint,
                sessions: [makeArchivedSession(nativeID: "session-a")]
            )
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .consumed)
    }

    func testExactTargetDriftRejectsEntireBatchWithoutMembershipOrReport() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-before", refreshedAt: date(100))
        try store.upsertProviderCheckpoint(checkpoint)
        let previewID = uuid("00000000-0000-0000-0000-000000001021")
        let reportID = uuid("00000000-0000-0000-0000-000000001022")
        let coordinator = makeCoordinator(
            store: store,
            now: date(110),
            previewID: previewID,
            reportID: reportID
        )
        let preview = try await coordinator.prepare(
            operation: .moveToTrash,
            sessions: [
                makeArchivedSession(nativeID: "session-a"),
                makeArchivedSession(nativeID: "session-b"),
            ],
            checkpoint: checkpoint
        )
        let refreshedCheckpoint = makeCheckpoint(
            hash: "inventory-after",
            refreshedAt: date(120)
        )
        try store.upsertProviderCheckpoint(refreshedCheckpoint)

        do {
            _ = try await coordinator.execute(
                previewID: preview.id,
                confirmationToken: preview.confirmationToken,
                freshSnapshot: makeSnapshot(
                    checkpoint: refreshedCheckpoint,
                    sessions: [
                        makeArchivedSession(nativeID: "session-a", title: "Changed title"),
                        makeArchivedSession(nativeID: "session-b"),
                    ]
                )
            )
            XCTFail("Expected exact target drift to reject the batch.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exact selected session drifted"))
        }
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        XCTAssertNil(try store.operationReport(id: reportID))
        XCTAssertEqual(try store.operationPreview(id: previewID)?.status, .prepared)
    }

    func testUnrelatedInventoryDriftStillAllowsExactMoveToArchive() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let originalCheckpoint = makeCheckpoint(
            hash: "inventory-before-unrelated-change",
            refreshedAt: date(100)
        )
        try store.saveTrashMembership(
            makeMembership(nativeID: "session-a", checkpoint: originalCheckpoint),
            checkpoint: originalCheckpoint
        )
        let previewID = uuid("00000000-0000-0000-0000-000000001023")
        let reportID = uuid("00000000-0000-0000-0000-000000001024")
        let coordinator = makeCoordinator(
            store: store,
            now: date(110),
            previewID: previewID,
            reportID: reportID
        )
        let preview = try await coordinator.prepare(
            operation: .moveToArchive,
            sessions: [makeArchivedSession(nativeID: "session-a", isTrashMember: true)],
            checkpoint: originalCheckpoint
        )
        let refreshedCheckpoint = makeCheckpoint(
            hash: "inventory-after-unrelated-change",
            refreshedAt: date(120)
        )
        try store.upsertProviderCheckpoint(refreshedCheckpoint)

        let report = try await coordinator.execute(
            previewID: preview.id,
            confirmationToken: preview.confirmationToken,
            freshSnapshot: makeSnapshot(
                checkpoint: refreshedCheckpoint,
                sessions: [
                    makeArchivedSession(nativeID: "session-a"),
                    makeArchivedSession(nativeID: "unrelated-session"),
                ]
            )
        )

        XCTAssertEqual(report.id, reportID)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        XCTAssertEqual(try store.operationPreview(id: previewID)?.status, .consumed)
    }

    func testWrongConfirmationLeavesPreparedPreviewAndManagerStateUntouched() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-token", refreshedAt: date(100))
        try store.upsertProviderCheckpoint(checkpoint)
        let previewID = uuid("00000000-0000-0000-0000-000000001025")
        let reportID = uuid("00000000-0000-0000-0000-000000001026")
        let coordinator = makeCoordinator(
            store: store,
            now: date(110),
            previewID: previewID,
            reportID: reportID
        )
        let preview = try await coordinator.prepare(
            operation: .moveToTrash,
            sessions: [makeArchivedSession(nativeID: "session-a")],
            checkpoint: checkpoint
        )
        let freshCheckpoint = makeCheckpoint(
            hash: checkpoint.inventoryHash,
            refreshedAt: date(120)
        )
        try store.upsertProviderCheckpoint(freshCheckpoint)

        do {
            _ = try await coordinator.execute(
                previewID: preview.id,
                confirmationToken: "wrong-token",
                freshSnapshot: makeSnapshot(
                    checkpoint: freshCheckpoint,
                    sessions: [makeArchivedSession(nativeID: "session-a")]
                )
            )
            XCTFail("Expected confirmation mismatch.")
        } catch {
            XCTAssertEqual(error as? PersistentStateError, .confirmationMismatch)
        }
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        XCTAssertNil(try store.operationReport(id: reportID))
        XCTAssertEqual(try store.operationPreview(id: previewID)?.status, .prepared)
    }

    func testMoveToTrashRejectsIncompleteProtectionBeforePreviewPersistence() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "test-runtime",
            inventoryHash: "inventory-protection-incomplete",
            refreshedAt: date(100),
            inventoryComplete: true,
            protectionComplete: false,
            lastErrorCode: "protection-incomplete"
        )
        try store.upsertProviderCheckpoint(checkpoint)
        let previewID = uuid("00000000-0000-0000-0000-000000001027")
        let coordinator = makeCoordinator(
            store: store,
            now: date(110),
            previewID: previewID,
            reportID: uuid("00000000-0000-0000-0000-000000001028")
        )

        do {
            _ = try await coordinator.prepare(
                operation: .moveToTrash,
                sessions: [makeArchivedSession(nativeID: "session-a")],
                checkpoint: checkpoint
            )
            XCTFail("Expected incomplete protection to block Preview.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("complete lifecycle protection"))
        }
        XCTAssertNil(try store.operationPreview(id: previewID))
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
    }

    func testReportInsertFailureRollsBackMembershipAndPreviewConsumption() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-rollback", refreshedAt: date(100))
        try store.upsertProviderCheckpoint(checkpoint)
        let previewID = uuid("00000000-0000-0000-0000-000000001031")
        let reportID = uuid("00000000-0000-0000-0000-000000001032")
        let coordinator = makeCoordinator(
            store: store,
            now: date(110),
            previewID: previewID,
            reportID: reportID
        )
        let preview = try await coordinator.prepare(
            operation: .moveToTrash,
            sessions: [makeArchivedSession(nativeID: "session-a")],
            checkpoint: checkpoint
        )
        let freshCheckpoint = makeCheckpoint(
            hash: checkpoint.inventoryHash,
            refreshedAt: date(120)
        )
        try store.upsertProviderCheckpoint(freshCheckpoint)
        try store.withLockedDatabase { database in
            let sql = """
            CREATE TRIGGER reject_manager_only_report
            BEFORE INSERT ON operation_reports
            BEGIN
                SELECT RAISE(ABORT, 'injected report failure');
            END;
            """
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw PersistentStateError.invalidRecord("Could not install rollback test trigger.")
            }
        }

        do {
            _ = try await coordinator.execute(
                previewID: preview.id,
                confirmationToken: preview.confirmationToken,
                freshSnapshot: makeSnapshot(
                    checkpoint: freshCheckpoint,
                    sessions: [makeArchivedSession(nativeID: "session-a")]
                )
            )
            XCTFail("Expected the injected report failure.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("injected report failure"))
        }
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        XCTAssertNil(try store.operationReport(id: reportID))
        XCTAssertEqual(try store.operationPreview(id: previewID)?.status, .prepared)
    }

    private func makeCoordinator(
        store: SQLiteStateStore,
        now: Date,
        previewID: UUID,
        reportID: UUID
    ) -> ManagerOnlyOperationCoordinator {
        ManagerOnlyOperationCoordinator(
            store: store,
            now: { now },
            makePreviewID: { previewID },
            makeReportID: { reportID }
        )
    }

    private func makeArchivedSession(
        nativeID: String,
        isTrashMember: Bool = false,
        title: String? = nil
    ) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: title ?? "Session \(nativeID)",
            project: SessionProject(id: "project-1", name: "Project", rootPath: "/tmp/project"),
            workingDirectory: "/tmp/project",
            updatedAt: date(90),
            sizeBytes: 100,
            nativeState: .archived,
            isTrashMember: isTrashMember,
            protection: SessionProtection()
        )
    }

    private func makeSnapshot(
        checkpoint: ProviderCheckpointRecord,
        sessions: [AgentSession]
    ) -> ProviderInventorySnapshot {
        ProviderInventorySnapshot(
            provider: checkpoint.provider,
            runtimeVersion: checkpoint.runtimeVersion,
            inventoryHash: checkpoint.inventoryHash,
            observedAt: checkpoint.refreshedAt,
            inventoryComplete: checkpoint.inventoryComplete,
            protectionComplete: checkpoint.protectionComplete,
            sessions: sessions,
            errorCode: checkpoint.lastErrorCode,
            errorMessage: checkpoint.lastErrorMessage
        )
    }

    private func makeCheckpoint(
        hash: String,
        refreshedAt: Date,
        protectionComplete: Bool = true
    ) -> ProviderCheckpointRecord {
        ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "test-runtime",
            inventoryHash: hash,
            refreshedAt: refreshedAt,
            inventoryComplete: true,
            protectionComplete: protectionComplete
        )
    }

    private func makeMembership(
        nativeID: String,
        checkpoint: ProviderCheckpointRecord
    ) -> TrashMembershipRecord {
        TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: nativeID,
            managerKey: "codex:\(nativeID)",
            titleAtEntry: "Session \(nativeID)",
            projectIDAtEntry: "project-1",
            workingDirectoryAtEntry: "/tmp/project",
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: checkpoint.inventoryHash,
            enteredAt: date(80),
            lastReconciledAt: checkpoint.refreshedAt
        )
    }

    private func makeStore(named name: String) throws -> SQLiteStateStore {
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-only-coordinator-\(safeName)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: directory.appendingPathComponent("manager.sqlite3"))
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
