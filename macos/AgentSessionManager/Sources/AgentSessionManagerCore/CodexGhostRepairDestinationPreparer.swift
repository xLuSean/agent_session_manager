import Darwin
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH
enum CodexGhostRepairDestinationDirectory: String, CaseIterable, Codable, Sendable {
    case bundleSupport
    case storage
    case snapshots
    case quarantine
    case journal
    case trashJournal
}

struct CodexGhostRepairDestinationDirectoryEvidence: Codable, Hashable, Sendable {
    let directory: CodexGhostRepairDestinationDirectory
    let exists: Bool
    let device: UInt64?
    let inode: UInt64?
    let mode: UInt32?
    let ownerUID: UInt32?
    let permissionContractSatisfied: Bool
}

struct CodexGhostRepairDestinationPreparationReport: Hashable, Sendable {
    let storageRootDigest: String
    let directories: [CodexGhostRepairDestinationDirectoryEvidence]
    let createdDirectories: [CodexGhostRepairDestinationDirectory]
    let completed: Bool

    /// A partial readback can explain what exists, but it cannot delete,
    /// replace, chmod, or otherwise repair any entry.
    let recoveryMutationAuthority = false
}

/// E34 preparation capability for a marked, injected, test-owned Application
/// Support root. It can create only the six fixed manager directories below.
/// It cannot read or copy Codex files, publish snapshots, or repair a collision.
struct CodexGhostRepairDestinationPreparer: Sendable {
    static let testRootMarkerFileName =
        ".agent-session-manager-e34-destination-root-v1"
    static let testRootMarkerContents =
        "Agent Session Manager E34 test-owned destination root v1\n"

    typealias DirectoryCreator = @Sendable (URL) throws -> Void

    private let frozenLocation: StateStoreLocation.GhostRepairDestinationLocation
    private let allowedParentURL: URL
    private let directoryCreator: DirectoryCreator

    init(
        location: StateStoreLocation.GhostRepairDestinationLocation,
        testOwnedAllowedParentURL: URL,
        directoryCreator: @escaping DirectoryCreator = {
            try Self.createPrivateDirectory($0)
        }
    ) throws {
        let allowedParent = try Self.validatedRealDirectory(
            testOwnedAllowedParentURL,
            label: "E34 test-owned allowed parent",
            exactPrivatePermissions: true
        )
        let applicationSupport = try Self.validatedRealDirectory(
            location.applicationSupportDirectoryURL,
            label: "E34 injected Application Support",
            exactPrivatePermissions: false
        )
        guard applicationSupport.path != allowedParent.path,
              Self.isDescendant(applicationSupport, of: allowedParent) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E34 destination escaped its test-owned allowed parent."
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
                "Live user Application Support is unavailable to E34."
            )
        }

        try Self.validateTestRootMarker(in: allowedParent)
        try Self.validateFrozenLocation(location)

        self.frozenLocation = location
        self.allowedParentURL = allowedParent
        self.directoryCreator = directoryCreator
    }

    func inspect() throws -> CodexGhostRepairDestinationPreparationReport {
        try validateFreshCapability()
        return try readback(createdDirectories: [])
    }

    func prepare() throws -> CodexGhostRepairDestinationPreparationReport {
        try validateFreshCapability()
        let preflight = try readback(createdDirectories: [])
        let evidenceByDirectory = Dictionary(
            uniqueKeysWithValues: preflight.directories.map { ($0.directory, $0) }
        )
        var created: [CodexGhostRepairDestinationDirectory] = []

        for entry in fixedDirectories {
            if evidenceByDirectory[entry.directory]?.exists == true { continue }

            // Revalidate the complete fixed layout immediately before every
            // effect. A collision or unsafe path anywhere blocks the next mkdir.
            try validateFreshCapability()
            _ = try readback(createdDirectories: created)
            try directoryCreator(entry.url)
            try Self.validateCreatedDirectory(
                entry.url,
                label: entry.directory.rawValue
            )
            try Self.synchronizeDirectory(entry.url.deletingLastPathComponent())
            created.append(entry.directory)
        }

        try validateFreshCapability()
        let report = try readback(createdDirectories: created)
        guard report.completed else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "E34 destination preparation did not complete exact readback."
            )
        }
        return report
    }

    func preparedSnapshotDestination(
        expectedReport: CodexGhostRepairDestinationPreparationReport,
        fixedCapacityHeadroomBytes: UInt64
    ) throws -> CodexGhostRepairPreparedSnapshotDestination {
        let expectedBinding = try CodexGhostRepairPreparedDestinationBinding(
            report: expectedReport
        )
        let freshBinding = try CodexGhostRepairPreparedDestinationBinding(
            report: inspect()
        )
        guard freshBinding == expectedBinding else {
            throw CodexGhostRepairError.targetDrift(
                "E34 destination changed after completed preparation readback."
            )
        }
        let destination = try CodexGhostRepairDisposableSnapshotDestination(
            applicationSupportDirectoryURL:
                frozenLocation.applicationSupportDirectoryURL,
            allowedParentURL: allowedParentURL,
            bundleIdentifier: frozenLocation.bundleSupportRootURL.lastPathComponent,
            fixedCapacityHeadroomBytes: fixedCapacityHeadroomBytes
        )
        guard destination.bundleSupportRootURL == frozenLocation.bundleSupportRootURL,
              destination.storageRootURL == frozenLocation.storageRootURL,
              destination.snapshotsRootURL == frozenLocation.snapshotsRootURL,
              destination.quarantineRootURL == frozenLocation.quarantineRootURL,
              destination.journalRootURL == frozenLocation.journalRootURL,
              destination.trashJournalRootURL == frozenLocation.trashJournalRootURL else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E35 destination adapter did not preserve the exact E33 layout."
            )
        }
        return try CodexGhostRepairPreparedSnapshotDestination(
            destination: destination,
            frozenBinding: expectedBinding,
            freshReadback: {
                try CodexGhostRepairPreparedDestinationBinding(
                    report: self.inspect()
                )
            }
        )
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
        try Self.validateTestRootMarker(in: allowedParentURL)
        let bundleIdentifier = frozenLocation.bundleSupportRootURL.lastPathComponent
        let fresh = try StateStoreLocation.ghostRepairDestinationLocation(
            applicationSupportDirectory: frozenLocation.applicationSupportDirectoryURL,
            bundleIdentifier: bundleIdentifier
        )
        guard fresh == frozenLocation else {
            throw CodexGhostRepairError.targetDrift(
                "E34 frozen manager destination drifted."
            )
        }
    }

    private func readback(
        createdDirectories: [CodexGhostRepairDestinationDirectory]
    ) throws -> CodexGhostRepairDestinationPreparationReport {
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
        return CodexGhostRepairDestinationPreparationReport(
            storageRootDigest: frozenLocation.storageRootDigest,
            directories: evidence,
            createdDirectories: createdDirectories,
            completed: evidence.allSatisfy(\.exists)
                && evidence.allSatisfy(\.permissionContractSatisfied)
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
                    "E34 directory metadata is unavailable for \(directory.rawValue)."
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
                "E34 directory could not be opened safely: \(directory.rawValue)."
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              stableIdentity(status, opened) else {
            throw CodexGhostRepairError.targetDrift(
                "E34 directory identity drifted: \(directory.rawValue)."
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
                "E34 directory creation was not observable: \(label)."
            )
        }
        try validateDirectoryStatus(
            status,
            label: label,
            exactPrivatePermissions: true
        )
        try synchronizeDirectory(url)
    }

    private static func validateFrozenLocation(
        _ location: StateStoreLocation.GhostRepairDestinationLocation
    ) throws {
        let identifier = location.bundleSupportRootURL.lastPathComponent
        let fresh = try StateStoreLocation.ghostRepairDestinationLocation(
            applicationSupportDirectory: location.applicationSupportDirectoryURL,
            bundleIdentifier: identifier
        )
        guard fresh == location,
              !location.resolutionMutationAuthority else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E34 requires an exact zero-effect E33 destination resolution."
            )
        }
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
                "E34 \(label) must be an owner-controlled real directory with expected permissions."
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
                "Exact E34 test-owned destination marker is missing or unsafe."
            )
        }
        let descriptor = Darwin.open(marker.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact E34 test-owned destination marker cannot be opened safely."
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              stableIdentity(before, opened) else {
            throw CodexGhostRepairError.targetDrift(
                "E34 test-owned destination marker drifted."
            )
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E34 test-owned destination marker could not be read."
                )
            }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= testRootMarkerContents.utf8.count else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Exact E34 test-owned destination marker is invalid."
                )
            }
        }
        guard String(data: bytes, encoding: .utf8) == testRootMarkerContents else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact E34 test-owned destination marker is invalid."
            )
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              stableFileEvidence(before, after) else {
            throw CodexGhostRepairError.targetDrift(
                "E34 test-owned destination marker drifted during readback."
            )
        }
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        guard Darwin.mkdir(url.path, S_IRWXU) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "E34 fixed private directory could not be created."
            )
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "E34 directory durability handle is unavailable."
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "E34 directory durability readback failed."
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
