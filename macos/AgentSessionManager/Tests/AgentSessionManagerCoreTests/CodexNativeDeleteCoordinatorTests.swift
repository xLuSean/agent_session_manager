import XCTest
@testable import AgentSessionManagerCore

final class CodexNativeDeleteCoordinatorTests: XCTestCase {
    private let nativeID = "01900000-0000-7000-8000-000000000001"
    private let runtime = "0.147.0"
    private let observedAt = Date(timeIntervalSince1970: 1_800_600_000)
    private let previewID = UUID(uuidString: "dead0000-0000-4000-8000-000000000001")!
    private let reportID = UUID(uuidString: "dead0000-0000-4000-8000-000000000002")!

    func testTrashDeletePersistsTombstoneOnlyAfterDualAbsenceReadback() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seed(fixture, into: store)
        let transport = DeleteTransportStub(
            preflight: fixture.snapshot,
            readback: emptySnapshot(observedAt: observedAt.addingTimeInterval(40)),
            exact: .absent(
                nativeSessionID: nativeID,
                observedAt: observedAt.addingTimeInterval(40),
                runtimeVersion: runtime
            )
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )
        XCTAssertEqual(preview.operation, .emptyTrash)
        XCTAssertEqual(preview.items.first?.beforeCollection, .trash)
        XCTAssertEqual(preview.items.first?.targetCollection, .deleted)

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.first?.observedNativeState, .absent)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        let tombstone = try XCTUnwrap(store.deletedSessions(for: .codex).first)
        XCTAssertEqual(tombstone.nativeSessionID, nativeID)
        XCTAssertEqual(tombstone.deleteReportID, reportID)
        let persistentReport = try XCTUnwrap(store.operationReport(id: reportID))
        XCTAssertFalse(persistentReport.releasedBytesComplete)
        XCTAssertNil(persistentReport.items.first?.verifiedReleasedBytes)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 2)
        XCTAssertEqual(counts.delete, 1)
        XCTAssertEqual(counts.exactRead, 1)
        XCTAssertEqual(counts.deleteIDs, [nativeID])
    }

    func testUnknownCrossHostRunningAndCurrentCanAttemptDeleteOnce() async throws {
        let protection = SessionProtection(
            isRunningKnown: false,
            isCurrentKnown: false
        )
        let fixture = try makeFixture(protection: protection)
        XCTAssertFalse(fixture.checkpoint.protectionComplete)
        XCTAssertTrue(fixture.session.protection.deleteAttemptMayFail)
        XCTAssertFalse(fixture.session.protection.blocksDeleteAttempt)

        let store = try makeStore(named: #function)
        defer { store.close() }
        try seed(fixture, into: store)
        let readbackAt = observedAt.addingTimeInterval(40)
        let transport = DeleteTransportStub(
            preflight: fixture.snapshot,
            readback: emptySnapshot(observedAt: readbackAt),
            exact: .absent(
                nativeSessionID: nativeID,
                observedAt: readbackAt,
                runtimeVersion: runtime
            )
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )
        XCTAssertTrue(preview.warnings.contains { $0.contains("another lifecycle host") })

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        XCTAssertEqual(try store.deletedSessions(for: .codex).count, 1)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.delete, 1)
    }

    func testUnknownPinStillBlocksDeletePreview() async throws {
        let fixture = try makeFixture(
            protection: SessionProtection(isPinnedKnown: false)
        )
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seed(fixture, into: store)
        let transport = DeleteTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot,
            exact: .present(
                nativeSessionID: nativeID,
                observedAt: observedAt.addingTimeInterval(40),
                runtimeVersion: runtime
            )
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        do {
            _ = try await coordinator.prepare(
                managerKey: fixture.session.id,
                snapshot: fixture.snapshot,
                checkpoint: fixture.checkpoint
            )
            XCTFail("Unavailable pin evidence must block Permanent Delete.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pin/descendant protection"))
        }
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.delete, 0)
    }

    func testRejectedDeleteWithPresentReadbackPreservesTrashAndNoTombstone() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seed(fixture, into: store)
        let readbackAt = observedAt.addingTimeInterval(40)
        let transport = DeleteTransportStub(
            preflight: fixture.snapshot,
            readback: try snapshot(observedAt: readbackAt),
            exact: .present(
                nativeSessionID: nativeID,
                observedAt: readbackAt,
                runtimeVersion: runtime
            ),
            deleteError: CodexAppServerError.rpcError(-32602, "not allowed")
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
        XCTAssertTrue(try store.deletedSessions(for: .codex).isEmpty)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.delete, 1)
    }

    func testInventoryAbsenceWithoutExactAbsenceIsUnknownAndNeverCommitsDeleted() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seed(fixture, into: store)
        let readbackAt = observedAt.addingTimeInterval(40)
        let transport = DeleteTransportStub(
            preflight: fixture.snapshot,
            readback: emptySnapshot(observedAt: readbackAt),
            exact: .unavailable(
                observedAt: readbackAt,
                errorCode: "delete_exact_read_timeout",
                message: "timed out"
            )
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

        XCTAssertEqual(report.outcome, .unknown)
        XCTAssertEqual(try store.trashMemberships(for: .codex).count, 1)
        XCTAssertTrue(try store.deletedSessions(for: .codex).isEmpty)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.delete, 1)
    }

    func testArchiveWithoutManagerTrashMembershipCannotPrepareDelete() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = DeleteTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot,
            exact: .present(
                nativeSessionID: nativeID,
                observedAt: observedAt.addingTimeInterval(40),
                runtimeVersion: runtime
            )
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        do {
            _ = try await coordinator.prepare(
                managerKey: fixture.session.id,
                snapshot: fixture.snapshot,
                checkpoint: fixture.checkpoint
            )
            XCTFail("Archive without Manager Trash membership must not prepare Delete.")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("Archive must be moved to Trash first")
            )
        }
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.delete, 0)
    }

    func testProtectionDriftStopsBeforeDeleteRequest() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seed(fixture, into: store)
        let protectedSnapshot = try snapshot(
            protection: SessionProtection(isRunning: true),
            observedAt: observedAt.addingTimeInterval(1)
        )
        let transport = DeleteTransportStub(
            preflight: protectedSnapshot,
            readback: fixture.snapshot,
            exact: .present(
                nativeSessionID: nativeID,
                observedAt: observedAt.addingTimeInterval(40),
                runtimeVersion: runtime
            )
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
        XCTAssertEqual(report.items.first?.errorCode, "delete_session_protected")
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.delete, 0)
    }

    func testInterruptedDeleteRecoveryUsesReadbackOnlyAndCreatesTombstone() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seed(fixture, into: store)
        let mutationTransport = DeleteTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot,
            exact: .present(
                nativeSessionID: nativeID,
                observedAt: observedAt.addingTimeInterval(40),
                runtimeVersion: runtime
            )
        )
        let coordinator = makeCoordinator(store: store, transport: mutationTransport)
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
        let recoveryReadback = DeleteRecoveryReadbackStub(
            observation: .absent(
                nativeSessionID: nativeID,
                observedAt: observedAt.addingTimeInterval(40),
                runtimeVersion: runtime
            )
        )
        let reconciler = DeleteExecutionRecoveryReconciler(
            store: store,
            readback: recoveryReadback,
            makeReportID: { self.reportID }
        )
        let recovery = CodexNativeDeleteRecoveryCoordinator(
            store: store,
            reconciler: reconciler
        )

        let recovered = try await recovery.recoverPending(
            using: emptySnapshot(observedAt: observedAt.addingTimeInterval(40))
        )
        let report = try XCTUnwrap(recovered)

        XCTAssertTrue(report.recoveredAfterInterruption)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
        XCTAssertEqual(try store.deletedSessions(for: .codex).first?.deleteReportID, reportID)
        let mutationCounts = await mutationTransport.callCounts()
        XCTAssertEqual(mutationCounts.delete, 0)
        let recoveryCalls = await recoveryReadback.callCount()
        XCTAssertEqual(recoveryCalls, 1)
    }

    func testRecoveryWithoutExactAbsenceLeavesExecutingPreviewForLaterReadback() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seed(fixture, into: store)
        let mutationTransport = DeleteTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot,
            exact: .present(
                nativeSessionID: nativeID,
                observedAt: observedAt.addingTimeInterval(40),
                runtimeVersion: runtime
            )
        )
        let coordinator = makeCoordinator(store: store, transport: mutationTransport)
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
        let recoveryReadback = DeleteRecoveryReadbackStub(
            observation: .unavailable(
                observedAt: observedAt.addingTimeInterval(40),
                errorCode: "timeout",
                message: "timed out"
            )
        )
        let recovery = CodexNativeDeleteRecoveryCoordinator(
            store: store,
            reconciler: DeleteExecutionRecoveryReconciler(
                store: store,
                readback: recoveryReadback,
                makeReportID: { self.reportID }
            )
        )

        do {
            _ = try await recovery.recoverPending(
                using: emptySnapshot(observedAt: observedAt.addingTimeInterval(40))
            )
            XCTFail("Recovery must not consume inventory-only absence.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exact-ID absence"))
        }

        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .executing)
        XCTAssertEqual(try store.trashMemberships(for: .codex).count, 1)
        XCTAssertTrue(try store.deletedSessions(for: .codex).isEmpty)
        let mutationCounts = await mutationTransport.callCounts()
        XCTAssertEqual(mutationCounts.delete, 0)
    }

    private func makeFixture(
        protection: SessionProtection = SessionProtection()
    ) throws -> (
        session: AgentSession,
        snapshot: ProviderInventorySnapshot,
        checkpoint: ProviderCheckpointRecord
    ) {
        let snapshot = try snapshot(protection: protection, observedAt: observedAt)
        return (snapshot.sessions[0], snapshot, snapshot.checkpoint)
    }

    private func snapshot(
        protection: SessionProtection = SessionProtection(),
        observedAt: Date
    ) throws -> ProviderInventorySnapshot {
        let session = AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: "Disposable Trash session",
            workingDirectory: "/Users/example/DeleteProject",
            updatedAt: self.observedAt,
            sizeBytes: 1234,
            nativeState: .archived,
            isTrashMember: false,
            protection: protection,
            descendantCount: 0,
            descendantCountKnown: true
        )
        return ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtime,
            inventoryHash: try InventorySnapshotHasher.hash(
                provider: .codex,
                sessions: [session]
            ),
            observedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: !protection.hasUnavailableState,
            sessions: [session]
        )
    }

    private func emptySnapshot(observedAt: Date) -> ProviderInventorySnapshot {
        ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtime,
            inventoryHash: "post-delete-empty",
            observedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: true,
            sessions: []
        )
    }

    private func seed(
        _ fixture: (
            session: AgentSession,
            snapshot: ProviderInventorySnapshot,
            checkpoint: ProviderCheckpointRecord
        ),
        into store: SQLiteStateStore
    ) throws {
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        try store.saveTrashMembership(
            TrashMembershipRecord(
                provider: .codex,
                nativeSessionID: fixture.session.nativeID,
                managerKey: fixture.session.id,
                titleAtEntry: fixture.session.title,
                projectIDAtEntry: fixture.session.project?.id,
                workingDirectoryAtEntry: fixture.session.workingDirectory,
                nativeStateAtEntry: .archived,
                providerInventoryHashAtEntry: fixture.checkpoint.inventoryHash,
                enteredAt: fixture.checkpoint.refreshedAt,
                lastReconciledAt: fixture.checkpoint.refreshedAt
            ),
            checkpoint: fixture.checkpoint
        )
    }

    private func makeCoordinator(
        store: SQLiteStateStore,
        transport: DeleteTransportStub
    ) -> CodexNativeDeleteCoordinator {
        CodexNativeDeleteCoordinator(
            store: store,
            transport: transport,
            now: { self.observedAt.addingTimeInterval(30) },
            makePreviewID: { self.previewID },
            makeReportID: { self.reportID }
        )
    }

    private func makeStore(named name: String) throws -> SQLiteStateStore {
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-delete-facade-\(safeName)-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStateStore(
            databaseURL: directory.appendingPathComponent("manager.sqlite3")
        )
    }
}

private actor DeleteTransportStub: DeleteMutationTransport {
    struct Counts: Sendable {
        let inventory: Int
        let delete: Int
        let exactRead: Int
        let deleteIDs: [String]
    }

    private let preflight: ProviderInventorySnapshot
    private let readback: ProviderInventorySnapshot
    private let exact: DeleteExactReadObservation
    private let deleteError: Error?
    private var inventoryCalls = 0
    private var deleteCalls = 0
    private var exactReadCalls = 0
    private var deleteIDs: [String] = []

    init(
        preflight: ProviderInventorySnapshot,
        readback: ProviderInventorySnapshot,
        exact: DeleteExactReadObservation,
        deleteError: Error? = nil
    ) {
        self.preflight = preflight
        self.readback = readback
        self.exact = exact
        self.deleteError = deleteError
    }

    func inventorySnapshot() -> ProviderInventorySnapshot {
        inventoryCalls += 1
        return inventoryCalls == 1 ? preflight : readback
    }

    func delete(nativeSessionID: String) throws {
        deleteCalls += 1
        deleteIDs.append(nativeSessionID)
        if let deleteError { throw deleteError }
    }

    func exactReadObservation(
        nativeSessionID _: String,
        auditedRuntimeVersion _: String
    ) -> DeleteExactReadObservation {
        exactReadCalls += 1
        return exact
    }

    func callCounts() -> Counts {
        Counts(
            inventory: inventoryCalls,
            delete: deleteCalls,
            exactRead: exactReadCalls,
            deleteIDs: deleteIDs
        )
    }
}

private actor DeleteRecoveryReadbackStub: DeleteExecutionRecoveryReadback {
    private let observation: DeleteExactReadObservation
    private var calls = 0

    init(observation: DeleteExactReadObservation) {
        self.observation = observation
    }

    func exactReadObservation(
        nativeSessionID _: String,
        auditedRuntimeVersion _: String
    ) -> DeleteExactReadObservation {
        calls += 1
        return observation
    }

    func callCount() -> Int { calls }
}
