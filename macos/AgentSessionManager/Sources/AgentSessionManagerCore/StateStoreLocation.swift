import Darwin
import Foundation

public enum StateStoreLocationError: Error, Equatable, LocalizedError {
    case applicationSupportUnavailable
    case invalidBundleIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The user Application Support directory is unavailable."
        case let .invalidBundleIdentifier(identifier):
            "Invalid state-store bundle identifier: \(identifier)"
        }
    }
}

public enum StateStoreLocation {
    public static let defaultBundleIdentifier = "com.sean.AgentSessionManager"
    public static let databaseFileName = "state.sqlite"
    public static let diagnosticLogFileName = "diagnostic-events.jsonl"

    struct GhostRepairDestinationLocation: Hashable, Sendable {
        let applicationSupportDirectoryURL: URL
        let bundleSupportRootURL: URL
        let storageRootURL: URL
        let snapshotsRootURL: URL
        let quarantineRootURL: URL
        let journalRootURL: URL
        let trashJournalRootURL: URL
        let capacityProbeURL: URL
        let storageRootDigest: String

        /// Resolving the fixed layout grants no directory creation, cleanup,
        /// snapshot, or repair authority.
        let resolutionMutationAuthority = false
    }

    /// Resolves through FileManager so a future sandboxed build naturally uses
    /// its container Application Support directory instead of a hard-coded path.
    public static func applicationSupportDatabaseURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = defaultBundleIdentifier
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StateStoreLocationError.applicationSupportUnavailable
        }
        return try databaseURL(
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: bundleIdentifier
        )
    }

    public static func applicationSupportDiagnosticLogURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = defaultBundleIdentifier
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StateStoreLocationError.applicationSupportUnavailable
        }
        return try diagnosticLogURL(
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: bundleIdentifier
        )
    }

    static func applicationSupportGhostRepairDestinationLocation(
        fileManager: FileManager = .default,
        bundleIdentifier: String = defaultBundleIdentifier
    ) throws -> GhostRepairDestinationLocation {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StateStoreLocationError.applicationSupportUnavailable
        }
        return try ghostRepairDestinationLocation(
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: bundleIdentifier
        )
    }

    static func ghostRepairDestinationLocation(
        applicationSupportDirectory: URL,
        bundleIdentifier: String = defaultBundleIdentifier
    ) throws -> GhostRepairDestinationLocation {
        let identifier = try validatedBundleIdentifier(bundleIdentifier)
        try validateExistingOwnerControlledDirectory(
            applicationSupportDirectory,
            label: "Application Support"
        )
        let applicationSupport = applicationSupportDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        let liveCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard applicationSupport.path != liveCodexHome.path,
              !isDescendant(applicationSupport, of: liveCodexHome) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Ghost Repair destination cannot be inside live ~/.codex."
            )
        }

        let bundleSupportRoot = applicationSupport.appendingPathComponent(
            identifier,
            isDirectory: true
        )
        let storageRoot = bundleSupportRoot.appendingPathComponent(
            CodexGhostRepairDestinationCanaryFixedLayout.ghostRepairDirectoryName,
            isDirectory: true
        )
        let snapshotsRoot = storageRoot.appendingPathComponent(
            CodexGhostRepairDestinationCanaryFixedLayout.snapshotsDirectoryName,
            isDirectory: true
        )
        let quarantineRoot = storageRoot.appendingPathComponent(
            CodexGhostRepairDestinationCanaryFixedLayout.quarantineDirectoryName,
            isDirectory: true
        )
        let journalRoot = storageRoot.appendingPathComponent(
            CodexGhostRepairDestinationCanaryFixedLayout.journalDirectoryName,
            isDirectory: true
        )
        let trashJournalRoot = journalRoot.appendingPathComponent(
            CodexGhostRepairDestinationCanaryFixedLayout.trashDirectoryName,
            isDirectory: true
        )
        for (label, url) in [
            ("bundle support root", bundleSupportRoot),
            ("Ghost Repair storage root", storageRoot),
            ("Snapshots root", snapshotsRoot),
            ("Quarantine root", quarantineRoot),
            ("Journal root", journalRoot),
            ("Trash journal root", trashJournalRoot),
        ] {
            try validateOptionalOwnerControlledDirectory(url, label: label)
        }

        return GhostRepairDestinationLocation(
            applicationSupportDirectoryURL: applicationSupport,
            bundleSupportRootURL: bundleSupportRoot,
            storageRootURL: storageRoot,
            snapshotsRootURL: snapshotsRoot,
            quarantineRootURL: quarantineRoot,
            journalRootURL: journalRoot,
            trashJournalRootURL: trashJournalRoot,
            capacityProbeURL: applicationSupport,
            storageRootDigest: try CodexGhostRepairHasher.hash(storageRoot.path)
        )
    }

    public static func databaseURL(
        applicationSupportDirectory: URL,
        bundleIdentifier: String = defaultBundleIdentifier
    ) throws -> URL {
        let identifier = try validatedBundleIdentifier(bundleIdentifier)
        return applicationSupportDirectory
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent(databaseFileName, isDirectory: false)
    }

    public static func diagnosticLogURL(
        applicationSupportDirectory: URL,
        bundleIdentifier: String = defaultBundleIdentifier
    ) throws -> URL {
        let identifier = try validatedBundleIdentifier(bundleIdentifier)
        return applicationSupportDirectory
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent(diagnosticLogFileName, isDirectory: false)
    }

    private static func validatedBundleIdentifier(_ bundleIdentifier: String) throws
        -> String
    {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              !identifier.contains("/"),
              identifier != ".",
              identifier != ".." else {
            throw StateStoreLocationError.invalidBundleIdentifier(bundleIdentifier)
        }
        return identifier
    }

    private static func validateOptionalOwnerControlledDirectory(
        _ url: URL,
        label: String
    ) throws {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Ghost Repair \(label) could not be inspected."
                )
            }
            return
        }
        try validateOwnerControlledDirectoryStatus(status, label: label)
    }

    private static func validateExistingOwnerControlledDirectory(
        _ url: URL,
        label: String
    ) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Ghost Repair \(label) is unavailable."
            )
        }
        try validateOwnerControlledDirectoryStatus(status, label: label)
    }

    private static func validateOwnerControlledDirectoryStatus(
        _ status: stat,
        label: String
    ) throws {
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & S_IRUSR) != 0,
              (status.st_mode & S_IXUSR) != 0,
              (status.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Ghost Repair \(label) must be an owner-controlled, non-symlink directory."
            )
        }
    }

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return candidate.path.hasPrefix(prefix)
    }
}
