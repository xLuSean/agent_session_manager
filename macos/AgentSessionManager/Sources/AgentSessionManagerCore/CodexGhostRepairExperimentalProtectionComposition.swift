import Foundation

/// M2j binds one M2e analysis request to one explicit M2h observation and the
/// exact M2f admission registry used by M2g. It has no production factory,
/// App call site, persistence, confirmation, or repair authority.
struct CodexGhostRepairExperimentalProtectionCompositionSource:
    CodexGhostRepairSnapshotDryRunProtectionAuditSource,
    Sendable
{
    let observer: any CodexGhostRepairExperimentalObservationCoordinating
    let registry: CodexGhostRepairExperimentalAbsenceRegistry

    func audit(
        requestID: UUID,
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        snapshotEvidence: CodexGhostRepairSnapshotAnalysisReadback
    ) async throws -> CodexGhostRepairSnapshotDryRunProtectionAudit {
        let outcome = await observer.observe(request: .init(
            requestID: requestID,
            identity: identity
        ))
        guard case let .observed(result) = outcome,
              result.requestID == requestID,
              result.identity == identity else {
            throw invalidEvidence()
        }

        return try CodexGhostRepairExperimentalProtectionCollector.collect(
            identity: identity,
            snapshotEvidence: snapshotEvidence,
            registry: registry,
            observation: result.observation
        )
    }

    private func invalidEvidence() -> CodexGhostRepairError {
        .invalidProtectionEvidence(
            "Experimental protection observation identity is unavailable or drifted."
        )
    }
}
