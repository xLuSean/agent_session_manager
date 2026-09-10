import CSQLite3
import Foundation

enum CodexGhostRepairBulkLiveJournalPhase:
    String,
    Codable,
    Equatable,
    Sendable
{
    case prepared
    case claimed
    case attempted
    case terminal
    case closedBeforeAttempt = "closed_before_attempt"
}

struct CodexGhostRepairBulkLiveTerminalItem:
    Codable,
    Equatable,
    Sendable
{
    let threadID: String
    let category: CodexGhostRepairCategory
    let outcome: CodexGhostRepairCategoryAItemOutcome
}

private struct CodexGhostRepairBulkLiveTerminalReportPayload:
    Codable,
    Equatable
{
    let reportID: UUID
    let requestID: UUID
    let planDigest: String
    let confirmationReceiptDigest: String
    let claimDigest: String
    let attemptDigest: String?
    let outcome: CodexGhostRepairCategoryABatchOutcome
    let items: [CodexGhostRepairBulkLiveTerminalItem]
    let completedAtMilliseconds: Int64
}

struct CodexGhostRepairBulkLiveTerminalReport:
    Codable,
    Equatable,
    Sendable
{
    let reportID: UUID
    let requestID: UUID
    let planDigest: String
    let confirmationReceiptDigest: String
    let claimDigest: String
    let attemptDigest: String?
    let outcome: CodexGhostRepairCategoryABatchOutcome
    let items: [CodexGhostRepairBulkLiveTerminalItem]
    let completedAtMilliseconds: Int64
    let reportDigest: String

    var automaticRetryAllowed: Bool { false }
    var automaticRestoreAllowed: Bool { false }
    var repairMutationAuthority: Bool { false }

    init(
        reportID: UUID,
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        receipt: CodexGhostRepairBulkConfirmationReceipt,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt?,
        outcome: CodexGhostRepairCategoryABatchOutcome,
        completedAtMilliseconds: Int64
    ) throws {
        let items = plan.selectedItems.map {
            CodexGhostRepairBulkLiveTerminalItem(
                threadID: $0.threadID,
                category: $0.category,
                outcome: Self.itemOutcome(for: $0, batchOutcome: outcome)
            )
        }
        let payload = CodexGhostRepairBulkLiveTerminalReportPayload(
            reportID: reportID,
            requestID: plan.requestID,
            planDigest: plan.planDigest,
            confirmationReceiptDigest: receipt.receiptDigest,
            claimDigest: claim.claimDigest,
            attemptDigest: attempt?.attemptDigest,
            outcome: outcome,
            items: items,
            completedAtMilliseconds: completedAtMilliseconds
        )
        self.reportID = reportID
        requestID = payload.requestID
        planDigest = payload.planDigest
        confirmationReceiptDigest = payload.confirmationReceiptDigest
        claimDigest = payload.claimDigest
        attemptDigest = payload.attemptDigest
        self.outcome = outcome
        self.items = items
        self.completedAtMilliseconds = completedAtMilliseconds
        reportDigest = try CodexGhostRepairHasher.hash(payload)
        try validate(
            plan: plan, receipt: receipt, claim: claim, attempt: attempt
        )
    }

    func validate(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        receipt: CodexGhostRepairBulkConfirmationReceipt,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt?
    ) throws {
        let payload = CodexGhostRepairBulkLiveTerminalReportPayload(
            reportID: reportID,
            requestID: requestID,
            planDigest: planDigest,
            confirmationReceiptDigest: confirmationReceiptDigest,
            claimDigest: claimDigest,
            attemptDigest: attemptDigest,
            outcome: outcome,
            items: items,
            completedAtMilliseconds: completedAtMilliseconds
        )
        let attemptRequired = outcome != .notAttempted
        guard requestID == plan.requestID,
              planDigest == plan.planDigest,
              confirmationReceiptDigest == receipt.receiptDigest,
              claimDigest == claim.claimDigest,
              attemptDigest == attempt?.attemptDigest,
              attemptRequired == (attempt != nil),
              items.map(\.threadID) == plan.selectedThreadIDs,
              items.map(\.category) == plan.selectedItems.map(\.category),
              items.map(\.outcome) == plan.selectedItems.map({
                  Self.itemOutcome(for: $0, batchOutcome: outcome)
              }),
              completedAtMilliseconds >= (attempt?.attemptedAtMilliseconds
                ?? claim.claimedAtMilliseconds),
              try CodexGhostRepairHasher.hash(payload) == reportDigest,
              !automaticRetryAllowed,
              !automaticRestoreAllowed,
              !repairMutationAuthority else {
            throw PersistentStateError.invalidRecord(
                "M4f-18 terminal Report does not match the exact batch."
            )
        }
    }

    private static func itemOutcome(
        for item: CodexGhostRepairBulkBackupBoundOperationItem,
        batchOutcome: CodexGhostRepairCategoryABatchOutcome
    ) -> CodexGhostRepairCategoryAItemOutcome {
        if batchOutcome == .success,
           item.expectedEffect == .alreadyAbsent {
            return .alreadyAbsent
        }
        return batchOutcome.itemOutcome
    }
}

struct CodexGhostRepairBulkLiveJournalRecord:
    Codable,
    Equatable,
    Sendable
{
    let plan: CodexGhostRepairBulkBackupBoundOperationPlan
    let confirmationReceipt: CodexGhostRepairBulkConfirmationReceipt
    let phase: CodexGhostRepairBulkLiveJournalPhase
    let claim: CodexGhostRepairBulkLiveMixedClaim?
    let attempt: CodexGhostRepairBulkLiveMixedAttempt?
    let report: CodexGhostRepairBulkLiveTerminalReport?
    let closure: CodexGhostRepairBulkPreparedClosureRecord?

    init(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        confirmationReceipt: CodexGhostRepairBulkConfirmationReceipt,
        phase: CodexGhostRepairBulkLiveJournalPhase,
        claim: CodexGhostRepairBulkLiveMixedClaim?,
        attempt: CodexGhostRepairBulkLiveMixedAttempt?,
        report: CodexGhostRepairBulkLiveTerminalReport?,
        closure: CodexGhostRepairBulkPreparedClosureRecord? = nil
    ) {
        self.plan = plan
        self.confirmationReceipt = confirmationReceipt
        self.phase = phase
        self.claim = claim
        self.attempt = attempt
        self.report = report
        self.closure = closure
    }

    var mutationAttemptCount: Int { attempt == nil ? 0 : 1 }
    var automaticRetryAllowed: Bool { false }
    var automaticRestoreAllowed: Bool { false }
    var silentSelectionShrinkAllowed: Bool { false }

    func validate() throws {
        try plan.validate()
        try Self.validateReceipt(confirmationReceipt, plan: plan)
        switch phase {
        case .prepared:
            guard claim == nil, attempt == nil, report == nil,
                  closure == nil else {
                throw invalidPhase()
            }
        case .claimed:
            guard let claim, attempt == nil, report == nil,
                  closure == nil else {
                throw invalidPhase()
            }
            try claim.validate(plan: plan)
        case .attempted:
            guard let claim, let attempt, report == nil,
                  closure == nil else {
                throw invalidPhase()
            }
            try claim.validate(plan: plan)
            try attempt.validate(claim: claim)
        case .terminal:
            guard let claim, let report, closure == nil else {
                throw invalidPhase()
            }
            try claim.validate(plan: plan)
            if let attempt { try attempt.validate(claim: claim) }
            try report.validate(
                plan: plan,
                receipt: confirmationReceipt,
                claim: claim,
                attempt: attempt
            )
        case .closedBeforeAttempt:
            guard claim == nil, attempt == nil, report == nil,
                  let closure else { throw invalidPhase() }
            try closure.validate()
            let closureItems = plan.selectedItems.map {
                CodexGhostRepairBulkPreparedClosureItem(
                    threadID: $0.threadID,
                    category: $0.category
                )
            }
            guard closure.identity.requestID == plan.requestID,
                  closure.identity.operationID
                    == confirmationReceipt.operationID,
                  closure.confirmationReceiptID
                    == confirmationReceipt.receiptID,
                  closure.selectedItems == closureItems,
                  closure.planDigest == plan.planDigest,
                  closure.confirmationReceiptDigest
                    == confirmationReceipt.receiptDigest,
                  closure.backupReceiptDigest
                    == plan.backup.receiptDigest,
                  closure.preparedAtMilliseconds
                    == plan.plannedAtMilliseconds,
                  closure.closedAtMilliseconds
                    >= plan.plannedAtMilliseconds else {
                throw invalidPhase()
            }
        }
        guard mutationAttemptCount <= 1,
              !automaticRetryAllowed,
              !automaticRestoreAllowed,
              !silentSelectionShrinkAllowed else {
            throw invalidPhase()
        }
    }

    static func validateReceipt(
        _ receipt: CodexGhostRepairBulkConfirmationReceipt,
        plan: CodexGhostRepairBulkBackupBoundOperationPlan
    ) throws {
        guard receipt.savedPreviewRequestID == plan.requestID,
              receipt.selectedCount == plan.selectedCount,
              receipt.confirmedAtMilliseconds <= plan.plannedAtMilliseconds,
              receipt.confirmedAtMilliseconds < plan.expiresAtMilliseconds,
              receipt.wholeBatchConfirmationRecorded,
              !receipt.createsRepairClaim,
              !receipt.repairClaimCreated,
              !receipt.repairMutationAuthority,
              !receipt.automaticRetryAllowed else {
            throw PersistentStateError.invalidRecord(
                "M4f-18 requires the exact confirmation-only receipt."
            )
        }
    }

    private func invalidPhase() -> PersistentStateError {
        .invalidRecord("M4f-18 live execution journal phase is inconsistent.")
    }
}

/// Canonical decoder for one persisted v20 journal row. Both the mutable
/// repository and Shipping's separate read-only recovery facade use this
/// validator so checksum and denormalized-column rules cannot drift apart.
struct CodexGhostRepairBulkLiveJournalPersistedRow: Sendable {
    let receiptID: UUID
    let receiptDigest: String
    let planDigest: String
    let backupDigest: String
    let selectedCount: Int
    let phase: CodexGhostRepairBulkLiveJournalPhase
    let claimDigest: String?
    let attemptDigest: String?
    let reportDigest: String?
    let closureDigest: String?
    let encodedPayload: String
    let payloadHash: String
    let mutationAttemptCount: Int
    let automaticRetryAllowed: Int64
    let automaticRestoreAllowed: Int64
    let silentSelectionShrinkAllowed: Int64

    func decodeValidated(
        requestID: UUID
    ) throws -> CodexGhostRepairBulkLiveJournalRecord {
        guard payloadHash
                == SQLiteStateStore.hashBulkPreviewPayload(encodedPayload)
        else {
            throw PersistentStateError.invalidRecord(
                "M4f-18 journal payload hash does not match."
            )
        }
        let record: CodexGhostRepairBulkLiveJournalRecord =
            try SQLiteStateStore.decodeBulkPreviewPayload(encodedPayload)
        try record.validate()
        guard record.plan.requestID == requestID,
              record.confirmationReceipt.receiptID == receiptID,
              record.confirmationReceipt.receiptDigest == receiptDigest,
              record.plan.planDigest == planDigest,
              record.plan.backup.receiptDigest == backupDigest,
              record.plan.selectedCount == selectedCount,
              record.phase == phase,
              record.claim?.claimDigest == claimDigest,
              record.attempt?.attemptDigest == attemptDigest,
              record.report?.reportDigest == reportDigest,
              record.closure?.closureDigest == closureDigest,
              record.mutationAttemptCount == mutationAttemptCount,
              automaticRetryAllowed == 0,
              automaticRestoreAllowed == 0,
              silentSelectionShrinkAllowed == 0 else {
            throw PersistentStateError.invalidRecord(
                "M4f-18 journal columns and payload disagree."
            )
        }
        return record
    }
}

struct CodexGhostRepairBulkValidatedJournalSnapshot: Sendable {
    let record: CodexGhostRepairBulkLiveJournalRecord
    let payloadHash: String
}

extension SQLiteStateStore {
    enum PreparedClosureWriteOutcome {
        case closed(
            CodexGhostRepairBulkLiveJournalRecord,
            newlyClosed: Bool
        )
        case notClosable(CodexGhostRepairBulkLiveJournalRecord)
        case notFound
    }

    @discardableResult
    func prepareCodexGhostRepairBulkLiveExecutionJournal(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        confirmationReceipt: CodexGhostRepairBulkConfirmationReceipt
    ) throws -> CodexGhostRepairBulkLiveJournalRecord {
        let proposed = CodexGhostRepairBulkLiveJournalRecord(
            plan: plan,
            confirmationReceipt: confirmationReceipt,
            phase: .prepared,
            claim: nil,
            attempt: nil,
            report: nil
        )
        try proposed.validate()
        return try withLockedDatabase { database in
            try transaction(database) {
                try requireExactBulkLiveReceipt(
                    confirmationReceipt,
                    plan: plan,
                    database: database
                )
                if let existing = try loadBulkLiveExecutionJournal(
                    requestID: plan.requestID,
                    database: database
                ) {
                    guard existing.plan == plan,
                          existing.confirmationReceipt
                            == confirmationReceipt else {
                        throw PersistentStateError.invalidRecord(
                            "M4f-18 request already belongs to another operation."
                        )
                    }
                    return existing
                }
                try writeBulkLiveExecutionJournal(
                    proposed,
                    expectedPhase: nil,
                    database: database
                )
                return try exactBulkLiveExecutionJournal(
                    requestID: plan.requestID,
                    expected: proposed,
                    database: database
                )
            }
        }
    }

    func claimCodexGhostRepairBulkLiveExecution(
        requestID: UUID,
        expectedPlanDigest: String,
        claimID: UUID,
        claimedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkLiveMixedClaim {
        try withLockedDatabase { database in
            try transaction(database) {
                let record = try requireBulkLiveExecutionJournal(
                    requestID: requestID,
                    database: database
                )
                guard record.phase == .prepared,
                      record.plan.planDigest == expectedPlanDigest else {
                    throw CodexGhostRepairError.claimAlreadyExists
                }
                let claim = try CodexGhostRepairBulkLiveMixedClaim(
                    claimID: claimID,
                    plan: record.plan,
                    claimedAtMilliseconds: claimedAtMilliseconds
                )
                let updated = CodexGhostRepairBulkLiveJournalRecord(
                    plan: record.plan,
                    confirmationReceipt: record.confirmationReceipt,
                    phase: .claimed,
                    claim: claim,
                    attempt: nil,
                    report: nil
                )
                try writeBulkLiveExecutionJournal(
                    updated,
                    expectedPhase: .prepared,
                    database: database
                )
                _ = try exactBulkLiveExecutionJournal(
                    requestID: requestID,
                    expected: updated,
                    database: database
                )
                return claim
            }
        }
    }

    func recordCodexGhostRepairBulkLiveExecutionAttempt(
        requestID: UUID,
        expectedClaimDigest: String,
        attemptedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkLiveMixedAttempt {
        try withLockedDatabase { database in
            try transaction(database) {
                let record = try requireBulkLiveExecutionJournal(
                    requestID: requestID,
                    database: database
                )
                guard record.phase == .claimed,
                      let claim = record.claim,
                      claim.claimDigest == expectedClaimDigest else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                let attempt = try CodexGhostRepairBulkLiveMixedAttempt(
                    claim: claim,
                    attemptedAtMilliseconds: attemptedAtMilliseconds
                )
                let updated = CodexGhostRepairBulkLiveJournalRecord(
                    plan: record.plan,
                    confirmationReceipt: record.confirmationReceipt,
                    phase: .attempted,
                    claim: claim,
                    attempt: attempt,
                    report: nil
                )
                try writeBulkLiveExecutionJournal(
                    updated,
                    expectedPhase: .claimed,
                    database: database
                )
                _ = try exactBulkLiveExecutionJournal(
                    requestID: requestID,
                    expected: updated,
                    database: database
                )
                return attempt
            }
        }
    }

    @discardableResult
    func recordCodexGhostRepairBulkLiveTerminalReport(
        _ report: CodexGhostRepairBulkLiveTerminalReport
    ) throws -> CodexGhostRepairBulkLiveJournalRecord {
        try recordCodexGhostRepairBulkLiveTerminalReport(
            report,
            expectedUnresolvedRecord: nil
        )
    }

    /// Recovery-only compare-and-swap. The caller must provide the exact
    /// checksummed unresolved record observed before private readback.
    @discardableResult
    func recordCodexGhostRepairBulkLiveTerminalReport(
        _ report: CodexGhostRepairBulkLiveTerminalReport,
        expectedUnresolvedRecord:
            CodexGhostRepairBulkLiveJournalRecord?
    ) throws -> CodexGhostRepairBulkLiveJournalRecord {
        try withLockedDatabase { database in
            try transaction(database) {
                let record = try requireBulkLiveExecutionJournal(
                    requestID: report.requestID,
                    database: database
                )
                if let expectedUnresolvedRecord {
                    try expectedUnresolvedRecord.validate()
                    guard record == expectedUnresolvedRecord,
                          record.phase != .terminal,
                          let durableReceipt = try
                            loadCodexGhostRepairBulkReceipt(
                                savedPreviewRequestID:
                                    record.plan.requestID,
                                database: database
                            ),
                          durableReceipt
                            == record.confirmationReceipt else {
                        throw CodexGhostRepairError.recoveryRequired
                    }
                }
                let expectedPhase: CodexGhostRepairBulkLiveJournalPhase
                switch report.outcome {
                case .notAttempted:
                    expectedPhase = .claimed
                case .success, .explicitFailure, .unknown:
                    expectedPhase = .attempted
                }
                guard record.phase == expectedPhase,
                      let claim = record.claim else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                try report.validate(
                    plan: record.plan,
                    receipt: record.confirmationReceipt,
                    claim: claim,
                    attempt: record.attempt
                )
                let updated = CodexGhostRepairBulkLiveJournalRecord(
                    plan: record.plan,
                    confirmationReceipt: record.confirmationReceipt,
                    phase: .terminal,
                    claim: claim,
                    attempt: record.attempt,
                    report: report
                )
                try writeBulkLiveExecutionJournal(
                    updated,
                    expectedPhase: expectedPhase,
                    database: database
                )
                return try exactBulkLiveExecutionJournal(
                    requestID: report.requestID,
                    expected: updated,
                    database: database
                )
            }
        }
    }

    func codexGhostRepairBulkLiveExecutionJournal(
        requestID: UUID
    ) throws -> CodexGhostRepairBulkLiveJournalRecord? {
        try withLockedDatabase { database in
            try loadBulkLiveExecutionJournal(
                requestID: requestID,
                database: database
            )
        }
    }

    func validatedCodexGhostRepairBulkLiveJournalSnapshot(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkValidatedJournalSnapshot? {
        guard let record = try loadBulkLiveExecutionJournal(
            requestID: identity.requestID,
            database: database
        ) else { return nil }
        guard record.confirmationReceipt.operationID == identity.operationID else {
            throw CodexGhostRepairError.recoveryRequired
        }
        try requireExactBulkLiveReceipt(
            record.confirmationReceipt,
            plan: record.plan,
            database: database
        )
        guard try legacyBulkExecutionConflicts(
            operationID: identity.operationID,
            receiptDigest: record.confirmationReceipt.receiptDigest,
            database: database
        ) == false else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return .init(
            record: record,
            payloadHash: try bulkLiveExecutionPayloadHash(
                requestID: identity.requestID,
                database: database
            )
        )
    }

    func closeCodexGhostRepairBulkPreparedOperation(
        preview: CodexGhostRepairBulkPreparedClosurePreview,
        closureID: UUID,
        closedAtMilliseconds: Int64
    ) throws -> PreparedClosureWriteOutcome {
        try preview.validate()
        return try withLockedDatabase { database in
            try transaction(database) {
                guard let record = try loadBulkLiveExecutionJournal(
                    requestID: preview.identity.requestID,
                    database: database
                ), record.confirmationReceipt.operationID
                    == preview.identity.operationID else {
                    return .notFound
                }
                guard let durableReceipt = try
                    loadCodexGhostRepairBulkReceipt(
                        savedPreviewRequestID: record.plan.requestID,
                        database: database
                    ), durableReceipt == record.confirmationReceipt else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                guard try legacyBulkExecutionConflicts(
                    operationID: record.confirmationReceipt.operationID,
                    receiptDigest: record.confirmationReceipt.receiptDigest,
                    database: database
                ) == false else {
                    return .notClosable(record)
                }
                if record.phase == .closedBeforeAttempt,
                   let closure = record.closure,
                   closure.closureReviewID == preview.closureReviewID,
                   closure.reviewDigest == preview.reviewDigest,
                   closure.expectedPreparedJournalPayloadHash
                    == preview.expectedJournalPayloadHash {
                    return .closed(record, newlyClosed: false)
                }
                let items = record.plan.selectedItems.map {
                    CodexGhostRepairBulkPreparedClosureItem(
                        threadID: $0.threadID,
                        category: $0.category
                    )
                }
                let currentPayloadHash = try bulkLiveExecutionPayloadHash(
                    requestID: record.plan.requestID,
                    database: database
                )
                guard record.phase == .prepared,
                      record.claim == nil,
                      record.attempt == nil,
                      record.report == nil,
                      record.closure == nil,
                      preview.confirmationReceiptID
                        == record.confirmationReceipt.receiptID,
                      preview.selectedItems == items,
                      preview.planDigest == record.plan.planDigest,
                      preview.confirmationReceiptDigest
                        == record.confirmationReceipt.receiptDigest,
                      preview.backupReceiptDigest
                        == record.plan.backup.receiptDigest,
                      preview.preparedAtMilliseconds
                        == record.plan.plannedAtMilliseconds,
                      currentPayloadHash
                        == preview.expectedJournalPayloadHash,
                      closedAtMilliseconds >= preview.reviewedAtMilliseconds else {
                    return .notClosable(record)
                }
                let closure = try CodexGhostRepairBulkPreparedClosureRecord(
                    closureID: closureID,
                    preview: preview,
                    reason: .userClosedUnstartedPlan,
                    closedAtMilliseconds: closedAtMilliseconds
                )
                let updated = CodexGhostRepairBulkLiveJournalRecord(
                    plan: record.plan,
                    confirmationReceipt: record.confirmationReceipt,
                    phase: .closedBeforeAttempt,
                    claim: nil,
                    attempt: nil,
                    report: nil,
                    closure: closure
                )
                try writeBulkLiveExecutionJournal(
                    updated,
                    expectedPhase: .prepared,
                    expectedPayloadHash: preview.expectedJournalPayloadHash,
                    database: database
                )
                return .closed(
                    try exactBulkLiveExecutionJournal(
                        requestID: record.plan.requestID,
                        expected: updated,
                        database: database
                    ),
                    newlyClosed: true
                )
            }
        }
    }

    func codexGhostRepairBulkHasLegacyExecutionConflict(
        operationID: UUID,
        receiptDigest: String
    ) throws -> Bool {
        try withLockedDatabase { database in
            try legacyBulkExecutionConflicts(
                operationID: operationID,
                receiptDigest: receiptDigest,
                database: database
            )
        }
    }

    private func legacyBulkExecutionConflicts(
        operationID: UUID,
        receiptDigest: String,
        database: OpaquePointer
    ) throws -> Bool {
        let rows = try query(
            """
            SELECT 1
            FROM codex_ghost_repair_bulk_execution_journal
            WHERE operation_id = ? OR confirmation_receipt_digest = ?
            LIMIT 1
            """,
            values: [
                .text(operationID.uuidString.lowercased()),
                .text(receiptDigest),
            ],
            database: database
        ) { _ in true }
        return !rows.isEmpty
    }

    private func bulkLiveExecutionPayloadHash(
        requestID: UUID,
        database: OpaquePointer
    ) throws -> String {
        let rows = try query(
            "SELECT payload_hash FROM codex_ghost_repair_bulk_live_execution_journal WHERE request_id = ?",
            values: [.text(requestID.uuidString.lowercased())],
            database: database
        ) { statement in try requiredText(statement, 0) }
        guard rows.count == 1 else {
            throw PersistentStateError.invalidRecord(
                "Bulk journal payload hash is missing or duplicated."
            )
        }
        return rows[0]
    }

    func codexGhostRepairBulkLiveExecutionJournal(
        confirmationReceiptID: UUID
    ) throws -> CodexGhostRepairBulkLiveJournalRecord? {
        try withLockedDatabase { database in
            let requestIDs = try query(
                """
                SELECT request_id
                FROM codex_ghost_repair_bulk_live_execution_journal
                WHERE confirmation_receipt_id = ?
                """,
                values: [
                    .text(confirmationReceiptID.uuidString.lowercased()),
                ],
                database: database
            ) { statement in
                try Self.bulkCanonicalUUID(requiredText(statement, 0))
            }
            guard requestIDs.count <= 1 else {
                throw PersistentStateError.invalidRecord(
                    "Duplicate M4f-18 confirmation receipt identities."
                )
            }
            guard let requestID = requestIDs.first else { return nil }
            return try loadBulkLiveExecutionJournal(
                requestID: requestID,
                database: database
            )
        }
    }

    private func requireExactBulkLiveReceipt(
        _ receipt: CodexGhostRepairBulkConfirmationReceipt,
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        database: OpaquePointer
    ) throws {
        let rows = try query(
            """
            SELECT receipt_id, operation_id, challenge_digest,
                   confirmation_phrase_hash, selected_count,
                   confirmed_at_ms, receipt_digest,
                   confirmation_recorded, repair_claim_created,
                   repair_mutation_authority, automatic_retry_allowed
            FROM codex_ghost_repair_bulk_confirmation_receipts
            WHERE saved_preview_request_id = ?
            """,
            values: [.text(plan.requestID.uuidString.lowercased())],
            database: database
        ) { statement -> (String, String, String, String, Int, Int64, String,
                           Int64, Int64, Int64, Int64) in
            (
                try requiredText(statement, 0),
                try requiredText(statement, 1),
                try requiredText(statement, 2),
                try requiredText(statement, 3),
                Int(sqlite3_column_int64(statement, 4)),
                sqlite3_column_int64(statement, 5),
                try requiredText(statement, 6),
                sqlite3_column_int64(statement, 7),
                sqlite3_column_int64(statement, 8),
                sqlite3_column_int64(statement, 9),
                sqlite3_column_int64(statement, 10)
            )
        }
        guard rows.count == 1 else {
            throw PersistentStateError.invalidRecord(
                "M4f-18 confirmation receipt is missing or duplicated."
            )
        }
        let row = rows[0]
        guard row.0 == receipt.receiptID.uuidString.lowercased(),
              row.1 == receipt.operationID.uuidString.lowercased(),
              row.2 == receipt.challengeDigest,
              row.3 == receipt.confirmationPhraseHash,
              row.4 == receipt.selectedCount,
              row.5 == receipt.confirmedAtMilliseconds,
              row.6 == receipt.receiptDigest,
              row.7 == 1, row.8 == 0, row.9 == 0, row.10 == 0 else {
            throw PersistentStateError.invalidRecord(
                "M4f-18 confirmation receipt changed before journaling."
            )
        }
    }

    private func requireBulkLiveExecutionJournal(
        requestID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkLiveJournalRecord {
        guard let record = try loadBulkLiveExecutionJournal(
            requestID: requestID,
            database: database
        ) else {
            throw PersistentStateError.recordNotFound(
                requestID.uuidString.lowercased()
            )
        }
        return record
    }

    private func exactBulkLiveExecutionJournal(
        requestID: UUID,
        expected: CodexGhostRepairBulkLiveJournalRecord,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkLiveJournalRecord {
        guard let readback = try loadBulkLiveExecutionJournal(
            requestID: requestID,
            database: database
        ), readback == expected else {
            throw PersistentStateError.invalidRecord(
                "M4f-18 journal exact readback did not match."
            )
        }
        return readback
    }

    private func writeBulkLiveExecutionJournal(
        _ record: CodexGhostRepairBulkLiveJournalRecord,
        expectedPhase: CodexGhostRepairBulkLiveJournalPhase?,
        expectedPayloadHash: String? = nil,
        database: OpaquePointer
    ) throws {
        try record.validate()
        let encoded = try Self.encodeBulkPreviewPayload(record)
        let payloadHash = Self.hashBulkPreviewPayload(encoded)
        if let expectedPhase {
            let expectedHashPredicate = expectedPayloadHash == nil
                ? "" : " AND payload_hash = ?"
            var values: [RepositorySQLiteValue] = [
                .text(record.phase.rawValue),
                record.claim.map { .text($0.claimDigest) } ?? .null,
                record.attempt.map { .text($0.attemptDigest) } ?? .null,
                record.report.map { .text($0.reportDigest) } ?? .null,
                record.closure.map { .text($0.closureDigest) } ?? .null,
                .text(encoded), .text(payloadHash),
                .int64(Int64(record.mutationAttemptCount)),
                .text(record.plan.requestID.uuidString.lowercased()),
                .text(expectedPhase.rawValue),
            ]
            if let expectedPayloadHash {
                values.append(.text(expectedPayloadHash))
            }
            try execute(
                """
                UPDATE codex_ghost_repair_bulk_live_execution_journal
                SET phase = ?, claim_digest = ?, attempt_digest = ?,
                    terminal_report_digest = ?, closure_digest = ?, payload_json = ?,
                    payload_hash = ?, mutation_attempt_count = ?
                WHERE request_id = ? AND phase = ?\(expectedHashPredicate)
                """,
                values: values,
                database: database
            )
            guard sqlite3_changes(database) == 1 else {
                throw CodexGhostRepairError.recoveryRequired
            }
        } else {
            try execute(
                """
                INSERT INTO codex_ghost_repair_bulk_live_execution_journal (
                    request_id, confirmation_receipt_id,
                    confirmation_receipt_digest, plan_digest,
                    backup_receipt_digest, selected_count, phase,
                    claim_digest, attempt_digest, terminal_report_digest,
                    closure_digest, payload_json, payload_hash, mutation_attempt_count,
                    automatic_retry_allowed, automatic_restore_allowed,
                    silent_selection_shrink_allowed
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, ?, ?, 0, 0, 0, 0)
                """,
                values: [
                    .text(record.plan.requestID.uuidString.lowercased()),
                    .text(record.confirmationReceipt.receiptID
                        .uuidString.lowercased()),
                    .text(record.confirmationReceipt.receiptDigest),
                    .text(record.plan.planDigest),
                    .text(record.plan.backup.receiptDigest),
                    .int64(Int64(record.plan.selectedCount)),
                    .text(record.phase.rawValue),
                    .text(encoded), .text(payloadHash),
                ],
                database: database
            )
        }
    }

    func loadBulkLiveExecutionJournal(
        requestID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkLiveJournalRecord? {
        let rows = try query(
            """
            SELECT confirmation_receipt_id, confirmation_receipt_digest,
                   plan_digest, backup_receipt_digest, selected_count,
                   phase, claim_digest, attempt_digest,
                   terminal_report_digest, closure_digest, payload_json, payload_hash,
                   mutation_attempt_count, automatic_retry_allowed,
                   automatic_restore_allowed,
                   silent_selection_shrink_allowed
            FROM codex_ghost_repair_bulk_live_execution_journal
            WHERE request_id = ?
            """,
            values: [.text(requestID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairBulkLiveJournalRecord in
            let receiptID = try Self.bulkCanonicalUUID(
                requiredText(statement, 0)
            )
            let receiptDigest = try requiredText(statement, 1)
            let planDigest = try requiredText(statement, 2)
            let backupDigest = try requiredText(statement, 3)
            let selectedCount = Int(sqlite3_column_int64(statement, 4))
            guard let phase = CodexGhostRepairBulkLiveJournalPhase(
                rawValue: try requiredText(statement, 5)
            ) else {
                throw PersistentStateError.invalidRecord(
                    "M4f-18 journal phase is unknown."
                )
            }
            let claimDigest = optionalText(statement, 6)
            let attemptDigest = optionalText(statement, 7)
            let reportDigest = optionalText(statement, 8)
            let closureDigest = optionalText(statement, 9)
            let encoded = try requiredText(statement, 10)
            let payloadHash = try requiredText(statement, 11)
            let attemptCount = Int(sqlite3_column_int64(statement, 12))
            let retry = sqlite3_column_int64(statement, 13)
            let restore = sqlite3_column_int64(statement, 14)
            let shrink = sqlite3_column_int64(statement, 15)
            return try CodexGhostRepairBulkLiveJournalPersistedRow(
                receiptID: receiptID,
                receiptDigest: receiptDigest,
                planDigest: planDigest,
                backupDigest: backupDigest,
                selectedCount: selectedCount,
                phase: phase,
                claimDigest: claimDigest,
                attemptDigest: attemptDigest,
                reportDigest: reportDigest,
                closureDigest: closureDigest,
                encodedPayload: encoded,
                payloadHash: payloadHash,
                mutationAttemptCount: attemptCount,
                automaticRetryAllowed: retry,
                automaticRestoreAllowed: restore,
                silentSelectionShrinkAllowed: shrink
            ).decodeValidated(requestID: requestID)
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate M4f-18 journal records."
            )
        }
        return rows.first
    }
}
