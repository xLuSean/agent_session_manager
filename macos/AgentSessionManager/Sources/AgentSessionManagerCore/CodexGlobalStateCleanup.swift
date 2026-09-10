import CSQLite3
import Foundation

/// An in-memory, exact-byte preview. It is never persisted in diagnostic logs.
public struct CodexGlobalStateCleanupPreview: Identifiable, Sendable {
    public let id: UUID
    public let operationID: UUID
    public let threadIDs: [String]
    public let expiresAt: Date
    public let changes: [CodexGlobalStateCleanupChange]
    fileprivate let files: [GlobalStateFilePlan]
}

public struct CodexGlobalStateCleanupChange: Identifiable, Sendable {
    public let fileName: String
    public let field: String
    public let threadID: String
    public let removedJSON: String
    public var id: String { fileName + field + threadID }
    public var diff: String {
        "--- \(fileName)\n+++ \(fileName) (after cleanup)\n@@ \(field) @@\n"
            + removedJSON.components(separatedBy: "\n").map { "- " + $0 }.joined(separator: "\n")
    }
}

fileprivate struct GlobalStateFilePlan: Sendable {
    let name: String
    let before: Data?
    let after: Data?
}

public struct CodexGlobalStateCleanupResult: Sendable {
    public let removedEntryCount: Int
    public let backupURL: URL?
}

public enum CodexGlobalStateCleanupError: LocalizedError {
    case stopped(String)
    public var errorDescription: String? {
        switch self { case let .stopped(message): message }
    }
}

/// This is a separate, explicitly confirmed follow-up, never part of an
/// automatic Ghost mutation or a replay of official Delete.
public actor CodexGlobalStateCleanup {
    private let home: URL
    private let backupRoot: URL
    private let checkGate: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private let exclusion: CodexGhostRepairBulkOperationExclusion
    private var issued: CodexGlobalStateCleanupPreview?
    private var busy = false
    private static let fileNames = [".codex-global-state.json", ".codex-global-state.json.bak"]
    private static let rootMaps = [
        "thread-project-assignments", "thread-workspace-root-hints",
        "thread-projectless-output-directories", "thread-writable-roots",
    ]
    private static let atomMaps = [
        "prompt-history", "heartbeat-thread-permissions-by-id", "thread-descriptions-v1",
    ]

    public static func production() throws -> CodexGlobalStateCleanup {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let backup = try StateStoreLocation.applicationSupportDatabaseURL()
            .deletingLastPathComponent().appendingPathComponent("GlobalStateCleanup")
        let gate = CodexGhostRepairMacOSOperationalGateSource(configuration:
            CodexGhostRepairOperationalGateConfiguration(codexHomeURL: home,
                backupVolumeProbeURL: home.deletingLastPathComponent()))
        return CodexGlobalStateCleanup(home: home, backupRoot: backup, exclusion: .production(), checkGate: {
            guard try await gate.ghostRepairExecutionGate().isClear else {
                throw CodexGlobalStateCleanupError.stopped("Keep Codex and its terminal/editor sessions closed before reviewing or applying this cleanup.")
            }
        })
    }

    // Test-only root injection; the shipping factory never accepts caller paths.
    init(home: URL, backupRoot: URL,
         exclusion: CodexGhostRepairBulkOperationExclusion = .uncoordinatedTestOnly,
         checkGate: @escaping @Sendable () async throws -> Void,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home; self.backupRoot = backupRoot
        self.checkGate = checkGate; self.now = now
        self.exclusion = exclusion
    }

    public func cancel() { issued = nil }

    public func preview(report: CodexGhostRepairBulkRepairReport) async throws -> CodexGlobalStateCleanupPreview {
        guard !busy else { throw stop("Another global-state review is running.") }
        busy = true; defer { busy = false }
        issued = nil
        guard report.outcome == .success else { throw stop("A successful Desktop cleanup report is required.") }
        let ids = report.itemReports.map(\.threadID)
        guard ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw stop("Invalid session identity.") }
        try await checkGate()
        try verifyAbsent(ids)
        var changes: [CodexGlobalStateCleanupChange] = []
        let files = try Self.fileNames.map { name -> GlobalStateFilePlan in
            guard let before = try read(name) else { return .init(name: name, before: nil, after: nil) }
            let transformed = try Self.transform(before, fileName: name, ids: Set(ids))
            changes += transformed.changes
            return .init(name: name, before: before, after: transformed.changes.isEmpty ? before : transformed.data)
        }
        // A quiet window and exact comparison, not an lsof-only inference.
        try await Task.sleep(nanoseconds: 500_000_000)
        try await checkGate()
        try verifyFiles(files, after: false)
        let result = CodexGlobalStateCleanupPreview(id: UUID(), operationID: report.operationID,
            threadIDs: ids, expiresAt: now().addingTimeInterval(300), changes: changes, files: files)
        issued = result
        return result
    }

    public func apply(preview: CodexGlobalStateCleanupPreview) async throws -> CodexGlobalStateCleanupResult {
        guard !busy else { throw stop("Another global-state cleanup is running.") }
        busy = true; defer { busy = false }
        guard issued?.id == preview.id, now() < preview.expiresAt else {
            throw stop("This diff was cancelled, used, or expired. Generate a new diff.")
        }
        // Consume before any await or mutation: no duplicate confirmation/replay.
        issued = nil
        let lease = try exclusion.acquire()
        defer { lease.release() }
        try await checkGate()
        try lease.validateCurrentPath()
        try verifyAbsent(preview.threadIDs)
        try verifyFiles(preview.files, after: false)
        guard !preview.changes.isEmpty else { return .init(removedEntryCount: 0, backupURL: nil) }
        try safePath(backupRoot)
        let fm = FileManager.default
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // An interrupted multi-file operation must be inspected, not retried automatically.
        for url in try fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil) {
            if fm.fileExists(atPath: url.appendingPathComponent("pending.json").path)
                && !fm.fileExists(atPath: url.appendingPathComponent("verified.json").path) {
                throw stop("An earlier global-state cleanup needs review. Backups: \(url.path). Do not retry Delete.")
            }
        }
        let backup = backupRoot.appendingPathComponent(preview.id.uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        for file in preview.files {
            if let before = file.before {
                let url = backup.appendingPathComponent(file.name)
                try before.write(to: url, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                guard try Data(contentsOf: url) == before else { throw stop("Backup verification failed; no source files were changed.") }
            }
        }
        let receipt = try JSONSerialization.data(withJSONObject: [
            "previewID": preview.id.uuidString, "operationID": preview.operationID.uuidString,
            "threadIDs": preview.threadIDs, "removedEntryCount": preview.changes.count,
            "backupPurpose": "User-confirmed global-state cleanup; contains pre-cleanup private data",
        ], options: [.sortedKeys])
        try receipt.write(to: backup.appendingPathComponent("pending.json"), options: .withoutOverwriting)
        do {
            try await checkGate()
            try lease.validateCurrentPath()
            try verifyAbsent(preview.threadIDs)
            try verifyFiles(preview.files, after: false)
            for file in preview.files where file.before != file.after {
                try await checkGate()
                try lease.validateCurrentPath()
                guard try read(file.name) == file.before else { throw stop("The file changed after review.") }
                guard let data = file.after else { throw stop("Unexpected file removal request.") }
                let url = home.appendingPathComponent(file.name)
                try data.write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try await checkGate()
            try lease.validateCurrentPath()
            try verifyFiles(preview.files, after: true)
            try receipt.write(to: backup.appendingPathComponent("verified.json"), options: .withoutOverwriting)
        } catch {
            throw stop("Global-state cleanup was not fully verified and may be partial. Do not retry Delete or restore automatically. Inspect backup: \(backup.path).")
        }
        return .init(removedEntryCount: preview.changes.count, backupURL: backup)
    }

    private func stop(_ message: String) -> CodexGlobalStateCleanupError { .stopped(message) }

    private func safePath(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw stop("Symlinked cleanup paths are not supported.")
        }
    }

    private func read(_ name: String) throws -> Data? {
        let url = home.appendingPathComponent(name)
        try safePath(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if name == Self.fileNames[0] { throw stop("The main global-state file is missing.") }
            return nil
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16 * 1_024 * 1_024,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw stop("Unsupported global-state file type, link count, or size.")
        }
        return try Data(contentsOf: url)
    }

    private func verifyFiles(_ files: [GlobalStateFilePlan], after: Bool) throws {
        for file in files {
            guard try read(file.name) == (after ? file.after : file.before) else {
                throw stop("Global state changed since this diff was generated. Review a new diff; nothing will be retried.")
            }
        }
    }

    private func verifyAbsent(_ ids: [String]) throws {
        for (name, query) in [
            ("state_5.sqlite", "SELECT count(*) FROM threads WHERE id = ?"),
            ("sqlite/codex-dev.db", "SELECT count(*) FROM local_thread_catalog WHERE host_id = 'local' AND thread_id = ?"),
        ] {
            let url = home.appendingPathComponent(name)
            try safePath(url)
            var db: OpaquePointer?
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }
                throw stop("Cannot verify current session absence.")
            }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                throw stop("Unsupported session database schema.")
            }
            defer { sqlite3_finalize(stmt) }
            for id in ids {
                sqlite3_reset(stmt)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                guard sqlite3_bind_text(stmt, 1, id, -1, transient) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) == 0 else {
                    throw stop("A selected session still exists or could not be checked. No global-state cleanup is allowed.")
                }
            }
        }
    }

    static func transform(_ data: Data, fileName: String, ids: Set<String>) throws
        -> (data: Data, changes: [CodexGlobalStateCleanupChange]) {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexGlobalStateCleanupError.stopped("Global state must be a JSON object.")
        }
        var changes: [CodexGlobalStateCleanupChange] = []
        func record(_ field: String, _ id: String, _ value: Any) throws {
            let removed = try JSONSerialization.data(withJSONObject: [id: value], options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            changes.append(.init(fileName: fileName, field: field, threadID: id,
                removedJSON: String(decoding: removed, as: UTF8.self)))
        }
        func cleanMaps(_ object: inout [String: Any], keys: [String], prefix: String) throws {
            for key in keys {
                guard let value = object[key], !(value is NSNull) else { continue }
                guard var entries = value as? [String: Any] else {
                    throw CodexGlobalStateCleanupError.stopped("Unsupported shape for \(prefix)/\(key); no cleanup was prepared.")
                }
                for id in ids.sorted() {
                    if let value = entries.removeValue(forKey: id) { try record(prefix + "/" + key, id, value) }
                }
                object[key] = entries
            }
        }
        try cleanMaps(&root, keys: rootMaps, prefix: "")
        if let value = root["projectless-thread-ids"], !(value is NSNull) {
            guard let values = value as? [String] else {
                throw CodexGlobalStateCleanupError.stopped("Unsupported projectless-thread-ids shape.")
            }
            for id in Set(values).intersection(ids).sorted() { try record("/projectless-thread-ids", id, id) }
            root["projectless-thread-ids"] = values.filter { !ids.contains($0) }
        }
        if let value = root["electron-persisted-atom-state"], !(value is NSNull) {
            guard var atom = value as? [String: Any] else {
                throw CodexGlobalStateCleanupError.stopped("Unsupported persisted state shape.")
            }
            try cleanMaps(&atom, keys: atomMaps, prefix: "/electron-persisted-atom-state")
            root["electron-persisted-atom-state"] = atom
        }
        return (try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), changes)
    }
}
