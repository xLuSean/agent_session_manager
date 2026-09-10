import Darwin
import Foundation

/// Current eligibility only. Historical outcome readback must not depend on pins.
enum CodexGhostRepairFreshPinProtection {
    static func requireUnpinned(_ threadIDs: [String], codexHomeURL: URL) throws {
        do {
            let data = try readState(codexHomeURL: codexHomeURL)
            let state = try JSONDecoder().decode(CodexDesktopState.self, from: data)
            let pins = try state.validatedPinnedThreadIDSet()
            guard pins.count <= 10_000,
                  pins.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }) else {
                throw unavailable
            }
            guard pins.isDisjoint(with: threadIDs) else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "A selected session is now pinned. Nothing was cleared; scan again."
                )
            }
        } catch let error as CodexGhostRepairError {
            throw error
        } catch {
            // Do not expose private file contents, paths, or decoding errors.
            throw unavailable
        }
    }

    private static var unavailable: CodexGhostRepairError {
        .invalidProtectionEvidence(
            "Current pinned-session protection could not be verified. Nothing was cleared; scan again."
        )
    }

    private static func readState(codexHomeURL: URL) throws -> Data {
        let root = open(codexHomeURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw unavailable }
        defer { close(root) }
        let name = ".codex-global-state.json"
        let descriptor = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw unavailable }
        defer { close(descriptor) }
        var before = stat()
        let maximumBytes = 16 * 1_024 * 1_024
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & (S_IWGRP | S_IWOTH) == 0,
              before.st_size >= 0, before.st_size <= maximumBytes else {
            throw unavailable
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= maximumBytes else { throw unavailable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var current = stat()
        guard fstat(descriptor, &after) == 0,
              fstatat(root, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              data.count == before.st_size,
              [after, current].allSatisfy({
                  $0.st_dev == before.st_dev && $0.st_ino == before.st_ino
                      && $0.st_size == before.st_size && $0.st_mode == before.st_mode
                      && $0.st_uid == before.st_uid && $0.st_nlink == before.st_nlink
                      && $0.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
                      && $0.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
                      && $0.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec
                      && $0.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
              }) else { throw unavailable }
        return data
    }
}
