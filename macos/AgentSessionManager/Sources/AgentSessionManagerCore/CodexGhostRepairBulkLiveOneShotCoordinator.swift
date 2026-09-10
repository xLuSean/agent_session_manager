import Foundation

struct CodexGhostRepairBulkLiveOneShotCapabilities:
    Equatable,
    Sendable
{
    let productionFactoryAvailable = true
    let productionConstructionPerformsIO = false
    let productionFactoryAcceptsCallerPath = false
    let exactConfirmationReceiptRequired = true
    let exactBackupBoundPlanRequired = true
    let durableClaimBeforeAttempt = true
    let durableAttemptBeforeMutation = true
    let maximumMutationAttemptCount = 1
    let coldRestartUsesReadbackOnly = true
    let itemizedTerminalReport = true
    let automaticRetryAllowed = false
    let automaticRestoreAllowed = false
    let silentSelectionShrinkAllowed = false
    let appWiringAvailable = true
    let liveExecutionAuthorized = false
    let repairMutationAuthority = false
}

enum CodexGhostRepairBulkLiveOneShotFault: Sendable {
    case none
    case afterClaim
    case afterAttempt
}

protocol CodexGhostRepairBulkLiveExecutionJournaling: Sendable {
    func prepare(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        confirmationReceipt: CodexGhostRepairBulkConfirmationReceipt
    ) async throws -> CodexGhostRepairBulkLiveJournalRecord

    func record(
        requestID: UUID
    ) async throws -> CodexGhostRepairBulkLiveJournalRecord?

    func claim(
        requestID: UUID,
        expectedPlanDigest: String,
        claimID: UUID,
        claimedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairBulkLiveMixedClaim

    func recordAttempt(
        requestID: UUID,
        expectedClaimDigest: String,
        attemptedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairBulkLiveMixedAttempt

    func finalize(
        report: CodexGhostRepairBulkLiveTerminalReport
    ) async throws -> CodexGhostRepairBulkLiveJournalRecord
}

protocol CodexGhostRepairBulkLiveMixedMutating: Sendable {
    func executeOnce(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt
    ) async throws -> CodexGhostRepairCategoryABatchOutcome

    func recoverByReadback(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt
    ) async throws -> CodexGhostRepairCategoryABatchOutcome
}

extension CodexGhostRepairBulkLiveMixedMutator:
    CodexGhostRepairBulkLiveMixedMutating {}

actor CodexGhostRepairBulkLivePackagedExecutionJournal:
    CodexGhostRepairBulkLiveExecutionJournaling
{
    private let storeProvider: @Sendable () throws -> SQLiteStateStore

    static func production() -> Self {
        Self(storeProvider: {
            try SQLiteStateStore(
                databaseURL: StateStoreLocation.applicationSupportDatabaseURL()
            )
        })
    }

    init(storeProvider: @escaping @Sendable () throws -> SQLiteStateStore) {
        self.storeProvider = storeProvider
    }

    func prepare(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        confirmationReceipt: CodexGhostRepairBulkConfirmationReceipt
    ) throws -> CodexGhostRepairBulkLiveJournalRecord {
        let store = try storeProvider()
        defer { store.close() }
        return try store.prepareCodexGhostRepairBulkLiveExecutionJournal(
            plan: plan,
            confirmationReceipt: confirmationReceipt
        )
    }

    func record(
        requestID: UUID
    ) throws -> CodexGhostRepairBulkLiveJournalRecord? {
        let store = try storeProvider()
        defer { store.close() }
        return try store.codexGhostRepairBulkLiveExecutionJournal(
            requestID: requestID
        )
    }

    func claim(
        requestID: UUID,
        expectedPlanDigest: String,
        claimID: UUID,
        claimedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkLiveMixedClaim {
        let store = try storeProvider()
        defer { store.close() }
        return try store.claimCodexGhostRepairBulkLiveExecution(
            requestID: requestID,
            expectedPlanDigest: expectedPlanDigest,
            claimID: claimID,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
    }

    func recordAttempt(
        requestID: UUID,
        expectedClaimDigest: String,
        attemptedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkLiveMixedAttempt {
        let store = try storeProvider()
        defer { store.close() }
        return try store.recordCodexGhostRepairBulkLiveExecutionAttempt(
            requestID: requestID,
            expectedClaimDigest: expectedClaimDigest,
            attemptedAtMilliseconds: attemptedAtMilliseconds
        )
    }

    func finalize(
        report: CodexGhostRepairBulkLiveTerminalReport
    ) throws -> CodexGhostRepairBulkLiveJournalRecord {
        let store = try storeProvider()
        defer { store.close() }
        return try store.recordCodexGhostRepairBulkLiveTerminalReport(report)
    }
}

/// The Shipping one-shot composition. The manager journal consumes the exact
/// confirmation receipt, persists the claim and attempt before the mixed
/// mutator is called, and turns every cold restart into readback-only recovery.
/// Construction performs no I/O and does not itself grant live authority.
actor CodexGhostRepairBulkLiveOneShotCoordinator {
    nonisolated let capabilities =
        CodexGhostRepairBulkLiveOneShotCapabilities()

    private let journal: any CodexGhostRepairBulkLiveExecutionJournaling
    private let mutator: any CodexGhostRepairBulkLiveMixedMutating
    private let nowMilliseconds: @Sendable () -> Int64
    private let makeUUID: @Sendable () -> UUID
    private let fault: CodexGhostRepairBulkLiveOneShotFault
    private let operationExclusion: CodexGhostRepairBulkOperationExclusion

    static func production(
        backupReader: any CodexGhostRepairBulkLiveMixedBackupReading,
        profile: CodexGhostRepairSnapshotSourceProfile
    ) -> Self {
        Self(
            journal: CodexGhostRepairBulkLivePackagedExecutionJournal
                .production(),
            mutator: CodexGhostRepairBulkLiveMixedMutator.production(
                backupReader: backupReader,
                profile: profile
            ),
            operationExclusion: .production()
        )
    }

    init(
        journal: any CodexGhostRepairBulkLiveExecutionJournaling,
        mutator: any CodexGhostRepairBulkLiveMixedMutating,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        fault: CodexGhostRepairBulkLiveOneShotFault = .none,
        operationExclusion: CodexGhostRepairBulkOperationExclusion =
            .uncoordinatedTestOnly
    ) {
        self.journal = journal
        self.mutator = mutator
        self.nowMilliseconds = nowMilliseconds
        self.makeUUID = makeUUID
        self.fault = fault
        self.operationExclusion = operationExclusion
    }

    func prepare(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        confirmationReceipt: CodexGhostRepairBulkConfirmationReceipt
    ) async throws -> CodexGhostRepairBulkLiveJournalRecord {
        try plan.validate()
        try CodexGhostRepairBulkLiveJournalRecord.validateReceipt(
            confirmationReceipt,
            plan: plan
        )
        let record = try await journal.prepare(
            plan: plan,
            confirmationReceipt: confirmationReceipt
        )
        guard record.plan == plan,
              record.confirmationReceipt == confirmationReceipt,
              record.phase == .prepared else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return record
    }

    func execute(
        requestID: UUID,
        expectedPlanDigest: String
    ) async throws -> CodexGhostRepairBulkLiveTerminalReport {
        let lease = try operationExclusion.acquire()
        defer { lease.release() }
        return try await executeExclusively(
            requestID: requestID,
            expectedPlanDigest: expectedPlanDigest,
            lease: lease
        )
    }

    private func executeExclusively(
        requestID: UUID,
        expectedPlanDigest: String,
        lease: CodexGhostRepairBulkOperationExclusion.Lease
    ) async throws -> CodexGhostRepairBulkLiveTerminalReport {
        guard let record = try await journal.record(requestID: requestID),
              record.plan.planDigest == expectedPlanDigest else {
            throw CodexGhostRepairError.recoveryRequired
        }
        try lease.validateCurrentPath()
        switch record.phase {
        case .closedBeforeAttempt:
            throw CodexGhostRepairError.recoveryRequired
        case .terminal:
            guard let report = record.report else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return report
        case .claimed:
            guard let claim = record.claim else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return try await finish(
                record: record,
                claim: claim,
                attempt: nil,
                outcome: .notAttempted,
                lease: lease
            )
        case .attempted:
            guard let claim = record.claim,
                  let attempt = record.attempt else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return try await recover(
                record: record,
                claim: claim,
                attempt: attempt,
                lease: lease
            )
        case .prepared:
            return try await executePrepared(record, lease: lease)
        }
    }

    private func executePrepared(
        _ record: CodexGhostRepairBulkLiveJournalRecord,
        lease: CodexGhostRepairBulkOperationExclusion.Lease
    ) async throws -> CodexGhostRepairBulkLiveTerminalReport {
        try lease.validateCurrentPath()
        let claim = try await journal.claim(
            requestID: record.plan.requestID,
            expectedPlanDigest: record.plan.planDigest,
            claimID: makeUUID(),
            claimedAtMilliseconds: nowMilliseconds()
        )
        if fault == .afterClaim {
            throw CodexGhostRepairError.injectedInterruption
        }
        try lease.validateCurrentPath()
        let attempt = try await journal.recordAttempt(
            requestID: record.plan.requestID,
            expectedClaimDigest: claim.claimDigest,
            attemptedAtMilliseconds: nowMilliseconds()
        )
        if fault == .afterAttempt {
            throw CodexGhostRepairError.injectedInterruption
        }
        try lease.validateCurrentPath()
        do {
            let outcome = try await mutator.executeOnce(
                plan: record.plan,
                claim: claim,
                attempt: attempt
            )
            if outcome == .notAttempted {
                return try await recover(
                    record: record,
                    claim: claim,
                    attempt: attempt,
                    lease: lease
                )
            }
            return try await finish(
                record: record,
                claim: claim,
                attempt: attempt,
                outcome: outcome,
                lease: lease
            )
        } catch {
            return try await recover(
                record: record,
                claim: claim,
                attempt: attempt,
                lease: lease
            )
        }
    }

    private func recover(
        record: CodexGhostRepairBulkLiveJournalRecord,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt,
        lease: CodexGhostRepairBulkOperationExclusion.Lease
    ) async throws -> CodexGhostRepairBulkLiveTerminalReport {
        try lease.validateCurrentPath()
        let observed: CodexGhostRepairCategoryABatchOutcome
        do {
            let value = try await mutator.recoverByReadback(
                plan: record.plan,
                claim: claim,
                attempt: attempt
            )
            observed = value == .notAttempted ? .explicitFailure : value
        } catch {
            observed = .unknown
        }
        return try await finish(
            record: record,
            claim: claim,
            attempt: attempt,
            outcome: observed,
            lease: lease
        )
    }

    private func finish(
        record: CodexGhostRepairBulkLiveJournalRecord,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt?,
        outcome: CodexGhostRepairCategoryABatchOutcome,
        lease: CodexGhostRepairBulkOperationExclusion.Lease
    ) async throws -> CodexGhostRepairBulkLiveTerminalReport {
        let report = try CodexGhostRepairBulkLiveTerminalReport(
            reportID: makeUUID(),
            plan: record.plan,
            receipt: record.confirmationReceipt,
            claim: claim,
            attempt: attempt,
            outcome: outcome,
            completedAtMilliseconds: nowMilliseconds()
        )
        try lease.validateCurrentPath()
        let terminal = try await journal.finalize(report: report)
        try lease.validateCurrentPath()
        guard terminal.phase == .terminal,
              terminal.report == report else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return report
    }
}
