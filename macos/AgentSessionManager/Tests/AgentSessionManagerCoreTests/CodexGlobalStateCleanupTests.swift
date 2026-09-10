import CSQLite3
import XCTest
@testable import AgentSessionManagerCore

final class CodexGlobalStateCleanupTests: XCTestCase {
    private let target = "a1000000-0000-4000-8000-000000000001"
    private let other = "a1000000-0000-4000-8000-000000000002"

    func testDiffRemovesOnlyOwnedEntriesAndPreservesMentionsUnknownFieldsAndAutomation() throws {
        let input: [String: Any] = [
            "thread-project-assignments": [target: "project-a", other: "project-b"],
            "projectless-thread-ids": [target, other],
            "unknown-future-field": [target: "keep unknown schema"],
            "automations": ["definition": ["enabled": true, "schedule": "daily"]],
            "electron-persisted-atom-state": [
                "prompt-history": [target: ["private old prompt"], other: ["mentions \(target)"]],
                "thread-descriptions-v1": [target: "old description"],
                "heartbeat-thread-permissions-by-id": [target: ["network": true]],
                "composer-prompt-drafts-v2": [other: ["prompt": "mentions \(target)"]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        let result = try CodexGlobalStateCleanup.transform(data, fileName: "main", ids: [target])
        XCTAssertEqual(result.changes.count, 5)
        XCTAssertTrue(result.changes.allSatisfy { $0.threadID == target && $0.diff.contains("- ") })
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        XCTAssertNil((after["thread-project-assignments"] as? [String: Any])?[target])
        XCTAssertEqual(after["projectless-thread-ids"] as? [String], [other])
        XCTAssertEqual(after["automations"] as? NSDictionary, input["automations"] as? NSDictionary)
        XCTAssertEqual(after["unknown-future-field"] as? NSDictionary, input["unknown-future-field"] as? NSDictionary)
        let atom = try XCTUnwrap(after["electron-persisted-atom-state"] as? [String: Any])
        XCTAssertEqual((atom["prompt-history"] as? [String: [String]])?[other], ["mentions \(target)"])
        XCTAssertNotNil(atom["composer-prompt-drafts-v2"])
    }

    func testUnsupportedKnownShapeBlocksRatherThanDroppingData() throws {
        for value in ["bad shape" as Any, ["not a map"] as Any] {
            let data = try JSONSerialization.data(withJSONObject: ["thread-project-assignments": value])
            XCTAssertThrowsError(try CodexGlobalStateCleanup.transform(data, fileName: "main", ids: [target]))
        }
    }

    func testPreviewAndCancelDoNotWriteOrCreateBackups() async throws {
        let f = try fixture(); defer { dispose(f.root) }
        let before = try Data(contentsOf: f.main)
        let preview = try await f.service.preview(report: report())
        XCTAssertEqual(preview.changes.count, 2) // main and .bak
        XCTAssertEqual(try Data(contentsOf: f.main), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backups.path))
        await f.service.cancel()
        do { _ = try await f.service.apply(preview: preview); XCTFail("Cancelled diff applied") } catch {}
        XCTAssertEqual(try Data(contentsOf: f.main), before)
    }

    func testConfirmedDiffWritesBothFilesBacksUpAndRejectsReplay() async throws {
        let f = try fixture(); defer { dispose(f.root) }
        let before = try Data(contentsOf: f.main)
        let preview = try await f.service.preview(report: report())
        let result = try await f.service.apply(preview: preview)
        XCTAssertEqual(result.removedEntryCount, 2)
        let backup = try XCTUnwrap(result.backupURL)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(f.main.lastPathComponent)), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("verified.json").path))
        for name in [".codex-global-state.json", ".codex-global-state.json.bak"] {
            let after = try Data(contentsOf: f.home.appendingPathComponent(name))
            XCTAssertNotEqual(after, before)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: Any])
            XCTAssertEqual(obj["thread-project-assignments"] as? [String: String], [other: "keep"])
        }
        do { _ = try await f.service.apply(preview: preview); XCTFail("Replayed diff") } catch {}
    }

    func testDriftInEitherFileBlocksAllWrites() async throws {
        for name in [".codex-global-state.json", ".codex-global-state.json.bak"] {
            let f = try fixture(); defer { dispose(f.root) }
            let preview = try await f.service.preview(report: report())
            let changed = Data("{\"new-state\":true}".utf8)
            try changed.write(to: f.home.appendingPathComponent(name))
            do { _ = try await f.service.apply(preview: preview); XCTFail("Stale diff applied") } catch {}
            XCTAssertEqual(try Data(contentsOf: f.home.appendingPathComponent(name)), changed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.backups.path))
        }
    }

    func testReappearingSessionBlocksApply() async throws {
        let f = try fixture(); defer { dispose(f.root) }
        let preview = try await f.service.preview(report: report())
        try execute(f.home.appendingPathComponent("state_5.sqlite"), "INSERT INTO threads VALUES ('\(target)')")
        do { _ = try await f.service.apply(preview: preview); XCTFail("Existing session allowed") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backups.path))
    }

    func testUnresolvedReportBlocksPreview() async throws {
        let f = try fixture(); defer { dispose(f.root) }
        do { _ = try await f.service.preview(report: report(outcome: .unknown)); XCTFail("Unknown report allowed") } catch {}
    }

    func testGateFailureBlocksWithoutMutation() async throws {
        let f = try fixture(); defer { dispose(f.root) }
        let service = CodexGlobalStateCleanup(home: f.home, backupRoot: f.backups, checkGate: {
            throw CodexGlobalStateCleanupError.stopped("Writer is running")
        })
        do { _ = try await service.preview(report: report()); XCTFail("Writer allowed") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backups.path))
    }

    func testUnfinishedPriorOperationBlocksApply() async throws {
        let f = try fixture(); defer { dispose(f.root) }
        let preview = try await f.service.preview(report: report())
        let unfinished = f.backups.appendingPathComponent("old-operation")
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: unfinished.appendingPathComponent("pending.json"))
        let before = try Data(contentsOf: f.main)
        do { _ = try await f.service.apply(preview: preview); XCTFail("Pending operation ignored") } catch {}
        XCTAssertEqual(try Data(contentsOf: f.main), before)
    }

    func testInterruptedBetweenFilesLeavesBackupAndBlocksFurtherWrites() async throws {
        let f = try fixture(); defer { dispose(f.root) }
        let gate = FailingGate()
        let service = CodexGlobalStateCleanup(home: f.home, backupRoot: f.backups,
            checkGate: { try await gate.check() })
        let preview = try await service.preview(report: report())
        let before = try Data(contentsOf: f.main)
        do { _ = try await service.apply(preview: preview); XCTFail("Expected partial outcome") }
        catch { XCTAssertTrue(error.localizedDescription.contains("may be partial")) }
        XCTAssertNotEqual(try Data(contentsOf: f.main), before)
        XCTAssertEqual(try Data(contentsOf: f.home.appendingPathComponent(".codex-global-state.json.bak")), before)
        let backups = try FileManager.default.contentsOfDirectory(at: f.backups, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(".codex-global-state.json")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("verified.json").path))
        let next = try await service.preview(report: report())
        do { _ = try await service.apply(preview: next); XCTFail("Retried a partial operation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("earlier global-state cleanup")) }
    }

    func testExpiredPreviewCannotApply() async throws {
        let f = try fixture(); defer { dispose(f.root) }
        let clock = TestClock()
        let service = CodexGlobalStateCleanup(home: f.home, backupRoot: f.backups,
            checkGate: {}, now: { clock.read() })
        let preview = try await service.preview(report: report())
        clock.advance()
        do { _ = try await service.apply(preview: preview); XCTFail("Expired preview applied") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backups.path))
    }

    func testNoChangesDoesNotCreateBackupOrRewrite() async throws {
        let f = try fixture(); defer { dispose(f.root) }
        let bytes = Data("{ \"unknown\" : true }\n".utf8)
        for name in [".codex-global-state.json", ".codex-global-state.json.bak"] {
            try bytes.write(to: f.home.appendingPathComponent(name))
        }
        let preview = try await f.service.preview(report: report())
        XCTAssertTrue(preview.changes.isEmpty)
        let result = try await f.service.apply(preview: preview)
        XCTAssertNil(result.backupURL)
        XCTAssertEqual(try Data(contentsOf: f.main), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backups.path))
    }

    func testSymlinkedBackupFileCannotBePreviewed() async throws {
        let f = try fixture(); defer { dispose(f.root) }
        let bak = f.home.appendingPathComponent(".codex-global-state.json.bak")
        dispose(bak)
        try FileManager.default.createSymbolicLink(at: bak, withDestinationURL: f.main)
        do { _ = try await f.service.preview(report: report()); XCTFail("Symlink accepted") } catch {}
    }

    private func report(outcome: CodexGhostRepairBulkRepairObservedOutcome = .success) throws -> CodexGhostRepairBulkRepairReport {
        try .init(operationID: UUID(), outcome: outcome,
            itemReports: [.init(threadID: target, category: .ordinary, outcome: outcome)],
            reportDigest: "sha256:" + String(repeating: "a", count: 64))
    }

    private func fixture() throws -> (root: URL, home: URL, main: URL, backups: URL, service: CodexGlobalStateCleanup) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("asm-global-state-test-" + UUID().uuidString)
        let home = root.appendingPathComponent("codex")
        let backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sqlite"), withIntermediateDirectories: true)
        try execute(home.appendingPathComponent("state_5.sqlite"), "CREATE TABLE threads(id TEXT PRIMARY KEY)")
        try execute(home.appendingPathComponent("sqlite/codex-dev.db"), "CREATE TABLE local_thread_catalog(host_id TEXT, thread_id TEXT)")
        let main = home.appendingPathComponent(".codex-global-state.json")
        let data = try JSONSerialization.data(withJSONObject: ["thread-project-assignments": [target: "remove", other: "keep"]])
        try data.write(to: main)
        try data.write(to: home.appendingPathComponent(".codex-global-state.json.bak"))
        return (root, home, main, backups, .init(home: home, backupRoot: backups, checkGate: {}))
    }

    private func execute(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CodexGlobalStateCleanupError.stopped("Fixture open failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CodexGlobalStateCleanupError.stopped("Fixture SQL failed") }
    }

    private func dispose(_ root: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["trash", root.path]
        do { try process.run(); process.waitUntilExit() } catch { XCTFail("Fixture trash failed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}

private actor FailingGate {
    private var calls = 0
    func check() throws {
        calls += 1
        if calls == 6 { throw CodexGlobalStateCleanupError.stopped("Injected interruption before .bak write") }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 100)
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance() { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(301) }
}
