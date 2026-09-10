import Foundation

private struct CodexGhostRepairCategoryAPreparedRepairBindingPayload:
    Codable,
    Equatable
{
    let savedPreviewRequestID: UUID
    let draft: CodexGhostRepairCategoryAExecutionDraft
    let review: CodexGhostRepairCategoryAExecutionReviewEvidence
    let challenge: CodexGhostRepairCategoryAConfirmationChallenge
}

/// One durable, authority-free record tying the user-visible challenge to the
/// exact saved Preview, published backup, logical effects and fresh review.
/// Later confirmation may consume this identity once, but this record itself
/// cannot claim or mutate Codex state.
struct CodexGhostRepairCategoryAPreparedRepairBinding:
    Codable,
    Equatable,
    Sendable
{
    let savedPreviewRequestID: UUID
    let draft: CodexGhostRepairCategoryAExecutionDraft
    let review: CodexGhostRepairCategoryAExecutionReviewEvidence
    let challenge: CodexGhostRepairCategoryAConfirmationChallenge
    let bindingDigest: String

    var operationID: UUID { challenge.operationID }
    var snapshotReference: String { draft.snapshotReference }
    var snapshotManifestHash: String { draft.snapshotManifestHash }
    var snapshotSourceFingerprintHash: String {
        draft.snapshotSourceFingerprintHash
    }

    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }
    var automaticRetryAllowed: Bool { false }
    var restoreAuthority: Bool { false }
    var cleanupAuthority: Bool { false }

    init(
        savedPreviewRequestID: UUID,
        draft: CodexGhostRepairCategoryAExecutionDraft,
        review: CodexGhostRepairCategoryAExecutionReviewEvidence,
        challenge: CodexGhostRepairCategoryAConfirmationChallenge
    ) throws {
        let payload = CodexGhostRepairCategoryAPreparedRepairBindingPayload(
            savedPreviewRequestID: savedPreviewRequestID,
            draft: draft,
            review: review,
            challenge: challenge
        )
        self.savedPreviewRequestID = savedPreviewRequestID
        self.draft = draft
        self.review = review
        self.challenge = challenge
        bindingDigest = try CodexGhostRepairHasher.hash(payload)
        try validateDigest()
    }

    func validateDigest() throws {
        try draft.validateDigest()
        try review.validateDigest()
        try challenge.validateDigest()

        let draftItems = draft.itemChanges.map {
            CodexGhostRepairCategoryAExecutionReviewItem(
                threadID: $0.threadID,
                catalogRowDigest: $0.catalogRowDigest
            )
        }
        guard challenge.operationID == draft.operationID,
              challenge.draftDigest == draft.draftDigest,
              challenge.reviewDigest == review.reviewDigest,
              challenge.targetThreadIDs == draft.targetThreadIDs,
              review.items == draftItems,
              review.databaseExpectations == draft.databaseExpectations,
              review.observedAtMilliseconds
                >= draft.preparedAtMilliseconds,
              challenge.generatedAtMilliseconds
                >= review.observedAtMilliseconds,
              challenge.expiresAtMilliseconds
                <= draft.expiresAtMilliseconds,
              Self.isCanonicalUUID(draft.snapshotReference),
              Self.isSHA256(draft.snapshotManifestHash),
              Self.isSHA256(draft.snapshotSourceFingerprintHash),
              Self.isSHA256(draft.snapshotDestinationBindingHash),
              Self.isSHA256(draft.snapshotAcquisitionRecordHash),
              Self.isSHA256(draft.snapshotPublicationReceiptHash) else {
            throw CodexGhostRepairError.invalidPlan(
                "Prepared Category A repair binding scope is invalid."
            )
        }

        let payload = CodexGhostRepairCategoryAPreparedRepairBindingPayload(
            savedPreviewRequestID: savedPreviewRequestID,
            draft: draft,
            review: review,
            challenge: challenge
        )
        guard try CodexGhostRepairHasher.hash(payload) == bindingDigest else {
            throw CodexGhostRepairError.invalidPlan(
                "Prepared Category A repair binding digest mismatch."
            )
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value.lowercased()
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}
