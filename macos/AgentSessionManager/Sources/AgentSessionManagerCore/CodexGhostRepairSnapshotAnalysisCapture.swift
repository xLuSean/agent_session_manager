import CryptoKit
import Darwin
import Foundation

/// Destination-side capture for authority-free analysis. Uses only read-only
/// source descriptors and an owner-private workspace. APFS clones keep the
/// acquisition window short; the streaming fallback has the same drift guard.
/// SHM is omitted and rebuilt inside the workspace. The returned fingerprint
/// describes the captured set and never substitutes for a production backup.
enum CodexGhostRepairSnapshotAnalysisCapture {
    static func capture(
        source: CodexGhostRepairSnapshotCanonicalSource,
        in workspace: CodexGhostRepairSnapshotAnalysisWorkspace,
        forceStreamingForTesting: Bool = false,
        afterCopiedMemberForTesting: (Int) throws -> Void = { _ in },
        afterCaptureForTesting: () throws -> Void = {}
    ) throws -> CodexGhostRepairSnapshotCanonicalFingerprint {
        let directory = Darwin.open(workspace.rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence("Analysis copy destination is unavailable.")
        }
        defer { Darwin.close(directory) }
        var directoryStatus = stat()
        guard fstat(directory, &directoryStatus) == 0,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & 0o7777 == 0o700 else {
            throw CodexGhostRepairError.invalidProtectionEvidence("Analysis copy destination is unsafe.")
        }
        let captured = try source.captureAnalysisMembers { index, file, descriptor, expected in
            let cloned = !forceStreamingForTesting
                && fclonefileat(descriptor, directory, file.rawValue, 0) == 0
            if !cloned {
                guard forceStreamingForTesting || errno == ENOTSUP || errno == EXDEV else {
                    throw CodexGhostRepairError.invalidProtectionEvidence("Analysis file clone failed.")
                }
                // A different filesystem may not support clones. A slower copy
                // still has to pass the exact same stable-capture checks.
                let destination = openat(directory, file.rawValue,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
                guard destination >= 0 else {
                    throw CodexGhostRepairError.invalidProtectionEvidence("Analysis file copy could not be created.")
                }
                defer { Darwin.close(destination) }
                guard fcopyfile(descriptor, destination, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                    throw CodexGhostRepairError.invalidProtectionEvidence("Analysis file copy failed.")
                }
            }
            let copy = openat(directory, file.rawValue, O_RDONLY | O_NOFOLLOW)
            guard copy >= 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence("Analysis copy could not be verified.")
            }
            defer { Darwin.close(copy) }
            var copied = stat()
            guard fstat(copy, &copied) == 0,
                  (copied.st_mode & S_IFMT) == S_IFREG,
                  copied.st_uid == geteuid(), copied.st_nlink == 1,
                  copied.st_size == expected.st_size,
                  fchmod(copy, S_IRUSR | S_IWUSR) == 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence("Analysis copy identity is unsafe.")
            }
            try afterCopiedMemberForTesting(index)
        }
        try afterCaptureForTesting()
        let files = try source.profile.files.enumerated().map { index, file in
            guard let status = captured.files[index] else {
                return CodexGhostRepairSnapshotCanonicalFileEvidence(
                    fileName: file.rawValue, exists: false, device: nil, inode: nil,
                    mode: nil, size: nil, modificationSeconds: nil,
                    modificationNanoseconds: nil, sha256: nil)
            }
            let descriptor = openat(directory, file.rawValue, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence("Captured analysis file is unavailable.")
            }
            defer { Darwin.close(descriptor) }
            var hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else {
                    throw CodexGhostRepairError.invalidProtectionEvidence("Captured analysis file is unreadable.")
                }
                if count == 0 { break }
                hash.update(data: Data(buffer[0..<count]))
            }
            return CodexGhostRepairSnapshotCanonicalFileEvidence(
                fileName: file.rawValue, exists: true,
                device: UInt64(status.st_dev), inode: UInt64(status.st_ino),
                mode: UInt32(status.st_mode), size: UInt64(status.st_size),
                modificationSeconds: Int64(status.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
                sha256: "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        return try .init(profile: source.profile, sourceRootDigest: captured.sourceRootDigest, files: files)
    }

}
