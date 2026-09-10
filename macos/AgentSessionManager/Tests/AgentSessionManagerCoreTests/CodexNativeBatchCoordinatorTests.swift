import XCTest
import CSQLite3
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
        ], at: baseTime.addingTimeInterval(20), protectionComplete: false)
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
        XCTAssertEqual(calls.fullInventoryCount, 1)
        XCTAssertEqual(calls.readbackCount, 2)
        XCTAssertFalse(calls.archive.contains(sessions[2].nativeID))
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .consumed)
    }

    func testIncompleteLifecycleReadbackStopsBatchWithoutRetryOrFullInventoryFallback() async throws {
        let sessions = [session(1, state: .active), session(2, state: .active)]
        let initial = snapshot(sessions, at: baseTime)
        let transport = NativeBatchTransportStub(inventories: [
            snapshot(sessions, at: baseTime.addingTimeInterval(1)),
            snapshot([session(1, state: .archived)], at: baseTime.addingTimeInterval(20),
                     inventoryComplete: false),
        ])
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(initial.checkpoint)
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(
            managerKeys: Set(sessions.map(\.id)), operation: .archive,
            snapshot: initial, checkpoint: initial.checkpoint
        )
        let report = try await coordinator.execute(preview: preview, confirmationToken: preview.confirmationToken)
        XCTAssertEqual(report.items[0].outcome, .unknown)
        XCTAssertEqual(report.items[1].errorCode, "batch_not_attempted")
        let calls = await transport.calls()
        XCTAssertEqual(calls.archive, [sessions[0].nativeID])
        XCTAssertEqual(calls.fullInventoryCount, 1)
        XCTAssertEqual(calls.readbackCount, 1)
    }

    func testRunningCodexBlocksBatchBeforeClaimOrProviderRequest() async throws {
        let sessions = [
            session(1, state: .active),
            session(2, state: .active),
        ]
        let checkpointSnapshot = snapshot(sessions, at: baseTime)
        let transport = NativeBatchTransportStub(inventories: [])
        let store = try makeStore(named: #function)
        defer { store.close() }
        try store.upsertProviderCheckpoint(checkpointSnapshot.checkpoint)
        let gate = LifecycleExecutionGateStub(
            error: .codexDesktopRunning(processKinds: [.codexHelper])
        )
        let coordinator = makeCoordinator(
            store: store,
            transport: transport,
            executionGate: gate
        )
        let preview = try await coordinator.prepare(
            managerKeys: Set(sessions.map(\.id)),
            operation: .archive,
            snapshot: checkpointSnapshot,
            checkpoint: checkpointSnapshot.checkpoint
        )

        do {
            _ = try await coordinator.execute(
                preview: preview,
                confirmationToken: preview.confirmationToken
            )
            XCTFail("Running Codex must block before batch Preview claim.")
        } catch let error as CodexLifecycleExecutionGateError {
            XCTAssertEqual(
                error,
                .codexDesktopRunning(processKinds: [.codexHelper])
            )
        }

        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .prepared)
        let gateCalls = await gate.observedCallCount()
        XCTAssertEqual(gateCalls, 1)
        let calls = await transport.calls()
        XCTAssertTrue(calls.archive.isEmpty)
        XCTAssertTrue(calls.restore.isEmpty)
        XCTAssertTrue(calls.delete.isEmpty)
        XCTAssertTrue(calls.exactRead.isEmpty)
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

    func testDeleteRejectsDriftedOrStaleReadbackWithoutTombstoneOrRetry() async throws {
        for variant in 0..<5 {
            let sessions = [session(1, state: .archived), session(2, state: .archived)]
            let initial = snapshot(sessions, at: baseTime)
            let store = try makeStore(named: "\(#function)-\(variant)")
            defer { store.close() }
            try seedTrash(sessions, snapshot: initial, store: store)
            let after = snapshot([sessions[1]], at: baseTime.addingTimeInterval(20),
                                 runtimeVersion: variant == 0 ? "0.153.4" : runtime)
            let exact: DeleteExactReadObservation = .absent(
                nativeSessionID: variant == 4 ? sessions[1].nativeID : sessions[0].nativeID,
                observedAt: baseTime.addingTimeInterval(variant == 2 ? 9 : 20),
                runtimeVersion: variant == 1 ? "0.153.4" : variant == 3 ? "" : runtime)
            let transport = NativeBatchTransportStub(inventories: [
                snapshot(sessions, at: baseTime.addingTimeInterval(1)), after,
            ], exactObservation: exact)
            let coordinator = makeCoordinator(store: store, transport: transport)
            let preview = try await coordinator.prepare(managerKeys: Set(sessions.map(\.id)),
                operation: .emptyTrash, snapshot: initial, checkpoint: initial.checkpoint)
            let report = try await coordinator.execute(preview: preview, confirmationToken: preview.confirmationToken)
            XCTAssertEqual(report.items[0].outcome, .unknown, "variant \(variant)")
            XCTAssertEqual(report.items[1].errorCode, "batch_not_attempted")
            XCTAssertTrue(try store.deletedSessions(for: .codex).isEmpty)
            XCTAssertEqual(try store.trashMemberships(for: .codex).count, 2)
            let calls = await transport.calls()
            XCTAssertEqual(calls.delete, [sessions[0].nativeID])
        }
    }

    func testRecoveryRejectsDriftedOrStaleEvidenceWithoutMutation() async throws {
        for variant in 0..<6 {
            let sessions = [session(1, state: .archived), session(2, state: .archived)]
            let initial = snapshot(sessions, at: baseTime)
            let store = try makeStore(named: "\(#function)-\(variant)")
            defer { store.close() }
            try seedTrash(sessions, snapshot: initial, store: store)
            let transport = NativeBatchTransportStub(inventories: [],
                exactRuntime: variant == 3 ? "0.153.4" : nil,
                exactTime: variant == 4 ? baseTime : nil)
            let coordinator = makeCoordinator(store: store, transport: transport)
            let preview = try await coordinator.prepare(managerKeys: Set(sessions.map(\.id)),
                operation: .emptyTrash, snapshot: initial, checkpoint: initial.checkpoint)
            _ = try store.claimOperationPreviewForExecution(id: preview.id,
                now: baseTime.addingTimeInterval(10),
                confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(preview.confirmationToken))
            let observed = ProviderInventorySnapshot(provider: variant == 2 ? .claudeCode : .codex,
                runtimeVersion: variant == 0 ? "0.153.4" : runtime,
                inventoryHash: "recovery", observedAt: variant == 1 ? baseTime : baseTime.addingTimeInterval(20),
                inventoryComplete: variant != 5, protectionComplete: false, sessions: [], archiveScopeComplete: true)
            let recovered = try await coordinator.recoverPending(using: observed)
            let report = try XCTUnwrap(recovered)
            XCTAssertTrue(report.items.allSatisfy { $0.outcome == .unknown }, "variant \(variant)")
            XCTAssertTrue(try store.deletedSessions(for: .codex).isEmpty)
            XCTAssertEqual(try store.trashMemberships(for: .codex).count, 2)
            let calls = await transport.calls()
            XCTAssertTrue(calls.delete.isEmpty && calls.archive.isEmpty && calls.restore.isEmpty)
            if [0, 1, 2, 5].contains(variant) { XCTAssertTrue(calls.exactRead.isEmpty) }
        }
    }

    func testRecoveryAcceptsFreshDualAbsenceWithoutReissuingDelete() async throws {
        let sessions = [session(1, state: .archived), session(2, state: .archived)]
        let initial = snapshot(sessions, at: baseTime)
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedTrash(sessions, snapshot: initial, store: store)
        let transport = NativeBatchTransportStub(inventories: [])
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(managerKeys: Set(sessions.map(\.id)),
            operation: .emptyTrash, snapshot: initial, checkpoint: initial.checkpoint)
        _ = try store.claimOperationPreviewForExecution(id: preview.id, now: baseTime.addingTimeInterval(10),
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(preview.confirmationToken))
        let result = try await coordinator.recoverPending(using: snapshot([], at: baseTime.addingTimeInterval(20)))
        XCTAssertEqual(result?.outcome, .success)
        XCTAssertEqual(try store.deletedSessions(for: .codex).count, 2)
        let calls = await transport.calls()
        XCTAssertTrue(calls.delete.isEmpty)
    }

    func testDeleteAdaptersRequireSourceRuntimeEvidenceNotRawRPCText() async throws {
        let id = session(1, state: .archived).nativeID
        let date = baseTime.addingTimeInterval(20)
        let inputs: [any Error & Sendable] = [
            CodexAppServerError.rpcError(-32600, "thread not loaded: \(id)"),
            CodexDeleteAbsenceEvidence(nativeSessionID: id, runtimeVersion: "0.153.4", observedAt: date),
            CodexDeleteAbsenceEvidence(nativeSessionID: session(2, state: .archived).nativeID,
                                      runtimeVersion: runtime, observedAt: date),
            CodexDeleteAbsenceEvidence(nativeSessionID: id, runtimeVersion: runtime, observedAt: date),
        ]
        for (index, error) in inputs.enumerated() {
            let source = DeleteEvidenceSourceStub(error: error)
            let batch = await CodexNativeBatchTransport(source: source).exactDeleteRead(id, auditedRuntimeVersion: runtime)
            let single = await CodexDeleteMutationTransport(source: source).exactReadObservation(
                nativeSessionID: id, auditedRuntimeVersion: runtime)
            let recovery = await CodexDeleteExecutionRecoveryReadback(source: source).exactReadObservation(
                nativeSessionID: id, auditedRuntimeVersion: runtime)
            for result in [batch, single, recovery] {
                if index == 3 {
                    XCTAssertEqual(result, .absent(nativeSessionID: id, observedAt: date, runtimeVersion: runtime))
                } else if case .unavailable = result {} else { XCTFail("Unproven absence accepted: \(index)") }
            }
        }
    }

    func testArchiveAndRestoreRecoveryAlsoRejectRuntimeDrift() async throws {
        for operation: SessionOperation in [.archive, .moveToTrash, .restore] {
            let before: NativeSessionState = operation == .restore ? .archived : .active
            let after: NativeSessionState = operation == .restore ? .active : .archived
            let sessions = [session(1, state: before), session(2, state: before)]
            let initial = snapshot(sessions, at: baseTime)
            let store = try makeStore(named: "\(#function)-\(operation)")
            defer { store.close() }
            if operation == .restore { try seedTrash(sessions, snapshot: initial, store: store) }
            else { try store.upsertProviderCheckpoint(initial.checkpoint) }
            let transport = NativeBatchTransportStub(inventories: [])
            let coordinator = makeCoordinator(store: store, transport: transport)
            let preview = try await coordinator.prepare(managerKeys: Set(sessions.map(\.id)),
                operation: operation, snapshot: initial, checkpoint: initial.checkpoint)
            _ = try store.claimOperationPreviewForExecution(id: preview.id, now: baseTime.addingTimeInterval(10),
                confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(preview.confirmationToken))
            let report = try await coordinator.recoverPending(using: snapshot(
                [session(1, state: after), session(2, state: after)], at: baseTime.addingTimeInterval(20),
                runtimeVersion: "0.153.4"))
            XCTAssertEqual(report?.unknownCount, 2)
            XCTAssertEqual(try store.trashMemberships(for: .codex).count, operation == .restore ? 2 : 0)
            let calls = await transport.calls()
            XCTAssertTrue(calls.archive.isEmpty && calls.restore.isEmpty && calls.delete.isEmpty)
        }
    }

    func testRecoveryRejectsChangedClaimCheckpointBeforeExactRead() async throws {
        let sessions = [session(1, state: .archived), session(2, state: .archived)]
        let initial = snapshot(sessions, at: baseTime)
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedTrash(sessions, snapshot: initial, store: store)
        let transport = NativeBatchTransportStub(inventories: [])
        let coordinator = makeCoordinator(store: store, transport: transport)
        let preview = try await coordinator.prepare(managerKeys: Set(sessions.map(\.id)),
            operation: .emptyTrash, snapshot: initial, checkpoint: initial.checkpoint)
        _ = try store.claimOperationPreviewForExecution(id: preview.id, now: baseTime.addingTimeInterval(10),
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(preview.confirmationToken))
        // Same inventory hash, changed runtime: manifest binding must detect it.
        XCTAssertThrowsError(try store.upsertProviderCheckpoint(
            snapshot(sessions, at: baseTime, runtimeVersion: "0.153.4").checkpoint))
        // Simulate externally replaced persisted evidence in this test-owned DB only.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE provider_checkpoints SET runtime_version='0.153.4'", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await coordinator.recoverPending(using: snapshot([], at: baseTime.addingTimeInterval(20)))
            XCTFail("A replaced original checkpoint was accepted")
        } catch is PersistentStateError {}
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .executing)
        XCTAssertTrue(try store.deletedSessions(for: .codex).isEmpty)
        let calls = await transport.calls()
        XCTAssertTrue(calls.exactRead.isEmpty && calls.delete.isEmpty)
    }

    private func binding(_ fingerprint: String = "environment-a",
                         features: [CodexCompatibilityFeature] = [.archiveRestore, .officialDelete]) -> CodexCompatibilityBinding {
        .init(revision: 1, runtimeVersion: "0.999.0", environmentFingerprint: fingerprint, features: features)
    }

    func testVerifiedNewRuntimeExecutesEveryBatchOperationWithFrozenBinding() async throws {
        for operation: SessionOperation in [.archive, .moveToTrash, .restore, .emptyTrash] {
            let archived = operation == .restore || operation == .emptyTrash
            let sessions = [session(1, state: archived ? .archived : .active), session(2, state: archived ? .archived : .active)]
            let binding = binding()
            let initial = snapshot(sessions, at: baseTime, binding: binding)
            let target: NativeSessionState = operation == .restore ? .active : .archived
            let first = operation == .emptyTrash ? [sessions[1]] : [session(1, state: target), sessions[1]]
            let last = operation == .emptyTrash ? [] : [session(1, state: target), session(2, state: target)]
            let transport = NativeBatchTransportStub(inventories: [
                snapshot(sessions, at: baseTime.addingTimeInterval(1), binding: binding),
                snapshot(first, at: baseTime.addingTimeInterval(20), binding: binding),
                snapshot(last, at: baseTime.addingTimeInterval(30), binding: binding),
            ])
            let store = try makeStore(named: #function)
            defer { store.close() }
            try store.upsertProviderCheckpoint(initial.checkpoint)
            if operation == .emptyTrash { try seedTrash(sessions, snapshot: initial, store: store) }
            XCTAssertEqual(try store.providerCheckpoint(for: .codex)?.compatibilityBinding, binding)
            let coordinator = makeCoordinator(store: store, transport: transport)
            let preview = try await coordinator.prepare(managerKeys: Set(sessions.map(\.id)),
                operation: operation, snapshot: initial, checkpoint: initial.checkpoint)
            let report = try await coordinator.execute(preview: preview, confirmationToken: preview.confirmationToken)
            XCTAssertEqual(report.successCount, 2, "\(operation)")
            let calls = await transport.calls()
            XCTAssertFalse(calls.bindings.isEmpty)
            XCTAssertTrue(calls.bindings.allSatisfy { $0 == binding })
        }
    }

    func testSameVersionBindingDriftBlocksPreflightAndReadback() async throws {
        for driftAt in [0, 1] {
            let sessions = [session(1, state: .active), session(2, state: .active)]
            let initial = snapshot(sessions, at: baseTime, binding: binding())
            let transport = NativeBatchTransportStub(inventories: [
                snapshot(sessions, at: baseTime.addingTimeInterval(1), binding: binding(driftAt == 0 ? "changed" : "environment-a")),
                snapshot([session(1, state: .archived), sessions[1]], at: baseTime.addingTimeInterval(20), binding: binding("changed")),
            ])
            let store = try makeStore(named: #function)
            defer { store.close() }
            try store.upsertProviderCheckpoint(initial.checkpoint)
            let coordinator = makeCoordinator(store: store, transport: transport)
            let preview = try await coordinator.prepare(managerKeys: Set(sessions.map(\.id)),
                operation: .archive, snapshot: initial, checkpoint: initial.checkpoint)
            let report = try await coordinator.execute(preview: preview, confirmationToken: preview.confirmationToken)
            XCTAssertEqual(report.successCount, 0)
            let calls = await transport.calls()
            XCTAssertEqual(calls.archive.count, driftAt)
            if driftAt == 1 { XCTAssertEqual(report.items.first?.outcome, .unknown) }
        }
    }

    func testNewRuntimeRecoveryRequiresOriginalBindingAndNeverResends() async throws {
        for matches in [true, false] {
            let sessions = [session(1, state: .archived), session(2, state: .archived)]
            let initial = snapshot(sessions, at: baseTime, binding: binding())
            let store = try makeStore(named: #function)
            defer { store.close() }
            try seedTrash(sessions, snapshot: initial, store: store)
            let transport = NativeBatchTransportStub(inventories: [])
            let coordinator = makeCoordinator(store: store, transport: transport)
            let preview = try await coordinator.prepare(managerKeys: Set(sessions.map(\.id)),
                operation: .emptyTrash, snapshot: initial, checkpoint: initial.checkpoint)
            _ = try store.claimOperationPreviewForExecution(id: preview.id, now: baseTime.addingTimeInterval(10),
                confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(preview.confirmationToken))
            let recovered = try await coordinator.recoverPending(using: snapshot([], at: baseTime.addingTimeInterval(20),
                binding: binding(matches ? "environment-a" : "changed")))
            let report = try XCTUnwrap(recovered)
            XCTAssertEqual(report.successCount, matches ? 2 : 0)
            let calls = await transport.calls()
            XCTAssertTrue(calls.archive.isEmpty && calls.restore.isEmpty && calls.delete.isEmpty)
            XCTAssertEqual(calls.exactRead.count, matches ? 2 : 0)
        }
    }

    func testNewRuntimeArchiveProofDoesNotUnlockDeletePreview() async throws {
        let sessions = [session(1, state: .archived), session(2, state: .archived)]
        let initial = snapshot(sessions, at: baseTime, binding: binding(features: [.archiveRestore]))
        let store = try makeStore(named: #function)
        defer { store.close() }
        try seedTrash(sessions, snapshot: initial, store: store)
        let transport = NativeBatchTransportStub(inventories: [])
        let coordinator = makeCoordinator(store: store, transport: transport)
        do {
            _ = try await coordinator.prepare(managerKeys: Set(sessions.map(\.id)),
                operation: .emptyTrash, snapshot: initial, checkpoint: initial.checkpoint)
            XCTFail("Archive acceptance must not authorize Delete")
        } catch is SessionManagerError {}
        let calls = await transport.calls()
        XCTAssertTrue(calls.delete.isEmpty && calls.bindings.isEmpty)
    }

    private func seedTrash(_ sessions: [AgentSession], snapshot: ProviderInventorySnapshot, store: SQLiteStateStore) throws {
        for item in sessions {
            try store.saveTrashMembership(TrashMembershipRecord(provider: .codex,
                nativeSessionID: item.nativeID, managerKey: item.id, titleAtEntry: item.title,
                workingDirectoryAtEntry: item.workingDirectory, nativeStateAtEntry: .archived,
                providerInventoryHashAtEntry: snapshot.inventoryHash, enteredAt: baseTime,
                lastReconciledAt: baseTime), checkpoint: snapshot.checkpoint)
        }
    }

    private func makeCoordinator(
        store: SQLiteStateStore,
        transport: NativeBatchTransportStub,
        executionGate: any CodexLifecycleExecutionChecking = LifecycleExecutionGateStub()
    ) -> CodexNativeBatchCoordinator {
        let now = baseTime.addingTimeInterval(10)
        return CodexNativeBatchCoordinator(
            store: store,
            transport: transport,
            executionGate: executionGate,
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
        protectionComplete: Bool = true,
        inventoryComplete: Bool = true,
        runtimeVersion: String? = nil,
        binding: CodexCompatibilityBinding? = nil
    ) -> ProviderInventorySnapshot {
        ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtimeVersion ?? binding?.runtimeVersion ?? runtime,
            compatibilityBinding: binding,
            inventoryHash: "checkpoint-batch-v1",
            observedAt: date,
            inventoryComplete: inventoryComplete,
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

private struct DeleteEvidenceSourceStub: CodexDeleteSource, CodexArchiveSource, CodexRestoreSource {
    let error: any Error & Sendable
    func inventory() async throws -> CodexInventorySnapshot { throw CodexAppServerError.responseTimeout }
    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot { throw error }
    func archive(threadID: String) async throws { throw CodexAppServerError.exactReadUnavailable }
    func unarchive(threadID: String) async throws { throw CodexAppServerError.exactReadUnavailable }
    func delete(threadID: String) async throws { throw CodexAppServerError.exactReadUnavailable }
}

private actor NativeBatchTransportStub: CodexNativeBatchMutationTransport {
    struct CallLog: Sendable {
        var fullInventoryCount = 0
        var readbackCount = 0
        var archive: [String] = []
        var restore: [String] = []
        var delete: [String] = []
        var exactRead: [String] = []
        var bindings: [CodexCompatibilityBinding?] = []
    }

    private var inventories: [ProviderInventorySnapshot]
    private let archiveFailureOrdinal: Int?
    private var archiveOrdinal = 0
    private var log = CallLog()
    private let exactObservation: DeleteExactReadObservation?
    private let exactRuntime: String?
    private let exactTime: Date?

    init(
        inventories: [ProviderInventorySnapshot],
        archiveFailureOrdinal: Int? = nil,
        exactObservation: DeleteExactReadObservation? = nil,
        exactRuntime: String? = nil,
        exactTime: Date? = nil
    ) {
        self.inventories = inventories
        self.archiveFailureOrdinal = archiveFailureOrdinal
        self.exactObservation = exactObservation
        self.exactRuntime = exactRuntime
        self.exactTime = exactTime
    }

    func inventorySnapshot() async throws -> ProviderInventorySnapshot {
        log.fullInventoryCount += 1
        return try nextInventory()
    }

    func lifecycleReadbackSnapshot() async throws -> ProviderInventorySnapshot {
        log.readbackCount += 1
        return try nextInventory()
    }

    private func nextInventory() throws -> ProviderInventorySnapshot {
        guard !inventories.isEmpty else {
            throw CodexAppServerError.responseTimeout
        }
        return inventories.removeFirst()
    }

    func archive(_ nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        log.bindings.append(expectedCompatibility)
        try await archive(nativeSessionID)
    }

    func restore(_ nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        log.bindings.append(expectedCompatibility)
        try await restore(nativeSessionID)
    }

    func delete(_ nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        log.bindings.append(expectedCompatibility)
        try await delete(nativeSessionID)
    }

    func exactDeleteRead(_ nativeSessionID: String, auditedRuntimeVersion: String,
                         expectedCompatibility: CodexCompatibilityBinding?) async -> DeleteExactReadObservation {
        log.bindings.append(expectedCompatibility)
        return await exactDeleteRead(nativeSessionID, auditedRuntimeVersion: auditedRuntimeVersion)
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
        if let exactObservation { return exactObservation }
        return .absent(
            nativeSessionID: nativeSessionID,
            observedAt: exactTime ?? Date(timeIntervalSince1970: 1_800_700_100),
            runtimeVersion: exactRuntime ?? auditedRuntimeVersion
        )
    }

    func calls() -> CallLog { log }
}
