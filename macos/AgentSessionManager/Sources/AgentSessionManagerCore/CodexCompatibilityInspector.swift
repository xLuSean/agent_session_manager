import CryptoKit
import CSQLite3
import Darwin
import Foundation
import CoreServices

/// On-device inspection and explicitly requested isolated behavior checks.
/// Cached observations require fresh environment admission at the client boundary;
/// they never change the built-in version lists or authorize Desktop cleanup.
public actor CodexCompatibilityInspector: CodexCompatibilityInspecting {
    private let reportURL: URL
    private let desktopCandidates: [URL]?
    private var runtimeVersions: [String: String] = [:]
    private var diagnosticEvents: [DiagnosticEvent] = []

    public func takeDiagnostics(runID: UUID) async -> [DiagnosticEvent] {
        let events = diagnosticEvents.filter { $0.metadata["check_id"] == runID.uuidString }
        diagnosticEvents.removeAll { $0.metadata["check_id"] == runID.uuidString }
        return events
    }

    private func record(_ request: CodexCompatibilityRequest, message: String,
                        level: DiagnosticLogLevel = .info, metadata: [String: String]) {
        guard let runID = request.diagnosticRunID else { return }
        diagnosticEvents.append(.init(level: level, category: .compatibility, message: message,
            metadata: metadata.merging(["check_id": runID.uuidString]) { _, value in value }))
        // Bound in-memory buffering too; persistent retention is owned by Logs.
        if diagnosticEvents.count > 200 { diagnosticEvents.removeFirst(diagnosticEvents.count - 200) }
    }
    static let retainedReportLimit = 15

    private struct ReportCache: Codable { let reports: [CodexCompatibilityReport] }

    public init(reportURL: URL? = nil, desktopCandidates: [URL]? = nil) {
        self.reportURL = reportURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.sean.AgentSessionManager/compatibility/latest-inspection.json")
        self.desktopCandidates = desktopCandidates
    }

    static func installedDesktopCandidates() -> [URL] {
        let registered = LSCopyApplicationURLsForBundleIdentifier("com.openai.codex" as CFString, nil)?
            .takeRetainedValue() as? [URL] ?? []
        let candidates = registered + [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app")
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public func savedReport() throws -> CodexCompatibilityReport? {
        try savedReports().first
    }

    private func savedReports() throws -> [CodexCompatibilityReport] {
        guard FileManager.default.fileExists(atPath: reportURL.path) else { return [] }
        let size = try reportURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 2_048_000 else { throw CheckError.invalidReport }
        let data = try Data(contentsOf: reportURL)
        let decoder = JSONDecoder()
        let reports: [CodexCompatibilityReport]
        if let cache = try? decoder.decode(ReportCache.self, from: data) {
            guard cache.reports.count <= Self.retainedReportLimit else { throw CheckError.invalidReport }
            reports = cache.reports
        } else {
            // Read the first inspection format without requiring another test.
            reports = [try decoder.decode(CodexCompatibilityReport.self, from: data)]
        }
        return reports.filter { $0.revision == CodexCompatibilityReport.policyRevision }.map {
            var report = $0
            if report.behavior?.revision != CodexCompatibilityBehaviorReport.policyRevision { report.behavior = nil }
            return report
        }
    }

    func saveInspection(_ report: CodexCompatibilityReport) throws {
        // A successful explicit check also replaces an unreadable old cache.
        var reports = (try? savedReports()) ?? []
        reports.removeAll { $0.environmentFingerprint == report.environmentFingerprint }
        reports.insert(report, at: 0)
        reports = Array(reports.prefix(Self.retainedReportLimit))
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(ReportCache(reports: reports)).write(to: reportURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
    }

    public func reviewSavedCompatibility(_ request: CodexCompatibilityRequest) throws -> CodexCompatibilityReview {
        let state = try installation(request)
        let reports = try savedReports()
        if let report = reports.first(where: { $0.installation == state }) {
            return .init(report: report, isCurrent: true, environmentFingerprint: report.environmentFingerprint,
                         providerVersion: report.provider.version, desktopVersion: report.desktop?.version)
        }
        // A changed installation needs a Settings check, not a background audit.
        // --version is small; do not hash binaries or inspect databases here.
        let work = try makeWorkDirectory()
        defer { _ = try? FileManager.default.trashItem(at: work, resultingItemURL: nil) }
        let data = try? command(request.providerExecutable, arguments: ["--version"], work: work)
        let providerVersion = data.flatMap { CodexAppServerProvider.runtimeVersion(fromVersionOutput: String(decoding: $0, as: UTF8.self)) }
        let desktopRuntime = state.desktop?.files.first { $0.requestedPath.hasSuffix("/Contents/Resources/codex") }
        let desktopData = desktopRuntime.flatMap { try? command(URL(fileURLWithPath: $0.requestedPath), arguments: ["--version"], work: work) }
        let desktopVersion = desktopData.flatMap { CodexAppServerProvider.runtimeVersion(fromVersionOutput: String(decoding: $0, as: UTF8.self)) }
        guard try installation(request) == state else { throw CheckError.changed }
        return .init(report: reports.first, isCurrent: false, environmentFingerprint: state.fingerprint,
                     providerVersion: providerVersion, desktopVersion: desktopVersion)
    }

    private func installation(_ request: CodexCompatibilityRequest) throws -> CodexCompatibilityInstallation {
        try .read(request, desktopCandidates: desktopCandidates ?? Self.installedDesktopCandidates())
    }

    private func matchingReport(_ request: CodexCompatibilityRequest) throws -> CodexCompatibilityReport {
        let current = try installation(request)
        guard let report = try savedReports().first(where: { $0.installation == current }) else {
            throw CheckError.admissionRequired
        }
        return report
    }

    private func makeWorkDirectory() throws -> URL {
        let work = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("asm-compatibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return work
    }

    public func isCurrent(_ report: CodexCompatibilityReport, request: CodexCompatibilityRequest) -> Bool {
        guard report.revision == CodexCompatibilityReport.policyRevision else { return false }
        guard let saved = report.installation else { return false }
        return (try? installation(request)) == saved
    }

    /// Reads cached results and cheap installation metadata only.
    /// It never runs behavioral tests, invokes lifecycle APIs or changes a report.
    func lifecycleAdmission(_ request: CodexCompatibilityRequest, runtimeVersion: String,
                            feature: CodexCompatibilityFeature) throws -> CodexCompatibilityAdmission {
        let report = try matchingReport(request)
        guard
              let admission = CodexCompatibilityAdmission.evaluate(report: report, request: request,
                currentFingerprint: report.environmentFingerprint, runtimeVersion: runtimeVersion, feature: feature)
        else { throw CheckError.admissionRequired }
        return admission
    }

    /// A candidate allows only initialization to discover the actual home.
    /// It is not enough to send a mutation; lifecycleAdmission must follow.
    func hasLifecycleCandidate(executable: URL, runtimeVersion: String,
                               feature: CodexCompatibilityFeature) throws -> Bool {
        let stamp = try CodexCompatibilityInstallation.FileStamp.read(executable)
        return try savedReports().contains { report in
            return report.provider.path == executable.path && report.provider.version == runtimeVersion
                && report.installation?.provider == stamp
                && report.permitsSavedLifecycleFeature(feature)
        }
    }

    func requireCurrent(_ admission: CodexCompatibilityAdmission,
                        request: CodexCompatibilityRequest) throws {
        guard Date().timeIntervalSince(admission.issuedAt) >= -5,
              Date().timeIntervalSince(admission.issuedAt) <= 60,
              request.codexHome?.standardizedFileURL == admission.codexHome else { throw CheckError.admissionRequired }
        let current = try lifecycleAdmission(request, runtimeVersion: admission.runtime.version, feature: admission.feature)
        guard current.environmentFingerprint == admission.environmentFingerprint,
              current.runtime == admission.runtime else { throw CheckError.admissionRequired }
    }

    func lifecycleBinding(_ request: CodexCompatibilityRequest, runtimeVersion: String) throws -> CodexCompatibilityBinding? {
        guard let report = try? matchingReport(request) else { return nil }
        let passed = [CodexCompatibilityFeature.archiveRestore, .officialDelete].filter {
            CodexCompatibilityAdmission.evaluate(report: report, request: request,
                currentFingerprint: report.environmentFingerprint, runtimeVersion: runtimeVersion, feature: $0) != nil
        }
        guard !passed.isEmpty else { return nil }
        return .init(revision: 1, runtimeVersion: runtimeVersion,
            environmentFingerprint: report.environmentFingerprint, features: passed)
    }

    public func inspect(_ request: CodexCompatibilityRequest) throws -> CodexCompatibilityReport {
        try Task.checkCancellation()
        let installedBefore = try installation(request)
        let before = try environment(request)
        let work = try makeWorkDirectory()
        // Temporary schemas contain no user sessions. Retain the exact folder
        // if macOS cannot move it to Trash; never replace this with hard delete.
        defer { _ = try? FileManager.default.trashItem(at: work, resultingItemURL: nil) }
        let provider = try runtime(request.providerExecutable, work: work)
        let desktop = before.desktopURL.flatMap { try? runtime($0, work: work) }
        let schemas = work.appendingPathComponent("schema")
        _ = try command(request.providerExecutable, arguments: ["app-server", "generate-json-schema", "--out", schemas.path], work: work)
        let contract = try CodexCompatibilitySchema.read(directory: schemas)
        let after = try environment(request)
        try Task.checkCancellation()
        try requireSameEnvironment(before, after)
        guard try installation(request) == installedBefore else { throw CheckError.changed }
        var report = CodexCompatibilityReport(
            revision: CodexCompatibilityReport.policyRevision, checkedAt: Date(),
            provider: provider, desktop: desktop, environmentFingerprint: after.fingerprint,
            desktopSchemaProfile: after.desktopProfile,
            results: CodexCompatibilityEvaluator.results(
                version: provider.version, browsing: contract.browsing,
                archive: contract.archive, restore: contract.restore, delete: contract.delete,
                desktopVersion: desktop?.version, desktopSchemaProfile: after.desktopProfile,
                desktopMetadataAvailable: desktop != nil && after.desktopMetadataAvailable,
                desktopDatabaseChecks: after.databaseChecks,
                desktopIdentityVerified: after.desktopApplication != nil),
            notes: ["Read-only inspection. No session was created, archived, restored or deleted.",
                    "Schema checks are not behavioral acceptance. This report does not unlock new runtime versions.",
                    "Up to \(Self.retainedReportLimit) environment results are remembered locally. Startup compares them without rerunning tests."])
        report.databaseChecks = after.databaseChecks
        report.desktopApplication = after.desktopApplication
        report.diagnosticRunID = request.diagnosticRunID
        report.installation = installedBefore
        report.behavior = try? savedReports().first { $0.environmentFingerprint == after.fingerprint }?.behavior
        try saveInspection(report)
        record(request, message: "Compatibility interfaces inspected", metadata: [
            "cli_version": provider.version, "desktop_runtime_version": desktop?.version ?? "unavailable",
            "desktop_app_version": after.desktopApplication?.version ?? "unavailable"])
        for result in report.results {
            record(request, message: "Feature compatibility result",
                level: result.status == .supportedByBuild ? .info : .warning,
                metadata: ["feature": result.feature.rawValue, "outcome": result.status.rawValue])
        }
        return report
    }

    public func verifyBehavior(_ request: CodexCompatibilityRequest, confirmedFingerprint: String,
                               progress: @escaping @Sendable (String) async -> Void) async throws -> CodexCompatibilityReport {
        let installedBefore = try installation(request)
        let before = try environment(request)
        guard before.fingerprint == confirmedFingerprint,
              var report = try savedReports().first(where: { $0.environmentFingerprint == confirmedFingerprint }) else {
            throw before.databaseChecks.contains(where: { $0.issue == .unavailable })
                ? CheckError.metadataUnavailable : CheckError.changed
        }
        var results: [CodexCompatibilityBehaviorResult] = []
        for feature in [CodexCompatibilityFeature.archiveRestore, .officialDelete] {
            try Task.checkCancellation()
            try requireSameEnvironment(before, environment(request))
            let required: [CodexCompatibilityFeature] = feature == .officialDelete
                ? [.browsing, .archiveRestore, .officialDelete] : [.browsing, .archiveRestore]
            guard required.allSatisfy({ candidate in
                report.results.contains { $0.feature == candidate && [.supportedByBuild, .needsBehaviorVerification].contains($0.status) }
            }) else {
                results.append(.init(feature: feature, status: .notTested,
                    detail: "Required interface checks did not pass. No test session was created for this feature."))
                record(request, message: "Isolated feature test skipped: interface checks did not pass", level: .warning,
                       metadata: ["feature": feature.rawValue, "outcome": "skipped"])
                continue
            }
            await progress(feature == .archiveRestore ? "Testing archive and restore in isolation…" : "Testing deletion in isolation…")
            let started = Date()
            results.append(try CodexCompatibilityBehaviorRunner.run(executable: request.providerExecutable,
                expectedSHA256: report.provider.sha256, feature: feature))
            record(request, message: "Isolated feature test finished", level: results.last!.status == .passed ? .info : .warning, metadata: [
                "feature": feature.rawValue, "outcome": results.last!.status.rawValue,
                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1_000))])
        }
        try Task.checkCancellation()
        try requireSameEnvironment(before, environment(request))
        await progress("Checking Desktop cleanup SQL with synthetic data…")
        let desktopReady = before.desktopMetadataAvailable && before.databaseChecks.allSatisfy({ $0.issue == nil }) && report.results.contains {
            $0.feature == .desktopCleanup && [.supportedByBuild, .needsBehaviorVerification].contains($0.status)
        }
        if desktopReady {
            let started = Date()
            results.append(try CodexCompatibilityDesktopProbe.run(profileIdentifier: before.desktopProfile))
            record(request, message: "Desktop SQL self-test finished", level: results.last!.status == .passed ? .info : .warning, metadata: [
                "outcome": results.last!.status.rawValue,
                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1_000))])
        } else {
            let blockers = before.databaseChecks.filter { $0.issue != nil }.map {
                "\($0.fileName): \($0.readFailure?.detail ?? $0.issue!.detail)"
            }.joined(separator: " ")
            results.append(.init(feature: .desktopCleanup, status: .notTested,
                detail: "Skipped because required Desktop checks did not pass. \(blockers.isEmpty ? "Review the Desktop runtime and application checks." : blockers) No private database was changed."))
            record(request, message: "Desktop SQL self-test skipped: prerequisite checks did not pass",
                   level: .warning, metadata: ["feature": "desktopCleanup", "outcome": "skipped"])
        }
        try Task.checkCancellation()
        try requireSameEnvironment(before, environment(request))
        report.behavior = .init(revision: CodexCompatibilityBehaviorReport.policyRevision,
                                checkedAt: Date(), results: results)
        report.diagnosticRunID = request.diagnosticRunID
        guard try installation(request) == installedBefore else { throw CheckError.changed }
        report.installation = installedBefore
        try saveInspection(report)
        return report
    }

    enum CheckError: Error, LocalizedError {
        case unavailable, metadataUnavailable, invalidReport, changed, processFailed, timedOut, admissionRequired
        case processExit(Int32)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Required local runtime or metadata is unavailable. No permissions changed."
            case .metadataUnavailable: "Database metadata could not be read consistently. This does not mean Codex was updated or is incompatible. Review database diagnostics, then check again."
            case .invalidReport: "The saved compatibility report is invalid. Run a new check."
            case .changed: "Codex changed during inspection. Run a new check after the update finishes."
            case .processFailed: "The local runtime could not complete the isolated interface check. No session operations were sent."
            case .processExit(let status): "The isolated interface check exited with code \(status). No session operations were sent."
            case .timedOut: "The local interface check timed out. No session operations were sent."
            case .admissionRequired: "This Codex environment has no current successful compatibility test for this operation. Open Settings → Compatibility and run the check. No new lifecycle request was sent."
            }
        }
    }

    private struct Environment {
        let fingerprint: String
        let desktopURL: URL?
        let desktopProfile: String?
        let desktopMetadataAvailable: Bool
        let databaseChecks: [CodexCompatibilityDatabaseCheck]
        let providerSHA: String
        let desktopSHA: String?
        let desktopApplication: CodexCompatibilityDesktopApplication?
    }

    private func requireSameEnvironment(_ before: Environment, _ after: Environment) throws {
        guard before.fingerprint != after.fingerprint else { return }
        throw (before.databaseChecks + after.databaseChecks).contains(where: { $0.issue == .unavailable })
            ? CheckError.metadataUnavailable : CheckError.changed
    }

    private func environment(_ request: CodexCompatibilityRequest) throws -> Environment {
        let providerSHA = try digest(request.providerExecutable)
        var parts = ["policy=\(CodexCompatibilityReport.policyRevision)", request.providerExecutable.path,
                     providerSHA, request.codexHome?.standardizedFileURL.path ?? "no-home"]
        var desktopURL: URL?
        var desktopSHA: String?
        var desktopApplication: CodexCompatibilityDesktopApplication?
        for app in desktopCandidates ?? Self.installedDesktopCandidates() {
            let plistURL = app.appendingPathComponent("Contents/Info.plist")
            guard let size = try? plistURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 1_048_576, let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["CFBundleIdentifier"] as? String == "com.openai.codex" else { continue }
            desktopURL = app.appendingPathComponent("Contents/Resources/codex")
            desktopSHA = try? digest(desktopURL!)
            parts += [app.path, Self.hash(data), desktopSHA ?? "runtime-unavailable"]
            if let identity = try? CodexCompatibilityDesktopApplicationReader.read(app) {
                desktopApplication = identity.application
                desktopURL = identity.runtimeURL
                desktopSHA = identity.runtimeSHA256
                parts.append(identity.application.fingerprint)
            } else {
                parts.append("desktop-bundle-unverified")
            }
            break
        }
        if desktopURL == nil { parts.append("no-desktop") }
        var desktopProfile: String?
        var databaseChecks: [CodexCompatibilityDatabaseCheck] = []
        var metadataAvailable = request.codexHome != nil
        if let home = request.codexHome {
            // Schema definitions only; never SELECT from a session/automation table.
            for database in CodexGhostRepairSnapshotAnalysisDatabase.allCases {
                let name = database.canonicalFile.rawValue
                let url = database.canonicalFile.sourceURL(codexHomeURL: home, sqliteRootURL: home.appendingPathComponent("sqlite"))
                let started = Date()
                var diagnostic: [String: String] = ["database": name, "stage": "databaseMetadata"]
                do {
                    let metadata = try CodexCompatibilityDatabase.metadata(at: url)
                    guard let check = metadata.check else { throw CheckError.unavailable }
                    parts += [name, metadata.fingerprint]
                    databaseChecks.append(check)
                    if database == .desktop {
                        desktopProfile = metadata.desktopProfile
                    }
                    diagnostic["outcome"] = check.issue?.rawValue ?? "passed"
                    diagnostic["read_method"] = metadata.readMethod
                } catch {
                    parts.append("\(name):unavailable")
                    let failure = error as? CodexCompatibilityReadFailure
                    var check = CodexCompatibilityDatabaseCheck(database: database, issue: .unavailable)
                    check.readFailure = failure
                    databaseChecks.append(check)
                    metadataAvailable = false
                    diagnostic["outcome"] = "unavailable"
                    diagnostic["failure_stage"] = failure?.stage.rawValue ?? "unknown"
                    diagnostic["error_source"] = failure?.source.rawValue ?? "other"
                    diagnostic["error_code"] = failure.map { String($0.code) } ?? "unavailable"
                    if let code = failure?.systemCode { diagnostic["os_errno"] = String(code) }
                    if let files = failure?.sidecars {
                        diagnostic["wal"] = files.wal.rawValue
                        diagnostic["shm"] = files.shm.rawValue
                        diagnostic["journal"] = files.journal.rawValue
                    }
                }
                diagnostic["elapsed_ms"] = String(Int(Date().timeIntervalSince(started) * 1_000))
                record(request, message: "Database metadata check", level: diagnostic["outcome"] == "passed" ? .info : .warning,
                       metadata: diagnostic)
            }
        } else {
            databaseChecks = CodexGhostRepairSnapshotAnalysisDatabase.allCases.map { .init(database: $0, issue: .unavailable) }
        }
        return .init(fingerprint: Self.hash(Data(parts.joined(separator: "\n").utf8)),
                     desktopURL: desktopURL, desktopProfile: desktopProfile, desktopMetadataAvailable: metadataAvailable,
                     databaseChecks: databaseChecks,
                     providerSHA: providerSHA, desktopSHA: desktopSHA, desktopApplication: desktopApplication)
    }

    private func runtime(_ url: URL, work: URL) throws -> CodexCompatibilityRuntime {
        let sha = try digest(url)
        let key = url.path + ":" + sha
        if let version = runtimeVersions[key] {
            return .init(path: url.path, version: version, sha256: sha)
        }
        let output = try command(url, arguments: ["--version"], work: work)
        guard let text = String(data: output, encoding: .utf8),
              let version = CodexAppServerProvider.runtimeVersion(fromVersionOutput: text) else { throw CheckError.unavailable }
        guard sha == (try digest(url)) else { throw CheckError.changed }
        if runtimeVersions.count >= 16 { runtimeVersions.removeAll() }
        runtimeVersions[key] = version
        return .init(path: url.path, version: version, sha256: sha)
    }

    private func digest(_ url: URL) throws -> String {
        try Self.executableSHA256(url)
    }

    static func executableSHA256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        // FileHandle's autoreleased NSData can otherwise retain every chunk
        // for the duration of a long-running Swift concurrency job.
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func command(_ executable: URL, arguments: [String], work: URL) throws -> Data {
        try Task.checkCancellation()
        let runtimePath = try CodexCompatibilitySandbox.canonicalPath(executable)
        let profile = try CodexCompatibilitySandbox.profile(executable: executable, work: work)
        let outputURL = work.appendingPathComponent("command-output-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, runtimePath] + arguments
        process.environment = CodexCompatibilitySandbox.environment(work: work)
        // Interface generation uses explicit output paths, not the user's cwd.
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 30) == .success else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = finished.wait(timeout: .now() + 2)
            throw CheckError.timedOut
        }
        guard process.terminationStatus == 0 else { throw CheckError.processExit(process.terminationStatus) }
        try Task.checkCancellation()
        guard let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576 else { throw CheckError.processFailed }
        return try Data(contentsOf: outputURL)
    }
}
