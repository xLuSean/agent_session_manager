import Foundation

struct CodexGhostRepairBulkPackagedPreparedOperation: Sendable {
    let plan: CodexGhostRepairBulkBackupBoundOperationPlan
    let receipt: CodexGhostRepairBulkConfirmationReceipt
}

protocol CodexGhostRepairBulkPackagedPlanPreparing: Sendable {
    func prepare(
        confirmationReceiptID: UUID
    ) async throws -> CodexGhostRepairBulkPackagedPreparedOperation

    func receipt(
        confirmationReceiptID: UUID
    ) async throws -> CodexGhostRepairBulkConfirmationReceipt
}

protocol CodexGhostRepairBulkOneShotRunning: Sendable {
    func prepare(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        confirmationReceipt: CodexGhostRepairBulkConfirmationReceipt
    ) async throws -> CodexGhostRepairBulkLiveJournalRecord

    func execute(
        requestID: UUID,
        expectedPlanDigest: String
    ) async throws -> CodexGhostRepairBulkLiveTerminalReport
}

extension CodexGhostRepairBulkLiveOneShotCoordinator:
    CodexGhostRepairBulkOneShotRunning {}

/// Product bridge for the existing whole-batch Final Review and Execute UI.
/// The bridge never accepts a filesystem path and does not infer or shrink a
/// selection. Preparation must first return one backup-bound plan tied to the
/// exact confirmation receipt. Execution reconstructs the one-shot runner
/// from the review's packaged source profile and the durable receipt.
actor CodexGhostRepairBulkPackagedRepairCoordinator:
    CodexGhostRepairBulkRepairCoordinating
{
    typealias RunnerFactory = @Sendable (String) throws
        -> any CodexGhostRepairBulkOneShotRunning

    nonisolated let capabilities =
        CodexGhostRepairBulkRepairCapabilities.deterministicComposition

    private let planPreparer: any CodexGhostRepairBulkPackagedPlanPreparing
    private let runnerFactory: RunnerFactory
    private var operationInProgress = false

    init(
        planPreparer: any CodexGhostRepairBulkPackagedPlanPreparing,
        runnerFactory: @escaping RunnerFactory
    ) {
        self.planPreparer = planPreparer
        self.runnerFactory = runnerFactory
    }

    func prepareFinalReview(
        request: CodexGhostRepairBulkRepairReviewRequest
    ) async -> CodexGhostRepairBulkRepairReviewOutcome {
        guard !operationInProgress else {
            return .blocked(message: "A bulk repair operation is already running.")
        }
        operationInProgress = true
        defer { operationInProgress = false }
        var planPreparationFinished = false
        do {
            let prepared = try await planPreparer.prepare(
                confirmationReceiptID: request.confirmationReceiptID
            )
            planPreparationFinished = true
            let plan = prepared.plan
            let receipt = prepared.receipt
            try plan.validate()
            guard receipt.receiptID == request.confirmationReceiptID,
                  receipt.savedPreviewRequestID == plan.requestID,
                  receipt.selectedCount == plan.selectedCount,
                  let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
                      sourceLayoutIdentifier: plan.sourceLayoutIdentifier
                  ) else {
                throw CodexGhostRepairError.authorityDrift
            }
            let runner = try runnerFactory(profile.identifier)
            let record = try await runner.prepare(
                plan: plan,
                confirmationReceipt: receipt
            )
            guard record.plan == plan,
                  record.confirmationReceipt == receipt,
                  record.phase == .prepared else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return .ready(try CodexGhostRepairBulkFinalReview(
                operationID: receipt.operationID,
                confirmationReceiptID: receipt.receiptID,
                selectedCount: plan.selectedCount,
                ordinaryCount: plan.ordinaryCount,
                automationCount: plan.automationCount,
                alreadyAbsentCount: plan.alreadyAbsentCount,
                blockedOutsideBatchCount: plan.blockedOutsideBatchCount,
                sourceLayoutIdentifier: profile.identifier,
                reviewDigest: plan.planDigest
            ))
        } catch {
            if !planPreparationFinished,
               case CodexGhostRepairError.executionGateBlocked = error {
                return .awaitingShutdown(message: Self.finalReviewFailureMessage(error))
            }
            return .blocked(
                message: Self.finalReviewFailureMessage(error)
            )
        }
    }

    private static func finalReviewFailureMessage(_ error: Error) -> String {
        guard let error = error as? CodexGhostRepairError else {
            return "Final Review stopped before the repair claim. The manager-owned Preview or receipt could not be read exactly. Nothing was executed."
        }
        switch error {
        case .executionGateBlocked:
            return "Final Review stopped: Codex or another app-server still has a Codex database open. Nothing was executed."
        case .previewExpired:
            return "Final Review stopped: the frozen Preview expired. Build one new Preview after Codex is ready to exit. Nothing was executed."
        case .invalidDatabaseContract:
            return "Final Review stopped: the current Codex database schema is unsupported or incomplete. Nothing was executed."
        case let .targetDrift(detail):
            return "Final Review stopped before claim: \(detail) Nothing was executed."
        case .authorityDrift:
            return "Final Review stopped: live Codex data changed while the backup and target checks were running. Nothing was executed."
        case .backupFailed:
            return "Final Review stopped: the verified backup could not be created or read back exactly. Nothing was executed."
        case .claimAlreadyExists, .recoveryRequired:
            return "Final Review stopped: durable recovery evidence already exists. Do not retry or restore automatically."
        case .sqlite:
            return "Final Review stopped: a required SQLite read or backup operation failed. Nothing was executed."
        case let .invalidDisposablePath(detail):
            return "Final Review stopped before claim: the fixed storage path failed validation. \(detail) Nothing was executed."
        case let .invalidPlan(detail):
            return "Final Review stopped before claim: the frozen operation plan is invalid. \(detail) Nothing was executed."
        case let .invalidProtectionEvidence(detail):
            return "Final Review stopped before claim: a required protection check failed. \(detail) Nothing was executed."
        case .confirmationMismatch:
            return "Final Review stopped before claim: the whole-batch confirmation no longer matches the frozen Preview. Nothing was executed."
        case let .snapshotAcquisitionFailed(detail):
            return "Final Review stopped before claim: Snapshot evidence is unavailable. \(detail) Nothing was executed."
        case .injectedInterruption:
            return "Final Review stopped before claim because the operation was interrupted. Nothing was executed."
        }
    }

    func execute(
        request: CodexGhostRepairBulkRepairExecutionRequest
    ) async -> CodexGhostRepairBulkRepairExecutionOutcome {
        guard !operationInProgress else {
            return .unavailable(
                message: "A bulk repair operation is already running."
            )
        }
        operationInProgress = true
        defer { operationInProgress = false }
        do {
            let receipt = try await planPreparer.receipt(
                confirmationReceiptID:
                    request.review.confirmationReceiptID
            )
            guard receipt.receiptID
                    == request.review.confirmationReceiptID,
                  receipt.operationID == request.review.operationID,
                  receipt.selectedCount == request.review.selectedCount,
                  let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
                      sourceLayoutIdentifier:
                        request.review.sourceLayoutIdentifier
                  ) else {
                throw CodexGhostRepairError.authorityDrift
            }
            let report = try await runnerFactory(profile.identifier).execute(
                requestID: receipt.savedPreviewRequestID,
                expectedPlanDigest: request.review.reviewDigest
            )
            guard report.requestID == receipt.savedPreviewRequestID,
                  report.planDigest == request.review.reviewDigest,
                  report.confirmationReceiptDigest
                    == receipt.receiptDigest else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return .completed(try Self.publicReport(
                report,
                operationID: receipt.operationID
            ))
        } catch {
            return .recoveryRequired(
                operationID: request.review.operationID,
                message: "The one-shot operation stopped or needs exact readback. Do not retry or restore automatically."
            )
        }
    }

    private static func publicReport(
        _ report: CodexGhostRepairBulkLiveTerminalReport,
        operationID: UUID
    ) throws -> CodexGhostRepairBulkRepairReport {
        let outcome: CodexGhostRepairBulkRepairObservedOutcome = switch report.outcome {
        case .success: .success
        case .explicitFailure: .explicitFailure
        case .unknown: .unknown
        case .notAttempted: .notAttempted
        }
        return try CodexGhostRepairBulkRepairReport(
            operationID: operationID,
            outcome: outcome,
            itemReports: report.items.map {
                CodexGhostRepairBulkRepairItemReport(
                    threadID: $0.threadID,
                    category: $0.category,
                    outcome: Self.publicOutcome($0.outcome)
                )
            },
            reportDigest: report.reportDigest
        )
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
