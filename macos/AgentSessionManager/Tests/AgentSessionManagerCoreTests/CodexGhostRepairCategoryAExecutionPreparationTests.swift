@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairCategoryAExecutionPreparationTests: XCTestCase {
    private let fixture = M3eCategoryATestFixture()

    func testChallengeFreezesExactTwoItemReviewWithoutGrantingAuthority()
        throws
    {
        let draft = try fixture.draft()
        let review = try fixture.review(draft: draft, catalogRevision: 1_000)
        let challenge = try fixture.challenge(draft: draft, review: review)

        try challenge.validateDigest()
        XCTAssertEqual(challenge.targetThreadIDs, [fixture.targetA, fixture.targetB])
        XCTAssertEqual(challenge.reviewDigest, review.reviewDigest)
        XCTAssertTrue(challenge.confirmationToken.hasPrefix("M3A-REPAIR-"))
        XCTAssertFalse(challenge.confirmationAuthority)
        XCTAssertFalse(challenge.repairMutationAuthority)
        XCTAssertFalse(challenge.filesystemAuthority)
        XCTAssertFalse(challenge.codexSQLiteAuthority)
    }

    func testChallengeBlocksIncompleteProtectionAndOperationalGate() throws {
        let draft = try fixture.draft()
        let incomplete = try fixture.review(
            draft: draft,
            protectionComplete: false
        )
        let blockedGate = try fixture.review(
            draft: draft,
            operationalGateClear: false
        )

        XCTAssertEqual(
            CodexGhostRepairCategoryAExecutionPreparation.prepareChallenge(
                draft: draft,
                review: incomplete,
                buildIdentifier: "tests",
                observedAtMilliseconds: 2_200
            ),
            .blocked(.protectionUnavailable)
        )
        XCTAssertEqual(
            CodexGhostRepairCategoryAExecutionPreparation.prepareChallenge(
                draft: draft,
                review: blockedGate,
                buildIdentifier: "tests",
                observedAtMilliseconds: 2_200
            ),
            .blocked(.operationalGateBlocked)
        )
    }

    func testWrongOrExpiredConfirmationCannotCreateReceipt() throws {
        let draft = try fixture.draft()
        let review = try fixture.review(draft: draft)
        let challenge = try fixture.challenge(draft: draft, review: review)

        XCTAssertThrowsError(
            try CodexGhostRepairCategoryAExecutionPreparation
                .consumeAuthorization(
                    challenge: challenge,
                    confirmationToken: "wrong",
                    confirmedAtMilliseconds: 2_300
                )
        ) { error in
            XCTAssertEqual(
                error as? PersistentStateError,
                .confirmationMismatch
            )
        }
        XCTAssertThrowsError(
            try CodexGhostRepairCategoryAExecutionPreparation
                .consumeAuthorization(
                    challenge: challenge,
                    confirmationToken: challenge.confirmationToken,
                    confirmedAtMilliseconds: challenge.expiresAtMilliseconds
                )
        )
    }

    func testFreshAuthorityCountersMayChangeButExactRowsAndProtectionMayNot()
        throws
    {
        let draft = try fixture.draft()
        let review = try fixture.review(draft: draft, catalogRevision: 1_000)
        let challenge = try fixture.challenge(draft: draft, review: review)
        let receipt = try fixture.receipt(challenge: challenge)
        let claim = try fixture.claim(
            draft: draft,
            review: review,
            challenge: challenge,
            receipt: receipt
        )

        try claim.validateDigest()
        XCTAssertEqual(claim.freshEvidence.freshAuthority.catalogRevision, 2_000)
        XCTAssertNotEqual(
            claim.freshEvidence.freshAuthority.catalogRevision,
            review.authorityAudit.catalogRevision
        )
        XCTAssertFalse(claim.createsBackup)
        XCTAssertFalse(claim.repairMutationAuthority)
        XCTAssertFalse(claim.automaticRetryAllowed)

        let drifted = try CodexGhostRepairCategoryAFreshExecutionEvidence(
            items: claim.freshEvidence.items,
            protectionEvidenceHash: fixture.digest("0"),
            protectionComplete: true,
            operationalGateEvidenceHash: fixture.digest("8"),
            operationalGateClear: true,
            databaseExpectations: draft.databaseExpectations,
            freshAuthority: claim.freshEvidence.freshAuthority,
            observedAtMilliseconds: 2_400
        )
        XCTAssertThrowsError(
            try CodexGhostRepairCategoryAExecutionPreparation
                .prepareClaimEvidence(
                    draft: draft,
                    review: review,
                    challenge: challenge,
                    receipt: receipt,
                    executionSnapshotManifestHash: fixture.digest("9"),
                    freshEvidence: drifted,
                    executionAtMilliseconds: 2_600,
                    claimedAtMilliseconds: 2_500
                )
        )
    }

    func testTerminalVocabularyPreservesUnknownAndNeverAllowsRetry() throws {
        let draft = try fixture.draft()
        let review = try fixture.review(draft: draft)
        let challenge = try fixture.challenge(draft: draft, review: review)
        let receipt = try fixture.receipt(challenge: challenge)
        let claim = try fixture.claim(
            draft: draft,
            review: review,
            challenge: challenge,
            receipt: receipt
        )
        let report = try CodexGhostRepairCategoryAExecutionPreparation
            .terminalReport(
                challenge: challenge,
                receipt: receipt,
                claim: claim,
                outcome: .unknown,
                mutationAttemptedOnce: true,
                completedAtMilliseconds: 2_700
            )

        XCTAssertEqual(report.outcome, .unknown)
        XCTAssertEqual(report.itemOutcomes, [.unknown, .unknown])
        XCTAssertFalse(report.automaticRetryAllowed)
        XCTAssertFalse(report.automaticRestoreAllowed)
        XCTAssertFalse(
            CodexGhostRepairCategoryAExecutionPreparation.capabilities
                .repairMutationAuthority
        )
    }
}
