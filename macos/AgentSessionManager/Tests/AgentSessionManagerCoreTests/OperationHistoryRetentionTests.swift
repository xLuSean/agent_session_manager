@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class OperationHistoryRetentionTests: XCTestCase {
    func testAutomaticRetentionPrunesWholeOldestBundleAndPreservesOtherState() throws {
        let databaseURL = makeDatabaseURL(named: #function)
        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            historyRetentionPolicy: OperationHistoryRetentionPolicy(
                maximumReportsPerProvider: 2
            )
        )
        defer { store.close() }
        let codexCheckpoint = checkpoint(provider: .codex, hash: "codex-inventory")
        let claudeCheckpoint = checkpoint(provider: .claudeCode, hash: "claude-inventory")
        let membership = TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: "trash-member",
            managerKey: "codex:trash-member",
            titleAtEntry: "Retained Trash intent",
            workingDirectoryAtEntry: "/tmp/project",
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: codexCheckpoint.inventoryHash,
            enteredAt: date(1),
            lastReconciledAt: date(2)
        )
        try store.saveTrashMembership(membership, checkpoint: codexCheckpoint)

        let pendingPreview = preview(
            number: 90,
            provider: .codex,
            checkpoint: codexCheckpoint,
            createdAt: date(90)
        )
        try store.saveOperationPreview(pendingPreview, checkpoint: codexCheckpoint)

        let claudeBundle = bundle(
            number: 50,
            provider: .claudeCode,
            checkpoint: claudeCheckpoint,
            completedAt: date(50)
        )
        try save(claudeBundle, checkpoint: claudeCheckpoint, to: store)

        let oldest = bundle(
            number: 1,
            provider: .codex,
            checkpoint: codexCheckpoint,
            completedAt: date(10)
        )
        let middle = bundle(
            number: 2,
            provider: .codex,
            checkpoint: codexCheckpoint,
            completedAt: date(20)
        )
        let newest = bundle(
            number: 3,
            provider: .codex,
            checkpoint: codexCheckpoint,
            completedAt: date(30)
        )
        try save(oldest, checkpoint: codexCheckpoint, to: store)
        try save(middle, checkpoint: codexCheckpoint, to: store)
        let result = try save(newest, checkpoint: codexCheckpoint, to: store)

        XCTAssertEqual(result.provider, .codex)
        XCTAssertEqual(result.retainedReportCount, 2)
        XCTAssertEqual(result.deletedReportIDs, [oldest.report.id])
        XCTAssertEqual(result.deletedPreviewIDs, [oldest.preview.id])
        XCTAssertEqual(result.deletedItemCount, 1)
        XCTAssertNil(try store.operationReport(id: oldest.report.id))
        XCTAssertNil(try store.operationPreview(id: oldest.preview.id))
        XCTAssertEqual(try store.operationReport(id: middle.report.id), middle.report)
        XCTAssertEqual(try store.operationReport(id: newest.report.id), newest.report)
        XCTAssertEqual(try store.operationReport(id: claudeBundle.report.id), claudeBundle.report)
        XCTAssertEqual(try store.operationPreview(id: pendingPreview.id), pendingPreview)
        XCTAssertEqual(try store.trashMemberships(for: .codex), [membership])
        XCTAssertEqual(try store.providerCheckpoint(for: .codex), codexCheckpoint)

        let idempotent = try store.pruneOperationHistory(for: .codex)
        XCTAssertEqual(idempotent.retainedReportCount, 2)
        XCTAssertEqual(idempotent.deletedReportIDs, [])
        XCTAssertEqual(idempotent.deletedPreviewIDs, [])
        XCTAssertEqual(idempotent.deletedItemCount, 0)
    }

    func testRetentionRollbackRestoresEarlierCandidateWhenLaterBundleIsInvalid() throws {
        let databaseURL = makeDatabaseURL(named: #function)
        let checkpoint = checkpoint(provider: .codex, hash: "rollback-inventory")
        let bundles = (1 ... 3).map { number in
            bundle(
                number: number,
                provider: .codex,
                checkpoint: checkpoint,
                completedAt: date(TimeInterval(number * 10))
            )
        }

        var store: SQLiteStateStore? = try SQLiteStateStore(
            databaseURL: databaseURL,
            historyRetentionPolicy: OperationHistoryRetentionPolicy(
                maximumReportsPerProvider: 3
            )
        )
        for bundle in bundles {
            try save(bundle, checkpoint: checkpoint, to: try XCTUnwrap(store))
        }
        store?.close()
        store = nil

        try executeRawSQL(
            "UPDATE operation_reports SET item_count = 2 WHERE id = '\(bundles[0].report.id.uuidString.lowercased())'",
            databaseURL: databaseURL
        )

        let pruningStore = try SQLiteStateStore(
            databaseURL: databaseURL,
            historyRetentionPolicy: OperationHistoryRetentionPolicy(
                maximumReportsPerProvider: 1
            )
        )
        defer { pruningStore.close() }

        XCTAssertThrowsError(try pruningStore.pruneOperationHistory(for: .codex))
        for bundle in bundles {
            XCTAssertNotNil(try pruningStore.operationReport(id: bundle.report.id))
            XCTAssertNotNil(try pruningStore.operationPreview(id: bundle.preview.id))
        }
    }

    func testInvalidRetentionLimitFailsBeforeOpeningStore() {
        let databaseURL = makeDatabaseURL(named: #function)

        XCTAssertThrowsError(
            try SQLiteStateStore(
                databaseURL: databaseURL,
                historyRetentionPolicy: OperationHistoryRetentionPolicy(
                    maximumReportsPerProvider: 0
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SQLiteStateStoreError,
                .invalidHistoryRetentionLimit(0)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testExplicitClearDeletesExactHistoryBundleAndPreservesManagerState() throws {
        let store = try SQLiteStateStore(databaseURL: makeDatabaseURL(named: #function))
        defer { store.close() }
        let codexCheckpoint = checkpoint(provider: .codex, hash: "clear-codex")
        let claudeCheckpoint = checkpoint(provider: .claudeCode, hash: "clear-claude")
        let membership = TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: "trash-member",
            managerKey: "codex:trash-member",
            titleAtEntry: "Keep Trash membership",
            workingDirectoryAtEntry: "/tmp/project",
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: codexCheckpoint.inventoryHash,
            enteredAt: date(1),
            lastReconciledAt: date(2)
        )
        try store.saveTrashMembership(membership, checkpoint: codexCheckpoint)
        let pending = preview(
            number: 90,
            provider: .codex,
            checkpoint: codexCheckpoint,
            createdAt: date(90)
        )
        try store.saveOperationPreview(pending, checkpoint: codexCheckpoint)
        let deleted = bundle(
            number: 1,
            provider: .codex,
            checkpoint: codexCheckpoint,
            completedAt: date(10)
        )
        let retained = bundle(
            number: 2,
            provider: .codex,
            checkpoint: codexCheckpoint,
            completedAt: date(20)
        )
        let otherProvider = bundle(
            number: 3,
            provider: .claudeCode,
            checkpoint: claudeCheckpoint,
            completedAt: date(30)
        )
        try save(deleted, checkpoint: codexCheckpoint, to: store)
        try save(retained, checkpoint: codexCheckpoint, to: store)
        try save(otherProvider, checkpoint: claudeCheckpoint, to: store)

        XCTAssertThrowsError(
            try store.clearOperationHistory(
                reportIDs: [deleted.report.id],
                provider: .codex,
                confirmationToken: "WRONG",
                expectedConfirmationToken: "CLEAR-REPORTS-EXACT"
            )
        )
        XCTAssertEqual(try store.operationReport(id: deleted.report.id), deleted.report)

        let result = try store.clearOperationHistory(
            reportIDs: [deleted.report.id],
            provider: .codex,
            confirmationToken: "CLEAR-REPORTS-EXACT",
            expectedConfirmationToken: "CLEAR-REPORTS-EXACT"
        )

        XCTAssertEqual(result.provider, .codex)
        XCTAssertEqual(result.deletedReportIDs, [deleted.report.id])
        XCTAssertEqual(result.deletedPreviewIDs, [deleted.preview.id])
        XCTAssertEqual(result.deletedItemCount, 1)
        XCTAssertNil(try store.operationReport(id: deleted.report.id))
        XCTAssertNil(try store.operationPreview(id: deleted.preview.id))
        XCTAssertEqual(try store.operationReport(id: retained.report.id), retained.report)
        XCTAssertEqual(try store.operationReport(id: otherProvider.report.id), otherProvider.report)
        XCTAssertEqual(try store.operationPreview(id: pending.id), pending)
        XCTAssertEqual(try store.trashMemberships(for: .codex), [membership])
        XCTAssertEqual(try store.providerCheckpoint(for: .codex), codexCheckpoint)
    }

    func testExplicitClearSelectionDriftAndMidBatchFailureRollbackCompletely() throws {
        let databaseURL = makeDatabaseURL(named: #function)
        let checkpoint = checkpoint(provider: .codex, hash: "clear-rollback")
        let first = bundle(
            number: 1,
            provider: .codex,
            checkpoint: checkpoint,
            completedAt: date(10)
        )
        let second = bundle(
            number: 2,
            provider: .codex,
            checkpoint: checkpoint,
            completedAt: date(20)
        )
        var store: SQLiteStateStore? = try SQLiteStateStore(databaseURL: databaseURL)
        try save(first, checkpoint: checkpoint, to: try XCTUnwrap(store))
        try save(second, checkpoint: checkpoint, to: try XCTUnwrap(store))

        XCTAssertThrowsError(
            try store?.clearOperationHistory(
                reportIDs: [first.report.id, uuid(9_999)],
                provider: .codex,
                confirmationToken: "CLEAR-REPORTS-ROLLBACK",
                expectedConfirmationToken: "CLEAR-REPORTS-ROLLBACK"
            )
        )
        XCTAssertEqual(try store?.operationReport(id: first.report.id), first.report)

        store?.close()
        store = nil
        try executeRawSQL(
            "UPDATE operation_reports SET item_count = 2 WHERE id = '\(second.report.id.uuidString.lowercased())'",
            databaseURL: databaseURL
        )
        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        defer { reopened.close() }

        XCTAssertThrowsError(
            try reopened.clearOperationHistory(
                reportIDs: [first.report.id, second.report.id],
                provider: .codex,
                confirmationToken: "CLEAR-REPORTS-ROLLBACK",
                expectedConfirmationToken: "CLEAR-REPORTS-ROLLBACK"
            )
        )
        XCTAssertNotNil(try reopened.operationReport(id: first.report.id))
        XCTAssertNotNil(try reopened.operationReport(id: second.report.id))
        XCTAssertNotNil(try reopened.operationPreview(id: first.preview.id))
        XCTAssertNotNil(try reopened.operationPreview(id: second.preview.id))
    }

    private typealias Bundle = (
        preview: PersistentOperationPreview,
        report: PersistentOperationReport
    )

    @discardableResult
    private func save(
        _ bundle: Bundle,
        checkpoint: ProviderCheckpointRecord,
        to store: SQLiteStateStore
    ) throws -> OperationHistoryPruneResult {
        try store.saveOperationPreview(bundle.preview, checkpoint: checkpoint)
        return try store.saveOperationReport(bundle.report)
    }

    private func bundle(
        number: Int,
        provider: AgentSystem,
        checkpoint: ProviderCheckpointRecord,
        completedAt: Date
    ) -> Bundle {
        let preview = preview(
            number: number,
            provider: provider,
            checkpoint: checkpoint,
            createdAt: completedAt.addingTimeInterval(-2)
        )
        return (
            preview,
            PersistentOperationReport(
                id: uuid(1_000 + number),
                previewID: preview.id,
                provider: provider,
                operation: .archive,
                outcome: .success,
                startedAt: completedAt.addingTimeInterval(-1),
                completedAt: completedAt,
                releasedBytesComplete: true,
                items: [
                    PersistentReportItem(
                        managerKey: "\(provider.rawValue):session-\(number)",
                        outcome: .success,
                        observedNativeState: .archived,
                        verifiedReleasedBytes: 0,
                        evidenceAt: completedAt
                    ),
                ]
            )
        )
    }

    private func preview(
        number: Int,
        provider: AgentSystem,
        checkpoint: ProviderCheckpointRecord,
        createdAt: Date
    ) -> PersistentOperationPreview {
        PersistentOperationPreview(
            id: uuid(number),
            provider: provider,
            operation: .archive,
            confirmationTokenHash: "sha256:token-\(number)",
            manifestHash: "manifest-\(number)",
            providerInventoryHash: checkpoint.inventoryHash,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(60),
            items: [
                PersistentPreviewItem(
                    managerKey: "\(provider.rawValue):session-\(number)",
                    nativeSessionID: "session-\(number)",
                    expectedNativeState: .active,
                    expectedProtectionHash: "protection-\(number)",
                    expectedTitle: "Session \(number)"
                ),
            ]
        )
    }

    private func checkpoint(
        provider: AgentSystem,
        hash: String
    ) -> ProviderCheckpointRecord {
        ProviderCheckpointRecord(
            provider: provider,
            runtimeVersion: "test-runtime",
            inventoryHash: hash,
            refreshedAt: date(2),
            inventoryComplete: true,
            protectionComplete: true
        )
    }

    private func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func makeDatabaseURL(named name: String) -> URL {
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-manager-retention-\(safeName)-\(UUID().uuidString)")
            .appendingPathComponent("manager.sqlite3")
    }

    private func executeRawSQL(_ sql: String, databaseURL: URL) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            throw SQLiteStateStoreError.openFailed(
                path: databaseURL.path,
                message: "Test corruption connection could not open."
            )
        }
        defer { sqlite3_close_v2(database) }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteStateStoreError.sqlite(
                operation: "test-corruption",
                code: result,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
    }
}
