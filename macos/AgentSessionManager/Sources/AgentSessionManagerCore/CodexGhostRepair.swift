import CryptoKit
import Foundation

public enum CodexGhostRepairCategory: String, Codable, Hashable, Sendable {
    case ordinary = "A"
    case automation = "B"
}

public enum CodexGhostRepairSQLiteValue: Codable, Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public struct CodexGhostRepairSQLiteField: Codable, Hashable, Sendable {
    public let name: String
    public let value: CodexGhostRepairSQLiteValue

    public init(name: String, value: CodexGhostRepairSQLiteValue) {
        self.name = name
        self.value = value
    }
}

public struct CodexGhostRepairSQLiteRow: Codable, Hashable, Sendable {
    public let fields: [CodexGhostRepairSQLiteField]

    public init(fields: [CodexGhostRepairSQLiteField]) {
        self.fields = fields
    }

    public func value(named name: String) -> CodexGhostRepairSQLiteValue? {
        fields.first { $0.name == name }?.value
    }

    func replacing(_ name: String, with value: CodexGhostRepairSQLiteValue) throws -> Self {
        guard fields.contains(where: { $0.name == name }) else {
            throw CodexGhostRepairError.invalidDatabaseContract("Missing expected column: \(name)")
        }
        return Self(fields: fields.map { field in
            field.name == name ? CodexGhostRepairSQLiteField(name: name, value: value) : field
        })
    }

    /// Preserves only operation-relevant fields. Every other typed value is
    /// replaced by a deterministic digest, so exact row drift remains visible
    /// without persisting prompts, messages, titles, or other private payloads
    /// into the manager-owned journal.
    func privacyPreserving(cleartextFields: Set<String>) throws -> Self {
        Self(fields: try fields.map { field in
            guard !cleartextFields.contains(field.name) else { return field }
            return CodexGhostRepairSQLiteField(
                name: field.name,
                value: .text("redacted:" + (try CodexGhostRepairHasher.hash(field)))
            )
        })
    }

    func satisfiesPrivacyContract(cleartextFields: Set<String>) -> Bool {
        fields.allSatisfy { field in
            if cleartextFields.contains(field.name) { return true }
            guard case let .text(value) = field.value,
                  value.hasPrefix("redacted:sha256:") else { return false }
            let digest = value.dropFirst("redacted:sha256:".count)
            return digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
        }
    }
}

enum CodexGhostRepairPrivacyContract {
    static let catalog: Set<String> = ["host_id", "thread_id", "missing_candidate"]
    static let automationRun: Set<String> = [
        "thread_id", "automation_id", "status", "archived_reason", "updated_at",
        "archived_user_message", "archived_assistant_message",
    ]
    static let automationDefinition: Set<String> = ["id", "status"]
    static let metadata: Set<String> = ["id", "catalog_revision"]
    static let localSync: Set<String> = [
        "host_id", "observation_sequence", "watermark_updated_at",
    ]
}

/// The smallest row evidence that can change whether a frozen bulk target is
/// still the same authorized deletion target. Display text, recency markers,
/// read state, and other synchronization metadata are intentionally excluded.
/// Those bytes remain protected by the fresh whole-source backup, but they do
/// not invalidate a user's exact stable-ID selection.
enum CodexGhostRepairBulkTargetEvidenceContract {
    private static let catalogAuthorizationFields: Set<String> = [
        "host_id", "thread_id",
    ]
    private static let automationIdentityFields: Set<String> = [
        "thread_id", "automation_id", "created_at",
        "archived_user_message", "archived_assistant_message",
    ]
    private static let automationIdentityRequiredFields: Set<String> = [
        "thread_id", "automation_id",
    ]
    private static let automationDefinitionAuthorizationFields: Set<String> = [
        "id", "status",
    ]
    private static let normalizedEmptyFields: Set<String> = [
        "archived_user_message", "archived_assistant_message",
    ]

    static func catalogAuthorizationDigest(
        _ row: CodexGhostRepairSQLiteRow
    ) throws -> String {
        try digest(
            row,
            includedFields: catalogAuthorizationFields,
            requiredFields: catalogAuthorizationFields
        )
    }

    static func automationIdentityDigest(
        _ row: CodexGhostRepairSQLiteRow
    ) throws -> String {
        try digest(
            row,
            includedFields: automationIdentityFields,
            requiredFields: automationIdentityRequiredFields,
            normalizeEmptyFields: normalizedEmptyFields
        )
    }

    static func automationDefinitionAuthorizationDigest(
        _ row: CodexGhostRepairSQLiteRow
    ) throws -> String {
        try digest(
            row,
            includedFields: automationDefinitionAuthorizationFields,
            requiredFields: automationDefinitionAuthorizationFields
        )
    }

    private static func digest(
        _ row: CodexGhostRepairSQLiteRow,
        includedFields: Set<String>,
        requiredFields: Set<String>,
        normalizeEmptyFields: Set<String> = []
    ) throws -> String {
        let availableNames = Set(row.fields.map(\.name))
        guard requiredFields.isSubset(of: availableNames) else {
            let missing = requiredFields.subtracting(availableNames).sorted()
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Missing bulk target evidence columns: \(missing.joined(separator: ", "))."
            )
        }
        let fields = row.fields.compactMap { field -> CodexGhostRepairSQLiteField? in
            guard includedFields.contains(field.name) else { return nil }
            let value: CodexGhostRepairSQLiteValue
            if normalizeEmptyFields.contains(field.name),
               field.value == .null || field.value == .text("") {
                value = .null
            } else {
                value = field.value
            }
            return .init(name: field.name, value: value)
        }.sorted { $0.name < $1.name }
        return try CodexGhostRepairHasher.hash(fields)
    }
}

public struct CodexGhostRepairProtectionEvidence: Codable, Hashable, Sendable {
    public let threadID: String
    public let inventoryComplete: Bool
    public let activeInventoryPresent: Bool
    public let archivedInventoryPresent: Bool
    public let exactReadNotLoaded: Bool
    public let exactReadErrorCode: Int
    public let pinned: Bool
    public let descendantCount: Int

    public init(
        threadID: String,
        inventoryComplete: Bool,
        activeInventoryPresent: Bool,
        archivedInventoryPresent: Bool,
        exactReadNotLoaded: Bool,
        exactReadErrorCode: Int,
        pinned: Bool,
        descendantCount: Int
    ) {
        self.threadID = threadID
        self.inventoryComplete = inventoryComplete
        self.activeInventoryPresent = activeInventoryPresent
        self.archivedInventoryPresent = archivedInventoryPresent
        self.exactReadNotLoaded = exactReadNotLoaded
        self.exactReadErrorCode = exactReadErrorCode
        self.pinned = pinned
        self.descendantCount = descendantCount
    }

    public var isEligible: Bool {
        inventoryComplete && !activeInventoryPresent && !archivedInventoryPresent
            && exactReadNotLoaded && exactReadErrorCode == -32600
            && !pinned && descendantCount == 0
    }
}

public enum CodexGhostRepairDesktopProcessKind:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Sendable
{
    case codexApplication
    case codexHelper
    case codexCrashReporter
    case chatGPTApplication
    case chatGPTHelper
    case chatGPTCrashReporter

    public var blocksSnapshotAcquisition: Bool {
        switch self {
        case .codexCrashReporter, .chatGPTCrashReporter:
            false
        case .codexApplication, .codexHelper,
             .chatGPTApplication, .chatGPTHelper:
            true
        }
    }

    public var userFacingDescription: String {
        switch self {
        case .codexApplication:
            "Codex main application process"
        case .codexHelper:
            "Codex helper process"
        case .codexCrashReporter:
            "Codex crash reporter process"
        case .chatGPTApplication:
            "ChatGPT main application process"
        case .chatGPTHelper:
            "ChatGPT helper process"
        case .chatGPTCrashReporter:
            "ChatGPT crash reporter process"
        }
    }
}

public struct CodexGhostRepairDesktopProcessEvidence:
    Codable,
    Hashable,
    Sendable
{
    public let kind: CodexGhostRepairDesktopProcessKind
    public let processCount: Int

    public init(
        kind: CodexGhostRepairDesktopProcessKind,
        processCount: Int
    ) {
        self.kind = kind
        self.processCount = processCount
    }

    public var userFacingDescription: String {
        "\(kind.userFacingDescription) is still running (\(processCount))"
    }

    public var blocksSnapshotAcquisition: Bool {
        kind.blocksSnapshotAcquisition
    }

    public var userFacingObservationDescription: String {
        "Observed but non-blocking: \(kind.userFacingDescription) (\(processCount))"
    }
}

public enum CodexGhostRepairDatabaseRole:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Sendable
{
    case desktop
    case summaries
    case legacyHistory
    case state
    case threadHistory

    public var userFacingDescription: String {
        switch self {
        case .desktop: "Desktop"
        case .summaries: "Summaries"
        case .legacyHistory: "Legacy history"
        case .state: "State"
        case .threadHistory: "Thread history"
        }
    }

    public var databaseFileName: String {
        switch self {
        case .desktop: "codex-dev.db"
        case .summaries: "codex-thread-summaries-dev.db"
        case .legacyHistory: "codex-history-snapshots-dev.db"
        case .state: "state_5.sqlite"
        case .threadHistory: "thread_history_1.sqlite"
        }
    }
}

/// Path-redacted application identity for an exact open-handle owner. This is
/// intentionally separate from the lower-level process kind: the operator
/// needs to know which application to close, not how a helper is implemented.
public enum CodexGhostRepairOpenHandleOwnerApplication:
    String,
    Codable,
    Hashable,
    Sendable
{
    case visualStudioCodeOpenAIExtension
    case codexDesktop
    case chatGPTDesktop
    case codexCommandLine

    public var closeInstruction: String {
        switch self {
        case .visualStudioCodeOpenAIExtension:
            "Close Visual Studio Code (OpenAI extension), then check again."
        case .codexDesktop:
            "Close Codex, then check again."
        case .chatGPTDesktop:
            "Close ChatGPT, then check again."
        case .codexCommandLine:
            "Stop the Codex CLI or App Server process, then check again."
        }
    }
}

/// Path-redacted owner evidence for one fixed Codex database role. One item
/// represents one unique process, while `fileDescriptorCount` preserves the
/// number of matching `lsof` descriptors without misreporting them as a
/// process count.
public struct CodexGhostRepairOpenHandleOwnerEvidence:
    Codable,
    Hashable,
    Sendable
{
    public let databaseRole: CodexGhostRepairDatabaseRole
    public let processIdentifier: Int32
    public let parentProcessIdentifier: Int32?
    public let processName: String
    public let executableName: String?
    public let parentProcessName: String?
    public let processKind: CodexGhostRepairDesktopProcessKind?
    public let ownerApplication:
        CodexGhostRepairOpenHandleOwnerApplication?
    public let fileDescriptorCount: Int

    public init(
        databaseRole: CodexGhostRepairDatabaseRole,
        processIdentifier: Int32,
        parentProcessIdentifier: Int32?,
        processName: String,
        executableName: String? = nil,
        parentProcessName: String? = nil,
        processKind: CodexGhostRepairDesktopProcessKind?,
        ownerApplication:
            CodexGhostRepairOpenHandleOwnerApplication? = nil,
        fileDescriptorCount: Int
    ) {
        self.databaseRole = databaseRole
        self.processIdentifier = processIdentifier
        self.parentProcessIdentifier = parentProcessIdentifier
        self.processName = processName
        self.executableName = executableName
        self.parentProcessName = parentProcessName
        self.processKind = processKind
        self.ownerApplication = ownerApplication
        self.fileDescriptorCount = fileDescriptorCount
    }

    public var userFacingDescription: String {
        let parent: String
        if let parentProcessIdentifier {
            if let parentProcessName {
                parent = "\(parentProcessName) (PID \(parentProcessIdentifier))"
            } else {
                parent = "PID \(parentProcessIdentifier)"
            }
        } else {
            parent = "unavailable"
        }
        let executable = executableName ?? processName
        let descriptorNoun = fileDescriptorCount == 1
            ? "open file descriptor"
            : "open file descriptors"
        if let ownerApplication {
            return "\(ownerApplication.closeInstruction) \(databaseRole.userFacingDescription) (\(databaseRole.databaseFileName)) is held by PID \(processIdentifier) with \(fileDescriptorCount) \(descriptorNoun)."
        }
        return "\(databaseRole.userFacingDescription) (\(databaseRole.databaseFileName)): process \(processName) · executable \(executable) · PID \(processIdentifier) · parent \(parent) · \(fileDescriptorCount) \(descriptorNoun)"
    }
}

public struct CodexGhostRepairExecutionGate: Codable, Hashable, Sendable {
    public let codexFullyExited: Bool
    /// Path-redacted process classes observed by the production macOS gate.
    /// `nil` preserves compatibility with older persisted research evidence
    /// and deterministic fakes that predate process classification.
    public let desktopProcessEvidence:
        [CodexGhostRepairDesktopProcessEvidence]?
    public let desktopOpenHandleCount: Int
    public let summariesOpenHandleCount: Int
    public let historyOpenHandleCount: Int
    /// Added for the Codex 0.149 paginated runtime layout. Optional decoding
    /// preserves older persisted research evidence.
    public let stateOpenHandleCount: Int?
    public let threadHistoryOpenHandleCount: Int?
    /// `nil` preserves compatibility with older persisted evidence and fakes
    /// that predate exact owner diagnostics. A fresh production observation
    /// supplies an empty array when all five roles have zero handles.
    public let openHandleOwnerEvidence:
        [CodexGhostRepairOpenHandleOwnerEvidence]?
    public let capacitySufficient: Bool

    public init(
        codexFullyExited: Bool,
        desktopOpenHandleCount: Int,
        summariesOpenHandleCount: Int,
        historyOpenHandleCount: Int,
        stateOpenHandleCount: Int? = nil,
        threadHistoryOpenHandleCount: Int? = nil,
        capacitySufficient: Bool,
        desktopProcessEvidence:
            [CodexGhostRepairDesktopProcessEvidence]? = nil,
        openHandleOwnerEvidence:
            [CodexGhostRepairOpenHandleOwnerEvidence]? = nil
    ) {
        self.codexFullyExited = codexFullyExited
        self.desktopProcessEvidence = desktopProcessEvidence
        self.desktopOpenHandleCount = desktopOpenHandleCount
        self.summariesOpenHandleCount = summariesOpenHandleCount
        self.historyOpenHandleCount = historyOpenHandleCount
        self.stateOpenHandleCount = stateOpenHandleCount
        self.threadHistoryOpenHandleCount = threadHistoryOpenHandleCount
        self.openHandleOwnerEvidence = openHandleOwnerEvidence
        self.capacitySufficient = capacitySufficient
    }

    public var isClear: Bool {
        codexFullyExited && desktopOpenHandleCount == 0 && summariesOpenHandleCount == 0
            && historyOpenHandleCount == 0
            && (stateOpenHandleCount ?? 0) == 0
            && (threadHistoryOpenHandleCount ?? 0) == 0
            && capacitySufficient
    }
}

public struct CodexGhostRepairTargetEvidence: Codable, Hashable, Sendable {
    public let threadID: String
    public let catalogRow: CodexGhostRepairSQLiteRow
    public let automationRow: CodexGhostRepairSQLiteRow?
    public let automationDefinitionRow: CodexGhostRepairSQLiteRow?

    public init(
        threadID: String,
        catalogRow: CodexGhostRepairSQLiteRow,
        automationRow: CodexGhostRepairSQLiteRow?,
        automationDefinitionRow: CodexGhostRepairSQLiteRow?
    ) {
        self.threadID = threadID
        self.catalogRow = catalogRow
        self.automationRow = automationRow
        self.automationDefinitionRow = automationDefinitionRow
    }
}

public struct CodexGhostRepairAuthorityEvidence: Codable, Hashable, Sendable {
    public let metadataRow: CodexGhostRepairSQLiteRow
    public let localSyncRow: CodexGhostRepairSQLiteRow

    public init(
        metadataRow: CodexGhostRepairSQLiteRow,
        localSyncRow: CodexGhostRepairSQLiteRow
    ) {
        self.metadataRow = metadataRow
        self.localSyncRow = localSyncRow
    }
}

public struct CodexGhostRepairDatabaseSnapshot: Codable, Hashable, Sendable {
    public let desktopSchemaVersion: Int32
    public let summariesSchemaVersion: Int32
    public let historySchemaVersion: Int32
    public let targets: [CodexGhostRepairTargetEvidence]
    public let authority: CodexGhostRepairAuthorityEvidence

    public init(
        desktopSchemaVersion: Int32,
        summariesSchemaVersion: Int32,
        historySchemaVersion: Int32,
        targets: [CodexGhostRepairTargetEvidence],
        authority: CodexGhostRepairAuthorityEvidence
    ) {
        self.desktopSchemaVersion = desktopSchemaVersion
        self.summariesSchemaVersion = summariesSchemaVersion
        self.historySchemaVersion = historySchemaVersion
        self.targets = targets
        self.authority = authority
    }
}

private struct CodexGhostRepairPlanPayload: Codable, Hashable {
    let id: UUID
    let createdAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let category: CodexGhostRepairCategory
    let targetIDs: [String]
    let frozenTargets: [CodexGhostRepairTargetEvidence]
    let previewAuthorityAudit: CodexGhostRepairAuthorityEvidence
    let protectionEvidence: [CodexGhostRepairProtectionEvidence]
    let desktopSchemaVersion: Int32
    let summariesSchemaVersion: Int32
    let historySchemaVersion: Int32
}

public struct CodexGhostRepairPlan: Codable, Hashable, Sendable {
    public let id: UUID
    public let createdAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let category: CodexGhostRepairCategory
    public let targetIDs: [String]
    public let frozenTargets: [CodexGhostRepairTargetEvidence]
    /// Preview-time counters are audit evidence only. Execution freezes fresh
    /// authority after shutdown and verified backup.
    public let previewAuthorityAudit: CodexGhostRepairAuthorityEvidence
    public let protectionEvidence: [CodexGhostRepairProtectionEvidence]
    public let desktopSchemaVersion: Int32
    public let summariesSchemaVersion: Int32
    public let historySchemaVersion: Int32
    public let manifestHash: String
    public let confirmationToken: String

    public var isLiveMutationAuthority: Bool { false }

    public init(
        id: UUID,
        createdAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        category: CodexGhostRepairCategory,
        targetIDs: [String],
        frozenTargets: [CodexGhostRepairTargetEvidence],
        previewAuthorityAudit: CodexGhostRepairAuthorityEvidence,
        protectionEvidence: [CodexGhostRepairProtectionEvidence],
        desktopSchemaVersion: Int32,
        summariesSchemaVersion: Int32,
        historySchemaVersion: Int32
    ) throws {
        let payload = CodexGhostRepairPlanPayload(
            id: id,
            createdAtMilliseconds: createdAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds,
            category: category,
            targetIDs: targetIDs,
            frozenTargets: frozenTargets,
            previewAuthorityAudit: previewAuthorityAudit,
            protectionEvidence: protectionEvidence,
            desktopSchemaVersion: desktopSchemaVersion,
            summariesSchemaVersion: summariesSchemaVersion,
            historySchemaVersion: historySchemaVersion
        )
        let hash = try CodexGhostRepairHasher.hash(payload)
        self.id = id
        self.createdAtMilliseconds = createdAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.category = category
        self.targetIDs = targetIDs
        self.frozenTargets = frozenTargets
        self.previewAuthorityAudit = previewAuthorityAudit
        self.protectionEvidence = protectionEvidence
        self.desktopSchemaVersion = desktopSchemaVersion
        self.summariesSchemaVersion = summariesSchemaVersion
        self.historySchemaVersion = historySchemaVersion
        manifestHash = hash
        confirmationToken = "GHOST-REPAIR-" + hash.dropFirst("sha256:".count).prefix(12).uppercased()
    }

    func validateManifest() throws {
        let payload = CodexGhostRepairPlanPayload(
            id: id,
            createdAtMilliseconds: createdAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds,
            category: category,
            targetIDs: targetIDs,
            frozenTargets: frozenTargets,
            previewAuthorityAudit: previewAuthorityAudit,
            protectionEvidence: protectionEvidence,
            desktopSchemaVersion: desktopSchemaVersion,
            summariesSchemaVersion: summariesSchemaVersion,
            historySchemaVersion: historySchemaVersion
        )
        let expectedHash = try CodexGhostRepairHasher.hash(payload)
        guard expectedHash == manifestHash else {
            throw CodexGhostRepairError.invalidPlan("Manifest hash mismatch.")
        }
        let expectedToken = "GHOST-REPAIR-"
            + expectedHash.dropFirst("sha256:".count).prefix(12).uppercased()
        guard confirmationToken == expectedToken else {
            throw CodexGhostRepairError.invalidPlan("Confirmation token mismatch.")
        }
    }
}

public enum CodexGhostRepairPersistentStatus: String, Codable, Hashable, Sendable {
    case prepared
    case executing
    case consumed
}

private struct CodexGhostRepairExecutionClaimPayload: Codable, Hashable {
    let planID: UUID
    let planManifestHash: String
    let claimedAtMilliseconds: Int64
    let executionAtMilliseconds: Int64
    let freshAuthority: CodexGhostRepairAuthorityEvidence
    let freshProtectionEvidenceHash: String
    let executionGate: CodexGhostRepairExecutionGate
    let backupManifestHash: String
}

/// Manager-owned execution journal. It is durable replay protection and audit
/// evidence, never independent authority to mutate a Codex database.
public struct CodexGhostRepairExecutionClaim: Codable, Hashable, Sendable {
    public let planID: UUID
    public let planManifestHash: String
    public let claimedAtMilliseconds: Int64
    public let executionAtMilliseconds: Int64
    public let freshAuthority: CodexGhostRepairAuthorityEvidence
    public let freshProtectionEvidenceHash: String
    public let executionGate: CodexGhostRepairExecutionGate
    public let backupManifestHash: String
    public let claimHash: String

    public init(
        planID: UUID,
        planManifestHash: String,
        claimedAtMilliseconds: Int64,
        executionAtMilliseconds: Int64,
        freshAuthority: CodexGhostRepairAuthorityEvidence,
        freshProtectionEvidenceHash: String,
        executionGate: CodexGhostRepairExecutionGate,
        backupManifestHash: String
    ) throws {
        let payload = CodexGhostRepairExecutionClaimPayload(
            planID: planID,
            planManifestHash: planManifestHash,
            claimedAtMilliseconds: claimedAtMilliseconds,
            executionAtMilliseconds: executionAtMilliseconds,
            freshAuthority: freshAuthority,
            freshProtectionEvidenceHash: freshProtectionEvidenceHash,
            executionGate: executionGate,
            backupManifestHash: backupManifestHash
        )
        guard executionGate.isClear,
              !freshProtectionEvidenceHash.isEmpty,
              !backupManifestHash.isEmpty else {
            throw CodexGhostRepairError.invalidPlan(
                "Execution claim requires clear gates and complete hashes."
            )
        }
        self.planID = planID
        self.planManifestHash = planManifestHash
        self.claimedAtMilliseconds = claimedAtMilliseconds
        self.executionAtMilliseconds = executionAtMilliseconds
        self.freshAuthority = freshAuthority
        self.freshProtectionEvidenceHash = freshProtectionEvidenceHash
        self.executionGate = executionGate
        self.backupManifestHash = backupManifestHash
        claimHash = try CodexGhostRepairHasher.hash(payload)
    }

    func validateHash() throws {
        let payload = CodexGhostRepairExecutionClaimPayload(
            planID: planID,
            planManifestHash: planManifestHash,
            claimedAtMilliseconds: claimedAtMilliseconds,
            executionAtMilliseconds: executionAtMilliseconds,
            freshAuthority: freshAuthority,
            freshProtectionEvidenceHash: freshProtectionEvidenceHash,
            executionGate: executionGate,
            backupManifestHash: backupManifestHash
        )
        guard try CodexGhostRepairHasher.hash(payload) == claimHash else {
            throw CodexGhostRepairError.invalidPlan("Execution claim hash mismatch.")
        }
    }
}

public enum CodexGhostRepairBeginResult: Hashable, Sendable {
    case claimed(CodexGhostRepairExecutionClaim)
    case recoveryRequired(CodexGhostRepairExecutionClaim)
    case existingReport(CodexGhostRepairReport)
}

public enum CodexGhostRepairItemOutcome: String, Codable, Hashable, Sendable {
    case repaired
    case notApplied = "not_applied"
    case unknown
}

public enum CodexGhostRepairReportOutcome: String, Codable, Hashable, Sendable {
    case success
    case notApplied = "not_applied"
    case unknown
}

public struct CodexGhostRepairReportItem: Codable, Hashable, Sendable {
    public let threadID: String
    public let outcome: CodexGhostRepairItemOutcome

    public init(threadID: String, outcome: CodexGhostRepairItemOutcome) {
        self.threadID = threadID
        self.outcome = outcome
    }
}

public struct CodexGhostRepairReport: Codable, Hashable, Sendable {
    public let planID: UUID
    public let planManifestHash: String
    public let completedAtMilliseconds: Int64
    public let outcome: CodexGhostRepairReportOutcome
    public let items: [CodexGhostRepairReportItem]
    public let recoveredByReadback: Bool
    public let mutationAttemptedOnce: Bool
    public let mutationRetryAllowed: Bool
    public let backupManifestHash: String

    public init(
        planID: UUID,
        planManifestHash: String,
        completedAtMilliseconds: Int64,
        outcome: CodexGhostRepairReportOutcome,
        items: [CodexGhostRepairReportItem],
        recoveredByReadback: Bool,
        mutationAttemptedOnce: Bool,
        mutationRetryAllowed: Bool,
        backupManifestHash: String
    ) {
        self.planID = planID
        self.planManifestHash = planManifestHash
        self.completedAtMilliseconds = completedAtMilliseconds
        self.outcome = outcome
        self.items = items
        self.recoveredByReadback = recoveredByReadback
        self.mutationAttemptedOnce = mutationAttemptedOnce
        self.mutationRetryAllowed = mutationRetryAllowed
        self.backupManifestHash = backupManifestHash
    }
}

public enum CodexGhostRepairError: Error, Equatable, LocalizedError {
    case invalidDisposablePath(String)
    case invalidPlan(String)
    case invalidProtectionEvidence(String)
    case executionGateBlocked
    case previewExpired
    case confirmationMismatch
    case invalidDatabaseContract(String)
    case targetDrift(String)
    case authorityDrift
    case backupFailed(String)
    case snapshotAcquisitionFailed(String)
    case claimAlreadyExists
    case recoveryRequired
    case sqlite(operation: String, code: Int32, message: String)
    case injectedInterruption

    public var errorDescription: String? {
        switch self {
        case let .invalidDisposablePath(message): "Invalid disposable Ghost Repair path: \(message)"
        case let .invalidPlan(message): "Invalid Ghost Repair Preview: \(message)"
        case let .invalidProtectionEvidence(message): "Invalid protection evidence: \(message)"
        case .executionGateBlocked: "Codex shutdown, open-handle, or capacity gate is not clear."
        case .previewExpired: "The frozen Ghost Repair Preview expired."
        case .confirmationMismatch: "Ghost Repair confirmation does not match the frozen Preview."
        case let .invalidDatabaseContract(message): "Unsupported Codex Desktop database contract: \(message)"
        case let .targetDrift(message): "Frozen Ghost Repair target drifted: \(message)"
        case .authorityDrift: "Fresh Codex Desktop execution authority drifted."
        case let .backupFailed(message): "Ghost Repair backup failed: \(message)"
        case let .snapshotAcquisitionFailed(message):
            "Ghost Repair snapshot acquisition failed: \(message)"
        case .claimAlreadyExists: "A durable Ghost Repair execution claim already exists."
        case .recoveryRequired: "A claimed Ghost Repair requires readback-only recovery; it cannot replay."
        case let .sqlite(operation, code, message): "SQLite \(operation) failed (\(code)): \(message)"
        case .injectedInterruption: "Injected Ghost Repair interruption."
        }
    }
}

enum CodexGhostRepairHasher {
    static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(value))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
