@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairExperimentalCompatibilityReviewTests:
    XCTestCase
{
    private let targetA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let targetB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"
    private let present = "019f6500-1111-7222-8333-444444444444"

    func testPackagedFactoryConstructsWithoutIOAndGrantsNoAuthority() async {
        let gate = CompatibilityGateSource()
        let coordinator =
            CodexGhostRepairSnapshotDryRunAnalysisCoordinatorFactory
                .packagedCompatibilityReview(executionGateSource: gate)

        XCTAssertTrue(coordinator.capabilities.analysisAvailable)
        XCTAssertTrue(
            coordinator.capabilities.identityResolutionAvailable
        )
        XCTAssertTrue(coordinator.capabilities.snapshotQueryAvailable)
        XCTAssertFalse(coordinator.capabilities.protectionAuditAvailable)
        XCTAssertTrue(
            coordinator.capabilities.compatibilityReviewAvailable
        )
        XCTAssertFalse(coordinator.capabilities.automaticAnalysis)
        XCTAssertFalse(coordinator.capabilities.automaticRetry)
        XCTAssertTrue(coordinator.capabilities.writesFilesystem)
        XCTAssertTrue(
            coordinator.capabilities.usesEphemeralAnalysisWorkspace
        )
        XCTAssertFalse(coordinator.capabilities.writesPublishedSnapshot)
        XCTAssertFalse(coordinator.capabilities.persistsPreview)
        XCTAssertFalse(coordinator.capabilities.confirmationAuthority)
        XCTAssertFalse(coordinator.capabilities.repairMutationAuthority)
        let gateCallCount = await gate.callCount
        XCTAssertEqual(gateCallCount, 0)
    }

    func testPackagedAdmittedFactoryConstructsWithoutIOAndGrantsNoAuthority()
        async
    {
        let gate = CompatibilityGateSource()
        let coordinator =
            CodexGhostRepairSnapshotDryRunAnalysisCoordinatorFactory
                .packagedAdmittedPreview(executionGateSource: gate)

        XCTAssertTrue(coordinator.capabilities.analysisAvailable)
        XCTAssertTrue(coordinator.capabilities.protectionAuditAvailable)
        XCTAssertTrue(coordinator.capabilities.compatibilityReviewAvailable)
        XCTAssertTrue(coordinator.capabilities.persistsPreview)
        XCTAssertTrue(
            coordinator.capabilities.experimentalAbsenceContractAvailable
        )
        XCTAssertFalse(coordinator.capabilities.automaticAnalysis)
        XCTAssertFalse(coordinator.capabilities.automaticRetry)
        XCTAssertFalse(coordinator.capabilities.writesPublishedSnapshot)
        XCTAssertFalse(coordinator.capabilities.confirmationAuthority)
        XCTAssertFalse(coordinator.capabilities.repairMutationAuthority)
        let gateCallCount = await gate.callCount
        XCTAssertEqual(gateCallCount, 0)
    }

    func testExplicitCandidateReturnsOnlyCanonicalCompatibilityEvidence()
        async throws
    {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let request = makeRequest(identity: identity)
        let observer = CompatibilityObserver(
            outcome: .observed(.init(
                requestID: request.requestID,
                identity: identity,
                observation: makeObservation(targets: [targetA, targetB])
            ))
        )
        let coordinator =
            CodexGhostRepairExperimentalCompatibilityReviewCoordinator(
                identityCoordinator: CompatibilityIdentitySource(
                    outcome: .resolved(identity)
                ),
                reader: CompatibilityReaderSource(
                    outcome: .read(makeReadback(identity: identity))
                ),
                observer: observer
            )

        let outcome = await coordinator.analyze(request: request)

        guard case let .compatibilityReview(requestID, evidence) = outcome
        else {
            return XCTFail("Expected compatibility review evidence")
        }
        XCTAssertEqual(requestID, request.requestID)
        XCTAssertEqual(evidence.requestID, request.requestID)
        XCTAssertEqual(evidence.snapshotIdentity, identity)
        XCTAssertEqual(evidence.targetThreadIDs, [targetA, targetB])
        XCTAssertTrue(evidence.presentControlThreadIDHash.hasPrefix("sha256:"))
        XCTAssertEqual(evidence.presentControlThreadIDHash.count, 71)
        XCTAssertEqual(evidence.runtimeVersion, "0.149.0")
        XCTAssertEqual(evidence.method, .threadRead)
        XCTAssertEqual(evidence.errorKind, .rpcError)
        XCTAssertEqual(evidence.rpcCode, -32600)
        XCTAssertEqual(
            evidence.responseShapeIdentifier,
            "rpc-error-code-message-v1"
        )
        XCTAssertEqual(
            evidence.exactMessageTemplate,
            "thread not loaded: {thread_id}"
        )
        XCTAssertTrue(evidence.canonicalEvidenceHash.hasPrefix("sha256:"))
        XCTAssertEqual(evidence.canonicalEvidenceHash.count, 71)
        XCTAssertFalse(evidence.previewCreated)
        XCTAssertFalse(evidence.previewPersisted)
        XCTAssertFalse(evidence.confirmationAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)
        let observationCount = await observer.requestCount()
        XCTAssertEqual(observationCount, 1)
    }

    func testIdentityOrReaderUnavailableShortCircuitsLaterReads()
        async throws
    {
        let identity = try makeIdentity(targets: [targetA])
        let observer = CompatibilityObserver(
            outcome: .unavailable(
                requestID: UUID(),
                failure: failure(
                    stage: .appServerInventory,
                    reason: .observationUnavailable
                )
            )
        )
        let identityUnavailable =
            CodexGhostRepairExperimentalCompatibilityReviewCoordinator(
                identityCoordinator: CompatibilityIdentitySource(
                    outcome: .unavailable(message: "unavailable")
                ),
                reader: CompatibilityReaderSource(
                    outcome: .read(makeReadback(identity: identity))
                ),
                observer: observer
            )
        guard case let .compatibilityUnavailable(_, identityFailure) =
            await identityUnavailable.analyze(
            request: makeRequest(identity: identity)
        ) else {
            return XCTFail("Expected unavailable identity")
        }
        XCTAssertEqual(identityFailure.stage, .snapshotIdentity)
        XCTAssertEqual(identityFailure.reason, .snapshotIdentityUnavailable)
        let countAfterIdentity = await observer.requestCount()
        XCTAssertEqual(countAfterIdentity, 0)

        let readerUnavailable =
            CodexGhostRepairExperimentalCompatibilityReviewCoordinator(
                identityCoordinator: CompatibilityIdentitySource(
                    outcome: .resolved(identity)
                ),
                reader: CompatibilityReaderSource(
                    outcome: .unavailable(
                        reason: .desktopContractUnavailable
                    )
                ),
                observer: observer
            )
        guard case let .compatibilityUnavailable(_, readerFailure) =
            await readerUnavailable.analyze(
            request: makeRequest(identity: identity)
        ) else {
            return XCTFail("Expected unavailable reader")
        }
        XCTAssertEqual(readerFailure.stage, .snapshotReadback)
        XCTAssertEqual(readerFailure.reason, .snapshotReadUnavailable)
        XCTAssertEqual(
            readerFailure.snapshotReadReason,
            .desktopContractUnavailable
        )
        XCTAssertTrue(readerFailure.snapshotReadReason?.pathRedacted == true)
        XCTAssertFalse(
            readerFailure.snapshotReadReason?.rawErrorIncluded == true
        )
        let countAfterReader = await observer.requestCount()
        XCTAssertEqual(countAfterReader, 0)
    }

    func testCrossRequestObservationAndMessageTemplateDriftFailClosed()
        async throws
    {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let request = makeRequest(identity: identity)
        let crossRequest =
            CodexGhostRepairExperimentalCompatibilityReviewCoordinator(
                identityCoordinator: CompatibilityIdentitySource(
                    outcome: .resolved(identity)
                ),
                reader: CompatibilityReaderSource(
                    outcome: .read(makeReadback(identity: identity))
                ),
                observer: CompatibilityObserver(outcome: .observed(.init(
                    requestID: UUID(),
                    identity: identity,
                    observation: makeObservation(
                        targets: [targetA, targetB]
                    )
                )))
            )
        guard case let .compatibilityUnavailable(_, failure) =
            await crossRequest.analyze(
            request: request
        ) else {
            return XCTFail("Expected cross-request rejection")
        }
        XCTAssertEqual(failure.stage, .resultIdentity)
        XCTAssertEqual(failure.reason, .observationIdentityMismatch)

        let crossRequestFailure =
            CodexGhostRepairExperimentalCompatibilityReviewCoordinator(
                identityCoordinator: CompatibilityIdentitySource(
                    outcome: .resolved(identity)
                ),
                reader: CompatibilityReaderSource(
                    outcome: .read(makeReadback(identity: identity))
                ),
                observer: CompatibilityObserver(outcome: .unavailable(
                    requestID: UUID(),
                    failure: self.failure(
                        stage: .appServerInventory,
                        reason: .inventoryReadFailed
                    )
                ))
            )
        guard case let .compatibilityUnavailable(_, unavailableFailure) =
            await crossRequestFailure.analyze(request: request) else {
            return XCTFail("Expected cross-request failure rejection")
        }
        XCTAssertEqual(unavailableFailure.stage, .resultIdentity)
        XCTAssertEqual(
            unavailableFailure.reason,
            .observationIdentityMismatch
        )

        let driftedObservation = makeObservation(
            targets: [targetA, targetB],
            secondMessage: "missing thread (targetB)"
        )
        XCTAssertThrowsError(
            try CodexGhostRepairExperimentalCompatibilityEvidenceBuilder
                .build(
                    requestID: request.requestID,
                    identity: identity,
                    snapshotEvidence: makeReadback(identity: identity),
                    observation: driftedObservation
                )
        )

        let driftedCoordinator =
            CodexGhostRepairExperimentalCompatibilityReviewCoordinator(
                identityCoordinator: CompatibilityIdentitySource(
                    outcome: .resolved(identity)
                ),
                reader: CompatibilityReaderSource(
                    outcome: .read(makeReadback(identity: identity))
                ),
                observer: CompatibilityObserver(outcome: .observed(.init(
                    requestID: request.requestID,
                    identity: identity,
                    observation: driftedObservation
                )))
            )
        guard case let .compatibilityUnavailable(_, driftFailure) =
            await driftedCoordinator.analyze(request: request) else {
            return XCTFail("Expected evidence-validation failure")
        }
        XCTAssertEqual(driftFailure.stage, .evidenceValidation)
        XCTAssertEqual(driftFailure.reason, .evidenceInvalid)
    }

    func testExactAdmittedEvidencePersistsPreviewOnceWithExactReceipt()
        async throws
    {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let request = makeRequest(identity: identity)
        let persister = CompatibilityPreviewPersister(mode: .exact)
        let coordinator = admittedCoordinator(
            identity: identity,
            request: request,
            observation: makeObservation(targets: [targetA, targetB]),
            persister: persister
        )

        XCTAssertTrue(coordinator.capabilities.protectionAuditAvailable)
        XCTAssertTrue(coordinator.capabilities.persistsPreview)
        XCTAssertTrue(
            coordinator.capabilities.experimentalAbsenceContractAvailable
        )
        let outcome = await coordinator.analyze(request: request)

        guard case let .persistedPreview(requestID, preview, receipt) = outcome
        else {
            return XCTFail("Expected one exactly persisted Preview")
        }
        XCTAssertEqual(requestID, request.requestID)
        XCTAssertEqual(preview.previewID, request.previewID)
        XCTAssertEqual(receipt.requestID, request.requestID)
        XCTAssertEqual(receipt.previewID, preview.previewID)
        XCTAssertTrue(receipt.durableReadbackMatched)
        XCTAssertFalse(receipt.confirmationAuthority)
        XCTAssertFalse(receipt.repairMutationAuthority)
        XCTAssertFalse(preview.confirmationAuthority)
        XCTAssertFalse(preview.repairMutationAuthority)
        let persistCount = await persister.persistCount()
        XCTAssertEqual(persistCount, 1)
    }

    func testAdmissionDriftReturnsReviewOnlyAndNeverPersists()
        async throws
    {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let request = makeRequest(identity: identity)
        let persister = CompatibilityPreviewPersister(mode: .exact)
        var drifted = makeObservation(targets: [targetA, targetB])
        drifted = .init(
            provider: drifted.provider,
            runtimeVersion: "0.149.1",
            inventoryComplete: drifted.inventoryComplete,
            activeThreadIDs: drifted.activeThreadIDs,
            archivedThreadIDs: drifted.archivedThreadIDs,
            pinnedThreadIDs: drifted.pinnedThreadIDs,
            pinnedInventoryComplete: drifted.pinnedInventoryComplete,
            descendantNodes: drifted.descendantNodes,
            descendantGraphComplete: drifted.descendantGraphComplete,
            presentControlThreadID: drifted.presentControlThreadID,
            presentControlReturnedThreadID:
                drifted.presentControlReturnedThreadID,
            exactReadFailures: drifted.exactReadFailures.map {
                .init(
                    threadID: $0.threadID,
                    provider: $0.provider,
                    runtimeVersion: "0.149.1",
                    method: $0.method,
                    errorKind: $0.errorKind,
                    rpcCode: $0.rpcCode,
                    responseShapeIdentifier: $0.responseShapeIdentifier,
                    message: $0.message
                )
            },
            operationalAudit: drifted.operationalAudit
        )
        let coordinator = admittedCoordinator(
            identity: identity,
            request: request,
            observation: drifted,
            persister: persister
        )

        guard case let .compatibilityReview(_, evidence) =
            await coordinator.analyze(request: request) else {
            return XCTFail("Expected review-only evidence after drift")
        }
        XCTAssertEqual(evidence.runtimeVersion, "0.149.1")
        XCTAssertFalse(evidence.previewCreated)
        XCTAssertFalse(evidence.previewPersisted)
        let persistCount = await persister.persistCount()
        XCTAssertEqual(persistCount, 0)
    }

    func testPersistenceFailureIsUnknownAndNeverPresentsPreview()
        async throws
    {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let request = makeRequest(identity: identity)
        let persister = CompatibilityPreviewPersister(mode: .throwFailure)
        let coordinator = admittedCoordinator(
            identity: identity,
            request: request,
            observation: makeObservation(targets: [targetA, targetB]),
            persister: persister
        )

        guard case let .persistenceUnavailable(requestID, failure) =
            await coordinator.analyze(request: request) else {
            return XCTFail("Expected unknown persistence outcome")
        }
        XCTAssertEqual(requestID, request.requestID)
        XCTAssertEqual(failure.snapshotReference, request.snapshotReference)
        XCTAssertEqual(failure.reason, .writeOrReadbackFailed)
        XCTAssertEqual(failure.persistenceOutcome, "unknown")
        XCTAssertFalse(failure.previewPresented)
        XCTAssertFalse(failure.automaticRetry)
        XCTAssertFalse(failure.confirmationAuthority)
        XCTAssertFalse(failure.repairMutationAuthority)
        let persistCount = await persister.persistCount()
        XCTAssertEqual(persistCount, 1)
    }

    func testMismatchedPersistenceReceiptFailsClosed()
        async throws
    {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let request = makeRequest(identity: identity)
        let persister = CompatibilityPreviewPersister(mode: .mismatched)
        let coordinator = admittedCoordinator(
            identity: identity,
            request: request,
            observation: makeObservation(targets: [targetA, targetB]),
            persister: persister
        )

        guard case let .persistenceUnavailable(_, failure) =
            await coordinator.analyze(request: request) else {
            return XCTFail("Expected mismatched receipt to fail closed")
        }
        XCTAssertEqual(failure.reason, .receiptIdentityMismatch)
        XCTAssertFalse(failure.previewPresented)
        XCTAssertEqual(failure.persistenceOutcome, "unknown")
    }

    private func failure(
        stage: CodexGhostRepairExperimentalCompatibilityFailureStage,
        reason: CodexGhostRepairExperimentalCompatibilityFailureReason
    ) -> CodexGhostRepairExperimentalCompatibilityFailure {
        .init(stage: stage, reason: reason)
    }

    private func admittedCoordinator(
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        request: CodexGhostRepairSnapshotDryRunAnalysisRequest,
        observation: CodexGhostRepairExperimentalProtectionObservation,
        persister: CompatibilityPreviewPersister
    ) -> CodexGhostRepairExperimentalCompatibilityReviewCoordinator {
        CodexGhostRepairExperimentalCompatibilityReviewCoordinator(
            identityCoordinator: CompatibilityIdentitySource(
                outcome: .resolved(identity)
            ),
            reader: CompatibilityReaderSource(
                outcome: .read(makeReadback(identity: identity))
            ),
            observer: CompatibilityObserver(outcome: .observed(.init(
                requestID: request.requestID,
                identity: identity,
                observation: observation
            ))),
            registry: .packagedReviewedV1(),
            previewPersister: persister
        )
    }

    private func makeRequest(
        identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) -> CodexGhostRepairSnapshotDryRunAnalysisRequest {
        .init(
            requestID: UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!,
            snapshotReference: identity.snapshotReference,
            previewID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!,
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
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
            databases: databaseEvidence(),
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

    private func makeObservation(
        targets: [String],
        secondMessage: String? = nil
    ) -> CodexGhostRepairExperimentalProtectionObservation {
        .init(
            provider: .codex,
            runtimeVersion: "0.149.0",
            inventoryComplete: true,
            activeThreadIDs: [present],
            archivedThreadIDs: [],
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            descendantNodes: [],
            descendantGraphComplete: true,
            presentControlThreadID: present,
            presentControlReturnedThreadID: present,
            exactReadFailures: targets.enumerated().map { index, target in
                .init(
                    threadID: target,
                    provider: .codex,
                    runtimeVersion: "0.149.0",
                    method: .threadRead,
                    errorKind: .rpcError,
                    rpcCode: -32600,
                    responseShapeIdentifier: "rpc-error-code-message-v1",
                    message: index == 1
                        ? secondMessage ?? "thread not loaded: \(target)"
                        : "thread not loaded: \(target)"
                )
            },
            operationalAudit: .init(
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

    private func databaseEvidence()
        -> [CodexGhostRepairSnapshotAnalysisDatabaseEvidence] {
        [
            .init(
                database: .desktop,
                schemaVersion: 32,
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
        ]
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}

private struct CompatibilityIdentitySource:
    CodexGhostRepairSnapshotAnalysisIdentityCoordinator
{
    let capabilities =
        CodexGhostRepairSnapshotAnalysisIdentityCapabilities.packagedReadOnly
    let outcome: CodexGhostRepairSnapshotAnalysisIdentityOutcome

    func resolve(
        request _: CodexGhostRepairSnapshotAnalysisRequest
    ) async -> CodexGhostRepairSnapshotAnalysisIdentityOutcome {
        outcome
    }
}

private struct CompatibilityReaderSource:
    CodexGhostRepairSnapshotAnalysisReading
{
    let capabilities =
        CodexGhostRepairSnapshotAnalysisReaderCapabilities.packagedReadOnly
    let outcome: CodexGhostRepairSnapshotAnalysisReadOutcome

    func read(
        identity _: CodexGhostRepairSnapshotAnalysisIdentity
    ) async -> CodexGhostRepairSnapshotAnalysisReadOutcome {
        outcome
    }
}

private actor CompatibilityObserver:
    CodexGhostRepairExperimentalObservationCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairExperimentalObservationCapabilities
            .deterministicCandidate
    let outcome: CodexGhostRepairExperimentalObservationOutcome
    private var count = 0

    init(outcome: CodexGhostRepairExperimentalObservationOutcome) {
        self.outcome = outcome
    }

    func observe(
        request _: CodexGhostRepairExperimentalObservationRequest
    ) async -> CodexGhostRepairExperimentalObservationOutcome {
        count += 1
        return outcome
    }

    func requestCount() -> Int { count }
}

private actor CompatibilityGateSource:
    CodexGhostRepairExecutionGateSource
{
    private(set) var callCount = 0

    func ghostRepairExecutionGate() async throws
        -> CodexGhostRepairExecutionGate {
        callCount += 1
        return .init(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            stateOpenHandleCount: 0,
            threadHistoryOpenHandleCount: 0,
            capacitySufficient: true
        )
    }
}

private actor CompatibilityPreviewPersister:
    CodexGhostRepairSnapshotDryRunPreviewPersisting
{
    enum Mode: Sendable {
        case exact
        case mismatched
        case throwFailure
    }

    private let mode: Mode
    private var count = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func persist(
        requestID: UUID,
        preview: CodexGhostRepairSnapshotDryRunPreview
    ) async throws -> CodexGhostRepairSnapshotDryRunPersistenceReceipt {
        count += 1
        switch mode {
        case .exact:
            return .init(
                requestID: requestID,
                previewID: preview.previewID,
                payloadHash: "sha256:" + String(repeating: "a", count: 64),
                durableReadbackMatched: true
            )
        case .mismatched:
            return .init(
                requestID: UUID(),
                previewID: preview.previewID,
                payloadHash: "sha256:" + String(repeating: "a", count: 64),
                durableReadbackMatched: true
            )
        case .throwFailure:
            throw NSError(
                domain: "CompatibilityPreviewPersister",
                code: 1
            )
        }
    }

    func persistCount() -> Int { count }
}
