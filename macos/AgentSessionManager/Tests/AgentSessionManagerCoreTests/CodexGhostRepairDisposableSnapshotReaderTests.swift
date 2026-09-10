#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class CodexGhostRepairDisposableSnapshotReaderTests: XCTestCase {
    func testCategoryAAndBOneAndTenSnapshotsArePrivateAndByteStable() throws {
        for category in [CodexGhostRepairCategory.ordinary, .automation] {
            for count in [1, 10] {
                let fixture = try makeFixture(
                    label: "\(#function)-\(category.rawValue)-\(count)",
                    category: category,
                    count: count
                )
                let before = try fingerprint(fixture.bundle)

                let evidence = try CodexGhostRepairDisposableSnapshotReader.read(
                    bundle: fixture.bundle,
                    targetIDs: fixture.targetIDs
                )

                XCTAssertEqual(evidence.desktopSchemaVersion, 32)
                XCTAssertEqual(evidence.summariesSchemaVersion, 2)
                XCTAssertEqual(evidence.historySchemaVersion, 3)
                XCTAssertEqual(evidence.targets.map(\.threadID), fixture.targetIDs)
                XCTAssertTrue(evidence.satisfiesPrivacyContract)
                for target in evidence.targets {
                    XCTAssertEqual(target.catalogRows.count, 1)
                    XCTAssertEqual(target.sideReferenceCount, 0)
                    if category == .ordinary {
                        XCTAssertTrue(target.automationRows.isEmpty)
                        XCTAssertTrue(target.definitionRows.isEmpty)
                    } else {
                        XCTAssertEqual(target.automationRows.count, 1)
                        XCTAssertEqual(target.definitionRows.count, 1)
                    }
                }
                XCTAssertEqual(try fingerprint(fixture.bundle), before)
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: fixture.bundle.rootURL
                            .appendingPathComponent("e24-execution", isDirectory: true).path
                    )
                )
            }
        }
    }

    func testSideReferencesAreCountedAcrossAllThreeSnapshotsWithoutMutation() throws {
        let fixture = try makeFixture(
            label: #function,
            category: .ordinary,
            count: 1
        )
        let threadID = fixture.targetIDs[0]
        try executeSQL(
            "INSERT INTO inbox_items(thread_id) VALUES ('\(threadID)')",
            at: fixture.bundle.desktopDatabaseURL
        )
        try executeSQL(
            "INSERT INTO thread_timeline_ledger(thread_id) VALUES ('\(threadID)')",
            at: fixture.bundle.desktopDatabaseURL
        )
        try executeSQL(
            "INSERT INTO thread_turn_summaries(thread_id) VALUES ('\(threadID)')",
            at: fixture.bundle.summariesDatabaseURL
        )
        try executeSQL(
            "INSERT INTO app_server_history_snapshots(thread_id) VALUES ('\(threadID)')",
            at: fixture.bundle.historyDatabaseURL
        )
        let before = try fingerprint(fixture.bundle)

        let evidence = try CodexGhostRepairDisposableSnapshotReader.read(
            bundle: fixture.bundle,
            targetIDs: fixture.targetIDs
        )

        XCTAssertEqual(evidence.targets[0].sideReferenceCount, 4)
        XCTAssertEqual(try fingerprint(fixture.bundle), before)
    }

    func testIncoherentSidecarsFailClosedAndRemainUnchanged() throws {
        let fixture = try makeFixture(
            label: #function,
            category: .ordinary,
            count: 1
        )
        try createSentinelSidecars(for: fixture.bundle)
        let before = try fingerprint(fixture.bundle)

        XCTAssertThrowsError(
            try CodexGhostRepairDisposableSnapshotReader.read(
                bundle: fixture.bundle,
                targetIDs: fixture.targetIDs
            )
        )

        XCTAssertEqual(try fingerprint(fixture.bundle), before)
    }

    func testSchemaDriftMalformedDatabaseAndInvalidSelectionFailClosed() throws {
        let schemaDrift = try makeFixture(
            label: "\(#function)-schema",
            category: .ordinary,
            count: 1
        )
        try executeSQL("PRAGMA user_version=4", at: schemaDrift.bundle.historyDatabaseURL)
        XCTAssertThrowsError(
            try CodexGhostRepairDisposableSnapshotReader.read(
                bundle: schemaDrift.bundle,
                targetIDs: schemaDrift.targetIDs
            )
        ) { error in
            guard case .invalidDatabaseContract = error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidDatabaseContract, found \(error)")
            }
        }

        let malformed = try makeFixture(
            label: "\(#function)-malformed",
            category: .ordinary,
            count: 1
        )
        try Data("not a sqlite database".utf8).write(
            to: malformed.bundle.summariesDatabaseURL,
            options: .atomic
        )
        XCTAssertThrowsError(
            try CodexGhostRepairDisposableSnapshotReader.read(
                bundle: malformed.bundle,
                targetIDs: malformed.targetIDs
            )
        )

        let valid = try makeFixture(
            label: "\(#function)-selection",
            category: .ordinary,
            count: 1
        )
        XCTAssertThrowsError(
            try CodexGhostRepairDisposableSnapshotReader.read(
                bundle: valid.bundle,
                targetIDs: []
            )
        )
        XCTAssertThrowsError(
            try CodexGhostRepairDisposableSnapshotReader.read(
                bundle: valid.bundle,
                targetIDs: [valid.targetIDs[0], valid.targetIDs[0]]
            )
        )
    }

    func testAuthorizerAllowsOnlyRequiredReadOperations() {
        XCTAssertEqual(decision(SQLITE_SELECT), SQLITE_OK)
        XCTAssertEqual(
            decision(SQLITE_READ, "local_thread_catalog"),
            SQLITE_OK
        )
        XCTAssertEqual(decision(SQLITE_FUNCTION, nil, "count"), SQLITE_OK)
        XCTAssertEqual(decision(SQLITE_PRAGMA, "user_version"), SQLITE_OK)
        XCTAssertEqual(decision(SQLITE_PRAGMA, "integrity_check"), SQLITE_OK)

        XCTAssertEqual(decision(SQLITE_INSERT, "local_thread_catalog"), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_UPDATE, "local_thread_catalog"), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_DELETE, "local_thread_catalog"), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_ATTACH), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_DETACH), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_READ, "sqlite_master"), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_FUNCTION, nil, "load_extension"), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_PRAGMA, "writable_schema"), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_PRAGMA, "query_only", "OFF"), SQLITE_DENY)
    }

    private func decision(
        _ actionCode: Int32,
        _ parameterOne: String? = nil,
        _ parameterTwo: String? = nil
    ) -> Int32 {
        CodexGhostRepairSnapshotAuthorizer.decision(
            actionCode: actionCode,
            parameterOne: parameterOne,
            parameterTwo: parameterTwo
        )
    }

    private struct Fixture {
        let bundle: CodexGhostRepairDisposableBundle
        let targetIDs: [String]
    }

    private struct FileFingerprint: Equatable {
        let exists: Bool
        let data: Data?
        let size: UInt64?
        let modificationDate: Date?
        let permissions: Int?
        let fileNumber: UInt64?
    }

    private func makeFixture(
        label: String,
        category: CodexGhostRepairCategory,
        count: Int
    ) throws -> Fixture {
        let parent = try makeDirectory(label: label)
        let root = parent.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data(CodexGhostRepairDisposableBundle.markerContents.utf8).write(
            to: root.appendingPathComponent(CodexGhostRepairDisposableBundle.markerFileName)
        )
        let desktop = root.appendingPathComponent("codex-dev.db")
        let summaries = root.appendingPathComponent("codex-thread-summaries-dev.db")
        let history = root.appendingPathComponent("codex-history-snapshots-dev.db")
        try createDesktopFixture(at: desktop)
        try createSideFixture(at: summaries, version: 2, table: "thread_turn_summaries")
        try createSideFixture(
            at: history,
            version: 3,
            table: "app_server_history_snapshots"
        )
        let targetIDs = (0..<count).map { "e25-\(category.rawValue.lowercased())-\($0)" }
        for (index, threadID) in targetIDs.enumerated() {
            try executeSQL(
                "INSERT INTO local_thread_catalog(host_id,thread_id,missing_candidate,private_title) VALUES ('local','\(threadID)',0,'private title \(index)')",
                at: desktop
            )
            if category == .automation {
                let automationID = "automation-\(index)"
                try executeSQL(
                    "INSERT INTO automation_runs(thread_id,automation_id,status,archived_reason,updated_at,archived_user_message,archived_assistant_message,private_payload) VALUES ('\(threadID)','\(automationID)','ACCEPTED',NULL,\(1_000 + index),NULL,NULL,'private payload \(index)')",
                    at: desktop
                )
                try executeSQL(
                    "INSERT INTO automations(id,status,updated_at,private_prompt) VALUES ('\(automationID)','ACTIVE',\(2_000 + index),'private prompt \(index)')",
                    at: desktop
                )
            }
        }
        return Fixture(
            bundle: try CodexGhostRepairDisposableBundle(
                rootURL: root,
                allowedParentURL: parent
            ),
            targetIDs: targetIDs
        )
    }

    private func makeDirectory(label: String) throws -> URL {
        let sanitized = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-manager-e25-\(sanitized)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func createDesktopFixture(at url: URL) throws {
        try createEmptySQLite(at: url, version: 32)
        try executeSQL(
            """
            CREATE TABLE local_thread_catalog(host_id TEXT NOT NULL, thread_id TEXT NOT NULL, missing_candidate INTEGER NOT NULL, private_title TEXT, PRIMARY KEY(host_id,thread_id));
            CREATE TABLE automation_runs(thread_id TEXT PRIMARY KEY, automation_id TEXT NOT NULL, status TEXT NOT NULL, archived_reason TEXT, updated_at INTEGER NOT NULL, archived_user_message TEXT, archived_assistant_message TEXT, private_payload TEXT);
            CREATE TABLE automations(id TEXT PRIMARY KEY, status TEXT NOT NULL, updated_at INTEGER NOT NULL, private_prompt TEXT);
            CREATE TABLE inbox_items(thread_id TEXT);
            CREATE TABLE thread_timeline_ledger(thread_id TEXT);
            CREATE TABLE local_thread_catalog_metadata(id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL, private_value TEXT);
            CREATE TABLE local_thread_catalog_sync_state(host_id TEXT PRIMARY KEY, observation_sequence INTEGER NOT NULL, watermark_updated_at INTEGER NOT NULL, private_value TEXT);
            INSERT INTO local_thread_catalog_metadata(id,catalog_revision,private_value) VALUES (1,100,'private metadata');
            INSERT INTO local_thread_catalog_sync_state(host_id,observation_sequence,watermark_updated_at,private_value) VALUES ('local',200,300,'private sync');
            """,
            at: url
        )
    }

    private func createSideFixture(at url: URL, version: Int, table: String) throws {
        try createEmptySQLite(at: url, version: version)
        try executeSQL("CREATE TABLE \(table)(thread_id TEXT)", at: url)
    }

    private func createEmptySQLite(at url: URL, version: Int) throws {
        var database: OpaquePointer?
        try check(sqlite3_open(url.path, &database), database: database)
        guard let database else { throw TestSQLiteError.open }
        defer { sqlite3_close_v2(database) }
        try check(
            sqlite3_exec(database, "PRAGMA journal_mode=DELETE", nil, nil, nil),
            database: database
        )
        try check(
            sqlite3_exec(database, "PRAGMA user_version=\(version)", nil, nil, nil),
            database: database
        )
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        try check(sqlite3_open(url.path, &database), database: database)
        guard let database else { throw TestSQLiteError.open }
        defer { sqlite3_close_v2(database) }
        try check(sqlite3_exec(database, sql, nil, nil, nil), database: database)
    }

    private func createSentinelSidecars(for bundle: CodexGhostRepairDisposableBundle) throws {
        for database in databaseURLs(bundle) {
            for suffix in ["-wal", "-shm", "-journal"] {
                try Data("E25 sentinel \(suffix)".utf8).write(
                    to: URL(fileURLWithPath: database.path + suffix)
                )
            }
        }
    }

    private func fingerprint(
        _ bundle: CodexGhostRepairDisposableBundle
    ) throws -> [String: FileFingerprint] {
        var result: [String: FileFingerprint] = [:]
        for database in databaseURLs(bundle) {
            for url in [
                database,
                URL(fileURLWithPath: database.path + "-wal"),
                URL(fileURLWithPath: database.path + "-shm"),
                URL(fileURLWithPath: database.path + "-journal"),
            ] {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    result[url.path] = FileFingerprint(
                        exists: false,
                        data: nil,
                        size: nil,
                        modificationDate: nil,
                        permissions: nil,
                        fileNumber: nil
                    )
                    continue
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                result[url.path] = FileFingerprint(
                    exists: true,
                    data: try Data(contentsOf: url),
                    size: (attributes[.size] as? NSNumber)?.uint64Value,
                    modificationDate: attributes[.modificationDate] as? Date,
                    permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
                    fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
                )
            }
        }
        return result
    }

    private func databaseURLs(_ bundle: CodexGhostRepairDisposableBundle) -> [URL] {
        [
            bundle.desktopDatabaseURL,
            bundle.summariesDatabaseURL,
            bundle.historyDatabaseURL,
        ]
    }

    private func check(_ code: Int32, database: OpaquePointer?) throws {
        guard code == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw TestSQLiteError.sqlite(code, message)
        }
    }

    private enum TestSQLiteError: Error {
        case open
        case sqlite(Int32, String)
    }
}
#endif
