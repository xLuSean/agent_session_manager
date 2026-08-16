@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class SQLiteMaintenanceTests: XCTestCase {
    func testBackupRetentionAssessmentIsReadOnlyAndProtectsUnverifiedBackups() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        store.close()

        let now = Date(timeIntervalSince1970: 200_000_000)
        let migrationDates = [1, 2, 10, 20].map {
            now.addingTimeInterval(-Double($0) * 24 * 60 * 60)
        }
        let migrationURLs = try migrationDates.map {
            try createBackup(
                for: databaseURL,
                kind: .migration,
                sourceVersion: 0,
                createdAt: $0
            )
        }
        _ = try createBackup(
            for: databaseURL,
            kind: .preRestore,
            sourceVersion: 1,
            createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60)
        )
        _ = try createBackup(
            for: databaseURL,
            kind: .preRestore,
            sourceVersion: 1,
            createdAt: now.addingTimeInterval(-50 * 24 * 60 * 60)
        )
        let mislabeledURL = try createBackup(
            for: databaseURL,
            kind: .migration,
            sourceVersion: 1,
            fileNameVersion: 0,
            createdAt: now.addingTimeInterval(-60 * 24 * 60 * 60)
        )
        let nonPrivateURL = try createBackup(
            for: databaseURL,
            kind: .migration,
            sourceVersion: 0,
            createdAt: now.addingTimeInterval(-70 * 24 * 60 * 60),
            usesPrivatePermissions: false
        )

        let corruptURL = backupURL(
            for: databaseURL,
            kind: .migration,
            sourceVersion: 0,
            createdAt: now.addingTimeInterval(-100 * 24 * 60 * 60)
        )
        try Data("not sqlite".utf8).write(to: corruptURL)
        try setPrivatePermissions(at: corruptURL)

        let symlinkURL = backupURL(
            for: databaseURL,
            kind: .migration,
            sourceVersion: 0,
            createdAt: now.addingTimeInterval(-200 * 24 * 60 * 60)
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: migrationURLs[0]
        )
        try Data("unrelated".utf8).write(to: directory.appendingPathComponent("state.sqlite.copy"))

        let before = try directoryContents(at: directory)
        let policy = SQLiteBackupRetentionPolicy(
            minimumBackupsPerKind: 2,
            minimumAge: 7 * 24 * 60 * 60
        )
        let assessment = try SQLiteStateStore.backupRetentionAssessment(
            for: databaseURL,
            now: now,
            policy: policy
        )
        let after = try directoryContents(at: directory)

        XCTAssertEqual(before, after)
        XCTAssertEqual(assessment.recognizedBackups.count, 9)
        XCTAssertEqual(
            assessment.trashCandidates.map { $0.url.lastPathComponent },
            [migrationURLs[3], migrationURLs[2]].map(\.lastPathComponent)
        )
        XCTAssertEqual(assessment.protectedBackups.count, 7)
        XCTAssertFalse(
            assessment.recognizedBackups.contains {
                $0.url.lastPathComponent == symlinkURL.lastPathComponent
            }
        )

        let corrupt = try XCTUnwrap(
            assessment.recognizedBackups.first {
                $0.url.lastPathComponent == corruptURL.lastPathComponent
            }
        )
        XCTAssertNotEqual(corrupt.verification, .verified)
        XCTAssertTrue(assessment.protectedBackups.contains(corrupt))
        XCTAssertEqual(
            assessment.decisions.first {
                $0.backup.url.lastPathComponent == corruptURL.lastPathComponent
            }?.reason,
            .verificationFailed(corrupt.verification)
        )
        XCTAssertEqual(
            assessment.recognizedBackups.first {
                $0.url.lastPathComponent == mislabeledURL.lastPathComponent
            }?.verification,
            .schemaVersionMismatch
        )
        XCTAssertEqual(
            assessment.decisions.first {
                $0.backup.url.lastPathComponent == migrationURLs[3].lastPathComponent
            }?.disposition,
            .trashCandidate
        )
        XCTAssertEqual(
            assessment.decisions.first {
                $0.backup.url.lastPathComponent == nonPrivateURL.lastPathComponent
            }?.reason,
            .permissionsNotPrivate
        )
        XCTAssertTrue(
            assessment.trashCandidates.allSatisfy {
                $0.verification == .verified && $0.hasPrivatePermissions
            }
        )
    }

    func testBackupRetentionPolicyAndCandidateLimitFailClosed() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let now = Date(timeIntervalSince1970: 3_000_000)

        XCTAssertThrowsError(
            try SQLiteStateStore.backupRetentionAssessment(
                for: databaseURL,
                now: now,
                policy: SQLiteBackupRetentionPolicy(
                    minimumBackupsPerKind: 0,
                    minimumAge: 0
                )
            )
        ) { error in
            XCTAssertEqual(error as? SQLiteStateStoreError, .invalidMaintenancePolicy)
        }

        for ageInDays in [10, 20, 30] {
            _ = try createBackup(
                for: databaseURL,
                kind: .migration,
                sourceVersion: 0,
                createdAt: now.addingTimeInterval(-Double(ageInDays) * 24 * 60 * 60)
            )
        }
        XCTAssertThrowsError(
            try SQLiteStateStore.backupRetentionAssessment(
                for: databaseURL,
                now: now,
                policy: SQLiteBackupRetentionPolicy(
                    minimumBackupsPerKind: 1,
                    minimumAge: 0,
                    maximumCandidatesPerAssessment: 1
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SQLiteStateStoreError,
                .maintenanceAssessmentLimitExceeded(found: 2, limit: 1)
            )
        }
    }

    func testCompactionAssessmentFindsFreePagesWithoutMutatingDatabase() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        try store.withLockedDatabase { database in
            try execute(
                "CREATE TABLE compaction_fixture (payload BLOB NOT NULL)",
                database: database
            )
            try execute(
                """
                WITH RECURSIVE counter(value) AS (
                    SELECT 1
                    UNION ALL
                    SELECT value + 1 FROM counter WHERE value < 1024
                )
                INSERT INTO compaction_fixture(payload)
                SELECT randomblob(4096) FROM counter
                """,
                database: database
            )
            try execute("DELETE FROM compaction_fixture", database: database)
        }

        let before = try physicalStatistics(in: store)
        let assessment = try store.physicalCompactionAssessment(
            policy: SQLiteCompactionPolicy(
                minimumReclaimableBytes: 1,
                minimumReclaimableRatio: 0.01
            )
        )
        let after = try physicalStatistics(in: store)

        XCTAssertEqual(before, after)
        XCTAssertEqual(assessment.pageSizeBytes, before.pageSize)
        XCTAssertEqual(assessment.pageCount, before.pageCount)
        XCTAssertEqual(assessment.freeListPageCount, before.freeListPageCount)
        XCTAssertGreaterThan(assessment.estimatedReclaimableBytes, 0)
        XCTAssertEqual(assessment.recommendation, .eligibleForExplicitPreview)
        XCTAssertEqual(assessment.strategy, .vacuumIntoVerifiedReplacement)
        XCTAssertTrue(assessment.requiresExplicitConfirmation)
        XCTAssertTrue(assessment.requiresClosedStoreForExecution)
        XCTAssertTrue(assessment.requiresPreCompactionBackup)
        XCTAssertTrue(assessment.requiresReplacementIntegrityCheck)
        XCTAssertFalse(assessment.executionAuthorized)
    }

    func testNewStoreDoesNotNeedProductionCompaction() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        let assessment = try store.maintenanceAssessment()

        XCTAssertTrue(assessment.backupRetention.recognizedBackups.isEmpty)
        XCTAssertEqual(assessment.physicalCompaction.recommendation, .notNeeded)
        XCTAssertFalse(assessment.physicalCompaction.executionAuthorized)
    }

    private struct PhysicalStatistics: Equatable {
        let pageSize: Int64
        let pageCount: Int64
        let freeListPageCount: Int64
    }

    private func physicalStatistics(in store: SQLiteStateStore) throws -> PhysicalStatistics {
        try store.withLockedDatabase { database in
            PhysicalStatistics(
                pageSize: try scalar("PRAGMA page_size", database: database),
                pageCount: try scalar("PRAGMA page_count", database: database),
                freeListPageCount: try scalar("PRAGMA freelist_count", database: database)
            )
        }
    }

    private func createBackup(
        for databaseURL: URL,
        kind: SQLiteBackupKind,
        sourceVersion: Int32,
        fileNameVersion: Int32? = nil,
        createdAt: Date,
        usesPrivatePermissions: Bool = true
    ) throws -> URL {
        let url = backupURL(
            for: databaseURL,
            kind: kind,
            sourceVersion: fileNameVersion ?? sourceVersion,
            createdAt: createdAt
        )
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "SQLiteMaintenanceTests", code: Int(result))
        }
        defer { sqlite3_close_v2(database) }
        try execute("CREATE TABLE marker (value TEXT NOT NULL)", database: database)
        try execute("INSERT INTO marker(value) VALUES ('backup')", database: database)
        if sourceVersion > 0 {
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
        }
        try execute("PRAGMA user_version = \(sourceVersion)", database: database)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(usesPrivatePermissions ? 0o600 : 0o644))],
            ofItemAtPath: url.path
        )
        return url
    }

    private func backupURL(
        for databaseURL: URL,
        kind: SQLiteBackupKind,
        sourceVersion: Int32,
        createdAt: Date
    ) -> URL {
        let milliseconds = Int64((createdAt.timeIntervalSince1970 * 1_000).rounded())
        let label = kind == .migration ? "backup-v\(sourceVersion)" : "pre-restore"
        return databaseURL.deletingLastPathComponent().appendingPathComponent(
            "\(databaseURL.lastPathComponent).\(label)-\(milliseconds)-\(UUID().uuidString.lowercased()).sqlite3"
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-maintenance-\(safeName)-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func directoryContents(at directory: URL) throws -> [String: Data] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return try Dictionary(uniqueKeysWithValues: entries.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }

    private func setPrivatePermissions(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw sqliteError(result, database: database) }
    }

    private func scalar(_ sql: String, database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            throw sqliteError(prepareResult, database: database)
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw sqliteError(stepResult, database: database)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func sqliteError(_ result: Int32, database: OpaquePointer) -> NSError {
        NSError(
            domain: "SQLiteMaintenanceTests",
            code: Int(result),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }
}
