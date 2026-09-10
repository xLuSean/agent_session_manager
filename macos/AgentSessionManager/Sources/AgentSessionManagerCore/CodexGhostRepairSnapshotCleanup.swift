import CSQLite3
import Darwin
import Foundation

public struct CodexGhostRepairSnapshotCleanupCapabilities:
    Equatable,
    Sendable
{
    public let inspectionAvailable: Bool
    public let moveToManagerTrashAvailable: Bool

    public var acceptsCallerPath: Bool { false }
    public var permanentDeletionAuthority: Bool { false }
    public var opensRawDatabaseContents: Bool { false }
    public var codexDatabaseMutationAuthority: Bool { false }
    public var automaticCleanupAuthority: Bool { false }
    public var retryAllowed: Bool { false }

    public static let packaged = Self(
        inspectionAvailable: true,
        moveToManagerTrashAvailable: true
    )
    public static let unavailable = Self(
        inspectionAvailable: false,
        moveToManagerTrashAvailable: false
    )
}

public enum CodexGhostRepairSnapshotCleanupEligibility:
    Equatable,
    Sendable
{
    case eligible
    case protectedByActivePreview(count: Int)
    case protectedByRepair(count: Int)
}

public struct CodexGhostRepairSnapshotCleanupItem: Equatable, Sendable {
    public let reference: String
    public let publishedAtMilliseconds: Int64
    public let actualBytes: UInt64
    public let activePreviewCount: Int
    public let nonterminalRepairCount: Int
    public let historicalReferenceCount: Int
    public let eligibility: CodexGhostRepairSnapshotCleanupEligibility

    public var canMoveToTrash: Bool { eligibility == .eligible }
    public var permanentDeletionAuthority: Bool { false }
    public var codexDatabaseMutationAuthority: Bool { false }
}

public struct CodexGhostRepairSnapshotCleanupInventory:
    Equatable,
    Sendable
{
    public let snapshots: [CodexGhostRepairSnapshotCleanupItem]
    public let activeSnapshotCount: Int
    public let maximumSnapshotCount: Int
    public let totalActiveBytes: UInt64

    public var pathRedacted: Bool { true }
    public var automaticCleanupAuthority: Bool { false }
    public var permanentDeletionAuthority: Bool { false }
    public var codexDatabaseMutationAuthority: Bool { false }
}

public enum CodexGhostRepairSnapshotCleanupInspectionOutcome:
    Equatable,
    Sendable
{
    case observed(CodexGhostRepairSnapshotCleanupInventory)
    case unavailable(message: String)
}

public struct CodexGhostRepairSnapshotCleanupReview: Equatable, Sendable {
    public let operationID: UUID
    public let snapshot: CodexGhostRepairSnapshotCleanupItem
    public let activeSnapshotCountBefore: Int
    public let activeSnapshotCountAfter: Int
    public let previewDigest: String

    public var effectDescription: String {
        "Move exactly snapshot \(snapshot.reference) from active Snapshot Storage to Agent Session Manager Trash."
    }

    public var retryAllowed: Bool { false }
    public var restorePerformedAutomatically: Bool { false }
    public var permanentDeletionAuthority: Bool { false }
    public var codexDatabaseMutationAuthority: Bool { false }
}

public enum CodexGhostRepairSnapshotCleanupPrepareOutcome:
    Equatable,
    Sendable
{
    case ready(CodexGhostRepairSnapshotCleanupReview)
    case blocked(message: String)
    case unavailable(message: String)
}

public struct CodexGhostRepairSnapshotCleanupReport: Equatable, Sendable {
    public let operationID: UUID
    public let snapshotReference: String
    public let movedToManagerTrash: Bool
    public let activeSnapshotCountBefore: Int
    public let activeSnapshotCountAfter: Int
    public let completedAtMilliseconds: Int64
    public let reportDigest: String

    public var exactItemCount: Int { 1 }
    public var retryAllowed: Bool { false }
    public var permanentDeletionPerformed: Bool { false }
    public var codexDatabaseMutated: Bool { false }
}

public enum CodexGhostRepairSnapshotCleanupExecutionOutcome:
    Equatable,
    Sendable
{
    case completed(CodexGhostRepairSnapshotCleanupReport)
    case rejected(message: String)
    case recoveryRequired(operationID: UUID, message: String)
}

public protocol CodexGhostRepairSnapshotCleanupCoordinating: Sendable {
    var capabilities: CodexGhostRepairSnapshotCleanupCapabilities { get }
    func inspect() async -> CodexGhostRepairSnapshotCleanupInspectionOutcome
    func prepare(
        snapshotReference: String
    ) async -> CodexGhostRepairSnapshotCleanupPrepareOutcome
    func execute(
        operationID: UUID
    ) async -> CodexGhostRepairSnapshotCleanupExecutionOutcome
}

public enum CodexGhostRepairSnapshotCleanupCoordinatorFactory {
    /// Construction performs no I/O. Live manager-owned metadata and snapshot
    /// storage are opened only after an explicit inspect, review, or execution.
    public static func packaged()
        -> any CodexGhostRepairSnapshotCleanupCoordinating
    {
        CodexGhostRepairSnapshotCleanupCoordinator.production()
    }
}

struct CodexGhostRepairSnapshotCleanupDependencyEvidence:
    Codable,
    Equatable,
    Sendable
{
    let activePreviewCount: Int
    let nonterminalRepairCount: Int
    let historicalReferenceCount: Int

    var eligibility: CodexGhostRepairSnapshotCleanupEligibility {
        if nonterminalRepairCount > 0 {
            return .protectedByRepair(count: nonterminalRepairCount)
        }
        if activePreviewCount > 0 {
            return .protectedByActivePreview(count: activePreviewCount)
        }
        return .eligible
    }
}

protocol CodexGhostRepairSnapshotCleanupDependencyReading: Sendable {
    func evidence(
        snapshotReference: String,
        nowMilliseconds: Int64
    ) async throws -> CodexGhostRepairSnapshotCleanupDependencyEvidence
}

private struct CodexGhostRepairSnapshotCleanupReadOnlyDependencyReader:
    CodexGhostRepairSnapshotCleanupDependencyReading,
    Sendable
{
    let databaseURLProvider: @Sendable () throws -> URL

    static func production() -> Self {
        Self(databaseURLProvider: {
            try StateStoreLocation.applicationSupportDatabaseURL()
        })
    }

    func evidence(
        snapshotReference: String,
        nowMilliseconds: Int64
    ) async throws -> CodexGhostRepairSnapshotCleanupDependencyEvidence {
        let store = try Store(databaseURL: databaseURLProvider())
        defer { store.close() }
        return try store.evidence(
            snapshotReference: snapshotReference,
            nowMilliseconds: nowMilliseconds
        )
    }

    private final class Store {
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
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot dependency evidence is unavailable."
                )
            }
            database = pointer
            do {
                guard sqlite3_db_readonly(pointer, "main") == 1,
                      sqlite3_exec(
                        pointer,
                        "PRAGMA query_only=ON",
                        nil,
                        nil,
                        nil
                      ) == SQLITE_OK,
                      try scalar("PRAGMA query_only") == 1,
                      try scalar("PRAGMA application_id")
                        == Int64(SQLiteStateStore.applicationID),
                      try scalar("PRAGMA user_version")
                        == Int64(SQLiteStateStore.currentSchemaVersion) else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Snapshot dependency database contract does not match."
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

        func evidence(
            snapshotReference: String,
            nowMilliseconds: Int64
        ) throws -> CodexGhostRepairSnapshotCleanupDependencyEvidence {
            let activePreviewCount = try count(
                """
                SELECT COUNT(*)
                FROM codex_ghost_repair_dry_run_previews
                WHERE snapshot_reference = ? AND expires_at_ms >= ?
                """,
                text: snapshotReference,
                integer: nowMilliseconds
            )
            let allPreviewCount = try count(
                """
                SELECT COUNT(*)
                FROM codex_ghost_repair_dry_run_previews
                WHERE snapshot_reference = ?
                """,
                text: snapshotReference
            )
            let nonterminalRepairCount = try count(
                """
                SELECT COUNT(*)
                FROM codex_ghost_repair_category_a_prepared_bindings AS binding
                JOIN codex_ghost_repair_category_a_operations AS operation
                  ON operation.operation_id = binding.operation_id
                WHERE binding.snapshot_reference = ?
                  AND operation.status != 'terminal'
                """,
                text: snapshotReference
            )
            let allRepairCount = try count(
                """
                SELECT COUNT(*)
                FROM codex_ghost_repair_category_a_prepared_bindings
                WHERE snapshot_reference = ?
                """,
                text: snapshotReference
            )
            return .init(
                activePreviewCount: activePreviewCount,
                nonterminalRepairCount: nonterminalRepairCount,
                historicalReferenceCount: allPreviewCount + allRepairCount
            )
        }

        private func scalar(_ sql: String) throws -> Int64 {
            guard let database else { throw CodexGhostRepairError.recoveryRequired }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                    == SQLITE_OK,
                  let statement else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot dependency contract query failed."
                )
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_stmt_readonly(statement) == 1,
                  sqlite3_step(statement) == SQLITE_ROW else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot dependency contract readback failed."
                )
            }
            return sqlite3_column_int64(statement, 0)
        }

        private func count(
            _ sql: String,
            text: String,
            integer: Int64? = nil
        ) throws -> Int {
            guard let database else { throw CodexGhostRepairError.recoveryRequired }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                    == SQLITE_OK,
                  let statement else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot dependency fixed query could not be prepared."
                )
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_stmt_readonly(statement) == 1 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot dependency query was not read-only."
                )
            }
            let bindText = text.withCString { pointer in
                sqlite3_bind_text(
                    statement,
                    1,
                    pointer,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            guard bindText == SQLITE_OK else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot dependency identity could not be bound."
                )
            }
            if let integer,
               sqlite3_bind_int64(statement, 2, integer) != SQLITE_OK {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot dependency time could not be bound."
                )
            }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot dependency fixed query failed."
                )
            }
            let value = sqlite3_column_int64(statement, 0)
            guard value >= 0, value <= Int64(Int.max),
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot dependency count is invalid."
                )
            }
            return Int(value)
        }
    }
}

struct CodexGhostRepairSnapshotCleanupFrozenItem:
    Codable,
    Equatable,
    Sendable
{
    let snapshotReference: String
    let publishedAtMilliseconds: Int64
    let manifestHash: String
    let publicationReceiptHash: String
    let regularFileCount: Int
    let actualBytes: UInt64
    let dependency: CodexGhostRepairSnapshotCleanupDependencyEvidence
}

struct CodexGhostRepairSnapshotCleanupPreviewRecord:
    Codable,
    Equatable,
    Sendable
{
    let operationID: UUID
    let item: CodexGhostRepairSnapshotCleanupFrozenItem
    let inventoryDigest: String
    let activeSnapshotCountBefore: Int
    let createdAtMilliseconds: Int64
    let previewDigest: String

    init(
        operationID: UUID,
        item: CodexGhostRepairSnapshotCleanupFrozenItem,
        inventoryDigest: String,
        activeSnapshotCountBefore: Int,
        createdAtMilliseconds: Int64
    ) throws {
        self.operationID = operationID
        self.item = item
        self.inventoryDigest = inventoryDigest
        self.activeSnapshotCountBefore = activeSnapshotCountBefore
        self.createdAtMilliseconds = createdAtMilliseconds
        previewDigest = try CodexGhostRepairHasher.hash(Payload(
            operationID: operationID,
            item: item,
            inventoryDigest: inventoryDigest,
            activeSnapshotCountBefore: activeSnapshotCountBefore,
            createdAtMilliseconds: createdAtMilliseconds
        ))
    }

    func validate() throws {
        let expected = try CodexGhostRepairHasher.hash(Payload(
            operationID: operationID,
            item: item,
            inventoryDigest: inventoryDigest,
            activeSnapshotCountBefore: activeSnapshotCountBefore,
            createdAtMilliseconds: createdAtMilliseconds
        ))
        guard expected == previewDigest else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot cleanup Preview checksum mismatch."
            )
        }
    }

    private struct Payload: Codable {
        let operationID: UUID
        let item: CodexGhostRepairSnapshotCleanupFrozenItem
        let inventoryDigest: String
        let activeSnapshotCountBefore: Int
        let createdAtMilliseconds: Int64
    }
}

struct CodexGhostRepairSnapshotCleanupClaimRecord:
    Codable,
    Equatable,
    Sendable
{
    let operationID: UUID
    let snapshotReference: String
    let previewDigest: String
    let claimedAtMilliseconds: Int64
    let claimDigest: String

    init(preview: CodexGhostRepairSnapshotCleanupPreviewRecord, now: Int64)
        throws
    {
        operationID = preview.operationID
        snapshotReference = preview.item.snapshotReference
        previewDigest = preview.previewDigest
        claimedAtMilliseconds = now
        claimDigest = try CodexGhostRepairHasher.hash(Payload(
            operationID: operationID,
            snapshotReference: snapshotReference,
            previewDigest: previewDigest,
            claimedAtMilliseconds: now
        ))
    }

    func validate() throws {
        guard claimDigest == (try CodexGhostRepairHasher.hash(Payload(
            operationID: operationID,
            snapshotReference: snapshotReference,
            previewDigest: previewDigest,
            claimedAtMilliseconds: claimedAtMilliseconds
        ))) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot cleanup claim checksum mismatch."
            )
        }
    }

    private struct Payload: Codable {
        let operationID: UUID
        let snapshotReference: String
        let previewDigest: String
        let claimedAtMilliseconds: Int64
    }
}

struct CodexGhostRepairSnapshotCleanupReportRecord:
    Codable,
    Equatable,
    Sendable
{
    let operationID: UUID
    let snapshotReference: String
    let previewDigest: String
    let claimDigest: String
    let activeSnapshotCountBefore: Int
    let activeSnapshotCountAfter: Int
    let completedAtMilliseconds: Int64
    let reportDigest: String

    init(
        preview: CodexGhostRepairSnapshotCleanupPreviewRecord,
        claim: CodexGhostRepairSnapshotCleanupClaimRecord,
        activeSnapshotCountAfter: Int,
        now: Int64
    ) throws {
        operationID = preview.operationID
        snapshotReference = preview.item.snapshotReference
        previewDigest = preview.previewDigest
        claimDigest = claim.claimDigest
        activeSnapshotCountBefore = preview.activeSnapshotCountBefore
        self.activeSnapshotCountAfter = activeSnapshotCountAfter
        completedAtMilliseconds = now
        reportDigest = try CodexGhostRepairHasher.hash(Payload(
            operationID: operationID,
            snapshotReference: snapshotReference,
            previewDigest: previewDigest,
            claimDigest: claimDigest,
            activeSnapshotCountBefore: activeSnapshotCountBefore,
            activeSnapshotCountAfter: activeSnapshotCountAfter,
            completedAtMilliseconds: now
        ))
    }

    func validate() throws {
        guard reportDigest == (try CodexGhostRepairHasher.hash(Payload(
            operationID: operationID,
            snapshotReference: snapshotReference,
            previewDigest: previewDigest,
            claimDigest: claimDigest,
            activeSnapshotCountBefore: activeSnapshotCountBefore,
            activeSnapshotCountAfter: activeSnapshotCountAfter,
            completedAtMilliseconds: completedAtMilliseconds
        ))) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot cleanup Report checksum mismatch."
            )
        }
    }

    private struct Payload: Codable {
        let operationID: UUID
        let snapshotReference: String
        let previewDigest: String
        let claimDigest: String
        let activeSnapshotCountBefore: Int
        let activeSnapshotCountAfter: Int
        let completedAtMilliseconds: Int64
    }
}

struct CodexGhostRepairSnapshotCleanupLedger: Sendable {
    private static let previewPrefix = "cleanup-preview-"
    private static let claimPrefix = "cleanup-claim-"
    private static let reportPrefix = "cleanup-report-"
    private static let suffix = ".json"
    private static let maximumRecordBytes = 65_536

    let trashRootURL: URL

    func save(_ preview: CodexGhostRepairSnapshotCleanupPreviewRecord) throws {
        try preview.validate()
        try write(preview, to: previewURL(preview.operationID))
    }

    func save(_ claim: CodexGhostRepairSnapshotCleanupClaimRecord) throws {
        try claim.validate()
        try write(claim, to: claimURL(claim.operationID))
    }

    func save(_ report: CodexGhostRepairSnapshotCleanupReportRecord) throws {
        try report.validate()
        try write(report, to: reportURL(report.operationID))
    }

    func preview(_ operationID: UUID)
        throws -> CodexGhostRepairSnapshotCleanupPreviewRecord
    {
        let record: CodexGhostRepairSnapshotCleanupPreviewRecord = try read(
            previewURL(operationID)
        )
        try record.validate()
        guard record.operationID == operationID else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot cleanup Preview identity mismatch."
            )
        }
        return record
    }

    func claim(_ operationID: UUID)
        throws -> CodexGhostRepairSnapshotCleanupClaimRecord?
    {
        guard FileManager.default.fileExists(atPath: claimURL(operationID).path)
        else { return nil }
        let record: CodexGhostRepairSnapshotCleanupClaimRecord = try read(
            claimURL(operationID)
        )
        try record.validate()
        return record
    }

    func report(_ operationID: UUID)
        throws -> CodexGhostRepairSnapshotCleanupReportRecord?
    {
        guard FileManager.default.fileExists(atPath: reportURL(operationID).path)
        else { return nil }
        let record: CodexGhostRepairSnapshotCleanupReportRecord = try read(
            reportURL(operationID)
        )
        try record.validate()
        return record
    }

    func movedSnapshotRoot(_ snapshotID: UUID) -> URL {
        trashRootURL.appendingPathComponent(
            CodexGhostRepairSnapshotPublishedInventoryCollector
                .snapshotDirectoryName(snapshotID),
            isDirectory: true
        )
    }

    static func retiredSnapshotIDs(
        location: CodexGhostRepairSnapshotPreparedDestination.Location
    ) throws -> Set<UUID> {
        let ledger = Self(trashRootURL: location.trashRootURL)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: location.trashRootURL.path
        ).sorted()
        guard names.count <= 256 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot cleanup journal exceeds its fixed read bound."
            )
        }
        var movedIDs: Set<UUID> = []
        var previewIDs: Set<UUID> = []
        var claimIDs: Set<UUID> = []
        var reportIDs: Set<UUID> = []
        for name in names {
            if name.hasPrefix(
                CodexGhostRepairSnapshotPublishedFormat.snapshotDirectoryPrefix
            ) {
                guard movedIDs.insert(
                    try CodexGhostRepairSnapshotPublishedInventoryCollector
                        .snapshotID(name)
                ).inserted else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Duplicate snapshot cleanup directory identity."
                    )
                }
            } else if let operationID = exactID(
                name,
                prefix: previewPrefix,
                suffix: suffix
            ) {
                previewIDs.insert(operationID)
            } else if let operationID = exactID(
                name,
                prefix: claimPrefix,
                suffix: suffix
            ) {
                claimIDs.insert(operationID)
            } else if let operationID = exactID(
                name,
                prefix: reportPrefix,
                suffix: suffix
            ) {
                reportIDs.insert(operationID)
            } else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot cleanup Trash contains an unsupported entry."
                )
            }
        }
        guard claimIDs.isSubset(of: previewIDs),
              reportIDs.isSubset(of: claimIDs) else {
            throw CodexGhostRepairError.recoveryRequired
        }
        var claimedIDs: Set<UUID> = []
        for operationID in claimIDs {
            let preview = try ledger.preview(operationID)
            guard let claim = try ledger.claim(operationID),
                  claim.operationID == operationID,
                  claim.previewDigest == preview.previewDigest,
                  claim.snapshotReference == preview.item.snapshotReference,
                  let snapshotID = UUID(uuidString: claim.snapshotReference),
                  ledger.movedSnapshotRoot(snapshotID).lastPathComponent
                    == CodexGhostRepairSnapshotPublishedInventoryCollector
                        .snapshotDirectoryName(snapshotID) else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot cleanup claim evidence is invalid."
                )
            }
            guard claimedIDs.insert(snapshotID).inserted else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "A snapshot has more than one cleanup claim."
                )
            }
            if let report = try ledger.report(operationID) {
                guard report.operationID == operationID,
                      report.snapshotReference == claim.snapshotReference,
                      report.previewDigest == preview.previewDigest,
                      report.claimDigest == claim.claimDigest,
                      report.activeSnapshotCountAfter
                        == report.activeSnapshotCountBefore - 1 else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Snapshot cleanup Report does not match its claim."
                    )
                }
            }
        }
        guard movedIDs == claimedIDs else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return movedIDs
    }

    private func previewURL(_ operationID: UUID) -> URL {
        recordURL(prefix: Self.previewPrefix, operationID: operationID)
    }

    private func claimURL(_ operationID: UUID) -> URL {
        recordURL(prefix: Self.claimPrefix, operationID: operationID)
    }

    private func reportURL(_ operationID: UUID) -> URL {
        recordURL(prefix: Self.reportPrefix, operationID: operationID)
    }

    private func recordURL(prefix: String, operationID: UUID) -> URL {
        trashRootURL.appendingPathComponent(
            prefix + operationID.uuidString.lowercased() + Self.suffix
        )
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumRecordBytes else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot cleanup record exceeds its fixed bound."
            )
        }
        try data.write(to: url, options: .withoutOverwriting)
        guard chmod(url.path, 0o600) == 0 else {
            throw CodexGhostRepairError.recoveryRequired
        }
        try Self.fsyncFile(url)
        try Self.fsyncDirectory(trashRootURL)
    }

    private func read<T: Decodable>(_ url: URL) throws -> T {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o600,
              status.st_size >= 0,
              status.st_size <= Self.maximumRecordBytes else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot cleanup record metadata is invalid."
            )
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private static func exactID(
        _ name: String,
        prefix: String,
        suffix: String
    ) -> UUID? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end,
              let id = UUID(uuidString: String(name[start..<end])),
              name == prefix + id.uuidString.lowercased() + suffix else {
            return nil
        }
        return id
    }

    static func fsyncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CodexGhostRepairError.recoveryRequired }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.recoveryRequired
        }
    }

    static func fsyncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CodexGhostRepairError.recoveryRequired }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.recoveryRequired
        }
    }
}

actor CodexGhostRepairSnapshotCleanupCoordinator:
    CodexGhostRepairSnapshotCleanupCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairSnapshotCleanupCapabilities.packaged

    private let destination: CodexGhostRepairSnapshotPreparedDestination
    private let inventoryCollector:
        CodexGhostRepairSnapshotPublishedInventoryCollector
    private let dependencyReader:
        any CodexGhostRepairSnapshotCleanupDependencyReading
    private let clock: @Sendable () -> Date

    static func production() -> Self {
        let destination = CodexGhostRepairSnapshotPreparedDestination.production()
        return Self(
            destination: destination,
            inventoryCollector: .production(destination: destination),
            dependencyReader:
                CodexGhostRepairSnapshotCleanupReadOnlyDependencyReader
                    .production(),
            clock: { Date() }
        )
    }

    init(
        destination: CodexGhostRepairSnapshotPreparedDestination,
        inventoryCollector: CodexGhostRepairSnapshotPublishedInventoryCollector,
        dependencyReader:
            any CodexGhostRepairSnapshotCleanupDependencyReading,
        clock: @escaping @Sendable () -> Date
    ) {
        self.destination = destination
        self.inventoryCollector = inventoryCollector
        self.dependencyReader = dependencyReader
        self.clock = clock
    }

    func inspect() async -> CodexGhostRepairSnapshotCleanupInspectionOutcome {
        do {
            return .observed(try await freshInventory().publicInventory)
        } catch {
            return .unavailable(
                message: "Published Snapshot Storage could not be read exactly. Nothing was moved."
            )
        }
    }

    func prepare(
        snapshotReference: String
    ) async -> CodexGhostRepairSnapshotCleanupPrepareOutcome {
        guard let snapshotID = UUID(uuidString: snapshotReference),
              snapshotReference == snapshotID.uuidString.lowercased() else {
            return .blocked(message: "Choose one exact snapshot from this screen.")
        }
        do {
            let fresh = try await freshInventory()
            guard let item = fresh.items.first(where: {
                $0.snapshot.snapshotID == snapshotID
            }) else {
                return .blocked(
                    message: "That snapshot is no longer in active Snapshot Storage."
                )
            }
            guard item.dependency.eligibility == .eligible else {
                return .blocked(
                    message: Self.protectionMessage(item.dependency.eligibility)
                )
            }
            let operationID = UUID()
            let preview = try CodexGhostRepairSnapshotCleanupPreviewRecord(
                operationID: operationID,
                item: item.frozen,
                inventoryDigest: fresh.digest,
                activeSnapshotCountBefore: fresh.items.count,
                createdAtMilliseconds: Self.milliseconds(clock())
            )
            let binding = try await destination.bindPrepared()
            let location = try await destination.location(for: binding)
            let ledger = CodexGhostRepairSnapshotCleanupLedger(
                trashRootURL: location.trashRootURL
            )
            try ledger.save(preview)
            let readback = try ledger.preview(operationID)
            guard readback == preview else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return .ready(Self.publicReview(preview, item: item.publicItem))
        } catch {
            return .unavailable(
                message: "The exact cleanup review could not be frozen. Nothing was moved."
            )
        }
    }

    func execute(
        operationID: UUID
    ) async -> CodexGhostRepairSnapshotCleanupExecutionOutcome {
        do {
            let binding = try await destination.bindPrepared()
            let location = try await destination.location(for: binding)
            let ledger = CodexGhostRepairSnapshotCleanupLedger(
                trashRootURL: location.trashRootURL
            )
            let preview = try ledger.preview(operationID)
            if try ledger.report(operationID) != nil {
                return .recoveryRequired(
                    operationID: operationID,
                    message: "This one-shot cleanup already has a terminal Report and cannot run again."
                )
            }
            if try ledger.claim(operationID) != nil {
                return .recoveryRequired(
                    operationID: operationID,
                    message: "This one-shot cleanup was already claimed. Do not retry."
                )
            }

            let before = try await freshInventory()
            guard before.digest == preview.inventoryDigest,
                  before.items.count == preview.activeSnapshotCountBefore,
                  let exact = before.items.first(where: {
                    $0.frozen == preview.item
                  }),
                  exact.dependency.eligibility == .eligible,
                  let snapshotID = UUID(
                    uuidString: preview.item.snapshotReference
                  ) else {
                return .rejected(
                    message: "Snapshot Storage or its dependencies changed after review. Nothing was moved."
                )
            }

            let claim = try CodexGhostRepairSnapshotCleanupClaimRecord(
                preview: preview,
                now: Self.milliseconds(clock())
            )
            try ledger.save(claim)
            guard try ledger.claim(operationID) == claim else {
                throw CodexGhostRepairError.recoveryRequired
            }

            try await destination.validateFresh(binding)
            let claimedDependency = try await dependencyReader.evidence(
                snapshotReference: preview.item.snapshotReference,
                nowMilliseconds: Self.milliseconds(clock())
            )
            let acquisition = try await CodexGhostRepairSnapshotAcquisitionJournal
                .production(destination: destination)
                .readback(snapshotID: snapshotID, destinationBinding: binding)
            let claimedEvidence = try CodexGhostRepairSnapshotPublishedInventoryCollector
                .inspectPublishedSnapshot(
                    snapshotID: snapshotID,
                    acquisition: acquisition,
                    binding: binding,
                    location: location
                )
            guard claimedDependency == preview.item.dependency,
                  claimedDependency.eligibility == .eligible,
                  claimedEvidence.snapshotID == snapshotID,
                  claimedEvidence.publishedAtMilliseconds
                    == preview.item.publishedAtMilliseconds,
                  claimedEvidence.manifestHash == preview.item.manifestHash,
                  claimedEvidence.publicationReceiptHash
                    == preview.item.publicationReceiptHash,
                  claimedEvidence.regularFileCount
                    == preview.item.regularFileCount,
                  claimedEvidence.actualBytes == preview.item.actualBytes else {
                return .recoveryRequired(
                    operationID: operationID,
                    message: "Storage changed after the one-shot claim. No retry is allowed."
                )
            }

            let source = location.snapshotsRootURL.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(snapshotID),
                isDirectory: true
            )
            let destinationURL = ledger.movedSnapshotRoot(snapshotID)
            guard !FileManager.default.fileExists(atPath: destinationURL.path),
                  rename(source.path, destinationURL.path) == 0 else {
                return .recoveryRequired(
                    operationID: operationID,
                    message: "The claimed snapshot move did not complete exactly. Do not retry."
                )
            }
            try CodexGhostRepairSnapshotCleanupLedger.fsyncDirectory(
                location.snapshotsRootURL
            )
            try CodexGhostRepairSnapshotCleanupLedger.fsyncDirectory(
                location.trashRootURL
            )

            let movedLocation = CodexGhostRepairSnapshotPreparedDestination.Location(
                applicationSupportURL: location.applicationSupportURL,
                bundleRootURL: location.bundleRootURL,
                storageRootURL: location.storageRootURL,
                snapshotsRootURL: location.trashRootURL,
                quarantineRootURL: location.quarantineRootURL,
                journalRootURL: location.journalRootURL,
                trashRootURL: location.trashRootURL
            )
            let movedEvidence = try CodexGhostRepairSnapshotPublishedInventoryCollector
                .inspectPublishedSnapshot(
                    snapshotID: snapshotID,
                    acquisition: acquisition,
                    binding: binding,
                    location: movedLocation
                )
            guard movedEvidence.manifestHash == preview.item.manifestHash,
                  movedEvidence.publicationReceiptHash
                    == preview.item.publicationReceiptHash else {
                throw CodexGhostRepairError.recoveryRequired
            }

            let reportRecord = try CodexGhostRepairSnapshotCleanupReportRecord(
                preview: preview,
                claim: claim,
                activeSnapshotCountAfter: preview.activeSnapshotCountBefore - 1,
                now: Self.milliseconds(clock())
            )
            try ledger.save(reportRecord)
            guard try ledger.report(operationID) == reportRecord else {
                throw CodexGhostRepairError.recoveryRequired
            }
            let after = try await freshInventory()
            guard after.items.count == reportRecord.activeSnapshotCountAfter,
                  !after.items.contains(where: {
                    $0.snapshot.snapshotID == snapshotID
                  }) else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return .completed(.init(
                operationID: operationID,
                snapshotReference: reportRecord.snapshotReference,
                movedToManagerTrash: true,
                activeSnapshotCountBefore:
                    reportRecord.activeSnapshotCountBefore,
                activeSnapshotCountAfter: reportRecord.activeSnapshotCountAfter,
                completedAtMilliseconds: reportRecord.completedAtMilliseconds,
                reportDigest: reportRecord.reportDigest
            ))
        } catch {
            return .recoveryRequired(
                operationID: operationID,
                message: "The one-shot cleanup outcome needs exact readback. Do not retry or move files manually."
            )
        }
    }

    private struct Item {
        let snapshot: CodexGhostRepairSnapshotPublishedEvidence
        let dependency: CodexGhostRepairSnapshotCleanupDependencyEvidence

        var frozen: CodexGhostRepairSnapshotCleanupFrozenItem {
            .init(
                snapshotReference: snapshot.snapshotID.uuidString.lowercased(),
                publishedAtMilliseconds: snapshot.publishedAtMilliseconds,
                manifestHash: snapshot.manifestHash,
                publicationReceiptHash: snapshot.publicationReceiptHash,
                regularFileCount: snapshot.regularFileCount,
                actualBytes: snapshot.actualBytes,
                dependency: dependency
            )
        }

        var publicItem: CodexGhostRepairSnapshotCleanupItem {
            .init(
                reference: snapshot.snapshotID.uuidString.lowercased(),
                publishedAtMilliseconds: snapshot.publishedAtMilliseconds,
                actualBytes: snapshot.actualBytes,
                activePreviewCount: dependency.activePreviewCount,
                nonterminalRepairCount: dependency.nonterminalRepairCount,
                historicalReferenceCount: dependency.historicalReferenceCount,
                eligibility: dependency.eligibility
            )
        }
    }

    private struct FreshInventory {
        let raw: CodexGhostRepairSnapshotPublishedInventory
        let items: [Item]
        let maximumSnapshotCount: Int
        let digest: String

        var publicInventory: CodexGhostRepairSnapshotCleanupInventory {
            .init(
                snapshots: items.map(\.publicItem),
                activeSnapshotCount: items.count,
                maximumSnapshotCount: maximumSnapshotCount,
                totalActiveBytes: raw.totalBytes
            )
        }
    }

    private func freshInventory() async throws -> FreshInventory {
        let binding = try await destination.bindPrepared()
        let inventory = try await inventoryCollector.inventory(binding: binding)
        let now = Self.milliseconds(clock())
        var items: [Item] = []
        for snapshot in inventory.snapshots {
            let dependency = try await dependencyReader.evidence(
                snapshotReference: snapshot.snapshotID.uuidString.lowercased(),
                nowMilliseconds: now
            )
            items.append(.init(snapshot: snapshot, dependency: dependency))
        }
        items.sort {
            if $0.snapshot.publishedAtMilliseconds
                != $1.snapshot.publishedAtMilliseconds {
                return $0.snapshot.publishedAtMilliseconds
                    < $1.snapshot.publishedAtMilliseconds
            }
            return $0.snapshot.snapshotID.uuidString
                < $1.snapshot.snapshotID.uuidString
        }
        let payload = items.map(\.frozen)
        return .init(
            raw: inventory,
            items: items,
            maximumSnapshotCount: binding.policy.maximumSnapshotCount,
            digest: try CodexGhostRepairHasher.hash(payload)
        )
    }

    private static func publicReview(
        _ preview: CodexGhostRepairSnapshotCleanupPreviewRecord,
        item: CodexGhostRepairSnapshotCleanupItem
    ) -> CodexGhostRepairSnapshotCleanupReview {
        .init(
            operationID: preview.operationID,
            snapshot: item,
            activeSnapshotCountBefore: preview.activeSnapshotCountBefore,
            activeSnapshotCountAfter: preview.activeSnapshotCountBefore - 1,
            previewDigest: preview.previewDigest
        )
    }

    private static func protectionMessage(
        _ eligibility: CodexGhostRepairSnapshotCleanupEligibility
    ) -> String {
        switch eligibility {
        case .eligible:
            return ""
        case let .protectedByActivePreview(count):
            return "This snapshot is still used by \(count) unexpired Preview record(s)."
        case let .protectedByRepair(count):
            return "This snapshot is still used by \(count) unfinished Repair operation(s)."
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
