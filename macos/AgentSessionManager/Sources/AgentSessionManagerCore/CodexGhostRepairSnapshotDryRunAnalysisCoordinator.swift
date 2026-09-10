import Foundation

public struct CodexGhostRepairSnapshotDryRunAnalysisRequest:
    Equatable,
    Sendable
{
    public let requestID: UUID
    public let snapshotReference: String
    public let previewID: UUID
    public let generatedAtMilliseconds: Int64
    public let lifetimeMilliseconds: Int64

    public init(
        requestID: UUID,
        snapshotReference: String,
        previewID: UUID,
        generatedAtMilliseconds: Int64,
        lifetimeMilliseconds: Int64
    ) {
        self.requestID = requestID
        self.snapshotReference = snapshotReference
        self.previewID = previewID
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.lifetimeMilliseconds = lifetimeMilliseconds
    }

    public var acceptsCallerPath: Bool { false }
    public var automaticAnalysis: Bool { false }
    public var persistsPreview: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public enum CodexGhostRepairSnapshotDryRunAnalysisOutcome:
    Hashable,
    Sendable
{
    case preview(
        requestID: UUID,
        preview: CodexGhostRepairSnapshotDryRunPreview
    )
    case persistedPreview(
        requestID: UUID,
        preview: CodexGhostRepairSnapshotDryRunPreview,
        receipt: CodexGhostRepairSnapshotDryRunPersistenceReceipt
    )
    case persistenceUnavailable(
        requestID: UUID,
        failure: CodexGhostRepairSnapshotDryRunPersistenceFailure
    )
    case blocked(
        requestID: UUID,
        blockers: [CodexGhostRepairSnapshotDryRunBlocker]
    )
    case compatibilityReview(
        requestID: UUID,
        evidence: CodexGhostRepairExperimentalCompatibilityEvidence
    )
    case compatibilityUnavailable(
        requestID: UUID,
        failure: CodexGhostRepairExperimentalCompatibilityFailure
    )
    case unavailable(requestID: UUID, message: String)

    public var requestID: UUID {
        switch self {
        case let .preview(requestID, _),
             let .persistedPreview(requestID, _, _),
             let .persistenceUnavailable(requestID, _),
             let .blocked(requestID, _),
             let .compatibilityReview(requestID, _),
             let .compatibilityUnavailable(requestID, _),
             let .unavailable(requestID, _):
            requestID
        }
    }

    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public enum CodexGhostRepairSnapshotDryRunPersistenceFailureReason:
    String,
    Codable,
    Hashable,
    Sendable
{
    case writeOrReadbackFailed = "write-or-readback-failed"
    case receiptIdentityMismatch = "receipt-identity-mismatch"
}

public struct CodexGhostRepairSnapshotDryRunPersistenceFailure:
    Codable,
    Hashable,
    Sendable
{
    public let snapshotReference: String
    public let reason:
        CodexGhostRepairSnapshotDryRunPersistenceFailureReason

    public var previewPresented: Bool { false }
    public var persistenceOutcome: String { "unknown" }
    public var automaticRetry: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var pathRedacted: Bool { true }
}

public struct CodexGhostRepairSnapshotDryRunAnalysisCapabilities:
    Hashable,
    Sendable
{
    public let analysisAvailable: Bool
    public let identityResolutionAvailable: Bool
    public let snapshotQueryAvailable: Bool
    public let protectionAuditAvailable: Bool
    public let compatibilityReviewAvailable: Bool
    public let usesEphemeralAnalysisWorkspace: Bool
    public let previewPersistenceAvailable: Bool
    public let admittedExperimentalContractAvailable: Bool

    public var acceptsCallerPath: Bool { false }
    public var automaticAnalysis: Bool { false }
    public var automaticRetry: Bool { false }
    public var writesFilesystem: Bool { usesEphemeralAnalysisWorkspace }
    public var writesPublishedSnapshot: Bool { false }
    public var persistsPreview: Bool { previewPersistenceAvailable }
    public var experimentalAbsenceContractAvailable: Bool {
        admittedExperimentalContractAvailable
    }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let unavailable = Self(
        analysisAvailable: false,
        identityResolutionAvailable: false,
        snapshotQueryAvailable: false,
        protectionAuditAvailable: false,
        compatibilityReviewAvailable: false,
        usesEphemeralAnalysisWorkspace: false,
        previewPersistenceAvailable: false,
        admittedExperimentalContractAvailable: false
    )

    static let deterministicReadOnlyCandidate = Self(
        analysisAvailable: true,
        identityResolutionAvailable: true,
        snapshotQueryAvailable: true,
        protectionAuditAvailable: true,
        compatibilityReviewAvailable: false,
        usesEphemeralAnalysisWorkspace: true,
        previewPersistenceAvailable: false,
        admittedExperimentalContractAvailable: false
    )

    static let packagedCompatibilityReview = Self(
        analysisAvailable: true,
        identityResolutionAvailable: true,
        snapshotQueryAvailable: true,
        protectionAuditAvailable: false,
        compatibilityReviewAvailable: true,
        usesEphemeralAnalysisWorkspace: true,
        previewPersistenceAvailable: false,
        admittedExperimentalContractAvailable: false
    )

    static let packagedAdmittedPreview = Self(
        analysisAvailable: true,
        identityResolutionAvailable: true,
        snapshotQueryAvailable: true,
        protectionAuditAvailable: true,
        compatibilityReviewAvailable: true,
        usesEphemeralAnalysisWorkspace: true,
        previewPersistenceAvailable: true,
        admittedExperimentalContractAvailable: true
    )
}

public protocol CodexGhostRepairSnapshotDryRunAnalysisCoordinating: Sendable {
    var capabilities: CodexGhostRepairSnapshotDryRunAnalysisCapabilities {
        get
    }

    func analyze(
        request: CodexGhostRepairSnapshotDryRunAnalysisRequest
    ) async -> CodexGhostRepairSnapshotDryRunAnalysisOutcome
}

struct CodexGhostRepairSnapshotDryRunProtectionAudit:
    Equatable,
    Sendable
{
    let identity: CodexGhostRepairSnapshotAnalysisIdentity
    let protectionEvidence: [CodexGhostRepairProtectionEvidence]
    let experimentalAbsenceEvidence:
        [CodexGhostRepairExperimentalAbsenceEvidence]
    let operationalAudit: CodexGhostRepairExecutionGate
}

protocol CodexGhostRepairSnapshotDryRunProtectionAuditSource: Sendable {
    func audit(
        requestID: UUID,
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        snapshotEvidence: CodexGhostRepairSnapshotAnalysisReadback
    ) async throws -> CodexGhostRepairSnapshotDryRunProtectionAudit
}

/// M2e composes only already-bounded read-only components. The first accepted
/// composition is injected and deterministic: it has no production protection
/// transport, App call site, Preview persistence, or repair authority.
actor CodexGhostRepairSnapshotDryRunAnalysisCandidateCoordinator:
    CodexGhostRepairSnapshotDryRunAnalysisCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairSnapshotDryRunAnalysisCapabilities
            .deterministicReadOnlyCandidate

    private static let unavailableMessage =
        "Snapshot dry-run analysis is unavailable; no Preview persistence, confirmation, or repair authority was created."

    private let identityCoordinator:
        any CodexGhostRepairSnapshotAnalysisIdentityCoordinator
    private let reader: any CodexGhostRepairSnapshotAnalysisReading
    private let protectionSource:
        any CodexGhostRepairSnapshotDryRunProtectionAuditSource

    init(
        identityCoordinator:
            any CodexGhostRepairSnapshotAnalysisIdentityCoordinator,
        reader: any CodexGhostRepairSnapshotAnalysisReading,
        protectionSource:
            any CodexGhostRepairSnapshotDryRunProtectionAuditSource
    ) {
        self.identityCoordinator = identityCoordinator
        self.reader = reader
        self.protectionSource = protectionSource
    }

    func analyze(
        request: CodexGhostRepairSnapshotDryRunAnalysisRequest
    ) async -> CodexGhostRepairSnapshotDryRunAnalysisOutcome {
        let identityOutcome = await identityCoordinator.resolve(
            request: .init(snapshotReference: request.snapshotReference)
        )
        guard case let .resolved(identity) = identityOutcome else {
            return unavailable(request.requestID)
        }

        let readOutcome = await reader.read(identity: identity)
        guard case let .read(snapshotEvidence) = readOutcome else {
            return unavailable(request.requestID)
        }

        let audit: CodexGhostRepairSnapshotDryRunProtectionAudit
        do {
            audit = try await protectionSource.audit(
                requestID: request.requestID,
                identity: identity,
                snapshotEvidence: snapshotEvidence
            )
        } catch {
            return unavailable(request.requestID)
        }
        guard audit.identity == identity else {
            return .blocked(
                requestID: request.requestID,
                blockers: [.init(code: .snapshotEvidenceDrift)]
            )
        }

        switch CodexGhostRepairSnapshotDryRunPlanner.plan(
            identity: identity,
            snapshotEvidence: snapshotEvidence,
            protectionEvidence: audit.protectionEvidence,
            experimentalAbsenceEvidence:
                audit.experimentalAbsenceEvidence,
            operationalAudit: audit.operationalAudit,
            previewID: request.previewID,
            generatedAtMilliseconds: request.generatedAtMilliseconds,
            lifetimeMilliseconds: request.lifetimeMilliseconds
        ) {
        case let .preview(preview):
            return .preview(requestID: request.requestID, preview: preview)
        case let .blocked(blockers):
            return .blocked(
                requestID: request.requestID,
                blockers: blockers
            )
        }
    }

    private func unavailable(
        _ requestID: UUID
    ) -> CodexGhostRepairSnapshotDryRunAnalysisOutcome {
        .unavailable(
            requestID: requestID,
            message: Self.unavailableMessage
        )
    }
}

private struct CodexGhostRepairUnavailableSnapshotDryRunAnalysisCoordinator:
    CodexGhostRepairSnapshotDryRunAnalysisCoordinating
{
    let capabilities =
        CodexGhostRepairSnapshotDryRunAnalysisCapabilities.unavailable

    func analyze(
        request: CodexGhostRepairSnapshotDryRunAnalysisRequest
    ) async -> CodexGhostRepairSnapshotDryRunAnalysisOutcome {
        .unavailable(
            requestID: request.requestID,
            message:
                "Snapshot dry-run analysis is unavailable; no Preview persistence, confirmation, or repair authority was created."
        )
    }
}

public enum CodexGhostRepairSnapshotDryRunAnalysisCoordinatorFactory {
    public static func packagedDefaultUnavailable()
        -> any CodexGhostRepairSnapshotDryRunAnalysisCoordinating
    {
        CodexGhostRepairUnavailableSnapshotDryRunAnalysisCoordinator()
    }
}
