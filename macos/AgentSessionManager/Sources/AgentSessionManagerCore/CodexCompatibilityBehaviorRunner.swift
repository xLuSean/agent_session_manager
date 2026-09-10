import CryptoKit
import CSQLite3
import Darwin
import Foundation

/// No caller-supplied home or target ID. Every mutation is confined to a newly
/// created, credential-free home and to the ID returned by its own thread/start.
enum CodexCompatibilityBehaviorRunner {
    static func run(executable: URL, expectedSHA256: String,
                    feature: CodexCompatibilityFeature) throws -> CodexCompatibilityBehaviorResult {
        guard [.archiveRestore, .officialDelete].contains(feature) else { throw Failure.contract }
        // A canonical direct temporary root avoids /var vs /private/var aliases
        // between creation replies and persisted App Server working directories.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("asm-behavior-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var disposal = ""
        var stage = "isolated startup"
        let outcome: CodexCompatibilityBehaviorResult
        do {
            let copy = root.appendingPathComponent("runtime")
            try FileManager.default.copyItem(at: executable.resolvingSymlinksInPath(), to: copy)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: copy.path)
            guard try digest(copy) == expectedSHA256 else { throw Failure.changed }
            for name in ["codex", "project"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
            }
            let context = Context(root: root, executable: copy, sha256: expectedSHA256)
            try context.verifyInventory(id: nil, archived: false)
            stage = "test conversation creation"
            let id = try context.create { stage = $0 }
            stage = "persisted test conversation readback"
            try context.verifyInventory(id: id, archived: false)
            stage = "test conversation file and database persistence"
            try context.verifyLocalPresence(id: id)
            stage = "archive and fresh readback"
            try context.mutate("thread/archive", id: id)
            try context.verifyInventory(id: id, archived: true)
            if feature == .archiveRestore {
                stage = "restore and fresh readback"
                try context.mutate("thread/unarchive", id: id)
                try context.verifyInventory(id: id, archived: false)
            } else {
                stage = "delete and absence verification"
                try context.mutate("thread/delete", id: id)
                try context.verifyInventory(id: nil, archived: false)
                try context.withRPC { rpc in
                    do {
                        _ = try rpc.call("thread/read", ["threadId": id, "includeTurns": false])
                        throw Failure.contract
                    } catch let error as RPCError {
                        guard error.code == -32600, error.message == "thread not loaded: \(id)" else { throw Failure.contract }
                    }
                }
                // A list omission alone is insufficient: require canonical data
                // and every known rollout file to be absent in this test home.
                try context.verifyPaths()
                try CodexUnlistedSessionInventory.verifyLocalAbsence(home: context.home, threadID: id)
            }
            guard try digest(copy) == expectedSHA256 else { throw Failure.changed }
            try Task.checkCancellation()
            outcome = .init(feature: feature, status: .passed,
                detail: feature == .archiveRestore
                    ? "The isolated test session was archived and restored; fresh processes verified each state."
                    : "The isolated test session was deleted; fresh list, exact-ID and local file/database checks verified absence.")
        } catch is CancellationError {
            _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
            throw CancellationError()
        } catch {
            // Never persist raw provider messages, payloads, IDs or temporary paths.
            let reason = (error as? Failure)?.summary ?? "Response or persistence checks failed."
            outcome = .init(feature: feature, status: .failed,
                detail: "Could not verify \(stage). \(reason) No real sessions were touched and no operation was retried.")
        }
        do { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        catch { disposal = " Temporary test files could not be moved to Trash (\(root.lastPathComponent))." }
        return .init(feature: feature, status: outcome.status, detail: outcome.detail + disposal)
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum Failure: Error {
        case contract, changed, timeout, outputLimit, pagination, decoding, canonicalRow, databasePath, databaseOpen, databaseSchema
        case inventoryCount(expected: Int, actual: Int)
        case rolloutCheck(String)
        var summary: String {
            switch self {
            case .contract: "The response did not match the required identity or state."
            case .changed: "The test executable changed."
            case .timeout: "The test runtime did not respond in time."
            case .outputLimit: "The test output exceeded its limit."
            case .pagination: "The inventory format changed or has more pages."
            case .decoding: "The conversation response format changed."
            case .canonicalRow: "The test conversation was not persisted in the expected canonical database row."
            case let .rolloutCheck(check): "The test rollout failed its \(check) check."
            case .databasePath: "The test canonical database is missing or reached through an unexpected path."
            case .databaseOpen: "The test canonical database could not be opened read-only."
            case .databaseSchema: "The test canonical database does not expose the expected threads and rollout_path fields."
            case let .inventoryCount(expected, actual): "Expected \(expected) test conversations in this collection; found \(actual)."
            }
        }
    }
    private struct RPCError: Error { let code: Int; let message: String }

    private struct Context {
        let root: URL
        let executable: URL
        let sha256: String
        var home: URL { root.appendingPathComponent("codex") }
        var project: String { root.appendingPathComponent("project").path }

        func verifyPaths() throws {
            for directory in [root, home, root.appendingPathComponent("project")] {
                guard directory.standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL,
                      try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                      try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure.contract }
            }
        }

        func withRPC<T>(_ body: (RPC) throws -> T) throws -> T {
            try Task.checkCancellation()
            try verifyPaths()
            guard try digest(executable) == sha256 else { throw Failure.changed }
            let rpc = try RPC(executable: executable, root: root)
            defer { rpc.stop() }
            let initialized = try rpc.call("initialize", ["clientInfo": [
                "name": "agent_session_manager_compatibility", "version": "1.0"]])
            try verifyPaths()
            guard let observed = initialized["codexHome"] as? String,
                  URL(fileURLWithPath: observed).standardizedFileURL.resolvingSymlinksInPath()
                    == home.standardizedFileURL.resolvingSymlinksInPath() else { throw Failure.contract }
            try rpc.send(["method": "initialized", "params": [:] as [String: Any]])
            return try body(rpc)
        }

        func create(updateStage: (String) -> Void) throws -> String {
            try withRPC { rpc in
                updateStage("thread creation response")
                let response = try rpc.call("thread/start", ["approvalPolicy": "never", "cwd": project,
                    "ephemeral": false, "sandbox": "read-only", "sessionStartSource": "startup", "threadSource": "cli"])
                let record = try thread(response)
                guard UUID(uuidString: record.id)?.uuidString.lowercased() == record.id,
                      record.cwd == project, !record.ephemeral, record.parentThreadId == nil else { throw Failure.contract }
                updateStage("test turn startup")
                let start = try rpc.call("turn/start", ["threadId": record.id, "cwd": project, "approvalPolicy": "never",
                    "input": [["type": "text", "text": "ASM isolated compatibility test. No tools are needed."]]])
                guard let turn = start["turn"] as? [String: Any], let turnID = turn["id"] as? String, !turnID.isEmpty else {
                    throw Failure.contract
                }
                // With no credentials or network a turn should fail. Otherwise
                // interrupt once, then require the terminal event before proceeding.
                let naturalEnd = Date().addingTimeInterval(4)
                updateStage("test turn completion")
                while rpc.terminal(thread: record.id, turn: turnID) == nil {
                    do { _ = try rpc.next(deadline: naturalEnd) }
                    catch Failure.timeout { break }
                }
                if rpc.terminal(thread: record.id, turn: turnID) == nil {
                    updateStage("test turn interrupt acknowledgement")
                    _ = try rpc.call("turn/interrupt", ["threadId": record.id, "turnId": turnID])
                    updateStage("test turn terminal event")
                    let end = Date().addingTimeInterval(3)
                    while rpc.terminal(thread: record.id, turn: turnID) == nil { _ = try rpc.next(deadline: end) }
                }
                guard let status = rpc.terminal(thread: record.id, turn: turnID),
                      ["failed", "interrupted"].contains(status) else { throw Failure.contract }
                return record.id
            }
        }

        func mutate(_ method: String, id: String) throws {
            guard ["thread/archive", "thread/unarchive", "thread/delete"].contains(method), UUID(uuidString: id) != nil else {
                throw Failure.contract
            }
            try withRPC { rpc in
                let result = try rpc.call(method, ["threadId": id])
                if method == "thread/unarchive" {
                    let restored = try thread(result)
                    guard restored.id == id, restored.cwd == project else { throw Failure.contract }
                } else if !result.isEmpty { throw Failure.contract }
            }
        }

        func verifyInventory(id: String?, archived: Bool) throws {
            try withRPC { rpc in
                for state in [false, true] {
                    let result = try rpc.call("thread/list", ["archived": state, "limit": 10,
                        "sourceKinds": [] as [String], "sortKey": "updated_at", "sortDirection": "desc", "cursor": NSNull()])
                    guard let rows = result["data"] as? [[String: Any]],
                          result["nextCursor"] is NSNull else { throw Failure.pagination }
                    let records: [CodexThreadRecord]
                    do { records = try rows.map { try JSONDecoder().decode(CodexThreadRecord.self,
                        from: JSONSerialization.data(withJSONObject: $0)) } }
                    catch { throw Failure.decoding }
                    let expected = id != nil && state == archived ? 1 : 0
                    guard records.count == expected else { throw Failure.inventoryCount(expected: expected, actual: records.count) }
                    if let id, state == archived {
                        guard records.count == 1, records[0].id == id, records[0].cwd == project,
                              records[0].parentThreadId == nil, !records[0].ephemeral else { throw Failure.contract }
                    } else if !records.isEmpty { throw Failure.contract }
                }
                if let id {
                    let read = try thread(rpc.call("thread/read", ["threadId": id, "includeTurns": false]))
                    guard read.id == id, read.cwd == project else { throw Failure.contract }
                }
            }
        }

        func verifyLocalPresence(id: String) throws {
            try verifyPaths()
            let database = home.appendingPathComponent("state_5.sqlite").standardizedFileURL
            guard database.resolvingSymlinksInPath() == database,
                  try database.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.databasePath }
            var db: OpaquePointer?
            guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }; throw Failure.databaseOpen
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1_000)
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE id = ?", -1, &query, nil) == SQLITE_OK,
                  let query else { throw Failure.databaseSchema }
            defer { sqlite3_finalize(query) }
            _ = id.withCString { sqlite3_bind_text(query, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard sqlite3_step(query) == SQLITE_ROW, let bytes = sqlite3_column_text(query, 0) else { throw Failure.canonicalRow }
            let file = URL(fileURLWithPath: String(cString: bytes)).standardizedFileURL
            guard file.resolvingSymlinksInPath() == file else { throw Failure.rolloutCheck("canonical path") }
            // Foundation shortens existing /private/tmp paths to /tmp. Compare
            // both sides in the same representation, preserving the directory boundary.
            let sessions = home.appendingPathComponent("sessions").standardizedFileURL
            guard file.path.hasPrefix(sessions.path + "/") else { throw Failure.rolloutCheck("isolated location") }
            guard file.lastPathComponent.contains(id), file.pathExtension == "jsonl" else { throw Failure.rolloutCheck("session filename") }
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.rolloutCheck("regular file") }
            guard sqlite3_step(query) == SQLITE_DONE else { throw Failure.rolloutCheck("unique database row") }
        }

        private func thread(_ result: [String: Any]) throws -> CodexThreadRecord {
            guard let value = result["thread"] as? [String: Any] else { throw Failure.contract }
            return try JSONDecoder().decode(CodexThreadRecord.self, from: JSONSerialization.data(withJSONObject: value))
        }
    }

    /// A fresh process per operation/readback; bounded stream, no raw log files,
    /// no credentials or inherited environment, no provider request approvals.
    private final class RPC {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        var buffer = Data()
        var bytesSeen = 0
        var nextID = 0
        var terminals: [String: String] = [:]
        let lifetime = Date().addingTimeInterval(35)

        init(executable: URL, root: URL) throws {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", try CodexCompatibilitySandbox.profile(executable: executable, work: root),
                                 executable.path, "app-server", "--listen", "stdio://"]
            process.environment = CodexCompatibilitySandbox.environment(work: root)
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        func stop() {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.interrupt() }
            let end = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < end { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            nextID += 1
            let id = nextID
            try send(["id": id, "method": method, "params": params])
            let deadline = min(lifetime, Date().addingTimeInterval(20))
            while true {
                let object = try next(deadline: deadline)
                guard (object["id"] as? NSNumber)?.intValue == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw RPCError(code: (error["code"] as? NSNumber)?.intValue ?? 0,
                                   message: error["message"] as? String ?? "")
                }
                guard let result = object["result"] as? [String: Any] else { throw Failure.contract }
                return result
            }
        }

        func terminal(thread: String, turn: String) -> String? { terminals[thread + "/" + turn] }

        func next(deadline: Date) throws -> [String: Any] {
            while true {
                try Task.checkCancellation()
                guard Date() < min(deadline, lifetime) else { throw Failure.timeout }
                if let newline = buffer.firstIndex(of: 10) {
                    let data = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.contract }
                    if object["method"] != nil, object["id"] != nil { throw Failure.contract }
                    if object["method"] as? String == "turn/completed",
                       let params = object["params"] as? [String: Any], let id = params["threadId"] as? String,
                       let turn = params["turn"] as? [String: Any], let turnID = turn["id"] as? String,
                       let status = turn["status"] as? String { terminals[id + "/" + turnID] = status }
                    return object
                }
                var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&fd, 1, 100)
                if ready == 0 { continue }
                if ready < 0 { if errno == EINTR { continue }; throw Failure.contract }
                var bytes = [UInt8](repeating: 0, count: 8_192)
                let count = Darwin.read(fd.fd, &bytes, bytes.count)
                guard count > 0 else { throw Failure.contract }
                bytesSeen += count
                guard bytesSeen <= 8_388_608 else { throw Failure.outputLimit }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }
    }
}
