import CSQLite3
import Darwin
import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexCompatibilityDatabaseTests: XCTestCase {
    private func standaloneWALFixture() throws -> URL {
        let file = try fixture(.threadHistory)
        try execute(file, "PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE);")
        // Only artificial, checkpointed, closed fixtures are moved here.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.moveItem(at: sidecar, to: root.appendingPathComponent("parked" + suffix))
            }
        }
        return file
    }

    func testStandaloneWALMetadataWithoutCreatingSidecarsOrChangingBytes() throws {
        let file = try standaloneWALFixture()
        let before = try Data(contentsOf: file)
        XCTAssertEqual(chmod(file.path, 0o400), 0)
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { chmod(root.path, 0o700); chmod(file.path, 0o600) }
        for _ in 0..<3 {
            XCTAssertNil(try CodexCompatibilityDatabase.metadata(at: file).check?.issue)
            XCTAssertTrue(CodexCompatibilitySidecars.read(at: file).allMissing)
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    func testSingleFileLockBlocksSQLiteAndIsReleasedAfterFailure() throws {
        let file = try standaloneWALFixture()
        XCTAssertThrowsError(try CodexCompatibilitySingleFileRead.withLock(at: file) {
            // A separate process must not read past our exclusive lock.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [file.path, "PRAGMA user_version;"]
            process.standardOutput = Pipe(); process.standardError = Pipe()
            try process.run(); process.waitUntilExit()
            XCTAssertNotEqual(process.terminationStatus, 0)
            throw TestFailure.sqlite
        })
        XCTAssertNil(try CodexCompatibilityDatabase.metadata(at: file).check?.issue)
    }

    func testSingleFileLockCannotBypassOrReleaseExistingSQLiteLock() throws {
        let file = try fixture(.threadHistory)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try CodexCompatibilitySingleFileRead.withLock(at: file) { XCTFail("Must not read") })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [file.path, "PRAGMA user_version;"]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0, "A failed lock attempt must preserve the existing SQLite lock")
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
    }

    func testSingleFileReadRejectsSidecarAppearance() throws {
        let file = try standaloneWALFixture()
        XCTAssertThrowsError(try CodexCompatibilitySingleFileRead.withLock(at: file) {
            try Data().write(to: URL(fileURLWithPath: file.path + "-wal"))
        })
        XCTAssertThrowsError(try CodexCompatibilitySingleFileRead.withLock(at: file) { XCTFail("Must not ignore WAL") })
    }

    func testSingleFileReadRejectsSourceReplacementAndEscapesURI() throws {
        let file = try standaloneWALFixture()
        let renamed = root.appendingPathComponent("history ?#%.sqlite")
        try FileManager.default.moveItem(at: file, to: renamed)
        _ = try CodexCompatibilityDatabase.metadata(at: renamed)
        let bytes = try Data(contentsOf: renamed)
        XCTAssertThrowsError(try CodexCompatibilitySingleFileRead.withLock(at: renamed) {
            try bytes.write(to: renamed, options: .atomic)
        }) { error in
            XCTAssertEqual((error as? CodexCompatibilityReadFailure)?.stage, .sourceChanged)
        }
    }

    func testDiagnosticExtensionsArePrivateAndBackwardCompatible() throws {
        let old = Data(#"{"stage":"step","source":"sqlite","code":14}"#.utf8)
        let decoded = try JSONDecoder().decode(CodexCompatibilityReadFailure.self, from: old)
        XCTAssertNil(decoded.systemCode)
        XCTAssertNil(decoded.sidecars)
        let failure = CodexCompatibilityReadFailure(stage: .step, source: .sqlite, code: 14,
            systemCode: 2, sidecars: .init(wal: .missing, shm: .inaccessible, journal: .missing))
        XCTAssertEqual(try JSONDecoder().decode(CodexCompatibilityReadFailure.self, from: JSONEncoder().encode(failure)), failure)
        XCTAssertEqual(CodexCompatibilityDiagnosticError.metadata(CodexCompatibilityInspector.CheckError.metadataUnavailable)["reason"], "metadataUnavailable")
    }

    func testLiveWALSchemaIsNotIgnored() throws {
        let file = try fixture(.threadHistory)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; ALTER TABLE thread_items ADD COLUMN changed TEXT;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: file).check?.issue, .columns)
        XCTAssertThrowsError(try CodexCompatibilitySingleFileRead.withLock(at: file) { XCTFail("Must not bypass live WAL") })
    }

    func testMissingMetadataRetainsOnlySafeErrorCode() throws {
        let file = root.appendingPathComponent("private-personal-name.sqlite")
        XCTAssertThrowsError(try CodexCompatibilityDatabase.metadata(at: file)) { error in
            guard let failure = error as? CodexCompatibilityReadFailure else { return XCTFail("Missing typed diagnostic") }
            XCTAssertEqual(failure.stage, .fileMetadata)
            XCTAssertNotEqual(failure.code, 0)
            let encoded = String(decoding: try! JSONEncoder().encode(failure), as: UTF8.self)
            XCTAssertFalse(encoded.contains("private-personal"))
            XCTAssertFalse(encoded.contains(self.root.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testBusyDatabaseIsReportedAndLaterRecoversWithoutRetryingMutation() throws {
        let file = try fixture(.threadHistory)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try CodexCompatibilityDatabase.metadata(at: file)) { error in
            guard let failure = error as? CodexCompatibilityReadFailure else { return XCTFail("Missing SQLite diagnostic") }
            XCTAssertEqual(failure.source, .sqlite)
            XCTAssertEqual(failure.code & 255, Int(SQLITE_BUSY))
            XCTAssertTrue(failure.detail.contains("busy or locked"))
        }
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertNil(try CodexCompatibilityDatabase.metadata(at: file).check?.issue)
    }

    func testOlderDatabaseCheckDecodesWithoutDiagnostic() throws {
        let data = Data(#"{"database":"threadHistory","issue":"unavailable"}"#.utf8)
        let check = try JSONDecoder().decode(CodexCompatibilityDatabaseCheck.self, from: data)
        XCTAssertNil(check.readFailure)
        XCTAssertEqual(check.issue, .unavailable)
    }

    func testMalformedDatabaseAndGenericErrorsDoNotLeakContent() throws {
        let file = root.appendingPathComponent("corrupt.sqlite")
        try Data("private-conversation-content".utf8).write(to: file)
        XCTAssertThrowsError(try CodexCompatibilityDatabase.metadata(at: file)) { error in
            guard let failure = error as? CodexCompatibilityReadFailure else { return XCTFail("Expected typed failure") }
            XCTAssertEqual(failure.source, .sqlite)
            XCTAssertEqual(failure.code & 255, Int(SQLITE_NOTADB))
            XCTAssertFalse(failure.detail.contains("private-conversation"))
        }
        let error = NSError(domain: "private-title", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "secret at /private/user/path"])
        let metadata = CodexCompatibilityDiagnosticError.metadata(error)
        XCTAssertEqual(metadata, ["error_source": "other", "error_code": "7"])
        XCTAssertEqual(CodexCompatibilityDiagnosticError.metadata(CodexCompatibilityInspector.CheckError.changed)["reason"], "environmentChanged")
    }

    func testRunningPresentationDoesNotAskUserToRecheck() {
        XCTAssertEqual(CodexCompatibilityBehaviorStatus.notTested.label, "Skipped")
        for current in [true, false] {
            XCTAssertEqual(CodexCompatibilityPresentation.label(saved: "Passed", isCurrent: current, isChecking: true, isComparing: false), "Verifying… · Previous: Passed")
        }
        XCTAssertEqual(CodexCompatibilityPresentation.label(saved: "Passed", isCurrent: false, isChecking: false, isComparing: true), "Comparing… · Previous: Passed")
        XCTAssertEqual(CodexCompatibilityPresentation.label(saved: "Passed", isCurrent: false, isChecking: false, isComparing: false), "Recheck required")
        XCTAssertEqual(CodexCompatibilityPresentation.label(saved: "Passed", isCurrent: true, isChecking: false, isComparing: false), "Passed")
    }

    func testCompatibilityExportIncludesOnlyOneRunAndSurvivesRetention() async throws {
        let store = try DiagnosticLogStore(retentionPolicy: .init(maximumEvents: 2, maximumAge: 3600, maximumBytes: 100_000))
        let runID = UUID()
        for (category, id) in [(DiagnosticLogCategory.app, runID), (.compatibility, UUID()), (.compatibility, runID)] {
            _ = try await store.record(level: .info, category: category, message: "fixture", metadata: ["check_id": id.uuidString])
        }
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.events.count, 2)
        let data = try await store.exportJSONL(compatibilityRunID: runID)
        let lines = data.split(separator: 10)
        XCTAssertEqual(lines.count, 1)
        let event = try JSONDecoder().decode(DiagnosticEvent.self, from: Data(lines[0]))
        XCTAssertEqual(event.category, .compatibility)
        XCTAssertEqual(event.metadata["check_id"], runID.uuidString)
    }
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("asm-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["trash", root.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAllFourRequiredSchemasMatchWithoutChangingFiles() throws {
        for kind in CodexGhostRepairSnapshotAnalysisDatabase.allCases {
            let file = try fixture(kind)
            let before = try Data(contentsOf: file)
            let metadata = try CodexCompatibilityDatabase.metadata(at: file)
            XCTAssertEqual(metadata.check?.database, kind)
            XCTAssertNil(metadata.check?.issue)
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    func testMatchingVersionWithMissingTablesDoesNotPass() throws {
        for kind in CodexGhostRepairSnapshotAnalysisDatabase.allCases {
            let file = root.appendingPathComponent(kind.canonicalFile.rawValue)
            let version = CodexGhostRepairDatabaseSchemaProfile.desktopV34.databaseVersions[kind]!
            try execute(file, "PRAGMA user_version=\(version); CREATE TABLE unrelated(id TEXT);")
            XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: file).check?.issue, .table)
        }
    }

    func testUnknownVersionIsDifferentFromUnreadableMetadata() throws {
        for kind in CodexGhostRepairSnapshotAnalysisDatabase.allCases {
            let file = try fixture(kind)
            try execute(file, "PRAGMA user_version=999;")
            XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: file).check?.issue, .version)
        }
        XCTAssertThrowsError(try CodexCompatibilityDatabase.metadata(at: root.appendingPathComponent("missing.db")))
    }

    func testAuxiliaryColumnsAndEveryHistoryTableAreChecked() throws {
        let summaries = try fixture(.summaries)
        try execute(summaries, "ALTER TABLE thread_turn_summaries RENAME COLUMN compact_summary TO changed;")
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: summaries).check?.issue, .columns)
        let history = try fixture(.threadHistory)
        try execute(history, "ALTER TABLE thread_items ADD COLUMN changed TEXT;")
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: history).check?.issue, .columns)
        try execute(history, "ALTER TABLE thread_items DROP COLUMN changed; DROP TABLE thread_history_projection_state;")
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: history).check?.issue, .table)
        let state = try fixture(.state)
        try execute(state, "ALTER TABLE threads ADD COLUMN private_body TEXT; INSERT INTO threads VALUES ('fake', 'private fixture');")
        XCTAssertNil(try CodexCompatibilityDatabase.metadata(at: state).check?.issue, "State permits unreferenced ordinary columns")
        try execute(state, "ALTER TABLE threads RENAME COLUMN id TO changed;")
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: state).check?.issue, .columns)
    }

    func testViewsVirtualTablesAndGeneratedColumnsCannotImpersonateRequiredTables() throws {
        let state = try fixture(.state)
        try execute(state, "DROP TABLE threads; CREATE VIEW threads AS SELECT 'fake' AS id;")
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: state).check?.issue, .table)
        try execute(state, "DROP VIEW threads; CREATE VIRTUAL TABLE threads USING fts5(id);")
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: state).check?.issue, .table)
        try execute(state, "DROP TABLE threads; CREATE TABLE threads(source TEXT, id TEXT GENERATED ALWAYS AS (source) VIRTUAL);")
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: state).check?.issue, .columns)
    }

    func testAdditionalDesktopIndexesAreRejectedNotIgnored() throws {
        let desktop = try fixture(.desktop)
        try execute(desktop, "CREATE INDEX unreviewed ON automation_runs(status);")
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: desktop).check?.issue, .indexes)
        try execute(desktop, "DROP INDEX unreviewed; DROP INDEX automations_owner_idx;")
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: desktop).check?.issue, .indexes)
        XCTAssertNil(try CodexCompatibilityDatabase.metadata(at: desktop).desktopProfile)
    }

    func testWriteDatabaseTriggersAndExternalReferencesAreRejectedWithoutLeakingNames() throws {
        for kind in [CodexGhostRepairSnapshotAnalysisDatabase.desktop, .summaries] {
            let file = try fixture(kind)
            let table = kind == .desktop ? "local_thread_catalog" : "thread_turn_summaries"
            try execute(file, "CREATE TRIGGER private_trigger BEFORE DELETE ON \(table) BEGIN SELECT 1; END;")
            XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: file).check?.issue, .triggers)
            try execute(file, "DROP TRIGGER private_trigger; CREATE TABLE \"private'quoted\"(id TEXT REFERENCES \(table)(thread_id));")
            let check = try XCTUnwrap(CodexCompatibilityDatabase.metadata(at: file).check)
            XCTAssertEqual(check.issue, .foreignKeys)
            let persisted = String(decoding: try JSONEncoder().encode(check), as: UTF8.self)
            XCTAssertFalse(persisted.contains("private"))
            XCTAssertFalse(persisted.contains(root.path))
        }
    }

    func testSchemaMismatchBlocksOnlyDesktopAndReportsAllFourChecks() throws {
        let checks = try CodexGhostRepairSnapshotAnalysisDatabase.allCases.map { kind in
            try XCTUnwrap(CodexCompatibilityDatabase.metadata(at: fixture(kind)).check)
        }
        for kind in CodexGhostRepairSnapshotAnalysisDatabase.allCases {
            let changed = checks.map { $0.database == kind ? .init(database: kind, issue: .columns) : $0 }
            let result = CodexCompatibilityEvaluator.results(version: "0.153.4", browsing: true, archive: true, restore: true,
                delete: true, desktopVersion: "0.153.4", desktopSchemaProfile: "desktop-v34", desktopMetadataAvailable: true,
                desktopDatabaseChecks: changed)
            XCTAssertEqual(result.map(\.status), [.supportedByBuild, .supportedByBuild, .supportedByBuild, .incompatible])
        }
        let matched = CodexCompatibilityEvaluator.results(version: "0.153.4", browsing: true, archive: true, restore: true,
            delete: true, desktopVersion: "0.153.4", desktopSchemaProfile: "desktop-v34", desktopMetadataAvailable: true,
            desktopDatabaseChecks: checks)
        XCTAssertEqual(matched.last?.status, .supportedByBuild)
    }

    func testKnownTimelineUniqueIndexIsAcceptedButDifferentUniqueIndexIsRejected() throws {
        let file = try fixture(.desktop, timelineUnique: "host_id, thread_id, record_id")
        XCTAssertNil(try CodexCompatibilityDatabase.metadata(at: file).check?.issue)
        try execute(file, "DROP TABLE thread_timeline_ledger; CREATE TABLE thread_timeline_ledger (host_id TEXT NOT NULL, thread_id TEXT NOT NULL, sequence INTEGER NOT NULL, record_id TEXT NOT NULL, payload_json TEXT NOT NULL, PRIMARY KEY(host_id,thread_id,sequence), UNIQUE(record_id)) WITHOUT ROWID;")
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: file).check?.issue, .indexes)
    }

    private func fixture(_ kind: CodexGhostRepairSnapshotAnalysisDatabase, timelineUnique: String? = nil) throws -> URL {
        let file = root.appendingPathComponent(kind.canonicalFile.rawValue)
        let profile = CodexGhostRepairDatabaseSchemaProfile.desktopV34
        var sql = "PRAGMA user_version=\(profile.databaseVersions[kind]!);"
        if kind == .desktop {
            for table in profile.desktopTables {
                var parts = table.columns.map { column in
                    "\(column.name) \(column.declaredType)" + (column.notNull ? " NOT NULL" : "")
                        + (column.defaultValue.map { " DEFAULT \($0)" } ?? "")
                }
                let primary = table.columns.filter { $0.primaryKeyPosition > 0 }.sorted { $0.primaryKeyPosition < $1.primaryKeyPosition }
                if !primary.isEmpty { parts.append("PRIMARY KEY (\(primary.map(\.name).joined(separator: ",")))") }
                if table.table == "thread_timeline_ledger", let timelineUnique { parts.append("UNIQUE(\(timelineUnique))") }
                sql += "CREATE TABLE \(table.table) (\(parts.joined(separator: ",")));"
                for index in table.customIndexes {
                    sql += "CREATE \(index.unique ? "UNIQUE " : "")INDEX \(index.name) ON \(table.table) (\(index.columns.joined(separator: ",")))\(index.partial ? " WHERE 1" : "");"
                }
            }
        } else {
            for table in CodexGhostRepairReferencedTables.byDatabase[kind]! {
                sql += "CREATE TABLE \(table.table) (\(table.columns.map { "\($0) TEXT" }.joined(separator: ",")));"
            }
        }
        try execute(file, sql)
        return file
    }

    private func execute(_ file: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else { throw TestFailure.sqlite }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw TestFailure.sqlite }
    }
    private enum TestFailure: Error { case sqlite }
}
