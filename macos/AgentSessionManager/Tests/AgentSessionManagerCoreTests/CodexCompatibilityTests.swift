import CSQLite3
import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexCompatibilityTests: XCTestCase {
    func testDatabaseLabelsDistinguishStructureSuccessFromUnavailableAndChanged() throws {
        let database = try XCTUnwrap(CodexGhostRepairSnapshotAnalysisDatabase.allCases.first)
        let passed = CodexCompatibilityDatabaseCheck(database: database, issue: nil)
        XCTAssertEqual(passed.label, "Structure check passed")
        XCTAssertEqual(CodexCompatibilityDatabaseCheck(database: database, issue: .unavailable).label, "Could not check")
        XCTAssertEqual(CodexCompatibilityDatabaseCheck(database: database, issue: .columns).label, "Structure changed")
        XCTAssertEqual(CodexCompatibilityPresentation.label(saved: passed.label, isCurrent: true,
                                                           isChecking: false, isComparing: false), passed.label)
        XCTAssertEqual(CodexCompatibilityPresentation.label(saved: passed.label, isCurrent: false,
                                                           isChecking: false, isComparing: false), "Recheck required")
        XCTAssertEqual(CodexCompatibilityPresentation.label(saved: passed.label, isCurrent: true,
                                                           isChecking: true, isComparing: false), "Verifying… · Previous: Structure check passed")
    }

    func testCompletionDoesNotDescribeSkippedTestsAsAllPassed() {
        var report = fixtureReport(revision: CodexCompatibilityReport.policyRevision)
        report.behavior = .init(revision: 1, checkedAt: Date(), results: [
            .init(feature: .archiveRestore, status: .passed, detail: "fixture"),
            .init(feature: .officialDelete, status: .passed, detail: "fixture"),
            .init(feature: .desktopCleanup, status: .notTested, detail: "fixture")])
        XCTAssertEqual(CodexCompatibilityPresentation.completion(report, behaviorRun: true),
                       "Isolated tests finished: 2 passed, 0 failed, 1 skipped.")
        XCTAssertTrue(CodexCompatibilityPresentation.completion(report, behaviorRun: false).contains("isolated tests are separate"))
    }

    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("asm-compat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["trash", root.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testNewVersionWithMatchingSchemaIsNotGrantedMutationPermission() {
        let results = CodexCompatibilityEvaluator.results(version: "0.999.0", browsing: true, archive: true, restore: true, delete: true,
            desktopVersion: "0.999.0", desktopSchemaProfile: "desktop-v34", desktopMetadataAvailable: true)
        XCTAssertEqual(results.map(\.status), [.supportedByBuild, .needsBehaviorVerification, .needsBehaviorVerification, .needsBehaviorVerification])
        XCTAssertFalse(CodexAppServerProvider.supportsVerifiedDeleteContract("0.999.0"))
    }

    func testFeatureFailuresDoNotBecomeGlobalBrowsingFailure() {
        let results = CodexCompatibilityEvaluator.results(version: "0.153.4", browsing: true, archive: true, restore: true, delete: false,
            desktopVersion: nil, desktopSchemaProfile: nil, desktopMetadataAvailable: false)
        XCTAssertEqual(results.map(\.status), [.supportedByBuild, .supportedByBuild, .incompatible, .unavailable])
    }

    func testDesktopAndProviderVersionsAreNotInterchangeable() {
        let known = CodexCompatibilityEvaluator.results(version: "0.153.2", browsing: true, archive: true, restore: true, delete: true,
            desktopVersion: "0.153.1", desktopSchemaProfile: "desktop-v34", desktopMetadataAvailable: true)
        XCTAssertEqual(known.last?.status, .supportedByBuild)
        let changed = CodexCompatibilityEvaluator.results(version: "0.153.2", browsing: true, archive: true, restore: true, delete: true,
            desktopVersion: "0.999.0", desktopSchemaProfile: "desktop-v34", desktopMetadataAvailable: true)
        XCTAssertEqual(changed.last?.status, .needsBehaviorVerification)
        XCTAssertEqual(changed[2].status, .needsBehaviorVerification)
    }

    func testSchemaChecksRejectNewRequiredArgumentsAndResponseDrift() throws {
        try writeSchemas()
        let good = try CodexCompatibilitySchema.read(directory: root)
        XCTAssertTrue(good.browsing && good.archive && good.restore && good.delete)
        try writeJSON("ThreadDeleteParams", ["type": "object", "required": ["threadId", "newConfirmation"],
            "properties": ["threadId": ["type": "string"], "newConfirmation": ["type": "string"]]])
        let drift = try CodexCompatibilitySchema.read(directory: root)
        XCTAssertTrue(drift.browsing && drift.archive && drift.restore)
        XCTAssertFalse(drift.delete)
        try writeJSON("ThreadListResponse", ["type": "object"])
        XCTAssertFalse(try CodexCompatibilitySchema.read(directory: root).browsing)
    }

    func testDatabaseFingerprintChangesForSchemaNotConversationData() throws {
        let database = root.appendingPathComponent("test.db")
        try execute(database, "CREATE TABLE conversations (id TEXT, private_body TEXT); INSERT INTO conversations VALUES ('fake', 'private fixture');")
        let before = try CodexCompatibilityDatabase.metadata(at: database)
        try execute(database, "UPDATE conversations SET private_body = 'different private fixture';")
        let dataChanged = try CodexCompatibilityDatabase.metadata(at: database)
        XCTAssertEqual(before.fingerprint, dataChanged.fingerprint)
        try execute(database, "ALTER TABLE conversations ADD COLUMN changed INTEGER;")
        let schemaChanged = try CodexCompatibilityDatabase.metadata(at: database)
        XCTAssertNotEqual(before.fingerprint, schemaChanged.fingerprint)
        XCTAssertNil(schemaChanged.desktopProfile)
    }

    func testKnownDesktopProfileRequiresColumnsAndIndexesNotJustVersion() throws {
        let database = root.appendingPathComponent("codex-dev.db")
        let profile = CodexGhostRepairDatabaseSchemaProfile.desktopV34
        var sql = "PRAGMA user_version=34;"
        for table in profile.desktopTables {
            var parts = table.columns.map { column in
                "\(column.name) \(column.declaredType)" + (column.notNull ? " NOT NULL" : "")
                    + (column.defaultValue.map { " DEFAULT \($0)" } ?? "")
            }
            let primary = table.columns.filter { $0.primaryKeyPosition > 0 }.sorted { $0.primaryKeyPosition < $1.primaryKeyPosition }
            if !primary.isEmpty { parts.append("PRIMARY KEY (\(primary.map(\.name).joined(separator: ",")))") }
            sql += "CREATE TABLE \(table.table) (\(parts.joined(separator: ",")));"
            for index in table.customIndexes {
                sql += "CREATE \(index.unique ? "UNIQUE " : "")INDEX \(index.name) ON \(table.table) (\(index.columns.joined(separator: ",")))\(index.partial ? " WHERE 1" : "");"
            }
        }
        try execute(database, sql)
        XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: database).desktopProfile, "desktop-v34")
        try execute(database, "DROP INDEX automations_owner_idx;")
        XCTAssertNil(try CodexCompatibilityDatabase.metadata(at: database).desktopProfile)
    }

    func testSavedReportInvalidatesOnPolicyChangeAndMalformedData() async throws {
        let path = root.appendingPathComponent("report.json")
        let inspector = CodexCompatibilityInspector(reportURL: path, desktopCandidates: [])
        let missing = try await inspector.savedReport()
        XCTAssertNil(missing)
        let report = fixtureReport(revision: 999)
        try JSONEncoder().encode(report).write(to: path)
        let obsolete = try await inspector.savedReport()
        XCTAssertNil(obsolete)
        try JSONEncoder().encode(fixtureReport(revision: 1)).write(to: path)
        let incompletePriorPolicy = try await inspector.savedReport()
        XCTAssertNil(incompletePriorPolicy, "Old version-only database checks must be inspected again")
        try JSONEncoder().encode(fixtureReport(revision: 2)).write(to: path)
        let priorAppIdentity = try await inspector.savedReport()
        XCTAssertNil(priorAppIdentity, "Reports without sealed Desktop App identity require a fresh check")
        try Data("not json".utf8).write(to: path)
        do { _ = try await inspector.savedReport(); XCTFail("Expected corrupt report rejection") } catch {}
    }

    func testStaleOrMissingRuntimeCannotReuseAReport() async throws {
        let executable = root.appendingPathComponent("fake-runtime")
        try Data("not an executable; hash only".utf8).write(to: executable)
        let inspector = CodexCompatibilityInspector(reportURL: root.appendingPathComponent("report.json"), desktopCandidates: [])
        let report = fixtureReport()
        let current = await inspector.isCurrent(report, request: .init(providerExecutable: executable, codexHome: root))
        XCTAssertFalse(current)
        let missing = await inspector.isCurrent(report, request: .init(providerExecutable: root.appendingPathComponent("missing"), codexHome: root))
        XCTAssertFalse(missing)
    }

    func testExplicitCheckDiagnosticsAreBoundedScopedAndDoNotLeakPaths() async throws {
        let executable = root.appendingPathComponent("private-runtime-path")
        try Data("hash-only fixture".utf8).write(to: executable)
        let inspector = CodexCompatibilityInspector(reportURL: root.appendingPathComponent("report.json"), desktopCandidates: [])
        let runID = UUID()
        _ = await inspector.isCurrent(fixtureReport(), request: .init(providerExecutable: executable, codexHome: root))
        let silent = await inspector.takeDiagnostics(runID: runID)
        XCTAssertTrue(silent.isEmpty)
        _ = await inspector.isCurrent(fixtureReport(), request: .init(providerExecutable: executable, codexHome: root, diagnosticRunID: runID))
        let wrongRun = await inspector.takeDiagnostics(runID: UUID())
        XCTAssertTrue(wrongRun.isEmpty)
        let events = await inspector.takeDiagnostics(runID: runID)
        XCTAssertEqual(events.count, 4)
        XCTAssertTrue(events.allSatisfy { $0.category == .compatibility && $0.metadata["failure_stage"] == "fileMetadata" })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(root.path))
        XCTAssertFalse(encoded.contains("private-runtime-path"))
        let drained = await inspector.takeDiagnostics(runID: runID)
        XCTAssertTrue(drained.isEmpty)
        for _ in 0..<51 {
            _ = await inspector.isCurrent(fixtureReport(), request: .init(providerExecutable: executable, codexHome: root, diagnosticRunID: runID))
        }
        let bounded = await inspector.takeDiagnostics(runID: runID)
        XCTAssertEqual(bounded.count, 200)
    }

    func testIsolatedInspectionSavesReportAndDeniesOutsideReadsAndWrites() async throws {
        let executable = root.appendingPathComponent("fixture-runtime")
        let privateFile = root.appendingPathComponent("private-fixture.txt")
        let outsideWrite = root.appendingPathComponent("unexpected-write")
        try Data("private fixture must not be read".utf8).write(to: privateFile)
        // The fixture is the only readable file outside the command's own work
        // directory. Any other read/write succeeding makes inspection fail.
        let script = """
        #!/bin/sh
        if /bin/cat '\(privateFile.path)' >/dev/null 2>/dev/null; then exit 88; fi
        if (printf forbidden >'\(outsideWrite.path)') 2>/dev/null; then exit 89; fi
        if [ "$1" = "--version" ]; then
            printf 'codex-cli 0.999.0\\n'
        elif [ "$1" = "app-server" ] && [ "$2" = "generate-json-schema" ] && [ "$3" = "--out" ]; then
            /bin/mkdir -p "$4/v2"
        else
            exit 90
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let inspector = CodexCompatibilityInspector(reportURL: root.appendingPathComponent("report.json"), desktopCandidates: [])
        let request = CodexCompatibilityRequest(providerExecutable: executable, codexHome: nil, diagnosticRunID: UUID())
        let report = try await inspector.inspect(request)
        XCTAssertEqual(report.diagnosticRunID, request.diagnosticRunID)
        XCTAssertEqual(report.provider.version, "0.999.0")
        XCTAssertEqual(report.results.first?.status, .incompatible)
        XCTAssertEqual(report.databaseChecks?.map(\.database), CodexGhostRepairSnapshotAnalysisDatabase.allCases)
        XCTAssertEqual(report.databaseChecks?.map(\.issue), [.unavailable, .unavailable, .unavailable, .unavailable])
        let saved = try await inspector.savedReport()
        XCTAssertEqual(saved, report)
        let current = await inspector.isCurrent(report, request: request)
        XCTAssertTrue(current)
        let restarted = CodexCompatibilityInspector(reportURL: root.appendingPathComponent("report.json"), desktopCandidates: [])
        let startup = try await restarted.reviewSavedCompatibility(request)
        XCTAssertTrue(startup.isCurrent)
        XCTAssertEqual(startup.report, report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideWrite.path))
        XCTAssertEqual(try String(contentsOf: privateFile, encoding: .utf8), "private fixture must not be read")
        try Data((script + "\n# runtime updated\n").utf8).write(to: executable)
        let stale = await inspector.isCurrent(report, request: request)
        XCTAssertFalse(stale)
        let changed = try await restarted.reviewSavedCompatibility(request)
        XCTAssertFalse(changed.isCurrent)
        XCTAssertEqual(changed.providerVersion, "0.999.0", "Same version with different executable bytes still invalidates evidence")
        // Record the second environment, then restore the first executable.
        let second = try await restarted.inspect(request)
        XCTAssertNotEqual(second.environmentFingerprint, report.environmentFingerprint)
        try Data(script.utf8).write(to: executable)
        let nextLaunch = CodexCompatibilityInspector(reportURL: root.appendingPathComponent("report.json"), desktopCandidates: [])
        let returned = try await nextLaunch.reviewSavedCompatibility(request)
        XCTAssertTrue(returned.isCurrent)
        XCTAssertEqual(returned.report, report, "An older matching environment is reusable after restart without a new inspection")
        let latest = try await nextLaunch.savedReport()
        XCTAssertEqual(latest, second, "Startup must not run or save a new inspection")
    }

    func testReportCacheIsBoundedAndReplacesOnlyMatchingEnvironment() async throws {
        let path = root.appendingPathComponent("report.json")
        let inspector = CodexCompatibilityInspector(reportURL: path, desktopCandidates: [])
        for index in 0..<18 {
            try await inspector.saveInspection(.init(revision: CodexCompatibilityReport.policyRevision,
                checkedAt: Date(timeIntervalSince1970: Double(index)), provider: fixtureReport().provider,
                desktop: nil, environmentFingerprint: "environment-\(index)", desktopSchemaProfile: nil, results: [], notes: []))
        }
        var cache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual((cache["reports"] as? [Any])?.count, 15)
        let saved = try await inspector.savedReport()
        let report = try XCTUnwrap(saved)
        XCTAssertEqual(report.environmentFingerprint, "environment-17")
        try await inspector.saveInspection(report)
        cache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual((cache["reports"] as? [Any])?.count, 15)
    }

    private func fixtureReport(revision: Int = CodexCompatibilityReport.policyRevision) -> CodexCompatibilityReport {
        .init(revision: revision, checkedAt: Date(), provider: .init(path: "fixture", version: "0.153.4", sha256: "fixture"),
              desktop: nil, environmentFingerprint: "obsolete", desktopSchemaProfile: nil, results: [], notes: [])
    }

    private func writeJSON(_ name: String, _ object: [String: Any]) throws {
        let directory = root.appendingPathComponent("v2")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("\(name).json"))
    }

    private func writeSchemas() throws {
        var properties: [String: Any] = [:]
        for (key, type) in ["id": "string", "sessionId": "string", "preview": "string", "ephemeral": "boolean",
                            "modelProvider": "string", "createdAt": "integer", "updatedAt": "integer", "cliVersion": "string"] {
            properties[key] = ["type": type]
        }
        properties["status"] = ["allOf": [["$ref": "#/definitions/ThreadStatus"]]]
        properties["cwd"] = ["allOf": [["$ref": "#/definitions/AbsolutePathBuf"]]]
        let definitions: [String: Any] = ["Thread": ["required": Array(properties.keys), "properties": properties],
            "ThreadStatus": ["oneOf": [["required": ["type"], "properties": ["type": ["type": "string"]]]]]]
        try writeJSON("ThreadListResponse", ["definitions": definitions, "properties": ["data": ["type": "array", "items": ["$ref": "#/definitions/Thread"]]]])
        try writeJSON("ThreadListParams", ["type": "object"])
        try writeJSON("ThreadReadResponse", ["definitions": definitions, "properties": ["thread": ["$ref": "#/definitions/Thread"]]])
        for prefix in ["ThreadArchive", "ThreadUnarchive", "ThreadDelete"] {
            let idOnly: [String: Any] = ["type": "object", "properties": ["threadId": ["type": "string"]], "required": ["threadId"]]
            try writeJSON("\(prefix)Params", idOnly)
            try writeJSON("\(prefix)dNotification", idOnly)
            try writeJSON("\(prefix)Response", prefix == "ThreadUnarchive"
                ? ["type": "object", "required": ["thread"], "properties": ["thread": ["$ref": "#/definitions/Thread"]], "definitions": definitions]
                : ["type": "object"])
        }
    }

    private func execute(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw NSError(domain: "Fixture", code: 1) }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
    }
}
