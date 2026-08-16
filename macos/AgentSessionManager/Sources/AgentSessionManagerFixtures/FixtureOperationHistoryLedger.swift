import AgentSessionManagerCore
import Foundation

/// Process-local Report history for the Fixture provider.
///
/// This ledger never opens SQLite and deliberately has no serialization API.
/// Its contents disappear when the model clears it or the process exits.
public final class FixtureOperationHistoryLedger: @unchecked Sendable {
    public static let defaultMaximumReportsPerProvider = 500

    public let maximumReportsPerProvider: Int

    private let lock = NSLock()
    private var entries: [OperationHistoryEntry] = []

    public init() {
        maximumReportsPerProvider = Self.defaultMaximumReportsPerProvider
    }

    public init(maximumReportsPerProvider: Int) throws {
        guard maximumReportsPerProvider > 0 else {
            throw PersistentStateError.invalidRecord(
                "Fixture history retention limit must be greater than zero."
            )
        }
        self.maximumReportsPerProvider = maximumReportsPerProvider
    }

    /// Converts a completed Fixture operation into the shared history/export
    /// model. It does not contain confirmation tokens, hashes, paths, or
    /// conversation content.
    public func record(preview: OperationPreview, report: OperationReport) throws {
        let entry = try Self.makeEntry(preview: preview, report: report)
        lock.lock()
        defer { lock.unlock() }

        guard !entries.contains(where: { $0.reportID == entry.reportID }) else {
            throw PersistentStateError.invalidRecord(
                "Fixture history already contains Report \(entry.reportID.uuidString)."
            )
        }
        entries.append(entry)
        entries.sort(by: Self.newestFirst)

        var retainedForProvider = 0
        entries.removeAll { existing in
            guard existing.provider == entry.provider else { return false }
            retainedForProvider += 1
            return retainedForProvider > maximumReportsPerProvider
        }
    }

    public func operationHistory(
        _ query: OperationHistoryQuery = OperationHistoryQuery()
    ) throws -> OperationHistoryPage {
        try Self.validate(query)
        lock.lock()
        defer { lock.unlock() }

        let needle = query.searchText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matching = entries.filter { entry in
            guard query.provider == nil || entry.provider == query.provider,
                  query.operation == nil || entry.operation == query.operation,
                  query.outcome == nil || entry.outcome == query.outcome,
                  Self.isBeforeCursor(entry, cursor: query.cursor),
                  needle.isEmpty || Self.matchesSearch(entry, needle: needle) else {
                return false
            }
            if let from = query.completedFrom, entry.completedAt < from { return false }
            if let through = query.completedThrough, entry.completedAt > through { return false }
            return true
        }

        let hasMore = matching.count > query.limit
        let pageEntries = Array(matching.prefix(query.limit))
        let nextCursor = hasMore ? pageEntries.last.map {
            OperationHistoryCursor(completedAt: $0.completedAt, reportID: $0.reportID)
        } : nil
        return OperationHistoryPage(entries: pageEntries, nextCursor: nextCursor)
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
    }

    @discardableResult
    public func remove(reportIDs: Set<UUID>) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let existingIDs = Set(entries.map(\.reportID))
        guard reportIDs.isSubset(of: existingIDs) else {
            throw PersistentStateError.invalidRecord(
                "Fixture Report history changed after clear confirmation. Refresh and confirm again."
            )
        }
        let originalCount = entries.count
        entries.removeAll { reportIDs.contains($0.reportID) }
        return originalCount - entries.count
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}

private extension FixtureOperationHistoryLedger {
    static func makeEntry(
        preview: OperationPreview,
        report: OperationReport
    ) throws -> OperationHistoryEntry {
        guard report.previewID == preview.id,
              report.provider == preview.provider,
              report.operation == preview.operation,
              !preview.items.isEmpty,
              report.completedAt >= preview.generatedAt else {
            throw PersistentStateError.invalidRecord(
                "Fixture Report does not match its completed Preview."
            )
        }

        let previewItems = Dictionary(
            uniqueKeysWithValues: try unique(preview.items, key: \OperationPreviewItem.managerKey)
                .map { ($0.managerKey, $0) }
        )
        let resultItems = Dictionary(
            uniqueKeysWithValues: try unique(report.items, key: \OperationResultItem.managerKey)
                .map { ($0.managerKey, $0) }
        )
        guard Set(previewItems.keys) == Set(resultItems.keys) else {
            throw PersistentStateError.previewItemSetMismatch
        }

        let items = try previewItems.keys.sorted().map { managerKey -> OperationHistoryItem in
            guard let expected = previewItems[managerKey],
                  let result = resultItems[managerKey],
                  expected.nativeID == result.nativeID,
                  expected.title == result.title,
                  expected.projectName == result.projectName,
                  expected.workingDirectory == result.workingDirectory,
                  expected.beforeCollection == result.beforeCollection,
                  result.success
                    == (result.observedFinalCollection == expected.targetCollection) else {
                throw PersistentStateError.invalidRecord(
                    "Fixture Report identity does not match Preview item \(managerKey)."
                )
            }
            return OperationHistoryItem(
                managerKey: managerKey,
                nativeSessionID: result.nativeID,
                expectedNativeState: nativeState(expected.beforeCollection),
                sessionTitle: result.title,
                projectID: expected.projectID,
                knownSizeBytes: expected.sizeBytes,
                outcome: result.success ? .success : .failure,
                observedNativeState: nativeState(result.observedFinalCollection),
                verifiedReleasedBytes: nil,
                evidenceAt: report.completedAt,
                errorCode: result.success ? nil : "fixture_result_failed",
                errorMessage: result.success ? nil : result.note
            )
        }

        let successCount = items.filter { $0.outcome == .success }.count
        let failureCount = items.filter { $0.outcome == .failure }.count
        let outcome: PersistentReportOutcome
        if items.isEmpty {
            outcome = .unknown
        } else if successCount == items.count {
            outcome = .success
        } else if failureCount == items.count {
            outcome = .failure
        } else {
            outcome = .partial
        }

        return OperationHistoryEntry(
            reportID: report.id,
            previewID: preview.id,
            provider: report.provider,
            operation: PersistentOperation(report.operation),
            outcome: outcome,
            startedAt: preview.generatedAt,
            completedAt: report.completedAt,
            itemCount: items.count,
            successCount: successCount,
            failureCount: failureCount,
            unknownCount: 0,
            verifiedReleasedBytes: 0,
            releasedBytesComplete: false,
            errorCode: nil,
            errorMessage: nil,
            items: items
        )
    }

    static func unique<T>(_ values: [T], key: KeyPath<T, String>) throws -> [T] {
        var seen: Set<String> = []
        for value in values {
            let identifier = value[keyPath: key]
            guard !identifier.isEmpty, seen.insert(identifier).inserted else {
                throw PersistentStateError.invalidRecord(
                    "Fixture history contains an empty or duplicate manager key."
                )
            }
        }
        return values
    }

    static func nativeState(_ collection: SessionCollection) -> NativeSessionState {
        switch collection {
        case .active: .active
        case .archive, .trash: .archived
        case .deleted: .absent
        case .unavailable: .unavailable
        }
    }

    static func validate(_ query: OperationHistoryQuery) throws {
        guard (1 ... OperationHistoryQuery.maximumLimit).contains(query.limit) else {
            throw PersistentStateError.invalidRecord(
                "Operation history query limit must be between 1 and \(OperationHistoryQuery.maximumLimit)."
            )
        }
        if let from = query.completedFrom,
           let through = query.completedThrough,
           from > through {
            throw PersistentStateError.invalidRecord(
                "Operation history completedFrom must not follow completedThrough."
            )
        }
    }

    static func newestFirst(_ lhs: OperationHistoryEntry, _ rhs: OperationHistoryEntry) -> Bool {
        if lhs.completedAt != rhs.completedAt { return lhs.completedAt > rhs.completedAt }
        return lhs.reportID.uuidString.lowercased() > rhs.reportID.uuidString.lowercased()
    }

    static func isBeforeCursor(
        _ entry: OperationHistoryEntry,
        cursor: OperationHistoryCursor?
    ) -> Bool {
        guard let cursor else { return true }
        if entry.completedAt != cursor.completedAt {
            return entry.completedAt < cursor.completedAt
        }
        return entry.reportID.uuidString.lowercased()
            < cursor.reportID.uuidString.lowercased()
    }

    static func matchesSearch(_ entry: OperationHistoryEntry, needle: String) -> Bool {
        let reportValues = [
            entry.reportID.uuidString,
            entry.previewID.uuidString,
            entry.errorCode,
        ].compactMap { $0 }
        if reportValues.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) {
            return true
        }
        return entry.items.contains { item in
            [
                item.managerKey,
                item.nativeSessionID,
                item.sessionTitle,
                item.projectID,
                item.errorCode,
            ].compactMap { $0 }.contains {
                $0.localizedCaseInsensitiveContains(needle)
            }
        }
    }
}
