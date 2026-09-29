import Foundation
import XCTest
@testable import ASMCompatibilityCLI
@testable import AgentSessionManagerCore

final class CompatibilityCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("asm-command-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.trashItem(at: root, resultingItemURL: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOptionsAreExplicitAndRejectUnknownDuplicateOrRelativePaths() throws {
        let options = try CompatibilityOptions(arguments: ["--inspect-only", "--codex-home", "/tmp/metadata home"],
                                               environment: ["CODEX_HOME": "/tmp/environment-home"])
        XCTAssertTrue(options.inspectOnly)
        XCTAssertEqual(options.home.path, "/tmp/metadata home")
        XCTAssertEqual(options.homeSource, "--codex-home")
        XCTAssertFalse(try CompatibilityOptions(arguments: [], environment: [:]).inspectOnly)
        for args in [["--force"], ["--inspect-only", "--inspect-only"], ["--codex-home"],
                     ["--output-root", "relative"], ["--codex-executable", "--inspect-only"]] {
            XCTAssertThrowsError(try CompatibilityOptions(arguments: args, environment: [:]))
        }
    }

    func testRunDirectoriesCannotOverwriteAppEvidenceOrCodexDataIncludingAliases() throws {
        let home = root.appendingPathComponent("home")
        let codex = home.appendingPathComponent(".codex")
        let appState = home.appendingPathComponent("Library/Application Support/com.sean.AgentSessionManager")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appState, withIntermediateDirectories: true)
        let sentinel = appState.appendingPathComponent("latest-inspection.json")
        try Data("existing App evidence".utf8).write(to: sentinel)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: appState)
        for target in [appState, codex.appendingPathComponent("reports"), alias.appendingPathComponent("reports")] {
            XCTAssertThrowsError(try CompatibilityCommand.createRunDirectory(outputRoot: target, codexHome: codex, userHome: home))
        }
        let output = root.appendingPathComponent("reports")
        let one = try CompatibilityCommand.createRunDirectory(outputRoot: output, codexHome: codex, userHome: home)
        let two = try CompatibilityCommand.createRunDirectory(outputRoot: output, codexHome: codex, userHome: home)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: one.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try String(contentsOf: sentinel), "existing App evidence")
    }

    func testFullRunUsesSharedInspectorSequenceAndPersistsIndependentReport() async throws {
        let calls = Calls()
        let result = try await run(calls: calls)
        let observed = await calls.values
        XCTAssertEqual(observed, ["inspect", "verifyBehavior", "savedReport", "isCurrent"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.savedReportReadbackPassed)
        XCTAssertFalse(result.appCacheUpdated)
        XCTAssertFalse(result.desktopRestartTested)
        XCTAssertEqual(result.featureAvailability.last?.state, .updateRequired)
        XCTAssertTrue(result.summary.contains("Not enabled for this Codex version"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(CompatibilityRunReport.self, from: Data(contentsOf: root.appendingPathComponent("report.json")))
        XCTAssertEqual(saved.featureAvailability, result.featureAvailability)
        XCTAssertEqual(saved.inspection?.environmentFingerprint, "fixture")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("report.json").path)[.posixPermissions] as? Int, 0o600)
    }

    func testInspectOnlyNeverCallsBehaviorAndDoesNotClaimIsolatedSuccess() async throws {
        let calls = Calls()
        let result = try await run(inspectOnly: true, calls: calls)
        let observed = await calls.values
        XCTAssertEqual(observed, ["inspect", "savedReport", "isCurrent"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.inspection?.behavior)
        XCTAssertEqual(result.featureAvailability[1].state, .isolatedTestRequired)
    }

    func testSkippedFailedAndDuplicateTestsCannotReturnSuccess() {
        for status in [CodexCompatibilityBehaviorStatus.failed, .notTested] {
            var report = Self.fixture()
            report.behavior = .init(revision: 1, checkedAt: report.checkedAt, results: [
                .init(feature: .archiveRestore, status: .passed, detail: ""),
                .init(feature: .officialDelete, status: .passed, detail: ""),
                .init(feature: .desktopCleanup, status: status, detail: "")])
            XCTAssertFalse(CompatibilityCommand.checksPassed(report, inspectOnly: false))
        }
        var duplicate = Self.fixture()
        duplicate.behavior = .init(revision: 1, checkedAt: duplicate.checkedAt,
                                  results: Array(repeating: .init(feature: .officialDelete, status: .passed, detail: ""), count: 3))
        XCTAssertFalse(CompatibilityCommand.checksPassed(duplicate, inspectOnly: false))
        duplicate.databaseChecks = Array(repeating: duplicate.databaseChecks![0], count: 4)
        XCTAssertFalse(CompatibilityCommand.checksPassed(duplicate, inspectOnly: true))
    }

    func testFeatureAvailabilityKeepsStructureAndSQLSuccessSeparateFromDesktopSupport() {
        var report = Self.fixture()
        report.behavior = .init(revision: 1, checkedAt: report.checkedAt,
                               results: [CodexCompatibilityFeature.archiveRestore, .officialDelete, .desktopCleanup].map {
            .init(feature: $0, status: .passed, detail: "fixture")
        })
        let rows = CodexCompatibilityPresentation.availability(report, isCurrent: true)
        XCTAssertEqual(rows.map(\.state), [.available, .available, .available, .updateRequired])
        XCTAssertTrue(rows.last!.nextStep!.contains("ASM compatibility update"))
        XCTAssertTrue(CodexCompatibilityPresentation.interfaceChecks(report).allSatisfy(\.passed))
        XCTAssertTrue(CodexCompatibilityPresentation.availability(report, isCurrent: false).allSatisfy { $0.state == .recheckRequired })
    }

    func testBuiltInSupportDoesNotHideFailedLifecycleTest() {
        var report = Self.fixture(version: "0.153.4", profile: "desktop-v34")
        XCTAssertEqual(CodexCompatibilityPresentation.availability(report, isCurrent: true).last?.state, .available)
        report.behavior = .init(revision: 1, checkedAt: report.checkedAt, results: [
            .init(feature: .officialDelete, status: .failed, detail: "failure")])
        XCTAssertEqual(CodexCompatibilityPresentation.availability(report, isCurrent: true)[2].state, .checkFailed)
        XCTAssertTrue(CodexCompatibilityPresentation.interfaceChecks(report)[2].passed)
    }

    func testSkippedTestProducesNonzeroExitAndRetainsDiagnostics() async throws {
        let result = try await run(behaviorStatus: .notTested)
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.automatedChecks, "incompleteOrFailed")
        XCTAssertTrue(result.savedReportReadbackPassed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("summary.txt").path))
    }

    func testEnvironmentChangeNeverReportsSuccess() async throws {
        let result = try await run(current: false)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.failure?["reason"], "environmentChanged")
        XCTAssertTrue(result.featureAvailability.allSatisfy { $0.state == .recheckRequired })
    }

    func testCorruptSavedEvidenceNeverReportsSuccess() async throws {
        let result = try await run(corruptCache: true)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.savedReportReadbackPassed)
    }

    func testBehaviorFailureRetainsPartialInspectionAndSanitizedError() async throws {
        let result = try await run(throwBehavior: true)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertNotNil(result.inspection)
        XCTAssertNil(result.inspection?.behavior)
        XCTAssertNotNil(result.failure)
        XCTAssertFalse(result.summary.contains("PRIVATE_ERROR_CONTENT"))
    }

    private func run(inspectOnly: Bool = false, behaviorStatus: CodexCompatibilityBehaviorStatus = .passed,
                     current: Bool = true, corruptCache: Bool = false, throwBehavior: Bool = false,
                     calls: Calls = Calls()) async throws -> CompatibilityRunReport {
        try await CompatibilityCommand.run(
            request: .init(providerExecutable: URL(fileURLWithPath: "/synthetic/codex"),
                           codexHome: root.appendingPathComponent("metadata"), diagnosticRunID: UUID()),
            inspectOnly: inspectOnly, homeSource: "fixture", source: .init(asmVersion: "fixture", revision: "fixture"),
            directory: root, factory: { cache in
                FixtureInspector(cache: cache, calls: calls, behaviorStatus: behaviorStatus,
                                 current: current, corruptCache: corruptCache, throwBehavior: throwBehavior)
            })
    }

    fileprivate static func fixture(version: String = "0.999.0", profile: String = "desktop-v34-extended") -> CodexCompatibilityReport {
        var report = CodexCompatibilityReport(
            revision: CodexCompatibilityReport.policyRevision, checkedAt: Date(timeIntervalSince1970: 1_000),
            provider: .init(path: "/synthetic/codex", version: version, sha256: String(repeating: "a", count: 64)),
            desktop: .init(path: "/synthetic/desktop", version: version, sha256: String(repeating: "b", count: 64)),
            environmentFingerprint: "fixture", desktopSchemaProfile: profile,
            results: CodexCompatibilityEvaluator.results(version: version, browsing: true, archive: true,
                restore: true, delete: true, desktopVersion: version,
                desktopSchemaProfile: profile, desktopMetadataAvailable: true),
            notes: [])
        report.desktopApplication = .init(version: "fixture", build: "1", fingerprint: "fixture")
        report.databaseChecks = CodexGhostRepairSnapshotAnalysisDatabase.allCases.map { .init(database: $0, issue: nil) }
        return report
    }
}

private actor Calls {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor FixtureInspector: CodexCompatibilityInspecting {
    let cache: URL
    let calls: Calls
    let behaviorStatus: CodexCompatibilityBehaviorStatus
    let current: Bool
    let corruptCache: Bool
    let throwBehavior: Bool

    init(cache: URL, calls: Calls, behaviorStatus: CodexCompatibilityBehaviorStatus,
         current: Bool, corruptCache: Bool, throwBehavior: Bool) {
        self.cache = cache; self.calls = calls; self.behaviorStatus = behaviorStatus
        self.current = current; self.corruptCache = corruptCache; self.throwBehavior = throwBehavior
    }

    func inspect(_ request: CodexCompatibilityRequest) async throws -> CodexCompatibilityReport {
        await calls.append("inspect")
        let report = CompatibilityCommandTests.fixture()
        try JSONEncoder().encode(report).write(to: cache)
        return report
    }

    func verifyBehavior(_ request: CodexCompatibilityRequest, confirmedFingerprint: String,
                        progress: @escaping @Sendable (String) async -> Void) async throws -> CodexCompatibilityReport {
        await calls.append("verifyBehavior")
        guard confirmedFingerprint == "fixture", !throwBehavior else {
            throw NSError(domain: "PRIVATE_ERROR_CONTENT", code: 7)
        }
        var report = CompatibilityCommandTests.fixture()
        report.behavior = .init(revision: 1, checkedAt: report.checkedAt,
            results: [CodexCompatibilityFeature.archiveRestore, .officialDelete, .desktopCleanup].map {
                .init(feature: $0, status: behaviorStatus, detail: "fixture")
            })
        try JSONEncoder().encode(report).write(to: cache)
        return report
    }

    func savedReport() async throws -> CodexCompatibilityReport? {
        await calls.append("savedReport")
        if corruptCache { return nil }
        return try JSONDecoder().decode(CodexCompatibilityReport.self, from: Data(contentsOf: cache))
    }

    func isCurrent(_ report: CodexCompatibilityReport, request: CodexCompatibilityRequest) async -> Bool {
        await calls.append("isCurrent")
        return current
    }

    func reviewSavedCompatibility(_ request: CodexCompatibilityRequest) async throws -> CodexCompatibilityReview {
        fatalError("The command must reopen evidence without launching a live provider.")
    }
}
