import CSQLite3
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH
struct CodexGhostRepairRawTargetState: Equatable, Sendable {
    let threadID: String
    let catalogRows: [CodexGhostRepairSQLiteRow]
    let automationRows: [CodexGhostRepairSQLiteRow]
    let definitionRows: [CodexGhostRepairSQLiteRow]
    let sideReferenceCount: Int
}

struct CodexGhostRepairRawDatabaseState: Equatable, Sendable {
    let desktopSchemaVersion: Int32
    let summariesSchemaVersion: Int32
    let historySchemaVersion: Int32
    let targets: [CodexGhostRepairRawTargetState]
    let authority: CodexGhostRepairAuthorityEvidence
}

/// E25 test-owned snapshot reader. This type intentionally has no backup,
/// transaction, execute, or generic SQL API and cannot accept a live path
/// without first satisfying the existing disposable-bundle capability guard.
enum CodexGhostRepairDisposableSnapshotReader {
    static func read(
        bundle: CodexGhostRepairDisposableBundle,
        targetIDs: [String]
    ) throws -> CodexGhostRepairRawDatabaseState {
        guard (1...10).contains(targetIDs.count), Set(targetIDs).count == targetIDs.count else {
            throw CodexGhostRepairError.invalidPlan(
                "Snapshot selection must contain 1–10 unique exact IDs."
            )
        }
        try bundle.validatePaths()

        let desktop = try CodexGhostRepairQueryOnlySQLite(url: bundle.desktopDatabaseURL)
        defer { desktop.close() }
        let summaries = try CodexGhostRepairQueryOnlySQLite(url: bundle.summariesDatabaseURL)
        defer { summaries.close() }
        let history = try CodexGhostRepairQueryOnlySQLite(url: bundle.historyDatabaseURL)
        defer { history.close() }

        let desktopVersion = try desktop.schemaVersion()
        let summariesVersion = try summaries.schemaVersion()
        let historyVersion = try history.schemaVersion()
        guard desktopVersion == 32, summariesVersion == 2, historyVersion == 3 else {
            throw CodexGhostRepairError.invalidDatabaseContract("schema version mismatch")
        }
        try desktop.verifyHealth()
        try summaries.verifyHealth()
        try history.verifyHealth()

        var targets: [CodexGhostRepairRawTargetState] = []
        for threadID in targetIDs {
            let catalogRows = try desktop.catalogRows(threadID: threadID).map {
                try $0.privacyPreserving(cleartextFields: CodexGhostRepairPrivacyContract.catalog)
            }
            let rawAutomationRows = try desktop.automationRunRows(threadID: threadID)
            let automationRows = try rawAutomationRows.map {
                try $0.privacyPreserving(
                    cleartextFields: CodexGhostRepairPrivacyContract.automationRun
                )
            }
            var definitionRows: [CodexGhostRepairSQLiteRow] = []
            for automation in rawAutomationRows {
                guard case let .text(automationID)? = automation.value(named: "automation_id") else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "automation_id is not text"
                    )
                }
                let definitions = try desktop.automationDefinitionRows(
                    automationID: automationID
                ).map {
                    try $0.privacyPreserving(
                        cleartextFields: CodexGhostRepairPrivacyContract.automationDefinition
                    )
                }
                definitionRows.append(contentsOf: definitions)
            }
            let sideReferenceCount = try desktop.sideReferenceCount(
                table: .inboxItems,
                threadID: threadID
            ) + desktop.sideReferenceCount(
                table: .timeline,
                threadID: threadID
            ) + summaries.sideReferenceCount(
                table: .summaries,
                threadID: threadID
            ) + history.sideReferenceCount(
                table: .history,
                threadID: threadID
            )
            targets.append(
                CodexGhostRepairRawTargetState(
                    threadID: threadID,
                    catalogRows: catalogRows,
                    automationRows: automationRows,
                    definitionRows: definitionRows,
                    sideReferenceCount: sideReferenceCount
                )
            )
        }

        let metadataRows = try desktop.metadataRows().map {
            try $0.privacyPreserving(cleartextFields: CodexGhostRepairPrivacyContract.metadata)
        }
        let syncRows = try desktop.localSyncRows().map {
            try $0.privacyPreserving(cleartextFields: CodexGhostRepairPrivacyContract.localSync)
        }
        guard metadataRows.count == 1, syncRows.count == 1 else {
            throw CodexGhostRepairError.invalidDatabaseContract("authority row multiplicity")
        }

        let state = CodexGhostRepairRawDatabaseState(
            desktopSchemaVersion: desktopVersion,
            summariesSchemaVersion: summariesVersion,
            historySchemaVersion: historyVersion,
            targets: targets,
            authority: CodexGhostRepairAuthorityEvidence(
                metadataRow: metadataRows[0],
                localSyncRow: syncRows[0]
            )
        )
        guard state.satisfiesPrivacyContract else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "snapshot evidence violated the privacy contract"
            )
        }
        return state
    }
}

extension CodexGhostRepairRawDatabaseState {
    var satisfiesPrivacyContract: Bool {
        targets.allSatisfy { target in
            target.catalogRows.allSatisfy {
                $0.satisfiesPrivacyContract(
                    cleartextFields: CodexGhostRepairPrivacyContract.catalog
                )
            }
                && target.automationRows.allSatisfy {
                    $0.satisfiesPrivacyContract(
                        cleartextFields: CodexGhostRepairPrivacyContract.automationRun
                    )
                }
                && target.definitionRows.allSatisfy {
                    $0.satisfiesPrivacyContract(
                        cleartextFields: CodexGhostRepairPrivacyContract.automationDefinition
                    )
                }
        }
            && authority.metadataRow.satisfiesPrivacyContract(
                cleartextFields: CodexGhostRepairPrivacyContract.metadata
            )
            && authority.localSyncRow.satisfiesPrivacyContract(
                cleartextFields: CodexGhostRepairPrivacyContract.localSync
            )
    }
}

enum CodexGhostRepairSnapshotAuthorizer {
    private static let allowedTables: Set<String> = [
        "local_thread_catalog",
        "automation_runs",
        "automations",
        "inbox_items",
        "thread_timeline_ledger",
        "thread_turn_summaries",
        "app_server_history_snapshots",
        "local_thread_catalog_metadata",
        "local_thread_catalog_sync_state",
    ]

    static func decision(
        actionCode: Int32,
        parameterOne: String?,
        parameterTwo: String?
    ) -> Int32 {
        switch actionCode {
        case SQLITE_SELECT:
            return SQLITE_OK
        case SQLITE_READ:
            return parameterOne.map(allowedTables.contains) == true ? SQLITE_OK : SQLITE_DENY
        case SQLITE_FUNCTION:
            return [parameterOne, parameterTwo]
                .compactMap { $0?.lowercased() }
                .contains("count") ? SQLITE_OK : SQLITE_DENY
        case SQLITE_PRAGMA:
            guard parameterTwo == nil else { return SQLITE_DENY }
            return ["user_version", "integrity_check", "foreign_key_check", "query_only"]
                .contains(parameterOne?.lowercased() ?? "") ? SQLITE_OK : SQLITE_DENY
        default:
            return SQLITE_DENY
        }
    }
}

private enum CodexGhostRepairSnapshotSideTable: String {
    case inboxItems = "inbox_items"
    case timeline = "thread_timeline_ledger"
    case summaries = "thread_turn_summaries"
    case history = "app_server_history_snapshots"
}

private enum CodexGhostRepairSnapshotBinding {
    case text(String)
}

private final class CodexGhostRepairQueryOnlySQLite {
    private var database: OpaquePointer?

    init(url: URL) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &pointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let pointer { sqlite3_close_v2(pointer) }
            throw CodexGhostRepairError.sqlite(
                operation: "snapshot_open",
                code: result,
                message: message
            )
        }
        database = pointer
        do {
            guard sqlite3_db_readonly(pointer, "main") == 1 else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "snapshot connection is not SQLite read-only"
                )
            }
            try executeSetup("PRAGMA query_only=ON")
            guard sqlite3_busy_timeout(pointer, 250) == SQLITE_OK else {
                throw sqliteError(operation: "snapshot_busy_timeout")
            }
            guard sqlite3_set_authorizer(
                pointer,
                codexGhostRepairSnapshotAuthorize,
                nil
            ) == SQLITE_OK else {
                throw sqliteError(operation: "snapshot_authorizer")
            }
            guard try scalarInteger(.queryOnly) == 1 else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "snapshot connection did not retain query_only"
                )
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if let database {
            sqlite3_set_authorizer(database, nil, nil)
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    func schemaVersion() throws -> Int32 {
        let value = try scalarInteger(.schemaVersion)
        guard value >= 0, value <= Int64(Int32.max) else {
            throw CodexGhostRepairError.invalidDatabaseContract("invalid user_version")
        }
        return Int32(value)
    }

    func verifyHealth() throws {
        guard let row = try query(.integrityCheck).first,
              row.fields.first?.value == .text("ok") else {
            throw CodexGhostRepairError.invalidDatabaseContract("integrity_check failed")
        }
        guard try query(.foreignKeyCheck).isEmpty else {
            throw CodexGhostRepairError.invalidDatabaseContract("foreign_key_check failed")
        }
    }

    func catalogRows(threadID: String) throws -> [CodexGhostRepairSQLiteRow] {
        try query(.catalog, bindings: [.text(threadID)])
    }

    func automationRunRows(threadID: String) throws -> [CodexGhostRepairSQLiteRow] {
        try query(.automationRun, bindings: [.text(threadID)])
    }

    func automationDefinitionRows(
        automationID: String
    ) throws -> [CodexGhostRepairSQLiteRow] {
        try query(.automationDefinition, bindings: [.text(automationID)])
    }

    func sideReferenceCount(
        table: CodexGhostRepairSnapshotSideTable,
        threadID: String
    ) throws -> Int {
        guard let value = try query(
            .sideReferenceCount(table),
            bindings: [.text(threadID)]
        ).first?.value(named: "count"), case let .integer(count) = value,
              count >= 0, count <= Int64(Int.max) else {
            throw CodexGhostRepairError.invalidDatabaseContract("side-reference count failed")
        }
        return Int(count)
    }

    func metadataRows() throws -> [CodexGhostRepairSQLiteRow] {
        try query(.metadata)
    }

    func localSyncRows() throws -> [CodexGhostRepairSQLiteRow] {
        try query(.localSync)
    }

    private func scalarInteger(_ statement: Statement) throws -> Int64 {
        guard let row = try query(statement).first,
              case let .integer(value)? = row.fields.first?.value else {
            throw CodexGhostRepairError.invalidDatabaseContract("integer read failed")
        }
        return value
    }

    private func executeSetup(_ sql: String) throws {
        guard let database else {
            throw CodexGhostRepairError.sqlite(
                operation: "snapshot_setup",
                code: SQLITE_MISUSE,
                message: "closed"
            )
        }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw sqliteError(operation: "snapshot_setup") }
    }

    private func query(
        _ statement: Statement,
        bindings: [CodexGhostRepairSnapshotBinding] = []
    ) throws -> [CodexGhostRepairSQLiteRow] {
        guard let database else {
            throw CodexGhostRepairError.sqlite(
                operation: "snapshot_query",
                code: SQLITE_MISUSE,
                message: "closed"
            )
        }
        var prepared: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, statement.sql, -1, &prepared, nil)
        guard prepareResult == SQLITE_OK, let prepared else {
            throw sqliteError(operation: "snapshot_prepare")
        }
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_stmt_readonly(prepared) == 1 else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "snapshot statement is not read-only"
            )
        }
        for (offset, binding) in bindings.enumerated() {
            let result: Int32
            switch binding {
            case let .text(value):
                result = value.withCString { pointer in
                    sqlite3_bind_text(
                        prepared,
                        Int32(offset + 1),
                        pointer,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            }
            guard result == SQLITE_OK else { throw sqliteError(operation: "snapshot_bind") }
        }

        var rows: [CodexGhostRepairSQLiteRow] = []
        while true {
            let result = sqlite3_step(prepared)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw sqliteError(operation: "snapshot_step") }
            var fields: [CodexGhostRepairSQLiteField] = []
            for index in 0..<sqlite3_column_count(prepared) {
                let name = String(cString: sqlite3_column_name(prepared, index))
                let value: CodexGhostRepairSQLiteValue
                switch sqlite3_column_type(prepared, index) {
                case SQLITE_NULL:
                    value = .null
                case SQLITE_INTEGER:
                    value = .integer(sqlite3_column_int64(prepared, index))
                case SQLITE_FLOAT:
                    value = .real(sqlite3_column_double(prepared, index))
                case SQLITE_TEXT:
                    value = sqlite3_column_text(prepared, index).map {
                        .text(String(cString: $0))
                    } ?? .null
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(prepared, index))
                    if count == 0 {
                        value = .blob(Data())
                    } else if let bytes = sqlite3_column_blob(prepared, index) {
                        value = .blob(Data(bytes: bytes, count: count))
                    } else {
                        value = .null
                    }
                default:
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "unknown SQLite value type"
                    )
                }
                fields.append(CodexGhostRepairSQLiteField(name: name, value: value))
            }
            rows.append(CodexGhostRepairSQLiteRow(fields: fields))
        }
        return rows
    }

    private func sqliteError(operation: String) -> CodexGhostRepairError {
        guard let database else {
            return .sqlite(operation: operation, code: SQLITE_MISUSE, message: "closed")
        }
        return .sqlite(
            operation: operation,
            code: sqlite3_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private enum Statement {
        case queryOnly
        case schemaVersion
        case integrityCheck
        case foreignKeyCheck
        case catalog
        case automationRun
        case automationDefinition
        case sideReferenceCount(CodexGhostRepairSnapshotSideTable)
        case metadata
        case localSync

        var sql: String {
            switch self {
            case .queryOnly:
                "PRAGMA query_only"
            case .schemaVersion:
                "PRAGMA user_version"
            case .integrityCheck:
                "PRAGMA integrity_check"
            case .foreignKeyCheck:
                "PRAGMA foreign_key_check"
            case .catalog:
                "SELECT * FROM local_thread_catalog WHERE thread_id = ? ORDER BY host_id"
            case .automationRun:
                "SELECT * FROM automation_runs WHERE thread_id = ? ORDER BY automation_id"
            case .automationDefinition:
                "SELECT * FROM automations WHERE id = ? ORDER BY id"
            case let .sideReferenceCount(table):
                "SELECT count(*) AS count FROM \(table.rawValue) WHERE thread_id = ?"
            case .metadata:
                "SELECT * FROM local_thread_catalog_metadata WHERE id = 1"
            case .localSync:
                "SELECT * FROM local_thread_catalog_sync_state WHERE host_id = 'local'"
            }
        }
    }
}

private func codexGhostRepairSnapshotAuthorize(
    _ context: UnsafeMutableRawPointer?,
    _ actionCode: Int32,
    _ parameterOne: UnsafePointer<CChar>?,
    _ parameterTwo: UnsafePointer<CChar>?,
    _ databaseName: UnsafePointer<CChar>?,
    _ triggerName: UnsafePointer<CChar>?
) -> Int32 {
    _ = context
    _ = databaseName
    _ = triggerName
    return CodexGhostRepairSnapshotAuthorizer.decision(
        actionCode: actionCode,
        parameterOne: parameterOne.map(String.init(cString:)),
        parameterTwo: parameterTwo.map(String.init(cString:))
    )
}
#endif
