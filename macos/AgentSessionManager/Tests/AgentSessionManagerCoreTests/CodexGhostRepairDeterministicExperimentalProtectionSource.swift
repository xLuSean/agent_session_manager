@testable import AgentSessionManagerCore
import Foundation

/// Supplies fixed observations to collector tests without a live App Server.
struct CodexGhostRepairDeterministicExperimentalProtectionSource:
    CodexGhostRepairSnapshotDryRunProtectionAuditSource,
    Sendable
{
    let registry: CodexGhostRepairExperimentalAbsenceRegistry
    let observation: CodexGhostRepairExperimentalProtectionObservation

    func audit(
        requestID: UUID,
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        snapshotEvidence: CodexGhostRepairSnapshotAnalysisReadback
    ) async throws -> CodexGhostRepairSnapshotDryRunProtectionAudit {
        try CodexGhostRepairExperimentalProtectionCollector.collect(
            identity: identity,
            snapshotEvidence: snapshotEvidence,
            registry: registry,
            observation: observation
        )
    }
}
