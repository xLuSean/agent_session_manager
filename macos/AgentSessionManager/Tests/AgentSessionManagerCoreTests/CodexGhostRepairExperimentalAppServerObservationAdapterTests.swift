@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairExperimentalAppServerObservationAdapterTests:
    XCTestCase
{
    private let target = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let present = "019f6500-1111-7222-8333-444444444444"
    private let archived = "019f6502-1111-7222-8333-444444444444"
    private let child = "019f6501-1111-7222-8333-444444444444"

    func testConstructionPerformsNoInventoryExactReadOrGateIO() async {
        let source = FakeExperimentalAppServerSource(
            snapshot: makeSnapshot(),
            exactResults: [:]
        )
        let gate = RecordingExperimentalGateSource(gate: clearGate())

        _ = CodexGhostRepairExperimentalAppServerObservationAdapter(
            source: source,
            executionGateSource: gate
        )

        let inventoryCalls = await source.inventoryCallCount
        let exactReads = await source.exactReadThreadIDs
        let gateCalls = await gate.callCount
        XCTAssertEqual(inventoryCalls, 0)
        XCTAssertEqual(exactReads, [])
        XCTAssertEqual(gateCalls, 0)
    }

    func testInventoryMapsExactRuntimeListsPinsAndDescendantGraph()
        async throws
    {
        let source = FakeExperimentalAppServerSource(
            snapshot: makeSnapshot(
                active: [makeRecord(id: present, isPinned: false)],
                archived: [makeRecord(id: archived, isPinned: false)],
                descendants: [
                    makeRecord(
                        id: child,
                        parentThreadID: target,
                        isPinned: true
                    ),
                ],
                pinned: [child]
            ),
            exactResults: [:]
        )
        let adapter = makeAdapter(source: source)

        let inventory = try await adapter.inventory()

        XCTAssertEqual(inventory.provider, .codex)
        XCTAssertEqual(inventory.runtimeVersion, "0.149.0")
        XCTAssertTrue(inventory.inventoryComplete)
        XCTAssertEqual(inventory.activeThreadIDs, [present])
        XCTAssertEqual(inventory.archivedThreadIDs, [archived])
        XCTAssertEqual(inventory.pinnedThreadIDs, [child])
        XCTAssertTrue(inventory.pinnedInventoryComplete)
        XCTAssertEqual(
            inventory.descendantNodes,
            [.init(threadID: child, parentThreadID: target)]
        )
        XCTAssertTrue(inventory.descendantGraphComplete)
        let inventoryCalls = await source.inventoryCallCount
        let exactReads = await source.exactReadThreadIDs
        XCTAssertEqual(inventoryCalls, 1)
        XCTAssertEqual(exactReads, [])
    }

    func testTruncationMissingRuntimeAndPinConflictRemainIncomplete()
        async throws
    {
        let conflicting = makeRecord(id: present, isPinned: true)
        let source = FakeExperimentalAppServerSource(
            snapshot: makeSnapshot(
                runtimeVersion: nil,
                active: [conflicting],
                truncated: true,
                pinned: []
            ),
            exactResults: [:]
        )

        let inventory = try await makeAdapter(source: source).inventory()

        XCTAssertEqual(inventory.runtimeVersion, "")
        XCTAssertFalse(inventory.inventoryComplete)
        XCTAssertFalse(inventory.pinnedInventoryComplete)
    }

    func testExactReadSuccessReturnsOnlyExactNativeIdentity() async throws {
        let source = FakeExperimentalAppServerSource(
            snapshot: makeSnapshot(),
            exactResults: [
                present: .present(makeRecord(id: present)),
            ]
        )

        let outcome = try await makeAdapter(source: source).exactRead(
            threadID: present
        )

        guard case let .present(returnedID) = outcome else {
            return XCTFail("Expected exact present result")
        }
        XCTAssertEqual(returnedID, present)
        let exactReads = await source.exactReadThreadIDs
        XCTAssertEqual(exactReads, [present])
    }

    func testRPCFailurePreservesExactCodeShapeAndRawMessage() async throws {
        let message = "thread not loaded: \(target)"
        let source = FakeExperimentalAppServerSource(
            snapshot: makeSnapshot(),
            exactResults: [target: .rpcError(-32600, message)]
        )

        let outcome = try await makeAdapter(source: source).exactRead(
            threadID: target
        )

        guard case let .failure(
            errorKind,
            code,
            shape,
            returnedMessage
        ) = outcome else {
            return XCTFail("Expected typed RPC failure")
        }
        XCTAssertEqual(errorKind, .rpcError)
        XCTAssertEqual(code, -32600)
        XCTAssertEqual(shape, "rpc-error-code-message-v1")
        XCTAssertEqual(returnedMessage, message)
    }

    func testNonRPCFailureStaysUnavailableAndDoesNotReachGate()
        async throws
    {
        let source = FakeExperimentalAppServerSource(
            snapshot: makeSnapshot(active: [makeRecord(id: present)]),
            exactResults: [present: .timeout]
        )
        let gate = RecordingExperimentalGateSource(gate: clearGate())
        let adapter =
            CodexGhostRepairExperimentalAppServerObservationAdapter(
                source: source,
                executionGateSource: gate
            )
        let coordinator =
            CodexGhostRepairExperimentalObservationCandidateCoordinator(
                transport: adapter
            )
        let requestID = UUID()

        let outcome = await coordinator.observe(request: .init(
            requestID: requestID,
            identity: try makeIdentity()
        ))

        guard case let .unavailable(returnedID, failure) = outcome else {
            return XCTFail("Expected path-redacted Unavailable")
        }
        XCTAssertEqual(returnedID, requestID)
        XCTAssertEqual(failure.stage, .presentControlRead)
        XCTAssertEqual(failure.reason, .presentControlReadFailed)
        XCTAssertTrue(failure.pathRedacted)
        XCTAssertFalse(failure.rawErrorIncluded)
        let gateCalls = await gate.callCount
        let exactReads = await source.exactReadThreadIDs
        XCTAssertEqual(gateCalls, 0)
        XCTAssertEqual(exactReads, [present])
    }

    func testFakeAppServerAdapterComposesThroughM2hObservation()
        async throws
    {
        let source = FakeExperimentalAppServerSource(
            snapshot: makeSnapshot(active: [makeRecord(id: present)]),
            exactResults: [
                present: .present(makeRecord(id: present)),
                target: .rpcError(
                    -32600,
                    "thread not loaded: \(target)"
                ),
            ]
        )
        let gate = RecordingExperimentalGateSource(gate: clearGate())
        let coordinator =
            CodexGhostRepairExperimentalObservationCandidateCoordinator(
                transport:
                    CodexGhostRepairExperimentalAppServerObservationAdapter(
                        source: source,
                        executionGateSource: gate
                    )
            )
        let identity = try makeIdentity()

        let outcome = await coordinator.observe(request: .init(
            requestID: UUID(),
            identity: identity
        ))

        guard case let .observed(result) = outcome else {
            return XCTFail("Expected M2h observation")
        }
        XCTAssertEqual(result.identity, identity)
        XCTAssertEqual(result.observation.runtimeVersion, "0.149.0")
        XCTAssertEqual(result.observation.activeThreadIDs, [present])
        XCTAssertEqual(
            result.observation.exactReadFailures.map(\.threadID),
            [target]
        )
        XCTAssertEqual(
            result.observation.exactReadFailures[0].message,
            "thread not loaded: \(target)"
        )
        XCTAssertTrue(result.observation.operationalAudit.isClear)
        let inventoryCalls = await source.inventoryCallCount
        let exactReads = await source.exactReadThreadIDs
        let gateCalls = await gate.callCount
        XCTAssertEqual(inventoryCalls, 1)
        XCTAssertEqual(
            exactReads,
            [present, target]
        )
        XCTAssertEqual(gateCalls, 1)
    }

    private func makeAdapter(
        source: FakeExperimentalAppServerSource
    ) -> CodexGhostRepairExperimentalAppServerObservationAdapter {
        .init(
            source: source,
            executionGateSource:
                RecordingExperimentalGateSource(gate: clearGate())
        )
    }

    private func makeSnapshot(
        runtimeVersion: String? = "0.149.0",
        active: [CodexThreadRecord] = [],
        archived: [CodexThreadRecord] = [],
        descendants: [CodexThreadRecord] = [],
        truncated: Bool = false,
        pinned: Set<String> = [],
        pinStateAvailable: Bool = true,
        descendantGraphComplete: Bool = true
    ) -> CodexInventorySnapshot {
        .init(
            serverInfo: .init(
                userAgent: "m2i-fake",
                codexHome: "/not-exposed/.codex",
                platformFamily: "unix",
                platformOs: "macos"
            ),
            runtimeVersion: runtimeVersion,
            active: active,
            archived: archived,
            descendantRecords: descendants,
            descendantNativeStates: Dictionary(
                uniqueKeysWithValues: descendants.map { ($0.id, .active) }
            ),
            descendantGraphComplete: descendantGraphComplete,
            descendantGraphError:
                descendantGraphComplete ? nil : "incomplete",
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000),
            isTruncated: truncated,
            projects: [],
            projectCatalogAvailable: true,
            projectCatalogError: nil,
            desktopPinnedThreadIDs: pinned,
            desktopPinStateAvailable: pinStateAvailable,
            desktopPinStateError: pinStateAvailable ? nil : "unavailable",
            trustFolders: [:],
            trustConfigurationAvailable: true,
            trustConfigurationError: nil
        )
    }

    private func makeRecord(
        id: String,
        parentThreadID: String? = nil,
        isPinned: Bool? = nil
    ) -> CodexThreadRecord {
        .init(
            id: id,
            sessionId: id,
            parentThreadId: parentThreadID,
            preview: "private preview is never mapped",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_800_000_000,
            updatedAt: 1_800_000_001,
            status: .init(type: "notLoaded", activeFlags: nil),
            cwd: "/private/project/path",
            cliVersion: "0.149.0",
            name: "private title is never mapped",
            isPinned: isPinned,
            gitInfo: nil
        )
    }

    private func makeIdentity()
        throws -> CodexGhostRepairSnapshotAnalysisIdentity
    {
        try .init(
            snapshotID: UUID(
                uuidString: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
            )!,
            targetThreadIDs: [target],
            preparedAtMilliseconds: 100,
            publishedAtMilliseconds: 200,
            sourceFingerprintHash: digest("1"),
            destinationBindingHash: digest("2"),
            acquisitionRecordHash: digest("3"),
            manifestHash: digest("4"),
            publicationReceiptHash: digest("5"),
            observedRegularFileCount: 10,
            actualPublishedBytes: 1_000
        )
    }

    private func clearGate() -> CodexGhostRepairExecutionGate {
        .init(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            stateOpenHandleCount: 0,
            threadHistoryOpenHandleCount: 0,
            capacitySufficient: true
        )
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}

private actor FakeExperimentalAppServerSource: CodexInventorySource {
    enum ExactResult: Sendable {
        case present(CodexThreadRecord)
        case rpcError(Int, String)
        case timeout
    }

    let snapshot: CodexInventorySnapshot
    let exactResults: [String: ExactResult]
    private(set) var inventoryCallCount = 0
    private(set) var exactReadThreadIDs: [String] = []

    init(
        snapshot: CodexInventorySnapshot,
        exactResults: [String: ExactResult]
    ) {
        self.snapshot = snapshot
        self.exactResults = exactResults
    }

    func inventory() async throws -> CodexInventorySnapshot {
        inventoryCallCount += 1
        return snapshot
    }

    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot {
        exactReadThreadIDs.append(threadID)
        guard let result = exactResults[threadID] else {
            throw CodexAppServerError.exactReadUnavailable
        }
        switch result {
        case let .present(record):
            return .init(
                serverInfo: snapshot.serverInfo,
                runtimeVersion: snapshot.runtimeVersion,
                thread: record,
                observedAt: Date(timeIntervalSince1970: 1_800_000_001)
            )
        case let .rpcError(code, message):
            throw CodexAppServerError.rpcError(code, message)
        case .timeout:
            throw CodexAppServerError.responseTimeout
        }
    }
}

private actor RecordingExperimentalGateSource:
    CodexGhostRepairExecutionGateSource
{
    let gate: CodexGhostRepairExecutionGate
    private(set) var callCount = 0

    init(gate: CodexGhostRepairExecutionGate) {
        self.gate = gate
    }

    func ghostRepairExecutionGate() async throws
        -> CodexGhostRepairExecutionGate
    {
        callCount += 1
        return gate
    }
}
