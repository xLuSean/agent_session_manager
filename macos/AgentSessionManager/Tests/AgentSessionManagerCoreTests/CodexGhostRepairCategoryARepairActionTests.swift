@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairCategoryARepairActionTests: XCTestCase {
#if AGENT_SESSION_MANAGER_RESEARCH
    func testDefaultFactoryIsBlockedAndPerformsNoRepair() async throws {
        let coordinator = CodexGhostRepairCategoryARepairCoordinatorFactory
            .packagedDefaultBlocked()
        XCTAssertEqual(coordinator.capabilities, .unavailable)
        XCTAssertFalse(coordinator.capabilities.reviewAvailable)
        XCTAssertFalse(coordinator.capabilities.executionAvailable)
        XCTAssertFalse(coordinator.capabilities.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.automaticRetryAllowed)

        let review = await coordinator.prepareReview(
            request: .init(
                requestID: UUID(),
                savedPreviewRequestID: UUID()
            )
        )
        guard case .unavailable = review else {
            return XCTFail("Expected the packaged default to block review")
        }

        let execution = await coordinator.confirmAndRepair(
            request: .init(
                requestID: UUID(),
                challenge: try challenge(),
                exactConfirmationToken: "M3A-REPAIR-AAAAAAAAAAAA"
            )
        )
        guard case .unavailable = execution else {
            return XCTFail("Expected the packaged default to block execution")
        }
    }
#endif

    func testChallengeFreezesExactSortedOneOrTwoTargets() throws {
        let value = try challenge()
        XCTAssertEqual(value.targetThreadIDs, [targetA, targetB])
        XCTAssertFalse(value.confirmationAuthority)
        XCTAssertFalse(value.repairMutationAuthority)
        XCTAssertFalse(value.automaticRetryAllowed)

        XCTAssertThrowsError(
            try challenge(targets: [targetB, targetA])
        )
        XCTAssertThrowsError(
            try challenge(targets: [targetA, targetA])
        )
        XCTAssertThrowsError(
            try challenge(targets: [targetA, targetB, UUID().uuidString])
        )
        XCTAssertThrowsError(
            try challenge(token: "M3A-REPAIR-aaaaaaaaaaaa")
        )
        XCTAssertThrowsError(
            try challenge(token: "M3A-REPAIR-ZZZZZZZZZZZZ")
        )
    }

    func testExecutionRequestAndReportNeverGrantRetryRestoreOrCleanup()
        throws
    {
        let challenge = try challenge(targets: [targetA])
        let request = CodexGhostRepairCategoryARepairExecutionRequest(
            requestID: UUID(),
            challenge: challenge,
            exactConfirmationToken: challenge.confirmationToken
        )
        XCTAssertFalse(request.automaticRetryAllowed)
        XCTAssertFalse(request.restoreAuthority)
        XCTAssertFalse(request.cleanupAuthority)

        let report = try CodexGhostRepairCategoryARepairReport(
            operationID: challenge.operationID,
            outcome: .unknown,
            itemOutcomes: [
                .init(threadID: targetA, outcome: .unknown),
            ],
            reportDigest: digest("d")
        )
        XCTAssertFalse(report.automaticRetryAllowed)
        XCTAssertFalse(report.restoreAuthority)
        XCTAssertFalse(report.cleanupAuthority)

        XCTAssertThrowsError(
            try CodexGhostRepairCategoryARepairReport(
                operationID: challenge.operationID,
                outcome: .success,
                itemOutcomes: [
                    .init(threadID: targetA, outcome: .unknown),
                ],
                reportDigest: digest("e")
            )
        )
    }

    func testCapabilityVocabularyCannotWidenAuthority() {
        for capabilities in [
            CodexGhostRepairCategoryARepairCapabilities.unavailable,
            .packagedDefaultBlocked,
            .testOwned,
        ] {
            XCTAssertFalse(capabilities.acceptsCallerPath)
            XCTAssertFalse(capabilities.automaticRetryAllowed)
            XCTAssertFalse(capabilities.restoreAuthority)
            XCTAssertFalse(capabilities.cleanupAuthority)
            XCTAssertFalse(capabilities.effect.acceptsCallerPath)
            XCTAssertFalse(capabilities.effect.supportsAutomaticRetry)
        }
    }

    private let targetA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let targetB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"

    private func challenge(
        targets: [String]? = nil,
        token: String = "M3A-REPAIR-AAAAAAAAAAAA"
    ) throws -> CodexGhostRepairCategoryARepairChallenge {
        try .init(
            operationID: UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!,
            savedPreviewRequestID: UUID(
                uuidString: "11111111-2222-4333-8444-555555555555"
            )!,
            snapshotReference: "fb3f9168-75db-471b-aa9b-cd8bcea36c03",
            snapshotManifestHash: digest("d"),
            snapshotSourceFingerprintHash: digest("e"),
            preparedBindingDigest: digest("f"),
            targetThreadIDs: targets ?? [targetA, targetB],
            buildIdentifier: "test-build",
            draftDigest: digest("a"),
            reviewDigest: digest("b"),
            challengeDigest: digest("c"),
            confirmationToken: token,
            generatedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_900)
        )
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}
