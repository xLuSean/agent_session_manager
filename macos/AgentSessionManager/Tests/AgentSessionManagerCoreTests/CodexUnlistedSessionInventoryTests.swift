import XCTest
import CSQLite3
@testable import AgentSessionManagerCore

final class CodexUnlistedSessionInventoryTests: XCTestCase {
    private let target = "00000000-0000-4000-8000-000000000001"
    private let other = "00000000-0000-4000-8000-000000000002"

    func testSupplementRequiresOfficialReadAndPreservesActiveArchiveAndPin() throws {
        let home = try fixture(); defer { dispose(home) }
        try insert(home, id: other, archived: true, pinned: true)
        let before = try Data(contentsOf: home.appendingPathComponent("state_5.sqlite"))
        var reads: [String] = []
        let result = try collect(home) { id in reads.append(id); return self.record(id) }
        XCTAssertEqual(reads, [target, other])
        XCTAssertEqual(result.active.map(\.id), [target])
        XCTAssertEqual(result.archived.map(\.id), [other])
        XCTAssertEqual(result.active.first?.isPinned, false)
        XCTAssertEqual(result.archived.first?.isPinned, true)
        XCTAssertEqual(result.active.first?.name, "Automation fixture")
        XCTAssertEqual(result.active.first?.localSupplement?.label, "Desktop automation · local supplement")
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("state_5.sqlite")), before)
    }

    func testListedSessionIsNotDuplicatedOrReread() throws {
        let home = try fixture(); defer { dispose(home) }
        let result = try CodexUnlistedSessionInventory.collect(home: home, runtimeVersion: "0.153.4",
            active: [record(target)], archived: []) { _ in XCTFail("Already listed"); return self.record(self.target) }
        XCTAssertTrue(result.active.isEmpty)
    }

    func testDifferentRuntimeDoesNotReadLocalSchema() throws {
        let result = try CodexUnlistedSessionInventory.collect(home: URL(fileURLWithPath: "/nonexistent/asm-fixture"),
            runtimeVersion: "0.149.0", active: [], archived: []) { _ in XCTFail("Wrong adapter"); return self.record(self.target) }
        XCTAssertTrue(result.active.isEmpty)
    }

    func testMismatchEphemeralOrUnavailableOfficialReadIsRejected() throws {
        let home = try fixture(); defer { dispose(home) }
        for bad in [record(other), record(target, sessionID: other), record(target, ephemeral: true),
                    record(target, cwd: "/elsewhere"), record(target, pinned: true)] {
            XCTAssertThrowsError(try collect(home) { _ in bad })
        }
        XCTAssertThrowsError(try collect(home) { _ in throw CodexAppServerError.responseTimeout })
    }

    func testConcurrentMetadataChangeIsRejected() throws {
        let home = try fixture(); defer { dispose(home) }
        XCTAssertThrowsError(try collect(home) { id in
            try self.sql(home, "UPDATE threads SET archived=1 WHERE id='\(id)'")
            return self.record(id)
        })
    }

    func testMissingOutsideAndSymlinkRolloutsAreRejected() throws {
        let home = try fixture(); defer { dispose(home) }
        let unnamed = home.appendingPathComponent("sessions/unattributed.jsonl")
        try Data("unattributed".utf8).write(to: unnamed)
        for path in [home.appendingPathComponent("sessions/missing.jsonl").path,
                     home.appendingPathComponent("state_5.sqlite").path, unnamed.path] {
            try sql(home, "UPDATE threads SET rollout_path='\(path)'")
            XCTAssertThrowsError(try collect(home) { self.record($0) })
        }
        let link = home.appendingPathComponent("sessions/linked-\(target).jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rollout(home, target))
        try sql(home, "UPDATE threads SET rollout_path='\(link.path)'")
        XCTAssertThrowsError(try collect(home) { self.record($0) })
    }

    func testUnsupportedSchemaOrUnknownPinFailsClosed() throws {
        let home = try fixture(); defer { dispose(home) }
        try sql(home, "UPDATE threads SET is_pinned=NULL")
        XCTAssertThrowsError(try collect(home) { self.record($0) })
        try sql(home, "ALTER TABLE threads RENAME COLUMN preview TO old_preview")
        XCTAssertThrowsError(try collect(home) { self.record($0) })
    }

    func testCandidateBoundFailsBeforeAnyOfficialReads() throws {
        let home = try fixture(); defer { dispose(home) }
        try sql(home, """
            WITH RECURSIVE n(x) AS (SELECT 2 UNION ALL SELECT x+1 FROM n WHERE x<1001)
            INSERT INTO threads SELECT printf('00000000-0000-4000-8000-%012d',x),0,'/unused','/tmp','vscode','automation',0,'' FROM n;
            """)
        XCTAssertThrowsError(try collect(home) { _ in XCTFail("Bound must fail before reads"); return self.record(self.target) })
    }

    func testCanonicalChildrenRemainProtected() async throws {
        let home = try fixture(); defer { dispose(home) }
        try sql(home, "INSERT INTO thread_spawn_edges VALUES ('\(target)','\(other)')")
        let client = try client(home)
        let snapshot = try await client.inventory()
        let session = try XCTUnwrap(CodexAppServerProvider.map(snapshot: snapshot).first)
        XCTAssertFalse(session.descendantCountKnown)
        XCTAssertFalse(session.protection.hasPinnedDescendantKnown)
        let scope = CodexAppServerProvider.archiveScope(snapshot: snapshot)
        XCTAssertFalse(try XCTUnwrap(scope.nodes.first).descendantCountKnown)
    }

    func testFullAndLeanInventoryKeepOmittedSessionAcrossArchiveTransition() async throws {
        let home = try fixture(); defer { dispose(home) }
        let client = try client(home)
        let full = try await client.inventory()
        XCTAssertEqual(full.active.map(\.id), [target])
        let mapped = CodexAppServerProvider.map(snapshot: full)
        XCTAssertEqual(mapped.first?.title, "Automation fixture")
        XCTAssertNotNil(mapped.first?.supplementalSourceLabel)
        XCTAssertEqual(mapped.first?.protection.isPinnedKnown, true)
        XCTAssertEqual(mapped.first?.protection.hasPinnedDescendantKnown, true)
        // The fixture changes only its own canonical state to simulate official archive.
        try sql(home, "UPDATE threads SET archived=1")
        let readback = try await client.lifecycleReadback()
        XCTAssertTrue(readback.active.isEmpty)
        XCTAssertEqual(readback.archived.map(\.id), [target])
        XCTAssertFalse(readback.isTruncated)
        XCTAssertFalse(readback.desktopPinStateAvailable)
        let refreshed = try await client.inventory()
        XCTAssertEqual(refreshed.archived.map(\.id), [target])
    }

    func testExactReadDoesNotProveDeletionWhileOldRolloutExists() async throws {
        let home = try fixture(); defer { dispose(home) }
        let client = try client(home)
        try sql(home, "DELETE FROM threads")
        do { _ = try await client.exactRead(threadID: target); XCTFail("Residue was accepted as absent") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rollout still exists"), "\(error)") }
        dispose(rollout(home, target))
        do { _ = try await client.exactRead(threadID: target); XCTFail("Absent fixture should return official not-loaded") }
        catch { XCTAssertEqual(error as? CodexAppServerError, .rpcError(-32600, "thread not loaded: \(target)")) }
        let beforeRead = Date()
        do { _ = try await client.exactReadForDeletion(threadID: target); XCTFail("Expected source-bound absence") }
        catch {
            let evidence = try XCTUnwrap(error as? CodexDeleteAbsenceEvidence)
            XCTAssertEqual(evidence.nativeSessionID, target)
            XCTAssertEqual(evidence.runtimeVersion, "0.153.4")
            XCTAssertGreaterThanOrEqual(evidence.observedAt, beforeRead)
        }
        let actual = await CodexDeleteMutationTransport(source: client).exactReadObservation(
            nativeSessionID: target, auditedRuntimeVersion: "0.153.4")
        guard case .absent = actual else { return XCTFail("Valid source absence was rejected") }
        let drifted = await CodexDeleteMutationTransport(source: client).exactReadObservation(
            nativeSessionID: target, auditedRuntimeVersion: "0.147.0")
        guard case .unavailable = drifted else { return XCTFail("Caller version replaced actual runtime") }
    }

    func testAbsenceRequiresCanonicalRowAndEveryRolloutToBeGone() throws {
        let home = try fixture(); defer { dispose(home) }
        XCTAssertThrowsError(try CodexUnlistedSessionInventory.verifyLocalAbsence(home: home, threadID: target))
        let old = home.appendingPathComponent("archived_sessions/old-\(target).jsonl")
        try Data("old".utf8).write(to: old)
        try sql(home, "DELETE FROM threads")
        dispose(rollout(home, target))
        XCTAssertThrowsError(try CodexUnlistedSessionInventory.verifyLocalAbsence(home: home, threadID: target))
        dispose(old)
        XCTAssertNoThrow(try CodexUnlistedSessionInventory.verifyLocalAbsence(home: home, threadID: target))
        let link = home.appendingPathComponent("sessions/broken-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/fixture")
        XCTAssertThrowsError(try CodexUnlistedSessionInventory.verifyLocalAbsence(home: home, threadID: target))
    }

    func testOfficialJSONCannotForgeSupplementProvenance() throws {
        let bytes = try JSONEncoder().encode(record(target))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["localSupplement"] = ["label": "forged", "hasCanonicalChildren": false]
        let decoded = try JSONDecoder().decode(CodexThreadRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.localSupplement)
    }

    func testSupplementedSessionUsesExistingTrashAndDeleteCoordinators() async throws {
        try await exerciseLifecycle(leaveRollout: false)
    }

    func testExistingDeleteCoordinatorKeepsUnknownWhenRolloutSurvives() async throws {
        try await exerciseLifecycle(leaveRollout: true)
    }

    private func exerciseLifecycle(leaveRollout: Bool) async throws {
        let home = try fixture(); defer { dispose(home) }
        let client = try client(home)
        let source = UnlistedLifecycleFixtureSource(home: home, client: client, leaveRollout: leaveRollout)
        let store = try SQLiteStateStore(databaseURL: home.appendingPathComponent("manager.sqlite"))
        defer { store.close() }
        let initial = try CodexProviderInventorySnapshotBuilder.make(from: await client.inventory())
        try store.upsertProviderCheckpoint(initial.checkpoint)
        let key = try XCTUnwrap(initial.sessions.first?.id)
        let archive = CodexNativeArchiveCoordinator(store: store,
            transport: CodexArchiveMutationTransport(source: source), executionGate: LifecycleExecutionGateStub(),
            now: { Date() }, makePreviewID: { UUID() }, makeReportID: { UUID() })
        let trashPreview = try await archive.prepare(managerKey: key, snapshot: initial,
            checkpoint: initial.checkpoint, operation: .moveToTrash)
        let trashReport = try await archive.execute(preview: trashPreview, confirmationToken: trashPreview.confirmationToken)
        XCTAssertEqual(trashReport.outcome, .success)
        XCTAssertEqual(try store.trashMemberships(for: .codex).map(\.nativeSessionID), [target])

        let archived = try CodexProviderInventorySnapshotBuilder.make(from: await client.inventory())
        try store.upsertProviderCheckpoint(archived.checkpoint)
        let delete = CodexNativeDeleteCoordinator(store: store,
            transport: CodexDeleteMutationTransport(source: source), executionGate: LifecycleExecutionGateStub(),
            now: { Date() }, makePreviewID: { UUID() }, makeReportID: { UUID() })
        let preview = try await delete.prepare(managerKey: key, snapshot: archived, checkpoint: archived.checkpoint)
        let report = try await delete.execute(preview: preview, confirmationToken: preview.confirmationToken)
        XCTAssertEqual(report.outcome, leaveRollout ? .unknown : .success)
        XCTAssertEqual(try store.deletedSessions(for: .codex).count, leaveRollout ? 0 : 1)
        XCTAssertEqual(try store.trashMemberships(for: .codex).count, leaveRollout ? 1 : 0)
        let calls = await source.calls()
        XCTAssertEqual(calls.archive, [target])
        XCTAssertEqual(calls.delete, [target])
    }

    private func collect(_ home: URL, read: (String) throws -> CodexThreadRecord) throws -> CodexUnlistedSessionInventory.Result {
        try CodexUnlistedSessionInventory.collect(home: home, runtimeVersion: "0.153.4", active: [], archived: [], read: read)
    }

    private func record(_ id: String, sessionID: String? = nil, ephemeral: Bool = false,
                        cwd: String = "/tmp", pinned: Bool? = nil) -> CodexThreadRecord {
        .init(id: id, sessionId: sessionID ?? id, parentThreadId: nil, preview: "", ephemeral: ephemeral,
              modelProvider: "openai", createdAt: 0, updatedAt: 1, status: .init(type: "notLoaded", activeFlags: nil),
              cwd: cwd, cliVersion: "0.153.4", name: "Automation fixture", isPinned: pinned, gitInfo: nil)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("asm-unlisted-test-" + UUID().uuidString)
        for name in ["sessions", "archived_sessions"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try sql(root, """
            CREATE TABLE threads (id TEXT PRIMARY KEY, archived INTEGER, rollout_path TEXT, cwd TEXT,
              source TEXT, thread_source TEXT, is_pinned INTEGER, preview TEXT);
            CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT);
            """)
        try Data("{\"pinned-thread-ids\":[]}".utf8).write(to: root.appendingPathComponent(".codex-global-state.json"))
        try insert(root, id: target)
        return root
    }

    private func insert(_ home: URL, id: String, archived: Bool = false, pinned: Bool = false) throws {
        try Data("synthetic rollout".utf8).write(to: rollout(home, id))
        try sql(home, "INSERT INTO threads VALUES ('\(id)',\(archived ? 1 : 0),'\(rollout(home,id).path)','/tmp','vscode','automation',\(pinned ? 1 : 0),'')")
    }

    private func rollout(_ home: URL, _ id: String) -> URL { home.appendingPathComponent("sessions/rollout-\(id).jsonl") }

    private func client(_ home: URL) throws -> CodexAppServerClient {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "fake-app-server-unlisted", withExtension: "sh"))
        let executable = home.appendingPathComponent("server.sh")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return CodexAppServerClient(configuration: .init(executableURL: executable, timeout: 3))
    }

    private func sql(_ home: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else {
            throw CodexAppServerError.malformedResponse("Fixture open failed")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CodexAppServerError.malformedResponse("Fixture SQL failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func dispose(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["trash", url.path]
        do { try process.run(); process.waitUntilExit() } catch { XCTFail("Fixture cleanup: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

/// Simulates official lifecycle effects only inside the test's disposable home.
/// Readback still passes through the real client, local adapter and coordinators.
private actor UnlistedLifecycleFixtureSource: CodexArchiveSource, CodexDeleteSource {
    let home: URL
    let client: CodexAppServerClient
    let leaveRollout: Bool
    var archivedIDs: [String] = []
    var deletedIDs: [String] = []

    init(home: URL, client: CodexAppServerClient, leaveRollout: Bool) {
        precondition(home.lastPathComponent.hasPrefix("asm-unlisted-test-"))
        self.home = home; self.client = client; self.leaveRollout = leaveRollout
    }

    func inventory() async throws -> CodexInventorySnapshot { try await client.inventory() }
    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot { try await client.exactRead(threadID: threadID) }
    func exactReadForDeletion(threadID: String) async throws -> CodexExactReadSnapshot {
        try await client.exactReadForDeletion(threadID: threadID)
    }
    func archive(threadID: String) async throws {
        archivedIDs.append(threadID)
        try mutate("UPDATE threads SET archived=1 WHERE id=?", id: threadID)
    }
    func delete(threadID: String) async throws {
        deletedIDs.append(threadID)
        try mutate("DELETE FROM threads WHERE id=?", id: threadID)
        if !leaveRollout {
            let file = home.appendingPathComponent("sessions/rollout-\(threadID).jsonl")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["trash", file.path]
            try process.run(); process.waitUntilExit()
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }
    func calls() -> (archive: [String], delete: [String]) { (archivedIDs, deletedIDs) }
    private func mutate(_ query: String, id: String) throws {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw CodexAppServerError.exactReadUnavailable }
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else {
            throw CodexAppServerError.exactReadUnavailable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw CodexAppServerError.exactReadUnavailable }
        defer { sqlite3_finalize(statement) }
        _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CodexAppServerError.exactReadUnavailable }
    }
}
