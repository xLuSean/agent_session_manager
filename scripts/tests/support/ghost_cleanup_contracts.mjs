// Read-only source-boundary checks against the current Swift implementation.
// These supplement executable Swift tests; they neither grant authority nor prove live acceptance.
// Historical milestone evaluators and operator authorization are deliberately not retained.

const SHIPPING_ENGINE_SOURCE_KEYS = Object.freeze([
  "operationPlan",
  "maintenanceCollector",
  "backupDestination",
  "backupTransport",
  "liveJournal",
  "liveMutator",
  "sqlCleanup",
  "oneShotCoordinator",
  "productionBundle",
  "draftCollector",
  "executionContract",
]);

export function analyzeCleanupEngine(sources) {
  return Object.freeze({
    shippingEngineHasNoResearchGate: SHIPPING_ENGINE_SOURCE_KEYS.every(
      (key) => !sources[key].includes("AGENT_SESSION_MANAGER_RESEARCH"),
    ),
    exactLargeBatchAcceptanceRetained:
      sources.preview.includes("public static let maximumSelectedItems = 500") &&
      sources.mutatorTests.includes(
        "testM4f20DesktopV33Exact148MixedBatchIsAtomicAndColdRecoverable",
      ) &&
      sources.mutatorTests.includes("makeFixture(itemCount: 148, desktopSchema: 33)"),
    oneShotAndNoReplayRetained:
      sources.oneShotCoordinator.includes("let durableClaimBeforeAttempt = true") &&
      sources.oneShotCoordinator.includes("let durableAttemptBeforeMutation = true") &&
      sources.oneShotCoordinator.includes("let maximumMutationAttemptCount = 1") &&
      sources.oneShotCoordinator.includes("let automaticRetryAllowed = false") &&
      sources.oneShotCoordinator.includes("let automaticRestoreAllowed = false") &&
      sources.oneShotCoordinator.includes("let silentSelectionShrinkAllowed = false") &&
      sources.oneShotCoordinator.includes("mutator.recoverByReadback"),
    atomicMixedMutationRetained:
      sources.liveMutator.includes('desktop.execute("BEGIN IMMEDIATE")') &&
      sources.liveMutator.includes("try CodexGhostRepairBulkSQLCleanup.apply(database: database,") &&
      sources.sqlCleanup.includes("DELETE FROM local_thread_catalog") &&
      sources.sqlCleanup.includes(
        "UPDATE automation_runs SET status = 'ARCHIVED'",
      ) &&
      sources.liveMutator.includes("let automaticRetryAllowed = false") &&
      sources.liveMutator.includes("let automaticRestoreAllowed = false"),
    constructionDoesNotGrantAuthority:
      // App composition reachability is not live execution or mutation
      // authority. The one-shot facade is now legitimately App-wired, while
      // the effectful capabilities below must remain independently false.
      [
        sources.operationPlan,
        sources.liveMutator,
        sources.draftCollector,
        sources.executionContract,
      ].every((value) => value.includes("appWiringAvailable = false")) &&
      sources.productionBundle.includes("let acceptsCallerPath = false") &&
      sources.productionBundle.includes("let constructionPerformsIO = false") &&
      sources.productionBundle.includes("let resolutionPerformsIO = false") &&
      sources.productionBundle.includes("let opensFilesystem = false") &&
      sources.productionBundle.includes("let opensSQLite = false") &&
      sources.productionBundle.includes("let acceptsLiveCodexRoot: Bool") &&
      sources.productionBundle.includes("acceptsLiveCodexRoot: false") &&
      sources.productionBundle.includes("acceptsLiveCodexRoot: true") &&
      [sources.operationPlan, sources.liveMutator, sources.oneShotCoordinator]
        .every((value) => value.includes("liveExecutionAuthorized = false")) &&
      [
        sources.operationPlan,
        sources.liveMutator,
        sources.oneShotCoordinator,
        sources.productionBundle,
        sources.draftCollector,
        sources.executionContract,
      ].every((value) => value.includes("repairMutationAuthority = false")),
  });
}

export function analyzeCleanupComposition(sources) {
  const bulkFactoryBlock = sources.appModel.match(
    /CodexGhostRepairBulkRepairCoordinatorFactory[\s\S]{0,120}/,
  )?.[0] ?? "";
  const gateIndex = sources.maintenanceObserver.indexOf(
    "ghostRepairExecutionGate()",
  );
  const fingerprintIndex = sources.maintenanceObserver.indexOf(
    "fingerprintReader()",
  );
  const authorityIndex = sources.maintenanceObserver.indexOf(
    "authorityReader(resolution)",
  );
  return Object.freeze({
    exactSingleAppFacade:
      bulkFactoryBlock.includes(".packagedProduction()") &&
      (sources.appModel.match(
        /CodexGhostRepairBulkRepairCoordinatorFactory/g,
      ) ?? []).length === 1 &&
      !sources.appModel.includes("CodexGhostRepairBulkLiveOneShot") &&
      !sources.appModel.includes("CodexGhostRepairBulkLiveMixed") &&
      !sources.appModel.includes("CodexGhostRepairBulkSQLCleanup") &&
      !sources.appModel.includes("CodexGhostRepairBulkLiveBackup"),
    callerPathFreeProductionResolution:
      sources.productionBundle.includes("init(productionColdReadback") &&
      sources.productionBundle.includes("func resolveForProduction()") &&
      sources.productionBundle.includes("productionFactoryAcceptsCallerPath = false"),
    gatePrecedesLiveReads:
      gateIndex >= 0 &&
      fingerprintIndex > gateIndex &&
      authorityIndex > fingerprintIndex &&
      sources.maintenanceObserver.includes("gate.stateOpenHandleCount == 0") &&
      sources.maintenanceObserver.includes("gate.threadHistoryOpenHandleCount == 0"),
    exactReceiptPlanAndBackupBinding:
      sources.planPreparer.includes("receiptID: confirmationReceiptID") &&
      sources.planPreparer.includes("phase: .beforeBackup") &&
      sources.planPreparer.includes("phase: .beforeBackupRepeat") &&
      sources.planPreparer.includes("prepareFixedStorageIfNeeded()") &&
      sources.planPreparer.includes("readExactBackup") &&
      sources.planPreparer.includes("validateReceipt"),
    oneShotBridgeAndItemizedReport:
      sources.repairCoordinator.includes("runner.prepare(") &&
      sources.repairCoordinator.includes("runnerFactory(profile.identifier).execute(") &&
      sources.repairCoordinator.includes("itemReports: report.items.map") &&
      sources.repairCoordinator.includes("Do not retry or restore automatically"),
    wholeBatchScaleAndRecoveryAcceptance:
      sources.preview.includes("public static let maximumSelectedItems = 500") &&
      sources.mutatorTests.includes(
        "testM4f20DesktopV33Exact148MixedBatchIsAtomicAndColdRecoverable",
      ) &&
      sources.mutatorTests.includes(
        "testPackagedBridgeUsesExactReceiptPlanAndOneShotReport",
      ) &&
      sources.maintenanceTests.includes(
        "testRepeatBeforeBackupWindowKeepsStableDestinationIdentity",
      ) &&
      sources.backupTests.includes(
        "testExplicitPreparationRejectsFixedPathCollision",
      ),
    noReplayRestoreOrShrink:
      sources.repairAction.includes("automaticRetryAllowed: Bool { false }") &&
      sources.repairAction.includes("automaticRestoreAllowed: Bool { false }") &&
      sources.repairAction.includes("silentSelectionShrinkAllowed: Bool { false }") &&
      sources.liveCoordinator.includes("let maximumMutationAttemptCount = 1") &&
      sources.liveCoordinator.includes("coldRestartUsesReadbackOnly = true"),
    singleBulkProductEntry:
      sources.appViews.includes("Enable Bulk Ghost Delete") &&
      sources.appViews.includes("Open Bulk Ghost Delete…") &&
      sources.appViews.includes('Label("Bulk Ghost Delete", systemImage: "list.bullet.clipboard")') &&
      sources.appViews.includes("one exact whole-batch confirmation is required before final Ghost Delete review") &&
      !sources.appViews.includes("Enable explicit Create Snapshot action") &&
      !sources.appViews.includes("GhostRepairReadOnlyReviewSheet") &&
      !sources.appViews.includes("GhostRepairGuidedWorkflowSheet") &&
      !sources.appViews.includes("CategoryARepairSheet"),
    stageFirstAppHandoffAcceptance:
      sources.appModel.includes("await readSavedGhostRepairBulkPreview()") &&
      sources.appModel.includes("await prepareGhostRepairBulkConfirmationChallenge()") &&
      sources.appModel.includes("await prepareGhostRepairBulkFinalReview()") &&
      sources.appModel.includes("await executeGhostRepairBulkOneShot()") &&
      sources.appModel.includes("guard ghostRepairCleanupState == .awaitingShutdown,") &&
      sources.appViews.includes("model.confirmGhostCleanup(") &&
      sources.appViews.includes("model.continueGhostCleanupAfterShutdown()") &&
      sources.appViews.includes('accessibilityIdentifier("confirmGhostCleanup")') &&
      !sources.appViews.includes('Button("Prepare Final Review")') &&
      !sources.appViews.includes('"Paste exact whole-batch confirmation phrase"') &&
      sources.appModelTests.includes(
        "testSimplifiedCleanupConfirmsOnceWaitsForShutdownAndExecutes148Items",
      ) &&
      sources.appModelTests.includes("XCTAssertEqual(reviewRequestCountBeforeExplicitReview, 0)") &&
      sources.appModelTests.includes("XCTAssertEqual(challengeRequestCount, 1)") &&
      sources.appModelTests.includes("XCTAssertEqual(receiptRequestCount, 1)") &&
      sources.appModelTests.includes(
        "XCTAssertEqual(reviewRequestCountBeforeExecution, 1)",
      ) &&
      sources.appModelTests.includes("XCTAssertEqual(executionRequestCount, 1)"),
    nativeHoverHelpLifecycle:
      sources.appViews.includes(".help(text)") &&
      !sources.appViews.includes("NSPanel("),
    boundedBulkSheetViewport:
      sources.appViews.includes(
        "GhostRepairBulkInventorySheetLayout.maximumHeight",
      ) &&
      sources.appViews.includes(
        "GhostRepairBulkInventorySheetLayout.inventoryMaximumHeight",
      ) &&
      sources.appViews.includes(".onExitCommand") &&
      sources.appViews.includes(".keyboardShortcut(.cancelAction)") &&
      sources.appViews.includes(
        ".frame(maxWidth: .infinity, maxHeight: .infinity)",
      ),
  });
}
