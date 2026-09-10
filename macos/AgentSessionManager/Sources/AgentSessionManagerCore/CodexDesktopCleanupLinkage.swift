import CSQLite3
import Foundation

public struct CodexDesktopCleanupHandoffItem:
    Codable, Equatable, Hashable, Sendable
{
    public let managerKey: String
    public let nativeSessionID: String
    public let deletedAtMilliseconds: Int64

    public init(
        managerKey: String,
        nativeSessionID: String,
        deletedAtMilliseconds: Int64
    ) throws {
        guard !managerKey.isEmpty,
              !nativeSessionID.isEmpty,
              deletedAtMilliseconds >= 0 else {
            throw PersistentStateError.invalidRecord(
                "Canonical Delete handoff item is invalid."
            )
        }
        self.managerKey = managerKey
        self.nativeSessionID = nativeSessionID
        self.deletedAtMilliseconds = deletedAtMilliseconds
    }
}

private struct CodexDesktopCleanupHandoffPayload: Codable {
    let canonicalDeleteReportID: UUID
    let items: [CodexDesktopCleanupHandoffItem]
}

public struct CodexDesktopCleanupHandoff: Codable, Equatable, Sendable {
    public let canonicalDeleteReportID: UUID
    public let items: [CodexDesktopCleanupHandoffItem]
    public let handoffDigest: String

    public var nativeSessionIDs: [String] { items.map(\.nativeSessionID) }

    public init(
        canonicalDeleteReportID: UUID,
        items: [CodexDesktopCleanupHandoffItem]
    ) throws {
        let ordered = items.sorted {
            if $0.nativeSessionID != $1.nativeSessionID {
                return $0.nativeSessionID < $1.nativeSessionID
            }
            return $0.managerKey < $1.managerKey
        }
        guard (1 ... CodexGhostRepairBulkPreview.maximumSelectedItems)
                .contains(ordered.count),
              Set(ordered.map(\.nativeSessionID)).count == ordered.count,
              Set(ordered.map(\.managerKey)).count == ordered.count else {
            throw PersistentStateError.invalidRecord(
                "Canonical Delete handoff must contain unique exact items."
            )
        }
        self.canonicalDeleteReportID = canonicalDeleteReportID
        self.items = ordered
        handoffDigest = try CodexGhostRepairHasher.hash(
            CodexDesktopCleanupHandoffPayload(
                canonicalDeleteReportID: canonicalDeleteReportID,
                items: ordered
            )
        )
    }

    func validate() throws {
        let rebuilt = try Self(
            canonicalDeleteReportID: canonicalDeleteReportID,
            items: items
        )
        guard rebuilt == self else {
            throw PersistentStateError.invalidRecord(
                "Canonical Delete handoff digest or item order changed."
            )
        }
    }
}

public struct CodexDesktopCleanupBindingItem:
    Codable, Equatable, Hashable, Sendable
{
    public let managerKey: String
    public let nativeSessionID: String
    public let deletedAtMilliseconds: Int64
    public let category: CodexGhostRepairCategory

    public init(
        managerKey: String,
        nativeSessionID: String,
        deletedAtMilliseconds: Int64,
        category: CodexGhostRepairCategory
    ) throws {
        guard !managerKey.isEmpty,
              !nativeSessionID.isEmpty,
              deletedAtMilliseconds >= 0 else {
            throw PersistentStateError.invalidRecord(
                "Desktop cleanup binding item is invalid."
            )
        }
        self.managerKey = managerKey
        self.nativeSessionID = nativeSessionID
        self.deletedAtMilliseconds = deletedAtMilliseconds
        self.category = category
    }
}

private struct CodexDesktopCleanupBindingPayload: Codable {
    let canonicalDeleteReportID: UUID
    let handoffDigest: String
    let bulkIdentity: CodexGhostRepairBulkRecoveryOperationIdentity
    let confirmationReceiptID: UUID
    let confirmationReceiptDigest: String
    let planDigest: String
    let backupReceiptDigest: String
    let preparedJournalPayloadHash: String
    let items: [CodexDesktopCleanupBindingItem]
    let boundAtMilliseconds: Int64
}

public struct CodexDesktopCleanupBinding: Codable, Equatable, Sendable {
    public let canonicalDeleteReportID: UUID
    public let handoffDigest: String
    public let bulkIdentity: CodexGhostRepairBulkRecoveryOperationIdentity
    public let confirmationReceiptID: UUID
    public let confirmationReceiptDigest: String
    public let planDigest: String
    public let backupReceiptDigest: String
    public let preparedJournalPayloadHash: String
    public let items: [CodexDesktopCleanupBindingItem]
    public let boundAtMilliseconds: Int64
    public let bindingDigest: String

    public init(
        canonicalDeleteReportID: UUID,
        handoffDigest: String,
        bulkIdentity: CodexGhostRepairBulkRecoveryOperationIdentity,
        confirmationReceiptID: UUID,
        confirmationReceiptDigest: String,
        planDigest: String,
        backupReceiptDigest: String,
        preparedJournalPayloadHash: String,
        items: [CodexDesktopCleanupBindingItem],
        boundAtMilliseconds: Int64
    ) throws {
        let ordered = items.sorted { $0.nativeSessionID < $1.nativeSessionID }
        let digests = [
            handoffDigest, confirmationReceiptDigest, planDigest,
            backupReceiptDigest, preparedJournalPayloadHash,
        ]
        guard (1 ... CodexGhostRepairBulkPreview.maximumSelectedItems)
                .contains(ordered.count),
              Set(ordered.map(\.nativeSessionID)).count == ordered.count,
              Set(ordered.map(\.managerKey)).count == ordered.count,
              digests.allSatisfy(Self.isSHA256),
              boundAtMilliseconds >= (ordered.map(\.deletedAtMilliseconds).max() ?? 0)
        else {
            throw PersistentStateError.invalidRecord(
                "Desktop cleanup binding is invalid."
            )
        }
        self.canonicalDeleteReportID = canonicalDeleteReportID
        self.handoffDigest = handoffDigest
        self.bulkIdentity = bulkIdentity
        self.confirmationReceiptID = confirmationReceiptID
        self.confirmationReceiptDigest = confirmationReceiptDigest
        self.planDigest = planDigest
        self.backupReceiptDigest = backupReceiptDigest
        self.preparedJournalPayloadHash = preparedJournalPayloadHash
        self.items = ordered
        self.boundAtMilliseconds = boundAtMilliseconds
        bindingDigest = try CodexGhostRepairHasher.hash(
            CodexDesktopCleanupBindingPayload(
                canonicalDeleteReportID: canonicalDeleteReportID,
                handoffDigest: handoffDigest,
                bulkIdentity: bulkIdentity,
                confirmationReceiptID: confirmationReceiptID,
                confirmationReceiptDigest: confirmationReceiptDigest,
                planDigest: planDigest,
                backupReceiptDigest: backupReceiptDigest,
                preparedJournalPayloadHash: preparedJournalPayloadHash,
                items: ordered,
                boundAtMilliseconds: boundAtMilliseconds
            )
        )
    }

    func validate() throws {
        let rebuilt = try Self(
            canonicalDeleteReportID: canonicalDeleteReportID,
            handoffDigest: handoffDigest,
            bulkIdentity: bulkIdentity,
            confirmationReceiptID: confirmationReceiptID,
            confirmationReceiptDigest: confirmationReceiptDigest,
            planDigest: planDigest,
            backupReceiptDigest: backupReceiptDigest,
            preparedJournalPayloadHash: preparedJournalPayloadHash,
            items: items,
            boundAtMilliseconds: boundAtMilliseconds
        )
        guard rebuilt == self else {
            throw PersistentStateError.invalidRecord(
                "Desktop cleanup binding digest changed."
            )
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

public struct CodexDesktopCleanupLinkageCapabilities:
    Equatable, Sendable
{
    public let available: Bool
    public var readsManagerOwnedState: Bool { available }
    public var writesManagerOwnedBinding: Bool { available }
    public var readsCodexData: Bool { false }
    public var createsPreview: Bool { false }
    public var createsReceipt: Bool { false }
    public var createsClaim: Bool { false }
    public var recordsMutationAttempt: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var retryAuthority: Bool { false }

    public static let unavailable = Self(available: false)
    public static let packaged = Self(available: true)

    public init(available: Bool) {
        self.available = available
    }
}

public enum CodexDesktopCleanupReviewOutcome: Equatable, Sendable {
    case ready(CodexDesktopCleanupHandoff)
    case notFound(reportID: UUID)
    case rejected(message: String)
    case unavailable(message: String)
}

public enum CodexDesktopCleanupBindOutcome: Equatable, Sendable {
    case bound(CodexDesktopCleanupBinding)
    case alreadyBound(CodexDesktopCleanupBinding)
    case notFound(reportID: UUID)
    case rejected(message: String)
    case finalizationOutcomeUnknown(reportID: UUID, message: String)
}

public enum CodexDesktopCleanupStatus: Equatable, Sendable {
    case pending(CodexDesktopCleanupHandoff)
    case prepared(CodexDesktopCleanupHandoff, CodexDesktopCleanupBinding)
    case recoveryRequired(
        CodexDesktopCleanupHandoff,
        CodexDesktopCleanupBinding,
        phase: CodexGhostRepairBulkRecoveryJournalPhase,
        message: String
    )
    case closedBeforeAttempt(
        CodexDesktopCleanupHandoff,
        CodexDesktopCleanupBinding
    )
    case terminalNotVerified(
        CodexDesktopCleanupHandoff,
        CodexDesktopCleanupBinding,
        outcome: CodexGhostRepairBulkRepairObservedOutcome
    )
    case outcomeUnknown(
        CodexDesktopCleanupHandoff,
        CodexDesktopCleanupBinding
    )
    case verified(
        CodexDesktopCleanupHandoff,
        CodexDesktopCleanupBinding,
        completedAtMilliseconds: Int64
    )
}

public enum CodexDesktopCleanupStatusOutcome: Equatable, Sendable {
    case status(CodexDesktopCleanupStatus)
    case notFound(reportID: UUID)
    case unavailable(message: String)
}

public protocol CodexDesktopCleanupLinkageCoordinating: Sendable {
    var capabilities: CodexDesktopCleanupLinkageCapabilities { get }

    func reviewCanonicalDelete(
        reportID: UUID,
        expectedNativeSessionIDs: [String]
    ) async -> CodexDesktopCleanupReviewOutcome

    func bindPreparedOperation(
        handoff: CodexDesktopCleanupHandoff,
        bulkIdentity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexDesktopCleanupBindOutcome

    func readStatus(reportID: UUID) async -> CodexDesktopCleanupStatusOutcome
}

public enum CodexDesktopCleanupLinkageCoordinatorFactory {
    public static func packaged()
        -> any CodexDesktopCleanupLinkageCoordinating
    {
        CodexDesktopCleanupLinkageCoordinator()
    }
}

public actor CodexDesktopCleanupLinkageUnavailableCoordinator:
    CodexDesktopCleanupLinkageCoordinating
{
    public nonisolated let capabilities =
        CodexDesktopCleanupLinkageCapabilities.unavailable

    public init() {}

    public func reviewCanonicalDelete(
        reportID _: UUID,
        expectedNativeSessionIDs _: [String]
    ) async -> CodexDesktopCleanupReviewOutcome {
        .unavailable(message: "Desktop cleanup linkage is unavailable.")
    }

    public func bindPreparedOperation(
        handoff _: CodexDesktopCleanupHandoff,
        bulkIdentity _: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexDesktopCleanupBindOutcome {
        .rejected(message: "Desktop cleanup linkage is unavailable.")
    }

    public func readStatus(
        reportID _: UUID
    ) async -> CodexDesktopCleanupStatusOutcome {
        .unavailable(message: "Desktop cleanup linkage is unavailable.")
    }
}

extension SQLiteStateStore {
    enum CodexDesktopCleanupBindingWriteOutcome {
        case bound(CodexDesktopCleanupBinding)
        case alreadyBound(CodexDesktopCleanupBinding)
    }

    func codexDesktopCleanupHandoff(
        reportID: UUID,
        expectedNativeSessionIDs: [String]? = nil
    ) throws -> CodexDesktopCleanupHandoff? {
        try withLockedDatabase { database in
            try codexDesktopCleanupHandoff(
                reportID: reportID,
                expectedNativeSessionIDs: expectedNativeSessionIDs,
                database: database
            )
        }
    }

    func bindCodexDesktopCleanup(
        handoff: CodexDesktopCleanupHandoff,
        bulkIdentity: CodexGhostRepairBulkRecoveryOperationIdentity,
        boundAtMilliseconds: Int64
    ) throws -> CodexDesktopCleanupBindingWriteOutcome {
        try handoff.validate()
        return try withLockedDatabase { database in
            try transaction(database) {
                guard let durableHandoff = try codexDesktopCleanupHandoff(
                    reportID: handoff.canonicalDeleteReportID,
                    expectedNativeSessionIDs: handoff.nativeSessionIDs,
                    database: database
                ), durableHandoff == handoff else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                if let existing = try loadCodexDesktopCleanupBinding(
                    reportID: handoff.canonicalDeleteReportID,
                    database: database
                ) {
                    guard existing.bulkIdentity == bulkIdentity,
                          existing.handoffDigest == handoff.handoffDigest else {
                        throw CodexGhostRepairError.recoveryRequired
                    }
                    _ = try validate(
                        existing,
                        handoff: durableHandoff,
                        database: database
                    )
                    return .alreadyBound(existing)
                }
                guard let snapshot = try
                    validatedCodexGhostRepairBulkLiveJournalSnapshot(
                        identity: bulkIdentity,
                        database: database
                    ), snapshot.record.phase == .prepared,
                      snapshot.record.claim == nil,
                      snapshot.record.attempt == nil,
                      snapshot.record.report == nil,
                      snapshot.record.closure == nil else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                let plan = snapshot.record.plan
                guard plan.selectedThreadIDs == durableHandoff.nativeSessionIDs else {
                    throw PersistentStateError.previewItemSetMismatch
                }
                let selectedByID = Dictionary(
                    uniqueKeysWithValues: plan.selectedItems.map {
                        ($0.threadID, $0)
                    }
                )
                let bindingItems = try durableHandoff.items.map { item in
                    guard let selected = selectedByID[item.nativeSessionID] else {
                        throw PersistentStateError.previewItemSetMismatch
                    }
                    return try CodexDesktopCleanupBindingItem(
                        managerKey: item.managerKey,
                        nativeSessionID: item.nativeSessionID,
                        deletedAtMilliseconds: item.deletedAtMilliseconds,
                        category: selected.category
                    )
                }
                let latestDeletion = durableHandoff.items
                    .map(\.deletedAtMilliseconds).max() ?? 0
                guard plan.plannedAtMilliseconds >= latestDeletion,
                      boundAtMilliseconds >= plan.plannedAtMilliseconds,
                      boundAtMilliseconds < plan.expiresAtMilliseconds else {
                    throw PersistentStateError.invalidRecord(
                        "Desktop cleanup cannot bind an older or expired bulk plan."
                    )
                }
                let binding = try CodexDesktopCleanupBinding(
                    canonicalDeleteReportID:
                        durableHandoff.canonicalDeleteReportID,
                    handoffDigest: durableHandoff.handoffDigest,
                    bulkIdentity: bulkIdentity,
                    confirmationReceiptID:
                        snapshot.record.confirmationReceipt.receiptID,
                    confirmationReceiptDigest:
                        snapshot.record.confirmationReceipt.receiptDigest,
                    planDigest: plan.planDigest,
                    backupReceiptDigest: plan.backup.receiptDigest,
                    preparedJournalPayloadHash: snapshot.payloadHash,
                    items: bindingItems,
                    boundAtMilliseconds: boundAtMilliseconds
                )
                let encoded = try Self.encodeBulkPreviewPayload(binding)
                let payloadHash = Self.hashBulkPreviewPayload(encoded)
                try execute(
                    """
                    INSERT INTO codex_desktop_cleanup_bindings (
                        canonical_delete_report_id, handoff_digest,
                        bulk_request_id, bulk_operation_id,
                        confirmation_receipt_id,
                        confirmation_receipt_digest, plan_digest,
                        backup_receipt_digest, bound_at_milliseconds,
                        payload_json, payload_hash,
                        automatic_retry_allowed, repair_mutation_authority
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
                    """,
                    values: [
                        .text(binding.canonicalDeleteReportID
                            .uuidString.lowercased()),
                        .text(binding.handoffDigest),
                        .text(binding.bulkIdentity.requestID
                            .uuidString.lowercased()),
                        .text(binding.bulkIdentity.operationID
                            .uuidString.lowercased()),
                        .text(binding.confirmationReceiptID
                            .uuidString.lowercased()),
                        .text(binding.confirmationReceiptDigest),
                        .text(binding.planDigest),
                        .text(binding.backupReceiptDigest),
                        .int64(binding.boundAtMilliseconds),
                        .text(encoded), .text(payloadHash),
                    ],
                    database: database
                )
                guard let readback = try loadCodexDesktopCleanupBinding(
                    reportID: binding.canonicalDeleteReportID,
                    database: database
                ), readback == binding else {
                    throw PersistentStateError.invalidRecord(
                        "Desktop cleanup binding exact readback failed."
                    )
                }
                return .bound(readback)
            }
        }
    }

    func codexDesktopCleanupStatus(
        reportID: UUID
    ) throws -> CodexDesktopCleanupStatus? {
        try withLockedDatabase { database in
            try codexDesktopCleanupStatus(reportID: reportID, database: database)
        }
    }

    func codexDesktopCleanupStatus(
        reportID: UUID, database: OpaquePointer
    ) throws -> CodexDesktopCleanupStatus? {
            guard let handoff = try codexDesktopCleanupHandoff(
                reportID: reportID,
                expectedNativeSessionIDs: nil,
                database: database
            ) else { return nil }
            guard let binding = try loadCodexDesktopCleanupBinding(
                reportID: reportID,
                database: database
            ) else { return .pending(handoff) }
            let record = try validate(
                binding,
                handoff: handoff,
                database: database
            )
            switch record.phase {
            case .prepared:
                return .prepared(handoff, binding)
            case .claimed:
                return .recoveryRequired(
                    handoff, binding, phase: .claimed,
                    message:
                        "The bound cleanup operation was claimed but has no terminal Report. Recover the same operation; do not create another plan."
                )
            case .attempted:
                return .recoveryRequired(
                    handoff, binding, phase: .attempted,
                    message:
                        "The bound cleanup operation recorded a mutation attempt but has no terminal Report. Its outcome is unresolved; do not create another plan."
                )
            case .closedBeforeAttempt:
                return .closedBeforeAttempt(handoff, binding)
            case .terminal:
                guard let report = record.report else {
                    throw PersistentStateError.invalidRecord(
                        "Bound terminal cleanup operation has no Report."
                    )
                }
                let requested = Dictionary(
                    uniqueKeysWithValues: binding.items.map {
                        ($0.nativeSessionID, $0.category)
                    }
                )
                let terminal = Dictionary(
                    uniqueKeysWithValues: report.items.map {
                        ($0.threadID, ($0.category, $0.outcome))
                    }
                )
                guard requested.allSatisfy({ id, category in
                    terminal[id]?.0 == category
                }),
                      report.completedAtMilliseconds
                        >= binding.boundAtMilliseconds else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                switch report.outcome {
                case .success:
                    guard requested.keys.allSatisfy({ id in
                        guard let outcome = terminal[id]?.1 else { return false }
                        return outcome == .success || outcome == .alreadyAbsent
                    }) else {
                        throw CodexGhostRepairError.recoveryRequired
                    }
                    return .verified(
                        handoff, binding,
                        completedAtMilliseconds: report.completedAtMilliseconds
                    )
                case .unknown:
                    return .outcomeUnknown(handoff, binding)
                case .explicitFailure:
                    return .terminalNotVerified(
                        handoff, binding, outcome: .explicitFailure
                    )
                case .notAttempted:
                    return .terminalNotVerified(
                        handoff, binding, outcome: .notAttempted
                    )
                }
            }
    }

    private func codexDesktopCleanupHandoff(
        reportID: UUID,
        expectedNativeSessionIDs: [String]?,
        database: OpaquePointer
    ) throws -> CodexDesktopCleanupHandoff? {
        let records = try loadDeletedSessions(
            provider: .codex,
            database: database
        ).filter { $0.deleteReportID == reportID }
        guard !records.isEmpty else { return nil }
        let items = try records.map { record in
            let canonical = PersistentTimestamp.canonical(record.deletedAt)
            let milliseconds = Int64(
                (canonical.timeIntervalSince1970 * 1_000).rounded()
            )
            return try CodexDesktopCleanupHandoffItem(
                managerKey: record.managerKey,
                nativeSessionID: record.nativeSessionID,
                deletedAtMilliseconds: milliseconds
            )
        }
        let handoff = try CodexDesktopCleanupHandoff(
            canonicalDeleteReportID: reportID,
            items: items
        )
        if let expectedNativeSessionIDs {
            let ordered = expectedNativeSessionIDs.sorted()
            guard !ordered.isEmpty,
                  Set(ordered).count == ordered.count,
                  ordered == handoff.nativeSessionIDs else {
                throw PersistentStateError.previewItemSetMismatch
            }
        }
        return handoff
    }

    private func loadCodexDesktopCleanupBinding(
        reportID: UUID,
        database: OpaquePointer
    ) throws -> CodexDesktopCleanupBinding? {
        let rows = try query(
            """
            SELECT handoff_digest, bulk_request_id, bulk_operation_id,
                   confirmation_receipt_id,
                   confirmation_receipt_digest, plan_digest,
                   backup_receipt_digest, bound_at_milliseconds,
                   payload_json, payload_hash,
                   automatic_retry_allowed, repair_mutation_authority
            FROM codex_desktop_cleanup_bindings
            WHERE canonical_delete_report_id = ?
            """,
            values: [.text(reportID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexDesktopCleanupBinding in
            let encoded = try requiredText(statement, 8)
            guard Self.hashBulkPreviewPayload(encoded)
                    == (try requiredText(statement, 9)),
                  sqlite3_column_int64(statement, 10) == 0,
                  sqlite3_column_int64(statement, 11) == 0 else {
                throw PersistentStateError.invalidRecord(
                    "Desktop cleanup binding checksum or authority flags changed."
                )
            }
            let binding: CodexDesktopCleanupBinding =
                try Self.decodeBulkPreviewPayload(encoded)
            try binding.validate()
            guard binding.canonicalDeleteReportID == reportID,
                  binding.handoffDigest == (try requiredText(statement, 0)),
                  binding.bulkIdentity.requestID == UUID(
                    uuidString: try requiredText(statement, 1)
                  ),
                  binding.bulkIdentity.operationID == UUID(
                    uuidString: try requiredText(statement, 2)
                  ),
                  binding.confirmationReceiptID == UUID(
                    uuidString: try requiredText(statement, 3)
                  ),
                  binding.confirmationReceiptDigest
                    == (try requiredText(statement, 4)),
                  binding.planDigest == (try requiredText(statement, 5)),
                  binding.backupReceiptDigest
                    == (try requiredText(statement, 6)),
                  binding.boundAtMilliseconds
                    == sqlite3_column_int64(statement, 7) else {
                throw PersistentStateError.invalidRecord(
                    "Desktop cleanup binding columns and payload disagree."
                )
            }
            return binding
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Desktop cleanup binding is duplicated."
            )
        }
        return rows.first
    }

    private func validate(
        _ binding: CodexDesktopCleanupBinding,
        handoff: CodexDesktopCleanupHandoff,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkLiveJournalRecord {
        try binding.validate()
        try handoff.validate()
        guard binding.canonicalDeleteReportID
                == handoff.canonicalDeleteReportID,
              binding.handoffDigest == handoff.handoffDigest,
              binding.items.map(\.managerKey) == handoff.items.map(\.managerKey),
              binding.items.map(\.nativeSessionID)
                == handoff.items.map(\.nativeSessionID),
              binding.items.map(\.deletedAtMilliseconds)
                == handoff.items.map(\.deletedAtMilliseconds),
              let snapshot = try validatedCodexGhostRepairBulkLiveJournalSnapshot(
                identity: binding.bulkIdentity,
                database: database
              ),
              snapshot.record.confirmationReceipt.receiptID
                == binding.confirmationReceiptID,
              snapshot.record.confirmationReceipt.receiptDigest
                == binding.confirmationReceiptDigest,
              snapshot.record.plan.planDigest == binding.planDigest,
              snapshot.record.plan.backup.receiptDigest
                == binding.backupReceiptDigest,
              snapshot.record.plan.plannedAtMilliseconds
                >= (binding.items.map(\.deletedAtMilliseconds).max() ?? 0) else {
            throw CodexGhostRepairError.recoveryRequired
        }
        if snapshot.record.phase == .prepared,
           snapshot.payloadHash != binding.preparedJournalPayloadHash {
            throw CodexGhostRepairError.recoveryRequired
        }
        let selected = Dictionary(
            uniqueKeysWithValues: snapshot.record.plan.selectedItems.map {
                ($0.threadID, $0.category)
            }
        )
        guard snapshot.record.plan.selectedThreadIDs
                == handoff.nativeSessionIDs,
              binding.items.allSatisfy({
            selected[$0.nativeSessionID] == $0.category
        }) else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return snapshot.record
    }
}

actor CodexDesktopCleanupLinkageCoordinator:
    CodexDesktopCleanupLinkageCoordinating
{
    nonisolated let capabilities =
        CodexDesktopCleanupLinkageCapabilities.packaged

    private let databaseURLProvider: @Sendable () throws -> URL
    private let fileExists: @Sendable (String) -> Bool
    private let nowMilliseconds: @Sendable () -> Int64
    private let testStore: SQLiteStateStore?

    init(
        databaseURLProvider: @escaping @Sendable () throws -> URL = {
            try StateStoreLocation.applicationSupportDatabaseURL()
        },
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) {
        self.databaseURLProvider = databaseURLProvider
        self.fileExists = fileExists
        self.nowMilliseconds = nowMilliseconds
        testStore = nil
    }

    init(
        testStore: SQLiteStateStore,
        nowMilliseconds: @escaping @Sendable () -> Int64
    ) {
        databaseURLProvider = { testStore.databaseURL }
        fileExists = { _ in true }
        self.nowMilliseconds = nowMilliseconds
        self.testStore = testStore
    }

    func reviewCanonicalDelete(
        reportID: UUID,
        expectedNativeSessionIDs: [String]
    ) async -> CodexDesktopCleanupReviewOutcome {
        do {
            guard let loaded = try withStore({
                try $0.codexDesktopCleanupHandoff(
                    reportID: reportID,
                    expectedNativeSessionIDs: expectedNativeSessionIDs
                )
            }), let handoff = loaded else {
                return .notFound(reportID: reportID)
            }
            return .ready(handoff)
        } catch let error as PersistentStateError {
            return .rejected(message: error.localizedDescription)
        } catch {
            return .unavailable(
                message: "Canonical Delete handoff could not be read exactly."
            )
        }
    }

    func bindPreparedOperation(
        handoff: CodexDesktopCleanupHandoff,
        bulkIdentity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexDesktopCleanupBindOutcome {
        var writeReturned = false
        do {
            let outcome = try withStore { store in
                let result = try store.bindCodexDesktopCleanup(
                    handoff: handoff,
                    bulkIdentity: bulkIdentity,
                    boundAtMilliseconds: nowMilliseconds()
                )
                writeReturned = true
                return result
            }
            guard let outcome else {
                return .notFound(reportID: handoff.canonicalDeleteReportID)
            }
            switch outcome {
            case let .bound(binding): return .bound(binding)
            case let .alreadyBound(binding): return .alreadyBound(binding)
            }
        } catch let error as PersistentStateError {
            return .rejected(message: error.localizedDescription)
        } catch {
            if writeReturned {
                return .finalizationOutcomeUnknown(
                    reportID: handoff.canonicalDeleteReportID,
                    message:
                        "Desktop cleanup binding may have committed, but exact readback became unavailable. Read status before taking another action."
                )
            }
            return .rejected(
                message:
                    "Desktop cleanup binding was not established from the exact prepared operation."
            )
        }
    }

    func readStatus(
        reportID: UUID
    ) async -> CodexDesktopCleanupStatusOutcome {
        do {
            guard let loaded = try withStore({
                try $0.codexDesktopCleanupStatus(reportID: reportID)
            }), let status = loaded else {
                return .notFound(reportID: reportID)
            }
            return .status(status)
        } catch {
            return .unavailable(
                message:
                    "Desktop cleanup status could not be derived from the exact tombstone and bound journal."
            )
        }
    }

    private func withStore<T>(
        _ body: (SQLiteStateStore) throws -> T
    ) throws -> T? {
        if let testStore { return try body(testStore) }
        let databaseURL = try databaseURLProvider().standardizedFileURL
        guard fileExists(databaseURL.path) else { return nil }
        let exclusion = CodexGhostRepairBulkOperationExclusion(
            databaseURL: databaseURL
        )
        let lease = try exclusion.acquire()
        defer { lease.release() }
        try lease.validateCurrentPath()
        guard let identity = lease.fileIdentity else {
            throw CodexGhostRepairError.recoveryRequired
        }
        let store = try SQLiteStateStore(
            existingCurrentDatabaseURL: databaseURL,
            expectedFileIdentity: identity
        )
        defer { store.close() }
        let result = try body(store)
        try lease.validateCurrentPath()
        return result
    }
}
