import Foundation

protocol RestoreMutationTransport: Sendable {
    func inventorySnapshot() async throws -> ProviderInventorySnapshot
    func restore(nativeSessionID: String) async throws
}

actor CodexRestoreMutationTransport: RestoreMutationTransport {
    private let source: any CodexRestoreSource

    init(source: any CodexRestoreSource = CodexAppServerClient()) {
        self.source = source
    }

    func inventorySnapshot() async throws -> ProviderInventorySnapshot {
        try CodexProviderInventorySnapshotBuilder.make(from: await source.inventory())
    }

    func restore(nativeSessionID: String) async throws {
        try await source.unarchive(threadID: nativeSessionID)
    }
}

struct RestoreExecutionResult: Equatable, Sendable {
    let previewID: UUID
    let managerKey: String
    let nativeSessionID: String
    let outcome: ArchiveExecutionOutcome
    let restoreRequestAcknowledged: Bool
    let observedNativeState: NativeSessionState
    let completedAt: Date
    let errorCode: String?
    let message: String
}

enum RestoreExecutionError: Error, Equatable, LocalizedError {
    case invalidPreview(String)
    case expired
    case confirmationMismatch
    case checkpointMismatch(String)
    case preflightUnavailable(String)
    case stateDrift(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPreview(message):
            "Invalid Restore Preview: \(message)"
        case .expired:
            "The frozen Restore Preview expired before execution."
        case .confirmationMismatch:
            "Restore confirmation does not match the frozen Preview."
        case let .checkpointMismatch(message):
            "Restore checkpoint mismatch: \(message)"
        case let .preflightUnavailable(message):
            "Restore preflight is unavailable: \(message)"
        case let .stateDrift(message):
            "Restore preflight detected state drift: \(message)"
        }
    }
}

/// Executes one exact Codex Archived -> Active transition. Restore is not a
/// destructive lifecycle operation, so Archive-only pin/running/descendant
/// prohibitions do not apply. Identity, state, runtime and inventory evidence
/// are still frozen and revalidated before one non-retried request.
actor RestoreMutationExecutor {
    private let transport: any RestoreMutationTransport
    private let now: @Sendable () -> Date

    init(
        transport: any RestoreMutationTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    func execute(
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        confirmationToken: String
    ) async throws -> RestoreExecutionResult {
        let item = try validateFrozenPreview(
            preview,
            checkpoint: checkpoint,
            confirmationToken: confirmationToken
        )
        let preflight = try await transport.inventorySnapshot()
        try validatePreflight(
            preflight,
            preview: preview,
            checkpoint: checkpoint,
            item: item
        )

        var acknowledgementError: Error?
        do {
            try await transport.restore(nativeSessionID: item.nativeSessionID)
        } catch {
            // Delivery can be indeterminate. Never replay automatically; use
            // the exact post-operation inventory as the outcome authority.
            acknowledgementError = error
        }

        let readbackNotBefore = now()
        do {
            let readback = try await transport.inventorySnapshot()
            return classifyReadback(
                readback,
                preview: preview,
                checkpoint: checkpoint,
                item: item,
                acknowledgementError: acknowledgementError,
                readbackNotBefore: readbackNotBefore,
                completedAt: now()
            )
        } catch {
            return RestoreExecutionResult(
                previewID: preview.id,
                managerKey: item.managerKey,
                nativeSessionID: item.nativeSessionID,
                outcome: .unknown,
                restoreRequestAcknowledged: acknowledgementError == nil,
                observedNativeState: .unavailable,
                completedAt: now(),
                errorCode: errorCode(for: error, prefix: "restore_readback"),
                message: "Restore outcome is unknown because the exact post-operation inventory readback failed. The request was not retried."
            )
        }
    }

    private func validateFrozenPreview(
        _ preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        confirmationToken: String
    ) throws -> PersistentPreviewItem {
        guard preview.provider == .codex, checkpoint.provider == .codex else {
            throw RestoreExecutionError.invalidPreview("the first executor slice accepts only Codex")
        }
        guard preview.operation == .restore, preview.status == .executing else {
            throw RestoreExecutionError.invalidPreview("operation must be a claimed executing Restore")
        }
        guard preview.items.count == 1, let item = preview.items.first else {
            throw RestoreExecutionError.invalidPreview("exactly one frozen item is required")
        }
        guard item.managerKey == "\(AgentSystem.codex.rawValue):\(item.nativeSessionID)" else {
            throw RestoreExecutionError.invalidPreview("manager key does not match the native ID")
        }
        guard item.expectedNativeState == .archived else {
            throw RestoreExecutionError.invalidPreview("the frozen native state must be Archived")
        }
        guard preview.expiresAt > now() else {
            throw RestoreExecutionError.expired
        }
        guard ArchiveExecutionHasher.confirmationTokenHash(confirmationToken)
            == preview.confirmationTokenHash else {
            throw RestoreExecutionError.confirmationMismatch
        }
        guard checkpoint.inventoryComplete else {
            throw RestoreExecutionError.checkpointMismatch("inventory evidence must be complete")
        }
        guard preview.providerInventoryHash == checkpoint.inventoryHash,
              let runtimeVersion = checkpoint.runtimeVersion,
              !runtimeVersion.isEmpty else {
            throw RestoreExecutionError.checkpointMismatch(
                "Preview inventory or runtime binding is unavailable"
            )
        }
        guard CodexAppServerProvider.supportsVerifiedLifecycleContract(runtimeVersion) else {
            throw RestoreExecutionError.checkpointMismatch(
                "runtime is outside the verified Restore contract"
            )
        }
        let manifestHash = try ArchiveExecutionHasher.manifestHash(
            provider: preview.provider,
            operation: preview.operation,
            providerInventoryHash: preview.providerInventoryHash,
            runtimeVersion: runtimeVersion,
            reconciliationTimestamp: checkpoint.refreshedAt,
            createdAt: preview.createdAt,
            expiresAt: preview.expiresAt,
            trashMembershipMutation: preview.trashMembershipMutation,
            items: preview.items
        )
        guard manifestHash == preview.manifestHash else {
            throw RestoreExecutionError.invalidPreview("canonical manifest hash mismatch")
        }
        return item
    }

    private func validatePreflight(
        _ snapshot: ProviderInventorySnapshot,
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        item: PersistentPreviewItem
    ) throws {
        guard snapshot.provider == .codex else {
            throw RestoreExecutionError.preflightUnavailable("provider identity mismatch")
        }
        guard snapshot.inventoryComplete else {
            throw RestoreExecutionError.preflightUnavailable("inventory coverage is incomplete")
        }
        guard snapshot.runtimeVersion == checkpoint.runtimeVersion else {
            throw RestoreExecutionError.stateDrift("runtime version changed")
        }
        // The inventory hash includes every session and display-only metadata.
        // Restore authorization is bound to the frozen Preview, while this
        // preflight must reject drift of the exact target identity/state only.
        guard snapshot.observedAt >= checkpoint.refreshedAt else {
            throw RestoreExecutionError.preflightUnavailable(
                "inventory predates the frozen reconciliation checkpoint"
            )
        }
        guard let session = snapshot.sessions.first(where: { $0.id == item.managerKey }) else {
            throw RestoreExecutionError.stateDrift("the exact frozen session is no longer present")
        }
        guard session.nativeID == item.nativeSessionID,
              session.nativeState == .archived else {
            throw RestoreExecutionError.stateDrift(
                "native identity or Archived state changed"
            )
        }
    }

    private func classifyReadback(
        _ snapshot: ProviderInventorySnapshot,
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        item: PersistentPreviewItem,
        acknowledgementError: Error?,
        readbackNotBefore: Date,
        completedAt: Date
    ) -> RestoreExecutionResult {
        guard snapshot.provider == .codex,
              snapshot.inventoryComplete,
              snapshot.runtimeVersion == checkpoint.runtimeVersion else {
            return unknownResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                completedAt: completedAt,
                state: .unavailable,
                code: "restore_readback_incomplete",
                message: "Restore outcome is unknown because post-operation provider/runtime evidence is incomplete."
            )
        }
        guard snapshot.observedAt >= readbackNotBefore else {
            return unknownResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                completedAt: completedAt,
                state: .unavailable,
                code: "restore_readback_stale",
                message: "Restore outcome is unknown because the post-operation inventory predates the mutation attempt."
            )
        }
        guard let session = snapshot.sessions.first(where: { $0.id == item.managerKey }),
              session.nativeID == item.nativeSessionID else {
            return unknownResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                completedAt: completedAt,
                state: .unavailable,
                code: "restore_readback_identity_missing",
                message: "Restore outcome is unknown because exact-ID inventory readback did not return the frozen session."
            )
        }

        if session.nativeState == .active {
            return RestoreExecutionResult(
                previewID: preview.id,
                managerKey: item.managerKey,
                nativeSessionID: item.nativeSessionID,
                outcome: .success,
                restoreRequestAcknowledged: acknowledgementError == nil,
                observedNativeState: .active,
                completedAt: completedAt,
                errorCode: acknowledgementError.map {
                    errorCode(for: $0, prefix: "restore_request")
                },
                message: acknowledgementError == nil
                    ? "Official post-operation inventory readback verified Active."
                    : "Restore acknowledgement was uncertain, but official post-operation inventory readback verified Active; the request was not retried."
            )
        }

        if session.nativeState == .archived,
           case .rpcError? = acknowledgementError as? CodexAppServerError {
            return RestoreExecutionResult(
                previewID: preview.id,
                managerKey: item.managerKey,
                nativeSessionID: item.nativeSessionID,
                outcome: .failure,
                restoreRequestAcknowledged: false,
                observedNativeState: .archived,
                completedAt: completedAt,
                errorCode: acknowledgementError.map {
                    errorCode(for: $0, prefix: "restore_request")
                },
                message: rejectionMessage(for: acknowledgementError)
            )
        }

        return unknownResult(
            preview: preview,
            item: item,
            acknowledgementError: acknowledgementError,
            completedAt: completedAt,
            state: session.nativeState,
            code: acknowledgementError.map {
                errorCode(for: $0, prefix: "restore_request")
            } ?? "restore_not_observed",
            message: "Restore was not verified by the bounded post-operation inventory readback. The request was not retried."
        )
    }

    private func unknownResult(
        preview: PersistentOperationPreview,
        item: PersistentPreviewItem,
        acknowledgementError: Error?,
        completedAt: Date,
        state: NativeSessionState,
        code: String,
        message: String
    ) -> RestoreExecutionResult {
        RestoreExecutionResult(
            previewID: preview.id,
            managerKey: item.managerKey,
            nativeSessionID: item.nativeSessionID,
            outcome: .unknown,
            restoreRequestAcknowledged: acknowledgementError == nil,
            observedNativeState: state,
            completedAt: completedAt,
            errorCode: code,
            message: message
        )
    }

    private func errorCode(for error: Error, prefix: String) -> String {
        guard let appServerError = error as? CodexAppServerError else {
            return "\(prefix)_unknown"
        }
        switch appServerError {
        case let .rpcError(code, _): return "\(prefix)_rpc_\(code)"
        case .responseTimeout: return "\(prefix)_timeout"
        case .processExited: return "\(prefix)_process_exit"
        case .malformedResponse: return "\(prefix)_malformed"
        case .launchFailed: return "\(prefix)_launch_failed"
        case .executableNotFound: return "\(prefix)_executable_missing"
        case .exactReadUnavailable: return "\(prefix)_source_unavailable"
        }
    }

    private func rejectionMessage(for error: Error?) -> String {
        guard case let .rpcError(code, serverMessage) = error as? CodexAppServerError else {
            return "App Server rejected Restore and exact post-operation inventory readback still verified Archived."
        }
        return "App Server rejected Restore (RPC \(code)): \(serverMessage). Exact post-operation inventory readback still verified Archived."
    }
}
