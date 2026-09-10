import CSQLite3
import Foundation

public struct CodexGhostRepairBulkRecoveryOperationIdentity:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let requestID: UUID
    public let operationID: UUID

    public init(requestID: UUID, operationID: UUID) {
        self.requestID = requestID
        self.operationID = operationID
    }
}

public enum CodexGhostRepairBulkRecoveryJournalPhase:
    String,
    Equatable,
    Sendable
{
    case prepared
    case claimed
    case attempted
    case terminal
    case closedBeforeAttempt
}

public struct CodexGhostRepairBulkRecoveryOperationSummary:
    Equatable,
    Sendable
{
    public let identity: CodexGhostRepairBulkRecoveryOperationIdentity
    public let confirmationReceiptID: UUID
    public let selectedCount: Int
    public let phase: CodexGhostRepairBulkRecoveryJournalPhase
    public let mutationAttemptCount: Int
    public let recordedAtMilliseconds: Int64
    public let hasTerminalReport: Bool

    public init(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        confirmationReceiptID: UUID,
        selectedCount: Int,
        phase: CodexGhostRepairBulkRecoveryJournalPhase,
        mutationAttemptCount: Int,
        recordedAtMilliseconds: Int64,
        hasTerminalReport: Bool
    ) {
        self.identity = identity
        self.confirmationReceiptID = confirmationReceiptID
        self.selectedCount = selectedCount
        self.phase = phase
        self.mutationAttemptCount = mutationAttemptCount
        self.recordedAtMilliseconds = recordedAtMilliseconds
        self.hasTerminalReport = hasTerminalReport
    }
}

public struct CodexGhostRepairBulkRecoveryCapabilities:
    Equatable,
    Sendable
{
    public let explicitReadbackAvailable: Bool

    public var readsManagerOwnedState: Bool { explicitReadbackAvailable }
    public var readsCodexData: Bool { false }
    public var writesManagerOwnedRecords: Bool { false }
    public var mayUpdateSQLiteCoordination: Bool {
        explicitReadbackAvailable
    }
    public var createsChallenge: Bool { false }
    public var createsReceipt: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var claimAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var retryAuthority: Bool { false }
    public var restoreAuthority: Bool { false }

    public static let unavailable = Self(explicitReadbackAvailable: false)
    public static let packagedReadOnly = Self(explicitReadbackAvailable: true)
}

public enum CodexGhostRepairBulkPreviousOperationsOutcome:
    Equatable,
    Sendable
{
    case observed([CodexGhostRepairBulkRecoveryOperationSummary])
    case empty
    case limitExceeded(limit: Int, foundAtLeast: Int, message: String)
    case unavailable(message: String)
}

public enum CodexGhostRepairBulkRecoveryReadbackOutcome:
    Equatable,
    Sendable
{
    case terminal(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        report: CodexGhostRepairBulkRepairReport
    )
    case closedBeforeAttempt(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        closure: CodexGhostRepairBulkPreparedClosureRecord
    )
    case recoveryRequired(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        message: String
    )
    case notFound(identity: CodexGhostRepairBulkRecoveryOperationIdentity)
    case unavailable(message: String)
}

public protocol CodexGhostRepairBulkRecoveryCoordinating: Sendable {
    var capabilities: CodexGhostRepairBulkRecoveryCapabilities { get }

    func readPreviousOperations()
        async -> CodexGhostRepairBulkPreviousOperationsOutcome

    func readOperation(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkRecoveryReadbackOutcome
}

public enum CodexGhostRepairBulkFreshRecoveryReportSource:
    Equatable,
    Sendable
{
    case existingJournal
    case freshlyFinalized
}

public struct CodexGhostRepairBulkFreshRecoveryCapabilities:
    Equatable,
    Sendable
{
    public let explicitRecoveryAvailable: Bool

    public var readsManagerOwnedState: Bool { explicitRecoveryAvailable }
    public var readsCodexData: Bool { explicitRecoveryAvailable }
    public var finalizesOriginalJournal: Bool { explicitRecoveryAvailable }
    public var createsPreview: Bool { false }
    public var createsChallenge: Bool { false }
    public var createsReceipt: Bool { false }
    public var createsClaim: Bool { false }
    public var recordsMutationAttempt: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var retryAuthority: Bool { false }
    public var restoreAuthority: Bool { false }
    public var createsToken: Bool { false }

    public static let unavailable = Self(explicitRecoveryAvailable: false)
    public static let packagedExplicit = Self(explicitRecoveryAvailable: true)
}

public enum CodexGhostRepairBulkFreshRecoveryOutcome:
    Equatable,
    Sendable
{
    case terminal(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        report: CodexGhostRepairBulkRepairReport,
        source: CodexGhostRepairBulkFreshRecoveryReportSource
    )
    case closedBeforeAttempt(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        closure: CodexGhostRepairBulkPreparedClosureRecord
    )
    case recoveryRequired(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        message: String
    )
    case notFound(identity: CodexGhostRepairBulkRecoveryOperationIdentity)
    case unavailable(message: String)
}

public protocol CodexGhostRepairBulkFreshRecoveryCoordinating: Sendable {
    var capabilities: CodexGhostRepairBulkFreshRecoveryCapabilities { get }

    func recoverOperation(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkFreshRecoveryOutcome
}

public enum CodexGhostRepairBulkFreshRecoveryCoordinatorFactory {
    /// Construction is zero-I/O. Recovery is explicit and exact-identity only.
    /// It may read the frozen Codex source and finalize only the same v20
    /// journal; it cannot prepare, claim, attempt, execute, retry, or restore.
    public static func packagedExplicit()
        -> any CodexGhostRepairBulkFreshRecoveryCoordinating
    {
        CodexGhostRepairBulkFreshRecoveryLiveCoordinator.production()
    }
}

protocol CodexGhostRepairBulkFreshRecoveryReading: Sendable {
    func inspectFreshRecoveryByReadback(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt?
    ) async throws -> CodexGhostRepairBulkFreshRecoveryObservation
}

extension CodexGhostRepairBulkLiveMixedMutator:
    CodexGhostRepairBulkFreshRecoveryReading {}

public actor CodexGhostRepairBulkRecoveryUnavailableCoordinator:
    CodexGhostRepairBulkRecoveryCoordinating
{
    public nonisolated let capabilities =
        CodexGhostRepairBulkRecoveryCapabilities.unavailable

    public init() {}

    public func readPreviousOperations()
        async -> CodexGhostRepairBulkPreviousOperationsOutcome
    {
        .unavailable(message: "Bulk operation readback is unavailable.")
    }

    public func readOperation(
        identity _: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkRecoveryReadbackOutcome {
        .unavailable(message: "Bulk operation readback is unavailable.")
    }
}

public enum CodexGhostRepairBulkRecoveryCoordinatorFactory {
    /// Construction is zero-I/O. The existing manager-owned v20 journal is
    /// opened read-only only after an explicit list or exact-record request.
    /// No caller path, confirmation, claim, retry, mutation, or journal
    /// finalization capability is exposed by this facade.
    public static func packagedReadOnly()
        -> any CodexGhostRepairBulkRecoveryCoordinating
    {
        CodexGhostRepairBulkRecoveryLiveCoordinator()
    }
}

actor CodexGhostRepairBulkRecoveryLiveCoordinator:
    CodexGhostRepairBulkRecoveryCoordinating
{
    static let maximumDiscoveredOperations = 100

    nonisolated let capabilities =
        CodexGhostRepairBulkRecoveryCapabilities.packagedReadOnly

    private let databaseURLProvider: @Sendable () throws -> URL
    private let fileExists: @Sendable (String) -> Bool

    init(
        databaseURLProvider: @escaping @Sendable () throws -> URL = {
            try StateStoreLocation.applicationSupportDatabaseURL()
        },
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) {
        self.databaseURLProvider = databaseURLProvider
        self.fileExists = fileExists
    }

    func readPreviousOperations()
        async -> CodexGhostRepairBulkPreviousOperationsOutcome
    {
        do {
            let databaseURL = try databaseURLProvider()
            guard fileExists(databaseURL.path) else { return .empty }
            let reader = try CodexGhostRepairReadOnlyManagerStateStore(
                databaseURL: databaseURL
            )
            defer { reader.close() }
            switch try reader.records(
                maximumCount: Self.maximumDiscoveredOperations
            ) {
            case let .records(records):
                if records.isEmpty { return .empty }
                return .observed(try records.map(Self.summary).sorted(
                    by: Self.summaryComesFirst
                ))
            case let .limitExceeded(foundAtLeast):
                return .limitExceeded(
                    limit: Self.maximumDiscoveredOperations,
                    foundAtLeast: foundAtLeast,
                    message:
                        "More than \(Self.maximumDiscoveredOperations) durable bulk operations exist. No operation was selected or omitted as an inferred recovery target."
                )
            }
        } catch {
            return .unavailable(
                message:
                    "Previous bulk operations could not be read as exact, checksummed manager-owned records."
            )
        }
    }

    func readOperation(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkRecoveryReadbackOutcome {
        do {
            let databaseURL = try databaseURLProvider()
            guard fileExists(databaseURL.path) else {
                return .notFound(identity: identity)
            }
            let reader = try CodexGhostRepairReadOnlyManagerStateStore(
                databaseURL: databaseURL
            )
            defer { reader.close() }
            guard let record = try reader.record(identity: identity) else {
                return .notFound(identity: identity)
            }
            if record.phase == .closedBeforeAttempt,
               try reader.hasLegacyExecutionConflict(
                   operationID: identity.operationID,
                   confirmationReceiptDigest:
                       record.confirmationReceipt.receiptDigest
               ) {
                throw PersistentStateError.invalidRecord(
                    "Closed operation conflicts with a legacy execution journal."
                )
            }
            let summary = try Self.summary(record)
            switch record.phase {
            case .prepared:
                return .recoveryRequired(
                    summary: summary,
                    message:
                        "This durable operation has no recorded mutation attempt and no terminal Report. This read-only screen cannot continue, confirm, or execute it, and it does not prove that private Codex data was unchanged."
                )
            case .claimed:
                return .recoveryRequired(
                    summary: summary,
                    message:
                        "This durable operation was claimed but has no terminal Report. Read-only journal evidence cannot prove its outcome and cannot retry or finalize it."
                )
            case .attempted:
                return .recoveryRequired(
                    summary: summary,
                    message:
                        "This durable operation recorded one mutation attempt but has no terminal Report. Its outcome remains unresolved; this facade does not inspect private Codex data, retry, or finalize it."
                )
            case .terminal:
                guard let report = record.report else {
                    throw PersistentStateError.invalidRecord(
                        "Terminal bulk journal record has no Report."
                    )
                }
                return .terminal(
                    summary: summary,
                    report: try Self.publicReport(
                        report,
                        operationID: record.confirmationReceipt.operationID
                    )
                )
            case .closedBeforeAttempt:
                guard let closure = record.closure else {
                    throw PersistentStateError.invalidRecord(
                        "Closed bulk journal record has no closure evidence."
                    )
                }
                return .closedBeforeAttempt(
                    summary: summary,
                    closure: closure
                )
            }
        } catch {
            return .unavailable(
                message:
                    "The exact bulk operation could not be read as a checksummed manager-owned record."
            )
        }
    }

    static func summary(
        _ record: CodexGhostRepairBulkLiveJournalRecord
    ) throws -> CodexGhostRepairBulkRecoveryOperationSummary {
        try record.validate()
        let recordedAt: Int64
        switch record.phase {
        case .prepared:
            recordedAt = record.plan.plannedAtMilliseconds
        case .claimed:
            recordedAt = try required(record.claim).claimedAtMilliseconds
        case .attempted:
            recordedAt = try required(record.attempt).attemptedAtMilliseconds
        case .terminal:
            recordedAt = try required(record.report).completedAtMilliseconds
        case .closedBeforeAttempt:
            recordedAt = try required(record.closure).closedAtMilliseconds
        }
        let publicPhase: CodexGhostRepairBulkRecoveryJournalPhase =
            switch record.phase {
            case .prepared: .prepared
            case .claimed: .claimed
            case .attempted: .attempted
            case .terminal: .terminal
            case .closedBeforeAttempt: .closedBeforeAttempt
            }
        return .init(
            identity: .init(
                requestID: record.plan.requestID,
                operationID: record.confirmationReceipt.operationID
            ),
            confirmationReceiptID: record.confirmationReceipt.receiptID,
            selectedCount: record.plan.selectedCount,
            phase: publicPhase,
            mutationAttemptCount: record.mutationAttemptCount,
            recordedAtMilliseconds: recordedAt,
            hasTerminalReport: record.report != nil
        )
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else {
            throw PersistentStateError.invalidRecord(
                "Bulk journal phase lost its required evidence."
            )
        }
        return value
    }

    private static func summaryComesFirst(
        _ lhs: CodexGhostRepairBulkRecoveryOperationSummary,
        _ rhs: CodexGhostRepairBulkRecoveryOperationSummary
    ) -> Bool {
        if lhs.recordedAtMilliseconds != rhs.recordedAtMilliseconds {
            return lhs.recordedAtMilliseconds > rhs.recordedAtMilliseconds
        }
        let lhsOperation = lhs.identity.operationID.uuidString.lowercased()
        let rhsOperation = rhs.identity.operationID.uuidString.lowercased()
        if lhsOperation != rhsOperation { return lhsOperation < rhsOperation }
        return lhs.identity.requestID.uuidString.lowercased()
            < rhs.identity.requestID.uuidString.lowercased()
    }

    fileprivate static func publicReport(
        _ report: CodexGhostRepairBulkLiveTerminalReport,
        operationID: UUID
    ) throws -> CodexGhostRepairBulkRepairReport {
        try .init(
            operationID: operationID,
            outcome: publicOutcome(report.outcome),
            itemReports: report.items.map {
                .init(
                    threadID: $0.threadID,
                    category: $0.category,
                    outcome: publicOutcome($0.outcome)
                )
            },
            reportDigest: report.reportDigest
        )
    }

    private static func publicOutcome(
        _ outcome: CodexGhostRepairCategoryABatchOutcome
    ) -> CodexGhostRepairBulkRepairObservedOutcome {
        switch outcome {
        case .success: .success
        case .explicitFailure: .explicitFailure
        case .unknown: .unknown
        case .notAttempted: .notAttempted
        }
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

actor CodexGhostRepairBulkFreshRecoveryLiveCoordinator:
    CodexGhostRepairBulkFreshRecoveryCoordinating
{
    typealias ReadbackProvider = @Sendable (
        CodexGhostRepairSnapshotSourceProfile
    ) throws -> any CodexGhostRepairBulkFreshRecoveryReading

    nonisolated let capabilities =
        CodexGhostRepairBulkFreshRecoveryCapabilities.packagedExplicit

    private let databaseURLProvider: @Sendable () throws -> URL
    private let fileExists: @Sendable (String) -> Bool
    private let operationExclusion: CodexGhostRepairBulkOperationExclusion
    private let readbackProvider: ReadbackProvider
    private let nowMilliseconds: @Sendable () -> Int64
    private let makeUUID: @Sendable () -> UUID
    private let afterFinalizationForTesting: @Sendable () throws -> Void

    static func production() -> Self {
        Self(
            databaseURLProvider: {
                try StateStoreLocation.applicationSupportDatabaseURL()
            },
            operationExclusion: .production(),
            readbackProvider: { profile in
                CodexGhostRepairBulkLiveMixedMutator.production(
                    backupReader:
                        CodexGhostRepairBulkLiveBackupEnvironment.production(
                            profile: profile
                        ),
                    profile: profile
                )
            }
        )
    }

    init(
        databaseURLProvider: @escaping @Sendable () throws -> URL,
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        operationExclusion: CodexGhostRepairBulkOperationExclusion,
        readbackProvider: @escaping ReadbackProvider,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        afterFinalizationForTesting:
            @escaping @Sendable () throws -> Void = {}
    ) {
        self.databaseURLProvider = databaseURLProvider
        self.fileExists = fileExists
        self.operationExclusion = operationExclusion
        self.readbackProvider = readbackProvider
        self.nowMilliseconds = nowMilliseconds
        self.makeUUID = makeUUID
        self.afterFinalizationForTesting = afterFinalizationForTesting
    }

    func recoverOperation(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkFreshRecoveryOutcome {
        do {
            let databaseURL = try databaseURLProvider()
            guard fileExists(databaseURL.path) else {
                return .notFound(identity: identity)
            }
            let lease = try operationExclusion.acquire()
            defer { lease.release() }
            try lease.validateCurrentPath()
            guard let fileIdentity = lease.fileIdentity else {
                throw CodexGhostRepairError.recoveryRequired
            }
            let store = try SQLiteStateStore(
                existingCurrentDatabaseURL: databaseURL,
                expectedFileIdentity: fileIdentity
            )
            defer { store.close() }
            guard let record = try store
                    .codexGhostRepairBulkLiveExecutionJournal(
                        requestID: identity.requestID
                    ),
                  record.confirmationReceipt.operationID
                    == identity.operationID else {
                return .notFound(identity: identity)
            }
            guard try store.codexGhostRepairBulkConfirmationReceipt(
                receiptID: record.confirmationReceipt.receiptID
            ) == record.confirmationReceipt else {
                throw CodexGhostRepairError.recoveryRequired
            }
            if record.phase == .closedBeforeAttempt,
               try store.codexGhostRepairBulkHasLegacyExecutionConflict(
                   operationID: identity.operationID,
                   receiptDigest: record.confirmationReceipt.receiptDigest
               ) {
                throw CodexGhostRepairError.recoveryRequired
            }
            let summary = try CodexGhostRepairBulkRecoveryLiveCoordinator
                .summary(record)
            switch record.phase {
            case .terminal:
                guard let report = record.report else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                return .terminal(
                    summary: summary,
                    report: try CodexGhostRepairBulkRecoveryLiveCoordinator
                        .publicReport(
                            report,
                            operationID: identity.operationID
                        ),
                    source: .existingJournal
                )
            case .closedBeforeAttempt:
                guard let closure = record.closure else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                return .closedBeforeAttempt(
                    summary: summary,
                    closure: closure
                )
            case .prepared:
                return .recoveryRequired(
                    summary: summary,
                    message:
                        "This prepared operation has no durable claim. Fresh recovery cannot invent a claim or infer that private Codex data was unchanged."
                )
            case .claimed, .attempted:
                return await recoverUnresolved(
                    record,
                    summary: summary,
                    store: store,
                    lease: lease
                )
            }
        } catch {
            return .unavailable(
                message:
                    "Fresh recovery could not acquire and validate the exact existing v20 operation. No journal record was changed."
            )
        }
    }

    private func recoverUnresolved(
        _ record: CodexGhostRepairBulkLiveJournalRecord,
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        store: SQLiteStateStore,
        lease: CodexGhostRepairBulkOperationExclusion.Lease
    ) async -> CodexGhostRepairBulkFreshRecoveryOutcome {
        guard let claim = record.claim,
              let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
                  sourceLayoutIdentifier: record.plan.sourceLayoutIdentifier
              ) else {
            return .recoveryRequired(
                summary: summary,
                message:
                    "Fresh recovery cannot validate the frozen source profile. No journal record was changed."
            )
        }
        var finalizationBegan = false
        do {
            let observation = try await readbackProvider(profile)
                .inspectFreshRecoveryByReadback(
                    plan: record.plan,
                    claim: claim,
                    attempt: record.attempt
                )
            let outcome: CodexGhostRepairCategoryABatchOutcome
            switch record.phase {
            case .claimed:
                guard observation == .initial
                        || observation == .initialAndFinal else {
                    return .recoveryRequired(
                        summary: summary,
                        message:
                            "The zero-attempt claimed operation did not match the exact frozen initial state. It remains unresolved and was not finalized."
                    )
                }
                outcome = .notAttempted
            case .attempted:
                switch observation {
                case .final, .initialAndFinal: outcome = .success
                case .initial: outcome = .explicitFailure
                case .indeterminate: outcome = .unknown
                }
            case .prepared, .terminal, .closedBeforeAttempt:
                return .recoveryRequired(
                    summary: summary,
                    message:
                        "The operation phase changed before fresh recovery. No journal record was changed."
                )
            }
            let minimumCompletion = record.attempt?.attemptedAtMilliseconds
                ?? claim.claimedAtMilliseconds
            let completedAt = nowMilliseconds()
            guard completedAt >= minimumCompletion else {
                return .recoveryRequired(
                    summary: summary,
                    message:
                        "Fresh recovery time moved behind the durable operation. It remains unresolved and no journal record was changed."
                )
            }
            let report = try CodexGhostRepairBulkLiveTerminalReport(
                reportID: makeUUID(),
                plan: record.plan,
                receipt: record.confirmationReceipt,
                claim: claim,
                attempt: record.attempt,
                outcome: outcome,
                completedAtMilliseconds: completedAt
            )
            try lease.validateCurrentPath()
            finalizationBegan = true
            let terminal = try store
                .recordCodexGhostRepairBulkLiveTerminalReport(
                    report,
                    expectedUnresolvedRecord: record
                )
            try afterFinalizationForTesting()
            try lease.validateCurrentPath()
            guard terminal.phase == .terminal,
                  terminal.report == report else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return .terminal(
                summary: try CodexGhostRepairBulkRecoveryLiveCoordinator
                    .summary(terminal),
                report: try CodexGhostRepairBulkRecoveryLiveCoordinator
                    .publicReport(
                        report,
                        operationID:
                            record.confirmationReceipt.operationID
                    ),
                source: .freshlyFinalized
            )
        } catch {
            return .recoveryRequired(
                summary: summary,
                message: finalizationBegan
                    ? "Fresh recovery finalization or its durable readback became uncertain. Do not retry; read the original durable operation again."
                    : "Fresh profile, schema, backup, gate, or target readback could not be validated. The original operation remains unresolved and no journal record was changed."
            )
        }
    }
}

enum CodexGhostRepairBulkRecoveryRecordQuery {
    case records([CodexGhostRepairBulkLiveJournalRecord])
    case limitExceeded(foundAtLeast: Int)
}

struct CodexGhostRepairBulkLiveJournalSnapshot: Sendable {
    let record: CodexGhostRepairBulkLiveJournalRecord
    let payloadHash: String
}

enum CodexGhostRepairBulkConfirmationReceiptRecoveryEvidence {
    case challengeWithoutReceipt
    case confirmed(CodexGhostRepairBulkConfirmationReceipt)
    case executionJournalPresent(
        receipt: CodexGhostRepairBulkConfirmationReceipt,
        phase: CodexGhostRepairBulkRecoveryJournalPhase
    )
}

final class CodexGhostRepairReadOnlyManagerStateStore {
    private var database: OpaquePointer?
    private var readTransactionOpen = false

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
                "Bulk recovery state store could not be opened read-only."
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
                  try scalar("PRAGMA query_only") == 1 else {
                throw PersistentStateError.invalidRecord(
                    "Bulk recovery state database is not read-only."
                )
            }
            guard sqlite3_exec(pointer, "BEGIN", nil, nil, nil)
                    == SQLITE_OK else {
                throw PersistentStateError.invalidRecord(
                    "Bulk recovery read snapshot could not be started."
                )
            }
            readTransactionOpen = true
            guard try scalar("PRAGMA application_id")
                    == Int64(SQLiteStateStore.applicationID),
                  try scalar("PRAGMA user_version")
                    == Int64(SQLiteStateStore.currentSchemaVersion) else {
                throw PersistentStateError.invalidRecord(
                    "Bulk recovery state database contract did not match v20."
                )
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if let database {
            if readTransactionOpen {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                readTransactionOpen = false
            }
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    func records(
        maximumCount: Int
    ) throws -> CodexGhostRepairBulkRecoveryRecordQuery {
        guard maximumCount > 0 else {
            throw PersistentStateError.invalidRecord(
                "Bulk recovery discovery limit is invalid."
            )
        }
        let identities = try requestIDs(limit: maximumCount + 1)
        guard identities.count <= maximumCount else {
            return .limitExceeded(foundAtLeast: identities.count)
        }
        let records = try identities.map { requestID in
            guard let record = try snapshot(requestID: requestID)?.record else {
                throw PersistentStateError.invalidRecord(
                    "Bulk recovery discovery lost a journal record."
                )
            }
            return record
        }
        return .records(records)
    }

    func record(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) throws -> CodexGhostRepairBulkLiveJournalRecord? {
        try recordSnapshot(identity: identity)?.record
    }

    func recordSnapshot(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) throws -> CodexGhostRepairBulkLiveJournalSnapshot? {
        guard let snapshot = try snapshot(requestID: identity.requestID) else {
            return nil
        }
        let record = snapshot.record
        guard record.confirmationReceipt.operationID
                == identity.operationID else {
            return nil
        }
        try validateConfirmationLineage(for: record)
        return snapshot
    }

    private func validateConfirmationLineage(
        for record: CodexGhostRepairBulkLiveJournalRecord
    ) throws {
        guard let preview = try confirmationPreview(
            requestID: record.plan.requestID
        ),
              let challenge = try confirmationChallenge(
                  savedPreviewRequestID: record.plan.requestID
              ) else {
            throw PersistentStateError.invalidRecord(
                "Bulk journal lost its exact saved Preview or challenge."
            )
        }
        try challenge.validate(
            requestID: record.plan.requestID,
            preview: preview.preview,
            payloadHash: preview.payloadHash
        )
        guard let receipt = try confirmationReceipt(
            savedPreviewRequestID: record.plan.requestID,
            challenge: challenge
        ), receipt == record.confirmationReceipt else {
            throw PersistentStateError.invalidRecord(
                "Bulk journal and durable confirmation lineage disagree."
            )
        }
    }

    func hasLegacyExecutionConflict(
        operationID: UUID,
        confirmationReceiptDigest: String
    ) throws -> Bool {
        guard let database else { throw closed() }
        let sql =
            """
            SELECT 1
            FROM codex_ghost_repair_bulk_execution_journal
            WHERE operation_id = ? OR confirmation_receipt_digest = ?
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else { throw queryFailed() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw queryFailed()
        }
        try bind(
            operationID.uuidString.lowercased(),
            to: statement,
            at: 1
        )
        try bind(confirmationReceiptDigest, to: statement, at: 2)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return false
        case SQLITE_ROW: return true
        default: throw queryFailed()
        }
    }

    func confirmationReceiptRecoveryEvidence(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest
    ) throws -> CodexGhostRepairBulkConfirmationReceiptRecoveryEvidence? {
        guard let preview = try confirmationPreview(
            requestID: request.savedPreviewRequestID
        ) else {
            throw PersistentStateError.invalidRecord(
                "Bulk receipt recovery challenge lost its saved Preview."
            )
        }
        guard let challenge = try confirmationChallenge(
            savedPreviewRequestID: request.savedPreviewRequestID
        ) else { return nil }
        try challenge.validate(
            requestID: request.savedPreviewRequestID,
            preview: preview.preview,
            payloadHash: preview.payloadHash
        )
        guard challenge == request.challenge else {
            throw PersistentStateError.invalidRecord(
                "Bulk receipt recovery challenge identity changed."
            )
        }
        guard let receipt = try confirmationReceipt(
            savedPreviewRequestID: request.savedPreviewRequestID,
            challenge: challenge
        ) else {
            return .challengeWithoutReceipt
        }
        if let phase = try executionJournalPhase(
            request: request,
            receipt: receipt
        ) {
            return .executionJournalPresent(
                receipt: receipt,
                phase: phase
            )
        }
        return .confirmed(receipt)
    }

    private func confirmationPreview(
        requestID: UUID
    ) throws -> CodexGhostRepairBulkStoredPreview? {
        guard let database else { throw closed() }
        let sql =
            """
            SELECT preview_id, snapshot_reference, inventory_digest,
                   manifest_digest, generated_at_ms, expires_at_ms,
                   selected_count, blocked_count,
                   unselected_eligible_count, payload_json, payload_hash,
                   confirmation_authority, repair_mutation_authority
            FROM codex_ghost_repair_bulk_previews
            WHERE request_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else { throw queryFailed() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw queryFailed()
        }
        try bind(requestID.uuidString.lowercased(), to: statement, at: 1)
        let firstStep = sqlite3_step(statement)
        if firstStep == SQLITE_DONE { return nil }
        guard firstStep == SQLITE_ROW else { throw queryFailed() }
        let preview = try CodexGhostRepairBulkPreviewPersistedRow(
            previewID: canonicalUUID(requiredText(statement, 0)),
            snapshotReference: requiredText(statement, 1),
            inventoryDigest: requiredText(statement, 2),
            manifestDigest: requiredText(statement, 3),
            generatedAtMilliseconds: sqlite3_column_int64(statement, 4),
            expiresAtMilliseconds: sqlite3_column_int64(statement, 5),
            selectedCount: Int(sqlite3_column_int64(statement, 6)),
            blockedCount: Int(sqlite3_column_int64(statement, 7)),
            unselectedEligibleCount:
                Int(sqlite3_column_int64(statement, 8)),
            encodedPayload: requiredText(statement, 9),
            payloadHash: requiredText(statement, 10),
            confirmationAuthority: sqlite3_column_int64(statement, 11),
            repairMutationAuthority: sqlite3_column_int64(statement, 12)
        ).decodeValidated(requestID: requestID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistentStateError.invalidRecord(
                "Bulk receipt recovery Preview query returned duplicate rows."
            )
        }
        return preview
    }

    private func confirmationChallenge(
        savedPreviewRequestID: UUID
    ) throws -> CodexGhostRepairBulkConfirmationChallenge? {
        guard let database else { throw closed() }
        let sql =
            """
            SELECT operation_id, preview_id, manifest_digest,
                   preview_payload_hash, selected_count, ordinary_count,
                   automation_count, blocked_outside_batch_count,
                   generated_at_ms, expires_at_ms, challenge_digest,
                   confirmation_phrase, payload_json, payload_hash,
                   confirmation_authority, repair_claim_created,
                   repair_mutation_authority
            FROM codex_ghost_repair_bulk_confirmation_challenges
            WHERE saved_preview_request_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else { throw queryFailed() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw queryFailed()
        }
        try bind(
            savedPreviewRequestID.uuidString.lowercased(),
            to: statement,
            at: 1
        )
        let firstStep = sqlite3_step(statement)
        if firstStep == SQLITE_DONE { return nil }
        guard firstStep == SQLITE_ROW else { throw queryFailed() }
        let challenge = try CodexGhostRepairBulkConfirmationChallengePersistedRow(
            operationID: canonicalUUID(requiredText(statement, 0)),
            previewID: canonicalUUID(requiredText(statement, 1)),
            manifestDigest: requiredText(statement, 2),
            previewPayloadHash: requiredText(statement, 3),
            selectedCount: Int(sqlite3_column_int64(statement, 4)),
            ordinaryCount: Int(sqlite3_column_int64(statement, 5)),
            automationCount: Int(sqlite3_column_int64(statement, 6)),
            blockedOutsideBatchCount:
                Int(sqlite3_column_int64(statement, 7)),
            generatedAtMilliseconds: sqlite3_column_int64(statement, 8),
            expiresAtMilliseconds: sqlite3_column_int64(statement, 9),
            challengeDigest: requiredText(statement, 10),
            confirmationPhrase: requiredText(statement, 11),
            encodedPayload: requiredText(statement, 12),
            payloadHash: requiredText(statement, 13),
            confirmationAuthority: sqlite3_column_int64(statement, 14),
            repairClaimCreated: sqlite3_column_int64(statement, 15),
            repairMutationAuthority: sqlite3_column_int64(statement, 16)
        ).decodeValidated(savedPreviewRequestID: savedPreviewRequestID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistentStateError.invalidRecord(
                "Bulk receipt recovery challenge query returned duplicate rows."
            )
        }
        return challenge
    }

    private func confirmationReceipt(
        savedPreviewRequestID: UUID,
        challenge: CodexGhostRepairBulkConfirmationChallenge
    ) throws -> CodexGhostRepairBulkConfirmationReceipt? {
        guard let database else { throw closed() }
        let sql =
            """
            SELECT operation_id, receipt_id, challenge_digest,
                   confirmation_phrase_hash, selected_count,
                   confirmed_at_ms, receipt_digest, payload_json,
                   payload_hash, confirmation_recorded,
                   repair_claim_created, repair_mutation_authority,
                   automatic_retry_allowed
            FROM codex_ghost_repair_bulk_confirmation_receipts
            WHERE saved_preview_request_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else { throw queryFailed() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw queryFailed()
        }
        try bind(
            savedPreviewRequestID.uuidString.lowercased(),
            to: statement,
            at: 1
        )
        let firstStep = sqlite3_step(statement)
        if firstStep == SQLITE_DONE { return nil }
        guard firstStep == SQLITE_ROW else { throw queryFailed() }
        let receipt = try CodexGhostRepairBulkConfirmationReceiptPersistedRow(
            operationID: canonicalUUID(requiredText(statement, 0)),
            receiptID: canonicalUUID(requiredText(statement, 1)),
            challengeDigest: requiredText(statement, 2),
            confirmationPhraseHash: requiredText(statement, 3),
            selectedCount: Int(sqlite3_column_int64(statement, 4)),
            confirmedAtMilliseconds: sqlite3_column_int64(statement, 5),
            receiptDigest: requiredText(statement, 6),
            encodedPayload: requiredText(statement, 7),
            payloadHash: requiredText(statement, 8),
            confirmationRecorded: sqlite3_column_int64(statement, 9),
            repairClaimCreated: sqlite3_column_int64(statement, 10),
            repairMutationAuthority: sqlite3_column_int64(statement, 11),
            automaticRetryAllowed: sqlite3_column_int64(statement, 12)
        ).decodeValidated(
            savedPreviewRequestID: savedPreviewRequestID,
            challenge: challenge
        )
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistentStateError.invalidRecord(
                "Bulk receipt recovery receipt query returned duplicate rows."
            )
        }
        return receipt
    }

    private func executionJournalPhase(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest,
        receipt: CodexGhostRepairBulkConfirmationReceipt
    ) throws -> CodexGhostRepairBulkRecoveryJournalPhase? {
        let live = try liveExecutionJournalPhase(
            request: request,
            receipt: receipt
        )
        let legacy = try legacyExecutionJournalPhase(
            request: request,
            receipt: receipt
        )
        guard live == nil || legacy == nil else {
            throw PersistentStateError.invalidRecord(
                "Bulk receipt recovery found both live and legacy journals."
            )
        }
        return live ?? legacy
    }

    private func liveExecutionJournalPhase(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest,
        receipt: CodexGhostRepairBulkConfirmationReceipt
    ) throws -> CodexGhostRepairBulkRecoveryJournalPhase? {
        guard let database else { throw closed() }
        let sql =
            """
            SELECT request_id, confirmation_receipt_id,
                   confirmation_receipt_digest, selected_count, phase,
                   automatic_retry_allowed, automatic_restore_allowed,
                   silent_selection_shrink_allowed
            FROM codex_ghost_repair_bulk_live_execution_journal
            WHERE request_id = ? OR confirmation_receipt_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else { throw queryFailed() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw queryFailed()
        }
        try bind(
            request.savedPreviewRequestID.uuidString.lowercased(),
            to: statement,
            at: 1
        )
        try bind(
            receipt.receiptID.uuidString.lowercased(),
            to: statement,
            at: 2
        )
        let firstStep = sqlite3_step(statement)
        if firstStep == SQLITE_DONE { return nil }
        guard firstStep == SQLITE_ROW else { throw queryFailed() }
        let returnedRequestID = try canonicalUUID(
            requiredText(statement, 0)
        )
        let returnedReceiptID = try canonicalUUID(
            requiredText(statement, 1)
        )
        let returnedReceiptDigest = try requiredText(statement, 2)
        let rawPhase = try requiredText(statement, 4)
        guard returnedRequestID == request.savedPreviewRequestID,
              returnedReceiptID == receipt.receiptID,
              returnedReceiptDigest == receipt.receiptDigest,
              Int(sqlite3_column_int64(statement, 3))
                == request.selectedCount,
              let phase = CodexGhostRepairBulkRecoveryJournalPhase(
                  rawValue: rawPhase
              ),
              sqlite3_column_int64(statement, 5) == 0,
              sqlite3_column_int64(statement, 6) == 0,
              sqlite3_column_int64(statement, 7) == 0 else {
            throw PersistentStateError.invalidRecord(
                "Bulk receipt recovery live journal identity changed."
            )
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistentStateError.invalidRecord(
                "Bulk receipt recovery live journal query returned duplicate rows."
            )
        }
        return phase
    }

    private func legacyExecutionJournalPhase(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest,
        receipt: CodexGhostRepairBulkConfirmationReceipt
    ) throws -> CodexGhostRepairBulkRecoveryJournalPhase? {
        guard let database else { throw closed() }
        let sql =
            """
            SELECT operation_id, confirmation_receipt_digest,
                   selected_count, phase, automatic_retry_allowed,
                   automatic_restore_allowed,
                   silent_selection_shrink_allowed
            FROM codex_ghost_repair_bulk_execution_journal
            WHERE operation_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else { throw queryFailed() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw queryFailed()
        }
        try bind(
            request.operationID.uuidString.lowercased(),
            to: statement,
            at: 1
        )
        let firstStep = sqlite3_step(statement)
        if firstStep == SQLITE_DONE { return nil }
        guard firstStep == SQLITE_ROW else { throw queryFailed() }
        let returnedOperationID = try canonicalUUID(
            requiredText(statement, 0)
        )
        let returnedReceiptDigest = try requiredText(statement, 1)
        let rawPhase = try requiredText(statement, 3)
        guard returnedOperationID == request.operationID,
              returnedReceiptDigest == receipt.receiptDigest,
              Int(sqlite3_column_int64(statement, 2))
                == request.selectedCount,
              let phase = CodexGhostRepairBulkRecoveryJournalPhase(
                  rawValue: rawPhase
              ),
              sqlite3_column_int64(statement, 4) == 0,
              sqlite3_column_int64(statement, 5) == 0,
              sqlite3_column_int64(statement, 6) == 0 else {
            throw PersistentStateError.invalidRecord(
                "Bulk receipt recovery legacy journal identity changed."
            )
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistentStateError.invalidRecord(
                "Bulk receipt recovery legacy journal query returned duplicate rows."
            )
        }
        return phase
    }

    private func requestIDs(limit: Int) throws -> [UUID] {
        guard let database else { throw closed() }
        let sql =
            "SELECT request_id FROM codex_ghost_repair_bulk_live_execution_journal LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw queryFailed()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1,
              sqlite3_bind_int64(statement, 1, Int64(limit)) == SQLITE_OK else {
            throw queryFailed()
        }
        var values: [UUID] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                values.append(try canonicalUUID(requiredText(statement, 0)))
            case SQLITE_DONE:
                return values
            default:
                throw queryFailed()
            }
        }
    }

    private func snapshot(
        requestID: UUID
    ) throws -> CodexGhostRepairBulkLiveJournalSnapshot? {
        guard let database else { throw closed() }
        let sql =
            """
            SELECT j.confirmation_receipt_id,
                   j.confirmation_receipt_digest, j.plan_digest,
                   j.backup_receipt_digest, j.selected_count, j.phase,
                   j.claim_digest, j.attempt_digest,
                   j.terminal_report_digest, j.closure_digest,
                   j.payload_json, j.payload_hash,
                   j.mutation_attempt_count, j.automatic_retry_allowed,
                   j.automatic_restore_allowed,
                   j.silent_selection_shrink_allowed,
                   r.operation_id, r.saved_preview_request_id,
                   r.receipt_id, r.receipt_digest,
                   r.confirmation_recorded,
                   r.repair_claim_created, r.repair_mutation_authority,
                   r.automatic_retry_allowed
            FROM codex_ghost_repair_bulk_live_execution_journal AS j
            JOIN codex_ghost_repair_bulk_confirmation_receipts AS r
              ON r.receipt_id = j.confirmation_receipt_id
            WHERE j.request_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw queryFailed()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw queryFailed()
        }
        let requestText = requestID.uuidString.lowercased()
        guard requestText.withCString({ pointer in
            sqlite3_bind_text(
                statement,
                1,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }) == SQLITE_OK else {
            throw queryFailed()
        }
        let firstStep = sqlite3_step(statement)
        if firstStep == SQLITE_DONE { return nil }
        guard firstStep == SQLITE_ROW else { throw queryFailed() }
        let record = try decodeRecord(statement, requestID: requestID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistentStateError.invalidRecord(
                "Bulk recovery exact query returned duplicate rows."
            )
        }
        return record
    }

    private func decodeRecord(
        _ statement: OpaquePointer,
        requestID: UUID
    ) throws -> CodexGhostRepairBulkLiveJournalSnapshot {
        let receiptID = try canonicalUUID(requiredText(statement, 0))
        let receiptDigest = try requiredText(statement, 1)
        let planDigest = try requiredText(statement, 2)
        let backupDigest = try requiredText(statement, 3)
        let selectedCount = Int(sqlite3_column_int64(statement, 4))
        guard let phase = CodexGhostRepairBulkLiveJournalPhase(
            rawValue: try requiredText(statement, 5)
        ) else {
            throw PersistentStateError.invalidRecord(
                "Bulk recovery journal phase is unknown."
            )
        }
        let claimDigest = optionalText(statement, 6)
        let attemptDigest = optionalText(statement, 7)
        let terminalReportDigest = optionalText(statement, 8)
        let closureDigest = optionalText(statement, 9)
        let encodedPayload = try requiredText(statement, 10)
        let payloadHash = try requiredText(statement, 11)
        let mutationAttemptCount = Int(sqlite3_column_int64(statement, 12))
        let automaticRetry = sqlite3_column_int64(statement, 13)
        let automaticRestore = sqlite3_column_int64(statement, 14)
        let silentShrink = sqlite3_column_int64(statement, 15)

        let operationID = try canonicalUUID(requiredText(statement, 16))
        let receiptRequestID = try canonicalUUID(requiredText(statement, 17))
        let joinedReceiptID = try canonicalUUID(requiredText(statement, 18))
        let joinedReceiptDigest = try requiredText(statement, 19)
        let confirmationRecorded = sqlite3_column_int64(statement, 20)
        let receiptClaimCreated = sqlite3_column_int64(statement, 21)
        let receiptMutationAuthority = sqlite3_column_int64(statement, 22)
        let receiptAutomaticRetry = sqlite3_column_int64(statement, 23)

        let record = try CodexGhostRepairBulkLiveJournalPersistedRow(
            receiptID: receiptID,
            receiptDigest: receiptDigest,
            planDigest: planDigest,
            backupDigest: backupDigest,
            selectedCount: selectedCount,
            phase: phase,
            claimDigest: claimDigest,
            attemptDigest: attemptDigest,
            reportDigest: terminalReportDigest,
            closureDigest: closureDigest,
            encodedPayload: encodedPayload,
            payloadHash: payloadHash,
            mutationAttemptCount: mutationAttemptCount,
            automaticRetryAllowed: automaticRetry,
            automaticRestoreAllowed: automaticRestore,
            silentSelectionShrinkAllowed: silentShrink
        ).decodeValidated(requestID: requestID)
        guard operationID == record.confirmationReceipt.operationID,
              receiptRequestID == requestID,
              joinedReceiptID == receiptID,
              joinedReceiptDigest == receiptDigest,
              confirmationRecorded == 1,
              receiptClaimCreated == 0,
              receiptMutationAuthority == 0,
              receiptAutomaticRetry == 0 else {
            throw PersistentStateError.invalidRecord(
                "Bulk recovery journal, receipt columns, and payload disagree."
            )
        }
        return .init(record: record, payloadHash: payloadHash)
    }

    private func scalar(_ sql: String) throws -> Int64 {
        guard let database else { throw closed() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw queryFailed()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw queryFailed()
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func bind(
        _ value: String,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        guard value.withCString({ pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }) == SQLITE_OK else {
            throw queryFailed()
        }
    }

    private func requiredText(
        _ statement: OpaquePointer,
        _ column: Int32
    ) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let text = sqlite3_column_text(statement, column) else {
            throw PersistentStateError.invalidRecord(
                "Bulk recovery fixed query returned invalid text."
            )
        }
        return String(cString: text)
    }

    private func optionalText(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let text = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: text)
    }

    private func canonicalUUID(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw PersistentStateError.invalidRecord(
                "Bulk recovery identity is not canonical."
            )
        }
        return uuid
    }

    private func closed() -> PersistentStateError {
        .invalidRecord("Bulk recovery state connection is closed.")
    }

    private func queryFailed() -> PersistentStateError {
        .invalidRecord("Bulk recovery fixed read-only query failed.")
    }
}
