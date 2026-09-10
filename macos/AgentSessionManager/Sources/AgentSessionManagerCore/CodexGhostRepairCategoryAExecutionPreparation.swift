import Foundation

enum CodexGhostRepairCategoryAExecutionPreparationBlocker:
    String,
    Codable,
    Equatable,
    Sendable
{
    case invalidDraft
    case draftExpired
    case invalidReview
    case targetDrift
    case protectionUnavailable
    case operationalGateBlocked
    case schemaDrift
}

struct CodexGhostRepairCategoryAExecutionReviewItem:
    Codable,
    Hashable,
    Sendable
{
    let threadID: String
    let catalogRowDigest: String
}

private struct CodexGhostRepairCategoryAExecutionReviewPayload:
    Codable,
    Hashable
{
    let reviewID: UUID
    let items: [CodexGhostRepairCategoryAExecutionReviewItem]
    let protectionEvidenceHash: String
    let protectionComplete: Bool
    let operationalGateEvidenceHash: String
    let operationalGateClear: Bool
    let databaseExpectations:
        [CodexGhostRepairCategoryADatabaseExpectation]
    let authorityAudit: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let observedAtMilliseconds: Int64
}

/// Privacy-safe, caller-supplied evidence for a deterministic M3e review.
///
/// The authority values remain audit provenance. A later execution claim must
/// carry separately collected fresh authority and must not require equality to
/// these Preview/review-time counters.
struct CodexGhostRepairCategoryAExecutionReviewEvidence:
    Codable,
    Hashable,
    Sendable
{
    let reviewID: UUID
    let items: [CodexGhostRepairCategoryAExecutionReviewItem]
    let protectionEvidenceHash: String
    let protectionComplete: Bool
    let operationalGateEvidenceHash: String
    let operationalGateClear: Bool
    let databaseExpectations:
        [CodexGhostRepairCategoryADatabaseExpectation]
    let authorityAudit: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let observedAtMilliseconds: Int64
    let reviewDigest: String

    init(
        reviewID: UUID,
        items: [CodexGhostRepairCategoryAExecutionReviewItem],
        protectionEvidenceHash: String,
        protectionComplete: Bool,
        operationalGateEvidenceHash: String,
        operationalGateClear: Bool,
        databaseExpectations:
            [CodexGhostRepairCategoryADatabaseExpectation],
        authorityAudit: CodexGhostRepairSnapshotAnalysisAuthorityEvidence,
        observedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairCategoryAExecutionReviewPayload(
            reviewID: reviewID,
            items: items,
            protectionEvidenceHash: protectionEvidenceHash,
            protectionComplete: protectionComplete,
            operationalGateEvidenceHash: operationalGateEvidenceHash,
            operationalGateClear: operationalGateClear,
            databaseExpectations: databaseExpectations,
            authorityAudit: authorityAudit,
            observedAtMilliseconds: observedAtMilliseconds
        )
        self.reviewID = reviewID
        self.items = items
        self.protectionEvidenceHash = protectionEvidenceHash
        self.protectionComplete = protectionComplete
        self.operationalGateEvidenceHash = operationalGateEvidenceHash
        self.operationalGateClear = operationalGateClear
        self.databaseExpectations = databaseExpectations
        self.authorityAudit = authorityAudit
        self.observedAtMilliseconds = observedAtMilliseconds
        reviewDigest = try CodexGhostRepairHasher.hash(payload)
    }

    func validateDigest() throws {
        let payload = CodexGhostRepairCategoryAExecutionReviewPayload(
            reviewID: reviewID,
            items: items,
            protectionEvidenceHash: protectionEvidenceHash,
            protectionComplete: protectionComplete,
            operationalGateEvidenceHash: operationalGateEvidenceHash,
            operationalGateClear: operationalGateClear,
            databaseExpectations: databaseExpectations,
            authorityAudit: authorityAudit,
            observedAtMilliseconds: observedAtMilliseconds
        )
        guard try CodexGhostRepairHasher.hash(payload) == reviewDigest else {
            throw CodexGhostRepairError.invalidPlan(
                "M3e execution review digest mismatch."
            )
        }
    }
}

private struct CodexGhostRepairCategoryAConfirmationChallengePayload:
    Codable,
    Hashable
{
    let operationID: UUID
    let draftDigest: String
    let reviewDigest: String
    let buildIdentifier: String
    let targetThreadIDs: [String]
    let generatedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
}

struct CodexGhostRepairCategoryAConfirmationChallenge:
    Codable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let draftDigest: String
    let reviewDigest: String
    let buildIdentifier: String
    let targetThreadIDs: [String]
    let generatedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let challengeDigest: String
    let confirmationToken: String

    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }
    var filesystemAuthority: Bool { false }
    var codexSQLiteAuthority: Bool { false }

    fileprivate init(
        operationID: UUID,
        draftDigest: String,
        reviewDigest: String,
        buildIdentifier: String,
        targetThreadIDs: [String],
        generatedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairCategoryAConfirmationChallengePayload(
            operationID: operationID,
            draftDigest: draftDigest,
            reviewDigest: reviewDigest,
            buildIdentifier: buildIdentifier,
            targetThreadIDs: targetThreadIDs,
            generatedAtMilliseconds: generatedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
        self.operationID = operationID
        self.draftDigest = draftDigest
        self.reviewDigest = reviewDigest
        self.buildIdentifier = buildIdentifier
        self.targetThreadIDs = targetThreadIDs
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        challengeDigest = try CodexGhostRepairHasher.hash(payload)
        confirmationToken = Self.token(for: challengeDigest)
    }

    func validateDigest() throws {
        let payload = CodexGhostRepairCategoryAConfirmationChallengePayload(
            operationID: operationID,
            draftDigest: draftDigest,
            reviewDigest: reviewDigest,
            buildIdentifier: buildIdentifier,
            targetThreadIDs: targetThreadIDs,
            generatedAtMilliseconds: generatedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
        let expectedDigest = try CodexGhostRepairHasher.hash(payload)
        guard expectedDigest == challengeDigest,
              confirmationToken == Self.token(for: expectedDigest) else {
            throw CodexGhostRepairError.invalidPlan(
                "M3e confirmation challenge digest mismatch."
            )
        }
    }

    private static func token(for digest: String) -> String {
        let compact = digest.replacingOccurrences(of: "sha256:", with: "")
        return "M3A-REPAIR-" + compact.prefix(12).uppercased()
    }
}

enum CodexGhostRepairCategoryAConfirmationChallengeOutcome:
    Equatable,
    Sendable
{
    case challenge(CodexGhostRepairCategoryAConfirmationChallenge)
    case blocked(CodexGhostRepairCategoryAExecutionPreparationBlocker)
}

private struct CodexGhostRepairCategoryAAuthorizationReceiptPayload:
    Codable,
    Hashable
{
    let operationID: UUID
    let challengeDigest: String
    let confirmationTokenHash: String
    let confirmedAtMilliseconds: Int64
}

struct CodexGhostRepairCategoryAAuthorizationReceipt:
    Codable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let challengeDigest: String
    let confirmationTokenHash: String
    let confirmedAtMilliseconds: Int64
    let receiptDigest: String

    /// The receipt consumes one user authorization but cannot perform repair.
    var repairMutationAuthority: Bool { false }
    var automaticRetryAllowed: Bool { false }

    fileprivate init(
        challenge: CodexGhostRepairCategoryAConfirmationChallenge,
        confirmedAtMilliseconds: Int64
    ) throws {
        let tokenHash = try CodexGhostRepairHasher.hash(
            challenge.confirmationToken
        )
        let payload = CodexGhostRepairCategoryAAuthorizationReceiptPayload(
            operationID: challenge.operationID,
            challengeDigest: challenge.challengeDigest,
            confirmationTokenHash: tokenHash,
            confirmedAtMilliseconds: confirmedAtMilliseconds
        )
        operationID = payload.operationID
        challengeDigest = payload.challengeDigest
        confirmationTokenHash = payload.confirmationTokenHash
        self.confirmedAtMilliseconds = payload.confirmedAtMilliseconds
        receiptDigest = try CodexGhostRepairHasher.hash(payload)
    }

    func validateDigest() throws {
        let payload = CodexGhostRepairCategoryAAuthorizationReceiptPayload(
            operationID: operationID,
            challengeDigest: challengeDigest,
            confirmationTokenHash: confirmationTokenHash,
            confirmedAtMilliseconds: confirmedAtMilliseconds
        )
        guard try CodexGhostRepairHasher.hash(payload) == receiptDigest else {
            throw CodexGhostRepairError.invalidPlan(
                "M3e authorization receipt digest mismatch."
            )
        }
    }
}

struct CodexGhostRepairCategoryAFreshExecutionItem:
    Codable,
    Hashable,
    Sendable
{
    let threadID: String
    let catalogRowDigest: String
}

private struct CodexGhostRepairCategoryAFreshExecutionEvidencePayload:
    Codable,
    Hashable
{
    let items: [CodexGhostRepairCategoryAFreshExecutionItem]
    let protectionEvidenceHash: String
    let protectionComplete: Bool
    let operationalGateEvidenceHash: String
    let operationalGateClear: Bool
    let databaseExpectations:
        [CodexGhostRepairCategoryADatabaseExpectation]
    let freshAuthority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let observedAtMilliseconds: Int64
}

struct CodexGhostRepairCategoryAFreshExecutionEvidence:
    Codable,
    Hashable,
    Sendable
{
    let items: [CodexGhostRepairCategoryAFreshExecutionItem]
    let protectionEvidenceHash: String
    let protectionComplete: Bool
    let operationalGateEvidenceHash: String
    let operationalGateClear: Bool
    let databaseExpectations:
        [CodexGhostRepairCategoryADatabaseExpectation]
    let freshAuthority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let observedAtMilliseconds: Int64
    let evidenceDigest: String

    init(
        items: [CodexGhostRepairCategoryAFreshExecutionItem],
        protectionEvidenceHash: String,
        protectionComplete: Bool,
        operationalGateEvidenceHash: String,
        operationalGateClear: Bool,
        databaseExpectations:
            [CodexGhostRepairCategoryADatabaseExpectation],
        freshAuthority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence,
        observedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairCategoryAFreshExecutionEvidencePayload(
            items: items,
            protectionEvidenceHash: protectionEvidenceHash,
            protectionComplete: protectionComplete,
            operationalGateEvidenceHash: operationalGateEvidenceHash,
            operationalGateClear: operationalGateClear,
            databaseExpectations: databaseExpectations,
            freshAuthority: freshAuthority,
            observedAtMilliseconds: observedAtMilliseconds
        )
        self.items = items
        self.protectionEvidenceHash = protectionEvidenceHash
        self.protectionComplete = protectionComplete
        self.operationalGateEvidenceHash = operationalGateEvidenceHash
        self.operationalGateClear = operationalGateClear
        self.databaseExpectations = databaseExpectations
        self.freshAuthority = freshAuthority
        self.observedAtMilliseconds = observedAtMilliseconds
        evidenceDigest = try CodexGhostRepairHasher.hash(payload)
    }

    func validateDigest() throws {
        let payload = CodexGhostRepairCategoryAFreshExecutionEvidencePayload(
            items: items,
            protectionEvidenceHash: protectionEvidenceHash,
            protectionComplete: protectionComplete,
            operationalGateEvidenceHash: operationalGateEvidenceHash,
            operationalGateClear: operationalGateClear,
            databaseExpectations: databaseExpectations,
            freshAuthority: freshAuthority,
            observedAtMilliseconds: observedAtMilliseconds
        )
        guard try CodexGhostRepairHasher.hash(payload) == evidenceDigest else {
            throw CodexGhostRepairError.invalidPlan(
                "M3e fresh execution evidence digest mismatch."
            )
        }
    }
}

private struct CodexGhostRepairCategoryAExecutionClaimEvidencePayload:
    Codable,
    Hashable
{
    let operationID: UUID
    let draftDigest: String
    let receiptDigest: String
    let executionSnapshotManifestHash: String
    let freshEvidence: CodexGhostRepairCategoryAFreshExecutionEvidence
    let executionAtMilliseconds: Int64
    let claimedAtMilliseconds: Int64
}

struct CodexGhostRepairCategoryAExecutionClaimEvidence:
    Codable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let draftDigest: String
    let receiptDigest: String
    let executionSnapshotManifestHash: String
    let freshEvidence: CodexGhostRepairCategoryAFreshExecutionEvidence
    let executionAtMilliseconds: Int64
    let claimedAtMilliseconds: Int64
    let claimDigest: String

    var opensFilesystem: Bool { false }
    var opensCodexSQLite: Bool { false }
    var createsBackup: Bool { false }
    var repairMutationAuthority: Bool { false }
    var automaticRetryAllowed: Bool { false }

    fileprivate init(
        operationID: UUID,
        draftDigest: String,
        receiptDigest: String,
        executionSnapshotManifestHash: String,
        freshEvidence: CodexGhostRepairCategoryAFreshExecutionEvidence,
        executionAtMilliseconds: Int64,
        claimedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairCategoryAExecutionClaimEvidencePayload(
            operationID: operationID,
            draftDigest: draftDigest,
            receiptDigest: receiptDigest,
            executionSnapshotManifestHash: executionSnapshotManifestHash,
            freshEvidence: freshEvidence,
            executionAtMilliseconds: executionAtMilliseconds,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
        self.operationID = operationID
        self.draftDigest = draftDigest
        self.receiptDigest = receiptDigest
        self.executionSnapshotManifestHash = executionSnapshotManifestHash
        self.freshEvidence = freshEvidence
        self.executionAtMilliseconds = executionAtMilliseconds
        self.claimedAtMilliseconds = claimedAtMilliseconds
        claimDigest = try CodexGhostRepairHasher.hash(payload)
    }

    func validateDigest() throws {
        try freshEvidence.validateDigest()
        let payload = CodexGhostRepairCategoryAExecutionClaimEvidencePayload(
            operationID: operationID,
            draftDigest: draftDigest,
            receiptDigest: receiptDigest,
            executionSnapshotManifestHash: executionSnapshotManifestHash,
            freshEvidence: freshEvidence,
            executionAtMilliseconds: executionAtMilliseconds,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
        guard try CodexGhostRepairHasher.hash(payload) == claimDigest else {
            throw CodexGhostRepairError.invalidPlan(
                "M3e execution claim digest mismatch."
            )
        }
    }
}

private struct CodexGhostRepairCategoryAExecutionTerminalReportPayload:
    Codable,
    Hashable
{
    let operationID: UUID
    let draftDigest: String
    let receiptDigest: String
    let claimDigest: String?
    let outcome: CodexGhostRepairCategoryABatchOutcome
    let targetThreadIDs: [String]
    let mutationAttemptedOnce: Bool
    let completedAtMilliseconds: Int64
}

struct CodexGhostRepairCategoryAExecutionTerminalReport:
    Codable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let draftDigest: String
    let receiptDigest: String
    let claimDigest: String?
    let outcome: CodexGhostRepairCategoryABatchOutcome
    let targetThreadIDs: [String]
    let mutationAttemptedOnce: Bool
    let completedAtMilliseconds: Int64
    let reportDigest: String

    var itemOutcomes: [CodexGhostRepairCategoryAItemOutcome] {
        targetThreadIDs.map { _ in outcome.itemOutcome }
    }
    var automaticRetryAllowed: Bool { false }
    var automaticRestoreAllowed: Bool { false }

    fileprivate init(
        operationID: UUID,
        draftDigest: String,
        receiptDigest: String,
        claimDigest: String?,
        outcome: CodexGhostRepairCategoryABatchOutcome,
        targetThreadIDs: [String],
        mutationAttemptedOnce: Bool,
        completedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairCategoryAExecutionTerminalReportPayload(
            operationID: operationID,
            draftDigest: draftDigest,
            receiptDigest: receiptDigest,
            claimDigest: claimDigest,
            outcome: outcome,
            targetThreadIDs: targetThreadIDs,
            mutationAttemptedOnce: mutationAttemptedOnce,
            completedAtMilliseconds: completedAtMilliseconds
        )
        self.operationID = operationID
        self.draftDigest = draftDigest
        self.receiptDigest = receiptDigest
        self.claimDigest = claimDigest
        self.outcome = outcome
        self.targetThreadIDs = targetThreadIDs
        self.mutationAttemptedOnce = mutationAttemptedOnce
        self.completedAtMilliseconds = completedAtMilliseconds
        reportDigest = try CodexGhostRepairHasher.hash(payload)
    }

    func validateDigest() throws {
        let payload = CodexGhostRepairCategoryAExecutionTerminalReportPayload(
            operationID: operationID,
            draftDigest: draftDigest,
            receiptDigest: receiptDigest,
            claimDigest: claimDigest,
            outcome: outcome,
            targetThreadIDs: targetThreadIDs,
            mutationAttemptedOnce: mutationAttemptedOnce,
            completedAtMilliseconds: completedAtMilliseconds
        )
        guard try CodexGhostRepairHasher.hash(payload) == reportDigest,
              !targetThreadIDs.isEmpty,
              Set(targetThreadIDs).count == targetThreadIDs.count,
              !automaticRetryAllowed,
              !automaticRestoreAllowed,
              validOutcomeBinding else {
            throw CodexGhostRepairError.invalidPlan(
                "M3e terminal Report contract is invalid."
            )
        }
    }

    private var validOutcomeBinding: Bool {
        if claimDigest == nil {
            return outcome == .notAttempted && !mutationAttemptedOnce
        }
        switch outcome {
        case .success, .explicitFailure:
            return mutationAttemptedOnce
        case .unknown:
            return true
        case .notAttempted:
            return !mutationAttemptedOnce
        }
    }
}

struct CodexGhostRepairCategoryAExecutionPreparationCapabilities:
    Equatable,
    Sendable
{
    let maximumTargetCount = 2
    let categoryAOnly = true
    let previewAuthorityIsAuditOnly = true
    let separatesFreshExecutionAuthority = true
    let opensFilesystem = false
    let opensCodexSQLite = false
    let createsBackup = false
    let appWiringAvailable = false
    let repairMutationAuthority = false
    let automaticRetry = false
}

enum CodexGhostRepairCategoryAExecutionPreparation {
    static let capabilities =
        CodexGhostRepairCategoryAExecutionPreparationCapabilities()

    static func prepareChallenge(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        review: CodexGhostRepairCategoryAExecutionReviewEvidence,
        buildIdentifier: String,
        observedAtMilliseconds: Int64,
        lifetimeMilliseconds: Int64 = 15 * 60 * 1_000
    ) -> CodexGhostRepairCategoryAConfirmationChallengeOutcome {
        do {
            try draft.validateDigest()
        } catch {
            return .blocked(.invalidDraft)
        }
        do {
            try review.validateDigest()
        } catch {
            return .blocked(.invalidReview)
        }
        guard observedAtMilliseconds >= draft.preparedAtMilliseconds,
              observedAtMilliseconds < draft.expiresAtMilliseconds,
              lifetimeMilliseconds > 0 else {
            return .blocked(.draftExpired)
        }
        guard !buildIdentifier.isEmpty,
              review.observedAtMilliseconds <= observedAtMilliseconds,
              isDigest(review.protectionEvidenceHash),
              isDigest(review.operationalGateEvidenceHash) else {
            return .blocked(.invalidReview)
        }
        guard review.protectionComplete else {
            return .blocked(.protectionUnavailable)
        }
        guard review.operationalGateClear else {
            return .blocked(.operationalGateBlocked)
        }
        guard review.items == draft.itemChanges.map({
                  .init(
                      threadID: $0.threadID,
                      catalogRowDigest: $0.catalogRowDigest
                  )
              }) else {
            return .blocked(.targetDrift)
        }
        guard review.databaseExpectations == draft.databaseExpectations else {
            return .blocked(.schemaDrift)
        }
        let expires = min(
            draft.expiresAtMilliseconds,
            observedAtMilliseconds + lifetimeMilliseconds
        )
        do {
            return .challenge(try .init(
                operationID: draft.operationID,
                draftDigest: draft.draftDigest,
                reviewDigest: review.reviewDigest,
                buildIdentifier: buildIdentifier,
                targetThreadIDs: draft.targetThreadIDs,
                generatedAtMilliseconds: observedAtMilliseconds,
                expiresAtMilliseconds: expires
            ))
        } catch {
            return .blocked(.invalidDraft)
        }
    }

    static func consumeAuthorization(
        challenge: CodexGhostRepairCategoryAConfirmationChallenge,
        confirmationToken: String,
        confirmedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairCategoryAAuthorizationReceipt {
        try challenge.validateDigest()
        guard confirmationToken == challenge.confirmationToken else {
            throw PersistentStateError.confirmationMismatch
        }
        guard confirmedAtMilliseconds >= challenge.generatedAtMilliseconds,
              confirmedAtMilliseconds < challenge.expiresAtMilliseconds else {
            throw CodexGhostRepairError.previewExpired
        }
        return try .init(
            challenge: challenge,
            confirmedAtMilliseconds: confirmedAtMilliseconds
        )
    }

    static func prepareClaimEvidence(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        review: CodexGhostRepairCategoryAExecutionReviewEvidence,
        challenge: CodexGhostRepairCategoryAConfirmationChallenge,
        receipt: CodexGhostRepairCategoryAAuthorizationReceipt,
        executionSnapshotManifestHash: String,
        freshEvidence: CodexGhostRepairCategoryAFreshExecutionEvidence,
        executionAtMilliseconds: Int64,
        claimedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairCategoryAExecutionClaimEvidence {
        try draft.validateDigest()
        try review.validateDigest()
        try challenge.validateDigest()
        try receipt.validateDigest()
        try freshEvidence.validateDigest()
        guard draft.operationID == challenge.operationID,
              draft.draftDigest == challenge.draftDigest,
              review.reviewDigest == challenge.reviewDigest,
              receipt.operationID == challenge.operationID,
              receipt.challengeDigest == challenge.challengeDigest,
              receipt.confirmationTokenHash
                == (try CodexGhostRepairHasher.hash(
                    challenge.confirmationToken
                )),
              challenge.targetThreadIDs == draft.targetThreadIDs,
              freshEvidence.items == draft.itemChanges.map({
                  .init(
                      threadID: $0.threadID,
                      catalogRowDigest: $0.catalogRowDigest
                  )
              }),
              freshEvidence.databaseExpectations
                == draft.databaseExpectations,
              freshEvidence.protectionEvidenceHash
                == review.protectionEvidenceHash,
              freshEvidence.protectionComplete,
              freshEvidence.operationalGateClear,
              isDigest(freshEvidence.protectionEvidenceHash),
              isDigest(freshEvidence.operationalGateEvidenceHash),
              isDigest(executionSnapshotManifestHash),
              freshEvidence.observedAtMilliseconds
                >= receipt.confirmedAtMilliseconds,
              freshEvidence.observedAtMilliseconds
                <= claimedAtMilliseconds,
              claimedAtMilliseconds >= receipt.confirmedAtMilliseconds,
              claimedAtMilliseconds <= executionAtMilliseconds else {
            throw CodexGhostRepairError.authorityDrift
        }
        // Deliberately do not compare freshExecutionAuthority with
        // draft.authorityAudit or review-time authority counters.
        return try .init(
            operationID: draft.operationID,
            draftDigest: draft.draftDigest,
            receiptDigest: receipt.receiptDigest,
            executionSnapshotManifestHash: executionSnapshotManifestHash,
            freshEvidence: freshEvidence,
            executionAtMilliseconds: executionAtMilliseconds,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
    }

    static func terminalReport(
        challenge: CodexGhostRepairCategoryAConfirmationChallenge,
        receipt: CodexGhostRepairCategoryAAuthorizationReceipt,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence?,
        outcome: CodexGhostRepairCategoryABatchOutcome,
        mutationAttemptedOnce: Bool,
        completedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairCategoryAExecutionTerminalReport {
        try challenge.validateDigest()
        try receipt.validateDigest()
        try claim?.validateDigest()
        guard receipt.operationID == challenge.operationID,
              receipt.challengeDigest == challenge.challengeDigest,
              receipt.confirmationTokenHash
                == (try CodexGhostRepairHasher.hash(
                    challenge.confirmationToken
                )),
              completedAtMilliseconds >= receipt.confirmedAtMilliseconds else {
            throw CodexGhostRepairError.invalidPlan(
                "M3e terminal Report identity mismatch."
            )
        }
        if let claim {
            guard claim.operationID == challenge.operationID,
                  claim.draftDigest == challenge.draftDigest,
                  claim.receiptDigest == receipt.receiptDigest else {
                throw CodexGhostRepairError.invalidPlan(
                    "M3e terminal Report claim identity mismatch."
                )
            }
        }
        let report = try CodexGhostRepairCategoryAExecutionTerminalReport(
            operationID: challenge.operationID,
            draftDigest: challenge.draftDigest,
            receiptDigest: receipt.receiptDigest,
            claimDigest: claim?.claimDigest,
            outcome: outcome,
            targetThreadIDs: challenge.targetThreadIDs,
            mutationAttemptedOnce: mutationAttemptedOnce,
            completedAtMilliseconds: completedAtMilliseconds
        )
        try report.validateDigest()
        return report
    }

    private static func isDigest(_ value: String) -> Bool {
        guard value.count == 71, value.hasPrefix("sha256:") else {
            return false
        }
        return value.dropFirst(7).allSatisfy { character in
            character.isHexDigit && !character.isUppercase
        }
    }
}
