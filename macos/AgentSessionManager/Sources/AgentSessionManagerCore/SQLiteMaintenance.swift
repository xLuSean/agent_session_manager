import CSQLite3
import Foundation

public enum SQLiteBackupKind: String, CaseIterable, Codable, Equatable, Sendable {
    case migration
    case preRestore = "pre_restore"
}

public enum SQLiteBackupVerification: String, Codable, Equatable, Sendable {
    case verified
    case unreadable
    case integrityCheckFailed = "integrity_check_failed"
    case unsupportedSchemaVersion = "unsupported_schema_version"
    case schemaVersionMismatch = "schema_version_mismatch"
    case unexpectedApplicationID = "unexpected_application_id"
}

public struct SQLiteBackupDescriptor: Equatable, Sendable {
    public let url: URL
    public let kind: SQLiteBackupKind
    public let sourceSchemaVersion: Int32?
    public let createdAt: Date
    public let byteCount: Int64
    public let verification: SQLiteBackupVerification
    public let hasPrivatePermissions: Bool

    public init(
        url: URL,
        kind: SQLiteBackupKind,
        sourceSchemaVersion: Int32?,
        createdAt: Date,
        byteCount: Int64,
        verification: SQLiteBackupVerification,
        hasPrivatePermissions: Bool
    ) {
        self.url = url
        self.kind = kind
        self.sourceSchemaVersion = sourceSchemaVersion
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.verification = verification
        self.hasPrivatePermissions = hasPrivatePermissions
    }
}

public struct SQLiteBackupRetentionPolicy: Equatable, Sendable {
    public static let production = SQLiteBackupRetentionPolicy(
        minimumBackupsPerKind: 3,
        minimumAge: 30 * 24 * 60 * 60,
        maximumCandidatesPerAssessment: 100
    )

    public let minimumBackupsPerKind: Int
    public let minimumAge: TimeInterval
    public let maximumCandidatesPerAssessment: Int

    public init(
        minimumBackupsPerKind: Int,
        minimumAge: TimeInterval,
        maximumCandidatesPerAssessment: Int = 100
    ) {
        self.minimumBackupsPerKind = minimumBackupsPerKind
        self.minimumAge = minimumAge
        self.maximumCandidatesPerAssessment = maximumCandidatesPerAssessment
    }
}

public enum SQLiteBackupRetentionDisposition: String, Codable, Equatable, Sendable {
    case protected
    case trashCandidate = "trash_candidate"
}

public enum SQLiteBackupRetentionReason: Equatable, Sendable {
    case eligibleByCountAndAge
    case minimumVerifiedCount(position: Int, minimum: Int)
    case youngerThanMinimumAge(age: TimeInterval, minimum: TimeInterval)
    case futureDated
    case verificationFailed(SQLiteBackupVerification)
    case permissionsNotPrivate
}

public struct SQLiteBackupRetentionDecision: Equatable, Sendable {
    public let backup: SQLiteBackupDescriptor
    public let disposition: SQLiteBackupRetentionDisposition
    public let reason: SQLiteBackupRetentionReason
}

/// A read-only proposal. `trashCandidates` are not removed or moved by Core.
public struct SQLiteBackupRetentionAssessment: Equatable, Sendable {
    public let policy: SQLiteBackupRetentionPolicy
    public let recognizedBackups: [SQLiteBackupDescriptor]
    public let protectedBackups: [SQLiteBackupDescriptor]
    public let trashCandidates: [SQLiteBackupDescriptor]
    public let decisions: [SQLiteBackupRetentionDecision]

    public init(
        policy: SQLiteBackupRetentionPolicy,
        recognizedBackups: [SQLiteBackupDescriptor],
        protectedBackups: [SQLiteBackupDescriptor],
        trashCandidates: [SQLiteBackupDescriptor],
        decisions: [SQLiteBackupRetentionDecision]
    ) {
        self.policy = policy
        self.recognizedBackups = recognizedBackups
        self.protectedBackups = protectedBackups
        self.trashCandidates = trashCandidates
        self.decisions = decisions
    }
}

public struct SQLiteCompactionPolicy: Equatable, Sendable {
    public static let production = SQLiteCompactionPolicy(
        minimumReclaimableBytes: 16 * 1_024 * 1_024,
        minimumReclaimableRatio: 0.20
    )

    public let minimumReclaimableBytes: Int64
    public let minimumReclaimableRatio: Double

    public init(minimumReclaimableBytes: Int64, minimumReclaimableRatio: Double) {
        self.minimumReclaimableBytes = minimumReclaimableBytes
        self.minimumReclaimableRatio = minimumReclaimableRatio
    }
}

public enum SQLiteCompactionRecommendation: String, Codable, Equatable, Sendable {
    case notNeeded = "not_needed"
    case eligibleForExplicitPreview = "eligible_for_explicit_preview"
}

public enum SQLiteCompactionStrategy: String, Codable, Equatable, Sendable {
    /// A future executor must write a separate database, verify it, then use a
    /// reversible replacement flow. In-place automatic VACUUM is not allowed.
    case vacuumIntoVerifiedReplacement = "vacuum_into_verified_replacement"
}

/// Read-only statistics and a possible future strategy. This value never
/// authorizes or performs compaction.
public struct SQLitePhysicalCompactionAssessment: Equatable, Sendable {
    public let databaseURL: URL
    public let policy: SQLiteCompactionPolicy
    public let pageSizeBytes: Int64
    public let pageCount: Int64
    public let freeListPageCount: Int64
    public let logicalDatabaseBytes: Int64
    public let estimatedReclaimableBytes: Int64
    public let reclaimableRatio: Double
    public let recommendation: SQLiteCompactionRecommendation
    public let strategy: SQLiteCompactionStrategy

    public var requiresExplicitConfirmation: Bool { true }
    public var requiresClosedStoreForExecution: Bool { true }
    public var requiresPreCompactionBackup: Bool { true }
    public var requiresReplacementIntegrityCheck: Bool { true }
    public var executionAuthorized: Bool { false }
}

public struct SQLiteMaintenanceAssessment: Equatable, Sendable {
    public let backupRetention: SQLiteBackupRetentionAssessment
    public let physicalCompaction: SQLitePhysicalCompactionAssessment
}

public extension SQLiteStateStore {
    /// Inspects manager-owned backups and SQLite free pages without changing
    /// the database, checkpointing WAL, deleting files, or running VACUUM.
    func maintenanceAssessment(
        now: Date = Date(),
        backupPolicy: SQLiteBackupRetentionPolicy = .production,
        compactionPolicy: SQLiteCompactionPolicy = .production
    ) throws -> SQLiteMaintenanceAssessment {
        SQLiteMaintenanceAssessment(
            backupRetention: try Self.backupRetentionAssessment(
                for: databaseURL,
                now: now,
                policy: backupPolicy
            ),
            physicalCompaction: try physicalCompactionAssessment(policy: compactionPolicy)
        )
    }

    /// Produces a frozen candidate list only. A future UI/executor must require
    /// a separate confirmation and move exact candidates to macOS Trash.
    static func backupRetentionAssessment(
        for databaseURL: URL,
        now: Date = Date(),
        policy: SQLiteBackupRetentionPolicy = .production
    ) throws -> SQLiteBackupRetentionAssessment {
        try validate(policy)

        let directoryURL = databaseURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return SQLiteBackupRetentionAssessment(
                policy: policy,
                recognizedBackups: [],
                protectedBackups: [],
                trashCandidates: [],
                decisions: []
            )
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        var recognized: [SQLiteBackupDescriptor] = []
        for entry in entries {
            guard let identity = parseBackupIdentity(
                fileName: entry.lastPathComponent,
                databaseFileName: databaseURL.lastPathComponent
            ) else { continue }

            let values = try entry.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

            recognized.append(
                SQLiteBackupDescriptor(
                    url: entry,
                    kind: identity.kind,
                    sourceSchemaVersion: identity.sourceSchemaVersion,
                    createdAt: identity.createdAt,
                    byteCount: Int64(values.fileSize ?? 0),
                    verification: verifyBackup(
                        at: entry,
                        expectedSourceSchemaVersion: identity.sourceSchemaVersion
                    ),
                    hasPrivatePermissions: permissions == 0o600
                )
            )
        }

        recognized.sort(by: newestBackupFirst)
        var candidateURLs = Set<URL>()
        for kind in SQLiteBackupKind.allCases {
            let verified = recognized
                .filter {
                    $0.kind == kind
                        && $0.verification == .verified
                        && $0.hasPrivatePermissions
                }
                .sorted(by: newestBackupFirst)
            for backup in verified.dropFirst(policy.minimumBackupsPerKind) {
                let age = now.timeIntervalSince(backup.createdAt)
                if age >= policy.minimumAge {
                    candidateURLs.insert(backup.url)
                }
            }
        }

        guard candidateURLs.count <= policy.maximumCandidatesPerAssessment else {
            throw SQLiteStateStoreError.maintenanceAssessmentLimitExceeded(
                found: candidateURLs.count,
                limit: policy.maximumCandidatesPerAssessment
            )
        }

        let candidates = recognized
            .filter { candidateURLs.contains($0.url) }
            .sorted(by: oldestBackupFirst)
        let protected = recognized.filter { !candidateURLs.contains($0.url) }
        let decisions = recognized.map { backup in
            retentionDecision(
                for: backup,
                among: recognized,
                candidateURLs: candidateURLs,
                now: now,
                policy: policy
            )
        }
        return SQLiteBackupRetentionAssessment(
            policy: policy,
            recognizedBackups: recognized,
            protectedBackups: protected,
            trashCandidates: candidates,
            decisions: decisions
        )
    }

    func physicalCompactionAssessment(
        policy: SQLiteCompactionPolicy = .production
    ) throws -> SQLitePhysicalCompactionAssessment {
        try Self.validate(policy)
        return try withLockedDatabase { database in
            let pageSize = try Self.maintenanceScalar("PRAGMA page_size", database: database)
            let pageCount = try Self.maintenanceScalar("PRAGMA page_count", database: database)
            let freeListPageCount = try Self.maintenanceScalar(
                "PRAGMA freelist_count",
                database: database
            )
            let (logicalBytes, logicalOverflow) = pageSize.multipliedReportingOverflow(by: pageCount)
            let (reclaimableBytes, reclaimableOverflow) = pageSize.multipliedReportingOverflow(
                by: freeListPageCount
            )
            guard !logicalOverflow, !reclaimableOverflow,
                  pageSize > 0, pageCount >= 0,
                  freeListPageCount >= 0, freeListPageCount <= pageCount else {
                throw SQLiteStateStoreError.invalidMaintenanceStatistics
            }

            let ratio = pageCount == 0 ? 0 : Double(freeListPageCount) / Double(pageCount)
            let recommendation: SQLiteCompactionRecommendation =
                reclaimableBytes >= policy.minimumReclaimableBytes
                && ratio >= policy.minimumReclaimableRatio
                ? .eligibleForExplicitPreview
                : .notNeeded

            return SQLitePhysicalCompactionAssessment(
                databaseURL: databaseURL,
                policy: policy,
                pageSizeBytes: pageSize,
                pageCount: pageCount,
                freeListPageCount: freeListPageCount,
                logicalDatabaseBytes: logicalBytes,
                estimatedReclaimableBytes: reclaimableBytes,
                reclaimableRatio: ratio,
                recommendation: recommendation,
                strategy: .vacuumIntoVerifiedReplacement
            )
        }
    }
}

private extension SQLiteStateStore {
    struct BackupIdentity {
        let kind: SQLiteBackupKind
        let sourceSchemaVersion: Int32?
        let createdAt: Date
    }

    static func validate(_ policy: SQLiteBackupRetentionPolicy) throws {
        guard policy.minimumBackupsPerKind >= 1,
              policy.minimumAge.isFinite,
              policy.minimumAge >= 0,
              policy.maximumCandidatesPerAssessment > 0 else {
            throw SQLiteStateStoreError.invalidMaintenancePolicy
        }
    }

    static func validate(_ policy: SQLiteCompactionPolicy) throws {
        guard policy.minimumReclaimableBytes >= 0,
              policy.minimumReclaimableRatio.isFinite,
              (0...1).contains(policy.minimumReclaimableRatio) else {
            throw SQLiteStateStoreError.invalidMaintenancePolicy
        }
    }

    static func parseBackupIdentity(
        fileName: String,
        databaseFileName: String
    ) -> BackupIdentity? {
        let databasePattern = NSRegularExpression.escapedPattern(for: databaseFileName)
        let pattern = "^\(databasePattern)\\.(backup-v([0-9]+)|pre-restore)-([0-9]+)-([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\\.sqlite3$"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(fileName.startIndex..., in: fileName)
        guard let match = expression.firstMatch(in: fileName, range: fullRange),
              match.range == fullRange else { return nil }

        let value = fileName as NSString
        let label = value.substring(with: match.range(at: 1))
        let millisecondsString = value.substring(with: match.range(at: 3))
        let uuidString = value.substring(with: match.range(at: 4))
        guard let milliseconds = Int64(millisecondsString),
              UUID(uuidString: uuidString) != nil else { return nil }

        if label == "pre-restore" {
            return BackupIdentity(
                kind: .preRestore,
                sourceSchemaVersion: nil,
                createdAt: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            )
        }

        guard match.range(at: 2).location != NSNotFound,
              let version = Int32(value.substring(with: match.range(at: 2))) else { return nil }
        return BackupIdentity(
            kind: .migration,
            sourceSchemaVersion: version,
            createdAt: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        )
    }

    static func verifyBackup(
        at url: URL,
        expectedSourceSchemaVersion: Int32?
    ) -> SQLiteBackupVerification {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            return .unreadable
        }
        defer { sqlite3_close_v2(database) }

        guard integrityCheckIsOK(database) else { return .integrityCheckFailed }
        guard let version = try? maintenanceScalar("PRAGMA user_version", database: database),
              version <= Int64(currentSchemaVersion) else {
            return .unsupportedSchemaVersion
        }
        if let expectedSourceSchemaVersion,
           version != Int64(expectedSourceSchemaVersion) {
            return .schemaVersionMismatch
        }
        if version > 0 {
            guard let foundApplicationID = try? maintenanceScalar(
                "PRAGMA application_id",
                database: database
            ), foundApplicationID == Int64(applicationID) else {
                return .unexpectedApplicationID
            }
        }
        return .verified
    }

    static func integrityCheckIsOK(_ database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text) == "ok"
    }

    static func maintenanceScalar(_ sql: String, database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            throw SQLiteStateStoreError.sqlite(
                operation: "maintenance prepare",
                code: prepareResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw SQLiteStateStoreError.sqlite(
                operation: "maintenance query",
                code: stepResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        return sqlite3_column_int64(statement, 0)
    }

    static func retentionDecision(
        for backup: SQLiteBackupDescriptor,
        among recognized: [SQLiteBackupDescriptor],
        candidateURLs: Set<URL>,
        now: Date,
        policy: SQLiteBackupRetentionPolicy
    ) -> SQLiteBackupRetentionDecision {
        if candidateURLs.contains(backup.url) {
            return SQLiteBackupRetentionDecision(
                backup: backup,
                disposition: .trashCandidate,
                reason: .eligibleByCountAndAge
            )
        }
        guard backup.verification == .verified else {
            return SQLiteBackupRetentionDecision(
                backup: backup,
                disposition: .protected,
                reason: .verificationFailed(backup.verification)
            )
        }
        guard backup.hasPrivatePermissions else {
            return SQLiteBackupRetentionDecision(
                backup: backup,
                disposition: .protected,
                reason: .permissionsNotPrivate
            )
        }

        let verifiedForKind = recognized
            .filter {
                $0.kind == backup.kind
                    && $0.verification == .verified
                    && $0.hasPrivatePermissions
            }
            .sorted(by: newestBackupFirst)
        let position = (verifiedForKind.firstIndex { $0.url == backup.url } ?? 0) + 1
        if position <= policy.minimumBackupsPerKind {
            return SQLiteBackupRetentionDecision(
                backup: backup,
                disposition: .protected,
                reason: .minimumVerifiedCount(
                    position: position,
                    minimum: policy.minimumBackupsPerKind
                )
            )
        }

        let age = now.timeIntervalSince(backup.createdAt)
        if age < 0 {
            return SQLiteBackupRetentionDecision(
                backup: backup,
                disposition: .protected,
                reason: .futureDated
            )
        }
        return SQLiteBackupRetentionDecision(
            backup: backup,
            disposition: .protected,
            reason: .youngerThanMinimumAge(age: age, minimum: policy.minimumAge)
        )
    }

    static func newestBackupFirst(_ lhs: SQLiteBackupDescriptor, _ rhs: SQLiteBackupDescriptor) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.url.lastPathComponent > rhs.url.lastPathComponent
    }

    static func oldestBackupFirst(_ lhs: SQLiteBackupDescriptor, _ rhs: SQLiteBackupDescriptor) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.url.lastPathComponent < rhs.url.lastPathComponent
    }
}
