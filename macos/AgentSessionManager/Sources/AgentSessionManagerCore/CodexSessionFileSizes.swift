import Foundation

public protocol SessionFileSizeReading: Sendable {
    /// Missing entries mean unavailable, never zero. This is display information,
    /// not evidence for deletion or a forecast of reclaimable disk space.
    func sizes(homeURL: URL, sessionIDs: Set<String>) async -> [String: Int64]
}

/// Reads metadata once per inventory, not the contents of potentially large
/// transcripts. Actor isolation keeps directory traversal off the UI actor.
public actor CodexSessionFileSizeReader: SessionFileSizeReading {
    private let maximumEntries: Int

    public init(maximumEntries: Int = 100_000) {
        self.maximumEntries = maximumEntries
    }

    public func sizes(homeURL: URL, sessionIDs: Set<String>) -> [String: Int64] {
        let ids = Set(sessionIDs.filter { UUID(uuidString: $0)?.uuidString.lowercased() == $0 })
        guard !ids.isEmpty else { return [:] }
        let root = homeURL.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [:] }
        let pattern = #"(?<=[_-])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=_|\.jsonl$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var totals = Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(0)) })
        var unavailable = Set<String>()
        var entries = 0
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name)
            do {
                let attrs = try fm.attributesOfItem(atPath: directory.path)
                guard attrs[.type] as? FileAttributeType == .typeDirectory else { return [:] }
            } catch CocoaError.fileReadNoSuchFile { continue }
            catch { return [:] }
            var failed = false
            guard let files = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                errorHandler: { _, _ in failed = true; return false }
            ) else { return [:] }
            for case let file as URL in files {
                entries += 1
                guard !Task.isCancelled, entries <= maximumEntries else { return [:] }
                let filename = file.lastPathComponent
                let matches = filename.hasPrefix("rollout-") && filename.hasSuffix(".jsonl")
                    ? regex.matches(in: filename, range: NSRange(filename.startIndex..., in: filename)) : []
                let owners = Set(matches.compactMap { Range($0.range, in: filename).map { String(filename[$0]) } })
                let relevant = owners.intersection(ids)
                do {
                    let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                    // Never follow symlink directories outside the transcript roots.
                    // Their unknown contents prevent a complete total for any ID.
                    if values.isSymbolicLink == true {
                        files.skipDescendants()
                        return [:]
                    }
                    guard !relevant.isEmpty else { continue }
                    guard owners.count == 1, values.isRegularFile == true,
                          let size = values.fileSize, size >= 0,
                          let id = relevant.first else {
                        unavailable.formUnion(relevant)
                        continue
                    }
                    let sum = totals[id, default: 0].addingReportingOverflow(Int64(size))
                    if sum.overflow { unavailable.insert(id) }
                    else { totals[id] = sum.partialValue }
                } catch { return [:] }
            }
            if failed { return [:] }
        }
        for id in unavailable { totals.removeValue(forKey: id) }
        return totals
    }
}
