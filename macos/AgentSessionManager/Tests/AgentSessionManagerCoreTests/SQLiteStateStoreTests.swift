@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteStateStoreTests: XCTestCase {
    func testVersionTwentyOneRetentionMigrationBacksUpWithoutClearingHistory() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let url = directory.appendingPathComponent("manager.sqlite3")
        let original = try SQLiteStateStore(databaseURL: url)
        original.close()
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { db in
            try execute("DROP TRIGGER reject_retired_bulk_preview", database: db)
            try execute("DROP TRIGGER reject_retired_operation_preview", database: db)
            try execute("DROP TRIGGER reject_retired_archive_batch", database: db)
            try execute("DROP TABLE retired_history_keys", database: db)
            try execute("CREATE TABLE test_retained_marker (value TEXT)", database: db)
            try execute("INSERT INTO test_retained_marker VALUES ('preserved')", database: db)
            try execute("ALTER TABLE provider_checkpoints DROP COLUMN compatibility_binding_json", database: db)
            try execute("PRAGMA user_version = 21", database: db)
        }
        let migrated = try SQLiteStateStore(databaseURL: url)
        defer { migrated.close() }
        XCTAssertEqual(try migrated.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        let backup = try XCTUnwrap(migrated.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backup), 21)
        XCTAssertEqual(try rawText("SELECT value FROM test_retained_marker", at: url), "preserved")
        XCTAssertEqual(try rawText("SELECT value FROM test_retained_marker", at: backup), "preserved")
        XCTAssertEqual(try rawInt("SELECT COUNT(*) FROM retired_history_keys", at: url), 0)
    }

    func testVersionTwentyTwoMigrationPreservesCheckpointAndBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let url = directory.appendingPathComponent("manager.sqlite3")
        let original = try SQLiteStateStore(databaseURL: url)
        let checkpoint = ProviderCheckpointRecord(provider: .codex, runtimeVersion: "0.147.0",
            inventoryHash: "old-checkpoint", refreshedAt: Date(timeIntervalSince1970: 100),
            inventoryComplete: true, protectionComplete: true)
        try original.upsertProviderCheckpoint(checkpoint)
        original.close()
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { db in
            try execute("ALTER TABLE provider_checkpoints DROP COLUMN compatibility_binding_json", database: db)
            try execute("PRAGMA user_version = 22", database: db)
        }
        let migrated = try SQLiteStateStore(databaseURL: url)
        defer { migrated.close() }
        XCTAssertEqual(try migrated.providerCheckpoint(for: .codex), checkpoint)
        XCTAssertEqual(try migrated.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        let backup = try XCTUnwrap(migrated.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backup), 22)
        XCTAssertFalse(try columnExists("compatibility_binding_json", table: "provider_checkpoints", at: backup))
    }

    func testNewStoreCreatesCurrentSchemaWithPrivatePermissions() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try columnExists("manager_intent", table: "operation_previews", at: databaseURL))
        XCTAssertTrue(try columnExists("manager_intent", table: "operation_reports", at: databaseURL))
        XCTAssertTrue(try columnExists("trash_membership_mutation", table: "operation_previews", at: databaseURL))
        XCTAssertTrue(try columnExists("expected_working_directory", table: "operation_items", at: databaseURL))
        XCTAssertTrue(try columnExists(
            "expected_trash_membership_set_hash",
            table: "operation_previews",
            at: databaseURL
        ))
        XCTAssertNil(store.migrationBackupURL)
        XCTAssertEqual(
            try store.tableNames(),
            [
                "archive_batch_items",
                "archive_batch_plans",
                "archive_batch_reports",
                "archive_batch_units",
                "codex_desktop_cleanup_bindings",
                "codex_ghost_repair_bulk_confirmation_challenges",
                "codex_ghost_repair_bulk_confirmation_receipts",
                "codex_ghost_repair_bulk_execution_journal",
                "codex_ghost_repair_bulk_frozen_plan_sources",
                "codex_ghost_repair_bulk_live_execution_journal",
                "codex_ghost_repair_bulk_previews",
                "codex_ghost_repair_category_a_authorizations",
                "codex_ghost_repair_category_a_execution_claims",
                "codex_ghost_repair_category_a_execution_reports",
                "codex_ghost_repair_category_a_operations",
                "codex_ghost_repair_category_a_prepared_bindings",
                "codex_ghost_repair_claims",
                "codex_ghost_repair_dry_run_previews",
                "codex_ghost_repair_previews",
                "codex_ghost_repair_reports",
                "deleted_sessions",
                "operation_items",
                "operation_previews",
                "operation_reports",
                "provider_checkpoints",
                "retired_history_keys",
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

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
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

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
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

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
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

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
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

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
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

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
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

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
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

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
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

    func testMigrationFromVersionEightAddsFrozenTrashPreservationEvidence() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionEightDatabase(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 186)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try columnExists(
            "expected_trash_membership_set_hash",
            table: "operation_previews",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 8)
        XCTAssertFalse(try columnExists(
            "expected_trash_membership_set_hash",
            table: "operation_previews",
            at: backupURL
        ))
    }

    func testFailedVersionEightMigrationRollsBackAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionEightDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 8,
            toVersion: 9,
            statements: [
                "ALTER TABLE operation_previews ADD COLUMN expected_trash_membership_set_hash TEXT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 187)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 8)
        XCTAssertFalse(try columnExists(
            "expected_trash_membership_set_hash",
            table: "operation_previews",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v8-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)), 8)
    }

    func testMigrationFromVersionNineAddsGhostRepairJournalAndBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionNineDatabase(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 188)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try tableExists("codex_ghost_repair_previews", at: databaseURL))
        XCTAssertTrue(try tableExists("codex_ghost_repair_claims", at: databaseURL))
        XCTAssertTrue(try tableExists("codex_ghost_repair_reports", at: databaseURL))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 9)
        XCTAssertFalse(try tableExists("codex_ghost_repair_previews", at: backupURL))
    }

    func testFailedVersionNineMigrationRollsBackAllGhostRepairTablesAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionNineDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 9,
            toVersion: 10,
            statements: [
                "CREATE TABLE codex_ghost_repair_previews (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 189)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 9)
        XCTAssertFalse(try tableExists("codex_ghost_repair_previews", at: databaseURL))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v9-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)), 9)
    }

    func testMigrationFromVersionTenAddsAuthorityFreeDryRunPreviewJournalAndBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionTenDatabase(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 190)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try tableExists(
            "codex_ghost_repair_dry_run_previews",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 10)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_dry_run_previews",
            at: backupURL
        ))
    }

    func testFailedVersionTenMigrationRollsBackDryRunPreviewJournalAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionTenDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 10,
            toVersion: 11,
            statements: [
                "CREATE TABLE codex_ghost_repair_dry_run_previews (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 191)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 10)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_dry_run_previews",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v10-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)),
            10
        )
    }

    func testMigrationFromVersionElevenAddsCategoryAExecutionJournalAndBackup()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionElevenDatabase(at: databaseURL)

        let store = try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 192)
        )
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        for table in [
            "codex_ghost_repair_category_a_operations",
            "codex_ghost_repair_category_a_authorizations",
            "codex_ghost_repair_category_a_execution_claims",
            "codex_ghost_repair_category_a_execution_reports",
            "codex_ghost_repair_category_a_prepared_bindings",
        ] {
            XCTAssertTrue(try tableExists(table, at: databaseURL))
        }
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 11)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_category_a_operations",
            at: backupURL
        ))
    }

    func testFailedVersionElevenMigrationRollsBackCategoryAExecutionJournal()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionElevenDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 11,
            toVersion: 12,
            statements: [
                "CREATE TABLE codex_ghost_repair_category_a_operations (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 193)
        ))

        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 11)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_category_a_operations",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v11-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)),
            11
        )
    }

    func testMigrationFromVersionTwelveAddsPreparedBindingAndBackup()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionTwelveDatabase(at: databaseURL)

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try tableExists(
            "codex_ghost_repair_category_a_prepared_bindings",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 12)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_category_a_prepared_bindings",
            at: backupURL
        ))
    }

    func testFailedVersionTwelveMigrationRollsBackPreparedBindingTable()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionTwelveDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 12,
            toVersion: 13,
            statements: [
                "CREATE TABLE codex_ghost_repair_category_a_prepared_bindings (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 194)
        ))
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 12)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_category_a_prepared_bindings",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v12-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)),
            12
        )
    }

    func testMigrationFromVersionThirteenAddsBulkPreviewJournalAndBackup()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionThirteenDatabase(at: databaseURL)

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try tableExists(
            "codex_ghost_repair_bulk_previews",
            at: databaseURL
        ))
        XCTAssertTrue(try tableExists(
            "codex_ghost_repair_bulk_confirmation_challenges",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 13)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_previews",
            at: backupURL
        ))
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_confirmation_challenges",
            at: backupURL
        ))
    }

    func testFailedVersionThirteenMigrationRollsBackBulkPreviewJournal()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionThirteenDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 13,
            toVersion: 14,
            statements: [
                "CREATE TABLE codex_ghost_repair_bulk_previews (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 195)
        ))
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 13)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_previews",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v13-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)),
            13
        )
    }

    func testMigrationFromVersionFourteenAddsBulkChallengeAndBackup()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionFourteenDatabase(at: databaseURL)

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try tableExists(
            "codex_ghost_repair_bulk_confirmation_challenges",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 14)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_confirmation_challenges",
            at: backupURL
        ))
    }

    func testFailedVersionFourteenMigrationRollsBackBulkChallenge()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionFourteenDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 14,
            toVersion: 15,
            statements: [
                "CREATE TABLE codex_ghost_repair_bulk_confirmation_challenges (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 196)
        ))
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 14)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_confirmation_challenges",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v14-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)),
            14
        )
    }

    func testMigrationFromVersionFifteenAddsBulkConfirmationReceiptAndBackup()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionFifteenDatabase(at: databaseURL)

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try tableExists(
            "codex_ghost_repair_bulk_confirmation_receipts",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 15)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_confirmation_receipts",
            at: backupURL
        ))
    }

    func testFailedVersionFifteenMigrationRollsBackBulkConfirmationReceipt()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionFifteenDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 15,
            toVersion: 16,
            statements: [
                "CREATE TABLE codex_ghost_repair_bulk_confirmation_receipts (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 197)
        ))
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 15)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_confirmation_receipts",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v15-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)),
            15
        )
    }

    func testMigrationFromVersionSixteenAddsBulkExecutionJournalAndBackup()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionSixteenDatabase(at: databaseURL)

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try tableExists(
            "codex_ghost_repair_bulk_execution_journal",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 16)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_execution_journal",
            at: backupURL
        ))
    }

    func testFailedVersionSixteenMigrationRollsBackBulkExecutionJournal()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionSixteenDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 16,
            toVersion: 17,
            statements: [
                "CREATE TABLE codex_ghost_repair_bulk_execution_journal (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 198)
        ))
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 16)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_execution_journal",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v16-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)),
            16
        )
    }

    func testMigrationFromVersionSeventeenAddsFrozenPlanSourceAndBackup()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionSeventeenDatabase(at: databaseURL)

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try tableExists(
            "codex_ghost_repair_bulk_frozen_plan_sources",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 17)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_frozen_plan_sources",
            at: backupURL
        ))
    }

    func testFailedVersionSeventeenMigrationRollsBackFrozenPlanSource()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionSeventeenDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 17,
            toVersion: 18,
            statements: [
                "CREATE TABLE codex_ghost_repair_bulk_frozen_plan_sources (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 199)
        ))
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 17)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_frozen_plan_sources",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v17-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)),
            17
        )
    }

    func testMigrationFromVersionEighteenAddsLiveExecutionJournalAndBackup()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionEighteenDatabase(at: databaseURL)

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        XCTAssertTrue(try tableExists(
            "codex_ghost_repair_bulk_live_execution_journal",
            at: databaseURL
        ))
        let backupURL = try XCTUnwrap(store.migrationBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backupURL), 18)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_live_execution_journal",
            at: backupURL
        ))
    }

    func testFailedVersionEighteenMigrationRollsBackLiveExecutionJournal()
        throws
    {
        let directory = try makeTemporaryDirectory(named: #function)
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        try createVersionEighteenDatabase(at: databaseURL)
        let failingMigration = SQLiteMigration(
            fromVersion: 18,
            toVersion: 19,
            statements: [
                "CREATE TABLE codex_ghost_repair_bulk_live_execution_journal (id TEXT PRIMARY KEY) STRICT",
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: databaseURL,
            migrations: [failingMigration],
            now: Date(timeIntervalSince1970: 200)
        ))
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: databaseURL), 18)
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_live_execution_journal",
            at: databaseURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v18-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)),
            18
        )
    }

    func testVersionNineteenToCurrentPreservesEveryExistingJournalPayload()
        async throws
    {
        for phase in [
            CodexGhostRepairBulkLiveJournalPhase.prepared,
            .claimed, .attempted, .terminal,
        ] {
            let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
            try makeJournal(phase: phase, fixture: fixture)
            try downgradeJournalToVersionNineteen(at: fixture.managerStateURL)
            let payloadBefore = try rawText(
                "SELECT payload_json FROM codex_ghost_repair_bulk_live_execution_journal",
                at: fixture.managerStateURL
            )
            let hashBefore = try rawText(
                "SELECT payload_hash FROM codex_ghost_repair_bulk_live_execution_journal",
                at: fixture.managerStateURL
            )

            let migrated = try SQLiteStateStore(
                databaseURL: fixture.managerStateURL
            )
            XCTAssertEqual(try migrated.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
            let backup = try XCTUnwrap(migrated.migrationBackupURL)
            migrated.close()

            XCTAssertEqual(
                try rawText(
                    "SELECT payload_json FROM codex_ghost_repair_bulk_live_execution_journal",
                    at: fixture.managerStateURL
                ),
                payloadBefore
            )
            XCTAssertEqual(
                try rawText(
                    "SELECT payload_hash FROM codex_ghost_repair_bulk_live_execution_journal",
                    at: fixture.managerStateURL
                ),
                hashBefore
            )
            XCTAssertEqual(
                try rawInt(
                    "SELECT closure_digest IS NULL FROM codex_ghost_repair_bulk_live_execution_journal",
                    at: fixture.managerStateURL
                ),
                1
            )
            XCTAssertEqual(try rawInt("PRAGMA user_version", at: backup), 19)
            XCTAssertEqual(
                try rawText(
                    "SELECT payload_json FROM codex_ghost_repair_bulk_live_execution_journal",
                    at: backup
                ),
                payloadBefore
            )
            XCTAssertEqual(
                try rawText(
                    "SELECT phase FROM codex_ghost_repair_bulk_live_execution_journal",
                    at: fixture.managerStateURL
                ),
                phase.rawValue
            )
        }
    }

    func testFailedVersionNineteenMigrationRollsBackAndKeepsBackup()
        throws
    {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        try makeJournal(phase: .prepared, fixture: fixture)
        try downgradeJournalToVersionNineteen(at: fixture.managerStateURL)
        let payloadBefore = try rawText(
            "SELECT payload_json FROM codex_ghost_repair_bulk_live_execution_journal",
            at: fixture.managerStateURL
        )
        let failing = SQLiteMigration(
            fromVersion: 19,
            toVersion: 20,
            statements: Array(SQLiteStateStore.schemaV20Statements.prefix(4))
                + ["THIS IS NOT VALID SQL"]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: fixture.managerStateURL,
            migrations: [failing],
            now: Date(timeIntervalSince1970: 201)
        ))
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: fixture.managerStateURL),
            19
        )
        XCTAssertTrue(try tableExists(
            "codex_ghost_repair_bulk_live_execution_journal",
            at: fixture.managerStateURL
        ))
        XCTAssertFalse(try tableExists(
            "codex_ghost_repair_bulk_live_execution_journal_v19",
            at: fixture.managerStateURL
        ))
        XCTAssertEqual(
            try rawText(
                "SELECT payload_json FROM codex_ghost_repair_bulk_live_execution_journal",
                at: fixture.managerStateURL
            ),
            payloadBefore
        )
        let backups = try FileManager.default.contentsOfDirectory(
            at: fixture.managerStateURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.contains(".backup-v19-")
                && !$0.lastPathComponent.hasSuffix("-wal")
                && !$0.lastPathComponent.hasSuffix("-shm")
        }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: XCTUnwrap(backups.first)),
            19
        )
    }

    func testVersionTwentyToTwentyOneBacksUpAndPreservesJournalBytes()
        throws
    {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try makeJournal(phase: .prepared, fixture: fixture)
        try downgradeToVersionTwenty(at: fixture.managerStateURL)
        let payload = try rawText(
            "SELECT payload_json FROM codex_ghost_repair_bulk_live_execution_journal",
            at: fixture.managerStateURL
        )
        let payloadHash = try rawText(
            "SELECT payload_hash FROM codex_ghost_repair_bulk_live_execution_journal",
            at: fixture.managerStateURL
        )

        let store = try SQLiteStateStore(
            databaseURL: fixture.managerStateURL,
            migrations: SQLiteStateStore.productionMigrations,
            now: Date(timeIntervalSince1970: 250)
        )
        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        let backup = try XCTUnwrap(store.migrationBackupURL)
        store.close()

        XCTAssertTrue(try tableExists(
            "codex_desktop_cleanup_bindings",
            at: fixture.managerStateURL
        ))
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: backup), 20)
        XCTAssertFalse(try tableExists(
            "codex_desktop_cleanup_bindings",
            at: backup
        ))
        XCTAssertEqual(
            try rawText(
                "SELECT payload_json FROM codex_ghost_repair_bulk_live_execution_journal",
                at: fixture.managerStateURL
            ),
            payload
        )
        XCTAssertEqual(
            try rawText(
                "SELECT payload_hash FROM codex_ghost_repair_bulk_live_execution_journal",
                at: fixture.managerStateURL
            ),
            payloadHash
        )
    }

    func testFailedVersionTwentyToTwentyOneRollsBackAndKeepsBackup()
        throws
    {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try downgradeToVersionTwenty(at: fixture.managerStateURL)
        let failing = SQLiteMigration(
            fromVersion: 20,
            toVersion: 21,
            statements: [
                SQLiteStateStore.schemaV21Statements[0],
                "THIS IS NOT VALID SQL",
            ]
        )

        XCTAssertThrowsError(try SQLiteStateStore(
            databaseURL: fixture.managerStateURL,
            migrations: [failing],
            now: Date(timeIntervalSince1970: 251)
        ))
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: fixture.managerStateURL),
            20
        )
        XCTAssertFalse(try tableExists(
            "codex_desktop_cleanup_bindings",
            at: fixture.managerStateURL
        ))
        let backups = try FileManager.default.contentsOfDirectory(
            at: fixture.managerStateURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".backup-v20-") }
        .filter {
            !$0.lastPathComponent.hasSuffix("-wal")
                && !$0.lastPathComponent.hasSuffix("-shm")
        }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: try XCTUnwrap(backups.first)),
            20
        )
    }

    func testNoncanonicalVersionNineteenPayloadKeepsExactHashAndCanClose()
        async throws
    {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        try makeJournal(phase: .prepared, fixture: fixture)
        try downgradeJournalToVersionNineteen(at: fixture.managerStateURL)
        let original = try rawText(
            "SELECT payload_json FROM codex_ghost_repair_bulk_live_execution_journal",
            at: fixture.managerStateURL
        )
        let noncanonical = " \n" + original
        let exactHash = SQLiteStateStore.hashBulkPreviewPayload(noncanonical)
        try withDatabase(
            at: fixture.managerStateURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        ) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(
                database,
                "UPDATE codex_ghost_repair_bulk_live_execution_journal SET payload_json = ?, payload_hash = ?",
                -1, &statement, nil
            ), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            for (index, value) in [noncanonical, exactHash].enumerated() {
                XCTAssertEqual(value.withCString { pointer in
                    sqlite3_bind_text(
                        statement, Int32(index + 1), pointer, -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }, SQLITE_OK)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        XCTAssertThrowsError(try CodexGhostRepairReadOnlyManagerStateStore(
            databaseURL: fixture.managerStateURL
        ))
        XCTAssertEqual(
            try rawInt("PRAGMA user_version", at: fixture.managerStateURL),
            19
        )
        let migrated = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        migrated.close()
        let coordinator = CodexGhostRepairBulkPreparedClosureLiveCoordinator(
            databaseURLProvider: { fixture.managerStateURL },
            operationExclusion: .init(databaseURL: fixture.managerStateURL),
            nowMilliseconds: { 1_800 },
            makeUUID: { UUID() }
        )
        let identity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: fixture.livePlan.requestID,
            operationID: fixture.confirmationReceipt.operationID
        )
        guard case let .ready(preview) = await coordinator.reviewClosure(
            identity: identity
        ) else { return XCTFail("Expected noncanonical v19 payload review.") }
        XCTAssertEqual(preview.expectedJournalPayloadHash, exactHash)
        guard case let .closed(summary, closure, _) =
            await coordinator.closePreparedOperation(preview) else {
            return XCTFail("Expected exact noncanonical v19 payload closure.")
        }
        XCTAssertEqual(summary.phase, .closedBeforeAttempt)
        XCTAssertEqual(
            closure.expectedPreparedJournalPayloadHash,
            exactHash
        )
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
        XCTAssertEqual(try store.schemaVersion(), SQLiteStateStore.currentSchemaVersion)
        store.close()

        let result = try SQLiteStateStore.restoreBackup(
            from: migrationBackupURL,
            to: databaseURL,
            now: Date(timeIntervalSince1970: 200)
        )

        let preRestoreBackupURL = try XCTUnwrap(result.preRestoreBackupURL)
        XCTAssertEqual(try rawInt("PRAGMA user_version", at: preRestoreBackupURL), SQLiteStateStore.currentSchemaVersion)
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

    private func createVersionEightDatabase(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements {
                try execute(statement, database: database)
            }
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
            try execute("PRAGMA user_version = 8", database: database)
        }
    }

    private func createVersionNineDatabase(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements
                + SQLiteStateStore.schemaV9Statements {
                try execute(statement, database: database)
            }
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
            try execute("PRAGMA user_version = 9", database: database)
        }
    }

    private func createVersionTenDatabase(at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements
                + SQLiteStateStore.schemaV9Statements
                + SQLiteStateStore.schemaV10Statements {
                try execute(statement, database: database)
            }
            try execute("PRAGMA application_id = \(SQLiteStateStore.applicationID)", database: database)
            try execute("PRAGMA user_version = 10", database: database)
        }
    }

    private func createVersionElevenDatabase(at url: URL) throws {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements
                + SQLiteStateStore.schemaV9Statements
                + SQLiteStateStore.schemaV10Statements
                + SQLiteStateStore.schemaV11Statements {
                try execute(statement, database: database)
            }
            try execute(
                "PRAGMA application_id = \(SQLiteStateStore.applicationID)",
                database: database
            )
            try execute("PRAGMA user_version = 11", database: database)
        }
    }

    private func createVersionTwelveDatabase(at url: URL) throws {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements
                + SQLiteStateStore.schemaV9Statements
                + SQLiteStateStore.schemaV10Statements
                + SQLiteStateStore.schemaV11Statements
                + SQLiteStateStore.schemaV12Statements {
                try execute(statement, database: database)
            }
            try execute(
                "PRAGMA application_id = \(SQLiteStateStore.applicationID)",
                database: database
            )
            try execute("PRAGMA user_version = 12", database: database)
        }
    }

    private func createVersionThirteenDatabase(at url: URL) throws {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements
                + SQLiteStateStore.schemaV9Statements
                + SQLiteStateStore.schemaV10Statements
                + SQLiteStateStore.schemaV11Statements
                + SQLiteStateStore.schemaV12Statements
                + SQLiteStateStore.schemaV13Statements {
                try execute(statement, database: database)
            }
            try execute(
                "PRAGMA application_id = \(SQLiteStateStore.applicationID)",
                database: database
            )
            try execute("PRAGMA user_version = 13", database: database)
        }
    }

    private func createVersionFourteenDatabase(at url: URL) throws {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements
                + SQLiteStateStore.schemaV9Statements
                + SQLiteStateStore.schemaV10Statements
                + SQLiteStateStore.schemaV11Statements
                + SQLiteStateStore.schemaV12Statements
                + SQLiteStateStore.schemaV13Statements
                + SQLiteStateStore.schemaV14Statements {
                try execute(statement, database: database)
            }
            try execute(
                "PRAGMA application_id = \(SQLiteStateStore.applicationID)",
                database: database
            )
            try execute("PRAGMA user_version = 14", database: database)
        }
    }

    private func createVersionFifteenDatabase(at url: URL) throws {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements
                + SQLiteStateStore.schemaV9Statements
                + SQLiteStateStore.schemaV10Statements
                + SQLiteStateStore.schemaV11Statements
                + SQLiteStateStore.schemaV12Statements
                + SQLiteStateStore.schemaV13Statements
                + SQLiteStateStore.schemaV14Statements
                + SQLiteStateStore.schemaV15Statements {
                try execute(statement, database: database)
            }
            try execute(
                "PRAGMA application_id = \(SQLiteStateStore.applicationID)",
                database: database
            )
            try execute("PRAGMA user_version = 15", database: database)
        }
    }

    private func createVersionSixteenDatabase(at url: URL) throws {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements
                + SQLiteStateStore.schemaV9Statements
                + SQLiteStateStore.schemaV10Statements
                + SQLiteStateStore.schemaV11Statements
                + SQLiteStateStore.schemaV12Statements
                + SQLiteStateStore.schemaV13Statements
                + SQLiteStateStore.schemaV14Statements
                + SQLiteStateStore.schemaV15Statements
                + SQLiteStateStore.schemaV16Statements {
                try execute(statement, database: database)
            }
            try execute(
                "PRAGMA application_id = \(SQLiteStateStore.applicationID)",
                database: database
            )
            try execute("PRAGMA user_version = 16", database: database)
        }
    }

    private func createVersionSeventeenDatabase(at url: URL) throws {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements
                + SQLiteStateStore.schemaV9Statements
                + SQLiteStateStore.schemaV10Statements
                + SQLiteStateStore.schemaV11Statements
                + SQLiteStateStore.schemaV12Statements
                + SQLiteStateStore.schemaV13Statements
                + SQLiteStateStore.schemaV14Statements
                + SQLiteStateStore.schemaV15Statements
                + SQLiteStateStore.schemaV16Statements
                + SQLiteStateStore.schemaV17Statements {
                try execute(statement, database: database)
            }
            try execute(
                "PRAGMA application_id = \(SQLiteStateStore.applicationID)",
                database: database
            )
            try execute("PRAGMA user_version = 17", database: database)
        }
    }

    private func createVersionEighteenDatabase(at url: URL) throws {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            for statement in SQLiteStateStore.schemaV1Statements
                + SQLiteStateStore.schemaV2Statements
                + SQLiteStateStore.schemaV3Statements
                + SQLiteStateStore.schemaV4Statements
                + SQLiteStateStore.schemaV5Statements
                + SQLiteStateStore.schemaV6Statements
                + SQLiteStateStore.schemaV7Statements
                + SQLiteStateStore.schemaV8Statements
                + SQLiteStateStore.schemaV9Statements
                + SQLiteStateStore.schemaV10Statements
                + SQLiteStateStore.schemaV11Statements
                + SQLiteStateStore.schemaV12Statements
                + SQLiteStateStore.schemaV13Statements
                + SQLiteStateStore.schemaV14Statements
                + SQLiteStateStore.schemaV15Statements
                + SQLiteStateStore.schemaV16Statements
                + SQLiteStateStore.schemaV17Statements
                + SQLiteStateStore.schemaV18Statements {
                try execute(statement, database: database)
            }
            try execute(
                "PRAGMA application_id = \(SQLiteStateStore.applicationID)",
                database: database
            )
            try execute("PRAGMA user_version = 18", database: database)
        }
    }

    private func makeJournal(
        phase: CodexGhostRepairBulkLiveJournalPhase,
        fixture: BulkShippingCompositionTestFixture.Value
    ) throws {
        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { store.close() }
        _ = try store.prepareCodexGhostRepairBulkLiveExecutionJournal(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        guard phase != .prepared else { return }
        let claim = try store.claimCodexGhostRepairBulkLiveExecution(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest,
            claimID: UUID(),
            claimedAtMilliseconds: 1_600
        )
        guard phase != .claimed else { return }
        let attempt = try store.recordCodexGhostRepairBulkLiveExecutionAttempt(
            requestID: fixture.livePlan.requestID,
            expectedClaimDigest: claim.claimDigest,
            attemptedAtMilliseconds: 1_700
        )
        guard phase != .attempted else { return }
        let report = try CodexGhostRepairBulkLiveTerminalReport(
            reportID: UUID(),
            plan: fixture.livePlan,
            receipt: fixture.confirmationReceipt,
            claim: claim,
            attempt: attempt,
            outcome: .unknown,
            completedAtMilliseconds: 1_800
        )
        _ = try store.recordCodexGhostRepairBulkLiveTerminalReport(report)
    }

    private func downgradeJournalToVersionNineteen(at url: URL) throws {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        ) { database in
            try execute("BEGIN IMMEDIATE", database: database)
            do {
                try execute(
                    "DROP INDEX codex_desktop_cleanup_bindings_operation_idx",
                    database: database
                )
                try execute(
                    "DROP TABLE codex_desktop_cleanup_bindings",
                    database: database
                )
                try execute("DROP TRIGGER reject_retired_bulk_preview", database: database)
                try execute("DROP TRIGGER reject_retired_operation_preview", database: database)
                try execute("DROP TRIGGER reject_retired_archive_batch", database: database)
                try execute("DROP TABLE retired_history_keys", database: database)
                try execute(
                    "ALTER TABLE codex_ghost_repair_bulk_live_execution_journal RENAME TO codex_ghost_repair_bulk_live_execution_journal_v20",
                    database: database
                )
                try execute(
                    "DROP INDEX codex_ghost_repair_bulk_live_execution_journal_phase_idx",
                    database: database
                )
                try execute(
                    SQLiteStateStore.schemaV19Statements[0],
                    database: database
                )
                try execute(
                    """
                    INSERT INTO codex_ghost_repair_bulk_live_execution_journal (
                        request_id, confirmation_receipt_id,
                        confirmation_receipt_digest, plan_digest,
                        backup_receipt_digest, selected_count, phase,
                        claim_digest, attempt_digest, terminal_report_digest,
                        payload_json, payload_hash, mutation_attempt_count,
                        automatic_retry_allowed, automatic_restore_allowed,
                        silent_selection_shrink_allowed
                    )
                    SELECT request_id, confirmation_receipt_id,
                           confirmation_receipt_digest, plan_digest,
                           backup_receipt_digest, selected_count, phase,
                           claim_digest, attempt_digest, terminal_report_digest,
                           payload_json, payload_hash, mutation_attempt_count,
                           automatic_retry_allowed, automatic_restore_allowed,
                           silent_selection_shrink_allowed
                    FROM codex_ghost_repair_bulk_live_execution_journal_v20
                    """,
                    database: database
                )
                try execute(
                    "DROP TABLE codex_ghost_repair_bulk_live_execution_journal_v20",
                    database: database
                )
                try execute(
                    SQLiteStateStore.schemaV19Statements[1],
                    database: database
                )
                try execute("ALTER TABLE provider_checkpoints DROP COLUMN compatibility_binding_json", database: database)
                try execute("PRAGMA user_version = 19", database: database)
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
    }

    private func downgradeToVersionTwenty(at url: URL) throws {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        ) { database in
            try execute("BEGIN IMMEDIATE", database: database)
            do {
                try execute(
                    "DROP INDEX codex_desktop_cleanup_bindings_operation_idx",
                    database: database
                )
                try execute(
                    "DROP TABLE codex_desktop_cleanup_bindings",
                    database: database
                )
                try execute("DROP TRIGGER reject_retired_bulk_preview", database: database)
                try execute("DROP TRIGGER reject_retired_operation_preview", database: database)
                try execute("DROP TRIGGER reject_retired_archive_batch", database: database)
                try execute("DROP TABLE retired_history_keys", database: database)
                try execute("ALTER TABLE provider_checkpoints DROP COLUMN compatibility_binding_json", database: database)
                try execute("PRAGMA user_version = 20", database: database)
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
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
