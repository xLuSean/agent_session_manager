@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairSnapshotActionCoordinatorTests: XCTestCase {
    func testPackagedFactoryDisclosesFixedEffectButCannotCallPublisher()
        async throws
    {
        let coordinator =
            CodexGhostRepairSnapshotActionCoordinatorFactory
                .packagedDefaultBlocked()

        XCTAssertEqual(
            coordinator.capabilities,
            .packagedFixedManagerSnapshotBlocked
        )
        XCTAssertFalse(coordinator.capabilities.acquisitionAvailable)
        XCTAssertTrue(coordinator.capabilities.effect.readsCodexDatabaseFiles)
        XCTAssertFalse(coordinator.capabilities.effect.writesCodexDatabaseFiles)
        XCTAssertFalse(coordinator.capabilities.effect.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.repairMutationAuthority)

        let outcome = await coordinator.perform(request: try makeRequest())
        XCTAssertEqual(
            outcome,
            .unavailable(
                message: "Packaged raw database snapshot acquisition is assembled but live use is not authorized."
            )
        )
    }

    func testExplicitPackagedFactoryEnablesOnlyFixedSnapshotEffect() {
        let coordinator =
            CodexGhostRepairSnapshotActionCoordinatorFactory
                .packagedExplicitAction()

        XCTAssertEqual(
            coordinator.capabilities,
            .fixedManagerRawDatabaseSnapshot
        )
        XCTAssertTrue(coordinator.capabilities.acquisitionAvailable)
        XCTAssertTrue(coordinator.capabilities.effect.readsCodexDatabaseFiles)
        XCTAssertFalse(coordinator.capabilities.effect.writesCodexDatabaseFiles)
        XCTAssertFalse(coordinator.capabilities.effect.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.repairMutationAuthority)
    }

    func testBlockedCoordinatorReturnsBeforeGeneratingOrPublishing() async throws {
        let publisher = SnapshotActionPublisherSpy(outcomes: [])
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: false
        )

        _ = await coordinator.perform(request: try makeRequest())

        let requests = await publisher.requests
        XCTAssertEqual(requests, [])
    }

    func testUnsupportedRuntimeStopsBeforeGeneratingOrPublishing() async throws {
        let publisher = SnapshotActionPublisherSpy(outcomes: [])
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )

        let outcome = await coordinator.perform(
            request: try makeRequest(runtimeVersion: "codex-cli 0.150.0")
        )

        XCTAssertEqual(
            outcome,
            .unavailable(
                message: "This snapshot build has no exact audited packaged profile for the observed Codex runtime."
            )
        )
        let requests = await publisher.requests
        XCTAssertEqual(requests, [])
    }

    func testEnabledTestCompositionPublishesExactIDsOnceAndReturnsReference()
        async throws
    {
        let publisher = SnapshotActionPublisherSpy(outcomes: [.requestedID])
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )
        let request = try makeRequest(ids: ["thread-a", "thread-b"])

        let outcome = await coordinator.perform(request: request)

        guard case let .succeeded(reference) = outcome else {
            return XCTFail("Expected one successful deterministic publication")
        }
        let requests = await publisher.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].selection.request, request)
        XCTAssertEqual(requests[0].selection.sourceProfile, .v149DesktopV32)
        XCTAssertEqual(reference, requests[0].snapshotID.uuidString.lowercased())
    }

    func testV151RequestSelectsExactTypedProfileAndPreservesWholeRequest()
        async throws
    {
        let publisher = SnapshotActionPublisherSpy(outcomes: [.requestedID])
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )
        let request = try makeRequest(
            ids: ["thread-a", "thread-b"],
            runtimeVersion: "0.151.0-alpha.7.2"
        )

        guard case .succeeded = await coordinator.perform(request: request) else {
            return XCTFail("Expected exact v0.151 request to be admitted")
        }

        let requests = await publisher.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].selection.request, request)
        XCTAssertEqual(requests[0].selection.sourceProfile, .v151DesktopV33)
    }

    func testV152RequestSelectsExactTypedV34ProfileAndPreservesWholeRequest()
        async throws
    {
        let publisher = SnapshotActionPublisherSpy(outcomes: [.requestedID])
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )
        let request = try makeRequest(
            ids: ["thread-a", "thread-b"],
            runtimeVersion: "0.152.1"
        )

        guard case .succeeded = await coordinator.perform(request: request) else {
            return XCTFail("Expected exact v0.152.1 request to be admitted")
        }

        let requests = await publisher.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].selection.request, request)
        XCTAssertEqual(requests[0].selection.sourceProfile, .v152DesktopV34)
        XCTAssertEqual(
            requests[0].selection.expectedSchemaProfileIdentifier,
            "desktop-v34"
        )
    }

    func testV153ProviderRequestSelectsDesktopOwnedV34Profile()
        async throws
    {
        let publisher = SnapshotActionPublisherSpy(outcomes: [.requestedID])
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )
        let request = try makeRequest(
            ids: ["thread-a", "thread-b"],
            runtimeVersion: "0.153.2"
        )

        guard case .succeeded = await coordinator.perform(request: request) else {
            return XCTFail("Expected exact v0.153.2 provider request to be admitted")
        }

        let requests = await publisher.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].selection.request, request)
        XCTAssertEqual(requests[0].selection.sourceProfile, .v153DesktopV34)
        XCTAssertEqual(
            requests[0].selection.expectedSchemaProfileIdentifier,
            "desktop-v34"
        )
    }

    func testV1534ProviderRequestSelectsIndependentDesktopOwnedV34Profile()
        async throws
    {
        let publisher = SnapshotActionPublisherSpy(outcomes: [.requestedID])
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )
        let request = try makeRequest(
            ids: ["thread-a", "thread-b"],
            runtimeVersion: "0.153.4"
        )

        guard case .succeeded = await coordinator.perform(request: request) else {
            return XCTFail("Expected exact v0.153.4 provider request to be admitted")
        }

        let requests = await publisher.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].selection.request, request)
        XCTAssertEqual(requests[0].selection.sourceProfile, .v1534DesktopV34)
        XCTAssertEqual(
            requests[0].selection.expectedSchemaProfileIdentifier,
            "desktop-v34"
        )
    }

    func testAdjacentV153RuntimeDoesNotSelectCurrentProfile() async throws {
        let publisher = SnapshotActionPublisherSpy(outcomes: [.requestedID])
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )
        let request = try makeRequest(
            ids: ["thread-a", "thread-b"],
            runtimeVersion: "0.153.3"
        )

        guard case .unavailable =
                await coordinator.perform(request: request) else {
            return XCTFail("Expected adjacent v0.153 runtime to remain blocked")
        }
        let requests = await publisher.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPublisherFailurePreservesReferenceForReadbackAndDoesNotRetry()
        async throws
    {
        let publisher = SnapshotActionPublisherSpy(outcomes: [.failure])
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )

        let outcome = await coordinator.perform(request: try makeRequest())

        guard case let .recoveryRequired(reference, message) = outcome else {
            return XCTFail("Unknown publisher phase must require readback")
        }
        let requests = await publisher.requests
        XCTAssertEqual(requests.count, 1)
        let expectedReference = requests[0].snapshotID.uuidString.lowercased()
        XCTAssertEqual(reference, expectedReference)
        XCTAssertTrue(message.contains(expectedReference))
        XCTAssertTrue(message.contains("do not retry"))
        XCTAssertFalse(message.contains("injected"))
    }

    func testDatabaseContractFailureReportsPathRedactedStoppedStage()
        async throws
    {
        let publisher = SnapshotActionPublisherSpy(
            outcomes: [.databaseContractFailure]
        )
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )

        let outcome = await coordinator.perform(request: try makeRequest())

        guard case let .recoveryRequired(_, message) = outcome else {
            return XCTFail("Schema failure must require exact readback")
        }
        XCTAssertTrue(
            message.contains("post-copy database schema verification")
        )
        XCTAssertFalse(message.contains("/Users/"))
        XCTAssertFalse(message.contains("rrule"))
        let requestCount = await publisher.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testKnownAdmissionBlockStopsBeforeSnapshotIdentityOrPublication()
        async throws
    {
        let evidence = SnapshotActionPublisherSpy.admissionEvidence(
            publishedCount: 3,
            maximumCount: 3,
            blockers: [.maximumSnapshotCountExceeded]
        )
        let publisher = SnapshotActionPublisherSpy(
            outcomes: [.requestedID],
            admissionOutcome: .blocked(
                evidence: evidence,
                message: evidence.userFacingBlockReason!
            )
        )
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )

        let outcome = await coordinator.perform(request: try makeRequest())

        XCTAssertEqual(
            outcome,
            .blocked(message: evidence.userFacingBlockReason!)
        )
        let requests = await publisher.requests
        let admissionRequestCount = await publisher.admissionRequestCount()
        XCTAssertEqual(requests, [])
        XCTAssertEqual(admissionRequestCount, 1)
    }

    func testMismatchedPublishedIDFailsClosedWithoutSecondPublication()
        async throws
    {
        let publisher = SnapshotActionPublisherSpy(
            outcomes: [.fixedID(UUID())]
        )
        let coordinator = CodexGhostRepairSnapshotPackagedCoordinator(
            publisher: publisher,
            acquisitionAvailable: true
        )

        let outcome = await coordinator.perform(request: try makeRequest())

        guard case .recoveryRequired = outcome else {
            return XCTFail("Mismatched publication identity must fail closed")
        }
        let requestCount = await publisher.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    private func makeRequest(
        ids: [String] = ["thread-a"],
        runtimeVersion: String = "codex-cli 0.149.0"
    ) throws -> CodexGhostRepairSnapshotActionRequest {
        let sorted = ids.sorted()
        let evidence = sorted.map {
            CodexGhostRepairSnapshotProtectionEvidence(
                threadID: $0,
                inventoryComplete: true,
                activeInventoryPresent: false,
                archivedInventoryPresent: false,
                pinned: false,
                descendantCount: 0
            )
        }
        return try CodexGhostRepairSnapshotActionRequest(
            review: CodexGhostRepairReadOnlyReview(
                targetThreadIDs: sorted,
                runtimeVersion: runtimeVersion,
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
                    capacitySufficient: true
                )
            )
        )
    }
}

private actor SnapshotActionPublisherSpy: CodexGhostRepairSnapshotPublishing {
    struct Request: Equatable {
        let snapshotID: UUID
        let selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    }

    enum Outcome {
        case requestedID
        case fixedID(UUID)
        case failure
        case databaseContractFailure
    }

    private(set) var requests: [Request] = []
    private var admissionRequests: [
        CodexGhostRepairSnapshotRequestBoundProfileSelection
    ] = []
    private var outcomes: [Outcome]
    private let admissionOutcome: CodexGhostRepairSnapshotAdmissionOutcome

    init(
        outcomes: [Outcome],
        admissionOutcome: CodexGhostRepairSnapshotAdmissionOutcome =
            .allowed(SnapshotActionPublisherSpy.admissionEvidence())
    ) {
        self.outcomes = outcomes
        self.admissionOutcome = admissionOutcome
    }

    func inspectAdmission(
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        admissionRequests.append(selection)
        return admissionOutcome
    }

    func publish(
        snapshotID: UUID,
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    ) async throws -> UUID {
        requests.append(Request(
            snapshotID: snapshotID,
            selection: selection
        ))
        guard !outcomes.isEmpty else { throw SnapshotActionTestError.injected }
        switch outcomes.removeFirst() {
        case .requestedID:
            return snapshotID
        case let .fixedID(value):
            return value
        case .failure:
            throw SnapshotActionTestError.injected
        case .databaseContractFailure:
            throw CodexGhostRepairError.invalidDatabaseContract(
                "private schema detail must not leave Core"
            )
        }
    }

    func admissionRequestCount() -> Int { admissionRequests.count }

    nonisolated static func admissionEvidence(
        publishedCount: Int = 0,
        maximumCount: Int = 3,
        blockers: [CodexGhostRepairSnapshotAdmissionBlocker] = []
    ) -> CodexGhostRepairSnapshotAdmissionEvidence {
        CodexGhostRepairSnapshotAdmissionEvidence(
            publishedSnapshotCount: publishedCount,
            maximumSnapshotCount: maximumCount,
            publishedBytes: 0,
            maximumTotalBytes: 4_294_967_296,
            prospectiveSnapshotBytes: 1,
            oldestPublishedAgeMilliseconds: nil,
            maximumPublishedAgeMilliseconds: 2_592_000_000,
            destinationRequiredBytes: 1,
            destinationAvailableBytes: 2,
            blockers: blockers
        )
    }
}

private enum SnapshotActionTestError: Error {
    case injected
}
