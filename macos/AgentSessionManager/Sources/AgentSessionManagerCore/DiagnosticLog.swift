import Foundation

public enum DiagnosticLogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case info
    case warning
    case error

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

public enum DiagnosticLogCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case app
    case inventory
    case lifecycle
    case storage
    case recovery

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .app: "App"
        case .inventory: "Inventory"
        case .lifecycle: "Lifecycle"
        case .storage: "Storage"
        case .recovery: "Recovery"
        }
    }
}

public struct DiagnosticEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: DiagnosticLogLevel
    public let category: DiagnosticLogCategory
    public let message: String
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: DiagnosticLogLevel,
        category: DiagnosticLogCategory,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

public struct DiagnosticLogRetentionPolicy: Equatable, Sendable {
    public static let production = DiagnosticLogRetentionPolicy(
        maximumEvents: 10_000,
        maximumAge: 30 * 24 * 60 * 60,
        maximumBytes: 20 * 1_024 * 1_024
    )

    public let maximumEvents: Int
    public let maximumAge: TimeInterval
    public let maximumBytes: Int

    public init(
        maximumEvents: Int,
        maximumAge: TimeInterval,
        maximumBytes: Int
    ) {
        self.maximumEvents = maximumEvents
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
    }
}

public struct DiagnosticLogSnapshot: Equatable, Sendable {
    public static let empty = DiagnosticLogSnapshot(
        events: [],
        fileByteCount: 0,
        discardedCorruptLineCount: 0,
        retentionPolicy: .production
    )

    /// Newest event first for direct presentation in Settings.
    public let events: [DiagnosticEvent]
    public let fileByteCount: Int
    public let discardedCorruptLineCount: Int
    public let retentionPolicy: DiagnosticLogRetentionPolicy

    public var oldestEventAt: Date? { events.last?.timestamp }
    public var newestEventAt: Date? { events.first?.timestamp }
}

public enum DiagnosticLogStoreError: Error, Equatable, LocalizedError {
    case invalidRetentionPolicy
    case emptyMessage

    public var errorDescription: String? {
        switch self {
        case .invalidRetentionPolicy:
            "Diagnostic Log retention values must all be greater than zero."
        case .emptyMessage:
            "Diagnostic Log messages cannot be empty."
        }
    }
}

public enum DiagnosticLogPersistenceStatus: Equatable, Sendable {
    case persistent(fileURL: URL)
    case inMemoryFallback(intendedFileURL: URL?, failureDescription: String)

    public var fileURL: URL? {
        switch self {
        case let .persistent(fileURL):
            fileURL
        case .inMemoryFallback:
            nil
        }
    }

    public var warningMessage: String? {
        switch self {
        case .persistent:
            nil
        case let .inMemoryFallback(intendedFileURL, failureDescription):
            "Diagnostic Logs could not be opened at "
                + "\(intendedFileURL?.path ?? "the Application Support location"). "
                + "This run is being kept in memory only and will be lost when the app quits. "
                + "Existing on-disk logs were not changed. Reason: \(failureDescription)"
        }
    }
}

public struct DiagnosticLogBootstrapResult: Sendable {
    public let store: DiagnosticLogStore
    public let persistenceStatus: DiagnosticLogPersistenceStatus
}

public enum DiagnosticLogBootstrap {
    public static func make(
        fileURLProvider: @Sendable () throws -> URL,
        persistentStoreFactory: @Sendable (URL) throws -> DiagnosticLogStore = {
            try DiagnosticLogStore(fileURL: $0)
        }
    ) -> DiagnosticLogBootstrapResult {
        do {
            return make(
                fileURL: try fileURLProvider(),
                persistentStoreFactory: persistentStoreFactory
            )
        } catch {
            return inMemoryFallback(
                intendedFileURL: nil,
                failureDescription: error.localizedDescription
            )
        }
    }

    public static func make(
        fileURL: URL,
        persistentStoreFactory: @Sendable (URL) throws -> DiagnosticLogStore = {
            try DiagnosticLogStore(fileURL: $0)
        }
    ) -> DiagnosticLogBootstrapResult {
        do {
            return DiagnosticLogBootstrapResult(
                store: try persistentStoreFactory(fileURL),
                persistenceStatus: .persistent(fileURL: fileURL)
            )
        } catch {
            return inMemoryFallback(
                intendedFileURL: fileURL,
                failureDescription: error.localizedDescription
            )
        }
    }

    private static func inMemoryFallback(
        intendedFileURL: URL?,
        failureDescription: String
    ) -> DiagnosticLogBootstrapResult {
        DiagnosticLogBootstrapResult(
            store: DiagnosticLogStore.productionInMemory(),
            persistenceStatus: .inMemoryFallback(
                intendedFileURL: intendedFileURL,
                failureDescription: failureDescription
            )
        )
    }
}

/// App-owned, privacy-bounded diagnostic timeline. It never reads or writes
/// Codex session files and is intentionally separate from lifecycle audit
/// Reports. The JSONL file is append-only between retention passes; pruning
/// rewrites the retained set atomically.
public actor DiagnosticLogStore {
    public nonisolated let fileURL: URL?
    public nonisolated let retentionPolicy: DiagnosticLogRetentionPolicy

    private struct StoredEvent {
        let event: DiagnosticEvent
        let encodedLine: Data
    }

    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var storedEvents: [StoredEvent]
    private var fileByteCount: Int
    private var discardedCorruptLineCount: Int

    public nonisolated static func productionInMemory(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> DiagnosticLogStore {
        DiagnosticLogStore(
            validatedInMemoryRetentionPolicy: .production,
            fileManager: fileManager,
            now: now
        )
    }

    private init(
        validatedInMemoryRetentionPolicy retentionPolicy: DiagnosticLogRetentionPolicy,
        fileManager: FileManager,
        now: @escaping @Sendable () -> Date
    ) {
        self.fileURL = nil
        self.retentionPolicy = retentionPolicy
        self.fileManager = fileManager
        self.now = now
        self.storedEvents = []
        self.fileByteCount = 0
        self.discardedCorruptLineCount = 0
    }

    public init(
        fileURL: URL? = nil,
        retentionPolicy: DiagnosticLogRetentionPolicy = .production,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard retentionPolicy.maximumEvents > 0,
              retentionPolicy.maximumAge > 0,
              retentionPolicy.maximumBytes > 0 else {
            throw DiagnosticLogStoreError.invalidRetentionPolicy
        }
        self.fileURL = fileURL
        self.retentionPolicy = retentionPolicy
        self.fileManager = fileManager
        self.now = now

        var loaded: [StoredEvent] = []
        var corruptLines = 0
        if let fileURL, fileManager.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let line = Data(rawLine)
                do {
                    let event = try Self.decoder().decode(DiagnosticEvent.self, from: line)
                    loaded.append(
                        StoredEvent(
                            event: event,
                            encodedLine: try Self.encodedLine(event)
                        )
                    )
                } catch {
                    corruptLines += 1
                }
            }
        }

        let sortedLoaded = loaded.sorted(by: Self.isChronologicallyBefore)
        let pruned = Self.pruned(
            sortedLoaded,
            now: now(),
            policy: retentionPolicy
        )
        let needsRewrite = corruptLines > 0 || pruned.count != sortedLoaded.count
        self.storedEvents = pruned
        self.fileByteCount = pruned.reduce(0) { $0 + $1.encodedLine.count }
        self.discardedCorruptLineCount = corruptLines
        if needsRewrite, let fileURL {
            try Self.rewrite(
                pruned,
                to: fileURL,
                fileManager: fileManager
            )
        }
    }

    @discardableResult
    public func record(
        level: DiagnosticLogLevel,
        category: DiagnosticLogCategory,
        message: String,
        metadata: [String: String] = [:],
        timestamp: Date? = nil
    ) throws -> DiagnosticLogSnapshot {
        let sanitizedMessage = Self.sanitized(message, maximumLength: 4_096)
        guard !sanitizedMessage.isEmpty else {
            throw DiagnosticLogStoreError.emptyMessage
        }
        let event = DiagnosticEvent(
            timestamp: timestamp ?? now(),
            level: level,
            category: category,
            message: sanitizedMessage,
            metadata: Self.sanitizedMetadata(metadata)
        )
        let stored = StoredEvent(
            event: event,
            encodedLine: try Self.encodedLine(event)
        )
        storedEvents.append(stored)
        storedEvents.sort(by: Self.isChronologicallyBefore)

        let beforePruneCount = storedEvents.count
        let pruned = Self.pruned(
            storedEvents,
            now: now(),
            policy: retentionPolicy
        )
        let appendedAtEnd = storedEvents.last?.event.id == event.id
        let needsRewrite = pruned.count != beforePruneCount || !appendedAtEnd
        storedEvents = pruned
        fileByteCount = pruned.reduce(0) { $0 + $1.encodedLine.count }

        if let fileURL {
            if needsRewrite {
                try Self.rewrite(pruned, to: fileURL, fileManager: fileManager)
            } else {
                try Self.append(stored.encodedLine, to: fileURL, fileManager: fileManager)
            }
        }
        return makeSnapshot()
    }

    public func snapshot() throws -> DiagnosticLogSnapshot {
        let pruned = Self.pruned(
            storedEvents,
            now: now(),
            policy: retentionPolicy
        )
        if pruned.count != storedEvents.count {
            storedEvents = pruned
            fileByteCount = pruned.reduce(0) { $0 + $1.encodedLine.count }
            if let fileURL {
                try Self.rewrite(pruned, to: fileURL, fileManager: fileManager)
            }
        }
        return makeSnapshot()
    }

    public func exportJSONL() throws -> Data {
        _ = try snapshot()
        return storedEvents.reduce(into: Data()) { data, stored in
            data.append(stored.encodedLine)
        }
    }

    private func makeSnapshot() -> DiagnosticLogSnapshot {
        DiagnosticLogSnapshot(
            events: storedEvents.reversed().map(\.event),
            fileByteCount: fileByteCount,
            discardedCorruptLineCount: discardedCorruptLineCount,
            retentionPolicy: retentionPolicy
        )
    }

    private static func pruned(
        _ source: [StoredEvent],
        now: Date,
        policy: DiagnosticLogRetentionPolicy
    ) -> [StoredEvent] {
        let cutoff = now.addingTimeInterval(-policy.maximumAge)
        var retained = source
            .filter { $0.event.timestamp >= cutoff }
            .sorted(by: isChronologicallyBefore)
        if retained.count > policy.maximumEvents {
            retained.removeFirst(retained.count - policy.maximumEvents)
        }
        var bytes = retained.reduce(0) { $0 + $1.encodedLine.count }
        while retained.count > 1, bytes > policy.maximumBytes {
            bytes -= retained.removeFirst().encodedLine.count
        }
        if retained.first?.encodedLine.count ?? 0 > policy.maximumBytes {
            retained.removeAll()
        }
        return retained
    }

    private static func isChronologicallyBefore(_ lhs: StoredEvent, _ rhs: StoredEvent) -> Bool {
        if lhs.event.timestamp != rhs.event.timestamp {
            return lhs.event.timestamp < rhs.event.timestamp
        }
        return lhs.event.id.uuidString < rhs.event.id.uuidString
    }

    private static func sanitizedMetadata(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in metadata.keys.sorted().prefix(32) {
            guard !isSensitiveMetadataKey(key) else { continue }
            let cleanKey = sanitized(key, maximumLength: 64)
            let cleanValue = sanitized(metadata[key] ?? "", maximumLength: 1_024)
            guard !cleanKey.isEmpty, !cleanValue.isEmpty else { continue }
            result[cleanKey] = cleanValue
        }
        return result
    }

    private static func isSensitiveMetadataKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return ["token", "payload", "conversation", "prompt", "body", "content"]
            .contains { normalized.contains($0) }
    }

    private static func sanitized(_ value: String, maximumLength: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumLength))
    }

    private static func encodedLine(_ event: DiagnosticEvent) throws -> Data {
        var data = try encoder().encode(event)
        data.append(0x0A)
        return data
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func append(
        _ data: Data,
        to fileURL: URL,
        fileManager: FileManager
    ) throws {
        try prepareDirectory(for: fileURL, fileManager: fileManager)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    private static func rewrite(
        _ events: [StoredEvent],
        to fileURL: URL,
        fileManager: FileManager
    ) throws {
        try prepareDirectory(for: fileURL, fileManager: fileManager)
        let data = events.reduce(into: Data()) { output, event in
            output.append(event.encodedLine)
        }
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    private static func prepareDirectory(
        for fileURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
