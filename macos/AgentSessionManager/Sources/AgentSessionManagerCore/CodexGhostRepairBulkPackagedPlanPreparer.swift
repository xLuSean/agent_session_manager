import Foundation

/// Loads the exact confirmation receipt and frozen Preview from manager
/// SQLite, performs two fresh pre-backup observations, creates or cold-reads
/// one fixed verified operation backup, and returns one deterministic plan.
/// It never creates a mutation claim and never calls the mutator.
actor CodexGhostRepairBulkPackagedPlanPreparer:
    CodexGhostRepairBulkPackagedPlanPreparing
{
    typealias StoreProvider = @Sendable () throws -> SQLiteStateStore
    typealias ResolutionProvider = @Sendable (
        CodexGhostRepairBulkStoredPreview
    ) throws -> (
        CodexGhostRepairBulkProductionBundle.Resolution,
        CodexGhostRepairSnapshotSourceProfile
    )
    typealias MaintenanceObserverProvider = @Sendable (
        CodexGhostRepairSnapshotSourceProfile
    ) -> any CodexGhostRepairBulkFreshMaintenanceObserving
    typealias BackupTransportProvider = @Sendable (
        CodexGhostRepairBulkProductionBundle.Resolution,
        CodexGhostRepairBulkMaintenanceWindow
    ) throws -> CodexGhostRepairBulkLiveBackupTransport
    typealias TargetRevalidatorProvider = @Sendable (
        CodexGhostRepairSnapshotSourceProfile
    ) throws -> CodexGhostRepairBulkLiveTargetRevalidator

    private let storeProvider: StoreProvider
    private let resolutionProvider: ResolutionProvider
    private let maintenanceObserverProvider: MaintenanceObserverProvider
    private let backupTransportProvider: BackupTransportProvider
    private let targetRevalidatorProvider: TargetRevalidatorProvider
    private var activeReceiptID: UUID?

    static func production() -> Self {
        Self(
            storeProvider: {
                try SQLiteStateStore(
                    databaseURL: StateStoreLocation
                        .applicationSupportDatabaseURL()
                )
            },
            resolutionProvider: { preview in
                let resolution = try CodexGhostRepairBulkProductionBundle(
                    productionColdReadback: preview
                ).resolveForProduction()
                guard let profile = CodexGhostRepairSnapshotSourceProfile
                    .admitted(
                        sourceLayoutIdentifier:
                            resolution.sourceLayoutIdentifier
                    ) else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Bulk Final Review source layout is not packaged."
                    )
                }
                return (resolution, profile)
            },
            maintenanceObserverProvider: { profile in
                CodexGhostRepairBulkProductionMaintenanceObserver
                    .production(profile: profile)
            },
            backupTransportProvider: { resolution, window in
                try CodexGhostRepairBulkLiveBackupTransport.production(
                    resolution: resolution,
                    maintenanceWindow: window
                )
            },
            targetRevalidatorProvider: { profile in
                try CodexGhostRepairBulkLiveTargetRevalidator.production(
                    profile: profile
                )
            }
        )
    }

    init(
        storeProvider: @escaping StoreProvider,
        resolutionProvider: @escaping ResolutionProvider,
        maintenanceObserverProvider:
            @escaping MaintenanceObserverProvider,
        backupTransportProvider: @escaping BackupTransportProvider,
        targetRevalidatorProvider: @escaping TargetRevalidatorProvider
    ) {
        self.storeProvider = storeProvider
        self.resolutionProvider = resolutionProvider
        self.maintenanceObserverProvider = maintenanceObserverProvider
        self.backupTransportProvider = backupTransportProvider
        self.targetRevalidatorProvider = targetRevalidatorProvider
    }

    func receipt(
        confirmationReceiptID: UUID
    ) throws -> CodexGhostRepairBulkConfirmationReceipt {
        let store = try storeProvider()
        defer { store.close() }
        guard let receipt = try store.codexGhostRepairBulkConfirmationReceipt(
            receiptID: confirmationReceiptID
        ) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Whole-batch confirmation receipt is unavailable."
            )
        }
        return receipt
    }

    func prepare(
        confirmationReceiptID: UUID
    ) async throws -> CodexGhostRepairBulkPackagedPreparedOperation {
        guard activeReceiptID == nil else {
            throw CodexGhostRepairError.recoveryRequired
        }
        activeReceiptID = confirmationReceiptID
        defer { activeReceiptID = nil }

        let material = try loadMaterial(
            confirmationReceiptID: confirmationReceiptID
        )
        let (resolution, profile) = try resolutionProvider(material.preview)
        guard material.receipt.savedPreviewRequestID == resolution.requestID,
              material.receipt.selectedCount == resolution.selectedCount else {
            throw CodexGhostRepairError.authorityDrift
        }

        let collector = try CodexGhostRepairBulkFreshMaintenanceCollector(
            resolution: resolution,
            observer: maintenanceObserverProvider(profile)
        )
        let before = try await collector.collectFresh(
            phase: .beforeBackup
        )
        let repeated = try await collector.collectFresh(
            phase: .beforeBackupRepeat
        )
        let window = try CodexGhostRepairBulkMaintenanceWindow(
            before: before,
            after: repeated
        )
        let transport = try backupTransportProvider(resolution, window)
        try await transport.prepareFixedStorageIfNeeded()
        let destination = try await transport.inspectFreshDestination()
        let backup: CodexGhostRepairBulkLiveBackupReceipt
        switch destination.state {
        case .available:
            backup = try await transport.createExactBackup(
                destination: destination
            )
        case .exactColdReadback:
            backup = try await transport.readExactBackup(
                destination: destination.record
            )
        }
        let liveRevalidation = try await targetRevalidatorProvider(profile)
            .revalidate(
                storedPreview: material.preview,
                resolution: resolution,
                verifiedBackup: backup
            )
        let plan = try CodexGhostRepairBulkBackupBoundOperationPlan.prepare(
            coldReadback: material.preview,
            resolution: resolution,
            destination: destination.record,
            verifiedBackup: backup,
            liveRevalidation: liveRevalidation,
            plannedAtMilliseconds: max(
                max(
                    backup.capturedAtMilliseconds,
                    liveRevalidation.observedAtMilliseconds
                ),
                material.receipt.confirmedAtMilliseconds
            )
        )
        try CodexGhostRepairBulkLiveJournalRecord.validateReceipt(
            material.receipt,
            plan: plan
        )
        return CodexGhostRepairBulkPackagedPreparedOperation(
            plan: plan,
            receipt: material.receipt
        )
    }

    private func loadMaterial(
        confirmationReceiptID: UUID
    ) throws -> (
        receipt: CodexGhostRepairBulkConfirmationReceipt,
        preview: CodexGhostRepairBulkStoredPreview
    ) {
        let store = try storeProvider()
        defer { store.close() }
        guard let receipt = try store.codexGhostRepairBulkConfirmationReceipt(
                  receiptID: confirmationReceiptID
              ),
              let preview = try store.codexGhostRepairBulkPreview(
                  requestID: receipt.savedPreviewRequestID
              ),
              receipt.receiptID == confirmationReceiptID,
              preview.requestID == receipt.savedPreviewRequestID,
              preview.preview.selectedThreadIDs.count
                == receipt.selectedCount else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Confirmed whole-batch material is incomplete."
            )
        }
        return (receipt, preview)
    }
}
