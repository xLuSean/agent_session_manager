import CryptoKit
import Darwin
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH
struct CodexGhostRepairSnapshotFileEvidence: Codable, Hashable, Sendable {
    let fileName: String
    let exists: Bool
    let device: UInt64?
    let inode: UInt64?
    let mode: UInt32?
    let size: UInt64?
    let modificationSeconds: Int64?
    let modificationNanoseconds: Int64?
    let sha256: String?
}

struct CodexGhostRepairSnapshotCapacityEvidence: Codable, Hashable, Sendable {
    let sourceBytes: UInt64
    let reservedCopyCount: UInt64
    let fixedHeadroomBytes: UInt64
    let requiredBytes: UInt64
    let availableBytes: UInt64
    let destinationVolumeDigest: String

    var isSufficient: Bool { availableBytes >= requiredBytes }
}

enum CodexGhostRepairSnapshotPartialStatus: String, Codable, Hashable, Sendable {
    case unpublishedPartial
    case publicationInterrupted
}

struct CodexGhostRepairSnapshotPartialRecord: Codable, Hashable, Sendable {
    let snapshotID: UUID
    let partialRootDigest: String
    let fileNames: [String]
    let markerPresent: Bool
    let manifestPresent: Bool
    let status: CodexGhostRepairSnapshotPartialStatus

    /// Quarantine inspection is evidence only. It never grants copy, retry,
    /// publication, deletion, or Trash authority.
    let recoveryMutationAuthority: Bool
}

protocol CodexGhostRepairSnapshotCapacityProbing: Sendable {
    func availableCapacity(at url: URL) async throws -> UInt64
}

struct DarwinGhostRepairSnapshotCapacityProbe:
    CodexGhostRepairSnapshotCapacityProbing,
    Sendable
{
    func availableCapacity(at url: URL) async throws -> UInt64 {
        var status = statfs()
        guard statfs(url.path, &status) == 0,
              status.f_bavail >= 0,
              status.f_bsize >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot destination capacity is unavailable."
            )
        }
        let (capacity, overflow) = UInt64(status.f_bavail)
            .multipliedReportingOverflow(by: UInt64(status.f_bsize))
        guard !overflow else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot destination capacity overflowed UInt64."
            )
        }
        return capacity
    }
}
/// E28 test-owned destination capability. It models an Agent Session Manager
/// Application Support root separately from the externally-owned source.
struct CodexGhostRepairDisposableSnapshotDestination: Hashable, Sendable {
    static let ghostRepairDirectoryName = "GhostRepair"
    static let snapshotsDirectoryName = "Snapshots"
    static let quarantineDirectoryName = "Quarantine"
    static let journalDirectoryName = "Journal"
    static let trashJournalDirectoryName = "Trash"

    let applicationSupportDirectoryURL: URL
    let bundleSupportRootURL: URL
    let storageRootURL: URL
    let snapshotsRootURL: URL
    let quarantineRootURL: URL
    let journalRootURL: URL
    let trashJournalRootURL: URL
    let allowedParentURL: URL
    let fixedCapacityHeadroomBytes: UInt64

    init(
        applicationSupportDirectoryURL: URL,
        allowedParentURL: URL,
        bundleIdentifier: String = StateStoreLocation.defaultBundleIdentifier,
        fixedCapacityHeadroomBytes: UInt64 = 64 * 1_024 * 1_024
    ) throws {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              !identifier.contains("/"),
              identifier != ".",
              identifier != ".." else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "snapshot destination bundle identifier is invalid"
            )
        }
        let original = try applicationSupportDirectoryURL.standardizedFileURL
            .resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard original.isDirectory == true, original.isSymbolicLink != true else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "Application Support destination must be a real directory"
            )
        }
        let allowedParent = allowedParentURL.standardizedFileURL.resolvingSymlinksInPath()
        let applicationSupport = applicationSupportDirectoryURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard Self.isDescendant(applicationSupport, of: allowedParent) else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "Application Support destination escaped the test-owned parent"
            )
        }
        let bundleSupportRoot = applicationSupport
            .appendingPathComponent(identifier, isDirectory: true)
        let storageRoot = bundleSupportRoot
            .appendingPathComponent(Self.ghostRepairDirectoryName, isDirectory: true)
        let homeCodex = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard storageRoot.path != homeCodex.path,
              !Self.isDescendant(storageRoot, of: homeCodex) else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "live ~/.codex is always prohibited"
            )
        }
        self.applicationSupportDirectoryURL = applicationSupport
        self.bundleSupportRootURL = bundleSupportRoot
        self.storageRootURL = storageRoot
        self.snapshotsRootURL = storageRoot.appendingPathComponent(
            Self.snapshotsDirectoryName,
            isDirectory: true
        )
        self.quarantineRootURL = storageRoot.appendingPathComponent(
            Self.quarantineDirectoryName,
            isDirectory: true
        )
        self.journalRootURL = storageRoot.appendingPathComponent(
            Self.journalDirectoryName,
            isDirectory: true
        )
        self.trashJournalRootURL = journalRootURL.appendingPathComponent(
            Self.trashJournalDirectoryName,
            isDirectory: true
        )
        self.allowedParentURL = allowedParent
        self.fixedCapacityHeadroomBytes = fixedCapacityHeadroomBytes
    }

    func publishedRoot(snapshotID: UUID) -> URL {
        snapshotsRootURL.appendingPathComponent(
            "snapshot-\(snapshotID.uuidString.lowercased())",
            isDirectory: true
        )
    }

    func quarantineRoot(snapshotID: UUID) -> URL {
        quarantineRootURL.appendingPathComponent(
            "snapshot-\(snapshotID.uuidString.lowercased())",
            isDirectory: true
        )
    }

    func validate(separatedFrom source: CodexGhostRepairDisposableBundle) throws {
        try source.validatePaths()
        let sourceRoot = source.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard sourceRoot.path != storageRootURL.path,
              !Self.isDescendant(sourceRoot, of: storageRootURL),
              !Self.isDescendant(storageRootURL, of: sourceRoot) else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "snapshot source and manager destination must be disjoint"
            )
        }
    }

    func preparePrivateDirectories() throws {
        for entry in [
            (url: bundleSupportRootURL, requiresExactPrivatePermissions: false),
            (url: storageRootURL, requiresExactPrivatePermissions: true),
            (url: snapshotsRootURL, requiresExactPrivatePermissions: true),
            (url: quarantineRootURL, requiresExactPrivatePermissions: true),
            (url: journalRootURL, requiresExactPrivatePermissions: true),
            (url: trashJournalRootURL, requiresExactPrivatePermissions: true),
        ] {
            let url = entry.url
            var status = stat()
            var created = false
            if lstat(url.path, &status) != 0 {
                guard errno == ENOENT else {
                    throw CodexGhostRepairError.snapshotAcquisitionFailed(
                        "snapshot storage directory metadata is unavailable"
                    )
                }
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                guard lstat(url.path, &status) == 0 else {
                    throw CodexGhostRepairError.snapshotAcquisitionFailed(
                        "snapshot storage directory creation was not observable"
                    )
                }
                created = true
            }
            guard (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == geteuid(),
                  (status.st_mode & S_IRUSR) != 0,
                  (status.st_mode & S_IXUSR) != 0,
                  (status.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                  !entry.requiresExactPrivatePermissions
                    || (status.st_mode & 0o777) == 0o700 else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "snapshot storage directory is not owner-controlled and private"
                )
            }
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "snapshot storage directory could not be opened safely"
                )
            }
            defer { Darwin.close(descriptor) }
            var openedStatus = stat()
            guard fstat(descriptor, &openedStatus) == 0,
                  openedStatus.st_dev == status.st_dev,
                  openedStatus.st_ino == status.st_ino,
                  (!created || fchmod(descriptor, S_IRWXU) == 0),
                  fstat(descriptor, &openedStatus) == 0,
                  openedStatus.st_uid == geteuid(),
                  (openedStatus.st_mode & S_IFMT) == S_IFDIR,
                  (openedStatus.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                  (!entry.requiresExactPrivatePermissions
                    || (openedStatus.st_mode & 0o777) == 0o700),
                  fsync(descriptor) == 0 else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "snapshot storage directory identity or durability failed"
                )
            }
        }
    }

    func partialRecord(snapshotID: UUID) throws
        -> CodexGhostRepairSnapshotPartialRecord?
    {
        let quarantine = quarantineRoot(snapshotID: snapshotID)
        let published = publishedRoot(snapshotID: snapshotID)
        let quarantineExists = FileManager.default.fileExists(atPath: quarantine.path)
        let publishedExists = FileManager.default.fileExists(atPath: published.path)
        guard !(quarantineExists && publishedExists) else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "snapshot exists in both quarantine and published storage"
            )
        }
        guard quarantineExists || publishedExists else { return nil }
        let root = quarantineExists ? quarantine : published
        var status = stat()
        guard lstat(root.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              (status.st_mode & 0o777) == 0o700 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "snapshot partial entry is not a private real directory"
            )
        }
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .sorted()
        for fileName in fileNames {
            let url = root.appendingPathComponent(fileName)
            var entry = stat()
            guard lstat(url.path, &entry) == 0,
                  (entry.st_mode & S_IFMT) == S_IFREG else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "snapshot quarantine contains an unsupported entry"
                )
            }
        }
        let markerPresent = fileNames.contains(
            CodexGhostRepairDisposableBundle.markerFileName
        )
        let manifestPresent = fileNames.contains(
            CodexGhostRepairDisposableSnapshotAcquirer.manifestFileName
        )
        if publishedExists, markerPresent, manifestPresent {
            return nil
        }
        guard !quarantineExists || !markerPresent else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "quarantine must never contain the publication marker"
            )
        }
        return CodexGhostRepairSnapshotPartialRecord(
            snapshotID: snapshotID,
            partialRootDigest: try CodexGhostRepairHasher.hash(root.path),
            fileNames: fileNames,
            markerPresent: markerPresent,
            manifestPresent: manifestPresent,
            status: publishedExists ? .publicationInterrupted : .unpublishedPartial,
            recoveryMutationAuthority: false
        )
    }

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return candidate.path.hasPrefix(parentPath)
    }
}

struct CodexGhostRepairSnapshotAcquisitionManifest: Codable, Hashable, Sendable {
    private struct Payload: Codable, Hashable {
        let snapshotID: UUID
        let sourceRootDigest: String
        let sourceFingerprintHash: String
        let files: [CodexGhostRepairSnapshotFileEvidence]
        let capacity: CodexGhostRepairSnapshotCapacityEvidence
        let preflightGate: CodexGhostRepairExecutionGate
        let postCopyGate: CodexGhostRepairExecutionGate
    }

    let snapshotID: UUID
    let sourceRootDigest: String
    let sourceFingerprintHash: String
    let files: [CodexGhostRepairSnapshotFileEvidence]
    let capacity: CodexGhostRepairSnapshotCapacityEvidence
    let preflightGate: CodexGhostRepairExecutionGate
    let postCopyGate: CodexGhostRepairExecutionGate
    let manifestHash: String

    init(
        snapshotID: UUID,
        sourceRootDigest: String,
        sourceFingerprintHash: String,
        files: [CodexGhostRepairSnapshotFileEvidence],
        capacity: CodexGhostRepairSnapshotCapacityEvidence,
        preflightGate: CodexGhostRepairExecutionGate,
        postCopyGate: CodexGhostRepairExecutionGate
    ) throws {
        let payload = Payload(
            snapshotID: snapshotID,
            sourceRootDigest: sourceRootDigest,
            sourceFingerprintHash: sourceFingerprintHash,
            files: files,
            capacity: capacity,
            preflightGate: preflightGate,
            postCopyGate: postCopyGate
        )
        self.snapshotID = snapshotID
        self.sourceRootDigest = sourceRootDigest
        self.sourceFingerprintHash = sourceFingerprintHash
        self.files = files
        self.capacity = capacity
        self.preflightGate = preflightGate
        self.postCopyGate = postCopyGate
        self.manifestHash = try CodexGhostRepairHasher.hash(payload)
    }

    func validateHash() throws {
        let expected = try CodexGhostRepairHasher.hash(
            Payload(
                snapshotID: snapshotID,
                sourceRootDigest: sourceRootDigest,
                sourceFingerprintHash: sourceFingerprintHash,
                files: files,
                capacity: capacity,
                preflightGate: preflightGate,
                postCopyGate: postCopyGate
            )
        )
        guard expected == manifestHash else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "manifest checksum mismatch"
            )
        }
    }
}

struct CodexGhostRepairDisposableSnapshotAcquisition: Sendable {
    let bundle: CodexGhostRepairDisposableBundle
    let manifest: CodexGhostRepairSnapshotAcquisitionManifest
    let manifestURL: URL
}

/// E28 test-owned raw-file snapshot acquisition. Source and manager-owned
/// destination capabilities are disjoint; neither can accept a live ~/.codex
/// path and the shipping App has no construction path.
actor CodexGhostRepairDisposableSnapshotAcquirer {
    static let manifestFileName = ".agent-session-manager-e28-snapshot-manifest-v2.json"

    private enum Source: Sendable {
        case disposable(CodexGhostRepairDisposableBundle)
        case canonical(CodexGhostRepairCanonicalAcquisitionSource)
    }

    private let source: Source
    private let destination: CodexGhostRepairDisposableSnapshotDestination
    private let gateSource: any CodexGhostRepairExecutionGateSource
    private let capacityProbe: any CodexGhostRepairSnapshotCapacityProbing
    private let journal: CodexGhostRepairSnapshotJournal

    init(
        source: CodexGhostRepairDisposableBundle,
        destination: CodexGhostRepairDisposableSnapshotDestination,
        gateSource: any CodexGhostRepairExecutionGateSource,
        journal: CodexGhostRepairSnapshotJournal,
        capacityProbe: any CodexGhostRepairSnapshotCapacityProbing =
            DarwinGhostRepairSnapshotCapacityProbe()
    ) {
        self.source = .disposable(source)
        self.destination = destination
        self.gateSource = gateSource
        self.journal = journal
        self.capacityProbe = capacityProbe
    }

    init(
        canonicalSource: CodexGhostRepairCanonicalAcquisitionSource,
        destination: CodexGhostRepairDisposableSnapshotDestination,
        gateSource: any CodexGhostRepairExecutionGateSource,
        journal: CodexGhostRepairSnapshotJournal,
        capacityProbe: any CodexGhostRepairSnapshotCapacityProbing =
            DarwinGhostRepairSnapshotCapacityProbe()
    ) {
        self.source = .canonical(canonicalSource)
        self.destination = destination
        self.gateSource = gateSource
        self.journal = journal
        self.capacityProbe = capacityProbe
    }

    init(
        canonicalSource: CodexGhostRepairCanonicalAcquisitionSource,
        preparedDestination: CodexGhostRepairPreparedSnapshotDestination,
        gateSource: any CodexGhostRepairExecutionGateSource,
        capacityProbe: any CodexGhostRepairSnapshotCapacityProbing =
            DarwinGhostRepairSnapshotCapacityProbe()
    ) {
        source = .canonical(canonicalSource)
        destination = preparedDestination.destination
        self.gateSource = gateSource
        journal = CodexGhostRepairSnapshotJournal(
            preparedDestination: preparedDestination
        )
        self.capacityProbe = capacityProbe
    }

    func acquire(
        snapshotID: UUID,
        afterCopyForTesting: (@Sendable () throws -> Void)? = nil,
        afterMoveBeforeMarkerForTesting: (@Sendable () throws -> Void)? = nil,
        afterMarkerBeforeJournalForTesting: (@Sendable () throws -> Void)? = nil
    ) async throws -> CodexGhostRepairDisposableSnapshotAcquisition {
        try Self.validateSeparation(source: source, destination: destination)
        let publishedRoot = destination.publishedRoot(snapshotID: snapshotID)
        let quarantineRoot = destination.quarantineRoot(snapshotID: snapshotID)
        guard !FileManager.default.fileExists(atPath: publishedRoot.path),
              !FileManager.default.fileExists(atPath: quarantineRoot.path) else {
            throw CodexGhostRepairError.claimAlreadyExists
        }
        let sourceRootDigest = try Self.sourceRootDigest(source)
        _ = try await journal.begin(
            snapshotID: snapshotID,
            sourceRootDigest: sourceRootDigest,
            nowMilliseconds: Self.nowMilliseconds()
        )
        do {
            let preflightGate = try await gateSource.ghostRepairExecutionGate()
            guard preflightGate.isClear else {
                throw CodexGhostRepairError.executionGateBlocked
            }
            let sourceBefore = try Self.fingerprint(source: source)
            let requiredDatabases = Set([
                CodexGhostRepairCanonicalSourceFile.desktop.rawValue,
                CodexGhostRepairCanonicalSourceFile.summaries.rawValue,
                CodexGhostRepairCanonicalSourceFile.history.rawValue,
            ])
            guard Set(sourceBefore.filter(\.exists).map(\.fileName))
                .isSuperset(of: requiredDatabases) else {
                throw CodexGhostRepairError.targetDrift(
                    "one or more required databases disappeared before acquisition"
                )
            }
            let sourceFingerprintHash = try CodexGhostRepairHasher.hash(sourceBefore)
            let capacity = try await Self.capacityEvidence(
                files: sourceBefore,
                destination: destination,
                capacityProbe: capacityProbe
            )
            guard capacity.isSufficient else {
                throw CodexGhostRepairError.executionGateBlocked
            }

            try await journal.markAcquiring(
                snapshotID: snapshotID,
                nowMilliseconds: Self.nowMilliseconds()
            )
            try Self.createExclusiveSnapshotDirectory(quarantineRoot)
            for evidence in sourceBefore where evidence.exists {
                let destinationURL = quarantineRoot.appendingPathComponent(evidence.fileName)
                try Self.copySourceFileExactly(
                    source: source,
                    destination: destinationURL,
                    expected: evidence
                )
            }
            try afterCopyForTesting?()

            let sourceAfter = try Self.fingerprint(source: source)
            guard sourceAfter == sourceBefore else {
                throw CodexGhostRepairError.targetDrift(
                    "snapshot source files drifted during acquisition"
                )
            }
            let postCopyGate = try await gateSource.ghostRepairExecutionGate()
            guard postCopyGate.isClear else {
                throw CodexGhostRepairError.executionGateBlocked
            }

            for evidence in sourceBefore where evidence.exists {
                let destinationURL = quarantineRoot.appendingPathComponent(evidence.fileName)
                let destinationEvidence = try Self.fingerprint(
                    url: destinationURL,
                    fileName: evidence.fileName
                )
                guard destinationEvidence.exists,
                      destinationEvidence.size == evidence.size,
                      destinationEvidence.sha256 == evidence.sha256,
                      destinationEvidence.mode.map({ $0 & UInt32(S_IFMT) })
                        == UInt32(S_IFREG),
                      destinationEvidence.mode.map({ $0 & 0o777 }) == 0o600 else {
                    throw CodexGhostRepairError.snapshotAcquisitionFailed(
                        "destination readback mismatch for \(evidence.fileName)"
                    )
                }
            }
            for evidence in sourceBefore where !evidence.exists {
                guard !FileManager.default.fileExists(
                    atPath: quarantineRoot.appendingPathComponent(evidence.fileName).path
                ) else {
                    throw CodexGhostRepairError.snapshotAcquisitionFailed(
                        "absent source sidecar appeared in the destination"
                    )
                }
            }

            let manifest = try CodexGhostRepairSnapshotAcquisitionManifest(
                snapshotID: snapshotID,
                sourceRootDigest: sourceRootDigest,
                sourceFingerprintHash: sourceFingerprintHash,
                files: sourceBefore,
                capacity: capacity,
                preflightGate: preflightGate,
                postCopyGate: postCopyGate
            )
            let quarantineManifestURL = quarantineRoot.appendingPathComponent(
                Self.manifestFileName
            )
            try Self.writeDurableExclusive(
                try Self.encode(manifest),
                to: quarantineManifestURL
            )
            let readbackManifest = try JSONDecoder().decode(
                CodexGhostRepairSnapshotAcquisitionManifest.self,
                from: Data(contentsOf: quarantineManifestURL)
            )
            try readbackManifest.validateHash()
            guard readbackManifest == manifest else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "manifest durable readback mismatch"
                )
            }
            try Self.publish(
                quarantineRoot: quarantineRoot,
                publishedRoot: publishedRoot
            )
            try afterMoveBeforeMarkerForTesting?()
            try Self.writeDurableExclusive(
                Data(CodexGhostRepairDisposableBundle.markerContents.utf8),
                to: publishedRoot.appendingPathComponent(
                    CodexGhostRepairDisposableBundle.markerFileName
                )
            )
            try afterMarkerBeforeJournalForTesting?()
            let bundle = try CodexGhostRepairDisposableBundle(
                rootURL: publishedRoot,
                allowedParentURL: destination.snapshotsRootURL
            )
            let manifestURL = publishedRoot.appendingPathComponent(Self.manifestFileName)
            try await journal.markPublished(
                snapshotID: snapshotID,
                manifestHash: manifest.manifestHash,
                nowMilliseconds: Self.nowMilliseconds()
            )
            return CodexGhostRepairDisposableSnapshotAcquisition(
                bundle: bundle,
                manifest: manifest,
                manifestURL: manifestURL
            )
        } catch let error as CodexGhostRepairError {
            try? await journal.markFailure(
                snapshotID: snapshotID,
                error: error,
                nowMilliseconds: Self.nowMilliseconds()
            )
            throw error
        } catch {
            try? await journal.markFailure(
                snapshotID: snapshotID,
                error: error,
                nowMilliseconds: Self.nowMilliseconds()
            )
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                error.localizedDescription
            )
        }
    }

    private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private static func validateSeparation(
        source: Source,
        destination: CodexGhostRepairDisposableSnapshotDestination
    ) throws {
        switch source {
        case let .disposable(bundle):
            try destination.validate(separatedFrom: bundle)
        case let .canonical(canonical):
            try canonical.validate(separatedFrom: destination)
        }
    }

    private static func sourceRootDigest(_ source: Source) throws -> String {
        switch source {
        case let .disposable(bundle):
            try CodexGhostRepairHasher.hash(bundle.rootURL.path)
        case let .canonical(canonical):
            canonical.canonicalCodexHomeDigest
        }
    }

    private static func capacityEvidence(
        files: [CodexGhostRepairSnapshotFileEvidence],
        destination: CodexGhostRepairDisposableSnapshotDestination,
        capacityProbe: any CodexGhostRepairSnapshotCapacityProbing
    ) async throws -> CodexGhostRepairSnapshotCapacityEvidence {
        var sourceBytes: UInt64 = 0
        for file in files where file.exists {
            guard let size = file.size else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot source size evidence is incomplete."
                )
            }
            let (next, overflow) = sourceBytes.addingReportingOverflow(size)
            guard !overflow else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot source size overflowed UInt64."
                )
            }
            sourceBytes = next
        }
        let reservedCopyCount: UInt64 = 2
        let (reservedBytes, copyOverflow) = sourceBytes.multipliedReportingOverflow(
            by: reservedCopyCount
        )
        let (requiredBytes, headroomOverflow) = reservedBytes.addingReportingOverflow(
            destination.fixedCapacityHeadroomBytes
        )
        guard !copyOverflow, !headroomOverflow else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot capacity requirement overflowed UInt64."
            )
        }
        let availableBytes = try await capacityProbe.availableCapacity(
            at: destination.applicationSupportDirectoryURL
        )
        return CodexGhostRepairSnapshotCapacityEvidence(
            sourceBytes: sourceBytes,
            reservedCopyCount: reservedCopyCount,
            fixedHeadroomBytes: destination.fixedCapacityHeadroomBytes,
            requiredBytes: requiredBytes,
            availableBytes: availableBytes,
            destinationVolumeDigest: try CodexGhostRepairHasher.hash(
                destination.applicationSupportDirectoryURL.path
            )
        )
    }

    private static func publish(quarantineRoot: URL, publishedRoot: URL) throws {
        guard !FileManager.default.fileExists(atPath: publishedRoot.path) else {
            throw CodexGhostRepairError.claimAlreadyExists
        }
        do {
            try FileManager.default.moveItem(at: quarantineRoot, to: publishedRoot)
        } catch {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "atomic snapshot publication failed"
            )
        }
        try fsyncDirectory(publishedRoot.deletingLastPathComponent())
        try fsyncDirectory(quarantineRoot.deletingLastPathComponent())
    }

    private static func fsyncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not open snapshot parent for fsync"
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "snapshot parent fsync failed"
            )
        }
    }

    private static func createExclusiveSnapshotDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(url.path, S_IRWXU) == 0 else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "could not set private snapshot directory permissions"
                )
            }
        } catch let error as CodexGhostRepairError {
            throw error
        } catch {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not create exclusive snapshot directory"
            )
        }
    }

    private static func fingerprint(source: Source) throws
        -> [CodexGhostRepairSnapshotFileEvidence]
    {
        switch source {
        case let .disposable(bundle):
            try fingerprint(disposableSource: bundle)
        case let .canonical(canonical):
            try canonical.fingerprint()
        }
    }

    private static func fingerprint(
        disposableSource source: CodexGhostRepairDisposableBundle
    ) throws -> [CodexGhostRepairSnapshotFileEvidence] {
        var evidence: [CodexGhostRepairSnapshotFileEvidence] = []
        for databaseURL in [
            source.desktopDatabaseURL,
            source.summariesDatabaseURL,
            source.historyDatabaseURL,
        ] {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let url = suffix.isEmpty
                    ? databaseURL
                    : URL(fileURLWithPath: databaseURL.path + suffix)
                evidence.append(
                    try fingerprint(
                        url: url,
                        fileName: databaseURL.lastPathComponent + suffix
                    )
                )
            }
        }
        return evidence
    }

    private static func copySourceFileExactly(
        source: Source,
        destination: URL,
        expected: CodexGhostRepairSnapshotFileEvidence
    ) throws {
        switch source {
        case let .disposable(bundle):
            try copyRegularFileExactly(
                source: bundle.rootURL.appendingPathComponent(expected.fileName),
                destination: destination,
                expected: expected
            )
        case let .canonical(canonical):
            guard let file = CodexGhostRepairCanonicalSourceFile(
                rawValue: expected.fileName
            ) else {
                throw CodexGhostRepairError.targetDrift(
                    "canonical source file is outside the fixed set: \(expected.fileName)"
                )
            }
            try copyCanonicalSourceFileExactly(
                canonical,
                file: file,
                destination: destination,
                expected: expected
            )
        }
    }

    private static func copyCanonicalSourceFileExactly(
        _ source: CodexGhostRepairCanonicalAcquisitionSource,
        file: CodexGhostRepairCanonicalSourceFile,
        destination: URL,
        expected: CodexGhostRepairSnapshotFileEvidence
    ) throws {
        let descriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not create destination: \(expected.fileName)"
            )
        }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not set destination permissions: \(expected.fileName)"
            )
        }
        try source.streamRawRead(file, expected: expected) { chunk in
            try chunk.withUnsafeBytes { rawBuffer in
                guard var pointer = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let written = Darwin.write(descriptor, pointer, remaining)
                    guard written > 0 else {
                        throw CodexGhostRepairError.snapshotAcquisitionFailed(
                            "destination write failed: \(expected.fileName)"
                        )
                    }
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                }
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "destination fsync failed: \(expected.fileName)"
            )
        }
    }

    private static func fingerprint(
        url: URL,
        fileName: String
    ) throws -> CodexGhostRepairSnapshotFileEvidence {
        var pathStatus = stat()
        if lstat(url.path, &pathStatus) != 0 {
            guard errno == ENOENT else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "could not inspect \(fileName)"
                )
            }
            return CodexGhostRepairSnapshotFileEvidence(
                fileName: fileName,
                exists: false,
                device: nil,
                inode: nil,
                mode: nil,
                size: nil,
                modificationSeconds: nil,
                modificationNanoseconds: nil,
                sha256: nil
            )
        }
        guard (pathStatus.st_mode & S_IFMT) == S_IFREG else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "snapshot source must be regular and non-symlink: \(fileName)"
            )
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not open snapshot source: \(fileName)"
            )
        }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino,
              openedStatus.st_size >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "snapshot source identity drifted while opening: \(fileName)"
            )
        }
        let digest = try sha256(descriptor: descriptor, rewind: false)
        var afterStatus = stat()
        guard fstat(descriptor, &afterStatus) == 0,
              stableIdentity(openedStatus, afterStatus) else {
            throw CodexGhostRepairError.targetDrift(
                "snapshot source drifted while hashing: \(fileName)"
            )
        }
        return evidence(fileName: fileName, status: afterStatus, sha256: digest)
    }

    private static func copyRegularFileExactly(
        source: URL,
        destination: URL,
        expected: CodexGhostRepairSnapshotFileEvidence
    ) throws {
        let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not open source for copy: \(expected.fileName)"
            )
        }
        defer { Darwin.close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              stableIdentity(sourceStatus, expected) else {
            throw CodexGhostRepairError.targetDrift(
                "source identity drifted before copy: \(expected.fileName)"
            )
        }

        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not create destination: \(expected.fileName)"
            )
        }
        defer { Darwin.close(destinationDescriptor) }
        guard fchmod(destinationDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not set destination permissions: \(expected.fileName)"
            )
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let readCount = Darwin.read(sourceDescriptor, &buffer, buffer.count)
            guard readCount >= 0 else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "source read failed: \(expected.fileName)"
                )
            }
            if readCount == 0 { break }
            hasher.update(data: Data(buffer[0..<readCount]))
            var offset = 0
            while offset < readCount {
                let written = buffer.withUnsafeBytes { rawBuffer in
                    Darwin.write(
                        destinationDescriptor,
                        rawBuffer.baseAddress!.advanced(by: offset),
                        readCount - offset
                    )
                }
                guard written > 0 else {
                    throw CodexGhostRepairError.snapshotAcquisitionFailed(
                        "destination write failed: \(expected.fileName)"
                    )
                }
                offset += written
            }
        }
        let copiedHash = "sha256:" + hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        guard copiedHash == expected.sha256 else {
            throw CodexGhostRepairError.targetDrift(
                "source content drifted during copy: \(expected.fileName)"
            )
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "destination fsync failed: \(expected.fileName)"
            )
        }
        var sourceAfter = stat()
        guard fstat(sourceDescriptor, &sourceAfter) == 0,
              stableIdentity(sourceAfter, expected) else {
            throw CodexGhostRepairError.targetDrift(
                "source metadata drifted during copy: \(expected.fileName)"
            )
        }
    }

    private static func evidence(
        fileName: String,
        status: stat,
        sha256: String
    ) -> CodexGhostRepairSnapshotFileEvidence {
        CodexGhostRepairSnapshotFileEvidence(
            fileName: fileName,
            exists: true,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            size: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            sha256: sha256
        )
    }

    private static func stableIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func stableIdentity(
        _ status: stat,
        _ evidence: CodexGhostRepairSnapshotFileEvidence
    ) -> Bool {
        evidence.exists
            && UInt64(status.st_dev) == evidence.device
            && UInt64(status.st_ino) == evidence.inode
            && UInt32(status.st_mode) == evidence.mode
            && status.st_size >= 0
            && UInt64(status.st_size) == evidence.size
            && Int64(status.st_mtimespec.tv_sec) == evidence.modificationSeconds
            && Int64(status.st_mtimespec.tv_nsec) == evidence.modificationNanoseconds
    }

    private static func sha256(descriptor: Int32, rewind: Bool) throws -> String {
        if rewind, lseek(descriptor, 0, SEEK_SET) < 0 {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not rewind source"
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "source hash read failed"
                )
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return "sha256:" + hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func writeDurableExclusive(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not create publication evidence"
            )
        }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else {
                    throw CodexGhostRepairError.snapshotAcquisitionFailed(
                        "publication evidence write failed"
                    )
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "publication evidence fsync failed"
            )
        }
        let directoryDescriptor = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY
        )
        guard directoryDescriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "could not open snapshot directory for fsync"
            )
        }
        defer { Darwin.close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "snapshot directory fsync failed"
            )
        }
    }
}
#endif
