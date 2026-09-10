import CryptoKit
import CSQLite3
import Foundation

private struct CodexGhostRepairSnapshotDryRunPersistedPayload:
    Codable,
    Hashable
{
    let requestID: UUID
    let preview: CodexGhostRepairSnapshotDryRunPreview
}

struct CodexGhostRepairSnapshotDryRunStoredPreview: Hashable, Sendable {
    let requestID: UUID
    let preview: CodexGhostRepairSnapshotDryRunPreview
    let payloadHash: String

    var persistsPreview: Bool { true }
    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }
}

public struct CodexGhostRepairSnapshotDryRunPersistenceReceipt:
    Codable,
    Hashable,
    Sendable
{
    public let requestID: UUID
    public let previewID: UUID
    public let payloadHash: String
    public let durableReadbackMatched: Bool

    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    init(
        requestID: UUID,
        previewID: UUID,
        payloadHash: String,
        durableReadbackMatched: Bool
    ) {
        self.requestID = requestID
        self.previewID = previewID
        self.payloadHash = payloadHash
        self.durableReadbackMatched = durableReadbackMatched
    }
}

public struct CodexGhostRepairSnapshotDryRunReadbackEvidence:
    Codable,
    Hashable,
    Sendable
{
    public let requestID: UUID
    public let preview: CodexGhostRepairSnapshotDryRunPreview
    public let payloadHash: String
    public let durableReadbackMatched: Bool

    public var readsPublishedSnapshot: Bool { false }
    public var readsCodexData: Bool { false }
    public var writesFilesystem: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public init(
        requestID: UUID,
        preview: CodexGhostRepairSnapshotDryRunPreview,
        payloadHash: String,
        durableReadbackMatched: Bool
    ) {
        self.requestID = requestID
        self.preview = preview
        self.payloadHash = payloadHash
        self.durableReadbackMatched = durableReadbackMatched
    }
}

public struct CodexGhostRepairSnapshotDryRunVerificationBundle:
    Hashable,
    Sendable
{
    public static let schemaIdentifier =
        "ghost-repair-preview-verification-v1"

    public let text: String

    public init(
        preview: CodexGhostRepairSnapshotDryRunPreview,
        requestID: UUID,
        payloadHash: String,
        durableReadbackMatched: Bool
    ) {
        let targets = preview.targetThreadIDs
            .map { "- \($0)" }
            .joined(separator: "\n")
        text = [
            "Ghost Repair Snapshot Dry-run Verification Bundle",
            "Schema: \(Self.schemaIdentifier)",
            "Snapshot UUID: \(preview.snapshotIdentity.snapshotReference)",
            "Request ID: \(requestID.uuidString.lowercased())",
            "Preview ID: \(preview.previewID.uuidString.lowercased())",
            "Preview digest: \(preview.previewDigest)",
            "Dry-run token: \(preview.dryRunToken)",
            "Payload hash: \(payloadHash)",
            "Exact readback: \(durableReadbackMatched ? "Matched" : "Unavailable")",
            "Target IDs:",
            targets,
            "Confirmation authority: None",
            "Repair mutation authority: None",
        ].joined(separator: "\n")
    }

    public var readsPublishedSnapshot: Bool { false }
    public var readsCodexData: Bool { false }
    public var readsManagerOwnedState: Bool { false }
    public var writesManagerOwnedState: Bool { false }
    public var retryAuthority: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public enum CodexGhostRepairSnapshotDryRunReadbackOutcome:
    Hashable,
    Sendable
{
    case observed(CodexGhostRepairSnapshotDryRunReadbackEvidence)
    case notFound(requestID: UUID)
    case unavailable(requestID: UUID, message: String)

    public var requestID: UUID {
        switch self {
        case let .observed(evidence): evidence.requestID
        case let .notFound(requestID), let .unavailable(requestID, _):
            requestID
        }
    }
}

public struct CodexGhostRepairSnapshotDryRunReadbackCapabilities:
    Hashable,
    Sendable
{
    public let explicitReadbackAvailable: Bool

    public var readsManagerOwnedState: Bool { explicitReadbackAvailable }
    public var readsPublishedSnapshot: Bool { false }
    public var readsCodexData: Bool { false }
    public var writesFilesystem: Bool { false }
    public var automaticReadback: Bool { false }
    public var retryAuthority: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let unavailable = Self(explicitReadbackAvailable: false)
    public static let packagedReadOnly = Self(explicitReadbackAvailable: true)
}

public protocol CodexGhostRepairSnapshotDryRunReadbackCoordinating:
    Sendable
{
    var capabilities: CodexGhostRepairSnapshotDryRunReadbackCapabilities {
        get
    }

    func readback(
        requestID: UUID
    ) async -> CodexGhostRepairSnapshotDryRunReadbackOutcome
}

public actor CodexGhostRepairSnapshotDryRunUnavailableReadbackCoordinator:
    CodexGhostRepairSnapshotDryRunReadbackCoordinating
{
    public nonisolated let capabilities =
        CodexGhostRepairSnapshotDryRunReadbackCapabilities.unavailable

    public init() {}

    public func readback(
        requestID: UUID
    ) async -> CodexGhostRepairSnapshotDryRunReadbackOutcome {
        .unavailable(
            requestID: requestID,
            message: "Saved Preview readback is unavailable in this build."
        )
    }
}

actor CodexGhostRepairSnapshotDryRunLiveReadbackCoordinator:
    CodexGhostRepairSnapshotDryRunReadbackCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairSnapshotDryRunReadbackCapabilities.packagedReadOnly
    private let databaseURLProvider: @Sendable () throws -> URL

    init(
        databaseURLProvider: @escaping @Sendable () throws -> URL = {
            try StateStoreLocation.applicationSupportDatabaseURL()
        }
    ) {
        self.databaseURLProvider = databaseURLProvider
    }

    func readback(
        requestID: UUID
    ) async -> CodexGhostRepairSnapshotDryRunReadbackOutcome {
        do {
            let databaseURL = try databaseURLProvider()
            let reader = try CodexGhostRepairSnapshotDryRunReadOnlyStore(
                databaseURL: databaseURL
            )
            defer { reader.close() }
            guard let stored = try reader.preview(requestID: requestID)
            else {
                return .notFound(requestID: requestID)
            }
            guard stored.requestID == requestID,
                  stored.payloadHash.hasPrefix("sha256:"),
                  stored.payloadHash.count == 71,
                  !stored.confirmationAuthority,
                  !stored.repairMutationAuthority,
                  !stored.preview.confirmationAuthority,
                  !stored.preview.repairMutationAuthority else {
                return .unavailable(
                    requestID: requestID,
                    message:
                        "Saved Preview readback did not match the exact authority-free record."
                )
            }
            return .observed(.init(
                requestID: stored.requestID,
                preview: stored.preview,
                payloadHash: stored.payloadHash,
                durableReadbackMatched: true
            ))
        } catch {
            return .unavailable(
                requestID: requestID,
                message:
                    "Saved Preview readback could not produce exact manager-owned evidence."
            )
        }
    }
}

private final class CodexGhostRepairSnapshotDryRunReadOnlyStore {
    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &pointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw PersistentStateError.invalidRecord(
                "Saved Preview state store could not be opened read-only."
            )
        }
        database = pointer
        do {
            guard sqlite3_db_readonly(pointer, "main") == 1 else {
                throw PersistentStateError.invalidRecord(
                    "Saved Preview state connection was not read-only."
                )
            }
            guard sqlite3_exec(
                pointer,
                "PRAGMA query_only=ON",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw PersistentStateError.invalidRecord(
                    "Saved Preview state connection rejected query_only."
                )
            }
            guard try scalar("PRAGMA query_only") == 1,
                  try scalar("PRAGMA application_id")
                    == Int64(SQLiteStateStore.applicationID),
                  try scalar("PRAGMA user_version")
                    == Int64(SQLiteStateStore.currentSchemaVersion) else {
                throw PersistentStateError.invalidRecord(
                    "Saved Preview state database contract did not match."
                )
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    func preview(
        requestID: UUID
    ) throws -> CodexGhostRepairSnapshotDryRunStoredPreview? {
        guard let database else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview state connection is closed."
            )
        }
        let sql =
            """
            SELECT preview_id, snapshot_reference, category, preview_digest,
                   dry_run_token, generated_at_ms, expires_at_ms, target_count,
                   payload_json, payload_hash, confirmation_authority,
                   repair_mutation_authority
            FROM codex_ghost_repair_dry_run_previews
            WHERE request_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview fixed query could not be prepared."
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview fixed query was not read-only."
            )
        }
        let canonicalRequestID = requestID.uuidString.lowercased()
        let bindResult = canonicalRequestID.withCString { pointer in
            sqlite3_bind_text(
                statement,
                1,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard bindResult == SQLITE_OK else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview request ID could not be bound."
            )
        }

        let firstStep = sqlite3_step(statement)
        if firstStep == SQLITE_DONE { return nil }
        guard firstStep == SQLITE_ROW else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview fixed query did not complete."
            )
        }

        let previewID = try SQLiteStateStore.requiredCanonicalUUID(
            requiredText(statement, 0),
            field: "preview_id"
        )
        let snapshotReference = try requiredText(statement, 1)
        guard let category = CodexGhostRepairCategory(
            rawValue: try requiredText(statement, 2)
        ) else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview category is unknown."
            )
        }
        let previewDigest = try requiredText(statement, 3)
        let dryRunToken = try requiredText(statement, 4)
        let generatedAt = sqlite3_column_int64(statement, 5)
        let expiresAt = sqlite3_column_int64(statement, 6)
        let targetCount = Int(sqlite3_column_int64(statement, 7))
        let encoded = try requiredText(statement, 8)
        let payloadHash = try requiredText(statement, 9)
        let confirmationAuthority = sqlite3_column_int64(statement, 10)
        let repairMutationAuthority = sqlite3_column_int64(statement, 11)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview fixed query returned duplicate rows."
            )
        }
        guard payloadHash == SQLiteStateStore.hashDryRunPayload(encoded) else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview payload hash does not match."
            )
        }
        let payload: CodexGhostRepairSnapshotDryRunPersistedPayload =
            try SQLiteStateStore.decodeDryRunPayload(encoded)
        try payload.preview.validateForPersistence()
        guard payload.requestID == requestID,
              payload.preview.previewID == previewID,
              payload.preview.snapshotIdentity.snapshotReference
                == snapshotReference,
              payload.preview.category == category,
              payload.preview.previewDigest == previewDigest,
              payload.preview.dryRunToken == dryRunToken,
              payload.preview.generatedAtMilliseconds == generatedAt,
              payload.preview.expiresAtMilliseconds == expiresAt,
              payload.preview.targetThreadIDs.count == targetCount,
              confirmationAuthority == 0,
              repairMutationAuthority == 0 else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview columns and payload disagree."
            )
        }
        return .init(
            requestID: requestID,
            preview: payload.preview,
            payloadHash: payloadHash
        )
    }

    private func scalar(_ sql: String) throws -> Int64 {
        guard let database else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview state connection is closed."
            )
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview database contract query failed."
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview database contract could not be read."
            )
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func requiredText(
        _ statement: OpaquePointer,
        _ column: Int32
    ) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let text = sqlite3_column_text(statement, column) else {
            throw PersistentStateError.invalidRecord(
                "Saved Preview fixed query returned an invalid text field."
            )
        }
        return String(cString: text)
    }
}

public enum CodexGhostRepairSnapshotDryRunReadbackCoordinatorFactory {
    /// Construction performs no I/O. The manager-owned state database is
    /// opened only after the user explicitly requests one exact request ID.
    public static func packagedReadOnly()
        -> any CodexGhostRepairSnapshotDryRunReadbackCoordinating
    {
        CodexGhostRepairSnapshotDryRunLiveReadbackCoordinator()
    }
}

protocol CodexGhostRepairSnapshotDryRunPreviewPersisting: Sendable {
    func persist(
        requestID: UUID,
        preview: CodexGhostRepairSnapshotDryRunPreview
    ) async throws -> CodexGhostRepairSnapshotDryRunPersistenceReceipt
}

/// Construction is zero-I/O. The manager-owned state store is opened only
/// after an admitted, authority-free Preview has been planned. The existing
/// repository performs its own transaction and exact immediate readback.
actor CodexGhostRepairSnapshotDryRunLivePreviewPersister:
    CodexGhostRepairSnapshotDryRunPreviewPersisting
{
    func persist(
        requestID: UUID,
        preview: CodexGhostRepairSnapshotDryRunPreview
    ) async throws -> CodexGhostRepairSnapshotDryRunPersistenceReceipt {
        let databaseURL = try StateStoreLocation
            .applicationSupportDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        let stored = try store.saveCodexGhostRepairSnapshotDryRunPreview(
            requestID: requestID,
            preview: preview
        )
        guard stored.requestID == requestID,
              stored.preview == preview,
              stored.payloadHash.hasPrefix("sha256:"),
              stored.payloadHash.count == 71,
              !stored.confirmationAuthority,
              !stored.repairMutationAuthority else {
            throw PersistentStateError.invalidRecord(
                "Dry-run Preview persistence receipt did not match exactly."
            )
        }
        return .init(
            requestID: stored.requestID,
            previewID: stored.preview.previewID,
            payloadHash: stored.payloadHash,
            durableReadbackMatched: true
        )
    }
}

extension SQLiteStateStore {
    /// Persists one authority-free M2 dry-run Preview. The request ID and
    /// Preview ID are both unique; exact replay is an idempotent readback and
    /// any changed payload fails closed.
    @discardableResult
    func saveCodexGhostRepairSnapshotDryRunPreview(
        requestID: UUID,
        preview: CodexGhostRepairSnapshotDryRunPreview
    ) throws -> CodexGhostRepairSnapshotDryRunStoredPreview {
        try preview.validateForPersistence()
        let payload = CodexGhostRepairSnapshotDryRunPersistedPayload(
            requestID: requestID,
            preview: preview
        )
        let encoded = try Self.encodeDryRunPayload(payload)
        let payloadHash = Self.hashDryRunPayload(encoded)
        let expected = CodexGhostRepairSnapshotDryRunStoredPreview(
            requestID: requestID,
            preview: preview,
            payloadHash: payloadHash
        )

        try withLockedDatabase { database in
            try transaction(database) {
                if let existing = try loadCodexGhostRepairSnapshotDryRunPreview(
                    requestID: requestID,
                    database: database
                ) {
                    guard existing == expected else {
                        throw PersistentStateError.invalidRecord(
                            "Dry-run Preview request ID already belongs to different evidence."
                        )
                    }
                    return
                }

                try execute(
                    """
                    INSERT INTO codex_ghost_repair_dry_run_previews (
                        request_id, preview_id, snapshot_reference, category,
                        preview_digest, dry_run_token, generated_at_ms,
                        expires_at_ms, target_count, payload_json, payload_hash,
                        confirmation_authority, repair_mutation_authority
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
                    """,
                    values: [
                        .text(requestID.uuidString.lowercased()),
                        .text(preview.previewID.uuidString.lowercased()),
                        .text(preview.snapshotIdentity.snapshotReference),
                        .text(preview.category.rawValue),
                        .text(preview.previewDigest),
                        .text(preview.dryRunToken),
                        .int64(preview.generatedAtMilliseconds),
                        .int64(preview.expiresAtMilliseconds),
                        .int64(Int64(preview.targetThreadIDs.count)),
                        .text(encoded),
                        .text(payloadHash),
                    ],
                    database: database
                )
            }
        }

        guard try codexGhostRepairSnapshotDryRunPreview(
            requestID: requestID
        ) == expected else {
            throw PersistentStateError.invalidRecord(
                "Dry-run Preview durable readback did not match exactly."
            )
        }
        return expected
    }

    func codexGhostRepairSnapshotDryRunPreview(
        requestID: UUID
    ) throws -> CodexGhostRepairSnapshotDryRunStoredPreview? {
        try withLockedDatabase { database in
            try loadCodexGhostRepairSnapshotDryRunPreview(
                requestID: requestID,
                database: database
            )
        }
    }
}

fileprivate extension SQLiteStateStore {
    func loadCodexGhostRepairSnapshotDryRunPreview(
        requestID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairSnapshotDryRunStoredPreview? {
        let rows = try query(
            """
            SELECT preview_id, snapshot_reference, category, preview_digest,
                   dry_run_token, generated_at_ms, expires_at_ms, target_count,
                   payload_json, payload_hash, confirmation_authority,
                   repair_mutation_authority
            FROM codex_ghost_repair_dry_run_previews
            WHERE request_id = ?
            """,
            values: [.text(requestID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairSnapshotDryRunStoredPreview in
            let previewID = try Self.requiredCanonicalUUID(
                requiredText(statement, 0),
                field: "preview_id"
            )
            let snapshotReference = try requiredText(statement, 1)
            guard let category = CodexGhostRepairCategory(
                rawValue: try requiredText(statement, 2)
            ) else {
                throw PersistentStateError.invalidRecord(
                    "Dry-run Preview category is unknown."
                )
            }
            let previewDigest = try requiredText(statement, 3)
            let dryRunToken = try requiredText(statement, 4)
            let generatedAt = sqlite3_column_int64(statement, 5)
            let expiresAt = sqlite3_column_int64(statement, 6)
            let targetCount = Int(sqlite3_column_int64(statement, 7))
            let encoded = try requiredText(statement, 8)
            let payloadHash = try requiredText(statement, 9)
            let confirmationAuthority = sqlite3_column_int64(statement, 10)
            let repairMutationAuthority = sqlite3_column_int64(statement, 11)

            guard payloadHash == Self.hashDryRunPayload(encoded) else {
                throw PersistentStateError.invalidRecord(
                    "Dry-run Preview payload hash does not match."
                )
            }
            let payload: CodexGhostRepairSnapshotDryRunPersistedPayload =
                try Self.decodeDryRunPayload(encoded)
            try payload.preview.validateForPersistence()
            guard payload.requestID == requestID,
                  payload.preview.previewID == previewID,
                  payload.preview.snapshotIdentity.snapshotReference
                    == snapshotReference,
                  payload.preview.category == category,
                  payload.preview.previewDigest == previewDigest,
                  payload.preview.dryRunToken == dryRunToken,
                  payload.preview.generatedAtMilliseconds == generatedAt,
                  payload.preview.expiresAtMilliseconds == expiresAt,
                  payload.preview.targetThreadIDs.count == targetCount,
                  confirmationAuthority == 0,
                  repairMutationAuthority == 0 else {
                throw PersistentStateError.invalidRecord(
                    "Dry-run Preview columns and payload disagree."
                )
            }
            return .init(
                requestID: requestID,
                preview: payload.preview,
                payloadHash: payloadHash
            )
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate dry-run Preview rows."
            )
        }
        return rows.first
    }

    static func encodeDryRunPayload<T: Encodable>(_ value: T) throws
        -> String
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw PersistentStateError.invalidRecord(
                "Dry-run Preview payload is not valid UTF-8."
            )
        }
        return encoded
    }

    static func decodeDryRunPayload<T: Decodable>(_ encoded: String) throws
        -> T
    {
        guard let data = encoded.data(using: .utf8) else {
            throw PersistentStateError.invalidRecord(
                "Dry-run Preview payload is not valid UTF-8."
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func hashDryRunPayload(_ encoded: String) -> String {
        let digest = SHA256.hash(data: Data(encoded.utf8))
        return "sha256:"
            + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func requiredCanonicalUUID(
        _ value: String,
        field: String
    ) throws -> UUID {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw PersistentStateError.invalidRecord(
                "Dry-run Preview \(field) is not canonical."
            )
        }
        return uuid
    }
}
