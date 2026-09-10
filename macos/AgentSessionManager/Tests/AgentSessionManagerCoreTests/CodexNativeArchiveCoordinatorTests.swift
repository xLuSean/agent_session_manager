import XCTest
@testable import AgentSessionManagerCore

final class CodexNativeArchiveCoordinatorTests: XCTestCase {
    private let nativeID = "01900000-0000-7000-8000-000000000001"
    private let runtime = "0.147.0"
    private let observedAt = Date(timeIntervalSince1970: 1_800_400_000)
    private let previewID = UUID(uuidString: "a11f0000-0000-4000-8000-000000000001")!
    private let reportID = UUID(uuidString: "a11f0000-0000-4000-8000-000000000002")!

    func testSubmillisecondInventoryCanPrepareArchiveWithoutFalseCheckpointDrift() async throws {
        let fixture = try makeFixture(observationTime: observedAt.addingTimeInterval(0.123456))
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: try readbackSnapshot(state: .archived)
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )

        XCTAssertEqual(try store.providerCheckpoint(for: .codex), fixture.checkpoint)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 0)
    }

    func testFacadePersistsPreviewThenExecutesOneShotArchiveAndMapsReport() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: try readbackSnapshot(state: .archived)
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )

        XCTAssertEqual(preview.id, previewID)
        XCTAssertEqual(preview.items.map(\.nativeID), [nativeID])
        let frozen = try XCTUnwrap(store.operationPreview(id: preview.id))
        XCTAssertEqual(frozen.status, .prepared)
        let recalculatedManifest = try ArchiveExecutionHasher.manifestHash(
            provider: frozen.provider,
            operation: frozen.operation,
            providerInventoryHash: frozen.providerInventoryHash,
            runtimeVersion: runtime,
            reconciliationTimestamp: fixture.checkpoint.refreshedAt,
            createdAt: frozen.createdAt,
            expiresAt: frozen.expiresAt,
            affectedSetHash: frozen.affectedSetHash,
            items: frozen.items
        )
        XCTAssertEqual(frozen.manifestHash, recalculatedManifest)

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.id, reportID)
        XCTAssertEqual(report.outcome, .success, report.items[0].message ?? "no message")
        XCTAssertEqual(report.items[0].observedNativeState, .archived)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .consumed)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 2)
        XCTAssertEqual(counts.archive, 1)
        XCTAssertEqual(counts.archiveIDs, [nativeID])
    }

    func testRunningCodexBlocksBeforeClaimOrArchiveRequest() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: try readbackSnapshot(state: .archived)
        )
        let gate = LifecycleExecutionGateStub(
            error: .codexDesktopRunning(processKinds: [.codexApplication])
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
            XCTFail("Running Codex must block before Archive Preview claim.")
        } catch let error as CodexLifecycleExecutionGateError {
            XCTAssertEqual(
                error,
                .codexDesktopRunning(processKinds: [.codexApplication])
            )
        }

        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)
        let gateCalls = await gate.observedCallCount()
        XCTAssertEqual(gateCalls, 1)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    func testActiveMovesToTrashOnlyAfterArchivedReadback() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: try readbackSnapshot(state: .archived)
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint,
            operation: .moveToTrash
        )

        XCTAssertEqual(preview.operation, .moveToTrash)
        XCTAssertEqual(preview.items.first?.beforeCollection, .active)
        XCTAssertEqual(preview.items.first?.targetCollection, .trash)
        XCTAssertEqual(
            try store.operationPreview(id: preview.id)?.trashMembershipMutation,
            .add
        )
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.operation, .moveToTrash)
        XCTAssertEqual(report.outcome, .success)
        let memberships = try store.trashMemberships(for: .codex)
        XCTAssertEqual(memberships.map(\.managerKey), [fixture.session.id])
        XCTAssertEqual(memberships.first?.workingDirectoryAtEntry, fixture.session.workingDirectory)
    }

    func testFailedActiveToTrashNeverAddsMembership() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: try readbackSnapshot(state: .active),
            archiveError: CodexAppServerError.rpcError(-32602, "busy")
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint,
            operation: .moveToTrash
        )

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .failure)
        XCTAssertTrue(try store.trashMemberships(for: .codex).isEmpty)
    }

    func testReapplyTrashIntentArchivesOnceAndPreservesExactMembership() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let membership = makeMembership(fixture: fixture)
        try store.saveTrashMembership(membership, checkpoint: fixture.checkpoint)
        let state = makeConflictState(fixture: fixture, membership: membership)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: try readbackSnapshot(state: .archived)
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        let preview = try await coordinator.prepareReapplyTrashIntent(
            state: state,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )

        XCTAssertEqual(preview.operation, .archive)
        XCTAssertEqual(preview.items.first?.beforeCollection, .trash)
        XCTAssertEqual(preview.items.first?.targetCollection, .trash)
        let frozen = try XCTUnwrap(store.operationPreview(id: preview.id))
        XCTAssertNil(frozen.trashMembershipMutation)
        XCTAssertEqual(
            frozen.expectedTrashMembershipSetHash,
            try ConflictResolutionHasher.membershipSetHash([membership])
        )

        let report = try await coordinator.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(report.preservedTrashIntent)
        XCTAssertEqual(try store.trashMemberships(for: .codex), [membership])
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)
        XCTAssertEqual(counts.archiveIDs, [nativeID])
    }

    func testReapplyTrashIntentMembershipDriftBeforeClaimSendsNoArchive() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let membership = makeMembership(fixture: fixture)
        try store.saveTrashMembership(membership, checkpoint: fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: try readbackSnapshot(state: .archived)
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepareReapplyTrashIntent(
            state: makeConflictState(fixture: fixture, membership: membership),
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )
        _ = try store.removeTrashMembership(managerKey: fixture.session.id)

        do {
            _ = try await coordinator.execute(
                preview: preview,
                confirmationToken: preview.confirmationToken
            )
            XCTFail("Trash membership drift must reject the durable claim.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Trash membership"))
        }

        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    func testReapplyTrashIntentMembershipDriftAfterArchiveLeavesExecutingForRecovery() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let membership = makeMembership(fixture: fixture)
        try store.saveTrashMembership(membership, checkpoint: fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: try readbackSnapshot(state: .archived),
            onArchive: {
                _ = try store.removeTrashMembership(managerKey: fixture.session.id)
            }
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepareReapplyTrashIntent(
            state: makeConflictState(fixture: fixture, membership: membership),
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )

        do {
            _ = try await coordinator.execute(
                preview: preview,
                confirmationToken: preview.confirmationToken
            )
            XCTFail("Report commit must reject manager Trash intent drift.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("audit Report"))
        }

        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .executing)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)
    }

    func testReapplyTrashIntentRecoveryPreservesMembershipWithoutResending() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let membership = makeMembership(fixture: fixture)
        try store.saveTrashMembership(membership, checkpoint: fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepareReapplyTrashIntent(
            state: makeConflictState(fixture: fixture, membership: membership),
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
        let recovery = CodexNativeArchiveRecoveryCoordinator(store: store)

        let recovered = try await recovery.recoverPending(
            using: readbackSnapshot(state: .archived)
        )
        let report = try XCTUnwrap(recovered)

        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(report.preservedTrashIntent)
        XCTAssertEqual(try store.trashMemberships(for: .codex), [membership])
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 0)
    }

    func testActiveToTrashRecoveryAddsMembershipFromReadbackWithoutResending() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint,
            operation: .moveToTrash
        )
        _ = try store.claimOperationPreviewForExecution(
            id: preview.id,
            now: observedAt.addingTimeInterval(31),
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                preview.confirmationToken
            )
        )
        let recovery = CodexNativeArchiveRecoveryCoordinator(store: store)

        let recovered = try await recovery.recoverPending(
            using: readbackSnapshot(state: .archived)
        )
        let report = try XCTUnwrap(recovered)

        XCTAssertTrue(report.recoveredAfterInterruption)
        XCTAssertEqual(report.operation, .moveToTrash)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(try store.trashMemberships(for: .codex).count, 1)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 0)
    }

    func testUnknownPinEvidenceCannotCreateProductionPreview() async throws {
        let fixture = try makeFixture(
            protection: SessionProtection(
                isPinnedKnown: false,
                isRunningKnown: false,
                isCurrentKnown: false
            )
        )
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        do {
            _ = try await coordinator.prepare(
                managerKey: fixture.session.id,
                snapshot: fixture.snapshot,
                checkpoint: fixture.checkpoint
            )
            XCTFail("Unknown pin evidence must fail before Preview persistence.")
        } catch let error as PersistentStateError {
            guard case .invalidRecord = error else {
                return XCTFail("Unexpected persistence error: \(error)")
            }
        }

        XCTAssertNil(try store.operationPreview(id: previewID))
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    func testUnauditedRuntimeCannotCreateProductionPreview() async throws {
        let fixture = try makeFixture(runtime: "0.150.0")
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        do {
            _ = try await coordinator.prepare(
                managerKey: fixture.session.id,
                snapshot: fixture.snapshot,
                checkpoint: fixture.checkpoint
            )
            XCTFail("An unaudited runtime must fail before Preview persistence.")
        } catch let error as SessionManagerError {
            guard case .unsupportedOperation(let message) = error else {
                return XCTFail("Unexpected operation error: \(error)")
            }
            XCTAssertEqual(
                message,
                "Archive is unavailable because Codex runtime 0.150.0 is outside this version of Agent Session Manager's audited lifecycle allow-list. Open Settings → Compatibility and run the isolated tests to verify this installation. No Archive request was sent."
            )
            XCTAssertFalse(error.localizedDescription.contains("persistent state"))
        }

        XCTAssertNil(try store.operationPreview(id: previewID))
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    func testBusyRejectionIsPersistedAsFailureWithoutRetry() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: try readbackSnapshot(state: .active),
            archiveError: CodexAppServerError.rpcError(
                -32600,
                "thread \(nativeID) already has an active writer"
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

        XCTAssertEqual(report.outcome, .failure, report.items[0].message ?? "no message")
        XCTAssertEqual(report.items[0].observedNativeState, .active)
        XCTAssertEqual(report.items[0].errorCode, "archive_request_busy_active_writer")
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 2)
        XCTAssertEqual(counts.archive, 1)
    }

    func testRecoveryFacadeUsesProvidedSnapshotAndNeverResendsArchive() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
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
        let recovery = CodexNativeArchiveRecoveryCoordinator(store: store)

        let recovered = try await recovery.recoverPending(
            using: readbackSnapshot(state: .archived)
        )
        let report = try XCTUnwrap(recovered)

        XCTAssertTrue(report.recoveredAfterInterruption)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items[0].nativeSessionID, nativeID)
        XCTAssertEqual(report.items[0].observedNativeState, .archived)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .consumed)
        let secondRecovery = try await recovery.recoverPending(using: fixture.snapshot)
        XCTAssertNil(secondRecovery)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    func testRecoveryFacadeFailsClosedForMultipleExecutingPreviews() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(fixture.checkpoint)
        let transport = NativeArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKey: fixture.session.id,
            snapshot: fixture.snapshot,
            checkpoint: fixture.checkpoint
        )
        let claimed = try store.claimOperationPreviewForExecution(
            id: preview.id,
            now: observedAt.addingTimeInterval(31),
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                preview.confirmationToken
            )
        ).preview
        let duplicate = PersistentOperationPreview(
            id: UUID(uuidString: "a11f0000-0000-4000-8000-000000000003")!,
            provider: claimed.provider,
            operation: claimed.operation,
            confirmationTokenHash: claimed.confirmationTokenHash,
            manifestHash: claimed.manifestHash,
            providerInventoryHash: claimed.providerInventoryHash,
            affectedSetHash: claimed.affectedSetHash,
            createdAt: claimed.createdAt,
            expiresAt: claimed.expiresAt,
            items: claimed.items
        )
        try store.saveOperationPreview(duplicate, checkpoint: fixture.checkpoint)
        _ = try store.claimOperationPreviewForExecution(
            id: duplicate.id,
            now: observedAt.addingTimeInterval(31),
            confirmationTokenHash: duplicate.confirmationTokenHash
        )
        let recovery = CodexNativeArchiveRecoveryCoordinator(store: store)

        do {
            _ = try await recovery.recoverPending(using: fixture.snapshot)
            XCTFail("Multiple executing Previews must not be recovered by choosing one.")
        } catch let error as SessionManagerError {
            guard case .unsupportedOperation(let message) = error else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
            XCTAssertTrue(message.contains("multiple"))
        }

        XCTAssertEqual(try store.executingOperationPreviews(for: .codex).count, 2)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    private func makeFixture(
        protection: SessionProtection = SessionProtection(
            isRunningKnown: false,
            isCurrentKnown: false
        ),
        runtime: String? = nil,
        observationTime: Date? = nil
    ) throws -> (
        session: AgentSession,
        snapshot: ProviderInventorySnapshot,
        checkpoint: ProviderCheckpointRecord
    ) {
        let observedAt = observationTime ?? self.observedAt
        let session = AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: "Production facade fixture",
            workingDirectory: "/Users/example/Project",
            updatedAt: observedAt,
            sizeBytes: nil,
            nativeState: .active,
            protection: protection,
            descendantCount: 0,
            descendantCountKnown: true
        )
        let scope = ArchiveScopeNode(
            managerKey: session.id,
            nativeSessionID: session.nativeID,
            title: session.title,
            nativeState: .active,
            protection: protection,
            descendantCount: 0,
            descendantCountKnown: true,
            workingDirectory: session.workingDirectory
        )
        let hash = try InventorySnapshotHasher.hash(
            provider: .codex,
            sessions: [session],
            archiveScopeNodes: [scope],
            archiveScopeComplete: true
        )
        let snapshot = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtime ?? self.runtime,
            inventoryHash: hash,
            observedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: false,
            sessions: [session],
            archiveScopeNodes: [scope],
            archiveScopeComplete: true
        )
        return (session, snapshot, snapshot.checkpoint)
    }

    private func readbackSnapshot(state: NativeSessionState) throws -> ProviderInventorySnapshot {
        let session = AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: "Production facade fixture",
            workingDirectory: "/Users/example/Project",
            updatedAt: observedAt,
            sizeBytes: nil,
            nativeState: state,
            protection: SessionProtection(
                isRunningKnown: false,
                isCurrentKnown: false
            ),
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
            observedAt: observedAt.addingTimeInterval(40),
            inventoryComplete: true,
            protectionComplete: false,
            sessions: [session]
        )
    }

    private func makeMembership(
        fixture: (
            session: AgentSession,
            snapshot: ProviderInventorySnapshot,
            checkpoint: ProviderCheckpointRecord
        )
    ) -> TrashMembershipRecord {
        TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: fixture.session.nativeID,
            managerKey: fixture.session.id,
            titleAtEntry: fixture.session.title,
            workingDirectoryAtEntry: fixture.session.workingDirectory,
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: fixture.checkpoint.inventoryHash,
            enteredAt: observedAt.addingTimeInterval(-20),
            lastReconciledAt: observedAt
        )
    }

    private func makeConflictState(
        fixture: (
            session: AgentSession,
            snapshot: ProviderInventorySnapshot,
            checkpoint: ProviderCheckpointRecord
        ),
        membership: TrashMembershipRecord
    ) -> ReconciledSessionState {
        ReconciledSessionState(
            managerKey: fixture.session.id,
            liveSession: fixture.session,
            trashMembership: membership,
            status: .nativeActiveTrashConflict,
            isStableForLifecyclePreview: false
        )
    }

    private func makeCoordinator(
        store: SQLiteStateStore,
        transport: NativeArchiveTransportStub,
        executionGate: any CodexLifecycleExecutionChecking = LifecycleExecutionGateStub()
    ) -> CodexNativeArchiveCoordinator {
        CodexNativeArchiveCoordinator(
            store: store,
            transport: transport,
            executionGate: executionGate,
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
            "native-archive-facade-\(safeName)-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStateStore(
            databaseURL: directory.appendingPathComponent("manager.sqlite3")
        )
    }
}

private actor NativeArchiveTransportStub: ArchiveMutationTransport {
    struct Counts: Sendable {
        let inventory: Int
        let archive: Int
        let archiveIDs: [String]
    }

    private let preflight: ProviderInventorySnapshot
    private let readback: ProviderInventorySnapshot
    private let archiveError: Error?
    private let onArchive: @Sendable () throws -> Void
    private var inventoryCalls = 0
    private var archiveCalls = 0
    private var archiveIDs: [String] = []

    init(
        preflight: ProviderInventorySnapshot,
        readback: ProviderInventorySnapshot,
        archiveError: Error? = nil,
        onArchive: @escaping @Sendable () throws -> Void = {}
    ) {
        self.preflight = preflight
        self.readback = readback
        self.archiveError = archiveError
        self.onArchive = onArchive
    }

    func inventorySnapshot() throws -> ProviderInventorySnapshot {
        inventoryCalls += 1
        return inventoryCalls == 1 ? preflight : readback
    }

    func archive(nativeSessionID: String) throws {
        archiveCalls += 1
        archiveIDs.append(nativeSessionID)
        try onArchive()
        if let archiveError { throw archiveError }
    }

    func callCounts() -> Counts {
        Counts(
            inventory: inventoryCalls,
            archive: archiveCalls,
            archiveIDs: archiveIDs
        )
    }
}
