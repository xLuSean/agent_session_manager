import Foundation

enum DeleteExactReadObservation: Equatable, Sendable {
    case present(nativeSessionID: String, observedAt: Date, runtimeVersion: String?)
    case absent(nativeSessionID: String, observedAt: Date, runtimeVersion: String)
    case unavailable(observedAt: Date, errorCode: String, message: String)
}

protocol DeleteMutationTransport: Sendable {
    func inventorySnapshot() async throws -> ProviderInventorySnapshot
    func delete(nativeSessionID: String) async throws
    func exactReadObservation(
        nativeSessionID: String,
        auditedRuntimeVersion: String
    ) async -> DeleteExactReadObservation
}

actor CodexDeleteMutationTransport: DeleteMutationTransport {
    private let source: any CodexDeleteSource

    init(source: any CodexDeleteSource = CodexAppServerClient()) {
        self.source = source
    }

    func inventorySnapshot() async throws -> ProviderInventorySnapshot {
        try CodexProviderInventorySnapshotBuilder.make(from: await source.inventory())
    }

    func delete(nativeSessionID: String) async throws {
        try await source.delete(threadID: nativeSessionID)
    }

    func exactReadObservation(
        nativeSessionID: String,
        auditedRuntimeVersion: String
    ) async -> DeleteExactReadObservation {
        do {
            let snapshot = try await source.exactRead(threadID: nativeSessionID)
            guard snapshot.thread.id == nativeSessionID else {
                return .unavailable(
                    observedAt: snapshot.observedAt,
                    errorCode: "delete_exact_read_identity_mismatch",
                    message: "thread/read returned a different native session ID."
                )
            }
            return .present(
                nativeSessionID: snapshot.thread.id,
                observedAt: snapshot.observedAt,
                runtimeVersion: snapshot.runtimeVersion
            )
        } catch let CodexAppServerError.rpcError(code, message)
            where code == -32600
                && message == "thread not loaded: \(nativeSessionID)"
                && CodexAppServerProvider.supportsVerifiedDeleteContract(
                    auditedRuntimeVersion
                ) {
            // The 0.147.0 Delete contract is deliberately narrow: this exact
            // discriminator is accepted only together with a complete fresh
            // inventory that also omits the same ID. Generic RPC errors never
            // prove absence.
            return .absent(
                nativeSessionID: nativeSessionID,
                observedAt: Date(),
                runtimeVersion: auditedRuntimeVersion
            )
        } catch {
            return .unavailable(
                observedAt: Date(),
                errorCode: Self.errorCode(for: error),
                message: error.localizedDescription
            )
        }
    }

    private static func errorCode(for error: Error) -> String {
        guard let appServerError = error as? CodexAppServerError else {
            return "delete_exact_read_unknown"
        }
        switch appServerError {
        case .executableNotFound: return "delete_exact_read_executable_missing"
        case .launchFailed: return "delete_exact_read_launch_failed"
        case .processExited: return "delete_exact_read_process_exited"
        case .responseTimeout: return "delete_exact_read_timeout"
        case .exactReadUnavailable: return "delete_exact_read_unavailable"
        case .malformedResponse: return "delete_exact_read_malformed"
        case let .rpcError(code, _): return "delete_exact_read_rpc_\(code)"
        }
    }
}

struct DeleteExecutionResult: Equatable, Sendable {
    let previewID: UUID
    let managerKey: String
    let nativeSessionID: String
    let outcome: ArchiveExecutionOutcome
    let deleteRequestAcknowledged: Bool
    let observedNativeState: NativeSessionState
    let completedAt: Date
    let errorCode: String?
    let message: String
}

enum DeleteExecutionError: Error, Equatable, LocalizedError {
    case invalidPreview(String)
    case expired
    case confirmationMismatch
    case checkpointMismatch(String)
    case preflightUnavailable(String)
    case stateDrift(String)
    case protectedSession([String])
    case descendantScopeChanged

    var errorDescription: String? {
        switch self {
        case let .invalidPreview(message):
            "Invalid Permanent Delete Preview: \(message)"
        case .expired:
            "The frozen Permanent Delete Preview expired before execution."
        case .confirmationMismatch:
            "Permanent Delete confirmation does not match the frozen Preview."
        case let .checkpointMismatch(message):
            "Permanent Delete checkpoint mismatch: \(message)"
        case let .preflightUnavailable(message):
            "Permanent Delete preflight is unavailable: \(message)"
        case let .stateDrift(message):
            "Permanent Delete preflight detected state drift: \(message)"
        case let .protectedSession(labels):
            "Permanent Delete is blocked by: \(labels.joined(separator: ", "))."
        case .descendantScopeChanged:
            "Permanent Delete requires a verified session with zero descendants."
        }
    }
}

/// Executes one exact Codex Trash -> Deleted transition. The executor receives
/// only a claimed durable Preview, sends at most one `thread/delete`, and
/// requires both complete list absence and the audited exact-read absence
/// discriminator before reporting success.
actor DeleteMutationExecutor {
    private let transport: any DeleteMutationTransport
    private let now: @Sendable () -> Date

    init(
        transport: any DeleteMutationTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    func execute(
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        confirmationToken: String
    ) async throws -> DeleteExecutionResult {
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
            try await transport.delete(nativeSessionID: item.nativeSessionID)
        } catch {
            acknowledgementError = error
        }

        let readbackNotBefore = now()
        let runtimeVersion = checkpoint.runtimeVersion ?? ""
        async let exactObservation = transport.exactReadObservation(
            nativeSessionID: item.nativeSessionID,
            auditedRuntimeVersion: runtimeVersion
        )
        do {
            let inventory = try await transport.inventorySnapshot()
            return classifyReadback(
                inventory: inventory,
                exactObservation: await exactObservation,
                preview: preview,
                checkpoint: checkpoint,
                item: item,
                acknowledgementError: acknowledgementError,
                readbackNotBefore: readbackNotBefore,
                completedAt: now()
            )
        } catch {
            _ = await exactObservation
            return unknownResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                completedAt: now(),
                code: "delete_readback_inventory_failed",
                message: "Permanent Delete outcome is unknown because the complete post-operation inventory failed. The request was not retried."
            )
        }
    }

    private func validateFrozenPreview(
        _ preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        confirmationToken: String
    ) throws -> PersistentPreviewItem {
        guard preview.provider == .codex, checkpoint.provider == .codex else {
            throw DeleteExecutionError.invalidPreview("only Codex is supported")
        }
        guard preview.operation == .permanentlyDelete,
              preview.status == .executing,
              preview.trashMembershipMutation == .remove else {
            throw DeleteExecutionError.invalidPreview(
                "operation must be a claimed Permanent Delete with frozen Trash removal"
            )
        }
        guard preview.items.count == 1, let item = preview.items.first else {
            throw DeleteExecutionError.invalidPreview("exactly one frozen item is required")
        }
        guard item.managerKey == "\(AgentSystem.codex.rawValue):\(item.nativeSessionID)",
              item.expectedNativeState == .archived else {
            throw DeleteExecutionError.invalidPreview(
                "the exact Trash item must be natively Archived"
            )
        }
        guard preview.expiresAt > now() else { throw DeleteExecutionError.expired }
        guard ArchiveExecutionHasher.confirmationTokenHash(confirmationToken)
            == preview.confirmationTokenHash else {
            throw DeleteExecutionError.confirmationMismatch
        }
        guard checkpoint.inventoryComplete else {
            throw DeleteExecutionError.checkpointMismatch(
                "a complete inventory checkpoint is required"
            )
        }
        guard preview.providerInventoryHash == checkpoint.inventoryHash,
              let runtimeVersion = checkpoint.runtimeVersion,
              CodexAppServerProvider.supportsVerifiedDeleteContract(runtimeVersion) else {
            throw DeleteExecutionError.checkpointMismatch(
                "Preview inventory or audited Delete runtime binding is unavailable"
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
            throw DeleteExecutionError.invalidPreview("canonical manifest hash mismatch")
        }
        return item
    }

    private func validatePreflight(
        _ snapshot: ProviderInventorySnapshot,
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        item: PersistentPreviewItem
    ) throws {
        guard snapshot.provider == .codex,
              snapshot.inventoryComplete else {
            throw DeleteExecutionError.preflightUnavailable(
                "provider inventory is incomplete"
            )
        }
        guard snapshot.runtimeVersion == checkpoint.runtimeVersion,
              snapshot.observedAt >= checkpoint.refreshedAt else {
            throw DeleteExecutionError.stateDrift(
                "runtime changed or preflight predates the frozen checkpoint"
            )
        }
        guard let session = snapshot.sessions.first(where: { $0.id == item.managerKey }),
              session.nativeID == item.nativeSessionID,
              session.nativeState == .archived else {
            throw DeleteExecutionError.stateDrift(
                "the exact frozen session is missing or no longer Archived"
            )
        }
        guard session.descendantCountKnown, session.descendantCount == 0 else {
            throw DeleteExecutionError.descendantScopeChanged
        }
        guard !session.protection.blocksDeleteAttempt else {
            throw DeleteExecutionError.protectedSession(
                session.protection.deleteAttemptBlockingLabels
            )
        }
        _ = preview
    }

    private func classifyReadback(
        inventory: ProviderInventorySnapshot,
        exactObservation: DeleteExactReadObservation,
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        item: PersistentPreviewItem,
        acknowledgementError: Error?,
        readbackNotBefore: Date,
        completedAt: Date
    ) -> DeleteExecutionResult {
        guard inventory.provider == .codex,
              inventory.inventoryComplete,
              inventory.runtimeVersion == checkpoint.runtimeVersion,
              inventory.observedAt >= readbackNotBefore else {
            return unknownResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                completedAt: completedAt,
                code: "delete_readback_inventory_incomplete",
                message: "Permanent Delete outcome is unknown because post-operation inventory evidence is incomplete or stale."
            )
        }

        let inventoryMatch = inventory.sessions.first {
            $0.id == item.managerKey && $0.nativeID == item.nativeSessionID
        }
        if let inventoryMatch {
            return stillPresentResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                observedState: inventoryMatch.nativeState,
                completedAt: completedAt
            )
        }

        switch exactObservation {
        case let .absent(nativeSessionID, observedAt, runtimeVersion)
            where nativeSessionID == item.nativeSessionID
                && observedAt >= readbackNotBefore
                && runtimeVersion == checkpoint.runtimeVersion:
            return DeleteExecutionResult(
                previewID: preview.id,
                managerKey: item.managerKey,
                nativeSessionID: item.nativeSessionID,
                outcome: .success,
                deleteRequestAcknowledged: acknowledgementError == nil,
                observedNativeState: .absent,
                completedAt: completedAt,
                errorCode: acknowledgementError.map {
                    errorCode(for: $0, prefix: "delete_request")
                },
                message: acknowledgementError == nil
                    ? "Official post-operation list and exact-ID readback verified the session is absent."
                    : "Delete acknowledgement was uncertain, but both official readbacks verified absence; the request was not retried."
            )

        case let .present(nativeSessionID, observedAt, runtimeVersion)
            where nativeSessionID == item.nativeSessionID
                && observedAt >= readbackNotBefore
                && runtimeVersion == checkpoint.runtimeVersion:
            return stillPresentResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                observedState: .archived,
                completedAt: completedAt
            )

        case let .unavailable(_, code, message):
            return unknownResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                completedAt: completedAt,
                code: code,
                message: "Permanent Delete outcome is unknown because exact-ID absence was not proven: \(message)"
            )

        default:
            return unknownResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                completedAt: completedAt,
                code: "delete_readback_exact_mismatch",
                message: "Permanent Delete outcome is unknown because exact-ID readback identity, runtime, or timestamp did not match the frozen request."
            )
        }
    }

    private func stillPresentResult(
        preview: PersistentOperationPreview,
        item: PersistentPreviewItem,
        acknowledgementError: Error?,
        observedState: NativeSessionState,
        completedAt: Date
    ) -> DeleteExecutionResult {
        if case .rpcError? = acknowledgementError as? CodexAppServerError {
            return DeleteExecutionResult(
                previewID: preview.id,
                managerKey: item.managerKey,
                nativeSessionID: item.nativeSessionID,
                outcome: .failure,
                deleteRequestAcknowledged: false,
                observedNativeState: observedState,
                completedAt: completedAt,
                errorCode: acknowledgementError.map {
                    errorCode(for: $0, prefix: "delete_request")
                },
                message: "App Server rejected Permanent Delete and official readback still returned the session."
            )
        }
        return unknownResult(
            preview: preview,
            item: item,
            acknowledgementError: acknowledgementError,
            completedAt: completedAt,
            code: "delete_not_observed",
            message: "Permanent Delete was not verified because official readback still returned the session. The request was not retried."
        )
    }

    private func unknownResult(
        preview: PersistentOperationPreview,
        item: PersistentPreviewItem,
        acknowledgementError: Error?,
        completedAt: Date,
        code: String,
        message: String
    ) -> DeleteExecutionResult {
        DeleteExecutionResult(
            previewID: preview.id,
            managerKey: item.managerKey,
            nativeSessionID: item.nativeSessionID,
            outcome: .unknown,
            deleteRequestAcknowledged: acknowledgementError == nil,
            observedNativeState: .unavailable,
            completedAt: completedAt,
            errorCode: acknowledgementError.map {
                errorCode(for: $0, prefix: "delete_request")
            } ?? code,
            message: message
        )
    }

    private func errorCode(for error: Error, prefix: String) -> String {
        guard let appServerError = error as? CodexAppServerError else {
            return "\(prefix)_unknown"
        }
        switch appServerError {
        case .executableNotFound: return "\(prefix)_executable_missing"
        case .launchFailed: return "\(prefix)_launch_failed"
        case .processExited: return "\(prefix)_process_exited"
        case .responseTimeout: return "\(prefix)_timeout"
        case .exactReadUnavailable: return "\(prefix)_exact_read_unavailable"
        case .malformedResponse: return "\(prefix)_malformed"
        case let .rpcError(code, _): return "\(prefix)_rpc_\(code)"
        }
    }
}
