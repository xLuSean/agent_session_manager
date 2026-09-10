import Foundation

public struct CodexGhostRepairBulkRepairCapabilities: Equatable, Sendable {
    public let reviewAvailable: Bool
    public let executionAvailable: Bool

    public var acceptsCallerPath: Bool { false }
    public var automaticRetryAllowed: Bool { false }
    public var automaticRestoreAllowed: Bool { false }
    public var silentSelectionShrinkAllowed: Bool { false }

    public static let unavailable = Self(
        reviewAvailable: false,
        executionAvailable: false
    )

    public static let testOwned = Self(
        reviewAvailable: true,
        executionAvailable: true
    )

    static let deterministicComposition = Self(
        reviewAvailable: true,
        executionAvailable: true
    )

    private init(reviewAvailable: Bool, executionAvailable: Bool) {
        self.reviewAvailable = reviewAvailable
        self.executionAvailable = executionAvailable
    }
}

public struct CodexGhostRepairBulkRepairReviewRequest: Equatable, Sendable {
    public let requestID: UUID
    public let confirmationReceiptID: UUID

    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public init(requestID: UUID, confirmationReceiptID: UUID) {
        self.requestID = requestID
        self.confirmationReceiptID = confirmationReceiptID
    }
}

public struct CodexGhostRepairBulkFinalReview: Equatable, Sendable {
    public let operationID: UUID
    public let confirmationReceiptID: UUID
    public let selectedCount: Int
    public let ordinaryCount: Int
    public let automationCount: Int
    public let alreadyAbsentCount: Int
    public let blockedOutsideBatchCount: Int
    public let sourceLayoutIdentifier: String
    public let reviewDigest: String

    public var allOrNothing: Bool { true }
    public var codexMustRemainExited: Bool { true }
    public var managerMustRemainOpen: Bool { true }
    public var automaticRetryAllowed: Bool { false }
    public var automaticRestoreAllowed: Bool { false }
    public var silentSelectionShrinkAllowed: Bool { false }

    public init(
        operationID: UUID,
        confirmationReceiptID: UUID,
        selectedCount: Int,
        ordinaryCount: Int,
        automationCount: Int,
        alreadyAbsentCount: Int = 0,
        blockedOutsideBatchCount: Int,
        sourceLayoutIdentifier: String,
        reviewDigest: String
    ) throws {
        guard (1...500).contains(selectedCount),
              ordinaryCount >= 0,
              automationCount >= 0,
              ordinaryCount + automationCount == selectedCount,
              (0...selectedCount).contains(alreadyAbsentCount),
              blockedOutsideBatchCount >= 0,
              CodexGhostRepairSnapshotSourceProfile.admitted(
                  sourceLayoutIdentifier: sourceLayoutIdentifier
              ) != nil,
              Self.isSHA256(reviewDigest) else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk final repair review is invalid."
            )
        }
        self.operationID = operationID
        self.confirmationReceiptID = confirmationReceiptID
        self.selectedCount = selectedCount
        self.ordinaryCount = ordinaryCount
        self.automationCount = automationCount
        self.alreadyAbsentCount = alreadyAbsentCount
        self.blockedOutsideBatchCount = blockedOutsideBatchCount
        self.sourceLayoutIdentifier = sourceLayoutIdentifier
        self.reviewDigest = reviewDigest
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

public enum CodexGhostRepairBulkRepairReviewOutcome: Equatable, Sendable {
    case ready(CodexGhostRepairBulkFinalReview)
    /// A shutdown gate failed before the durable runner was reached. Only a
    /// fresh review of the same confirmed batch may be requested by the user.
    case awaitingShutdown(message: String)
    case blocked(message: String)
    case unavailable(message: String)
}

public struct CodexGhostRepairBulkRepairExecutionRequest: Equatable, Sendable {
    public let requestID: UUID
    public let review: CodexGhostRepairBulkFinalReview

    public var automaticRetryAllowed: Bool { false }
    public var automaticRestoreAllowed: Bool { false }
    public var silentSelectionShrinkAllowed: Bool { false }

    public init(requestID: UUID, review: CodexGhostRepairBulkFinalReview) {
        self.requestID = requestID
        self.review = review
    }
}

public enum CodexGhostRepairBulkRepairObservedOutcome:
    String,
    Equatable,
    Sendable
{
    case success
    case alreadyAbsent
    case explicitFailure
    case unknown
    case notAttempted
}

public struct CodexGhostRepairBulkRepairItemReport: Equatable, Sendable {
    public let threadID: String
    public let category: CodexGhostRepairCategory
    public let outcome: CodexGhostRepairBulkRepairObservedOutcome

    public init(
        threadID: String,
        category: CodexGhostRepairCategory,
        outcome: CodexGhostRepairBulkRepairObservedOutcome
    ) {
        self.threadID = threadID
        self.category = category
        self.outcome = outcome
    }
}

public struct CodexGhostRepairBulkRepairReport: Equatable, Sendable {
    public let operationID: UUID
    public let outcome: CodexGhostRepairBulkRepairObservedOutcome
    public let itemReports: [CodexGhostRepairBulkRepairItemReport]
    public let reportDigest: String

    public var automaticRetryAllowed: Bool { false }
    public var automaticRestoreAllowed: Bool { false }

    public init(
        operationID: UUID,
        outcome: CodexGhostRepairBulkRepairObservedOutcome,
        itemReports: [CodexGhostRepairBulkRepairItemReport],
        reportDigest: String
    ) throws {
        let ids = itemReports.map(\.threadID)
        guard (1...500).contains(ids.count),
              ids == ids.sorted(),
              Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty }),
              Self.validItemOutcomes(itemReports, batchOutcome: outcome),
              Self.isSHA256(reportDigest) else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk repair terminal Report is invalid."
            )
        }
        self.operationID = operationID
        self.outcome = outcome
        self.itemReports = itemReports
        self.reportDigest = reportDigest
    }

    private static func validItemOutcomes(
        _ items: [CodexGhostRepairBulkRepairItemReport],
        batchOutcome: CodexGhostRepairBulkRepairObservedOutcome
    ) -> Bool {
        if batchOutcome == .success {
            return items.allSatisfy {
                $0.outcome == .success || $0.outcome == .alreadyAbsent
            }
        }
        return items.allSatisfy { $0.outcome == batchOutcome }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

public enum CodexGhostRepairBulkRepairExecutionOutcome: Equatable, Sendable {
    case completed(CodexGhostRepairBulkRepairReport)
    case recoveryRequired(operationID: UUID, message: String)
    case unavailable(message: String)
}

public protocol CodexGhostRepairBulkRepairCoordinating: Sendable {
    var capabilities: CodexGhostRepairBulkRepairCapabilities { get }

    func prepareFinalReview(
        request: CodexGhostRepairBulkRepairReviewRequest
    ) async -> CodexGhostRepairBulkRepairReviewOutcome

    func execute(
        request: CodexGhostRepairBulkRepairExecutionRequest
    ) async -> CodexGhostRepairBulkRepairExecutionOutcome
}

public struct CodexGhostRepairBulkRepairUnavailableCoordinator:
    CodexGhostRepairBulkRepairCoordinating
{
    public init() {}

    public var capabilities: CodexGhostRepairBulkRepairCapabilities {
        .unavailable
    }

    public func prepareFinalReview(
        request _: CodexGhostRepairBulkRepairReviewRequest
    ) async -> CodexGhostRepairBulkRepairReviewOutcome {
        .unavailable(
            message: "Bulk final repair review is not available in this build."
        )
    }

    public func execute(
        request _: CodexGhostRepairBulkRepairExecutionRequest
    ) async -> CodexGhostRepairBulkRepairExecutionOutcome {
        .unavailable(
            message: "Bulk repair execution is not available in this build."
        )
    }
}

public enum CodexGhostRepairBulkRepairCoordinatorFactory {
    public static func packagedDefaultBlocked()
        -> any CodexGhostRepairBulkRepairCoordinating
    {
        CodexGhostRepairBulkRepairUnavailableCoordinator()
    }

    /// Zero-I/O construction of the packaged whole-batch bridge. Filesystem,
    /// manager SQLite and Codex SQLite are touched only by the existing
    /// explicit Final Review / Execute actions.
    public static func packagedProduction()
        -> any CodexGhostRepairBulkRepairCoordinating
    {
        CodexGhostRepairBulkPackagedRepairCoordinator(
            planPreparer: CodexGhostRepairBulkPackagedPlanPreparer.production(),
            runnerFactory: { sourceLayoutIdentifier in
                guard let profile = CodexGhostRepairSnapshotSourceProfile
                        .admitted(
                            sourceLayoutIdentifier: sourceLayoutIdentifier
                        ) else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Bulk execution source layout is not packaged."
                    )
                }
                let backupReader = try
                    CodexGhostRepairBulkLiveProductionBackupReader.production(
                        sourceLayoutIdentifier: sourceLayoutIdentifier
                    )
                return CodexGhostRepairBulkLiveOneShotCoordinator.production(
                    backupReader: backupReader,
                    profile: profile
                )
            }
        )
    }
}
