@testable import AgentSessionManagerCore
import Foundation
import XCTest

private enum CoordinatorFixtureError: Error {
    case inventoryFailed
}

private actor CoordinatorFixtureProvider: SessionProvider {
    nonisolated let system: AgentSystem
    nonisolated let capabilities: SessionCapabilities = .readOnlyFixture

    private let result: Result<[AgentSession], Error>
    private let diagnosticValue: ProviderDiagnostics

    init(
        system: AgentSystem = .codex,
        result: Result<[AgentSession], Error>,
        diagnostics: ProviderDiagnostics
    ) {
        self.system = system
        self.result = result
        self.diagnosticValue = diagnostics
    }

    func sessions() throws -> [AgentSession] { try result.get() }
    func projects() -> [SessionProject] { [] }
    func diagnostics() -> ProviderDiagnostics { diagnosticValue }

    func preview(
        operation: SessionOperation,
        managerKeys: [String]
    ) throws -> OperationPreview {
        throw SessionManagerError.unsupportedOperation("Coordinator fixture is read-only.")
    }

    func execute(
        preview: OperationPreview,
        confirmationToken: String
    ) throws -> OperationReport {
        throw SessionManagerError.unsupportedOperation("Coordinator fixture is read-only.")
    }
}

final class SessionSnapshotCoordinatorTests: XCTestCase {
    func testLiveCodexCoordinatorWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENT_SESSION_MANAGER_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set AGENT_SESSION_MANAGER_LIVE_TEST=1 for the explicit live coordinator smoke test.")
        }
        let store = try makeStore(named: #function)
        defer { store.close() }
        let provider = CodexAppServerProvider()
        let coordinator = SessionSnapshotCoordinator(provider: provider, store: store)

        let result = try await coordinator.refresh()

        XCTAssertTrue(result.diagnostics.inventoryComplete)
        XCTAssertEqual(result.diagnostics.runtimeVersion, "0.147.0")
        XCTAssertEqual(result.checkpointDisposition, .advanced)
        XCTAssertFalse(result.reconciliation.entries.isEmpty)
        XCTAssertTrue(result.diagnostics.capabilities.canReadPinnedState)
        XCTAssertTrue(result.snapshot.sessions.allSatisfy { $0.protection.isPinnedKnown })
        XCTAssertTrue(
            result.snapshot.sessions.allSatisfy { $0.protection.hasPinnedDescendantKnown }
        )
        XCTAssertEqual(
            try store.providerCheckpoint(for: .codex),
            result.reconciliation.checkpoint
        )
        XCTAssertEqual(
            try store.providerCheckpoint(for: .codex)?.runtimeVersion,
            "0.147.0"
        )
    }

    func testCompleteDegradedSnapshotAdvancesCheckpointAndReconcilesFrozenMembershipSet() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let oldCheckpoint = checkpoint(hash: "old", at: date(100))
        let membership = trashMembership(hash: oldCheckpoint.inventoryHash, reconciledAt: date(100))
        try store.saveTrashMembership(membership, checkpoint: oldCheckpoint)

        let sessions = [session("trash-1", state: .archived)]
        let diagnostics = diagnostic(
            connection: .degraded,
            refreshedAt: date(200.123_456),
            inventoryComplete: true,
            protectionComplete: false
        )
        let provider = CoordinatorFixtureProvider(
            result: .success(sessions),
            diagnostics: diagnostics
        )
        let coordinator = SessionSnapshotCoordinator(provider: provider, store: store)

        let result = try await coordinator.refresh()

        XCTAssertEqual(result.checkpointDisposition, .advanced)
        XCTAssertEqual(result.reconciliation.entries.count, 1)
        XCTAssertEqual(result.reconciliation.entries[0].status, .trash)
        XCTAssertFalse(result.reconciliation.entries[0].isStableForLifecyclePreview)
        XCTAssertTrue(result.reconciliation.checkpoint.inventoryComplete)
        XCTAssertFalse(result.reconciliation.checkpoint.protectionComplete)
        XCTAssertEqual(
            try store.providerCheckpoint(for: .codex),
            result.reconciliation.checkpoint
        )
        XCTAssertEqual(
            try store.trashMemberships(for: .codex).first?.lastReconciledAt,
            date(200.123)
        )
    }

    func testIncompleteSnapshotIsDiagnosticOnlyAndDoesNotReplaceAuthoritativeCheckpoint() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let oldCheckpoint = checkpoint(hash: "authoritative", at: date(100))
        let membership = trashMembership(hash: oldCheckpoint.inventoryHash, reconciledAt: date(100))
        try store.saveTrashMembership(membership, checkpoint: oldCheckpoint)
        let provider = CoordinatorFixtureProvider(
            result: .success([]),
            diagnostics: diagnostic(
                connection: .degraded,
                refreshedAt: date(200),
                inventoryComplete: false,
                protectionComplete: false
            )
        )
        let coordinator = SessionSnapshotCoordinator(provider: provider, store: store)

        let result = try await coordinator.refresh()

        XCTAssertEqual(result.checkpointDisposition, .skippedIncompleteInventory)
        XCTAssertEqual(result.reconciliation.entries[0].status, .unavailable)
        XCTAssertEqual(try store.providerCheckpoint(for: .codex), oldCheckpoint)
        XCTAssertEqual(
            try store.trashMemberships(for: .codex).first?.lastReconciledAt,
            date(100)
        )
    }

    func testExecutingPreviewPreservesClaimCheckpointUntilRecovery() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let active = session("executing", state: .active)
        let originalHash = try InventorySnapshotHasher.hash(provider: .codex, sessions: [active])
        let original = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: originalHash,
            refreshedAt: date(100),
            inventoryComplete: true,
            protectionComplete: true
        )
        let item = PersistentPreviewItem(
            managerKey: active.id,
            nativeSessionID: active.nativeID,
            expectedNativeState: .active,
            expectedProtectionHash: "sha256:fixture",
            expectedTitle: active.title
        )
        let preview = PersistentOperationPreview(
            id: UUID(),
            provider: .codex,
            operation: .archive,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash("TOKEN"),
            manifestHash: try ArchiveExecutionHasher.manifestHash(
                provider: .codex,
                operation: .archive,
                providerInventoryHash: originalHash,
                runtimeVersion: "0.147.0",
                reconciliationTimestamp: date(100),
                createdAt: date(100),
                expiresAt: date(300),
                items: [item]
            ),
            providerInventoryHash: originalHash,
            createdAt: date(100),
            expiresAt: date(300),
            items: [item]
        )
        try store.saveOperationPreview(preview, checkpoint: original)
        _ = try store.claimOperationPreviewForExecution(
            id: preview.id,
            now: date(150),
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash("TOKEN")
        )

        let newerSessions = [session("new-session", state: .active)]
        let provider = CoordinatorFixtureProvider(
            result: .success(newerSessions),
            diagnostics: diagnostic(
                connection: .ready,
                refreshedAt: date(200),
                inventoryComplete: true,
                protectionComplete: true
            )
        )
        let result = try await SessionSnapshotCoordinator(provider: provider, store: store).refresh()

        XCTAssertEqual(result.checkpointDisposition, .skippedExecutingRecovery)
        XCTAssertEqual(try store.providerCheckpoint(for: .codex), original)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .executing)
        XCTAssertThrowsError(
            try store.commitReconciliationCheckpoint(
                result.reconciliation.checkpoint,
                expectedTrashManagerKeys: []
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentStateError,
                .invalidRecord(
                    "Provider checkpoint cannot advance while execution recovery is unresolved."
                )
            )
        }
        XCTAssertEqual(try store.providerCheckpoint(for: .codex), original)
    }

    func testProviderFailureLeavesSQLiteUntouched() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let oldCheckpoint = checkpoint(hash: "authoritative", at: date(100))
        try store.upsertProviderCheckpoint(oldCheckpoint)
        let provider = CoordinatorFixtureProvider(
            result: .failure(CoordinatorFixtureError.inventoryFailed),
            diagnostics: diagnostic(
                connection: .unavailable,
                refreshedAt: nil,
                inventoryComplete: false,
                protectionComplete: false
            )
        )
        let coordinator = SessionSnapshotCoordinator(provider: provider, store: store)

        do {
            _ = try await coordinator.refresh()
            XCTFail("Expected provider failure")
        } catch CoordinatorFixtureError.inventoryFailed {
            // Expected.
        }
        XCTAssertEqual(try store.providerCheckpoint(for: .codex), oldCheckpoint)
    }

    func testStaleCompleteSnapshotFailsClosedWithoutUpdatingReconciliationTime() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let currentCheckpoint = checkpoint(hash: "current", at: date(300))
        let membership = trashMembership(
            hash: currentCheckpoint.inventoryHash,
            reconciledAt: date(300)
        )
        try store.saveTrashMembership(membership, checkpoint: currentCheckpoint)
        let provider = CoordinatorFixtureProvider(
            result: .success([session("trash-1", state: .archived)]),
            diagnostics: diagnostic(
                connection: .ready,
                refreshedAt: date(200),
                inventoryComplete: true,
                protectionComplete: true
            )
        )
        let coordinator = SessionSnapshotCoordinator(provider: provider, store: store)

        do {
            _ = try await coordinator.refresh()
            XCTFail("Expected stale snapshot rejection")
        } catch let error as SnapshotCoordinatorError {
            XCTAssertEqual(
                error,
                .staleSnapshot(existing: date(300), incoming: date(200))
            )
        }
        XCTAssertEqual(try store.providerCheckpoint(for: .codex), currentCheckpoint)
        XCTAssertEqual(
            try store.trashMemberships(for: .codex).first?.lastReconciledAt,
            date(300)
        )
    }

    func testIdenticalTimestampAndSnapshotIsIdempotent() async throws {
        let store = try makeStore(named: #function)
        defer { store.close() }
        let sessions = [session("active", state: .active)]
        let hash = try InventorySnapshotHasher.hash(provider: .codex, sessions: sessions)
        let existing = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "test-runtime",
            inventoryHash: hash,
            refreshedAt: date(200),
            inventoryComplete: true,
            protectionComplete: true
        )
        try store.upsertProviderCheckpoint(existing)
        let provider = CoordinatorFixtureProvider(
            result: .success(sessions),
            diagnostics: diagnostic(
                connection: .ready,
                refreshedAt: date(200),
                inventoryComplete: true,
                protectionComplete: true
            )
        )
        let coordinator = SessionSnapshotCoordinator(provider: provider, store: store)

        let result = try await coordinator.refresh()

        XCTAssertEqual(result.checkpointDisposition, .unchanged)
        XCTAssertEqual(try store.providerCheckpoint(for: .codex), existing)
    }

    func testInventoryHashIsOrderIndependentAndIgnoresManagerTrashFlag() throws {
        var first = session("a", state: .active)
        let second = session("b", state: .archived)
        let expected = try InventorySnapshotHasher.hash(
            provider: .codex,
            sessions: [first, second]
        )
        first.isTrashMember = true
        let reordered = try InventorySnapshotHasher.hash(
            provider: .codex,
            sessions: [second, first]
        )

        XCTAssertEqual(reordered, expected)
    }

    func testInventoryHashIncludesExactArchiveScopeEvenWhenDescendantCountMatches() throws {
        let session = session("root", state: .active)
        let first = try InventorySnapshotHasher.hash(
            provider: .codex,
            sessions: [session],
            archiveScopeNodes: [scopeNode("root"), scopeNode("child-a", parent: "root")],
            archiveScopeComplete: true
        )
        let changedIdentity = try InventorySnapshotHasher.hash(
            provider: .codex,
            sessions: [session],
            archiveScopeNodes: [scopeNode("root"), scopeNode("child-b", parent: "root")],
            archiveScopeComplete: true
        )
        let changedState = try InventorySnapshotHasher.hash(
            provider: .codex,
            sessions: [session],
            archiveScopeNodes: [scopeNode("root"), scopeNode("child-a", parent: "root", state: .archived)],
            archiveScopeComplete: true
        )

        XCTAssertNotEqual(first, changedIdentity)
        XCTAssertNotEqual(first, changedState)
    }

    private func scopeNode(
        _ nativeID: String,
        parent: String? = nil,
        state: NativeSessionState = .active
    ) -> ArchiveScopeNode {
        ArchiveScopeNode(
            managerKey: "codex:\(nativeID)",
            nativeSessionID: nativeID,
            parentNativeSessionID: parent,
            title: nativeID,
            nativeState: state,
            protection: SessionProtection(),
            descendantCount: parent == nil ? 1 : 0,
            descendantCountKnown: true
        )
    }

    private func makeStore(named name: String) throws -> SQLiteStateStore {
        let safeName = name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-manager-coordinator-\(safeName)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: directory.appendingPathComponent("manager.sqlite3"))
    }

    private func diagnostic(
        connection: ProviderConnectionState,
        refreshedAt: Date?,
        inventoryComplete: Bool,
        protectionComplete: Bool
    ) -> ProviderDiagnostics {
        ProviderDiagnostics(
            system: .codex,
            connectionState: connection,
            runtimeVersion: "test-runtime",
            lastRefreshedAt: refreshedAt,
            inventoryComplete: inventoryComplete,
            protectionComplete: protectionComplete,
            capabilities: .readOnlyFixture
        )
    }

    private func checkpoint(hash: String, at refreshedAt: Date) -> ProviderCheckpointRecord {
        ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "older-runtime",
            inventoryHash: hash,
            refreshedAt: refreshedAt,
            inventoryComplete: true,
            protectionComplete: true
        )
    }

    private func session(_ nativeID: String, state: NativeSessionState) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: nativeID,
            workingDirectory: "/tmp/project",
            updatedAt: date(100),
            sizeBytes: nil,
            nativeState: state,
            protection: SessionProtection()
        )
    }

    private func trashMembership(hash: String, reconciledAt: Date) -> TrashMembershipRecord {
        TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: "trash-1",
            managerKey: "codex:trash-1",
            titleAtEntry: "trash-1",
            workingDirectoryAtEntry: "/tmp/project",
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: hash,
            enteredAt: date(90),
            lastReconciledAt: reconciledAt
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
