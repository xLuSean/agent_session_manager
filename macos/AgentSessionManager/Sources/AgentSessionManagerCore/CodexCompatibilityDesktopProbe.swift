import Foundation

/// A synthetic SQL self-test, not Desktop runtime acceptance. It never accepts a
/// source path or copies rows/schema SQL from the user's databases. The production
/// transaction's SQL is exercised against compiled, recognized table contracts.
enum CodexCompatibilityDesktopProbe {
    enum Scenario: CaseIterable {
        case mixedSuccess, summaryInterruption, summaryDrift, catalogDrift, authorityDrift
    }
    enum Failure: Error { case mismatch, backupMismatch }

    static func run(profileIdentifier: String?) throws -> CodexCompatibilityBehaviorResult {
        guard let profile = CodexGhostRepairDatabaseSchemaProfile.admittedProfiles.first(where: {
            $0.identifier == profileIdentifier
        }) else {
            return .init(feature: .desktopCleanup, status: .notTested,
                         detail: "A recognized Desktop schema is required for the synthetic SQL test. No private database was changed.")
        }
        do {
            for scenario in Scenario.allCases {
                try Task.checkCancellation()
                try verify(profile: profile, scenario: scenario, onDisk: true)
            }
            return .init(feature: .desktopCleanup, status: .passed,
                         detail: "Synthetic cleanup self-test passed: disk backup readback, selected residue, preserved conversations and automation settings, rollback, cold reopen and restore into a separate test copy were checked. This does not test the Desktop application, the live backup pipeline or crash recovery, and does not unlock new Desktop versions.")
        } catch is CancellationError { throw CancellationError() }
        catch {
            return .init(feature: .desktopCleanup, status: .failed,
                         detail: "The synthetic Desktop SQL self-test failed. No private database was opened or changed. New Desktop versions remain restricted.")
        }
    }

    static func verify(profile: CodexGhostRepairDatabaseSchemaProfile, scenario: Scenario,
                       onDisk: Bool = false, corruptBackup: Bool = false) throws {
        let workspace = try onDisk ? CodexCompatibilityDesktopDiskWorkspace() : nil
        defer { workspace?.dispose() }
        var database = try CodexGhostRepairProductionSQLite(inMemory: ())
        defer { database.close() }
        // Identifiers and definitions below come only from compiled contracts.
        for table in profile.desktopTables {
            var definitions = table.columns.map { column in
                "\"\(column.name)\" \(column.declaredType)"
                    + (column.notNull ? " NOT NULL" : "")
                    + (column.defaultValue.map { " DEFAULT \($0)" } ?? "")
            }
            let primary = table.columns.filter { $0.primaryKeyPosition > 0 }.sorted { $0.primaryKeyPosition < $1.primaryKeyPosition }
            if !primary.isEmpty { definitions.append("PRIMARY KEY (" + primary.map { "\"\($0.name)\"" }.joined(separator: ",") + ")") }
            try database.execute("CREATE TABLE \(table.table) (\(definitions.joined(separator: ",")))")
            // Index predicates are not modeled by these column contracts. This
            // probe tests row effects, not indexes or arbitrary schema SQL.
        }
        try database.execute("ATTACH DATABASE ':memory:' AS reviewed_summaries")
        // This is deliberately a SQL projection, not a claim of full summaries
        // schema acceptance. Production schema validation remains independent.
        try database.execute("CREATE TABLE reviewed_summaries.thread_turn_summaries (thread_id TEXT, summary TEXT)")
        let ordinary = "asm-probe-ordinary", automated = "asm-probe-automation"
        let runOnly = "asm-probe-run-only", kept = "asm-probe-kept"
        for id in [ordinary, automated, kept] {
            try seed(database, profile: profile, table: "local_thread_catalog", values: ["host_id": .text("local"), "thread_id": .text(id)])
        }
        try seed(database, profile: profile, table: "local_thread_catalog", values: ["host_id": .text("remote"), "thread_id": .text(ordinary)])
        for id in [automated, runOnly, kept] {
            try seed(database, profile: profile, table: "automation_runs", values: [
                "thread_id": .text(id), "automation_id": .text("asm-probe-definition"), "status": .text("PENDING_REVIEW"),
            ])
        }
        for table in ["automations", "inbox_items", "thread_timeline_ledger"] {
            try seed(database, profile: profile, table: table, values: [:])
        }
        try seed(database, profile: profile, table: "local_thread_catalog_metadata", values: ["id": .integer(1), "catalog_revision": .integer(10)])
        for host in ["local", "remote"] {
            try seed(database, profile: profile, table: "local_thread_catalog_sync_state", values: ["host_id": .text(host), "observation_sequence": .integer(20)])
        }
        for id in [automated, kept] {
            try database.execute("INSERT INTO reviewed_summaries.thread_turn_summaries VALUES (?, ?)", bindings: [.text(id), .text("synthetic summary")])
        }
        let tables = profile.desktopTables.map(\.table) + ["reviewed_summaries.thread_turn_summaries"]
        func snapshot() throws -> [[CodexGhostRepairSQLiteRow]] {
            try tables.map { try database.query("SELECT * FROM \($0) ORDER BY rowid", maximumRows: 100) }
        }
        let before = try snapshot()
        if let workspace {
            try workspace.materialize(database)
            database.close()
            try workspace.backup(corruptForTest: corruptBackup)
            // Validate both the exact bytes and a cold read of both databases
            // before any cleanup transaction starts.
            database = try workspace.openBackup()
            guard try snapshot() == before else { throw Failure.mismatch }
            database.close()
            database = try workspace.openWorking()
        }
        let targets: [CodexGhostRepairBulkSQLCleanup.Target] = [
            .init(threadID: automated, effect: .removeCatalogRowAndArchiveAutomation, summaryCount: scenario == .summaryDrift ? 2 : 1),
            .init(threadID: scenario == .catalogDrift ? "asm-probe-missing" : ordinary, effect: .removeCatalogRow, summaryCount: 0),
            .init(threadID: runOnly, effect: .archiveAutomation, summaryCount: 0),
            .init(threadID: "asm-probe-already-absent", effect: .alreadyAbsent, summaryCount: 0),
        ]
        try database.execute("BEGIN IMMEDIATE")
        var failed = false
        do {
            try CodexGhostRepairBulkSQLCleanup.apply(database: database, targets: targets,
                catalogRevision: scenario == .authorityDrift ? 999 : 10, observationSequence: 20,
                executionAtMilliseconds: 100, failAfterSummaryRemoval: scenario == .summaryInterruption)
            try database.execute("COMMIT")
        } catch {
            failed = true
            try database.execute("ROLLBACK")
        }
        guard failed == (scenario != .mixedSuccess) else { throw Failure.mismatch }
        if let workspace {
            database.close()
            database = try workspace.openWorking()
        }
        let after = try snapshot()
        if failed {
            guard after == before else { throw Failure.mismatch }
        } else {
            for (index, table) in tables.enumerated() {
                let expected = before[index].compactMap { row -> CodexGhostRepairSQLiteRow? in
                    let id = row.value(named: "thread_id")
                    if table == "local_thread_catalog", row.value(named: "host_id") == .text("local"),
                       [ordinary, automated].contains(where: { id == .text($0) }) { return nil }
                    if table == "reviewed_summaries.thread_turn_summaries", id == .text(automated) { return nil }
                    let changes: [String: CodexGhostRepairSQLiteValue]
                    if table == "automation_runs", [automated, runOnly].contains(where: { id == .text($0) }) {
                        changes = ["status": .text("ARCHIVED"), "archived_reason": .text("auto"), "updated_at": .integer(100)]
                    } else if table == "local_thread_catalog_metadata" {
                        changes = ["catalog_revision": .integer(12)]
                    } else if table == "local_thread_catalog_sync_state", row.value(named: "host_id") == .text("local") {
                        changes = ["observation_sequence": .integer(22)]
                    } else { changes = [:] }
                    return .init(fields: row.fields.map { .init(name: $0.name, value: changes[$0.name] ?? $0.value) })
                }
                guard after[index] == expected else { throw Failure.mismatch }
            }
        }
        guard try database.integrityPassed(), try database.foreignKeyViolationCount() == 0 else { throw Failure.mismatch }
        if let workspace {
            database.close()
            database = try workspace.restoreIntoSeparateCopy()
            guard try snapshot() == before, try database.integrityPassed() else { throw Failure.mismatch }
        }
    }

    private static func seed(_ database: CodexGhostRepairProductionSQLite,
                             profile: CodexGhostRepairDatabaseSchemaProfile, table: String,
                             values: [String: CodexGhostRepairProductionSQLiteBinding]) throws {
        guard let contract = profile.desktopTables.first(where: { $0.table == table }) else { throw Failure.mismatch }
        let bindings = contract.columns.map { column in
            values[column.name] ?? (column.declaredType.uppercased().contains("INT") ? .integer(1) : .text("asm-probe-\(column.name)"))
        }
        try database.execute("INSERT INTO \(table) VALUES (\(bindings.map { _ in "?" }.joined(separator: ",")))", bindings: bindings)
    }
}
