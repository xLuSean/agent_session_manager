import Foundation

extension CodexNativeBatchMutationTransport {
    func exactDeleteRead(_ nativeSessionID: String, auditedRuntimeVersion: String,
                  expectedCompatibility: CodexCompatibilityBinding?) async -> DeleteExactReadObservation {
        guard expectedCompatibility == nil else {
            return .unavailable(observedAt: Date(), errorCode: "compatibility_binding_required",
                                message: "This readback source cannot verify the frozen Codex environment.")
        }
        return await exactDeleteRead(nativeSessionID, auditedRuntimeVersion: auditedRuntimeVersion)
    }
}


extension DeleteExecutionRecoveryReadback {
    func exactReadObservation(nativeSessionID: String, auditedRuntimeVersion: String,
                  expectedCompatibility: CodexCompatibilityBinding?) async -> DeleteExactReadObservation {
        guard expectedCompatibility == nil else {
            return .unavailable(observedAt: Date(), errorCode: "compatibility_binding_required",
                                message: "This readback source cannot verify the frozen Codex environment.")
        }
        return await exactReadObservation(nativeSessionID: nativeSessionID, auditedRuntimeVersion: auditedRuntimeVersion)
    }
}


extension DeleteMutationTransport {
    func exactReadObservation(nativeSessionID: String, auditedRuntimeVersion: String,
                  expectedCompatibility: CodexCompatibilityBinding?) async -> DeleteExactReadObservation {
        guard expectedCompatibility == nil else {
            return .unavailable(observedAt: Date(), errorCode: "compatibility_binding_required",
                                message: "This readback source cannot verify the frozen Codex environment.")
        }
        return await exactReadObservation(nativeSessionID: nativeSessionID, auditedRuntimeVersion: auditedRuntimeVersion)
    }
}


// Legacy fixture transports cannot silently discard a frozen environment binding.
extension CodexNativeBatchMutationTransport {
    func archive(_ nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        guard expectedCompatibility == nil else { throw CodexCompatibilityInspector.CheckError.admissionRequired }
        try await archive(nativeSessionID)
    }

    func restore(_ nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        guard expectedCompatibility == nil else { throw CodexCompatibilityInspector.CheckError.admissionRequired }
        try await restore(nativeSessionID)
    }

    func delete(_ nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        guard expectedCompatibility == nil else { throw CodexCompatibilityInspector.CheckError.admissionRequired }
        try await delete(nativeSessionID)
    }
}
extension ArchiveMutationTransport {
    func archive(nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        guard expectedCompatibility == nil else { throw CodexCompatibilityInspector.CheckError.admissionRequired }
        try await archive(nativeSessionID: nativeSessionID)
    }
}

extension RestoreMutationTransport {
    func restore(nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        guard expectedCompatibility == nil else { throw CodexCompatibilityInspector.CheckError.admissionRequired }
        try await restore(nativeSessionID: nativeSessionID)
    }
}

extension DeleteMutationTransport {
    func delete(nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        guard expectedCompatibility == nil else { throw CodexCompatibilityInspector.CheckError.admissionRequired }
        try await delete(nativeSessionID: nativeSessionID)
    }
}
