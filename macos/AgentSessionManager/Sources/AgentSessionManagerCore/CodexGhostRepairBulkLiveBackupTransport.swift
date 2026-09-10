import CryptoKit
import Darwin
import Foundation

struct CodexGhostRepairBulkLiveBackupTransportCapabilities:
    Equatable,
    Sendable
{
    let fixedCanonicalFileCount =
        CodexGhostRepairSnapshotCanonicalFile.allCases.count
    let productionFactoryAvailable = true
    let productionConstructionPerformsIO = false
    let productionFactoryAcceptsCallerPath = false
    let explicitActionRequired = true
    let destinationRecordWrittenBeforeRawBytes = true
    let receiptManifestWrittenLast = true
    let sourceFingerprintRequiredBeforeAndAfter = true
    let exactColdReadbackSupported = true
    let overwritesExistingOperation = false
    let retriesPartialOperation = false
    let automaticRestoreAllowed = false
    let automaticCleanupAllowed = false
    let opensSQLite = false
    let createsClaim = false
    let appWiringAvailable = false
    let liveExecutionAuthorized = false
    let repairMutationAuthority = false
}

struct CodexGhostRepairBulkLiveBackupFile:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let fileName: String
    let present: Bool
    let byteCount: UInt64?
    let contentHash: String?
}

private struct CodexGhostRepairBulkLiveBackupReceiptPayload:
    Codable,
    Hashable
{
    let formatVersion: Int
    let destinationRecordDigest: String
    let bundleDigest: String
    let maintenanceWindowDigest: String
    let sourceFingerprintHash: String
    let files: [CodexGhostRepairBulkLiveBackupFile]
    let capturedAtMilliseconds: Int64
}

struct CodexGhostRepairBulkLiveBackupReceipt:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    static let formatVersion = 1

    let formatVersion: Int
    let destinationRecordDigest: String
    let bundleDigest: String
    let maintenanceWindowDigest: String
    let sourceFingerprintHash: String
    let files: [CodexGhostRepairBulkLiveBackupFile]
    let capturedAtMilliseconds: Int64
    let receiptDigest: String

    var pathRedacted: Bool { true }
    var createsClaim: Bool { false }
    var repairMutationAuthority: Bool { false }

    init(
        destination: CodexGhostRepairBulkFixedBackupDestinationRecord,
        sourceFingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        capturedAtMilliseconds: Int64
    ) throws {
        try destination.validate()
        try sourceFingerprint.validateHash()
        let files = sourceFingerprint.files.map {
            CodexGhostRepairBulkLiveBackupFile(
                fileName: $0.fileName,
                present: $0.exists,
                byteCount: $0.size,
                contentHash: $0.sha256
            )
        }
        let payload = CodexGhostRepairBulkLiveBackupReceiptPayload(
            formatVersion: Self.formatVersion,
            destinationRecordDigest: destination.recordDigest,
            bundleDigest: destination.bundleDigest,
            maintenanceWindowDigest: destination.maintenanceWindowDigest,
            sourceFingerprintHash: sourceFingerprint.fingerprintHash,
            files: files,
            capturedAtMilliseconds: capturedAtMilliseconds
        )
        formatVersion = payload.formatVersion
        destinationRecordDigest = payload.destinationRecordDigest
        bundleDigest = payload.bundleDigest
        maintenanceWindowDigest = payload.maintenanceWindowDigest
        sourceFingerprintHash = payload.sourceFingerprintHash
        self.files = payload.files
        self.capturedAtMilliseconds = payload.capturedAtMilliseconds
        receiptDigest = try CodexGhostRepairHasher.hash(payload)
        try validate()
    }

    func validate() throws {
        let payload = CodexGhostRepairBulkLiveBackupReceiptPayload(
            formatVersion: formatVersion,
            destinationRecordDigest: destinationRecordDigest,
            bundleDigest: bundleDigest,
            maintenanceWindowDigest: maintenanceWindowDigest,
            sourceFingerprintHash: sourceFingerprintHash,
            files: files,
            capturedAtMilliseconds: capturedAtMilliseconds
        )
        let expectedNames =
            CodexGhostRepairSnapshotCanonicalFile.allCases.map(\.rawValue)
        guard formatVersion == Self.formatVersion,
              files.map(\.fileName) == expectedNames,
              files.count
                == CodexGhostRepairSnapshotCanonicalFile.allCases.count,
              zip(CodexGhostRepairSnapshotCanonicalFile.allCases, files)
                .allSatisfy({ file, evidence in
                    !file.isRequiredDatabase || evidence.present
                }),
              files.allSatisfy({ file in
                  if file.present {
                      return file.byteCount != nil
                          && Self.isSHA256(file.contentHash)
                  }
                  return file.byteCount == nil && file.contentHash == nil
              }),
              Self.isSHA256(destinationRecordDigest),
              Self.isSHA256(bundleDigest),
              Self.isSHA256(maintenanceWindowDigest),
              Self.isSHA256(sourceFingerprintHash),
              Self.isSHA256(receiptDigest),
              try CodexGhostRepairHasher.hash(payload) == receiptDigest,
              pathRedacted,
              !createsClaim,
              !repairMutationAuthority else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 operation-backup receipt is invalid."
            )
        }
    }

    /// Compares durable SQLite content while excluding WAL-index (`-shm`)
    /// coordination files. Read-only SQLite opens may legitimately create or
    /// update SHM bytes; database, WAL, and rollback-journal content remains
    /// exact unless explicitly excluded by a post-mutation caller.
    func firstStableSourceMismatch(
        in fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        excluding additionalFileNames: Set<String> = []
    ) -> String? {
        guard fingerprint.files.count == files.count else {
            return "canonical-member-set"
        }
        for (canonical, evidence) in zip(
            CodexGhostRepairSnapshotCanonicalFile.allCases,
            zip(fingerprint.files, files)
        ) {
            let (observed, expected) = evidence
            guard observed.fileName == canonical.rawValue,
                  expected.fileName == canonical.rawValue else {
                return canonical.rawValue
            }
            guard !canonical.isVolatileSharedMemory,
                  !additionalFileNames.contains(canonical.rawValue) else {
                continue
            }
            guard observed.exists == expected.present,
                  observed.size == expected.byteCount,
                  observed.sha256 == expected.contentHash else {
                return canonical.rawValue
            }
        }
        return nil
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value,
              value.hasPrefix("sha256:"),
              value == value.lowercased() else {
            return false
        }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

private struct CodexGhostRepairBulkLiveBackupRoots: Sendable {
    let storageRootURL: URL
    let operationRootURL: URL
    let storageRootDigest: String
}

/// Typed source/destination boundary for M4f-15. Production construction is
/// path-free and zero-I/O. Only an explicit inspect or create call resolves the
/// canonical Codex home and manager Application Support namespace. Tests use
/// separately marker-protected mirrors and never authorize those live roots.
actor CodexGhostRepairBulkLiveBackupEnvironment:
    CodexGhostRepairBulkFixedBackupDestinationInspecting
{
    static let destinationRecordFileName = "destination.json"
    static let receiptFileName = "receipt.json"
    static let operationBackupsDirectoryName = "OperationBackups"
    static let versionDirectoryName = "v1"

    fileprivate typealias RootResolver = @Sendable () throws
        -> CodexGhostRepairBulkLiveBackupRoots

    private let source: CodexGhostRepairSnapshotCanonicalSource
    private let rootResolver: RootResolver
    private let testOwnedManagerRootURL: URL?
    private let testOwnedAllowedParentURL: URL?
    private let nowMilliseconds: @Sendable () -> Int64
    private let afterCopiedMemberForTesting: @Sendable (Int) throws -> Void

    static func production(
        profile: CodexGhostRepairSnapshotSourceProfile,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) -> Self {
        Self(
            source: .production(profile: profile),
            rootResolver: {
                let location = try StateStoreLocation
                    .applicationSupportGhostRepairDestinationLocation()
                let operationRoot = location.storageRootURL
                    .appendingPathComponent(
                        Self.operationBackupsDirectoryName,
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        Self.versionDirectoryName,
                        isDirectory: true
                    )
                return CodexGhostRepairBulkLiveBackupRoots(
                    storageRootURL: location.storageRootURL,
                    operationRootURL: operationRoot,
                    storageRootDigest: location.storageRootDigest
                )
            },
            testOwnedManagerRootURL: nil,
            testOwnedAllowedParentURL: nil,
            nowMilliseconds: nowMilliseconds,
            afterCopiedMemberForTesting: { _ in }
        )
    }

    init(
        testOwnedCodexHomeURL: URL,
        testOwnedSourceAllowedParentURL: URL,
        testOwnedManagerRootURL: URL,
        testOwnedManagerAllowedParentURL: URL,
        profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32,
        nowMilliseconds: @escaping @Sendable () -> Int64 = { 1_000 },
        afterCopiedMemberForTesting:
            @escaping @Sendable (Int) throws -> Void = { _ in }
    ) throws {
        let managerRoot = testOwnedManagerRootURL.standardizedFileURL
        let allowedParent = testOwnedManagerAllowedParentURL.standardizedFileURL
        guard managerRoot.path != allowedParent.path,
              Self.isDescendant(managerRoot, of: allowedParent) else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f-15 manager destination escaped its test boundary."
            )
        }
        source = CodexGhostRepairSnapshotCanonicalSource(
            testOwnedCodexHomeURL: testOwnedCodexHomeURL,
            testOwnedAllowedParentURL: testOwnedSourceAllowedParentURL,
            profile: profile
        )
        rootResolver = {
            let storageRoot = managerRoot.appendingPathComponent(
                CodexGhostRepairBulkFixedBackupDestinationTestInspector
                    .ghostRepairDirectoryName,
                isDirectory: true
            )
            let operationRoot = storageRoot
                .appendingPathComponent(
                    Self.operationBackupsDirectoryName,
                    isDirectory: true
                )
                .appendingPathComponent(
                    Self.versionDirectoryName,
                    isDirectory: true
                )
            return CodexGhostRepairBulkLiveBackupRoots(
                storageRootURL: storageRoot,
                operationRootURL: operationRoot,
                storageRootDigest: try CodexGhostRepairHasher.hash(
                    storageRoot.path
                )
            )
        }
        self.testOwnedManagerRootURL = managerRoot
        testOwnedAllowedParentURL = allowedParent
        self.nowMilliseconds = nowMilliseconds
        self.afterCopiedMemberForTesting = afterCopiedMemberForTesting
    }

    private init(
        source: CodexGhostRepairSnapshotCanonicalSource,
        rootResolver: @escaping RootResolver,
        testOwnedManagerRootURL: URL?,
        testOwnedAllowedParentURL: URL?,
        nowMilliseconds: @escaping @Sendable () -> Int64,
        afterCopiedMemberForTesting:
            @escaping @Sendable (Int) throws -> Void
    ) {
        self.source = source
        self.rootResolver = rootResolver
        self.testOwnedManagerRootURL = testOwnedManagerRootURL
        self.testOwnedAllowedParentURL = testOwnedAllowedParentURL
        self.nowMilliseconds = nowMilliseconds
        self.afterCopiedMemberForTesting = afterCopiedMemberForTesting
    }

    func storageRootDigestFresh() throws -> String {
        try validatedRoots().storageRootDigest
    }

    /// Explicit manager-owned preparation for the fixed operation-backup
    /// namespace. It never touches Codex files and creates only missing 0700
    /// `OperationBackups/v1` directories under the already-private fixed
    /// GhostRepair storage root.
    func prepareFixedStorageIfNeeded() throws {
        let roots = try rootResolver()
        try Self.requirePrivateDirectory(roots.storageRootURL)
        let operationBackups = roots.operationRootURL
            .deletingLastPathComponent()
        for directory in [operationBackups, roots.operationRootURL] {
            var status = stat()
            if lstat(directory.path, &status) == 0 {
                try Self.requirePrivateDirectoryStatus(status)
                continue
            }
            guard errno == ENOENT,
                  mkdir(directory.path, S_IRWXU) == 0 else {
                throw CodexGhostRepairError.backupFailed(
                    "Fixed operation-backup storage could not be prepared."
                )
            }
            try Self.requirePrivateDirectory(directory)
            try Self.synchronizeDirectory(
                directory.deletingLastPathComponent()
            )
        }
        _ = try validatedRoots()
    }

    func inspectFresh(
        record: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) throws -> CodexGhostRepairBulkFixedBackupDestinationState {
        try record.validate()
        let roots = try validatedRoots()
        guard record.storageRootDigest == roots.storageRootDigest else {
            throw CodexGhostRepairError.authorityDrift
        }
        let destination = operationURL(record, roots: roots)
        var status = stat()
        if lstat(destination.path, &status) != 0 {
            guard errno == ENOENT else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "M4f-15 destination could not be inspected."
                )
            }
            return .available
        }
        try Self.requirePrivateDirectoryStatus(status)
        let members = try Set(FileManager.default.contentsOfDirectory(
            atPath: destination.path
        ))
        guard members == [Self.destinationRecordFileName] else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 existing destination is complete or partial; create cannot retry."
            )
        }
        let observed: CodexGhostRepairBulkFixedBackupDestinationRecord =
            try Self.decodePrivateFile(
                destination.appendingPathComponent(
                    Self.destinationRecordFileName
                )
            )
        try observed.validate()
        guard observed == record else {
            throw CodexGhostRepairError.authorityDrift
        }
        return .exactColdReadback
    }

    func createExactBackup(
        destination: CodexGhostRepairBulkFixedBackupDestinationResolution,
        maintenanceWindow: CodexGhostRepairBulkMaintenanceWindow
    ) throws -> CodexGhostRepairBulkLiveBackupReceipt {
        try destination.record.validate()
        guard destination.state == .available,
              destination.record.bundleDigest
                == maintenanceWindow.bundleDigest,
              destination.record.maintenanceWindowDigest
                == maintenanceWindow.windowDigest,
              destination.record.sourceFingerprintMatches(maintenanceWindow),
              !destination.overwriteAllowed,
              !destination.createsClaim,
              !destination.repairMutationAuthority else {
            throw CodexGhostRepairError.authorityDrift
        }
        let roots = try validatedRoots()
        guard destination.record.storageRootDigest
                == roots.storageRootDigest else {
            throw CodexGhostRepairError.authorityDrift
        }
        let operation = operationURL(destination.record, roots: roots)
        var status = stat()
        guard lstat(operation.path, &status) != 0, errno == ENOENT else {
            throw CodexGhostRepairError.recoveryRequired
        }

        let fingerprint = try source.fingerprint()
        try fingerprint.validateHash()
        guard fingerprint.fingerprintHash
                == maintenanceWindow.before.maintenance.sourceFingerprintHash,
              fingerprint.fingerprintHash
                == maintenanceWindow.after.maintenance.sourceFingerprintHash
        else {
            throw CodexGhostRepairError.authorityDrift
        }

        guard mkdir(operation.path, S_IRWXU) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 could not create the exact operation directory."
            )
        }
        try Self.requirePrivateDirectory(operation)
        try Self.writeExclusive(
            try Self.encoded(destination.record),
            to: operation.appendingPathComponent(
                Self.destinationRecordFileName
            )
        )
        try Self.synchronizeDirectory(operation)

        var copied = 0
        for (file, evidence) in zip(
            CodexGhostRepairSnapshotCanonicalFile.allCases,
            fingerprint.files
        ) where evidence.exists {
            try copy(
                file: file,
                evidence: evidence,
                destination: operation.appendingPathComponent(file.rawValue)
            )
            copied += 1
            try afterCopiedMemberForTesting(copied)
        }

        let after = try source.fingerprint()
        try after.validateHash()
        guard after == fingerprint else {
            throw CodexGhostRepairError.targetDrift(
                "M4f-15 canonical source drifted during backup."
            )
        }
        let receipt = try CodexGhostRepairBulkLiveBackupReceipt(
            destination: destination.record,
            sourceFingerprint: fingerprint,
            capturedAtMilliseconds: nowMilliseconds()
        )
        try Self.writeExclusive(
            try Self.encoded(receipt),
            to: operation.appendingPathComponent(Self.receiptFileName)
        )
        try Self.synchronizeDirectory(operation)
        try Self.synchronizeDirectory(roots.operationRootURL)
        return try loadExact(
            destination: destination.record,
            roots: roots
        )
    }

    func readExactBackup(
        destination: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) throws -> CodexGhostRepairBulkLiveBackupReceipt {
        try destination.validate()
        let roots = try validatedRoots()
        guard destination.storageRootDigest == roots.storageRootDigest else {
            throw CodexGhostRepairError.authorityDrift
        }
        return try loadExact(destination: destination, roots: roots)
    }

    private func loadExact(
        destination: CodexGhostRepairBulkFixedBackupDestinationRecord,
        roots: CodexGhostRepairBulkLiveBackupRoots
    ) throws -> CodexGhostRepairBulkLiveBackupReceipt {
        let operation = operationURL(destination, roots: roots)
        try Self.requirePrivateDirectory(operation)
        let storedDestination:
            CodexGhostRepairBulkFixedBackupDestinationRecord =
            try Self.decodePrivateFile(
                operation.appendingPathComponent(
                    Self.destinationRecordFileName
                )
            )
        let receipt: CodexGhostRepairBulkLiveBackupReceipt =
            try Self.decodePrivateFile(
                operation.appendingPathComponent(Self.receiptFileName)
            )
        try storedDestination.validate()
        try receipt.validate()
        guard storedDestination == destination,
              receipt.destinationRecordDigest == destination.recordDigest,
              receipt.bundleDigest == destination.bundleDigest,
              receipt.maintenanceWindowDigest
                == destination.maintenanceWindowDigest else {
            throw CodexGhostRepairError.authorityDrift
        }
        let expectedMembers = Set(
            receipt.files.filter(\.present).map(\.fileName)
                + [Self.destinationRecordFileName, Self.receiptFileName]
        )
        let actualMembers = try Set(FileManager.default.contentsOfDirectory(
            atPath: operation.path
        ))
        guard actualMembers == expectedMembers else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 backup membership drifted."
            )
        }
        for file in receipt.files where file.present {
            let observed = try Self.hashPrivateFile(
                operation.appendingPathComponent(file.fileName)
            )
            guard observed.byteCount == file.byteCount,
                  observed.contentHash == file.contentHash else {
                throw CodexGhostRepairError.backupFailed(
                    "M4f-15 backup durable readback drifted."
                )
            }
        }
        return receipt
    }

    private func copy(
        file: CodexGhostRepairSnapshotCanonicalFile,
        evidence: CodexGhostRepairSnapshotCanonicalFileEvidence,
        destination: URL
    ) throws {
        let descriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 could not create a fixed backup member."
            )
        }
        defer { Darwin.close(descriptor) }
        _ = try source.streamRawRead(file, expected: evidence) { data in
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw CodexGhostRepairError.backupFailed(
                            "M4f-15 raw backup write failed."
                        )
                    }
                    offset += count
                }
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 backup member was not durable."
            )
        }
        let observed = try Self.hashPrivateFile(destination)
        guard observed.byteCount == evidence.size,
              observed.contentHash == evidence.sha256 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 copied bytes do not match source evidence."
            )
        }
    }

    private func validatedRoots() throws
        -> CodexGhostRepairBulkLiveBackupRoots
    {
        let roots = try rootResolver()
        try Self.requirePrivateDirectory(roots.storageRootURL)
        try Self.requirePrivateDirectory(roots.operationRootURL)
        let expectedStorageRootDigest = try CodexGhostRepairHasher.hash(
            roots.storageRootURL.path
        )
        guard roots.operationRootURL.deletingLastPathComponent()
                .lastPathComponent == Self.operationBackupsDirectoryName,
              roots.operationRootURL.lastPathComponent
                == Self.versionDirectoryName,
              roots.storageRootDigest
                == expectedStorageRootDigest,
              Self.isDescendant(
                  roots.operationRootURL,
                  of: roots.storageRootURL
              ) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "M4f-15 fixed destination layout drifted."
            )
        }
        if let managerRoot = testOwnedManagerRootURL,
           let allowedParent = testOwnedAllowedParentURL {
            _ = try Self.testOwnedRoots(
                managerRoot: managerRoot,
                allowedParent: allowedParent,
                storageRoot: roots.storageRootURL,
                operationRoot: roots.operationRootURL
            )
        }
        return roots
    }

    private func operationURL(
        _ record: CodexGhostRepairBulkFixedBackupDestinationRecord,
        roots: CodexGhostRepairBulkLiveBackupRoots
    ) -> URL {
        roots.operationRootURL.appendingPathComponent(
            record.destinationID,
            isDirectory: true
        )
    }

    private static func testOwnedRoots(
        managerRoot: URL,
        allowedParent: URL,
        storageRoot: URL,
        operationRoot: URL
    ) throws -> CodexGhostRepairBulkLiveBackupRoots {
        try requirePrivateDirectory(allowedParent)
        try requirePrivateDirectory(managerRoot)
        guard managerRoot.path != allowedParent.path,
              isDescendant(managerRoot, of: allowedParent) else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f-15 test destination escaped its allowed parent."
            )
        }
        let liveApplicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.standardizedFileURL
        guard liveApplicationSupport?.path != managerRoot.path,
              liveApplicationSupport.map({
                  !isDescendant(managerRoot, of: $0)
              }) ?? true else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "Live Application Support is unavailable to M4f-15 tests."
            )
        }
        let marker = managerRoot.appendingPathComponent(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector
                .markerFileName
        )
        try requirePrivateRegularFile(marker)
        guard try String(contentsOf: marker, encoding: .utf8)
                == CodexGhostRepairBulkFixedBackupDestinationTestInspector
                    .markerContents else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f-15 destination marker is invalid."
            )
        }
        try requirePrivateDirectory(storageRoot)
        try requirePrivateDirectory(operationRoot)
        return CodexGhostRepairBulkLiveBackupRoots(
            storageRootURL: storageRoot,
            operationRootURL: operationRoot,
            storageRootDigest: try CodexGhostRepairHasher.hash(storageRoot.path)
        )
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decodePrivateFile<T: Decodable>(
        _ url: URL
    ) throws -> T {
        try requirePrivateRegularFile(url)
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 durable record already exists."
            )
        }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw CodexGhostRepairError.backupFailed(
                        "M4f-15 durable record write failed."
                    )
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 durable record was not synchronized."
            )
        }
    }

    private static func hashPrivateFile(
        _ url: URL
    ) throws -> (byteCount: UInt64, contentHash: String) {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 backup member could not be read back."
            )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0,
              status.st_size >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 backup member is not owner-private."
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw CodexGhostRepairError.backupFailed(
                    "M4f-15 backup readback failed."
                )
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return (
            UInt64(status.st_size),
            "sha256:" + hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "M4f-15 private directory is unavailable."
            )
        }
        try requirePrivateDirectoryStatus(status)
    }

    private static func requirePrivateDirectoryStatus(_ status: stat) throws {
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "M4f-15 private directory identity or permission is unsafe."
            )
        }
    }

    private static func requirePrivateRegularFile(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "M4f-15 private record is unavailable or unsafe."
            )
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 backup directory could not be synchronized."
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-15 backup directory synchronization failed."
            )
        }
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentParts = parent.standardizedFileURL.pathComponents
        let childParts = child.standardizedFileURL.pathComponents
        return childParts.count > parentParts.count
            && childParts.prefix(parentParts.count) == parentParts[...]
    }
}

actor CodexGhostRepairBulkLiveBackupTransport {
    nonisolated let capabilities =
        CodexGhostRepairBulkLiveBackupTransportCapabilities()

    private let resolution: CodexGhostRepairBulkProductionBundle.Resolution
    private let maintenanceWindow: CodexGhostRepairBulkMaintenanceWindow
    private let environment: CodexGhostRepairBulkLiveBackupEnvironment
    private var operationInProgress = false

    static func production(
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        maintenanceWindow: CodexGhostRepairBulkMaintenanceWindow
    ) throws -> Self {
        guard let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
            sourceLayoutIdentifier: resolution.sourceLayoutIdentifier
        ) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk backup source layout is not packaged."
            )
        }
        return try Self(
            resolution: resolution,
            maintenanceWindow: maintenanceWindow,
            environment: .production(profile: profile)
        )
    }

    init(
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        maintenanceWindow: CodexGhostRepairBulkMaintenanceWindow,
        environment: CodexGhostRepairBulkLiveBackupEnvironment
    ) throws {
        guard resolution.bundleDigest == maintenanceWindow.bundleDigest,
              maintenanceWindow.before.requestID == resolution.requestID,
              maintenanceWindow.after.requestID == resolution.requestID,
              !resolution.createsClaim,
              !resolution.repairMutationAuthority,
              !maintenanceWindow.createsClaim,
              !maintenanceWindow.repairMutationAuthority else {
            throw CodexGhostRepairError.authorityDrift
        }
        self.resolution = resolution
        self.maintenanceWindow = maintenanceWindow
        self.environment = environment
    }

    func inspectFreshDestination()
        async throws -> CodexGhostRepairBulkFixedBackupDestinationResolution
    {
        let resolver = try CodexGhostRepairBulkFixedBackupDestinationResolver(
            resolution: resolution,
            maintenanceWindow: maintenanceWindow,
            inspector: environment
        )
        return try await resolver.inspectFresh()
    }

    func prepareFixedStorageIfNeeded() async throws {
        try await environment.prepareFixedStorageIfNeeded()
    }

    func createExactBackup(
        destination: CodexGhostRepairBulkFixedBackupDestinationResolution
    ) async throws -> CodexGhostRepairBulkLiveBackupReceipt {
        guard !operationInProgress else {
            throw CodexGhostRepairError.recoveryRequired
        }
        operationInProgress = true
        defer { operationInProgress = false }

        let fresh = try await inspectFreshDestination()
        guard fresh == destination,
              fresh.state == .available else {
            throw CodexGhostRepairError.authorityDrift
        }
        return try await environment.createExactBackup(
            destination: fresh,
            maintenanceWindow: maintenanceWindow
        )
    }

    func readExactBackup(
        destination: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) async throws -> CodexGhostRepairBulkLiveBackupReceipt {
        try await environment.readExactBackup(destination: destination)
    }
}

/// Cold readback of one already-published operation backup. Construction is
/// caller-path-free and performs no I/O; the exact manager namespace is
/// resolved only when the one-shot executor asks for readback.
actor CodexGhostRepairBulkLiveProductionBackupReader:
    CodexGhostRepairBulkLiveMixedBackupReading
{
    private let environment: CodexGhostRepairBulkLiveBackupEnvironment

    static func production(
        sourceLayoutIdentifier: String
    ) throws -> Self {
        guard let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
            sourceLayoutIdentifier: sourceLayoutIdentifier
        ) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk backup readback source layout is not packaged."
            )
        }
        return Self(environment: .production(profile: profile))
    }

    private init(environment: CodexGhostRepairBulkLiveBackupEnvironment) {
        self.environment = environment
    }

    func readExactBackup(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan
    ) async throws -> CodexGhostRepairBulkLiveBackupReceipt {
        let receipt = try await environment.readExactBackup(
            destination: plan.destination
        )
        guard receipt == plan.backup else {
            throw CodexGhostRepairError.backupFailed(
                "Bulk operation backup cold readback drifted."
            )
        }
        return receipt
    }
}

private extension CodexGhostRepairBulkFixedBackupDestinationRecord {
    func sourceFingerprintMatches(
        _ window: CodexGhostRepairBulkMaintenanceWindow
    ) -> Bool {
        window.before.maintenance.sourceFingerprintHash
            == window.after.maintenance.sourceFingerprintHash
    }
}
