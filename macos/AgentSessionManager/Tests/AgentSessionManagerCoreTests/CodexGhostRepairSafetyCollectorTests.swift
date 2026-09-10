@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairSafetyCollectorTests: XCTestCase {
    func testCollectorBuildsSortedExactEvidenceFromReadOnlySource() async throws {
        let source = FixedGhostRepairSafetySource(snapshot: makeSnapshot(
            targetIDs: ["thread-b", "thread-a"]
        ))

        let evidence = try await CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: ["thread-b", "thread-a"],
            from: source
        )

        XCTAssertEqual(evidence.protectionEvidence.map(\.threadID), ["thread-a", "thread-b"])
        XCTAssertTrue(evidence.protectionEvidence.allSatisfy(\.isEligible))
        XCTAssertTrue(evidence.executionGate.isClear)
        let requestedIDs = await source.requestedIDs
        XCTAssertEqual(requestedIDs, [["thread-b", "thread-a"]])
    }

    func testIncompleteAnyAuthoritativeInventoryFailsClosed() throws {
        let base = makeSnapshot(targetIDs: ["thread-a"])
        let snapshot = CodexGhostRepairSafetySnapshot(
            inventory: ProviderInventorySnapshot(
                provider: .codex,
                runtimeVersion: base.inventory.runtimeVersion,
                inventoryHash: base.inventory.inventoryHash,
                observedAt: base.inventory.observedAt,
                inventoryComplete: true,
                protectionComplete: true,
                sessions: [],
                archiveScopeNodes: [],
                archiveScopeComplete: false
            ),
            exactReadbacks: base.exactReadbacks,
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            executionGate: base.executionGate
        )

        XCTAssertThrowsError(try CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: ["thread-a"],
            snapshot: snapshot
        ))
    }

    func testPresentTargetIsCollectedAsIneligibleAndCannotBecomeRepairPlan() throws {
        let present = AgentSession(
            system: .codex,
            nativeID: "thread-a",
            title: "Present",
            workingDirectory: "/tmp",
            updatedAt: Date(timeIntervalSince1970: 1),
            sizeBytes: nil,
            nativeState: .active
        )
        let base = makeSnapshot(targetIDs: ["thread-a"])
        let snapshot = replacingInventory(base, sessions: [present])

        let evidence = try CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: ["thread-a"],
            snapshot: snapshot
        )

        XCTAssertTrue(evidence.protectionEvidence[0].activeInventoryPresent)
        XCTAssertFalse(evidence.protectionEvidence[0].isEligible)
    }

    func testUndocumentedExactReadFailureFailsClosed() throws {
        let base = makeSnapshot(targetIDs: ["thread-a"])
        let unavailable = ExactSessionReadbackEvidence(
            provider: .codex,
            nativeSessionID: "thread-a",
            status: .unavailable,
            observedAt: Date(timeIntervalSince1970: 2),
            runtimeVersion: "codex-cli 0.148.0",
            evidenceKind: .rpcError,
            rpcCode: -32600,
            message: "not documented"
        )
        let snapshot = CodexGhostRepairSafetySnapshot(
            inventory: base.inventory,
            exactReadbacks: [unavailable],
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            executionGate: base.executionGate
        )

        XCTAssertThrowsError(try CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: ["thread-a"],
            snapshot: snapshot
        ))
    }

    func testPinnedAndRecursiveDescendantFactsRemainVisibleAsIneligibleEvidence() throws {
        let base = makeSnapshot(targetIDs: ["thread-a"])
        let nodes = [
            node(id: "child", parent: "thread-a"),
            node(id: "grandchild", parent: "child"),
        ]
        let inventory = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: base.inventory.runtimeVersion,
            inventoryHash: base.inventory.inventoryHash,
            observedAt: base.inventory.observedAt,
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [],
            archiveScopeNodes: nodes,
            archiveScopeComplete: true
        )
        let snapshot = CodexGhostRepairSafetySnapshot(
            inventory: inventory,
            exactReadbacks: base.exactReadbacks,
            pinnedThreadIDs: ["thread-a"],
            pinnedInventoryComplete: true,
            executionGate: base.executionGate
        )

        let evidence = try CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: ["thread-a"],
            snapshot: snapshot
        ).protectionEvidence[0]

        XCTAssertTrue(evidence.pinned)
        XCTAssertEqual(evidence.descendantCount, 2)
        XCTAssertFalse(evidence.isEligible)
    }

    func testDuplicateExactReadbackAndDescendantCycleFailClosed() throws {
        let base = makeSnapshot(targetIDs: ["thread-a"])
        let duplicateReadback = CodexGhostRepairSafetySnapshot(
            inventory: base.inventory,
            exactReadbacks: [base.exactReadbacks[0], base.exactReadbacks[0]],
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            executionGate: base.executionGate
        )
        XCTAssertThrowsError(try CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: ["thread-a"],
            snapshot: duplicateReadback
        ))

        let cyclicInventory = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: base.inventory.runtimeVersion,
            inventoryHash: base.inventory.inventoryHash,
            observedAt: base.inventory.observedAt,
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [],
            archiveScopeNodes: [
                node(id: "child", parent: "thread-a"),
                node(id: "thread-a", parent: "child"),
            ],
            archiveScopeComplete: true
        )
        XCTAssertThrowsError(try CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: ["thread-a"],
            snapshot: CodexGhostRepairSafetySnapshot(
                inventory: cyclicInventory,
                exactReadbacks: base.exactReadbacks,
                pinnedThreadIDs: [],
                pinnedInventoryComplete: true,
                executionGate: base.executionGate
            )
        ))
    }

    func testReadOnlyReviewReportsEvidenceWithoutCreatingMutationAuthority() throws {
        let review = try CodexGhostRepairReadOnlyReviewBuilder.build(
            targetThreadIDs: ["thread-b", "thread-a"],
            snapshot: makeSnapshot(targetIDs: ["thread-a", "thread-b"])
        )

        XCTAssertEqual(review.targetThreadIDs, ["thread-a", "thread-b"])
        XCTAssertEqual(review.runtimeVersion, "codex-cli 0.148.0")
        XCTAssertTrue(review.officialEvidenceEligible)
        XCTAssertTrue(review.snapshotEvidenceEligible)
        XCTAssertTrue(review.operationalGateClear)
        XCTAssertFalse(review.liveRepairAvailable)
        XCTAssertTrue(review.protectionEvidence.allSatisfy { $0.blockers.isEmpty })
        XCTAssertTrue(review.executionGate.blockers.isEmpty)
    }

    func testReadOnlyReviewKeepsProtectionAndOperationalBlockersTyped() throws {
        let base = makeSnapshot(targetIDs: ["thread-a"])
        let snapshot = CodexGhostRepairSafetySnapshot(
            inventory: base.inventory,
            exactReadbacks: base.exactReadbacks,
            pinnedThreadIDs: ["thread-a"],
            pinnedInventoryComplete: true,
            executionGate: CodexGhostRepairExecutionGate(
                codexFullyExited: false,
                desktopOpenHandleCount: 1,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 2,
                capacitySufficient: false
            )
        )

        let review = try CodexGhostRepairReadOnlyReviewBuilder.build(
            targetThreadIDs: ["thread-a"],
            snapshot: snapshot
        )

        XCTAssertEqual(review.protectionEvidence[0].blockers, [.pinned])
        XCTAssertEqual(
            review.executionGate.blockers,
            [
                .codexStillRunning,
                .desktopDatabaseOpen,
                .historyDatabaseOpen,
                .backupCapacityInsufficient,
            ]
        )
        XCTAssertFalse(review.officialEvidenceEligible)
        XCTAssertFalse(review.operationalGateClear)
        XCTAssertFalse(review.liveRepairAvailable)
    }

    func testReadOnlyReviewPreservesUndocumentedRPCDetailsWithoutAuthorizingAbsence() throws {
        let base = makeSnapshot(targetIDs: ["thread-a"])
        let unavailable = ExactSessionReadbackEvidence(
            provider: .codex,
            nativeSessionID: "thread-a",
            status: .unavailable,
            observedAt: Date(timeIntervalSince1970: 2),
            runtimeVersion: "codex-cli 0.149.0",
            evidenceKind: .rpcError,
            rpcCode: -32600,
            message: "thread not loaded: thread-a"
        )
        let snapshot = CodexGhostRepairSafetySnapshot(
            inventory: ProviderInventorySnapshot(
                provider: .codex,
                runtimeVersion: "codex-cli 0.149.0",
                inventoryHash: base.inventory.inventoryHash,
                observedAt: base.inventory.observedAt,
                inventoryComplete: true,
                protectionComplete: true,
                sessions: [],
                archiveScopeNodes: [],
                archiveScopeComplete: true
            ),
            exactReadbacks: [unavailable],
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            executionGate: base.executionGate
        )

        let review = try CodexGhostRepairReadOnlyReviewBuilder.build(
            targetThreadIDs: ["thread-a"],
            snapshot: snapshot
        )

        XCTAssertEqual(review.exactReadbacks, [unavailable])
        XCTAssertNotNil(review.evidenceUnavailableReason)
        XCTAssertTrue(review.protectionEvidence.isEmpty)
        XCTAssertNil(review.snapshotEvidenceUnavailableReason)
        XCTAssertEqual(
            review.snapshotProtectionEvidence.map(\.threadID),
            ["thread-a"]
        )
        XCTAssertTrue(review.snapshotEvidenceEligible)
        XCTAssertFalse(review.officialEvidenceEligible)
        XCTAssertFalse(review.liveRepairAvailable)
    }

    func testSnapshotActionRequestFreezesOnlyExactEligibleReviewMetadata() throws {
        let review = try CodexGhostRepairReadOnlyReviewBuilder.build(
            targetThreadIDs: ["thread-b", "thread-a"],
            snapshot: makeSnapshot(targetIDs: ["thread-a", "thread-b"])
        )

        let request = try CodexGhostRepairSnapshotActionRequest(review: review)

        XCTAssertEqual(request.targetThreadIDs, ["thread-a", "thread-b"])
        XCTAssertEqual(request.runtimeVersion, "codex-cli 0.148.0")
        XCTAssertEqual(request.inventoryHash, "inventory-hash")
        XCTAssertEqual(request.reviewObservedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(
            request.snapshotProtectionEvidence,
            review.snapshotProtectionEvidence
        )
        XCTAssertEqual(request.reviewedExecutionGate, review.executionGate)
        XCTAssertFalse(request.liveFilesystemAuthority)
        XCTAssertFalse(request.repairMutationAuthority)
    }

    func testSnapshotActionRequestDoesNotRequireOfficialExactAbsence() throws {
        let base = makeSnapshot(targetIDs: ["thread-a"])
        let snapshot = CodexGhostRepairSafetySnapshot(
            inventory: base.inventory,
            exactReadbacks: [ExactSessionReadbackEvidence(
                provider: .codex,
                nativeSessionID: "thread-a",
                status: .unavailable,
                observedAt: Date(timeIntervalSince1970: 2),
                runtimeVersion: "codex-cli 0.148.0",
                evidenceKind: .rpcError,
                rpcCode: -32600,
                message: "thread not loaded"
            )],
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            executionGate: base.executionGate
        )
        let review = try CodexGhostRepairReadOnlyReviewBuilder.build(
            targetThreadIDs: ["thread-a"],
            snapshot: snapshot
        )

        XCTAssertFalse(review.officialEvidenceEligible)
        XCTAssertTrue(review.snapshotEvidenceEligible)

        let request = try CodexGhostRepairSnapshotActionRequest(review: review)
        XCTAssertEqual(request.targetThreadIDs, ["thread-a"])
        XCTAssertEqual(request.inventoryHash, base.inventory.inventoryHash)
        XCTAssertFalse(request.repairMutationAuthority)
    }

    func testSnapshotActionRequestRejectsPresentPinnedOrDescendantTarget() throws {
        let base = makeSnapshot(targetIDs: ["thread-a"])
        let present = AgentSession(
            system: .codex,
            nativeID: "thread-a",
            title: "Present",
            workingDirectory: "/tmp",
            updatedAt: Date(timeIntervalSince1970: 1),
            sizeBytes: nil,
            nativeState: .archived
        )
        let inventory = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: base.inventory.runtimeVersion,
            inventoryHash: base.inventory.inventoryHash,
            observedAt: base.inventory.observedAt,
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [present],
            archiveScopeNodes: [node(id: "child", parent: "thread-a")],
            archiveScopeComplete: true
        )
        let review = try CodexGhostRepairReadOnlyReviewBuilder.build(
            targetThreadIDs: ["thread-a"],
            snapshot: CodexGhostRepairSafetySnapshot(
                inventory: inventory,
                exactReadbacks: base.exactReadbacks,
                pinnedThreadIDs: ["thread-a"],
                pinnedInventoryComplete: true,
                executionGate: base.executionGate
            )
        )

        XCTAssertFalse(review.snapshotEvidenceEligible)
        XCTAssertEqual(
            review.snapshotProtectionEvidence[0].blockers,
            [.archivedInventoryPresent, .pinned, .descendantsPresent]
        )
        XCTAssertThrowsError(
            try CodexGhostRepairSnapshotActionRequest(review: review)
        )
    }

    func testSnapshotActionRequestRejectsBlockedOperationalGate() throws {
        let base = makeSnapshot(targetIDs: ["thread-a"])
        let snapshot = CodexGhostRepairSafetySnapshot(
            inventory: base.inventory,
            exactReadbacks: base.exactReadbacks,
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            executionGate: CodexGhostRepairExecutionGate(
                codexFullyExited: false,
                desktopOpenHandleCount: 1,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                capacitySufficient: true
            )
        )
        let review = try CodexGhostRepairReadOnlyReviewBuilder.build(
            targetThreadIDs: ["thread-a"],
            snapshot: snapshot
        )

        XCTAssertThrowsError(
            try CodexGhostRepairSnapshotActionRequest(review: review)
        )
    }

    func testShippingSnapshotActionCoordinatorIsUnavailableAndEffectFree() async throws {
        let review = try CodexGhostRepairReadOnlyReviewBuilder.build(
            targetThreadIDs: ["thread-a"],
            snapshot: makeSnapshot(targetIDs: ["thread-a"])
        )
        let request = try CodexGhostRepairSnapshotActionRequest(review: review)

        let coordinator = CodexGhostRepairSnapshotActionUnavailableCoordinator()
        XCTAssertEqual(coordinator.capabilities, .unavailable)
        XCTAssertFalse(coordinator.capabilities.acquisitionAvailable)
        XCTAssertFalse(coordinator.capabilities.effect.readsCodexDatabaseFiles)
        XCTAssertFalse(coordinator.capabilities.effect.writesCodexDatabaseFiles)
        XCTAssertFalse(coordinator.capabilities.repairMutationAuthority)

        let outcome = await coordinator.perform(request: request)

        XCTAssertEqual(
            outcome,
            .unavailable(
                message: "Live Ghost Repair snapshot acquisition is not available in this build."
            )
        )
    }

    private func makeSnapshot(targetIDs: [String]) -> CodexGhostRepairSafetySnapshot {
        let runtimeVersion = "codex-cli 0.148.0"
        let contract = ExactSessionAbsenceContract(
            provider: .codex,
            runtimeVersion: runtimeVersion,
            rpcCode: -32600,
            identifier: "thread_not_loaded",
            officialSourceURL: URL(string: "https://developers.openai.com/codex/app-server")!
        )
        return CodexGhostRepairSafetySnapshot(
            inventory: ProviderInventorySnapshot(
                provider: .codex,
                runtimeVersion: runtimeVersion,
                inventoryHash: "inventory-hash",
                observedAt: Date(timeIntervalSince1970: 1),
                inventoryComplete: true,
                protectionComplete: true,
                sessions: [],
                archiveScopeNodes: [],
                archiveScopeComplete: true
            ),
            exactReadbacks: targetIDs.map { id in
                ExactSessionReadbackEvidence(
                    provider: .codex,
                    nativeSessionID: id,
                    status: .absent,
                    observedAt: Date(timeIntervalSince1970: 2),
                    runtimeVersion: runtimeVersion,
                    evidenceKind: .documentedNotFound,
                    rpcCode: -32600,
                    absenceContract: contract,
                    message: "thread not loaded"
                )
            },
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            executionGate: CodexGhostRepairExecutionGate(
                codexFullyExited: true,
                desktopOpenHandleCount: 0,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                capacitySufficient: true
            )
        )
    }

    private func replacingInventory(
        _ snapshot: CodexGhostRepairSafetySnapshot,
        sessions: [AgentSession]
    ) -> CodexGhostRepairSafetySnapshot {
        CodexGhostRepairSafetySnapshot(
            inventory: ProviderInventorySnapshot(
                provider: snapshot.inventory.provider,
                runtimeVersion: snapshot.inventory.runtimeVersion,
                inventoryHash: snapshot.inventory.inventoryHash,
                observedAt: snapshot.inventory.observedAt,
                inventoryComplete: snapshot.inventory.inventoryComplete,
                protectionComplete: snapshot.inventory.protectionComplete,
                sessions: sessions,
                archiveScopeNodes: snapshot.inventory.archiveScopeNodes,
                archiveScopeComplete: snapshot.inventory.archiveScopeComplete
            ),
            exactReadbacks: snapshot.exactReadbacks,
            pinnedThreadIDs: snapshot.pinnedThreadIDs,
            pinnedInventoryComplete: snapshot.pinnedInventoryComplete,
            executionGate: snapshot.executionGate
        )
    }

    private func node(id: String, parent: String?) -> ArchiveScopeNode {
        ArchiveScopeNode(
            managerKey: "codex:\(id)",
            nativeSessionID: id,
            parentNativeSessionID: parent,
            title: id,
            nativeState: .active,
            protection: SessionProtection()
        )
    }
}

private actor FixedGhostRepairSafetySource: CodexGhostRepairReadOnlySafetySource {
    let snapshot: CodexGhostRepairSafetySnapshot
    private(set) var requestedIDs: [[String]] = []

    init(snapshot: CodexGhostRepairSafetySnapshot) {
        self.snapshot = snapshot
    }

    func ghostRepairSafetySnapshot(
        targetThreadIDs: [String]
    ) async throws -> CodexGhostRepairSafetySnapshot {
        requestedIDs.append(targetThreadIDs)
        return snapshot
    }
}
