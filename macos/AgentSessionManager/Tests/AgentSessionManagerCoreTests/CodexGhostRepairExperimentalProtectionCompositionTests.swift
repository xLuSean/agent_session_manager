@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairExperimentalProtectionCompositionTests:
    XCTestCase
{
    private let target = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let present = "019f6500-1111-7222-8333-444444444444"
    private let child = "019f6501-1111-7222-8333-444444444444"

    func testExplicitObservationComposesThroughCollectorIntoM2ePreview()
        async throws
    {
        let identity = try makeIdentity()
        let readback = makeReadback(identity: identity)
        let transport = CompositionTransport(
            inventory: makeInventory(),
            reads: makeReads(),
            gate: clearGate()
        )
        let source = CodexGhostRepairExperimentalProtectionCompositionSource(
            observer:
                CodexGhostRepairExperimentalObservationCandidateCoordinator(
                    transport: transport
                ),
            registry: try makeRegistry()
        )
        let coordinator =
            CodexGhostRepairSnapshotDryRunAnalysisCandidateCoordinator(
                identityCoordinator: CompositionIdentitySource(
                    identity: identity
                ),
                reader: CompositionReadbackSource(readback: readback),
                protectionSource: source
            )
        let requestID = UUID(
            uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!

        let outcome = await coordinator.analyze(request: .init(
            requestID: requestID,
            snapshotReference: identity.snapshotReference,
            previewID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!,
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
        ))

        guard case let .preview(returnedID, preview) = outcome else {
            return XCTFail("Expected composed Experimental Preview")
        }
        XCTAssertEqual(returnedID, requestID)
        XCTAssertEqual(preview.targetThreadIDs, [target])
        XCTAssertEqual(
            preview.items.map {
                $0.experimentalAbsenceEvidence.requestedThreadID
            },
            [target]
        )
        XCTAssertFalse(preview.confirmationAuthority)
        XCTAssertFalse(preview.repairMutationAuthority)
        let calls = await transport.recordedCalls()
        XCTAssertEqual(
            calls,
            [
                .inventory,
                .exactRead(present),
                .exactRead(target),
                .operationalAudit,
            ]
        )
    }

    func testAnalysisRequestIDIsPassedExactlyToObservation() async throws {
        let identity = try makeIdentity()
        let requestID = UUID()
        let observer = RecordingCompositionObserver(
            result: .success(makeObservation(
                requestID: requestID,
                identity: identity
            ))
        )
        let source = CodexGhostRepairExperimentalProtectionCompositionSource(
            observer: observer,
            registry: try makeRegistry()
        )
        _ = try await source.audit(
            requestID: requestID,
            identity: identity,
            snapshotEvidence: makeReadback(identity: identity)
        )

        let requests = await observer.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].requestID, requestID)
        XCTAssertEqual(requests[0].identity, identity)
    }

    func testMismatchedObservationRequestIDFailsClosed() async throws {
        let identity = try makeIdentity()
        let observed = makeObservation(
            requestID: UUID(),
            identity: identity
        )
        let source = try makeSource(observerResult: .success(observed))

        await XCTAssertThrowsErrorAsync {
            _ = try await source.audit(
                requestID: UUID(),
                identity: identity,
                snapshotEvidence: self.makeReadback(identity: identity)
            )
        }
    }

    func testMismatchedObservationIdentityFailsClosed() async throws {
        let identity = try makeIdentity()
        let drifted = try makeIdentity(snapshotID: UUID())
        let requestID = UUID()
        let source = try makeSource(observerResult: .success(
            makeObservation(requestID: requestID, identity: drifted)
        ))

        await XCTAssertThrowsErrorAsync {
            _ = try await source.audit(
                requestID: requestID,
                identity: identity,
                snapshotEvidence: self.makeReadback(identity: identity)
            )
        }
    }

    func testUnavailableObservationAndEmptyRegistryBothFailClosed()
        async throws
    {
        let identity = try makeIdentity()
        let requestID = UUID()
        let unavailable = CodexGhostRepairExperimentalProtectionCompositionSource(
            observer: RecordingCompositionObserver(result: .unavailable),
            registry: try makeRegistry()
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await unavailable.audit(
                requestID: requestID,
                identity: identity,
                snapshotEvidence: self.makeReadback(identity: identity)
            )
        }

        let empty = CodexGhostRepairExperimentalProtectionCompositionSource(
            observer: RecordingCompositionObserver(
                result: .success(makeObservation(
                    requestID: requestID,
                    identity: identity
                ))
            ),
            registry: .init()
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await empty.audit(
                requestID: requestID,
                identity: identity,
                snapshotEvidence: self.makeReadback(identity: identity)
            )
        }
    }

    func testPinnedAndDescendantEvidenceStillBlocksPlanner() async throws {
        let identity = try makeIdentity()
        let requestID = UUID()
        let observation = makeProtectionObservation(
            pinned: [target],
            descendants: [
                .init(threadID: child, parentThreadID: target),
            ]
        )
        let source = try makeSource(observerResult: .success(.init(
            requestID: requestID,
            identity: identity,
            observation: observation
        )))
        let coordinator =
            CodexGhostRepairSnapshotDryRunAnalysisCandidateCoordinator(
                identityCoordinator: CompositionIdentitySource(
                    identity: identity
                ),
                reader: CompositionReadbackSource(
                    readback: makeReadback(identity: identity)
                ),
                protectionSource: source
            )

        let outcome = await coordinator.analyze(request: .init(
            requestID: requestID,
            snapshotReference: identity.snapshotReference,
            previewID: UUID(),
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
        ))

        XCTAssertEqual(
            outcome,
            .blocked(
                requestID: requestID,
                blockers: [
                    .init(
                        code: .invalidProtectionEvidence,
                        threadID: target
                    ),
                ]
            )
        )
    }

    private func makeSource(
        observerResult: CompositionObserverResult
    ) throws -> CodexGhostRepairExperimentalProtectionCompositionSource {
        .init(
            observer: RecordingCompositionObserver(result: observerResult),
            registry: try makeRegistry()
        )
    }

    private func makeObservation(
        requestID: UUID = UUID(),
        identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) -> CodexGhostRepairExperimentalObservedProtection {
        .init(
            requestID: requestID,
            identity: identity,
            observation: makeProtectionObservation()
        )
    }

    private func makeProtectionObservation(
        pinned: Set<String> = [],
        descendants: [CodexGhostRepairExperimentalDescendantNode] = []
    ) -> CodexGhostRepairExperimentalProtectionObservation {
        .init(
            provider: .codex,
            runtimeVersion: "0.149.0",
            inventoryComplete: true,
            activeThreadIDs: [present],
            archivedThreadIDs: [],
            pinnedThreadIDs: pinned,
            pinnedInventoryComplete: true,
            descendantNodes: descendants,
            descendantGraphComplete: true,
            presentControlThreadID: present,
            presentControlReturnedThreadID: present,
            exactReadFailures: [
                .init(
                    threadID: target,
                    provider: .codex,
                    runtimeVersion: "0.149.0",
                    method: .threadRead,
                    errorKind: .rpcError,
                    rpcCode: -32600,
                    responseShapeIdentifier: "rpc-error-code-message-v1",
                    message: "thread not loaded: \(target)"
                ),
            ],
            operationalAudit: clearGate()
        )
    }

    private func makeIdentity(
        snapshotID: UUID = UUID(
            uuidString: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
        )!
    ) throws -> CodexGhostRepairSnapshotAnalysisIdentity {
        try .init(
            snapshotID: snapshotID,
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
            targets: [
                .init(
                    threadID: target,
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
                ),
            ],
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
                compatibilityFixtureHash: digest("d"),
                packagedCanaryEvidenceHash: digest("e"),
                presentControlThreadIDHash: digest("f"),
                missingFixtureThreadIDHashes: [digest("a")],
                presentControlVerified: true,
                missingFixtureVerified: true
            ),
        ])
    }

    private func makeInventory()
        -> CodexGhostRepairExperimentalTransportInventory
    {
        .init(
            provider: .codex,
            runtimeVersion: "0.149.0",
            inventoryComplete: true,
            activeThreadIDs: [present],
            archivedThreadIDs: [],
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            descendantNodes: [],
            descendantGraphComplete: true
        )
    }

    private func makeReads()
        -> [String: CodexGhostRepairExperimentalTransportExactReadOutcome]
    {
        [
            present: .present(returnedThreadID: present),
            target: .failure(
                errorKind: .rpcError,
                rpcCode: -32600,
                responseShapeIdentifier: "rpc-error-code-message-v1",
                message: "thread not loaded: \(target)"
            ),
        ]
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

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}

private enum CompositionObserverResult: Sendable {
    case success(CodexGhostRepairExperimentalObservedProtection)
    case unavailable
}

private actor RecordingCompositionObserver:
    CodexGhostRepairExperimentalObservationCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairExperimentalObservationCapabilities
            .deterministicCandidate
    let result: CompositionObserverResult
    private(set) var requests:
        [CodexGhostRepairExperimentalObservationRequest] = []

    init(result: CompositionObserverResult) {
        self.result = result
    }

    func observe(
        request: CodexGhostRepairExperimentalObservationRequest
    ) async -> CodexGhostRepairExperimentalObservationOutcome {
        requests.append(request)
        switch result {
        case let .success(result):
            return .observed(result)
        case .unavailable:
            return .unavailable(
                requestID: request.requestID,
                failure: .init(
                    stage: .appServerInventory,
                    reason: .observationUnavailable
                )
            )
        }
    }
}

private actor CompositionTransport:
    CodexGhostRepairExperimentalObservationTransport
{
    enum Call: Equatable {
        case inventory
        case exactRead(String)
        case operationalAudit
    }

    let inventoryValue: CodexGhostRepairExperimentalTransportInventory
    let reads:
        [String: CodexGhostRepairExperimentalTransportExactReadOutcome]
    let gate: CodexGhostRepairExecutionGate
    private var calls: [Call] = []

    init(
        inventory: CodexGhostRepairExperimentalTransportInventory,
        reads:
            [String: CodexGhostRepairExperimentalTransportExactReadOutcome],
        gate: CodexGhostRepairExecutionGate
    ) {
        inventoryValue = inventory
        self.reads = reads
        self.gate = gate
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
            throw CodexAppServerError.exactReadUnavailable
        }
        return result
    }

    func operationalAudit() async throws -> CodexGhostRepairExecutionGate {
        calls.append(.operationalAudit)
        return gate
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

private struct CompositionIdentitySource:
    CodexGhostRepairSnapshotAnalysisIdentityCoordinator
{
    let capabilities =
        CodexGhostRepairSnapshotAnalysisIdentityCapabilities.packagedReadOnly
    let identity: CodexGhostRepairSnapshotAnalysisIdentity

    func resolve(
        request: CodexGhostRepairSnapshotAnalysisRequest
    ) async -> CodexGhostRepairSnapshotAnalysisIdentityOutcome {
        .resolved(identity)
    }
}

private struct CompositionReadbackSource:
    CodexGhostRepairSnapshotAnalysisReading
{
    let capabilities =
        CodexGhostRepairSnapshotAnalysisReaderCapabilities.packagedReadOnly
    let readback: CodexGhostRepairSnapshotAnalysisReadback

    func read(
        identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) async -> CodexGhostRepairSnapshotAnalysisReadOutcome {
        .read(readback)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {}
}
