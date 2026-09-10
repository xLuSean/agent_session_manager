import Foundation

/// Read-only packaged admission capability. This interface deliberately has
/// no Snapshot identity, publication, journal, copy, cleanup, or repair entry
/// point. A caller can only request path-redacted admission evidence for one
/// exact reviewed request.
public struct CodexGhostRepairSnapshotAdmissionInspectorCapabilities:
    Equatable,
    Sendable
{
    public let inspectionAvailable: Bool
    public let readsFixedRawDatabaseFiles: Bool

    public var acceptsCallerPath: Bool { false }
    public var usesSQLiteAPI: Bool { false }
    public var writesManagerFilesystem: Bool { false }
    public var snapshotAcquisitionAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let unavailable = Self(
        inspectionAvailable: false,
        readsFixedRawDatabaseFiles: false
    )
    public static let packagedFixedReadOnly = Self(
        inspectionAvailable: true,
        readsFixedRawDatabaseFiles: true
    )

    public init(
        inspectionAvailable: Bool,
        readsFixedRawDatabaseFiles: Bool
    ) {
        self.inspectionAvailable = inspectionAvailable
        self.readsFixedRawDatabaseFiles = readsFixedRawDatabaseFiles
    }
}

public protocol CodexGhostRepairSnapshotAdmissionInspecting: Sendable {
    var capabilities:
        CodexGhostRepairSnapshotAdmissionInspectorCapabilities { get }

    func inspect(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome
}

public struct CodexGhostRepairSnapshotAdmissionUnavailableInspector:
    CodexGhostRepairSnapshotAdmissionInspecting
{
    public init() {}

    public var capabilities:
        CodexGhostRepairSnapshotAdmissionInspectorCapabilities
    {
        .unavailable
    }

    public func inspect(
        request _: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        .unavailable(
            message: "Packaged Snapshot admission inspection is not available in this build."
        )
    }
}

protocol CodexGhostRepairSnapshotAdmissionInspectingBackend: Sendable {
    func inspect(
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome
}

private struct CodexGhostRepairSnapshotProductionAdmissionBackend:
    CodexGhostRepairSnapshotAdmissionInspectingBackend
{
    func inspect(
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        let publisher =
            CodexGhostRepairSnapshotQuarantinePublisher
                .productionOperationalGateCandidate(
                    profile: selection.sourceProfile
                )
        return await publisher.inspectAdmissionProfileBound(
            selection: selection,
            currentRequest: selection.request
        )
    }
}

actor CodexGhostRepairSnapshotPackagedAdmissionInspector:
    CodexGhostRepairSnapshotAdmissionInspecting
{
    nonisolated let capabilities:
        CodexGhostRepairSnapshotAdmissionInspectorCapabilities

    private let backend:
        any CodexGhostRepairSnapshotAdmissionInspectingBackend

    static func productionExplicitReadOnly() -> Self {
        Self(
            backend: CodexGhostRepairSnapshotProductionAdmissionBackend(),
            inspectionAvailable: true
        )
    }

    init(
        backend: any CodexGhostRepairSnapshotAdmissionInspectingBackend,
        inspectionAvailable: Bool
    ) {
        self.backend = backend
        capabilities = inspectionAvailable
            ? .packagedFixedReadOnly
            : .unavailable
    }

    func inspect(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        guard capabilities.inspectionAvailable else {
            return .unavailable(
                message: "Packaged Snapshot admission inspection is not available in this build."
            )
        }
        guard let selection = try? CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        ) else {
            return .unavailable(
                message: "This build has no exact audited Snapshot profile for the reviewed Codex runtime."
            )
        }
        return await backend.inspect(selection: selection)
    }
}

public enum CodexGhostRepairSnapshotAdmissionInspectorFactory {
    /// Construction performs no I/O. Only an explicit `inspect` call can read
    /// the fixed live evidence, and this returned interface cannot publish.
    public static func packagedExplicitReadOnly()
        -> any CodexGhostRepairSnapshotAdmissionInspecting
    {
        CodexGhostRepairSnapshotPackagedAdmissionInspector
            .productionExplicitReadOnly()
    }
}
