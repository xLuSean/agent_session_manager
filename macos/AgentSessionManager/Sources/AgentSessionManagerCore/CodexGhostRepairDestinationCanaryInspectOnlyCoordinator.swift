import Darwin
import Foundation

/// E49 shipping-safe destination inspection contract. The production factory
/// captures a fresh resolver but performs no I/O. This type can only read the
/// fixed manager layout; it has no directory creator, SQLite API, or Prepare
/// backend.
struct CodexGhostRepairDestinationCanaryInspectOnlyCoordinator:
    CodexGhostRepairDestinationCanaryCoordinator
{
    static let testRootMarkerFileName =
        ".agent-session-manager-e49-inspect-only-root-v1"
    static let testRootMarkerContents =
        "Agent Session Manager E49 test-owned inspect-only root v1\n"

    typealias RootResolver = @Sendable () throws -> URL
    typealias Clock = @Sendable () -> Date

    private let rootResolver: RootResolver
    private let testBoundary: TestBoundary?
    private let clock: Clock

    var capabilities: CodexGhostRepairDestinationCanaryCapabilities {
        .inspectOnly
    }

    /// Production construction is deliberately lazy and performs zero I/O.
    /// E49 has no caller; retaining this function reference is not permission
    /// to invoke it against the live Application Support directory.
    static func production(
        clock: @escaping Clock = { Date() }
    ) -> Self {
        Self(
            rootResolver: {
                guard let root = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    throw InspectionError.applicationSupportUnavailable
                }
                return root
            },
            testBoundary: nil,
            clock: clock
        )
    }

    /// E49 deterministic acceptance seam. Construction is also zero-I/O;
    /// marker, ancestry, identity, and permissions are checked only by an
    /// explicit Inspect call. The initializer remains Core-internal.
    init(
        testOwnedApplicationSupportDirectory: URL,
        testOwnedAllowedParentURL: URL,
        clock: @escaping Clock = { Date() }
    ) {
        rootResolver = { testOwnedApplicationSupportDirectory }
        testBoundary = TestBoundary(
            allowedParentURL: testOwnedAllowedParentURL,
            applicationSupportURL: testOwnedApplicationSupportDirectory
        )
        self.clock = clock
    }

    private init(
        rootResolver: @escaping RootResolver,
        testBoundary: TestBoundary?,
        clock: @escaping Clock
    ) {
        self.rootResolver = rootResolver
        self.testBoundary = testBoundary
        self.clock = clock
    }

    func inspect(
        requestID _: UUID
    ) async -> CodexGhostRepairDestinationCanaryInspectionOutcome {
        do {
            let applicationSupport = try rootResolver().standardizedFileURL
            if let testBoundary {
                try validateTestBoundary(
                    testBoundary,
                    resolvedApplicationSupport: applicationSupport
                )
            } else {
                try validateDirectory(
                    applicationSupport,
                    requirement: .ownerControlled
                )
            }

            var evidenceByDirectory: [
                CodexGhostRepairDestinationCanaryDirectory:
                    CodexGhostRepairDestinationCanaryDirectoryEvidence
            ] = [:]
            let directories = try CodexGhostRepairDestinationCanaryFixedLayout.entries(
                applicationSupport: applicationSupport
            ).map { entry in
                let evidence: CodexGhostRepairDestinationCanaryDirectoryEvidence
                if let parent = entry.parent,
                   let parentStatus = evidenceByDirectory[parent]?.status {
                    evidence = switch parentStatus {
                    case .ready:
                        try inspect(directory: entry.directory, url: entry.url)
                    case .missing:
                        try Self.missingDirectoryEvidence(entry.directory)
                    case .collision:
                        try Self.collisionDirectoryEvidence(entry.directory)
                    case .unsafe:
                        try Self.unsafeDirectoryEvidence(entry.directory)
                    }
                } else {
                    evidence = try inspect(
                        directory: entry.directory,
                        url: entry.url
                    )
                }
                evidenceByDirectory[entry.directory] = evidence
                return evidence
            }
            let evidence = try Self.makeEvidence(
                policy: .initial,
                directories: directories,
                observedAt: clock()
            )
            if directories.contains(where: {
                $0.status == .collision || $0.status == .unsafe
            }) {
                return .blocked(
                    evidence: evidence,
                    message: Self.blockedMessage(code: "unsafe-fixed-layout")
                )
            }
            return evidence.isReady
                ? .ready(evidence)
                : .needsPreparation(evidence)
        } catch {
            return .blocked(
                evidence: nil,
                message: Self.blockedMessage(code: Self.errorCode(error))
            )
        }
    }

    func prepare(
        request _: CodexGhostRepairDestinationCanaryPreparationRequest
    ) async -> CodexGhostRepairDestinationCanaryPreparationOutcome {
        .unavailable(
            message: "Snapshot Storage preparation is not included in the inspect-only build."
        )
    }

    private func validateTestBoundary(
        _ boundary: TestBoundary,
        resolvedApplicationSupport: URL
    ) throws {
        let allowedParent = boundary.allowedParentURL.standardizedFileURL
        let expectedApplicationSupport =
            boundary.applicationSupportURL.standardizedFileURL
        guard resolvedApplicationSupport == expectedApplicationSupport,
              resolvedApplicationSupport != allowedParent,
              Self.isDescendant(resolvedApplicationSupport, of: allowedParent)
        else {
            throw InspectionError.invalidTestBoundary
        }
        if let liveRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.standardizedFileURL {
            guard resolvedApplicationSupport != liveRoot,
                  !Self.isDescendant(resolvedApplicationSupport, of: liveRoot)
            else {
                throw InspectionError.liveRootRejected
            }
        }
        try validateDirectory(allowedParent, requirement: .ownerPrivate0700)
        try validateDirectory(
            resolvedApplicationSupport,
            requirement: .ownerPrivate0700
        )
        try validateTestMarker(in: allowedParent)
    }

    private func validateTestMarker(in allowedParent: URL) throws {
        let markerURL = allowedParent.appendingPathComponent(
            Self.testRootMarkerFileName,
            isDirectory: false
        )
        let descriptor = open(
            markerURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw InspectionError.invalidTestMarker
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o7777 == 0o600,
              status.st_size == Self.testRootMarkerContents.utf8.count
        else {
            throw InspectionError.invalidTestMarker
        }
        var buffer = [UInt8](
            repeating: 0,
            count: Self.testRootMarkerContents.utf8.count
        )
        let count = read(descriptor, &buffer, buffer.count)
        guard count == buffer.count,
              String(decoding: buffer, as: UTF8.self)
                == Self.testRootMarkerContents
        else {
            throw InspectionError.invalidTestMarker
        }
    }

    private func validateDirectory(
        _ url: URL,
        requirement: CodexGhostRepairDestinationCanaryPermissionRequirement
    ) throws {
        let identity = try readDirectoryIdentity(url)
        guard identity.ownerUID == UInt32(getuid()),
              Self.permissionSatisfied(
                mode: identity.mode,
                requirement: requirement
              ) else {
            throw InspectionError.unsafeDirectory
        }
    }

    private func inspect(
        directory: CodexGhostRepairDestinationCanaryDirectory,
        url: URL
    ) throws -> CodexGhostRepairDestinationCanaryDirectoryEvidence {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0 else {
            if errno == ENOENT {
                return try Self.missingDirectoryEvidence(directory)
            }
            throw InspectionError.metadataUnavailable
        }
        guard (pathStatus.st_mode & S_IFMT) == S_IFDIR else {
            return try Self.collisionDirectoryEvidence(directory)
        }
        let identity = try readDirectoryIdentity(url, lstatIdentity: pathStatus)
        let requirement = Self.permissionRequirement(for: directory)
        let permissionSatisfied =
            identity.ownerUID == UInt32(getuid())
            && Self.permissionSatisfied(
                mode: identity.mode,
                requirement: requirement
            )
        return try Self.existingDirectoryEvidence(
            directory,
            device: identity.device,
            inode: identity.inode,
            mode: identity.mode,
            ownerUID: identity.ownerUID,
            permissionSatisfied: permissionSatisfied
        )
    }

    private func readDirectoryIdentity(
        _ url: URL,
        lstatIdentity: stat? = nil
    ) throws -> DirectoryIdentity {
        var before = lstatIdentity ?? stat()
        if lstatIdentity == nil {
            guard lstat(url.path, &before) == 0 else {
                throw InspectionError.metadataUnavailable
            }
        }
        guard (before.st_mode & S_IFMT) == S_IFDIR else {
            throw InspectionError.unsafeDirectory
        }
        let descriptor = open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw InspectionError.metadataUnavailable
        }
        defer { close(descriptor) }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              (after.st_mode & S_IFMT) == S_IFDIR,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino else {
            throw InspectionError.identityDrift
        }
        return DirectoryIdentity(
            device: UInt64(after.st_dev),
            inode: UInt64(after.st_ino),
            mode: UInt32(after.st_mode & 0o7777),
            ownerUID: UInt32(after.st_uid)
        )
    }

    static func makePolicyEvidence(
        _ policy: CodexGhostRepairProductionPolicy
    ) throws -> CodexGhostRepairDestinationCanaryPolicyEvidence {
        guard let totalBytes = Int64(exactly: policy.maximumTotalBytes) else {
            throw InspectionError.invalidPolicy
        }
        let payload = PolicyDigestPayload(
            identifier: policy.identifier,
            version: policy.version,
            maximumSnapshotCount: policy.maximumSnapshotCount,
            maximumTotalBytes: totalBytes,
            maximumAgeMilliseconds: policy.maximumAgeMilliseconds
        )
        return try CodexGhostRepairDestinationCanaryPolicyEvidence(
            identifier: payload.identifier,
            version: payload.version,
            maximumSnapshotCount: payload.maximumSnapshotCount,
            maximumTotalBytes: payload.maximumTotalBytes,
            maximumAgeMilliseconds: payload.maximumAgeMilliseconds,
            policyDigest: CodexGhostRepairHasher.hash(payload)
        )
    }

    static func makeEvidence(
        policy: CodexGhostRepairProductionPolicy,
        directories: [CodexGhostRepairDestinationCanaryDirectoryEvidence],
        observedAt: Date
    ) throws -> CodexGhostRepairDestinationCanaryEvidence {
        let policyEvidence = try makePolicyEvidence(policy)
        let sorted = directories.sorted {
            $0.directory.rawValue < $1.directory.rawValue
        }
        let token = try CodexGhostRepairHasher.hash(EvidenceTokenPayload(
            contractIdentifier: "ghost-repair-destination-canary-e47-v1",
            policy: policyEvidence,
            directories: sorted
        ))
        return try CodexGhostRepairDestinationCanaryEvidence(
            policy: policyEvidence,
            directories: sorted,
            evidenceToken: token,
            observedAt: observedAt
        )
    }

    static func existingDirectoryEvidence(
        _ directory: CodexGhostRepairDestinationCanaryDirectory,
        device: UInt64,
        inode: UInt64,
        mode: UInt32,
        ownerUID: UInt32,
        permissionSatisfied: Bool
    ) throws -> CodexGhostRepairDestinationCanaryDirectoryEvidence {
        let requirement = permissionRequirement(for: directory)
        let digest = try CodexGhostRepairHasher.hash(DirectoryIdentityPayload(
            contractIdentifier: "ghost-repair-destination-canary-e47-directory-v1",
            directory: directory,
            permissionRequirement: requirement,
            device: device,
            inode: inode,
            mode: mode,
            ownerUID: ownerUID,
            permissionContractSatisfied: permissionSatisfied
        ))
        return try CodexGhostRepairDestinationCanaryDirectoryEvidence(
            directory: directory,
            status: permissionSatisfied ? .ready : .unsafe,
            permissionRequirement: requirement,
            identityDigest: digest,
            observedMode: Int(mode)
        )
    }

    static func missingDirectoryEvidence(
        _ directory: CodexGhostRepairDestinationCanaryDirectory
    ) throws -> CodexGhostRepairDestinationCanaryDirectoryEvidence {
        try CodexGhostRepairDestinationCanaryDirectoryEvidence(
            directory: directory,
            status: .missing,
            permissionRequirement: permissionRequirement(for: directory)
        )
    }

    static func collisionDirectoryEvidence(
        _ directory: CodexGhostRepairDestinationCanaryDirectory
    ) throws -> CodexGhostRepairDestinationCanaryDirectoryEvidence {
        try CodexGhostRepairDestinationCanaryDirectoryEvidence(
            directory: directory,
            status: .collision,
            permissionRequirement: permissionRequirement(for: directory)
        )
    }

    static func unsafeDirectoryEvidence(
        _ directory: CodexGhostRepairDestinationCanaryDirectory
    ) throws -> CodexGhostRepairDestinationCanaryDirectoryEvidence {
        try CodexGhostRepairDestinationCanaryDirectoryEvidence(
            directory: directory,
            status: .unsafe,
            permissionRequirement: permissionRequirement(for: directory)
        )
    }

    static func permissionRequirement(
        for directory: CodexGhostRepairDestinationCanaryDirectory
    ) -> CodexGhostRepairDestinationCanaryPermissionRequirement {
        directory == .applicationBundleRoot
            ? .ownerControlled
            : .ownerPrivate0700
    }

    private static func permissionSatisfied(
        mode: UInt32,
        requirement: CodexGhostRepairDestinationCanaryPermissionRequirement
    ) -> Bool {
        switch requirement {
        case .ownerControlled:
            return mode & 0o500 == 0o500 && mode & 0o022 == 0
        case .ownerPrivate0700:
            return mode == 0o700
        }
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && Array(childComponents.prefix(parentComponents.count))
                == parentComponents
    }

    private static func blockedMessage(code: String) -> String {
        "Snapshot Storage inspection stopped (\(code)). Clear filesystem paths are unavailable."
    }

    private static func errorCode(_ error: Error) -> String {
        guard let error = error as? InspectionError else {
            return "unexpected-readback-error"
        }
        return error.rawValue
    }
}

private extension CodexGhostRepairDestinationCanaryInspectOnlyCoordinator {
    struct TestBoundary: Sendable {
        let allowedParentURL: URL
        let applicationSupportURL: URL
    }

    struct DirectoryIdentity: Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let ownerUID: UInt32
    }

    struct PolicyDigestPayload: Encodable {
        let identifier: String
        let version: Int
        let maximumSnapshotCount: Int
        let maximumTotalBytes: Int64
        let maximumAgeMilliseconds: Int64
    }

    struct DirectoryIdentityPayload: Encodable {
        let contractIdentifier: String
        let directory: CodexGhostRepairDestinationCanaryDirectory
        let permissionRequirement:
            CodexGhostRepairDestinationCanaryPermissionRequirement
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let ownerUID: UInt32
        let permissionContractSatisfied: Bool
    }

    struct EvidenceTokenPayload: Encodable {
        let contractIdentifier: String
        let policy: CodexGhostRepairDestinationCanaryPolicyEvidence
        let directories: [CodexGhostRepairDestinationCanaryDirectoryEvidence]
    }

    enum InspectionError: String, Error {
        case applicationSupportUnavailable = "application-support-unavailable"
        case invalidTestBoundary = "invalid-test-boundary"
        case liveRootRejected = "live-root-rejected"
        case invalidTestMarker = "invalid-test-marker"
        case unsafeDirectory = "unsafe-directory"
        case metadataUnavailable = "metadata-unavailable"
        case identityDrift = "identity-drift"
        case invalidPolicy = "invalid-policy"
    }
}
