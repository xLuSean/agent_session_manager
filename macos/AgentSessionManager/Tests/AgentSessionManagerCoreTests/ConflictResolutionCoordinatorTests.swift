@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class ConflictResolutionCoordinatorTests: XCTestCase {
    func testAcceptNativeRestoreRemovesMembershipAndReportsActiveWithoutProviderDependency() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-active", protectionComplete: false)
        let membership = makeMembership(checkpoint: checkpoint)
        try store.saveTrashMembership(membership, checkpoint: checkpoint)
        let coordinator = makeCoordinator(store: store, now: 110.123456)

        let preview = try await coordinator.prepareAcceptNativeRestore(
            state: makeConflict(membership: membership),
            checkpoint: checkpoint
        )
        let report = try await coordinator.executeAcceptNativeRestore(
            previewID: preview.id,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(preview.operation, .restore)
        XCTAssertEqual(preview.items.first?.beforeCollection, .trash)
        XCTAssertEqual(preview.items.first?.targetCollection, .active)
        XCTAssertEqual(report.operation, .restore)
        XCTAssertEqual(
            report.completedAt,
            PersistentTimestamp.canonical(date(110.123456))
        )
        XCTAssertEqual(report.items.first?.observedNativeState, .active)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .consumed)
        XCTAssertEqual(try store.operationReport(id: report.id), report)
    }

    func testFreshReconciliationTimestampDoesNotInvalidateFrozenMembership() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "same-native-hash", protectionComplete: false)
        let membership = makeMembership(checkpoint: checkpoint)
        try store.saveTrashMembership(membership, checkpoint: checkpoint)
        let coordinator = makeCoordinator(store: store)
        let preview = try await coordinator.prepareAcceptNativeRestore(
            state: makeConflict(membership: membership),
            checkpoint: checkpoint
        )

        let refreshed = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: checkpoint.runtimeVersion,
            inventoryHash: checkpoint.inventoryHash,
            refreshedAt: date(120),
            inventoryComplete: true,
            protectionComplete: false,
            lastErrorCode: "protection-incomplete"
        )
        try store.commitReconciliationCheckpoint(
            refreshed,
            expectedTrashManagerKeys: [membership.managerKey]
        )

        let report = try await coordinator.executeAcceptNativeRestore(
            previewID: preview.id,
            confirmationToken: preview.confirmationToken
        )
        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
    }

    func testCheckpointDriftRejectsWithoutRemovingMembershipOrWritingReport() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-before", protectionComplete: false)
        let membership = makeMembership(checkpoint: checkpoint)
        try store.saveTrashMembership(membership, checkpoint: checkpoint)
        let previewID = uuid("00000000-0000-0000-0000-000000002001")
        let reportID = uuid("00000000-0000-0000-0000-000000002002")
        let coordinator = makeCoordinator(
            store: store,
            previewID: previewID,
            reportID: reportID
        )
        let preview = try await coordinator.prepareAcceptNativeRestore(
            state: makeConflict(membership: membership),
            checkpoint: checkpoint
        )
        try store.commitReconciliationCheckpoint(
            makeCheckpoint(hash: "inventory-after", protectionComplete: false, refreshedAt: 120),
            expectedTrashManagerKeys: [membership.managerKey]
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.executeAcceptNativeRestore(
                previewID: preview.id,
                confirmationToken: preview.confirmationToken
            )
        }
        XCTAssertEqual(try store.trashMemberships(for: .codex), [
            TrashMembershipRecord(
                provider: membership.provider,
                nativeSessionID: membership.nativeSessionID,
                managerKey: membership.managerKey,
                titleAtEntry: membership.titleAtEntry,
                projectIDAtEntry: membership.projectIDAtEntry,
                workingDirectoryAtEntry: membership.workingDirectoryAtEntry,
                nativeStateAtEntry: membership.nativeStateAtEntry,
                providerInventoryHashAtEntry: membership.providerInventoryHashAtEntry,
                enteredAt: membership.enteredAt,
                lastReconciledAt: date(120)
            )
        ])
        XCTAssertNil(try store.operationReport(id: reportID))
        XCTAssertEqual(try store.operationPreview(id: previewID)?.status, .prepared)
    }

    func testWrongTokenLeavesMembershipAndPreviewUntouched() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-token", protectionComplete: false)
        let membership = makeMembership(checkpoint: checkpoint)
        try store.saveTrashMembership(membership, checkpoint: checkpoint)
        let coordinator = makeCoordinator(store: store)
        let preview = try await coordinator.prepareAcceptNativeRestore(
            state: makeConflict(membership: membership),
            checkpoint: checkpoint
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.executeAcceptNativeRestore(
                previewID: preview.id,
                confirmationToken: "wrong-token"
            )
        }
        XCTAssertEqual(try store.trashMemberships(for: .codex).count, 1)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)
    }

    func testAnyTrashMembershipSetDriftRejectsEntireResolution() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-membership-drift", protectionComplete: false)
        let membership = makeMembership(checkpoint: checkpoint)
        try store.saveTrashMembership(membership, checkpoint: checkpoint)
        let coordinator = makeCoordinator(store: store)
        let preview = try await coordinator.prepareAcceptNativeRestore(
            state: makeConflict(membership: membership),
            checkpoint: checkpoint
        )
        try store.saveTrashMembership(
            TrashMembershipRecord(
                provider: .codex,
                nativeSessionID: "other",
                managerKey: "codex:other",
                titleAtEntry: "Other session",
                nativeStateAtEntry: .archived,
                providerInventoryHashAtEntry: checkpoint.inventoryHash,
                enteredAt: date(105),
                lastReconciledAt: checkpoint.refreshedAt
            ),
            checkpoint: checkpoint
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.executeAcceptNativeRestore(
                previewID: preview.id,
                confirmationToken: preview.confirmationToken
            )
        }
        XCTAssertEqual(try store.trashMemberships(for: .codex).count, 2)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)
    }

    func testReportFailureRollsBackMembershipRemovalAndPreviewConsumption() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-rollback", protectionComplete: false)
        let membership = makeMembership(checkpoint: checkpoint)
        try store.saveTrashMembership(membership, checkpoint: checkpoint)
        let coordinator = makeCoordinator(store: store)
        let preview = try await coordinator.prepareAcceptNativeRestore(
            state: makeConflict(membership: membership),
            checkpoint: checkpoint
        )
        try store.withLockedDatabase { database in
            let sql = """
            CREATE TRIGGER reject_conflict_report
            BEFORE INSERT ON operation_reports
            BEGIN
                SELECT RAISE(ABORT, 'injected conflict report failure');
            END;
            """
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw PersistentStateError.invalidRecord("Could not install rollback trigger.")
            }
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.executeAcceptNativeRestore(
                previewID: preview.id,
                confirmationToken: preview.confirmationToken
            )
        }
        XCTAssertEqual(try store.trashMemberships(for: .codex).count, 1)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)
    }

    private func makeCoordinator(
        store: SQLiteStateStore,
        now: TimeInterval = 110,
        previewID: UUID = UUID(),
        reportID: UUID = UUID()
    ) -> ConflictResolutionCoordinator {
        ConflictResolutionCoordinator(
            store: store,
            now: { self.date(now) },
            makePreviewID: { previewID },
            makeReportID: { reportID }
        )
    }

    private func makeConflict(
        membership: TrashMembershipRecord
    ) -> ReconciledSessionState {
        let session = AgentSession(
            system: .codex,
            nativeID: membership.nativeSessionID,
            title: "Conflict session",
            project: SessionProject(id: "project-1", name: "Project", rootPath: "/tmp/project"),
            workingDirectory: "/tmp/project",
            updatedAt: date(100),
            sizeBytes: 42,
            nativeState: .active,
            isTrashMember: true,
            protection: SessionProtection(
                isPinnedKnown: false,
                isRunningKnown: false,
                isCurrentKnown: false,
                hasPinnedDescendantKnown: false
            )
        )
        return ReconciledSessionState(
            managerKey: session.id,
            liveSession: session,
            trashMembership: membership,
            status: .nativeActiveTrashConflict,
            isStableForLifecyclePreview: false
        )
    }

    private func makeMembership(
        checkpoint: ProviderCheckpointRecord
    ) -> TrashMembershipRecord {
        TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: "conflict",
            managerKey: "codex:conflict",
            titleAtEntry: "Conflict session",
            projectIDAtEntry: "project-1",
            workingDirectoryAtEntry: "/tmp/project",
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: checkpoint.inventoryHash,
            enteredAt: date(90),
            lastReconciledAt: checkpoint.refreshedAt
        )
    }

    private func makeCheckpoint(
        hash: String,
        protectionComplete: Bool,
        refreshedAt: TimeInterval = 100
    ) -> ProviderCheckpointRecord {
        ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "test-runtime",
            inventoryHash: hash,
            refreshedAt: date(refreshedAt),
            inventoryComplete: true,
            protectionComplete: protectionComplete,
            lastErrorCode: protectionComplete ? nil : "protection-incomplete"
        )
    }

    private func makeStore(named name: String) throws -> SQLiteStateStore {
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conflict-coordinator-\(safeName)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: directory.appendingPathComponent("manager.sqlite3"))
    }

    private func uuid(_ value: String) -> UUID { UUID(uuidString: value)! }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {}
}
