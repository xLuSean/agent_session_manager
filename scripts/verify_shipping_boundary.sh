#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
APP_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManager"
PACKAGE_FILE="$REPOSITORY_ROOT/macos/AgentSessionManager/Package.swift"
PROJECT_FILE="$REPOSITORY_ROOT/macos/AgentSessionManager/App/AgentSessionManager/AgentSessionManager.xcodeproj/project.pbxproj"
FIXTURE_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerFixtures"
INSPECT_ONLY_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairDestinationCanaryInspectOnlyCoordinator.swift"
PRODUCTION_POLICY_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairProductionPolicy.swift"
DESTINATION_CANARY_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairDestinationCanary.swift"
E58_LAYOUT_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairDestinationCanaryFixedLayout.swift"
E58_PREPARE_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator.swift"
SNAPSHOT_CANONICAL_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotCanonicalSource.swift"
PRODUCTION_REPAIR_BUNDLE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairProductionRepairBundle.swift"
CATEGORY_A_EXECUTION_CONTRACT="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairCategoryAExecutionContract.swift"
CATEGORY_A_EXECUTION_PREPARATION="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairCategoryAExecutionPreparation.swift"
CATEGORY_A_EXECUTION_JOURNAL="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairCategoryAExecutionJournal.swift"
CATEGORY_A_DISPOSABLE_EXECUTOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairCategoryADisposableExecutor.swift"
CATEGORY_A_PRODUCTION_RECIPE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairCategoryAProductionRecipe.swift"
CATEGORY_A_REPAIR_ACTION="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairCategoryARepairAction.swift"
CATEGORY_A_REPAIR_REVIEW="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairCategoryARepairReviewCoordinator.swift"
CATEGORY_A_PRODUCTION_REVIEW="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairCategoryAProductionReviewMaterialCollector.swift"
CATEGORY_A_REPAIR_EXECUTION="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairCategoryARepairExecutionCoordinator.swift"
CATEGORY_A_PRODUCTION_MUTATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairCategoryAProductionMutator.swift"
SNAPSHOT_PREPARED_DESTINATION="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotPreparedDestination.swift"
SNAPSHOT_ACQUISITION_JOURNAL="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotAcquisitionJournal.swift"
SNAPSHOT_PUBLISHED_INVENTORY="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotPublishedInventory.swift"
SNAPSHOT_QUARANTINE_PUBLISHER="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotQuarantinePublisher.swift"
SNAPSHOT_OPERATIONAL_GATE_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotOperationalGateSource.swift"
SNAPSHOT_ACTION_COORDINATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotActionCoordinator.swift"
SNAPSHOT_ADMISSION_INSPECTOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotAdmissionInspector.swift"
SNAPSHOT_REQUEST_BOUND_PROFILE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotRequestBoundProfileSelection.swift"
SNAPSHOT_READBACK_COORDINATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotReadbackCoordinator.swift"
SNAPSHOT_ANALYSIS_IDENTITY="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotAnalysisIdentity.swift"
SNAPSHOT_ANALYSIS_READER="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotAnalysisReader.swift"
INITIAL_WITNESS_DISCOVERY="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairInitialWitnessDiscovery.swift"
SNAPSHOT_DRY_RUN_PLANNER="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotDryRunPlanner.swift"
SNAPSHOT_DRY_RUN_COORDINATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotDryRunAnalysisCoordinator.swift"
SNAPSHOT_DRY_RUN_REPOSITORY="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotDryRunPreviewRepository.swift"
BULK_INVENTORY_COORDINATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkInventoryCoordinator.swift"
BULK_PREVIEW_REPOSITORY="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkPreviewRepository.swift"
BULK_CONFIRMATION_CONTRACT="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkConfirmation.swift"
BULK_CONFIRMATION_REPOSITORY="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkConfirmationRepository.swift"
BULK_CONFIRMATION_RECEIPT_REPOSITORY="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkConfirmationReceiptRepository.swift"
BULK_REPAIR_ACTION="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkRepairAction.swift"
BULK_DISPOSABLE_EXECUTOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkDisposableExecutor.swift"
BULK_PRODUCTION_EXECUTION_CONTRACT="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkProductionExecutionContract.swift"
BULK_PRODUCTION_EXECUTION_JOURNAL="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkProductionExecutionJournal.swift"
BULK_PRODUCTION_DRAFT_COLLECTOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkProductionDraftCollector.swift"
BULK_OPERATION_BACKUP_TRANSPORT="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkOperationBoundBackupTransport.swift"
BULK_PRODUCTION_BUNDLE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkProductionBundle.swift"
BULK_MAINTENANCE_COLLECTOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkMaintenanceCollector.swift"
BULK_FIXED_BACKUP_DESTINATION="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkFixedBackupDestination.swift"
BULK_LIVE_BACKUP_TRANSPORT="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkLiveBackupTransport.swift"
BULK_BACKUP_BOUND_OPERATION_PLAN="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkBackupBoundOperationPlan.swift"
BULK_LIVE_MIXED_MUTATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkLiveMixedMutator.swift"
BULK_SQL_CLEANUP="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkSQLCleanup.swift"
BULK_LIVE_EXECUTION_JOURNAL="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkLiveExecutionJournal.swift"
BULK_LIVE_ONE_SHOT_COORDINATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkLiveOneShotCoordinator.swift"
BULK_PACKAGED_PLAN_PREPARER="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkPackagedPlanPreparer.swift"
BULK_PACKAGED_REPAIR_COORDINATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkPackagedRepairCoordinator.swift"
BULK_RECOVERY_COORDINATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkRecoveryCoordinator.swift"
BULK_PREPARED_CLOSURE_COORDINATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkPreparedClosureCoordinator.swift"
BULK_PRODUCTION_MAINTENANCE_OBSERVER="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkProductionMaintenanceObserver.swift"
BULK_PRODUCTION_MUTATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkProductionMutator.swift"
BULK_PRODUCTION_COMPOSITION="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkProductionComposition.swift"
BULK_REPAIR_EXECUTION_COORDINATOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairBulkRepairExecutionCoordinator.swift"
EXPERIMENTAL_ABSENCE_CONTRACT="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairExperimentalAbsenceContract.swift"
EXPERIMENTAL_PROTECTION_COLLECTOR="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairExperimentalProtectionCollector.swift"
EXPERIMENTAL_OBSERVATION_TRANSPORT="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairExperimentalObservationTransport.swift"
EXPERIMENTAL_APP_SERVER_ADAPTER="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairExperimentalAppServerObservationAdapter.swift"
EXPERIMENTAL_PROTECTION_COMPOSITION="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairExperimentalProtectionComposition.swift"
EXPERIMENTAL_COMPATIBILITY_REVIEW="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairExperimentalCompatibilityReview.swift"
LEGACY_SNAPSHOT_REVIEW_SHEET="$APP_SOURCE/GhostRepairReadOnlyReviewSheet.swift"

if grep -nE 'ASM_ISOLATED_DELETE|IsolatedDeleteAcceptance' \
    "$PROJECT_FILE" "$PACKAGE_FILE" "$APP_SOURCE"/*.swift; then
    print -u2 "Isolated Delete acceptance must not be enabled or referenced by the shipping App or package configuration."
    exit 1
fi

if grep -nE \
    'AgentSessionManagerFixtures|FixtureSessionProvider|FixtureOperationHistoryLedger|FixtureData|BulkShippingComposition(TestFixture|AcceptanceTests)|INITIAL_DATA_SOURCE|InventoryMode|inventoryMode|testtube\.2|CodexGhostRepairDisposable(Bundle|Coordinator|Executor|SnapshotReader|SnapshotAcquirer|SnapshotDestination)|CodexGhostRepairBulk(Disposable|ProductionExecution|ProductionDraft|OperationBoundBackup|ProductionBundle|FreshMaintenance|MaintenanceWindow|FixedBackupDestination|LiveBackup|BackupBound|LiveMixed|LiveExecution|LiveOneShot)|CodexGhostRepairBulkRepairExecutionCoordinator|CodexGhostRepairCanonical(AcquisitionSource|SourceFile|SourceRead)|CodexGhostRepairSnapshot(Canonical|Prepared|AcquisitionJournal|PublishedInventory|QuarantinePublisher|OperationalGateSource|RecoveryReader|PackagedReadbackCoordinator)|GhostRepairDestinationLocation|CodexGhostRepairDestination(Preparer|Directory|Preparation|CanaryInspectOnlyCoordinator|CanaryExistingRootPrepareCoordinator|CanaryFixedDirectoryPrepareCoordinator)|CodexGhostRepairProduction(Destination|Policy|RepairBundle)|CodexGhostRepairCategoryA(Execution|Disposable|ProductionRecipe)|CodexGhostRepairPrepared(SnapshotDestination|DestinationBinding)|CodexGhostRepairPublishedSnapshot|CodexGhostRepairSnapshot(Capacity|Partial|Journal)|CodexGhostRepairQuarantineTrash|CodexGhostRepairPlanner' \
    "$APP_SOURCE"/*.swift; then
    print -u2 "Shipping App source references Fixture or disposable private-database code."
    exit 1
fi

if [[ ! -f "$BULK_LIVE_EXECUTION_JOURNAL" ]] \
    || grep -nE '^public |CodexAppServerClient|SessionManagerModel|automaticRetryAllowed: Bool \{ true \}|automaticRestoreAllowed: Bool \{ true \}|repairMutationAuthority: Bool \{ true \}' "$BULK_LIVE_EXECUTION_JOURNAL" \
    || grep -R -n 'CodexGhostRepairBulkLiveExecutionJournal' "$APP_SOURCE" \
    || ! grep -q 'case prepared' "$BULK_LIVE_EXECUTION_JOURNAL" \
    || ! grep -q 'case claimed' "$BULK_LIVE_EXECUTION_JOURNAL" \
    || ! grep -q 'case attempted' "$BULK_LIVE_EXECUTION_JOURNAL" \
    || ! grep -q 'case terminal' "$BULK_LIVE_EXECUTION_JOURNAL" \
    || ! grep -q 'var mutationAttemptCount: Int' "$BULK_LIVE_EXECUTION_JOURNAL" \
    || ! grep -q 'silentSelectionShrinkAllowed: Bool { false }' "$BULK_LIVE_EXECUTION_JOURNAL" \
    || ! grep -q 'confirmation_receipt_id' "$BULK_LIVE_EXECUTION_JOURNAL"; then
    print -u2 "The M4f-18 live execution journal is missing, App-reachable, replayable, restorable, silently shrinkable, or not bound to exact confirmation."
    exit 1
fi

if [[ ! -f "$BULK_LIVE_ONE_SHOT_COORDINATOR" ]] \
    || grep -nE '^public |CodexAppServerClient|SessionManagerModel|productionFactoryAcceptsCallerPath = true|productionConstructionPerformsIO = true|automaticRetryAllowed = true|automaticRestoreAllowed = true|silentSelectionShrinkAllowed = true|liveExecutionAuthorized = true|repairMutationAuthority = true' "$BULK_LIVE_ONE_SHOT_COORDINATOR" \
    || grep -R -n 'CodexGhostRepairBulkLiveOneShot' "$APP_SOURCE" \
    || ! grep -q 'let durableClaimBeforeAttempt = true' "$BULK_LIVE_ONE_SHOT_COORDINATOR" \
    || ! grep -q 'let durableAttemptBeforeMutation = true' "$BULK_LIVE_ONE_SHOT_COORDINATOR" \
    || ! grep -q 'let maximumMutationAttemptCount = 1' "$BULK_LIVE_ONE_SHOT_COORDINATOR" \
    || ! grep -q 'let coldRestartUsesReadbackOnly = true' "$BULK_LIVE_ONE_SHOT_COORDINATOR" \
    || ! grep -q 'mutator.recoverByReadback' "$BULK_LIVE_ONE_SHOT_COORDINATOR" \
    || ! grep -q 'outcome: .notAttempted' "$BULK_LIVE_ONE_SHOT_COORDINATOR"; then
    print -u2 "The M4f-18 one-shot coordinator is missing, App-reachable, path-extensible, replayable, restorable, or lacks cold readback recovery."
    exit 1
fi

if [[ ! -f "$BULK_PRODUCTION_MAINTENANCE_OBSERVER" ]] \
    || grep -nE '^public |SessionManagerModel|acceptsCallerPath|O_WRONLY|O_RDWR|O_CREAT|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO' "$BULK_PRODUCTION_MAINTENANCE_OBSERVER" \
    || ! grep -q 'static func production(' "$BULK_PRODUCTION_MAINTENANCE_OBSERVER" \
    || ! grep -q 'ghostRepairExecutionGate()' "$BULK_PRODUCTION_MAINTENANCE_OBSERVER" \
    || ! grep -q 'gate.stateOpenHandleCount == 0' "$BULK_PRODUCTION_MAINTENANCE_OBSERVER" \
    || ! grep -q 'gate.threadHistoryOpenHandleCount == 0' "$BULK_PRODUCTION_MAINTENANCE_OBSERVER" \
    || ! grep -q 'CodexGhostRepairProductionSQLite(' "$BULK_PRODUCTION_MAINTENANCE_OBSERVER" \
    || ! grep -q 'readOnly: true' "$BULK_PRODUCTION_MAINTENANCE_OBSERVER"; then
    print -u2 "The packaged bulk maintenance observer is public, path-extensible, writable, or missing its gate-first fixed read-only evidence contract."
    exit 1
fi

if [[ ! -f "$BULK_PACKAGED_PLAN_PREPARER" ]] \
    || grep -nE '^public |SessionManagerModel|acceptsCallerPath|automaticRetry|automaticRestore|DELETE FROM|UPDATE |INSERT INTO|BEGIN|COMMIT' "$BULK_PACKAGED_PLAN_PREPARER" \
    || ! grep -q 'receiptID: confirmationReceiptID' "$BULK_PACKAGED_PLAN_PREPARER" \
    || ! grep -q 'phase: .beforeBackup' "$BULK_PACKAGED_PLAN_PREPARER" \
    || ! grep -q 'phase: .beforeBackupRepeat' "$BULK_PACKAGED_PLAN_PREPARER" \
    || ! grep -q 'prepareFixedStorageIfNeeded()' "$BULK_PACKAGED_PLAN_PREPARER" \
    || ! grep -q 'readExactBackup' "$BULK_PACKAGED_PLAN_PREPARER" \
    || ! grep -q 'CodexGhostRepairBulkBackupBoundOperationPlan.prepare' "$BULK_PACKAGED_PLAN_PREPARER" \
    || ! grep -q 'validateReceipt' "$BULK_PACKAGED_PLAN_PREPARER"; then
    print -u2 "The packaged bulk plan preparer is public, path-extensible, replayable, writable, or not bound to one exact receipt and verified backup."
    exit 1
fi

if [[ ! -f "$BULK_PACKAGED_REPAIR_COORDINATOR" ]] \
    || grep -nE '^public |FileManager|URL\(|CSQLite3|sqlite3_|acceptsCallerPath|automaticRetryAllowed: Bool \{ true \}|automaticRestoreAllowed: Bool \{ true \}|silentSelectionShrinkAllowed: Bool \{ true \}' "$BULK_PACKAGED_REPAIR_COORDINATOR" \
    || grep -R -n 'CodexGhostRepairBulkPackagedRepairCoordinator' "$APP_SOURCE" \
    || ! grep -q 'runner.prepare(' "$BULK_PACKAGED_REPAIR_COORDINATOR" \
    || ! grep -q 'runnerFactory(profile.identifier).execute(' "$BULK_PACKAGED_REPAIR_COORDINATOR" \
    || ! grep -q 'itemReports: report.items.map' "$BULK_PACKAGED_REPAIR_COORDINATOR" \
    || ! grep -q 'Do not retry or restore automatically' "$BULK_PACKAGED_REPAIR_COORDINATOR"; then
    print -u2 "The packaged bulk facade is public-internal-bypassing, App-direct, path-capable, replayable, or missing exact itemized terminal readback."
    exit 1
fi

if [[ ! -f "$BULK_LIVE_MIXED_MUTATOR" ]] \
    || grep -nE '^public |CodexAppServerClient|SessionManagerModel|productionFactoryAcceptsCallerPath = true|productionConstructionPerformsIO = true|automaticRetryAllowed = true|automaticRestoreAllowed = true|appWiringAvailable = true|liveExecutionAuthorized = true|repairMutationAuthority = true' "$BULK_LIVE_MIXED_MUTATOR" \
    || grep -R -n 'CodexGhostRepairBulkLiveMixed' "$APP_SOURCE" \
    || ! grep -q 'let productionFactoryAvailable = true' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'let productionConstructionPerformsIO = false' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'let productionFactoryAcceptsCallerPath = false' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'CodexGhostRepairBulkBackupBoundOperationPlan' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'CodexGhostRepairBulkLiveMixedClaim' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'CodexGhostRepairBulkLiveMixedAttempt' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'BEGIN IMMEDIATE' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'try CodexGhostRepairBulkSQLCleanup.apply(database: database,' "$BULK_LIVE_MIXED_MUTATOR" \
    || [[ ! -f "$BULK_SQL_CLEANUP" ]] \
    || grep -nE '^public |FileManager|URL\(|sqlite3_|BEGIN|COMMIT|ROLLBACK' "$BULK_SQL_CLEANUP" \
    || grep -R -n 'CodexGhostRepairBulkSQLCleanup' "$APP_SOURCE" \
    || ! grep -q 'DELETE FROM local_thread_catalog' "$BULK_SQL_CLEANUP" \
    || ! grep -q "UPDATE automation_runs SET status = 'ARCHIVED'" "$BULK_SQL_CLEANUP" \
    || ! grep -q 'let automaticRetryAllowed = false' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'let automaticRestoreAllowed = false' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'let appWiringAvailable = false' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'let liveExecutionAuthorized = false' "$BULK_LIVE_MIXED_MUTATOR" \
    || ! grep -q 'let repairMutationAuthority = false' "$BULK_LIVE_MIXED_MUTATOR"; then
    print -u2 "The M4f-17 live-capable mixed mutator is missing, App-reachable, path-extensible, retryable, restorable, incomplete, or over-authorized."
    exit 1
fi

if [[ ! -f "$BULK_BACKUP_BOUND_OPERATION_PLAN" ]] \
    || grep -nE '^public |CodexAppServerClient|SessionManagerModel|CSQLite3|sqlite3_|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO|acceptsCallerPath = true|performsIO = true|opensSQLite = true|createsBackup = true|createsClaim = true|invokesMutator = true|appWiringAvailable = true|liveExecutionAuthorized = true|repairMutationAuthority = true' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || grep -R -n 'CodexGhostRepairBulkBackupBound' "$APP_SOURCE" \
    || ! grep -q 'CodexGhostRepairBulkStoredPreview' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'CodexGhostRepairBulkProductionBundle.Resolution' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'CodexGhostRepairBulkLiveBackupReceipt' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'case removeCatalogRowAndArchiveAutomation' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'static func decodeValidated' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'let acceptsCallerPath = false' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'let performsIO = false' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'let createsClaim = false' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'let invokesMutator = false' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'let appWiringAvailable = false' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'let liveExecutionAuthorized = false' "$BULK_BACKUP_BOUND_OPERATION_PLAN" \
    || ! grep -q 'let repairMutationAuthority = false' "$BULK_BACKUP_BOUND_OPERATION_PLAN"; then
    print -u2 "The M4f-16 backup-bound operation plan is missing, App-reachable, path-extensible, effectful, incomplete, or over-authorized."
    exit 1
fi

if [[ ! -f "$BULK_MAINTENANCE_COLLECTOR" ]] \
    || grep -nE '^public |static func production|CodexAppServerClient|SessionManagerModel|CSQLite3|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO|acceptsCallerPath = true|acceptsLiveCodexRoot = true|appWiringAvailable = true|automaticRetryAllowed = true|repairMutationAuthority = true' "$BULK_MAINTENANCE_COLLECTOR" \
    || grep -R -n 'CodexGhostRepairBulkFreshMaintenanceCollector' "$APP_SOURCE" \
    || ! grep -q 'CodexGhostRepairBulkProductionBundle.Resolution' "$BULK_MAINTENANCE_COLLECTOR" \
    || ! grep -q 'let freshObservationPerCall = true' "$BULK_MAINTENANCE_COLLECTOR" \
    || ! grep -q 'let fiveDatabaseHandleOwnerEvidenceRequired = true' "$BULK_MAINTENANCE_COLLECTOR" \
    || ! grep -q 'observation.executionGate.stateOpenHandleCount != nil' "$BULK_MAINTENANCE_COLLECTOR" \
    || ! grep -q 'observation.executionGate.threadHistoryOpenHandleCount != nil' "$BULK_MAINTENANCE_COLLECTOR" \
    || ! grep -q 'struct CodexGhostRepairBulkMaintenanceWindow' "$BULK_MAINTENANCE_COLLECTOR" \
    || ! grep -q 'let createsBackup = false' "$BULK_MAINTENANCE_COLLECTOR" \
    || ! grep -q 'let createsClaim = false' "$BULK_MAINTENANCE_COLLECTOR" \
    || ! grep -q 'let acceptsLiveCodexRoot = false' "$BULK_MAINTENANCE_COLLECTOR" \
    || ! grep -q 'let appWiringAvailable = false' "$BULK_MAINTENANCE_COLLECTOR" \
    || ! grep -q 'let repairMutationAuthority = false' "$BULK_MAINTENANCE_COLLECTOR"; then
    print -u2 "The M4f-13 fresh bulk maintenance collector is missing, App-reachable, incomplete, retryable, effectful, or not bound to the exact M4f-12 bundle."
    exit 1
fi

if [[ ! -f "$BULK_FIXED_BACKUP_DESTINATION" ]] \
    || grep -nE '^public |static func production|CodexAppServerClient|SessionManagerModel|CSQLite3|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO|acceptsCallerPath = true|acceptsLiveCodexRoot = true|appWiringAvailable = true|automaticRetryAllowed = true|overwritesExistingOperation = true|createsDirectory = true|createsBackupBytes = true|repairMutationAuthority = true' "$BULK_FIXED_BACKUP_DESTINATION" \
    || grep -R -n 'CodexGhostRepairBulkFixedBackupDestination' "$APP_SOURCE" \
    || ! grep -q 'CodexGhostRepairBulkProductionBundle.Resolution' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'CodexGhostRepairBulkMaintenanceWindow' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let fixedManagerNamespace = true' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let operationIdentityIsDeterministic = true' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let inspectionIsFreshPerCall = true' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let coldReadbackSupported = true' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let acceptsCallerPath = false' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let overwritesExistingOperation = false' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let createsDirectory = false' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let createsBackupBytes = false' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let createsClaim = false' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let acceptsLiveCodexRoot = false' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let appWiringAvailable = false' "$BULK_FIXED_BACKUP_DESTINATION" \
    || ! grep -q 'let repairMutationAuthority = false' "$BULK_FIXED_BACKUP_DESTINATION"; then
    print -u2 "The M4f-14 fixed operation-backup destination is missing, App-reachable, effectful, retryable, overwrite-capable, or not bound to the exact M4f-12/M4f-13 evidence."
    exit 1
fi

if [[ ! -f "$BULK_LIVE_BACKUP_TRANSPORT" ]] \
    || grep -nE '^public |CodexAppServerClient|SessionManagerModel|CSQLite3|sqlite3_|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO|productionFactoryAcceptsCallerPath = true|overwritesExistingOperation = true|retriesPartialOperation = true|automaticRestoreAllowed = true|automaticCleanupAllowed = true|opensSQLite = true|createsClaim = true|appWiringAvailable = true|liveExecutionAuthorized = true|repairMutationAuthority = true' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || grep -R -n 'CodexGhostRepairBulkLiveBackup' "$APP_SOURCE" \
    || ! grep -q 'static func production(' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'CodexGhostRepairSnapshotCanonicalFile.allCases' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'static let destinationRecordFileName = "destination.json"' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'static let receiptFileName = "receipt.json"' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'O_WRONLY | O_CREAT | O_EXCL' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'guard after == fingerprint' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'let productionConstructionPerformsIO = false' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'let productionFactoryAcceptsCallerPath = false' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'let destinationRecordWrittenBeforeRawBytes = true' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'let receiptManifestWrittenLast = true' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'let overwritesExistingOperation = false' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'let retriesPartialOperation = false' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'let createsClaim = false' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'let appWiringAvailable = false' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'let liveExecutionAuthorized = false' "$BULK_LIVE_BACKUP_TRANSPORT" \
    || ! grep -q 'let repairMutationAuthority = false' "$BULK_LIVE_BACKUP_TRANSPORT"; then
    print -u2 "The M4f-15 live-capable backup transport is missing, App-reachable, path-extensible, retryable, overwrite-capable, SQLite-backed, or over-authorized."
    exit 1
fi

if grep -n 'AgentSessionManagerFixtures.*Frameworks' "$PROJECT_FILE"; then
    print -u2 "The shipping App target links AgentSessionManagerFixtures."
    exit 1
fi

if grep -n 'AGENT_SESSION_MANAGER_RESEARCH' "$PROJECT_FILE"; then
    print -u2 "The shipping Xcode project enables research-only Ghost Repair code."
    exit 1
fi

if [[ ! -f "$INSPECT_ONLY_SOURCE" ]] \
    || grep -nE 'AGENT_SESSION_MANAGER_RESEARCH|CodexGhostRepairProductionDestinationCapability|CodexGhostRepairDestinationPreparer|directoryCreator|sqlite3_|mkdir\(|chmod\(' "$INSPECT_ONLY_SOURCE"; then
    print -u2 "The shipping inspect-only coordinator is missing or contains research/effect authority."
    exit 1
fi

if [[ ! -f "$PRODUCTION_POLICY_SOURCE" ]] \
    || head -n 8 "$PRODUCTION_POLICY_SOURCE" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'FileManager|sqlite3_|mkdir\(|chmod\(' "$PRODUCTION_POLICY_SOURCE"; then
    print -u2 "The shipping production policy is missing, research-gated, or effectful."
    exit 1
fi

if [[ ! -f "$DESTINATION_CANARY_SOURCE" ]] \
    || ! grep -q 'public struct CodexGhostRepairDestinationCanaryCapabilities' "$DESTINATION_CANARY_SOURCE" \
    || ! grep -q 'public static func packagedInspectOnly()' "$DESTINATION_CANARY_SOURCE" \
    || ! grep -q 'public static func packagedFixedDirectoryPrepare()' "$DESTINATION_CANARY_SOURCE" \
    || ! grep -q 'var filesystemAuthority: Bool { false }' "$DESTINATION_CANARY_SOURCE" \
    || ! grep -q 'var repairMutationAuthority: Bool { false }' "$DESTINATION_CANARY_SOURCE"; then
    print -u2 "The shipping destination capability/factory contract is missing or grants authority."
    exit 1
fi

if grep -R -nE 'CodexGhostRepairDestinationCanary(ExistingRootPrepareCoordinator|TestOwnedAdapter)|CodexGhostRepairDisposable(Coordinator|Executor)|CodexGhostRepairPlanner|CodexGhostRepairFaultInjection' \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Tests" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/App/AgentSessionManager/AgentSessionManagerAppTests"; then
    print -u2 "Retired preparation and execution prototypes must not return to source or tests; use the current fixed-directory and bulk cleanup flows."
    exit 1
fi

if [[ ! -f "$E58_LAYOUT_SOURCE" ]] \
    || head -n 8 "$E58_LAYOUT_SOURCE" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'sqlite3_|mkdir\(|chmod\(|removeItem|delete' "$E58_LAYOUT_SOURCE"; then
    print -u2 "The E58 fixed layout is missing, research-gated, or effectful."
    exit 1
fi

if [[ ! -f "$E58_PREPARE_SOURCE" ]] \
    || head -n 10 "$E58_PREPARE_SOURCE" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |sqlite3_|chmod\(|removeItem|unlink\(|rmdir\(' "$E58_PREPARE_SOURCE" \
    || ! grep -q 'fixedManagerPrivateDirectoryPrepare' "$E58_PREPARE_SOURCE" \
    || ! grep -q 'CodexGhostRepairDestinationCanaryFixedLayout' "$E58_PREPARE_SOURCE" \
    || ! grep -q 'consumedRequestIDs' "$E58_PREPARE_SOURCE" \
    || ! grep -q 'consumedEvidenceTokens' "$E58_PREPARE_SOURCE"; then
    print -u2 "The exact E58 Core candidate is missing, public/research-gated, or exceeds its fixed-directory effect boundary."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_CANONICAL_SOURCE" ]] \
    || head -n 8 "$SNAPSHOT_CANONICAL_SOURCE" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'sqlite3_|O_WRONLY|O_RDWR|createDirectory|copyItem|moveItem|removeItem|chmod\(|fchmod\(|unlink\(|rename\(' "$SNAPSHOT_CANONICAL_SOURCE" \
    || ! grep -q 'static func production(' "$SNAPSHOT_CANONICAL_SOURCE" \
    || ! grep -q 'profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32' "$SNAPSHOT_CANONICAL_SOURCE" \
    || ! grep -q 'O_RDONLY | O_NOFOLLOW' "$SNAPSHOT_CANONICAL_SOURCE" \
    || ! grep -q 'let writesCodexDatabaseFiles = false' "$SNAPSHOT_CANONICAL_SOURCE" \
    || ! grep -q 'let acceptsCallerPath = false' "$SNAPSHOT_CANONICAL_SOURCE" \
    || ! grep -q 'let repairMutationAuthority = false' "$SNAPSHOT_CANONICAL_SOURCE"; then
    print -u2 "The M1b-2 canonical snapshot source is missing, research-gated, path-extensible, or write-capable."
    exit 1
fi

if [[ ! -f "$PRODUCTION_REPAIR_BUNDLE" ]] \
    || head -n 8 "$PRODUCTION_REPAIR_BUNDLE" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'import CSQLite3|sqlite3_|O_WRONLY|O_RDWR|createDirectory|copyItem|moveItem|removeItem|chmod\(|fchmod\(|unlink\(|rename\(|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO' "$PRODUCTION_REPAIR_BUNDLE" \
    || ! grep -q 'static func production() -> Self' "$PRODUCTION_REPAIR_BUNDLE" \
    || ! grep -q 'let acceptsCallerPath = false' "$PRODUCTION_REPAIR_BUNDLE" \
    || ! grep -q 'let constructionPerformsIO = false' "$PRODUCTION_REPAIR_BUNDLE" \
    || ! grep -q 'let opensSQLite = false' "$PRODUCTION_REPAIR_BUNDLE" \
    || ! grep -q 'let writesCodexDatabaseFiles = false' "$PRODUCTION_REPAIR_BUNDLE" \
    || ! grep -q 'let repairMutationAuthority = false' "$PRODUCTION_REPAIR_BUNDLE" \
    || ! grep -q 'let maximumTargetCount = 2' "$PRODUCTION_REPAIR_BUNDLE" \
    || ! grep -q 'let categoryAOnly = true' "$PRODUCTION_REPAIR_BUNDLE"; then
    print -u2 "The M3a production repair bundle is missing, path-extensible, effectful, or over-authorized."
    exit 1
fi

if [[ ! -f "$CATEGORY_A_EXECUTION_CONTRACT" ]] \
    || head -n 8 "$CATEGORY_A_EXECUTION_CONTRACT" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |import CSQLite3|sqlite3_|FileManager|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|chmod\(|fchmod\(|unlink\(|rename\(|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO' "$CATEGORY_A_EXECUTION_CONTRACT" \
    || ! grep -q 'let maximumTargetCount = 2' "$CATEGORY_A_EXECUTION_CONTRACT" \
    || ! grep -q 'let categoryAOnly = true' "$CATEGORY_A_EXECUTION_CONTRACT" \
    || ! grep -q 'var allOrNothing: Bool { true }' "$CATEGORY_A_EXECUTION_CONTRACT" \
    || ! grep -q 'var silentSelectionShrinkAllowed: Bool { false }' "$CATEGORY_A_EXECUTION_CONTRACT" \
    || ! grep -q 'var requiresFreshExecutionSnapshotBinding: Bool { true }' "$CATEGORY_A_EXECUTION_CONTRACT" \
    || ! grep -q 'var requiresNewExactConfirmation: Bool { true }' "$CATEGORY_A_EXECUTION_CONTRACT" \
    || ! grep -q 'let confirmationAuthority = false' "$CATEGORY_A_EXECUTION_CONTRACT" \
    || ! grep -q 'let repairMutationAuthority = false' "$CATEGORY_A_EXECUTION_CONTRACT"; then
    print -u2 "The M3b Category A execution contract is missing, effectful, public, or over-authorized."
    exit 1
fi

if [[ ! -f "$CATEGORY_A_EXECUTION_PREPARATION" ]] \
    || head -n 8 "$CATEGORY_A_EXECUTION_PREPARATION" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |import CSQLite3|sqlite3_|FileManager|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|chmod\(|fchmod\(|unlink\(|rename\(|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO' "$CATEGORY_A_EXECUTION_PREPARATION" \
    || ! grep -q 'let maximumTargetCount = 2' "$CATEGORY_A_EXECUTION_PREPARATION" \
    || ! grep -q 'let previewAuthorityIsAuditOnly = true' "$CATEGORY_A_EXECUTION_PREPARATION" \
    || ! grep -q 'let separatesFreshExecutionAuthority = true' "$CATEGORY_A_EXECUTION_PREPARATION" \
    || ! grep -q 'let repairMutationAuthority = false' "$CATEGORY_A_EXECUTION_PREPARATION" \
    || ! grep -q 'let automaticRetry = false' "$CATEGORY_A_EXECUTION_PREPARATION"; then
    print -u2 "The M3e Category A preparation contract is missing, effectful, public, or over-authorized."
    exit 1
fi

if [[ ! -f "$CATEGORY_A_EXECUTION_JOURNAL" ]] \
    || head -n 8 "$CATEGORY_A_EXECUTION_JOURNAL" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |FileManager|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|chmod\(|fchmod\(|unlink\(|rename\(|DELETE FROM' "$CATEGORY_A_EXECUTION_JOURNAL" \
    || ! grep -q 'case recoveryRequired' "$CATEGORY_A_EXECUTION_JOURNAL" \
    || ! grep -q 'var automaticRetryAllowed: Bool { false }' "$CATEGORY_A_EXECUTION_JOURNAL" \
    || ! grep -q 'var repairMutationAuthority: Bool { false }' "$CATEGORY_A_EXECUTION_JOURNAL" \
    || ! grep -q 'confirmation_authority, repair_mutation_authority' "$CATEGORY_A_EXECUTION_JOURNAL" \
    || ! grep -q 'automatic_retry_allowed' "$CATEGORY_A_EXECUTION_JOURNAL"; then
    print -u2 "The M3e manager one-shot journal is missing, filesystem-capable, public, replayable, or over-authorized."
    exit 1
fi

if [[ ! -f "$CATEGORY_A_DISPOSABLE_EXECUTOR" ]] \
    || ! head -n 8 "$CATEGORY_A_DISPOSABLE_EXECUTOR" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |static func production|CodexAppServerClient|SessionManagerModel' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let testOwnedDisposableCopiesOnly = true' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let durableClaimBeforeMutation = true' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let replaysMutation = false' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let retriesUnknown = false' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let acceptsLiveCodexRoot = false' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let appWiringAvailable = false' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let packagedRepairAuthority = false' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'BEGIN IMMEDIATE' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'func recoverByReadback' "$CATEGORY_A_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'automaticRetryAllowed: false' "$CATEGORY_A_DISPOSABLE_EXECUTOR"; then
    print -u2 "The M3c disposable Category A executor is missing, shipping-visible, replayable, or over-authorized."
    exit 1
fi

if [[ ! -f "$BULK_DISPOSABLE_EXECUTOR" ]] \
    || grep -nE '^public |static func production|CodexAppServerClient|SessionManagerModel|acceptsLiveCodexRoot = true|appWiringAvailable = true|packagedRepairAuthority = true' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let testOwnedDisposableCopiesOnly = true' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let mixedCategoryBatch = true' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let oneDesktopTransaction = true' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let durableClaimBeforeMutation = true' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let automaticRetryAllowed = false' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let acceptsLiveCodexRoot = false' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let appWiringAvailable = false' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'let packagedRepairAuthority = false' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'BEGIN IMMEDIATE' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'func recoverByReadback' "$BULK_DISPOSABLE_EXECUTOR" \
    || ! grep -q 'automaticRetryAllowed: false' "$BULK_DISPOSABLE_EXECUTOR"; then
    print -u2 "The M4c mixed bulk disposable executor is missing, App-reachable, replayable, path-extensible, or over-authorized."
    exit 1
fi

if [[ ! -f "$BULK_PRODUCTION_EXECUTION_CONTRACT" ]] \
    || grep -nE '^public |import CSQLite3|sqlite3_|FileManager|URL\(|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|chmod\(|fchmod\(|unlink\(|rename\(|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO|static func production|SessionManagerModel|managerClaimAvailable = true|filesystemMutationAuthority = true|repairMutationAuthority = true|appWiringAvailable = true|acceptsLiveCodexRoot = true' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let contractOnly = true' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let requiresFiveDatabaseHandleCounts = true' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let requiresFreshProcessEvidence = true' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let requiresOperationBoundVerifiedBackup = true' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let requiresWholeBatchConfirmationReceipt = true' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let plan: CodexGhostRepairBulkExecutionPlan' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let backup: CodexGhostRepairBulkExecutionBackupReceipt' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'try plan.validateDigest()' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'try backup.validate()' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'plan.selectedItems.map' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let managerClaimAvailable = false' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let filesystemMutationAuthority = false' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let repairMutationAuthority = false' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let appWiringAvailable = false' "$BULK_PRODUCTION_EXECUTION_CONTRACT" \
    || ! grep -q 'let acceptsLiveCodexRoot = false' "$BULK_PRODUCTION_EXECUTION_CONTRACT"; then
    print -u2 "The M4f bulk production execution contract is missing, effectful, App-reachable, path-extensible, or over-authorized."
    exit 1
fi

if [[ ! -f "$BULK_PRODUCTION_EXECUTION_JOURNAL" ]] \
    || ! head -n 8 "$BULK_PRODUCTION_EXECUTION_JOURNAL" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |FileManager|URL\(|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|chmod\(|fchmod\(|unlink\(|rename\(|SessionManagerModel|automaticRetryAllowed: Bool \{ true \}|automaticRestoreAllowed: Bool \{ true \}|silentSelectionShrinkAllowed: Bool \{ true \}|repairMutationAuthority: Bool \{ true \}' "$BULK_PRODUCTION_EXECUTION_JOURNAL" \
    || ! grep -q "phase IN ('prepared', 'claimed', 'attempted', 'terminal')" "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteStateStore.swift" \
    || ! grep -q 'mutation_attempt_count BETWEEN 0 AND 1' "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteStateStore.swift" \
    || ! grep -q 'automatic_retry_allowed = 0' "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteStateStore.swift" \
    || ! grep -q 'automatic_restore_allowed = 0' "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteStateStore.swift" \
    || ! grep -q 'silent_selection_shrink_allowed = 0' "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteStateStore.swift"; then
    print -u2 "The M4f manager-owned bulk execution journal is missing, shipping-visible, path-capable, replayable, restorable, or silently shrinkable."
    exit 1
fi

if [[ ! -f "$BULK_REPAIR_EXECUTION_COORDINATOR" ]] \
    || ! head -n 8 "$BULK_REPAIR_EXECUTION_COORDINATOR" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |FileManager|URL\(|CSQLite3|sqlite3_|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO|StateStoreLocation|CodexAppServerClient|SessionManagerModel|static func production|automaticRetryAllowed: Bool \{ true \}|automaticRestoreAllowed: Bool \{ true \}|silentSelectionShrinkAllowed: Bool \{ true \}' "$BULK_REPAIR_EXECUTION_COORDINATOR" \
    || grep -R -n 'CodexGhostRepairBulkRepairExecutionCoordinator' "$APP_SOURCE" \
    || ! grep -q 'case .claimed:' "$BULK_REPAIR_EXECUTION_COORDINATOR" \
    || ! grep -q 'case .attempted:' "$BULK_REPAIR_EXECUTION_COORDINATOR" \
    || ! grep -q 'recoverByReadback' "$BULK_REPAIR_EXECUTION_COORDINATOR" \
    || ! grep -q 'confirmationReceiptID == draft.confirmationReceiptID' "$BULK_REPAIR_EXECUTION_COORDINATOR" \
    || ! grep -q 'itemReports: report.items.map' "$BULK_REPAIR_EXECUTION_COORDINATOR" \
    || ! grep -q 'let category: CodexGhostRepairCategory' "$BULK_PRODUCTION_EXECUTION_JOURNAL"; then
    print -u2 "The M4f deterministic bulk coordinator is missing, shipping-visible, path-capable, replayable, or unable to preserve item categories across cold readback."
    exit 1
fi

if [[ ! -f "$BULK_PRODUCTION_DRAFT_COLLECTOR" ]] \
    || grep -nE '^public |FileManager|URL\(|CSQLite3|sqlite3_|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO|StateStoreLocation|CodexAppServerClient|SessionManagerModel|static func production|automaticRetryAllowed = true|automaticRestoreAllowed = true|silentSelectionShrinkAllowed = true' "$BULK_PRODUCTION_DRAFT_COLLECTOR" \
    || grep -R -n 'CodexGhostRepairBulkProductionDraftCollector' "$APP_SOURCE" \
    || ! grep -q 'case beforeBackup' "$BULK_PRODUCTION_DRAFT_COLLECTOR" \
    || ! grep -q 'case afterBackup' "$BULK_PRODUCTION_DRAFT_COLLECTOR" \
    || ! grep -q 'createOrReadExactBackup' "$BULK_PRODUCTION_DRAFT_COLLECTOR" \
    || ! grep -q 'confirmationReceiptID ==' "$BULK_PRODUCTION_DRAFT_COLLECTOR"; then
    print -u2 "The M4f bulk production draft collector is missing, App-reachable, path-capable, replayable, or does not preserve the required plan-gate-backup-gate sequence."
    exit 1
fi

if [[ ! -f "$BULK_OPERATION_BACKUP_TRANSPORT" ]] \
    || ! head -n 8 "$BULK_OPERATION_BACKUP_TRANSPORT" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |static func production|CodexAppServerClient|SessionManagerModel|acceptsLiveCodexRoot = true|appWiringAvailable = true|repairMutationAuthority = true|overwritesExistingOperation = true|retriesPartialOperation = true|automaticRestoreAllowed = true|automaticCleanupAllowed = true' "$BULK_OPERATION_BACKUP_TRANSPORT" \
    || grep -R -n 'CodexGhostRepairBulkOperationBoundBackupTransport' "$APP_SOURCE" \
    || ! grep -q 'source.researchTestMirrorOnly' "$BULK_OPERATION_BACKUP_TRANSPORT" \
    || ! grep -q 'O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC' "$BULK_OPERATION_BACKUP_TRANSPORT" \
    || ! grep -q 'let after = try source.fingerprint()' "$BULK_OPERATION_BACKUP_TRANSPORT" \
    || ! grep -q 'guard after == fingerprint' "$BULK_OPERATION_BACKUP_TRANSPORT" \
    || ! grep -q 'actualMembers == expectedMembers' "$BULK_OPERATION_BACKUP_TRANSPORT" \
    || ! grep -q 'func readExactBackup' "$BULK_OPERATION_BACKUP_TRANSPORT" \
    || ! grep -q 'receipt == draft.backup' "$BULK_OPERATION_BACKUP_TRANSPORT" \
    || ! grep -q 'try writeManifestLast' "$BULK_OPERATION_BACKUP_TRANSPORT"; then
    print -u2 "The M4f operation-bound backup transport is missing, shipping-visible, live-capable, replayable, restorable, or lacks exact durable readback."
    exit 1
fi

if [[ ! -f "$BULK_PRODUCTION_COMPOSITION" ]] \
    || ! head -n 8 "$BULK_PRODUCTION_COMPOSITION" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |FileManager|URL\(|CSQLite3|sqlite3_|static func production|CodexAppServerClient|SessionManagerModel|acceptsCallerPath = true|automaticRetryAllowed = true|automaticRestoreAllowed = true|appWiringAvailable = true|acceptsLiveCodexRoot = true' "$BULK_PRODUCTION_COMPOSITION" \
    || grep -R -n 'CodexGhostRepairBulkProductionComposition' "$APP_SOURCE" \
    || ! grep -q 'let exactPlanToTerminalReport = true' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'let operationBoundBackupReadback = true' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'let oneShotManagerJournal = true' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'let mixedCategoryMutation = true' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'source.researchTestMirrorOnly' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'CodexGhostRepairBulkProductionDraftCollector' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'CodexGhostRepairBulkProductionMutator' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'CodexGhostRepairBulkRepairExecutionCoordinator' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'let acceptsCallerPath = false' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'let automaticRetryAllowed = false' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'let automaticRestoreAllowed = false' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'let appWiringAvailable = false' "$BULK_PRODUCTION_COMPOSITION" \
    || ! grep -q 'let acceptsLiveCodexRoot = false' "$BULK_PRODUCTION_COMPOSITION"; then
    print -u2 "The M4f bulk production composition is missing, shipping-visible, path-capable, replayable, restorable, or does not bind the exact verified components."
    exit 1
fi

if [[ ! -f "$BULK_PRODUCTION_BUNDLE" ]] \
    || grep -nE '^public |static func production|CodexAppServerClient|SessionManagerModel|CSQLite3|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO|acceptsCallerPath = true|acceptsLiveCodexRoot = true|appWiringAvailable = true|repairMutationAuthority = true' "$BULK_PRODUCTION_BUNDLE" \
    || grep -R -n 'CodexGhostRepairBulkProductionBundle' "$APP_SOURCE" \
    || ! grep -q 'let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems' "$BULK_PRODUCTION_BUNDLE" \
    || ! grep -q 'let mixedOrdinaryAndAutomation = true' "$BULK_PRODUCTION_BUNDLE" \
    || ! grep -q 'let exactColdReadbackSourceRequired = true' "$BULK_PRODUCTION_BUNDLE" \
    || ! grep -q 'let selectedOnlySourceRequired = true' "$BULK_PRODUCTION_BUNDLE" \
    || ! grep -q 'coldReadback storedPreview: CodexGhostRepairBulkStoredPreview' "$BULK_PRODUCTION_BUNDLE" \
    || ! grep -q 'let acceptsCallerPath = false' "$BULK_PRODUCTION_BUNDLE" \
    || grep -q 'let appWiringAvailable' "$BULK_PRODUCTION_BUNDLE" \
    || ! grep -q 'let acceptsLiveCodexRoot: Bool' "$BULK_PRODUCTION_BUNDLE" \
    || ! grep -q 'acceptsLiveCodexRoot: false' "$BULK_PRODUCTION_BUNDLE" \
    || ! grep -q 'acceptsLiveCodexRoot: true' "$BULK_PRODUCTION_BUNDLE" \
    || ! grep -q 'let repairMutationAuthority = false' "$BULK_PRODUCTION_BUNDLE"; then
    print -u2 "The M4f-12 dedicated bulk production bundle is missing, App-reachable, caller-path-capable, effectful, mutation-authorized, or confuses global capabilities with per-resolution live-root evidence."
    exit 1
fi

if [[ ! -f "$BULK_PRODUCTION_MUTATOR" ]] \
    || ! head -n 8 "$BULK_PRODUCTION_MUTATOR" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |static func production|CodexAppServerClient|SessionManagerModel|acceptsLiveCodexRoot = true|appWiringAvailable = true|automaticRetryAllowed = true|automaticRestoreAllowed = true|acceptsCallerPath = true' "$BULK_PRODUCTION_MUTATOR" \
    || grep -R -n 'CodexGhostRepairBulkProductionMutator' "$APP_SOURCE" \
    || ! grep -q 'let mixedCategoryBatch = true' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'let requiresDurableExternalClaimAndAttempt = true' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'let requiresExactOperationBoundBackup = true' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'let testOwnedCanonicalSourceOnly = true' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'source.researchTestMirrorOnly' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'backup == draft.backup' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'try desktop.execute("BEGIN IMMEDIATE")' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'automationStableFieldsDigest' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'func recoverByReadback' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'let automaticRetryAllowed = false' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'let automaticRestoreAllowed = false' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'let appWiringAvailable = false' "$BULK_PRODUCTION_MUTATOR" \
    || ! grep -q 'let acceptsLiveCodexRoot = false' "$BULK_PRODUCTION_MUTATOR"; then
    print -u2 "The M4f mixed production mutator is missing, shipping-visible, live-capable, replayable, restorable, or lacks exact backup and cold readback guards."
    exit 1
fi

if [[ ! -f "$CATEGORY_A_PRODUCTION_RECIPE" ]] \
    || ! head -n 8 "$CATEGORY_A_PRODUCTION_RECIPE" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |static func production|CodexAppServerClient|SessionManagerModel|acceptsLiveCodexRoot = true|appWiringAvailable = true|packagedRepairAuthority = true' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'let markerProtectedTestMirrorsOnly = true' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'let operationBoundExecutionSnapshot = true' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'let freshAuthorityReplacesPreviewCounters = true' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'let managerClaimBeforeMutation = true' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'let recoveryReplaysMutation = false' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'let acceptsLiveCodexRoot = false' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'let appWiringAvailable = false' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'let packagedRepairAuthority = false' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'O_RDONLY | O_NOFOLLOW | O_CLOEXEC' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'fsync(descriptor)' "$CATEGORY_A_PRODUCTION_RECIPE" \
    || ! grep -q 'case afterManagerClaim' "$CATEGORY_A_PRODUCTION_RECIPE"; then
    print -u2 "The M3f production recipe is missing, shipping-visible, replayable, or over-authorized."
    exit 1
fi

if [[ ! -f "$CATEGORY_A_REPAIR_ACTION" ]] \
    || grep -nE 'import CSQLite3|sqlite3_|FileManager|URL\(|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|chmod\(|fchmod\(|unlink\(|rename\(|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO' "$CATEGORY_A_REPAIR_ACTION" \
    || ! grep -q 'public static let packagedDefaultBlocked' "$CATEGORY_A_REPAIR_ACTION" \
    || ! grep -q '#if AGENT_SESSION_MANAGER_RESEARCH' "$CATEGORY_A_REPAIR_ACTION" \
    || ! grep -q 'public enum CodexGhostRepairCategoryARepairCoordinatorFactory' "$CATEGORY_A_REPAIR_ACTION" \
    || grep -R -n 'CodexGhostRepairCategoryARepairCoordinatorFactory' "$APP_SOURCE" \
    || ! grep -q 'reviewAvailable: false' "$CATEGORY_A_REPAIR_ACTION" \
    || ! grep -q 'executionAvailable: false' "$CATEGORY_A_REPAIR_ACTION" \
    || ! grep -q 'public var acceptsCallerPath: Bool { false }' "$CATEGORY_A_REPAIR_ACTION" \
    || ! grep -q 'public var automaticRetryAllowed: Bool { false }' "$CATEGORY_A_REPAIR_ACTION" \
    || ! grep -q 'public var restoreAuthority: Bool { false }' "$CATEGORY_A_REPAIR_ACTION" \
    || ! grep -q 'public var cleanupAuthority: Bool { false }' "$CATEGORY_A_REPAIR_ACTION" \
    || ! grep -q 'case unknown' "$CATEGORY_A_REPAIR_ACTION" \
    || ! grep -q 'case notAttempted' "$CATEGORY_A_REPAIR_ACTION"; then
    print -u2 "The retired M3g Category A factory is not research-only, or its preserved action contract is missing, effectful, path-extensible, or over-authorized."
    exit 1
fi

if [[ ! -f "$CATEGORY_A_REPAIR_REVIEW" ]] \
    || grep -nE 'AGENT_SESSION_MANAGER_RESEARCH|import CSQLite3|sqlite3_|CodexGhostRepairCategoryAProductionRecipe|CodexGhostRepairCategoryADisposableExecutor|O_WRONLY|O_RDWR|O_CREAT|copyItem|moveItem|removeItem|chmod\(|fchmod\(|unlink\(|rename\(|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO' "$CATEGORY_A_REPAIR_REVIEW" \
    || grep -nE '^public |static func packagedRepair|executionAvailable: true|automaticRetryAllowed: true|restoreAuthority: true|cleanupAuthority: true' "$CATEGORY_A_REPAIR_REVIEW" \
    || ! grep -q 'CodexGhostRepairCategoryAPackagedSavedPreviewReader' "$CATEGORY_A_REPAIR_REVIEW" \
    || ! grep -q 'CodexGhostRepairCategoryAPackagedChallengeJournal' "$CATEGORY_A_REPAIR_REVIEW" \
    || ! grep -q 'CodexGhostRepairCategoryARepairCapabilities.packagedReviewOnly' "$CATEGORY_A_REPAIR_REVIEW" \
    || ! grep -q 'func confirmAndRepair' "$CATEGORY_A_REPAIR_REVIEW" \
    || ! grep -q 'Category A repair execution is unavailable' "$CATEGORY_A_REPAIR_REVIEW" \
    || ! grep -q 'static func packagedReviewOnly' "$CATEGORY_A_REPAIR_REVIEW"; then
    print -u2 "The M3h packaged repair review composition is missing, path-extensible, effectful, or execution-capable."
    exit 1
fi

if [[ ! -f "$CATEGORY_A_PRODUCTION_REVIEW" ]] \
    || grep -nE 'AGENT_SESSION_MANAGER_RESEARCH|CodexGhostRepairCategoryAProductionRecipe|CodexGhostRepairCategoryADisposableExecutor|BEGIN|COMMIT|DELETE FROM|UPDATE |INSERT INTO|automaticRetryAllowed: true|executionAvailable: true|repairMutationAuthority: true' "$CATEGORY_A_PRODUCTION_REVIEW" \
    || grep -nE '^public |URL\(|acceptsCallerPath: true|restoreAuthority: true|cleanupAuthority: true' "$CATEGORY_A_PRODUCTION_REVIEW" \
    || ! grep -q 'CodexGhostRepairCanonicalQueryOnlyReader.read' "$CATEGORY_A_PRODUCTION_REVIEW" \
    || ! grep -q 'CodexGhostRepairSnapshotCanonicalSource' "$CATEGORY_A_PRODUCTION_REVIEW" \
    || ! grep -q 'CodexGhostRepairExperimentalAbsenceRegistry' "$CATEGORY_A_PRODUCTION_REVIEW" \
    || ! grep -q 'operationalGate.isClear' "$CATEGORY_A_PRODUCTION_REVIEW" \
    || ! grep -q 'static func production' "$CATEGORY_A_PRODUCTION_REVIEW"; then
    print -u2 "The M3i production fresh review source is missing, path-extensible, mutation-capable, or insufficiently gated."
    exit 1
fi

if grep -R -nE 'CodexGhostRepairCategoryAProductionReviewMaterialCollector|packagedProductionReview' "$APP_SOURCE"; then
    print -u2 "The M3j App bypasses the public no-path Category A coordinator facade."
    exit 1
fi

if [[ ! -f "$CATEGORY_A_REPAIR_EXECUTION" ]] \
    || grep -nE '^public |AGENT_SESSION_MANAGER_RESEARCH|CodexGhostRepairCategoryAProductionRecipe|CodexGhostRepairCategoryADisposableExecutor|acceptsCallerPath: true|automaticRetryAllowed: true|restoreAuthority: true|cleanupAuthority: true' "$CATEGORY_A_REPAIR_EXECUTION" \
    || ! grep -q 'CodexGhostRepairCategoryAPreparedRepairBinding' "$CATEGORY_A_REPAIR_EXECUTION" \
    || ! grep -q 'consumeAuthorization' "$CATEGORY_A_REPAIR_EXECUTION" \
    || ! grep -q 'executionSnapshotManifestHash:' "$CATEGORY_A_REPAIR_EXECUTION" \
    || ! grep -q 'recoverByReadback' "$CATEGORY_A_REPAIR_EXECUTION" \
    || ! grep -q 'Do not retry the repair' "$CATEGORY_A_REPAIR_EXECUTION"; then
    print -u2 "The M3i-c execution composition is missing, public, replayable, or over-authorized."
    exit 1
fi

if grep -R -nE 'CodexGhostRepairCategoryARepairExecutionCoordinator|packagedExecutionCandidate' "$APP_SOURCE"; then
    print -u2 "The M3j App names the internal Category A execution composition."
    exit 1
fi

if [[ ! -f "$CATEGORY_A_PRODUCTION_MUTATOR" ]] \
    || grep -nE '^public |AGENT_SESSION_MANAGER_RESEARCH|acceptsCallerPath = true|automaticRetryAllowed = true|automaticRestoreAllowed = true|O_CREAT|createDirectory|copyItem|moveItem|removeItem|unlink\(|rename\(|INSERT INTO|automation_runs|UPDATE automations' "$CATEGORY_A_PRODUCTION_MUTATOR" \
    || ! grep -q 'import CSQLite3' "$CATEGORY_A_PRODUCTION_MUTATOR" \
    || ! grep -q 'actor CodexGhostRepairCategoryAProductionMutator' "$CATEGORY_A_PRODUCTION_MUTATOR" \
    || ! grep -q 'static func production() -> Self' "$CATEGORY_A_PRODUCTION_MUTATOR" \
    || ! grep -q 'let acceptsCallerPath = false' "$CATEGORY_A_PRODUCTION_MUTATOR" \
    || ! grep -q 'let desktopWriteDatabaseCount = 1' "$CATEGORY_A_PRODUCTION_MUTATOR" \
    || ! grep -q 'let readbackOnlyDatabaseCount = 4' "$CATEGORY_A_PRODUCTION_MUTATOR" \
    || ! grep -q 'let requiresDurableExternalClaim = true' "$CATEGORY_A_PRODUCTION_MUTATOR" \
    || ! grep -q 'BEGIN IMMEDIATE' "$CATEGORY_A_PRODUCTION_MUTATOR" \
    || [[ $(grep -c 'DELETE FROM local_thread_catalog' "$CATEGORY_A_PRODUCTION_MUTATOR") -ne 1 ]] \
    || [[ $(grep -c 'UPDATE local_thread_catalog_metadata' "$CATEGORY_A_PRODUCTION_MUTATOR") -ne 1 ]] \
    || [[ $(grep -c 'UPDATE local_thread_catalog_sync_state' "$CATEGORY_A_PRODUCTION_MUTATOR") -ne 1 ]] \
    || ! grep -q 'func recoverByReadback' "$CATEGORY_A_PRODUCTION_MUTATOR" \
    || ! grep -q 'readbackOnlyFilesUnchanged' "$CATEGORY_A_PRODUCTION_MUTATOR"; then
    print -u2 "The M3i-d production mutator is missing, path-extensible, replayable, or exceeds the fixed Category A Desktop-only effect."
    exit 1
fi

if grep -R -nE 'CodexGhostRepairCategoryAProductionMutator|ProductionSnapshotBaselineResolver' "$APP_SOURCE"; then
    print -u2 "The M3j App names the internal Category A production mutator."
    exit 1
fi

if grep -qE 'ghostRepairCategoryA|GhostRepairCategoryARepair(State|Coordinator)' \
        "$APP_SOURCE/SessionManagerModel.swift" \
    || grep -qE 'CategoryARepairSheet|Enable Experimental Category A Repair|Open Category A Repair' "$APP_SOURCE/SettingsView.swift" \
    || grep -q 'isGhostRepairCategoryARepairPresented' "$APP_SOURCE/ContentView.swift"; then
    print -u2 "The retired single-category repair must not remain a Shipping model or UI path."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_PREPARED_DESTINATION" ]] \
    || head -n 8 "$SNAPSHOT_PREPARED_DESTINATION" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'sqlite3_|createDirectory|copyItem|moveItem|removeItem|chmod\(|fchmod\(|unlink\(|rename\(' "$SNAPSHOT_PREPARED_DESTINATION" \
    || ! grep -q 'static func production()' "$SNAPSHOT_PREPARED_DESTINATION" \
    || ! grep -q 'func validateFresh' "$SNAPSHOT_PREPARED_DESTINATION" \
    || ! grep -q 'let acceptsCallerPath = false' "$SNAPSHOT_PREPARED_DESTINATION" \
    || ! grep -q 'let createsDirectories = false' "$SNAPSHOT_PREPARED_DESTINATION" \
    || ! grep -q 'let publishesSnapshots = false' "$SNAPSHOT_PREPARED_DESTINATION" \
    || ! grep -q 'let repairMutationAuthority = false' "$SNAPSHOT_PREPARED_DESTINATION"; then
    print -u2 "The M1b-3 prepared snapshot destination is missing, research-gated, path-extensible, or effectful."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_ACQUISITION_JOURNAL" ]] \
    || head -n 8 "$SNAPSHOT_ACQUISITION_JOURNAL" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'sqlite3_|copyItem|moveItem|removeItem|unlink\(|rename\(' "$SNAPSHOT_ACQUISITION_JOURNAL" \
    || ! grep -q 'O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW' "$SNAPSHOT_ACQUISITION_JOURNAL" \
    || ! grep -q 'fchmod(descriptor, S_IRUSR | S_IWUSR)' "$SNAPSHOT_ACQUISITION_JOURNAL" \
    || ! grep -q 'fsync(descriptor)' "$SNAPSHOT_ACQUISITION_JOURNAL" \
    || ! grep -q 'let copiesDatabaseFiles = false' "$SNAPSHOT_ACQUISITION_JOURNAL" \
    || ! grep -q 'let publishesSnapshots = false' "$SNAPSHOT_ACQUISITION_JOURNAL" \
    || ! grep -q 'let retriesAcquisition = false' "$SNAPSHOT_ACQUISITION_JOURNAL" \
    || ! grep -q 'let repairMutationAuthority = false' "$SNAPSHOT_ACQUISITION_JOURNAL"; then
    print -u2 "The M1b-4 acquisition journal is missing, research-gated, replayable, or over-authorized."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_PUBLISHED_INVENTORY" ]] \
    || head -n 8 "$SNAPSHOT_PUBLISHED_INVENTORY" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'sqlite3_|copyItem|moveItem|removeItem|unlink\(|rename\(|O_WRONLY|O_RDWR|O_CREAT' "$SNAPSHOT_PUBLISHED_INVENTORY" \
    || ! grep -q 'static func production(' "$SNAPSHOT_PUBLISHED_INVENTORY" \
    || ! grep -q 'let opensRawDatabaseContents = false' "$SNAPSHOT_PUBLISHED_INVENTORY" \
    || ! grep -q 'let writesFilesystem = false' "$SNAPSHOT_PUBLISHED_INVENTORY" \
    || ! grep -q 'let automaticDeletionAuthority = false' "$SNAPSHOT_PUBLISHED_INVENTORY" \
    || ! grep -q 'let cleanupAuthority = false' "$SNAPSHOT_PUBLISHED_INVENTORY" \
    || ! grep -q 'let snapshotAcquisitionAuthority = false' "$SNAPSHOT_PUBLISHED_INVENTORY" \
    || ! grep -q 'let repairMutationAuthority = false' "$SNAPSHOT_PUBLISHED_INVENTORY"; then
    print -u2 "The M1b-5 published inventory is missing, research-gated, effectful, or over-authorized."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_QUARANTINE_PUBLISHER" ]] \
    || head -n 8 "$SNAPSHOT_QUARANTINE_PUBLISHER" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'sqlite3_|removeItem|unlink\(|rmdir\(' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'static func production()' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'gateSource: CodexGhostRepairUnavailableExecutionGateSource()' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'static func productionOperationalGateCandidate(' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'source: .production(profile: profile)' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'func inspectAdmissionProfileBound(' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'func acquireProfileBound(' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'CodexGhostRepairSnapshotOperationalGateSource.production()' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'Darwin.rename(quarantineRoot.path, publishedRoot.path)' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'let writesCodexDatabaseFiles = false' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'let acceptsCallerPath = false' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'let retriesAcquisition = false' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'let automaticCleanupAuthority = false' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'let repairMutationAuthority = false' "$SNAPSHOT_QUARANTINE_PUBLISHER"; then
    print -u2 "The M1b-6 Quarantine publisher is missing, live-enabled, replayable, destructive, or over-authorized."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" ]] \
    || head -n 8 "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |sqlite3_|O_WRONLY|O_RDWR|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'static func production()' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'FileManager.default.homeDirectoryForCurrentUser' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'for: \.applicationSupportDirectory' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'CodexGhostRepairDestinationCanaryFixedLayout.entries' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'CodexGhostRepairMacOSOperationalGateSource' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'let acceptsCallerPath = false' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'let opensSQLite = false' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'let writesCodexDatabaseFiles = false' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'let writesManagerFilesystem = false' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'let snapshotAcquisitionAuthority = false' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE" \
    || ! grep -q 'let repairMutationAuthority = false' "$SNAPSHOT_OPERATIONAL_GATE_SOURCE"; then
    print -u2 "The M1b-9 operational gate source is missing, public, path-extensible, effectful, or over-authorized."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_ACTION_COORDINATOR" ]] \
    || head -n 8 "$SNAPSHOT_ACTION_COORDINATOR" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'sqlite3_|removeItem|unlink\(|rmdir\(|acceptsCallerPath[[:space:]]*=[[:space:]]*true' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'public enum CodexGhostRepairSnapshotActionCoordinatorFactory' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'public static func packagedDefaultBlocked()' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'public static func packagedExplicitAction()' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'productionDefaultBlocked()' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'productionExplicitAction()' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'acquisitionAvailable: false' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'acquisitionAvailable: true' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'CodexGhostRepairSnapshotQuarantinePublishingAdapter' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'selection: CodexGhostRepairSnapshotRequestBoundProfileSelection' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'productionOperationalGateCandidate(profile: \$0)' "$SNAPSHOT_ACTION_COORDINATOR" \
    || ! grep -q 'do not retry or clean up automatically' "$SNAPSHOT_ACTION_COORDINATOR"; then
    print -u2 "The M1b-12 snapshot coordinator is missing its blocked comparison, explicit packaged factory, fixed publisher, no-retry recovery, or exact capability boundary."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_ADMISSION_INSPECTOR" ]] \
    || head -n 8 "$SNAPSHOT_ADMISSION_INSPECTOR" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(|acquireProfileBound' "$SNAPSHOT_ADMISSION_INSPECTOR" \
    || ! grep -q 'public protocol CodexGhostRepairSnapshotAdmissionInspecting' "$SNAPSHOT_ADMISSION_INSPECTOR" \
    || ! grep -q 'public enum CodexGhostRepairSnapshotAdmissionInspectorFactory' "$SNAPSHOT_ADMISSION_INSPECTOR" \
    || ! grep -q 'public static func packagedExplicitReadOnly()' "$SNAPSHOT_ADMISSION_INSPECTOR" \
    || ! grep -q 'func inspectAdmissionProfileBound(' "$SNAPSHOT_QUARANTINE_PUBLISHER" \
    || ! grep -q 'public var acceptsCallerPath: Bool { false }' "$SNAPSHOT_ADMISSION_INSPECTOR" \
    || ! grep -q 'public var usesSQLiteAPI: Bool { false }' "$SNAPSHOT_ADMISSION_INSPECTOR" \
    || ! grep -q 'public var writesManagerFilesystem: Bool { false }' "$SNAPSHOT_ADMISSION_INSPECTOR" \
    || ! grep -q 'public var snapshotAcquisitionAuthority: Bool { false }' "$SNAPSHOT_ADMISSION_INSPECTOR" \
    || ! grep -q 'public var repairMutationAuthority: Bool { false }' "$SNAPSHOT_ADMISSION_INSPECTOR"; then
    print -u2 "The M4f-34 Snapshot Admission inspector is missing, effectful, path-extensible, or over-authorized."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_REQUEST_BOUND_PROFILE" ]] \
    || head -n 8 "$SNAPSHOT_REQUEST_BOUND_PROFILE" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |URL\(|FileManager|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|mkdir\(|chmod\(|unlink\(|rename\(|INSERT INTO|UPDATE |DELETE FROM' "$SNAPSHOT_REQUEST_BOUND_PROFILE" \
    || ! grep -q 'let request: CodexGhostRepairSnapshotActionRequest' "$SNAPSHOT_REQUEST_BOUND_PROFILE" \
    || ! grep -q 'let sourceProfile: CodexGhostRepairSnapshotSourceProfile' "$SNAPSHOT_REQUEST_BOUND_PROFILE" \
    || ! grep -q 'var runtimeAloneAdmitsSchema: Bool { false }' "$SNAPSHOT_REQUEST_BOUND_PROFILE" \
    || ! grep -q 'var repairMutationAuthority: Bool { false }' "$SNAPSHOT_REQUEST_BOUND_PROFILE"; then
    print -u2 "The M4f-30 request-bound profile selection is public, path-extensible, effectful, research-only, or over-authorized."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_READBACK_COORDINATOR" ]] \
    || head -n 8 "$SNAPSHOT_READBACK_COORDINATOR" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'public enum CodexGhostRepairSnapshotReadbackCoordinatorFactory' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'public static func packagedReadOnly()' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'FileManager.default.contentsOfDirectory' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'var acceptsCallerPath: Bool { false }' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'var opensRawDatabaseContents: Bool { false }' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'var writesFilesystem: Bool { false }' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'var retryAllowed: Bool { false }' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'var cleanupAuthority: Bool { false }' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'var snapshotAcquisitionAuthority: Bool { false }' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'var repairMutationAuthority: Bool { false }' "$SNAPSHOT_READBACK_COORDINATOR" \
    || ! grep -q 'CodexGhostRepairSnapshotRecoveryReader' "$SNAPSHOT_QUARANTINE_PUBLISHER"; then
    print -u2 "The M1b-10 cold readback facade is missing, path-extensible, effectful, replayable, or disconnected from publisher recovery."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_ANALYSIS_IDENTITY" ]] \
    || head -n 8 "$SNAPSHOT_ANALYSIS_IDENTITY" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'sqlite3_|FileManager|URL\(|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(' "$SNAPSHOT_ANALYSIS_IDENTITY" \
    || ! grep -q 'public enum CodexGhostRepairSnapshotAnalysisIdentityCoordinatorFactory' "$SNAPSHOT_ANALYSIS_IDENTITY" \
    || ! grep -q 'public static func packagedReadOnly()' "$SNAPSHOT_ANALYSIS_IDENTITY" \
    || ! grep -q 'var acceptsCallerPath: Bool { false }' "$SNAPSHOT_ANALYSIS_IDENTITY" \
    || ! grep -q 'var opensRawDatabaseContents: Bool { false }' "$SNAPSHOT_ANALYSIS_IDENTITY" \
    || ! grep -q 'var writesFilesystem: Bool { false }' "$SNAPSHOT_ANALYSIS_IDENTITY" \
    || ! grep -q 'var persistsRepairPreview: Bool { false }' "$SNAPSHOT_ANALYSIS_IDENTITY" \
    || ! grep -q 'var repairPreviewAuthority: Bool { false }' "$SNAPSHOT_ANALYSIS_IDENTITY" \
    || ! grep -q 'var repairMutationAuthority: Bool { false }' "$SNAPSHOT_ANALYSIS_IDENTITY"; then
    print -u2 "The M2 analysis identity is missing, path-extensible, effectful, or over-authorized."
    exit 1
fi

if grep -n 'CodexGhostRepairSnapshotAnalysisIdentityCoordinatorFactory' "$APP_SOURCE"/*.swift; then
    print -u2 "The M2 analysis identity is not yet authorized for an App call site."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_ANALYSIS_READER" ]] \
    || head -n 8 "$SNAPSHOT_ANALYSIS_READER" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|O_RDWR|O_TRUNC|O_APPEND|sqlite3_backup|sqlite3_deserialize|sqlite3_serialize|createDirectory|copyItem|\.moveItem|mkdir\(|unlink\(|rename\(|INSERT INTO|UPDATE |DELETE FROM|ATTACH |DETACH ' "$SNAPSHOT_ANALYSIS_READER" \
    || [[ $(grep -c 'O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW' "$SNAPSHOT_ANALYSIS_READER") -ne 2 ]] \
    || [[ $(grep -c 'FileManager.default.removeItem(at: rootURL)' "$SNAPSHOT_ANALYSIS_READER") -ne 2 ]] \
    || [[ $(grep -c 'chmod(rootURL.path, 0o700)' "$SNAPSHOT_ANALYSIS_READER") -ne 1 ]] \
    || [[ $(grep -c 'fchmod(destinationDescriptor, S_IRUSR | S_IWUSR)' "$SNAPSHOT_ANALYSIS_READER") -ne 1 ]] \
    || [[ $(grep -c 'Darwin.mkdtemp' "$SNAPSHOT_ANALYSIS_READER") -ne 1 ]] \
    || [[ $(grep -c 'allowingGeneratedSQLiteSharedMemory: true' "$SNAPSHOT_ANALYSIS_READER") -lt 4 ]] \
    || ! grep -q 'public enum CodexGhostRepairSnapshotAnalysisReaderFactory' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public static func packagedReadOnly()' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'enum CodexGhostRepairCanonicalQueryOnlyReader' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'private enum CodexGhostRepairSnapshotQueryOnlyBundle' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'O_RDONLY | O_NOFOLLOW' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'sqlite3_db_readonly' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'PRAGMA query_only=ON' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'sqlite3_set_authorizer' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'sqlite3_stmt_readonly' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var readsSessionRows: Bool { true }' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var returnsOnlyPrivacyPreservingRowDigests: Bool { true }' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q '"local_thread_catalog"' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q '"thread_turn_summaries"' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q '"threads"' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q '"thread_turns"' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q '"thread_items"' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q '"thread_history_projection_state"' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'case tableInfo(String)' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'CodexGhostRepairHasher.hash' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var exposesGenericSQL: Bool { false }' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var writesPublishedSnapshot: Bool { false }' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var usesEphemeralAnalysisWorkspace: Bool' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var retainsAnalysisWorkspace: Bool { false }' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'private static func allowedGeneratedSharedMemoryNames' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'existing.contains(wal)' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q '!existing.contains(sharedMemory)' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'generated.isSubset(of: allowedGenerated)' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'private static func validateGeneratedSharedMemory' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'held.st_mode & 0o7777 == 0o600' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'held.st_nlink == 1' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public enum CodexGhostRepairSnapshotAnalysisFailureReason' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'enum CodexGhostRepairSnapshotAnalysisFailurePoint' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'var failureReason: CodexGhostRepairSnapshotAnalysisFailureReason' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'case .freshIdentity: .freshIdentityUnavailable' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'case .desktopContract: .desktopContractUnavailable' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'case .workspaceCleanup: .workspaceCleanupUnavailable' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'case .publishedAccessDrift: .publishedAccessDrift' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'case desktopContractUnavailable = "desktop-contract-unavailable"' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'case workspaceCleanupUnavailable = "workspace-cleanup-unavailable"' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var pathRedacted: Bool { true }' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var rawErrorIncluded: Bool { false }' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var retryAuthority: Bool { false }' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var repairAuthority: Bool { false }' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var persistsRepairPreview: Bool { false }' "$SNAPSHOT_ANALYSIS_READER" \
    || ! grep -q 'public var repairMutationAuthority: Bool { false }' "$SNAPSHOT_ANALYSIS_READER"; then
    print -u2 "The M2b isolated query-only reader is missing, path-extensible, able to write published evidence, or over-authorized."
    exit 1
fi

if grep -n 'CodexGhostRepairSnapshotAnalysisReaderFactory' "$APP_SOURCE"/*.swift; then
    print -u2 "The M2b analysis reader is not yet authorized for an App call site."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_DRY_RUN_PLANNER" ]] \
    || head -n 8 "$SNAPSHOT_DRY_RUN_PLANNER" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'CSQLite3|FileManager|URL\(|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(|SQLiteStateStore|saveCodexGhostRepairPreview|CodexGhostRepairDisposableExecutor' "$SNAPSHOT_DRY_RUN_PLANNER" \
    || ! grep -q 'public enum CodexGhostRepairSnapshotDryRunPlanner' "$SNAPSHOT_DRY_RUN_PLANNER" \
    || ! grep -q 'public var opensSQLite: Bool { false }' "$SNAPSHOT_DRY_RUN_PLANNER" \
    || ! grep -q 'public var readsLiveCodexDatabase: Bool { false }' "$SNAPSHOT_DRY_RUN_PLANNER" \
    || ! grep -q 'public var writesFilesystem: Bool { false }' "$SNAPSHOT_DRY_RUN_PLANNER" \
    || ! grep -q 'public var persistsPreview: Bool { false }' "$SNAPSHOT_DRY_RUN_PLANNER" \
    || ! grep -q 'public var confirmationAuthority: Bool { false }' "$SNAPSHOT_DRY_RUN_PLANNER" \
    || ! grep -q 'public var repairMutationAuthority: Bool { false }' "$SNAPSHOT_DRY_RUN_PLANNER"; then
    print -u2 "The M2d dry-run planner is missing, effectful, persistent, or over-authorized."
    exit 1
fi

if grep -n 'CodexGhostRepairSnapshotDryRunPlanner' "$APP_SOURCE"/*.swift; then
    print -u2 "The M2d dry-run planner is not yet authorized for an App call site."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_DRY_RUN_COORDINATOR" ]] \
    || head -n 8 "$SNAPSHOT_DRY_RUN_COORDINATOR" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'CSQLite3|FileManager|URL\(|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(|SQLiteStateStore|saveCodexGhostRepairPreview|CodexGhostRepairDisposableExecutor' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'public enum CodexGhostRepairSnapshotDryRunAnalysisCoordinatorFactory' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'public static func packagedDefaultUnavailable()' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'public var acceptsCallerPath: Bool { false }' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'public var automaticAnalysis: Bool { false }' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'public var writesFilesystem: Bool { usesEphemeralAnalysisWorkspace }' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'public var writesPublishedSnapshot: Bool { false }' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'public var persistsPreview: Bool { previewPersistenceAvailable }' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'admittedExperimentalContractAvailable' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'static let packagedAdmittedPreview = Self(' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'public var confirmationAuthority: Bool { false }' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'public var repairMutationAuthority: Bool { false }' "$SNAPSHOT_DRY_RUN_COORDINATOR"; then
    print -u2 "The M2o analysis coordinator is missing, cannot distinguish admitted persistence, changes published evidence, or is over-authorized."
    exit 1
fi

if grep -nE 'CodexGhostRepairSnapshotDryRunAnalysisCoordinatorFactory|CodexGhostRepairSnapshotDryRunAnalysisCandidateCoordinator|CodexGhostRepairSnapshotDryRunProtectionAuditSource' \
        "$APP_SOURCE"/*.swift; then
    print -u2 "The retired manual dry-run coordinator must not be constructed by the Shipping App."
    exit 1
fi

if [[ ! -f "$EXPERIMENTAL_ABSENCE_CONTRACT" ]] \
    || head -n 8 "$EXPERIMENTAL_ABSENCE_CONTRACT" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'ExactSessionAbsenceContract|CodexGhostRepairAbsenceContractRegistry|CSQLite3|FileManager|URL\(|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(|SQLiteStateStore|CodexGhostRepairDisposableExecutor' "$EXPERIMENTAL_ABSENCE_CONTRACT" \
    || ! grep -q 'public struct CodexGhostRepairExperimentalAbsenceContract' "$EXPERIMENTAL_ABSENCE_CONTRACT" \
    || ! grep -q 'public struct CodexGhostRepairExperimentalAbsenceRegistry' "$EXPERIMENTAL_ABSENCE_CONTRACT" \
    || ! grep -q 'admissions = \[:\]' "$EXPERIMENTAL_ABSENCE_CONTRACT" \
    || ! grep -q 'public var officialLifecycleAuthority: Bool { false }' "$EXPERIMENTAL_ABSENCE_CONTRACT" \
    || ! grep -q 'public var officialGuarantee: Bool { false }' "$EXPERIMENTAL_ABSENCE_CONTRACT" \
    || ! grep -q 'public var confirmationAuthority: Bool { false }' "$EXPERIMENTAL_ABSENCE_CONTRACT" \
    || ! grep -q 'public var repairMutationAuthority: Bool { false }' "$EXPERIMENTAL_ABSENCE_CONTRACT"; then
    print -u2 "The M2f Experimental absence contract is missing, official-contract-coupled, effectful, admitted by default, or over-authorized."
    exit 1
fi

if grep -nE 'CodexGhostRepairExperimentalAbsence(Contract|Registry)' \
    "$APP_SOURCE"/*.swift \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/ExactSessionReadback.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairLiveReadOnlySafetySource.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSafetyCollector.swift"; then
    print -u2 "The M2f Experimental absence contract crossed into the App or official-only lifecycle flow."
    exit 1
fi

if [[ ! -f "$EXPERIMENTAL_PROTECTION_COLLECTOR" ]] \
    || head -n 8 "$EXPERIMENTAL_PROTECTION_COLLECTOR" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |ExactSessionAbsenceContract|CodexGhostRepairAbsenceContractRegistry|CSQLite3|FileManager|URL\(|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(|SQLiteStateStore|saveCodexGhostRepairPreview|CodexGhostRepairDisposableExecutor' "$EXPERIMENTAL_PROTECTION_COLLECTOR" \
    || ! grep -q 'enum CodexGhostRepairExperimentalProtectionCollector' "$EXPERIMENTAL_PROTECTION_COLLECTOR" \
    || ! grep -q 'inventoryComplete' "$EXPERIMENTAL_PROTECTION_COLLECTOR" \
    || ! grep -q 'pinnedInventoryComplete' "$EXPERIMENTAL_PROTECTION_COLLECTOR" \
    || ! grep -q 'descendantGraphComplete' "$EXPERIMENTAL_PROTECTION_COLLECTOR"; then
    print -u2 "The M2g Experimental protection collector is missing, public, official-contract-coupled, effectful, or incomplete."
    exit 1
fi

if grep -R -n 'CodexGhostRepairDeterministicExperimentalProtectionSource' \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources"; then
    print -u2 "The fixed-observation test source must remain in the test target."
    exit 1
fi

if grep -nE 'CodexGhostRepair(ExperimentalProtectionCollector|DeterministicExperimentalProtectionSource)' \
    "$APP_SOURCE"/*.swift \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/ExactSessionReadback.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairLiveReadOnlySafetySource.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSafetyCollector.swift"; then
    print -u2 "The M2g deterministic Experimental protection collector crossed into the App or official-only lifecycle flow."
    exit 1
fi

if [[ ! -f "$EXPERIMENTAL_OBSERVATION_TRANSPORT" ]] \
    || head -n 8 "$EXPERIMENTAL_OBSERVATION_TRANSPORT" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |ExactSessionAbsenceContract|CodexGhostRepairAbsenceContractRegistry|CodexAppServerClient|CodexInventorySource|CSQLite3|FileManager|URL\(|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(|SQLiteStateStore|saveCodexGhostRepairPreview|CodexGhostRepairDisposableExecutor' "$EXPERIMENTAL_OBSERVATION_TRANSPORT" \
    || ! grep -q 'protocol CodexGhostRepairExperimentalObservationTransport' "$EXPERIMENTAL_OBSERVATION_TRANSPORT" \
    || ! grep -q 'actor CodexGhostRepairExperimentalObservationCandidateCoordinator' "$EXPERIMENTAL_OBSERVATION_TRANSPORT" \
    || ! grep -q 'static func packagedDefaultUnavailable()' "$EXPERIMENTAL_OBSERVATION_TRANSPORT" \
    || ! grep -q 'var acceptsCallerPath: Bool { false }' "$EXPERIMENTAL_OBSERVATION_TRANSPORT" \
    || ! grep -q 'var automaticRead: Bool { false }' "$EXPERIMENTAL_OBSERVATION_TRANSPORT" \
    || ! grep -q 'var automaticRetry: Bool { false }' "$EXPERIMENTAL_OBSERVATION_TRANSPORT" \
    || ! grep -q 'var persistsEvidence: Bool { false }' "$EXPERIMENTAL_OBSERVATION_TRANSPORT" \
    || ! grep -q 'var officialLifecycleAuthority: Bool { false }' "$EXPERIMENTAL_OBSERVATION_TRANSPORT" \
    || ! grep -q 'var confirmationAuthority: Bool { false }' "$EXPERIMENTAL_OBSERVATION_TRANSPORT" \
    || ! grep -q 'var repairMutationAuthority: Bool { false }' "$EXPERIMENTAL_OBSERVATION_TRANSPORT"; then
    print -u2 "The M2h Experimental observation transport is missing, public, live-wired, effectful, automatic, or over-authorized."
    exit 1
fi

if grep -nE 'CodexGhostRepairExperimentalObservation(CoordinatorFactory|CandidateCoordinator|Transport)' \
    "$APP_SOURCE"/*.swift \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/ExactSessionReadback.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairLiveReadOnlySafetySource.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSafetyCollector.swift"; then
    print -u2 "The M2h fake-backed Experimental observation transport crossed into the App or official-only lifecycle flow."
    exit 1
fi

if [[ ! -f "$EXPERIMENTAL_APP_SERVER_ADAPTER" ]] \
    || head -n 8 "$EXPERIMENTAL_APP_SERVER_ADAPTER" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |CodexAppServerClient|CodexArchiveSource|CodexRestoreSource|CodexDeleteSource|func (archive|unarchive|delete)\(|CSQLite3|FileManager|URL\(|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(|SQLiteStateStore|saveCodexGhostRepairPreview|CodexGhostRepairDisposableExecutor|static func production' "$EXPERIMENTAL_APP_SERVER_ADAPTER" \
    || ! grep -q 'actor CodexGhostRepairExperimentalAppServerObservationAdapter' "$EXPERIMENTAL_APP_SERVER_ADAPTER" \
    || ! grep -q 'private let source: any CodexInventorySource' "$EXPERIMENTAL_APP_SERVER_ADAPTER" \
    || ! grep -q 'CodexGhostRepairExperimentalObservationTransport' "$EXPERIMENTAL_APP_SERVER_ADAPTER" \
    || ! grep -q 'rpc-error-code-message-v1' "$EXPERIMENTAL_APP_SERVER_ADAPTER"; then
    print -u2 "The M2i App Server observation adapter is missing, public, production-constructible, mutation-capable, effectful, or disconnected from the exact Experimental vocabulary."
    exit 1
fi

if grep -n 'CodexGhostRepairExperimentalAppServerObservationAdapter' \
    "$APP_SOURCE"/*.swift \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/ExactSessionReadback.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairLiveReadOnlySafetySource.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSafetyCollector.swift"; then
    print -u2 "The M2i read-only Experimental App Server adapter crossed into the App or official-only lifecycle flow."
    exit 1
fi

if [[ ! -f "$EXPERIMENTAL_PROTECTION_COMPOSITION" ]] \
    || head -n 8 "$EXPERIMENTAL_PROTECTION_COMPOSITION" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE '^public |CodexAppServerClient|CodexInventorySource|ExactSessionAbsenceContract|CodexGhostRepairAbsenceContractRegistry|CSQLite3|FileManager|URL\(|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(|SQLiteStateStore|saveCodexGhostRepairPreview|CodexGhostRepairDisposableExecutor|static func production' "$EXPERIMENTAL_PROTECTION_COMPOSITION" \
    || ! grep -q 'struct CodexGhostRepairExperimentalProtectionCompositionSource' "$EXPERIMENTAL_PROTECTION_COMPOSITION" \
    || ! grep -q 'requestID: UUID' "$EXPERIMENTAL_PROTECTION_COMPOSITION" \
    || ! grep -q 'result.requestID == requestID' "$EXPERIMENTAL_PROTECTION_COMPOSITION" \
    || ! grep -q 'result.identity == identity' "$EXPERIMENTAL_PROTECTION_COMPOSITION" \
    || ! grep -q 'CodexGhostRepairExperimentalProtectionCollector.collect' "$EXPERIMENTAL_PROTECTION_COMPOSITION"; then
    print -u2 "The M2j Experimental protection composition is missing, public, request-unbound, production-wired, effectful, or disconnected from the M2f/M2g contracts."
    exit 1
fi

if grep -n 'CodexGhostRepairExperimentalProtectionCompositionSource' \
    "$APP_SOURCE"/*.swift \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/ExactSessionReadback.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairLiveReadOnlySafetySource.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSafetyCollector.swift"; then
    print -u2 "The M2j request-bound Experimental protection composition crossed into the App or official-only lifecycle flow."
    exit 1
fi

if [[ ! -f "$EXPERIMENTAL_COMPATIBILITY_REVIEW" ]] \
    || head -n 8 "$EXPERIMENTAL_COMPATIBILITY_REVIEW" | grep -q 'AGENT_SESSION_MANAGER_RESEARCH' \
    || grep -nE 'SQLiteStateStore|saveCodexGhostRepairSnapshotDryRunPreview|CSQLite3|FileManager|URL\(|sqlite3_|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(|CodexArchiveSource|CodexRestoreSource|CodexDeleteSource|func (archive|unarchive|delete)\(' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'public struct CodexGhostRepairExperimentalCompatibilityEvidence' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'public struct CodexGhostRepairExperimentalCompatibilityFailure' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'CodexGhostRepairSnapshotAnalysisFailureReason?' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'public var pathRedacted: Bool { true }' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'public var rawErrorIncluded: Bool { false }' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'public var automaticRetry: Bool { false }' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'static func packagedCompatibilityReview(' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'static func packagedAdmittedPreview(' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'CodexGhostRepairExperimentalProtectionCollector' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'CodexGhostRepairSnapshotDryRunPlanner.plan' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'previewPersister.persist' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'receipt.requestID == request.requestID' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'case writeOrReadbackFailed' "$SNAPSHOT_DRY_RUN_COORDINATOR" \
    || ! grep -q 'private let source: any CodexInventorySource' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'public var previewCreated: Bool { false }' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'public var previewPersisted: Bool { false }' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'public var confirmationAuthority: Bool { false }' "$EXPERIMENTAL_COMPATIBILITY_REVIEW" \
    || ! grep -q 'public var repairMutationAuthority: Bool { false }' "$EXPERIMENTAL_COMPATIBILITY_REVIEW"; then
    print -u2 "The M2o admitted composition is missing, directly persistent, mutation-capable, identity-unbound, or over-authorized."
    exit 1
fi

if grep -nE 'CodexGhostRepairExperimentalCompatibility(EvidenceBuilder|ReviewCoordinator)|CodexGhostRepairExperimentalReadOnlyAppServerSource' \
    "$APP_SOURCE"/*.swift \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/ExactSessionReadback.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairLiveReadOnlySafetySource.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSafetyCollector.swift"; then
    print -u2 "The M2n private compatibility composition crossed into the App or official-only lifecycle flow."
    exit 1
fi

if [[ ! -f "$SNAPSHOT_DRY_RUN_REPOSITORY" ]] \
    || grep -nE 'public extension SQLiteStateStore|CodexAppServerClient|CodexInventorySource|ExactSessionAbsenceContract|CodexGhostRepairAbsenceContractRegistry|FileManager|(^|[^[:alnum:]_])URL\(|O_WRONLY|O_RDWR|O_CREAT|createDirectory|copyItem|moveItem|removeItem|mkdir\(|chmod\(|fchmod\(|unlink\(|rename\(|CodexGhostRepairDisposableExecutor|BEGIN IMMEDIATE|local_thread_catalog|func (archive|unarchive|delete)\(' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'public struct CodexGhostRepairSnapshotDryRunPersistenceReceipt' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'public struct CodexGhostRepairSnapshotDryRunReadbackEvidence' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'public protocol CodexGhostRepairSnapshotDryRunReadbackCoordinating' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'public enum CodexGhostRepairSnapshotDryRunReadbackCoordinatorFactory' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'actor CodexGhostRepairSnapshotDryRunLiveReadbackCoordinator' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'protocol CodexGhostRepairSnapshotDryRunPreviewPersisting' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'actor CodexGhostRepairSnapshotDryRunLivePreviewPersister' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'struct CodexGhostRepairSnapshotDryRunStoredPreview' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'func saveCodexGhostRepairSnapshotDryRunPreview' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'codexGhostRepairSnapshotDryRunPreview(' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'durableReadbackMatched: true' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'sqlite3_db_readonly(pointer, "main") == 1' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q '"PRAGMA query_only=ON"' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'sqlite3_stmt_readonly(statement) == 1' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'guard existing == expected' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'confirmationAuthority: Bool { false }' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'repairMutationAuthority: Bool { false }' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'confirmationAuthority == 0' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'repairMutationAuthority == 0' "$SNAPSHOT_DRY_RUN_REPOSITORY" \
    || ! grep -q 'confirmation_authority INTEGER NOT NULL DEFAULT 0 CHECK (confirmation_authority = 0)' "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteStateStore.swift" \
    || ! grep -q 'repair_mutation_authority INTEGER NOT NULL DEFAULT 0 CHECK (repair_mutation_authority = 0)' "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteStateStore.swift"; then
    print -u2 "The M2k durable dry-run Preview repository is missing, public, Codex-coupled, replayable, or grants confirmation/repair authority."
    exit 1
fi

if grep -nE 'saveCodexGhostRepairSnapshotDryRunPreview|codexGhostRepairSnapshotDryRunPreview' \
    "$APP_SOURCE"/*.swift \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/ExactSessionReadback.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairLiveReadOnlySafetySource.swift" \
    "$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSafetyCollector.swift"; then
    print -u2 "The M2k dry-run Preview repository crossed into the App or official-only lifecycle flow."
    exit 1
fi

if grep -n 'CodexGhostRepairDestinationCanaryCoordinatorFactory' \
        "$APP_SOURCE"/*.swift; then
    print -u2 "The retired Destination Canary coordinator must not be constructed by the Shipping App."
    exit 1
fi

if [[ ! -f "$INITIAL_WITNESS_DISCOVERY" ]] \
    || ! grep -q 'public protocol CodexGhostRepairInitialWitnessDiscovering' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || ! grep -q 'public enum CodexGhostRepairInitialWitnessDiscoveryFactory' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || ! grep -q 'public static func packagedExplicitReadOnly()' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || ! grep -q 'public var acceptsCallerPath: Bool { false }' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || ! grep -q 'public var acceptsCallerThreadIDs: Bool { false }' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || ! grep -q 'public var writesCodexDatabaseFiles: Bool { false }' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || ! grep -q 'public var writesManagerFilesystem: Bool { false }' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || ! grep -q 'public var publishesSnapshot: Bool { false }' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || ! grep -q 'public var persistsPreview: Bool { false }' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || ! grep -q 'public var confirmationAuthority: Bool { false }' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || ! grep -q 'public var repairMutationAuthority: Bool { false }' \
        "$INITIAL_WITNESS_DISCOVERY" \
    || grep -nE '^public (protocol|struct|actor|enum) CodexGhostRepairInitialWitness(CatalogReading|CanonicalCatalogReader|DiscoveryCoordinator|CatalogReadback|CanonicalQueryOnlyReader)' \
        "$INITIAL_WITNESS_DISCOVERY" "$SNAPSHOT_ANALYSIS_READER" \
    || grep -nE 'CodexArchiveSource|CodexRestoreSource|CodexDeleteSource|func (archive|unarchive|delete)\(|saveCodexGhostRepair|SnapshotActionCoordinator|PreviewRepository|createsClaim: Bool \{ true \}|repairMutationAuthority: Bool \{ true \}' \
        "$INITIAL_WITNESS_DISCOVERY"; then
    print -u2 "Initial Ghost witness discovery must remain a public no-path read-only facade over Core-only canonical readers, without lifecycle, Snapshot, Preview, claim, or mutation authority."
    exit 1
fi

INITIAL_WITNESS_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairInitialWitnessDiscoveryFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
INITIAL_WITNESS_MODEL_FACTORY_CALL_COUNT=$(grep -F \
    'CodexGhostRepairInitialWitnessDiscoveryFactory' \
    "$APP_SOURCE/SessionManagerModel.swift" -A 2 \
    | grep -F -o '.packagedExplicitReadOnly()' | wc -l | tr -d ' ')
if [[ "$INITIAL_WITNESS_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$INITIAL_WITNESS_MODEL_FACTORY_CALL_COUNT" != "1" ]] \
    || ! grep -q 'any CodexGhostRepairInitialWitnessDiscovering' \
        "$APP_SOURCE/SessionManagerModel.swift" \
    || grep -n 'CodexGhostRepairInitialWitnessDiscoveryFactory' \
        "$APP_SOURCE"/*View.swift "$APP_SOURCE"/*Sheet.swift \
    || grep -nE 'CodexGhostRepairInitialWitness(CatalogReading|CanonicalCatalogReader|DiscoveryCoordinator|CatalogReadback|CanonicalQueryOnlyReader)|CodexGhostRepairSnapshotAnalysisWorkspaceFactory' \
        "$APP_SOURCE"/*.swift; then
    print -u2 "The shipping App may use only the public no-path initial-witness discovery facade from SessionManagerModel; canonical query and workspace implementation must remain Core-only."
    exit 1
fi

SNAPSHOT_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairSnapshotActionCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
SNAPSHOT_MODEL_FACTORY_CALL_COUNT=$(grep -F -o \
    '.packagedExplicitAction()' \
    "$APP_SOURCE/SessionManagerModel.swift" | wc -l | tr -d ' ')
if [[ "$SNAPSHOT_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$SNAPSHOT_MODEL_FACTORY_CALL_COUNT" != "1" ]]; then
    print -u2 "The shipping App may construct only the explicit no-path Snapshot action coordinator at the exact SessionManagerModel default call site."
    exit 1
fi

SNAPSHOT_ADMISSION_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairSnapshotAdmissionInspectorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
SNAPSHOT_ADMISSION_MODEL_FACTORY_CALL_COUNT=$(grep -F -o \
    'CodexGhostRepairSnapshotAdmissionInspectorFactory' \
    "$APP_SOURCE/SessionManagerModel.swift" | wc -l | tr -d ' ')
if [[ "$SNAPSHOT_ADMISSION_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$SNAPSHOT_ADMISSION_MODEL_FACTORY_CALL_COUNT" != "1" ]] \
    || ! grep -q '\.packagedExplicitReadOnly()' \
        "$APP_SOURCE/SessionManagerModel.swift"; then
    print -u2 "The shipping App may construct the explicit read-only Snapshot Admission inspector only at the exact SessionManagerModel default call site."
    exit 1
fi

SNAPSHOT_READBACK_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairSnapshotReadbackCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
SNAPSHOT_READBACK_MODEL_FACTORY_CALL_COUNT=$(grep -F -o \
    'CodexGhostRepairSnapshotReadbackCoordinatorFactory' \
    "$APP_SOURCE/SessionManagerModel.swift" -A 2 \
    | grep -F -o '.packagedReadOnly()' | wc -l | tr -d ' ')
if [[ "$SNAPSHOT_READBACK_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$SNAPSHOT_READBACK_MODEL_FACTORY_CALL_COUNT" != "1" ]]; then
    print -u2 "The shipping App may construct the no-path snapshot readback facade only at the exact SessionManagerModel default call site."
    exit 1
fi

BULK_RECOVERY_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairBulkRecoveryCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
BULK_RECOVERY_MODEL_FACTORY_CALL_COUNT=$(grep -F \
    'CodexGhostRepairBulkRecoveryCoordinatorFactory' \
    "$APP_SOURCE/SessionManagerModel.swift" -A 2 \
    | grep -F -o '.packagedReadOnly()' | wc -l | tr -d ' ')
if [[ ! -f "$BULK_RECOVERY_COORDINATOR" ]] \
    || [[ "$BULK_RECOVERY_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$BULK_RECOVERY_MODEL_FACTORY_CALL_COUNT" != "1" ]] \
    || ! grep -q 'writesManagerOwnedRecords: Bool { false }' \
        "$BULK_RECOVERY_COORDINATOR" \
    || ! grep -A 2 -q 'mayUpdateSQLiteCoordination: Bool {' \
        "$BULK_RECOVERY_COORDINATOR" \
    || ! grep -A 2 'mayUpdateSQLiteCoordination: Bool {' \
        "$BULK_RECOVERY_COORDINATOR" | grep -q 'explicitReadbackAvailable' \
    || grep -nE 'CodexGhostRepairBulkRecoveryLiveCoordinator|CodexGhostRepairReadOnlyManagerStateStore|CodexGhostRepairBulkOperationExclusion|CodexGhostRepairBulkFreshRecoveryLiveCoordinator|CodexGhostRepairBulkLiveJournalPersistedRow|CSQLite3' \
        "$APP_SOURCE"/*.swift \
    || grep -n 'CodexGhostRepairBulkRecoveryCoordinatorFactory' \
        "$APP_SOURCE"/*View.swift "$APP_SOURCE"/*Sheet.swift; then
    print -u2 "Bulk recovery must remain one explicit model-owned read-only facade without App access to internal SQLite recovery implementation."
    exit 1
fi

BULK_CONFIRMATION_RECOVERY_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
BULK_CONFIRMATION_RECOVERY_MODEL_FACTORY_CALL_COUNT=$(grep -F \
    'CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinatorFactory' \
    "$APP_SOURCE/SessionManagerModel.swift" -A 2 \
    | grep -F -o '.packagedReadOnly()' | wc -l | tr -d ' ')
BULK_FRESH_RECOVERY_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairBulkFreshRecoveryCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
BULK_FRESH_RECOVERY_MODEL_FACTORY_CALL_COUNT=$(grep -F \
    'CodexGhostRepairBulkFreshRecoveryCoordinatorFactory' \
    "$APP_SOURCE/SessionManagerModel.swift" -A 2 \
    | grep -F -o '.packagedExplicit()' | wc -l | tr -d ' ')
if [[ "$BULK_CONFIRMATION_RECOVERY_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$BULK_CONFIRMATION_RECOVERY_MODEL_FACTORY_CALL_COUNT" != "1" ]] \
    || [[ "$BULK_FRESH_RECOVERY_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$BULK_FRESH_RECOVERY_MODEL_FACTORY_CALL_COUNT" != "1" ]] \
    || grep -nE 'CodexGhostRepairBulk(ConfirmationReceiptRecovery|FreshRecovery)CoordinatorFactory' \
        "$APP_SOURCE"/*View.swift "$APP_SOURCE"/*Sheet.swift; then
    print -u2 "Confirmation and fresh recovery facades must be constructed only at their exact SessionManagerModel default call sites; Views may invoke only explicit model intents."
    exit 1
fi

BULK_PREPARED_CLOSURE_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairBulkPreparedClosureCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
BULK_PREPARED_CLOSURE_MODEL_FACTORY_CALL_COUNT=$(grep -F \
    'CodexGhostRepairBulkPreparedClosureCoordinatorFactory' \
    "$APP_SOURCE/SessionManagerModel.swift" -A 2 \
    | grep -F -o '.packagedExplicit()' | wc -l | tr -d ' ')
if [[ ! -f "$BULK_PREPARED_CLOSURE_COORDINATOR" ]] \
    || [[ "$BULK_PREPARED_CLOSURE_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$BULK_PREPARED_CLOSURE_MODEL_FACTORY_CALL_COUNT" != "1" ]] \
    || grep -nE 'CodexGhostRepairBulkPreparedClosure(CoordinatorFactory|LiveCoordinator)|closeCodexGhostRepairBulkPreparedOperation' \
        "$APP_SOURCE"/*View.swift "$APP_SOURCE"/*Sheet.swift; then
    print -u2 "Prepared-plan closure must remain one explicit model-owned facade; Views may invoke only model review and closure intents, without direct store access."
    exit 1
fi

if grep -nE 'CodexGhostRepairSnapshotDryRunReadbackCoordinatorFactory|ghostRepairDryRunPreviewReadbackCoordinator' \
        "$APP_SOURCE"/*.swift; then
    print -u2 "The retired saved Preview readback coordinator must not be constructed by the Shipping App."
    exit 1
fi

BULK_INVENTORY_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairBulkInventoryCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
BULK_INVENTORY_MODEL_FACTORY_CALL_COUNT=$(grep -F \
    'CodexGhostRepairBulkInventoryCoordinatorFactory' \
    "$APP_SOURCE/SessionManagerModel.swift" -A 2 \
    | grep -F -o '.packagedExplicitReadOnly()' | wc -l | tr -d ' ')
if [[ "$BULK_INVENTORY_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$BULK_INVENTORY_MODEL_FACTORY_CALL_COUNT" != "1" ]] \
    || ! grep -q 'public static func packagedExplicitReadOnly()' \
        "$BULK_INVENTORY_COORDINATOR" \
    || ! grep -q 'automaticObservation: Bool { false }' \
        "$BULK_INVENTORY_COORDINATOR" \
    || ! grep -q 'repairMutationAuthority: Bool { false }' \
        "$BULK_INVENTORY_COORDINATOR"; then
    print -u2 "The packaged Bulk Ghost Inventory must remain explicit, read-only, authority-free, and constructed only at the model default call site."
    exit 1
fi

SNAPSHOT_UI_CALL_COUNT=$({ grep -h -F -o \
    'requestGhostRepairSnapshotWithAutomaticAdmission()' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
SNAPSHOT_ADMISSION_UI_CALL_COUNT=$({ grep -h -F -o \
    '.requestGhostRepairSnapshotAdmissionInspection()' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
if [[ "$SNAPSHOT_UI_CALL_COUNT" != "0" ]] \
    || [[ "$SNAPSHOT_ADMISSION_UI_CALL_COUNT" != "0" ]] \
    || [[ -f "$LEGACY_SNAPSHOT_REVIEW_SHEET" ]] \
    || grep -qE 'Enable read-only Ghost Repair Safety Review|Enable explicit Snapshot Admission inspection|Enable explicit Create Snapshot action' "$APP_SOURCE/SettingsView.swift" \
    || grep -qE 'GhostRepairReadOnlyReviewSheet|isGhostRepairReadOnlyReviewPresented' "$APP_SOURCE/ContentView.swift" \
    || ! grep -q 'private(set) var isGhostRepairBulkReconciliationEnabled' "$APP_SOURCE/SessionManagerModel.swift" \
    || ! grep -q 'ghostRepairBulkReconciliationPreferenceKey' "$APP_SOURCE/SessionManagerModel.swift" \
    || ! grep -q 'ghostRepairBulkReconciliationPreferenceWriter' "$APP_SOURCE/SessionManagerModel.swift" \
    || grep -qE 'isGhostRepair(BulkInventory|ReadOnly|SnapshotAction|SnapshotAdmissionInspector)Enabled|ghostRepair(ReadOnly|SnapshotAction|SnapshotAdmissionInspector|BulkInventory)Preference(Key|Writer)|setGhostRepair(ReadOnly|SnapshotAction|SnapshotAdmissionInspector)Enabled' "$APP_SOURCE/SessionManagerModel.swift" \
    || grep -qE 'Enable (the experimental read-only Ghost Repair Safety Review|explicit Snapshot Admission inspection)' "$APP_SOURCE/SessionManagerModel.swift" \
    || grep -qE 'requestGhostRepair(ReadOnlyReview|SnapshotAdmissionInspection|SnapshotAction|SnapshotWithAutomaticAdmission)\([^)]*managerKeys: Set<String>\? = nil' "$APP_SOURCE/SessionManagerModel.swift" \
    || grep -qF 'let frozenManagerKeys = managerKeys ?? selection' "$APP_SOURCE/SessionManagerModel.swift" \
    || ! grep -q 'ghostRepairSnapshotRecoveryReference' "$APP_SOURCE/SessionManagerModel.swift"; then
    print -u2 "Manual Snapshot Admission/Create must be absent from Shipping UI, with one persisted bulk reconciliation owner and explicit effect witness keys."
    exit 1
fi

SNAPSHOT_READBACK_UI_CALL_COUNT=$(grep -h -F -o \
    'model.readGhostRepairSnapshotInventory()' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
if [[ "$SNAPSHOT_READBACK_UI_CALL_COUNT" != "1" ]] \
    || ! grep -q 'Enable explicit Snapshot Readback' "$APP_SOURCE/SettingsView.swift" \
    || ! grep -q 'accessibilityIdentifier("ghostRepairSnapshotReadbackToggle")' "$APP_SOURCE/SettingsView.swift" \
    || ! grep -q 'accessibilityIdentifier("openGhostRepairSnapshotReadback")' "$APP_SOURCE/SettingsView.swift" \
    || ! grep -q 'accessibilityIdentifier("readGhostRepairSnapshotStatus")' "$APP_SOURCE/SettingsView.swift" \
    || ! grep -q 'No storage metadata is read until you press Read Snapshot Status.' "$APP_SOURCE/SettingsView.swift" \
    || ! grep -q 'interactiveDismissDisabled(isReading)' "$APP_SOURCE/SettingsView.swift" \
    || ! grep -q 'private var ghostRepairSnapshotReadbackRequestID' "$APP_SOURCE/SessionManagerModel.swift" \
    || ! grep -q 'ghostRepairSnapshotReadbackRequestID == requestID' "$APP_SOURCE/SessionManagerModel.swift"; then
    print -u2 "The M1b-11 Snapshot Readback surface is missing, duplicated, auto-triggered, dismissible during readback, or lacks model identity guards."
    exit 1
fi

BULK_INVENTORY_UI_CALL_COUNT=$({ grep -h -F -o \
    'model.observeGhostRepairBulkInventory()' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
BULK_PREPARATION_UI_CALL_COUNT=$(grep -h -F -o \
    'model.prepareGhostRepairBulkInventory()' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
if [[ "$BULK_INVENTORY_UI_CALL_COUNT" != "0" ]] \
    || [[ "$BULK_PREPARATION_UI_CALL_COUNT" != "1" ]] \
    || [[ ! -f "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" ]] \
    || [[ -f "$APP_SOURCE/GhostRepairGuidedWorkflowSheet.swift" ]] \
    || grep -q 'GhostRepairGuidedWorkflowSheet' "$APP_SOURCE/ContentView.swift" \
    || grep -q 'GhostRepairReadOnlyReviewSheet' "$APP_SOURCE/ContentView.swift" \
    || grep -q 'label: "Ghost Repair"' "$APP_SOURCE/SessionTableView.swift" \
    || grep -q 'label: "Ghost Safety"' "$APP_SOURCE/SessionTableView.swift" \
    || ! grep -q 'Enable Bulk Ghost Delete' "$APP_SOURCE/SettingsView.swift" \
    || ! grep -q 'Open Bulk Ghost Delete' "$APP_SOURCE/SettingsView.swift" \
    || [[ "$(grep -F -o 'model.observeGhostRepairBulkInventory()' "$APP_SOURCE/ContentView.swift" | wc -l | tr -d ' ')" != "0" ]] \
    || [[ "$(grep -F -o 'model.observeGhostRepairBulkInventory()' "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" | wc -l | tr -d ' ')" != "0" ]] \
    || grep -q 'queuedGhostRepairBulkSnapshotReference' \
        "$APP_SOURCE/SessionManagerModel.swift" \
    || grep -q 'accessibilityIdentifier("scanBulkGhostInventory")' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'accessibilityIdentifier(' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q '"prepareBulkGhostInventory"' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'accessibilityIdentifier("bulkGhostSelectedOnly")' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'accessibilityIdentifier("bulkGhostSelectAllEligible")' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'Search and category filters keep your selection.' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'the App checks the data, verifies a backup' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'Verified current scan' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'Scan for Ghosts, review the items to keep or clear, and confirm once.' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'Recovery tools — normally not needed' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'private var cleanupProgress' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'if showsFinalRepairStage' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'interactiveDismissDisabled(isBusy)' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'ghostRepairBulkInventoryRequestID == request.requestID' \
        "$APP_SOURCE/SessionManagerModel.swift"; then
    print -u2 "The Bulk Ghost Delete UI must have one current-evidence Prepare, no Snapshot or recovery Scan entry, stable selection, request identity guards, and progressive stage disclosure."
    exit 1
fi

BULK_PREVIEW_PERSISTENCE_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairBulkPreviewPersistenceFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
BULK_PREVIEW_READBACK_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairBulkPreviewReadbackCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
BULK_PREVIEW_BUILD_UI_CALL_COUNT=$({ grep -h -F -o \
    'model.buildGhostRepairBulkPreview()' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
BULK_PREVIEW_READBACK_UI_CALL_COUNT=$(grep -h -F -o \
    'model.readSavedGhostRepairBulkPreview()' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
if [[ ! -f "$BULK_PREVIEW_REPOSITORY" ]] \
    || [[ "$BULK_PREVIEW_PERSISTENCE_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$BULK_PREVIEW_READBACK_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$BULK_PREVIEW_BUILD_UI_CALL_COUNT" != "0" ]] \
    || [[ "$BULK_PREVIEW_READBACK_UI_CALL_COUNT" != "1" ]] \
    || ! grep -q 'public static func packaged()' "$BULK_PREVIEW_REPOSITORY" \
    || ! grep -q 'public static func packagedReadOnly()' "$BULK_PREVIEW_REPOSITORY" \
    || ! grep -q 'public var confirmationAuthority: Bool { false }' "$BULK_PREVIEW_REPOSITORY" \
    || ! grep -q 'public var repairMutationAuthority: Bool { false }' "$BULK_PREVIEW_REPOSITORY" \
    || ! grep -q 'SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX' "$BULK_PREVIEW_REPOSITORY" \
    || ! grep -q 'accessibilityIdentifier("confirmGhostCleanup")' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'accessibilityIdentifier("readSavedBulkGhostPreview")' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'accessibilityIdentifier("copyBulkGhostPreviewSummary")' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'buttonTitle: "Copy Request ID"' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'interactiveDismissDisabled(isBusy)' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'Only selected eligible items will be cleared' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift"; then
    print -u2 "The durable Bulk Preview must remain explicit, manager-owned, cold-readable, whole-batch, and authority-free."
    exit 1
fi

BULK_CONFIRMATION_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairBulkConfirmationChallengeCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
BULK_CONFIRMATION_MODEL_FACTORY_CALL_COUNT=$(grep -F -o \
    '.packagedEvidenceOnly()' \
    "$APP_SOURCE/SessionManagerModel.swift" | wc -l | tr -d ' ')
BULK_CONFIRMATION_UI_CALL_COUNT=$({ grep -h -F -o \
    '.prepareGhostRepairBulkConfirmationChallenge()' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
BULK_CONFIRMATION_MODEL_HANDOFF_COUNT=$(grep -F -o \
    'await prepareGhostRepairBulkConfirmationChallenge()' \
    "$APP_SOURCE/SessionManagerModel.swift" | wc -l | tr -d ' ')
if [[ ! -f "$BULK_CONFIRMATION_CONTRACT" ]] \
    || [[ ! -f "$BULK_CONFIRMATION_REPOSITORY" ]] \
    || [[ "$BULK_CONFIRMATION_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$BULK_CONFIRMATION_MODEL_FACTORY_CALL_COUNT" != "1" ]] \
    || [[ "$BULK_CONFIRMATION_UI_CALL_COUNT" != "0" ]] \
    || [[ "$BULK_CONFIRMATION_MODEL_HANDOFF_COUNT" != "1" ]] \
    || ! grep -q 'public static func packagedEvidenceOnly()' \
        "$BULK_CONFIRMATION_REPOSITORY" \
    || ! grep -q 'public var perItemConfirmation: Bool { false }' \
        "$BULK_CONFIRMATION_CONTRACT" \
    || ! grep -q 'public var confirmationAuthority: Bool { false }' \
        "$BULK_CONFIRMATION_CONTRACT" \
    || ! grep -q 'public var repairClaimCreated: Bool { false }' \
        "$BULK_CONFIRMATION_CONTRACT" \
    || ! grep -q 'public var repairMutationAuthority: Bool { false }' \
        "$BULK_CONFIRMATION_CONTRACT" \
    || ! grep -q 'Press Read Saved Preview for this exact Request ID first.' \
        "$APP_SOURCE/SessionManagerModel.swift" \
    || grep -q '"prepareBulkGhostConfirmationChallenge"' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || grep -q '"copyBulkGhostConfirmationPhrase"' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'ghostRepairBulkConfirmationPhraseDraft = challenge.confirmationPhrase' \
        "$APP_SOURCE/SessionManagerModel.swift"; then
    print -u2 "The whole-batch confirmation challenge must remain cold-readback-bound, single, evidence-only, and claim-free."
    exit 1
fi

BULK_CONFIRMATION_RECEIPT_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairBulkConfirmationReceiptCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
BULK_CONFIRMATION_RECEIPT_MODEL_FACTORY_CALL_COUNT=$(grep -F -o \
    '.packagedReceiptOnly()' \
    "$APP_SOURCE/SessionManagerModel.swift" | wc -l | tr -d ' ')
BULK_CONFIRMATION_RECEIPT_UI_CALL_COUNT=$({ grep -h -F -o \
    'model.confirmGhostRepairBulkBatch()' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
if [[ ! -f "$BULK_CONFIRMATION_RECEIPT_REPOSITORY" ]] \
    || [[ "$BULK_CONFIRMATION_RECEIPT_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$BULK_CONFIRMATION_RECEIPT_MODEL_FACTORY_CALL_COUNT" != "1" ]] \
    || [[ "$BULK_CONFIRMATION_RECEIPT_UI_CALL_COUNT" != "0" ]] \
    || ! grep -q 'public static func packagedReceiptOnly()' \
        "$BULK_CONFIRMATION_RECEIPT_REPOSITORY" \
    || ! grep -q 'public var createsRepairClaim: Bool { false }' \
        "$BULK_CONFIRMATION_CONTRACT" \
    || ! grep -q 'public var repairClaimCreated: Bool { false }' \
        "$BULK_CONFIRMATION_CONTRACT" \
    || ! grep -q 'public var repairMutationAuthority: Bool { false }' \
        "$BULK_CONFIRMATION_CONTRACT" \
    || ! grep -q 'public var automaticRetryAllowed: Bool { false }' \
        "$BULK_CONFIRMATION_CONTRACT" \
    || ! grep -q 'accessibilityIdentifier(' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || grep -q '"bulkGhostConfirmationPhrase"' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q '"confirmGhostCleanup"' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'Confirm Cleanup' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift"; then
    print -u2 "The whole-batch receipt must remain explicit, exact, manager-owned, no-replay, and repair-authority-free."
    exit 1
fi

BULK_REPAIR_FACTORY_REFERENCE_COUNT=$(grep -h -o \
    'CodexGhostRepairBulkRepairCoordinatorFactory' \
    "$APP_SOURCE"/*.swift | wc -l | tr -d ' ')
BULK_REPAIR_MODEL_FACTORY_CALL_COUNT=$(sed -n \
    '/CodexGhostRepairBulkRepairCoordinatorFactory/,+2p' \
    "$APP_SOURCE/SessionManagerModel.swift" \
    | grep -c '\.packagedProduction()' || true)
BULK_REPAIR_REVIEW_UI_CALL_COUNT=$({ grep -h -F -o \
    'model.prepareGhostRepairBulkFinalReview()' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
BULK_REPAIR_REVIEW_MODEL_HANDOFF_COUNT=$({ grep -F -o \
    'await prepareGhostRepairBulkFinalReview()' \
    "$APP_SOURCE/SessionManagerModel.swift" || true; } | wc -l | tr -d ' ')
BULK_REPAIR_EXECUTION_UI_CALL_COUNT=$({ grep -h -F -o \
    'model.executeGhostRepairBulkOneShot()' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
if [[ ! -f "$BULK_REPAIR_ACTION" ]] \
    || [[ "$BULK_REPAIR_FACTORY_REFERENCE_COUNT" != "1" ]] \
    || [[ "$BULK_REPAIR_MODEL_FACTORY_CALL_COUNT" != "1" ]] \
    || [[ "$BULK_REPAIR_REVIEW_UI_CALL_COUNT" != "0" ]] \
    || [[ "$BULK_REPAIR_REVIEW_MODEL_HANDOFF_COUNT" != "1" ]] \
    || [[ "$BULK_REPAIR_EXECUTION_UI_CALL_COUNT" != "0" ]] \
    || grep -nE 'FileManager|sqlite3_|CodexGhostRepairBulkProductionExecution|AGENT_SESSION_MANAGER_RESEARCH' \
        "$BULK_REPAIR_ACTION" \
    || ! grep -q 'public static let unavailable' "$BULK_REPAIR_ACTION" \
    || ! grep -q 'public var automaticRetryAllowed: Bool { false }' "$BULK_REPAIR_ACTION" \
    || ! grep -q 'public var automaticRestoreAllowed: Bool { false }' "$BULK_REPAIR_ACTION" \
    || ! grep -q 'public var silentSelectionShrinkAllowed: Bool { false }' "$BULK_REPAIR_ACTION" \
    || ! grep -q 'Keep Codex closed and Agent Session Manager open' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q 'Confirm the selected batch once' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift" \
    || ! grep -q '"continueGhostCleanupAfterShutdown"' \
        "$APP_SOURCE/GhostRepairBulkInventorySheet.swift"; then
    print -u2 "The M4f bulk final-review surface is missing its exact production facade, single confirmation and shutdown handoff, or safe one-shot boundaries."
    exit 1
fi

DRY_RUN_UI_CALL_COUNT=$({ grep -h -F -o \
    'model.analyzeGhostRepairDryRunPreview(' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
DRY_RUN_READBACK_UI_CALL_COUNT=$({ grep -h -F -o \
    'model.readSavedGhostRepairDryRunPreview(' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
DRY_RUN_VERIFICATION_COPY_UI_COUNT=$({ grep -h -F -o \
    'copyGhostRepairDryRunVerificationBundle' \
    "$APP_SOURCE"/*.swift || true; } | wc -l | tr -d ' ')
if [[ "$DRY_RUN_UI_CALL_COUNT" != "0" ]] \
    || [[ "$DRY_RUN_READBACK_UI_CALL_COUNT" != "0" ]] \
    || [[ "$DRY_RUN_VERIFICATION_COPY_UI_COUNT" != "0" ]] \
    || grep -qE 'SnapshotDryRunPreviewSheet|Enable Experimental Snapshot Dry-run Preview|Open Dry-run Preview|Continue to Category A Repair' "$APP_SOURCE/SettingsView.swift" \
    || grep -qE 'ghostRepairDryRun|GhostRepairDryRunPreviewState' \
        "$APP_SOURCE/SessionManagerModel.swift"; then
    print -u2 "The retired manual dry-run must not remain a Shipping model or UI path."
    exit 1
fi

if grep -qE 'ghostRepairDestinationCanary|GhostRepairDestinationCanaryState' \
        "$APP_SOURCE/SessionManagerModel.swift" \
    || grep -qE 'SnapshotStorageCanarySheet|Enable Snapshot Storage Canary|Open Snapshot Storage Canary' "$APP_SOURCE/SettingsView.swift"; then
    print -u2 "The retired Snapshot Storage Canary must not remain a Shipping model or UI path."
    exit 1
fi

if [[ ! -d "$FIXTURE_SOURCE" ]] \
    || ! grep -q 'name: "AgentSessionManagerFixtures"' "$PACKAGE_FILE"; then
    print -u2 "Fixture support is not isolated in its dedicated Swift package target."
    exit 1
fi

if [[ $# -gt 0 ]]; then
    APP_BUNDLE=$1
    APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentSessionManager"
    if [[ ! -x "$APP_BINARY" ]]; then
        print -u2 "Shipping App binary is unavailable: $APP_BINARY"
        exit 1
    fi
    for binary in "$APP_BUNDLE"/Contents/MacOS/*; do
        [[ -f "$binary" ]] || continue
        if /usr/bin/strings -a "$binary" \
            | grep -E 'ASM_ISOLATED_DELETE|IsolatedDeleteAcceptance'; then
            print -u2 "Shipping App contains test-only isolated Delete acceptance code: $binary"
            exit 1
        fi
        if /usr/bin/strings -a "$binary" \
            | grep -E 'AgentSessionManagerFixtures|FixtureSessionProvider|FixtureOperationHistoryLedger|BulkShippingComposition(TestFixture|AcceptanceTests)|InventoryMode|testtube\.2|CodexGhostRepairDisposable(Bundle|Coordinator|Executor|SnapshotReader|SnapshotAcquirer|SnapshotDestination)|CodexGhostRepairBulk(ProductionExecutionJournal|ProductionComposition|ProductionMutator)|CodexGhostRepairBulkOperationBoundBackupTransport|CodexGhostRepairBulkRepairExecutionCoordinator|CodexGhostRepairCategoryA(RepairCoordinatorFactory|Disposable|ProductionRecipe)|CodexGhostRepairCanonical(AcquisitionSource|SourceFile|SourceRead)|CodexGhostRepairDestination(Preparer|Directory|Preparation|CanaryExistingRootPrepareCoordinator)|CodexGhostRepairProductionDestination|CodexGhostRepairPrepared(SnapshotDestination|DestinationBinding)|CodexGhostRepairPublishedSnapshot|CodexGhostRepairSnapshot(Capacity|Partial|Journal)|CodexGhostRepairQuarantineTrash|CodexGhostRepairPlanner'; then
            print -u2 "Shipping App code contains Fixture or disposable private-database symbols: $binary"
            exit 1
        fi
    done
fi

print "Shipping boundary verified: App is Codex Live-only; Recorded Report reads are manager-only; fresh outcome recovery may finalize only the original journal, without Codex deletion; Bulk execution remains no-path and non-replaying."
