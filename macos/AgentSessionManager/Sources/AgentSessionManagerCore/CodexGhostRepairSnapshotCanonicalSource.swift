import CryptoKit
import Darwin
import Foundation

enum CodexGhostRepairSnapshotSourceLayout {
    static let identifier = "codex-cli-0.149.0-paginated-v1"

    static func supports(runtimeVersion: String) -> Bool {
        let normalized = runtimeVersion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized == "0.149.0"
            || normalized == "codex-cli 0.149.0"
            || normalized == "0.151.0"
            || normalized == "codex-cli 0.151.0"
            || normalized == "0.151.0-alpha.7.2"
            || normalized == "codex-cli 0.151.0-alpha.7.2"
            || normalized == "0.152.1"
            || normalized == "codex-cli 0.152.1"
            || normalized == "0.153.1"
            || normalized == "codex-cli 0.153.1"
            || normalized == "0.153.2"
            || normalized == "codex-cli 0.153.2"
            || normalized == "0.153.4"
            || normalized == "codex-cli 0.153.4"
    }
}

/// Exact packaged source identities admitted by the snapshot pipeline.
///
/// A caller can select only one of these packaged values; it cannot supply a
/// layout string, schema identifier, owner, member list, or path. Equal member
/// names therefore do not make two Desktop generations interchangeable.
struct CodexGhostRepairSnapshotSourceProfile: Equatable, Sendable {
    let identifier: String
    let ownerRuntimeProfileIdentifier: String
    let databaseSchemaProfileIdentifier: String
    let layoutDigest: String
    let files: [CodexGhostRepairSnapshotCanonicalFile]

    private init(
        identifier: String,
        ownerRuntimeProfileIdentifier: String,
        databaseSchemaProfileIdentifier: String,
        layoutDigest: String
    ) {
        self.identifier = identifier
        self.ownerRuntimeProfileIdentifier = ownerRuntimeProfileIdentifier
        self.databaseSchemaProfileIdentifier = databaseSchemaProfileIdentifier
        self.layoutDigest = layoutDigest
        files = CodexGhostRepairSnapshotCanonicalFile.allCases
    }

    static let v149DesktopV32 = Self(
        identifier: CodexGhostRepairSnapshotSourceLayout.identifier,
        ownerRuntimeProfileIdentifier: "desktop-bundled-0.149.0",
        databaseSchemaProfileIdentifier: "desktop-v32",
        layoutDigest:
            "sha256:964e20ef7a5b1b107f875ca119d5a5b8abf0b753156ac7554165df6ac86f13d5"
    )

    static let v151DesktopV33 = Self(
        identifier: CodexGhostRepairPackagedReadOnlyProfileCatalog
            .v151SourceLayoutIdentifier,
        ownerRuntimeProfileIdentifier: "desktop-bundled-0.151.0-alpha.7.2",
        databaseSchemaProfileIdentifier: "desktop-v33",
        layoutDigest:
            "sha256:75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85"
    )

    static let v152DesktopV34 = Self(
        identifier: CodexGhostRepairPackagedReadOnlyProfileCatalog
            .v152SourceLayoutIdentifier,
        ownerRuntimeProfileIdentifier: "desktop-bundled-0.152.1",
        databaseSchemaProfileIdentifier: "desktop-v34",
        layoutDigest:
            "sha256:75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85"
    )

    /// Current exact pair: Desktop owns the v34 source at 0.153.1 while the
    /// separately installed provider runtime is 0.153.2.
    static let v153DesktopV34 = Self(
        identifier: CodexGhostRepairPackagedReadOnlyProfileCatalog
            .v153SourceLayoutIdentifier,
        ownerRuntimeProfileIdentifier: "desktop-bundled-0.153.1",
        databaseSchemaProfileIdentifier: "desktop-v34",
        layoutDigest:
            "sha256:75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85"
    )

    /// Current exact pair: Desktop and the separately installed provider both
    /// report 0.153.4, but the Desktop-owned source remains a distinct identity.
    static let v1534DesktopV34 = Self(
        identifier: CodexGhostRepairPackagedReadOnlyProfileCatalog
            .v1534SourceLayoutIdentifier,
        ownerRuntimeProfileIdentifier: "desktop-bundled-0.153.4",
        databaseSchemaProfileIdentifier: "desktop-v34",
        layoutDigest:
            "sha256:75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85"
    )

    static func admitted(sourceLayoutIdentifier: String) -> Self? {
        switch sourceLayoutIdentifier {
        case v149DesktopV32.identifier: v149DesktopV32
        case v151DesktopV33.identifier: v151DesktopV33
        case v152DesktopV34.identifier: v152DesktopV34
        case v153DesktopV34.identifier: v153DesktopV34
        case v1534DesktopV34.identifier: v1534DesktopV34
        default: nil
        }
    }

    func supports(runtimeVersion: String) -> Bool {
        let normalized = runtimeVersion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        switch identifier {
        case Self.v149DesktopV32.identifier:
            return normalized == "0.149.0"
                || normalized == "codex-cli 0.149.0"
        case Self.v151DesktopV33.identifier:
            return normalized == "0.151.0"
                || normalized == "codex-cli 0.151.0"
                || normalized == "0.151.0-alpha.7.2"
                || normalized == "codex-cli 0.151.0-alpha.7.2"
        case Self.v152DesktopV34.identifier:
            return normalized == "0.152.1"
                || normalized == "codex-cli 0.152.1"
        case Self.v153DesktopV34.identifier:
            return normalized == "0.153.1"
                || normalized == "codex-cli 0.153.1"
                || normalized == "0.153.2"
                || normalized == "codex-cli 0.153.2"
        case Self.v1534DesktopV34.identifier:
            return normalized == "0.153.4"
                || normalized == "codex-cli 0.153.4"
        default:
            return false
        }
    }

    func validates(
        files evidence: [CodexGhostRepairSnapshotCanonicalFileEvidence]
    ) -> Bool {
        evidence.map(\.fileName) == files.map(\.rawValue)
            && Set(evidence.map(\.fileName)).count == evidence.count
    }

    func admits(
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    ) -> Bool {
        CodexGhostRepairDatabaseSchemaProfile.admitted(databases: databases)?
            .identifier == databaseSchemaProfileIdentifier
    }
}

/// The only Codex-owned files that the packaged Ghost Repair snapshot source
/// can read. Neither the App nor a caller can extend this set at runtime.
enum CodexGhostRepairSnapshotCanonicalFile: String, CaseIterable, Sendable {
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
    case state = "state_5.sqlite"
    case stateWAL = "state_5.sqlite-wal"
    case stateSHM = "state_5.sqlite-shm"
    case stateJournal = "state_5.sqlite-journal"
    case threadHistory = "thread_history_1.sqlite"
    case threadHistoryWAL = "thread_history_1.sqlite-wal"
    case threadHistorySHM = "thread_history_1.sqlite-shm"
    case threadHistoryJournal = "thread_history_1.sqlite-journal"

    var isRequiredDatabase: Bool {
        switch self {
        case .desktop, .summaries, .state, .threadHistory: true
        default: false
        }
    }

    /// SQLite's WAL index is coordination state, not durable database content.
    /// Opening a database read-only can create or update this file, so target
    /// inspection must not interpret SHM byte changes as source mutation.
    var isVolatileSharedMemory: Bool {
        switch self {
        case .desktopSHM, .summariesSHM, .historySHM, .stateSHM,
             .threadHistorySHM:
            true
        default:
            false
        }
    }

    private var isCodexHomeFile: Bool {
        switch self {
        case .state, .stateWAL, .stateSHM, .stateJournal,
             .threadHistory, .threadHistoryWAL, .threadHistorySHM,
             .threadHistoryJournal:
            true
        default:
            false
        }
    }

    func sourceURL(codexHomeURL: URL, sqliteRootURL: URL) -> URL {
        (isCodexHomeFile ? codexHomeURL : sqliteRootURL)
            .appendingPathComponent(rawValue, isDirectory: false)
    }
}

struct CodexGhostRepairSnapshotCanonicalFileEvidence:
    Codable,
    Hashable,
    Sendable
{
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

struct CodexGhostRepairSnapshotCanonicalFingerprint:
    Codable,
    Hashable,
    Sendable
{
    private struct Payload: Codable, Hashable {
        let sourceLayoutIdentifier: String
        let sourceRootDigest: String
        let files: [CodexGhostRepairSnapshotCanonicalFileEvidence]
    }

    let sourceLayoutIdentifier: String
    let sourceRootDigest: String
    let files: [CodexGhostRepairSnapshotCanonicalFileEvidence]
    let fingerprintHash: String

    init(
        profile: CodexGhostRepairSnapshotSourceProfile,
        sourceRootDigest: String,
        files: [CodexGhostRepairSnapshotCanonicalFileEvidence]
    ) throws {
        guard profile.validates(files: files) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical snapshot fingerprint member scope is invalid."
            )
        }
        let payload = Payload(
            sourceLayoutIdentifier: profile.identifier,
            sourceRootDigest: sourceRootDigest,
            files: files
        )
        sourceLayoutIdentifier = profile.identifier
        self.sourceRootDigest = sourceRootDigest
        self.files = files
        fingerprintHash = try CodexGhostRepairHasher.hash(payload)
    }

    func validateHash() throws {
        let expected = try CodexGhostRepairHasher.hash(Payload(
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            sourceRootDigest: sourceRootDigest,
            files: files
        ))
        guard let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
                sourceLayoutIdentifier: sourceLayoutIdentifier
              ),
              profile.validates(files: files),
              expected == fingerprintHash else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical snapshot fingerprint checksum mismatch."
            )
        }
    }
}

struct CodexGhostRepairSnapshotCanonicalSourceCapabilities:
    Equatable,
    Sendable
{
    let readsFixedRawDatabaseFiles = true
    let writesCodexDatabaseFiles = false
    let acceptsCallerPath = false
    let usesSQLiteAPI = false
    let repairMutationAuthority = false
}

/// Shipping-compiled, fixed-path raw source candidate for M1 snapshots.
///
/// Production construction is lazy and performs no I/O. Explicit fingerprint
/// or stream calls resolve only the current user's canonical `~/.codex` and
/// `~/.codex/sqlite` roots. The fixed twenty-file v0.149 layout includes the
/// required `state_5.sqlite` and `thread_history_1.sqlite` stores while retaining
/// the legacy history snapshot DB as optional migration evidence. Tests use a
/// marker-protected mirror; that capability cannot authorize the real Codex home.
struct CodexGhostRepairSnapshotCanonicalSource: Sendable {
    static let testMirrorMarkerFileName =
        ".agent-session-manager-m1b2-canonical-source-mirror-v1"
    static let testMirrorMarkerContents =
        "Agent Session Manager M1b-2 test-owned canonical source mirror v1\n"

    typealias RootResolver = @Sendable () throws -> RootResolution

    struct RootResolution: Sendable {
        let codexHomeURL: URL
        let sqliteRootURL: URL
    }

    struct TestBoundary: Sendable {
        let allowedParentURL: URL
    }

    let capabilities = CodexGhostRepairSnapshotCanonicalSourceCapabilities()

#if AGENT_SESSION_MANAGER_RESEARCH
    /// Research-only proof that this capability was constructed with the
    /// marker-protected test-mirror initializer rather than `production()`.
    var researchTestMirrorOnly: Bool { testBoundary != nil }
#endif

    private let rootResolver: RootResolver
    private let testBoundary: TestBoundary?
    let profile: CodexGhostRepairSnapshotSourceProfile

    /// Path-free and zero-I/O production construction.
    static func production(
        profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32
    ) -> Self {
        Self(
            rootResolver: {
                let codexHome = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex", isDirectory: true)
                return RootResolution(
                    codexHomeURL: codexHome,
                    sqliteRootURL: codexHome.appendingPathComponent(
                        "sqlite",
                        isDirectory: true
                    )
                )
            },
            testBoundary: nil,
            profile: profile
        )
    }

    /// Deterministic acceptance seam. Construction is also zero-I/O; the
    /// marker, parent and fixed-root checks run on each explicit read action.
    init(
        testOwnedCodexHomeURL: URL,
        testOwnedAllowedParentURL: URL,
        profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32
    ) {
        rootResolver = {
            RootResolution(
                codexHomeURL: testOwnedCodexHomeURL,
                sqliteRootURL: testOwnedCodexHomeURL.appendingPathComponent(
                    "sqlite",
                    isDirectory: true
                )
            )
        }
        testBoundary = TestBoundary(
            allowedParentURL: testOwnedAllowedParentURL
        )
        self.profile = profile
    }

    private init(
        rootResolver: @escaping RootResolver,
        testBoundary: TestBoundary?,
        profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32
    ) {
        self.rootResolver = rootResolver
        self.testBoundary = testBoundary
        self.profile = profile
    }

    func fingerprint() throws
        -> CodexGhostRepairSnapshotCanonicalFingerprint
    {
        let roots = try validatedRoots()
        let files = try profile.files.map {
            try inspect(
                $0,
                roots: roots,
                expected: nil,
                consume: nil,
                afterOpenForTesting: nil
            )
        }
        return try CodexGhostRepairSnapshotCanonicalFingerprint(
            profile: profile,
            sourceRootDigest: try CodexGhostRepairHasher.hash(
                roots.codexHomeURL.path
            ),
            files: files
        )
    }

    /// Streams one member of the fixed set without exposing its URL or giving
    /// the source any destination-write capability.
    @discardableResult
    func streamRawRead(
        _ file: CodexGhostRepairSnapshotCanonicalFile,
        expected: CodexGhostRepairSnapshotCanonicalFileEvidence,
        consume: @escaping (Data) throws -> Void,
        afterOpenForTesting: (() throws -> Void)? = nil
    ) throws -> CodexGhostRepairSnapshotCanonicalFileEvidence {
        guard expected.exists,
              expected.fileName == file.rawValue else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical snapshot stream requires matching existing evidence."
            )
        }
        let roots = try validatedRoots()
        let observed = try inspect(
            file,
            roots: roots,
            expected: expected,
            consume: consume,
            afterOpenForTesting: afterOpenForTesting
        )
        guard observed == expected else {
            throw CodexGhostRepairError.targetDrift(
                "Canonical snapshot source drifted during raw read."
            )
        }
        return observed
    }

    private func validatedRoots() throws -> RootResolution {
        let resolved = try rootResolver()
        let codexHome = resolved.codexHomeURL.standardizedFileURL
        let sqliteRoot = resolved.sqliteRootURL.standardizedFileURL
        try Self.validateDirectory(codexHome, label: "canonical Codex home")
        try Self.validateDirectory(sqliteRoot, label: "canonical sqlite root")

        let expectedSQLiteRoot = codexHome.appendingPathComponent(
            "sqlite",
            isDirectory: true
        ).standardizedFileURL
        guard sqliteRoot.path == expectedSQLiteRoot.path else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical snapshot source must use the fixed sqlite root."
            )
        }

        if let testBoundary {
            let allowedParent = testBoundary.allowedParentURL.standardizedFileURL
            try Self.validateDirectory(
                allowedParent,
                label: "test-owned allowed parent"
            )
            guard codexHome.path != allowedParent.path,
                  Self.isDescendant(codexHome, of: allowedParent) else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Canonical snapshot mirror escaped its test-owned parent."
                )
            }
            let liveCodexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .standardizedFileURL
            guard codexHome.path != liveCodexHome.path,
                  !Self.isDescendant(codexHome, of: liveCodexHome) else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Live ~/.codex is unavailable to the test mirror capability."
                )
            }
            try Self.validateTestMarker(in: codexHome)
        } else {
            let expectedCodexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .standardizedFileURL
            guard codexHome.path == expectedCodexHome.path else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Production snapshot source did not resolve canonical ~/.codex."
                )
            }
        }

        return RootResolution(
            codexHomeURL: codexHome,
            sqliteRootURL: sqliteRoot
        )
    }

    private func inspect(
        _ file: CodexGhostRepairSnapshotCanonicalFile,
        roots: RootResolution,
        expected: CodexGhostRepairSnapshotCanonicalFileEvidence?,
        consume: ((Data) throws -> Void)?,
        afterOpenForTesting: (() throws -> Void)?
    ) throws -> CodexGhostRepairSnapshotCanonicalFileEvidence {
        let url = file.sourceURL(
            codexHomeURL: roots.codexHomeURL,
            sqliteRootURL: roots.sqliteRootURL
        )
        var pathStatus = stat()
        if lstat(url.path, &pathStatus) != 0 {
            guard errno == ENOENT, !file.isRequiredDatabase else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Required canonical snapshot source file is unavailable: \(file.rawValue)."
                )
            }
            return CodexGhostRepairSnapshotCanonicalFileEvidence(
                fileName: file.rawValue,
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
        try Self.validateFile(pathStatus)

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical snapshot source could not open a fixed file."
            )
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              Self.sameObject(pathStatus, openedStatus) else {
            throw CodexGhostRepairError.targetDrift(
                "Canonical snapshot source identity drifted while opening."
            )
        }
        try Self.validateFile(openedStatus)
        if let expected,
           !Self.stableIdentity(openedStatus, expected) {
            throw CodexGhostRepairError.targetDrift(
                "Canonical snapshot source drifted before raw read."
            )
        }
        try afterOpenForTesting?()

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Canonical snapshot raw read failed."
                )
            }
            if count == 0 { break }
            let chunk = Data(buffer[0..<count])
            hasher.update(data: chunk)
            try consume?(chunk)
        }

        var afterStatus = stat()
        var currentPathStatus = stat()
        guard fstat(descriptor, &afterStatus) == 0,
              lstat(url.path, &currentPathStatus) == 0,
              Self.stableIdentity(openedStatus, afterStatus),
              Self.sameObject(afterStatus, currentPathStatus) else {
            throw CodexGhostRepairError.targetDrift(
                "Canonical snapshot source drifted during raw read."
            )
        }
        return CodexGhostRepairSnapshotCanonicalFileEvidence(
            fileName: file.rawValue,
            exists: true,
            device: UInt64(afterStatus.st_dev),
            inode: UInt64(afterStatus.st_ino),
            mode: UInt32(afterStatus.st_mode),
            size: UInt64(afterStatus.st_size),
            modificationSeconds: Int64(afterStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(afterStatus.st_mtimespec.tv_nsec),
            sha256: "sha256:" + hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private static func validateDirectory(_ url: URL, label: String) throws {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFDIR,
              pathStatus.st_uid == geteuid(),
              (pathStatus.st_mode & S_IRUSR) != 0,
              (pathStatus.st_mode & S_IXUSR) != 0,
              (pathStatus.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "\(label) must be an owner-controlled real directory."
            )
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "\(label) could not be opened without following links."
            )
        }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              sameObject(pathStatus, openedStatus) else {
            throw CodexGhostRepairError.targetDrift(
                "\(label) identity drifted during validation."
            )
        }
    }

    private static func validateTestMarker(in codexHome: URL) throws {
        let markerURL = codexHome.appendingPathComponent(
            testMirrorMarkerFileName,
            isDirectory: false
        )
        var before = stat()
        guard lstat(markerURL.path, &before) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact M1b-2 test-mirror marker is missing."
            )
        }
        try validateFile(before)
        let descriptor = Darwin.open(markerURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact M1b-2 test-mirror marker is unreadable."
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameObject(before, opened),
              opened.st_size >= 0,
              opened.st_size <= 4_096 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact M1b-2 test-mirror marker is invalid."
            )
        }
        var markerBuffer = [UInt8](repeating: 0, count: 4_097)
        let markerCount = Darwin.read(
            descriptor,
            &markerBuffer,
            markerBuffer.count
        )
        guard markerCount >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact M1b-2 test-mirror marker is unreadable."
            )
        }
        let markerData = Data(markerBuffer[0..<markerCount])
        guard String(data: markerData, encoding: .utf8)
                == testMirrorMarkerContents else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact M1b-2 test-mirror marker is invalid."
            )
        }
        var after = stat()
        guard lstat(markerURL.path, &after) == 0,
              stableIdentity(before, after) else {
            throw CodexGhostRepairError.targetDrift(
                "M1b-2 test-mirror marker drifted during validation."
            )
        }
    }

    private static func validateFile(_ status: stat) throws {
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & S_IRUSR) != 0,
              (status.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              status.st_size >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Canonical snapshot source requires owner-controlled regular files."
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
        _ evidence: CodexGhostRepairSnapshotCanonicalFileEvidence
    ) -> Bool {
        evidence.exists
            && UInt64(status.st_dev) == evidence.device
            && UInt64(status.st_ino) == evidence.inode
            && UInt32(status.st_mode) == evidence.mode
            && status.st_size >= 0
            && UInt64(status.st_size) == evidence.size
            && Int64(status.st_mtimespec.tv_sec)
                == evidence.modificationSeconds
            && Int64(status.st_mtimespec.tv_nsec)
                == evidence.modificationNanoseconds
    }

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return candidate.path.hasPrefix(prefix)
    }
}
