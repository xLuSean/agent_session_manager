import Foundation
import CSQLite3

/// Read-only adapter for the audited 0.153.4 empty-preview listing gap.
/// A local row discovers an ID; only a matching official read admits it.
enum CodexUnlistedSessionInventory {
    static let maximumCandidates = 1_000

    struct Row: Equatable {
        let id: String
        let archived: Bool
        let rolloutPath: String
        let cwd: String
        let source: String
        let threadSource: String
        let pinned: Bool
        let childCount: Int
    }

    struct Result {
        var active: [CodexThreadRecord] = []
        var archived: [CodexThreadRecord] = []
    }

    static func collect(
        home: URL,
        runtimeVersion: String?,
        active: [CodexThreadRecord],
        archived: [CodexThreadRecord],
        read: (String) throws -> CodexThreadRecord
    ) throws -> Result {
        guard runtimeVersion == "0.153.4" else { return Result() }
        let before = try candidates(home: home)
        let listed = Set((active + archived).map(\.id))
        var result = Result()
        for row in before where !listed.contains(row.id) {
            try validateRollout(row.rolloutPath, threadID: row.id, home: home)
            var record = try read(row.id)
            guard record.id == row.id, record.sessionId == row.id,
                  !record.ephemeral, record.cwd == row.cwd,
                  record.isPinned == nil || record.isPinned == row.pinned else {
                throw invalid("Official/local identity or pin evidence disagrees.")
            }
            // A persisted explicit pin value is not the same as assuming an
            // omitted official value means false. Desktop pin checks still apply.
            record.isPinned = row.pinned
            record.localSupplement = .init(
                label: row.source == "vscode" && row.threadSource == "automation"
                    ? "Desktop automation · local supplement" : "Local supplement · official ID verified",
                hasCanonicalChildren: row.childCount > 0
            )
            if row.archived { result.archived.append(record) }
            else { result.active.append(record) }
        }
        guard try candidates(home: home) == before else {
            throw invalid("Local session metadata changed during official readback.")
        }
        return result
    }

    static func candidates(home: URL) throws -> [Row] {
        try withDatabase(home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("state_5.sqlite")) { db in
            let sql = """
                SELECT id, archived, rollout_path, cwd, source, COALESCE(thread_source, ''), is_pinned,
                  (SELECT count(*) FROM thread_spawn_edges e WHERE e.parent_thread_id = threads.id)
                FROM threads WHERE preview = '' AND source IN ('cli', 'vscode')
                ORDER BY id LIMIT \(maximumCandidates + 1)
                """
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            var rows: [Row] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw invalid("Local inventory read failed.") }
                let id = string(statement, 0)
                let archived = sqlite3_column_int(statement, 1)
                let pinned = sqlite3_column_int(statement, 6)
                guard UUID(uuidString: id)?.uuidString.lowercased() == id,
                      sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                      sqlite3_column_type(statement, 6) == SQLITE_INTEGER,
                      [0, 1].contains(archived), [0, 1].contains(pinned) else {
                    throw invalid("Unsupported local session metadata.")
                }
                rows.append(Row(id: id, archived: archived == 1, rolloutPath: string(statement, 2),
                                cwd: string(statement, 3), source: string(statement, 4),
                                threadSource: string(statement, 5), pinned: pinned == 1,
                                childCount: Int(sqlite3_column_int64(statement, 7))))
            }
            guard rows.count <= maximumCandidates else { throw invalid("Local inventory exceeded its bound.") }
            return rows
        }
    }

    /// An official not-loaded error alone is insufficient when a canonical row
    /// or an old rollout still exists. This never removes or repairs either one.
    static func verifyLocalAbsence(home: URL, threadID: String) throws {
        guard UUID(uuidString: threadID)?.uuidString.lowercased() == threadID else {
            throw invalid("Invalid exact session ID.")
        }
        try withDatabase(home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("state_5.sqlite")) { db in
            let statement = try prepare(db, "SELECT count(*) FROM threads WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            _ = threadID.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_int64(statement, 0) == 0 else {
                throw invalid("Canonical session data still exists; deletion is not verified.")
            }
        }
        let root = home.standardizedFileURL.resolvingSymlinksInPath()
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: directory.path) }
            catch CocoaError.fileReadNoSuchFile { continue }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  directory.resolvingSymlinksInPath() == directory else {
                throw invalid("Rollout directory is unavailable or a symbolic link.")
            }
            var readFailed = false
            guard let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey],
                errorHandler: { _, _ in readFailed = true; return false }
            ) else { throw invalid("Rollout inventory unavailable.") }
            var count = 0
            for case let file as URL in files {
                count += 1
                guard count <= 100_000,
                      try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw invalid("Rollout inventory is incomplete or contains a symbolic link.")
                }
                if file.lastPathComponent.contains(threadID) {
                    throw invalid("A session rollout still exists; deletion is not verified.")
                }
            }
            if readFailed { throw invalid("Rollout inventory read failed.") }
        }
    }

    private static func validateRollout(_ path: String, threadID: String, home: URL) throws {
        let root = home.standardizedFileURL.resolvingSymlinksInPath()
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), file.resolvingSymlinksInPath() == file,
              file.pathExtension == "jsonl", file.lastPathComponent.contains(threadID),
              ["sessions", "archived_sessions"].contains(where: {
                  file.path.hasPrefix(root.appendingPathComponent($0).path + "/")
              }), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw invalid("The local rollout is missing or outside the supported session path/naming contract.")
        }
    }

    private static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let file = url.standardizedFileURL
        guard file.resolvingSymlinksInPath() == file,
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw invalid("Canonical database is unavailable or linked elsewhere.")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw invalid("Could not open canonical database read-only.")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_db_readonly(db, "main") == 1 else { throw invalid("Database is not read-only.") }
        sqlite3_busy_timeout(db, 1_000)
        return try body(db)
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw invalid("Required canonical schema is unavailable.")
        }
        return statement
    }

    private static func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private static func invalid(_ message: String) -> CodexAppServerError {
        .malformedResponse("Unlisted session check: \(message)")
    }
}

struct CodexLocalInventorySupplement: Codable, Hashable, Sendable {
    let label: String
    let hasCanonicalChildren: Bool
}
