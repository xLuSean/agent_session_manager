import Foundation

public enum ExactSessionReadbackStatus: String, Codable, Sendable {
    case present
    case absent
    case unavailable

    public var label: String {
        switch self {
        case .present: "Present"
        case .absent: "Absent"
        case .unavailable: "Unavailable"
        }
    }
}

public enum ExactSessionReadbackEvidenceKind: String, Codable, Sendable {
    case exactMatch = "exact_match"
    case documentedNotFound = "documented_not_found"
    case invalidRequest = "invalid_request"
    case identityMismatch = "identity_mismatch"
    case rpcError = "rpc_error"
    case timeout
    case processFailure = "process_failure"
    case malformedResponse = "malformed_response"
    case sourceUnavailable = "source_unavailable"
    case unknownFailure = "unknown_failure"

    public var label: String {
        switch self {
        case .exactMatch: "Exact match"
        case .documentedNotFound: "Documented not found"
        case .invalidRequest: "Invalid request"
        case .identityMismatch: "Identity mismatch"
        case .rpcError: "Undocumented RPC error"
        case .timeout: "Timeout"
        case .processFailure: "Process or transport failure"
        case .malformedResponse: "Malformed response"
        case .sourceUnavailable: "Exact read source unavailable"
        case .unknownFailure: "Unknown failure"
        }
    }
}

/// A not-found mapping is valid only for one exact provider runtime and RPC
/// code, backed by a named official source. Broader version ranges are
/// intentionally unsupported until the provider publishes that guarantee.
public struct ExactSessionAbsenceContract: Codable, Equatable, Sendable {
    public let provider: AgentSystem
    public let runtimeVersion: String
    public let rpcCode: Int
    public let identifier: String
    public let officialSourceURL: URL

    public init(
        provider: AgentSystem,
        runtimeVersion: String,
        rpcCode: Int,
        identifier: String,
        officialSourceURL: URL
    ) {
        self.provider = provider
        self.runtimeVersion = runtimeVersion
        self.rpcCode = rpcCode
        self.identifier = identifier
        self.officialSourceURL = officialSourceURL
    }
}

/// Evidence returned by a provider's official exact-ID read interface.
/// `absent` is reserved for a documented, version-compatible not-found result;
/// a generic RPC, transport, timeout, or decode failure must be `unavailable`.
public struct ExactSessionReadbackEvidence: Codable, Equatable, Sendable {
    public let provider: AgentSystem
    public let nativeSessionID: String
    public let status: ExactSessionReadbackStatus
    public let observedAt: Date
    public let runtimeVersion: String?
    public let evidenceKind: ExactSessionReadbackEvidenceKind
    public let rpcCode: Int?
    public let absenceContract: ExactSessionAbsenceContract?
    public let message: String

    public init(
        provider: AgentSystem,
        nativeSessionID: String,
        status: ExactSessionReadbackStatus,
        observedAt: Date,
        runtimeVersion: String? = nil,
        evidenceKind: ExactSessionReadbackEvidenceKind = .unknownFailure,
        rpcCode: Int? = nil,
        absenceContract: ExactSessionAbsenceContract? = nil,
        message: String
    ) {
        self.provider = provider
        self.nativeSessionID = nativeSessionID
        self.status = status
        self.observedAt = observedAt
        self.runtimeVersion = runtimeVersion
        self.evidenceKind = evidenceKind
        self.rpcCode = rpcCode
        self.absenceContract = absenceContract
        self.message = message
    }

    public var provesExistence: Bool {
        status == .present && evidenceKind == .exactMatch
    }
    public var provesAbsence: Bool {
        guard status == .absent,
              evidenceKind == .documentedNotFound,
              let runtimeVersion,
              let rpcCode,
              let absenceContract else {
            return false
        }
        return absenceContract.provider == provider
            && absenceContract.runtimeVersion == runtimeVersion
            && absenceContract.rpcCode == rpcCode
            && !absenceContract.identifier.isEmpty
            && absenceContract.officialSourceURL.scheme == "https"
    }
}

public protocol ExactSessionReadbackProviding: Sendable {
    var system: AgentSystem { get }
    func exactReadback(nativeSessionID: String) async -> ExactSessionReadbackEvidence
}
