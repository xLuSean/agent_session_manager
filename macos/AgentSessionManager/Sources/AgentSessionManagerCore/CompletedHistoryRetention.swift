import CSQLite3
import Foundation

/// A presentation-only dismissal. Recovery evidence is not removed or reclassified.
public struct DeletedListClearPreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var recordCount: Int { rows.count }
    public var isEmpty: Bool { rows.isEmpty }
    fileprivate let databasePath: String
    fileprivate let selectedManagerKeys: Set<String>?
    fileprivate let expiresAt: Date
    fileprivate let rows: [CompletedHistoryRow]
}

public struct CompletedHistoryClearPreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let deletedRecordCount: Int
    public let reportCount: Int
    public let ghostOperationCount: Int
    public let keptRecordCount: Int
    public var isEmpty: Bool { groups.isEmpty }
    fileprivate let databasePath: String
    fileprivate let selectedManagerKeys: Set<String>?
    fileprivate let cutoff: Date
    fileprivate let expiresAt: Date
    fileprivate let groups: [CompletedHistoryGroup]
}

private struct CompletedHistoryRow: Equatable, Sendable {
    let table: String
    let column: String
    let key: String
    let fingerprint: String
}

private struct CompletedHistoryGroup: Equatable, Sendable {
    let rows: [CompletedHistoryRow]
    let retiredKeys: [String]
}

extension SQLiteStateStore {
    // Keep this namespace separate from operation replay-prevention keys. A hidden
    // tombstone must remain available to Delete recovery and cleanup linkage.
    private static let deletedListPrefix = "deleted-list:"

    public func visibleDeletedSessions(for provider: AgentSystem) throws -> [DeletedSessionRecord] {
        try withLockedDatabase { database in
            let dismissed = try dismissedDeletedKeys(database)
            return try loadDeletedSessions(provider: provider, database: database)
                .filter { !dismissed.contains(Self.deletedListPrefix + $0.managerKey) }
        }
    }

    public func prepareDeletedListClear(
        selectedManagerKeys: Set<String>? = nil, now: Date = Date()
    ) throws -> DeletedListClearPreview {
        try withLockedDatabase { database in
            try transaction(database) {
                try deletedListPreview(selection: selectedManagerKeys, now: now, database: database)
            }
        }
    }

    public func clearDeletedList(_ preview: DeletedListClearPreview, now: Date = Date()) throws {
        guard preview.databasePath == databaseURL.standardizedFileURL.path, now < preview.expiresAt else {
            throw PersistentStateError.invalidRecord("List confirmation expired. Review the records again.")
        }
        try withLockedDatabase { database in
            try transaction(database) {
                let current = try deletedListPreview(selection: preview.selectedManagerKeys, now: now, database: database)
                guard current.rows == preview.rows else {
                    throw PersistentStateError.invalidRecord("Deleted records changed. Nothing was cleared; review again.")
                }
                for row in current.rows {
                    try execute("INSERT OR IGNORE INTO retired_history_keys(key) VALUES (?)",
                        values: [.text(Self.deletedListPrefix + row.key)], database: database)
                }
                let dismissed = try dismissedDeletedKeys(database)
                guard current.rows.allSatisfy({ dismissed.contains(Self.deletedListPrefix + $0.key) }) else {
                    throw PersistentStateError.invalidRecord("Deleted list removal readback failed.")
                }
            }
        }
    }

    private func dismissedDeletedKeys(_ database: OpaquePointer) throws -> Set<String> {
        Set(try query("SELECT key FROM retired_history_keys WHERE key LIKE 'deleted-list:%'",
            values: [], database: database) { try requiredText($0, 0) })
    }

    private func deletedListPreview(
        selection: Set<String>?, now: Date, database: OpaquePointer
    ) throws -> DeletedListClearPreview {
        let dismissed = try dismissedDeletedKeys(database)
        let records = try loadDeletedSessions(provider: .codex, database: database).filter {
            !dismissed.contains(Self.deletedListPrefix + $0.managerKey)
                && (selection == nil || selection!.contains($0.managerKey))
        }
        let rows = try records.sorted { $0.managerKey < $1.managerKey }.flatMap {
            try historyRows("deleted_sessions", "manager_key", $0.managerKey, database)
        }
        return .init(id: UUID(), databasePath: databaseURL.standardizedFileURL.path,
            selectedManagerKeys: selection, expiresAt: now.addingTimeInterval(300), rows: rows)
    }

    // The count cap applies only to safely removable reports. Unresolved reports
    // may exceed it; a successful new operation must not fail because of that.
    static let clearableHistoryPredicate = """
        outcome = 'success' AND failed_count = 0 AND unknown_count = 0
        AND id NOT IN (SELECT delete_report_id FROM deleted_sessions WHERE delete_report_id IS NOT NULL)
        AND id NOT IN (SELECT canonical_delete_report_id FROM codex_desktop_cleanup_bindings)
        AND preview_id NOT IN (SELECT preview_id FROM archive_batch_units WHERE preview_id IS NOT NULL)
        """

    static let schemaV22Statements = [
        """
        CREATE TABLE retired_history_keys (
            key TEXT PRIMARY KEY NOT NULL
        ) STRICT
        """,
        """
        CREATE TRIGGER reject_retired_bulk_preview BEFORE INSERT ON codex_ghost_repair_bulk_previews
        WHEN EXISTS (SELECT 1 FROM retired_history_keys WHERE key IN
            ('bulk-request:' || NEW.request_id, 'bulk-preview:' || NEW.preview_id,
             'bulk-manifest:' || NEW.manifest_digest))
        BEGIN SELECT RAISE(ABORT, 'Completed history was cleared; this operation cannot be replayed'); END
        """,
        """
        CREATE TRIGGER reject_retired_operation_preview BEFORE INSERT ON operation_previews
        WHEN EXISTS (SELECT 1 FROM retired_history_keys WHERE key = 'preview:' || NEW.id)
        BEGIN SELECT RAISE(ABORT, 'Completed history was cleared; this operation cannot be replayed'); END
        """,
        """
        CREATE TRIGGER reject_retired_archive_batch BEFORE INSERT ON archive_batch_plans
        WHEN EXISTS (SELECT 1 FROM retired_history_keys WHERE key = 'archive-batch:' || NEW.id)
        BEGIN SELECT RAISE(ABORT, 'Completed history was cleared; this operation cannot be replayed'); END
        """
    ]

    /// Manager metadata only. No provider RPC, Codex database, backup-file removal or VACUUM.
    /// nil means all completed history; a non-nil set means only whole Deleted batches in that set.
    public func prepareCompletedHistoryClear(
        selectedManagerKeys: Set<String>? = nil,
        olderThan cutoff: Date = .distantFuture,
        now: Date = Date()
    ) throws -> CompletedHistoryClearPreview {
        try withLockedDatabase { database in
            try transaction(database) {
                try completedHistoryPreview(selection: selectedManagerKeys, cutoff: cutoff, now: now, database: database)
            }
        }
    }

    public func clearableOperationReportIDs(provider: AgentSystem) throws -> Set<UUID> {
        try withLockedDatabase { database in
            Set(try query("SELECT id FROM operation_reports WHERE provider = ? AND \(Self.clearableHistoryPredicate)",
                values: [.text(provider.rawValue)], database: database) { try Self.bulkCanonicalUUID(requiredText($0, 0)) })
        }
    }

    @discardableResult
    public func clearCompletedHistory(
        _ preview: CompletedHistoryClearPreview, now: Date = Date()
    ) throws -> CompletedHistoryClearPreview {
        guard preview.databasePath == databaseURL.standardizedFileURL.path,
              now < preview.expiresAt else {
            throw PersistentStateError.invalidRecord("History confirmation expired. Review the records again.")
        }
        return try withLockedDatabase { database in
            try transaction(database) {
                let current = try completedHistoryPreview(selection: preview.selectedManagerKeys,
                    cutoff: preview.cutoff, now: now, database: database)
                guard current.groups == preview.groups else {
                    throw PersistentStateError.invalidRecord("History changed after confirmation. Nothing was cleared; review again.")
                }
                for group in current.groups {
                    for key in group.retiredKeys {
                        try execute("INSERT OR IGNORE INTO retired_history_keys(key) VALUES (?)",
                            values: [.text(key)], database: database)
                    }
                    for row in group.rows {
                        // Identifiers come exclusively from the fixed table list below.
                        try execute("DELETE FROM \(row.table) WHERE \(row.column) = ?",
                            values: [.text(row.key)], database: database)
                        guard try historyRows(row.table, row.column, row.key, database).isEmpty else {
                            throw PersistentStateError.invalidRecord("History removal readback failed.")
                        }
                    }
                }
                return current
            }
        }
    }

    @discardableResult
    public func pruneCompletedHistory(now: Date = Date()) throws -> CompletedHistoryClearPreview {
        let preview = try prepareCompletedHistoryClear(
            olderThan: now.addingTimeInterval(-30 * 24 * 60 * 60), now: now)
        return try clearCompletedHistory(preview, now: now)
    }

    private func completedHistoryPreview(
        selection: Set<String>?, cutoff: Date, now: Date, database: OpaquePointer
    ) throws -> CompletedHistoryClearPreview {
        // Never race an in-flight canonical mutation or a claimed Desktop cleanup.
        let active = try query("""
            SELECT 1 FROM operation_previews WHERE status = 'executing'
            UNION ALL SELECT 1 FROM codex_ghost_repair_bulk_live_execution_journal
                WHERE phase IN ('claimed', 'attempted') LIMIT 1
            """, values: [], database: database) { _ in true }
        guard active.isEmpty else {
            throw PersistentStateError.invalidRecord("An operation still needs completion or recovery. History was kept.")
        }
        let deleted = try loadDeletedSessions(provider: .codex, database: database)
        let requestIDs = try query("SELECT request_id FROM codex_ghost_repair_bulk_live_execution_journal ORDER BY request_id",
            values: [], database: database) { try requiredText($0, 0) }
        var groups: [CompletedHistoryGroup] = []
        var removedKeys = Set<String>()
        var removedReports = Set<String>()
        var ghostCount = 0
        for request in requestIDs {
            guard let id = UUID(uuidString: request),
                  let record = try? loadBulkLiveExecutionJournal(requestID: id, database: database),
                  record.phase == .terminal, let report = record.report,
                  report.outcome == .success,
                  Date(timeIntervalSince1970: Double(report.completedAtMilliseconds) / 1_000) < cutoff else { continue }
            let ids = Set(record.plan.selectedThreadIDs)
            let records = deleted.filter { ids.contains($0.nativeSessionID) }
            let keys = Set(records.map(\.managerKey))
            guard keys.isDisjoint(with: removedKeys) else { continue }
            if let selection, keys.isEmpty || !keys.isSubset(of: selection) { continue }
            let operation = record.confirmationReceipt.operationID.uuidString.lowercased()
            // Legacy journals have a separate recovery contract; never discard them implicitly.
            guard try historyRows("codex_ghost_repair_bulk_execution_journal", "operation_id", operation, database).isEmpty else { continue }
            let reportIDs = Set(records.compactMap { $0.deleteReportID?.uuidString.lowercased() })
            var valid = records.allSatisfy { $0.deletedAt < cutoff }
            for reportID in reportIDs {
                let linkedRecords = deleted.filter { $0.deleteReportID?.uuidString.lowercased() == reportID }
                guard Set(linkedRecords.map(\.managerKey)).isSubset(of: keys) else { valid = false; break }
                // Unbound historical tombstones can be cleared only when this exact successful
                // Ghost batch covered them and there is no conflicting cleanup binding.
                let bindings = try query("SELECT bulk_request_id FROM codex_desktop_cleanup_bindings WHERE canonical_delete_report_id = ?",
                    values: [.text(reportID)], database: database) { try requiredText($0, 0) }
                if !bindings.isEmpty {
                    guard bindings == [request],
                          let status = try? codexDesktopCleanupStatus(reportID: UUID(uuidString: reportID)!, database: database),
                          case .verified = status else { valid = false; break }
                }
            }
            guard valid else { continue }
            let boundIDs = try query("SELECT canonical_delete_report_id FROM codex_desktop_cleanup_bindings WHERE bulk_request_id = ?",
                values: [.text(request)], database: database) { try requiredText($0, 0) }
            guard Set(boundIDs).isSubset(of: reportIDs) else { continue }
            var rows: [CompletedHistoryRow] = []
            var retired = ["bulk-request:\(request)", "bulk-preview:\(record.plan.previewID.uuidString.lowercased())",
                           "bulk-manifest:\(record.plan.previewManifestDigest)"]
            for reportID in reportIDs.sorted() {
                let tooRecent = try query("SELECT 1 FROM operation_reports WHERE id = ? AND completed_at >= ?",
                    values: [.text(reportID), .text(encode(cutoff))], database: database) { _ in true }
                guard tooRecent.isEmpty else { valid = false; break }
                guard let bundle = try successfulHistoryBundle(reportID, database) else { valid = false; break }
                rows += bundle.rows
                retired += bundle.retiredKeys
            }
            guard valid else { continue }
            for key in keys.sorted() { rows += try historyRows("deleted_sessions", "manager_key", key, database) }
            rows += try historyRows("codex_desktop_cleanup_bindings", "bulk_request_id", request, database)
            rows += try historyRows("codex_ghost_repair_bulk_live_execution_journal", "request_id", request, database)
            rows += try historyRows("codex_ghost_repair_bulk_confirmation_receipts", "saved_preview_request_id", request, database)
            rows += try historyRows("codex_ghost_repair_bulk_confirmation_challenges", "saved_preview_request_id", request, database)
            rows += try historyRows("codex_ghost_repair_bulk_frozen_plan_sources", "request_id", request, database)
            rows += try historyRows("codex_ghost_repair_bulk_previews", "request_id", request, database)
            groups.append(.init(rows: rows, retiredKeys: retired))
            removedKeys.formUnion(keys)
            removedReports.formUnion(reportIDs)
            ghostCount += 1
        }
        if selection == nil {
            let batches = try query("""
                SELECT p.id FROM archive_batch_plans p JOIN archive_batch_reports r ON r.batch_id = p.id
                WHERE p.status = 'consumed' AND r.outcome = 'success' AND r.completed_at < ?
                AND r.not_attempted_unit_count = 0 AND r.attempted_unit_count = p.unit_count
                AND p.unit_count = (SELECT COUNT(*) FROM archive_batch_units u WHERE u.batch_id = p.id)
                AND p.item_count = (SELECT COUNT(*) FROM archive_batch_items i WHERE i.batch_id = p.id)
                AND NOT EXISTS (SELECT 1 FROM archive_batch_units u WHERE u.batch_id = p.id AND (u.disposition IS NULL OR u.disposition != 'success'))
                AND NOT EXISTS (SELECT 1 FROM archive_batch_items i WHERE i.batch_id = p.id AND (i.disposition IS NULL OR i.disposition != 'success'))
                ORDER BY p.id
                """, values: [.text(encode(cutoff))], database: database) { try requiredText($0, 0) }
            for batch in batches {
                let reportIDs = try query("""
                    SELECT r.id FROM archive_batch_units u LEFT JOIN operation_reports r ON r.preview_id = u.preview_id
                    WHERE u.batch_id = ? ORDER BY u.unit_ordinal
                    """, values: [.text(batch)], database: database) { optionalText($0, 0) }
                var bundles: [CompletedHistoryGroup] = []
                for id in reportIDs {
                    guard let id, let bundle = try successfulHistoryBundle(id, database, permittedBatch: batch) else { break }
                    bundles.append(bundle)
                }
                guard bundles.count == reportIDs.count else { continue }
                var rows: [CompletedHistoryRow] = []
                for table in ["archive_batch_items", "archive_batch_units", "archive_batch_reports"] {
                    rows += try historyRows(table, "batch_id", batch, database)
                }
                rows += try historyRows("archive_batch_plans", "id", batch, database)
                rows += bundles.flatMap(\.rows)
                groups.append(.init(rows: rows, retiredKeys: ["archive-batch:\(batch)"] + bundles.flatMap(\.retiredKeys)))
                removedReports.formUnion(reportIDs.compactMap { $0 })
            }
            let reports = try query("""
                SELECT id FROM operation_reports WHERE outcome = 'success' AND completed_at < ?
                AND id NOT IN (SELECT delete_report_id FROM deleted_sessions WHERE delete_report_id IS NOT NULL)
                AND id NOT IN (SELECT canonical_delete_report_id FROM codex_desktop_cleanup_bindings)
                ORDER BY id
                """, values: [.text(encode(cutoff))], database: database) { try requiredText($0, 0) }
            for id in reports where !removedReports.contains(id) {
                if let group = try successfulHistoryBundle(id, database) {
                    groups.append(group)
                    removedReports.insert(id)
                }
            }
        }
        return .init(id: UUID(), deletedRecordCount: removedKeys.count,
            reportCount: groups.flatMap(\.rows).filter { $0.table == "operation_reports" || $0.table == "archive_batch_reports" }.count,
            ghostOperationCount: ghostCount,
            keptRecordCount: deleted.filter { selection == nil || selection!.contains($0.managerKey) }.count - removedKeys.count,
            databasePath: databaseURL.standardizedFileURL.path, selectedManagerKeys: selection,
            cutoff: cutoff, expiresAt: now.addingTimeInterval(300), groups: groups)
    }

    private func successfulHistoryBundle(_ reportID: String, _ database: OpaquePointer, permittedBatch: String = "") throws -> CompletedHistoryGroup? {
        let previews = try query("""
            SELECT r.preview_id FROM operation_reports r JOIN operation_previews p ON p.id = r.preview_id
            WHERE r.id = ? AND r.outcome = 'success' AND r.failed_count = 0 AND r.unknown_count = 0
            AND r.succeeded_count = r.item_count
            AND r.item_count = (SELECT COUNT(*) FROM operation_items i WHERE i.report_id = r.id)
            AND NOT EXISTS (SELECT 1 FROM operation_items i WHERE i.report_id = r.id AND (i.result_outcome IS NULL OR i.result_outcome != 'success'))
            AND p.status = 'consumed'
            AND NOT EXISTS (SELECT 1 FROM archive_batch_units b WHERE b.preview_id = p.id AND b.batch_id != ?)
            """, values: [.text(reportID), .text(permittedBatch)], database: database) { try requiredText($0, 0) }
        if previews.isEmpty {
            // The ordinary report may already have been pruned; the independently
            // validated Ghost terminal journal and tombstones remain sufficient.
            let existing = try historyRows("operation_reports", "id", reportID, database)
            return existing.isEmpty ? .init(rows: [], retiredKeys: []) : nil
        }
        let preview = previews[0]
        let rows = try historyRows("operation_items", "preview_id", preview, database)
            + historyRows("operation_reports", "id", reportID, database)
            + historyRows("operation_previews", "id", preview, database)
        return .init(rows: rows, retiredKeys: ["preview:\(preview)"])
    }

    /// Fingerprint every column, including titles and payloads, but never expose
    /// those values in the confirmation object or diagnostics.
    private func historyRows(_ table: String, _ column: String, _ key: String, _ database: OpaquePointer) throws -> [CompletedHistoryRow] {
        let values = try query("SELECT * FROM \(table) WHERE \(column) = ?", values: [.text(key)], database: database) { statement in
            (0..<sqlite3_column_count(statement)).map { index -> String in
                if sqlite3_column_type(statement, index) == SQLITE_NULL { return "null" }
                let bytes = sqlite3_column_blob(statement, index)
                let data = bytes.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, index))) } ?? Data()
                return "\(sqlite3_column_type(statement, index)):\(data.base64EncodedString())"
            }.joined(separator: "|")
        }
        guard !values.isEmpty else { return [] }
        return [.init(table: table, column: column, key: key,
            fingerprint: Self.hashBulkPreviewPayload(values.sorted().joined(separator: "\n")))]
    }
}
