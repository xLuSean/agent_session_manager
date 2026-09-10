@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairCategoryARepairExecutionCoordinatorTests:
    XCTestCase
{
#if AGENT_SESSION_MANAGER_RESEARCH
    func testPackagedProductionCompositionIsNoPathAndZeroIO() {
        let coordinator =
            CodexGhostRepairCategoryARepairCoordinatorFactory
                .packagedProduction()

        XCTAssertTrue(coordinator.capabilities.reviewAvailable)
        XCTAssertTrue(coordinator.capabilities.executionAvailable)
        XCTAssertEqual(
            coordinator.capabilities.effect,
            .fixedCodexCategoryAOneShot
        )
        XCTAssertFalse(coordinator.capabilities.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.automaticRetryAllowed)
        XCTAssertFalse(coordinator.capabilities.restoreAuthority)
        XCTAssertFalse(coordinator.capabilities.cleanupAuthority)
    }
#endif

    func testExactConfirmationClaimsExecutesOnceAndDuplicateOnlyReadsReport()
        async throws
    {
        let fixture = try Fixture()
        let mutator = Mutator(execution: .init(
            outcome: .success,
            mutationAttemptedOnce: true
        ))
        let coordinator = try fixture.coordinator(mutator: mutator)

        let first = await coordinator.confirmAndRepair(
            request: fixture.executionRequest()
        )
        let duplicate = await coordinator.confirmAndRepair(
            request: fixture.executionRequest()
        )

        try assertCompleted(first, outcome: .success)
        XCTAssertEqual(first, duplicate)
        let executionCount = await mutator.executionCount()
        let recoveryCount = await mutator.recoveryCount()
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(recoveryCount, 0)
        let state = try fixture.operation()
        XCTAssertEqual(state?.status, .terminal)
        XCTAssertEqual(state?.claim?.executionSnapshotManifestHash,
                       fixture.binding.snapshotManifestHash)
        XCTAssertFalse(state?.automaticRetryAllowed ?? true)
    }

    func testFreshEvidenceFailureConsumesAuthorizationAndStopsNotAttempted()
        async throws
    {
        let fixture = try Fixture()
        let mutator = Mutator(execution: .init(
            outcome: .success,
            mutationAttemptedOnce: true
        ))
        let coordinator = try fixture.coordinator(
            mutator: mutator,
            includeFreshEvidence: false
        )

        let result = await coordinator.confirmAndRepair(
            request: fixture.executionRequest()
        )
        let duplicate = await coordinator.confirmAndRepair(
            request: fixture.executionRequest()
        )

        try assertCompleted(result, outcome: .notAttempted)
        XCTAssertEqual(result, duplicate)
        let executionCount = await mutator.executionCount()
        XCTAssertEqual(executionCount, 0)
        XCTAssertNil(try fixture.operation()?.claim)
        XCTAssertNotNil(try fixture.operation()?.receipt)
    }

    func testCrashAfterClaimUsesReadbackAndNeverCallsExecuteAgain()
        async throws
    {
        let fixture = try Fixture()
        let mutator = Mutator(
            execution: .init(outcome: .unknown, mutationAttemptedOnce: true),
            recovery: .init(outcome: .success, mutationAttemptedOnce: true),
            throwDuringExecution: true
        )
        let coordinator = try fixture.coordinator(mutator: mutator)

        let recovered = await coordinator.confirmAndRepair(
            request: fixture.executionRequest()
        )
        let duplicate = await coordinator.confirmAndRepair(
            request: fixture.executionRequest()
        )

        try assertCompleted(recovered, outcome: .success)
        XCTAssertEqual(recovered, duplicate)
        let executionCount = await mutator.executionCount()
        let recoveryCount = await mutator.recoveryCount()
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(recoveryCount, 1)
    }

    func testColdAuthorizedWithoutClaimBecomesTerminalNotAttempted()
        async throws
    {
        let fixture = try Fixture()
        let store = try SQLiteStateStore(databaseURL: fixture.databaseURL)
        _ = try store.consumeCodexGhostRepairCategoryAAuthorization(
            operationID: fixture.binding.operationID,
            confirmationToken: fixture.binding.challenge.confirmationToken,
            confirmedAtMilliseconds: 2_300
        )
        store.close()
        let mutator = Mutator(execution: .init(
            outcome: .success,
            mutationAttemptedOnce: true
        ))
        let coordinator = try fixture.coordinator(mutator: mutator)

        let result = await coordinator.confirmAndRepair(
            request: fixture.executionRequest()
        )

        try assertCompleted(result, outcome: .notAttempted)
        let executionCount = await mutator.executionCount()
        let recoveryCount = await mutator.recoveryCount()
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(recoveryCount, 0)
    }

    func testWrongTokenOrChallengeBindingNeverClaimsOrMutates() async throws {
        let fixture = try Fixture()
        let mutator = Mutator(execution: .init(
            outcome: .success,
            mutationAttemptedOnce: true
        ))
        let coordinator = try fixture.coordinator(mutator: mutator)
        let wrongToken = CodexGhostRepairCategoryARepairExecutionRequest(
            requestID: UUID(),
            challenge: fixture.publicChallenge,
            exactConfirmationToken: "M3A-REPAIR-000000000000"
        )

        guard case .unavailable = await coordinator.confirmAndRepair(
            request: wrongToken
        ) else { return XCTFail("Expected exact token rejection") }
        let executionCount = await mutator.executionCount()
        XCTAssertEqual(executionCount, 0)
        XCTAssertNil(try fixture.operation()?.receipt)

        let drifted = try CodexGhostRepairCategoryARepairChallenge(
            operationID: fixture.publicChallenge.operationID,
            savedPreviewRequestID: fixture.publicChallenge.savedPreviewRequestID,
            snapshotReference: fixture.publicChallenge.snapshotReference,
            snapshotManifestHash: fixture.publicChallenge.snapshotManifestHash,
            snapshotSourceFingerprintHash:
                fixture.publicChallenge.snapshotSourceFingerprintHash,
            preparedBindingDigest: M3eCategoryATestFixture().digest("0"),
            targetThreadIDs: fixture.publicChallenge.targetThreadIDs,
            buildIdentifier: fixture.publicChallenge.buildIdentifier,
            draftDigest: fixture.publicChallenge.draftDigest,
            reviewDigest: fixture.publicChallenge.reviewDigest,
            challengeDigest: fixture.publicChallenge.challengeDigest,
            confirmationToken: fixture.publicChallenge.confirmationToken,
            generatedAt: fixture.publicChallenge.generatedAt,
            expiresAt: fixture.publicChallenge.expiresAt
        )
        let wrongBinding = CodexGhostRepairCategoryARepairExecutionRequest(
            requestID: UUID(),
            challenge: drifted,
            exactConfirmationToken: drifted.confirmationToken
        )
        guard case .unavailable = await coordinator.confirmAndRepair(
            request: wrongBinding
        ) else { return XCTFail("Expected binding rejection") }
        XCTAssertNil(try fixture.operation()?.receipt)
    }

    func testProductionFreshAdapterRequiresExactProtectionContinuity()
        async throws
    {
        let fixture = try Fixture()
        let matching = ReviewCollector(outcome: .material(.init(
            review: fixture.binding.review,
            buildIdentifier: "build",
            observedAtMilliseconds: 2_400
        )))
        let accepted = await CodexGhostRepairCategoryAProductionFreshExecutionCollector(
            reviewCollector: matching
        ).collect(binding: fixture.binding)
        XCTAssertNotNil(accepted)

        let original = fixture.binding.review
        let driftedReview = try CodexGhostRepairCategoryAExecutionReviewEvidence(
            reviewID: UUID(),
            items: original.items,
            protectionEvidenceHash: M3eCategoryATestFixture().digest("0"),
            protectionComplete: true,
            operationalGateEvidenceHash: original.operationalGateEvidenceHash,
            operationalGateClear: true,
            databaseExpectations: original.databaseExpectations,
            authorityAudit: original.authorityAudit,
            observedAtMilliseconds: 2_400
        )
        let drifted = ReviewCollector(outcome: .material(.init(
            review: driftedReview,
            buildIdentifier: "build",
            observedAtMilliseconds: 2_400
        )))
        let rejected = await CodexGhostRepairCategoryAProductionFreshExecutionCollector(
            reviewCollector: drifted
        ).collect(binding: fixture.binding)
        XCTAssertNil(rejected)
    }

    private func assertCompleted(
        _ result: CodexGhostRepairCategoryARepairExecutionOutcome,
        outcome: CodexGhostRepairCategoryARepairObservedOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case let .completed(report) = result else {
            return XCTFail("Expected completed Report", file: file, line: line)
        }
        XCTAssertEqual(report.outcome, outcome, file: file, line: line)
        XCTAssertTrue(
            report.itemOutcomes.allSatisfy { $0.outcome == outcome },
            file: file,
            line: line
        )
        XCTAssertFalse(report.automaticRetryAllowed, file: file, line: line)
    }

    private struct Fixture {
        let databaseURL: URL
        let binding: CodexGhostRepairCategoryAPreparedRepairBinding
        let publicChallenge: CodexGhostRepairCategoryARepairChallenge
        let freshEvidence: CodexGhostRepairCategoryAFreshExecutionEvidence

        init() throws {
            let support = M3eCategoryATestFixture()
            let draft = try support.draft()
            let review = try support.review(draft: draft)
            let challenge = try support.challenge(draft: draft, review: review)
            binding = try .init(
                savedPreviewRequestID: UUID(
                    uuidString: "99999999-8888-4777-8666-555555555555"
                )!,
                draft: draft,
                review: review,
                challenge: challenge
            )
            publicChallenge = try .init(
                operationID: binding.operationID,
                savedPreviewRequestID: binding.savedPreviewRequestID,
                snapshotReference: binding.snapshotReference,
                snapshotManifestHash: binding.snapshotManifestHash,
                snapshotSourceFingerprintHash:
                    binding.snapshotSourceFingerprintHash,
                preparedBindingDigest: binding.bindingDigest,
                targetThreadIDs: challenge.targetThreadIDs,
                buildIdentifier: challenge.buildIdentifier,
                draftDigest: challenge.draftDigest,
                reviewDigest: challenge.reviewDigest,
                challengeDigest: challenge.challengeDigest,
                confirmationToken: challenge.confirmationToken,
                generatedAt: Date(
                    timeIntervalSince1970:
                        Double(challenge.generatedAtMilliseconds) / 1_000
                ),
                expiresAt: Date(
                    timeIntervalSince1970:
                        Double(challenge.expiresAtMilliseconds) / 1_000
                )
            )
            let baseFresh = try support.freshEvidence(
                draft: draft,
                review: review
            )
            freshEvidence = try .init(
                items: baseFresh.items,
                protectionEvidenceHash: baseFresh.protectionEvidenceHash,
                protectionComplete: baseFresh.protectionComplete,
                operationalGateEvidenceHash:
                    baseFresh.operationalGateEvidenceHash,
                operationalGateClear: baseFresh.operationalGateClear,
                databaseExpectations: baseFresh.databaseExpectations,
                freshAuthority: baseFresh.freshAuthority,
                observedAtMilliseconds: 2_500
            )
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agent-session-manager-m3i-c-\(UUID().uuidString)"
                )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            databaseURL = directory.appendingPathComponent("manager.sqlite3")
            let store = try SQLiteStateStore(databaseURL: databaseURL)
            try store.saveCodexGhostRepairCategoryAPreparedBinding(binding)
            store.close()
        }

        func coordinator(
            mutator: Mutator,
            includeFreshEvidence: Bool = true
        ) throws -> CodexGhostRepairCategoryARepairExecutionCoordinator {
            return .init(
                reviewCoordinator: ReviewCoordinator(),
                journal: CodexGhostRepairCategoryAPackagedExecutionJournal(
                    storeProvider: {
                        try SQLiteStateStore(databaseURL: databaseURL)
                    }
                ),
                freshCollector: FreshCollector(
                    evidence: includeFreshEvidence ? freshEvidence : nil
                ),
                mutator: mutator,
                nowMilliseconds: { 2_500 }
            )
        }

        func executionRequest()
            -> CodexGhostRepairCategoryARepairExecutionRequest
        {
            .init(
                requestID: UUID(),
                challenge: publicChallenge,
                exactConfirmationToken: publicChallenge.confirmationToken
            )
        }

        func operation() throws
            -> CodexGhostRepairCategoryAExecutionOperationState?
        {
            let store = try SQLiteStateStore(databaseURL: databaseURL)
            defer { store.close() }
            return try store.codexGhostRepairCategoryAOperation(
                operationID: binding.operationID
            )
        }
    }
}

private actor FreshCollector:
    CodexGhostRepairCategoryARepairFreshEvidenceCollecting
{
    let evidence: CodexGhostRepairCategoryAFreshExecutionEvidence?

    init(evidence: CodexGhostRepairCategoryAFreshExecutionEvidence?) {
        self.evidence = evidence
    }

    func collect(
        binding _: CodexGhostRepairCategoryAPreparedRepairBinding
    ) -> CodexGhostRepairCategoryAFreshExecutionEvidence? { evidence }
}

private actor Mutator: CodexGhostRepairCategoryARepairMutating {
    private let execution: CodexGhostRepairCategoryARepairExecutionObservation
    private let recovery: CodexGhostRepairCategoryARepairExecutionObservation
    private let throwDuringExecution: Bool
    private var executions = 0
    private var recoveries = 0

    init(
        execution: CodexGhostRepairCategoryARepairExecutionObservation,
        recovery: CodexGhostRepairCategoryARepairExecutionObservation? = nil,
        throwDuringExecution: Bool = false
    ) {
        self.execution = execution
        self.recovery = recovery ?? execution
        self.throwDuringExecution = throwDuringExecution
    }

    func executeOnce(
        binding _: CodexGhostRepairCategoryAPreparedRepairBinding,
        claim _: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) throws -> CodexGhostRepairCategoryARepairExecutionObservation {
        executions += 1
        if throwDuringExecution { throw TestError.interrupted }
        return execution
    }

    func recoverByReadback(
        binding _: CodexGhostRepairCategoryAPreparedRepairBinding,
        claim _: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) -> CodexGhostRepairCategoryARepairExecutionObservation {
        recoveries += 1
        return recovery
    }

    func executionCount() -> Int { executions }
    func recoveryCount() -> Int { recoveries }
}

private actor ReviewCoordinator: CodexGhostRepairCategoryARepairCoordinator {
    nonisolated let capabilities =
        CodexGhostRepairCategoryARepairCapabilities.packagedReviewOnly

    func prepareReview(
        request _: CodexGhostRepairCategoryARepairReviewRequest
    ) -> CodexGhostRepairCategoryARepairReviewOutcome {
        .unavailable(message: "unused")
    }

    func confirmAndRepair(
        request _: CodexGhostRepairCategoryARepairExecutionRequest
    ) -> CodexGhostRepairCategoryARepairExecutionOutcome {
        .unavailable(message: "unused")
    }
}

private actor ReviewCollector:
    CodexGhostRepairCategoryARepairReviewMaterialCollecting
{
    let outcome: CodexGhostRepairCategoryARepairReviewMaterialOutcome

    init(outcome: CodexGhostRepairCategoryARepairReviewMaterialOutcome) {
        self.outcome = outcome
    }

    func collect(
        draft _: CodexGhostRepairCategoryAExecutionDraft
    ) -> CodexGhostRepairCategoryARepairReviewMaterialOutcome { outcome }
}

private enum TestError: Error { case interrupted }
