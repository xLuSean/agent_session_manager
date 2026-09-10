import CryptoKit
import Darwin
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH
/// Fixed files that a future Ghost Repair snapshot acquisition may read.
/// Callers cannot supply a path or extend this set at runtime.
enum CodexGhostRepairCanonicalSourceFile: String, CaseIterable, Sendable {
    case desktop = "codex-dev.db"
    case desktopWAL = "codex-dev.db-wal"
    case desktopSHM = "codex-dev.db-shm"
    case desktopJournal = "codex-dev.db-journal"
    case summaries = "codex-thread-summaries-dev.db"
    case summariesWAL = "codex-thread-summaries-dev.db-wal"
    case summariesSHM = "codex-thread-summaries-dev.db-shm"
    case summariesJournal = "codex-thread-summaries-dev.db-journal"
    case history = "codex-history-snapshots-dev.db"
    case historyWAL = "codex-history-snapshots-dev.db-wal"
    case historySHM = "codex-history-snapshots-dev.db-shm"
    case historyJournal = "codex-history-snapshots-dev.db-journal"

    var isRequiredDatabase: Bool {
        switch self {
        case .desktop, .summaries, .history: true
        default: false
        }
    }
}

struct CodexGhostRepairCanonicalSourceRead: Sendable {
    let evidence: CodexGhostRepairSnapshotFileEvidence
    let bytes: Data
}

/// E31 acquisition-only source contract. This phase can construct it only for
/// a marked, test-owned canonical Codex-home mirror. It exposes fixed raw file
/// reads and fingerprints, never paths, SQLite queries, transactions, or writes.
struct CodexGhostRepairCanonicalAcquisitionSource: Sendable {
    static let testMirrorMarkerFileName =
        ".agent-session-manager-e31-canonical-source-mirror-v1"
    static let testMirrorMarkerContents =
        "Agent Session Manager E31 test-owned canonical source mirror v1\n"

    let canonicalCodexHomeDigest: String
    let sqliteRootDigest: String

    private let sqliteRootURL: URL

    init(
        operationalGateConfiguration: CodexGhostRepairOperationalGateConfiguration,
        testOwnedAllowedParentURL: URL
    ) throws {
        let configuredDesktop = operationalGateConfiguration.desktopDatabaseURL
            .standardizedFileURL
        let configuredSQLiteRoot = configuredDesktop.deletingLastPathComponent()
        let configuredCodexHome = configuredSQLiteRoot.deletingLastPathComponent()

        try Self.validateDirectory(
            configuredCodexHome,
            label: "canonical Codex home"
        )
        try Self.validateDirectory(
            configuredSQLiteRoot,
            label: "canonical sqlite root"
        )
        try Self.validateDirectory(
            testOwnedAllowedParentURL,
            label: "test-owned allowed parent"
        )

        let allowedParent = testOwnedAllowedParentURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let codexHome = configuredCodexHome.standardizedFileURL
            .resolvingSymlinksInPath()
        let sqliteRoot = configuredSQLiteRoot.standardizedFileURL
            .resolvingSymlinksInPath()
        guard codexHome.path != allowedParent.path,
              Self.isDescendant(codexHome, of: allowedParent) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical acquisition source escaped the test-owned parent."
            )
        }

        let liveCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard codexHome.path != liveCodexHome.path,
              !Self.isDescendant(codexHome, of: liveCodexHome) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Live ~/.codex is unavailable to the E31 source contract."
            )
        }

        let expectedSQLiteRoot = codexHome.appendingPathComponent(
            "sqlite",
            isDirectory: true
        )
        guard sqliteRoot.path == expectedSQLiteRoot.path else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical acquisition source must use the fixed sqlite root."
            )
        }

        let expectedDatabases = [
            expectedSQLiteRoot.appendingPathComponent("codex-dev.db"),
            expectedSQLiteRoot.appendingPathComponent(
                "codex-thread-summaries-dev.db"
            ),
            expectedSQLiteRoot.appendingPathComponent(
                "codex-history-snapshots-dev.db"
            ),
        ].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let configuredDatabases = [
            operationalGateConfiguration.desktopDatabaseURL,
            operationalGateConfiguration.summariesDatabaseURL,
            operationalGateConfiguration.historyDatabaseURL,
        ].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard configuredDatabases == expectedDatabases else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical acquisition source and operational gate roots differ."
            )
        }

        let markerURL = codexHome.appendingPathComponent(
            Self.testMirrorMarkerFileName,
            isDirectory: false
        )
        var markerBefore = stat()
        guard lstat(markerURL.path, &markerBefore) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact E31 test-mirror marker is missing."
            )
        }
        try Self.validateFileStatus(
            markerBefore,
            fileName: Self.testMirrorMarkerFileName
        )
        guard let marker = FileManager.default.contents(atPath: markerURL.path),
              String(data: marker, encoding: .utf8)
                == Self.testMirrorMarkerContents else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact E31 test-mirror marker is missing."
            )
        }
        var markerAfter = stat()
        guard lstat(markerURL.path, &markerAfter) == 0,
              Self.stableIdentity(markerBefore, markerAfter) else {
            throw CodexGhostRepairError.targetDrift(
                "E31 test-mirror marker drifted during validation."
            )
        }

        self.sqliteRootURL = sqliteRoot
        self.canonicalCodexHomeDigest = try CodexGhostRepairHasher.hash(
            codexHome.path
        )
        self.sqliteRootDigest = try CodexGhostRepairHasher.hash(sqliteRoot.path)
    }

    func fingerprint() throws -> [CodexGhostRepairSnapshotFileEvidence] {
        try CodexGhostRepairCanonicalSourceFile.allCases.map { file in
            try inspect(file: file, retainBytes: false).evidence
        }
    }

    func rawRead(
        _ file: CodexGhostRepairCanonicalSourceFile,
        afterOpenForTesting: (() throws -> Void)? = nil
    ) throws -> CodexGhostRepairCanonicalSourceRead? {
        let result = try inspect(
            file: file,
            retainBytes: true,
            afterOpenForTesting: afterOpenForTesting
        )
        guard result.evidence.exists else { return nil }
        return CodexGhostRepairCanonicalSourceRead(
            evidence: result.evidence,
            bytes: result.bytes
        )
    }

    /// Streams one fixed source file without exposing its path or granting a
    /// destination write capability. The caller owns the raw-byte consumer.
    @discardableResult
    func streamRawRead(
        _ file: CodexGhostRepairCanonicalSourceFile,
        expected: CodexGhostRepairSnapshotFileEvidence,
        consume: @escaping (Data) throws -> Void
    ) throws -> CodexGhostRepairSnapshotFileEvidence {
        let result = try inspect(
            file: file,
            retainBytes: false,
            expected: expected,
            consume: consume
        )
        guard result.evidence == expected else {
            throw CodexGhostRepairError.targetDrift(
                "Canonical source drifted during stream: \(file.rawValue)."
            )
        }
        return result.evidence
    }

    private func inspect(
        file: CodexGhostRepairCanonicalSourceFile,
        retainBytes: Bool,
        expected: CodexGhostRepairSnapshotFileEvidence? = nil,
        consume: ((Data) throws -> Void)? = nil,
        afterOpenForTesting: (() throws -> Void)? = nil
    ) throws -> (evidence: CodexGhostRepairSnapshotFileEvidence, bytes: Data) {
        let url = sqliteRootURL.appendingPathComponent(file.rawValue)
        var pathStatus = stat()
        if lstat(url.path, &pathStatus) != 0 {
            guard errno == ENOENT, !file.isRequiredDatabase else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Required canonical source file is unavailable: \(file.rawValue)"
                )
            }
            return (
                CodexGhostRepairSnapshotFileEvidence(
                    fileName: file.rawValue,
                    exists: false,
                    device: nil,
                    inode: nil,
                    mode: nil,
                    size: nil,
                    modificationSeconds: nil,
                    modificationNanoseconds: nil,
                    sha256: nil
                ),
                Data()
            )
        }
        try Self.validateFileStatus(pathStatus, fileName: file.rawValue)

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical source could not open \(file.rawValue) for raw read."
            )
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              Self.sameObject(pathStatus, openedStatus) else {
            throw CodexGhostRepairError.targetDrift(
                "Canonical source identity drifted while opening \(file.rawValue)."
            )
        }
        try Self.validateFileStatus(openedStatus, fileName: file.rawValue)
        if let expected,
           !Self.stableIdentity(openedStatus, expected) {
            throw CodexGhostRepairError.targetDrift(
                "Canonical source identity drifted before stream: \(file.rawValue)."
            )
        }
        try afterOpenForTesting?()

        var bytes = Data()
        if retainBytes, openedStatus.st_size > 0 {
            guard UInt64(openedStatus.st_size) <= UInt64(Int.max) else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Canonical source is too large for bounded raw read: \(file.rawValue)"
                )
            }
            bytes.reserveCapacity(Int(openedStatus.st_size))
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Canonical source raw read failed: \(file.rawValue)"
                )
            }
            if count == 0 { break }
            let chunk = Data(buffer[0..<count])
            hasher.update(data: chunk)
            if retainBytes { bytes.append(chunk) }
            try consume?(chunk)
        }

        var afterStatus = stat()
        var currentPathStatus = stat()
        guard fstat(descriptor, &afterStatus) == 0,
              lstat(url.path, &currentPathStatus) == 0,
              Self.stableIdentity(openedStatus, afterStatus),
              Self.sameObject(afterStatus, currentPathStatus) else {
            throw CodexGhostRepairError.targetDrift(
                "Canonical source drifted during raw read: \(file.rawValue)."
            )
        }
        let digest = "sha256:" + hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return (
            CodexGhostRepairSnapshotFileEvidence(
                fileName: file.rawValue,
                exists: true,
                device: UInt64(afterStatus.st_dev),
                inode: UInt64(afterStatus.st_ino),
                mode: UInt32(afterStatus.st_mode),
                size: UInt64(afterStatus.st_size),
                modificationSeconds: Int64(afterStatus.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(afterStatus.st_mtimespec.tv_nsec),
                sha256: digest
            ),
            bytes
        )
    }

    private static func validateDirectory(_ url: URL, label: String) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & S_IRUSR) != 0,
              (status.st_mode & S_IXUSR) != 0,
              (status.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "\(label) must be an owner-controlled, non-symlink directory."
            )
        }
    }

    private static func validateFileStatus(_ status: stat, fileName: String) throws {
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & S_IRUSR) != 0,
              (status.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              status.st_size >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical source must be an owner-controlled regular file: \(fileName)"
            )
        }
    }

    private static func sameObject(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private static func stableIdentity(_ first: stat, _ second: stat) -> Bool {
        sameObject(first, second)
            && first.st_mode == second.st_mode
            && first.st_uid == second.st_uid
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
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

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return candidate.path.hasPrefix(prefix)
    }

    func validate(
        separatedFrom destination: CodexGhostRepairDisposableSnapshotDestination
    ) throws {
        let sourceRoot = sqliteRootURL.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let destinationRoot = destination.storageRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard sourceRoot.path != destinationRoot.path,
              !Self.isDescendant(sourceRoot, of: destinationRoot),
              !Self.isDescendant(destinationRoot, of: sourceRoot) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical source and manager snapshot destination must be disjoint."
            )
        }
    }

    func validate(
        separatedFrom destination: StateStoreLocation.GhostRepairDestinationLocation
    ) throws {
        let sourceRoot = sqliteRootURL.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let destinationRoot = destination.storageRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard sourceRoot.path != destinationRoot.path,
              !Self.isDescendant(sourceRoot, of: destinationRoot),
              !Self.isDescendant(destinationRoot, of: sourceRoot) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical source and resolved manager destination must be disjoint."
            )
        }
    }
}
#endif
