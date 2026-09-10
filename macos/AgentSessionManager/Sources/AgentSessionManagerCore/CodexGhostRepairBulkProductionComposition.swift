import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH

struct CodexGhostRepairBulkProductionCompositionCapabilities:
    Equatable,
    Sendable
{
    let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems
    let exactPlanToTerminalReport = true
    let operationBoundBackupReadback = true
    let oneShotManagerJournal = true
    let mixedCategoryMutation = true
    let acceptsCallerPath = false
    let testOwnedCanonicalSourceOnly = true
    let automaticRetryAllowed = false
    let automaticRestoreAllowed = false
    let appWiringAvailable = false
    let acceptsLiveCodexRoot = false
}

private actor CodexGhostRepairBulkProductionBackupResolver:
    CodexGhostRepairBulkProductionBackupReadbackResolving
{
    private let backupReader:
        any CodexGhostRepairBulkOperationBoundBackupReading

    init(
        backupReader:
            any CodexGhostRepairBulkOperationBoundBackupReading
    ) {
        self.backupReader = backupReader
    }

    func exactBackup(
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) async throws -> CodexGhostRepairBulkExecutionBackupReceipt {
        let receipt = try await backupReader.readExactBackup(draft: draft)
        guard receipt == draft.backup else {
            throw CodexGhostRepairError.backupFailed(
                "M4f composed backup readback did not match the durable draft."
            )
        }
        return receipt
    }
}

/// Caller-path-free composition of the already verified M4f components. All
/// filesystem-bearing dependencies arrive as typed capabilities; this type
/// accepts no URL or path. The source and database bundle still reject live
/// Codex in this slice, and the composition remains absent from the App.
actor CodexGhostRepairBulkProductionComposition:
    CodexGhostRepairBulkRepairCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkRepairCapabilities.deterministicComposition
    nonisolated let compositionCapabilities =
        CodexGhostRepairBulkProductionCompositionCapabilities()

    private let coordinator: CodexGhostRepairBulkRepairExecutionCoordinator

    init(
        planCollector: any CodexGhostRepairBulkProductionPlanCollecting,
        maintenanceCollector:
            any CodexGhostRepairBulkMaintenanceCollecting,
        backupTransport:
            any CodexGhostRepairBulkOperationBoundBackupCreating
                & CodexGhostRepairBulkOperationBoundBackupReading,
        journal: any CodexGhostRepairBulkProductionExecutionJournaling,
        source: CodexGhostRepairSnapshotCanonicalSource,
        databaseBundle: CodexGhostRepairProductionRepairBundle,
        gateSource: any CodexGhostRepairExecutionGateSource,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) throws {
        guard source.researchTestMirrorOnly else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f composition requires a test-owned canonical source."
            )
        }
        let draftCollector = CodexGhostRepairBulkProductionDraftCollector(
            planCollector: planCollector,
            maintenanceCollector: maintenanceCollector,
            backupCreator: backupTransport,
            nowMilliseconds: nowMilliseconds
        )
        let backupResolver = CodexGhostRepairBulkProductionBackupResolver(
            backupReader: backupTransport
        )
        let mutator = try CodexGhostRepairBulkProductionMutator(
            bundle: databaseBundle,
            source: source,
            gateSource: gateSource,
            backupResolver: backupResolver
        )
        coordinator = CodexGhostRepairBulkRepairExecutionCoordinator(
            draftPreparer: draftCollector,
            journal: journal,
            mutator: mutator,
            nowMilliseconds: nowMilliseconds,
            makeUUID: makeUUID
        )
    }

    func prepareFinalReview(
        request: CodexGhostRepairBulkRepairReviewRequest
    ) async -> CodexGhostRepairBulkRepairReviewOutcome {
        await coordinator.prepareFinalReview(request: request)
    }

    func execute(
        request: CodexGhostRepairBulkRepairExecutionRequest
    ) async -> CodexGhostRepairBulkRepairExecutionOutcome {
        await coordinator.execute(request: request)
    }
}

#endif
