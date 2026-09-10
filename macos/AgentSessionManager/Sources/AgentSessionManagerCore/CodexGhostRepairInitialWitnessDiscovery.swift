import Foundation

/// A narrow, read-only bootstrap capability for installations that have no
/// manager-owned Deleted tombstone yet. Discovery identifies possible
/// Snapshot witnesses only; it does not prove that any identity is a ghost.
public struct CodexGhostRepairInitialWitnessDiscoveryCapabilities:
    Equatable,
    Sendable
{
    public let discoveryAvailable: Bool
    public let readsFixedRawDatabaseFiles: Bool
    public let officialInventoryAvailable: Bool

    public var acceptsCallerPath: Bool { false }
    public var acceptsCallerThreadIDs: Bool { false }
    public var writesCodexDatabaseFiles: Bool { false }
    public var writesManagerFilesystem: Bool { false }
    public var usesTemporaryWorkspace: Bool { discoveryAvailable }
    public var writesTemporaryWorkspace: Bool { discoveryAvailable }
    public var publishesSnapshot: Bool { false }
    public var persistsPreview: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let unavailable = Self(
        discoveryAvailable: false,
        readsFixedRawDatabaseFiles: false,
        officialInventoryAvailable: false
    )
    public static let packagedReadOnly = Self(
        discoveryAvailable: true,
        readsFixedRawDatabaseFiles: true,
        officialInventoryAvailable: true
    )

    public init(
        discoveryAvailable: Bool,
        readsFixedRawDatabaseFiles: Bool,
        officialInventoryAvailable: Bool
    ) {
        self.discoveryAvailable = discoveryAvailable
        self.readsFixedRawDatabaseFiles = readsFixedRawDatabaseFiles
        self.officialInventoryAvailable = officialInventoryAvailable
    }
}

/// Path-free provenance for one bounded witness suggestion. The App must still
/// run the existing fresh Safety Review for these exact identities before a
/// Snapshot request can exist.
public struct CodexGhostRepairInitialWitnessEvidence: Equatable, Sendable {
    public let threadIDs: [String]
    public let runtimeVersion: String
    public let sourceLayoutIdentifier: String
    public let sourceFingerprintHash: String

    public var confirmedGhostEvidence: Bool { false }
    public var snapshotAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public init(
        threadIDs: [String],
        runtimeVersion: String,
        sourceLayoutIdentifier: String,
        sourceFingerprintHash: String
    ) {
        self.threadIDs = threadIDs
        self.runtimeVersion = runtimeVersion
        self.sourceLayoutIdentifier = sourceLayoutIdentifier
        self.sourceFingerprintHash = sourceFingerprintHash
    }
}

public enum CodexGhostRepairInitialWitnessDiscoveryOutcome:
    Equatable,
    Sendable
{
    case discovered(CodexGhostRepairInitialWitnessEvidence)
    case empty(
        runtimeVersion: String,
        sourceLayoutIdentifier: String,
        sourceFingerprintHash: String
    )
    case unavailable(message: String)

    public var publishesSnapshot: Bool { false }
    public var persistsPreview: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public protocol CodexGhostRepairInitialWitnessDiscovering: Sendable {
    var capabilities: CodexGhostRepairInitialWitnessDiscoveryCapabilities {
        get
    }

    func discover() async -> CodexGhostRepairInitialWitnessDiscoveryOutcome
}

public struct CodexGhostRepairInitialWitnessUnavailableDiscovery:
    CodexGhostRepairInitialWitnessDiscovering
{
    public init() {}

    public let capabilities =
        CodexGhostRepairInitialWitnessDiscoveryCapabilities.unavailable

    public func discover() async
        -> CodexGhostRepairInitialWitnessDiscoveryOutcome
    {
        .unavailable(
            message: "Initial Snapshot witness discovery is unavailable in this build."
        )
    }
}

protocol CodexGhostRepairInitialWitnessCatalogReading: Sendable {
    func read(
        profile: CodexGhostRepairSnapshotSourceProfile
    ) throws -> CodexGhostRepairInitialWitnessCatalogReadback
}

struct CodexGhostRepairInitialWitnessCanonicalCatalogReader:
    CodexGhostRepairInitialWitnessCatalogReading,
    Sendable
{
    private let workspaceFactory:
        CodexGhostRepairSnapshotAnalysisWorkspaceFactory

    static func production() -> Self {
        Self(workspaceFactory: .production())
    }

    init(workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory) {
        self.workspaceFactory = workspaceFactory
    }

    func read(
        profile: CodexGhostRepairSnapshotSourceProfile
    ) throws -> CodexGhostRepairInitialWitnessCatalogReadback {
        try CodexGhostRepairInitialWitnessCanonicalQueryOnlyReader.read(
            source: .production(profile: profile),
            workspaceFactory: workspaceFactory
        )
    }
}

actor CodexGhostRepairInitialWitnessDiscoveryCoordinator:
    CodexGhostRepairInitialWitnessDiscovering
{
    nonisolated let capabilities =
        CodexGhostRepairInitialWitnessDiscoveryCapabilities.packagedReadOnly

    private static let maximumWitnessCount = 10

    private let catalogReader: any CodexGhostRepairInitialWitnessCatalogReading
    private let officialTransport:
        any CodexGhostRepairBulkOfficialObservationTransport
    private var discoveryInFlight = false

    init(
        catalogReader: any CodexGhostRepairInitialWitnessCatalogReading,
        officialTransport: any CodexGhostRepairBulkOfficialObservationTransport
    ) {
        self.catalogReader = catalogReader
        self.officialTransport = officialTransport
    }

    func discover() async -> CodexGhostRepairInitialWitnessDiscoveryOutcome {
        guard !discoveryInFlight else {
            return .unavailable(
                message: "Initial Snapshot witness discovery is already running."
            )
        }
        discoveryInFlight = true
        defer { discoveryInFlight = false }

        let official: CodexGhostRepairExperimentalTransportInventory
        do {
            official = try await officialTransport.inventory()
        } catch {
            return unavailable()
        }

        let validated: ValidatedOfficialProtection
        let profile: CodexGhostRepairSnapshotSourceProfile
        do {
            validated = try Self.validateOfficialProtection(official)
            guard let selected =
                CodexGhostRepairSnapshotRequestBoundProfileSelection
                    .selectProfile(
                        exactRuntimeVersion: official.runtimeVersion
                    )
            else {
                return unavailable()
            }
            profile = selected
        } catch {
            return unavailable()
        }

        let catalog: CodexGhostRepairInitialWitnessCatalogReadback
        do {
            catalog = try catalogReader.read(profile: profile)
        } catch {
            return unavailable()
        }
        guard catalog.sourceLayoutIdentifier == profile.identifier,
              profile.supports(runtimeVersion: official.runtimeVersion),
              profile.admits(databases: catalog.databases),
              Self.isCanonicalFingerprint(catalog.sourceFingerprintHash),
              Self.isCanonicalCatalog(catalog.threadIDs) else {
            return unavailable()
        }

        let witnesses = catalog.threadIDs.lazy.filter { threadID in
            !validated.officialThreadIDs.contains(threadID)
                && !validated.pinnedThreadIDs.contains(threadID)
                && !validated.threadIDsWithDescendants.contains(threadID)
        }.prefix(Self.maximumWitnessCount)
        let threadIDs = Array(witnesses)
        guard !threadIDs.isEmpty else {
            return .empty(
                runtimeVersion: official.runtimeVersion,
                sourceLayoutIdentifier: catalog.sourceLayoutIdentifier,
                sourceFingerprintHash: catalog.sourceFingerprintHash
            )
        }
        return .discovered(CodexGhostRepairInitialWitnessEvidence(
            threadIDs: threadIDs,
            runtimeVersion: official.runtimeVersion,
            sourceLayoutIdentifier: catalog.sourceLayoutIdentifier,
            sourceFingerprintHash: catalog.sourceFingerprintHash
        ))
    }

    private struct ValidatedOfficialProtection {
        let officialThreadIDs: Set<String>
        let pinnedThreadIDs: Set<String>
        let threadIDsWithDescendants: Set<String>
    }

    private static func validateOfficialProtection(
        _ value: CodexGhostRepairExperimentalTransportInventory
    ) throws -> ValidatedOfficialProtection {
        guard value.provider == .codex,
              value.inventoryComplete,
              value.pinnedInventoryComplete,
              value.descendantGraphComplete,
              CodexGhostRepairPackagedReadOnlyProfileCatalog
                .supportsObservationRuntime(value.runtimeVersion) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Initial witness discovery requires complete current official protection evidence."
            )
        }
        let active = try canonicalSet(value.activeThreadIDs)
        let archived = try canonicalSet(value.archivedThreadIDs)
        guard active.isDisjoint(with: archived),
              value.pinnedThreadIDs.count <= 10_000,
              value.pinnedThreadIDs.allSatisfy(isCanonicalUUID) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Initial witness official identity evidence is invalid."
            )
        }
        let graph = try validateDescendantGraph(value.descendantNodes)
        let allSourceThreadIDs = graph.allSourceThreadIDs
        guard active.union(archived).isSubset(of: allSourceThreadIDs) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Initial witness all-source inventory omitted an interactive session."
            )
        }
        return ValidatedOfficialProtection(
            // `active` and `archived` are the interactive product inventory,
            // while descendant nodes are the complete all-source inventory.
            // Both scopes are official presence and must be excluded.
            officialThreadIDs: active.union(archived).union(allSourceThreadIDs),
            pinnedThreadIDs: value.pinnedThreadIDs,
            threadIDsWithDescendants: graph.threadIDsWithDescendants
        )
    }

    private static func canonicalSet(_ values: [String]) throws -> Set<String> {
        guard values.count <= 10_000,
              Set(values).count == values.count,
              values.allSatisfy(isCanonicalUUID) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Initial witness official inventory IDs are invalid."
            )
        }
        return Set(values)
    }

    private static func validateDescendantGraph(
        _ nodes: [CodexGhostRepairExperimentalDescendantNode]
    ) throws -> (
        allSourceThreadIDs: Set<String>,
        threadIDsWithDescendants: Set<String>
    ) {
        guard nodes.count <= 10_000 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Initial witness descendant graph exceeded its bound."
            )
        }
        var seen: Set<String> = []
        var parentByChild: [String: String] = [:]
        var parents: Set<String> = []
        for node in nodes {
            guard isCanonicalUUID(node.threadID),
                  seen.insert(node.threadID).inserted else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Initial witness descendant identity is invalid."
                )
            }
            if let parent = node.parentThreadID {
                guard isCanonicalUUID(parent), parent != node.threadID else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Initial witness descendant parent is invalid."
                    )
                }
                parentByChild[node.threadID] = parent
                parents.insert(parent)
            }
        }

        // Each node has at most one parent. Following that chain once per
        // starting node is bounded by the graph size and detects cycles
        // without computing an O(n^2) descendant count for every ancestor.
        var completelyChecked: Set<String> = []
        for start in seen where !completelyChecked.contains(start) {
            var path: [String] = []
            var pathSet: Set<String> = []
            var current: String? = start
            while let node = current,
                  seen.contains(node),
                  !completelyChecked.contains(node) {
                guard pathSet.insert(node).inserted else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Initial witness descendant graph contains a cycle."
                    )
                }
                path.append(node)
                current = parentByChild[node]
            }
            completelyChecked.formUnion(path)
        }
        return (seen, parents)
    }

    private static func isCanonicalCatalog(_ values: [String]) -> Bool {
        values.count <= CodexGhostRepairBulkInventory.maximumObservedCatalogItems
            && values == values.sorted()
            && Set(values).count == values.count
            && values.allSatisfy(isCanonicalUUID)
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isCanonicalFingerprint(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        }
    }

    private func unavailable()
        -> CodexGhostRepairInitialWitnessDiscoveryOutcome
    {
        .unavailable(
            message: "Initial Snapshot witness discovery could not obtain complete, current, profile-matched read-only evidence."
        )
    }
}

public enum CodexGhostRepairInitialWitnessDiscoveryFactory {
    /// Zero-I/O construction. Observation begins only after one explicit
    /// `discover()` call and cannot publish a Snapshot or mutate either store.
    public static func packagedExplicitReadOnly()
        -> any CodexGhostRepairInitialWitnessDiscovering
    {
        CodexGhostRepairInitialWitnessDiscoveryCoordinator(
            catalogReader:
                CodexGhostRepairInitialWitnessCanonicalCatalogReader
                    .production(),
            officialTransport:
                CodexGhostRepairExperimentalAppServerObservationAdapter(
                    source: CodexAppServerClient.ghostRepairProduction(),
                    executionGateSource:
                        CodexGhostRepairUnavailableExecutionGateSource()
                )
        )
    }
}
