import Foundation

public struct OperationHistoryCursor: Codable, Equatable, Sendable {
    public let completedAt: Date
    public let reportID: UUID

    public init(completedAt: Date, reportID: UUID) {
        self.completedAt = completedAt
        self.reportID = reportID
    }
}

public struct OperationHistoryQuery: Equatable, Sendable {
    public static let defaultLimit = 100
    public static let maximumLimit = 500

    public let provider: AgentSystem?
    public let operation: PersistentOperation?
    public let outcome: PersistentReportOutcome?
    public let searchText: String?
    public let completedFrom: Date?
    public let completedThrough: Date?
    public let cursor: OperationHistoryCursor?
    public let limit: Int

    public init(
        provider: AgentSystem? = nil,
        operation: PersistentOperation? = nil,
        outcome: PersistentReportOutcome? = nil,
        searchText: String? = nil,
        completedFrom: Date? = nil,
        completedThrough: Date? = nil,
        cursor: OperationHistoryCursor? = nil,
        limit: Int = OperationHistoryQuery.defaultLimit
    ) {
        self.provider = provider
        self.operation = operation
        self.outcome = outcome
        self.searchText = searchText
        self.completedFrom = completedFrom
        self.completedThrough = completedThrough
        self.cursor = cursor
        self.limit = limit
    }
}

public struct OperationHistoryItem: Codable, Equatable, Sendable {
    public let managerKey: String
    public let nativeSessionID: String
    public let expectedNativeState: NativeSessionState
    public let sessionTitle: String
    public let projectID: String?
    public let knownSizeBytes: Int64?
    public let outcome: PersistentItemOutcome
    public let observedNativeState: NativeSessionState
    public let verifiedReleasedBytes: Int64?
    public let evidenceAt: Date
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        managerKey: String,
        nativeSessionID: String,
        expectedNativeState: NativeSessionState,
        sessionTitle: String,
        projectID: String? = nil,
        knownSizeBytes: Int64? = nil,
        outcome: PersistentItemOutcome,
        observedNativeState: NativeSessionState,
        verifiedReleasedBytes: Int64? = nil,
        evidenceAt: Date,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.managerKey = managerKey
        self.nativeSessionID = nativeSessionID
        self.expectedNativeState = expectedNativeState
        self.sessionTitle = sessionTitle
        self.projectID = projectID
        self.knownSizeBytes = knownSizeBytes
        self.outcome = outcome
        self.observedNativeState = observedNativeState
        self.verifiedReleasedBytes = verifiedReleasedBytes
        self.evidenceAt = evidenceAt
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public struct OperationHistoryEntry: Codable, Equatable, Sendable {
    public let reportID: UUID
    public let previewID: UUID
    public let provider: AgentSystem
    public let operation: PersistentOperation
    public let outcome: PersistentReportOutcome
    public let startedAt: Date
    public let completedAt: Date
    public let itemCount: Int
    public let successCount: Int
    public let failureCount: Int
    public let unknownCount: Int
    public let verifiedReleasedBytes: Int64
    public let releasedBytesComplete: Bool
    public let errorCode: String?
    public let errorMessage: String?
    public let items: [OperationHistoryItem]

    public init(
        reportID: UUID,
        previewID: UUID,
        provider: AgentSystem,
        operation: PersistentOperation,
        outcome: PersistentReportOutcome,
        startedAt: Date,
        completedAt: Date,
        itemCount: Int,
        successCount: Int,
        failureCount: Int,
        unknownCount: Int,
        verifiedReleasedBytes: Int64,
        releasedBytesComplete: Bool,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        items: [OperationHistoryItem]
    ) {
        self.reportID = reportID
        self.previewID = previewID
        self.provider = provider
        self.operation = operation
        self.outcome = outcome
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.itemCount = itemCount
        self.successCount = successCount
        self.failureCount = failureCount
        self.unknownCount = unknownCount
        self.verifiedReleasedBytes = verifiedReleasedBytes
        self.releasedBytesComplete = releasedBytesComplete
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.items = items
    }
}

public struct OperationHistoryPage: Equatable, Sendable {
    public let entries: [OperationHistoryEntry]
    public let nextCursor: OperationHistoryCursor?

    public init(entries: [OperationHistoryEntry], nextCursor: OperationHistoryCursor?) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

/// Export defaults deliberately omit user-authored and path-like metadata.
/// Native session IDs remain complete because they are the audit identity.
public struct OperationHistoryExportPolicy: Codable, Equatable, Sendable {
    public static let privateDefault = OperationHistoryExportPolicy()

    public let includeSessionTitles: Bool
    public let includeProjectIDs: Bool
    public let includeErrorMessages: Bool

    public init(
        includeSessionTitles: Bool = false,
        includeProjectIDs: Bool = false,
        includeErrorMessages: Bool = false
    ) {
        self.includeSessionTitles = includeSessionTitles
        self.includeProjectIDs = includeProjectIDs
        self.includeErrorMessages = includeErrorMessages
    }
}

public enum OperationHistoryExporter {
    public static func json(
        entries: [OperationHistoryEntry],
        policy: OperationHistoryExportPolicy = .privateDefault
    ) throws -> Data {
        let document = JSONDocument(
            formatVersion: 1,
            privacy: policy,
            reports: entries.map { JSONReport(entry: $0, policy: policy) }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    public static func csv(
        entries: [OperationHistoryEntry],
        policy: OperationHistoryExportPolicy = .privateDefault
    ) -> String {
        let header = [
            "report_id", "preview_id", "provider", "operation", "report_outcome",
            "started_at", "completed_at", "item_count", "success_count", "failure_count",
            "unknown_count", "verified_released_bytes", "released_bytes_complete",
            "report_error_code", "report_error_message", "manager_key", "native_session_id",
            "expected_native_state", "session_title", "project_id", "known_size_bytes",
            "item_outcome", "observed_native_state", "item_verified_released_bytes",
            "evidence_at", "item_error_code", "item_error_message",
        ]
        var rows = [header]
        for entry in entries {
            for item in entry.items {
                rows.append([
                    entry.reportID.uuidString.lowercased(),
                    entry.previewID.uuidString.lowercased(),
                    entry.provider.rawValue,
                    entry.operation.rawValue,
                    entry.outcome.rawValue,
                    encode(entry.startedAt),
                    encode(entry.completedAt),
                    String(entry.itemCount),
                    String(entry.successCount),
                    String(entry.failureCount),
                    String(entry.unknownCount),
                    String(entry.verifiedReleasedBytes),
                    entry.releasedBytesComplete ? "true" : "false",
                    entry.errorCode ?? "",
                    policy.includeErrorMessages ? entry.errorMessage ?? "" : "",
                    item.managerKey,
                    item.nativeSessionID,
                    item.expectedNativeState.rawValue,
                    policy.includeSessionTitles ? item.sessionTitle : "",
                    policy.includeProjectIDs ? item.projectID ?? "" : "",
                    item.knownSizeBytes.map(String.init) ?? "",
                    item.outcome.rawValue,
                    item.observedNativeState.rawValue,
                    item.verifiedReleasedBytes.map(String.init) ?? "",
                    encode(item.evidenceAt),
                    item.errorCode ?? "",
                    policy.includeErrorMessages ? item.errorMessage ?? "" : "",
                ])
            }
        }
        return rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}

private extension OperationHistoryExporter {
    struct JSONDocument: Encodable {
        let formatVersion: Int
        let privacy: OperationHistoryExportPolicy
        let reports: [JSONReport]
    }

    struct JSONReport: Encodable {
        let reportID: UUID
        let previewID: UUID
        let provider: AgentSystem
        let operation: PersistentOperation
        let outcome: PersistentReportOutcome
        let startedAt: Date
        let completedAt: Date
        let itemCount: Int
        let successCount: Int
        let failureCount: Int
        let unknownCount: Int
        let verifiedReleasedBytes: Int64
        let releasedBytesComplete: Bool
        let errorCode: String?
        let errorMessage: String?
        let items: [JSONItem]

        init(entry: OperationHistoryEntry, policy: OperationHistoryExportPolicy) {
            reportID = entry.reportID
            previewID = entry.previewID
            provider = entry.provider
            operation = entry.operation
            outcome = entry.outcome
            startedAt = entry.startedAt
            completedAt = entry.completedAt
            itemCount = entry.itemCount
            successCount = entry.successCount
            failureCount = entry.failureCount
            unknownCount = entry.unknownCount
            verifiedReleasedBytes = entry.verifiedReleasedBytes
            releasedBytesComplete = entry.releasedBytesComplete
            errorCode = entry.errorCode
            errorMessage = policy.includeErrorMessages ? entry.errorMessage : nil
            items = entry.items.map { JSONItem(item: $0, policy: policy) }
        }
    }

    struct JSONItem: Encodable {
        let managerKey: String
        let nativeSessionID: String
        let expectedNativeState: NativeSessionState
        let sessionTitle: String?
        let projectID: String?
        let knownSizeBytes: Int64?
        let outcome: PersistentItemOutcome
        let observedNativeState: NativeSessionState
        let verifiedReleasedBytes: Int64?
        let evidenceAt: Date
        let errorCode: String?
        let errorMessage: String?

        init(item: OperationHistoryItem, policy: OperationHistoryExportPolicy) {
            managerKey = item.managerKey
            nativeSessionID = item.nativeSessionID
            expectedNativeState = item.expectedNativeState
            sessionTitle = policy.includeSessionTitles ? item.sessionTitle : nil
            projectID = policy.includeProjectIDs ? item.projectID : nil
            knownSizeBytes = item.knownSizeBytes
            outcome = item.outcome
            observedNativeState = item.observedNativeState
            verifiedReleasedBytes = item.verifiedReleasedBytes
            evidenceAt = item.evidenceAt
            errorCode = item.errorCode
            errorMessage = policy.includeErrorMessages ? item.errorMessage : nil
        }
    }

    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func csvCell(_ rawValue: String) -> String {
        var value = rawValue
        if let first = value.first, ["=", "+", "-", "@", "\t", "\r"].contains(first) {
            value = "'" + value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
