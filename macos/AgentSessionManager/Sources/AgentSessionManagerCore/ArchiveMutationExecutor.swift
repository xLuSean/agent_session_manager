import CryptoKit
import Foundation

protocol ArchiveMutationTransport: Sendable {
    func inventorySnapshot() async throws -> ProviderInventorySnapshot
    func archive(nativeSessionID: String) async throws
    func archive(nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws
}

enum CodexProviderInventorySnapshotBuilder {
    static func make(from snapshot: CodexInventorySnapshot) throws -> ProviderInventorySnapshot {
        let sessions = CodexAppServerProvider.map(snapshot: snapshot)
        let archiveScope = CodexAppServerProvider.archiveScope(snapshot: snapshot)
        let runtimeVersion = snapshot.runtimeVersion
        let inventoryHash = try InventorySnapshotHasher.hash(
            provider: .codex,
            sessions: sessions,
            archiveScopeNodes: archiveScope.nodes,
            archiveScopeComplete: archiveScope.isComplete,
            compatibilityBinding: snapshot.compatibilityBinding
        )
        let pinStateComplete = sessions.allSatisfy { $0.protection.isPinnedKnown }
        let runningStateComplete = !sessions.isEmpty && sessions.allSatisfy {
            $0.protection.isRunningKnown
        }
        let currentStateComplete = sessions.allSatisfy {
            $0.protection.isCurrentKnown
        }
        let pinnedDescendantComplete = sessions.allSatisfy {
            $0.protection.hasPinnedDescendantKnown
        }
        return ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtimeVersion,
            compatibilityBinding: snapshot.compatibilityBinding,
            inventoryHash: inventoryHash,
            observedAt: snapshot.refreshedAt,
            inventoryComplete: !snapshot.isTruncated,
            protectionComplete: pinStateComplete
                && runningStateComplete
                && currentStateComplete
                && pinnedDescendantComplete,
            sessions: sessions,
            archiveScopeNodes: archiveScope.nodes,
            archiveScopeComplete: archiveScope.isComplete
        )
    }
}

/// Internal production transport for the guarded Archive executor. It is deliberately
/// not owned by `CodexAppServerProvider`, `SessionManagerModel`, or SwiftUI.
/// Constructing the normal live provider therefore cannot reach Archive.
actor CodexArchiveMutationTransport: ArchiveMutationTransport {
    private let source: any CodexArchiveSource

    init(source: any CodexArchiveSource = CodexAppServerClient()) {
        self.source = source
    }

    func inventorySnapshot() async throws -> ProviderInventorySnapshot {
        try CodexProviderInventorySnapshotBuilder.make(from: await source.inventory())
    }

    func archive(nativeSessionID: String) async throws {
        try await archive(nativeSessionID: nativeSessionID, expectedCompatibility: nil)
    }

    func archive(nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        try await source.archive(threadID: nativeSessionID, expectedCompatibility: expectedCompatibility)
    }
}

enum ArchiveExecutionOutcome: String, Codable, Hashable, Sendable {
    case success
    case failure
    case unknown
}

struct ArchiveExecutionResult: Codable, Equatable, Sendable {
    let previewID: UUID
    let managerKey: String
    let nativeSessionID: String
    let outcome: ArchiveExecutionOutcome
    let archiveRequestAcknowledged: Bool
    let observedNativeState: NativeSessionState
    let completedAt: Date
    let errorCode: String?
    let message: String

    init(
        previewID: UUID,
        managerKey: String,
        nativeSessionID: String,
        outcome: ArchiveExecutionOutcome,
        archiveRequestAcknowledged: Bool,
        observedNativeState: NativeSessionState,
        completedAt: Date,
        errorCode: String? = nil,
        message: String
    ) {
        self.previewID = previewID
        self.managerKey = managerKey
        self.nativeSessionID = nativeSessionID
        self.outcome = outcome
        self.archiveRequestAcknowledged = archiveRequestAcknowledged
        self.observedNativeState = observedNativeState
        self.completedAt = completedAt
        self.errorCode = errorCode
        self.message = message
    }
}

enum ArchiveExecutionError: Error, Equatable, LocalizedError {
    case invalidPreview(String)
    case expired
    case confirmationMismatch
    case checkpointMismatch(String)
    case preflightUnavailable(String)
    case stateDrift(String)
    case protectedSession(String)
    case descendantScopeChanged(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidPreview(message):
            "Invalid Archive Preview: \(message)"
        case .expired:
            "The frozen Archive Preview expired before execution."
        case .confirmationMismatch:
            "Archive confirmation does not match the frozen Preview."
        case let .checkpointMismatch(message):
            "Archive checkpoint mismatch: \(message)"
        case let .preflightUnavailable(message):
            "Archive preflight is unavailable: \(message)"
        case let .stateDrift(message):
            "Archive preflight detected state drift: \(message)"
        case let .protectedSession(message):
            "Archive is blocked by lifecycle protection: \(message)"
        case let .descendantScopeChanged(count):
            "Archive is blocked because the session now has \(count) descendant(s)."
        }
    }
}

/// Canonical hashes used by the native Archive executor contract. They are
/// intentionally independent of Swift's randomized `Hashable` implementation.
enum ArchiveExecutionHasher {
    static func confirmationTokenHash(_ token: String) -> String {
        digest(Data(token.utf8))
    }

    static func protectionHash(for session: AgentSession) throws -> String {
        try protectionHash(
            nativeSessionID: session.nativeID,
            protection: session.protection,
            descendantCount: session.descendantCount,
            descendantCountKnown: session.descendantCountKnown
        )
    }

    static func protectionHash(
        nativeSessionID: String,
        protection: SessionProtection,
        descendantCount: Int,
        descendantCountKnown: Bool
    ) throws -> String {
        let payload = ProtectionPayload(
            provider: .codex,
            nativeSessionID: nativeSessionID,
            protection: protection,
            descendantCount: descendantCount,
            descendantCountKnown: descendantCountKnown
        )
        return try digest(payload)
    }

    static func manifestHash(
        provider: AgentSystem,
        operation: PersistentOperation,
        providerInventoryHash: String,
        runtimeVersion: String,
        compatibilityBinding: CodexCompatibilityBinding? = nil,
        reconciliationTimestamp: Date,
        createdAt: Date,
        expiresAt: Date,
        affectedSetHash: String? = nil,
        trashMembershipMutation: TrashMembershipMutation? = nil,
        expectedTrashMembershipSetHash: String? = nil,
        items: [PersistentPreviewItem]
    ) throws -> String {
        if let compatibilityBinding {
            let unboundHash = try manifestHash(provider: provider, operation: operation,
                providerInventoryHash: providerInventoryHash, runtimeVersion: runtimeVersion,
                reconciliationTimestamp: reconciliationTimestamp, createdAt: createdAt, expiresAt: expiresAt,
                affectedSetHash: affectedSetHash, trashMembershipMutation: trashMembershipMutation,
                expectedTrashMembershipSetHash: expectedTrashMembershipSetHash, items: items)
            return try digest(BoundManifestPayload(manifestHash: unboundHash, compatibilityBinding: compatibilityBinding))
        }
        if let expectedTrashMembershipSetHash {
            return try digest(ManifestPayloadV3(
                provider: provider,
                operation: operation,
                providerInventoryHash: providerInventoryHash,
                runtimeVersion: runtimeVersion,
                reconciliationTimestamp: persistentTimestamp(reconciliationTimestamp),
                createdAt: persistentTimestamp(createdAt),
                expiresAt: persistentTimestamp(expiresAt),
                affectedSetHash: affectedSetHash,
                trashMembershipMutation: trashMembershipMutation,
                expectedTrashMembershipSetHash: expectedTrashMembershipSetHash,
                items: items.sorted { $0.managerKey < $1.managerKey }
            ))
        }
        if let trashMembershipMutation {
            return try digest(ManifestPayloadV2(
                provider: provider,
                operation: operation,
                providerInventoryHash: providerInventoryHash,
                runtimeVersion: runtimeVersion,
                reconciliationTimestamp: persistentTimestamp(reconciliationTimestamp),
                createdAt: persistentTimestamp(createdAt),
                expiresAt: persistentTimestamp(expiresAt),
                affectedSetHash: affectedSetHash,
                trashMembershipMutation: trashMembershipMutation,
                items: items.sorted { $0.managerKey < $1.managerKey }
            ))
        }
        let payload = ManifestPayload(
            provider: provider,
            operation: operation,
            providerInventoryHash: providerInventoryHash,
            runtimeVersion: runtimeVersion,
            reconciliationTimestamp: persistentTimestamp(reconciliationTimestamp),
            createdAt: persistentTimestamp(createdAt),
            expiresAt: persistentTimestamp(expiresAt),
            affectedSetHash: affectedSetHash,
            items: items.sorted { $0.managerKey < $1.managerKey }
        )
        return try digest(payload)
    }

    /// Manifest dates use the exact textual precision SQLite persists. Hashing
    /// raw `Date` values would bind sub-millisecond bits that are intentionally
    /// lost on durable Preview/checkpoint readback.
    private static func persistentTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return digest(try encoder.encode(value))
    }

    private static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct BoundManifestPayload: Encodable {
        let manifestHash: String
        let compatibilityBinding: CodexCompatibilityBinding
    }

    private struct ProtectionPayload: Encodable {
        let provider: AgentSystem
        let nativeSessionID: String
        let protection: SessionProtection
        let descendantCount: Int
        let descendantCountKnown: Bool
    }

    private struct ManifestPayload: Encodable {
        let provider: AgentSystem
        let operation: PersistentOperation
        let providerInventoryHash: String
        let runtimeVersion: String
        let reconciliationTimestamp: String
        let createdAt: String
        let expiresAt: String
        let affectedSetHash: String?
        let items: [PersistentPreviewItem]
    }

    private struct ManifestPayloadV2: Encodable {
        let provider: AgentSystem
        let operation: PersistentOperation
        let providerInventoryHash: String
        let runtimeVersion: String
        let reconciliationTimestamp: String
        let createdAt: String
        let expiresAt: String
        let affectedSetHash: String?
        let trashMembershipMutation: TrashMembershipMutation
        let items: [PersistentPreviewItem]
    }

    private struct ManifestPayloadV3: Encodable {
        let provider: AgentSystem
        let operation: PersistentOperation
        let providerInventoryHash: String
        let runtimeVersion: String
        let reconciliationTimestamp: String
        let createdAt: String
        let expiresAt: String
        let affectedSetHash: String?
        let trashMembershipMutation: TrashMembershipMutation?
        let expectedTrashMembershipSetHash: String
        let items: [PersistentPreviewItem]
    }
}

/// Internal single-item Archive executor. Production reaches it only through
/// the public facade and durable authorization coordinator; SwiftUI and the
/// read-only provider cannot construct it directly.
actor ArchiveMutationExecutor {
    private let transport: any ArchiveMutationTransport
    private let now: @Sendable () -> Date

    init(
        transport: any ArchiveMutationTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    func execute(
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        confirmationToken: String
    ) async throws -> ArchiveExecutionResult {
        let item = try validateFrozenPreview(
            preview,
            checkpoint: checkpoint,
            confirmationToken: confirmationToken
        )
        let preflight = try await transport.inventorySnapshot()
        let preflightSession = try validatePreflight(
            preflight,
            preview: preview,
            checkpoint: checkpoint,
            item: item
        )
        let frozenProtectionHash = try ArchiveExecutionHasher.protectionHash(for: preflightSession)
        guard frozenProtectionHash == item.expectedProtectionHash else {
            throw ArchiveExecutionError.stateDrift("protection evidence changed after Preview")
        }

        var acknowledgementError: Error?
        do {
            try await transport.archive(nativeSessionID: item.nativeSessionID, expectedCompatibility: checkpoint.compatibilityBinding)
        } catch {
            // The request may have reached App Server. Never retry it blindly;
            // proceed directly to one authoritative inventory readback.
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
            return ArchiveExecutionResult(
                previewID: preview.id,
                managerKey: item.managerKey,
                nativeSessionID: item.nativeSessionID,
                outcome: .unknown,
                archiveRequestAcknowledged: acknowledgementError == nil,
                observedNativeState: .unavailable,
                completedAt: now(),
                errorCode: errorCode(for: error, prefix: "readback"),
                message: "Archive outcome is unknown because the exact post-operation inventory readback failed. The request was not retried."
            )
        }
    }

    private func validateFrozenPreview(
        _ preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        confirmationToken: String
    ) throws -> PersistentPreviewItem {
        guard preview.provider == .codex, checkpoint.provider == .codex else {
            throw ArchiveExecutionError.invalidPreview("Archive supports only Codex sessions")
        }
        guard (preview.operation == .archive || preview.operation == .moveToTrash),
              preview.status == .executing else {
            throw ArchiveExecutionError.invalidPreview("operation must be a claimed executing Archive transition")
        }
        guard preview.items.count == 1, let item = preview.items.first else {
            throw ArchiveExecutionError.invalidPreview("exactly one frozen item is required")
        }
        guard item.managerKey == "\(AgentSystem.codex.rawValue):\(item.nativeSessionID)" else {
            throw ArchiveExecutionError.invalidPreview("manager key does not match the native ID")
        }
        guard item.expectedNativeState == .active else {
            throw ArchiveExecutionError.invalidPreview("the frozen native state must be Active")
        }
        guard preview.expiresAt > now() else {
            throw ArchiveExecutionError.expired
        }
        guard ArchiveExecutionHasher.confirmationTokenHash(confirmationToken)
            == preview.confirmationTokenHash else {
            throw ArchiveExecutionError.confirmationMismatch
        }
        guard checkpoint.inventoryComplete else {
            throw ArchiveExecutionError.checkpointMismatch("inventory evidence must be complete")
        }
        guard preview.providerInventoryHash == checkpoint.inventoryHash,
              let runtimeVersion = checkpoint.runtimeVersion,
              !runtimeVersion.isEmpty else {
            throw ArchiveExecutionError.checkpointMismatch("Preview inventory or runtime binding is unavailable")
        }
        guard CodexLifecycleMutationKind.archive.supports(runtimeVersion: runtimeVersion, binding: checkpoint.compatibilityBinding) else {
            throw ArchiveExecutionError.checkpointMismatch("runtime is outside the verified Archive contract")
        }
        let manifestHash = try ArchiveExecutionHasher.manifestHash(
            provider: preview.provider,
            operation: preview.operation,
            providerInventoryHash: preview.providerInventoryHash,
            runtimeVersion: runtimeVersion,
            compatibilityBinding: checkpoint.compatibilityBinding,
            reconciliationTimestamp: checkpoint.refreshedAt,
            createdAt: preview.createdAt,
            expiresAt: preview.expiresAt,
            affectedSetHash: preview.affectedSetHash,
            trashMembershipMutation: preview.trashMembershipMutation,
            expectedTrashMembershipSetHash: preview.expectedTrashMembershipSetHash,
            items: preview.items
        )
        guard manifestHash == preview.manifestHash else {
            throw ArchiveExecutionError.invalidPreview("canonical manifest hash mismatch")
        }
        return item
    }

    private func validatePreflight(
        _ snapshot: ProviderInventorySnapshot,
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        item: PersistentPreviewItem
    ) throws -> AgentSession {
        guard snapshot.provider == .codex else {
            throw ArchiveExecutionError.preflightUnavailable("provider identity mismatch")
        }
        guard snapshot.inventoryComplete else {
            throw ArchiveExecutionError.preflightUnavailable("inventory coverage is incomplete")
        }
        guard snapshot.runtimeVersion == checkpoint.runtimeVersion,
              snapshot.compatibilityBinding == checkpoint.compatibilityBinding else {
            throw ArchiveExecutionError.stateDrift("runtime version changed")
        }
        // The provider inventory hash covers every Codex session, including
        // display-only fields such as title and updatedAt. Unrelated activity
        // must not invalidate one exact-ID mutation. The frozen target state,
        // protection hash and descendant scope are revalidated below instead.
        guard snapshot.observedAt >= checkpoint.refreshedAt else {
            throw ArchiveExecutionError.preflightUnavailable("inventory predates the frozen reconciliation checkpoint")
        }
        guard let session = snapshot.sessions.first(where: { $0.id == item.managerKey }) else {
            throw ArchiveExecutionError.stateDrift("the exact frozen session is no longer present")
        }
        guard session.nativeID == item.nativeSessionID, session.nativeState == .active else {
            throw ArchiveExecutionError.stateDrift("native identity or Active state changed")
        }
        guard !session.protection.blocksArchiveAttempt else {
            throw ArchiveExecutionError.protectedSession(
                session.protection.archiveAttemptBlockingLabels.joined(separator: ", ")
            )
        }
        guard session.descendantCountKnown else {
            throw ArchiveExecutionError.preflightUnavailable("descendant scope is unknown")
        }
        guard session.descendantCount == 0 else {
            throw ArchiveExecutionError.descendantScopeChanged(session.descendantCount)
        }
        return session
    }

    private func classifyReadback(
        _ snapshot: ProviderInventorySnapshot,
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        item: PersistentPreviewItem,
        acknowledgementError: Error?,
        readbackNotBefore: Date,
        completedAt: Date
    ) -> ArchiveExecutionResult {
        guard snapshot.provider == .codex,
              snapshot.inventoryComplete,
              snapshot.runtimeVersion == checkpoint.runtimeVersion,
              snapshot.compatibilityBinding == checkpoint.compatibilityBinding else {
            return unknownResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                completedAt: completedAt,
                state: .unavailable,
                code: "readback_incomplete",
                message: "Archive outcome is unknown because post-operation provider/runtime evidence is incomplete."
            )
        }
        guard snapshot.observedAt >= readbackNotBefore else {
            return unknownResult(
                preview: preview,
                item: item,
                acknowledgementError: acknowledgementError,
                completedAt: completedAt,
                state: .unavailable,
                code: "readback_stale",
                message: "Archive outcome is unknown because the post-operation inventory snapshot predates the mutation attempt."
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
                code: "readback_identity_missing",
                message: "Archive outcome is unknown because exact-ID inventory readback did not return the frozen session."
            )
        }

        if session.nativeState == .archived {
            return ArchiveExecutionResult(
                previewID: preview.id,
                managerKey: item.managerKey,
                nativeSessionID: item.nativeSessionID,
                outcome: .success,
                archiveRequestAcknowledged: acknowledgementError == nil,
                observedNativeState: .archived,
                completedAt: completedAt,
                errorCode: acknowledgementError.map { errorCode(for: $0, prefix: "archive_request") },
                message: acknowledgementError == nil
                    ? "Official post-operation inventory readback verified Archived."
                    : "Archive acknowledgement was uncertain, but official post-operation inventory readback verified Archived; the request was not retried."
            )
        }

        if session.nativeState == .active,
           case .rpcError? = acknowledgementError as? CodexAppServerError {
            let rejection = acknowledgementError.map { archiveRejectionDetails(for: $0) }
            return ArchiveExecutionResult(
                previewID: preview.id,
                managerKey: item.managerKey,
                nativeSessionID: item.nativeSessionID,
                outcome: .failure,
                archiveRequestAcknowledged: false,
                observedNativeState: .active,
                completedAt: completedAt,
                errorCode: rejection?.code,
                message: rejection?.message
                    ?? "App Server rejected Archive and exact post-operation inventory readback still verified Active."
            )
        }

        return unknownResult(
            preview: preview,
            item: item,
            acknowledgementError: acknowledgementError,
            completedAt: completedAt,
            state: session.nativeState,
            code: acknowledgementError.map { errorCode(for: $0, prefix: "archive_request") }
                ?? "archive_not_observed",
            message: "Archive was not verified by the bounded post-operation inventory readback. The request was not retried."
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
    ) -> ArchiveExecutionResult {
        ArchiveExecutionResult(
            previewID: preview.id,
            managerKey: item.managerKey,
            nativeSessionID: item.nativeSessionID,
            outcome: .unknown,
            archiveRequestAcknowledged: acknowledgementError == nil,
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
        case .exactReadUnavailable:
            return "\(prefix)_source_unavailable"
        }
    }

    private func archiveRejectionDetails(for error: Error) -> (code: String, message: String) {
        guard case let .rpcError(code, serverMessage) = error as? CodexAppServerError else {
            return (
                errorCode(for: error, prefix: "archive_request"),
                "App Server rejected Archive and exact post-operation inventory readback still verified Active."
            )
        }

        if serverMessage.localizedCaseInsensitiveContains("already has an active writer") {
            return (
                "archive_request_busy_active_writer",
                "App Server rejected Archive because another Codex host still owns the session writer: \(serverMessage). Exact post-operation inventory readback verified Active. No automatic retry was attempted; a new Preview and confirmation are required after the writer is released."
            )
        }

        return (
            "archive_request_rpc_\(code)",
            "App Server rejected Archive (RPC \(code)): \(serverMessage). Exact post-operation inventory readback still verified Active."
        )
    }
}
