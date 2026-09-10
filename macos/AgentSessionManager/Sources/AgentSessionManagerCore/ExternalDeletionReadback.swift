import Foundation

/// Produced only after an exact read by the selected executable under the
/// external-deletion read-only contract. This is not Delete absence evidence.
struct CodexExternalDeletionAbsenceEvidence: Error, Sendable {
    let nativeSessionID: String
    let runtimeVersion: String
    let observedAt: Date
}

enum ExternalDeletionExactObservation: Equatable, Sendable {
    case present(nativeSessionID: String, observedAt: Date, runtimeVersion: String?)
    case absent(
        nativeSessionID: String,
        observedAt: Date,
        runtimeVersion: String,
        rpcCode: Int,
        message: String
    )
    case unavailable(observedAt: Date, errorCode: String, message: String)
}

/// Read-only boundary used by conflict resolution. It intentionally exposes no
/// Archive, Restore, or Delete method.
protocol ExternalDeletionReadback: Sendable {
    func inventorySnapshot() async throws -> ProviderInventorySnapshot
    func exactReadObservation(
        nativeSessionID: String,
        auditedRuntimeVersion: String
    ) async -> ExternalDeletionExactObservation
}

actor CodexExternalDeletionReadback: ExternalDeletionReadback {
    private let source: any CodexInventorySource

    init(source: any CodexInventorySource = CodexAppServerClient()) {
        self.source = source
    }

    func inventorySnapshot() async throws -> ProviderInventorySnapshot {
        try CodexProviderInventorySnapshotBuilder.make(from: await source.inventory())
    }

    func exactReadObservation(
        nativeSessionID: String,
        auditedRuntimeVersion: String
    ) async -> ExternalDeletionExactObservation {
        do {
            let snapshot = try await source.exactReadForExternalDeletion(threadID: nativeSessionID)
            guard snapshot.thread.id == nativeSessionID else {
                return .unavailable(
                    observedAt: snapshot.observedAt,
                    errorCode: "external_deletion_exact_read_identity_mismatch",
                    message: "thread/read returned a different native session ID."
                )
            }
            return .present(
                nativeSessionID: snapshot.thread.id,
                observedAt: snapshot.observedAt,
                runtimeVersion: snapshot.runtimeVersion
            )
        } catch let evidence as CodexExternalDeletionAbsenceEvidence
            where evidence.nativeSessionID == nativeSessionID
                && evidence.runtimeVersion == auditedRuntimeVersion
                && CodexAppServerProvider.supportsVerifiedExternalDeletionReadbackContract(
                    evidence.runtimeVersion
                ) {
            return .absent(
                nativeSessionID: evidence.nativeSessionID,
                observedAt: evidence.observedAt,
                runtimeVersion: evidence.runtimeVersion,
                rpcCode: -32600,
                message: "thread not loaded: \(evidence.nativeSessionID)"
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
            return "external_deletion_exact_read_unknown"
        }
        switch appServerError {
        case .executableNotFound: return "external_deletion_exact_read_executable_missing"
        case .launchFailed: return "external_deletion_exact_read_launch_failed"
        case .processExited: return "external_deletion_exact_read_process_exited"
        case .responseTimeout: return "external_deletion_exact_read_timeout"
        case .exactReadUnavailable: return "external_deletion_exact_read_unavailable"
        case .malformedResponse: return "external_deletion_exact_read_malformed"
        case let .rpcError(code, _): return "external_deletion_exact_read_rpc_\(code)"
        }
    }
}
