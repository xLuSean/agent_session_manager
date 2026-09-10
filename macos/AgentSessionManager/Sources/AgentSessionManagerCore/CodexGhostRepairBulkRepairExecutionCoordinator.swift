import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH

protocol CodexGhostRepairBulkProductionExecutionJournaling: Sendable {
    func prepare(
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) async throws -> CodexGhostRepairBulkProductionJournalRecord

    func record(
        operationID: UUID
    ) async throws -> CodexGhostRepairBulkProductionJournalRecord?

    func record(
        confirmationReceiptID: UUID
    ) async throws -> CodexGhostRepairBulkProductionJournalRecord?

    func claim(
        operationID: UUID,
        expectedDraftDigest: String,
        claimID: UUID,
        claimedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairBulkProductionClaim

    func recordAttempt(
        operationID: UUID,
        expectedClaimDigest: String,
        attemptedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairBulkProductionAttempt

    func finalize(
        report: CodexGhostRepairBulkProductionTerminalReport
    ) async throws -> CodexGhostRepairBulkProductionJournalRecord
}

protocol CodexGhostRepairBulkProductionMutating: Sendable {
    func executeOnce(
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claim: CodexGhostRepairBulkProductionClaim,
        attempt: CodexGhostRepairBulkProductionAttempt
    ) async throws -> CodexGhostRepairCategoryABatchOutcome

    func recoverByReadback(
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claim: CodexGhostRepairBulkProductionClaim,
        attempt: CodexGhostRepairBulkProductionAttempt
    ) async throws -> CodexGhostRepairCategoryABatchOutcome
}

actor CodexGhostRepairBulkPackagedExecutionJournal:
    CodexGhostRepairBulkProductionExecutionJournaling
{
    private let storeProvider: @Sendable () throws -> SQLiteStateStore

    init(storeProvider: @escaping @Sendable () throws -> SQLiteStateStore) {
        self.storeProvider = storeProvider
    }

    func prepare(
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) throws -> CodexGhostRepairBulkProductionJournalRecord {
        let store = try storeProvider()
        defer { store.close() }
        return try store.prepareCodexGhostRepairBulkExecutionJournal(
            draft: draft
        )
    }

    func record(
        operationID: UUID
    ) throws -> CodexGhostRepairBulkProductionJournalRecord? {
        let store = try storeProvider()
        defer { store.close() }
        return try store.codexGhostRepairBulkExecutionJournal(
            operationID: operationID
        )
    }

    func record(
        confirmationReceiptID: UUID
    ) throws -> CodexGhostRepairBulkProductionJournalRecord? {
        let store = try storeProvider()
        defer { store.close() }
        return try store.codexGhostRepairBulkExecutionJournal(
            confirmationReceiptID: confirmationReceiptID
        )
    }

    func claim(
        operationID: UUID,
        expectedDraftDigest: String,
        claimID: UUID,
        claimedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkProductionClaim {
        let store = try storeProvider()
        defer { store.close() }
        return try store.claimCodexGhostRepairBulkExecution(
            operationID: operationID,
            expectedDraftDigest: expectedDraftDigest,
            claimID: claimID,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
    }

    func recordAttempt(
        operationID: UUID,
        expectedClaimDigest: String,
        attemptedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkProductionAttempt {
        let store = try storeProvider()
        defer { store.close() }
        return try store.recordCodexGhostRepairBulkExecutionAttempt(
            operationID: operationID,
            expectedClaimDigest: expectedClaimDigest,
            attemptedAtMilliseconds: attemptedAtMilliseconds
        )
    }

    func finalize(
        report: CodexGhostRepairBulkProductionTerminalReport
    ) throws -> CodexGhostRepairBulkProductionJournalRecord {
        let store = try storeProvider()
        defer { store.close() }
        return try store.recordCodexGhostRepairBulkTerminalReport(report)
    }
}

/// Deterministic composition of an exact production draft, the v17 one-shot
/// journal, and one injected mixed mutator. This remains research-gated: no
/// production draft preparer or live Codex mutator is supplied here.
actor CodexGhostRepairBulkRepairExecutionCoordinator:
    CodexGhostRepairBulkRepairCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkRepairCapabilities.deterministicComposition

    private let draftPreparer:
        any CodexGhostRepairBulkProductionDraftPreparing
    private let journal:
        any CodexGhostRepairBulkProductionExecutionJournaling
    private let mutator: any CodexGhostRepairBulkProductionMutating
    private let nowMilliseconds: @Sendable () -> Int64
    private let makeUUID: @Sendable () -> UUID

    init(
        draftPreparer: any CodexGhostRepairBulkProductionDraftPreparing,
        journal: any CodexGhostRepairBulkProductionExecutionJournaling,
        mutator: any CodexGhostRepairBulkProductionMutating,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.draftPreparer = draftPreparer
        self.journal = journal
        self.mutator = mutator
        self.nowMilliseconds = nowMilliseconds
        self.makeUUID = makeUUID
    }

    func prepareFinalReview(
        request: CodexGhostRepairBulkRepairReviewRequest
    ) async -> CodexGhostRepairBulkRepairReviewOutcome {
        do {
            if let existing = try await journal.record(
                confirmationReceiptID: request.confirmationReceiptID
            ) {
                guard existing.draft.confirmationReceiptID
                        == request.confirmationReceiptID else {
                    return blocked(
                        "The exact whole-batch confirmation receipt changed."
                    )
                }
                // An advanced cold-start record still returns the same frozen
                // Review identity. A later execute call can only finalize a
                // claimed record, recover an attempted record by readback, or
                // return an existing terminal Report; it cannot replay work.
                return .ready(try finalReview(draft: existing.draft))
            }
            let draft = try await draftPreparer.prepareDraft(
                confirmationReceiptID: request.confirmationReceiptID
            )
            try draft.validate()
            guard draft.confirmationReceiptID
                    == request.confirmationReceiptID else {
                return blocked(
                    "The exact whole-batch confirmation receipt changed."
                )
            }
            let record = try await journal.prepare(draft: draft)
            guard record.phase == .prepared, record.draft == draft else {
                return blocked(
                    "This exact whole-batch operation has already advanced. Read back its terminal state; do not retry."
                )
            }
            return .ready(try finalReview(draft: draft))
        } catch {
            return blocked(
                "Fresh maintenance, backup, or frozen batch evidence did not match. No repair claim was created."
            )
        }
    }

    func execute(
        request: CodexGhostRepairBulkRepairExecutionRequest
    ) async -> CodexGhostRepairBulkRepairExecutionOutcome {
        do {
            guard let record = try await journal.record(
                operationID: request.review.operationID
            ), matches(request.review, draft: record.draft) else {
                return unavailable(
                    "The exact reviewed whole-batch operation is unavailable."
                )
            }
            switch record.phase {
            case .terminal:
                guard let report = record.report else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                return try completed(report)
            case .claimed:
                guard let claim = record.claim else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                return try await finish(
                    draft: record.draft,
                    claim: claim,
                    attempt: nil,
                    outcome: .notAttempted
                )
            case .attempted:
                guard let claim = record.claim,
                      let attempt = record.attempt else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                return try await recover(
                    draft: record.draft,
                    claim: claim,
                    attempt: attempt
                )
            case .prepared:
                return try await executePrepared(record.draft)
            }
        } catch {
            return .recoveryRequired(
                operationID: request.review.operationID,
                message:
                    "The one-shot operation could not prove a terminal outcome. Do not retry or restore from this screen."
            )
        }
    }

    private func executePrepared(
        _ draft: CodexGhostRepairBulkProductionExecutionDraft
    ) async throws -> CodexGhostRepairBulkRepairExecutionOutcome {
        let claim = try await journal.claim(
            operationID: draft.operationID,
            expectedDraftDigest: draft.draftDigest,
            claimID: makeUUID(),
            claimedAtMilliseconds: nowMilliseconds()
        )
        let attempt = try await journal.recordAttempt(
            operationID: draft.operationID,
            expectedClaimDigest: claim.claimDigest,
            attemptedAtMilliseconds: nowMilliseconds()
        )
        do {
            let outcome = try await mutator.executeOnce(
                draft: draft,
                claim: claim,
                attempt: attempt
            )
            guard outcome != .notAttempted else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return try await finish(
                draft: draft,
                claim: claim,
                attempt: attempt,
                outcome: outcome
            )
        } catch {
            return try await recover(
                draft: draft,
                claim: claim,
                attempt: attempt
            )
        }
    }

    private func recover(
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claim: CodexGhostRepairBulkProductionClaim,
        attempt: CodexGhostRepairBulkProductionAttempt
    ) async throws -> CodexGhostRepairBulkRepairExecutionOutcome {
        let outcome: CodexGhostRepairCategoryABatchOutcome
        do {
            let observed = try await mutator.recoverByReadback(
                draft: draft,
                claim: claim,
                attempt: attempt
            )
            outcome = observed == .notAttempted ? .unknown : observed
        } catch {
            outcome = .unknown
        }
        return try await finish(
            draft: draft,
            claim: claim,
            attempt: attempt,
            outcome: outcome
        )
    }

    private func finish(
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claim: CodexGhostRepairBulkProductionClaim,
        attempt: CodexGhostRepairBulkProductionAttempt?,
        outcome: CodexGhostRepairCategoryABatchOutcome
    ) async throws -> CodexGhostRepairBulkRepairExecutionOutcome {
        let report = try CodexGhostRepairBulkProductionTerminalReport(
            reportID: makeUUID(),
            draft: draft,
            claim: claim,
            attempt: attempt,
            outcome: outcome,
            completedAtMilliseconds: nowMilliseconds()
        )
        let terminal = try await journal.finalize(report: report)
        guard terminal.phase == .terminal,
              terminal.report == report else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return try completed(report)
    }

    private func finalReview(
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) throws -> CodexGhostRepairBulkFinalReview {
        try .init(
            operationID: draft.operationID,
            confirmationReceiptID: draft.confirmationReceiptID,
            selectedCount: draft.selectedItems.count,
            ordinaryCount: draft.ordinaryCount,
            automationCount: draft.automationCount,
            blockedOutsideBatchCount: draft.blockedOutsideBatchCount,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceProfile.v149DesktopV32.identifier,
            reviewDigest: draft.draftDigest
        )
    }

    private func matches(
        _ review: CodexGhostRepairBulkFinalReview,
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) -> Bool {
        review.operationID == draft.operationID
            && review.confirmationReceiptID == draft.confirmationReceiptID
            && review.selectedCount == draft.selectedItems.count
            && review.ordinaryCount == draft.ordinaryCount
            && review.automationCount == draft.automationCount
            && review.blockedOutsideBatchCount
                == draft.blockedOutsideBatchCount
            && review.sourceLayoutIdentifier
                == CodexGhostRepairSnapshotSourceProfile.v149DesktopV32.identifier
            && review.reviewDigest == draft.draftDigest
    }

    private func completed(
        _ report: CodexGhostRepairBulkProductionTerminalReport
    ) throws -> CodexGhostRepairBulkRepairExecutionOutcome {
        .completed(try .init(
            operationID: report.operationID,
            outcome: Self.publicOutcome(report.outcome),
            itemReports: report.items.map {
                .init(
                    threadID: $0.threadID,
                    category: $0.category,
                    outcome: Self.publicOutcome($0.outcome)
                )
            },
            reportDigest: report.reportDigest
        ))
    }

    private func blocked(
        _ message: String
    ) -> CodexGhostRepairBulkRepairReviewOutcome {
        .blocked(message: message)
    }

    private func unavailable(
        _ message: String
    ) -> CodexGhostRepairBulkRepairExecutionOutcome {
        .unavailable(message: message)
    }

    private static func publicOutcome(
        _ outcome: CodexGhostRepairCategoryABatchOutcome
    ) -> CodexGhostRepairBulkRepairObservedOutcome {
        switch outcome {
        case .success: .success
        case .explicitFailure: .explicitFailure
        case .unknown: .unknown
        case .notAttempted: .notAttempted
        }
    }

    private static func publicOutcome(
        _ outcome: CodexGhostRepairCategoryAItemOutcome
    ) -> CodexGhostRepairBulkRepairObservedOutcome {
        switch outcome {
        case .success: .success
        case .alreadyAbsent: .alreadyAbsent
        case .explicitFailure: .explicitFailure
        case .unknown: .unknown
        case .notAttempted: .notAttempted
        }
    }
}

#endif
