import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexCompatibilityDesktopApplicationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("asm-bundle-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.trashItem(at: root, resultingItemURL: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testSignedAppIdentityIsStableAndSeparateFromBundledCLIVersion() throws {
        let app = try fixture()
        let first = try CodexCompatibilityDesktopApplicationReader.read(app)
        let second = try CodexCompatibilityDesktopApplicationReader.read(app)
        XCTAssertEqual(first.application, second.application)
        XCTAssertEqual(first.application.version, "9.9.9")
        XCTAssertEqual(first.application.build, "42")
        XCTAssertEqual(first.application.fingerprint.count, 64)
        XCTAssertEqual(first.runtimeURL, app.appendingPathComponent("Contents/Resources/codex"))
        let encoded = try JSONEncoder().encode(first.application)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(root.path))
    }

    func testResignedResourceUpdateChangesIdentityWithoutVersionChange() throws {
        let app = try fixture()
        let before = try CodexCompatibilityDesktopApplicationReader.read(app)
        try Data("updated synthetic app logic".utf8).write(to: app.appendingPathComponent("Contents/Resources/app.asar"))
        try sign(app)
        let after = try CodexCompatibilityDesktopApplicationReader.read(app)
        XCTAssertEqual(before.application.version, after.application.version)
        XCTAssertEqual(before.runtimeSHA256, after.runtimeSHA256)
        XCTAssertNotEqual(before.application.fingerprint, after.application.fingerprint)
    }

    func testTamperedResourceAndExecutableAreRejected() throws {
        let app = try fixture()
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Resources/app.asar"))
        XCTAssertThrowsError(try CodexCompatibilityDesktopApplicationReader.read(app))
        try sign(app)
        let main = app.appendingPathComponent("Contents/MacOS/Codex")
        let file = try FileHandle(forWritingTo: main)
        try file.seekToEnd()
        try file.write(contentsOf: Data([1, 2, 3]))
        try file.close()
        XCTAssertThrowsError(try CodexCompatibilityDesktopApplicationReader.read(app))
    }

    func testUnsignedAndSymlinkedAppsAreRejected() throws {
        let unsigned = try fixture(signed: false)
        XCTAssertThrowsError(try CodexCompatibilityDesktopApplicationReader.read(unsigned))
        try sign(unsigned)
        let link = root.appendingPathComponent("link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unsigned)
        XCTAssertThrowsError(try CodexCompatibilityDesktopApplicationReader.read(link))
    }

    func testSavedReportInvalidatesForSameVersionAppUpdateAndTampering() async throws {
        let app = try fixture()
        let executable = app.appendingPathComponent("Contents/Resources/codex")
        let cache = root.appendingPathComponent("report.json")
        let inspector = CodexCompatibilityInspector(reportURL: cache, desktopCandidates: [app])
        let request = CodexCompatibilityRequest(providerExecutable: executable, codexHome: nil)
        let first = try await inspector.inspect(request)
        XCTAssertEqual(first.provider.version, "0.999.0")
        XCTAssertEqual(first.desktopApplication?.version, "9.9.9")
        let restarted = CodexCompatibilityInspector(reportURL: cache, desktopCandidates: [app])
        let unchanged = try await restarted.reviewSavedCompatibility(request)
        XCTAssertTrue(unchanged.isCurrent)
        XCTAssertEqual(unchanged.report?.desktopApplication, first.desktopApplication)

        let resource = app.appendingPathComponent("Contents/Resources/app.asar")
        try Data("new signed app, same versions".utf8).write(to: resource)
        try sign(app)
        let changed = try await restarted.reviewSavedCompatibility(request)
        XCTAssertFalse(changed.isCurrent)
        XCTAssertEqual(changed.providerVersion, "0.999.0")
        let second = try await restarted.inspect(request)
        XCTAssertNotEqual(first.environmentFingerprint, second.environmentFingerprint)
        try Data("unsealed modification".utf8).write(to: resource)
        let tampered = try await restarted.reviewSavedCompatibility(request)
        XCTAssertFalse(tampered.isCurrent)
        let rejected = try await restarted.inspect(request)
        XCTAssertNil(rejected.desktopApplication)
        XCTAssertEqual(rejected.results.last?.status, .unavailable)
    }

    func testRenamedCodexApplicationIsIdentifiedByBundleIdentifier() throws {
        let app = try fixture(appName: "ChatGPT.app")
        XCTAssertEqual(try CodexCompatibilityDesktopApplicationReader.read(app).application.version, "9.9.9")
        XCTAssertTrue(CodexCompatibilityInspector.installedDesktopCandidates().contains(URL(fileURLWithPath: "/Applications/ChatGPT.app")))
    }

    func testPackagedRuntimeIdentityUsesBinaryAndDetectsSameVersionReplacement() throws {
        let app = try packagedFixture()
        let runtime = try CodexCompatibilityDesktopRuntime.resolve(in: app)
        XCTAssertTrue(runtime.path.hasSuffix("codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        let first = try CodexCompatibilityDesktopApplicationReader.read(app)
        XCTAssertEqual(first.runtimeURL, runtime)
        let request = CodexCompatibilityRequest(providerExecutable: runtime, codexHome: nil)
        let installed = try CodexCompatibilityInstallation.read(request, desktopCandidates: [app])
        XCTAssertTrue(installed.desktop!.files.contains { $0.requestedPath == runtime.path })
        XCTAssertTrue(installed.desktop!.files.contains { $0.requestedPath.hasSuffix("codex-cli/bin/codex") })
        try FileManager.default.trashItem(at: runtime, resultingItemURL: nil)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: runtime)
        XCTAssertNotEqual(installed, try CodexCompatibilityInstallation.read(request, desktopCandidates: [app]))
        XCTAssertThrowsError(try CodexCompatibilityDesktopApplicationReader.read(app))
    }

    func testRuntimeResolverRejectsAmbiguousLayoutsAndSymlinksWithoutExecutingLauncher() throws {
        let app = try packagedFixture()
        let runtime = try CodexCompatibilityDesktopRuntime.resolve(in: app)
        let legacy = app.appendingPathComponent("Contents/Resources/codex")
        try FileManager.default.copyItem(at: runtime, to: legacy)
        XCTAssertThrowsError(try CodexCompatibilityDesktopRuntime.resolve(in: app))
        try FileManager.default.trashItem(at: legacy, resultingItemURL: nil)
        try FileManager.default.trashItem(at: runtime, resultingItemURL: nil)
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertThrowsError(try CodexCompatibilityDesktopRuntime.resolve(in: app))
        try FileManager.default.trashItem(at: runtime, resultingItemURL: nil)
        XCTAssertThrowsError(try CodexCompatibilityDesktopRuntime.resolve(in: app))
    }

    func testSignatureFailureDoesNotRevokeBuiltInPairButNeverAdmitsUnknownPair() {
        for version in ["0.153.4", "0.999.0"] {
            let result = CodexCompatibilityEvaluator.results(version: version, browsing: true, archive: true,
                restore: true, delete: true, desktopVersion: version, desktopSchemaProfile: "desktop-v34",
                desktopMetadataAvailable: true, desktopIdentityVerified: false)
            XCTAssertEqual(result.last?.status, version == "0.153.4" ? .supportedByBuild : .unavailable)
        }
    }

    func testInstalledEnvironmentReadOnlyRegression() async throws {
        guard ProcessInfo.processInfo.environment["ASM_COMPATIBILITY_LOCAL_INSPECTION"] == "1" else {
            throw XCTSkip("Explicit metadata-only installed-environment inspection")
        }
        let inspector = CodexCompatibilityInspector(reportURL: root.appendingPathComponent("local-report.json"))
        let report = try await inspector.inspect(.init(providerExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            codexHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")))
        XCTAssertNotNil(report.desktop)
        XCTAssertEqual(report.databaseChecks?.count, 4)
        XCTAssertTrue(report.databaseChecks?.allSatisfy { $0.issue == nil } == true)
        XCTAssertNotNil(report.desktopApplication)
        XCTAssertTrue([.supportedByBuild, .needsBehaviorVerification].contains(report.results.last!.status))
        XCTAssertEqual(try CodexCompatibilityDesktopProbe.run(profileIdentifier: report.desktopSchemaProfile).status, .passed)
        let reopened = CodexCompatibilityInspector(reportURL: root.appendingPathComponent("local-report.json"))
        let review = try await reopened.reviewSavedCompatibility(.init(providerExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            codexHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")))
        XCTAssertTrue(review.isCurrent)
        XCTAssertEqual(review.report?.desktop, report.desktop)
        print("Installed inspection: provider=\(report.provider.version), desktop=\(report.desktop!.version), profile=\(report.desktopSchemaProfile ?? "none"), cleanup=\(report.results.last!.status)")
    }

    private func packagedFixture() throws -> URL {
        let app = try fixture(signed: false)
        try FileManager.default.trashItem(at: app.appendingPathComponent("Contents/Resources/codex"), resultingItemURL: nil)
        let package = app.appendingPathComponent("Contents/Resources/codex-cli")
        let nested = package.appendingPathComponent("CodexCLI.app")
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: nested.appendingPathComponent("Contents/MacOS/codex"))
        let plist = ["CFBundleIdentifier": "com.openai.codex.cli", "CFBundleExecutable": "codex", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: nested.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: package.appendingPathComponent("bin/codex"))
        try sign(nested)
        try sign(app)
        return app
    }

    private func fixture(signed: Bool = true, appName: String = "Codex.app") throws -> URL {
        let app = root.appendingPathComponent(appName)
        let contents = app.appendingPathComponent("Contents")
        for directory in ["MacOS", "Resources"] {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let plist = ["CFBundleIdentifier": "com.openai.codex", "CFBundleExecutable": "Codex",
                     "CFBundleShortVersionString": "9.9.9", "CFBundleVersion": "42", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        // A copied system executable supplies Mach-O structure only. It is
        // re-signed locally and never launched; no real Codex App is touched.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Codex"))
        let runtime = contents.appendingPathComponent("Resources/codex")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            printf 'codex-cli 0.999.0\\n'
        elif [ "$1" = "app-server" ] && [ "$2" = "generate-json-schema" ]; then
            /bin/mkdir -p "$4/v2"
        else
            exit 90
        fi
        """.utf8).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        try Data("synthetic app logic".utf8).write(to: contents.appendingPathComponent("Resources/app.asar"))
        if signed { try sign(app) }
        return app
    }

    private func sign(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", "--identifier", "com.openai.codex", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "SyntheticCodeSigning", code: Int(process.terminationStatus)) }
    }
}
