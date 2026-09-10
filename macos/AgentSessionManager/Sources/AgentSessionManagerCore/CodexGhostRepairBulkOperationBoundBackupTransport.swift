import CryptoKit
import Darwin
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH

protocol CodexGhostRepairBulkOperationBoundBackupReading: Sendable {
    func readExactBackup(
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) async throws -> CodexGhostRepairBulkExecutionBackupReceipt
}

struct CodexGhostRepairBulkOperationBoundBackupTransportCapabilities:
    Equatable,
    Sendable
{
    let fixedCanonicalFileCount =
        CodexGhostRepairSnapshotCanonicalFile.allCases.count
    let markerProtectedTestMirrorsOnly = true
    let manifestWrittenLast = true
    let exactOperationReadback = true
    let overwritesExistingOperation = false
    let retriesPartialOperation = false
    let automaticRestoreAllowed = false
    let automaticCleanupAllowed = false
    let acceptsLiveCodexRoot = false
    let appWiringAvailable = false
    let repairMutationAuthority = false
}

/// Test-owned implementation of the exact operation-bound backup seam used by
/// the M4f production-draft collector. The source can only be the fixed,
/// marker-protected canonical mirror capability. The destination is a separate
/// marker-protected manager mirror. Existing operation directories are never
/// overwritten: a complete one is read back and a partial one fails closed.
actor CodexGhostRepairBulkOperationBoundBackupTransport:
    CodexGhostRepairBulkOperationBoundBackupCreating,
    CodexGhostRepairBulkOperationBoundBackupReading
{
    static let markerFileName =
        ".agent-session-manager-m4f-bulk-backup-mirror-v1"
    static let markerContents =
        "Agent Session Manager M4f bulk backup mirror v1\n"
    static let backupDirectoryName = "m4f-bulk-operation-backups"
    static let manifestFileName = "receipt.json"

    nonisolated let capabilities =
        CodexGhostRepairBulkOperationBoundBackupTransportCapabilities()

    private let source: CodexGhostRepairSnapshotCanonicalSource
    private let backupRootURL: URL
    private let nowMilliseconds: @Sendable () -> Int64

    init(
        source: CodexGhostRepairSnapshotCanonicalSource,
        testOwnedManagerRootURL: URL,
        testOwnedAllowedParentURL: URL,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) throws {
        guard source.researchTestMirrorOnly else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f bulk backup transport requires the test-mirror source capability."
            )
        }
        let root = testOwnedManagerRootURL.standardizedFileURL
        let parent = testOwnedAllowedParentURL.standardizedFileURL
        let liveCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
        guard root.path != parent.path,
              Self.isDescendant(root, of: parent),
              root.path != liveCodexHome.path,
              !Self.isDescendant(root, of: liveCodexHome) else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f manager backup root escaped its test-owned boundary."
            )
        }
        try Self.requirePrivateDirectory(root)
        let marker = root.appendingPathComponent(Self.markerFileName)
        try Self.requirePrivateRegularFile(marker)
        guard try String(contentsOf: marker, encoding: .utf8)
                == Self.markerContents else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f manager backup marker is missing or invalid."
            )
        }
        let backups = root.appendingPathComponent(
            Self.backupDirectoryName,
            isDirectory: true
        )
        try Self.requirePrivateDirectory(backups)
        self.source = source
        backupRootURL = backups
        self.nowMilliseconds = nowMilliseconds
    }

    func createOrReadExactBackup(
        plan: CodexGhostRepairBulkExecutionPlan,
        maintenance: CodexGhostRepairBulkMaintenanceEvidence
    ) throws -> CodexGhostRepairBulkExecutionBackupReceipt {
        try plan.validateDigest()
        try maintenance.validate()
        try Self.requirePrivateDirectory(backupRootURL)

        let destination = operationURL(plan.operationID)
        if FileManager.default.fileExists(atPath: destination.path) {
            return try loadExact(
                operationID: plan.operationID,
                plan: plan,
                sourceFingerprintHash: maintenance.sourceFingerprintHash
            )
        }

        let fingerprint = try source.fingerprint()
        try fingerprint.validateHash()
        guard fingerprint.fingerprintHash
                == maintenance.sourceFingerprintHash else {
            throw CodexGhostRepairError.authorityDrift
        }

        guard mkdir(destination.path, S_IRWXU) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f could not create the exact operation backup directory."
            )
        }
        try Self.requirePrivateDirectory(destination)

        for (file, evidence) in zip(
            CodexGhostRepairSnapshotCanonicalFile.allCases,
            fingerprint.files
        ) where evidence.exists {
            try copy(
                file: file,
                evidence: evidence,
                destination: destination.appendingPathComponent(file.rawValue)
            )
        }

        let after = try source.fingerprint()
        try after.validateHash()
        guard after == fingerprint else {
            throw CodexGhostRepairError.targetDrift(
                "M4f canonical source drifted while the operation backup was copied."
            )
        }

        let files = fingerprint.files.map {
            CodexGhostRepairBulkExecutionBackupFile(
                fileName: $0.fileName,
                present: $0.exists,
                byteCount: $0.size,
                contentHash: $0.sha256
            )
        }
        let receipt = try CodexGhostRepairBulkExecutionBackupReceipt(
            operationID: plan.operationID,
            planDigest: plan.planDigest,
            selectedThreadIDs: plan.selectedThreadIDs,
            sourceFingerprintHash: fingerprint.fingerprintHash,
            files: files,
            capturedAtMilliseconds: nowMilliseconds()
        )
        try writeManifestLast(receipt, in: destination)
        try Self.synchronizeDirectory(destination)
        try Self.synchronizeDirectory(backupRootURL)
        return try loadExact(
            operationID: plan.operationID,
            plan: plan,
            sourceFingerprintHash: maintenance.sourceFingerprintHash
        )
    }

    func readExactBackup(
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) throws -> CodexGhostRepairBulkExecutionBackupReceipt {
        try draft.validate()
        let receipt = try loadExact(
            operationID: draft.operationID,
            plan: draft.plan,
            sourceFingerprintHash: draft.backup.sourceFingerprintHash
        )
        guard receipt == draft.backup else {
            throw CodexGhostRepairError.backupFailed(
                "M4f durable backup no longer matches the exact draft."
            )
        }
        return receipt
    }

    private func loadExact(
        operationID: UUID,
        plan: CodexGhostRepairBulkExecutionPlan,
        sourceFingerprintHash: String
    ) throws -> CodexGhostRepairBulkExecutionBackupReceipt {
        let directory = operationURL(operationID)
        try Self.requirePrivateDirectory(directory)
        let manifest = directory.appendingPathComponent(Self.manifestFileName)
        try Self.requirePrivateRegularFile(manifest)
        let data = try Data(contentsOf: manifest)
        let receipt = try JSONDecoder().decode(
            CodexGhostRepairBulkExecutionBackupReceipt.self,
            from: data
        )
        try receipt.validate()
        guard receipt.operationID == operationID,
              receipt.operationID == plan.operationID,
              receipt.planDigest == plan.planDigest,
              receipt.selectedThreadIDs == plan.selectedThreadIDs,
              receipt.sourceFingerprintHash == sourceFingerprintHash else {
            throw CodexGhostRepairError.authorityDrift
        }

        let expectedMembers = Set(
            receipt.files.filter(\.present).map(\.fileName)
                + [Self.manifestFileName]
        )
        let actualMembers = try Set(FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ))
        guard actualMembers == expectedMembers else {
            throw CodexGhostRepairError.backupFailed(
                "M4f operation backup membership drifted."
            )
        }
        for file in receipt.files where file.present {
            let copied = directory.appendingPathComponent(file.fileName)
            let observed = try Self.hashPrivateFile(copied)
            guard observed.byteCount == file.byteCount,
                  observed.contentHash == file.contentHash else {
                throw CodexGhostRepairError.backupFailed(
                    "M4f operation backup durable readback drifted."
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
                "M4f could not create an exact operation backup member."
            )
        }
        var finished = false
        defer {
            if !finished { _ = fsync(descriptor) }
            Darwin.close(descriptor)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f could not protect an operation backup member."
            )
        }
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
                            "M4f operation backup write failed."
                        )
                    }
                    offset += count
                }
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f could not durably synchronize a backup member."
            )
        }
        finished = true
        let observed = try Self.hashPrivateFile(destination)
        guard observed.byteCount == evidence.size,
              observed.contentHash == evidence.sha256 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f copied operation backup member did not match its source."
            )
        }
    }

    private func writeManifestLast(
        _ receipt: CodexGhostRepairBulkExecutionBackupReceipt,
        in directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(receipt)
        let url = directory.appendingPathComponent(Self.manifestFileName)
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f operation backup receipt already exists."
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
                        "M4f operation backup receipt write failed."
                    )
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f operation backup receipt was not durable."
            )
        }
    }

    private func operationURL(_ operationID: UUID) -> URL {
        backupRootURL.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
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
                "M4f could not open a backup member for readback."
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
                "M4f backup member is not an owner-private regular file."
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw CodexGhostRepairError.backupFailed(
                    "M4f backup member readback failed."
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
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f required backup directory is not owner-private."
            )
        }
    }

    private static func requirePrivateRegularFile(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f required backup file is not owner-private."
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
                "M4f could not open a backup directory for synchronization."
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M4f could not synchronize a backup directory."
            )
        }
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentParts = parent.pathComponents
        let childParts = child.pathComponents
        return childParts.count > parentParts.count
            && childParts.prefix(parentParts.count) == parentParts[...]
    }
}

#endif
