import XCTest
@testable import AgentSessionManagerCore

final class ArchiveAuthorizationCoordinatorTests: XCTestCase {
    private let nativeID = "01900000-0000-7000-8000-000000000001"
    private let token = "ARCHIVE-COORDINATOR"
    private let runtime = "0.147.0"
    private let createdAt = Date(timeIntervalSince1970: 1_800_100_000)
    private let reportID = UUID(uuidString: "a11d0000-0000-4000-8000-000000000001")!

    func testPersistsAndClaimsPreviewBeforeArchiveThenPersistsReport() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        let transport = CoordinatorArchiveTransport(
            preflight: fixture.snapshot,
            readback: snapshot(session: session(state: .archived), hash: "post-archive"),
            store: store,
            observedPreviewID: fixture.preview.id
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        let persisted = try await coordinator.prepare(
            fixture.preview,
            checkpoint: fixture.checkpoint
        )
        XCTAssertEqual(persisted, fixture.preview)
        let report = try await coordinator.execute(
            previewID: fixture.preview.id,
            confirmationToken: token
        )

        XCTAssertEqual(report.id, reportID)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.map(\.managerKey), [fixture.preview.items[0].managerKey])
        XCTAssertEqual(report.items[0].observedNativeState, .archived)
        XCTAssertEqual(report.items[0].verifiedReleasedBytes, 0)
        XCTAssertTrue(report.releasedBytesComplete)
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .consumed)
        XCTAssertEqual(try store.operationReport(id: reportID), report)

        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 2)
        XCTAssertEqual(counts.archive, 1)
        XCTAssertEqual(counts.statusObservedAtArchive, .executing)
    }

    func testWrongConfirmationLeavesPreparedPreviewAndMakesNoProviderCall() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        let transport = CoordinatorArchiveTransport(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        _ = try await coordinator.prepare(fixture.preview, checkpoint: fixture.checkpoint)
        do {
            _ = try await coordinator.execute(
                previewID: fixture.preview.id,
                confirmationToken: "WRONG"
            )
            XCTFail("Expected confirmation mismatch.")
        } catch {
            XCTAssertEqual(error as? PersistentStateError, .confirmationMismatch)
        }
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .prepared)
        XCTAssertNil(try store.operationReport(id: reportID))
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    func testUnknownExecutorOutcomeIsPersistedAndConsumesPreview() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        let transport = CoordinatorArchiveTransport(
            preflight: fixture.snapshot,
            readback: snapshot(session: session(), hash: "still-active")
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        _ = try await coordinator.prepare(fixture.preview, checkpoint: fixture.checkpoint)
        let report = try await coordinator.execute(
            previewID: fixture.preview.id,
            confirmationToken: token
        )

        XCTAssertEqual(report.outcome, .unknown)
        XCTAssertEqual(report.errorCode, "archive_not_observed")
        XCTAssertEqual(report.items[0].outcome, .unknown)
        XCTAssertEqual(report.items[0].observedNativeState, .active)
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .consumed)
        XCTAssertEqual(try store.operationReport(id: report.id), report)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)
    }

    func testConsumedPreviewCannotReplayArchive() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        let transport = CoordinatorArchiveTransport(
            preflight: fixture.snapshot,
            readback: snapshot(session: session(state: .archived), hash: "post-archive")
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        _ = try await coordinator.prepare(fixture.preview, checkpoint: fixture.checkpoint)
        _ = try await coordinator.execute(
            previewID: fixture.preview.id,
            confirmationToken: token
        )
        do {
            _ = try await coordinator.execute(
                previewID: fixture.preview.id,
                confirmationToken: token
            )
            XCTFail("Expected the persisted Preview identity to reject replay.")
        } catch {
            // A duplicate immutable Preview is the intended durable replay gate.
        }

        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)
    }

    func testReportPersistenceFailureLeavesExecutingPreviewForReconciliation() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        let databaseURL = store.databaseURL
        let transport = CoordinatorArchiveTransport(
            preflight: fixture.snapshot,
            readback: snapshot(session: session(state: .archived), hash: "post-archive"),
            closeStoreAfterReadback: store
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        do {
            _ = try await coordinator.prepare(fixture.preview, checkpoint: fixture.checkpoint)
            _ = try await coordinator.execute(
                previewID: fixture.preview.id,
                confirmationToken: token
            )
            XCTFail("Expected Report persistence to fail after the injected store close.")
        } catch let error as ArchiveAuthorizationCoordinatorError {
            guard case let .reportPersistenceFailed(previewID, outcome, _) = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
            XCTAssertEqual(previewID, fixture.preview.id)
            XCTAssertEqual(outcome, .success)
        }

        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)

        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.operationPreview(id: fixture.preview.id)?.status, .executing)
        XCTAssertNil(try reopened.operationReport(id: reportID))
        XCTAssertThrowsError(
            try reopened.claimOperationPreviewForExecution(
                id: fixture.preview.id,
                now: createdAt.addingTimeInterval(50),
                confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(token)
            )
        )
    }

    func testCheckpointDriftPreventsClaimAndLeavesPreviewPrepared() throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.saveOperationPreview(fixture.preview, checkpoint: fixture.checkpoint)
        try store.upsertProviderCheckpoint(ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: runtime,
            inventoryHash: "newer-inventory",
            refreshedAt: createdAt.addingTimeInterval(20),
            inventoryComplete: true,
            protectionComplete: true
        ))

        XCTAssertThrowsError(
            try store.claimOperationPreviewForExecution(
                id: fixture.preview.id,
                now: createdAt.addingTimeInterval(30),
                confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(token)
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentStateError,
                .invalidRecord("Provider checkpoint drifted after Preview persistence.")
            )
        }
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .prepared)
    }

    func testFractionalCheckpointTimestampSurvivesSQLiteManifestRoundTrip() async throws {
        let fixture = try makeFixture()
        let fractionalCheckpointDate = createdAt.addingTimeInterval(0.123456)
        let checkpoint = ProviderCheckpointRecord(
            provider: fixture.checkpoint.provider,
            runtimeVersion: fixture.checkpoint.runtimeVersion,
            inventoryHash: fixture.checkpoint.inventoryHash,
            refreshedAt: fractionalCheckpointDate,
            inventoryComplete: true,
            protectionComplete: true
        )
        let preview = PersistentOperationPreview(
            id: fixture.preview.id,
            provider: fixture.preview.provider,
            operation: fixture.preview.operation,
            confirmationTokenHash: fixture.preview.confirmationTokenHash,
            manifestHash: try ArchiveExecutionHasher.manifestHash(
                provider: fixture.preview.provider,
                operation: fixture.preview.operation,
                providerInventoryHash: fixture.preview.providerInventoryHash,
                runtimeVersion: runtime,
                reconciliationTimestamp: fractionalCheckpointDate,
                createdAt: fixture.preview.createdAt,
                expiresAt: fixture.preview.expiresAt,
                items: fixture.preview.items
            ),
            providerInventoryHash: fixture.preview.providerInventoryHash,
            createdAt: fixture.preview.createdAt,
            expiresAt: fixture.preview.expiresAt,
            items: fixture.preview.items
        )
        let store = try makeStore(named: #function)
        defer { store.close() }
        let transport = CoordinatorArchiveTransport(
            preflight: fixture.snapshot,
            readback: snapshot(session: session(state: .archived), hash: "post-archive")
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        _ = try await coordinator.prepare(preview, checkpoint: checkpoint)
        let report = try await coordinator.execute(
            previewID: preview.id,
            confirmationToken: token
        )

        XCTAssertEqual(report.outcome, .success)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)
    }

    func testPrepareRejectsNonArchiveOperationWithoutPersisting() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        let transport = CoordinatorArchiveTransport(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        let wrongOperation = PersistentOperationPreview(
            id: fixture.preview.id,
            provider: fixture.preview.provider,
            operation: .moveToTrash,
            confirmationTokenHash: fixture.preview.confirmationTokenHash,
            manifestHash: fixture.preview.manifestHash,
            providerInventoryHash: fixture.preview.providerInventoryHash,
            createdAt: fixture.preview.createdAt,
            expiresAt: fixture.preview.expiresAt,
            items: fixture.preview.items
        )

        do {
            _ = try await coordinator.prepare(wrongOperation, checkpoint: fixture.checkpoint)
            XCTFail("Expected the Archive coordinator to reject another operation.")
        } catch {
            XCTAssertEqual(
                error as? PersistentStateError,
                .invalidRecord("The Archive coordinator requires one active Codex item.")
            )
        }
        XCTAssertNil(try store.operationPreview(id: fixture.preview.id))
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    private func makeCoordinator(
        store: SQLiteStateStore,
        transport: CoordinatorArchiveTransport
    ) -> ArchiveAuthorizationCoordinator {
        ArchiveAuthorizationCoordinator(
            store: store,
            executor: ArchiveMutationExecutor(
                transport: transport,
                now: { self.createdAt.addingTimeInterval(30) }
            ),
            now: { self.createdAt.addingTimeInterval(30) },
            makeReportID: { self.reportID }
        )
    }

    private func makeFixture() throws -> (
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        snapshot: ProviderInventorySnapshot
    ) {
        let active = session()
        let inventoryHash = try InventorySnapshotHasher.hash(provider: .codex, sessions: [active])
        let checkpoint = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: runtime,
            inventoryHash: inventoryHash,
            refreshedAt: createdAt,
            inventoryComplete: true,
            protectionComplete: true
        )
        let item = PersistentPreviewItem(
            managerKey: active.id,
            nativeSessionID: active.nativeID,
            expectedNativeState: .active,
            expectedProtectionHash: try ArchiveExecutionHasher.protectionHash(for: active),
            expectedTitle: active.title
        )
        let expiresAt = createdAt.addingTimeInterval(300)
        let preview = PersistentOperationPreview(
            id: UUID(uuidString: "a11d0000-0000-4000-8000-000000000002")!,
            provider: .codex,
            operation: .archive,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(token),
            manifestHash: try ArchiveExecutionHasher.manifestHash(
                provider: .codex,
                operation: .archive,
                providerInventoryHash: inventoryHash,
                runtimeVersion: runtime,
                reconciliationTimestamp: createdAt,
                createdAt: createdAt,
                expiresAt: expiresAt,
                items: [item]
            ),
            providerInventoryHash: inventoryHash,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: [item]
        )
        return (
            preview,
            checkpoint,
            snapshot(session: active, hash: inventoryHash)
        )
    }

    private func session(state: NativeSessionState = .active) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: "Coordinator fixture",
            workingDirectory: "/Users/example/Project",
            updatedAt: createdAt,
            sizeBytes: nil,
            nativeState: state,
            protection: SessionProtection(),
            descendantCount: 0,
            descendantCountKnown: true
        )
    }

    private func snapshot(
        session: AgentSession,
        hash: String
    ) -> ProviderInventorySnapshot {
        ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtime,
            inventoryHash: hash,
            observedAt: createdAt.addingTimeInterval(40),
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [session]
        )
    }

    private func makeStore(named name: String) throws -> SQLiteStateStore {
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-coordinator-\(safeName)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: directory.appendingPathComponent("manager.sqlite3"))
    }
}

private actor CoordinatorArchiveTransport: ArchiveMutationTransport {
    struct Counts: Sendable {
        let inventory: Int
        let archive: Int
        let statusObservedAtArchive: PersistentPreviewStatus?
    }

    private let preflight: ProviderInventorySnapshot
    private let readback: ProviderInventorySnapshot
    private let store: SQLiteStateStore?
    private let observedPreviewID: UUID?
    private let closeStoreAfterReadback: SQLiteStateStore?
    private var inventoryCalls = 0
    private var archiveCalls = 0
    private var statusObservedAtArchive: PersistentPreviewStatus?

    init(
        preflight: ProviderInventorySnapshot,
        readback: ProviderInventorySnapshot,
        store: SQLiteStateStore? = nil,
        observedPreviewID: UUID? = nil,
        closeStoreAfterReadback: SQLiteStateStore? = nil
    ) {
        self.preflight = preflight
        self.readback = readback
        self.store = store
        self.observedPreviewID = observedPreviewID
        self.closeStoreAfterReadback = closeStoreAfterReadback
    }

    func inventorySnapshot() throws -> ProviderInventorySnapshot {
        inventoryCalls += 1
        if inventoryCalls == 2 {
            closeStoreAfterReadback?.close()
            return readback
        }
        return preflight
    }

    func archive(nativeSessionID: String) throws {
        archiveCalls += 1
        if let store, let observedPreviewID {
            statusObservedAtArchive = try store.operationPreview(id: observedPreviewID)?.status
        }
    }

    func callCounts() -> Counts {
        Counts(
            inventory: inventoryCalls,
            archive: archiveCalls,
            statusObservedAtArchive: statusObservedAtArchive
        )
    }
}
