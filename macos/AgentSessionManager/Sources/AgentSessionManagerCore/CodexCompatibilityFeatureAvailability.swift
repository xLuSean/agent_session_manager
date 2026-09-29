import Foundation

/// Shared App/command-line presentation. These rows never grant operation authority.
public struct CodexCompatibilityFeatureAvailability: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case available, isolatedTestRequired, updateRequired, checkFailed, checkUnavailable, recheckRequired
    }

    public let feature: CodexCompatibilityFeature
    public let state: State
    public let label: String
    public let detail: String
    public let nextStep: String?
    public var id: CodexCompatibilityFeature { feature }
    public var isAvailable: Bool { state == .available }
}

public struct CodexCompatibilityInterfaceCheck: Codable, Equatable, Sendable, Identifiable {
    public let feature: CodexCompatibilityFeature
    public let label: String
    public let passed: Bool
    public var id: CodexCompatibilityFeature { feature }
}

extension CodexCompatibilityPresentation {
    public static func interfaceChecks(_ report: CodexCompatibilityReport) -> [CodexCompatibilityInterfaceCheck] {
        [CodexCompatibilityFeature.browsing, .archiveRestore, .officialDelete].map { feature in
            let matches = report.results.filter { $0.feature == feature }
            let passed = report.revision == CodexCompatibilityReport.policyRevision && matches.count == 1
                && [.supportedByBuild, .needsBehaviorVerification].contains(matches[0].status)
            let unavailable = matches.count != 1 || matches.first?.status == .unavailable
            return .init(feature: feature, label: passed ? "Interface check passed" : unavailable ? "Could not check" : "Interface changed",
                         passed: passed)
        }
    }

    public static func availability(_ report: CodexCompatibilityReport, isCurrent: Bool) -> [CodexCompatibilityFeatureAvailability] {
        typealias Row = CodexCompatibilityFeatureAvailability
        return CodexCompatibilityFeature.allCases.map { feature in
            func row(_ state: Row.State, _ label: String, _ detail: String, _ next: String? = nil) -> Row {
                .init(feature: feature, state: state, label: label, detail: detail, nextStep: next)
            }
            guard isCurrent, report.revision == CodexCompatibilityReport.policyRevision,
                  report.checkedAt <= Date().addingTimeInterval(5) else {
                return row(.recheckRequired, "Recheck required", "Saved evidence does not match the current environment.",
                           "Run Check Compatibility after Codex finishes updating.")
            }
            let matches = report.results.filter { $0.feature == feature }
            guard matches.count == 1 else {
                return row(.checkUnavailable, "Could not check", "Required feature evidence is missing or ambiguous.", "Run Check Compatibility.")
            }
            let result = matches[0]
            if result.status == .unavailable {
                return row(.checkUnavailable, "Could not check", result.detail, "Review the installation and database diagnostics, then run Check Compatibility.")
            }
            if result.status == .incompatible {
                return row(.checkFailed, "Compatibility check failed", result.detail, "This interface or structure needs an ASM compatibility update.")
            }
            if feature == .desktopCleanup {
                // Synthetic SQL evidence cannot admit a new Desktop runtime pair.
                if result.status == .supportedByBuild {
                    return row(.available, "Supported by this build", result.detail)
                }
                return row(.updateRequired, "Not enabled for this Codex version",
                           "Database and SQL test results are shown separately. Full Desktop cleanup, backup and restart acceptance is still required.",
                           "An ASM compatibility update is required after Desktop acceptance. Repeating isolated tests or deleting another conversation will not enable this feature.")
            }
            if feature == .browsing {
                return row(.available, "Supported by this build", result.detail)
            }
            if report.hasVerifiedBehavior(for: feature) {
                return row(.available, "Verified on this device",
                           "Isolated tests passed for this installation. Each operation still checks the current environment and selected sessions.")
            }
            // A recorded failure must not be hidden by built-in version support.
            if report.permitsSavedLifecycleFeature(feature, now: Date()) {
                return row(.available, "Supported by this build", result.detail)
            }
            if let behavior = report.behavior, behavior.revision == CodexCompatibilityBehaviorReport.policyRevision,
               behavior.results.contains(where: { $0.feature == feature && $0.status == .failed }) {
                return row(.checkFailed, "Isolated test failed", "This feature did not pass its isolated behavior test.",
                           "Review the test result and diagnostics before running the test again.")
            }
            return row(.isolatedTestRequired, "Isolated test required", "The interface matches, but this feature still needs a successful isolated test.",
                       "Run Isolated Compatibility Tests.")
        }
    }
}
