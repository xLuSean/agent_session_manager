import Darwin
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH
enum CodexGhostRepairProductionDestinationStatus: String, Hashable, Sendable {
    case requiresPreparation
    case ready
    case partialSafePrefix
}

struct CodexGhostRepairProductionDestinationReport: Hashable, Sendable {
    let storageRootDigest: String
    let retentionPolicy: CodexGhostRepairPublishedSnapshotRetentionPolicy
    let productionPolicy: CodexGhostRepairProductionPolicy?
    let directories: [CodexGhostRepairDestinationDirectoryEvidence]
    let createdDirectories: [CodexGhostRepairDestinationDirectory]
    let status: CodexGhostRepairProductionDestinationStatus
    let failureDigest: String?

    let automaticResumeAllowed = false
    let snapshotAcquisitionAuthority = false
    let officialAbsenceAuthority = false
    let repairMutationAuthority = false
}

/// E41 fixed production-destination contract. The production factory resolves
/// only FileManager's user Application Support plus the manager's exact bundle
/// namespace. Tests exercise effects only through a separately marked,
/// test-owned mirror constructor.
struct CodexGhostRepairProductionDestinationCapability: Sendable {
    static let testRootMarkerFileName =
        ".agent-session-manager-e41-production-destination-root-v1"
    static let testRootMarkerContents =
        "Agent Session Manager E41 test-owned production destination root v1\n"

    typealias DirectoryCreator = @Sendable (URL) throws -> Void
    typealias FreshLocationResolver = @Sendable () throws
        -> StateStoreLocation.GhostRepairDestinationLocation

    private let frozenLocation: StateStoreLocation.GhostRepairDestinationLocation
    private let retentionPolicy: CodexGhostRepairPublishedSnapshotRetentionPolicy
    private let productionPolicy: CodexGhostRepairProductionPolicy?
    private let freshLocationResolver: FreshLocationResolver
    private let testOwnedAllowedParentURL: URL?
    private let directoryCreator: DirectoryCreator

    var isTestOwnedCanaryBackend: Bool {
        testOwnedAllowedParentURL != nil
    }

    /// Compiles the fixed production resolution contract without accepting an
    /// arbitrary caller path. E43 has no App call site, so this factory is not
    /// executed by shipping or test code yet.
    static func production(policy: CodexGhostRepairProductionPolicy) throws -> Self {
        let location = try StateStoreLocation
            .applicationSupportGhostRepairDestinationLocation()
        return Self(
            frozenLocation: location,
            retentionPolicy: try policy.publishedSnapshotRetentionPolicy(),
            productionPolicy: policy,
            freshLocationResolver: {
                try StateStoreLocation
                    .applicationSupportGhostRepairDestinationLocation()
            },
            testOwnedAllowedParentURL: nil,
            directoryCreator: { try Self.createPrivateDirectory($0) }
        )
    }

    /// Test-only acceptance surface. The marker and allowed-parent capability
    /// are intentionally distinct from E34 and cannot authorize live paths.
    init(
        testOwnedApplicationSupportDirectory: URL,
        testOwnedAllowedParentURL: URL,
        retentionPolicy: CodexGhostRepairPublishedSnapshotRetentionPolicy,
        directoryCreator: @escaping DirectoryCreator = {
            try Self.createPrivateDirectory($0)
        }
    ) throws {
        try self.init(
            testOwnedApplicationSupportDirectory:
                testOwnedApplicationSupportDirectory,
            testOwnedAllowedParentURL: testOwnedAllowedParentURL,
            validatedRetentionPolicy: retentionPolicy,
            productionPolicy: nil,
            directoryCreator: directoryCreator
        )
    }

    /// E43 test-owned composition path. It proves the exact production policy
    /// reaches destination readback without calling the live factory.
    init(
        testOwnedApplicationSupportDirectory: URL,
        testOwnedAllowedParentURL: URL,
        productionPolicy: CodexGhostRepairProductionPolicy,
        directoryCreator: @escaping DirectoryCreator = {
            try Self.createPrivateDirectory($0)
        }
    ) throws {
        try self.init(
            testOwnedApplicationSupportDirectory:
                testOwnedApplicationSupportDirectory,
            testOwnedAllowedParentURL: testOwnedAllowedParentURL,
            validatedRetentionPolicy:
                productionPolicy.publishedSnapshotRetentionPolicy(),
            productionPolicy: productionPolicy,
            directoryCreator: directoryCreator
        )
    }

    private init(
        testOwnedApplicationSupportDirectory: URL,
        testOwnedAllowedParentURL: URL,
        validatedRetentionPolicy: CodexGhostRepairPublishedSnapshotRetentionPolicy,
        productionPolicy: CodexGhostRepairProductionPolicy?,
        directoryCreator: @escaping DirectoryCreator
    ) throws {
        let allowedParent = try Self.validatedRealDirectory(
            testOwnedAllowedParentURL,
            label: "E41 test-owned allowed parent",
            exactPrivatePermissions: true
        )
        let applicationSupport = try Self.validatedRealDirectory(
            testOwnedApplicationSupportDirectory,
            label: "E41 injected Application Support",
            exactPrivatePermissions: false
        )
        guard applicationSupport.path != allowedParent.path,
              Self.isDescendant(applicationSupport, of: allowedParent) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E41 destination escaped its test-owned allowed parent."
            )
        }
        let liveApplicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.standardizedFileURL.resolvingSymlinksInPath()
        guard liveApplicationSupport?.path != applicationSupport.path,
              liveApplicationSupport.map({
                  !Self.isDescendant(applicationSupport, of: $0)
              }) ?? true else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Live user Application Support is unavailable to E41 tests."
            )
        }
        try Self.validateTestRootMarker(in: allowedParent)
        let location = try StateStoreLocation.ghostRepairDestinationLocation(
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: StateStoreLocation.defaultBundleIdentifier
        )
        self.init(
            frozenLocation: location,
            retentionPolicy: validatedRetentionPolicy,
            productionPolicy: productionPolicy,
            freshLocationResolver: {
                try StateStoreLocation.ghostRepairDestinationLocation(
                    applicationSupportDirectory: applicationSupport,
                    bundleIdentifier: StateStoreLocation.defaultBundleIdentifier
                )
            },
            testOwnedAllowedParentURL: allowedParent,
            directoryCreator: directoryCreator
        )
    }

    private init(
        frozenLocation: StateStoreLocation.GhostRepairDestinationLocation,
        retentionPolicy: CodexGhostRepairPublishedSnapshotRetentionPolicy,
        productionPolicy: CodexGhostRepairProductionPolicy?,
        freshLocationResolver: @escaping FreshLocationResolver,
        testOwnedAllowedParentURL: URL?,
        directoryCreator: @escaping DirectoryCreator
    ) {
        self.frozenLocation = frozenLocation
        self.retentionPolicy = retentionPolicy
        self.productionPolicy = productionPolicy
        self.freshLocationResolver = freshLocationResolver
        self.testOwnedAllowedParentURL = testOwnedAllowedParentURL
        self.directoryCreator = directoryCreator
    }

    func inspect() throws -> CodexGhostRepairProductionDestinationReport {
        try validateFreshCapability()
        return try readback(
            createdDirectories: [],
            statusOverride: nil,
            failureDigest: nil
        )
    }

    func prepare() throws -> CodexGhostRepairProductionDestinationReport {
        try validateFreshCapability()
        let preflight = try readback(
            createdDirectories: [],
            statusOverride: nil,
            failureDigest: nil
        )
        var expectedEvidence = preflight.directories
        var created: [CodexGhostRepairDestinationDirectory] = []

        for entry in fixedDirectories {
            guard expectedEvidence.first(where: {
                $0.directory == entry.directory
            })?.exists != true else { continue }

            try validateFreshCapability()
            let beforeEffect = try readback(
                createdDirectories: created,
                statusOverride: nil,
                failureDigest: nil
            )
            guard beforeEffect.directories == expectedEvidence else {
                throw CodexGhostRepairError.targetDrift(
                    "E41 destination layout drifted before the next directory effect."
                )
            }

            do {
                try directoryCreator(entry.url)
            } catch {
                try validateFreshCapability()
                let afterFailure = try readback(
                    createdDirectories: created,
                    statusOverride: .partialSafePrefix,
                    failureDigest: try CodexGhostRepairHasher.hash(
                        String(describing: error)
                    )
                )
                guard afterFailure.directories == expectedEvidence else {
                    throw CodexGhostRepairError.targetDrift(
                        "E41 failed directory effect changed the frozen layout."
                    )
                }
                return afterFailure
            }

            try Self.validateCreatedDirectory(entry.url, label: entry.directory.rawValue)
            try Self.synchronizeDirectory(entry.url.deletingLastPathComponent())
            created.append(entry.directory)
            try validateFreshCapability()
            let afterEffect = try readback(
                createdDirectories: created,
                statusOverride: nil,
                failureDigest: nil
            )
            guard let newEvidence = afterEffect.directories.first(where: {
                $0.directory == entry.directory
            }), newEvidence.exists, newEvidence.permissionContractSatisfied else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "E41 directory effect did not produce exact readback."
                )
            }
            expectedEvidence = afterEffect.directories
        }

        try validateFreshCapability()
        let report = try readback(
            createdDirectories: created,
            statusOverride: nil,
            failureDigest: nil
        )
        guard report.status == .ready else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "E41 destination preparation did not complete exact readback."
            )
        }
        return report
    }

    private var fixedDirectories: [(
        directory: CodexGhostRepairDestinationDirectory,
        url: URL,
        requiresExactPrivatePermissions: Bool
    )] {
        [
            (.bundleSupport, frozenLocation.bundleSupportRootURL, false),
            (.storage, frozenLocation.storageRootURL, true),
            (.snapshots, frozenLocation.snapshotsRootURL, true),
            (.quarantine, frozenLocation.quarantineRootURL, true),
            (.journal, frozenLocation.journalRootURL, true),
            (.trashJournal, frozenLocation.trashJournalRootURL, true),
        ]
    }

    private func validateFreshCapability() throws {
        if let testOwnedAllowedParentURL {
            try Self.validateTestRootMarker(in: testOwnedAllowedParentURL)
        }
        let fresh = try freshLocationResolver()
        guard fresh == frozenLocation,
              !fresh.resolutionMutationAuthority else {
            throw CodexGhostRepairError.targetDrift(
                "E41 fixed production destination resolution drifted."
            )
        }
    }

    private func readback(
        createdDirectories: [CodexGhostRepairDestinationDirectory],
        statusOverride: CodexGhostRepairProductionDestinationStatus?,
        failureDigest: String?
    ) throws -> CodexGhostRepairProductionDestinationReport {
        var evidence: [CodexGhostRepairDestinationDirectoryEvidence] = []
        for entry in fixedDirectories {
            evidence.append(
                try Self.readDirectoryEvidence(
                    entry.directory,
                    url: entry.url,
                    requiresExactPrivatePermissions:
                        entry.requiresExactPrivatePermissions
                )
            )
        }
        let ready = evidence.allSatisfy(\.exists)
            && evidence.allSatisfy(\.permissionContractSatisfied)
        return CodexGhostRepairProductionDestinationReport(
            storageRootDigest: frozenLocation.storageRootDigest,
            retentionPolicy: retentionPolicy,
            productionPolicy: productionPolicy,
            directories: evidence,
            createdDirectories: createdDirectories,
            status: statusOverride ?? (ready ? .ready : .requiresPreparation),
            failureDigest: failureDigest
        )
    }

    private static func readDirectoryEvidence(
        _ directory: CodexGhostRepairDestinationDirectory,
        url: URL,
        requiresExactPrivatePermissions: Bool
    ) throws -> CodexGhostRepairDestinationDirectoryEvidence {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "E41 directory metadata is unavailable for \(directory.rawValue)."
                )
            }
            return CodexGhostRepairDestinationDirectoryEvidence(
                directory: directory,
                exists: false,
                device: nil,
                inode: nil,
                mode: nil,
                ownerUID: nil,
                permissionContractSatisfied: false
            )
        }
        try validateDirectoryStatus(
            status,
            label: directory.rawValue,
            exactPrivatePermissions: requiresExactPrivatePermissions
        )
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "E41 directory could not be opened safely: \(directory.rawValue)."
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              stableIdentity(status, opened) else {
            throw CodexGhostRepairError.targetDrift(
                "E41 directory identity drifted: \(directory.rawValue)."
            )
        }
        return CodexGhostRepairDestinationDirectoryEvidence(
            directory: directory,
            exists: true,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode & 0o777),
            ownerUID: status.st_uid,
            permissionContractSatisfied: requiresExactPrivatePermissions
                ? (status.st_mode & 0o777) == 0o700
                : ownerControlled(status)
        )
    }

    private static func validateCreatedDirectory(_ url: URL, label: String) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "E41 directory creation was not observable: \(label)."
            )
        }
        try validateDirectoryStatus(
            status,
            label: label,
            exactPrivatePermissions: true
        )
        try synchronizeDirectory(url)
    }

    private static func validatedRealDirectory(
        _ url: URL,
        label: String,
        exactPrivatePermissions: Bool
    ) throws -> URL {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "\(label) is unavailable."
            )
        }
        try validateDirectoryStatus(
            status,
            label: label,
            exactPrivatePermissions: exactPrivatePermissions
        )
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func validateDirectoryStatus(
        _ status: stat,
        label: String,
        exactPrivatePermissions: Bool
    ) throws {
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              ownerControlled(status),
              !exactPrivatePermissions || (status.st_mode & 0o777) == 0o700 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E41 \(label) must be an owner-controlled real directory with expected permissions."
            )
        }
    }

    private static func ownerControlled(_ status: stat) -> Bool {
        status.st_uid == geteuid()
            && (status.st_mode & S_IRUSR) != 0
            && (status.st_mode & S_IXUSR) != 0
            && (status.st_mode & (S_IWGRP | S_IWOTH)) == 0
    }

    private static func validateTestRootMarker(in allowedParent: URL) throws {
        let marker = allowedParent.appendingPathComponent(
            testRootMarkerFileName,
            isDirectory: false
        )
        var before = stat()
        guard lstat(marker.path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(),
              (before.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact E41 test-owned destination marker is missing or unsafe."
            )
        }
        let descriptor = Darwin.open(marker.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact E41 test-owned destination marker cannot be opened safely."
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              stableIdentity(before, opened) else {
            throw CodexGhostRepairError.targetDrift(
                "E41 test-owned destination marker drifted."
            )
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E41 test-owned destination marker could not be read."
                )
            }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= testRootMarkerContents.utf8.count else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Exact E41 test-owned destination marker is invalid."
                )
            }
        }
        guard String(data: bytes, encoding: .utf8) == testRootMarkerContents else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact E41 test-owned destination marker is invalid."
            )
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              stableFileEvidence(before, after) else {
            throw CodexGhostRepairError.targetDrift(
                "E41 test-owned destination marker drifted during readback."
            )
        }
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        guard Darwin.mkdir(url.path, S_IRWXU) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "E41 fixed private directory could not be created."
            )
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "E41 directory durability handle is unavailable."
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "E41 directory durability readback failed."
            )
        }
    }

    private static func stableIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
    }

    private static func stableFileEvidence(_ lhs: stat, _ rhs: stat) -> Bool {
        stableIdentity(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return candidate.path.hasPrefix(prefix)
    }
}
#endif
