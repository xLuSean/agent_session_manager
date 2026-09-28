import Foundation
import Security

/// Resolve the executable itself, never the shell launcher: the isolated probe
/// copies/reads only this file and must not follow arbitrary package entrypoints.
enum CodexCompatibilityDesktopRuntime {
    static let executableRelativePaths = [
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/codex",
    ]
    static let installationRelativePaths = executableRelativePaths + [
        "Contents/Resources/codex-cli/bin/codex",
        "Contents/Resources/codex-cli/codex-package.json",
    ]

    static func resolve(in app: URL) throws -> URL {
        let candidates = executableRelativePaths.map { app.appendingPathComponent($0) }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])) != nil
        }
        guard candidates.count == 1, let runtime = candidates.first else {
            throw CodexCompatibilityDesktopApplicationReader.Failure.unavailable
        }
        let values = try runtime.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              runtime.standardizedFileURL.path == runtime.resolvingSymlinksInPath().path,
              FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw CodexCompatibilityDesktopApplicationReader.Failure.unavailable
        }
        return runtime
    }
}

/// Identifies sealed App contents, not compatibility or publisher trust. A valid
/// signature (including an ad-hoc signature) is never a cleanup authorization.
public struct CodexCompatibilityDesktopApplication: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let fingerprint: String
}

enum CodexCompatibilityDesktopApplicationReader {
    struct Identity {
        let application: CodexCompatibilityDesktopApplication
        let runtimeURL: URL
        let runtimeSHA256: String
    }

    static func read(_ app: URL) throws -> Identity {
        try Task.checkCancellation()
        guard app.standardizedFileURL.path == app.resolvingSymlinksInPath().path else { throw Failure.unavailable }
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let values = try plistURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1_048_576 else { throw Failure.unavailable }
        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "com.openai.codex",
              let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty,
              ![".", ".."].contains(executable), !executable.contains("/"),
              let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty,
              let build = plist["CFBundleVersion"] as? String, !build.isEmpty else { throw Failure.unavailable }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw Failure.unavailable }
        // Network access is opt-in in this API; intentionally do not set it.
        // Check resources and embedded code as well as every main architecture.
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw Failure.invalidSignature }
        let runtime = try CodexCompatibilityDesktopRuntime.resolve(in: app)
        let main = app.appendingPathComponent("Contents/MacOS/" + executable)
        for file in [runtime, main] {
            let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  file.standardizedFileURL.path == file.resolvingSymlinksInPath().path else { throw Failure.unavailable }
        }
        let runtimeSHA = try CodexCompatibilityInspector.executableSHA256(runtime)
        let mainSHA = try CodexCompatibilityInspector.executableSHA256(main)
        // The signed main binary seals resource and nested-code identities.
        // Hash all its bytes to cover non-native architectures as well.
        let fingerprint = CodexCompatibilityInspector.hash(try JSONEncoder().encode([
            "desktop-bundle-v2", app.path, runtime.path, CodexCompatibilityInspector.hash(data), mainSHA, runtimeSHA,
        ]))
        try Task.checkCancellation()
        return .init(application: .init(version: version, build: build, fingerprint: fingerprint),
                     runtimeURL: runtime, runtimeSHA256: runtimeSHA)
    }

    enum Failure: Error { case unavailable, invalidSignature }
}
