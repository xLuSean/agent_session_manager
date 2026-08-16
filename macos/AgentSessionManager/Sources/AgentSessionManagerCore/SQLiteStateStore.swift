import CSQLite3
import Foundation

public enum SQLiteStateStoreError: Error, Equatable, LocalizedError {
    case openFailed(path: String, message: String)
    case sqlite(operation: String, code: Int32, message: String)
    case unsupportedSchemaVersion(found: Int32, supported: Int32)
    case invalidApplicationID(found: Int32)
    case missingMigration(fromVersion: Int32)
    case integrityCheckFailed(path: String, result: String)
    case invalidHistoryRetentionLimit(Int)
    case invalidMaintenancePolicy
    case maintenanceAssessmentLimitExceeded(found: Int, limit: Int)
    case invalidMaintenanceStatistics
    case closed

    public var errorDescription: String? {
        switch self {
        case let .openFailed(path, message):
            "Could not open SQLite state store at \(path): \(message)"
        case let .sqlite(operation, code, message):
            "SQLite \(operation) failed (\(code)): \(message)"
        case let .unsupportedSchemaVersion(found, supported):
            "State store schema version \(found) is newer than supported version \(supported)."
        case let .invalidApplicationID(found):
            "SQLite file has unexpected application_id \(found)."
        case let .missingMigration(fromVersion):
            "No state store migration starts at schema version \(fromVersion)."
        case let .integrityCheckFailed(path, result):
            "SQLite integrity check failed for \(path): \(result)"
        case let .invalidHistoryRetentionLimit(limit):
            "Operation history retention limit must be greater than zero; found \(limit)."
        case .invalidMaintenancePolicy:
            "SQLite maintenance policy is invalid."
        case let .maintenanceAssessmentLimitExceeded(found, limit):
            "SQLite maintenance assessment found \(found) candidates, exceeding the limit of \(limit)."
        case .invalidMaintenanceStatistics:
            "SQLite returned invalid physical maintenance statistics."
        case .closed:
            "SQLite state store is closed."
        }
    }
}

public struct SQLiteStateStoreRestoreResult: Equatable, Sendable {
    public let preRestoreBackupURL: URL?

    public init(preRestoreBackupURL: URL?) {
        self.preRestoreBackupURL = preRestoreBackupURL
    }
}

struct SQLiteMigration: Sendable {
    let fromVersion: Int32
    let toVersion: Int32
    let statements: [String]
}

/// The manager-owned metadata store.
///
/// This store never contains conversation bodies and is not an interface to an
/// agent system's private session files. The app opens it lazily for Codex Live
/// reconciliation and audited lifecycle metadata; Fixture mode does not create
/// or mutate this production store.
public final class SQLiteStateStore: @unchecked Sendable {
    public static let currentSchemaVersion: Int32 = 8

    // ASCII "ASM1". This prevents a future caller from treating an unrelated
    // versioned SQLite database as an Agent Session Manager state store.
    static let applicationID: Int32 = 1_095_978_289

    public let databaseURL: URL
    public let historyRetentionPolicy: OperationHistoryRetentionPolicy
    public private(set) var migrationBackupURL: URL?

    private let lock = NSLock()
    private var database: OpaquePointer?

    public convenience init(
        databaseURL: URL,
        historyRetentionPolicy: OperationHistoryRetentionPolicy = .production
    ) throws {
        try self.init(
            databaseURL: databaseURL,
            migrations: Self.productionMigrations,
            now: Date(),
            historyRetentionPolicy: historyRetentionPolicy
        )
    }

    init(
        databaseURL: URL,
        migrations: [SQLiteMigration],
        now: Date,
        historyRetentionPolicy: OperationHistoryRetentionPolicy = .production
    ) throws {
        guard historyRetentionPolicy.maximumReportsPerProvider > 0 else {
            throw SQLiteStateStoreError.invalidHistoryRetentionLimit(
                historyRetentionPolicy.maximumReportsPerProvider
            )
        }
        self.databaseURL = databaseURL
        self.historyRetentionPolicy = historyRetentionPolicy

        let fileManager = FileManager.default
        let databaseExisted = fileManager.fileExists(atPath: databaseURL.path)
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        database = try Self.openDatabase(
            at: databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        )

        do {
            // Tighten permissions before writing any manager metadata, including
            // on a newly created file whose process umask may be less strict.
            try Self.setPrivatePermissions(at: databaseURL)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA busy_timeout = 5000")
            try execute("PRAGMA synchronous = FULL")

            let originalVersion = try scalarInt32("PRAGMA user_version")
            guard originalVersion <= Self.currentSchemaVersion else {
                throw SQLiteStateStoreError.unsupportedSchemaVersion(
                    found: originalVersion,
                    supported: Self.currentSchemaVersion
                )
            }

            if originalVersion > 0 {
                let foundApplicationID = try scalarInt32("PRAGMA application_id")
                guard foundApplicationID == Self.applicationID else {
                    throw SQLiteStateStoreError.invalidApplicationID(found: foundApplicationID)
                }
            }

            if originalVersion < Self.currentSchemaVersion {
                if databaseExisted {
                    let backupURL = Self.backupURL(
                        for: databaseURL,
                        label: "backup-v\(originalVersion)",
                        now: now
                    )
                    try Self.copyDatabase(database, to: backupURL)
                    try Self.setPrivatePermissions(at: backupURL)
                    migrationBackupURL = backupURL
                }

                try migrate(
                    from: originalVersion,
                    migrations: migrations
                )
            }

            try execute("PRAGMA journal_mode = WAL")
            try Self.verifyIntegrity(database, at: databaseURL)
            try Self.setPrivatePermissions(at: databaseURL)
        } catch {
            closeUnlocked()
            throw error
        }
    }

    deinit {
        closeUnlocked()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closeUnlocked()
    }

    public func schemaVersion() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return try scalarInt32("PRAGMA user_version")
    }

    /// Restores a previously created SQLite backup. If a destination database
    /// already exists, it is backed up first so the restore remains reversible.
    /// The caller must close any `SQLiteStateStore` using the destination before
    /// invoking this method.
    @discardableResult
    public static func restoreBackup(
        from sourceBackupURL: URL,
        to databaseURL: URL,
        now: Date = Date()
    ) throws -> SQLiteStateStoreRestoreResult {
        let source = try openDatabase(at: sourceBackupURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(source) }
        try verifyIntegrity(source, at: sourceBackupURL)

        let sourceVersion = try scalarInt32("PRAGMA user_version", database: source)
        guard sourceVersion <= currentSchemaVersion else {
            throw SQLiteStateStoreError.unsupportedSchemaVersion(
                found: sourceVersion,
                supported: currentSchemaVersion
            )
        }
        if sourceVersion > 0 {
            let sourceApplicationID = try scalarInt32("PRAGMA application_id", database: source)
            guard sourceApplicationID == applicationID else {
                throw SQLiteStateStoreError.invalidApplicationID(found: sourceApplicationID)
            }
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let destinationExisted = fileManager.fileExists(atPath: databaseURL.path)
        let destination = try openDatabase(
            at: databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close_v2(destination) }
        try setPrivatePermissions(at: databaseURL)

        var preRestoreBackupURL: URL?
        if destinationExisted {
            let safetyBackupURL = backupURL(
                for: databaseURL,
                label: "pre-restore",
                now: now
            )
            try copyDatabase(destination, to: safetyBackupURL)
            try setPrivatePermissions(at: safetyBackupURL)
            preRestoreBackupURL = safetyBackupURL
        }

        try copyDatabase(source, toOpenDestination: destination, destinationURL: databaseURL)
        try verifyIntegrity(destination, at: databaseURL)
        try setPrivatePermissions(at: databaseURL)
        return SQLiteStateStoreRestoreResult(preRestoreBackupURL: preRestoreBackupURL)
    }

    func tableNames() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        SELECT name
        FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """
        return try stringColumn(sql)
    }

    func withLockedDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw SQLiteStateStoreError.closed }
        return try body(database)
    }

    private func migrate(from initialVersion: Int32, migrations: [SQLiteMigration]) throws {
        var version = initialVersion
        while version < Self.currentSchemaVersion {
            guard let migration = migrations.first(where: { $0.fromVersion == version }) else {
                throw SQLiteStateStoreError.missingMigration(fromVersion: version)
            }
            guard migration.toVersion > version,
                  migration.toVersion <= Self.currentSchemaVersion else {
                throw SQLiteStateStoreError.missingMigration(fromVersion: version)
            }

            try execute("BEGIN IMMEDIATE")
            do {
                for statement in migration.statements {
                    try execute(statement)
                }
                try execute("PRAGMA application_id = \(Self.applicationID)")
                try execute("PRAGMA user_version = \(migration.toVersion)")
                try execute("COMMIT")
                version = migration.toVersion
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw SQLiteStateStoreError.closed }
        try Self.execute(sql, database: database)
    }

    private func scalarInt32(_ sql: String) throws -> Int32 {
        guard let database else { throw SQLiteStateStoreError.closed }
        return try Self.scalarInt32(sql, database: database)
    }

    private func stringColumn(_ sql: String) throws -> [String] {
        guard let database else { throw SQLiteStateStoreError.closed }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            throw Self.sqliteError(operation: "prepare", code: prepareResult, database: database)
        }
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { return values }
            guard stepResult == SQLITE_ROW else {
                throw Self.sqliteError(operation: "query", code: stepResult, database: database)
            }
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
    }

    private func closeUnlocked() {
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    private static func openDatabase(at url: URL, flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close_v2(database) }
            throw SQLiteStateStoreError.openFailed(path: url.path, message: message)
        }
        return database
    }

    private static func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SQLiteStateStoreError.sqlite(
                operation: "execute",
                code: result,
                message: message
            )
        }
    }

    private static func scalarInt32(_ sql: String, database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            throw sqliteError(operation: "prepare", code: prepareResult, database: database)
        }
        defer { sqlite3_finalize(statement) }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw sqliteError(operation: "query", code: stepResult, database: database)
        }
        return sqlite3_column_int(statement, 0)
    }

    private static func verifyIntegrity(_ database: OpaquePointer?, at url: URL) throws {
        guard let database else { throw SQLiteStateStoreError.closed }
        var statement: OpaquePointer?
        let sql = "PRAGMA integrity_check"
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            throw sqliteError(operation: "integrity-check prepare", code: prepareResult, database: database)
        }
        defer { sqlite3_finalize(statement) }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            throw sqliteError(operation: "integrity-check query", code: stepResult, database: database)
        }
        let result = String(cString: text)
        guard result == "ok" else {
            throw SQLiteStateStoreError.integrityCheckFailed(path: url.path, result: result)
        }
    }

    private static func copyDatabase(_ source: OpaquePointer?, to destinationURL: URL) throws {
        guard let source else { throw SQLiteStateStoreError.closed }
        let destination = try openDatabase(
            at: destinationURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        )
        defer { sqlite3_close_v2(destination) }
        try setPrivatePermissions(at: destinationURL)
        try copyDatabase(source, toOpenDestination: destination, destinationURL: destinationURL)
        // A copied WAL database can otherwise require a matching -shm file even
        // for read-only verification. Backups are deliberately normalized into
        // one standalone SQLite file; the live store enables WAL when reopened.
        try execute("PRAGMA journal_mode = DELETE", database: destination)
        try verifyIntegrity(destination, at: destinationURL)
    }

    private static func copyDatabase(
        _ source: OpaquePointer,
        toOpenDestination destination: OpaquePointer,
        destinationURL: URL
    ) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw sqliteError(operation: "backup init", code: sqlite3_errcode(destination), database: destination)
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            let code = finishResult == SQLITE_OK ? stepResult : finishResult
            throw sqliteError(operation: "backup to \(destinationURL.path)", code: code, database: destination)
        }
    }

    private static func sqliteError(
        operation: String,
        code: Int32,
        database: OpaquePointer
    ) -> SQLiteStateStoreError {
        SQLiteStateStoreError.sqlite(
            operation: operation,
            code: code,
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private static func backupURL(for databaseURL: URL, label: String, now: Date) -> URL {
        let milliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let suffix = UUID().uuidString.lowercased()
        return databaseURL.deletingLastPathComponent().appendingPathComponent(
            "\(databaseURL.lastPathComponent).\(label)-\(milliseconds)-\(suffix).sqlite3"
        )
    }

    private static func setPrivatePermissions(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    static let productionMigrations: [SQLiteMigration] = [
        SQLiteMigration(
            fromVersion: 0,
            toVersion: 1,
            statements: schemaV1Statements
        ),
        SQLiteMigration(
            fromVersion: 1,
            toVersion: 2,
            statements: schemaV2Statements
        ),
        SQLiteMigration(
            fromVersion: 2,
            toVersion: 3,
            statements: schemaV3Statements
        ),
        SQLiteMigration(
            fromVersion: 3,
            toVersion: 4,
            statements: schemaV4Statements
        ),
        SQLiteMigration(
            fromVersion: 4,
            toVersion: 5,
            statements: schemaV5Statements
        ),
        SQLiteMigration(
            fromVersion: 5,
            toVersion: 6,
            statements: schemaV6Statements
        ),
        SQLiteMigration(
            fromVersion: 6,
            toVersion: 7,
            statements: schemaV7Statements
        ),
        SQLiteMigration(
            fromVersion: 7,
            toVersion: 8,
            statements: schemaV8Statements
        ),
    ]

    static let schemaV1Statements: [String] = [
        """
        CREATE TABLE provider_checkpoints (
            provider TEXT PRIMARY KEY NOT NULL,
            runtime_version TEXT,
            inventory_hash TEXT NOT NULL,
            refreshed_at TEXT NOT NULL,
            inventory_complete INTEGER NOT NULL CHECK (inventory_complete IN (0, 1)),
            protection_complete INTEGER NOT NULL CHECK (protection_complete IN (0, 1)),
            last_error_code TEXT,
            last_error_message TEXT
        ) STRICT
        """,
        """
        CREATE TABLE trash_memberships (
            provider TEXT NOT NULL,
            native_session_id TEXT NOT NULL,
            manager_key TEXT NOT NULL UNIQUE,
            title_at_entry TEXT NOT NULL,
            project_id_at_entry TEXT,
            working_directory_at_entry TEXT,
            native_state_at_entry TEXT NOT NULL CHECK (native_state_at_entry IN ('active', 'archived')),
            provider_inventory_hash_at_entry TEXT NOT NULL,
            entered_at TEXT NOT NULL,
            last_reconciled_at TEXT NOT NULL,
            PRIMARY KEY (provider, native_session_id),
            FOREIGN KEY (provider) REFERENCES provider_checkpoints(provider)
        ) STRICT
        """,
        """
        CREATE TABLE operation_previews (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL,
            operation TEXT NOT NULL CHECK (operation IN ('archive', 'move_to_trash', 'restore', 'permanently_delete')),
            status TEXT NOT NULL CHECK (status IN ('prepared', 'executing', 'consumed', 'expired', 'cancelled')),
            confirmation_token_hash TEXT NOT NULL,
            manifest_hash TEXT NOT NULL,
            provider_inventory_hash TEXT NOT NULL,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            item_count INTEGER NOT NULL CHECK (item_count >= 0),
            known_size_bytes INTEGER NOT NULL CHECK (known_size_bytes >= 0),
            unknown_size_count INTEGER NOT NULL CHECK (unknown_size_count >= 0),
            FOREIGN KEY (provider) REFERENCES provider_checkpoints(provider)
        ) STRICT
        """,
        """
        CREATE TABLE operation_reports (
            id TEXT PRIMARY KEY NOT NULL,
            preview_id TEXT NOT NULL UNIQUE,
            provider TEXT NOT NULL,
            operation TEXT NOT NULL CHECK (operation IN ('archive', 'move_to_trash', 'restore', 'permanently_delete')),
            outcome TEXT NOT NULL CHECK (outcome IN ('success', 'warning', 'failure', 'partial', 'unknown')),
            started_at TEXT NOT NULL,
            completed_at TEXT NOT NULL,
            item_count INTEGER NOT NULL CHECK (item_count >= 0),
            succeeded_count INTEGER NOT NULL CHECK (succeeded_count >= 0),
            failed_count INTEGER NOT NULL CHECK (failed_count >= 0),
            unknown_count INTEGER NOT NULL CHECK (unknown_count >= 0),
            verified_released_bytes INTEGER NOT NULL CHECK (verified_released_bytes >= 0),
            released_bytes_complete INTEGER NOT NULL CHECK (released_bytes_complete IN (0, 1)),
            error_code TEXT,
            error_message TEXT,
            FOREIGN KEY (preview_id) REFERENCES operation_previews(id),
            FOREIGN KEY (provider) REFERENCES provider_checkpoints(provider)
        ) STRICT
        """,
        """
        CREATE TABLE operation_items (
            preview_id TEXT NOT NULL,
            report_id TEXT,
            manager_key TEXT NOT NULL,
            native_session_id TEXT NOT NULL,
            expected_native_state TEXT NOT NULL CHECK (expected_native_state IN ('active', 'archived', 'absent')),
            expected_protection_hash TEXT NOT NULL,
            expected_title TEXT NOT NULL,
            expected_project_id TEXT,
            known_size_bytes INTEGER CHECK (known_size_bytes IS NULL OR known_size_bytes >= 0),
            result_outcome TEXT CHECK (result_outcome IS NULL OR result_outcome IN ('success', 'failure', 'unknown')),
            observed_native_state TEXT CHECK (observed_native_state IS NULL OR observed_native_state IN ('active', 'archived', 'absent', 'unavailable')),
            verified_released_bytes INTEGER CHECK (verified_released_bytes IS NULL OR verified_released_bytes >= 0),
            evidence_at TEXT,
            error_code TEXT,
            error_message TEXT,
            PRIMARY KEY (preview_id, manager_key),
            FOREIGN KEY (preview_id) REFERENCES operation_previews(id),
            FOREIGN KEY (report_id) REFERENCES operation_reports(id)
        ) STRICT
        """,
        "CREATE INDEX trash_memberships_entered_at_idx ON trash_memberships(entered_at)",
        "CREATE INDEX operation_previews_status_expires_idx ON operation_previews(status, expires_at)",
        "CREATE INDEX operation_reports_completed_at_idx ON operation_reports(completed_at)",
        "CREATE INDEX operation_items_report_outcome_idx ON operation_items(report_id, result_outcome)",
    ]

    static let schemaV2Statements: [String] = [
        "ALTER TABLE operation_previews ADD COLUMN affected_set_hash TEXT",
        "ALTER TABLE operation_items ADD COLUMN archive_affected_role TEXT CHECK (archive_affected_role IS NULL OR archive_affected_role IN ('selectedRoot', 'descendant'))",
        "ALTER TABLE operation_items ADD COLUMN parent_native_session_id TEXT",
        "ALTER TABLE operation_items ADD COLUMN archive_affected_depth INTEGER CHECK (archive_affected_depth IS NULL OR archive_affected_depth >= 0)",
    ]

    static let schemaV3Statements: [String] = [
        """
        CREATE TABLE archive_batch_plans (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL CHECK (provider = 'codex'),
            status TEXT NOT NULL CHECK (status IN ('prepared', 'executing', 'consumed', 'cancelled')),
            provider_inventory_hash TEXT NOT NULL,
            confirmation_token_hash TEXT NOT NULL,
            manifest_hash TEXT NOT NULL,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            unit_count INTEGER NOT NULL CHECK (unit_count > 0),
            item_count INTEGER NOT NULL CHECK (item_count > 0),
            FOREIGN KEY (provider) REFERENCES provider_checkpoints(provider)
        ) STRICT
        """,
        """
        CREATE TABLE archive_batch_units (
            batch_id TEXT NOT NULL,
            unit_ordinal INTEGER NOT NULL CHECK (unit_ordinal >= 0),
            preview_id TEXT NOT NULL UNIQUE,
            selected_root_manager_key TEXT NOT NULL,
            selected_root_native_session_id TEXT NOT NULL,
            affected_set_hash TEXT NOT NULL,
            disposition TEXT CHECK (disposition IS NULL OR disposition IN ('success', 'failure', 'partial', 'unknown', 'not_attempted')),
            error_code TEXT,
            error_message TEXT,
            PRIMARY KEY (batch_id, unit_ordinal),
            UNIQUE (batch_id, selected_root_manager_key),
            FOREIGN KEY (batch_id) REFERENCES archive_batch_plans(id),
            FOREIGN KEY (preview_id) REFERENCES operation_previews(id)
        ) STRICT
        """,
        """
        CREATE TABLE archive_batch_items (
            batch_id TEXT NOT NULL,
            unit_ordinal INTEGER NOT NULL,
            item_ordinal INTEGER NOT NULL CHECK (item_ordinal >= 0),
            preview_id TEXT NOT NULL,
            manager_key TEXT NOT NULL,
            native_session_id TEXT NOT NULL,
            disposition TEXT CHECK (disposition IS NULL OR disposition IN ('success', 'failure', 'unknown', 'not_attempted')),
            observed_native_state TEXT CHECK (observed_native_state IS NULL OR observed_native_state IN ('active', 'archived', 'absent', 'unavailable')),
            evidence_at TEXT,
            error_code TEXT,
            error_message TEXT,
            PRIMARY KEY (batch_id, unit_ordinal, item_ordinal),
            UNIQUE (batch_id, manager_key),
            FOREIGN KEY (batch_id, unit_ordinal) REFERENCES archive_batch_units(batch_id, unit_ordinal),
            FOREIGN KEY (preview_id, manager_key) REFERENCES operation_items(preview_id, manager_key)
        ) STRICT
        """,
        """
        CREATE TABLE archive_batch_reports (
            id TEXT PRIMARY KEY NOT NULL,
            batch_id TEXT NOT NULL UNIQUE,
            outcome TEXT NOT NULL CHECK (outcome IN ('success', 'failure', 'partial', 'unknown')),
            started_at TEXT NOT NULL,
            completed_at TEXT NOT NULL,
            attempted_unit_count INTEGER NOT NULL CHECK (attempted_unit_count >= 0),
            not_attempted_unit_count INTEGER NOT NULL CHECK (not_attempted_unit_count >= 0),
            error_code TEXT,
            error_message TEXT,
            FOREIGN KEY (batch_id) REFERENCES archive_batch_plans(id)
        ) STRICT
        """,
        "CREATE INDEX archive_batch_plans_status_expires_idx ON archive_batch_plans(status, expires_at)",
        "CREATE INDEX archive_batch_reports_completed_at_idx ON archive_batch_reports(completed_at)",
    ]

    static let schemaV4Statements: [String] = [
        "ALTER TABLE operation_previews ADD COLUMN manager_intent TEXT NOT NULL DEFAULT 'archive' CHECK (manager_intent IN ('archive', 'move_to_trash', 'restore', 'move_to_archive', 'permanently_delete'))",
        "UPDATE operation_previews SET manager_intent = operation",
        "ALTER TABLE operation_reports ADD COLUMN manager_intent TEXT NOT NULL DEFAULT 'archive' CHECK (manager_intent IN ('archive', 'move_to_trash', 'restore', 'move_to_archive', 'permanently_delete'))",
        "UPDATE operation_reports SET manager_intent = operation",
    ]

    static let schemaV5Statements: [String] = [
        "ALTER TABLE operation_previews ADD COLUMN trash_membership_mutation TEXT CHECK (trash_membership_mutation IS NULL OR trash_membership_mutation IN ('add', 'remove'))",
    ]

    static let schemaV6Statements: [String] = [
        "ALTER TABLE operation_items ADD COLUMN expected_working_directory TEXT",
    ]

    static let schemaV7Statements: [String] = [
        """
        CREATE TABLE deleted_sessions (
            provider TEXT NOT NULL,
            native_session_id TEXT NOT NULL,
            manager_key TEXT NOT NULL UNIQUE,
            title_at_deletion TEXT NOT NULL,
            project_id_at_deletion TEXT,
            working_directory_at_deletion TEXT,
            known_size_bytes INTEGER CHECK (known_size_bytes IS NULL OR known_size_bytes >= 0),
            provider_inventory_hash_at_deletion TEXT NOT NULL,
            deleted_at TEXT NOT NULL,
            delete_report_id TEXT UNIQUE,
            PRIMARY KEY (provider, native_session_id),
            FOREIGN KEY (provider) REFERENCES provider_checkpoints(provider)
        ) STRICT
        """,
        "CREATE INDEX deleted_sessions_deleted_at_idx ON deleted_sessions(deleted_at)",
    ]

    /// V7 assumed one Delete Report per tombstone. A frozen batch has one
    /// Report covering multiple exact sessions, so V8 keeps the report ID as a
    /// non-unique audit grouping key while preserving manager/native identity
    /// uniqueness.
    static let schemaV8Statements: [String] = [
        "ALTER TABLE deleted_sessions RENAME TO deleted_sessions_v7",
        "DROP INDEX deleted_sessions_deleted_at_idx",
        """
        CREATE TABLE deleted_sessions (
            provider TEXT NOT NULL,
            native_session_id TEXT NOT NULL,
            manager_key TEXT NOT NULL UNIQUE,
            title_at_deletion TEXT NOT NULL,
            project_id_at_deletion TEXT,
            working_directory_at_deletion TEXT,
            known_size_bytes INTEGER CHECK (known_size_bytes IS NULL OR known_size_bytes >= 0),
            provider_inventory_hash_at_deletion TEXT NOT NULL,
            deleted_at TEXT NOT NULL,
            delete_report_id TEXT,
            PRIMARY KEY (provider, native_session_id),
            FOREIGN KEY (provider) REFERENCES provider_checkpoints(provider)
        ) STRICT
        """,
        """
        INSERT INTO deleted_sessions (
            provider, native_session_id, manager_key, title_at_deletion,
            project_id_at_deletion, working_directory_at_deletion,
            known_size_bytes, provider_inventory_hash_at_deletion,
            deleted_at, delete_report_id
        )
        SELECT provider, native_session_id, manager_key, title_at_deletion,
               project_id_at_deletion, working_directory_at_deletion,
               known_size_bytes, provider_inventory_hash_at_deletion,
               deleted_at, delete_report_id
        FROM deleted_sessions_v7
        """,
        "DROP TABLE deleted_sessions_v7",
        "CREATE INDEX deleted_sessions_deleted_at_idx ON deleted_sessions(deleted_at)",
        "CREATE INDEX deleted_sessions_delete_report_id_idx ON deleted_sessions(delete_report_id)",
    ]
}
