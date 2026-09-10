#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class CodexGhostRepairDisposableBundleTests: XCTestCase {
    func testDisposablePathGuardRejectsBroadRootAndSymlinkedDatabase() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-disposable-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        addTeardownBlock {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            cleanup.arguments = ["trash", parent.path]
            try cleanup.run()
            cleanup.waitUntilExit()
            XCTAssertEqual(cleanup.terminationStatus, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        }
        XCTAssertThrowsError(
            try CodexGhostRepairDisposableBundle(rootURL: parent, allowedParentURL: parent)
        )

        let outside = parent.appendingPathComponent("outside.db")
        try createEmptySQLite(at: outside, version: 32)
        let root = parent.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data(CodexGhostRepairDisposableBundle.markerContents.utf8).write(
            to: root.appendingPathComponent(CodexGhostRepairDisposableBundle.markerFileName)
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("codex-dev.db"),
            withDestinationURL: outside
        )
        try createEmptySQLite(at: root.appendingPathComponent("codex-thread-summaries-dev.db"), version: 2)
        try createEmptySQLite(at: root.appendingPathComponent("codex-history-snapshots-dev.db"), version: 3)
        XCTAssertThrowsError(
            try CodexGhostRepairDisposableBundle(rootURL: root, allowedParentURL: parent)
        )
    }

    private func createEmptySQLite(at url: URL, version: Int) throws {
        var database: OpaquePointer?
        defer { if let database { sqlite3_close(database) } }
        guard sqlite3_open(url.path, &database) == SQLITE_OK,
              sqlite3_exec(database, "PRAGMA user_version=\(version)", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "DisposableBundleTest", code: 1)
        }
    }
}
#endif
