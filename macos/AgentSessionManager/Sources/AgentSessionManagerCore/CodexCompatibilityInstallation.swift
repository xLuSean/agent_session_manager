import Darwin
import Foundation

/// Cheap update detection, not a signature or content-integrity audit. Only an
/// explicit Settings check attaches this observation to its verified report.
public struct CodexCompatibilityInstallation: Codable, Equatable, Sendable {
    let provider: FileStamp
    let codexHome: String?
    let desktop: Desktop?

    struct Desktop: Codable, Equatable, Sendable {
        let path: String
        let version: String
        let build: String
        let files: [FileStamp]
    }

    struct FileStamp: Codable, Equatable, Sendable {
        let requestedPath: String
        let resolvedPath: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        static func read(_ url: URL) throws -> Self {
            let resolved = url.resolvingSymlinksInPath()
            var value = stat()
            guard stat(resolved.path, &value) == 0,
                  value.st_mode & S_IFMT == S_IFREG else {
                throw CodexCompatibilityInspector.CheckError.unavailable
            }
            return .init(requestedPath: url.standardizedFileURL.path, resolvedPath: resolved.path,
                device: value.st_dev, inode: value.st_ino, size: value.st_size,
                modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
        }
    }

    static func read(_ request: CodexCompatibilityRequest, desktopCandidates: [URL]) throws -> Self {
        let provider = try FileStamp.read(request.providerExecutable)
        var desktop: Desktop?
        for app in desktopCandidates {
            let plistURL = app.appendingPathComponent("Contents/Info.plist")
            guard FileManager.default.fileExists(atPath: plistURL.path) else { continue }
            let plistStamp = try FileStamp.read(plistURL)
            guard plistStamp.size <= 1_048_576,
                  let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
            else { throw CodexCompatibilityInspector.CheckError.unavailable }
            guard plist["CFBundleIdentifier"] as? String == "com.openai.codex" else { continue }
            guard let version = plist["CFBundleShortVersionString"] as? String,
                  let build = plist["CFBundleVersion"] as? String,
                  let executable = plist["CFBundleExecutable"] as? String,
                  !version.isEmpty, !build.isEmpty, !executable.isEmpty,
                  ![".", ".."].contains(executable), !executable.contains("/") else {
                throw CodexCompatibilityInspector.CheckError.unavailable
            }
            var files = [plistStamp]
            for path in ["Contents/Resources/codex", "Contents/MacOS/" + executable,
                         "Contents/Resources/app.asar", "Contents/_CodeSignature/CodeResources"] {
                let file = app.appendingPathComponent(path)
                // A partial/uninstalled Desktop may still leave CLI browsing usable.
                if FileManager.default.fileExists(atPath: file.path) { files.append(try FileStamp.read(file)) }
            }
            guard try FileStamp.read(plistURL) == plistStamp else { throw CodexCompatibilityInspector.CheckError.changed }
            desktop = .init(path: app.resolvingSymlinksInPath().path, version: version, build: build, files: files)
            break
        }
        return .init(provider: provider, codexHome: request.codexHome?.standardizedFileURL.path, desktop: desktop)
    }

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return CodexCompatibilityInspector.hash(try! encoder.encode(self))
    }
}
