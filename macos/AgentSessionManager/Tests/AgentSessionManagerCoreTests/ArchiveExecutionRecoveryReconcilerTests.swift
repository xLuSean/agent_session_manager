import XCTest
@testable import AgentSessionManagerCore

final class ArchiveExecutionRecoveryReconcilerTests: XCTestCase {
    private let nativeID = "01900000-0000-7000-8000-000000000001"
    private let token = "ARCHIVE-RECOVERY"
    private let runtime = "0.147.0"
    private let createdAt = Date(timeIntervalSince1970: 1_800_200_000)
    private let reportID = UUID(uuidString: "a11e0000-0000-4000-8000-000000000001")!

    func testArchivedReadbackPersistsSuccessAndConsumesExecutingPreview() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedExecuting(fixture, in: store)
        let source = RecoveryReadbackQueue(results: [
            .success(snapshot(sessions: [session(state: .archived)])),
        ])
        let reconciler = makeReconciler(store: store, source: source)

        let report = try await reconciler.reconcile(previewID: fixture.preview.id)

        XCTAssertEqual(report.id, reportID)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items[0].outcome, .success)
        XCTAssertEqual(report.items[0].observedNativeState, .archived)
        XCTAssertEqual(report.items[0].verifiedReleasedBytes, 0)
        XCTAssertTrue(report.releasedBytesComplete)
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .consumed)
        XCTAssertEqual(try store.operationReport(id: reportID), report)
        let callCount = await source.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testProvidedSnapshotRecoveryDoesNotInvokeReadbackSource() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedExecuting(fixture, in: store)
        let source = RecoveryReadbackQueue(results: [.failure(.unavailable)])
        let reconciler = makeReconciler(store: store, source: source)

        let report = try await reconciler.reconcile(
            previewID: fixture.preview.id,
            snapshot: snapshot(sessions: [session(state: .archived)])
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .consumed)
        let callCount = await source.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testRecoveryAcceptsOriginalArchiveCheckpointWithIncompleteAggregateProtection() async throws {
        let fixture = try makeFixture(protectionComplete: false)
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedExecuting(fixture, in: store)
        let source = RecoveryReadbackQueue(results: [
            .success(snapshot(sessions: [session(state: .archived)])),
        ])

        let report = try await makeReconciler(store: store, source: source)
            .reconcile(previewID: fixture.preview.id)

        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .consumed)
        let callCount = await source.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testActiveReadbackPersistsUnknownWithoutRetryingMutation() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedExecuting(fixture, in: store)
        let source = RecoveryReadbackQueue(results: [
            .success(snapshot(sessions: [session()])),
        ])

        let report = try await makeReconciler(store: store, source: source)
            .reconcile(previewID: fixture.preview.id)

        XCTAssertEqual(report.outcome, .unknown)
        XCTAssertEqual(report.errorCode, "archive_recovery_still_active")
        XCTAssertEqual(report.items[0].observedNativeState, .active)
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .consumed)
        let callCount = await source.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testMissingIdentityInCompleteInventoryPersistsUnknownAbsentEvidence() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedExecuting(fixture, in: store)
        let source = RecoveryReadbackQueue(results: [.success(snapshot(sessions: []))])

        let report = try await makeReconciler(store: store, source: source)
            .reconcile(previewID: fixture.preview.id)

        XCTAssertEqual(report.outcome, .unknown)
        XCTAssertEqual(report.errorCode, "archive_recovery_identity_missing")
        XCTAssertEqual(report.items[0].observedNativeState, .unavailable)
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .consumed)
    }

    func testIncompleteReadbackLeavesExecutingAndLaterReadOnlyRetryCanResolve() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedExecuting(fixture, in: store)
        let source = RecoveryReadbackQueue(results: [
            .success(snapshot(sessions: [session()], complete: false)),
            .success(snapshot(sessions: [session(state: .archived)])),
        ])
        let reconciler = makeReconciler(store: store, source: source)

        do {
            _ = try await reconciler.reconcile(previewID: fixture.preview.id)
            XCTFail("Expected incomplete recovery evidence to fail closed.")
        } catch let error as ArchiveExecutionRecoveryError {
            guard case .evidenceUnavailable = error else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
        }
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .executing)
        XCTAssertNil(try store.operationReport(id: reportID))

        let report = try await reconciler.reconcile(previewID: fixture.preview.id)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .consumed)
        let callCount = await source.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testReadbackFailureLeavesExecutingAndCanRetryReadbackOnly() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedExecuting(fixture, in: store)
        let source = RecoveryReadbackQueue(results: [
            .failure(.unavailable),
            .success(snapshot(sessions: [session(state: .archived)])),
        ])
        let reconciler = makeReconciler(store: store, source: source)

        do {
            _ = try await reconciler.reconcile(previewID: fixture.preview.id)
            XCTFail("Expected injected inventory failure.")
        } catch {
            XCTAssertEqual(error as? RecoveryReadbackQueue.Failure, .unavailable)
        }
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .executing)

        let report = try await reconciler.reconcile(previewID: fixture.preview.id)
        XCTAssertEqual(report.outcome, .success)
        let callCount = await source.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testRuntimeMismatchAndStaleReadbackBothLeaveExecuting() async throws {
        for (name, readback) in [
            ("runtime", snapshot(sessions: [session()], runtime: "0.148.0")),
            ("stale", snapshot(
                sessions: [session()],
                observedAt: createdAt.addingTimeInterval(-1)
            )),
        ] {
            let fixture = try makeFixture()
            let store = try makeStore(named: #function + name)
            defer { store.close() }
            try seedExecuting(fixture, in: store)
            let source = RecoveryReadbackQueue(results: [.success(readback)])

            do {
                _ = try await makeReconciler(store: store, source: source)
                    .reconcile(previewID: fixture.preview.id)
                XCTFail("Expected \(name) evidence to fail closed.")
            } catch let error as ArchiveExecutionRecoveryError {
                guard case .evidenceUnavailable = error else {
                    return XCTFail("Unexpected recovery error: \(error)")
                }
            }
            XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .executing)
            XCTAssertNil(try store.operationReport(id: reportID))
        }
    }

    func testRepositoryPreventsClaimCheckpointReplacementWhileExecuting() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedExecuting(fixture, in: store)
        XCTAssertThrowsError(
            try store.upsertProviderCheckpoint(ProviderCheckpointRecord(
                provider: .codex,
                runtimeVersion: runtime,
                inventoryHash: "newer-normal-refresh",
                refreshedAt: createdAt.addingTimeInterval(20),
                inventoryComplete: true,
                protectionComplete: true
            ))
        ) { error in
            XCTAssertEqual(
                error as? PersistentStateError,
                .invalidRecord(
                    "Provider checkpoint cannot change while execution recovery is unresolved."
                )
            )
        }
        let source = RecoveryReadbackQueue(results: [
            .success(snapshot(sessions: [session(state: .archived)])),
        ])

        let report = try await makeReconciler(store: store, source: source)
            .reconcile(previewID: fixture.preview.id)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(try store.operationPreview(id: fixture.preview.id)?.status, .consumed)
        let callCount = await source.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testPreparedAndConsumedPreviewsAreRejectedBeforeReadback() async throws {
        let fixture = try makeFixture()
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.saveOperationPreview(fixture.preview, checkpoint: fixture.checkpoint)
        let source = RecoveryReadbackQueue(results: [
            .success(snapshot(sessions: [session(state: .archived)])),
        ])
        let reconciler = makeReconciler(store: store, source: source)

        do {
            _ = try await reconciler.reconcile(previewID: fixture.preview.id)
            XCTFail("Expected a prepared Preview to be rejected.")
        } catch let error as ArchiveExecutionRecoveryError {
            guard case .invalidPreview = error else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
        }
        let preparedCallCount = await source.callCount()
        XCTAssertEqual(preparedCallCount, 0)

        _ = try store.claimOperationPreviewForExecution(
            id: fixture.preview.id,
            now: createdAt.addingTimeInterval(10),
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(token)
        )
        _ = try await reconciler.reconcile(previewID: fixture.preview.id)
        do {
            _ = try await reconciler.reconcile(previewID: fixture.preview.id)
            XCTFail("Expected a consumed Preview to reject replay.")
        } catch let error as ArchiveExecutionRecoveryError {
            guard case .invalidPreview = error else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
        }
        let consumedCallCount = await source.callCount()
        XCTAssertEqual(consumedCallCount, 1)
    }

    private func makeFixture(protectionComplete: Bool = true) throws -> (
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord
    ) {
        let active = session()
        let inventoryHash = try InventorySnapshotHasher.hash(provider: .codex, sessions: [active])
        let checkpoint = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: runtime,
            inventoryHash: inventoryHash,
            refreshedAt: createdAt,
            inventoryComplete: true,
            protectionComplete: protectionComplete
        )
        let item = PersistentPreviewItem(
            managerKey: active.id,
            nativeSessionID: active.nativeID,
            expectedNativeState: .active,
            expectedProtectionHash: try ArchiveExecutionHasher.protectionHash(for: active),
            expectedTitle: active.title
        )
        let expiresAt = createdAt.addingTimeInterval(300)
        return (
            PersistentOperationPreview(
                id: UUID(uuidString: "a11e0000-0000-4000-8000-000000000002")!,
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
            ),
            checkpoint
        )
    }

    private func seedExecuting(
        _ fixture: (preview: PersistentOperationPreview, checkpoint: ProviderCheckpointRecord),
        in store: SQLiteStateStore
    ) throws {
        try store.saveOperationPreview(fixture.preview, checkpoint: fixture.checkpoint)
        _ = try store.claimOperationPreviewForExecution(
            id: fixture.preview.id,
            now: createdAt.addingTimeInterval(10),
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(token)
        )
    }

    private func makeReconciler(
        store: SQLiteStateStore,
        source: RecoveryReadbackQueue
    ) -> ArchiveExecutionRecoveryReconciler {
        ArchiveExecutionRecoveryReconciler(
            store: store,
            readback: source,
            makeReportID: { self.reportID }
        )
    }

    private func session(state: NativeSessionState = .active) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: "Recovery fixture",
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
        sessions: [AgentSession],
        runtime: String? = nil,
        observedAt: Date? = nil,
        complete: Bool = true
    ) -> ProviderInventorySnapshot {
        ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtime ?? self.runtime,
            inventoryHash: "recovery-inventory",
            observedAt: observedAt ?? createdAt.addingTimeInterval(40),
            inventoryComplete: complete,
            protectionComplete: false,
            sessions: sessions
        )
    }

    private func makeStore(named name: String) throws -> SQLiteStateStore {
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-recovery-\(safeName)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: directory.appendingPathComponent("manager.sqlite3"))
    }
}

private actor RecoveryReadbackQueue: ArchiveExecutionRecoveryReadback {
    enum Failure: Error, Equatable {
        case unavailable
    }

    private var results: [Result<ProviderInventorySnapshot, Failure>]
    private var calls = 0

    init(results: [Result<ProviderInventorySnapshot, Failure>]) {
        self.results = results
    }

    func inventorySnapshot() throws -> ProviderInventorySnapshot {
        calls += 1
        guard !results.isEmpty else { throw Failure.unavailable }
        return try results.removeFirst().get()
    }

    func callCount() -> Int {
        calls
    }
}
