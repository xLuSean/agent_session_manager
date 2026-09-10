@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairInitialWitnessDiscoveryTests: XCTestCase {
    private let sourceLayout =
        CodexGhostRepairPackagedReadOnlyProfileCatalog
            .v1534SourceLayoutIdentifier
    private let fingerprint = "sha256:" + String(repeating: "a", count: 64)

    func testUnavailableAndPackagedCapabilitiesDenyEveryAuthority() async {
        let unavailable = CodexGhostRepairInitialWitnessUnavailableDiscovery()
        XCTAssertFalse(unavailable.capabilities.discoveryAvailable)
        guard case .unavailable = await unavailable.discover() else {
            return XCTFail("Unavailable discovery must fail closed")
        }

        let packaged = CodexGhostRepairInitialWitnessDiscoveryFactory
            .packagedExplicitReadOnly()
        let capabilities = packaged.capabilities
        XCTAssertTrue(capabilities.discoveryAvailable)
        XCTAssertTrue(capabilities.readsFixedRawDatabaseFiles)
        XCTAssertTrue(capabilities.officialInventoryAvailable)
        XCTAssertFalse(capabilities.acceptsCallerPath)
        XCTAssertFalse(capabilities.acceptsCallerThreadIDs)
        XCTAssertFalse(capabilities.writesCodexDatabaseFiles)
        XCTAssertFalse(capabilities.writesManagerFilesystem)
        XCTAssertTrue(capabilities.usesTemporaryWorkspace)
        XCTAssertTrue(capabilities.writesTemporaryWorkspace)
        XCTAssertFalse(capabilities.publishesSnapshot)
        XCTAssertFalse(capabilities.persistsPreview)
        XCTAssertFalse(capabilities.confirmationAuthority)
        XCTAssertFalse(capabilities.repairMutationAuthority)
    }

    func testDiscoveryFiltersCompleteOfficialProtectionThenTakesStableTen()
        async
    {
        let catalogIDs = (1...18).map(id)
        let active = catalogIDs[0]
        let archived = catalogIDs[1]
        let pinned = catalogIDs[2]
        let parent = catalogIDs[3]
        let child = catalogIDs[4]
        let coordinator = makeCoordinator(
            catalogIDs: catalogIDs,
            active: [active, child],
            archived: [archived],
            pinned: [pinned],
            descendants: [
                .init(threadID: parent, parentThreadID: nil),
                .init(threadID: child, parentThreadID: parent),
            ]
        )

        let outcome = await coordinator.discover()

        guard case let .discovered(evidence) = outcome else {
            return XCTFail("Expected bounded initial witnesses")
        }
        XCTAssertEqual(evidence.threadIDs, Array(catalogIDs[5...14]))
        XCTAssertEqual(evidence.threadIDs.count, 10)
        XCTAssertEqual(evidence.runtimeVersion, "0.153.4")
        XCTAssertEqual(evidence.sourceLayoutIdentifier, sourceLayout)
        XCTAssertEqual(evidence.sourceFingerprintHash, fingerprint)
        XCTAssertFalse(evidence.confirmedGhostEvidence)
        XCTAssertFalse(evidence.snapshotAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)
        XCTAssertFalse(outcome.publishesSnapshot)
        XCTAssertFalse(outcome.persistsPreview)
        XCTAssertFalse(outcome.confirmationAuthority)
        XCTAssertFalse(outcome.repairMutationAuthority)
    }

    func testEmptyMeansNoEligibleWitnessInCompleteCatalog() async {
        let catalogIDs = (1...4).map(id)
        let coordinator = makeCoordinator(
            catalogIDs: catalogIDs,
            active: [catalogIDs[0]],
            archived: [catalogIDs[1]],
            pinned: [catalogIDs[2]],
            descendants: [
                .init(threadID: catalogIDs[3], parentThreadID: nil),
                .init(threadID: id(99), parentThreadID: catalogIDs[3]),
            ]
        )

        guard case let .empty(runtime, layout, observedFingerprint) =
            await coordinator.discover() else {
            return XCTFail("Expected an empty eligible witness set")
        }
        XCTAssertEqual(runtime, "0.153.4")
        XCTAssertEqual(layout, sourceLayout)
        XCTAssertEqual(observedFingerprint, fingerprint)
    }

    func testIncompleteOfficialScopeFailsBeforeCatalogRead() async {
        let catalog = InitialWitnessCatalogSpy(
            result: makeCatalog(ids: [id(1)])
        )
        let coordinator = CodexGhostRepairInitialWitnessDiscoveryCoordinator(
            catalogReader: catalog,
            officialTransport: InitialWitnessTransportFake(
                inventoryValue: makeOfficialInventory(
                    active: [],
                    archived: [],
                    pinned: [],
                    descendants: [],
                    inventoryComplete: false
                )
            )
        )

        guard case .unavailable = await coordinator.discover() else {
            return XCTFail("Incomplete official inventory must fail closed")
        }
        XCTAssertEqual(catalog.readCount, 0)
    }

    func testCatalogMustBeFullyBoundedCanonicalAndProfileMatched() async {
        let malformedCases: [CodexGhostRepairInitialWitnessCatalogReadback] = [
            makeCatalog(ids: [id(2), id(1)]),
            makeCatalog(ids: [id(1), id(1)]),
            makeCatalog(ids: ["not-a-canonical-id"]),
            makeCatalog(ids: (1...10_001).map(id)),
            makeCatalog(
                ids: [id(1)],
                layout: CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v153SourceLayoutIdentifier
            ),
            makeCatalog(ids: [id(1)], fingerprint: "sha256:short"),
            makeCatalog(ids: [id(1)], desktopSchema: 33),
        ]
        for catalog in malformedCases {
            let coordinator = CodexGhostRepairInitialWitnessDiscoveryCoordinator(
                catalogReader: InitialWitnessCatalogFake(result: catalog),
                officialTransport: InitialWitnessTransportFake(
                    inventoryValue: makeOfficialInventory(
                        active: [],
                        archived: [],
                        pinned: [],
                        descendants: []
                    )
                )
            )
            guard case .unavailable = await coordinator.discover() else {
                return XCTFail("Malformed catalog evidence must fail closed")
            }
        }
    }

    func testUnsupportedRuntimeAndInvalidDescendantGraphFailClosed() async {
        let unsupported = CodexGhostRepairInitialWitnessDiscoveryCoordinator(
            catalogReader: InitialWitnessCatalogFake(
                result: makeCatalog(ids: [id(1)])
            ),
            officialTransport: InitialWitnessTransportFake(
                inventoryValue: makeOfficialInventory(
                    active: [],
                    archived: [],
                    pinned: [],
                    descendants: [],
                    runtimeVersion: "0.154.0"
                )
            )
        )
        guard case .unavailable = await unsupported.discover() else {
            return XCTFail("Unsupported runtime must fail closed")
        }

        let cycle = CodexGhostRepairInitialWitnessDiscoveryCoordinator(
            catalogReader: InitialWitnessCatalogFake(
                result: makeCatalog(ids: [id(1), id(2)])
            ),
            officialTransport: InitialWitnessTransportFake(
                inventoryValue: makeOfficialInventory(
                    active: [],
                    archived: [],
                    pinned: [],
                    descendants: [
                        .init(threadID: id(1), parentThreadID: id(2)),
                        .init(threadID: id(2), parentThreadID: id(1)),
                    ]
                )
            )
        )
        guard case .unavailable = await cycle.discover() else {
            return XCTFail("Descendant cycles must fail closed")
        }
    }

    func testAllSourceGraphMustContainEveryInteractiveSession() async {
        let interactive = id(1)
        let coordinator = CodexGhostRepairInitialWitnessDiscoveryCoordinator(
            catalogReader: InitialWitnessCatalogFake(
                result: makeCatalog(ids: [interactive, id(2)])
            ),
            officialTransport: InitialWitnessTransportFake(
                inventoryValue: makeOfficialInventory(
                    active: [interactive],
                    archived: [],
                    pinned: [],
                    descendants: [],
                    synthesizeAllSourceNodes: false
                )
            )
        )

        guard case .unavailable = await coordinator.discover() else {
            return XCTFail(
                "A complete flag cannot hide a missing all-source node"
            )
        }
    }

    func testAutomationOnlyAllSourceSessionIsNeverSuggestedAsWitness() async {
        let automation = id(1)
        let absentCandidate = id(2)
        let coordinator = makeCoordinator(
            catalogIDs: [automation, absentCandidate],
            active: [],
            archived: [],
            pinned: [],
            descendants: [
                .init(threadID: automation, parentThreadID: nil),
            ]
        )

        guard case let .discovered(evidence) = await coordinator.discover()
        else {
            return XCTFail("Expected the absent catalog identity only")
        }
        XCTAssertEqual(evidence.threadIDs, [absentCandidate])
    }

    func testMaximumBoundedAllSourceChainValidatesWithoutQuadraticTraversal()
        async
    {
        let nodes = (1...10_000).map { index in
            CodexGhostRepairExperimentalDescendantNode(
                threadID: id(index),
                parentThreadID: index == 1 ? nil : id(index - 1)
            )
        }
        let absentCandidate = id(10_001)
        let coordinator = makeCoordinator(
            catalogIDs: [absentCandidate],
            active: [],
            archived: [],
            pinned: [],
            descendants: nodes
        )

        guard case let .discovered(evidence) = await coordinator.discover()
        else {
            return XCTFail("Expected the absent candidate after bounded graph validation")
        }
        XCTAssertEqual(evidence.threadIDs, [absentCandidate])
    }

    func testSecondConcurrentDiscoveryIsRejectedWithoutReplay() async {
        let transport = SuspendingInitialWitnessTransport()
        let coordinator = CodexGhostRepairInitialWitnessDiscoveryCoordinator(
            catalogReader: InitialWitnessCatalogFake(
                result: makeCatalog(ids: [id(1)])
            ),
            officialTransport: transport
        )
        let first = Task { await coordinator.discover() }
        await transport.waitUntilRequested()

        guard case .unavailable = await coordinator.discover() else {
            return XCTFail("Concurrent discovery must not start a second read")
        }
        await transport.finish(
            with: makeOfficialInventory(
                active: [],
                archived: [],
                pinned: [],
                descendants: []
            )
        )
        guard case .discovered = await first.value else {
            return XCTFail("The original discovery should complete once")
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testInitialWitnessEvidenceBindsExactSnapshotRequestProfile()
        throws
    {
        let ids = [id(1), id(2)]
        let review = makeReview(ids: ids)
        let evidence = CodexGhostRepairInitialWitnessEvidence(
            threadIDs: ids,
            runtimeVersion: "0.153.4",
            sourceLayoutIdentifier: sourceLayout,
            sourceFingerprintHash: fingerprint
        )

        let request = try CodexGhostRepairSnapshotActionRequest(
            review: review,
            initialWitnessEvidence: evidence
        )
        let selection = try CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        )

        XCTAssertEqual(request.initialWitnessEvidence, evidence)
        XCTAssertEqual(selection.sourceProfile, .v1534DesktopV34)
    }

    func testInitialWitnessEvidenceDriftCannotCreateSnapshotRequest() {
        let ids = [id(1)]
        let review = makeReview(ids: ids)
        let wrongValues = [
            CodexGhostRepairInitialWitnessEvidence(
                threadIDs: [id(2)],
                runtimeVersion: "0.153.4",
                sourceLayoutIdentifier: sourceLayout,
                sourceFingerprintHash: fingerprint
            ),
            CodexGhostRepairInitialWitnessEvidence(
                threadIDs: ids,
                runtimeVersion: "0.153.2",
                sourceLayoutIdentifier: sourceLayout,
                sourceFingerprintHash: fingerprint
            ),
            CodexGhostRepairInitialWitnessEvidence(
                threadIDs: ids,
                runtimeVersion: "0.153.4",
                sourceLayoutIdentifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v153SourceLayoutIdentifier,
                sourceFingerprintHash: fingerprint
            ),
            CodexGhostRepairInitialWitnessEvidence(
                threadIDs: ids,
                runtimeVersion: "0.153.4",
                sourceLayoutIdentifier: sourceLayout,
                sourceFingerprintHash: "sha256:short"
            ),
        ]

        for evidence in wrongValues {
            XCTAssertThrowsError(
                try CodexGhostRepairSnapshotActionRequest(
                    review: review,
                    initialWitnessEvidence: evidence
                )
            )
        }
    }

    func testDiscoveryFingerprintIsProvenanceNotSnapshotAuthorization()
        throws
    {
        let ids = [id(1)]
        let review = makeReview(ids: ids)
        let earlierSource = CodexGhostRepairInitialWitnessEvidence(
            threadIDs: ids,
            runtimeVersion: "0.153.4",
            sourceLayoutIdentifier: sourceLayout,
            sourceFingerprintHash:
                "sha256:" + String(repeating: "b", count: 64)
        )

        let request = try CodexGhostRepairSnapshotActionRequest(
            review: review,
            initialWitnessEvidence: earlierSource
        )
        let selection = try CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        )

        XCTAssertEqual(
            request.initialWitnessEvidence?.sourceFingerprintHash,
            earlierSource.sourceFingerprintHash
        )
        XCTAssertEqual(selection.sourceProfile, .v1534DesktopV34)
        XCTAssertNotEqual(
            earlierSource.sourceFingerprintHash,
            fingerprint
        )
    }

    private func makeCoordinator(
        catalogIDs: [String],
        active: [String],
        archived: [String],
        pinned: Set<String>,
        descendants: [CodexGhostRepairExperimentalDescendantNode]
    ) -> CodexGhostRepairInitialWitnessDiscoveryCoordinator {
        CodexGhostRepairInitialWitnessDiscoveryCoordinator(
            catalogReader: InitialWitnessCatalogFake(
                result: makeCatalog(ids: catalogIDs)
            ),
            officialTransport: InitialWitnessTransportFake(
                inventoryValue: makeOfficialInventory(
                    active: active,
                    archived: archived,
                    pinned: pinned,
                    descendants: descendants
                )
            )
        )
    }

    private func makeReview(
        ids: [String]
    ) -> CodexGhostRepairReadOnlyReview {
        let evidence = ids.map {
            CodexGhostRepairSnapshotProtectionEvidence(
                threadID: $0,
                inventoryComplete: true,
                activeInventoryPresent: false,
                archivedInventoryPresent: false,
                pinned: false,
                descendantCount: 0
            )
        }
        return CodexGhostRepairReadOnlyReview(
            targetThreadIDs: ids,
            runtimeVersion: "0.153.4",
            inventoryHash: "inventory-hash",
            observedAt: Date(timeIntervalSince1970: 1),
            protectionEvidence: [],
            snapshotProtectionEvidence: evidence,
            exactReadbacks: [],
            executionGate: CodexGhostRepairExecutionGate(
                codexFullyExited: true,
                desktopOpenHandleCount: 0,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                stateOpenHandleCount: 0,
                threadHistoryOpenHandleCount: 0,
                capacitySufficient: true
            )
        )
    }

    private func makeCatalog(
        ids: [String],
        layout: String? = nil,
        fingerprint: String? = nil,
        desktopSchema: Int32 = 34
    ) -> CodexGhostRepairInitialWitnessCatalogReadback {
        CodexGhostRepairInitialWitnessCatalogReadback(
            sourceLayoutIdentifier: layout ?? sourceLayout,
            sourceFingerprintHash: fingerprint ?? self.fingerprint,
            databases: [
                .init(
                    database: .desktop,
                    schemaVersion: desktopSchema,
                    integrityCheckPassed: true,
                    foreignKeyViolationCount: 0
                ),
                .init(
                    database: .summaries,
                    schemaVersion: 2,
                    integrityCheckPassed: true,
                    foreignKeyViolationCount: 0
                ),
                .init(
                    database: .state,
                    schemaVersion: 0,
                    integrityCheckPassed: true,
                    foreignKeyViolationCount: 0
                ),
                .init(
                    database: .threadHistory,
                    schemaVersion: 0,
                    integrityCheckPassed: true,
                    foreignKeyViolationCount: 0
                ),
            ],
            threadIDs: ids
        )
    }

    private func makeOfficialInventory(
        active: [String],
        archived: [String],
        pinned: Set<String>,
        descendants: [CodexGhostRepairExperimentalDescendantNode],
        runtimeVersion: String = "0.153.4",
        inventoryComplete: Bool = true,
        synthesizeAllSourceNodes: Bool = true
    ) -> CodexGhostRepairExperimentalTransportInventory {
        var allSource = descendants
        if synthesizeAllSourceNodes {
            var seen = Set(allSource.map(\.threadID))
            for threadID in active + archived
            where seen.insert(threadID).inserted {
                allSource.append(.init(
                    threadID: threadID,
                    parentThreadID: nil
                ))
            }
        }
        return .init(
            provider: .codex,
            runtimeVersion: runtimeVersion,
            inventoryComplete: inventoryComplete,
            activeThreadIDs: active,
            archivedThreadIDs: archived,
            pinnedThreadIDs: pinned,
            pinnedInventoryComplete: true,
            descendantNodes: allSource,
            descendantGraphComplete: true
        )
    }

    private func id(_ value: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", value)
    }
}

private struct InitialWitnessCatalogFake:
    CodexGhostRepairInitialWitnessCatalogReading
{
    let result: CodexGhostRepairInitialWitnessCatalogReadback

    func read(
        profile _: CodexGhostRepairSnapshotSourceProfile
    ) throws -> CodexGhostRepairInitialWitnessCatalogReadback {
        result
    }
}

private final class InitialWitnessCatalogSpy:
    CodexGhostRepairInitialWitnessCatalogReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: CodexGhostRepairInitialWitnessCatalogReadback
    private var count = 0

    init(result: CodexGhostRepairInitialWitnessCatalogReadback) {
        self.result = result
    }

    var readCount: Int {
        lock.withLock { count }
    }

    func read(
        profile _: CodexGhostRepairSnapshotSourceProfile
    ) throws -> CodexGhostRepairInitialWitnessCatalogReadback {
        lock.withLock { count += 1 }
        return result
    }
}

private actor InitialWitnessTransportFake:
    CodexGhostRepairBulkOfficialObservationTransport
{
    let inventoryValue: CodexGhostRepairExperimentalTransportInventory

    init(inventoryValue: CodexGhostRepairExperimentalTransportInventory) {
        self.inventoryValue = inventoryValue
    }

    func inventory() async throws
        -> CodexGhostRepairExperimentalTransportInventory
    {
        inventoryValue
    }

    func exactRead(
        threadID _: String
    ) async throws -> CodexGhostRepairExperimentalTransportExactReadOutcome {
        throw TestError.unexpectedExactRead
    }
}

private actor SuspendingInitialWitnessTransport:
    CodexGhostRepairBulkOfficialObservationTransport
{
    private var continuation:
        CheckedContinuation<CodexGhostRepairExperimentalTransportInventory, Never>?
    private var requests = 0

    func inventory() async throws
        -> CodexGhostRepairExperimentalTransportInventory
    {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func exactRead(
        threadID _: String
    ) async throws -> CodexGhostRepairExperimentalTransportExactReadOutcome {
        throw TestError.unexpectedExactRead
    }

    func waitUntilRequested() async {
        while continuation == nil { await Task.yield() }
    }

    func finish(
        with value: CodexGhostRepairExperimentalTransportInventory
    ) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func requestCount() -> Int { requests }
}

private enum TestError: Error {
    case unexpectedExactRead
}
