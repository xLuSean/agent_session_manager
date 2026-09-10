import CryptoKit
import CSQLite3
import Darwin
import Foundation

enum CodexGhostRepairBulkDisposableFault: Sendable {
    case none
    case explicitBusyBeforeTransaction
    case afterClaim
    case afterCommitBeforeReport
}

struct CodexGhostRepairBulkDisposableExecutorCapabilities:
    Equatable,
    Sendable
{
    let testOwnedDisposableCopiesOnly = true
    let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems
    let mixedCategoryBatch = true
    let oneDesktopTransaction = true
    let durableClaimBeforeMutation = true
    let durableItemizedReport = true
    let silentSelectionShrinkAllowed = false
    let automaticRetryAllowed = false
    let acceptsLiveCodexRoot = false
    let appWiringAvailable = false
    let packagedRepairAuthority = false
}

private struct CodexGhostRepairBulkExecutionPlanPayload:
    Codable,
    Hashable
{
    let operationID: UUID
    let previewID: UUID
    let previewManifestDigest: String
    let confirmationReceiptID: UUID
    let confirmationReceiptDigest: String
    let snapshotReference: String
    let selectedItems: [CodexGhostRepairBulkExecutionFrozenItem]
    let blockedOutsideBatchCount: Int
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let plannedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
}

struct CodexGhostRepairBulkExecutionFrozenItem:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let threadID: String
    let category: CodexGhostRepairCategory
    let inventoryEvidenceDigest: String
    let catalogRowDigest: String
    let automationRunRowDigest: String?
    let automationStableFieldsDigest: String?
    let automationDefinitionRowDigest: String?
}

struct CodexGhostRepairBulkExecutionPlan:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let previewID: UUID
    let previewManifestDigest: String
    let confirmationReceiptID: UUID
    let confirmationReceiptDigest: String
    let snapshotReference: String
    let selectedItems: [CodexGhostRepairBulkExecutionFrozenItem]
    let blockedOutsideBatchCount: Int
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let plannedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let planDigest: String

    var selectedThreadIDs: [String] { selectedItems.map(\.threadID) }
    var allOrNothing: Bool { true }
    var silentSelectionShrinkAllowed: Bool { false }
    var createsClaim: Bool { false }
    var repairMutationAuthority: Bool { false }
    var automaticRetryAllowed: Bool { false }

    static func prepare(
        operationID: UUID,
        preview: CodexGhostRepairBulkPreview,
        challenge: CodexGhostRepairBulkConfirmationChallenge,
        receipt: CodexGhostRepairBulkConfirmationReceipt,
        frozenInventoryInput: CodexGhostRepairBulkInventoryInput,
        plannedAtMilliseconds: Int64
    ) throws -> Self {
        try preview.validateForPersistence()
        try challenge.validate(
            requestID: challenge.savedPreviewRequestID,
            preview: preview,
            payloadHash: challenge.previewPayloadHash
        )
        try receipt.validate(challenge: challenge)
        let inventory = try CodexGhostRepairBulkInventoryBuilder.build(
            input: frozenInventoryInput
        )
        guard plannedAtMilliseconds >= receipt.confirmedAtMilliseconds,
              plannedAtMilliseconds < preview.expiresAtMilliseconds,
              inventory.snapshotReference == preview.snapshotReference,
              inventory.inventoryDigest == preview.inventoryDigest,
              receipt.selectedCount == preview.selectedItems.count,
              receipt.savedPreviewRequestID
                == challenge.savedPreviewRequestID else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk execution inputs do not describe one exact confirmed Preview."
            )
        }
        let targetByID = Dictionary(
            uniqueKeysWithValues: frozenInventoryInput.targets.map {
                ($0.threadID, $0)
            }
        )
        let inventoryByID = Dictionary(
            uniqueKeysWithValues: inventory.items.map { ($0.threadID, $0) }
        )
        let frozenItems: [CodexGhostRepairBulkExecutionFrozenItem] =
            try preview.selectedItems.map { item in
            guard let target = targetByID[item.threadID],
                  let inventoryItem = inventoryByID[item.threadID],
                  inventoryItem.disposition == .eligible,
                  inventoryItem.category == item.category,
                  inventoryItem.evidenceDigest == item.evidenceDigest,
                  target.catalogRowDigests.count == 1,
                  target.references.total == 0 else {
                throw CodexGhostRepairError.invalidPlan(
                    "Bulk execution target evidence drifted from the saved Preview."
                )
            }
            switch item.category {
            case .ordinary:
                guard target.rowContract == .categoryAEligible,
                      target.automationRunRowDigests.isEmpty,
                      target.automationStableFieldsDigests.isEmpty,
                      target.automationDefinitionRowDigests.isEmpty else {
                    throw CodexGhostRepairError.invalidPlan(
                        "Bulk Category A target shape is invalid."
                    )
                }
            case .automation:
                guard target.rowContract == .categoryBEligible,
                      target.automationRunRowDigests.count == 1,
                      target.automationStableFieldsDigests.count == 1,
                      target.automationDefinitionRowDigests.count == 1 else {
                    throw CodexGhostRepairError.invalidPlan(
                        "Bulk Category B target shape is invalid."
                    )
                }
            }
            return CodexGhostRepairBulkExecutionFrozenItem(
                threadID: item.threadID,
                category: item.category,
                inventoryEvidenceDigest: item.evidenceDigest,
                catalogRowDigest: target.catalogRowDigests[0],
                automationRunRowDigest: target.automationRunRowDigests.first,
                automationStableFieldsDigest:
                    target.automationStableFieldsDigests.first,
                automationDefinitionRowDigest:
                    target.automationDefinitionRowDigests.first
            )
        }
        let payload = CodexGhostRepairBulkExecutionPlanPayload(
            operationID: operationID,
            previewID: preview.previewID,
            previewManifestDigest: preview.manifestDigest,
            confirmationReceiptID: receipt.receiptID,
            confirmationReceiptDigest: receipt.receiptDigest,
            snapshotReference: preview.snapshotReference,
            selectedItems: frozenItems,
            blockedOutsideBatchCount: preview.blockedItems.count,
            databases: frozenInventoryInput.databases,
            authority: frozenInventoryInput.authority,
            plannedAtMilliseconds: plannedAtMilliseconds,
            expiresAtMilliseconds: preview.expiresAtMilliseconds
        )
        return try Self(payload: payload)
    }

    private init(payload: CodexGhostRepairBulkExecutionPlanPayload) throws {
        operationID = payload.operationID
        previewID = payload.previewID
        previewManifestDigest = payload.previewManifestDigest
        confirmationReceiptID = payload.confirmationReceiptID
        confirmationReceiptDigest = payload.confirmationReceiptDigest
        snapshotReference = payload.snapshotReference
        selectedItems = payload.selectedItems
        blockedOutsideBatchCount = payload.blockedOutsideBatchCount
        databases = payload.databases
        authority = payload.authority
        plannedAtMilliseconds = payload.plannedAtMilliseconds
        expiresAtMilliseconds = payload.expiresAtMilliseconds
        planDigest = try CodexGhostRepairHasher.hash(payload)
    }

    func validateDigest() throws {
        let payload = CodexGhostRepairBulkExecutionPlanPayload(
            operationID: operationID,
            previewID: previewID,
            previewManifestDigest: previewManifestDigest,
            confirmationReceiptID: confirmationReceiptID,
            confirmationReceiptDigest: confirmationReceiptDigest,
            snapshotReference: snapshotReference,
            selectedItems: selectedItems,
            blockedOutsideBatchCount: blockedOutsideBatchCount,
            databases: databases,
            authority: authority,
            plannedAtMilliseconds: plannedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
        guard try CodexGhostRepairHasher.hash(payload) == planDigest,
              (1...CodexGhostRepairBulkPreview.maximumSelectedItems)
                .contains(selectedItems.count),
              selectedThreadIDs == selectedThreadIDs.sorted(),
              Set(selectedThreadIDs).count == selectedThreadIDs.count,
              selectedItems.allSatisfy(Self.hasValidFrozenShape),
              blockedOutsideBatchCount >= 0,
              databases.map(\.database)
                == CodexGhostRepairSnapshotAnalysisDatabase.allCases else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk execution plan integrity is invalid."
            )
        }
    }

    private static func hasValidFrozenShape(
        _ item: CodexGhostRepairBulkExecutionFrozenItem
    ) -> Bool {
        switch item.category {
        case .ordinary:
            item.automationRunRowDigest == nil
                && item.automationStableFieldsDigest == nil
                && item.automationDefinitionRowDigest == nil
        case .automation:
            item.automationRunRowDigest != nil
                && item.automationStableFieldsDigest != nil
                && item.automationDefinitionRowDigest != nil
        }
    }
}

private struct CodexGhostRepairBulkExecutionObservedItem:
    Codable,
    Equatable,
    Hashable
{
    let threadID: String
    let category: CodexGhostRepairCategory
    let catalogRowDigest: String?
    let automationRunRowDigest: String?
    let automationStableFieldsDigest: String?
    let automationStatus: String?
    let automationArchivedReason: String?
    let automationUpdatedAt: Int64?
    let automationDefinitionRowDigest: String?
    let referenceCount: Int
}

private struct CodexGhostRepairBulkExecutionObservedState:
    Codable,
    Equatable,
    Hashable
{
    let items: [CodexGhostRepairBulkExecutionObservedItem]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let databaseEvidence: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let readOnlyDatabaseHashes: [String: String]
}

private struct CodexGhostRepairBulkExecutionClaim:
    Codable,
    Equatable,
    Hashable
{
    let operationID: UUID
    let planDigest: String
    let confirmationReceiptDigest: String
    let executionAtMilliseconds: Int64
    let beforeState: CodexGhostRepairBulkExecutionObservedState
    let claimedAtMilliseconds: Int64
}

private struct CodexGhostRepairBulkExecutionAttempt:
    Codable,
    Equatable,
    Hashable
{
    let operationID: UUID
    let planDigest: String
    let claimDigest: String
    let attemptedAtMilliseconds: Int64
}

struct CodexGhostRepairBulkDisposableReportItem:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let threadID: String
    let category: CodexGhostRepairCategory
    let outcome: CodexGhostRepairCategoryAItemOutcome
}

struct CodexGhostRepairBulkDisposableReport:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let planDigest: String
    let confirmationReceiptDigest: String
    let completedAtMilliseconds: Int64
    let outcome: CodexGhostRepairCategoryABatchOutcome
    let items: [CodexGhostRepairBulkDisposableReportItem]
    let durableClaimCreated: Bool
    let mutationAttemptedOnce: Bool
    let recoveredByReadback: Bool
    let readOnlyDatabasesUnchanged: Bool
    let automaticRetryAllowed: Bool
    let liveCodexRootAccessed: Bool
    let appRepairAuthority: Bool
}

struct CodexGhostRepairBulkDisposableBundle: Sendable {
    static let markerFileName =
        ".agent-session-manager-m4c-bulk-disposable-v1"
    static let markerContents =
        "Agent Session Manager M4c bulk disposable mirror v1\n"
    static let evidenceDirectoryName = "m4c-bulk-executions"

    let rootURL: URL
    let evidenceRootURL: URL

    init(rootURL: URL, allowedParentURL: URL) throws {
        let root = rootURL.standardizedFileURL
        let parent = allowedParentURL.standardizedFileURL
        let live = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
        guard root.path != parent.path,
              root.path.hasPrefix(parent.path + "/"),
              root.path != live.path,
              !root.path.hasPrefix(live.path + "/") else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4c disposable root escaped its test-owned boundary."
            )
        }
        let marker = root.appendingPathComponent(Self.markerFileName)
        guard try String(contentsOf: marker, encoding: .utf8)
                == Self.markerContents else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4c disposable marker is missing or invalid."
            )
        }
        let evidence = root.appendingPathComponent(
            Self.evidenceDirectoryName,
            isDirectory: true
        )
        self.rootURL = root
        evidenceRootURL = evidence
        try validateFreshLayout()
    }

    var desktopURL: URL { databaseURL(.desktop) }

    func databaseURL(_ database: CodexGhostRepairSnapshotAnalysisDatabase)
        -> URL
    {
        rootURL.appendingPathComponent(database.canonicalFile.rawValue)
    }

    func validateFreshLayout() throws {
        try Self.requirePrivateDirectory(rootURL)
        try Self.requirePrivateDirectory(evidenceRootURL)
        for database in CodexGhostRepairSnapshotAnalysisDatabase.allCases {
            try Self.requirePrivateFile(databaseURL(database))
        }
    }

    fileprivate func paths(for operationID: UUID) -> EvidencePaths {
        let directory = evidenceRootURL.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
        return .init(
            directory: directory,
            claim: directory.appendingPathComponent("claim.json"),
            attempt: directory.appendingPathComponent("attempt.json"),
            report: directory.appendingPathComponent("report.json")
        )
    }

    fileprivate struct EvidencePaths {
        let directory: URL
        let claim: URL
        let attempt: URL
        let report: URL
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFDIR,
              value.st_uid == getuid(),
              value.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4c fixed directory is not owner-private."
            )
        }
    }

    private static func requirePrivateFile(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == getuid(),
              value.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4c fixed database is not an owner-private regular file."
            )
        }
    }
}

actor CodexGhostRepairBulkDisposableExecutor {
    static let capabilities =
        CodexGhostRepairBulkDisposableExecutorCapabilities()

    private let bundle: CodexGhostRepairBulkDisposableBundle
    private let nowMilliseconds: @Sendable () -> Int64

    init(
        bundle: CodexGhostRepairBulkDisposableBundle,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) {
        self.bundle = bundle
        self.nowMilliseconds = nowMilliseconds
    }

    func execute(
        plan: CodexGhostRepairBulkExecutionPlan,
        fault: CodexGhostRepairBulkDisposableFault = .none
    ) throws -> CodexGhostRepairBulkDisposableReport {
        try plan.validateDigest()
        try bundle.validateFreshLayout()
        let paths = bundle.paths(for: plan.operationID)
        if FileManager.default.fileExists(atPath: paths.report.path) {
            return try validatedReport(try read(paths.report), plan: plan)
        }
        guard !FileManager.default.fileExists(atPath: paths.directory.path)
        else { throw CodexGhostRepairError.recoveryRequired }
        try FileManager.default.createDirectory(
            at: paths.directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let before = try inspect(plan: plan)
        guard matchesInitial(before, plan: plan) else {
            let report = makeReport(
                plan: plan,
                outcome: .notAttempted,
                durableClaimCreated: false,
                mutationAttemptedOnce: false,
                recoveredByReadback: false,
                readOnlyDatabasesUnchanged: true
            )
            try write(report, to: paths.report)
            return report
        }
        let claim = CodexGhostRepairBulkExecutionClaim(
            operationID: plan.operationID,
            planDigest: plan.planDigest,
            confirmationReceiptDigest: plan.confirmationReceiptDigest,
            executionAtMilliseconds: nowMilliseconds(),
            beforeState: before,
            claimedAtMilliseconds: nowMilliseconds()
        )
        try write(claim, to: paths.claim)
        if fault == .afterClaim {
            throw CodexGhostRepairError.injectedInterruption
        }
        let attempt = CodexGhostRepairBulkExecutionAttempt(
            operationID: plan.operationID,
            planDigest: plan.planDigest,
            claimDigest: try CodexGhostRepairHasher.hash(claim),
            attemptedAtMilliseconds: nowMilliseconds()
        )
        try write(attempt, to: paths.attempt)
        do {
            if fault == .explicitBusyBeforeTransaction {
                throw CodexGhostRepairError.sqlite(
                    operation: "begin",
                    code: SQLITE_BUSY,
                    message: "deterministic M4c busy"
                )
            }
            try apply(plan: plan, claim: claim)
        } catch {
            let observed = try? inspect(plan: plan)
            let unchanged = observed == claim.beforeState
            let report = makeReport(
                plan: plan,
                outcome: unchanged ? .explicitFailure : .unknown,
                durableClaimCreated: true,
                mutationAttemptedOnce: true,
                recoveredByReadback: true,
                readOnlyDatabasesUnchanged: observed.map {
                    $0.readOnlyDatabaseHashes
                        == claim.beforeState.readOnlyDatabaseHashes
                } ?? false
            )
            try write(report, to: paths.report)
            return report
        }
        if fault == .afterCommitBeforeReport {
            throw CodexGhostRepairError.injectedInterruption
        }
        return try finishByReadback(plan: plan, claim: claim, paths: paths)
    }

    func recoverByReadback(
        plan: CodexGhostRepairBulkExecutionPlan
    ) throws -> CodexGhostRepairBulkDisposableReport {
        try plan.validateDigest()
        try bundle.validateFreshLayout()
        let paths = bundle.paths(for: plan.operationID)
        if FileManager.default.fileExists(atPath: paths.report.path) {
            return try validatedReport(try read(paths.report), plan: plan)
        }
        let claim: CodexGhostRepairBulkExecutionClaim = try read(paths.claim)
        guard claim.operationID == plan.operationID,
              claim.planDigest == plan.planDigest,
              claim.confirmationReceiptDigest
                == plan.confirmationReceiptDigest else {
            throw CodexGhostRepairError.invalidPlan(
                "M4c claim does not match the frozen whole batch."
            )
        }
        let attempted = FileManager.default.fileExists(atPath: paths.attempt.path)
        if attempted {
            let attempt: CodexGhostRepairBulkExecutionAttempt = try read(
                paths.attempt
            )
            guard attempt.operationID == plan.operationID,
                  attempt.planDigest == plan.planDigest,
                  attempt.claimDigest
                    == (try CodexGhostRepairHasher.hash(claim)) else {
                throw CodexGhostRepairError.invalidPlan(
                    "M4c attempt does not match the durable claim."
                )
            }
        }
        let observed = try inspect(plan: plan)
        let outcome: CodexGhostRepairCategoryABatchOutcome
        if matchesFinal(observed, plan: plan, claim: claim) {
            outcome = .success
        } else if observed == claim.beforeState {
            outcome = attempted ? .explicitFailure : .notAttempted
        } else {
            outcome = .unknown
        }
        let report = makeReport(
            plan: plan,
            outcome: outcome,
            durableClaimCreated: true,
            mutationAttemptedOnce: attempted,
            recoveredByReadback: true,
            readOnlyDatabasesUnchanged:
                observed.readOnlyDatabaseHashes
                    == claim.beforeState.readOnlyDatabaseHashes
        )
        try write(report, to: paths.report)
        return report
    }

    private func finishByReadback(
        plan: CodexGhostRepairBulkExecutionPlan,
        claim: CodexGhostRepairBulkExecutionClaim,
        paths: CodexGhostRepairBulkDisposableBundle.EvidencePaths
    ) throws -> CodexGhostRepairBulkDisposableReport {
        let after = try inspect(plan: plan)
        let report = makeReport(
            plan: plan,
            outcome: matchesFinal(after, plan: plan, claim: claim)
                ? .success : .unknown,
            durableClaimCreated: true,
            mutationAttemptedOnce: true,
            recoveredByReadback: true,
            readOnlyDatabasesUnchanged:
                after.readOnlyDatabaseHashes
                    == claim.beforeState.readOnlyDatabaseHashes
        )
        try write(report, to: paths.report)
        return report
    }

    private func apply(
        plan: CodexGhostRepairBulkExecutionPlan,
        claim: CodexGhostRepairBulkExecutionClaim
    ) throws {
        let database = try M4cSQLite(url: bundle.desktopURL, readOnly: false)
        defer { database.close() }
        try database.execute("BEGIN IMMEDIATE")
        do {
            let transactionState = try inspect(
                plan: plan,
                desktopDatabase: database
            )
            guard transactionState == claim.beforeState else {
                throw CodexGhostRepairError.targetDrift(
                    "M4c transaction state drifted from its durable claim."
                )
            }
            for item in plan.selectedItems {
                try database.execute(
                    "DELETE FROM local_thread_catalog "
                        + "WHERE host_id = 'local' AND thread_id = ?",
                    bindings: [.text(item.threadID)]
                )
                guard database.changeCount == 1 else {
                    throw CodexGhostRepairError.targetDrift(
                        "M4c exact catalog row count drifted."
                    )
                }
                if item.category == .automation {
                    try database.execute(
                        "UPDATE automation_runs SET status = 'ARCHIVED', "
                            + "archived_reason = 'auto', updated_at = ? "
                            + "WHERE thread_id = ?",
                        bindings: [
                            .integer(claim.executionAtMilliseconds),
                            .text(item.threadID),
                        ]
                    )
                    guard database.changeCount == 1 else {
                        throw CodexGhostRepairError.targetDrift(
                            "M4c exact automation row count drifted."
                        )
                    }
                }
            }
            let increment = Int64(plan.selectedItems.count)
            try database.execute(
                "UPDATE local_thread_catalog_metadata "
                    + "SET catalog_revision = ? "
                    + "WHERE id = 1 AND catalog_revision = ?",
                bindings: [
                    .integer(plan.authority.catalogRevision + increment),
                    .integer(plan.authority.catalogRevision),
                ]
            )
            guard database.changeCount == 1 else {
                throw CodexGhostRepairError.authorityDrift
            }
            try database.execute(
                "UPDATE local_thread_catalog_sync_state "
                    + "SET observation_sequence = ? "
                    + "WHERE host_id = 'local' AND observation_sequence = ?",
                bindings: [
                    .integer(plan.authority.observationSequence + increment),
                    .integer(plan.authority.observationSequence),
                ]
            )
            guard database.changeCount == 1 else {
                throw CodexGhostRepairError.authorityDrift
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private func inspect(
        plan: CodexGhostRepairBulkExecutionPlan,
        desktopDatabase: M4cSQLite? = nil
    ) throws -> CodexGhostRepairBulkExecutionObservedState {
        try bundle.validateFreshLayout()
        let ownsDesktop = desktopDatabase == nil
        let desktop = try desktopDatabase
            ?? M4cSQLite(url: bundle.databaseURL(.desktop), readOnly: true)
        defer { if ownsDesktop { desktop.close() } }
        let summaries = try M4cSQLite(
            url: bundle.databaseURL(.summaries), readOnly: true
        )
        let state = try M4cSQLite(
            url: bundle.databaseURL(.state), readOnly: true
        )
        let history = try M4cSQLite(
            url: bundle.databaseURL(.threadHistory), readOnly: true
        )
        defer {
            summaries.close()
            state.close()
            history.close()
        }
        let databases: [(CodexGhostRepairSnapshotAnalysisDatabase, M4cSQLite)] = [
            (.desktop, desktop), (.summaries, summaries),
            (.state, state), (.threadHistory, history),
        ]
        let databaseEvidence = try databases.map { database, handle in
            CodexGhostRepairSnapshotAnalysisDatabaseEvidence(
                database: database,
                schemaVersion: try handle.schemaVersion(),
                integrityCheckPassed: try handle.integrityPassed(),
                foreignKeyViolationCount:
                    try handle.foreignKeyViolationCount()
            )
        }
        let items = try plan.selectedItems.map { frozen in
            try observedItem(
                frozen: frozen,
                desktop: desktop,
                summaries: summaries,
                state: state,
                history: history
            )
        }
        let metadata = try desktop.singleRow(
            "SELECT * FROM local_thread_catalog_metadata WHERE id = 1"
        )
        let sync = try desktop.singleRow(
            "SELECT * FROM local_thread_catalog_sync_state "
                + "WHERE host_id = 'local'"
        )
        guard case let .integer(revision)? = metadata.value(
                  named: "catalog_revision"
              ),
              case let .integer(sequence)? = sync.value(
                  named: "observation_sequence"
              ) else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M4c authority rows are unavailable."
            )
        }
        let watermark: Double?
        switch sync.value(named: "watermark_updated_at") {
        case let .integer(value): watermark = Double(value)
        case let .real(value): watermark = value
        case .null: watermark = nil
        default:
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M4c watermark evidence is invalid."
            )
        }
        var readOnlyHashes: [String: String] = [:]
        for database in CodexGhostRepairSnapshotAnalysisDatabase.allCases
            where database != .desktop {
            readOnlyHashes[database.rawValue] = try fileHash(
                bundle.databaseURL(database)
            )
        }
        return .init(
            items: items,
            authority: .init(
                catalogRevision: revision,
                observationSequence: sequence,
                watermarkUpdatedAt: watermark,
                metadataRowDigest: try CodexGhostRepairHasher.hash(metadata),
                localSyncRowDigest: try CodexGhostRepairHasher.hash(sync)
            ),
            databaseEvidence: databaseEvidence,
            readOnlyDatabaseHashes: readOnlyHashes
        )
    }

    private func observedItem(
        frozen: CodexGhostRepairBulkExecutionFrozenItem,
        desktop: M4cSQLite,
        summaries: M4cSQLite,
        state: M4cSQLite,
        history: M4cSQLite
    ) throws -> CodexGhostRepairBulkExecutionObservedItem {
        let catalog = try desktop.rows(
            "SELECT * FROM local_thread_catalog "
                + "WHERE thread_id = ? ORDER BY host_id",
            bindings: [.text(frozen.threadID)],
            maximumRows: 2
        )
        let automation = try desktop.rows(
            "SELECT * FROM automation_runs "
                + "WHERE thread_id = ? ORDER BY automation_id",
            bindings: [.text(frozen.threadID)],
            maximumRows: 2
        )
        var definitions: [CodexGhostRepairSQLiteRow] = []
        for row in automation {
            guard case let .text(automationID)? = row.value(
                named: "automation_id"
            ) else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "M4c automation identity is invalid."
                )
            }
            definitions += try desktop.rows(
                "SELECT * FROM automations WHERE id = ? ORDER BY id",
                bindings: [.text(automationID)],
                maximumRows: 2
            )
        }
        guard catalog.count <= 1, automation.count <= 1,
              definitions.count <= 1 else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M4c target row multiplicity exceeded one."
            )
        }
        let references = try desktop.count(
            "SELECT count(*) FROM inbox_items WHERE thread_id = ?",
            frozen.threadID
        ) + desktop.count(
            "SELECT count(*) FROM thread_timeline_ledger WHERE thread_id = ?",
            frozen.threadID
        ) + summaries.count(
            "SELECT count(*) FROM thread_turn_summaries WHERE thread_id = ?",
            frozen.threadID
        ) + state.count(
            "SELECT count(*) FROM threads WHERE id = ?",
            frozen.threadID
        ) + history.count(
            "SELECT count(*) FROM thread_turns WHERE thread_id = ?",
            frozen.threadID
        ) + history.count(
            "SELECT count(*) FROM thread_items WHERE thread_id = ?",
            frozen.threadID
        ) + history.count(
            "SELECT count(*) FROM thread_history_projection_state "
                + "WHERE thread_id = ?",
            frozen.threadID
        )
        let automationRow = automation.first
        return .init(
            threadID: frozen.threadID,
            category: frozen.category,
            catalogRowDigest: try catalog.first.map {
                try CodexGhostRepairBulkTargetEvidenceContract
                    .catalogAuthorizationDigest($0)
            },
            automationRunRowDigest: try automationRow.map {
                try CodexGhostRepairHasher.hash($0)
            },
            automationStableFieldsDigest: try automationRow.map {
                try CodexGhostRepairBulkTargetEvidenceContract
                    .automationIdentityDigest($0)
            },
            automationStatus: text(automationRow, "status"),
            automationArchivedReason: text(automationRow, "archived_reason"),
            automationUpdatedAt: integer(automationRow, "updated_at"),
            automationDefinitionRowDigest: try definitions.first.map {
                try CodexGhostRepairBulkTargetEvidenceContract
                    .automationDefinitionAuthorizationDigest($0)
            },
            referenceCount: references
        )
    }

    private func matchesInitial(
        _ state: CodexGhostRepairBulkExecutionObservedState,
        plan: CodexGhostRepairBulkExecutionPlan
    ) -> Bool {
        guard state.authority == plan.authority,
              state.databaseEvidence == plan.databases,
              state.items.count == plan.selectedItems.count,
              state.databaseEvidence.allSatisfy({
                  $0.integrityCheckPassed
                      && $0.foreignKeyViolationCount == 0
              }) else { return false }
        return zip(state.items, plan.selectedItems).allSatisfy {
            observed, frozen in
            observed.threadID == frozen.threadID
                && observed.category == frozen.category
                && observed.catalogRowDigest == frozen.catalogRowDigest
                && observed.automationStableFieldsDigest
                    == frozen.automationStableFieldsDigest
                && observed.automationDefinitionRowDigest
                    == frozen.automationDefinitionRowDigest
                && observed.referenceCount == 0
                && initialAutomationShape(observed)
        }
    }

    private func initialAutomationShape(
        _ item: CodexGhostRepairBulkExecutionObservedItem
    ) -> Bool {
        switch item.category {
        case .ordinary:
            item.automationRunRowDigest == nil
                && item.automationStableFieldsDigest == nil
                && item.automationDefinitionRowDigest == nil
        case .automation:
            item.automationRunRowDigest != nil
                && item.automationStableFieldsDigest != nil
                && ["ACCEPTED", "PENDING_REVIEW"]
                    .contains(item.automationStatus)
                && item.automationArchivedReason == nil
                && item.automationDefinitionRowDigest != nil
        }
    }

    private func matchesFinal(
        _ state: CodexGhostRepairBulkExecutionObservedState,
        plan: CodexGhostRepairBulkExecutionPlan,
        claim: CodexGhostRepairBulkExecutionClaim
    ) -> Bool {
        let increment = Int64(plan.selectedItems.count)
        guard state.databaseEvidence == claim.beforeState.databaseEvidence,
              state.readOnlyDatabaseHashes
                == claim.beforeState.readOnlyDatabaseHashes,
              state.authority.catalogRevision
                == claim.beforeState.authority.catalogRevision + increment,
              state.authority.observationSequence
                == claim.beforeState.authority.observationSequence + increment,
              state.authority.watermarkUpdatedAt
                == claim.beforeState.authority.watermarkUpdatedAt,
              state.items.count == claim.beforeState.items.count,
              state.items.count == plan.selectedItems.count else {
            return false
        }
        return zip(
            zip(state.items, claim.beforeState.items), plan.selectedItems
        ).allSatisfy { pair, frozen in
            let (after, before) = pair
            guard after.threadID == before.threadID,
                  after.threadID == frozen.threadID,
                  after.category == before.category,
                  after.category == frozen.category,
                  after.catalogRowDigest == nil,
                  after.referenceCount == 0 else { return false }
            switch after.category {
            case .ordinary:
                return after.automationRunRowDigest == nil
                    && after.automationDefinitionRowDigest == nil
            case .automation:
                return after.automationRunRowDigest != nil
                    && after.automationRunRowDigest
                        != before.automationRunRowDigest
                    && after.automationStableFieldsDigest
                        == frozen.automationStableFieldsDigest
                    && after.automationStatus == "ARCHIVED"
                    && after.automationArchivedReason == "auto"
                    && after.automationUpdatedAt
                        == claim.executionAtMilliseconds
                    && after.automationDefinitionRowDigest
                        == before.automationDefinitionRowDigest
            }
        }
    }

    private func makeReport(
        plan: CodexGhostRepairBulkExecutionPlan,
        outcome: CodexGhostRepairCategoryABatchOutcome,
        durableClaimCreated: Bool,
        mutationAttemptedOnce: Bool,
        recoveredByReadback: Bool,
        readOnlyDatabasesUnchanged: Bool
    ) -> CodexGhostRepairBulkDisposableReport {
        .init(
            operationID: plan.operationID,
            planDigest: plan.planDigest,
            confirmationReceiptDigest: plan.confirmationReceiptDigest,
            completedAtMilliseconds: nowMilliseconds(),
            outcome: outcome,
            items: plan.selectedItems.map {
                .init(
                    threadID: $0.threadID,
                    category: $0.category,
                    outcome: outcome.itemOutcome
                )
            },
            durableClaimCreated: durableClaimCreated,
            mutationAttemptedOnce: mutationAttemptedOnce,
            recoveredByReadback: recoveredByReadback,
            readOnlyDatabasesUnchanged: readOnlyDatabasesUnchanged,
            automaticRetryAllowed: false,
            liveCodexRootAccessed: false,
            appRepairAuthority: false
        )
    }

    private func validatedReport(
        _ report: CodexGhostRepairBulkDisposableReport,
        plan: CodexGhostRepairBulkExecutionPlan
    ) throws -> CodexGhostRepairBulkDisposableReport {
        guard report.operationID == plan.operationID,
              report.planDigest == plan.planDigest,
              report.confirmationReceiptDigest
                == plan.confirmationReceiptDigest,
              report.items.map(\.threadID) == plan.selectedThreadIDs,
              !report.automaticRetryAllowed,
              !report.liveCodexRootAccessed,
              !report.appRepairAuthority else {
            throw CodexGhostRepairError.invalidPlan(
                "M4c Report does not match the exact whole batch."
            )
        }
        return report
    }

    private func text(
        _ row: CodexGhostRepairSQLiteRow?,
        _ name: String
    ) -> String? {
        guard case let .text(value)? = row?.value(named: name) else {
            return nil
        }
        return value
    }

    private func integer(
        _ row: CodexGhostRepairSQLiteRow?,
        _ name: String
    ) -> Int64? {
        guard case let .integer(value)? = row?.value(named: name) else {
            return nil
        }
        return value
    }

    private func fileHash(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func write<T: Codable & Hashable>(_ payload: T, to url: URL)
        throws
    {
        let envelope = try M4cEnvelope(payload: payload)
        let data = try JSONEncoder.sorted.encode(envelope)
        try data.write(to: url, options: [.atomic])
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4c evidence permissions could not be fixed."
            )
        }
    }

    private func read<T: Codable & Hashable>(_ url: URL) throws -> T {
        let envelope = try JSONDecoder().decode(
            M4cEnvelope<T>.self,
            from: Data(contentsOf: url)
        )
        guard try CodexGhostRepairHasher.hash(envelope.payload)
                == envelope.payloadHash else {
            throw CodexGhostRepairError.invalidPlan(
                "M4c durable evidence checksum mismatch."
            )
        }
        return envelope.payload
    }
}

private struct M4cEnvelope<Payload: Codable & Hashable>: Codable, Hashable {
    let payload: Payload
    let payloadHash: String

    init(payload: Payload) throws {
        self.payload = payload
        payloadHash = try CodexGhostRepairHasher.hash(payload)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private enum M4cBinding {
    case integer(Int64)
    case text(String)
}

private final class M4cSQLite {
    private var database: OpaquePointer?

    init(url: URL, readOnly: Bool) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              database != nil else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M4c fixed database could not be opened."
            )
        }
        sqlite3_busy_timeout(database, 0)
    }

    var changeCount: Int { Int(sqlite3_changes(database)) }

    func close() {
        if let database { sqlite3_close_v2(database) }
        database = nil
    }

    func execute(_ sql: String, bindings: [M4cBinding] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError("execute")
        }
    }

    func rows(
        _ sql: String,
        bindings: [M4cBinding] = [],
        maximumRows: Int
    ) throws -> [CodexGhostRepairSQLiteRow] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [CodexGhostRepairSQLiteRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, result.count < maximumRows else {
                throw sqliteError("query")
            }
            var fields: [CodexGhostRepairSQLiteField] = []
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(
                    cString: sqlite3_column_name(statement, index)
                )
                let value: CodexGhostRepairSQLiteValue
                switch sqlite3_column_type(statement, index) {
                case SQLITE_NULL: value = .null
                case SQLITE_INTEGER:
                    value = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    value = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    value = sqlite3_column_text(statement, index).map {
                        .text(String(cString: $0))
                    } ?? .null
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    value = sqlite3_column_blob(statement, index).map {
                        .blob(Data(bytes: $0, count: count))
                    } ?? .blob(Data())
                default:
                    throw sqliteError("column")
                }
                fields.append(.init(name: name, value: value))
            }
            result.append(.init(fields: fields))
        }
        return result
    }

    func singleRow(_ sql: String) throws -> CodexGhostRepairSQLiteRow {
        let result = try rows(sql, maximumRows: 2)
        guard result.count == 1 else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M4c fixed query did not return one row."
            )
        }
        return result[0]
    }

    func count(_ sql: String, _ value: String) throws -> Int {
        let result = try rows(
            sql,
            bindings: [.text(value)],
            maximumRows: 1
        )
        guard result.count == 1,
              case let .integer(count)? = result[0].fields.first?.value,
              count >= 0, count <= Int64(Int.max) else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M4c reference count is invalid."
            )
        }
        return Int(count)
    }

    func schemaVersion() throws -> Int32 {
        let result = try rows("PRAGMA user_version", maximumRows: 1)
        guard result.count == 1,
              case let .integer(version)? = result[0].fields.first?.value
        else { throw sqliteError("schema") }
        return Int32(version)
    }

    func integrityPassed() throws -> Bool {
        let result = try rows("PRAGMA integrity_check", maximumRows: 2)
        return result.count == 1
            && result[0].fields.first?.value == .text("ok")
    }

    func foreignKeyViolationCount() throws -> Int {
        try rows("PRAGMA foreign_key_check", maximumRows: 1).count
    }

    private func prepare(
        _ sql: String,
        bindings: [M4cBinding]
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else { throw sqliteError("prepare") }
        do {
            for (offset, binding) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let code: Int32
                switch binding {
                case let .integer(value):
                    code = sqlite3_bind_int64(statement, index, value)
                case let .text(value):
                    code = value.withCString {
                        sqlite3_bind_text(
                            statement,
                            index,
                            $0,
                            -1,
                            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                        )
                    }
                }
                guard code == SQLITE_OK else { throw sqliteError("bind") }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func sqliteError(_ operation: String) -> CodexGhostRepairError {
        CodexGhostRepairError.sqlite(
            operation: operation,
            code: sqlite3_errcode(database),
            message: database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown"
        )
    }
}
