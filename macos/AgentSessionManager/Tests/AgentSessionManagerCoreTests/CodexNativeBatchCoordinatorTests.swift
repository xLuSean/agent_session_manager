import XCTest
@testable import AgentSessionManagerCore

final class CodexNativeBatchCoordinatorTests: XCTestCase {
    private let runtime = "0.147.0"
    private let baseTime = Date(timeIntervalSince1970: 1_800_700_000)

    func testArchiveBatchStopsAfterFailureAndNeverSendsRemainingRequest() async throws {
        let sessions = (1 ... 3).map { session($0, state: .active) }
        let checkpointSnapshot = snapshot(sessions, at: baseTime)
        let preflight = snapshot(sessions, at: baseTime.addingTimeInterval(1))
        let afterFirst = snapshot([
            session(1, state: .archived),
            session(2, state: .active),
            session(3, state: .active),
        ], at: baseTime.addingTimeInterval(20))
        let afterSecond = snapshot([
            session(1, state: .archived),
            session(2, state: .active),
            session(3, state: .active),
        ], at: baseTime.addingTimeInterval(30))
        let transport = NativeBatchTransportStub(
            inventories: [preflight, afterFirst, afterSecond],
            archiveFailureOrdinal: 2
        )
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(checkpointSnapshot.checkpoint)
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKeys: Set(sessions.map(\.id)),
            operation: .archive,
            snapshot: checkpointSnapshot,
            checkpoint: checkpointSnapshot.checkpoint
        )
        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .partial)
        XCTAssertEqual(report.items.map(\.outcome), [.success, .failure, .failure])
        XCTAssertEqual(report.items[2].errorCode, "batch_not_attempted")
        let calls = await transport.calls()
        XCTAssertEqual(calls.archive, [sessions[0].nativeID, sessions[1].nativeID])
        XCTAssertFalse(calls.archive.contains(sessions[2].nativeID))
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .consumed)
    }

    func testDeleteBatchCreatesOneTombstonePerDualAbsenceSuccess() async throws {
        let sessions = [session(1, state: .archived), session(2, state: .archived)]
        let checkpointSnapshot = snapshot(sessions, at: baseTime)
        let preflight = snapshot(sessions, at: baseTime.addingTimeInterval(1))
        let afterFirst = snapshot(
            [session(2, state: .archived)],
            at: baseTime.addingTimeInterval(20)
        )
        let afterSecond = snapshot([], at: baseTime.addingTimeInterval(30))
        let transport = NativeBatchTransportStub(
            inventories: [preflight, afterFirst, afterSecond]
        )
        let store = try makeStore(named: #function)
        defer { store.close() }
        for item in sessions {
            try store.saveTrashMembership(
                TrashMembershipRecord(
                    provider: .codex,
                    nativeSessionID: item.nativeID,
                    managerKey: item.id,
                    titleAtEntry: item.title,
                    workingDirectoryAtEntry: item.workingDirectory,
                    nativeStateAtEntry: .archived,
                    providerInventoryHashAtEntry: checkpointSnapshot.inventoryHash,
                    enteredAt: baseTime,
                    lastReconciledAt: baseTime
                ),
                checkpoint: checkpointSnapshot.checkpoint
            )
        }
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKeys: Set(sessions.map(\.id)),
            operation: .emptyTrash,
            snapshot: checkpointSnapshot,
            checkpoint: checkpointSnapshot.checkpoint
        )
        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        let tombstones = try store.deletedSessions(for: .codex)
        XCTAssertEqual(Set(tombstones.map(\.managerKey)), Set(sessions.map(\.id)))
        XCTAssertTrue(tombstones.allSatisfy { $0.deleteReportID == report.id })
        let calls = await transport.calls()
        XCTAssertEqual(calls.delete, sessions.map(\.nativeID))
        XCTAssertEqual(calls.exactRead, sessions.map(\.nativeID))
    }

    func testDeleteBatchAllowsUnknownCrossHostRunningAndCurrent() async throws {
        let uncertain = SessionProtection(
            isRunningKnown: false,
            isCurrentKnown: false
        )
        let sessions = [
            session(1, state: .archived, protection: uncertain),
            session(2, state: .archived, protection: uncertain),
        ]
        let checkpointSnapshot = snapshot(
            sessions,
            at: baseTime,
            protectionComplete: false
        )
        let transport = NativeBatchTransportStub(inventories: [
            snapshot(
                sessions,
                at: baseTime.addingTimeInterval(1),
                protectionComplete: false
            ),
            snapshot(
                [session(2, state: .archived, protection: uncertain)],
                at: baseTime.addingTimeInterval(20),
                protectionComplete: false
            ),
            snapshot([], at: baseTime.addingTimeInterval(30), protectionComplete: false),
        ])
        let store = try makeStore(named: #function)
        defer { store.close() }
        for item in sessions {
            try store.saveTrashMembership(
                TrashMembershipRecord(
                    provider: .codex,
                    nativeSessionID: item.nativeID,
                    managerKey: item.id,
                    titleAtEntry: item.title,
                    workingDirectoryAtEntry: item.workingDirectory,
                    nativeStateAtEntry: .archived,
                    providerInventoryHashAtEntry: checkpointSnapshot.inventoryHash,
                    enteredAt: baseTime,
                    lastReconciledAt: baseTime
                ),
                checkpoint: checkpointSnapshot.checkpoint
            )
        }
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKeys: Set(sessions.map(\.id)),
            operation: .emptyTrash,
            snapshot: checkpointSnapshot,
            checkpoint: checkpointSnapshot.checkpoint
        )
        XCTAssertTrue(preview.warnings.contains { $0.contains("Cross-host") })
        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(try store.deletedSessions(for: .codex).count, 2)
        let calls = await transport.calls()
        XCTAssertEqual(calls.delete, sessions.map(\.nativeID))
    }

    func testDeleteBatchStillBlocksUnknownPinEvidence() async throws {
        let sessions = [
            session(
                1,
                state: .archived,
                protection: SessionProtection(isPinnedKnown: false)
            ),
            session(2, state: .archived),
        ]
        let checkpointSnapshot = snapshot(
            sessions,
            at: baseTime,
            protectionComplete: false
        )
        let store = try makeStore(named: #function)
        defer { store.close() }
        for item in sessions {
            try store.saveTrashMembership(
                TrashMembershipRecord(
                    provider: .codex,
                    nativeSessionID: item.nativeID,
                    managerKey: item.id,
                    titleAtEntry: item.title,
                    workingDirectoryAtEntry: item.workingDirectory,
                    nativeStateAtEntry: .archived,
                    providerInventoryHashAtEntry: checkpointSnapshot.inventoryHash,
                    enteredAt: baseTime,
                    lastReconciledAt: baseTime
                ),
                checkpoint: checkpointSnapshot.checkpoint
            )
        }
        let transport = NativeBatchTransportStub(inventories: [])
        let coordinator = makeCoordinator(store: store, transport: transport)

        do {
            _ = try await coordinator.prepare(
                managerKeys: Set(sessions.map(\.id)),
                operation: .emptyTrash,
                snapshot: checkpointSnapshot,
                checkpoint: checkpointSnapshot.checkpoint
            )
            XCTFail("Delete preview should require known pin evidence")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("pin"),
                "Unexpected error: \(error)"
            )
        }
        let calls = await transport.calls()
        XCTAssertTrue(calls.delete.isEmpty)
    }

    func testActiveToTrashBatchAddsEverySuccessfulMembershipAtomicallyWithReport() async throws {
        let sessions = [session(1, state: .active), session(2, state: .active)]
        let checkpointSnapshot = snapshot(sessions, at: baseTime)
        let transport = NativeBatchTransportStub(inventories: [
            snapshot(sessions, at: baseTime.addingTimeInterval(1)),
            snapshot(
                [session(1, state: .archived), session(2, state: .active)],
                at: baseTime.addingTimeInterval(20)
            ),
            snapshot(
                [session(1, state: .archived), session(2, state: .archived)],
                at: baseTime.addingTimeInterval(30)
            ),
        ])
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(checkpointSnapshot.checkpoint)
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKeys: Set(sessions.map(\.id)),
            operation: .moveToTrash,
            snapshot: checkpointSnapshot,
            checkpoint: checkpointSnapshot.checkpoint
        )
        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(
            Set(try store.trashMemberships(for: .codex).map(\.managerKey)),
            Set(sessions.map(\.id))
        )
        let calls = await transport.calls()
        XCTAssertEqual(calls.archive, sessions.map(\.nativeID))
    }

    func testTrashRestoreBatchRemovesEverySuccessfulMembership() async throws {
        let sessions = [session(1, state: .archived), session(2, state: .archived)]
        let checkpointSnapshot = snapshot(sessions, at: baseTime)
        let transport = NativeBatchTransportStub(inventories: [
            snapshot(sessions, at: baseTime.addingTimeInterval(1)),
            snapshot(
                [session(1, state: .active), session(2, state: .archived)],
                at: baseTime.addingTimeInterval(20)
            ),
            snapshot(
                [session(1, state: .active), session(2, state: .active)],
                at: baseTime.addingTimeInterval(30)
            ),
        ])
        let store = try makeStore(named: #function)
        defer { store.close() }
        for item in sessions {
            try store.saveTrashMembership(
                TrashMembershipRecord(
                    provider: .codex,
                    nativeSessionID: item.nativeID,
                    managerKey: item.id,
                    titleAtEntry: item.title,
                    workingDirectoryAtEntry: item.workingDirectory,
                    nativeStateAtEntry: .archived,
                    providerInventoryHashAtEntry: checkpointSnapshot.inventoryHash,
                    enteredAt: baseTime,
                    lastReconciledAt: baseTime
                ),
                checkpoint: checkpointSnapshot.checkpoint
            )
        }
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKeys: Set(sessions.map(\.id)),
            operation: .restore,
            snapshot: checkpointSnapshot,
            checkpoint: checkpointSnapshot.checkpoint
        )
        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        let calls = await transport.calls()
        XCTAssertEqual(calls.restore, sessions.map(\.nativeID))
    }

    func testWholeBatchPreflightDriftSendsNoMutation() async throws {
        let sessions = [session(1, state: .active), session(2, state: .active)]
        let checkpointSnapshot = snapshot(sessions, at: baseTime)
        let drifted = snapshot(
            [session(1, state: .archived), session(2, state: .active)],
            at: baseTime.addingTimeInterval(1)
        )
        let transport = NativeBatchTransportStub(inventories: [drifted])
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(checkpointSnapshot.checkpoint)
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKeys: Set(sessions.map(\.id)),
            operation: .archive,
            snapshot: checkpointSnapshot,
            checkpoint: checkpointSnapshot.checkpoint
        )

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .failure)
        XCTAssertTrue(report.items.allSatisfy { $0.errorCode == "batch_preflight_rejected" })
        let calls = await transport.calls()
        XCTAssertTrue(calls.archive.isEmpty)
        XCTAssertTrue(calls.restore.isEmpty)
        XCTAssertTrue(calls.delete.isEmpty)
    }

    private func makeCoordinator(
        store: SQLiteStateStore,
        transport: NativeBatchTransportStub
    ) -> CodexNativeBatchCoordinator {
        let now = baseTime.addingTimeInterval(10)
        return CodexNativeBatchCoordinator(
            store: store,
            transport: transport,
            now: { now },
            makePreviewID: { UUID(uuidString: "ba7c0000-0000-4000-8000-000000000001")! },
            makeReportID: { UUID(uuidString: "ba7c0000-0000-4000-8000-000000000002")! }
        )
    }

    private func session(
        _ ordinal: Int,
        state: NativeSessionState,
        protection: SessionProtection = SessionProtection()
    ) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: String(format: "019f0000-0000-7000-8000-%012d", ordinal),
            title: "Batch \(ordinal)",
            workingDirectory: "/tmp/batch-\(ordinal)",
            updatedAt: baseTime,
            sizeBytes: Int64(ordinal * 100),
            nativeState: state,
            protection: protection,
            descendantCount: 0,
            descendantCountKnown: true
        )
    }

    private func snapshot(
        _ sessions: [AgentSession],
        at date: Date,
        protectionComplete: Bool = true
    ) -> ProviderInventorySnapshot {
        ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtime,
            inventoryHash: "checkpoint-batch-v1",
            observedAt: date,
            inventoryComplete: true,
            protectionComplete: protectionComplete,
            sessions: sessions,
            archiveScopeComplete: true
        )
    }

    private func makeStore(named name: String) throws -> SQLiteStateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-native-batch-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try SQLiteStateStore(
            databaseURL: directory.appendingPathComponent("\(name)-\(UUID()).sqlite3")
        )
    }
}

private actor NativeBatchTransportStub: CodexNativeBatchMutationTransport {
    struct CallLog: Sendable {
        var archive: [String] = []
        var restore: [String] = []
        var delete: [String] = []
        var exactRead: [String] = []
    }

    private var inventories: [ProviderInventorySnapshot]
    private let archiveFailureOrdinal: Int?
    private var archiveOrdinal = 0
    private var log = CallLog()

    init(
        inventories: [ProviderInventorySnapshot],
        archiveFailureOrdinal: Int? = nil
    ) {
        self.inventories = inventories
        self.archiveFailureOrdinal = archiveFailureOrdinal
    }

    func inventorySnapshot() async throws -> ProviderInventorySnapshot {
        guard !inventories.isEmpty else {
            throw CodexAppServerError.responseTimeout
        }
        return inventories.removeFirst()
    }

    func archive(_ nativeSessionID: String) async throws {
        archiveOrdinal += 1
        log.archive.append(nativeSessionID)
        if archiveOrdinal == archiveFailureOrdinal {
            throw CodexAppServerError.rpcError(-32602, "busy")
        }
    }

    func restore(_ nativeSessionID: String) async throws {
        log.restore.append(nativeSessionID)
    }

    func delete(_ nativeSessionID: String) async throws {
        log.delete.append(nativeSessionID)
    }

    func exactDeleteRead(
        _ nativeSessionID: String,
        auditedRuntimeVersion: String
    ) async -> DeleteExactReadObservation {
        log.exactRead.append(nativeSessionID)
        return .absent(
            nativeSessionID: nativeSessionID,
            observedAt: Date(timeIntervalSince1970: 1_800_700_100),
            runtimeVersion: auditedRuntimeVersion
        )
    }

    func calls() -> CallLog { log }
}
