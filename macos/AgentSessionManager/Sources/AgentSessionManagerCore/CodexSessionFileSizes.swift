import Foundation
import Darwin

/// Display-only logical file sizes, never physical disk reclamation or mutation authority.
public struct DeletedConversationSpaceSummary: Equatable, Sendable {
    public let measuredBytes: Int64?
    public let measuredSessionCount: Int
    public let deletedSessionCount: Int

    public var isComplete: Bool {
        measuredBytes != nil && measuredSessionCount == deletedSessionCount
    }

    public init(verifiedDeletedSessionIDs: Set<String>, before: [String: Int64], after: [String: Int64]) {
        deletedSessionCount = verifiedDeletedSessionIDs.count
        var total: Int64 = 0
        var count = 0
        for id in verifiedDeletedSessionIDs {
            // Zero after a complete scan plus successful official absence is
            // required. Missing metadata or remaining files are not zero.
            guard let bytes = before[id], bytes >= 0, after[id] == 0 else { continue }
            let sum = total.addingReportingOverflow(bytes)
            guard !sum.overflow else {
                measuredBytes = nil
                measuredSessionCount = 0
                return
            }
            total = sum.partialValue
            count += 1
        }
        measuredBytes = count > 0 || verifiedDeletedSessionIDs.isEmpty ? total : nil
        measuredSessionCount = count
    }
}

public enum SessionFileSizeIssue: String, Error, Equatable, Sendable {
    case unavailable, invalidSessionID, homeUnavailable, scanIncomplete, scanLimit, cancelled
    case symbolicLink, notRegularFile, fileUnavailable, invalidHeader, conflictingIdentity
    case headerTooLarge, headerBudgetExceeded, fileChanged, sizeOverflow

    public var explanation: String {
        switch self {
        case .unavailable: "File size could not be measured. Refresh to try again."
        case .invalidSessionID: "The session ID format is not supported by the size scan."
        case .homeUnavailable: "The Codex conversation folder could not be read."
        case .scanIncomplete: "The conversation folders could not be completely scanned."
        case .scanLimit: "The conversation scan exceeded its file-count limit."
        case .cancelled: "The size scan was cancelled. Refresh to try again."
        case .symbolicLink: "The scan encountered a symbolic link and did not follow it."
        case .notRegularFile: "A matching conversation path is not a regular file."
        case .fileUnavailable: "A matching conversation file could not be read."
        case .invalidHeader: "A multi-ID filename could not be matched to valid session metadata in its first line."
        case .conflictingIdentity: "The file's session metadata disagrees with its filename or contains conflicting session IDs."
        case .headerTooLarge: "A conversation header exceeds the bounded read limit. The rest of the file was not loaded."
        case .headerBudgetExceeded: "The size scan reached its total header-read limit. Some file identities could not be checked."
        case .fileChanged: "A conversation file changed while its identity was being checked. Refresh to try again."
        case .sizeOverflow: "The combined conversation size exceeds the supported numeric range."
        }
    }
}

public struct SessionFileSizeInspection: Equatable, Sendable {
    public let sizes: [String: Int64]
    public let issues: [String: SessionFileSizeIssue]
    /// Bounded I/O accounting; no header contents or file paths are retained.
    public let headerBytesRead: Int

    public init(sizes: [String: Int64], issues: [String: SessionFileSizeIssue] = [:], headerBytesRead: Int = 0) {
        self.sizes = sizes
        self.issues = issues
        self.headerBytesRead = headerBytesRead
    }
}

public protocol SessionFileSizeReading: Sendable {
    /// Missing entries mean unavailable, never zero. Sizes do not authorize deletion.
    func sizes(homeURL: URL, sessionIDs: Set<String>) async -> [String: Int64]
    func inspect(homeURL: URL, sessionIDs: Set<String>) async -> SessionFileSizeInspection
}

public extension SessionFileSizeReading {
    func inspect(homeURL: URL, sessionIDs: Set<String>) async -> SessionFileSizeInspection {
        let sizes = await sizes(homeURL: homeURL, sessionIDs: sessionIDs)
        return SessionFileSizeInspection(sizes: sizes, issues: Dictionary(
            uniqueKeysWithValues: sessionIDs.subtracting(sizes.keys).map { ($0, .unavailable) }))
    }
}

/// Counts file metadata off the UI actor. Ambiguous filenames need only a bounded
/// session_meta header read; neither transcript bodies nor parsed headers are retained.
public actor CodexSessionFileSizeReader: SessionFileSizeReading {
    private let maximumEntries: Int
    private let maximumHeaderBytes: Int
    private let maximumTotalHeaderBytes: Int

    public init(maximumEntries: Int = 100_000, maximumHeaderBytes: Int = 256 * 1024,
                maximumTotalHeaderBytes: Int = 64 * 1024 * 1024) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumHeaderBytes = min(256 * 1024, max(1, maximumHeaderBytes))
        self.maximumTotalHeaderBytes = min(64 * 1024 * 1024, max(0, maximumTotalHeaderBytes))
    }

    public func sizes(homeURL: URL, sessionIDs: Set<String>) async -> [String: Int64] {
        inspectFiles(homeURL: homeURL, sessionIDs: sessionIDs).sizes
    }

    public func inspect(homeURL: URL, sessionIDs: Set<String>) async -> SessionFileSizeInspection {
        inspectFiles(homeURL: homeURL, sessionIDs: sessionIDs)
    }

    private func inspectFiles(homeURL: URL, sessionIDs: Set<String>) -> SessionFileSizeInspection {
        let ids = Set(sessionIDs.filter { UUID(uuidString: $0)?.uuidString.lowercased() == $0 })
        var issues = Dictionary(uniqueKeysWithValues: sessionIDs.subtracting(ids).map { ($0, SessionFileSizeIssue.invalidSessionID) })
        var headerBytesRead = 0
        func incomplete(_ reason: SessionFileSizeIssue) -> SessionFileSizeInspection {
            .init(sizes: [:], issues: issues.merging(Dictionary(uniqueKeysWithValues: ids.map { ($0, reason) })) { old, _ in old },
                  headerBytesRead: headerBytesRead)
        }
        guard !ids.isEmpty else { return incomplete(.invalidSessionID) }
        guard !Task.isCancelled else { return incomplete(.cancelled) }
        // Foundation may shorten /private/var to /var for the root while its
        // enumerator returns /private/var entries. Use one physical root path.
        guard let resolvedRoot = realpath(homeURL.standardizedFileURL.path, nil) else { return incomplete(.homeUnavailable) }
        let root = URL(fileURLWithPath: String(cString: resolvedRoot), isDirectory: true)
        free(resolvedRoot)
        let fm = FileManager.default
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return incomplete(.homeUnavailable) }
        let pattern = #"(?<=[_-])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=_|\.jsonl$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return incomplete(.unavailable) }
        var totals = Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(0)) })
        var entries = 0
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name)
            do {
                let attrs = try fm.attributesOfItem(atPath: directory.path)
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink { return incomplete(.symbolicLink) }
                guard attrs[.type] as? FileAttributeType == .typeDirectory else { return incomplete(.scanIncomplete) }
            } catch CocoaError.fileReadNoSuchFile { continue }
            catch { return incomplete(.scanIncomplete) }
            var failed = false
            guard let files = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                errorHandler: { _, _ in failed = true; return false }
            ) else { return incomplete(.scanIncomplete) }
            for case let file as URL in files {
                entries += 1
                guard !Task.isCancelled else { return incomplete(.cancelled) }
                guard entries <= maximumEntries else { return incomplete(.scanLimit) }
                let filename = file.lastPathComponent
                let matches = filename.hasPrefix("rollout-") && filename.hasSuffix(".jsonl")
                    ? regex.matches(in: filename, range: NSRange(filename.startIndex..., in: filename)) : []
                let candidates = Set(matches.compactMap { Range($0.range, in: filename).map { String(filename[$0]) } })
                let relevant = candidates.intersection(ids)
                do {
                    let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                    if values.isSymbolicLink == true {
                        files.skipDescendants()
                        return incomplete(.symbolicLink)
                    }
                    guard !relevant.isEmpty else { continue }
                    guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                        for id in relevant { issues[id] = issues[id] ?? .notRegularFile }
                        continue
                    }
                    let owner: String
                    let bytes: Int64
                    if candidates.count == 1, let only = relevant.first {
                        owner = only
                        bytes = Int64(size)
                    } else {
                        // Release Foundation's temporary objects after each header,
                        // not only when a potentially large inventory completes.
                        let resolved = try autoreleasepool {
                            try readOwner(file: file, root: root, candidates: candidates, bytesRead: &headerBytesRead)
                        }
                        owner = resolved.id
                        bytes = resolved.bytes
                    }
                    guard ids.contains(owner) else { continue }
                    let sum = totals[owner, default: 0].addingReportingOverflow(bytes)
                    if sum.overflow { issues[owner] = .sizeOverflow }
                    else { totals[owner] = sum.partialValue }
                } catch let reason as SessionFileSizeIssue {
                    for id in relevant { issues[id] = issues[id] ?? reason }
                } catch {
                    if relevant.isEmpty { return incomplete(.scanIncomplete) }
                    for id in relevant { issues[id] = issues[id] ?? .fileUnavailable }
                }
            }
            if failed { return incomplete(.scanIncomplete) }
        }
        guard !Task.isCancelled else { return incomplete(.cancelled) }
        for id in issues.keys { totals.removeValue(forKey: id) }
        return .init(sizes: totals, issues: issues, headerBytesRead: headerBytesRead)
    }

    private func readOwner(file: URL, root: URL, candidates: Set<String>, bytesRead: inout Int) throws -> (id: String, bytes: Int64) {
        guard bytesRead < maximumTotalHeaderBytes else { throw SessionFileSizeIssue.headerBudgetExceeded }
        let descriptor = try openWithoutFollowingLinks(file: file, root: root)
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else {
            throw SessionFileSizeIssue.fileUnavailable
        }
        var header = Data()
        var buffer = [UInt8](repeating: 0, count: min(16 * 1024, maximumHeaderBytes))
        var complete = false
        while header.count < maximumHeaderBytes {
            guard !Task.isCancelled else { throw SessionFileSizeIssue.cancelled }
            let count = min(buffer.count, maximumHeaderBytes - header.count, maximumTotalHeaderBytes - bytesRead)
            guard count > 0 else { throw SessionFileSizeIssue.headerBudgetExceeded }
            let readCount = Darwin.read(descriptor, &buffer, count)
            guard readCount >= 0 else { throw SessionFileSizeIssue.fileUnavailable }
            if readCount == 0 { complete = true; break }
            bytesRead += readCount
            if let newline = buffer.prefix(readCount).firstIndex(of: 10) {
                header.append(contentsOf: buffer.prefix(newline))
                complete = true
                break
            }
            header.append(contentsOf: buffer.prefix(readCount))
        }
        guard complete else { throw SessionFileSizeIssue.headerTooLarge }
        guard let record = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
              record["type"] as? String == "session_meta", let payload = record["payload"] as? [String: Any] else {
            throw SessionFileSizeIssue.invalidHeader
        }
        var identities = Set<String>()
        for field in ["session_id", "id"] where payload[field] != nil {
            guard let value = payload[field] as? String, let uuid = UUID(uuidString: value) else {
                throw SessionFileSizeIssue.invalidHeader
            }
            identities.insert(uuid.uuidString.lowercased())
        }
        guard !identities.isEmpty else { throw SessionFileSizeIssue.invalidHeader }
        guard identities.count == 1, let owner = identities.first, candidates.contains(owner) else {
            throw SessionFileSizeIssue.conflictingIdentity
        }
        var after = stat()
        var currentPath = stat()
        guard fstat(descriptor, &after) == 0, lstat(file.path, &currentPath) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_dev == currentPath.st_dev, after.st_ino == currentPath.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SessionFileSizeIssue.fileChanged
        }
        return (owner, Int64(after.st_size))
    }

    private func openWithoutFollowingLinks(file: URL, root: URL) throws -> Int32 {
        let prefix = root.path + "/"
        guard file.path.hasPrefix(prefix) else { throw SessionFileSizeIssue.fileUnavailable }
        let parts = file.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { throw SessionFileSizeIssue.fileUnavailable }
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SessionFileSizeIssue.fileUnavailable }
        for (index, part) in parts.enumerated() {
            let directoryFlag = index == parts.count - 1 ? 0 : O_DIRECTORY
            let next = openat(descriptor, part, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | directoryFlag)
            close(descriptor)
            guard next >= 0 else { throw SessionFileSizeIssue.fileUnavailable }
            descriptor = next
        }
        return descriptor
    }
}
