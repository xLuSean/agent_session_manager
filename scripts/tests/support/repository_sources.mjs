import { readFileSync, readdirSync } from "node:fs";

const root = new URL("../../../", import.meta.url);
const core = "macos/AgentSessionManager/Sources/AgentSessionManagerCore/";
const app = "macos/AgentSessionManager/Sources/AgentSessionManager/";
const tests = "macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/";
const appProject = "macos/AgentSessionManager/App/AgentSessionManager/";
const read = path => readFileSync(new URL(path, root), "utf8");

// Only repository sources are read. No App launch, home lookup, RPC, or database access.
export function repositorySources() {
  const sourceNames = {
    profiles: "CodexGhostRepairExperimentalAbsenceContract",
    canonicalSource: "CodexGhostRepairSnapshotCanonicalSource",
    inventory: "CodexGhostRepairBulkInventory",
    coordinator: "CodexGhostRepairBulkInventoryCoordinator",
    publisher: "CodexGhostRepairSnapshotQuarantinePublisher",
    publishedInventory: "CodexGhostRepairSnapshotPublishedInventory",
    analysisReader: "CodexGhostRepairSnapshotAnalysisReader",
    selection: "CodexGhostRepairSnapshotRequestBoundProfileSelection",
    actionCoordinator: "CodexGhostRepairSnapshotActionCoordinator",
    operationPlan: "CodexGhostRepairBulkBackupBoundOperationPlan",
    maintenanceCollector: "CodexGhostRepairBulkMaintenanceCollector",
    backupDestination: "CodexGhostRepairBulkFixedBackupDestination",
    backupTransport: "CodexGhostRepairBulkLiveBackupTransport",
    liveJournal: "CodexGhostRepairBulkLiveExecutionJournal",
    liveMutator: "CodexGhostRepairBulkLiveMixedMutator",
    sqlCleanup: "CodexGhostRepairBulkSQLCleanup",
    oneShotCoordinator: "CodexGhostRepairBulkLiveOneShotCoordinator",
    productionBundle: "CodexGhostRepairBulkProductionBundle",
    draftCollector: "CodexGhostRepairBulkProductionDraftCollector",
    executionContract: "CodexGhostRepairBulkProductionExecutionContract",
    preview: "CodexGhostRepairBulkPreview",
    repairAction: "CodexGhostRepairBulkRepairAction",
    maintenanceObserver: "CodexGhostRepairBulkProductionMaintenanceObserver",
    planPreparer: "CodexGhostRepairBulkPackagedPlanPreparer",
    repairCoordinator: "CodexGhostRepairBulkPackagedRepairCoordinator",
  };
  const testNames = {
    profileTests: "CodexGhostRepairExperimentalAbsenceContractTests",
    inventoryTests: "CodexGhostRepairBulkInventoryTests",
    coordinatorTests: "CodexGhostRepairBulkInventoryCoordinatorTests",
    analysisTests: "CodexGhostRepairSnapshotAnalysisReaderTests",
    canonicalTests: "CodexGhostRepairSnapshotCanonicalSourceTests",
    publisherTests: "CodexGhostRepairSnapshotQuarantinePublisherTests",
    actionTests: "CodexGhostRepairSnapshotActionCoordinatorTests",
    mutatorTests: "CodexGhostRepairBulkProductionMutatorTests",
    maintenanceTests: "CodexGhostRepairBulkMaintenanceCollectorTests",
    backupTests: "CodexGhostRepairBulkLiveBackupTransportTests",
  };
  const sources = Object.fromEntries([
    ...Object.entries(sourceNames).map(([key, name]) => [key, read(core + name + ".swift")]),
    ...Object.entries(testNames).map(([key, name]) => [key, read(tests + name + ".swift")]),
  ]);
  sources.sourceLayout = sources.canonicalSource;
  sources.liveCoordinator = sources.oneShotCoordinator;
  sources.appModel = read(app + "SessionManagerModel.swift");
  sources.appViews = readdirSync(new URL(app, root))
    .filter(name => name.endsWith(".swift") && name !== "SessionManagerModel.swift")
    .map(name => read(app + name)).join("\n");
  sources.appModelTests = read(appProject + "AgentSessionManagerAppTests/SessionManagerModelTests.swift");
  sources.xcodeProject = read(appProject + "AgentSessionManager.xcodeproj/project.pbxproj");
  return Object.freeze(sources);
}
