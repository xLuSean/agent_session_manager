import CSQLite3
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH

enum CodexGhostRepairBulkProductionJournalPhase:
    String,
    Codable,
    Equatable,
    Sendable
{
    case prepared
    case claimed
    case attempted
    case terminal
}

private struct CodexGhostRepairBulkProductionClaimPayload:
    Codable,
    Hashable
{
    let claimID: UUID
    let operationID: UUID
    let draftDigest: String
    let planDigest: String
    let selectedThreadIDs: [String]
    let claimedAtMilliseconds: Int64
}

struct CodexGhostRepairBulkProductionClaim:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let claimID: UUID
    let operationID: UUID
    let draftDigest: String
    let planDigest: String
    let selectedThreadIDs: [String]
    let claimedAtMilliseconds: Int64
    let claimDigest: String

    var mutationAttempted: Bool { false }
    var automaticRetryAllowed: Bool { false }
    var automaticRestoreAllowed: Bool { false }

    init(
        claimID: UUID,
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claimedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairBulkProductionClaimPayload(
            claimID: claimID,
            operationID: draft.operationID,
            draftDigest: draft.draftDigest,
            planDigest: draft.planDigest,
            selectedThreadIDs: draft.selectedThreadIDs,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
        self.claimID = claimID
        operationID = draft.operationID
        draftDigest = draft.draftDigest
        planDigest = draft.planDigest
        selectedThreadIDs = draft.selectedThreadIDs
        self.claimedAtMilliseconds = claimedAtMilliseconds
        claimDigest = try CodexGhostRepairHasher.hash(payload)
    }

    func validate(draft: CodexGhostRepairBulkProductionExecutionDraft) throws {
        let payload = CodexGhostRepairBulkProductionClaimPayload(
            claimID: claimID,
            operationID: operationID,
            draftDigest: draftDigest,
            planDigest: planDigest,
            selectedThreadIDs: selectedThreadIDs,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
        guard operationID == draft.operationID,
              draftDigest == draft.draftDigest,
              planDigest == draft.planDigest,
              selectedThreadIDs == draft.selectedThreadIDs,
              claimedAtMilliseconds >= draft.preparedAtMilliseconds,
              claimedAtMilliseconds < draft.expiresAtMilliseconds,
              try CodexGhostRepairHasher.hash(payload) == claimDigest,
              !mutationAttempted,
              !automaticRetryAllowed,
              !automaticRestoreAllowed else {
            throw PersistentStateError.invalidRecord(
                "Bulk execution claim does not match the frozen draft."
            )
        }
    }
}

private struct CodexGhostRepairBulkProductionAttemptPayload:
    Codable,
    Hashable
{
    let operationID: UUID
    let claimDigest: String
    let attemptedAtMilliseconds: Int64
}

struct CodexGhostRepairBulkProductionAttempt:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let claimDigest: String
    let attemptedAtMilliseconds: Int64
    let attemptDigest: String

    var attemptOrdinal: Int { 1 }
    var automaticRetryAllowed: Bool { false }

    init(
        claim: CodexGhostRepairBulkProductionClaim,
        attemptedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairBulkProductionAttemptPayload(
            operationID: claim.operationID,
            claimDigest: claim.claimDigest,
            attemptedAtMilliseconds: attemptedAtMilliseconds
        )
        operationID = claim.operationID
        claimDigest = claim.claimDigest
        self.attemptedAtMilliseconds = attemptedAtMilliseconds
        attemptDigest = try CodexGhostRepairHasher.hash(payload)
    }

    func validate(claim: CodexGhostRepairBulkProductionClaim) throws {
        let payload = CodexGhostRepairBulkProductionAttemptPayload(
            operationID: operationID,
            claimDigest: claimDigest,
            attemptedAtMilliseconds: attemptedAtMilliseconds
        )
        guard operationID == claim.operationID,
              claimDigest == claim.claimDigest,
              attemptedAtMilliseconds >= claim.claimedAtMilliseconds,
              try CodexGhostRepairHasher.hash(payload) == attemptDigest,
              attemptOrdinal == 1,
              !automaticRetryAllowed else {
            throw PersistentStateError.invalidRecord(
                "Bulk execution attempt does not match the one-shot claim."
            )
        }
    }
}

struct CodexGhostRepairBulkProductionTerminalItem:
    Codable,
    Equatable,
    Sendable
{
    let threadID: String
    let category: CodexGhostRepairCategory
    let outcome: CodexGhostRepairCategoryAItemOutcome
}

private struct CodexGhostRepairBulkProductionTerminalReportPayload:
    Codable,
    Equatable
{
    let reportID: UUID
    let operationID: UUID
    let draftDigest: String
    let claimDigest: String
    let attemptDigest: String?
    let outcome: CodexGhostRepairCategoryABatchOutcome
    let items: [CodexGhostRepairBulkProductionTerminalItem]
    let completedAtMilliseconds: Int64
}

struct CodexGhostRepairBulkProductionTerminalReport:
    Codable,
    Equatable,
    Sendable
{
    let reportID: UUID
    let operationID: UUID
    let draftDigest: String
    let claimDigest: String
    let attemptDigest: String?
    let outcome: CodexGhostRepairCategoryABatchOutcome
    let items: [CodexGhostRepairBulkProductionTerminalItem]
    let completedAtMilliseconds: Int64
    let reportDigest: String

    var automaticRetryAllowed: Bool { false }
    var automaticRestoreAllowed: Bool { false }
    var repairMutationAuthority: Bool { false }

    init(
        reportID: UUID,
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claim: CodexGhostRepairBulkProductionClaim,
        attempt: CodexGhostRepairBulkProductionAttempt?,
        outcome: CodexGhostRepairCategoryABatchOutcome,
        completedAtMilliseconds: Int64
    ) throws {
        let items = draft.selectedItems.map {
            CodexGhostRepairBulkProductionTerminalItem(
                threadID: $0.threadID,
                category: $0.category,
                outcome: outcome.itemOutcome
            )
        }
        let payload = CodexGhostRepairBulkProductionTerminalReportPayload(
            reportID: reportID,
            operationID: draft.operationID,
            draftDigest: draft.draftDigest,
            claimDigest: claim.claimDigest,
            attemptDigest: attempt?.attemptDigest,
            outcome: outcome,
            items: items,
            completedAtMilliseconds: completedAtMilliseconds
        )
        self.reportID = reportID
        operationID = draft.operationID
        draftDigest = draft.draftDigest
        claimDigest = claim.claimDigest
        attemptDigest = attempt?.attemptDigest
        self.outcome = outcome
        self.items = items
        self.completedAtMilliseconds = completedAtMilliseconds
        reportDigest = try CodexGhostRepairHasher.hash(payload)
        try validate(draft: draft, claim: claim, attempt: attempt)
    }

    func validate(
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claim: CodexGhostRepairBulkProductionClaim,
        attempt: CodexGhostRepairBulkProductionAttempt?
    ) throws {
        let payload = CodexGhostRepairBulkProductionTerminalReportPayload(
            reportID: reportID,
            operationID: operationID,
            draftDigest: draftDigest,
            claimDigest: claimDigest,
            attemptDigest: attemptDigest,
            outcome: outcome,
            items: items,
            completedAtMilliseconds: completedAtMilliseconds
        )
        let attemptRequired = outcome != .notAttempted
        guard operationID == draft.operationID,
              draftDigest == draft.draftDigest,
              claimDigest == claim.claimDigest,
              attemptDigest == attempt?.attemptDigest,
              attemptRequired == (attempt != nil),
              items.map(\.threadID) == draft.selectedThreadIDs,
              items.map(\.category) == draft.selectedItems.map(\.category),
              items.allSatisfy({ $0.outcome == outcome.itemOutcome }),
              completedAtMilliseconds >= (attempt?.attemptedAtMilliseconds
                  ?? claim.claimedAtMilliseconds),
              try CodexGhostRepairHasher.hash(payload) == reportDigest,
              !automaticRetryAllowed,
              !automaticRestoreAllowed,
              !repairMutationAuthority else {
            throw PersistentStateError.invalidRecord(
                "Bulk terminal Report does not itemize the exact frozen batch."
            )
        }
    }
}

struct CodexGhostRepairBulkProductionJournalRecord:
    Codable,
    Equatable,
    Sendable
{
    let draft: CodexGhostRepairBulkProductionExecutionDraft
    let phase: CodexGhostRepairBulkProductionJournalPhase
    let claim: CodexGhostRepairBulkProductionClaim?
    let attempt: CodexGhostRepairBulkProductionAttempt?
    let report: CodexGhostRepairBulkProductionTerminalReport?

    var mutationAttemptCount: Int { attempt == nil ? 0 : 1 }
    var automaticRetryAllowed: Bool { false }
    var automaticRestoreAllowed: Bool { false }
    var silentSelectionShrinkAllowed: Bool { false }

    func validate() throws {
        try draft.validate()
        switch phase {
        case .prepared:
            guard claim == nil, attempt == nil, report == nil else {
                throw invalidPhase()
            }
        case .claimed:
            guard let claim, attempt == nil, report == nil else {
                throw invalidPhase()
            }
            try claim.validate(draft: draft)
        case .attempted:
            guard let claim, let attempt, report == nil else {
                throw invalidPhase()
            }
            try claim.validate(draft: draft)
            try attempt.validate(claim: claim)
        case .terminal:
            guard let claim, let report else { throw invalidPhase() }
            try claim.validate(draft: draft)
            if let attempt { try attempt.validate(claim: claim) }
            try report.validate(draft: draft, claim: claim, attempt: attempt)
        }
        guard mutationAttemptCount <= 1,
              !automaticRetryAllowed,
              !automaticRestoreAllowed,
              !silentSelectionShrinkAllowed else {
            throw invalidPhase()
        }
    }

    private func invalidPhase() -> PersistentStateError {
        .invalidRecord("Bulk execution journal phase is inconsistent.")
    }
}

extension SQLiteStateStore {
    @discardableResult
    func prepareCodexGhostRepairBulkExecutionJournal(
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) throws -> CodexGhostRepairBulkProductionJournalRecord {
        try draft.validate()
        return try withLockedDatabase { database in
            try transaction(database) {
                let receiptRows = try query(
                    """
                    SELECT receipt_digest, selected_count,
                           repair_claim_created, repair_mutation_authority,
                           automatic_retry_allowed
                    FROM codex_ghost_repair_bulk_confirmation_receipts
                    WHERE operation_id = ?
                    """,
                    values: [.text(draft.operationID.uuidString.lowercased())],
                    database: database
                ) { statement -> (String, Int, Int64, Int64, Int64) in
                    (
                        try requiredText(statement, 0),
                        Int(sqlite3_column_int64(statement, 1)),
                        sqlite3_column_int64(statement, 2),
                        sqlite3_column_int64(statement, 3),
                        sqlite3_column_int64(statement, 4)
                    )
                }
                guard receiptRows.count == 1,
                      receiptRows[0].0 == draft.confirmationReceiptDigest,
                      receiptRows[0].1 == draft.selectedThreadIDs.count,
                      receiptRows[0].2 == 0,
                      receiptRows[0].3 == 0,
                      receiptRows[0].4 == 0 else {
                    throw PersistentStateError.invalidRecord(
                        "Bulk execution draft lost its exact confirmation receipt."
                    )
                }
                if let existing = try loadBulkExecutionJournal(
                    operationID: draft.operationID,
                    database: database
                ) {
                    guard existing.draft == draft else {
                        throw PersistentStateError.invalidRecord(
                            "Bulk execution operation already belongs to another draft."
                        )
                    }
                    return existing
                }
                let record = CodexGhostRepairBulkProductionJournalRecord(
                    draft: draft,
                    phase: .prepared,
                    claim: nil,
                    attempt: nil,
                    report: nil
                )
                try insertOrUpdateBulkExecutionJournal(
                    record,
                    expectedPhase: nil,
                    database: database
                )
                return try exactBulkExecutionJournal(
                    operationID: draft.operationID,
                    expected: record,
                    database: database
                )
            }
        }
    }

    func claimCodexGhostRepairBulkExecution(
        operationID: UUID,
        expectedDraftDigest: String,
        claimID: UUID,
        claimedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkProductionClaim {
        try withLockedDatabase { database in
            try transaction(database) {
                let record = try requireBulkExecutionJournal(
                    operationID: operationID,
                    database: database
                )
                guard record.phase == .prepared,
                      record.draft.draftDigest == expectedDraftDigest else {
                    throw CodexGhostRepairError.claimAlreadyExists
                }
                let claim = try CodexGhostRepairBulkProductionClaim(
                    claimID: claimID,
                    draft: record.draft,
                    claimedAtMilliseconds: claimedAtMilliseconds
                )
                let updated = CodexGhostRepairBulkProductionJournalRecord(
                    draft: record.draft,
                    phase: .claimed,
                    claim: claim,
                    attempt: nil,
                    report: nil
                )
                try insertOrUpdateBulkExecutionJournal(
                    updated,
                    expectedPhase: .prepared,
                    database: database
                )
                _ = try exactBulkExecutionJournal(
                    operationID: operationID,
                    expected: updated,
                    database: database
                )
                return claim
            }
        }
    }

    func recordCodexGhostRepairBulkExecutionAttempt(
        operationID: UUID,
        expectedClaimDigest: String,
        attemptedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkProductionAttempt {
        try withLockedDatabase { database in
            try transaction(database) {
                let record = try requireBulkExecutionJournal(
                    operationID: operationID,
                    database: database
                )
                guard record.phase == .claimed,
                      let claim = record.claim,
                      claim.claimDigest == expectedClaimDigest else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                let attempt = try CodexGhostRepairBulkProductionAttempt(
                    claim: claim,
                    attemptedAtMilliseconds: attemptedAtMilliseconds
                )
                let updated = CodexGhostRepairBulkProductionJournalRecord(
                    draft: record.draft,
                    phase: .attempted,
                    claim: claim,
                    attempt: attempt,
                    report: nil
                )
                try insertOrUpdateBulkExecutionJournal(
                    updated,
                    expectedPhase: .claimed,
                    database: database
                )
                _ = try exactBulkExecutionJournal(
                    operationID: operationID,
                    expected: updated,
                    database: database
                )
                return attempt
            }
        }
    }

    @discardableResult
    func recordCodexGhostRepairBulkTerminalReport(
        _ report: CodexGhostRepairBulkProductionTerminalReport
    ) throws -> CodexGhostRepairBulkProductionJournalRecord {
        try withLockedDatabase { database in
            try transaction(database) {
                let record = try requireBulkExecutionJournal(
                    operationID: report.operationID,
                    database: database
                )
                let expectedPhase: CodexGhostRepairBulkProductionJournalPhase
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
                    draft: record.draft,
                    claim: claim,
                    attempt: record.attempt
                )
                let updated = CodexGhostRepairBulkProductionJournalRecord(
                    draft: record.draft,
                    phase: .terminal,
                    claim: claim,
                    attempt: record.attempt,
                    report: report
                )
                try insertOrUpdateBulkExecutionJournal(
                    updated,
                    expectedPhase: expectedPhase,
                    database: database
                )
                return try exactBulkExecutionJournal(
                    operationID: report.operationID,
                    expected: updated,
                    database: database
                )
            }
        }
    }

    func codexGhostRepairBulkExecutionJournal(
        operationID: UUID
    ) throws -> CodexGhostRepairBulkProductionJournalRecord? {
        try withLockedDatabase { database in
            try loadBulkExecutionJournal(
                operationID: operationID,
                database: database
            )
        }
    }

    func codexGhostRepairBulkExecutionJournal(
        confirmationReceiptID: UUID
    ) throws -> CodexGhostRepairBulkProductionJournalRecord? {
        try withLockedDatabase { database in
            let operationIDs = try query(
                """
                SELECT operation_id
                FROM codex_ghost_repair_bulk_confirmation_receipts
                WHERE receipt_id = ?
                """,
                values: [
                    .text(
                        confirmationReceiptID.uuidString.lowercased()
                    ),
                ],
                database: database
            ) { statement in
                try Self.bulkCanonicalUUID(requiredText(statement, 0))
            }
            guard operationIDs.count <= 1 else {
                throw PersistentStateError.invalidRecord(
                    "Duplicate whole-batch confirmation receipt identities."
                )
            }
            guard let operationID = operationIDs.first else { return nil }
            guard let record = try loadBulkExecutionJournal(
                operationID: operationID,
                database: database
            ) else { return nil }
            guard record.draft.confirmationReceiptID
                    == confirmationReceiptID else {
                throw PersistentStateError.invalidRecord(
                    "Bulk execution journal receipt identity disagrees."
                )
            }
            return record
        }
    }

    private func requireBulkExecutionJournal(
        operationID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkProductionJournalRecord {
        guard let record = try loadBulkExecutionJournal(
            operationID: operationID,
            database: database
        ) else {
            throw PersistentStateError.recordNotFound(
                operationID.uuidString.lowercased()
            )
        }
        return record
    }

    private func exactBulkExecutionJournal(
        operationID: UUID,
        expected: CodexGhostRepairBulkProductionJournalRecord,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkProductionJournalRecord {
        guard let readback = try loadBulkExecutionJournal(
            operationID: operationID,
            database: database
        ), readback == expected else {
            throw PersistentStateError.invalidRecord(
                "Bulk execution journal exact readback did not match."
            )
        }
        return readback
    }

    private func insertOrUpdateBulkExecutionJournal(
        _ record: CodexGhostRepairBulkProductionJournalRecord,
        expectedPhase: CodexGhostRepairBulkProductionJournalPhase?,
        database: OpaquePointer
    ) throws {
        try record.validate()
        let encoded = try Self.encodeBulkPreviewPayload(record)
        let payloadHash = Self.hashBulkPreviewPayload(encoded)
        if let expectedPhase {
            try execute(
                """
                UPDATE codex_ghost_repair_bulk_execution_journal
                SET phase = ?, claim_digest = ?, attempt_digest = ?,
                    terminal_report_digest = ?, payload_json = ?,
                    payload_hash = ?, mutation_attempt_count = ?
                WHERE operation_id = ? AND phase = ?
                """,
                values: [
                    .text(record.phase.rawValue),
                    record.claim.map { .text($0.claimDigest) } ?? .null,
                    record.attempt.map { .text($0.attemptDigest) } ?? .null,
                    record.report.map { .text($0.reportDigest) } ?? .null,
                    .text(encoded), .text(payloadHash),
                    .int64(Int64(record.mutationAttemptCount)),
                    .text(record.draft.operationID.uuidString.lowercased()),
                    .text(expectedPhase.rawValue),
                ],
                database: database
            )
        } else {
            try execute(
                """
                INSERT INTO codex_ghost_repair_bulk_execution_journal (
                    operation_id, plan_digest,
                    confirmation_receipt_digest, draft_digest,
                    selected_count, phase, claim_digest, attempt_digest,
                    terminal_report_digest, payload_json, payload_hash,
                    mutation_attempt_count, automatic_retry_allowed,
                    automatic_restore_allowed,
                    silent_selection_shrink_allowed
                ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, 0, 0, 0, 0)
                """,
                values: [
                    .text(record.draft.operationID.uuidString.lowercased()),
                    .text(record.draft.planDigest),
                    .text(record.draft.confirmationReceiptDigest),
                    .text(record.draft.draftDigest),
                    .int64(Int64(record.draft.selectedThreadIDs.count)),
                    .text(record.phase.rawValue),
                    .text(encoded), .text(payloadHash),
                ],
                database: database
            )
        }
    }

    private func loadBulkExecutionJournal(
        operationID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkProductionJournalRecord? {
        let rows = try query(
            """
            SELECT plan_digest, confirmation_receipt_digest, draft_digest,
                   selected_count, phase, claim_digest, attempt_digest,
                   terminal_report_digest, payload_json, payload_hash,
                   mutation_attempt_count, automatic_retry_allowed,
                   automatic_restore_allowed,
                   silent_selection_shrink_allowed
            FROM codex_ghost_repair_bulk_execution_journal
            WHERE operation_id = ?
            """,
            values: [.text(operationID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairBulkProductionJournalRecord in
            let planDigest = try requiredText(statement, 0)
            let receiptDigest = try requiredText(statement, 1)
            let draftDigest = try requiredText(statement, 2)
            let selectedCount = Int(sqlite3_column_int64(statement, 3))
            guard let phase = CodexGhostRepairBulkProductionJournalPhase(
                rawValue: try requiredText(statement, 4)
            ) else {
                throw PersistentStateError.invalidRecord(
                    "Bulk execution journal phase is unknown."
                )
            }
            let claimDigest = optionalText(statement, 5)
            let attemptDigest = optionalText(statement, 6)
            let reportDigest = optionalText(statement, 7)
            let encoded = try requiredText(statement, 8)
            let payloadHash = try requiredText(statement, 9)
            let attemptCount = Int(sqlite3_column_int64(statement, 10))
            let retry = sqlite3_column_int64(statement, 11)
            let restore = sqlite3_column_int64(statement, 12)
            let shrink = sqlite3_column_int64(statement, 13)
            guard payloadHash == Self.hashBulkPreviewPayload(encoded) else {
                throw PersistentStateError.invalidRecord(
                    "Bulk execution journal payload hash does not match."
                )
            }
            let record: CodexGhostRepairBulkProductionJournalRecord =
                try Self.decodeBulkPreviewPayload(encoded)
            try record.validate()
            guard record.draft.operationID == operationID,
                  record.draft.planDigest == planDigest,
                  record.draft.confirmationReceiptDigest == receiptDigest,
                  record.draft.draftDigest == draftDigest,
                  record.draft.selectedThreadIDs.count == selectedCount,
                  record.phase == phase,
                  record.claim?.claimDigest == claimDigest,
                  record.attempt?.attemptDigest == attemptDigest,
                  record.report?.reportDigest == reportDigest,
                  record.mutationAttemptCount == attemptCount,
                  retry == 0, restore == 0, shrink == 0 else {
                throw PersistentStateError.invalidRecord(
                    "Bulk execution journal columns and payload disagree."
                )
            }
            return record
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate bulk execution journal records."
            )
        }
        return rows.first
    }
}

#endif
