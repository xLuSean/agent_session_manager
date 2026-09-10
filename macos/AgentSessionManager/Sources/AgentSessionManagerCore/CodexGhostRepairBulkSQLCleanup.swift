import Foundation

/// Shared SQL operations, not an execution entry point. The live caller still owns
/// exact plan/backup admission, transaction readback, commit and recovery.
enum CodexGhostRepairBulkSQLCleanup {
    struct Target {
        let threadID: String
        let effect: CodexGhostRepairBulkBackupBoundExpectedEffect
        let summaryCount: Int
    }

    static func apply(database: CodexGhostRepairProductionSQLite, targets: [Target],
                      catalogRevision: Int64, observationSequence: Int64,
                      executionAtMilliseconds: Int64, failAfterSummaryRemoval: Bool = false) throws {
        for item in targets {
            if item.summaryCount > 0 {
                try database.execute("DELETE FROM reviewed_summaries.thread_turn_summaries WHERE thread_id = ?",
                                     bindings: [.text(item.threadID)])
                guard database.changeCount == item.summaryCount else {
                    throw CodexGhostRepairError.targetDrift("Reviewed summary row count drifted.")
                }
                if failAfterSummaryRemoval { throw CodexGhostRepairError.injectedInterruption }
            }
            if [.removeCatalogRow, .removeCatalogRowAndArchiveAutomation].contains(item.effect) {
                try database.execute("DELETE FROM local_thread_catalog WHERE host_id = 'local' AND thread_id = ?",
                                     bindings: [.text(item.threadID)])
                guard database.changeCount == 1 else {
                    throw CodexGhostRepairError.targetDrift("M4f-17 exact catalog row count drifted.")
                }
            }
            if [.archiveAutomation, .removeCatalogRowAndArchiveAutomation].contains(item.effect) {
                try database.execute("UPDATE automation_runs SET status = 'ARCHIVED', archived_reason = 'auto', updated_at = ? WHERE thread_id = ?",
                                     bindings: [.integer(executionAtMilliseconds), .text(item.threadID)])
                guard database.changeCount == 1 else {
                    throw CodexGhostRepairError.targetDrift("M4f-17 exact automation row count drifted.")
                }
            }
        }
        let increment = Int64(targets.filter { [.removeCatalogRow, .removeCatalogRowAndArchiveAutomation].contains($0.effect) }.count)
        try database.execute("UPDATE local_thread_catalog_metadata SET catalog_revision = ? WHERE id = 1 AND catalog_revision = ?",
                             bindings: [.integer(catalogRevision + increment), .integer(catalogRevision)])
        guard database.changeCount == 1 else { throw CodexGhostRepairError.authorityDrift }
        try database.execute("UPDATE local_thread_catalog_sync_state SET observation_sequence = ? WHERE host_id = 'local' AND observation_sequence = ?",
                             bindings: [.integer(observationSequence + increment), .integer(observationSequence)])
        guard database.changeCount == 1 else { throw CodexGhostRepairError.authorityDrift }
    }
}
