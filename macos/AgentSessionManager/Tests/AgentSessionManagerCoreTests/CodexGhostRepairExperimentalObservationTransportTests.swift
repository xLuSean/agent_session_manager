@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairExperimentalObservationTransportTests:
    XCTestCase
{
    private let targetA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let targetB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"
    private let present = "019f6500-1111-7222-8333-444444444444"

    func testPackagedFactoryIsUnavailableAndAuthorityFree() async throws {
        let coordinator =
            CodexGhostRepairExperimentalObservationCoordinatorFactory
                .packagedDefaultUnavailable()
        let capabilities = coordinator.capabilities
        XCTAssertEqual(capabilities, .unavailable)
        XCTAssertFalse(capabilities.acceptsCallerPath)
        XCTAssertFalse(capabilities.automaticRead)
        XCTAssertFalse(capabilities.automaticRetry)
        XCTAssertFalse(capabilities.writesFilesystem)
        XCTAssertFalse(capabilities.persistsEvidence)
        XCTAssertFalse(capabilities.officialLifecycleAuthority)
        XCTAssertFalse(capabilities.confirmationAuthority)
        XCTAssertFalse(capabilities.repairMutationAuthority)

        let requestID = UUID()
        let outcome = await coordinator.observe(request: .init(
            requestID: requestID,
            identity: try makeIdentity(targets: [targetA])
        ))
        guard case let .unavailable(returnedID, failure) = outcome else {
            return XCTFail("Expected packaged observation to be unavailable")
        }
        XCTAssertEqual(returnedID, requestID)
        XCTAssertEqual(failure.stage, .appServerInventory)
        XCTAssertEqual(failure.reason, .observationUnavailable)
    }

    func testExplicitObservationUsesOneExactOrderedReadSequence()
        async throws
    {
        let transport = makeTransport(targets: [targetA, targetB])
        let coordinator =
            CodexGhostRepairExperimentalObservationCandidateCoordinator(
                transport: transport
            )
        let callsBeforeObservation = await transport.recordedCalls()
        XCTAssertEqual(callsBeforeObservation, [])

        let requestID = UUID()
        let identity = try makeIdentity(targets: [targetA, targetB])
        let outcome = await coordinator.observe(request: .init(
            requestID: requestID,
            identity: identity
        ))

        guard case let .observed(result) = outcome else {
            return XCTFail("Expected deterministic observation")
        }
        XCTAssertEqual(result.requestID, requestID)
        XCTAssertEqual(result.identity, identity)
        XCTAssertEqual(
            result.observation.exactReadFailures.map(\.threadID),
            [targetA, targetB]
        )
        let calls = await transport.recordedCalls()
        XCTAssertEqual(
            calls,
            [
                .inventory,
                .exactRead(present),
                .exactRead(targetA),
                .exactRead(targetB),
                .operationalAudit,
            ]
        )
        XCTAssertFalse(coordinator.capabilities.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.automaticRead)
        XCTAssertFalse(coordinator.capabilities.automaticRetry)
    }

    func testObservedResultComposesWithM2gCollector() async throws {
        let identity = try makeIdentity(targets: [targetA])
        let coordinator =
            CodexGhostRepairExperimentalObservationCandidateCoordinator(
                transport: makeTransport(targets: [targetA])
            )
        let outcome = await coordinator.observe(request: .init(
            requestID: UUID(),
            identity: identity
        ))
        guard case let .observed(result) = outcome else {
            return XCTFail("Expected transport observation")
        }

        let audit = try CodexGhostRepairExperimentalProtectionCollector.collect(
            identity: result.identity,
            snapshotEvidence: makeReadback(identity: identity),
            registry: makeRegistry(),
            observation: result.observation
        )
        XCTAssertEqual(audit.identity, identity)
        XCTAssertEqual(
            audit.experimentalAbsenceEvidence.map(\.requestedThreadID),
            [targetA]
        )
        XCTAssertTrue(audit.protectionEvidence[0].isEligible)
    }

    func testIncompleteInventoryShortCircuitsBeforeExactReads() async throws {
        let transport = FakeExperimentalObservationTransport(
            inventory: makeInventory(inventoryComplete: false),
            reads: [:],
            gate: clearGate()
        )
        let outcome = await candidate(transport).observe(request: .init(
            requestID: UUID(),
            identity: try makeIdentity(targets: [targetA])
        ))
        assertUnavailable(
            outcome,
            stage: .inventoryValidation,
            reason: .inventoryIncomplete
        )
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls, [.inventory])
    }

    func testPresentControlMismatchShortCircuitsBeforeTargetReads()
        async throws
    {
        let transport = FakeExperimentalObservationTransport(
            inventory: makeInventory(),
            reads: [
                present: .present(returnedThreadID: targetA),
            ],
            gate: clearGate()
        )
        let outcome = await candidate(transport).observe(request: .init(
            requestID: UUID(),
            identity: try makeIdentity(targets: [targetA])
        ))
        assertUnavailable(
            outcome,
            stage: .presentControlRead,
            reason: .presentControlMismatch
        )
        let calls = await transport.recordedCalls()
        XCTAssertEqual(
            calls,
            [.inventory, .exactRead(present)]
        )
    }

    func testTargetPresentShortCircuitsBeforeOperationalAudit() async throws {
        let transport = FakeExperimentalObservationTransport(
            inventory: makeInventory(),
            reads: [
                present: .present(returnedThreadID: present),
                targetA: .present(returnedThreadID: targetA),
            ],
            gate: clearGate()
        )
        let outcome = await candidate(transport).observe(request: .init(
            requestID: UUID(),
            identity: try makeIdentity(targets: [targetA])
        ))
        assertUnavailable(
            outcome,
            stage: .targetExactRead,
            reason: .targetUnexpectedlyPresent
        )
        let calls = await transport.recordedCalls()
        XCTAssertEqual(
            calls,
            [.inventory, .exactRead(present), .exactRead(targetA)]
        )
    }

    func testNoFreshPresentControlStopsAfterInventory() async throws {
        let transport = FakeExperimentalObservationTransport(
            inventory: makeInventory(activeThreadIDs: []),
            reads: [:],
            gate: clearGate()
        )
        let outcome = await candidate(transport).observe(request: .init(
            requestID: UUID(),
            identity: try makeIdentity(targets: [targetA])
        ))
        assertUnavailable(
            outcome,
            stage: .inventoryValidation,
            reason: .noPresentControl
        )
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls, [.inventory])
    }

    func testPresentControlIsSelectedDeterministicallyFromFreshInventory()
        async throws
    {
        let later = "019f6600-1111-7222-8333-444444444444"
        let transport = FakeExperimentalObservationTransport(
            inventory: makeInventory(
                activeThreadIDs: [later, present]
            ),
            reads: [
                present: .present(returnedThreadID: present),
                targetA: .failure(
                    errorKind: .rpcError,
                    rpcCode: -32600,
                    responseShapeIdentifier: "rpc-error-code-message-v1",
                    message: "thread not loaded: \(targetA)"
                ),
            ],
            gate: clearGate()
        )

        let outcome = await candidate(transport).observe(request: .init(
            requestID: UUID(),
            identity: try makeIdentity(targets: [targetA])
        ))

        guard case let .observed(result) = outcome else {
            return XCTFail("Expected deterministic control selection")
        }
        XCTAssertEqual(result.observation.presentControlThreadID, present)
        let calls = await transport.recordedCalls()
        XCTAssertEqual(
            calls,
            [
                .inventory,
                .exactRead(present),
                .exactRead(targetA),
                .operationalAudit,
            ]
        )
    }

    func testTransportFailureIsPathRedactedAndKeepsRequestIdentity()
        async throws
    {
        let transport = FakeExperimentalObservationTransport(
            inventory: makeInventory(),
            reads: [:],
            gate: clearGate()
        )
        let requestID = UUID()
        let outcome = await candidate(transport).observe(request: .init(
            requestID: requestID,
            identity: try makeIdentity(targets: [targetA])
        ))
        guard case let .unavailable(returnedID, failure) = outcome else {
            return XCTFail("Expected stable Unavailable")
        }
        XCTAssertEqual(returnedID, requestID)
        XCTAssertEqual(failure.stage, .presentControlRead)
        XCTAssertEqual(failure.reason, .presentControlReadFailed)
        XCTAssertTrue(failure.pathRedacted)
        XCTAssertFalse(failure.rawErrorIncluded)
        XCTAssertFalse(failure.automaticRetry)
    }

    func testOperationalAuditFailureIsTypedAndStopsAtFinalRead()
        async throws
    {
        let transport = makeTransport(
            targets: [targetA],
            failOperationalAudit: true
        )
        let outcome = await candidate(transport).observe(request: .init(
            requestID: UUID(),
            identity: try makeIdentity(targets: [targetA])
        ))
        assertUnavailable(
            outcome,
            stage: .operationalAudit,
            reason: .operationalAuditFailed
        )
        let calls = await transport.recordedCalls()
        XCTAssertEqual(
            calls,
            [
                .inventory,
                .exactRead(present),
                .exactRead(targetA),
                .operationalAudit,
            ]
        )
    }

    func testSeparateRequestsNeverExchangeLateResultIdentity() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = await candidate(
            makeTransport(targets: [targetA])
        ).observe(request: .init(
            requestID: firstID,
            identity: try makeIdentity(targets: [targetA])
        ))
        let second = await candidate(
            makeTransport(targets: [targetB])
        ).observe(request: .init(
            requestID: secondID,
            identity: try makeIdentity(targets: [targetB])
        ))
        XCTAssertEqual(first.requestID, firstID)
        XCTAssertEqual(second.requestID, secondID)
    }

    private func candidate(
        _ transport: FakeExperimentalObservationTransport
    ) -> CodexGhostRepairExperimentalObservationCandidateCoordinator {
        .init(transport: transport)
    }

    private func makeTransport(
        targets: [String],
        failOperationalAudit: Bool = false
    ) -> FakeExperimentalObservationTransport {
        var reads: [String:
            CodexGhostRepairExperimentalTransportExactReadOutcome] = [
                present: .present(returnedThreadID: present),
            ]
        for target in targets {
            reads[target] = .failure(
                errorKind: .rpcError,
                rpcCode: -32600,
                responseShapeIdentifier: "rpc-error-code-message-v1",
                message: "thread not loaded: \(target)"
            )
        }
        return .init(
            inventory: makeInventory(),
            reads: reads,
            gate: clearGate(),
            failOperationalAudit: failOperationalAudit
        )
    }

    private func makeInventory(
        inventoryComplete: Bool = true,
        activeThreadIDs: [String]? = nil
    ) -> CodexGhostRepairExperimentalTransportInventory {
        .init(
            provider: .codex,
            runtimeVersion: "0.149.0",
            inventoryComplete: inventoryComplete,
            activeThreadIDs: activeThreadIDs ?? [present],
            archivedThreadIDs: [],
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            descendantNodes: [],
            descendantGraphComplete: true
        )
    }

    private func makeIdentity(
        targets: [String]
    ) throws -> CodexGhostRepairSnapshotAnalysisIdentity {
        try .init(
            snapshotID: UUID(
                uuidString: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
            )!,
            targetThreadIDs: targets,
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

    private func makeReadback(
        identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) -> CodexGhostRepairSnapshotAnalysisReadback {
        .init(
            identity: identity,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: makeDatabaseContracts().map {
                .init(
                    database: $0.database,
                    schemaVersion: $0.schemaVersion,
                    integrityCheckPassed: true,
                    foreignKeyViolationCount: 0
                )
            },
            targets: identity.targetThreadIDs.map {
                .init(
                    threadID: $0,
                    catalogRowDigests: [digest("a")],
                    automationRunRowDigests: [],
                    automationDefinitionRowDigests: [],
                    references: .init(
                        inbox: 0,
                        timeline: 0,
                        summaries: 0,
                        canonicalState: 0,
                        threadTurns: 0,
                        threadItems: 0,
                        historyProjection: 0
                    ),
                    rowContract: .categoryAEligible
                )
            },
            authority: .init(
                catalogRevision: 1,
                observationSequence: 2,
                watermarkUpdatedAt: 3,
                metadataRowDigest: digest("b"),
                localSyncRowDigest: digest("c")
            )
        )
    }

    private func makeRegistry()
        throws -> CodexGhostRepairExperimentalAbsenceRegistry
    {
        let contract = try CodexGhostRepairExperimentalAbsenceContract(
            identifier: "codex-ghost-repair-experimental-absence",
            version: 1,
            provider: .codex,
            runtimeVersion: "0.149.0",
            method: .threadRead,
            errorKind: .rpcError,
            rpcCode: -32600,
            responseShapeIdentifier: "rpc-error-code-message-v1",
            exactMessageTemplate: "thread not loaded: {thread_id}",
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: makeDatabaseContracts()
        )
        return try .init(admissions: [
            .init(
                contract: contract,
                compatibilityFixtureHash: digest("6"),
                packagedCanaryEvidenceHash: digest("7"),
                presentControlThreadIDHash: digest("8"),
                missingFixtureThreadIDHashes: [digest("9")],
                presentControlVerified: true,
                missingFixtureVerified: true
            ),
        ])
    }

    private func makeDatabaseContracts()
        -> [CodexGhostRepairExperimentalDatabaseContract]
    {
        [
            .init(database: .desktop, schemaVersion: 32),
            .init(database: .summaries, schemaVersion: 2),
            .init(database: .state, schemaVersion: 0),
            .init(database: .threadHistory, schemaVersion: 0),
        ]
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

    private func assertUnavailable(
        _ outcome: CodexGhostRepairExperimentalObservationOutcome,
        stage: CodexGhostRepairExperimentalCompatibilityFailureStage? = nil,
        reason: CodexGhostRepairExperimentalCompatibilityFailureReason? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(_, failure) = outcome else {
            return XCTFail("Expected Unavailable", file: file, line: line)
        }
        if let stage {
            XCTAssertEqual(failure.stage, stage, file: file, line: line)
        }
        if let reason {
            XCTAssertEqual(failure.reason, reason, file: file, line: line)
        }
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}

private actor FakeExperimentalObservationTransport:
    CodexGhostRepairExperimentalObservationTransport
{
    enum Call: Equatable {
        case inventory
        case exactRead(String)
        case operationalAudit
    }

    enum Failure: Error {
        case missingRead
        case operationalAudit
    }

    private let inventoryValue:
        CodexGhostRepairExperimentalTransportInventory
    private let reads:
        [String: CodexGhostRepairExperimentalTransportExactReadOutcome]
    private let gate: CodexGhostRepairExecutionGate
    private let failOperationalAudit: Bool
    private var calls: [Call] = []

    init(
        inventory: CodexGhostRepairExperimentalTransportInventory,
        reads:
            [String: CodexGhostRepairExperimentalTransportExactReadOutcome],
        gate: CodexGhostRepairExecutionGate,
        failOperationalAudit: Bool = false
    ) {
        inventoryValue = inventory
        self.reads = reads
        self.gate = gate
        self.failOperationalAudit = failOperationalAudit
    }

    func inventory() async throws
        -> CodexGhostRepairExperimentalTransportInventory
    {
        calls.append(.inventory)
        return inventoryValue
    }

    func exactRead(
        threadID: String
    ) async throws -> CodexGhostRepairExperimentalTransportExactReadOutcome {
        calls.append(.exactRead(threadID))
        guard let result = reads[threadID] else {
            throw Failure.missingRead
        }
        return result
    }

    func operationalAudit() async throws -> CodexGhostRepairExecutionGate {
        calls.append(.operationalAudit)
        if failOperationalAudit {
            throw Failure.operationalAudit
        }
        return gate
    }

    func recordedCalls() -> [Call] {
        calls
    }
}
