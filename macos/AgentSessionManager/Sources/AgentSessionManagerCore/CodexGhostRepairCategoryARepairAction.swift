import Foundation

public enum CodexGhostRepairCategoryARepairEffect:
    String,
    Equatable,
    Sendable
{
    case unavailable
    case testOwnedCategoryAOneShot
    case fixedCodexCategoryAOneShot

    public var writesCodexDatabaseFiles: Bool {
        self != .unavailable
    }

    public var acceptsCallerPath: Bool { false }
    public var supportsAutomaticRetry: Bool { false }
}

public struct CodexGhostRepairCategoryARepairCapabilities:
    Equatable,
    Sendable
{
    public let reviewAvailable: Bool
    public let executionAvailable: Bool
    public let effect: CodexGhostRepairCategoryARepairEffect

    public var acceptsCallerPath: Bool { false }
    public var automaticRetryAllowed: Bool { false }
    public var restoreAuthority: Bool { false }
    public var cleanupAuthority: Bool { false }

    public static let unavailable = Self(
        reviewAvailable: false,
        executionAvailable: false,
        effect: .unavailable
    )

    public static let packagedDefaultBlocked = Self(
        reviewAvailable: false,
        executionAvailable: false,
        effect: .fixedCodexCategoryAOneShot
    )

    static let packagedReviewOnly = Self(
        reviewAvailable: true,
        executionAvailable: false,
        effect: .fixedCodexCategoryAOneShot
    )

    /// Internal composition capability used before the App wiring gate. It
    /// does not itself grant confirmation or mutation authority; those remain
    /// bound to one durable prepared operation and one exact confirmation.
    static let packagedExecutionCandidate = Self(
        reviewAvailable: true,
        executionAvailable: true,
        effect: .fixedCodexCategoryAOneShot
    )

    public static let testOwned = Self(
        reviewAvailable: true,
        executionAvailable: true,
        effect: .testOwnedCategoryAOneShot
    )

    private init(
        reviewAvailable: Bool,
        executionAvailable: Bool,
        effect: CodexGhostRepairCategoryARepairEffect
    ) {
        self.reviewAvailable = reviewAvailable
        self.executionAvailable = executionAvailable
        self.effect = effect
    }
}

public struct CodexGhostRepairCategoryARepairReviewRequest:
    Equatable,
    Sendable
{
    public let requestID: UUID
    public let savedPreviewRequestID: UUID

    public var filesystemAuthority: Bool { false }
    public var codexSQLiteAuthority: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public init(requestID: UUID, savedPreviewRequestID: UUID) {
        self.requestID = requestID
        self.savedPreviewRequestID = savedPreviewRequestID
    }
}

public struct CodexGhostRepairCategoryARepairChallenge:
    Equatable,
    Sendable
{
    public let operationID: UUID
    public let savedPreviewRequestID: UUID
    public let snapshotReference: String
    public let snapshotManifestHash: String
    public let snapshotSourceFingerprintHash: String
    public let preparedBindingDigest: String
    public let targetThreadIDs: [String]
    public let buildIdentifier: String
    public let draftDigest: String
    public let reviewDigest: String
    public let challengeDigest: String
    public let confirmationToken: String
    public let generatedAt: Date
    public let expiresAt: Date

    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var automaticRetryAllowed: Bool { false }

    public init(
        operationID: UUID,
        savedPreviewRequestID: UUID,
        snapshotReference: String,
        snapshotManifestHash: String,
        snapshotSourceFingerprintHash: String,
        preparedBindingDigest: String,
        targetThreadIDs: [String],
        buildIdentifier: String,
        draftDigest: String,
        reviewDigest: String,
        challengeDigest: String,
        confirmationToken: String,
        generatedAt: Date,
        expiresAt: Date
    ) throws {
        let normalized = targetThreadIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.sorted()
        guard (1...2).contains(normalized.count),
              normalized == targetThreadIDs,
              Set(normalized).count == normalized.count,
              normalized.allSatisfy({ !$0.isEmpty }),
              Self.isCanonicalUUID(snapshotReference),
              Self.isSHA256(snapshotManifestHash),
              Self.isSHA256(snapshotSourceFingerprintHash),
              Self.isSHA256(preparedBindingDigest),
              !buildIdentifier.isEmpty,
              Self.isSHA256(draftDigest),
              Self.isSHA256(reviewDigest),
              Self.isSHA256(challengeDigest),
              confirmationToken.hasPrefix("M3A-REPAIR-"),
              confirmationToken.count == 23,
              Self.isUppercaseHexToken(confirmationToken),
              expiresAt > generatedAt else {
            throw CodexGhostRepairError.invalidPlan(
                "Packaged Category A repair challenge is invalid."
            )
        }
        self.operationID = operationID
        self.savedPreviewRequestID = savedPreviewRequestID
        self.snapshotReference = snapshotReference
        self.snapshotManifestHash = snapshotManifestHash
        self.snapshotSourceFingerprintHash = snapshotSourceFingerprintHash
        self.preparedBindingDigest = preparedBindingDigest
        self.targetThreadIDs = normalized
        self.buildIdentifier = buildIdentifier
        self.draftDigest = draftDigest
        self.reviewDigest = reviewDigest
        self.challengeDigest = challengeDigest
        self.confirmationToken = confirmationToken
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value.lowercased()
    }

    private static func isUppercaseHexToken(_ value: String) -> Bool {
        let suffix = value.dropFirst("M3A-REPAIR-".count)
        return suffix.count == 12
            && suffix.allSatisfy(\.isHexDigit)
            && suffix == suffix.uppercased()
    }
}

public enum CodexGhostRepairCategoryARepairReviewBlocker:
    String,
    Equatable,
    Sendable
{
    case savedPreviewUnavailable
    case savedPreviewExpired
    case categoryNotSupported
    case targetDrift
    case protectionUnavailable
    case operatingConditionsBlocked
    case schemaDrift
    case persistenceUnavailable
}

public enum CodexGhostRepairCategoryARepairReviewOutcome:
    Equatable,
    Sendable
{
    case ready(CodexGhostRepairCategoryARepairChallenge)
    case blocked(CodexGhostRepairCategoryARepairReviewBlocker, message: String)
    case unavailable(message: String)
}

public struct CodexGhostRepairCategoryARepairExecutionRequest:
    Equatable,
    Sendable
{
    public let requestID: UUID
    public let challenge: CodexGhostRepairCategoryARepairChallenge
    public let exactConfirmationToken: String

    public var automaticRetryAllowed: Bool { false }
    public var restoreAuthority: Bool { false }
    public var cleanupAuthority: Bool { false }

    public init(
        requestID: UUID,
        challenge: CodexGhostRepairCategoryARepairChallenge,
        exactConfirmationToken: String
    ) {
        self.requestID = requestID
        self.challenge = challenge
        self.exactConfirmationToken = exactConfirmationToken
    }
}

public enum CodexGhostRepairCategoryARepairObservedOutcome:
    String,
    Equatable,
    Sendable
{
    case success
    case explicitFailure
    case unknown
    case notAttempted
}

public struct CodexGhostRepairCategoryARepairItemOutcome:
    Equatable,
    Sendable
{
    public let threadID: String
    public let outcome: CodexGhostRepairCategoryARepairObservedOutcome

    public init(
        threadID: String,
        outcome: CodexGhostRepairCategoryARepairObservedOutcome
    ) {
        self.threadID = threadID
        self.outcome = outcome
    }
}

public struct CodexGhostRepairCategoryARepairReport:
    Equatable,
    Sendable
{
    public let operationID: UUID
    public let outcome: CodexGhostRepairCategoryARepairObservedOutcome
    public let itemOutcomes: [CodexGhostRepairCategoryARepairItemOutcome]
    public let reportDigest: String

    public var automaticRetryAllowed: Bool { false }
    public var restoreAuthority: Bool { false }
    public var cleanupAuthority: Bool { false }

    public init(
        operationID: UUID,
        outcome: CodexGhostRepairCategoryARepairObservedOutcome,
        itemOutcomes: [CodexGhostRepairCategoryARepairItemOutcome],
        reportDigest: String
    ) throws {
        let ids = itemOutcomes.map(\.threadID)
        guard (1...2).contains(ids.count),
              ids == ids.sorted(),
              Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty }),
              itemOutcomes.allSatisfy({ $0.outcome == outcome }),
              Self.isSHA256(reportDigest) else {
            throw CodexGhostRepairError.invalidPlan(
                "Packaged Category A repair Report is invalid."
            )
        }
        self.operationID = operationID
        self.outcome = outcome
        self.itemOutcomes = itemOutcomes
        self.reportDigest = reportDigest
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

public enum CodexGhostRepairCategoryARepairExecutionOutcome:
    Equatable,
    Sendable
{
    case completed(CodexGhostRepairCategoryARepairReport)
    case recoveryRequired(operationID: UUID, message: String)
    case unavailable(message: String)
}

public protocol CodexGhostRepairCategoryARepairCoordinator: Sendable {
    var capabilities: CodexGhostRepairCategoryARepairCapabilities { get }

    func prepareReview(
        request: CodexGhostRepairCategoryARepairReviewRequest
    ) async -> CodexGhostRepairCategoryARepairReviewOutcome

    func confirmAndRepair(
        request: CodexGhostRepairCategoryARepairExecutionRequest
    ) async -> CodexGhostRepairCategoryARepairExecutionOutcome
}

public struct CodexGhostRepairCategoryARepairUnavailableCoordinator:
    CodexGhostRepairCategoryARepairCoordinator
{
    public init() {}

    public var capabilities: CodexGhostRepairCategoryARepairCapabilities {
        .unavailable
    }

    public func prepareReview(
        request _: CodexGhostRepairCategoryARepairReviewRequest
    ) async -> CodexGhostRepairCategoryARepairReviewOutcome {
        .unavailable(
            message: "Packaged Category A repair review is not available in this build."
        )
    }

    public func confirmAndRepair(
        request _: CodexGhostRepairCategoryARepairExecutionRequest
    ) async -> CodexGhostRepairCategoryARepairExecutionOutcome {
        .unavailable(
            message: "Packaged Category A repair execution is not available in this build."
        )
    }
}

#if AGENT_SESSION_MANAGER_RESEARCH
public enum CodexGhostRepairCategoryARepairCoordinatorFactory {
    public static func packagedDefaultBlocked()
        -> any CodexGhostRepairCategoryARepairCoordinator
    {
        CodexGhostRepairCategoryARepairUnavailableCoordinator()
    }

    /// Default-off packaged production coordinator. Construction performs no
    /// I/O and accepts no caller path. The App must still require an explicit
    /// fresh Review and exact one-shot confirmation before execution.
    public static func packagedProduction()
        -> any CodexGhostRepairCategoryARepairCoordinator
    {
        CodexGhostRepairCategoryARepairExecutionCoordinatorFactory
            .packagedProduction()
    }
}
#endif
