import Foundation

/// Inspects SQLite metadata only. SQL literals derived from metadata are quoted;
/// schema SQL is never executed and no application table is selected.
enum CodexCompatibilityDatabaseContract {
    typealias Rows = (String) throws -> [[String?]]

    static func issue(database: CodexGhostRepairSnapshotAnalysisDatabase, version: Int32,
                      rows: Rows) throws -> CodexCompatibilityDatabaseIssue? {
        let profile = CodexGhostRepairDatabaseSchemaProfile.admitted(desktopUserVersion: version)
        if database == .desktop {
            guard profile != nil else { return .version }
        } else {
            guard CodexGhostRepairDatabaseSchemaProfile.desktopV34.databaseVersions[database] == version else { return .version }
        }
        let tables = try rows("PRAGMA table_list").filter { $0.count >= 6 && $0[0] == "main" }
        let names = database == .desktop ? profile!.desktopTables.map(\.table)
            : CodexGhostRepairReferencedTables.byDatabase[database, default: []].map(\.table)
        guard !names.isEmpty, names.allSatisfy({ name in
            tables.contains { $0[1] == name && $0[2] == "table" }
        }) else { return .table }
        for name in names {
            let observed = try rows("PRAGMA table_xinfo(\(literal(name)))")
            guard !observed.isEmpty, observed.allSatisfy({ $0.count >= 7 && $0[6] == "0" }) else { return .columns }
            if database == .desktop {
                let contract = profile!.desktopTables.first { $0.table == name }!
                let columns = observed.map { row in
                    CodexGhostRepairSQLiteColumnContract(name: row[1] ?? "", declaredType: (row[2] ?? "").uppercased(),
                        notNull: row[3] == "1", defaultValue: row[4], primaryKeyPosition: Int(row[5] ?? "") ?? -1)
                }
                guard columns == contract.columns else { return .columns }
                let indexes = try rows("PRAGMA index_list(\(literal(name)))")
                guard indexes.allSatisfy({ $0.count >= 5 && ["pk", "c", "u"].contains($0[3] ?? "") }) else { return .indexes }
                // The shipped timeline schema has UNIQUE(host_id, thread_id,
                // record_id). Accept that exact SQLite-generated index only.
                let automaticUnique = indexes.filter { $0[3] == "u" }
                guard automaticUnique.count <= 1 else { return .indexes }
                for row in automaticUnique {
                    guard name == "thread_timeline_ledger", row[2] == "1", row[4] == "0",
                          let indexName = row[1] else { return .indexes }
                    let info = try rows("PRAGMA index_info(\(literal(indexName)))")
                    guard info.allSatisfy({ $0.count >= 3 }),
                          info.compactMap({ $0[2] }) == ["host_id", "thread_id", "record_id"] else { return .indexes }
                }
                let custom = indexes.filter { $0[3] == "c" }
                guard Set(custom.compactMap { $0[1] }) == Set(contract.customIndexes.map(\.name)) else { return .indexes }
                for index in contract.customIndexes {
                    guard let row = custom.first(where: { $0[1] == index.name }),
                          (row[2] == "1") == index.unique, (row[4] == "1") == index.partial else { return .indexes }
                    let info = try rows("PRAGMA index_info(\(literal(index.name)))")
                    guard info.allSatisfy({ $0.count >= 3 }), info.compactMap({ $0[2] }) == index.columns else { return .indexes }
                }
            } else {
                let contract = CodexGhostRepairReferencedTables.byDatabase[database]!.first { $0.table == name }!
                let columns = observed.compactMap { $0[1] }
                guard contract.exact ? columns == contract.columns : contract.columns.allSatisfy(columns.contains) else { return .columns }
            }
        }
        if [.desktop, .summaries].contains(database) {
            guard try rows("SELECT name FROM sqlite_master WHERE type = 'trigger'").isEmpty else { return .triggers }
            // Includes referencing tables outside the selected cleanup tables.
            // Their relationships cannot be inferred from user_version alone.
            for row in tables where row[2] == "table" {
                guard let name = row[1] else { return .table }
                guard try rows("PRAGMA foreign_key_list(\(literal(name)))").isEmpty else { return .foreignKeys }
            }
        }
        return nil
    }

    private static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
