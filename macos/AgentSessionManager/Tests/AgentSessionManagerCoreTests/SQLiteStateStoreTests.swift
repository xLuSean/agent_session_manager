@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteStateStoreTests: XCTestCase {
    func testNewStoreCreatesVersionEightSchemaWithPrivatePermissions() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), 8)
        XCTAssertTrue(try columnExists("manager_intent", table: "operation_previews", at: databaseURL))
        XCTAssertTrue(try columnExists("manager_intent", table: "operation_reports", at: databaseURL))
        XCTAssertTrue(try columnExists("trash_membership_mutation", table: "operation_previews", at: databaseURL))
        XCTAssertTrue(try columnExists("expected_working_directory", table: "operation_items", at: databaseURL))
        XCTAssertNil(store.migrationBackupURL)
        XCTAssertEqual(
            try store.tableNames(),
            [
                "archive_batch_items",
                "archive_batch_plans",
                "archive_batch_reports",
                "archive_batch_units",
                "deleted_sessions",
                "operation_items",
                "operation_previews",
                "operation_reports",
                "provider_checkpoints",
                "trash_memberships",
            ]
        )
        XCTAssertEqual(try rawInt("PRAGMA application_id", at: databaseURL), 1_095_978_289)
        XCTAssertEqual(try permissions(at: databaseURL), 0o600)
    }

    func testMigrationBacksUpExistingVersionZeroDatabase() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createLegacyVersionZeroDatabase(at: databaseURL)

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try permissions(at: backupURL), 0o600)

        XCTAssertEqual(try store.schemaVersion(), 8)
        XCTAssertTrue(try tableExists("provider_checkpoints", at: databaseURL))
        XCTAssertTrue(try tableExists("legacy_marker", at: databaseURL))
        XCTAssertEqual(try rawText("SELECT value FROM legacy_marker", at: databaseURL), "before-migration")

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 0)
        XCTAssertFalse(try tableExists("provider_checkpoints", at: backupURL))
        XCTAssertEqual(try rawText("SELECT value FROM legacy_marker", at: backupURL), "before-migration")
    }

    func testMigrationFromVersionOneBacksUpAndPreservesExistingPreview() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionOneDatabaseWithPreview(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 150)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), 8)
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 1)
        XCTAssertFalse(try columnExists("affected_set_hash", table: "operation_previews", at: backupURL))
        XCTAssertTrue(try columnExists("affected_set_hash", table: "operation_previews", at: databaseURL))
        XCTAssertTrue(try columnExists("archive_affected_role", table: "operation_items", at: databaseURL))

        let previewID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let preview = try XCTUnwrap(store.operationPreview(id: previewID))
        XCTAssertNil(preview.affectedSetHash)
        XCTAssertNil(preview.items[0].archiveAffectedRole)
        XCTAssertEqual(preview.items[0].nativeSessionID, "legacy-session")
    }

    func testMigrationFromVersionTwoBacksUpAndPreservesAffectedPreview() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionTwoDatabaseWithAffectedPreview(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 160)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), 8)
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 2)
        XCTAssertFalse(try tableExists("archive_batch_plans", at: backupURL))
        XCTAssertTrue(try tableExists("archive_batch_plans", at: databaseURL))
        XCTAssertTrue(try tableExists("archive_batch_reports", at: databaseURL))

        let previewID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let preview = try XCTUnwrap(store.operationPreview(id: previewID))
        XCTAssertEqual(preview.affectedSetHash, "legacy-affected-hash")
        XCTAssertEqual(preview.items[0].archiveAffectedRole, .selectedRoot)
    }

    func testFailedVersionTwoMigrationRollsBackAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionTwoDatabaseWithAffectedPreview(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 2,
            toVersion: 3,
            statements: [
                "CREATE TABLE partial_v3 (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 180)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 2)
        XCTAssertFalse(try tableExists("partial_v3", at: databaseURL))
        XCTAssertEqual(
            try rawText("SELECT affected_set_hash FROM operation_previews", at: databaseURL),
            "legacy-affected-hash"
        )
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v2-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)), 2)
    }

    func testMigrationFromVersionThreeBacksUpAndPreservesLegacyIntent() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionThreeDatabaseWithPreview(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 170)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), 8)
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 3)
        XCTAssertFalse(try columnExists("manager_intent", table: "operation_previews", at: backupURL))
        XCTAssertEqual(
            try rawText("SELECT manager_intent FROM operation_previews", at: databaseURL),
            "move_to_trash"
        )
    }

    func testMigrationFromVersionFourBacksUpAndAddsDurableMembershipIntent() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionFourDatabase(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 175)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), 8)
        XCTAssertTrue(try columnExists(
            "trash_membership_mutation",
            table: "operation_previews",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 4)
        XCTAssertFalse(try columnExists(
            "trash_membership_mutation",
            table: "operation_previews",
            at: backupURL
        ))
    }

    func testFailedVersionFourMigrationRollsBackMembershipIntentAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionFourDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 4,
            toVersion: 5,
            statements: [
                "ALTER TABLE operation_previews ADD COLUMN trash_membership_mutation TEXT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 180)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 4)
        XCTAssertFalse(try columnExists(
            "trash_membership_mutation",
            table: "operation_previews",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v4-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)), 4)
    }

    func testMigrationFromVersionFiveBacksUpAndAddsWorkingDirectoryEvidence() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionFiveDatabase(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 176)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), 8)
        XCTAssertTrue(try columnExists(
            "expected_working_directory",
            table: "operation_items",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 5)
        XCTAssertFalse(try columnExists(
            "expected_working_directory",
            table: "operation_items",
            at: backupURL
        ))
    }

    func testFailedVersionFiveMigrationRollsBackWorkingDirectoryAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionFiveDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 5,
            toVersion: 6,
            statements: [
                "ALTER TABLE operation_items ADD COLUMN expected_working_directory TEXT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 181)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 5)
        XCTAssertFalse(try columnExists(
            "expected_working_directory",
            table: "operation_items",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v5-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)), 5)
    }

    func testMigrationFromVersionSixBacksUpAndAddsDeletedTombstones() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionSixDatabase(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 182)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), 8)
        XCTAssertTrue(try tableExists("deleted_sessions", at: databaseURL))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 6)
        XCTAssertFalse(try tableExists("deleted_sessions", at: backupURL))
    }

    func testFailedVersionSixMigrationRollsBackDeletedTombstoneAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionSixDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 6,
            toVersion: 7,
            statements: [
                "CREATE TABLE partial_deleted_sessions (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 183)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 6)
        XCTAssertFalse(try tableExists("partial_deleted_sessions", at: databaseURL))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v6-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)), 6)
    }

    func testMigrationFromVersionSevenAllowsBatchDeleteReportTombstones() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionSevenDatabase(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 184)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), 8)
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 7)
        XCTAssertTrue(try tableExists("deleted_sessions", at: databaseURL))
        XCTAssertFalse(try tableExists("deleted_sessions_v7", at: databaseURL))
    }

    func testFailedVersionSevenMigrationRollsBackAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionSevenDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 7,
            toVersion: 8,
            statements: [
                "ALTER TABLE deleted_sessions RENAME TO deleted_sessions_v7",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 185)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 7)
        XCTAssertTrue(try tableExists("deleted_sessions", at: databaseURL))
        XCTAssertFalse(try tableExists("deleted_sessions_v7", at: databaseURL))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v7-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)), 7)
    }

    func testFailedVersionThreeMigrationRollsBackBothIntentColumnsAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionThreeDatabaseWithPreview(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 3,
            toVersion: 4,
            statements: [
                "ALTER TABLE operation_previews ADD COLUMN manager_intent TEXT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 180)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 3)
        XCTAssertFalse(try columnExists("manager_intent", table: "operation_previews", at: databaseURL))
        XCTAssertFalse(try columnExists("manager_intent", table: "operation_reports", at: databaseURL))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v3-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)), 3)
    }

    func testFailedVersionOneMigrationRollsBackAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionOneDatabaseWithPreview(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 1,
            toVersion: 2,
            statements: [
                "ALTER TABLE operation_previews ADD COLUMN partial_v2 TEXT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 175)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 1)
        XCTAssertFalse(try columnExists("partial_v2", table: "operation_previews", at: databaseURL))
        XCTAssertEqual(
            try rawText("SELECT native_session_id FROM operation_items", at: databaseURL),
            "legacy-session"
        )
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v1-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)), 1)
    }

    func testFailedMigrationRollsBackWholeTransactionAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createLegacyVersionZeroDatabase(at: databaseURL)

        let failingMigration = SQLiteMigration(
            fromVersion: 0,
            toVersion: 1,
            statements: [
                "CREATE TABLE partial_migration (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(
            try SQLiteStateStore(
                databaseURL: databaseURL,
                migrations: [failingMigration],
                now: Date(timeIntervalSince1970: 100)
            )
        )

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 0)
        XCTAssertFalse(try tableExists("partial_migration", at: databaseURL))
        XCTAssertEqual(try rawText("SELECT value FROM legacy_marker", at: databaseURL), "before-migration")

        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v0-") }
        XCTAssertEqual(backups.count, 1)
        let backupURL = try XCTUnwrap(backups.first)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 0)
        XCTAssertEqual(try rawText("SELECT value FROM legacy_marker", at: backupURL), "before-migration")
    }

    func testRestoreIsReversibleAndRestoresBackupExactly() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createLegacyVersionZeroDatabase(at: databaseURL)

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let migrationBackupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try store.schemaVersion(), 8)
        store.close()

        let result = try SQLiteStateStore.restoreBackup(
            from: migrationBackupURL,
            to: databaseURL,
            now: Date(timeIntervalSince1970: 200)
        )

        let preRestoreBackupURL = try XCTUnwrap(result.preRestoreBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: preRestoreBackupURL), 8)
        XCTAssertTrue(try tableExists("provider_checkpoints", at: preRestoreBackupURL))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 0)
        XCTAssertFalse(try tableExists("provider_checkpoints", at: databaseURL))
        XCTAssertEqual(try rawText("SELECT value FROM legacy_marker", at: databaseURL), "before-migration")
        XCTAssertEqual(try permissions(at: databaseURL), 0o600)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let safeName = name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-manager-\(safeName)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createLegacyVersionZeroDatabase(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            try execute("CREATE TABLE legacy_marker (value TEXT NOT NULL)", database: database)
            try execute("INSERT INTO legacy_marker(value) VALUES ('before-migration')", database: database)
            try execute("PRAGMA user_version = 0", database: database)
        }
    }

    private func createVersionFourDatabase(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements {
                try execute(statement, database: database)
            }
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
            try execute("PRAGMA user_version = 4", database: database)
        }
    }

    private func createVersionFiveDatabase(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements {
                try execute(statement, database: database)
            }
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
            try execute("PRAGMA user_version = 5", database: database)
        }
    }

    private func createVersionSixDatabase(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements {
                try execute(statement, database: database)
            }
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
            try execute("PRAGMA user_version = 6", database: database)
        }
    }

    private func createVersionSevenDatabase(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements {
                try execute(statement, database: database)
            }
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
            try execute("PRAGMA user_version = 7", database: database)
        }
    }

    private func createVersionOneDatabaseWithPreview(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            for statement in SQLiteStateStore.schemaV1Statements {
                try execute(statement, database: database)
            }
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
            try execute("PRAGMA user_version = 1", database: database)
            try execute(
                """
                INSERT INTO provider_checkpoints (
                    provider, runtime_version, inventory_hash, refreshed_at,
                    inventory_complete, protection_complete
                ) VALUES ('codex', '0.147.0', 'legacy-hash', '1970-01-01T00:00:20.000Z', 1, 1)
                """,
                database: database
            )
            try execute(
                """
                INSERT INTO operation_previews (
                    id, provider, operation, status, confirmation_token_hash,
                    manifest_hash, provider_inventory_hash, created_at, expires_at,
                    item_count, known_size_bytes, unknown_size_count
                ) VALUES (
                    '00000000-0000-0000-0000-000000000001', 'codex', 'archive',
                    'prepared', 'token-hash', 'manifest-hash', 'legacy-hash',
                    '1970-01-01T00:00:30.000Z', '1970-01-01T00:01:00.000Z', 1, 0, 1
                )
                """,
                database: database
            )
            try execute(
                """
                INSERT INTO operation_items (
                    preview_id, manager_key, native_session_id,
                    expected_native_state, expected_protection_hash, expected_title
                ) VALUES (
                    '00000000-0000-0000-0000-000000000001', 'codex:legacy-session',
                    'legacy-session', 'active', 'protection-hash', 'Legacy session'
                )
                """,
                database: database
            )
        }
    }

    private func createVersionTwoDatabaseWithAffectedPreview(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements {
                try execute(statement, database: database)
            }
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
            try execute("PRAGMA user_version = 2", database: database)
            try execute(
                """
                INSERT INTO provider_checkpoints (
                    provider, runtime_version, inventory_hash, refreshed_at,
                    inventory_complete, protection_complete
                ) VALUES ('codex', '0.147.0', 'legacy-hash', '1970-01-01T00:00:20.000Z', 1, 1)
                """,
                database: database
            )
            try execute(
                """
                INSERT INTO operation_previews (
                    id, provider, operation, status, confirmation_token_hash,
                    manifest_hash, provider_inventory_hash, created_at, expires_at,
                    item_count, known_size_bytes, unknown_size_count, affected_set_hash
                ) VALUES (
                    '00000000-0000-0000-0000-000000000001', 'codex', 'archive',
                    'prepared', 'token-hash', 'manifest-hash', 'legacy-hash',
                    '1970-01-01T00:00:30.000Z', '1970-01-01T00:01:00.000Z',
                    1, 0, 1, 'legacy-affected-hash'
                )
                """,
                database: database
            )
            try execute(
                """
                INSERT INTO operation_items (
                    preview_id, manager_key, native_session_id,
                    expected_native_state, expected_protection_hash, expected_title,
                    archive_affected_role, archive_affected_depth
                ) VALUES (
                    '00000000-0000-0000-0000-000000000001', 'codex:legacy-session',
                    'legacy-session', 'active', 'protection-hash', 'Legacy session',
                    'selectedRoot', 0
                )
                """,
                database: database
            )
        }
    }

    private func createVersionThreeDatabaseWithPreview(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements {
                try execute(statement, database: database)
            }
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
            try execute("PRAGMA user_version = 3", database: database)
            try execute(
                """
                INSERT INTO provider_checkpoints (
                    provider, runtime_version, inventory_hash, refreshed_at,
                    inventory_complete, protection_complete
                ) VALUES ('codex', '0.147.0', 'legacy-hash', '1970-01-01T00:00:20.000Z', 1, 1)
                """,
                database: database
            )
            try execute(
                """
                INSERT INTO operation_previews (
                    id, provider, operation, status, confirmation_token_hash,
                    manifest_hash, provider_inventory_hash, created_at, expires_at,
                    item_count, known_size_bytes, unknown_size_count, affected_set_hash
                ) VALUES (
                    '00000000-0000-0000-0000-000000000001', 'codex', 'move_to_trash',
                    'prepared', 'token-hash', 'manifest-hash', 'legacy-hash',
                    '1970-01-01T00:00:30.000Z', '1970-01-01T00:01:00.000Z',
                    0, 0, 0, NULL
                )
                """,
                database: database
            )
        }
    }

    private func tableExists(_ table: String, at url: URL) throws -> Bool {
        try withDatabase(at: url, flags: SQLITE_OPEN_READONLY) { database in
            var statement: OpaquePointer?
            let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
            try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil), database: database)
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_text(statement, 1, table, -1, sqliteTransient), database: database)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW || result == SQLITE_DONE else {
                throw rawError(result, database: database)
            }
            return result == SQLITE_ROW
        }
    }

    private func columnExists(_ column: String, table: String, at url: URL) throws -> Bool {
        try withDatabase(at: url, flags: SQLITE_OPEN_READONLY) { database in
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil), database: database)
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 1), String(cString: text) == column {
                    return true
                }
            }
            return false
        }
    }

    private func rawInt(_ sql: String, at url: URL) throws -> Int32 {
        try withDatabase(at: url, flags: SQLITE_OPEN_READONLY) { database in
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil), database: database)
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw rawError(result, database: database) }
            return sqlite3_column_int(statement, 0)
        }
    }

    private func rawText(_ sql: String, at url: URL) throws -> String {
        try withDatabase(at: url, flags: SQLITE_OPEN_READONLY) { database in
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil), database: database)
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                throw rawError(result, database: database)
            }
            return String(cString: text)
        }
    }

    private func withDatabase<T>(
        at url: URL,
        flags: Int32,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "SQLiteStateStoreTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_close_v2(database) }
        return try body(database)
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        try check(result, database: database)
    }

    private func check(_ result: Int32, database: OpaquePointer) throws {
        guard result == SQLITE_OK else { throw rawError(result, database: database) }
    }

    private func rawError(_ result: Int32, database: OpaquePointer) -> NSError {
        NSError(
            domain: "SQLiteStateStoreTests",
            code: Int(result),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }
}
