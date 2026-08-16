import Foundation

enum ArchiveAuthorizationCoordinatorError: Error, Equatable, LocalizedError {
    case reportPersistenceFailed(
        previewID: UUID,
        executorOutcome: ArchiveExecutionOutcome,
        message: String
    )

    var errorDescription: String? {
        switch self {
        case let .reportPersistenceFailed(previewID, outcome, message):
            "Archive completed with executor outcome \(outcome.rawValue), but its audit Report could not be persisted for Preview \(previewID.uuidString): \(message). The executing Preview must be reconciled; never retry Archive blindly."
        }
    }
}

/// Internal persistence coordinator for the production single-item Archive
/// facade. App code cannot construct or bypass it directly.
actor ArchiveAuthorizationCoordinator {
    private let store: SQLiteStateStore
    private let executor: ArchiveMutationExecutor
    private let now: @Sendable () -> Date
    private let makeReportID: @Sendable () -> UUID

    init(
        store: SQLiteStateStore,
        executor: ArchiveMutationExecutor,
        now: @escaping @Sendable () -> Date = { Date() },
        makeReportID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.executor = executor
        self.now = now
        self.makeReportID = makeReportID
    }

    /// Persists a frozen Preview before confirmation is accepted. Returning the
    /// exact readback makes SQLite, not the caller's in-memory value, the source
    /// of truth for subsequent authorization.
    func prepare(
        _ preparedPreview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord
    ) throws -> PersistentOperationPreview {
        guard preparedPreview.status == .prepared else {
            throw PersistentStateError.invalidRecord(
                "Archive coordinator accepts only a prepared Preview."
            )
        }
        guard preparedPreview.provider == .codex,
              (preparedPreview.operation == .archive || preparedPreview.operation == .moveToTrash),
              (preparedPreview.operation == .archive
                ? preparedPreview.trashMembershipMutation == nil
                : preparedPreview.trashMembershipMutation == .add),
              preparedPreview.items.count == 1,
              preparedPreview.items[0].expectedNativeState == .active else {
            throw PersistentStateError.invalidRecord(
                "The Archive coordinator requires one active Codex item."
            )
        }
        try store.saveOperationPreview(preparedPreview, checkpoint: checkpoint)
        guard let persisted = try store.operationPreview(id: preparedPreview.id) else {
            throw PersistentStateError.recordNotFound(preparedPreview.id.uuidString)
        }
        guard persisted == preparedPreview else {
            throw PersistentStateError.invalidRecord(
                "Persisted Preview readback differs from the frozen Preview."
            )
        }
        return persisted
    }

    /// Claims only the exact SQLite Preview ID, executes at most once, then
    /// atomically persists the itemized Report and consumes the Preview.
    func execute(
        previewID: UUID,
        confirmationToken: String
    ) async throws -> PersistentOperationReport {
        let startedAt = now()
        let claimed = try store.claimOperationPreviewForExecution(
            id: previewID,
            now: startedAt,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            )
        )

        let executionResult: ArchiveExecutionResult
        do {
            executionResult = try await executor.execute(
                preview: claimed.preview,
                checkpoint: claimed.checkpoint,
                confirmationToken: confirmationToken
            )
        } catch {
            executionResult = ArchiveExecutionResult(
                previewID: claimed.preview.id,
                managerKey: claimed.preview.items[0].managerKey,
                nativeSessionID: claimed.preview.items[0].nativeSessionID,
                outcome: .failure,
                archiveRequestAcknowledged: false,
                observedNativeState: .unavailable,
                completedAt: now(),
                errorCode: executionErrorCode(error),
                message: error.localizedDescription
            )
        }

        let report = makeReport(
            from: executionResult,
            preview: claimed.preview,
            startedAt: startedAt
        )
        do {
            try store.saveOperationReport(report, requiringPreviewStatus: .executing)
        } catch {
            throw ArchiveAuthorizationCoordinatorError.reportPersistenceFailed(
                previewID: claimed.preview.id,
                executorOutcome: executionResult.outcome,
                message: error.localizedDescription
            )
        }
        return report
    }

    private func makeReport(
        from result: ArchiveExecutionResult,
        preview: PersistentOperationPreview,
        startedAt: Date
    ) -> PersistentOperationReport {
        let reportOutcome: PersistentReportOutcome
        let itemOutcome: PersistentItemOutcome
        switch result.outcome {
        case .success:
            reportOutcome = .success
            itemOutcome = .success
        case .failure:
            reportOutcome = .failure
            itemOutcome = .failure
        case .unknown:
            reportOutcome = .unknown
            itemOutcome = .unknown
        }

        return PersistentOperationReport(
            id: makeReportID(),
            previewID: preview.id,
            provider: preview.provider,
            operation: preview.operation,
            outcome: reportOutcome,
            startedAt: startedAt,
            completedAt: max(startedAt, result.completedAt),
            // Archive changes lifecycle state and releases no rollout bytes.
            releasedBytesComplete: true,
            errorCode: result.errorCode,
            errorMessage: result.outcome == .success ? nil : result.message,
            items: [
                PersistentReportItem(
                    managerKey: result.managerKey,
                    outcome: itemOutcome,
                    observedNativeState: result.observedNativeState,
                    verifiedReleasedBytes: 0,
                    evidenceAt: max(startedAt, result.completedAt),
                    errorCode: result.errorCode,
                    errorMessage: result.outcome == .success ? nil : result.message
                ),
            ]
        )
    }

    private func executionErrorCode(_ error: Error) -> String {
        guard let executionError = error as? ArchiveExecutionError else {
            return "archive_preflight_unknown"
        }
        switch executionError {
        case .expired: return "archive_preview_expired"
        case .confirmationMismatch: return "archive_confirmation_mismatch"
        case .invalidPreview: return "archive_preview_invalid"
        case .checkpointMismatch: return "archive_checkpoint_mismatch"
        case .preflightUnavailable: return "archive_preflight_unavailable"
        case .stateDrift: return "archive_state_drift"
        case .protectedSession: return "archive_session_protected"
        case .descendantScopeChanged: return "archive_descendant_scope_changed"
        }
    }
}
