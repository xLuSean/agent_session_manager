import Foundation

private struct CodexGhostRepairBulkConfirmationChallengePayload:
    Codable,
    Hashable
{
    let operationID: UUID
    let savedPreviewRequestID: UUID
    let previewID: UUID
    let snapshotReference: String
    let manifestDigest: String
    let previewPayloadHash: String
    let selectedCount: Int
    let ordinaryCount: Int
    let automationCount: Int
    let blockedOutsideBatchCount: Int
    let generatedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
}

public struct CodexGhostRepairBulkConfirmationChallenge:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let operationID: UUID
    public let savedPreviewRequestID: UUID
    public let previewID: UUID
    public let snapshotReference: String
    public let manifestDigest: String
    public let previewPayloadHash: String
    public let selectedCount: Int
    public let ordinaryCount: Int
    public let automationCount: Int
    public let blockedOutsideBatchCount: Int
    public let generatedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let challengeDigest: String
    public let confirmationPhrase: String

    public var allOrNothing: Bool { true }
    public var singleWholeBatchConfirmation: Bool { true }
    public var perItemConfirmation: Bool { false }
    public var persistsChallenge: Bool { true }
    public var confirmationAuthority: Bool { false }
    public var repairClaimCreated: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var automaticRetryAllowed: Bool { false }

    init(
        operationID: UUID,
        savedPreviewRequestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        previewPayloadHash: String,
        generatedAtMilliseconds: Int64
    ) throws {
        try preview.validateForPersistence()
        guard generatedAtMilliseconds >= preview.generatedAtMilliseconds,
              generatedAtMilliseconds < preview.expiresAtMilliseconds,
              Self.isSHA256(previewPayloadHash) else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk confirmation challenge timing or Preview hash is invalid."
            )
        }
        let payload = CodexGhostRepairBulkConfirmationChallengePayload(
            operationID: operationID,
            savedPreviewRequestID: savedPreviewRequestID,
            previewID: preview.previewID,
            snapshotReference: preview.snapshotReference,
            manifestDigest: preview.manifestDigest,
            previewPayloadHash: previewPayloadHash,
            selectedCount: preview.selectedItems.count,
            ordinaryCount: preview.ordinarySelectedCount,
            automationCount: preview.automationSelectedCount,
            blockedOutsideBatchCount: preview.blockedItems.count,
            generatedAtMilliseconds: generatedAtMilliseconds,
            expiresAtMilliseconds: preview.expiresAtMilliseconds
        )
        self.operationID = operationID
        self.savedPreviewRequestID = savedPreviewRequestID
        previewID = payload.previewID
        snapshotReference = payload.snapshotReference
        manifestDigest = payload.manifestDigest
        self.previewPayloadHash = payload.previewPayloadHash
        selectedCount = payload.selectedCount
        ordinaryCount = payload.ordinaryCount
        automationCount = payload.automationCount
        blockedOutsideBatchCount = payload.blockedOutsideBatchCount
        self.generatedAtMilliseconds = payload.generatedAtMilliseconds
        expiresAtMilliseconds = payload.expiresAtMilliseconds
        challengeDigest = try CodexGhostRepairHasher.hash(payload)
        confirmationPhrase = Self.phrase(
            selectedCount: selectedCount,
            digest: challengeDigest
        )
    }

    func validate(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        payloadHash: String
    ) throws {
        let rebuilt = try Self(
            operationID: operationID,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash: payloadHash,
            generatedAtMilliseconds: generatedAtMilliseconds
        )
        guard self == rebuilt,
              savedPreviewRequestID == requestID,
              expiresAtMilliseconds == preview.expiresAtMilliseconds else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk confirmation challenge does not match the saved Preview."
            )
        }
    }

    private static func phrase(selectedCount: Int, digest: String) -> String {
        let compact = digest.replacingOccurrences(of: "sha256:", with: "")
        return "CONFIRM BULK DELETE \(selectedCount) "
            + compact.prefix(12).uppercased()
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

public enum CodexGhostRepairBulkConfirmationChallengeOutcome:
    Equatable,
    Sendable
{
    case ready(CodexGhostRepairBulkConfirmationChallenge)
    case notFound(requestID: UUID)
    case unavailable(requestID: UUID, message: String)

    public var requestID: UUID {
        switch self {
        case let .ready(challenge): challenge.savedPreviewRequestID
        case let .notFound(requestID), let .unavailable(requestID, _): requestID
        }
    }
}

public struct CodexGhostRepairBulkConfirmationCapabilities:
    Equatable,
    Sendable
{
    public let explicitChallengeAvailable: Bool

    public var automaticChallenge: Bool { false }
    public var perItemConfirmation: Bool { false }
    public var createsAuthorizationReceipt: Bool { false }
    public var createsRepairClaim: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let unavailable = Self(explicitChallengeAvailable: false)
    public static let packagedEvidenceOnly = Self(
        explicitChallengeAvailable: true
    )
}

public protocol CodexGhostRepairBulkConfirmationChallengeCoordinating:
    Sendable
{
    var capabilities: CodexGhostRepairBulkConfirmationCapabilities { get }

    func prepareChallenge(
        savedPreviewRequestID: UUID
    ) async -> CodexGhostRepairBulkConfirmationChallengeOutcome
}

private struct CodexGhostRepairBulkConfirmationReceiptPayload:
    Codable,
    Hashable
{
    let receiptID: UUID
    let operationID: UUID
    let savedPreviewRequestID: UUID
    let challengeDigest: String
    let confirmationPhraseHash: String
    let selectedCount: Int
    let confirmedAtMilliseconds: Int64
}

public struct CodexGhostRepairBulkConfirmationReceipt:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let receiptID: UUID
    public let operationID: UUID
    public let savedPreviewRequestID: UUID
    public let challengeDigest: String
    public let confirmationPhraseHash: String
    public let selectedCount: Int
    public let confirmedAtMilliseconds: Int64
    public let receiptDigest: String

    public var wholeBatchConfirmationRecorded: Bool { true }
    public var createsRepairClaim: Bool { false }
    public var repairClaimCreated: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var automaticRetryAllowed: Bool { false }

    init(
        receiptID: UUID,
        challenge: CodexGhostRepairBulkConfirmationChallenge,
        confirmedAtMilliseconds: Int64
    ) throws {
        guard confirmedAtMilliseconds >= challenge.generatedAtMilliseconds,
              confirmedAtMilliseconds < challenge.expiresAtMilliseconds else {
            throw CodexGhostRepairError.previewExpired
        }
        let payload = CodexGhostRepairBulkConfirmationReceiptPayload(
            receiptID: receiptID,
            operationID: challenge.operationID,
            savedPreviewRequestID: challenge.savedPreviewRequestID,
            challengeDigest: challenge.challengeDigest,
            confirmationPhraseHash: try CodexGhostRepairHasher.hash(
                challenge.confirmationPhrase
            ),
            selectedCount: challenge.selectedCount,
            confirmedAtMilliseconds: confirmedAtMilliseconds
        )
        self.receiptID = payload.receiptID
        operationID = payload.operationID
        savedPreviewRequestID = payload.savedPreviewRequestID
        challengeDigest = payload.challengeDigest
        confirmationPhraseHash = payload.confirmationPhraseHash
        selectedCount = payload.selectedCount
        self.confirmedAtMilliseconds = payload.confirmedAtMilliseconds
        receiptDigest = try CodexGhostRepairHasher.hash(payload)
    }

    public func validate(
        challenge: CodexGhostRepairBulkConfirmationChallenge
    ) throws {
        let rebuilt = try Self(
            receiptID: receiptID,
            challenge: challenge,
            confirmedAtMilliseconds: confirmedAtMilliseconds
        )
        guard self == rebuilt else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk confirmation receipt does not match its challenge."
            )
        }
    }
}

public enum CodexGhostRepairBulkConfirmationReceiptOutcome:
    Equatable,
    Sendable
{
    case confirmed(CodexGhostRepairBulkConfirmationReceipt)
    case alreadyConfirmed(CodexGhostRepairBulkConfirmationReceipt)
    case notFound(requestID: UUID)
    case rejected(requestID: UUID, message: String)
    case outcomeUnknown(requestID: UUID, message: String)

    public var requestID: UUID {
        switch self {
        case let .confirmed(receipt), let .alreadyConfirmed(receipt):
            receipt.savedPreviewRequestID
        case let .notFound(requestID),
             let .rejected(requestID, _),
             let .outcomeUnknown(requestID, _):
            requestID
        }
    }
}

public struct CodexGhostRepairBulkConfirmationReceiptCapabilities:
    Equatable,
    Sendable
{
    public let explicitReceiptAvailable: Bool

    public var automaticConfirmation: Bool { false }
    public var perItemConfirmation: Bool { false }
    public var createsRepairClaim: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var automaticRetryAllowed: Bool { false }

    public static let unavailable = Self(explicitReceiptAvailable: false)
    public static let packagedReceiptOnly = Self(
        explicitReceiptAvailable: true
    )
}

public protocol CodexGhostRepairBulkConfirmationReceiptCoordinating:
    Sendable
{
    var capabilities: CodexGhostRepairBulkConfirmationReceiptCapabilities {
        get
    }

    func confirm(
        savedPreviewRequestID: UUID,
        exactConfirmationPhrase: String
    ) async -> CodexGhostRepairBulkConfirmationReceiptOutcome
}

public struct CodexGhostRepairBulkConfirmationReceiptRecoveryRequest:
    Equatable,
    Sendable
{
    public let challenge: CodexGhostRepairBulkConfirmationChallenge

    public var savedPreviewRequestID: UUID {
        challenge.savedPreviewRequestID
    }

    public var operationID: UUID { challenge.operationID }
    public var challengeDigest: String { challenge.challengeDigest }
    public var selectedCount: Int { challenge.selectedCount }

    public init(challenge: CodexGhostRepairBulkConfirmationChallenge) {
        self.challenge = challenge
    }
}

public enum CodexGhostRepairBulkConfirmationReceiptRecoveryReason:
    Equatable,
    Sendable
{
    case databaseMissing
    case challengeMissing
    case receiptAbsent
    case challengeExpiredWithoutReceipt
    case executionJournalPresent(
        phase: CodexGhostRepairBulkRecoveryJournalPhase
    )
    case evidenceInvalid
    case unavailable
}

public enum CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome:
    Equatable,
    Sendable
{
    case confirmed(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest,
        receipt: CodexGhostRepairBulkConfirmationReceipt
    )
    case executionRecoveryRequired(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest,
        receipt: CodexGhostRepairBulkConfirmationReceipt,
        phase: CodexGhostRepairBulkRecoveryJournalPhase,
        message: String
    )
    case recoveryRequired(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest,
        reason: CodexGhostRepairBulkConfirmationReceiptRecoveryReason,
        message: String
    )

    public var request:
        CodexGhostRepairBulkConfirmationReceiptRecoveryRequest
    {
        switch self {
        case let .confirmed(request, _),
             let .executionRecoveryRequired(request, _, _, _),
             let .recoveryRequired(request, _, _):
            request
        }
    }
}

public struct CodexGhostRepairBulkConfirmationReceiptRecoveryCapabilities:
    Equatable,
    Sendable
{
    public let explicitExactReadbackAvailable: Bool

    public var readsManagerOwnedState: Bool {
        explicitExactReadbackAvailable
    }
    public var readsCodexData: Bool { false }
    public var writesManagerOwnedRecords: Bool { false }
    public var mayUpdateSQLiteCoordination: Bool {
        explicitExactReadbackAvailable
    }
    public var createsChallenge: Bool { false }
    public var createsReceipt: Bool { false }
    public var createsClaim: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var retryAuthority: Bool { false }

    public static let unavailable = Self(
        explicitExactReadbackAvailable: false
    )
    public static let packagedReadOnly = Self(
        explicitExactReadbackAvailable: true
    )
}

public protocol CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinating:
    Sendable
{
    var capabilities:
        CodexGhostRepairBulkConfirmationReceiptRecoveryCapabilities { get }

    func recoverReceipt(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest
    ) async -> CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome
}
