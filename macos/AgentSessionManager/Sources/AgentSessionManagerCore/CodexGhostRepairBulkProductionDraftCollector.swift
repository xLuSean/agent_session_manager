import Foundation

enum CodexGhostRepairBulkMaintenanceCollectionPhase:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case beforeBackup = "before-backup"
    case beforeBackupRepeat = "before-backup-repeat"
    case afterBackup = "after-backup"
}

protocol CodexGhostRepairBulkProductionPlanCollecting: Sendable {
    func collectPlan(
        confirmationReceiptID: UUID
    ) async throws -> CodexGhostRepairBulkExecutionPlan
}

protocol CodexGhostRepairBulkMaintenanceCollecting: Sendable {
    func collectMaintenance(
        plan: CodexGhostRepairBulkExecutionPlan,
        phase: CodexGhostRepairBulkMaintenanceCollectionPhase
    ) async throws -> CodexGhostRepairBulkMaintenanceEvidence
}

protocol CodexGhostRepairBulkOperationBoundBackupCreating: Sendable {
    /// Must either create the exact operation-bound backup once or read back
    /// the already verified receipt for that same operation. It must never
    /// overwrite, widen, restore, clean up, or silently retry another backup.
    func createOrReadExactBackup(
        plan: CodexGhostRepairBulkExecutionPlan,
        maintenance: CodexGhostRepairBulkMaintenanceEvidence
    ) async throws -> CodexGhostRepairBulkExecutionBackupReceipt
}

protocol CodexGhostRepairBulkProductionDraftPreparing: Sendable {
    func prepareDraft(
        confirmationReceiptID: UUID
    ) async throws -> CodexGhostRepairBulkProductionExecutionDraft
}

struct CodexGhostRepairBulkProductionDraftCollectorCapabilities:
    Equatable,
    Sendable
{
    let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems
    let exactReceiptRequired = true
    let operationBoundBackupRequired = true
    let maintenanceReadCount = 2
    let backupCreateOrReadCount = 1
    let automaticRetryAllowed = false
    let automaticRestoreAllowed = false
    let silentSelectionShrinkAllowed = false
    let acceptsCallerPath = false
    let appWiringAvailable = false
    let acceptsLiveCodexRoot = false
    let repairMutationAuthority = false
}

/// Deterministic orchestration for collecting one exact production draft.
/// Every potentially live dependency remains injected and research-gated.
/// No production factory, path resolver, backup transport, or Codex mutator is
/// supplied by this slice.
actor CodexGhostRepairBulkProductionDraftCollector:
    CodexGhostRepairBulkProductionDraftPreparing
{
    nonisolated let capabilities =
        CodexGhostRepairBulkProductionDraftCollectorCapabilities()

    private let planCollector:
        any CodexGhostRepairBulkProductionPlanCollecting
    private let maintenanceCollector:
        any CodexGhostRepairBulkMaintenanceCollecting
    private let backupCreator:
        any CodexGhostRepairBulkOperationBoundBackupCreating
    private let nowMilliseconds: @Sendable () -> Int64
    private var activeReceiptID: UUID?

    init(
        planCollector: any CodexGhostRepairBulkProductionPlanCollecting,
        maintenanceCollector:
            any CodexGhostRepairBulkMaintenanceCollecting,
        backupCreator:
            any CodexGhostRepairBulkOperationBoundBackupCreating,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.planCollector = planCollector
        self.maintenanceCollector = maintenanceCollector
        self.backupCreator = backupCreator
        self.nowMilliseconds = nowMilliseconds
    }

    func prepareDraft(
        confirmationReceiptID: UUID
    ) async throws -> CodexGhostRepairBulkProductionExecutionDraft {
        guard activeReceiptID == nil else {
            throw CodexGhostRepairError.recoveryRequired
        }
        activeReceiptID = confirmationReceiptID
        defer { activeReceiptID = nil }

        let plan = try await planCollector.collectPlan(
            confirmationReceiptID: confirmationReceiptID
        )
        try plan.validateDigest()
        guard plan.confirmationReceiptID == confirmationReceiptID else {
            throw CodexGhostRepairError.authorityDrift
        }

        let before = try await maintenanceCollector.collectMaintenance(
            plan: plan,
            phase: .beforeBackup
        )
        try before.validate()

        let backup = try await backupCreator.createOrReadExactBackup(
            plan: plan,
            maintenance: before
        )
        try backup.validate()

        let after = try await maintenanceCollector.collectMaintenance(
            plan: plan,
            phase: .afterBackup
        )
        try after.validate()

        return try CodexGhostRepairBulkProductionExecutionDraft.prepare(
            plan: plan,
            preBackupMaintenance: before,
            backup: backup,
            postBackupMaintenance: after,
            preparedAtMilliseconds: nowMilliseconds()
        )
    }
}
