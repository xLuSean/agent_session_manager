import AgentSessionManagerCore
import Foundation

struct CompatibilityOptions {
    var inspectOnly = false
    var help = false
    var executable: URL?
    var home: URL
    var homeSource: String
    var outputRoot: URL

    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
         userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws {
        home = userHome.appendingPathComponent(".codex")
        homeSource = "default ~/.codex"
        outputRoot = workingDirectory.appendingPathComponent("tmp/compatibility-reports")
        if let value = environment["CODEX_HOME"], !value.isEmpty {
            home = try Self.absolutePath(value)
            homeSource = "CODEX_HOME"
        }
        var seen = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard seen.insert(argument).inserted else { throw UsageError("Duplicate option: \(argument)") }
            switch argument {
            case "--help", "-h": help = true
            case "--inspect-only": inspectOnly = true
            case "--codex-executable", "--codex-home", "--output-root":
                index += 1
                guard index < arguments.count else { throw UsageError("Missing value for \(argument)") }
                let url = try Self.absolutePath(arguments[index])
                switch argument {
                case "--codex-executable": executable = url
                case "--codex-home": home = url; homeSource = "--codex-home"
                default: outputRoot = url
                }
            default: throw UsageError("Unknown option: \(argument)")
            }
            index += 1
        }
    }

    private static func absolutePath(_ value: String) throws -> URL {
        guard value.hasPrefix("/"), !value.contains("\0") else {
            throw UsageError("Paths must be absolute (expand ~ in your shell).")
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    static let usage = """
    Usage: ./scripts/check_codex_compatibility.sh [options]

    Runs ASM's interface/database checks and all three isolated behavior tests.
    No real conversations are changed. Desktop cleanup support is reported separately.
    Reports are independent of the App cache and do not enable App features.

      --inspect-only             Only inspect interfaces and database metadata
      --codex-executable /path    Select CLI (default: ASM's executable resolver)
      --codex-home /path          Metadata location (default: CODEX_HOME or ~/.codex)
      --output-root /path         Create a new private run directory here
      --help                     Show this help

    Output: report.json, summary.txt, inspection-cache.json in a unique run directory.
    The wrapper defaults to this repository's tmp/compatibility-reports.
    Exit codes: 0 requested checks passed; 2 checks failed/skipped/unavailable;
                1 run or report verification failed; 64 invalid arguments.
    Exit 0 does not mean Desktop cleanup is enabled. No Desktop restart is performed.
    """
}

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct CompatibilitySource: Codable {
    let asmVersion: String
    let revision: String
}

struct CompatibilityRunReport: Codable {
    let formatVersion: Int
    let completedAt: Date
    let source: CompatibilitySource
    let mode: String
    let codexHome: String
    let homeSource: String
    let automatedChecks: String
    let exitCode: Int32
    let savedReportReadbackPassed: Bool
    let environmentIsCurrent: Bool
    let appCacheUpdated: Bool
    let desktopRestartTested: Bool
    let interfaceChecks: [CodexCompatibilityInterfaceCheck]
    let featureAvailability: [CodexCompatibilityFeatureAvailability]
    let inspection: CodexCompatibilityReport?
    let diagnostics: [DiagnosticEvent]
    let failure: [String: String]?

    var summary: String {
        var lines = [
            "ASM compatibility: \(automatedChecks) (exit \(exitCode))",
            "Source: \(source.asmVersion), \(source.revision)",
            "Mode: \(mode); checked: \(ISO8601DateFormatter().string(from: completedAt))",
            "Codex home: \(codexHome) (\(homeSource); not discovered through a live session)",
        ]
        if let inspection {
            lines += [
                "CLI: \(inspection.provider.version)",
                "Desktop bundled CLI: \(inspection.desktop?.version ?? "unavailable")",
                "Desktop App: \(inspection.desktopApplication.map { "\($0.version) (\($0.build))" } ?? "unavailable")",
                "", "Interface checks:",
            ]
            lines += interfaceChecks.map { "  \($0.feature.label): \($0.label)" }
            lines += ["", "Database structure checks:"]
            lines += (inspection.databaseChecks ?? []).map { "  \($0.fileName): \($0.label)" }
            lines += ["", "Isolated behavior tests:"]
            if let behavior = inspection.behavior {
                lines += behavior.results.map { "  \($0.feature == .desktopCleanup ? "Desktop cleanup SQL self-test" : $0.feature.label): \($0.status.label)\n    \($0.detail)" }
            } else {
                lines.append("  Not requested or not reached.")
            }
        }
        lines += ["", "Feature availability for this source build (App cache unchanged):"]
        for row in featureAvailability {
            lines.append("  \(row.feature.label): \(row.label)")
            if let next = row.nextStep { lines.append("    \(next)") }
        }
        if let failure { lines.append("Run failure: \(failure.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))") }
        lines += [
            "", "Saved report readback: \(savedReportReadbackPassed ? "passed" : "not verified")",
            "Environment still matches: \(environmentIsCurrent ? "yes" : "not verified")",
            "App cache unchanged. Real Desktop cleanup and restart were not tested.",
            "These results describe the source build above; an installed ASM may use different code.",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}

enum CompatibilityCommand {
    typealias InspectorFactory = (URL) -> any CodexCompatibilityInspecting

    /// Always create a fresh namespace. No CLI option can select the App cache file.
    static func createRunDirectory(outputRoot: URL, codexHome: URL,
                                   userHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let root = canonicalDestination(outputRoot)
        let protectedRoots = [codexHome, userHome.appendingPathComponent("Library/Application Support/com.sean.AgentSessionManager")]
        for protected in protectedRoots.map(canonicalDestination) {
            guard root.path != protected.path, !root.path.hasPrefix(protected.path + "/") else {
                throw UsageError("Report output must be outside Codex data and ASM's App state directory.")
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let run = root.appendingPathComponent("run-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return run
    }

    // Foundation may leave symlink parents unresolved when the leaf does not
    // exist yet. Resolve the existing ancestor before appending new components.
    private static func canonicalDestination(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath()
        for name in suffix.reversed() { result.appendPathComponent(name) }
        return result
    }

    static func run(request: CodexCompatibilityRequest, inspectOnly: Bool, homeSource: String,
                    source: CompatibilitySource, directory: URL,
                    factory: InspectorFactory = { CodexCompatibilityInspector(reportURL: $0) },
                    progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> CompatibilityRunReport {
        let cache = directory.appendingPathComponent("inspection-cache.json")
        let inspector = factory(cache)
        var inspection: CodexCompatibilityReport?
        var failure: [String: String]?
        var readback = false
        var current = false
        do {
            await progress("Checking installed interfaces and database definitions…")
            let baseline = try await inspector.inspect(request)
            inspection = baseline
            if !inspectOnly {
                inspection = try await inspector.verifyBehavior(request, confirmedFingerprint: baseline.environmentFingerprint, progress: progress)
            }
            // Reopen independent persisted evidence, as the App does on restart.
            // This is not a claim that the App or Desktop was launched.
            let reopened = factory(cache)
            let saved = try await reopened.savedReport()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            readback = try saved.map { try encoder.encode($0) == encoder.encode(inspection!) } ?? false
            current = await reopened.isCurrent(inspection!, request: request)
            if !readback || !current {
                failure = ["reason": !readback ? "savedReportMismatch" : "environmentChanged"]
            }
        } catch {
            failure = CodexCompatibilityDiagnosticError.metadata(error)
        }
        let exitCode: Int32 = failure != nil ? 1
            : inspection.map { checksPassed($0, inspectOnly: inspectOnly) ? 0 : 2 } ?? 1
        let report = CompatibilityRunReport(
            formatVersion: 1, completedAt: Date(), source: source,
            mode: inspectOnly ? "inspectionOnly" : "inspectionAndIsolatedTests",
            codexHome: request.codexHome?.path ?? "unavailable", homeSource: homeSource,
            automatedChecks: exitCode == 0 ? "passed" : exitCode == 2 ? "incompleteOrFailed" : "runFailed",
            exitCode: exitCode, savedReportReadbackPassed: readback, environmentIsCurrent: current,
            appCacheUpdated: false, desktopRestartTested: false,
            interfaceChecks: inspection.map(CodexCompatibilityPresentation.interfaceChecks) ?? [],
            featureAvailability: inspection.map { CodexCompatibilityPresentation.availability($0, isCurrent: current) } ?? [],
            inspection: inspection, diagnostics: await inspector.takeDiagnostics(runID: request.diagnosticRunID ?? UUID()), failure: failure)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try write(encoder.encode(report), to: directory.appendingPathComponent("report.json"))
        try write(Data(report.summary.utf8), to: directory.appendingPathComponent("summary.txt"))
        return report
    }

    static func checksPassed(_ report: CodexCompatibilityReport, inspectOnly: Bool) -> Bool {
        guard report.revision == CodexCompatibilityReport.policyRevision,
              report.desktop != nil, report.desktopApplication != nil,
              let databases = report.databaseChecks, databases.count == 4,
              Set(databases.map(\.database)).count == 4,
              databases.allSatisfy({ $0.issue == nil }) else { return false }
        for feature in CodexCompatibilityFeature.allCases {
            let matches = report.results.filter { $0.feature == feature }
            guard matches.count == 1, [.supportedByBuild, .needsBehaviorVerification].contains(matches[0].status) else { return false }
        }
        if inspectOnly { return true }
        guard let behavior = report.behavior, behavior.revision == CodexCompatibilityBehaviorReport.policyRevision,
              behavior.results.count == 3 else { return false }
        return [CodexCompatibilityFeature.archiveRestore, .officialDelete, .desktopCleanup].allSatisfy { feature in
            let matches = behavior.results.filter { $0.feature == feature }
            return matches.count == 1 && matches[0].status == .passed
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        // The directory is newly created and private; never replace an old report.
        try data.write(to: url, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
