import Foundation

/// Owns only newly created synthetic files. No caller-selected paths, Codex home,
/// live backup transport or mutation admission are exposed by this helper.
final class CodexCompatibilityDesktopDiskWorkspace {
    private let root: URL
    private let names = ["desktop.sqlite", "summaries.sqlite"]
    private var originalBytes: [Data] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("asm-desktop-probe-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    func dispose() {
        // Synthetic fixtures only; never fall back to irreversible deletion.
        _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }

    func materialize(_ database: CodexGhostRepairProductionSQLite) throws {
        for (schema, name) in zip(["main", "reviewed_summaries"], names) {
            try database.execute("VACUUM \(schema) INTO ?", bindings: [.text(file(name).path)])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(name).path)
        }
    }

    func backup(corruptForTest: Bool = false) throws {
        // Sources are closed, freshly generated databases with no WAL. This is
        // a bounded disk-copy test, not a substitute for live backup receipts.
        for name in names {
            let bytes = try Data(contentsOf: file(name))
            guard bytes.count < 4_194_304 else { throw CodexCompatibilityDesktopProbe.Failure.mismatch }
            originalBytes.append(bytes)
            try FileManager.default.copyItem(at: file(name), to: file("backup-" + name))
        }
        if corruptForTest {
            try Data("synthetic corruption".utf8).write(to: file("backup-" + names[1]))
        }
        try verifyBackup()
    }

    func openWorking() throws -> CodexGhostRepairProductionSQLite { try open(prefix: "", readOnly: false) }

    func openBackup() throws -> CodexGhostRepairProductionSQLite {
        try verifyBackup()
        return try open(prefix: "backup-", readOnly: true)
    }

    func restoreIntoSeparateCopy() throws -> CodexGhostRepairProductionSQLite {
        try verifyBackup()
        for name in names {
            try FileManager.default.copyItem(at: file("backup-" + name), to: file("restored-" + name))
        }
        return try open(prefix: "restored-", readOnly: true)
    }

    private func verifyBackup() throws {
        guard originalBytes.count == names.count else { throw CodexCompatibilityDesktopProbe.Failure.mismatch }
        for (name, bytes) in zip(names, originalBytes) {
            guard try Data(contentsOf: file("backup-" + name)) == bytes else {
                throw CodexCompatibilityDesktopProbe.Failure.backupMismatch
            }
        }
    }

    private func open(prefix: String, readOnly: Bool) throws -> CodexGhostRepairProductionSQLite {
        let database = try CodexGhostRepairProductionSQLite(url: file(prefix + names[0]), readOnly: readOnly)
        do {
            let uri = file(prefix + names[1]).absoluteString + (readOnly ? "?mode=ro" : "?mode=rw")
            try database.execute("ATTACH DATABASE ? AS reviewed_summaries", bindings: [.text(uri)])
            if !readOnly {
                // Match the multi-database rollback-journal transaction mode;
                // WAL crash atomicity is deliberately not claimed by this test.
                for schema in ["main", "reviewed_summaries"] {
                    let mode = try database.query("PRAGMA \(schema).journal_mode", maximumRows: 1)
                    guard mode.first?.fields.first?.value == .text("delete") else {
                        throw CodexCompatibilityDesktopProbe.Failure.mismatch
                    }
                    try database.execute("PRAGMA \(schema).synchronous=FULL")
                }
            }
            guard try database.integrityPassed(),
                  try database.query("PRAGMA reviewed_summaries.integrity_check", maximumRows: 1)
                    .first?.fields.first?.value == .text("ok") else {
                throw CodexCompatibilityDesktopProbe.Failure.mismatch
            }
            return database
        } catch {
            database.close()
            throw error
        }
    }

    private func file(_ name: String) -> URL { root.appendingPathComponent(name) }
}
