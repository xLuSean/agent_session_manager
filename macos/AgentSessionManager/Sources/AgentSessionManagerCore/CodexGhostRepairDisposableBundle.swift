import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH
/// Test-owned database bundle shared by snapshot research fixtures. The
/// existing marker format is retained; the shipping App cannot construct it.
struct CodexGhostRepairDisposableBundle: Hashable, Sendable {
    static let markerFileName = ".agent-session-manager-e24-disposable-v1"
    static let markerContents = "Agent Session Manager E24 disposable Ghost Repair bundle v1\n"

    let rootURL: URL
    let allowedParentURL: URL
    let desktopDatabaseURL: URL
    let summariesDatabaseURL: URL
    let historyDatabaseURL: URL

    init(rootURL: URL, allowedParentURL: URL) throws {
        let fileManager = FileManager.default
        let originalRootValues = try rootURL.standardizedFileURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard originalRootValues.isDirectory == true,
              originalRootValues.isSymbolicLink != true else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "bundle root must be a real, non-symlink directory"
            )
        }
        let parent = allowedParentURL.standardizedFileURL.resolvingSymlinksInPath()
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path != parent.path, Self.isDescendant(root, of: parent) else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "bundle root must be a child of the exact allowed parent"
            )
        }

        let homeCodex = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard root.path != homeCodex.path, !Self.isDescendant(root, of: homeCodex) else {
            throw CodexGhostRepairError.invalidDisposablePath("live ~/.codex is always prohibited")
        }

        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CodexGhostRepairError.invalidDisposablePath("bundle root is not a real directory")
        }

        let markerURL = root.appendingPathComponent(Self.markerFileName, isDirectory: false)
        guard let markerData = fileManager.contents(atPath: markerURL.path),
              String(data: markerData, encoding: .utf8) == Self.markerContents else {
            throw CodexGhostRepairError.invalidDisposablePath("exact E24 marker is missing")
        }

        let desktop = root.appendingPathComponent("codex-dev.db", isDirectory: false)
        let summaries = root.appendingPathComponent("codex-thread-summaries-dev.db", isDirectory: false)
        let history = root.appendingPathComponent("codex-history-snapshots-dev.db", isDirectory: false)
        for databaseURL in [desktop, summaries, history] {
            let values = try databaseURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CodexGhostRepairError.invalidDisposablePath(
                    "required database is missing, non-regular, or a symlink: \(databaseURL.lastPathComponent)"
                )
            }
            let resolved = databaseURL.resolvingSymlinksInPath()
            guard Self.isDescendant(resolved, of: root) else {
                throw CodexGhostRepairError.invalidDisposablePath("database escaped the disposable root")
            }
        }

        self.rootURL = root
        self.allowedParentURL = parent
        desktopDatabaseURL = desktop
        summariesDatabaseURL = summaries
        historyDatabaseURL = history
    }

    func validatePaths() throws {
        _ = try Self(rootURL: rootURL, allowedParentURL: allowedParentURL)
    }

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return candidate.path.hasPrefix(parentPath)
    }
}
#endif
