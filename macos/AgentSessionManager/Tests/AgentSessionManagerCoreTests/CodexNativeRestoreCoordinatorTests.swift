import XCTest
@testable import AgentSessionManagerCore

final class CodexNativeRestoreCoordinatorTests: XCTestCase {
    private let nativeID = "01900000-0000-7000-8000-000000000001"
    private let runtime = "0.147.0"
    private let observedAt = Date(timeIntervalSince1970: 1_800_500_000)
    private let previewID = UUID(uuidString: "beef0000-0000-4000-8000-000000000001")!
    private let reportID = UUID(uuidString: "beef0000-0000-4000-8000-000000000002")!

    func testArchiveRestorePersistsPreviewExecutesOnceAndRequiresActiveReadback() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeRestoreTransportStub(
            preflight: fixture.snapshot,
            readback: try snapshot(state: .active)
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )

        XCTAssertEqual(preview.operation, .restore)
        XCTAssertEqual(preview.items.first?.beforeCollection, .archive)
        XCTAssertEqual(preview.items.first?.targetCollection, .active)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.id, reportID)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.first?.observedNativeState, .active)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .consumed)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 2)
        XCTAssertEqual(counts.restore, 1)
        XCTAssertEqual(counts.restoreIDs, [nativeID])
    }

    func testRunningCodexBlocksBeforeClaimOrRestoreRequest() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeRestoreTransportStub(
            preflight: fixture.snapshot,
            readback: try snapshot(state: .active)
        )
        let gate = LifecycleExecutionGateStub(
            error: .codexDesktopRunning(processKinds: [.codexHelper])
        )
        let coordinator = makeCoordinator(
            store: store,
            transport: transport,
            executionGate: gate
        )
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )

        do {
            _ = try await coordinator.execute(
                preview: preview,
                confirmationToken: preview.confirmationToken
            )
            XCTFail("Running Codex must block before Restore Preview claim.")
        } catch let error as CodexLifecycleExecutionGateError {
            XCTAssertEqual(
                error,
                .codexDesktopRunning(processKinds: [.codexHelper])
            )
        }

        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)
        let gateCalls = await gate.observedCallCount()
        XCTAssertEqual(gateCalls, 1)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.restore, 0)
    }

    func testRestorePreviewCanonicalizesSubMillisecondTimestampsBeforePersistence() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeRestoreTransportStub(
            preflight: fixture.snapshot,
            readback: try snapshot(state: .active)
        )
        let rawNow = Date(timeIntervalSince1970: 1_800_500_030.123_456)
        let coordinator = makeCoordinator(
            store: store,
            transport: transport,
            now: rawNow
        )

        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )
        let persisted = try XCTUnwrap(store.operationPreview(id: preview.id))

        XCTAssertEqual(
            persisted.createdAt,
            PersistentTimestamp.canonical(rawNow)
        )
        XCTAssertNotEqual(persisted.createdAt, rawNow)
    }

    func testRestoreDoesNotRequireCompleteDestructiveProtectionEvidence() async throws {
        let fixture = try makeFixture(protection: SessionProtection(
            isPinnedKnown: false,
            isRunningKnown: false,
            isCurrentKnown: false,
            hasPinnedDescendantKnown: false
        ))
        XCTAssertFalse(fixture.checkpoint.protectionComplete)
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeRestoreTransportStub(
            preflight: fixture.snapshot,
            readback: try snapshot(state: .active)
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )
        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .success)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.restore, 1)
    }

    func testUnrelatedInventoryHashDriftDoesNotStopExactTargetRestore() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let changedInventory = ProviderInventorySnapshot(
            provider: fixture.snapshot.provider,
            runtimeVersion: fixture.snapshot.runtimeVersion,
            inventoryHash: "unrelated-session-changed",
            observedAt: fixture.snapshot.observedAt.addingTimeInterval(1),
            inventoryComplete: fixture.snapshot.inventoryComplete,
            protectionComplete: fixture.snapshot.protectionComplete,
            sessions: fixture.snapshot.sessions
        )
        let transport = NativeRestoreTransportStub(
            preflight: changedInventory,
            readback: try snapshot(state: .active)
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .success)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.restore, 1)
    }

    func testExactTargetStateDriftStillStopsRestoreBeforeRequest() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeRestoreTransportStub(
            preflight: try snapshot(state: .active),
            readback: fixture.snapshot
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .failure)
        XCTAssertEqual(report.items.first?.errorCode, "restore_state_drift")
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.restore, 0)
    }

    func testManagerTrashRestoresToActiveAndRemovesMembershipOnlyAfterReadback() async throws {
        let fixture = try makeFixture(isTrashMember: true)
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        try store.saveTrashMembership(
            trashMembership(for: fixture.session, checkpoint: fixture.checkpoint),
            checkpoint: fixture.checkpoint
        )
        let transport = NativeRestoreTransportStub(
            preflight: fixture.snapshot,
            readback: try snapshot(state: .active)
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )
        XCTAssertEqual(preview.items.first?.beforeCollection, .trash)
        XCTAssertEqual(
            try store.operationPreview(id: preview.id)?.trashMembershipMutation,
            .remove
        )
        XCTAssertEqual(try store.trashMemberships(for: .codex).count, 1)

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.restore, 1)
    }

    func testFailedTrashRestorePreservesMembership() async throws {
        let fixture = try makeFixture(isTrashMember: true)
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        try store.saveTrashMembership(
            trashMembership(for: fixture.session, checkpoint: fixture.checkpoint),
            checkpoint: fixture.checkpoint
        )
        let transport = NativeRestoreTransportStub(
            preflight: fixture.snapshot,
            readback: try snapshot(state: .archived),
            restoreError: CodexAppServerError.rpcError(-32602, "not allowed")
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .failure)
        XCTAssertEqual(try store.trashMemberships(for: .codex).count, 1)
    }

    func testTrashRestoreRecoveryRemovesMembershipFromReadbackWithoutResending() async throws {
        let fixture = try makeFixture(isTrashMember: true)
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        try store.saveTrashMembership(
            trashMembership(for: fixture.session, checkpoint: fixture.checkpoint),
            checkpoint: fixture.checkpoint
        )
        let transport = NativeRestoreTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )
        _ = try store.claimOperationPreviewForExecution(
            id: preview.id,
            now: observedAt.addingTimeInterval(31),
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                preview.confirmationToken
            )
        )
        let recovery = CodexNativeRestoreRecoveryCoordinator(store: store)

        let recovered = try await recovery.recoverPending(
            using: snapshot(state: .active)
        )
        let report = try XCTUnwrap(recovered)

        XCTAssertTrue(report.recoveredAfterInterruption)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.restore, 0)
    }

    func testTrashMembershipDriftBeforeClaimStopsWithoutProviderCall() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeRestoreTransportStub(
            preflight: fixture.snapshot,
            readback: try snapshot(state: .active)
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )
        try store.saveTrashMembership(
            trashMembership(for: fixture.session, checkpoint: fixture.checkpoint),
            checkpoint: fixture.checkpoint
        )

        do {
            _ = try await coordinator.execute(
                preview: preview,
                confirmationToken: preview.confirmationToken
            )
            XCTFail("Trash membership drift must stop before thread/unarchive.")
        } catch let error as PersistentStateError {
            guard case .invalidRecord(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Trash membership drift"))
        }

        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.restore, 0)
    }

    func testRejectedRestoreWithArchivedReadbackIsFailureAndNeverRetries() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeRestoreTransportStub(
            preflight: fixture.snapshot,
            readback: try snapshot(state: .archived),
            restoreError: CodexAppServerError.rpcError(-32602, "not allowed")
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .failure)
        XCTAssertEqual(report.items.first?.observedNativeState, .archived)
        XCTAssertEqual(report.items.first?.errorCode, "restore_request_rpc_-32602")
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.restore, 1)
    }

    func testRestoreRecoveryUsesReadbackOnlyAndNeverResends() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeRestoreTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )
        _ = try store.claimOperationPreviewForExecution(
            id: preview.id,
            now: observedAt.addingTimeInterval(31),
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                preview.confirmationToken
            )
        )
        let recovery = CodexNativeRestoreRecoveryCoordinator(store: store)

        let recovered = try await recovery.recoverPending(
            using: snapshot(state: .active)
        )
        let report = try XCTUnwrap(recovered)

        XCTAssertTrue(report.recoveredAfterInterruption)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.first?.observedNativeState, .active)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .consumed)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.restore, 0)
    }

    func testCodexRestoreClientUsesExactOfficialPayload() async throws {
        let executable = try XCTUnwrap(
            Bundle.module.url(forResource: "fake-app-server-archive", withExtension: "sh")
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o100 != 0 else {
            throw XCTSkip("Restore fixture executable bit is unavailable in this build environment.")
        }
        let compatibility = try await CodexCompatibilityTestSupport(executable: executable,
            home: URL(fileURLWithPath: "/tmp"), version: "0.149.0")
        defer { XCTAssertNoThrow(try compatibility.cleanUp()) }
        let source = CodexAppServerClient(configuration: CodexAppServerConfiguration(
            executableURL: executable,
            timeout: 2
        ), compatibilityInspector: compatibility.inspector)

        try await source.unarchive(threadID: nativeID)
    }

    private func makeFixture(
        protection: SessionProtection = SessionProtection(
            isRunningKnown: false,
            isCurrentKnown: false
        ),
        isTrashMember: Bool = false
    ) throws -> (
        session: AgentSession,
        snapshot: ProviderInventorySnapshot,
        checkpoint: ProviderCheckpointRecord
    ) {
        let snapshot = try snapshot(
            state: .archived,
            protection: protection,
            isTrashMember: isTrashMember,
            observedAt: observedAt
        )
        return (snapshot.sessions[0], snapshot, snapshot.checkpoint)
    }

    private func snapshot(
        state: NativeSessionState,
        protection: SessionProtection = SessionProtection(
            isRunningKnown: false,
            isCurrentKnown: false
        ),
        isTrashMember: Bool = false,
        observedAt: Date? = nil
    ) throws -> ProviderInventorySnapshot {
        let session = AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: "Native Restore fixture",
            workingDirectory: "/Users/example/Project",
            updatedAt: self.observedAt,
            sizeBytes: nil,
            nativeState: state,
            isTrashMember: isTrashMember,
            protection: protection,
            descendantCount: 2,
            descendantCountKnown: true
        )
        return ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtime,
            inventoryHash: try InventorySnapshotHasher.hash(
                provider: .codex,
                sessions: [session]
            ),
            observedAt: observedAt ?? self.observedAt.addingTimeInterval(40),
            inventoryComplete: true,
            protectionComplete: false,
            sessions: [session]
        )
    }

    private func makeCoordinator(
        store: SQLiteStateStore,
        transport: NativeRestoreTransportStub,
        executionGate: any CodexLifecycleExecutionChecking = LifecycleExecutionGateStub(),
        now: Date? = nil
    ) -> CodexNativeRestoreCoordinator {
        let fixedNow = now ?? observedAt.addingTimeInterval(30)
        return CodexNativeRestoreCoordinator(
            store: store,
            transport: transport,
            executionGate: executionGate,
            now: { fixedNow },
            makePreviewID: { self.previewID },
            makeReportID: { self.reportID }
        )
    }

    private func trashMembership(
        for session: AgentSession,
        checkpoint: ProviderCheckpointRecord
    ) -> TrashMembershipRecord {
        TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: session.nativeID,
            managerKey: session.id,
            titleAtEntry: session.title,
            workingDirectoryAtEntry: session.workingDirectory,
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: checkpoint.inventoryHash,
            enteredAt: checkpoint.refreshedAt,
            lastReconciledAt: checkpoint.refreshedAt
        )
    }

    private func makeStore(named name: String) throws -> SQLiteStateStore {
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-restore-facade-\(safeName)-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStateStore(
            databaseURL: directory.appendingPathComponent("manager.sqlite3")
        )
    }
}

private actor NativeRestoreTransportStub: RestoreMutationTransport {
    struct Counts: Sendable {
        let inventory: Int
        let restore: Int
        let restoreIDs: [String]
    }

    private let preflight: ProviderInventorySnapshot
    private let readback: ProviderInventorySnapshot
    private let restoreError: Error?
    private var inventoryCalls = 0
    private var restoreCalls = 0
    private var restoreIDs: [String] = []

    init(
        preflight: ProviderInventorySnapshot,
        readback: ProviderInventorySnapshot,
        restoreError: Error? = nil
    ) {
        self.preflight = preflight
        self.readback = readback
        self.restoreError = restoreError
    }

    func inventorySnapshot() throws -> ProviderInventorySnapshot {
        inventoryCalls += 1
        return inventoryCalls == 1 ? preflight : readback
    }

    func restore(nativeSessionID: String) throws {
        restoreCalls += 1
        restoreIDs.append(nativeSessionID)
        if let restoreError { throw restoreError }
    }

    func callCounts() -> Counts {
        Counts(
            inventory: inventoryCalls,
            restore: restoreCalls,
            restoreIDs: restoreIDs
        )
    }
}
