import assert from "node:assert/strict";
import test from "node:test";
import { analyzeCleanupEngine, analyzeCleanupComposition } from "./support/ghost_cleanup_contracts.mjs";
import { repositorySources } from "./support/repository_sources.mjs";

const baseline = repositorySources();
for (const analyze of [analyzeCleanupEngine, analyzeCleanupComposition]) {
  test(analyze.name + " validates the current shipping composition", () => {
    assert.deepEqual(Object.entries(analyze(baseline)).filter(([, value]) => value !== true), []);
  });
}
const cases = [
  ["bulk cannot become a small canary", analyzeCleanupEngine, "mutatorTests", "makeFixture(itemCount: 148, desktopSchema: 33)", "makeFixture(itemCount: 2, desktopSchema: 33)", "exactLargeBatchAcceptanceRetained"],
  ["the 500-item limit cannot silently shrink", analyzeCleanupComposition, "preview", "public static let maximumSelectedItems = 500", "public static let maximumSelectedItems = 10", "wholeBatchScaleAndRecoveryAcceptance"],
  ["claim must precede attempt", analyzeCleanupEngine, "oneShotCoordinator", "let durableClaimBeforeAttempt = true", "let durableClaimBeforeAttempt = false", "oneShotAndNoReplayRetained"],
  ["attempt must be durable before mutation", analyzeCleanupEngine, "oneShotCoordinator", "let durableAttemptBeforeMutation = true", "let durableAttemptBeforeMutation = false", "oneShotAndNoReplayRetained"],
  ["batch transaction remains immediate", analyzeCleanupEngine, "liveMutator", 'desktop.execute("BEGIN IMMEDIATE")', 'desktop.execute("BEGIN")', "atomicMixedMutationRetained"],
  ["automation cleanup must archive the run", analyzeCleanupEngine, "sqlCleanup", "UPDATE automation_runs SET status = 'ARCHIVED'", "UPDATE automation_runs SET status = 'ACCEPTED'", "atomicMixedMutationRetained"],
  ["live cleanup must call the shared SQL", analyzeCleanupEngine, "liveMutator", "try CodexGhostRepairBulkSQLCleanup.apply(database: database,", "try someOtherCleanup(database: database,", "atomicMixedMutationRetained"],
  ["App cannot directly invoke cleanup SQL", analyzeCleanupComposition, "appModel", "import Foundation", "import Foundation\n// CodexGhostRepairBulkSQLCleanup", "exactSingleAppFacade"],
  ["production construction cannot perform I/O", analyzeCleanupEngine, "productionBundle", "let constructionPerformsIO = false", "let constructionPerformsIO = true", "constructionDoesNotGrantAuthority"],
  ["one-shot composition cannot grant execution authority", analyzeCleanupEngine, "oneShotCoordinator", "liveExecutionAuthorized = false", "liveExecutionAuthorized = true", "constructionDoesNotGrantAuthority"],
  ["production bundle cannot grant mutation authority", analyzeCleanupEngine, "productionBundle", "repairMutationAuthority = false", "repairMutationAuthority = true", "constructionDoesNotGrantAuthority"],
  ["mutator cannot grant mutation authority", analyzeCleanupEngine, "liveMutator", "repairMutationAuthority = false", "repairMutationAuthority = true", "constructionDoesNotGrantAuthority"],
  ["App cannot directly access the mutator", analyzeCleanupComposition, "appModel", "import Foundation", "import Foundation\n// CodexGhostRepairBulkLiveMixedMutator", "exactSingleAppFacade"],
  ["receipt must bind the prepared plan", analyzeCleanupComposition, "planPreparer", "receiptID: confirmationReceiptID", "receiptID: UUID()", "exactReceiptPlanAndBackupBinding"],
  ["backup must be read back", analyzeCleanupComposition, "planPreparer", "readExactBackup", "skipBackupReadback", "exactReceiptPlanAndBackupBinding"],
  ["maintenance must repeat before backup", analyzeCleanupComposition, "planPreparer", "phase: .beforeBackupRepeat", "phase: .beforeBackup", "exactReceiptPlanAndBackupBinding"],
  ["only one mutation attempt is permitted", analyzeCleanupComposition, "liveCoordinator", "let maximumMutationAttemptCount = 1", "let maximumMutationAttemptCount = 2", "noReplayRestoreOrShrink"],
  ["automatic restore stays prohibited", analyzeCleanupComposition, "repairAction", "automaticRestoreAllowed: Bool { false }", "automaticRestoreAllowed: Bool { true }", "noReplayRestoreOrShrink"],
  ["silent selection shrink stays prohibited", analyzeCleanupComposition, "repairAction", "silentSelectionShrinkAllowed: Bool { false }", "silentSelectionShrinkAllowed: Bool { true }", "noReplayRestoreOrShrink"],
  ["bulk entry remains visible", analyzeCleanupComposition, "appViews", "Enable Bulk Ghost Delete", "Hidden Ghost Delete", "singleBulkProductEntry"],
  ["shutdown acknowledgement remains required", analyzeCleanupComposition, "appModel", "guard ghostRepairCleanupState == .awaitingShutdown,", "guard true,", "stageFirstAppHandoffAcceptance"],
  ["simplified confirmation acceptance remains covered", analyzeCleanupComposition, "appModelTests", "testSimplifiedCleanupConfirmsOnceWaitsForShutdownAndExecutes148Items", "removedAcceptance", "stageFirstAppHandoffAcceptance"],
  ["hover help must not open a floating panel", analyzeCleanupComposition, "appViews", ".help(text)", ".help(text) // NSPanel(", "nativeHoverHelpLifecycle"],
  ["result sheet must retain a bounded viewport", analyzeCleanupComposition, "appViews", "GhostRepairBulkInventorySheetLayout.maximumHeight", "unboundedHeight", "boundedBulkSheetViewport"],
];
for (const [name, analyze, key, before, after, reason] of cases) {
  test(name, () => {
    assert.ok(baseline[key].includes(before), "mutation must match a current source fragment");
    assert.equal(analyze({ ...baseline, [key]: baseline[key].replaceAll(before, after) })[reason], false, reason);
  });
}

test("source fingerprint reads cannot precede the maintenance gate", () => {
  const maintenanceObserver = baseline.maintenanceObserver
    .replace("let fingerprint = try fingerprintReader()", "")
    .replace("let gate = try await gateSource.ghostRepairExecutionGate()",
      "let fingerprint = try fingerprintReader()\nlet gate = try await gateSource.ghostRepairExecutionGate()");
  assert.notEqual(maintenanceObserver, baseline.maintenanceObserver);
  assert.equal(analyzeCleanupComposition({ ...baseline, maintenanceObserver }).gatePrecedesLiveReads, false);
});
test("retired manual Snapshot entry cannot return to the shipping UI", () => {
  assert.equal(analyzeCleanupComposition({
    ...baseline, appViews: baseline.appViews + "\nEnable explicit Create Snapshot action",
  }).singleBulkProductEntry, false);
});
