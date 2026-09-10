import Foundation

public enum CodexGhostRepairBulkPreparedClosureReason:
    String, Codable, Equatable, Sendable
{
    case userClosedUnstartedPlan
}

public struct CodexGhostRepairBulkPreparedClosureItem:
    Codable, Equatable, Sendable
{
    public let threadID: String
    public let category: CodexGhostRepairCategory

    public init(threadID: String, category: CodexGhostRepairCategory) {
        self.threadID = threadID
        self.category = category
    }
}

private struct CodexGhostRepairBulkPreparedClosureReviewPayload: Codable {
    let closureReviewID: UUID
    let identity: CodexGhostRepairBulkRecoveryOperationIdentity
    let confirmationReceiptID: UUID
    let selectedItems: [CodexGhostRepairBulkPreparedClosureItem]
    let planDigest: String
    let confirmationReceiptDigest: String
    let backupReceiptDigest: String
    let expectedJournalPayloadHash: String
    let preparedAtMilliseconds: Int64
    let reviewedAtMilliseconds: Int64
}

public struct CodexGhostRepairBulkPreparedClosurePreview:
    Codable, Equatable, Sendable
{
    public let identity: CodexGhostRepairBulkRecoveryOperationIdentity
    public let confirmationReceiptID: UUID
    public let selectedItems: [CodexGhostRepairBulkPreparedClosureItem]
    public let planDigest: String
    public let confirmationReceiptDigest: String
    public let backupReceiptDigest: String
    public let expectedJournalPayloadHash: String
    public let preparedAtMilliseconds: Int64
    public let closureReviewID: UUID
    public let reviewedAtMilliseconds: Int64
    public let reviewDigest: String

    public init(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        confirmationReceiptID: UUID,
        selectedItems: [CodexGhostRepairBulkPreparedClosureItem],
        planDigest: String,
        confirmationReceiptDigest: String,
        backupReceiptDigest: String,
        expectedJournalPayloadHash: String,
        preparedAtMilliseconds: Int64,
        closureReviewID: UUID,
        reviewedAtMilliseconds: Int64
    ) throws {
        self.identity = identity
        self.confirmationReceiptID = confirmationReceiptID
        self.selectedItems = selectedItems
        self.planDigest = planDigest
        self.confirmationReceiptDigest = confirmationReceiptDigest
        self.backupReceiptDigest = backupReceiptDigest
        self.expectedJournalPayloadHash = expectedJournalPayloadHash
        self.preparedAtMilliseconds = preparedAtMilliseconds
        self.closureReviewID = closureReviewID
        self.reviewedAtMilliseconds = reviewedAtMilliseconds
        reviewDigest = try CodexGhostRepairHasher.hash(Self.payload(
            identity: identity,
            confirmationReceiptID: confirmationReceiptID,
            selectedItems: selectedItems,
            planDigest: planDigest,
            confirmationReceiptDigest: confirmationReceiptDigest,
            backupReceiptDigest: backupReceiptDigest,
            expectedJournalPayloadHash: expectedJournalPayloadHash,
            preparedAtMilliseconds: preparedAtMilliseconds,
            closureReviewID: closureReviewID,
            reviewedAtMilliseconds: reviewedAtMilliseconds
        ))
        try validate()
    }

    public func validate() throws {
        guard (1...500).contains(selectedItems.count),
              Set(selectedItems.map(\.threadID)).count == selectedItems.count,
              selectedItems.allSatisfy({ !$0.threadID.isEmpty }),
              !planDigest.isEmpty,
              !confirmationReceiptDigest.isEmpty,
              !backupReceiptDigest.isEmpty,
              !expectedJournalPayloadHash.isEmpty,
              preparedAtMilliseconds >= 0,
              reviewedAtMilliseconds >= preparedAtMilliseconds,
              try CodexGhostRepairHasher.hash(Self.payload(
                  identity: identity,
                  confirmationReceiptID: confirmationReceiptID,
                  selectedItems: selectedItems,
                  planDigest: planDigest,
                  confirmationReceiptDigest: confirmationReceiptDigest,
                  backupReceiptDigest: backupReceiptDigest,
                  expectedJournalPayloadHash: expectedJournalPayloadHash,
                  preparedAtMilliseconds: preparedAtMilliseconds,
                  closureReviewID: closureReviewID,
                  reviewedAtMilliseconds: reviewedAtMilliseconds
              )) == reviewDigest else {
            throw PersistentStateError.invalidRecord(
                "Prepared closure review is not an exact frozen operation."
            )
        }
    }

    private static func payload(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        confirmationReceiptID: UUID,
        selectedItems: [CodexGhostRepairBulkPreparedClosureItem],
        planDigest: String,
        confirmationReceiptDigest: String,
        backupReceiptDigest: String,
        expectedJournalPayloadHash: String,
        preparedAtMilliseconds: Int64,
        closureReviewID: UUID,
        reviewedAtMilliseconds: Int64
    ) -> CodexGhostRepairBulkPreparedClosureReviewPayload {
        .init(
            closureReviewID: closureReviewID,
            identity: identity,
            confirmationReceiptID: confirmationReceiptID,
            selectedItems: selectedItems,
            planDigest: planDigest,
            confirmationReceiptDigest: confirmationReceiptDigest,
            backupReceiptDigest: backupReceiptDigest,
            expectedJournalPayloadHash: expectedJournalPayloadHash,
            preparedAtMilliseconds: preparedAtMilliseconds,
            reviewedAtMilliseconds: reviewedAtMilliseconds
        )
    }
}

private struct CodexGhostRepairBulkPreparedClosurePayload: Codable {
    let closureID: UUID
    let closureReviewID: UUID
    let reviewDigest: String
    let expectedPreparedJournalPayloadHash: String
    let identity: CodexGhostRepairBulkRecoveryOperationIdentity
    let confirmationReceiptID: UUID
    let selectedItems: [CodexGhostRepairBulkPreparedClosureItem]
    let planDigest: String
    let confirmationReceiptDigest: String
    let backupReceiptDigest: String
    let preparedAtMilliseconds: Int64
    let reviewedAtMilliseconds: Int64
    let reason: CodexGhostRepairBulkPreparedClosureReason
    let closedAtMilliseconds: Int64
}

public struct CodexGhostRepairBulkPreparedClosureRecord:
    Codable, Equatable, Sendable
{
    public let closureID: UUID
    public let closureReviewID: UUID
    public let reviewDigest: String
    public let expectedPreparedJournalPayloadHash: String
    public let identity: CodexGhostRepairBulkRecoveryOperationIdentity
    public let confirmationReceiptID: UUID
    public let selectedItems: [CodexGhostRepairBulkPreparedClosureItem]
    public let planDigest: String
    public let confirmationReceiptDigest: String
    public let backupReceiptDigest: String
    public let preparedAtMilliseconds: Int64
    public let reviewedAtMilliseconds: Int64
    public let reason: CodexGhostRepairBulkPreparedClosureReason
    public let closedAtMilliseconds: Int64
    public let closureDigest: String

    public init(
        closureID: UUID,
        preview: CodexGhostRepairBulkPreparedClosurePreview,
        reason: CodexGhostRepairBulkPreparedClosureReason,
        closedAtMilliseconds: Int64
    ) throws {
        try preview.validate()
        self.closureID = closureID
        closureReviewID = preview.closureReviewID
        reviewDigest = preview.reviewDigest
        expectedPreparedJournalPayloadHash = preview.expectedJournalPayloadHash
        identity = preview.identity
        confirmationReceiptID = preview.confirmationReceiptID
        selectedItems = preview.selectedItems
        planDigest = preview.planDigest
        confirmationReceiptDigest = preview.confirmationReceiptDigest
        backupReceiptDigest = preview.backupReceiptDigest
        preparedAtMilliseconds = preview.preparedAtMilliseconds
        reviewedAtMilliseconds = preview.reviewedAtMilliseconds
        self.reason = reason
        self.closedAtMilliseconds = closedAtMilliseconds
        closureDigest = try CodexGhostRepairHasher.hash(
            CodexGhostRepairBulkPreparedClosurePayload(
                closureID: closureID,
                closureReviewID: preview.closureReviewID,
                reviewDigest: preview.reviewDigest,
                expectedPreparedJournalPayloadHash:
                    preview.expectedJournalPayloadHash,
                identity: preview.identity,
                confirmationReceiptID: preview.confirmationReceiptID,
                selectedItems: preview.selectedItems,
                planDigest: preview.planDigest,
                confirmationReceiptDigest:
                    preview.confirmationReceiptDigest,
                backupReceiptDigest: preview.backupReceiptDigest,
                preparedAtMilliseconds: preview.preparedAtMilliseconds,
                reviewedAtMilliseconds: preview.reviewedAtMilliseconds,
                reason: reason,
                closedAtMilliseconds: closedAtMilliseconds
            )
        )
        try validate()
    }

    public func validate() throws {
        let reviewPayload = CodexGhostRepairBulkPreparedClosureReviewPayload(
            closureReviewID: closureReviewID,
            identity: identity,
            confirmationReceiptID: confirmationReceiptID,
            selectedItems: selectedItems,
            planDigest: planDigest,
            confirmationReceiptDigest: confirmationReceiptDigest,
            backupReceiptDigest: backupReceiptDigest,
            expectedJournalPayloadHash: expectedPreparedJournalPayloadHash,
            preparedAtMilliseconds: preparedAtMilliseconds,
            reviewedAtMilliseconds: reviewedAtMilliseconds
        )
        guard (1...500).contains(selectedItems.count),
              Set(selectedItems.map(\.threadID)).count == selectedItems.count,
              selectedItems.allSatisfy({ !$0.threadID.isEmpty }),
              !reviewDigest.isEmpty,
              !expectedPreparedJournalPayloadHash.isEmpty,
              !planDigest.isEmpty,
              !confirmationReceiptDigest.isEmpty,
              !backupReceiptDigest.isEmpty,
              preparedAtMilliseconds >= 0,
              reviewedAtMilliseconds >= preparedAtMilliseconds,
              closedAtMilliseconds >= reviewedAtMilliseconds,
              try CodexGhostRepairHasher.hash(reviewPayload) == reviewDigest,
              try CodexGhostRepairHasher.hash(payload) == closureDigest else {
            throw PersistentStateError.invalidRecord(
                "Prepared closure record is not exact or checksummed."
            )
        }
    }

    private var payload: CodexGhostRepairBulkPreparedClosurePayload {
        .init(
            closureID: closureID,
            closureReviewID: closureReviewID,
            reviewDigest: reviewDigest,
            expectedPreparedJournalPayloadHash:
                expectedPreparedJournalPayloadHash,
            identity: identity,
            confirmationReceiptID: confirmationReceiptID,
            selectedItems: selectedItems,
            planDigest: planDigest,
            confirmationReceiptDigest: confirmationReceiptDigest,
            backupReceiptDigest: backupReceiptDigest,
            preparedAtMilliseconds: preparedAtMilliseconds,
            reviewedAtMilliseconds: reviewedAtMilliseconds,
            reason: reason,
            closedAtMilliseconds: closedAtMilliseconds
        )
    }
}

public struct CodexGhostRepairBulkPreparedClosureCapabilities:
    Equatable, Sendable
{
    public let explicitClosureAvailable: Bool
    public var readsManagerOwnedState: Bool { explicitClosureAvailable }
    public var writesManagerOwnedRecords: Bool { explicitClosureAvailable }
    public var readsCodexData: Bool { false }
    public var createsExecutionPreview: Bool { false }
    public var createsChallenge: Bool { false }
    public var createsReceipt: Bool { false }
    public var createsClaim: Bool { false }
    public var recordsMutationAttempt: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var retryAuthority: Bool { false }
    public var restoreAuthority: Bool { false }
    public var createsToken: Bool { false }

    public static let unavailable = Self(explicitClosureAvailable: false)
    public static let packagedExplicit = Self(explicitClosureAvailable: true)
}

public enum CodexGhostRepairBulkPreparedClosureReviewOutcome:
    Equatable, Sendable
{
    case ready(preview: CodexGhostRepairBulkPreparedClosurePreview)
    case alreadyClosed(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        closure: CodexGhostRepairBulkPreparedClosureRecord
    )
    case notClosable(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        message: String
    )
    case notFound(identity: CodexGhostRepairBulkRecoveryOperationIdentity)
    case unavailable(message: String)
}

public enum CodexGhostRepairBulkPreparedClosureCommitOutcome:
    Equatable, Sendable
{
    case closed(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        closure: CodexGhostRepairBulkPreparedClosureRecord,
        newlyClosed: Bool
    )
    case notClosable(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        message: String
    )
    case notFound(identity: CodexGhostRepairBulkRecoveryOperationIdentity)
    case persistenceUncertain(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        message: String
    )
    case unavailable(message: String)
}

public protocol CodexGhostRepairBulkPreparedClosureCoordinating: Sendable {
    var capabilities: CodexGhostRepairBulkPreparedClosureCapabilities { get }

    func reviewClosure(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkPreparedClosureReviewOutcome

    func closePreparedOperation(
        _ preview: CodexGhostRepairBulkPreparedClosurePreview
    ) async -> CodexGhostRepairBulkPreparedClosureCommitOutcome
}

public enum CodexGhostRepairBulkPreparedClosureCoordinatorFactory {
    /// Construction is zero-I/O. Work starts only after an explicit review or
    /// close call for one exact operation identity.
    public static func packagedExplicit()
        -> any CodexGhostRepairBulkPreparedClosureCoordinating
    {
        CodexGhostRepairBulkPreparedClosureLiveCoordinator.production()
    }
}

actor CodexGhostRepairBulkPreparedClosureLiveCoordinator:
    CodexGhostRepairBulkPreparedClosureCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkPreparedClosureCapabilities.packagedExplicit

    private let databaseURLProvider: @Sendable () throws -> URL
    private let fileExists: @Sendable (String) -> Bool
    private let operationExclusion: CodexGhostRepairBulkOperationExclusion
    private let nowMilliseconds: @Sendable () -> Int64
    private let makeUUID: @Sendable () -> UUID
    private let afterFinalizationForTesting: @Sendable () throws -> Void

    static func production() -> Self {
        Self(
            databaseURLProvider: {
                try StateStoreLocation.applicationSupportDatabaseURL()
            },
            operationExclusion: .production()
        )
    }

    init(
        databaseURLProvider: @escaping @Sendable () throws -> URL,
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        operationExclusion: CodexGhostRepairBulkOperationExclusion,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        afterFinalizationForTesting:
            @escaping @Sendable () throws -> Void = {}
    ) {
        self.databaseURLProvider = databaseURLProvider
        self.fileExists = fileExists
        self.operationExclusion = operationExclusion
        self.nowMilliseconds = nowMilliseconds
        self.makeUUID = makeUUID
        self.afterFinalizationForTesting = afterFinalizationForTesting
    }

    func reviewClosure(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkPreparedClosureReviewOutcome {
        do {
            let databaseURL = try databaseURLProvider()
            guard fileExists(databaseURL.path) else {
                return .notFound(identity: identity)
            }
            let reader = try CodexGhostRepairReadOnlyManagerStateStore(
                databaseURL: databaseURL
            )
            defer { reader.close() }
            guard let snapshot = try reader.recordSnapshot(identity: identity)
            else { return .notFound(identity: identity) }
            let record = snapshot.record
            let summary = try CodexGhostRepairBulkRecoveryLiveCoordinator
                .summary(record)
            guard try !reader.hasLegacyExecutionConflict(
                operationID: identity.operationID,
                confirmationReceiptDigest:
                    record.confirmationReceipt.receiptDigest
            ) else {
                return .notClosable(
                    summary: summary,
                    message:
                        "A legacy execution journal also owns this receipt or operation identity. Closure is unavailable."
                )
            }
            if record.phase == .closedBeforeAttempt,
               let closure = record.closure {
                return .alreadyClosed(summary: summary, closure: closure)
            }
            guard record.phase == .prepared else {
                return .notClosable(
                    summary: summary,
                    message:
                        "Only an exact prepared operation with no competing legacy execution journal can be closed before attempt."
                )
            }
            let reviewedAt = nowMilliseconds()
            guard reviewedAt >= record.plan.plannedAtMilliseconds else {
                return .notClosable(
                    summary: summary,
                    message:
                        "The clock moved behind the durable prepared operation. No closure review was created."
                )
            }
            return .ready(preview: try .init(
                identity: identity,
                confirmationReceiptID:
                    record.confirmationReceipt.receiptID,
                selectedItems: record.plan.selectedItems.map {
                    .init(threadID: $0.threadID, category: $0.category)
                },
                planDigest: record.plan.planDigest,
                confirmationReceiptDigest:
                    record.confirmationReceipt.receiptDigest,
                backupReceiptDigest: record.plan.backup.receiptDigest,
                expectedJournalPayloadHash: snapshot.payloadHash,
                preparedAtMilliseconds: record.plan.plannedAtMilliseconds,
                closureReviewID: makeUUID(),
                reviewedAtMilliseconds: reviewedAt
            ))
        } catch {
            return .unavailable(
                message:
                    "The exact prepared operation could not be reviewed as a current checksummed manager record."
            )
        }
    }

    func closePreparedOperation(
        _ preview: CodexGhostRepairBulkPreparedClosurePreview
    ) async -> CodexGhostRepairBulkPreparedClosureCommitOutcome {
        var finalizationBegan = false
        do {
            try preview.validate()
            let databaseURL = try databaseURLProvider()
            guard fileExists(databaseURL.path) else {
                return .notFound(identity: preview.identity)
            }
            let lease = try operationExclusion.acquire()
            defer { lease.release() }
            try lease.validateCurrentPath()
            guard let fileIdentity = lease.fileIdentity else {
                throw CodexGhostRepairError.recoveryRequired
            }
            let store = try SQLiteStateStore(
                existingCurrentDatabaseURL: databaseURL,
                expectedFileIdentity: fileIdentity
            )
            defer { store.close() }
            let closedAt = nowMilliseconds()
            guard closedAt >= preview.reviewedAtMilliseconds else {
                guard let current = try store
                    .codexGhostRepairBulkLiveExecutionJournal(
                        requestID: preview.identity.requestID
                    ), current.confirmationReceipt.operationID
                        == preview.identity.operationID else {
                    return .notFound(identity: preview.identity)
                }
                return .notClosable(
                    summary: try CodexGhostRepairBulkRecoveryLiveCoordinator
                        .summary(current),
                    message:
                        "The clock moved behind the explicit closure review. This closure request did not change the manager record."
                )
            }
            try lease.validateCurrentPath()
            finalizationBegan = true
            let outcome = try store.closeCodexGhostRepairBulkPreparedOperation(
                preview: preview,
                closureID: makeUUID(),
                closedAtMilliseconds: closedAt
            )
            switch outcome {
            case let .closed(record, newlyClosed):
                if newlyClosed { try afterFinalizationForTesting() }
                try lease.validateCurrentPath()
                guard let closure = record.closure else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                return .closed(
                    summary: try CodexGhostRepairBulkRecoveryLiveCoordinator
                        .summary(record),
                    closure: closure,
                    newlyClosed: newlyClosed
                )
            case let .notClosable(record):
                try lease.validateCurrentPath()
                return .notClosable(
                    summary: try CodexGhostRepairBulkRecoveryLiveCoordinator
                        .summary(record),
                    message:
                        "The exact operation is no longer the unchanged prepared record reviewed for closure. Nothing was replayed."
                )
            case .notFound:
                try lease.validateCurrentPath()
                return .notFound(identity: preview.identity)
            }
        } catch {
            if finalizationBegan {
                return .persistenceUncertain(
                    identity: preview.identity,
                    message:
                        "Prepared-operation closure or its durable readback became uncertain. Do not execute or close again; read the exact durable operation."
                )
            }
            return .unavailable(
                message:
                    "The prepared operation could not be closed as an exact current manager record. No Codex data was read or changed."
            )
        }
    }
}
