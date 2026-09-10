import Darwin
import Foundation

/// Only presence/access categories are persisted, never paths or file contents.
public struct CodexCompatibilitySidecars: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case missing, readable, inaccessible, unsafe }
    public let wal: State
    public let shm: State
    public let journal: State

    static func read(at url: URL) -> Self {
        func state(_ suffix: String) -> State {
            let path = url.path + suffix
            var info = stat()
            guard lstat(path, &info) == 0 else { return errno == ENOENT ? .missing : .inaccessible }
            guard info.st_mode & S_IFMT == S_IFREG else { return .unsafe }
            return access(path, R_OK) == 0 ? .readable : .inaccessible
        }
        return .init(wal: state("-wal"), shm: state("-shm"), journal: state("-journal"))
    }

    var allMissing: Bool { wal == .missing && shm == .missing && journal == .missing }
}

enum CodexCompatibilitySingleFileRead {
    /// macOS open-time flock locks conflict with SQLite's POSIX locks, including
    /// this process's locks. Acquire atomically with open: opening then closing
    /// an unlocked fd could release another SQLite connection's POSIX locks.
    /// O_NONBLOCK fails immediately when any reader/writer already holds a lock.
    /// Never use immutable=1 on a live source without this lock and sidecar gate.
    static func withLock<T>(at url: URL, read: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CodexCompatibilityReadFailure(stage: .singleFileLock, source: .posix, code: Int(errno))
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw CodexCompatibilityReadFailure(stage: .fileValidation, source: .validation, code: 0)
        }
        func validate() throws {
            var current = stat()
            guard lstat(url.path, &current) == 0,
                  current.st_dev == before.st_dev, current.st_ino == before.st_ino,
                  current.st_size == before.st_size, current.st_mode == before.st_mode,
                  current.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  current.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
                  current.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
                  url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
                throw CodexCompatibilityReadFailure(stage: .sourceChanged, source: .validation, code: 0)
            }
            guard CodexCompatibilitySidecars.read(at: url).allMissing else {
                throw CodexCompatibilityReadFailure(stage: .sidecars, source: .validation, code: 0)
            }
        }
        try validate()
        let result = try read()
        try validate()
        return result
    }
}
