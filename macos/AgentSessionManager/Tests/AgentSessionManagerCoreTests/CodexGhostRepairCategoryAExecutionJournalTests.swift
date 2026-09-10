@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairCategoryAExecutionJournalTests: XCTestCase {
    private let fixture = M3eCategoryATestFixture()

    func testOneShotLifecyclePersistsAcrossColdReadbackAndNeverReplays()
        throws
    {
        let values = try makeValues()
        let databaseURL = try temporaryDatabaseURL()
        var store: SQLiteStateStore? = try SQLiteStateStore(
            databaseURL: databaseURL
        )

        let prepared = try store?.saveCodexGhostRepairCategoryAChallenge(
            values.challenge
        )
        XCTAssertEqual(prepared?.status, .prepared)
        XCTAssertThrowsError(
            try store?.consumeCodexGhostRepairCategoryAAuthorization(
                operationID: fixture.operationID,
                confirmationToken: "wrong",
                confirmedAtMilliseconds: 2_300
            )
        )
        XCTAssertNil(
            try store?.codexGhostRepairCategoryAOperation(
                operationID: fixture.operationID
            )?.receipt
        )

        guard case let .consumed(receipt) = try store?
            .consumeCodexGhostRepairCategoryAAuthorization(
                operationID: fixture.operationID,
                confirmationToken: values.challenge.confirmationToken,
                confirmedAtMilliseconds: 2_300
            ) else {
            return XCTFail("Expected one consumed authorization")
        }
        XCTAssertEqual(receipt, values.receipt)
        guard case let .existingReceipt(existingReceipt) = try store?
            .consumeCodexGhostRepairCategoryAAuthorization(
                operationID: fixture.operationID,
                confirmationToken: values.challenge.confirmationToken,
                confirmedAtMilliseconds: 2_300
            ) else {
            return XCTFail("Expected durable authorization readback")
        }
        XCTAssertEqual(existingReceipt, receipt)

        store?.close()
        store = try SQLiteStateStore(databaseURL: databaseURL)
        XCTAssertEqual(
            try store?.codexGhostRepairCategoryAOperation(
                operationID: fixture.operationID
            )?.status,
            .authorized
        )

        guard case let .claimed(claim) = try store?
            .claimCodexGhostRepairCategoryAExecution(values.claim) else {
            return XCTFail("Expected first durable claim")
        }
        XCTAssertEqual(claim, values.claim)
        guard case let .recoveryRequired(recoveredClaim) = try store?
            .claimCodexGhostRepairCategoryAExecution(values.claim) else {
            return XCTFail("Expected readback-only recovery after claim")
        }
        XCTAssertEqual(recoveredClaim, claim)

        let report = try CodexGhostRepairCategoryAExecutionPreparation
            .terminalReport(
                challenge: values.challenge,
                receipt: receipt,
                claim: claim,
                outcome: .unknown,
                mutationAttemptedOnce: true,
                completedAtMilliseconds: 2_700
            )
        try store?.finalizeCodexGhostRepairCategoryAExecution(report)
        try store?.finalizeCodexGhostRepairCategoryAExecution(report)

        store?.close()
        store = try SQLiteStateStore(databaseURL: databaseURL)
        let terminal = try store?.codexGhostRepairCategoryAOperation(
            operationID: fixture.operationID
        )
        XCTAssertEqual(terminal?.status, .terminal)
        XCTAssertEqual(terminal?.report, report)
        XCTAssertFalse(terminal?.automaticRetryAllowed ?? true)
        XCTAssertFalse(terminal?.repairMutationAuthority ?? true)
        guard case let .existingReport(recoveredReport) = try store?
            .claimCodexGhostRepairCategoryAExecution(values.claim) else {
            return XCTFail("Expected terminal readback, not a second claim")
        }
        XCTAssertEqual(recoveredReport, report)
        store?.close()
    }

    func testPreclaimStopIsTerminalNotAttemptedAndCannotLaterClaim() throws {
        let values = try makeValues()
        let databaseURL = try temporaryDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        _ = try store.saveCodexGhostRepairCategoryAChallenge(values.challenge)
        guard case let .consumed(receipt) = try store
            .consumeCodexGhostRepairCategoryAAuthorization(
                operationID: fixture.operationID,
                confirmationToken: values.challenge.confirmationToken,
                confirmedAtMilliseconds: 2_300
            ) else {
            return XCTFail("Expected authorization")
        }
        let report = try CodexGhostRepairCategoryAExecutionPreparation
            .terminalReport(
                challenge: values.challenge,
                receipt: receipt,
                claim: nil,
                outcome: .notAttempted,
                mutationAttemptedOnce: false,
                completedAtMilliseconds: 2_450
            )
        try store.finalizeCodexGhostRepairCategoryAExecution(report)

        XCTAssertEqual(
            try store.codexGhostRepairCategoryAOperation(
                operationID: fixture.operationID
            )?.report,
            report
        )
        guard case let .existingReport(existing) = try store
            .claimCodexGhostRepairCategoryAExecution(values.claim) else {
            return XCTFail("Expected terminal stop to block later claim")
        }
        XCTAssertEqual(existing, report)
    }

    func testDifferentEvidenceCannotReuseOperationOrTerminalReport() throws {
        let values = try makeValues()
        let databaseURL = try temporaryDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        _ = try store.saveCodexGhostRepairCategoryAChallenge(values.challenge)
        guard case let .consumed(receipt) = try store
            .consumeCodexGhostRepairCategoryAAuthorization(
                operationID: fixture.operationID,
                confirmationToken: values.challenge.confirmationToken,
                confirmedAtMilliseconds: 2_300
            ) else {
            return XCTFail("Expected authorization")
        }
        _ = try store.claimCodexGhostRepairCategoryAExecution(values.claim)
        let report = try CodexGhostRepairCategoryAExecutionPreparation
            .terminalReport(
                challenge: values.challenge,
                receipt: receipt,
                claim: values.claim,
                outcome: .success,
                mutationAttemptedOnce: true,
                completedAtMilliseconds: 2_700
            )
        try store.finalizeCodexGhostRepairCategoryAExecution(report)

        let different = try CodexGhostRepairCategoryAExecutionPreparation
            .terminalReport(
                challenge: values.challenge,
                receipt: receipt,
                claim: values.claim,
                outcome: .explicitFailure,
                mutationAttemptedOnce: true,
                completedAtMilliseconds: 2_700
            )
        XCTAssertThrowsError(
            try store.finalizeCodexGhostRepairCategoryAExecution(different)
        )
    }

    func testPreparedBindingRequiresClaimToUseExactFrozenSnapshotBackup()
        throws
    {
        let values = try makeValues()
        let binding = try CodexGhostRepairCategoryAPreparedRepairBinding(
            savedPreviewRequestID: UUID(
                uuidString: "99999999-8888-4777-8666-555555555555"
            )!,
            draft: values.draft,
            review: values.review,
            challenge: values.challenge
        )
        let store = try SQLiteStateStore(
            databaseURL: temporaryDatabaseURL()
        )
        defer { store.close() }
        try store.saveCodexGhostRepairCategoryAPreparedBinding(binding)
        guard case let .consumed(receipt) = try store
            .consumeCodexGhostRepairCategoryAAuthorization(
                operationID: fixture.operationID,
                confirmationToken: values.challenge.confirmationToken,
                confirmedAtMilliseconds: 2_300
            ) else {
            return XCTFail("Expected exact authorization")
        }

        XCTAssertThrowsError(
            try store.claimCodexGhostRepairCategoryAExecution(values.claim)
        )
        let exactClaim = try CodexGhostRepairCategoryAExecutionPreparation
            .prepareClaimEvidence(
                draft: values.draft,
                review: values.review,
                challenge: values.challenge,
                receipt: receipt,
                executionSnapshotManifestHash:
                    values.draft.snapshotManifestHash,
                freshEvidence: fixture.freshEvidence(
                    draft: values.draft,
                    review: values.review
                ),
                executionAtMilliseconds: 2_600,
                claimedAtMilliseconds: 2_500
            )
        guard case let .claimed(readback) = try store
            .claimCodexGhostRepairCategoryAExecution(exactClaim) else {
            return XCTFail("Expected exact backup-bound claim")
        }
        XCTAssertEqual(readback, exactClaim)
    }

    private func makeValues() throws -> (
        draft: CodexGhostRepairCategoryAExecutionDraft,
        review: CodexGhostRepairCategoryAExecutionReviewEvidence,
        challenge: CodexGhostRepairCategoryAConfirmationChallenge,
        receipt: CodexGhostRepairCategoryAAuthorizationReceipt,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) {
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
        return (draft, review, challenge, receipt, claim)
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-session-manager-m3e-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("manager.sqlite3")
    }
}
