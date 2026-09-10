import Foundation

/// Shipping-internal request/profile binding. Runtime evidence selects one
/// exact packaged source candidate; it does not by itself admit the copied
/// SQLite schema.
struct CodexGhostRepairSnapshotRequestBoundProfileSelection:
    Equatable,
    Sendable
{
    let request: CodexGhostRepairSnapshotActionRequest
    let sourceProfile: CodexGhostRepairSnapshotSourceProfile

    var sourceProfileIdentifier: String { sourceProfile.identifier }
    var expectedSchemaProfileIdentifier: String {
        sourceProfile.databaseSchemaProfileIdentifier
    }
    var runtimeAloneAdmitsSchema: Bool { false }
    var liveSourceReadAuthority: Bool { false }
    var snapshotAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }

    init(request: CodexGhostRepairSnapshotActionRequest) throws {
        guard let selected = Self.selectProfile(
            exactRuntimeVersion: request.runtimeVersion
        ) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot request runtime is outside the exact packaged profile selection."
            )
        }
        if let evidence = request.initialWitnessEvidence {
            guard evidence.threadIDs == request.targetThreadIDs,
                  evidence.runtimeVersion == request.runtimeVersion,
                  evidence.sourceLayoutIdentifier == selected.identifier else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Initial witness provenance drifted from the exact packaged Snapshot profile."
                )
            }
        }
        self.request = request
        sourceProfile = selected
    }

    static func selectProfile(
        exactRuntimeVersion runtimeVersion: String
    ) -> CodexGhostRepairSnapshotSourceProfile? {
        switch runtimeVersion.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) {
        case "0.149.0", "codex-cli 0.149.0":
            .v149DesktopV32
        case "0.151.0-alpha.7.2", "0.151.0":
            .v151DesktopV33
        case "0.152.1", "codex-cli 0.152.1":
            .v152DesktopV34
        case "0.153.1", "codex-cli 0.153.1",
             "0.153.2", "codex-cli 0.153.2":
            .v153DesktopV34
        case "0.153.4", "codex-cli 0.153.4":
            .v1534DesktopV34
        default:
            nil
        }
    }
}

/// Per-request publisher. It cannot select a raw profile string or path, and
/// every call must supply the exact request frozen above. Production
/// construction remains outside this type so deterministic acceptance can use
/// only marker-protected mirrors.
struct CodexGhostRepairSnapshotRequestBoundPublisher: Sendable {
    let selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    let publisher: CodexGhostRepairSnapshotQuarantinePublisher
    let workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory

    var retriesAcquisition: Bool { false }
    var acceptsCallerPath: Bool { false }
    var repairMutationAuthority: Bool { false }

    func inspectAdmission(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        await publisher.inspectAdmissionProfileBound(
            selection: selection,
            currentRequest: request
        )
    }

    func acquire(
        snapshotID: UUID,
        request: CodexGhostRepairSnapshotActionRequest,
        afterCopyForTesting: (@Sendable () throws -> Void)? = nil
    ) async throws -> CodexGhostRepairSnapshotPublishedAcquisition {
        guard request == selection.request else {
            throw CodexGhostRepairError.targetDrift(
                "Snapshot request drifted after exact profile selection."
            )
        }
        return try await publisher.acquireProfileBound(
            snapshotID: snapshotID,
            selection: selection,
            currentRequest: request,
            workspaceFactory: workspaceFactory,
            afterCopyForTesting: afterCopyForTesting
        )
    }
}
