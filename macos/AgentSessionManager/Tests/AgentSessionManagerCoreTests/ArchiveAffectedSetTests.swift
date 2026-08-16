import XCTest
@testable import AgentSessionManagerCore

final class ArchiveAffectedSetTests: XCTestCase {
    func testPlanFreezesRootAndEveryDescendantWithFullIdentity() throws {
        let plan = try ArchiveAffectedSetPlanner.plan(
            selectedRootNativeSessionID: "root",
            nodes: [
                node("grandchild", parent: "child", pinned: true),
                node("other-root"),
                node("root"),
                node("child", parent: "root"),
            ],
            graphComplete: true
        )

        XCTAssertEqual(plan.selectedRootNativeSessionID, "root")
        XCTAssertEqual(plan.descendantCount, 2)
        XCTAssertEqual(plan.items.map(\.nativeSessionID), ["root", "child", "grandchild"])
        XCTAssertEqual(plan.items.map(\.managerKey), ["codex:root", "codex:child", "codex:grandchild"])
        XCTAssertEqual(plan.items.map(\.depth), [0, 1, 2])
        XCTAssertEqual(plan.items.map(\.role), [.selectedRoot, .descendant, .descendant])
        XCTAssertTrue(plan.items.last?.protection.isPinned == true)
    }

    func testIncompleteGraphFailsBeforeReturningPartialSet() {
        XCTAssertThrowsError(try ArchiveAffectedSetPlanner.plan(
            selectedRootNativeSessionID: "root",
            nodes: [node("root")],
            graphComplete: false
        )) { error in
            XCTAssertEqual(error as? ArchiveAffectedSetError, .graphIncomplete)
        }
    }

    func testDuplicateIdentityAndMissingRootFailClosed() {
        XCTAssertThrowsError(try ArchiveAffectedSetPlanner.plan(
            selectedRootNativeSessionID: "root",
            nodes: [node("root"), node("root")],
            graphComplete: true
        )) { error in
            XCTAssertEqual(error as? ArchiveAffectedSetError, .duplicateNativeSessionID("root"))
        }
        XCTAssertThrowsError(try ArchiveAffectedSetPlanner.plan(
            selectedRootNativeSessionID: "missing",
            nodes: [node("root")],
            graphComplete: true
        )) { error in
            XCTAssertEqual(error as? ArchiveAffectedSetError, .selectedRootNotFound("missing"))
        }
    }

    func testCycleFailsInsteadOfLoopingOrShrinkingScope() {
        XCTAssertThrowsError(try ArchiveAffectedSetPlanner.plan(
            selectedRootNativeSessionID: "root",
            nodes: [node("root", parent: "child"), node("child", parent: "root")],
            graphComplete: true
        )) { error in
            XCTAssertEqual(error as? ArchiveAffectedSetError, .graphCycle("root"))
        }
    }

    func testAffectedSetPersistsExactStructureAndHash() throws {
        let set = try ArchiveAffectedSetPlanner.plan(
            selectedRootNativeSessionID: "root",
            nodes: [node("root"), node("child", parent: "root")],
            graphComplete: true
        )
        let items = try ArchiveAffectedSetPersistence.frozenItems(from: set)
        let hash = try ArchiveAffectedSetPersistence.hash(items: items)

        XCTAssertTrue(hash.hasPrefix("sha256:"))
        XCTAssertEqual(items.map(\.archiveAffectedRole), [.selectedRoot, .descendant])
        XCTAssertEqual(items.map(\.parentNativeSessionID), [nil, "root"])
        XCTAssertEqual(items.map(\.archiveAffectedDepth), [0, 1])

        let store = try makeStore()
        defer { store.close() }
        let checkpoint = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: "scope-inventory",
            refreshedAt: Date(timeIntervalSince1970: 20),
            inventoryComplete: true,
            protectionComplete: true
        )
        let preview = PersistentOperationPreview(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000311")!,
            provider: .codex,
            operation: .archive,
            confirmationTokenHash: "token-hash",
            manifestHash: "manifest-hash",
            providerInventoryHash: checkpoint.inventoryHash,
            affectedSetHash: hash,
            createdAt: Date(timeIntervalSince1970: 30),
            expiresAt: Date(timeIntervalSince1970: 60),
            items: items
        )

        try store.saveOperationPreview(preview, checkpoint: checkpoint)
        XCTAssertEqual(try store.operationPreview(id: preview.id), preview)
    }

    func testAffectedSetTamperingFailsWithoutPartialPreviewWrite() throws {
        let set = try ArchiveAffectedSetPlanner.plan(
            selectedRootNativeSessionID: "root",
            nodes: [node("root"), node("child", parent: "root")],
            graphComplete: true
        )
        let items = try ArchiveAffectedSetPersistence.frozenItems(from: set)
        let store = try makeStore()
        defer { store.close() }
        let checkpoint = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: "scope-inventory",
            refreshedAt: Date(timeIntervalSince1970: 20),
            inventoryComplete: true,
            protectionComplete: true
        )
        let preview = PersistentOperationPreview(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000312")!,
            provider: .codex,
            operation: .archive,
            confirmationTokenHash: "token-hash",
            manifestHash: "manifest-hash",
            providerInventoryHash: checkpoint.inventoryHash,
            affectedSetHash: "sha256:tampered",
            createdAt: Date(timeIntervalSince1970: 30),
            expiresAt: Date(timeIntervalSince1970: 60),
            items: items
        )

        XCTAssertThrowsError(try store.saveOperationPreview(preview, checkpoint: checkpoint))
        XCTAssertNil(try store.operationPreview(id: preview.id))
        XCTAssertNil(try store.providerCheckpoint(for: .codex))
    }

    func testFactoryFreezesPreparedPreviewButExistingExecutorRejectsAffectedSet() async throws {
        let observedAt = Date(timeIntervalSince1970: 20)
        let root = node("root")
        let child = node("child", parent: "root")
        let snapshot = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: "scope-inventory",
            observedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [],
            archiveScopeNodes: [root, child],
            archiveScopeComplete: true
        )
        let preview = try ArchiveAffectedSetPreviewFactory.makePreparedPreview(
            selectedRootNativeSessionID: "root",
            snapshot: snapshot,
            confirmationToken: "ARCHIVE-AFFECTED-SET",
            previewID: UUID(uuidString: "00000000-0000-0000-0000-000000000313")!,
            createdAt: Date(timeIntervalSince1970: 30),
            expiresAt: Date(timeIntervalSince1970: 60)
        )

        XCTAssertEqual(preview.status, .prepared)
        XCTAssertEqual(preview.items.count, 2)
        XCTAssertNotNil(preview.affectedSetHash)

        let executing = PersistentOperationPreview(
            id: preview.id,
            provider: preview.provider,
            operation: preview.operation,
            status: .executing,
            confirmationTokenHash: preview.confirmationTokenHash,
            manifestHash: preview.manifestHash,
            providerInventoryHash: preview.providerInventoryHash,
            affectedSetHash: preview.affectedSetHash,
            createdAt: preview.createdAt,
            expiresAt: preview.expiresAt,
            items: preview.items
        )
        let checkpoint = snapshot.checkpoint
        let executor = ArchiveMutationExecutor(
            transport: NoCallArchiveTransport(snapshot: snapshot),
            now: { Date(timeIntervalSince1970: 40) }
        )
        do {
            _ = try await executor.execute(
                preview: executing,
                checkpoint: checkpoint,
                confirmationToken: "ARCHIVE-AFFECTED-SET"
            )
            XCTFail("Descendant-aware Preview must not enter the single-item executor.")
        } catch let error as ArchiveExecutionError {
            XCTAssertEqual(error, .invalidPreview("exactly one frozen item is required"))
        }
    }

    func testFactoryRejectsProtectedDescendantAndNonActiveRoot() throws {
        let observedAt = Date(timeIntervalSince1970: 20)
        let base = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: "scope-inventory",
            observedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [],
            archiveScopeNodes: [node("root"), node("child", parent: "root", pinned: true)],
            archiveScopeComplete: true
        )
        XCTAssertThrowsError(try ArchiveAffectedSetPreviewFactory.makePreparedPreview(
            selectedRootNativeSessionID: "root",
            snapshot: base,
            confirmationToken: "TOKEN",
            previewID: UUID(),
            createdAt: Date(timeIntervalSince1970: 30),
            expiresAt: Date(timeIntervalSince1970: 60)
        ))

        let archivedRoot = ArchiveScopeNode(
            managerKey: "codex:root",
            nativeSessionID: "root",
            title: "Root",
            nativeState: .archived,
            protection: SessionProtection()
        )
        let archivedSnapshot = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: "scope-inventory",
            observedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [],
            archiveScopeNodes: [archivedRoot],
            archiveScopeComplete: true
        )
        XCTAssertThrowsError(try ArchiveAffectedSetPreviewFactory.makePreparedPreview(
            selectedRootNativeSessionID: "root",
            snapshot: archivedSnapshot,
            confirmationToken: "TOKEN",
            previewID: UUID(),
            createdAt: Date(timeIntervalSince1970: 30),
            expiresAt: Date(timeIntervalSince1970: 60)
        ))
    }

    func testFactoryAllowsUnknownRunningAndCurrentButRequiresKnownPinEvidence() throws {
        let observedAt = Date(timeIntervalSince1970: 20)
        let attemptableRoot = ArchiveScopeNode(
            managerKey: "codex:root",
            nativeSessionID: "root",
            title: "Root",
            nativeState: .active,
            protection: SessionProtection(
                isRunningKnown: false,
                isCurrentKnown: false
            )
        )
        let attemptableSnapshot = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: "attemptable-inventory",
            observedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: false,
            sessions: [],
            archiveScopeNodes: [attemptableRoot],
            archiveScopeComplete: true
        )

        let preview = try ArchiveAffectedSetPreviewFactory.makePreparedPreview(
            selectedRootNativeSessionID: "root",
            snapshot: attemptableSnapshot,
            confirmationToken: "TOKEN",
            previewID: UUID(),
            createdAt: Date(timeIntervalSince1970: 30),
            expiresAt: Date(timeIntervalSince1970: 60)
        )
        XCTAssertEqual(preview.items.count, 1)

        let unknownPinRoot = ArchiveScopeNode(
            managerKey: "codex:root",
            nativeSessionID: "root",
            title: "Root",
            nativeState: .active,
            protection: SessionProtection(isPinnedKnown: false)
        )
        let blockedSnapshot = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: "blocked-inventory",
            observedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: false,
            sessions: [],
            archiveScopeNodes: [unknownPinRoot],
            archiveScopeComplete: true
        )
        XCTAssertThrowsError(try ArchiveAffectedSetPreviewFactory.makePreparedPreview(
            selectedRootNativeSessionID: "root",
            snapshot: blockedSnapshot,
            confirmationToken: "TOKEN",
            previewID: UUID(),
            createdAt: Date(timeIntervalSince1970: 30),
            expiresAt: Date(timeIntervalSince1970: 60)
        ))
    }

    private func node(
        _ nativeID: String,
        parent: String? = nil,
        pinned: Bool = false
    ) -> ArchiveScopeNode {
        ArchiveScopeNode(
            managerKey: "codex:\(nativeID)",
            nativeSessionID: nativeID,
            parentNativeSessionID: parent,
            title: "Session \(nativeID)",
            nativeState: .active,
            protection: SessionProtection(isPinned: pinned)
        )
    }

    private func makeStore() throws -> SQLiteStateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-affected-set-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: directory.appendingPathComponent("manager.sqlite3"))
    }
}

private actor NoCallArchiveTransport: ArchiveMutationTransport {
    let snapshot: ProviderInventorySnapshot

    init(snapshot: ProviderInventorySnapshot) {
        self.snapshot = snapshot
    }

    func inventorySnapshot() -> ProviderInventorySnapshot { snapshot }

    func archive(nativeSessionID: String) {
        XCTFail("Affected-set Preview must not call Archive through the single-item executor.")
    }
}
