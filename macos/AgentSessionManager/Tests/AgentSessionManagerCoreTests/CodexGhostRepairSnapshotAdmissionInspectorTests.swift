@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairSnapshotAdmissionInspectorTests: XCTestCase {
    func testPackagedInspectorExposesOnlyReadOnlyAdmissionCapability() {
        let inspector =
            CodexGhostRepairSnapshotAdmissionInspectorFactory
                .packagedExplicitReadOnly()

        XCTAssertEqual(inspector.capabilities, .packagedFixedReadOnly)
        XCTAssertTrue(inspector.capabilities.inspectionAvailable)
        XCTAssertTrue(inspector.capabilities.readsFixedRawDatabaseFiles)
        XCTAssertFalse(inspector.capabilities.acceptsCallerPath)
        XCTAssertFalse(inspector.capabilities.usesSQLiteAPI)
        XCTAssertFalse(inspector.capabilities.writesManagerFilesystem)
        XCTAssertFalse(inspector.capabilities.snapshotAcquisitionAuthority)
        XCTAssertFalse(inspector.capabilities.repairMutationAuthority)
    }

    func testUnavailableInspectorPerformsNoBackendWork() async throws {
        let backend = SnapshotAdmissionBackendSpy()
        let inspector = CodexGhostRepairSnapshotPackagedAdmissionInspector(
            backend: backend,
            inspectionAvailable: false
        )

        let outcome = await inspector.inspect(request: try makeRequest())

        guard case .unavailable = outcome else {
            return XCTFail("Unavailable inspector must stop before backend")
        }
        let requestCount = await backend.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testUnknownRuntimeStopsBeforeBackend() async throws {
        let backend = SnapshotAdmissionBackendSpy()
        let inspector = CodexGhostRepairSnapshotPackagedAdmissionInspector(
            backend: backend,
            inspectionAvailable: true
        )

        let outcome = await inspector.inspect(
            request: try makeRequest(runtimeVersion: "0.150.0")
        )

        guard case .unavailable = outcome else {
            return XCTFail("Unknown runtime must fail closed")
        }
        let requestCount = await backend.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testExactRequestSelectsProfileAndReturnsEvidenceOnce() async throws {
        let expected = admissionEvidence()
        let backend = SnapshotAdmissionBackendSpy(
            outcome: .allowed(expected)
        )
        let inspector = CodexGhostRepairSnapshotPackagedAdmissionInspector(
            backend: backend,
            inspectionAvailable: true
        )
        let request = try makeRequest(runtimeVersion: "0.151.0-alpha.7.2")

        let outcome = await inspector.inspect(request: request)

        XCTAssertEqual(outcome, .allowed(expected))
        let selections = await backend.selections
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections[0].request, request)
        XCTAssertEqual(selections[0].sourceProfile, .v151DesktopV33)
    }

    private func makeRequest(
        runtimeVersion: String = "codex-cli 0.149.0"
    ) throws -> CodexGhostRepairSnapshotActionRequest {
        let threadID = "thread-a"
        return try CodexGhostRepairSnapshotActionRequest(
            review: CodexGhostRepairReadOnlyReview(
                targetThreadIDs: [threadID],
                runtimeVersion: runtimeVersion,
                inventoryHash: "inventory-hash",
                observedAt: Date(timeIntervalSince1970: 1),
                protectionEvidence: [],
                snapshotProtectionEvidence: [
                    CodexGhostRepairSnapshotProtectionEvidence(
                        threadID: threadID,
                        inventoryComplete: true,
                        activeInventoryPresent: false,
                        archivedInventoryPresent: false,
                        pinned: false,
                        descendantCount: 0
                    ),
                ],
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

    private func admissionEvidence()
        -> CodexGhostRepairSnapshotAdmissionEvidence
    {
        CodexGhostRepairSnapshotAdmissionEvidence(
            publishedSnapshotCount: 0,
            maximumSnapshotCount: 3,
            publishedBytes: 0,
            maximumTotalBytes: 4_294_967_296,
            prospectiveSnapshotBytes: 1,
            oldestPublishedAgeMilliseconds: nil,
            maximumPublishedAgeMilliseconds: 2_592_000_000,
            destinationRequiredBytes: 1,
            destinationAvailableBytes: 2,
            blockers: []
        )
    }
}

private actor SnapshotAdmissionBackendSpy:
    CodexGhostRepairSnapshotAdmissionInspectingBackend
{
    private(set) var selections:
        [CodexGhostRepairSnapshotRequestBoundProfileSelection] = []
    private let outcome: CodexGhostRepairSnapshotAdmissionOutcome

    init(
        outcome: CodexGhostRepairSnapshotAdmissionOutcome = .unavailable(
            message: "unused"
        )
    ) {
        self.outcome = outcome
    }

    func inspect(
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        selections.append(selection)
        return outcome
    }

    func requestCount() -> Int { selections.count }
}
