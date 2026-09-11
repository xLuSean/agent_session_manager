import Foundation
import XCTest
@testable import AgentSessionManagerCore

/// Synthetic Settings evidence for payload-only App Server fixtures. Never
/// writes the user's compatibility cache or tests an installed Codex runtime.
struct CodexCompatibilityTestSupport {
    let cache: URL
    let inspector: CodexCompatibilityInspector

    init(executable: URL, home: URL, version: String) async throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("asm-payload-cache-\(UUID().uuidString).json")
        inspector = .init(reportURL: cache, desktopCandidates: [])
        let request = CodexCompatibilityRequest(providerExecutable: executable, codexHome: home)
        var report = CodexCompatibilityReport(revision: CodexCompatibilityReport.policyRevision, checkedAt: Date(),
            provider: .init(path: executable.path, version: version, sha256: String(repeating: "a", count: 64)),
            desktop: nil, environmentFingerprint: "payload-fixture", desktopSchemaProfile: nil,
            results: CodexCompatibilityEvaluator.results(version: version, browsing: true, archive: true,
                restore: true, delete: true, desktopVersion: nil, desktopSchemaProfile: nil, desktopMetadataAvailable: false), notes: [])
        report.installation = try .read(request, desktopCandidates: [])
        try await inspector.saveInspection(report)
    }

    func cleanUp() throws {
        try FileManager.default.trashItem(at: cache, resultingItemURL: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
}
