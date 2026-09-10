@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairBulkInventoryCoordinatorTests: XCTestCase {
    private let snapshotReference =
        "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
    private let eligibleA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let blockedB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"
    private let unconfirmed = "11111111-2222-4333-8444-555555555555"
    private let presentControl = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let child = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"

    func testPackagedDefaultIsUnavailableAndAuthorityFree() async {
        let coordinator = CodexGhostRepairBulkInventoryCoordinatorFactory
            .packagedDefaultUnavailable()
        let request = makeRequest()

        let outcome = await coordinator.observe(request: request)

        XCTAssertEqual(outcome.requestID, request.requestID)
        guard case let .unavailable(_, failure) = outcome else {
            return XCTFail("Expected unavailable packaged default")
        }
        XCTAssertEqual(failure.stage, .unavailable)
        XCTAssertFalse(failure.partialInventoryPresented)
        XCTAssertFalse(failure.automaticRetry)
        XCTAssertFalse(failure.rawErrorIncluded)
        XCTAssertFalse(coordinator.capabilities.observationAvailable)
        assertAuthorityFree(coordinator.capabilities)
        XCTAssertFalse(outcome.persistsPreview)
        XCTAssertFalse(outcome.confirmationAuthority)
        XCTAssertFalse(outcome.repairMutationAuthority)
    }

    func testPostDeleteAbsenceRequiresExactAllDatabaseZeroEvidence() async throws {
        let handoff = try CodexDesktopCleanupHandoff(
            canonicalDeleteReportID: UUID(),
            items: [try .init(managerKey: "codex:\(eligibleA)", nativeSessionID: eligibleA, deletedAtMilliseconds: 1_000)]
        )
        for variant in ["absent", "catalog", "automation", "reference", "missing", "wrongID", "unsupportedRuntime"] {
            let recorder = Recorder()
            let target = CodexGhostRepairSnapshotAnalysisTargetEvidence(
                threadID: variant == "wrongID" ? unconfirmed : eligibleA,
                catalogRowDigests: variant == "catalog" ? [digest("e")] : [],
                automationRunRowDigests: variant == "automation" ? [digest("f")] : [],
                automationDefinitionRowDigests: [],
                references: .init(inbox: 0, timeline: 0, summaries: 0,
                                  canonicalState: variant == "reference" ? 1 : 0,
                                  threadTurns: 0, threadItems: 0, historyProjection: 0),
                rowContract: .unsupported
            )
            let coordinator = CodexGhostRepairBulkLiveScanCoordinator(
                liveReader: LiveCatalogFake(readback: .init(
                    databases: databaseEvidence(desktopSchemaVersion: 34),
                    targets: variant == "missing" ? [] : [target],
                    authority: .init(catalogRevision: 100, observationSequence: 200,
                                     watermarkUpdatedAt: 300, metadataRowDigest: digest("c"), localSyncRowDigest: digest("d")),
                    sourceFingerprintHash: digest("a")
                )),
                transport: TransportFake(recorder: recorder,
                    inventoryValue: makeOfficialInventory(runtimeVersion: variant == "unsupportedRuntime" ? "0.999.0" : "0.153.4"),
                    exactValues: [:]),
                absenceRegistry: .packagedReviewedV1()
            )
            let verified = await coordinator.verifyNoDesktopResidue(handoff: handoff)
            XCTAssertEqual(verified, variant == "absent", variant)
            let calls = await recorder.values()
            XCTAssertFalse(calls.contains { $0.hasPrefix("exact:") })
        }
    }

    func testPostDeleteMixedScanRetainsAlreadyClearIDsAndRejectsResidualReferences() async throws {
        let clearID = "019f64e3-ba20-4792-a7ab-1433db7ed8ec"
        let ids = [eligibleA, clearID, unconfirmed].sorted()
        let handoff = try CodexDesktopCleanupHandoff(
            canonicalDeleteReportID: UUID(), items: try ids.map {
                try .init(managerKey: "codex:\($0)", nativeSessionID: $0, deletedAtMilliseconds: 1_000)
            }
        )
        for hasReference in [false, true] {
            let recorder = Recorder()
            let targets = ids.map { id in
                id == eligibleA ? target(id, rowContract: .categoryAEligible) :
                    CodexGhostRepairSnapshotAnalysisTargetEvidence(
                        threadID: id, catalogRowDigests: [], automationRunRowDigests: [],
                        automationDefinitionRowDigests: [],
                        references: .init(inbox: hasReference && id == clearID ? 1 : 0,
                            timeline: 0, summaries: 0, canonicalState: 0,
                            threadTurns: 0, threadItems: 0, historyProjection: 0),
                        rowContract: .unsupported
                    )
            }
            let coordinator = CodexGhostRepairBulkLiveScanCoordinator(
                liveReader: ExactCleanupCatalogFake(expectedIDs: ids, readback: .init(
                    databases: databaseEvidence(desktopSchemaVersion: 34), targets: targets,
                    authority: .init(catalogRevision: 100, observationSequence: 200,
                        watermarkUpdatedAt: 300, metadataRowDigest: digest("c"), localSyncRowDigest: digest("d")),
                    sourceFingerprintHash: digest("a")
                )),
                transport: TransportFake(recorder: recorder,
                    inventoryValue: makeOfficialInventory(runtimeVersion: "0.153.4"),
                    exactValues: [presentControl: .present(returnedThreadID: presentControl),
                        eligibleA: exactAbsent(eligibleA), clearID: exactAbsent(clearID),
                        unconfirmed: exactAbsent(unconfirmed)]),
                absenceRegistry: .packagedReviewedV1(), versionSpecificRegistry: .packagedCurrent()
            )
            let outcome = await coordinator.observeCleanup(request: makeRequest(), handoff: handoff)
            guard case let .inventory(_, inventory) = outcome else {
                return XCTFail("Expected exact mixed inventory: \(outcome)")
            }
            XCTAssertEqual(inventory.items.map(\.threadID), ids)
            XCTAssertEqual(inventory.items.filter { $0.initiallyAbsent == true }.count, hasReference ? 1 : 2)
            XCTAssertEqual(inventory.eligibleThreadIDs, hasReference ? [eligibleA, unconfirmed].sorted() : ids)
            if hasReference {
                XCTAssertEqual(inventory.items.first { $0.threadID == clearID }?.disposition, .blocked)
            }
        }
    }

    func testInternalPackagedCandidateConstructsWithoutStartingObservation() {
        let coordinator = CodexGhostRepairBulkInventoryInternalFactory
            .packagedReadOnlyCandidate()

        XCTAssertTrue(coordinator.capabilities.observationAvailable)
        XCTAssertFalse(coordinator.capabilities.canonicalSourceQueryAvailable)
        XCTAssertTrue(coordinator.capabilities.publishedSnapshotQueryAvailable)
        XCTAssertTrue(coordinator.capabilities.officialInventoryAvailable)
        XCTAssertTrue(coordinator.capabilities.exactReadAvailable)
        assertAuthorityFree(coordinator.capabilities)
    }

    func testShippingLiveScanRequiresCanonicalAbsenceBeforeExactRead() async {
        let recorder = Recorder()
        let targets = [eligibleA, blockedB, unconfirmed, presentControl]
            .sorted()
            .map { threadID in
                target(
                    threadID,
                    rowContract: threadID == blockedB
                        ? .categoryBEligible : .categoryAEligible,
                    canonicalState: threadID == blockedB
                        || threadID == presentControl ? 1 : 0
                )
            }
        let coordinator = CodexGhostRepairBulkLiveScanCoordinator(
            liveReader: LiveCatalogFake(readback: .init(
                databases: databaseEvidence(desktopSchemaVersion: 34),
                targets: targets,
                authority: .init(
                    catalogRevision: 100,
                    observationSequence: 200,
                    watermarkUpdatedAt: 300,
                    metadataRowDigest: digest("c"),
                    localSyncRowDigest: digest("d")
                ),
                sourceFingerprintHash: digest("a")
            )),
            transport: TransportFake(
                recorder: recorder,
                inventoryValue: makeOfficialInventory(
                    runtimeVersion: "0.153.4"
                ),
                exactValues: [
                    presentControl: .present(returnedThreadID: presentControl),
                    eligibleA: exactAbsent(eligibleA),
                    unconfirmed: .present(returnedThreadID: unconfirmed),
                ]
            ),
            absenceRegistry: .packagedReviewedV1(),
            versionSpecificRegistry: .packagedCurrent()
        )

        let outcome = await coordinator.observe(request: makeRequest())

        guard case let .inventory(_, inventory) = outcome else {
            return XCTFail("Expected a complete two-signal inventory")
        }
        XCTAssertEqual(inventory.eligibleThreadIDs, [eligibleA])
        XCTAssertEqual(inventory.notGhostItemCount, 1)
        XCTAssertEqual(inventory.blockedItemCount, 2)
        XCTAssertEqual(
            inventory.items.first { $0.threadID == blockedB }?.blockers,
            [.canonicalStatePresent, .exactReadNotPerformed]
        )
        XCTAssertEqual(
            inventory.items.first { $0.threadID == unconfirmed }?.blockers,
            [.exactReadPresent]
        )
        let calls = await recorder.values()
        XCTAssertEqual(
            calls,
            [
                "inventory",
                "exact:\(presentControl)",
                "exact:\(eligibleA)",
                "exact:\(unconfirmed)",
            ]
        )
    }

    func testPublicPackagedReadOnlyConstructsWithoutStartingObservation() {
        let coordinator = CodexGhostRepairBulkInventoryCoordinatorFactory
            .packagedExplicitReadOnly()

        XCTAssertTrue(coordinator.capabilities.observationAvailable)
        XCTAssertTrue(coordinator.capabilities.canonicalSourceQueryAvailable)
        XCTAssertFalse(coordinator.capabilities.publishedSnapshotQueryAvailable)
        XCTAssertTrue(coordinator.capabilities.officialInventoryAvailable)
        XCTAssertTrue(coordinator.capabilities.exactReadAvailable)
        assertAuthorityFree(coordinator.capabilities)
    }

    func testV151ExactProfilesRequireAndUseFreshPresentControl() async {
        for runtimeVersion in ["0.151.0-alpha.7.2", "0.151.0"] {
            let recorder = Recorder()
            let coordinator = CodexGhostRepairBulkInventoryCandidateCoordinator(
                snapshotReader: SnapshotFake(
                    recorder: recorder,
                    evidence: makeSnapshot(
                        sourceLayoutIdentifier:
                            CodexGhostRepairPackagedReadOnlyProfileCatalog
                                .v151SourceLayoutIdentifier,
                        desktopSchemaVersion: 33
                    )
                ),
                transport: TransportFake(
                    recorder: recorder,
                    inventoryValue: makeOfficialInventory(
                        runtimeVersion: runtimeVersion
                    ),
                    exactValues: [
                        presentControl: .present(
                            returnedThreadID: presentControl
                        ),
                        eligibleA: exactAbsent(eligibleA),
                        blockedB: exactAbsent(blockedB),
                        unconfirmed: exactAbsent(unconfirmed),
                    ]
                ),
                absenceRegistry: .packagedReviewedV1(),
                versionSpecificRegistry: .packagedV151()
            )

            let outcome = await coordinator.observe(request: makeRequest())

            guard case let .inventory(_, inventory) = outcome else {
                return XCTFail(
                    "Expected v0.151 read-only inventory for \(runtimeVersion)"
                )
            }
            XCTAssertEqual(inventory.observedCatalogItemCount, 4)
            XCTAssertEqual(inventory.notGhostItemCount, 1)
            XCTAssertEqual(inventory.eligibleItemCount, 2)
            XCTAssertEqual(inventory.blockedItemCount, 1)
            XCTAssertFalse(inventory.repairPreviewAuthority)
            XCTAssertFalse(inventory.repairMutationAuthority)
            let calls = await recorder.values()
            XCTAssertEqual(calls.first, "snapshot:\(snapshotReference)")
            XCTAssertEqual(calls.dropFirst().first, "inventory")
            XCTAssertEqual(calls.dropFirst(2).first, "exact:\(presentControl)")
        }
    }

    func testCurrentV152ProfileRequiresAndUsesFreshPresentControl() async {
        let recorder = Recorder()
        let coordinator = CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: SnapshotFake(
                recorder: recorder,
                evidence: makeSnapshot(
                    sourceLayoutIdentifier:
                        CodexGhostRepairPackagedReadOnlyProfileCatalog
                            .v152SourceLayoutIdentifier,
                    desktopSchemaVersion: 34
                )
            ),
            transport: TransportFake(
                recorder: recorder,
                inventoryValue: makeOfficialInventory(
                    runtimeVersion: "0.152.1"
                ),
                exactValues: [
                    presentControl: .present(returnedThreadID: presentControl),
                    eligibleA: exactAbsent(eligibleA),
                    blockedB: exactAbsent(blockedB),
                    unconfirmed: exactAbsent(unconfirmed),
                ]
            ),
            absenceRegistry: .packagedReviewedV1(),
            versionSpecificRegistry: .packagedCurrent()
        )

        let outcome = await coordinator.observe(request: makeRequest())

        guard case let .inventory(_, inventory) = outcome else {
            return XCTFail("Expected current v0.152.1 read-only inventory")
        }
        XCTAssertEqual(inventory.observedCatalogItemCount, 4)
        XCTAssertEqual(inventory.notGhostItemCount, 1)
        XCTAssertEqual(inventory.eligibleItemCount, 2)
        XCTAssertEqual(inventory.blockedItemCount, 1)
        XCTAssertFalse(inventory.repairPreviewAuthority)
        XCTAssertFalse(inventory.repairMutationAuthority)
        let calls = await recorder.values()
        XCTAssertEqual(calls.first, "snapshot:\(snapshotReference)")
        XCTAssertEqual(calls.dropFirst().first, "inventory")
        XCTAssertEqual(calls.dropFirst(2).first, "exact:\(presentControl)")
    }

    func testCurrentV153PairRequiresAndUsesFreshPresentControl() async {
        let recorder = Recorder()
        let coordinator = CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: SnapshotFake(
                recorder: recorder,
                evidence: makeSnapshot(
                    sourceLayoutIdentifier:
                        CodexGhostRepairPackagedReadOnlyProfileCatalog
                            .v153SourceLayoutIdentifier,
                    desktopSchemaVersion: 34
                )
            ),
            transport: TransportFake(
                recorder: recorder,
                inventoryValue: makeOfficialInventory(
                    runtimeVersion: "0.153.2"
                ),
                exactValues: [
                    presentControl: .present(returnedThreadID: presentControl),
                    eligibleA: exactAbsent(eligibleA),
                    blockedB: exactAbsent(blockedB),
                    unconfirmed: exactAbsent(unconfirmed),
                ]
            ),
            absenceRegistry: .packagedReviewedV1(),
            versionSpecificRegistry: .packagedCurrent()
        )

        let outcome = await coordinator.observe(request: makeRequest())

        guard case let .inventory(_, inventory) = outcome else {
            return XCTFail("Expected current v0.153 provider/source pair")
        }
        XCTAssertEqual(inventory.observedCatalogItemCount, 4)
        XCTAssertEqual(inventory.notGhostItemCount, 1)
        XCTAssertEqual(inventory.eligibleItemCount, 2)
        XCTAssertEqual(inventory.blockedItemCount, 1)
        XCTAssertFalse(inventory.repairPreviewAuthority)
        XCTAssertFalse(inventory.repairMutationAuthority)
        let calls = await recorder.values()
        XCTAssertEqual(calls.first, "snapshot:\(snapshotReference)")
        XCTAssertEqual(calls.dropFirst().first, "inventory")
        XCTAssertEqual(calls.dropFirst(2).first, "exact:\(presentControl)")
    }

    func testCurrentV1534PairRequiresAndUsesFreshPresentControl() async {
        let recorder = Recorder()
        let coordinator = CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: SnapshotFake(
                recorder: recorder,
                evidence: makeSnapshot(
                    sourceLayoutIdentifier:
                        CodexGhostRepairPackagedReadOnlyProfileCatalog
                            .v1534SourceLayoutIdentifier,
                    desktopSchemaVersion: 34
                )
            ),
            transport: TransportFake(
                recorder: recorder,
                inventoryValue: makeOfficialInventory(
                    runtimeVersion: "0.153.4"
                ),
                exactValues: [
                    presentControl: .present(returnedThreadID: presentControl),
                    eligibleA: exactAbsent(eligibleA),
                    blockedB: exactAbsent(blockedB),
                    unconfirmed: exactAbsent(unconfirmed),
                ]
            ),
            absenceRegistry: .packagedReviewedV1(),
            versionSpecificRegistry: .packagedCurrent()
        )

        let outcome = await coordinator.observe(request: makeRequest())

        guard case let .inventory(_, inventory) = outcome else {
            return XCTFail("Expected exact v0.153.4 provider/source pair")
        }
        XCTAssertEqual(inventory.observedCatalogItemCount, 4)
        XCTAssertEqual(inventory.notGhostItemCount, 1)
        XCTAssertEqual(inventory.eligibleItemCount, 2)
        XCTAssertEqual(inventory.blockedItemCount, 1)
        XCTAssertFalse(inventory.repairPreviewAuthority)
        XCTAssertFalse(inventory.repairMutationAuthority)
        let calls = await recorder.values()
        XCTAssertEqual(calls.first, "snapshot:\(snapshotReference)")
        XCTAssertEqual(calls.dropFirst().first, "inventory")
        XCTAssertEqual(calls.dropFirst(2).first, "exact:\(presentControl)")
    }

    func testOldSnapshotProfileStopsCurrentV1534BeforeAnyExactRead() async {
        let recorder = Recorder()
        let coordinator = CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: SnapshotFake(
                recorder: recorder,
                evidence: makeSnapshot(
                    sourceLayoutIdentifier:
                        CodexGhostRepairPackagedReadOnlyProfileCatalog
                            .v153SourceLayoutIdentifier,
                    desktopSchemaVersion: 34
                )
            ),
            transport: TransportFake(
                recorder: recorder,
                inventoryValue: makeOfficialInventory(
                    runtimeVersion: "0.153.4"
                ),
                exactValues: [:]
            ),
            absenceRegistry: .packagedReviewedV1(),
            versionSpecificRegistry: .packagedCurrent()
        )

        let outcome = await coordinator.observe(request: makeRequest())

        assertUnavailable(outcome, stage: .snapshotProfile)
        let calls = await recorder.values()
        XCTAssertEqual(
            calls,
            ["snapshot:\(snapshotReference)", "inventory"]
        )
    }

    func testExplicitObservationComposesOfficialAndSnapshotEvidenceInOrder()
        async throws
    {
        let recorder = Recorder()
        let snapshot = makeSnapshot()
        let transport = TransportFake(
            recorder: recorder,
            inventoryValue: makeOfficialInventory(),
            exactValues: [
                presentControl: .present(returnedThreadID: presentControl),
                eligibleA: exactAbsent(eligibleA),
                blockedB: exactAbsent(blockedB),
                unconfirmed: .failure(
                    errorKind: .rpcError,
                    rpcCode: -32600,
                    responseShapeIdentifier: "rpc-error-code-message-v1",
                    message: "changed response"
                ),
            ]
        )
        let coordinator = CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: SnapshotFake(
                recorder: recorder,
                evidence: snapshot
            ),
            transport: transport,
            absenceRegistry: .packagedReviewedV1()
        )
        let request = makeRequest()

        let outcome = await coordinator.observe(request: request)

        guard case let .inventory(requestID, inventory) = outcome else {
            return XCTFail("Expected composed bulk inventory")
        }
        XCTAssertEqual(requestID, request.requestID)
        XCTAssertEqual(inventory.observedCatalogItemCount, 4)
        XCTAssertEqual(inventory.notGhostItemCount, 1)
        XCTAssertEqual(inventory.eligibleItemCount, 1)
        XCTAssertEqual(inventory.blockedItemCount, 2)
        XCTAssertEqual(inventory.ordinaryEligibleItemCount, 1)
        XCTAssertEqual(inventory.automationEligibleItemCount, 0)
        XCTAssertEqual(inventory.eligibleThreadIDs, [eligibleA])
        XCTAssertEqual(
            inventory.items.first { $0.threadID == blockedB }?.blockers,
            [.pinned, .descendantsPresent]
        )
        XCTAssertEqual(
            inventory.items.first { $0.threadID == unconfirmed }?.disposition,
            .unconfirmed
        )
        XCTAssertEqual(
            inventory.items.first { $0.threadID == presentControl }?.disposition,
            .notGhost
        )
        let calls = await recorder.values()
        XCTAssertEqual(
            calls,
            [
                "snapshot:\(snapshotReference)",
                "inventory",
                "exact:\(presentControl)",
                "exact:\(eligibleA)",
                "exact:\(blockedB)",
                "exact:\(unconfirmed)",
            ]
        )
        XCTAssertTrue(coordinator.capabilities.observationAvailable)
        assertAuthorityFree(coordinator.capabilities)
    }

    func testInvalidRequestStopsBeforeAnyRead() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)
        let request = CodexGhostRepairBulkInventoryRequest(
            requestID: UUID(),
            snapshotReference: "/Users/example/.codex/sqlite/codex-dev.db"
        )

        let outcome = await coordinator.observe(request: request)

        assertUnavailable(outcome, stage: .requestValidation)
        let calls = await recorder.values()
        XCTAssertEqual(calls, [])
        XCTAssertFalse(request.acceptsCallerPath)
        XCTAssertFalse(request.acceptsCallerThreadIDs)
        XCTAssertFalse(request.automaticObservation)
        XCTAssertFalse(request.persistsPreview)
        XCTAssertFalse(request.repairMutationAuthority)
    }

    func testIncompleteOfficialInventoryStopsBeforeExactRead() async {
        let recorder = Recorder()
        let incomplete = makeOfficialInventory(inventoryComplete: false)
        let coordinator = CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: SnapshotFake(
                recorder: recorder,
                evidence: makeSnapshot()
            ),
            transport: TransportFake(
                recorder: recorder,
                inventoryValue: incomplete,
                exactValues: [:]
            ),
            absenceRegistry: .packagedReviewedV1()
        )

        let outcome = await coordinator.observe(request: makeRequest())

        assertUnavailable(outcome, stage: .officialInventory)
        let calls = await recorder.values()
        XCTAssertEqual(
            calls,
            ["snapshot:\(snapshotReference)", "inventory"]
        )
    }

    func testPresentControlMismatchStopsBeforeCandidateReads() async {
        let recorder = Recorder()
        let coordinator = CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: SnapshotFake(
                recorder: recorder,
                evidence: makeSnapshot()
            ),
            transport: TransportFake(
                recorder: recorder,
                inventoryValue: makeOfficialInventory(),
                exactValues: [
                    presentControl: .present(returnedThreadID: eligibleA),
                ]
            ),
            absenceRegistry: .packagedReviewedV1()
        )

        let outcome = await coordinator.observe(request: makeRequest())

        assertUnavailable(outcome, stage: .presentControl)
        let calls = await recorder.values()
        XCTAssertEqual(
            calls,
            [
                "snapshot:\(snapshotReference)",
                "inventory",
                "exact:\(presentControl)",
            ]
        )
    }

    func testOneCandidateTransportFailureReturnsNoPartialInventory() async {
        let recorder = Recorder()
        let coordinator = CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: SnapshotFake(
                recorder: recorder,
                evidence: makeSnapshot()
            ),
            transport: TransportFake(
                recorder: recorder,
                inventoryValue: makeOfficialInventory(),
                exactValues: [
                    presentControl: .present(
                        returnedThreadID: presentControl
                    ),
                    eligibleA: exactAbsent(eligibleA),
                ],
                throwingThreadIDs: [blockedB]
            ),
            absenceRegistry: .packagedReviewedV1()
        )

        let outcome = await coordinator.observe(request: makeRequest())

        assertUnavailable(outcome, stage: .candidateExactRead)
        guard case let .unavailable(_, failure) = outcome else { return }
        XCTAssertFalse(failure.partialInventoryPresented)
        XCTAssertFalse(failure.automaticRetry)
        let calls = await recorder.values()
        XCTAssertEqual(
            calls,
            [
                "snapshot:\(snapshotReference)",
                "inventory",
                "exact:\(presentControl)",
                "exact:\(eligibleA)",
                "exact:\(blockedB)",
            ]
        )
    }

    func testConcurrentObservationIsRejectedWithoutStartingSecondRead()
        async
    {
        let recorder = Recorder()
        let snapshot = BlockingSnapshotFake(
            recorder: recorder,
            evidence: makeSnapshot()
        )
        let transport = TransportFake(
            recorder: recorder,
            inventoryValue: makeOfficialInventory(),
            exactValues: [
                presentControl: .present(returnedThreadID: presentControl),
                eligibleA: exactAbsent(eligibleA),
                blockedB: exactAbsent(blockedB),
                unconfirmed: exactAbsent(unconfirmed),
            ]
        )
        let coordinator = CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: snapshot,
            transport: transport,
            absenceRegistry: .packagedReviewedV1()
        )
        let firstRequest = makeRequest()
        let secondRequest = CodexGhostRepairBulkInventoryRequest(
            requestID: UUID(
                uuidString: "dddddddd-eeee-4fff-8000-111111111111"
            )!,
            snapshotReference: snapshotReference
        )

        async let first = coordinator.observe(request: firstRequest)
        await snapshot.waitUntilStarted()
        let second = await coordinator.observe(request: secondRequest)

        assertUnavailable(second, stage: .busy)
        XCTAssertEqual(second.requestID, secondRequest.requestID)
        await snapshot.release()
        _ = await first
        let calls = await recorder.values()
        XCTAssertEqual(
            calls.filter { $0.hasPrefix("snapshot:") },
            ["snapshot:\(snapshotReference)"]
        )
    }

    private func makeCoordinator(
        recorder: Recorder
    ) -> CodexGhostRepairBulkInventoryCandidateCoordinator {
        CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: SnapshotFake(
                recorder: recorder,
                evidence: makeSnapshot()
            ),
            transport: TransportFake(
                recorder: recorder,
                inventoryValue: makeOfficialInventory(),
                exactValues: [:]
            ),
            absenceRegistry: .packagedReviewedV1()
        )
    }

    private func makeRequest() -> CodexGhostRepairBulkInventoryRequest {
        .init(
            requestID: UUID(
                uuidString: "cccccccc-dddd-4eee-8fff-000000000000"
            )!,
            snapshotReference: snapshotReference
        )
    }

    private func makeSnapshot(
        sourceLayoutIdentifier: String =
            CodexGhostRepairSnapshotSourceLayout.identifier,
        desktopSchemaVersion: Int32 = 32
    )
        -> CodexGhostRepairBulkInventorySnapshotEvidence
    {
        let targets = [eligibleA, blockedB, unconfirmed, presentControl]
            .sorted()
            .map { threadID in
                target(
                    threadID,
                    rowContract: threadID == blockedB
                        ? .categoryBEligible : .categoryAEligible
                )
            }
        return .init(
            snapshotReference: snapshotReference,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            sourceFingerprintHash: digest("a"),
            manifestHash: digest("b"),
            readback: .init(
                databases: databaseEvidence(
                    desktopSchemaVersion: desktopSchemaVersion
                ),
                targets: targets,
                authority: .init(
                    catalogRevision: 100,
                    observationSequence: 200,
                    watermarkUpdatedAt: 300,
                    metadataRowDigest: digest("c"),
                    localSyncRowDigest: digest("d")
                ),
                sourceFingerprintHash: digest("a")
            )
        )
    }

    private func makeOfficialInventory(
        runtimeVersion: String = "0.149.0",
        inventoryComplete: Bool = true
    ) -> CodexGhostRepairExperimentalTransportInventory {
        .init(
            provider: .codex,
            runtimeVersion: runtimeVersion,
            inventoryComplete: inventoryComplete,
            activeThreadIDs: [presentControl],
            archivedThreadIDs: [],
            pinnedThreadIDs: [blockedB],
            pinnedInventoryComplete: true,
            descendantNodes: [
                .init(threadID: child, parentThreadID: blockedB),
            ],
            descendantGraphComplete: true
        )
    }

    private func exactAbsent(
        _ threadID: String
    ) -> CodexGhostRepairExperimentalTransportExactReadOutcome {
        .failure(
            errorKind: .rpcError,
            rpcCode: -32600,
            responseShapeIdentifier: "rpc-error-code-message-v1",
            message: "thread not loaded: \(threadID)"
        )
    }

    private func target(
        _ threadID: String,
        rowContract: CodexGhostRepairSnapshotAnalysisRowContract,
        canonicalState: Int = 0
    ) -> CodexGhostRepairSnapshotAnalysisTargetEvidence {
        .init(
            threadID: threadID,
            catalogRowDigests: [digest("e")],
            automationRunRowDigests: rowContract == .categoryBEligible
                ? [digest("f")] : [],
            automationDefinitionRowDigests:
                rowContract == .categoryBEligible ? [digest("1")] : [],
            references: .init(
                inbox: 0,
                timeline: 0,
                summaries: 0,
                canonicalState: canonicalState,
                threadTurns: 0,
                threadItems: 0,
                historyProjection: 0
            ),
            rowContract: rowContract
        )
    }

    private func databaseEvidence(
        desktopSchemaVersion: Int32 = 32
    )
        -> [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    {
        zip(
            CodexGhostRepairSnapshotAnalysisDatabase.allCases,
            [desktopSchemaVersion, 2, 0, 0]
        ).map {
            .init(
                database: $0.0,
                schemaVersion: $0.1,
                integrityCheckPassed: true,
                foreignKeyViolationCount: 0
            )
        }
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private func assertAuthorityFree(
        _ capabilities: CodexGhostRepairBulkInventoryCapabilities,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(capabilities.acceptsCallerPath, file: file, line: line)
        XCTAssertFalse(
            capabilities.acceptsCallerThreadIDs,
            file: file,
            line: line
        )
        XCTAssertFalse(
            capabilities.automaticObservation,
            file: file,
            line: line
        )
        XCTAssertFalse(capabilities.automaticRetry, file: file, line: line)
        XCTAssertFalse(
            capabilities.writesPublishedSnapshot,
            file: file,
            line: line
        )
        XCTAssertFalse(capabilities.persistsPreview, file: file, line: line)
        XCTAssertFalse(
            capabilities.officialLifecycleAuthority,
            file: file,
            line: line
        )
        XCTAssertFalse(
            capabilities.confirmationAuthority,
            file: file,
            line: line
        )
        XCTAssertFalse(
            capabilities.repairMutationAuthority,
            file: file,
            line: line
        )
    }

    private func assertUnavailable(
        _ outcome: CodexGhostRepairBulkInventoryOutcome,
        stage: CodexGhostRepairBulkInventoryFailureStage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(_, failure) = outcome else {
            return XCTFail("Expected unavailable outcome", file: file, line: line)
        }
        XCTAssertEqual(failure.stage, stage, file: file, line: line)
    }
}

private struct ExactCleanupCatalogFake: CodexGhostRepairBulkLiveCatalogReading {
    let expectedIDs: [String]
    let readback: CodexGhostRepairBulkCatalogQueryReadback

    func readExactCleanupScope(profile: CodexGhostRepairSnapshotSourceProfile,
                               targetThreadIDs: [String]) throws -> CodexGhostRepairBulkCatalogQueryReadback {
        XCTAssertEqual(targetThreadIDs, expectedIDs)
        return readback
    }

    func read(profile: CodexGhostRepairSnapshotSourceProfile) throws -> CodexGhostRepairBulkCatalogQueryReadback {
        XCTFail("Post-delete scan must not fall back to catalog-only enumeration")
        throw CocoaError(.fileReadUnknown)
    }
}

private struct LiveCatalogFake: CodexGhostRepairBulkLiveCatalogReading {
    let readback: CodexGhostRepairBulkCatalogQueryReadback

    func readExactCleanupScope(
        profile: CodexGhostRepairSnapshotSourceProfile,
        targetThreadIDs: [String]
    ) throws -> CodexGhostRepairBulkCatalogQueryReadback {
        readback
    }

    func read(
        profile _: CodexGhostRepairSnapshotSourceProfile
    ) throws -> CodexGhostRepairBulkCatalogQueryReadback {
        readback
    }
}

private actor Recorder {
    private var calls: [String] = []

    func append(_ value: String) { calls.append(value) }
    func values() -> [String] { calls }
}

private struct SnapshotFake: CodexGhostRepairBulkSnapshotCatalogReading {
    let recorder: Recorder
    let evidence: CodexGhostRepairBulkInventorySnapshotEvidence

    func readBulkCatalog(
        snapshotReference: String
    ) async throws -> CodexGhostRepairBulkInventorySnapshotEvidence {
        await recorder.append("snapshot:\(snapshotReference)")
        return evidence
    }
}

private actor BlockingSnapshotFake:
    CodexGhostRepairBulkSnapshotCatalogReading
{
    let recorder: Recorder
    let evidence: CodexGhostRepairBulkInventorySnapshotEvidence
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(
        recorder: Recorder,
        evidence: CodexGhostRepairBulkInventorySnapshotEvidence
    ) {
        self.recorder = recorder
        self.evidence = evidence
    }

    func readBulkCatalog(
        snapshotReference: String
    ) async throws -> CodexGhostRepairBulkInventorySnapshotEvidence {
        await recorder.append("snapshot:\(snapshotReference)")
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return evidence
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor TransportFake:
    CodexGhostRepairBulkOfficialObservationTransport
{
    let recorder: Recorder
    let inventoryValue: CodexGhostRepairExperimentalTransportInventory
    let exactValues:
        [String: CodexGhostRepairExperimentalTransportExactReadOutcome]
    let throwingThreadIDs: Set<String>

    init(
        recorder: Recorder,
        inventoryValue: CodexGhostRepairExperimentalTransportInventory,
        exactValues:
            [String: CodexGhostRepairExperimentalTransportExactReadOutcome],
        throwingThreadIDs: Set<String> = []
    ) {
        self.recorder = recorder
        self.inventoryValue = inventoryValue
        self.exactValues = exactValues
        self.throwingThreadIDs = throwingThreadIDs
    }

    func inventory() async throws
        -> CodexGhostRepairExperimentalTransportInventory
    {
        await recorder.append("inventory")
        return inventoryValue
    }

    func exactRead(
        threadID: String
    ) async throws -> CodexGhostRepairExperimentalTransportExactReadOutcome {
        await recorder.append("exact:\(threadID)")
        guard !throwingThreadIDs.contains(threadID),
              let value = exactValues[threadID] else {
            throw TestFailure.unavailable
        }
        return value
    }
}

private enum TestFailure: Error {
    case unavailable
}
