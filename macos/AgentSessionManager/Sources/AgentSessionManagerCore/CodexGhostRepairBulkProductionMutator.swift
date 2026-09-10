import CSQLite3
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH

enum CodexGhostRepairBulkProductionMutationFault: Sendable {
    case none
    case explicitBusyBeforeTransaction
    case afterCommitBeforeReadback
}

struct CodexGhostRepairBulkProductionMutatorCapabilities:
    Equatable,
    Sendable
{
    let acceptsCallerPath = false
    let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems
    let mixedCategoryBatch = true
    let fixedDatabaseGroupCount = 5
    let desktopWriteDatabaseCount = 1
    let readbackOnlyDatabaseCount = 4
    let requiresDurableExternalClaimAndAttempt = true
    let requiresExactOperationBoundBackup = true
    let requiresFreshOperationalGate = true
    let testOwnedCanonicalSourceOnly = true
    let automaticRetryAllowed = false
    let automaticRestoreAllowed = false
    let appWiringAvailable = false
    let acceptsLiveCodexRoot = false
}

protocol CodexGhostRepairBulkProductionBackupReadbackResolving: Sendable {
    func exactBackup(
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) async throws -> CodexGhostRepairBulkExecutionBackupReceipt
}

private struct CodexGhostRepairBulkProductionObservedItem:
    Equatable,
    Sendable
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

private struct CodexGhostRepairBulkProductionObservedState:
    Equatable,
    Sendable
{
    let items: [CodexGhostRepairBulkProductionObservedItem]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let databaseEvidence: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
}

/// Research-gated composition of the verified mixed transaction with the
/// production draft and external v17 claim/attempt. It deliberately accepts
/// only marker-protected canonical test mirrors in this slice. Construction
/// performs no I/O and there is no production factory or App call site.
actor CodexGhostRepairBulkProductionMutator:
    CodexGhostRepairBulkProductionMutating
{
    static let capabilities = CodexGhostRepairBulkProductionMutatorCapabilities()

    private let bundle: CodexGhostRepairProductionRepairBundle
    private let source: CodexGhostRepairSnapshotCanonicalSource
    private let gateSource: any CodexGhostRepairExecutionGateSource
    private let backupResolver:
        any CodexGhostRepairBulkProductionBackupReadbackResolving
    private let fault: CodexGhostRepairBulkProductionMutationFault

    init(
        bundle: CodexGhostRepairProductionRepairBundle,
        source: CodexGhostRepairSnapshotCanonicalSource,
        gateSource: any CodexGhostRepairExecutionGateSource,
        backupResolver:
            any CodexGhostRepairBulkProductionBackupReadbackResolving,
        fault: CodexGhostRepairBulkProductionMutationFault = .none
    ) throws {
        guard source.researchTestMirrorOnly else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f mixed mutator requires a test-owned canonical source."
            )
        }
        self.bundle = bundle
        self.source = source
        self.gateSource = gateSource
        self.backupResolver = backupResolver
        self.fault = fault
    }

    func executeOnce(
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claim: CodexGhostRepairBulkProductionClaim,
        attempt: CodexGhostRepairBulkProductionAttempt
    ) async throws -> CodexGhostRepairCategoryABatchOutcome {
        try Self.validate(draft: draft, claim: claim, attempt: attempt)
        let backup = try await backupResolver.exactBackup(draft: draft)
        guard backup == draft.backup else {
            throw CodexGhostRepairError.backupFailed(
                "M4f operation-bound backup readback drifted."
            )
        }
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .notAttempted
        }
        let beforeFingerprint = try source.fingerprint()
        try beforeFingerprint.validateHash()
        guard Self.fingerprint(beforeFingerprint, matches: backup) else {
            return .notAttempted
        }
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .notAttempted
        }

        let resolution = try bundle.resolveForPreflight()
        let before = try Self.inspect(
            draft: draft,
            resolution: resolution
        )
        guard Self.matchesInitial(before, plan: draft.plan) else {
            return .notAttempted
        }

        do {
            if fault == .explicitBusyBeforeTransaction {
                throw CodexGhostRepairError.sqlite(
                    operation: "begin",
                    code: SQLITE_BUSY,
                    message: "Deterministic M4f busy fault."
                )
            }
            let desktop = try CodexGhostRepairProductionSQLite(
                url: resolution.databaseURL(for: .desktop),
                readOnly: false
            )
            defer { desktop.close() }
            try desktop.execute("BEGIN IMMEDIATE")
            do {
                let transactionBefore = try Self.inspect(
                    draft: draft,
                    resolution: resolution,
                    desktopDatabase: desktop
                )
                guard transactionBefore == before else {
                    try desktop.execute("ROLLBACK")
                    return .notAttempted
                }
                try Self.apply(
                    database: desktop,
                    plan: draft.plan,
                    executionAtMilliseconds: claim.claimedAtMilliseconds
                )
                let transactionAfter = try Self.inspect(
                    draft: draft,
                    resolution: resolution,
                    desktopDatabase: desktop
                )
                guard Self.matchesFinal(
                    transactionAfter,
                    before: before,
                    plan: draft.plan,
                    executionAtMilliseconds: claim.claimedAtMilliseconds
                ) else {
                    throw CodexGhostRepairError.targetDrift(
                        "M4f mixed transaction readback was not exact."
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
                draft: draft,
                claim: claim,
                backup: backup
            )
        }

        return try await classifyByReadback(
            draft: draft,
            claim: claim,
            backup: backup
        )
    }

    func recoverByReadback(
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claim: CodexGhostRepairBulkProductionClaim,
        attempt: CodexGhostRepairBulkProductionAttempt
    ) async throws -> CodexGhostRepairCategoryABatchOutcome {
        try Self.validate(draft: draft, claim: claim, attempt: attempt)
        let backup = try await backupResolver.exactBackup(draft: draft)
        guard backup == draft.backup else {
            throw CodexGhostRepairError.backupFailed(
                "M4f operation-bound backup readback drifted."
            )
        }
        return try await classifyByReadback(
            draft: draft,
            claim: claim,
            backup: backup
        )
    }

    private func classifyByReadback(
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claim: CodexGhostRepairBulkProductionClaim,
        backup: CodexGhostRepairBulkExecutionBackupReceipt
    ) async throws -> CodexGhostRepairCategoryABatchOutcome {
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .unknown
        }
        let resolution = try bundle.resolveForPreflight()
        let observed = try Self.inspect(draft: draft, resolution: resolution)
        let afterFingerprint = try source.fingerprint()
        try afterFingerprint.validateHash()
        guard Self.readbackOnlyFilesUnchanged(
            backup: backup,
            after: afterFingerprint
        ) else { return .unknown }
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .unknown
        }
        if Self.matchesFinal(
            observed,
            beforeAuthority: draft.plan.authority,
            plan: draft.plan,
            executionAtMilliseconds: claim.claimedAtMilliseconds
        ) {
            return .success
        }
        if Self.matchesInitial(observed, plan: draft.plan) {
            return .explicitFailure
        }
        return .unknown
    }

    private static func validate(
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        claim: CodexGhostRepairBulkProductionClaim,
        attempt: CodexGhostRepairBulkProductionAttempt
    ) throws {
        try draft.validate()
        try claim.validate(draft: draft)
        try attempt.validate(claim: claim)
        guard draft.plan.selectedItems.count == draft.selectedItems.count,
              draft.plan.blockedOutsideBatchCount
                == draft.blockedOutsideBatchCount,
              draft.backup.operationID == draft.operationID,
              draft.backup.planDigest == draft.planDigest,
              draft.backup.selectedThreadIDs == draft.selectedThreadIDs,
              draft.backup.receiptDigest == draft.backupReceiptDigest,
              claim.operationID == draft.operationID,
              attempt.operationID == draft.operationID,
              claim.claimedAtMilliseconds < draft.expiresAtMilliseconds,
              draft.allOrNothing,
              !draft.silentSelectionShrinkAllowed,
              !claim.automaticRetryAllowed,
              !claim.automaticRestoreAllowed,
              !attempt.automaticRetryAllowed else {
            throw CodexGhostRepairError.invalidPlan(
                "M4f mixed mutator inputs do not form one exact attempt."
            )
        }
    }

    private static func inspect(
        draft: CodexGhostRepairBulkProductionExecutionDraft,
        resolution: CodexGhostRepairProductionRepairBundle.Resolution,
        desktopDatabase: CodexGhostRepairProductionSQLite? = nil
    ) throws -> CodexGhostRepairBulkProductionObservedState {
        let ownsDesktop = desktopDatabase == nil
        let desktop = try desktopDatabase ?? CodexGhostRepairProductionSQLite(
            url: resolution.databaseURL(for: .desktop),
            readOnly: true
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
        defer {
            summaries.close()
            state.close()
            history.close()
        }
        let databases: [
            (CodexGhostRepairSnapshotAnalysisDatabase,
             CodexGhostRepairProductionSQLite)
        ] = [
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
        let items = try draft.plan.selectedItems.map {
            try observedItem(
                frozen: $0,
                desktop: desktop,
                summaries: summaries,
                state: state,
                history: history
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
                "M4f authority rows are unavailable."
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
                "M4f watermark evidence is invalid."
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
            databaseEvidence: databaseEvidence
        )
    }

    private static func observedItem(
        frozen: CodexGhostRepairBulkExecutionFrozenItem,
        desktop: CodexGhostRepairProductionSQLite,
        summaries: CodexGhostRepairProductionSQLite,
        state: CodexGhostRepairProductionSQLite,
        history: CodexGhostRepairProductionSQLite
    ) throws -> CodexGhostRepairBulkProductionObservedItem {
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
                    "M4f automation identity is invalid."
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
                "M4f target row multiplicity exceeded one."
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
            "SELECT count(*) FROM thread_turn_summaries WHERE thread_id = ?",
            frozen.threadID
        ) + count(
            state, "SELECT count(*) FROM threads WHERE id = ?",
            frozen.threadID
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
        let catalogRow = catalog.first
        let automationRow = automation.first
        let definitionRow = definitions.first
        return .init(
            threadID: frozen.threadID,
            category: frozen.category,
            catalogRowDigest: try catalogRow.map {
                try CodexGhostRepairBulkTargetEvidenceContract
                    .catalogAuthorizationDigest($0)
            },
            automationRunRowDigest:
                try automationRow.map(CodexGhostRepairHasher.hash),
            automationStableFieldsDigest: try automationRow.map {
                try CodexGhostRepairBulkTargetEvidenceContract
                    .automationIdentityDigest($0)
            },
            automationStatus: text(automationRow, "status"),
            automationArchivedReason:
                text(automationRow, "archived_reason"),
            automationUpdatedAt: integer(automationRow, "updated_at"),
            automationDefinitionRowDigest:
                try definitionRow.map {
                    try CodexGhostRepairBulkTargetEvidenceContract
                        .automationDefinitionAuthorizationDigest($0)
                },
            referenceCount: references
        )
    }

    private static func matchesInitial(
        _ state: CodexGhostRepairBulkProductionObservedState,
        plan: CodexGhostRepairBulkExecutionPlan
    ) -> Bool {
        guard state.authority == plan.authority,
              state.databaseEvidence == plan.databases,
              state.items.count == plan.selectedItems.count,
              state.databaseEvidence.allSatisfy({
                  $0.integrityCheckPassed && $0.foreignKeyViolationCount == 0
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

    private static func initialAutomationShape(
        _ item: CodexGhostRepairBulkProductionObservedItem
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
        _ state: CodexGhostRepairBulkProductionObservedState,
        before: CodexGhostRepairBulkProductionObservedState,
        plan: CodexGhostRepairBulkExecutionPlan,
        executionAtMilliseconds: Int64
    ) -> Bool {
        matchesFinal(
            state,
            beforeAuthority: before.authority,
            plan: plan,
            executionAtMilliseconds: executionAtMilliseconds
        ) && state.databaseEvidence == before.databaseEvidence
    }

    private static func matchesFinal(
        _ state: CodexGhostRepairBulkProductionObservedState,
        beforeAuthority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence,
        plan: CodexGhostRepairBulkExecutionPlan,
        executionAtMilliseconds: Int64
    ) -> Bool {
        let increment = Int64(plan.selectedItems.count)
        guard state.databaseEvidence == plan.databases,
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
            switch after.category {
            case .ordinary:
                return after.automationRunRowDigest == nil
                    && after.automationDefinitionRowDigest == nil
            case .automation:
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
        plan: CodexGhostRepairBulkExecutionPlan,
        executionAtMilliseconds: Int64
    ) throws {
        for item in plan.selectedItems {
            try database.execute(
                "DELETE FROM local_thread_catalog "
                    + "WHERE host_id = 'local' AND thread_id = ?",
                bindings: [.text(item.threadID)]
            )
            guard database.changeCount == 1 else {
                throw CodexGhostRepairError.targetDrift(
                    "M4f exact catalog row count drifted."
                )
            }
            if item.category == .automation {
                try database.execute(
                    "UPDATE automation_runs SET status = 'ARCHIVED', "
                        + "archived_reason = 'auto', updated_at = ? "
                        + "WHERE thread_id = ?",
                    bindings: [
                        .integer(executionAtMilliseconds),
                        .text(item.threadID),
                    ]
                )
                guard database.changeCount == 1 else {
                    throw CodexGhostRepairError.targetDrift(
                        "M4f exact automation row count drifted."
                    )
                }
            }
        }
        let increment = Int64(plan.selectedItems.count)
        try database.execute(
            "UPDATE local_thread_catalog_metadata SET catalog_revision = ? "
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
                "M4f reference count is invalid."
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

    private static func fingerprint(
        _ fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        matches backup: CodexGhostRepairBulkExecutionBackupReceipt
    ) -> Bool {
        fingerprint.files.count == backup.files.count
            && fingerprint.fingerprintHash == backup.sourceFingerprintHash
            && zip(fingerprint.files, backup.files).allSatisfy {
                observed, expected in
                observed.fileName == expected.fileName
                    && observed.exists == expected.present
                    && observed.size == expected.byteCount
                    && observed.sha256 == expected.contentHash
            }
    }

    private static func readbackOnlyFilesUnchanged(
        backup: CodexGhostRepairBulkExecutionBackupReceipt,
        after: CodexGhostRepairSnapshotCanonicalFingerprint
    ) -> Bool {
        let desktopFiles: Set<String> = [
            CodexGhostRepairSnapshotCanonicalFile.desktop.rawValue,
            CodexGhostRepairSnapshotCanonicalFile.desktopWAL.rawValue,
            CodexGhostRepairSnapshotCanonicalFile.desktopSHM.rawValue,
            CodexGhostRepairSnapshotCanonicalFile.desktopJournal.rawValue,
        ]
        let expected = backup.files.filter {
            !desktopFiles.contains($0.fileName)
        }
        let observed = after.files.filter {
            !desktopFiles.contains($0.fileName)
        }
        return observed.count == expected.count
            && zip(observed, expected).allSatisfy { observed, expected in
            observed.fileName == expected.fileName
                && observed.exists == expected.present
                && observed.size == expected.byteCount
                && observed.sha256 == expected.contentHash
        }
    }
}

#endif
