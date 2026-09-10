import Foundation

struct CodexGhostRepairSnapshotOperationalGateSourceCapabilities:
    Equatable,
    Sendable
{
    let readsProcessList = true
    let readsOpenHandleMetadata = true
    let readsRequiredDatabaseMetadata = true
    let probesFixedManagerDestinationVolume = true
    let acceptsCallerPath = false
    let opensSQLite = false
    let writesCodexDatabaseFiles = false
    let writesManagerFilesystem = false
    let snapshotAcquisitionAuthority = false
    let repairMutationAuthority = false
}

/// Shipping-compiled M1b-9 bridge from the fixed production roots to the
/// existing read-only macOS operational gate. Construction only stores two
/// closures. Each explicit gate call freshly resolves the canonical Codex home
/// and the manager's fixed Snapshots volume before collecting process, handle,
/// database-metadata, and capacity evidence.
///
/// This source is not acquisition authority. The packaged coordinator remains
/// default-blocked and returns before invoking its publisher.
actor CodexGhostRepairSnapshotOperationalGateSource:
    CodexGhostRepairExecutionGateSource
{
    typealias ConfigurationResolver =
        @Sendable () throws -> CodexGhostRepairOperationalGateConfiguration
    typealias GateFactory =
        @Sendable (CodexGhostRepairOperationalGateConfiguration)
            -> any CodexGhostRepairExecutionGateSource

    nonisolated let capabilities =
        CodexGhostRepairSnapshotOperationalGateSourceCapabilities()

    private let configurationResolver: ConfigurationResolver
    private let gateFactory: GateFactory

    /// No-path, zero-I/O production construction. FileManager resolution and
    /// all read-only inspection are deferred until an explicit gate call.
    static func production() -> Self {
        Self(
            configurationResolver: {
                let codexHome = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex", isDirectory: true)
                guard let applicationSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    throw StateStoreLocationError.applicationSupportUnavailable
                }
                let entries = CodexGhostRepairDestinationCanaryFixedLayout.entries(
                    applicationSupport: applicationSupport
                )
                guard let snapshots = entries.first(where: {
                    $0.directory == .snapshots
                })?.url else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Fixed manager snapshot destination is unavailable."
                    )
                }
                return CodexGhostRepairOperationalGateConfiguration(
                    codexHomeURL: codexHome,
                    backupVolumeProbeURL: snapshots,
                    fixedCapacityHeadroomBytes:
                        CodexGhostRepairSnapshotPreparedDestination
                            .fixedCapacityHeadroomBytes
                )
            },
            gateFactory: {
                CodexGhostRepairMacOSOperationalGateSource(configuration: $0)
            }
        )
    }

    /// Deterministic zero-I/O composition seam. Tests inject only closures and
    /// never resolve or inspect the live production roots.
    init(
        configurationResolver: @escaping ConfigurationResolver,
        gateFactory: @escaping GateFactory
    ) {
        self.configurationResolver = configurationResolver
        self.gateFactory = gateFactory
    }

    func ghostRepairExecutionGate() async throws
        -> CodexGhostRepairExecutionGate
    {
        let configuration = try configurationResolver()
        let source = gateFactory(configuration)
        return try await source.ghostRepairExecutionGate()
    }
}
