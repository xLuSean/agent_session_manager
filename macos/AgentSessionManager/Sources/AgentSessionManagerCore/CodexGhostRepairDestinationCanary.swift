import Foundation

public enum CodexGhostRepairDestinationCanaryDirectory:
    String,
    CaseIterable,
    Codable,
    Sendable
{
    case applicationBundleRoot
    case ghostRepairRoot
    case snapshots
    case quarantine
    case journal
    case trash

    public var label: String {
        switch self {
        case .applicationBundleRoot: "Application bundle root"
        case .ghostRepairRoot: "GhostRepair"
        case .snapshots: "Snapshots"
        case .quarantine: "Quarantine"
        case .journal: "Journal"
        case .trash: "Trash"
        }
    }
}

public enum CodexGhostRepairDestinationCanaryEntryStatus:
    String,
    Codable,
    Sendable
{
    case ready
    case missing
    case collision
    case unsafe
}

public enum CodexGhostRepairDestinationCanaryPermissionRequirement:
    String,
    Codable,
    Sendable
{
    case ownerControlled
    case ownerPrivate0700
}

public enum CodexGhostRepairDestinationCanaryContractError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidPolicy
    case invalidDirectoryEvidence
    case invalidEvidenceSet
    case preparationUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            "Snapshot Storage Canary policy evidence is invalid."
        case .invalidDirectoryEvidence:
            "Snapshot Storage Canary directory evidence is invalid."
        case .invalidEvidenceSet:
            "Snapshot Storage Canary requires one path-redacted record for each fixed directory."
        case .preparationUnavailable:
            "Only an exact inspection with missing safe directories can authorize the prototype Prepare intent."
        }
    }
}

public struct CodexGhostRepairDestinationCanaryPolicyEvidence:
    Equatable,
    Codable,
    Sendable
{
    public let identifier: String
    public let version: Int
    public let maximumSnapshotCount: Int
    public let maximumTotalBytes: Int64
    public let maximumAgeMilliseconds: Int64
    public let policyDigest: String

    public init(
        identifier: String,
        version: Int,
        maximumSnapshotCount: Int,
        maximumTotalBytes: Int64,
        maximumAgeMilliseconds: Int64,
        policyDigest: String
    ) throws {
        guard !identifier.isEmpty,
              identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
              version > 0,
              maximumSnapshotCount > 0,
              maximumTotalBytes > 0,
              maximumAgeMilliseconds > 0,
              Self.isSHA256Digest(policyDigest) else {
            throw CodexGhostRepairDestinationCanaryContractError.invalidPolicy
        }
        self.identifier = identifier
        self.version = version
        self.maximumSnapshotCount = maximumSnapshotCount
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumAgeMilliseconds = maximumAgeMilliseconds
        self.policyDigest = policyDigest
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

public struct CodexGhostRepairDestinationCanaryDirectoryEvidence:
    Equatable,
    Codable,
    Sendable
{
    public let directory: CodexGhostRepairDestinationCanaryDirectory
    public let status: CodexGhostRepairDestinationCanaryEntryStatus
    public let permissionRequirement:
        CodexGhostRepairDestinationCanaryPermissionRequirement
    public let identityDigest: String?
    public let observedMode: Int?

    public init(
        directory: CodexGhostRepairDestinationCanaryDirectory,
        status: CodexGhostRepairDestinationCanaryEntryStatus,
        permissionRequirement:
            CodexGhostRepairDestinationCanaryPermissionRequirement,
        identityDigest: String? = nil,
        observedMode: Int? = nil
    ) throws {
        let expectedRequirement: CodexGhostRepairDestinationCanaryPermissionRequirement =
            directory == .applicationBundleRoot
                ? .ownerControlled
                : .ownerPrivate0700
        let digestIsValid = identityDigest.map(Self.isSHA256Digest) ?? true
        let modeIsValid = observedMode.map { (0...0o7777).contains($0) } ?? true
        guard permissionRequirement == expectedRequirement else {
            throw CodexGhostRepairDestinationCanaryContractError
                .invalidDirectoryEvidence
        }
        switch status {
        case .ready:
            guard identityDigest.map(Self.isSHA256Digest) == true,
                  observedMode.map({
                      Self.mode($0, satisfies: permissionRequirement)
                  }) == true else {
                throw CodexGhostRepairDestinationCanaryContractError
                    .invalidDirectoryEvidence
            }
        case .missing:
            guard identityDigest == nil, observedMode == nil else {
                throw CodexGhostRepairDestinationCanaryContractError
                    .invalidDirectoryEvidence
            }
        case .collision, .unsafe:
            guard digestIsValid, modeIsValid else {
                throw CodexGhostRepairDestinationCanaryContractError
                    .invalidDirectoryEvidence
            }
        }
        self.directory = directory
        self.status = status
        self.permissionRequirement = permissionRequirement
        self.identityDigest = identityDigest
        self.observedMode = observedMode
    }

    private static func mode(
        _ mode: Int,
        satisfies requirement: CodexGhostRepairDestinationCanaryPermissionRequirement
    ) -> Bool {
        switch requirement {
        case .ownerControlled:
            let ownerCanReadAndTraverse = mode & 0o500 == 0o500
            let groupOrOtherCanWrite = mode & 0o022 != 0
            return ownerCanReadAndTraverse && !groupOrOtherCanWrite
        case .ownerPrivate0700:
            return mode == 0o700
        }
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

public struct CodexGhostRepairDestinationCanaryEvidence:
    Equatable,
    Codable,
    Sendable
{
    public let policy: CodexGhostRepairDestinationCanaryPolicyEvidence
    public let directories: [CodexGhostRepairDestinationCanaryDirectoryEvidence]
    public let evidenceToken: String
    public let observedAt: Date

    public var pathRedacted: Bool { true }
    public var filesystemAuthority: Bool { false }
    public var snapshotAuthority: Bool { false }
    public var officialAbsenceAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public var missingDirectories: [CodexGhostRepairDestinationCanaryDirectory] {
        directories
            .filter { $0.status == .missing }
            .map(\.directory)
    }

    public var isReady: Bool {
        directories.allSatisfy { $0.status == .ready }
    }

    public var isPreparationEligible: Bool {
        !missingDirectories.isEmpty
            && directories.allSatisfy {
                $0.status == .ready || $0.status == .missing
            }
    }

    public init(
        policy: CodexGhostRepairDestinationCanaryPolicyEvidence,
        directories: [CodexGhostRepairDestinationCanaryDirectoryEvidence],
        evidenceToken: String,
        observedAt: Date
    ) throws {
        let expected = Set(CodexGhostRepairDestinationCanaryDirectory.allCases)
        let actual = Set(directories.map(\.directory))
        guard directories.count == expected.count,
              actual == expected,
              Self.isSHA256Digest(evidenceToken) else {
            throw CodexGhostRepairDestinationCanaryContractError.invalidEvidenceSet
        }
        self.policy = policy
        self.directories = directories.sorted {
            $0.directory.rawValue < $1.directory.rawValue
        }
        self.evidenceToken = evidenceToken
        self.observedAt = observedAt
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

public struct CodexGhostRepairDestinationCanaryPreparationRequest:
    Equatable,
    Sendable
{
    public let id: UUID
    public let evidenceToken: String
    public let policy: CodexGhostRepairDestinationCanaryPolicyEvidence
    public let missingDirectories: [CodexGhostRepairDestinationCanaryDirectory]

    public var filesystemAuthority: Bool { false }
    public var snapshotAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public init(
        id: UUID = UUID(),
        evidence: CodexGhostRepairDestinationCanaryEvidence
    ) throws {
        guard evidence.isPreparationEligible else {
            throw CodexGhostRepairDestinationCanaryContractError.preparationUnavailable
        }
        self.id = id
        evidenceToken = evidence.evidenceToken
        policy = evidence.policy
        missingDirectories = evidence.missingDirectories.sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

public enum CodexGhostRepairDestinationCanaryInspectionOutcome:
    Equatable,
    Sendable
{
    case unavailable(message: String)
    case needsPreparation(CodexGhostRepairDestinationCanaryEvidence)
    case ready(CodexGhostRepairDestinationCanaryEvidence)
    case blocked(
        evidence: CodexGhostRepairDestinationCanaryEvidence?,
        message: String
    )
    case failed(message: String)
}

public enum CodexGhostRepairDestinationCanaryPreparationOutcome:
    Equatable,
    Sendable
{
    case unavailable(message: String)
    case ready(CodexGhostRepairDestinationCanaryEvidence)
    case partial(
        evidence: CodexGhostRepairDestinationCanaryEvidence?,
        message: String
    )
    case blocked(
        evidence: CodexGhostRepairDestinationCanaryEvidence?,
        message: String
    )
    case failed(message: String)
}

/// Describes the concrete filesystem effect implemented by a Prepare-capable
/// coordinator. This is disclosure, not an authorization token.
public enum CodexGhostRepairDestinationCanaryPreparationEffect:
    String,
    Equatable,
    Sendable
{
    case unavailable
    case testOwnedPrototype
    case fixedManagerPrivateDirectories

    public var writesFilesystem: Bool {
        self != .unavailable
    }

    public var acceptsCallerPath: Bool { false }
    public var overwritesExistingEntry: Bool { false }
    public var changesExistingPermissions: Bool { false }
    public var deletesExistingEntry: Bool { false }
}

/// Operation-specific availability for the packaged destination canary.
/// These values describe which intents a coordinator implements; they do not
/// grant filesystem, snapshot, official-absence, or repair authority.
public struct CodexGhostRepairDestinationCanaryCapabilities:
    Equatable,
    Sendable
{
    public let inspectionAvailable: Bool
    public let preparationAvailable: Bool
    public let preparationEffect:
        CodexGhostRepairDestinationCanaryPreparationEffect

    public var filesystemAuthority: Bool { false }
    public var snapshotAuthority: Bool { false }
    public var officialAbsenceAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let unavailable = Self(
        inspectionAvailable: false,
        preparationAvailable: false,
        preparationEffect: .unavailable
    )
    public static let inspectOnly = Self(
        inspectionAvailable: true,
        preparationAvailable: false,
        preparationEffect: .unavailable
    )
    public static let inspectAndPrepare = Self(
        inspectionAvailable: true,
        preparationAvailable: true,
        preparationEffect: .testOwnedPrototype
    )
    public static let fixedManagerPrivateDirectoryPrepare = Self(
        inspectionAvailable: true,
        preparationAvailable: true,
        preparationEffect: .fixedManagerPrivateDirectories
    )

    private init(
        inspectionAvailable: Bool,
        preparationAvailable: Bool,
        preparationEffect: CodexGhostRepairDestinationCanaryPreparationEffect
    ) {
        self.inspectionAvailable = inspectionAvailable
        self.preparationAvailable = preparationAvailable
        self.preparationEffect = preparationEffect
    }
}

public protocol CodexGhostRepairDestinationCanaryCoordinator: Sendable {
    var capabilities: CodexGhostRepairDestinationCanaryCapabilities { get }

    func inspect(
        requestID: UUID
    ) async -> CodexGhostRepairDestinationCanaryInspectionOutcome

    func prepare(
        request: CodexGhostRepairDestinationCanaryPreparationRequest
    ) async -> CodexGhostRepairDestinationCanaryPreparationOutcome
}

/// E45 shipping default. It performs no filesystem I/O and cannot prepare a
/// destination. A future live adapter requires a separate adoption decision.
public struct CodexGhostRepairDestinationCanaryUnavailableCoordinator:
    CodexGhostRepairDestinationCanaryCoordinator
{
    public init() {}

    public var capabilities: CodexGhostRepairDestinationCanaryCapabilities {
        .unavailable
    }

    public func inspect(
        requestID _: UUID
    ) async -> CodexGhostRepairDestinationCanaryInspectionOutcome {
        .unavailable(
            message: "Packaged Snapshot Storage inspection is not available in this build."
        )
    }

    public func prepare(
        request _: CodexGhostRepairDestinationCanaryPreparationRequest
    ) async -> CodexGhostRepairDestinationCanaryPreparationOutcome {
        .unavailable(
            message: "Packaged Snapshot Storage preparation is not available in this build."
        )
    }
}

/// Public construction seams for the packaged destination canary. Construction
/// performs no I/O and accepts no caller-controlled path. Filesystem effects
/// remain possible only through the Prepare-capable coordinator after an
/// explicit Inspect, frozen request, and fresh exact evidence validation.
public enum CodexGhostRepairDestinationCanaryCoordinatorFactory {
    public static func packagedInspectOnly()
        -> any CodexGhostRepairDestinationCanaryCoordinator
    {
        CodexGhostRepairDestinationCanaryInspectOnlyCoordinator.production()
    }

    public static func packagedFixedDirectoryPrepare()
        -> any CodexGhostRepairDestinationCanaryCoordinator
    {
        CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator
            .production()
    }
}
