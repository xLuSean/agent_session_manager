import Darwin
import Foundation

struct CodexGhostRepairSnapshotPreparedDestinationCapabilities:
    Equatable,
    Sendable
{
    let bindsFixedPreparedLayout = true
    let readsDirectoryMetadata = true
    let probesDestinationCapacity = true
    let acceptsCallerPath = false
    let createsDirectories = false
    let copiesDatabaseFiles = false
    let publishesSnapshots = false
    let cleanupAuthority = false
    let repairMutationAuthority = false
}

struct CodexGhostRepairSnapshotPreparedDestinationBinding:
    Codable,
    Equatable,
    Sendable
{
    private struct Payload: Codable, Equatable {
        let storageRootDigest: String
        let policy: CodexGhostRepairDestinationCanaryPolicyEvidence
        let directories: [CodexGhostRepairDestinationCanaryDirectoryEvidence]
    }

    let storageRootDigest: String
    let policy: CodexGhostRepairDestinationCanaryPolicyEvidence
    let directories: [CodexGhostRepairDestinationCanaryDirectoryEvidence]
    let bindingHash: String

    var pathRedacted: Bool { true }
    var snapshotAcquisitionAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }

    init(
        storageRootDigest: String,
        evidence: CodexGhostRepairDestinationCanaryEvidence
    ) throws {
        guard evidence.isReady,
              evidence.directories.map(\.directory).sorted(by: {
                  $0.rawValue < $1.rawValue
              }) == CodexGhostRepairDestinationCanaryDirectory.allCases
                  .sorted(by: { $0.rawValue < $1.rawValue }) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Prepared snapshot destination requires six ready directories."
            )
        }
        let payload = Payload(
            storageRootDigest: storageRootDigest,
            policy: evidence.policy,
            directories: evidence.directories
        )
        self.storageRootDigest = storageRootDigest
        policy = evidence.policy
        directories = evidence.directories
        bindingHash = try CodexGhostRepairHasher.hash(payload)
    }

    func validateHash() throws {
        let expected = try CodexGhostRepairHasher.hash(
            Payload(
                storageRootDigest: storageRootDigest,
                policy: policy,
                directories: directories
            )
        )
        guard expected == bindingHash else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Prepared snapshot destination binding checksum mismatch."
            )
        }
    }
}

struct CodexGhostRepairSnapshotDestinationCapacityEvidence:
    Codable,
    Equatable,
    Sendable
{
    let bindingHash: String
    let sourceBytes: UInt64
    let reservedCopyCount: UInt64
    let fixedHeadroomBytes: UInt64
    let requiredBytes: UInt64
    let availableBytes: UInt64
    let destinationVolumeDigest: String

    var isSufficient: Bool { availableBytes >= requiredBytes }
    var automaticDeletionAuthority: Bool { false }
    var snapshotAcquisitionAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }
}

protocol CodexGhostRepairSnapshotDestinationCapacityProbing: Sendable {
    func availableCapacity(at url: URL) async throws -> UInt64
}

struct DarwinGhostRepairSnapshotDestinationCapacityProbe:
    CodexGhostRepairSnapshotDestinationCapacityProbing,
    Sendable
{
    func availableCapacity(at url: URL) async throws -> UInt64 {
        var status = statfs()
        guard statfs(url.path, &status) == 0,
              status.f_bavail >= 0,
              status.f_bsize >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Prepared snapshot destination capacity is unavailable."
            )
        }
        let (available, overflow) = UInt64(status.f_bavail)
            .multipliedReportingOverflow(by: UInt64(status.f_bsize))
        guard !overflow else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Prepared snapshot destination capacity overflowed."
            )
        }
        return available
    }
}

/// Binds exact ready storage evidence for the acquisition journal and acquirer.
/// This value never prepares, copies, publishes, cleans,
/// or repairs. URLs remain Core-internal and are available only after a fresh,
/// complete binding readback.
struct CodexGhostRepairSnapshotPreparedDestination: Sendable {
    static let reservedCopyCount: UInt64 = 2
    static let fixedCapacityHeadroomBytes: UInt64 = 64 * 1_024 * 1_024

    typealias RootResolver = @Sendable () throws -> URL

    struct Location: Sendable {
        let applicationSupportURL: URL
        let bundleRootURL: URL
        let storageRootURL: URL
        let snapshotsRootURL: URL
        let quarantineRootURL: URL
        let journalRootURL: URL
        let trashRootURL: URL
    }

    let capabilities =
        CodexGhostRepairSnapshotPreparedDestinationCapabilities()

    private let inspector:
        CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
    private let rootResolver: RootResolver
    private let capacityProbe:
        any CodexGhostRepairSnapshotDestinationCapacityProbing

    /// Path-free, zero-I/O production construction.
    static func production() -> Self {
        Self(
            inspector: .production(),
            rootResolver: {
                guard let root = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    throw StateStoreLocationError.applicationSupportUnavailable
                }
                return root
            },
            capacityProbe: DarwinGhostRepairSnapshotDestinationCapacityProbe()
        )
    }

    /// Test-owned acceptance seam. It reuses the E49 marker-protected inspector
    /// and cannot authorize the live Application Support directory.
    init(
        testOwnedApplicationSupportDirectory: URL,
        testOwnedAllowedParentURL: URL,
        capacityProbe:
            any CodexGhostRepairSnapshotDestinationCapacityProbing
    ) {
        inspector = CodexGhostRepairDestinationCanaryInspectOnlyCoordinator(
            testOwnedApplicationSupportDirectory:
                testOwnedApplicationSupportDirectory,
            testOwnedAllowedParentURL: testOwnedAllowedParentURL
        )
        rootResolver = { testOwnedApplicationSupportDirectory }
        self.capacityProbe = capacityProbe
    }

    private init(
        inspector: CodexGhostRepairDestinationCanaryInspectOnlyCoordinator,
        rootResolver: @escaping RootResolver,
        capacityProbe:
            any CodexGhostRepairSnapshotDestinationCapacityProbing
    ) {
        self.inspector = inspector
        self.rootResolver = rootResolver
        self.capacityProbe = capacityProbe
    }

    func bindPrepared() async throws
        -> CodexGhostRepairSnapshotPreparedDestinationBinding
    {
        let snapshot = try await freshSnapshot()
        return try CodexGhostRepairSnapshotPreparedDestinationBinding(
            storageRootDigest: snapshot.storageRootDigest,
            evidence: snapshot.evidence
        )
    }

    func validateFresh(
        _ binding: CodexGhostRepairSnapshotPreparedDestinationBinding
    ) async throws {
        try binding.validateHash()
        let fresh = try await bindPrepared()
        guard fresh == binding else {
            throw CodexGhostRepairError.targetDrift(
                "Prepared snapshot destination drifted from its frozen binding."
            )
        }
    }

    func capacityEvidence(
        for binding: CodexGhostRepairSnapshotPreparedDestinationBinding,
        sourceBytes: UInt64
    ) async throws -> CodexGhostRepairSnapshotDestinationCapacityEvidence {
        try await validateFresh(binding)
        let (reservedBytes, reserveOverflow) = sourceBytes
            .multipliedReportingOverflow(by: Self.reservedCopyCount)
        let (requiredBytes, headroomOverflow) = reservedBytes
            .addingReportingOverflow(Self.fixedCapacityHeadroomBytes)
        guard !reserveOverflow, !headroomOverflow else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Prepared snapshot capacity requirement overflowed."
            )
        }
        let snapshot = try await freshSnapshot()
        let available = try await capacityProbe.availableCapacity(
            at: snapshot.location.snapshotsRootURL
        )
        try await validateFresh(binding)
        return CodexGhostRepairSnapshotDestinationCapacityEvidence(
            bindingHash: binding.bindingHash,
            sourceBytes: sourceBytes,
            reservedCopyCount: Self.reservedCopyCount,
            fixedHeadroomBytes: Self.fixedCapacityHeadroomBytes,
            requiredBytes: requiredBytes,
            availableBytes: available,
            destinationVolumeDigest: try CodexGhostRepairHasher.hash(
                snapshot.location.snapshotsRootURL.path
            )
        )
    }

    func location(
        for binding: CodexGhostRepairSnapshotPreparedDestinationBinding
    ) async throws -> Location {
        try binding.validateHash()
        let snapshot = try await freshSnapshot()
        let freshBinding = try CodexGhostRepairSnapshotPreparedDestinationBinding(
            storageRootDigest: snapshot.storageRootDigest,
            evidence: snapshot.evidence
        )
        guard freshBinding == binding else {
            throw CodexGhostRepairError.targetDrift(
                "Prepared snapshot destination drifted before URL handoff."
            )
        }
        return snapshot.location
    }

    private func freshSnapshot() async throws -> (
        evidence: CodexGhostRepairDestinationCanaryEvidence,
        location: Location,
        storageRootDigest: String
    ) {
        let before = try rootResolver().standardizedFileURL
        let outcome = await inspector.inspect(requestID: UUID())
        let after = try rootResolver().standardizedFileURL
        guard before == after else {
            throw CodexGhostRepairError.targetDrift(
                "Prepared snapshot destination root resolver drifted."
            )
        }
        guard case let .ready(evidence) = outcome,
              evidence.isReady else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Prepared snapshot destination is not fully ready."
            )
        }
        let location = try Self.location(applicationSupport: after)
        return (
            evidence: evidence,
            location: location,
            storageRootDigest: try CodexGhostRepairHasher.hash(
                location.storageRootURL.path
            )
        )
    }

    private static func location(applicationSupport: URL) throws -> Location {
        let entries = CodexGhostRepairDestinationCanaryFixedLayout.entries(
            applicationSupport: applicationSupport
        )
        let byDirectory = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.directory, $0.url) }
        )
        guard let bundle = byDirectory[.applicationBundleRoot],
              let storage = byDirectory[.ghostRepairRoot],
              let snapshots = byDirectory[.snapshots],
              let quarantine = byDirectory[.quarantine],
              let journal = byDirectory[.journal],
              let trash = byDirectory[.trash] else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Prepared snapshot fixed destination layout is incomplete."
            )
        }
        return Location(
            applicationSupportURL: applicationSupport,
            bundleRootURL: bundle,
            storageRootURL: storage,
            snapshotsRootURL: snapshots,
            quarantineRootURL: quarantine,
            journalRootURL: journal,
            trashRootURL: trash
        )
    }
}
