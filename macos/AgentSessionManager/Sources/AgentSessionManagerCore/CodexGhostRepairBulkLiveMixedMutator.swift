import CSQLite3
import Foundation

enum CodexGhostRepairBulkLiveMixedMutationFault: Sendable {
    case none
    case explicitBusyBeforeTransaction
    case afterCommitBeforeReadback
    case afterSummaryRemoval
}

struct CodexGhostRepairBulkLiveMixedMutatorCapabilities:
    Equatable,
    Sendable
{
    let productionFactoryAvailable = true
    let productionConstructionPerformsIO = false
    let productionFactoryAcceptsCallerPath = false
    let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems
    let exactBackupBoundPlanRequired = true
    let exactVerifiedBackupReadbackRequired = true
    let durableExternalClaimAndAttemptRequired = true
    let freshOperationalGateRequired = true
    let singleDesktopTransaction = true
    let mixedOrdinaryAndAutomation = true
    let readbackOnlyDatabaseCount = 4
    let automaticRetryAllowed = false
    let automaticRestoreAllowed = false
    let appWiringAvailable = false
    let liveExecutionAuthorized = false
    let repairMutationAuthority = false
}

private struct CodexGhostRepairBulkLiveMixedClaimPayload:
    Codable,
    Hashable
{
    let claimID: UUID
    let requestID: UUID
    let planDigest: String
    let backupReceiptDigest: String
    let selectedThreadIDs: [String]
    let claimedAtMilliseconds: Int64
}

struct CodexGhostRepairBulkLiveMixedClaim:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let claimID: UUID
    let requestID: UUID
    let planDigest: String
    let backupReceiptDigest: String
    let selectedThreadIDs: [String]
    let claimedAtMilliseconds: Int64
    let claimDigest: String

    var attemptOrdinal: Int { 0 }
    var automaticRetryAllowed: Bool { false }
    var automaticRestoreAllowed: Bool { false }

    init(
        claimID: UUID,
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        claimedAtMilliseconds: Int64
    ) throws {
        try plan.validate()
        let payload = CodexGhostRepairBulkLiveMixedClaimPayload(
            claimID: claimID,
            requestID: plan.requestID,
            planDigest: plan.planDigest,
            backupReceiptDigest: plan.backup.receiptDigest,
            selectedThreadIDs: plan.selectedThreadIDs,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
        self.claimID = claimID
        requestID = payload.requestID
        planDigest = payload.planDigest
        backupReceiptDigest = payload.backupReceiptDigest
        selectedThreadIDs = payload.selectedThreadIDs
        self.claimedAtMilliseconds = claimedAtMilliseconds
        claimDigest = try CodexGhostRepairHasher.hash(payload)
        try validate(plan: plan)
    }

    func validate(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan
    ) throws {
        let payload = CodexGhostRepairBulkLiveMixedClaimPayload(
            claimID: claimID,
            requestID: requestID,
            planDigest: planDigest,
            backupReceiptDigest: backupReceiptDigest,
            selectedThreadIDs: selectedThreadIDs,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
        guard requestID == plan.requestID,
              planDigest == plan.planDigest,
              backupReceiptDigest == plan.backup.receiptDigest,
              selectedThreadIDs == plan.selectedThreadIDs,
              claimedAtMilliseconds >= plan.plannedAtMilliseconds,
              claimedAtMilliseconds < plan.expiresAtMilliseconds,
              try CodexGhostRepairHasher.hash(payload) == claimDigest,
              attemptOrdinal == 0,
              !automaticRetryAllowed,
              !automaticRestoreAllowed else {
            throw CodexGhostRepairError.invalidPlan(
                "M4f-17 claim does not match the exact operation plan."
            )
        }
    }
}

private struct CodexGhostRepairBulkLiveMixedAttemptPayload:
    Codable,
    Hashable
{
    let requestID: UUID
    let claimDigest: String
    let attemptedAtMilliseconds: Int64
}

struct CodexGhostRepairBulkLiveMixedAttempt:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let requestID: UUID
    let claimDigest: String
    let attemptedAtMilliseconds: Int64
    let attemptDigest: String

    var attemptOrdinal: Int { 1 }
    var automaticRetryAllowed: Bool { false }

    init(
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attemptedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairBulkLiveMixedAttemptPayload(
            requestID: claim.requestID,
            claimDigest: claim.claimDigest,
            attemptedAtMilliseconds: attemptedAtMilliseconds
        )
        requestID = claim.requestID
        claimDigest = claim.claimDigest
        self.attemptedAtMilliseconds = attemptedAtMilliseconds
        attemptDigest = try CodexGhostRepairHasher.hash(payload)
        try validate(claim: claim)
    }

    func validate(claim: CodexGhostRepairBulkLiveMixedClaim) throws {
        let payload = CodexGhostRepairBulkLiveMixedAttemptPayload(
            requestID: requestID,
            claimDigest: claimDigest,
            attemptedAtMilliseconds: attemptedAtMilliseconds
        )
        guard requestID == claim.requestID,
              claimDigest == claim.claimDigest,
              attemptedAtMilliseconds >= claim.claimedAtMilliseconds,
              try CodexGhostRepairHasher.hash(payload) == attemptDigest,
              attemptOrdinal == 1,
              !automaticRetryAllowed else {
            throw CodexGhostRepairError.invalidPlan(
                "M4f-17 attempt does not match the one-shot claim."
            )
        }
    }
}

protocol CodexGhostRepairBulkLiveMixedBackupReading: Sendable {
    func readExactBackup(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan
    ) async throws -> CodexGhostRepairBulkLiveBackupReceipt
}

extension CodexGhostRepairBulkLiveBackupTransport:
    CodexGhostRepairBulkLiveMixedBackupReading
{
    func readExactBackup(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan
    ) async throws -> CodexGhostRepairBulkLiveBackupReceipt {
        try await readExactBackup(destination: plan.destination)
    }
}

extension CodexGhostRepairBulkLiveBackupEnvironment:
    CodexGhostRepairBulkLiveMixedBackupReading
{
    func readExactBackup(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan
    ) async throws -> CodexGhostRepairBulkLiveBackupReceipt {
        try readExactBackup(destination: plan.destination)
    }
}

struct CodexGhostRepairBulkLiveMixedObservedItem: Equatable, Sendable {
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
    var summaryRowDigests: [String] = []
}

struct CodexGhostRepairBulkLiveMixedObservedState: Equatable, Sendable {
    let items: [CodexGhostRepairBulkLiveMixedObservedItem]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
}

enum CodexGhostRepairBulkFreshRecoveryObservation: Equatable, Sendable {
    case initial
    case final
    case initialAndFinal
    case indeterminate
}

/// Production-capable mixed mutator for the Shipping one-shot composition.
/// Construction is caller-path-free and zero-I/O; this type grants no live
/// execution authority by itself.
actor CodexGhostRepairBulkLiveMixedMutator {
    nonisolated let capabilities =
        CodexGhostRepairBulkLiveMixedMutatorCapabilities()

    private let bundle: CodexGhostRepairProductionRepairBundle
    private let source: CodexGhostRepairSnapshotCanonicalSource
    private let profile: CodexGhostRepairSnapshotSourceProfile
    private let gateSource: any CodexGhostRepairExecutionGateSource
    private let backupReader: any CodexGhostRepairBulkLiveMixedBackupReading
    private let fault: CodexGhostRepairBulkLiveMixedMutationFault
    private let beforeMutationForTesting: @Sendable () throws -> Void
    private let afterFreshRecoveryInspectionForTesting:
        @Sendable () throws -> Void

    static func production(
        backupReader: any CodexGhostRepairBulkLiveMixedBackupReading,
        profile: CodexGhostRepairSnapshotSourceProfile
    ) -> Self {
        Self(
            bundle: .production(),
            source: .production(profile: profile),
            profile: profile,
            gateSource: CodexGhostRepairSnapshotOperationalGateSource
                .production(),
            backupReader: backupReader,
            fault: .none,
            afterFreshRecoveryInspectionForTesting: {}
        )
    }

    init(
        testOwnedCodexHomeURL: URL,
        testOwnedAllowedParentURL: URL,
        profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32,
        gateSource: any CodexGhostRepairExecutionGateSource,
        backupReader: any CodexGhostRepairBulkLiveMixedBackupReading,
        fault: CodexGhostRepairBulkLiveMixedMutationFault = .none,
        beforeMutationForTesting: @escaping @Sendable () throws -> Void = {},
        afterFreshRecoveryInspectionForTesting:
            @escaping @Sendable () throws -> Void = {}
    ) {
        bundle = CodexGhostRepairProductionRepairBundle(
            testOwnedCodexHomeURL: testOwnedCodexHomeURL,
            testOwnedAllowedParentURL: testOwnedAllowedParentURL
        )
        source = CodexGhostRepairSnapshotCanonicalSource(
            testOwnedCodexHomeURL: testOwnedCodexHomeURL,
            testOwnedAllowedParentURL: testOwnedAllowedParentURL,
            profile: profile
        )
        self.profile = profile
        self.gateSource = gateSource
        self.backupReader = backupReader
        self.fault = fault
        self.beforeMutationForTesting = beforeMutationForTesting
        self.afterFreshRecoveryInspectionForTesting =
            afterFreshRecoveryInspectionForTesting
    }

    private init(
        bundle: CodexGhostRepairProductionRepairBundle,
        source: CodexGhostRepairSnapshotCanonicalSource,
        profile: CodexGhostRepairSnapshotSourceProfile,
        gateSource: any CodexGhostRepairExecutionGateSource,
        backupReader: any CodexGhostRepairBulkLiveMixedBackupReading,
        fault: CodexGhostRepairBulkLiveMixedMutationFault,
        afterFreshRecoveryInspectionForTesting:
            @escaping @Sendable () throws -> Void
    ) {
        self.bundle = bundle
        self.source = source
        self.profile = profile
        self.gateSource = gateSource
        self.backupReader = backupReader
        self.fault = fault
        self.beforeMutationForTesting = {}
        self.afterFreshRecoveryInspectionForTesting =
            afterFreshRecoveryInspectionForTesting
    }

    func executeOnce(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt
    ) async throws -> CodexGhostRepairCategoryABatchOutcome {
        try Self.validate(plan: plan, claim: claim, attempt: attempt)
        let backup = try await backupReader.readExactBackup(plan: plan)
        guard backup == plan.backup else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-17 verified backup readback drifted."
            )
        }
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .notAttempted
        }
        let beforeFingerprint = try source.fingerprint()
        try beforeFingerprint.validateHash()
        guard backup.firstStableSourceMismatch(in: beforeFingerprint) == nil
        else {
            return .notAttempted
        }
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .notAttempted
        }
        let resolution = try bundle.resolveForPreflight()
        do {
            try CodexGhostRepairFreshPinProtection.requireUnpinned(
                plan.selectedThreadIDs, codexHomeURL: resolution.codexHomeURL
            )
        } catch {
            return .notAttempted
        }
        let before = try Self.inspect(
            selectedItems: plan.selectedItems,
            resolution: resolution
        )
        guard Self.matchesInitial(before, plan: plan) else {
            return .notAttempted
        }

        do {
            if fault == .explicitBusyBeforeTransaction {
                throw CodexGhostRepairError.sqlite(
                    operation: "begin", code: SQLITE_BUSY,
                    message: "Deterministic M4f-17 busy fault."
                )
            }
            let desktop = try CodexGhostRepairProductionSQLite(
                url: resolution.databaseURL(for: .desktop), readOnly: false
            )
            defer { desktop.close() }
            let clearsSummaries = plan.selectedItems.contains {
                !($0.reviewedResidue?.summaryRowDigests.isEmpty ?? true)
            }
            if clearsSummaries {
                // Fixed, already-resolved source only. No caller-supplied path.
                try desktop.execute("ATTACH DATABASE ? AS reviewed_summaries", bindings: [
                    .text(resolution.databaseURL(for: .summaries).absoluteString + "?mode=rw"),
                ])
                let triggers = try desktop.query(
                    "SELECT name FROM reviewed_summaries.sqlite_master WHERE type = 'trigger'",
                    maximumRows: 1
                )
                guard triggers.isEmpty else {
                    throw CodexGhostRepairError.invalidDatabaseContract("Summary triggers are outside the reviewed cleanup contract.")
                }
            }
            try desktop.execute("BEGIN IMMEDIATE")
            do {
                let transactionBefore = try Self.inspect(
                    selectedItems: plan.selectedItems,
                    resolution: resolution,
                    desktopDatabase: desktop,
                    summaryTransaction: clearsSummaries ? desktop : nil
                )
                guard transactionBefore == before else {
                    try desktop.execute("ROLLBACK")
                    return .notAttempted
                }
                do {
                    try beforeMutationForTesting()
                    try CodexGhostRepairFreshPinProtection.requireUnpinned(
                        plan.selectedThreadIDs, codexHomeURL: resolution.codexHomeURL
                    )
                } catch {
                    try desktop.execute("ROLLBACK")
                    return .notAttempted
                }
                try Self.apply(
                    database: desktop,
                    plan: plan,
                    executionAtMilliseconds: claim.claimedAtMilliseconds,
                    failAfterSummaryRemoval: fault == .afterSummaryRemoval
                )
                let after = try Self.inspect(
                    selectedItems: plan.selectedItems,
                    resolution: resolution,
                    desktopDatabase: desktop,
                    summaryTransaction: clearsSummaries ? desktop : nil
                )
                guard Self.matchesFinal(
                    after,
                    beforeAuthority: before.authority,
                    plan: plan,
                    executionAtMilliseconds: claim.claimedAtMilliseconds
                ) else {
                    throw CodexGhostRepairError.targetDrift(
                        "M4f-17 transaction readback was not exact."
                    )
                }
                try desktop.execute("COMMIT")
            } catch {
                try? desktop.execute("ROLLBACK")
                throw error
            }
            if fault == .afterCommitBeforeReadback {
                throw CodexGhostRepairError.injectedInterruption
            }
        } catch {
            return try await classifyByReadback(
                plan: plan, claim: claim, backup: backup
            )
        }
        return try await classifyByReadback(
            plan: plan, claim: claim, backup: backup
        )
    }

    func recoverByReadback(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt
    ) async throws -> CodexGhostRepairCategoryABatchOutcome {
        try Self.validate(plan: plan, claim: claim, attempt: attempt)
        let backup = try await backupReader.readExactBackup(plan: plan)
        guard backup == plan.backup else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-17 verified backup readback drifted."
            )
        }
        return try await classifyByReadback(
            plan: plan, claim: claim, backup: backup
        )
    }

    /// Reads only the exact frozen operation state. Validation failures stay
    /// non-terminal so missing gate/profile/schema evidence is never laundered
    /// into an `unknown` Report.
    func inspectFreshRecoveryByReadback(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt?
    ) async throws -> CodexGhostRepairBulkFreshRecoveryObservation {
        try plan.validate()
        try claim.validate(plan: plan)
        if let attempt { try attempt.validate(claim: claim) }
        guard profile.identifier == plan.sourceLayoutIdentifier else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Fresh recovery source profile does not match the frozen plan."
            )
        }
        let backup = try await backupReader.readExactBackup(plan: plan)
        guard backup == plan.backup else {
            throw CodexGhostRepairError.backupFailed(
                "Fresh recovery backup readback drifted."
            )
        }
        let beforeGate = try await gateSource.ghostRepairExecutionGate()
        guard Self.freshRecoveryGateIsComplete(beforeGate) else {
            throw CodexGhostRepairError.executionGateBlocked
        }
        let beforeFingerprint = try source.fingerprint()
        try beforeFingerprint.validateHash()
        guard Self.readbackOnlyFilesUnchanged(
            backup: backup,
            after: beforeFingerprint, plan: plan
        ) else {
            throw CodexGhostRepairError.targetDrift(
                "Fresh recovery source changed outside the exact mutable database."
            )
        }
        let observed = try Self.inspect(
            selectedItems: plan.selectedItems,
            resolution: bundle.resolveForPreflight()
        )
        guard profile.admits(databases: observed.databases),
              observed.databases.allSatisfy({
                  $0.integrityCheckPassed && $0.foreignKeyViolationCount == 0
              }) else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Fresh recovery database schema no longer matches the frozen source profile."
            )
        }
        try afterFreshRecoveryInspectionForTesting()
        let afterFingerprint = try source.fingerprint()
        try afterFingerprint.validateHash()
        guard Self.freshRecoveryFingerprintsStable(
            before: beforeFingerprint,
            after: afterFingerprint
        ) else {
            throw CodexGhostRepairError.targetDrift(
                "Fresh recovery source changed during target inspection."
            )
        }
        guard Self.readbackOnlyFilesUnchanged(
            backup: backup,
            after: afterFingerprint, plan: plan
        ) else {
            throw CodexGhostRepairError.targetDrift(
                "Fresh recovery source changed during readback."
            )
        }
        let afterGate = try await gateSource.ghostRepairExecutionGate()
        guard Self.freshRecoveryGateIsComplete(afterGate) else {
            throw CodexGhostRepairError.executionGateBlocked
        }
        let initial = Self.matchesInitial(observed, plan: plan)
        let final = Self.matchesFinal(
            observed,
            beforeAuthority: plan.authority,
            plan: plan,
            executionAtMilliseconds: claim.claimedAtMilliseconds
        )
        switch (initial, final) {
        case (true, true): return .initialAndFinal
        case (true, false): return .initial
        case (false, true): return .final
        case (false, false): return .indeterminate
        }
    }

    private static func freshRecoveryGateIsComplete(
        _ gate: CodexGhostRepairExecutionGate
    ) -> Bool {
        gate.isClear
            && gate.stateOpenHandleCount == 0
            && gate.threadHistoryOpenHandleCount == 0
    }

    private func classifyByReadback(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        backup: CodexGhostRepairBulkLiveBackupReceipt
    ) async throws -> CodexGhostRepairCategoryABatchOutcome {
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .unknown
        }
        let observed = try Self.inspect(
            selectedItems: plan.selectedItems,
            resolution: bundle.resolveForPreflight()
        )
        let afterFingerprint = try source.fingerprint()
        try afterFingerprint.validateHash()
        guard Self.readbackOnlyFilesUnchanged(
            backup: backup, after: afterFingerprint, plan: plan
        ) else { return .unknown }
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .unknown
        }
        if Self.matchesFinal(
            observed,
            beforeAuthority: plan.authority,
            plan: plan,
            executionAtMilliseconds: claim.claimedAtMilliseconds
        ) { return .success }
        if Self.matchesInitial(observed, plan: plan) {
            return .explicitFailure
        }
        return .unknown
    }

    private static func validate(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        claim: CodexGhostRepairBulkLiveMixedClaim,
        attempt: CodexGhostRepairBulkLiveMixedAttempt
    ) throws {
        try plan.validate()
        try claim.validate(plan: plan)
        try attempt.validate(claim: claim)
        guard claim.requestID == plan.requestID,
              attempt.requestID == plan.requestID,
              plan.allOrNothing,
              !plan.silentSelectionShrinkAllowed,
              !claim.automaticRetryAllowed,
              !claim.automaticRestoreAllowed,
              !attempt.automaticRetryAllowed else {
            throw CodexGhostRepairError.invalidPlan(
                "M4f-17 inputs do not form one exact attempt."
            )
        }
    }

    static func inspect(
        selectedItems: [CodexGhostRepairBulkBackupBoundOperationItem],
        resolution: CodexGhostRepairProductionRepairBundle.Resolution,
        desktopDatabase: CodexGhostRepairProductionSQLite? = nil,
        summaryTransaction: CodexGhostRepairProductionSQLite? = nil
    ) throws -> CodexGhostRepairBulkLiveMixedObservedState {
        let ownsDesktop = desktopDatabase == nil
        let desktop = try desktopDatabase ?? CodexGhostRepairProductionSQLite(
            url: resolution.databaseURL(for: .desktop), readOnly: true
        )
        defer { if ownsDesktop { desktop.close() } }
        let summaries = try CodexGhostRepairProductionSQLite(
            url: resolution.databaseURL(for: .summaries), readOnly: true
        )
        let state = try CodexGhostRepairProductionSQLite(
            url: resolution.databaseURL(for: .state), readOnly: true
        )
        let history = try CodexGhostRepairProductionSQLite(
            url: resolution.databaseURL(for: .threadHistory), readOnly: true
        )
        defer { summaries.close(); state.close(); history.close() }
        let handles: [
            (CodexGhostRepairSnapshotAnalysisDatabase,
             CodexGhostRepairProductionSQLite)
        ] = [
            (.desktop, desktop), (.summaries, summaries),
            (.state, state), (.threadHistory, history),
        ]
        let databases = try handles.map { database, handle in
            CodexGhostRepairSnapshotAnalysisDatabaseEvidence(
                database: database,
                schemaVersion: try handle.schemaVersion(),
                integrityCheckPassed: try handle.integrityPassed(),
                foreignKeyViolationCount: try handle.foreignKeyViolationCount()
            )
        }
        let items = try selectedItems.map {
            try observedItem(
                frozen: $0, desktop: desktop, summaries: summaryTransaction ?? summaries,
                state: state, history: history,
                summaryPrefix: summaryTransaction == nil ? "" : "reviewed_summaries."
            )
        }
        let metadataRows = try desktop.query(
            "SELECT * FROM local_thread_catalog_metadata WHERE id = 1",
            maximumRows: 2
        )
        let syncRows = try desktop.query(
            "SELECT * FROM local_thread_catalog_sync_state "
                + "WHERE host_id = 'local'",
            maximumRows: 2
        )
        guard metadataRows.count == 1, syncRows.count == 1,
              case let .integer(revision)? = metadataRows[0].value(
                  named: "catalog_revision"
              ),
              case let .integer(sequence)? = syncRows[0].value(
                  named: "observation_sequence"
              ) else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M4f-17 authority rows are unavailable."
            )
        }
        let metadata = try metadataRows[0].privacyPreserving(
            cleartextFields: CodexGhostRepairPrivacyContract.metadata
        )
        let sync = try syncRows[0].privacyPreserving(
            cleartextFields: CodexGhostRepairPrivacyContract.localSync
        )
        let watermark: Double?
        switch sync.value(named: "watermark_updated_at") {
        case let .integer(value): watermark = Double(value)
        case let .real(value): watermark = value
        case .null: watermark = nil
        default:
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M4f-17 watermark evidence is invalid."
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
            databases: databases
        )
    }

    private static func observedItem(
        frozen: CodexGhostRepairBulkBackupBoundOperationItem,
        desktop: CodexGhostRepairProductionSQLite,
        summaries: CodexGhostRepairProductionSQLite,
        state: CodexGhostRepairProductionSQLite,
        history: CodexGhostRepairProductionSQLite,
        summaryPrefix: String
    ) throws -> CodexGhostRepairBulkLiveMixedObservedItem {
        let catalog = try desktop.query(
            "SELECT * FROM local_thread_catalog "
                + "WHERE thread_id = ? ORDER BY host_id",
            bindings: [.text(frozen.threadID)], maximumRows: 2
        )
        let automation = try desktop.query(
            "SELECT * FROM automation_runs "
                + "WHERE thread_id = ? ORDER BY automation_id",
            bindings: [.text(frozen.threadID)], maximumRows: 2
        )
        var definitions: [CodexGhostRepairSQLiteRow] = []
        for row in automation {
            guard case let .text(automationID)? = row.value(
                named: "automation_id"
            ) else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "M4f-17 automation identity is invalid."
                )
            }
            definitions += try desktop.query(
                "SELECT * FROM automations WHERE id = ? ORDER BY id",
                bindings: [.text(automationID)], maximumRows: 2
            )
        }
        guard catalog.count <= 1, automation.count <= 1,
              definitions.count <= 1 else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M4f-17 target row multiplicity exceeded one."
            )
        }
        let references = try count(
            desktop, "SELECT count(*) FROM inbox_items WHERE thread_id = ?",
            frozen.threadID
        ) + count(
            desktop,
            "SELECT count(*) FROM thread_timeline_ledger WHERE thread_id = ?",
            frozen.threadID
        ) + count(
            summaries,
            "SELECT count(*) FROM \(summaryPrefix)thread_turn_summaries WHERE thread_id = ?",
            frozen.threadID
        ) + count(
            state, "SELECT count(*) FROM threads WHERE id = ?", frozen.threadID
        ) + count(
            history, "SELECT count(*) FROM thread_turns WHERE thread_id = ?",
            frozen.threadID
        ) + count(
            history, "SELECT count(*) FROM thread_items WHERE thread_id = ?",
            frozen.threadID
        ) + count(
            history,
            "SELECT count(*) FROM thread_history_projection_state "
                + "WHERE thread_id = ?",
            frozen.threadID
        )
        let rawCatalogRow = catalog.first
        let rawAutomationRow = automation.first
        let rawDefinitionRow = definitions.first
        var result = CodexGhostRepairBulkLiveMixedObservedItem(
            threadID: frozen.threadID,
            category: frozen.category,
            catalogRowDigest: try rawCatalogRow.map {
                try CodexGhostRepairBulkTargetEvidenceContract
                    .catalogAuthorizationDigest($0)
            },
            automationRunRowDigest:
                try rawAutomationRow.map(CodexGhostRepairHasher.hash),
            automationStableFieldsDigest: try rawAutomationRow.map {
                try CodexGhostRepairBulkTargetEvidenceContract
                    .automationIdentityDigest($0)
            },
            automationStatus: text(rawAutomationRow, "status"),
            automationArchivedReason:
                text(rawAutomationRow, "archived_reason"),
            automationUpdatedAt: integer(rawAutomationRow, "updated_at"),
            automationDefinitionRowDigest:
                try rawDefinitionRow.map {
                    try CodexGhostRepairBulkTargetEvidenceContract
                        .automationDefinitionAuthorizationDigest($0)
                },
            referenceCount: references
        )
        if frozen.reviewedResidue != nil {
            result.summaryRowDigests = try summaries.query(
                "SELECT * FROM \(summaryPrefix)thread_turn_summaries WHERE thread_id = ? ORDER BY principal_key, host_key",
                bindings: [.text(frozen.threadID)], maximumRows: 100
            ).map { try CodexGhostRepairHasher.hash($0) }.sorted()
        }
        return result
    }

    private static func matchesInitial(
        _ state: CodexGhostRepairBulkLiveMixedObservedState,
        plan: CodexGhostRepairBulkBackupBoundOperationPlan
    ) -> Bool {
        guard state.authority == plan.authority,
              state.databases == plan.databaseEvidence,
              matchesFrozenTargets(
                  state,
                  selectedItems: plan.selectedItems
              ) else { return false }
        return true
    }

    /// Compares only target-relevant evidence and the admitted database
    /// contract. Unrelated Codex rows may legitimately change between Preview
    /// and Final Review; the fresh full backup protects those bytes instead.
    static func matchesFrozenTargets(
        _ state: CodexGhostRepairBulkLiveMixedObservedState,
        selectedItems: [CodexGhostRepairBulkBackupBoundOperationItem]
    ) -> Bool {
        frozenTargetMismatch(state, selectedItems: selectedItems) == nil
    }

    static func frozenTargetMismatch(
        _ state: CodexGhostRepairBulkLiveMixedObservedState,
        selectedItems: [CodexGhostRepairBulkBackupBoundOperationItem],
        allowAlreadyAbsent: Bool = false
    ) -> String? {
        guard state.items.count == selectedItems.count else {
            return "Selected session membership count changed from "
                + "\(selectedItems.count) to \(state.items.count)."
        }
        guard CodexGhostRepairDatabaseSchemaProfile.admitted(
            databases: state.databases
        ) != nil else {
            return "The selected sessions no longer use an admitted database schema."
        }
        guard state.databases.allSatisfy({
            $0.integrityCheckPassed && $0.foreignKeyViolationCount == 0
        }) else {
            return "A selected-session database integrity check no longer passes."
        }
        for (observed, frozen) in zip(state.items, selectedItems) {
            guard observed.threadID == frozen.threadID else {
                return "Selected session identity or ordering changed near "
                    + "\(frozen.threadID)."
            }
            guard observed.category == frozen.category else {
                return "Selected session \(frozen.threadID) changed repair category."
            }
            if observed.catalogRowDigest == nil {
                guard allowAlreadyAbsent
                        || [.alreadyAbsent, .archiveAutomation]
                            .contains(frozen.expectedEffect) else {
                    return "Selected session \(frozen.threadID) is already absent from the Desktop catalog."
                }
                guard referencesMatch(observed, frozen: frozen) else {
                    return "Selected session \(frozen.threadID) now has protected side references."
                }
                guard observed.automationStableFieldsDigest
                        == frozen.automationStableFieldsDigest,
                      observed.automationDefinitionRowDigest
                        == frozen.automationDefinitionRowDigest,
                      initialAutomationShape(observed) else {
                    return "Selected session \(frozen.threadID) changed automation eligibility fields."
                }
                continue
            }
            guard ![.alreadyAbsent, .archiveAutomation]
                .contains(frozen.expectedEffect) else {
                return "Selected session \(frozen.threadID) reappeared in the Desktop catalog."
            }
            guard observed.catalogRowDigest == frozen.catalogRowDigest else {
                return "Selected session \(frozen.threadID) changed catalog eligibility fields."
            }
            guard observed.automationStableFieldsDigest
                    == frozen.automationStableFieldsDigest,
                  observed.automationDefinitionRowDigest
                    == frozen.automationDefinitionRowDigest,
                  initialAutomationShape(observed) else {
                return "Selected session \(frozen.threadID) changed automation eligibility fields."
            }
            guard referencesMatch(observed, frozen: frozen) else {
                return "Selected session \(frozen.threadID) now has protected side references."
            }
        }
        return nil
    }

    private static func referencesMatch(
        _ observed: CodexGhostRepairBulkLiveMixedObservedItem,
        frozen: CodexGhostRepairBulkBackupBoundOperationItem
    ) -> Bool {
        let expected = frozen.reviewedResidue?.summaryRowDigests ?? []
        return observed.referenceCount == expected.count
            && observed.summaryRowDigests == expected
    }

    private static func initialAutomationShape(
        _ item: CodexGhostRepairBulkLiveMixedObservedItem
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

    private static func matchesFinal(
        _ state: CodexGhostRepairBulkLiveMixedObservedState,
        beforeAuthority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence,
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        executionAtMilliseconds: Int64
    ) -> Bool {
        let increment = Int64(plan.catalogDeletionCount)
        guard state.databases == plan.databaseEvidence,
              state.authority.catalogRevision
                == beforeAuthority.catalogRevision + increment,
              state.authority.observationSequence
                == beforeAuthority.observationSequence + increment,
              state.authority.watermarkUpdatedAt
                == beforeAuthority.watermarkUpdatedAt,
              state.items.count == plan.selectedItems.count else {
            return false
        }
        return zip(state.items, plan.selectedItems).allSatisfy {
            after, frozen in
            guard after.threadID == frozen.threadID,
                  after.category == frozen.category,
                  after.catalogRowDigest == nil,
                  after.referenceCount == 0 else { return false }
            switch frozen.expectedEffect {
            case .alreadyAbsent, .removeCatalogRow:
                return after.automationRunRowDigest == nil
                    && after.automationDefinitionRowDigest == nil
            case .archiveAutomation, .removeCatalogRowAndArchiveAutomation:
                return after.automationRunRowDigest != nil
                    && after.automationRunRowDigest
                        != frozen.automationRunRowDigest
                    && after.automationStableFieldsDigest
                        == frozen.automationStableFieldsDigest
                    && after.automationStatus == "ARCHIVED"
                    && after.automationArchivedReason == "auto"
                    && after.automationUpdatedAt == executionAtMilliseconds
                    && after.automationDefinitionRowDigest
                        == frozen.automationDefinitionRowDigest
            }
        }
    }

    private static func apply(
        database: CodexGhostRepairProductionSQLite,
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        executionAtMilliseconds: Int64,
        failAfterSummaryRemoval: Bool = false
    ) throws {
        try CodexGhostRepairBulkSQLCleanup.apply(database: database,
            targets: plan.selectedItems.map {
                .init(threadID: $0.threadID, effect: $0.expectedEffect,
                      summaryCount: $0.reviewedResidue?.summaryRowDigests.count ?? 0)
            }, catalogRevision: plan.authority.catalogRevision,
            observationSequence: plan.authority.observationSequence,
            executionAtMilliseconds: executionAtMilliseconds,
            failAfterSummaryRemoval: failAfterSummaryRemoval)
    }

    private static func count(
        _ database: CodexGhostRepairProductionSQLite,
        _ sql: String,
        _ threadID: String
    ) throws -> Int {
        let rows = try database.query(
            sql, bindings: [.text(threadID)], maximumRows: 2
        )
        guard rows.count == 1,
              case let .integer(value)? = rows[0].fields.first?.value,
              value >= 0 else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M4f-17 reference count is invalid."
            )
        }
        return Int(value)
    }

    private static func text(
        _ row: CodexGhostRepairSQLiteRow?, _ name: String
    ) -> String? {
        guard case let .text(value)? = row?.value(named: name) else {
            return nil
        }
        return value
    }

    private static func integer(
        _ row: CodexGhostRepairSQLiteRow?, _ name: String
    ) -> Int64? {
        guard case let .integer(value)? = row?.value(named: name) else {
            return nil
        }
        return value
    }

    private static func readbackOnlyFilesUnchanged(
        backup: CodexGhostRepairBulkLiveBackupReceipt,
        after: CodexGhostRepairSnapshotCanonicalFingerprint,
        plan: CodexGhostRepairBulkBackupBoundOperationPlan
    ) -> Bool {
        var desktopFiles: Set<String> = [
            CodexGhostRepairSnapshotCanonicalFile.desktop.rawValue,
            CodexGhostRepairSnapshotCanonicalFile.desktopWAL.rawValue,
            CodexGhostRepairSnapshotCanonicalFile.desktopSHM.rawValue,
            CodexGhostRepairSnapshotCanonicalFile.desktopJournal.rawValue,
        ]
        if plan.selectedItems.contains(where: { !($0.reviewedResidue?.summaryRowDigests.isEmpty ?? true) }) {
            desktopFiles.formUnion([
                CodexGhostRepairSnapshotCanonicalFile.summaries.rawValue,
                CodexGhostRepairSnapshotCanonicalFile.summariesWAL.rawValue,
                CodexGhostRepairSnapshotCanonicalFile.summariesSHM.rawValue,
                CodexGhostRepairSnapshotCanonicalFile.summariesJournal.rawValue,
            ])
        }
        return backup.firstStableSourceMismatch(
            in: after,
            excluding: desktopFiles
        ) == nil
    }

    private static func freshRecoveryFingerprintsStable(
        before: CodexGhostRepairSnapshotCanonicalFingerprint,
        after: CodexGhostRepairSnapshotCanonicalFingerprint
    ) -> Bool {
        guard before.sourceLayoutIdentifier == after.sourceLayoutIdentifier,
              before.sourceRootDigest == after.sourceRootDigest else {
            return false
        }
        let stableBefore = before.files.filter {
            !$0.fileName.hasSuffix("-shm")
        }
        let stableAfter = after.files.filter {
            !$0.fileName.hasSuffix("-shm")
        }
        return stableBefore == stableAfter
    }
}
