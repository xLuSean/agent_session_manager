@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class PersistentStateRepositoryTests: XCTestCase {
    func testCheckpointAndTrashMembershipRoundTripIsIdempotent() throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-1")
        let membership = makeMembership(
            nativeID: "trash-1",
            hash: checkpoint.inventoryHash,
            enteredAt: date(10),
            reconciledAt: date(20)
        )

        try store.saveTrashMembership(membership, checkpoint: checkpoint)

        XCTAssertEqual(try store.providerCheckpoint(for: .codex), checkpoint)
        XCTAssertEqual(try store.trashMemberships(for: .codex), [membership])

        let repeated = TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: membership.nativeSessionID,
            managerKey: membership.managerKey,
            titleAtEntry: "must-not-replace-original-evidence",
            workingDirectoryAtEntry: "/different",
            nativeStateAtEntry: .active,
            providerInventoryHashAtEntry: checkpoint.inventoryHash,
            enteredAt: date(99),
            lastReconciledAt: date(30)
        )
        try store.saveTrashMembership(repeated, checkpoint: checkpoint)

        let stored = try XCTUnwrap(store.trashMemberships(for: .codex).first)
        XCTAssertEqual(stored.titleAtEntry, membership.titleAtEntry)
        XCTAssertEqual(stored.enteredAt, membership.enteredAt)
        XCTAssertEqual(stored.lastReconciledAt, date(30))

        XCTAssertTrue(try store.removeTrashMembership(managerKey: membership.managerKey))
        XCTAssertFalse(try store.removeTrashMembership(managerKey: membership.managerKey))
        XCTAssertEqual(try store.trashMemberships(for: .codex), [])
    }

    func testPreviewHeaderAndItemsAreSavedAtomicallyWithoutPlaintextTokenAPI() throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-preview")
        let preview = makePreview(checkpoint: checkpoint)

        try store.saveOperationPreview(preview, checkpoint: checkpoint)

        XCTAssertEqual(try store.operationPreview(id: preview.id), preview)
        XCTAssertEqual(
            try store.operationPreview(id: preview.id)?.confirmationTokenHash,
            "sha256:confirmation-token-hash"
        )

        let duplicateItemPreview = PersistentOperationPreview(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            provider: .codex,
            operation: .moveToTrash,
            confirmationTokenHash: "sha256:other",
            manifestHash: "manifest-other",
            providerInventoryHash: checkpoint.inventoryHash,
            createdAt: date(40),
            expiresAt: date(50),
            items: [preview.items[0], preview.items[0]]
        )
        XCTAssertThrowsError(
            try store.saveOperationPreview(duplicateItemPreview, checkpoint: checkpoint)
        ) { error in
            XCTAssertEqual(error as? PersistentStateError, .duplicateManagerKey("codex:session-a"))
        }
        XCTAssertNil(try store.operationPreview(id: duplicateItemPreview.id))
    }

    func testArchivePreviewCanPersistAndClaimWithOperationSpecificProtectionCoverage() throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: "archive-attempt-inventory",
            refreshedAt: date(20),
            inventoryComplete: true,
            protectionComplete: false
        )
        let archive = makePreview(checkpoint: checkpoint, operation: .archive)

        try store.saveOperationPreview(archive, checkpoint: checkpoint)
        let claimed = try store.claimOperationPreviewForExecution(
            id: archive.id,
            now: date(40),
            confirmationTokenHash: archive.confirmationTokenHash
        )

        XCTAssertEqual(claimed.preview.status, .executing)
        XCTAssertFalse(claimed.checkpoint.protectionComplete)

        let moveToTrash = makePreview(
            checkpoint: checkpoint,
            operation: .moveToTrash,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        )
        XCTAssertThrowsError(
            try store.saveOperationPreview(moveToTrash, checkpoint: checkpoint)
        )
    }

    func testReportRequiresExactFrozenItemSetAndCommitsAtomically() throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-report")
        let preview = makePreview(checkpoint: checkpoint)
        try store.saveOperationPreview(preview, checkpoint: checkpoint)

        let incompleteReport = PersistentOperationReport(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            previewID: preview.id,
            provider: .codex,
            operation: .moveToTrash,
            outcome: .partial,
            startedAt: date(50),
            completedAt: date(60),
            releasedBytesComplete: false,
            items: [
                PersistentReportItem(
                    managerKey: "codex:session-a",
                    outcome: .success,
                    observedNativeState: .archived,
                    evidenceAt: date(60)
                ),
            ]
        )
        XCTAssertThrowsError(try store.saveOperationReport(incompleteReport)) { error in
            XCTAssertEqual(error as? PersistentStateError, .previewItemSetMismatch)
        }
        XCTAssertNil(try store.operationReport(id: incompleteReport.id))
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)

        let report = PersistentOperationReport(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            previewID: preview.id,
            provider: .codex,
            operation: .moveToTrash,
            outcome: .partial,
            startedAt: date(50),
            completedAt: date(60),
            releasedBytesComplete: false,
            errorCode: "partial-readback",
            items: [
                PersistentReportItem(
                    managerKey: "codex:session-a",
                    outcome: .success,
                    observedNativeState: .archived,
                    verifiedReleasedBytes: 0,
                    evidenceAt: date(60)
                ),
                PersistentReportItem(
                    managerKey: "codex:session-b",
                    outcome: .unknown,
                    observedNativeState: .unavailable,
                    evidenceAt: date(60),
                    errorCode: "readback-timeout",
                    errorMessage: "Exact-ID readback did not complete."
                ),
            ]
        )
        try store.saveOperationReport(report)

        XCTAssertEqual(try store.operationReport(id: report.id), report)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .consumed)
        XCTAssertThrowsError(try store.saveOperationReport(report))
        XCTAssertEqual(try store.operationReport(id: report.id), report)
    }

    func testMoveToArchiveIntentRoundTripsWithoutMasqueradingAsArchive() throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = makeCheckpoint(hash: "inventory-move-to-archive")
        let preview = makePreview(checkpoint: checkpoint, operation: .moveToArchive)
        try store.saveOperationPreview(preview, checkpoint: checkpoint)
        let report = PersistentOperationReport(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
            previewID: preview.id,
            provider: .codex,
            operation: .moveToArchive,
            outcome: .success,
            startedAt: date(50),
            completedAt: date(60),
            releasedBytesComplete: true,
            items: preview.items.map {
                PersistentReportItem(
                    managerKey: $0.managerKey,
                    outcome: .success,
                    observedNativeState: .archived,
                    evidenceAt: date(60)
                )
            }
        )
        try store.saveOperationReport(report)

        XCTAssertEqual(try store.operationPreview(id: preview.id)?.operation, .moveToArchive)
        XCTAssertEqual(try store.operationReport(id: report.id)?.operation, .moveToArchive)
        XCTAssertEqual(
            try store.operationHistory(OperationHistoryQuery(operation: .moveToArchive)).entries.count,
            1
        )
        XCTAssertTrue(
            try store.operationHistory(OperationHistoryQuery(operation: .archive)).entries.isEmpty
        )
    }

    func testTrashMembershipRejectsIncompleteCheckpointWithoutPartialWrite() throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let checkpoint = ProviderCheckpointRecord(
            provider: .codex,
            inventoryHash: "partial-inventory",
            refreshedAt: date(20),
            inventoryComplete: false,
            protectionComplete: false,
            lastErrorCode: "pagination-truncated"
        )
        let membership = makeMembership(
            nativeID: "unsafe",
            hash: checkpoint.inventoryHash,
            enteredAt: date(10),
            reconciledAt: date(20)
        )

        XCTAssertThrowsError(try store.saveTrashMembership(membership, checkpoint: checkpoint))
        XCTAssertNil(try store.providerCheckpoint(for: .codex))
        XCTAssertEqual(try store.trashMemberships(for: .codex), [])
    }

    func testCheckpointCannotRegressOrForkAtSameTimestamp() throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let current = makeCheckpoint(hash: "current")
        try store.upsertProviderCheckpoint(current)

        let stale = ProviderCheckpointRecord(
            provider: .codex,
            inventoryHash: "stale",
            refreshedAt: date(19),
            inventoryComplete: true,
            protectionComplete: true
        )
        XCTAssertThrowsError(try store.upsertProviderCheckpoint(stale))

        let forked = ProviderCheckpointRecord(
            provider: .codex,
            inventoryHash: "forked",
            refreshedAt: current.refreshedAt,
            inventoryComplete: true,
            protectionComplete: true
        )
        XCTAssertThrowsError(try store.upsertProviderCheckpoint(forked))
        XCTAssertEqual(try store.providerCheckpoint(for: .codex), current)
    }

    func testReconciliationCommitRejectsMembershipSetDriftAtomically() throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let original = makeCheckpoint(hash: "original")
        let membership = makeMembership(
            nativeID: "trash-1",
            hash: original.inventoryHash,
            enteredAt: date(10),
            reconciledAt: date(20)
        )
        try store.saveTrashMembership(membership, checkpoint: original)
        let newer = ProviderCheckpointRecord(
            provider: .codex,
            inventoryHash: "newer",
            refreshedAt: date(30),
            inventoryComplete: true,
            protectionComplete: true
        )

        XCTAssertThrowsError(
            try store.commitReconciliationCheckpoint(
                newer,
                expectedTrashManagerKeys: []
            )
        )
        XCTAssertEqual(try store.providerCheckpoint(for: .codex), original)
        XCTAssertEqual(
            try store.trashMemberships(for: .codex).first?.lastReconciledAt,
            date(20)
        )
    }

    private func makeStore(named name: String) throws -> SQLiteStateStore {
        let safeName = name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-manager-repository-\(safeName)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: directory.appendingPathComponent("manager.sqlite3"))
    }

    private func makeCheckpoint(hash: String) -> ProviderCheckpointRecord {
        ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "test-runtime",
            inventoryHash: hash,
            refreshedAt: date(20),
            inventoryComplete: true,
            protectionComplete: true
        )
    }

    private func makeMembership(
        nativeID: String,
        hash: String,
        enteredAt: Date,
        reconciledAt: Date
    ) -> TrashMembershipRecord {
        TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: nativeID,
            managerKey: "codex:\(nativeID)",
            titleAtEntry: "Trash \(nativeID)",
            projectIDAtEntry: "project-1",
            workingDirectoryAtEntry: "/tmp/project-1",
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: hash,
            enteredAt: enteredAt,
            lastReconciledAt: reconciledAt
        )
    }

    private func makePreview(
        checkpoint: ProviderCheckpointRecord,
        operation: PersistentOperation = .moveToTrash,
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    ) -> PersistentOperationPreview {
        PersistentOperationPreview(
            id: id,
            provider: .codex,
            operation: operation,
            confirmationTokenHash: "sha256:confirmation-token-hash",
            manifestHash: "manifest-1",
            providerInventoryHash: checkpoint.inventoryHash,
            createdAt: date(30),
            expiresAt: date(60),
            items: [
                PersistentPreviewItem(
                    managerKey: "codex:session-a",
                    nativeSessionID: "session-a",
                    expectedNativeState: .active,
                    expectedProtectionHash: "protection-a",
                    expectedTitle: "Session A",
                    expectedProjectID: "project-1",
                    knownSizeBytes: 100
                ),
                PersistentPreviewItem(
                    managerKey: "codex:session-b",
                    nativeSessionID: "session-b",
                    expectedNativeState: .archived,
                    expectedProtectionHash: "protection-b",
                    expectedTitle: "Session B"
                ),
            ]
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
