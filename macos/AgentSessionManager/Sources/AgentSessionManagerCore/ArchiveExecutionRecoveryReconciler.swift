import Foundation

/// Recovery receives only read-only inventory capability. It cannot issue or
/// retry an Archive request, even if reconciliation is run more than once.
protocol ArchiveExecutionRecoveryReadback: Sendable {
    func inventorySnapshot() async throws -> ProviderInventorySnapshot
}

actor CodexArchiveExecutionRecoveryReadback: ArchiveExecutionRecoveryReadback {
    private let source: any CodexInventorySource

    init(source: any CodexInventorySource = CodexAppServerClient()) {
        self.source = source
    }

    func inventorySnapshot() async throws -> ProviderInventorySnapshot {
        let snapshot = try await source.inventory()
        return try CodexProviderInventorySnapshotBuilder.make(from: snapshot)
    }
}

enum ArchiveExecutionRecoveryError: Error, Equatable, LocalizedError {
    case invalidPreview(String)
    case checkpointUnavailable(String)
    case evidenceUnavailable(String)
    case reportPersistenceFailed(previewID: UUID, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidPreview(message):
            "Archive recovery rejected the Preview: \(message)"
        case let .checkpointUnavailable(message):
            "Archive recovery checkpoint is unavailable: \(message)"
        case let .evidenceUnavailable(message):
            "Archive recovery evidence is unavailable: \(message)"
        case let .reportPersistenceFailed(previewID, message):
            "Archive recovery readback completed, but its Report could not be persisted for Preview \(previewID.uuidString): \(message). The executing Preview remains retryable by readback only."
        }
    }
}

/// Resolves one durable `.executing` native Archive or Restore Preview after
/// execution was interrupted before its Report commit. Insufficient evidence
/// leaves the Preview executing so a later read-only reconciliation can retry.
actor ArchiveExecutionRecoveryReconciler {
    private let store: SQLiteStateStore
    private let readback: any ArchiveExecutionRecoveryReadback
    private let makeReportID: @Sendable () -> UUID

    init(
        store: SQLiteStateStore,
        readback: any ArchiveExecutionRecoveryReadback,
        makeReportID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.readback = readback
        self.makeReportID = makeReportID
    }

    func reconcile(previewID: UUID) async throws -> PersistentOperationReport {
        let context = try loadContext(previewID: previewID)
        let snapshot = try await readback.inventorySnapshot()
        return try reconcile(context: context, snapshot: snapshot)
    }

    /// Reuses an already completed official inventory observation. This keeps
    /// app refresh recovery read-only without starting a second transport.
    func reconcile(
        previewID: UUID,
        snapshot: ProviderInventorySnapshot
    ) throws -> PersistentOperationReport {
        let context = try loadContext(previewID: previewID)
        return try reconcile(context: context, snapshot: snapshot)
    }

    private func reconcile(
        context: (preview: PersistentOperationPreview, runtimeVersion: String),
        snapshot: ProviderInventorySnapshot
    ) throws -> PersistentOperationReport {
        let evidence = try classify(
            snapshot: snapshot,
            preview: context.preview,
            expectedRuntimeVersion: context.runtimeVersion
        )
        let report = makeReport(
            preview: context.preview,
            evidence: evidence,
            completedAt: max(context.preview.createdAt, snapshot.observedAt)
        )
        do {
            try store.saveOperationReport(report, requiringPreviewStatus: .executing)
        } catch {
            throw ArchiveExecutionRecoveryError.reportPersistenceFailed(
                previewID: context.preview.id,
                message: error.localizedDescription
            )
        }
        return report
    }

    private func loadContext(
        previewID: UUID
    ) throws -> (preview: PersistentOperationPreview, runtimeVersion: String) {
        guard let preview = try store.operationPreview(id: previewID) else {
            throw ArchiveExecutionRecoveryError.invalidPreview("the exact persisted Preview does not exist")
        }
        guard preview.status == .executing else {
            throw ArchiveExecutionRecoveryError.invalidPreview(
                "status must be executing, found \(preview.status.rawValue)"
            )
        }
        let expectedState: NativeSessionState = switch preview.operation {
        case .archive, .moveToTrash: .active
        case .restore: .archived
        default: .unavailable
        }
        guard preview.provider == .codex,
              preview.operation == .archive
                || preview.operation == .moveToTrash
                || preview.operation == .restore,
              preview.items.count == 1,
              let item = preview.items.first,
              item.expectedNativeState == expectedState,
              item.managerKey == "\(AgentSystem.codex.rawValue):\(item.nativeSessionID)" else {
            throw ArchiveExecutionRecoveryError.invalidPreview(
                "native lifecycle recovery requires one exact Codex Archive or Restore item"
            )
        }
        guard let checkpoint = try store.providerCheckpoint(for: .codex),
              let runtimeVersion = checkpoint.runtimeVersion,
              !runtimeVersion.isEmpty else {
            throw ArchiveExecutionRecoveryError.checkpointUnavailable(
                "the persisted Codex runtime identity is missing"
            )
        }
        guard CodexAppServerProvider.supportsVerifiedLifecycleContract(runtimeVersion) else {
            throw ArchiveExecutionRecoveryError.checkpointUnavailable(
                "runtime \(runtimeVersion) is outside the verified lifecycle contract"
            )
        }
        guard checkpoint.inventoryComplete,
              checkpoint.inventoryHash == preview.providerInventoryHash else {
            throw ArchiveExecutionRecoveryError.checkpointUnavailable(
                "the original claim checkpoint was replaced or is incomplete; recovery must run before normal checkpoint refresh"
            )
        }
        let expectedManifestHash = try ArchiveExecutionHasher.manifestHash(
            provider: preview.provider,
            operation: preview.operation,
            providerInventoryHash: preview.providerInventoryHash,
            runtimeVersion: runtimeVersion,
            reconciliationTimestamp: checkpoint.refreshedAt,
            createdAt: preview.createdAt,
            expiresAt: preview.expiresAt,
            affectedSetHash: preview.affectedSetHash,
            trashMembershipMutation: preview.trashMembershipMutation,
            items: preview.items
        )
        guard expectedManifestHash == preview.manifestHash else {
            throw ArchiveExecutionRecoveryError.checkpointUnavailable(
                "the original claim checkpoint no longer validates the frozen manifest"
            )
        }
        return (preview, runtimeVersion)
    }

    private func classify(
        snapshot: ProviderInventorySnapshot,
        preview: PersistentOperationPreview,
        expectedRuntimeVersion: String
    ) throws -> RecoveryEvidence {
        guard snapshot.provider == .codex else {
            throw ArchiveExecutionRecoveryError.evidenceUnavailable("provider identity mismatch")
        }
        guard snapshot.inventoryComplete else {
            throw ArchiveExecutionRecoveryError.evidenceUnavailable(
                "the official active and archived inventory is incomplete"
            )
        }
        guard snapshot.runtimeVersion == expectedRuntimeVersion,
              CodexAppServerProvider.supportsVerifiedLifecycleContract(expectedRuntimeVersion) else {
            throw ArchiveExecutionRecoveryError.evidenceUnavailable(
                "runtime identity changed from the persisted verified contract"
            )
        }
        guard snapshot.observedAt >= preview.createdAt else {
            throw ArchiveExecutionRecoveryError.evidenceUnavailable(
                "inventory evidence predates the durable Preview"
            )
        }

        let item = preview.items[0]
        let exactMatches = snapshot.sessions.filter { session in
            session.id == item.managerKey && session.nativeID == item.nativeSessionID
        }
        guard exactMatches.count <= 1 else {
            throw ArchiveExecutionRecoveryError.evidenceUnavailable(
                "inventory returned duplicate exact native identities"
            )
        }
        guard let session = exactMatches.first else {
            let isArchiveTransition = preview.operation != .restore
            let codePrefix = isArchiveTransition ? "archive" : "restore"
            let operationLabel = isArchiveTransition ? "Archive" : "Restore"
            return RecoveryEvidence(
                outcome: .unknown,
                itemOutcome: .unknown,
                observedState: .unavailable,
                errorCode: "\(codePrefix)_recovery_identity_missing",
                message: "Complete official inventory did not return the exact session identity. \(operationLabel) cannot be proven and was not retried."
            )
        }
        let isArchiveTransition = preview.operation != .restore
        let successState: NativeSessionState = isArchiveTransition
            ? .archived
            : .active
        let originalState: NativeSessionState = isArchiveTransition
            ? .active
            : .archived
        let operationLabel = isArchiveTransition ? "Archive" : "Restore"
        let codePrefix = isArchiveTransition ? "archive" : "restore"

        if session.nativeState == successState {
            return RecoveryEvidence(
                outcome: .success,
                itemOutcome: .success,
                observedState: successState,
                errorCode: nil,
                message: nil
            )
        }
        if session.nativeState == originalState {
            return RecoveryEvidence(
                outcome: .unknown,
                itemOutcome: .unknown,
                observedState: originalState,
                errorCode: "\(codePrefix)_recovery_still_\(originalState.rawValue)",
                message: "Complete official inventory still reports \(originalState.rawValue.capitalized). The earlier \(operationLabel) outcome is unknown and the request was not retried."
            )
        }
        switch session.nativeState {
        case .absent:
            throw ArchiveExecutionRecoveryError.evidenceUnavailable(
                "bounded list inventory cannot establish exact-ID absence"
            )
        case .unavailable:
            throw ArchiveExecutionRecoveryError.evidenceUnavailable(
                "the exact session state is unavailable"
            )
        case .active, .archived:
            throw ArchiveExecutionRecoveryError.evidenceUnavailable(
                "the exact session state is outside the frozen lifecycle transition"
            )
        }
    }

    private func makeReport(
        preview: PersistentOperationPreview,
        evidence: RecoveryEvidence,
        completedAt: Date
    ) -> PersistentOperationReport {
        PersistentOperationReport(
            id: makeReportID(),
            previewID: preview.id,
            provider: preview.provider,
            operation: preview.operation,
            outcome: evidence.outcome,
            // Schema v1 has no separate claim timestamp. Preview creation is
            // the earliest durable boundary for this recovered operation.
            startedAt: preview.createdAt,
            completedAt: completedAt,
            releasedBytesComplete: true,
            errorCode: evidence.errorCode,
            errorMessage: evidence.message,
            items: [
                PersistentReportItem(
                    managerKey: preview.items[0].managerKey,
                    outcome: evidence.itemOutcome,
                    observedNativeState: evidence.observedState,
                    verifiedReleasedBytes: 0,
                    evidenceAt: completedAt,
                    errorCode: evidence.errorCode,
                    errorMessage: evidence.message
                ),
            ]
        )
    }

    private struct RecoveryEvidence {
        let outcome: PersistentReportOutcome
        let itemOutcome: PersistentItemOutcome
        let observedState: NativeSessionState
        let errorCode: String?
        let message: String?
    }
}
