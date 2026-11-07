import Foundation

/// Exact rooted/realtime history contract. Metadata is compared with compiled
/// definitions; no SQL obtained from a user's database is ever executed.
enum CodexThreadHistoryContract {
    static let profileIdentifier = "thread-history-rooted-realtime"

    enum Query {
        case tables, objects
        case columns(String), foreignKeys(String)
        var sql: String {
            switch self {
            case .tables: return "PRAGMA table_list"
            case .objects: return "SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN ('index','trigger') AND sql IS NOT NULL ORDER BY type,name"
            case let .columns(table): return "PRAGMA table_xinfo('\(table)')"
            case let .foreignKeys(table): return "PRAGMA foreign_key_list('\(table)')"
            }
        }
    }
    typealias Rows = (Query) throws -> [[String?]]

    static func isPresent(rows: Rows) throws -> Bool {
        let tables = try rows(.tables)
        if tables.contains(where: { $0.count >= 3 && $0[0] == "main" && $0[1] == "thread_realtime_items" }) { return true }
        return try rows(.columns("thread_turns")).contains { $0.count >= 2 && $0[1] == "root_turn_id" }
    }

    static func validate(rows: Rows) throws -> CodexCompatibilityDatabaseIssue? {
        let tables = try rows(.tables).filter {
            $0.count >= 6 && $0[0] == "main" && $0[1]?.hasPrefix("sqlite_") != true && $0[1] != "_sqlx_migrations"
        }
        guard Set(tables.compactMap { $0[1] }) == Set(columns.keys),
              tables.allSatisfy({ $0[2] == "table" }) else { return .table }
        for (table, expected) in columns {
            let observed = try rows(.columns(table))
            guard observed.allSatisfy({ $0.count >= 7 && $0[6] == "0" }) else { return .columns }
            let actual = observed.map {
                CodexGhostRepairSQLiteColumnContract(name: $0[1] ?? "", declaredType: ($0[2] ?? "").uppercased(),
                    notNull: $0[3] == "1", defaultValue: $0[4], primaryKeyPosition: Int($0[5] ?? "") ?? -1)
            }
            guard actual == expected else { return .columns }
            guard try rows(.foreignKeys(table)).isEmpty else { return .foreignKeys }
        }
        let objects = try rows(.objects)
        guard objects.allSatisfy({ $0.count == 4 && $0.allSatisfy { $0 != nil } }) else { return .indexes }
        let actual = objects.map { row in row.enumerated().map { $0.offset == 3 ? normalize($0.element!) : $0.element! } }
        for type in ["index", "trigger"] {
            guard actual.filter({ $0[0] == type }) == schemaObjects.filter({ $0[0] == type }) else {
                return type == "trigger" ? .triggers : .indexes
            }
        }
        return nil
    }

    private static func normalize(_ sql: String) -> String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static let columns: [String: [CodexGhostRepairSQLiteColumnContract]] = [
        "thread_turns": [
            .init(name: "thread_id", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 1),
            .init(name: "turn_id", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 2),
            .init(name: "rollout_ordinal", declaredType: "INTEGER", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "status", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "error_json", declaredType: "TEXT", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "started_at", declaredType: "INTEGER", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "completed_at", declaredType: "INTEGER", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "duration_ms", declaredType: "INTEGER", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "first_user_item_id", declaredType: "TEXT", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "final_agent_item_id", declaredType: "TEXT", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "rollout_byte_offset", declaredType: "INTEGER", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "rollout_end_ordinal", declaredType: "INTEGER", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "rollout_end_byte_offset", declaredType: "INTEGER", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "root_turn_id", declaredType: "TEXT", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
        ],
        "thread_items": [
            .init(name: "thread_id", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 1),
            .init(name: "turn_id", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 2),
            .init(name: "item_id", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 3),
            .init(name: "rollout_ordinal", declaredType: "INTEGER", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "created_at_ms", declaredType: "INTEGER", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "item_json", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "item_type", declaredType: "TEXT", notNull: true, defaultValue: "''", primaryKeyPosition: 0),
            .init(name: "updated_at_ordinal", declaredType: "INTEGER", notNull: true, defaultValue: "0", primaryKeyPosition: 0),
            .init(name: "started_at_ms", declaredType: "INTEGER", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "completed_at_ms", declaredType: "INTEGER", notNull: false, defaultValue: nil, primaryKeyPosition: 0),
        ],
        "thread_history_projection_state": [
            .init(name: "thread_id", declaredType: "TEXT", notNull: false, defaultValue: nil, primaryKeyPosition: 1),
            .init(name: "next_rollout_byte_offset", declaredType: "INTEGER", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "next_rollout_ordinal", declaredType: "INTEGER", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
        ],
        "thread_realtime_items": [
            .init(name: "thread_id", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 1),
            .init(name: "item_id", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 2),
            .init(name: "rollout_ordinal", declaredType: "INTEGER", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "created_at_ms", declaredType: "INTEGER", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "item_type", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
            .init(name: "item_json", declaredType: "TEXT", notNull: true, defaultValue: nil, primaryKeyPosition: 0),
        ],
    ]

    // Includes index predicates and the exact thread-scoped projection trigger.
    static let schemaObjects: [[String]] = [
        ["index", "idx_thread_items_by_turn_page", "thread_items", "CREATE INDEX idx_thread_items_by_turn_page ON thread_items(thread_id, turn_id, rollout_ordinal)"],
        ["index", "idx_thread_items_by_turn_updated_page", "thread_items", "CREATE INDEX idx_thread_items_by_turn_updated_page ON thread_items(thread_id, turn_id, updated_at_ordinal)"],
        ["index", "idx_thread_items_page", "thread_items", "CREATE UNIQUE INDEX idx_thread_items_page ON thread_items(thread_id, rollout_ordinal)"],
        ["index", "idx_thread_items_updated_page", "thread_items", "CREATE INDEX idx_thread_items_updated_page ON thread_items(thread_id, updated_at_ordinal)"],
        ["index", "idx_thread_items_user_messages", "thread_items", "CREATE INDEX idx_thread_items_user_messages ON thread_items(thread_id, rollout_ordinal) WHERE item_type = 'userMessage'"],
        ["index", "idx_thread_realtime_items_boundary", "thread_realtime_items", "CREATE INDEX idx_thread_realtime_items_boundary ON thread_realtime_items(thread_id, rollout_ordinal) WHERE item_type IN ('realtime_session_started', 'realtime_session_closed')"],
        ["index", "idx_thread_realtime_items_page", "thread_realtime_items", "CREATE UNIQUE INDEX idx_thread_realtime_items_page ON thread_realtime_items(thread_id, rollout_ordinal)"],
        ["index", "idx_thread_turns_end_page", "thread_turns", "CREATE INDEX idx_thread_turns_end_page ON thread_turns(thread_id, rollout_end_ordinal, turn_id) WHERE rollout_end_ordinal IS NOT NULL"],
        ["index", "idx_thread_turns_page", "thread_turns", "CREATE UNIQUE INDEX idx_thread_turns_page ON thread_turns(thread_id, rollout_ordinal)"],
        ["trigger", "thread_realtime_items_projection_cleanup", "thread_history_projection_state", "CREATE TRIGGER thread_realtime_items_projection_cleanup AFTER DELETE ON thread_history_projection_state BEGIN DELETE FROM thread_realtime_items WHERE thread_id = OLD.thread_id; END"],
    ]
}
