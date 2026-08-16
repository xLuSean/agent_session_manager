@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class OperationHistoryExportTests: XCTestCase {
    func testHistoryQueryUsesStableKeysetPaginationAndFilters() throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let codexCheckpoint = checkpoint(provider: .codex, hash: "codex-inventory")
        let claudeCheckpoint = checkpoint(provider: .claudeCode, hash: "claudeCode-inventory")

        try save(
            bundle(number: 1, provider: .codex, operation: .archive, outcome: .success, completedAt: date(20)),
            checkpoint: codexCheckpoint,
            to: store
        )
        try save(
            bundle(number: 2, provider: .codex, operation: .restore, outcome: .failure, completedAt: date(30)),
            checkpoint: codexCheckpoint,
            to: store
        )
        try save(
            bundle(number: 3, provider: .codex, operation: .restore, outcome: .failure, completedAt: date(30)),
            checkpoint: codexCheckpoint,
            to: store
        )
        try save(
            bundle(number: 4, provider: .claudeCode, operation: .archive, outcome: .success, completedAt: date(40)),
            checkpoint: claudeCheckpoint,
            to: store
        )

        let first = try store.operationHistory(
            OperationHistoryQuery(provider: .codex, limit: 2)
        )
        XCTAssertEqual(first.entries.map(\.reportID), [uuid(1_003), uuid(1_002)])
        XCTAssertEqual(
            first.nextCursor,
            OperationHistoryCursor(completedAt: date(30), reportID: uuid(1_002))
        )

        let second = try store.operationHistory(
            OperationHistoryQuery(provider: .codex, cursor: first.nextCursor, limit: 2)
        )
        XCTAssertEqual(second.entries.map(\.reportID), [uuid(1_001)])
        XCTAssertNil(second.nextCursor)

        let filtered = try store.operationHistory(
            OperationHistoryQuery(
                provider: .codex,
                operation: .restore,
                outcome: .failure,
                completedFrom: date(30),
                completedThrough: date(30)
            )
        )
        XCTAssertEqual(filtered.entries.map(\.reportID), [uuid(1_003), uuid(1_002)])
        XCTAssertEqual(filtered.entries[0].items[0].nativeSessionID, "session-3")
        XCTAssertEqual(filtered.entries[0].items[0].sessionTitle, "Secret Session 3")

        let searched = try store.operationHistory(
            OperationHistoryQuery(provider: .codex, searchText: "secret session 3")
        )
        XCTAssertEqual(searched.entries.map(\.reportID), [uuid(1_003)])

        let searchedByID = try store.operationHistory(
            OperationHistoryQuery(provider: .codex, searchText: "session-2")
        )
        XCTAssertEqual(searchedByID.entries.map(\.reportID), [uuid(1_002)])

        XCTAssertEqual(
            try store.operationHistory(
                OperationHistoryQuery(provider: .codex, searchText: "%")
            ).entries,
            []
        )
    }

    func testInvalidHistoryQueryFailsClosed() throws {
        let store = try makeStore(named: #function)
        defer { store.close() }

        XCTAssertThrowsError(
            try store.operationHistory(OperationHistoryQuery(limit: 0))
        )
        XCTAssertThrowsError(
            try store.operationHistory(
                OperationHistoryQuery(completedFrom: date(20), completedThrough: date(10))
            )
        )
        XCTAssertEqual(try store.operationHistory().entries, [])
    }

    func testHistoryQueryRejectsCorruptReportSummary() throws {
        let originalStore = try makeStore(named: #function)
        let databaseURL = originalStore.databaseURL
        let reportBundle = bundle(
            number: 1,
            provider: .codex,
            operation: .archive,
            outcome: .success,
            completedAt: date(20)
        )
        try save(
            reportBundle,
            checkpoint: checkpoint(provider: .codex, hash: "codex-inventory"),
            to: originalStore
        )
        originalStore.close()

        try executeRawSQL(
            "UPDATE operation_reports SET item_count = 2 WHERE id = '\(reportBundle.report.id.uuidString.lowercased())'",
            databaseURL: databaseURL
        )
        let reopenedStore = try SQLiteStateStore(databaseURL: databaseURL)
        defer { reopenedStore.close() }

        XCTAssertThrowsError(try reopenedStore.operationHistory()) { error in
            guard case let PersistentStateError.invalidRecord(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("summary does not match"))
        }
    }

    func testPrivateDefaultJSONAndCSVKeepFullNativeIDButRedactSensitiveText() throws {
        let nativeID = "01900000-0000-7000-8000-000000000001"
        let entry = exportEntry(nativeID: nativeID)

        let jsonData = try OperationHistoryExporter.json(entries: [entry])
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        XCTAssertTrue(json.contains(nativeID))
        XCTAssertTrue(json.contains("error_code"))
        XCTAssertFalse(json.contains("Private Session Title"))
        XCTAssertFalse(json.contains("/Users/example/PrivateProject"))
        XCTAssertFalse(json.contains("/Users/example/secret/report-error.log"))
        XCTAssertFalse(json.contains("/Users/example/secret/item-error.log"))
        XCTAssertFalse(json.contains("confirmation_token_hash"))
        XCTAssertFalse(json.contains("manifest_hash"))
        XCTAssertFalse(json.contains("expected_protection_hash"))

        let csv = OperationHistoryExporter.csv(entries: [entry])
        XCTAssertTrue(csv.contains(nativeID))
        XCTAssertTrue(csv.contains("report_error_code"))
        XCTAssertFalse(csv.contains("Private Session Title"))
        XCTAssertFalse(csv.contains("/Users/example/PrivateProject"))
        XCTAssertFalse(csv.contains("/Users/example/secret/report-error.log"))
        XCTAssertFalse(csv.contains("/Users/example/secret/item-error.log"))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 3)
    }

    func testExplicitExportPolicyIncludesRequestedTextAndNeutralizesCSVFormulaCells() throws {
        let entry = exportEntry(
            nativeID: "native-id",
            title: "=HYPERLINK(\"https://invalid.example\")"
        )
        let policy = OperationHistoryExportPolicy(
            includeSessionTitles: true,
            includeProjectIDs: true,
            includeErrorMessages: true
        )

        let jsonData = try OperationHistoryExporter.json(entries: [entry], policy: policy)
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        XCTAssertTrue(json.contains("=HYPERLINK"))
        XCTAssertTrue(json.contains("/Users/example/PrivateProject"))
        XCTAssertTrue(json.contains("/Users/example/secret/report-error.log"))
        XCTAssertTrue(json.contains("/Users/example/secret/item-error.log"))

        let csv = OperationHistoryExporter.csv(entries: [entry], policy: policy)
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"https://invalid.example\"\")\""))
        XCTAssertTrue(csv.contains("/Users/example/PrivateProject"))
        XCTAssertTrue(csv.contains("/Users/example/secret/report-error.log"))
        XCTAssertTrue(csv.contains("/Users/example/secret/item-error.log"))
    }

    private typealias Bundle = (
        preview: PersistentOperationPreview,
        report: PersistentOperationReport
    )

    private func bundle(
        number: Int,
        provider: AgentSystem,
        operation: PersistentOperation,
        outcome: PersistentReportOutcome,
        completedAt: Date
    ) -> Bundle {
        let managerKey = "\(provider.rawValue):session-\(number)"
        let preview = PersistentOperationPreview(
            id: uuid(number),
            provider: provider,
            operation: operation,
            confirmationTokenHash: "sha256:secret-token-\(number)",
            manifestHash: "secret-manifest-\(number)",
            providerInventoryHash: "\(provider.rawValue)-inventory",
            createdAt: completedAt.addingTimeInterval(-2),
            expiresAt: completedAt.addingTimeInterval(60),
            items: [
                PersistentPreviewItem(
                    managerKey: managerKey,
                    nativeSessionID: "session-\(number)",
                    expectedNativeState: operation == .restore ? .archived : .active,
                    expectedProtectionHash: "secret-protection-\(number)",
                    expectedTitle: "Secret Session \(number)",
                    expectedProjectID: "/Users/example/Project-\(number)",
                    knownSizeBytes: 100
                ),
            ]
        )
        let itemOutcome: PersistentItemOutcome = outcome == .failure ? .failure : .success
        return (
            preview,
            PersistentOperationReport(
                id: uuid(1_000 + number),
                previewID: preview.id,
                provider: provider,
                operation: operation,
                outcome: outcome,
                startedAt: completedAt.addingTimeInterval(-1),
                completedAt: completedAt,
                releasedBytesComplete: true,
                errorCode: outcome == .failure ? "provider-error" : nil,
                errorMessage: outcome == .failure ? "private provider error" : nil,
                items: [
                    PersistentReportItem(
                        managerKey: managerKey,
                        outcome: itemOutcome,
                        observedNativeState: outcome == .failure ? .unavailable : .archived,
                        verifiedReleasedBytes: 0,
                        evidenceAt: completedAt,
                        errorCode: outcome == .failure ? "item-error" : nil,
                        errorMessage: outcome == .failure ? "private item error" : nil
                    ),
                ]
            )
        )
    }

    private func exportEntry(
        nativeID: String,
        title: String = "Private Session Title"
    ) -> OperationHistoryEntry {
        OperationHistoryEntry(
            reportID: uuid(2_001),
            previewID: uuid(2_002),
            provider: .codex,
            operation: .moveToTrash,
            outcome: .failure,
            startedAt: date(10),
            completedAt: date(20),
            itemCount: 1,
            successCount: 0,
            failureCount: 1,
            unknownCount: 0,
            verifiedReleasedBytes: 0,
            releasedBytesComplete: false,
            errorCode: "report-error",
            errorMessage: "See /Users/example/secret/report-error.log",
            items: [
                OperationHistoryItem(
                    managerKey: "codex:\(nativeID)",
                    nativeSessionID: nativeID,
                    expectedNativeState: .active,
                    sessionTitle: title,
                    projectID: "/Users/example/PrivateProject",
                    knownSizeBytes: 42,
                    outcome: .failure,
                    observedNativeState: .unavailable,
                    evidenceAt: date(20),
                    errorCode: "item-error",
                    errorMessage: "See /Users/example/secret/item-error.log"
                ),
            ]
        )
    }

    private func save(
        _ bundle: Bundle,
        checkpoint: ProviderCheckpointRecord,
        to store: SQLiteStateStore
    ) throws {
        try store.saveOperationPreview(bundle.preview, checkpoint: checkpoint)
        try store.saveOperationReport(bundle.report)
    }

    private func checkpoint(provider: AgentSystem, hash: String) -> ProviderCheckpointRecord {
        ProviderCheckpointRecord(
            provider: provider,
            runtimeVersion: "test-runtime",
            inventoryHash: hash,
            refreshedAt: date(1),
            inventoryComplete: true,
            protectionComplete: true
        )
    }

    private func makeStore(named name: String) throws -> SQLiteStateStore {
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        return try SQLiteStateStore(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-session-manager-history-\(safeName)-\(UUID().uuidString)")
                .appendingPathComponent("manager.sqlite3")
        )
    }

    private func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
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
