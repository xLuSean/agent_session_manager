import Darwin
import Foundation

/// A non-persistent advisory exclusion shared by normal one-shot execution
/// and explicit fresh recovery. The existing manager database's parent
/// directory is opened read-only and locked; no lock file or manager record is
/// created. The database and directory identities are both pinned by the lease.
struct CodexGhostRepairBulkOperationExclusion: Sendable {
    typealias DatabaseURLProvider = @Sendable () throws -> URL

    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32?
        let databaseURL: URL?
        let fileIdentity: FileIdentity?
        private let coordinationDirectoryURL: URL?
        private let coordinationDirectoryIdentity: FileIdentity?

        fileprivate init(
            descriptor: Int32?,
            databaseURL: URL? = nil,
            fileIdentity: FileIdentity? = nil,
            coordinationDirectoryURL: URL? = nil,
            coordinationDirectoryIdentity: FileIdentity? = nil
        ) {
            self.descriptor = descriptor
            self.databaseURL = databaseURL
            self.fileIdentity = fileIdentity
            self.coordinationDirectoryURL = coordinationDirectoryURL
            self.coordinationDirectoryIdentity = coordinationDirectoryIdentity
        }

        func release() {
            lock.lock()
            defer { lock.unlock() }
            guard let descriptor else { return }
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            self.descriptor = nil
        }

        deinit { release() }

        func validateCurrentPath() throws {
            guard let databaseURL, let fileIdentity else { return }
            var status = stat()
            guard lstat(databaseURL.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_uid == geteuid(),
                  UInt64(status.st_dev) == fileIdentity.device,
                  UInt64(status.st_ino) == fileIdentity.inode else {
                throw CodexGhostRepairError.recoveryRequired
            }
            guard let coordinationDirectoryURL,
                  let coordinationDirectoryIdentity else {
                throw CodexGhostRepairError.recoveryRequired
            }
            var directoryStatus = stat()
            guard lstat(
                coordinationDirectoryURL.path,
                &directoryStatus
            ) == 0,
                  (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
                  directoryStatus.st_uid == geteuid(),
                  UInt64(directoryStatus.st_dev)
                    == coordinationDirectoryIdentity.device,
                  UInt64(directoryStatus.st_ino)
                    == coordinationDirectoryIdentity.inode else {
                throw CodexGhostRepairError.recoveryRequired
            }
        }
    }

    private let databaseURLProvider: DatabaseURLProvider?

    static let uncoordinatedTestOnly = Self(databaseURLProvider: nil)

    static func production() -> Self {
        Self(databaseURLProvider: {
            try StateStoreLocation.applicationSupportDatabaseURL()
        })
    }

    init(databaseURL: URL) {
        self.init(databaseURLProvider: { databaseURL })
    }

    private init(databaseURLProvider: DatabaseURLProvider?) {
        self.databaseURLProvider = databaseURLProvider
    }

    func acquire() throws -> Lease {
        guard let databaseURLProvider else {
            return Lease(descriptor: nil)
        }
        let url = try databaseURLProvider().standardizedFileURL
        let coordinationDirectoryURL = url.deletingLastPathComponent()
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFREG,
              pathStatus.st_uid == geteuid(),
              (pathStatus.st_mode & S_IRUSR) != 0,
              (pathStatus.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk operation exclusion requires the existing owner-controlled manager database."
            )
        }
        var directoryPathStatus = stat()
        guard lstat(
            coordinationDirectoryURL.path,
            &directoryPathStatus
        ) == 0,
              (directoryPathStatus.st_mode & S_IFMT) == S_IFDIR,
              directoryPathStatus.st_uid == geteuid(),
              (directoryPathStatus.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk operation exclusion requires the existing owner-controlled manager directory."
            )
        }
        let descriptor = open(
            coordinationDirectoryURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.recoveryRequired
        }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              (openedStatus.st_mode & S_IFMT) == S_IFDIR,
              openedStatus.st_uid == directoryPathStatus.st_uid,
              openedStatus.st_dev == directoryPathStatus.st_dev,
              openedStatus.st_ino == directoryPathStatus.st_ino,
              (openedStatus.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            _ = close(descriptor)
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk operation exclusion directory identity changed while opening."
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw CodexGhostRepairError.recoveryRequired
        }
        var lockedPathStatus = stat()
        guard lstat(url.path, &lockedPathStatus) == 0,
              (lockedPathStatus.st_mode & S_IFMT) == S_IFREG,
              lockedPathStatus.st_uid == pathStatus.st_uid,
              lockedPathStatus.st_dev == pathStatus.st_dev,
              lockedPathStatus.st_ino == pathStatus.st_ino,
              (lockedPathStatus.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw CodexGhostRepairError.recoveryRequired
        }
        return Lease(
            descriptor: descriptor,
            databaseURL: url,
            fileIdentity: .init(
                device: UInt64(pathStatus.st_dev),
                inode: UInt64(pathStatus.st_ino)
            ),
            coordinationDirectoryURL: coordinationDirectoryURL,
            coordinationDirectoryIdentity: .init(
                device: UInt64(openedStatus.st_dev),
                inode: UInt64(openedStatus.st_ino)
            )
        )
    }
}
