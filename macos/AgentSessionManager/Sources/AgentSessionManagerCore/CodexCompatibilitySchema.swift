import CSQLite3
import Foundation

struct CodexCompatibilitySchema {
    let browsing: Bool
    let archive: Bool
    let restore: Bool
    let delete: Bool

    static func read(directory: URL) throws -> Self {
        func document(_ name: String) -> [String: Any] {
            let url = directory.appendingPathComponent("v2/\(name).json")
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true, let count = values.fileSize, count <= 8_000_000,
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return json
        }
        func idOnly(_ document: [String: Any]) -> Bool {
            let properties = document["properties"] as? [String: [String: Any]] ?? [:]
            return document["type"] as? String == "object"
                && Set(properties.keys) == ["threadId"]
                && document["required"] as? [String] == ["threadId"]
                && properties["threadId"]?["type"] as? String == "string"
        }
        func lifecycle(_ prefix: String, restores: Bool = false) -> Bool {
            guard idOnly(document("\(prefix)Params")), idOnly(document("\(prefix)dNotification")) else { return false }
            let response = document("\(prefix)Response")
            let properties = response["properties"] as? [String: [String: Any]] ?? [:]
            guard response["type"] as? String == "object" else { return false }
            if restores {
                return Set(properties.keys) == ["thread"] && response["required"] as? [String] == ["thread"]
                    && properties["thread"]?["$ref"] as? String == "#/definitions/Thread"
                    && threadDecoder(response)
            }
            return properties.isEmpty && (response["required"] as? [String] ?? []).isEmpty
        }
        let list = document("ThreadListResponse")
        let listParams = document("ThreadListParams")
        let read = document("ThreadReadResponse")
        let properties = list["properties"] as? [String: [String: Any]] ?? [:]
        let readProperties = read["properties"] as? [String: [String: Any]] ?? [:]
        let browsing = threadDecoder(list) && threadDecoder(read)
            && properties["data"]?["type"] as? String == "array"
            && (properties["data"]?["items"] as? [String: Any])?["$ref"] as? String == "#/definitions/Thread"
            && readProperties["thread"]?["$ref"] as? String == "#/definitions/Thread"
            && listParams["type"] as? String == "object"
        return .init(browsing: browsing, archive: lifecycle("ThreadArchive"),
                     restore: lifecycle("ThreadUnarchive", restores: true), delete: lifecycle("ThreadDelete"))
    }

    static func threadDecoder(_ document: [String: Any]) -> Bool {
        let definitions = document["definitions"] as? [String: [String: Any]] ?? [:]
        let thread = definitions["Thread"] ?? [:]
        let properties = thread["properties"] as? [String: [String: Any]] ?? [:]
        let expected = ["id": "string", "sessionId": "string", "preview": "string", "ephemeral": "boolean",
                        "modelProvider": "string", "createdAt": "integer", "updatedAt": "integer", "cliVersion": "string"]
        let required = Set(thread["required"] as? [String] ?? [])
        guard required.isSuperset(of: Set(expected.keys).union(["status", "cwd"])),
              expected.allSatisfy({ properties[$0.key]?["type"] as? String == $0.value }),
              (properties["status"]?["allOf"] as? [[String: String]])?.first?["$ref"] == "#/definitions/ThreadStatus",
              (properties["cwd"]?["allOf"] as? [[String: String]])?.first?["$ref"] == "#/definitions/AbsolutePathBuf",
              let statuses = definitions["ThreadStatus"]?["oneOf"] as? [[String: Any]], !statuses.isEmpty else { return false }
        for key in ["parentThreadId", "name"] where properties[key] != nil {
            guard Set(properties[key]?["type"] as? [String] ?? []) == ["string", "null"] else { return false }
        }
        return statuses.allSatisfy {
            ($0["required"] as? [String] ?? []).contains("type")
                && ($0["properties"] as? [String: [String: Any]])?["type"]?["type"] as? String == "string"
        }
    }
}

enum CodexCompatibilityDatabase {
    struct Metadata {
        let fingerprint: String
        let userVersion: Int32
        let desktopProfile: String?
        let check: CodexCompatibilityDatabaseCheck?
        var readMethod = "sqliteReadOnly"
    }

    static func metadata(at url: URL) throws -> Metadata {
        do {
            do { return try readMetadata(at: url) }
            catch let failure as CodexCompatibilityReadFailure {
                guard failure.source == .sqlite, failure.code & 255 == SQLITE_CANTOPEN,
                      CodexCompatibilitySidecars.read(at: url).allMissing else { throw failure }
                // The failed connection has closed before taking an independent lock.
                return try CodexCompatibilitySingleFileRead.withLock(at: url) {
                    var result = try readMetadata(at: url, lockedSingleFile: true)
                    result.readMethod = "lockedSingleFile"
                    return result
                }
            }
        } catch var failure as CodexCompatibilityReadFailure {
            failure.sidecars = .read(at: url)
            throw failure
        }
    }

    private static func readMetadata(at url: URL, lockedSingleFile: Bool = false) throws -> Metadata {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) }
        catch { throw CodexCompatibilityReadFailure.fileError(error) }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw CodexCompatibilityReadFailure(stage: .fileValidation, source: .validation, code: 0)
        }
        var database: OpaquePointer?
        var location = url.path
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if lockedSingleFile {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "mode", value: "ro"), .init(name: "immutable", value: "1")]
            location = components.string!
            flags |= SQLITE_OPEN_URI
        }
        let opened = sqlite3_open_v2(location, &database, flags, nil)
        defer { sqlite3_close(database) }
        func failure(_ stage: CodexCompatibilityReadFailure.Stage, fallback: Int32 = SQLITE_ERROR) -> CodexCompatibilityReadFailure {
            .init(stage: stage, source: .sqlite, code: Int(database.map { sqlite3_extended_errcode($0) } ?? fallback),
                  systemCode: database.map { Int(sqlite3_system_errno($0)) })
        }
        guard opened == SQLITE_OK, let database else { throw failure(.open, fallback: opened) }
        sqlite3_busy_timeout(database, 1_000)
        // Hold one read transaction so concurrent migrations cannot mix schemas.
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw failure(.transaction) }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        func rows(_ sql: String) throws -> [[String?]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw failure(.prepare)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_stmt_readonly(statement) == 1 else {
                throw CodexCompatibilityReadFailure(stage: .readOnly, source: .validation, code: 0)
            }
            var result: [[String?]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw failure(.step, fallback: status) }
                guard result.count < 10_000 else {
                    throw CodexCompatibilityReadFailure(stage: .rowLimit, source: .validation, code: 10_000)
                }
                result.append((0..<sqlite3_column_count(statement)).map {
                    sqlite3_column_text(statement, $0).map { String(cString: $0) }
                })
            }
        }
        let versions = try rows("PRAGMA user_version")
        guard let version = versions.first?.first.flatMap({ $0 }).flatMap(Int32.init) else {
            throw CodexCompatibilityReadFailure(stage: .version, source: .validation, code: 0)
        }
        let schema = try rows("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
        let fingerprint = CodexCompatibilityInspector.hash(try JSONEncoder().encode(versions + schema))
        let kind = CodexGhostRepairSnapshotAnalysisDatabase.allCases.first { $0.canonicalFile.rawValue == url.lastPathComponent }
        let check = try kind.map { kind in
            CodexCompatibilityDatabaseCheck(database: kind,
                issue: try CodexCompatibilityDatabaseContract.issue(database: kind, version: version, rows: rows))
        }
        let profileID = kind == .desktop && check?.issue == nil
            ? CodexGhostRepairDatabaseSchemaProfile.admitted(desktopUserVersion: version)?.identifier : nil
        return .init(fingerprint: fingerprint, userVersion: version, desktopProfile: profileID, check: check)
    }
}
