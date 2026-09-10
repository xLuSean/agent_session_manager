import Foundation

/// Persisted identity binding, not authority. Execution requires a fresh matching
/// inventory and the client's independent last-moment admission check.
public struct CodexCompatibilityBinding: Codable, Hashable, Sendable {
    public let revision: Int
    public let runtimeVersion: String
    public let environmentFingerprint: String
    public let features: [CodexCompatibilityFeature]

    func supports(_ kind: CodexLifecycleMutationKind, runtimeVersion: String?) -> Bool {
        revision == 1 && self.runtimeVersion == runtimeVersion
            && features.contains(kind == .permanentDelete ? .officialDelete : .archiveRestore)
    }
}

/// Short-lived, in-memory evidence for one feature in one freshly observed
/// environment. Never decoded from the saved report or persisted as a permit.
struct CodexCompatibilityAdmission: Equatable, Sendable {
    let feature: CodexCompatibilityFeature
    let runtime: CodexCompatibilityRuntime
    let environmentFingerprint: String
    let codexHome: URL
    let issuedAt: Date

    fileprivate init(feature: CodexCompatibilityFeature, report: CodexCompatibilityReport,
                     home: URL, now: Date) {
        self.feature = feature
        self.runtime = report.provider
        self.environmentFingerprint = report.environmentFingerprint
        self.codexHome = home
        self.issuedAt = now
    }

    static func evaluate(report: CodexCompatibilityReport, request: CodexCompatibilityRequest,
                         currentFingerprint: String, runtimeVersion: String,
                         feature: CodexCompatibilityFeature, now: Date = Date()) -> Self? {
        guard [.archiveRestore, .officialDelete].contains(feature),
              let home = request.codexHome, home.isFileURL, home.path.hasPrefix("/"),
              report.revision == CodexCompatibilityReport.policyRevision,
              report.environmentFingerprint == currentFingerprint,
              report.provider.path == request.providerExecutable.path,
              report.provider.version == runtimeVersion,
              report.provider.sha256.count == 64,
              report.provider.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              report.checkedAt <= now.addingTimeInterval(5),
              let behavior = report.behavior,
              behavior.revision == CodexCompatibilityBehaviorReport.policyRevision,
              behavior.checkedAt <= now.addingTimeInterval(5) else { return nil }
        // Duplicate or missing results are ambiguous, even if one says passed.
        let required: [CodexCompatibilityFeature] = feature == .officialDelete
            ? [.browsing, .archiveRestore, .officialDelete] : [.browsing, .archiveRestore]
        for candidate in required {
            let matches = report.results.filter { $0.feature == candidate }
            guard matches.count == 1,
                  [.supportedByBuild, .needsBehaviorVerification].contains(matches[0].status) else { return nil }
        }
        let observations = behavior.results.filter { $0.feature == feature }
        guard observations.count == 1, observations[0].status == .passed else { return nil }
        return .init(feature: feature, report: report, home: home.standardizedFileURL, now: now)
    }
}
