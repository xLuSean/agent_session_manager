import Foundation

public enum CodexCompatibilityFeature: String, CaseIterable, Codable, Sendable, Identifiable {
    case browsing, archiveRestore, officialDelete, desktopCleanup
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .browsing: "Browse, search and conversation sizes"
        case .archiveRestore: "Archive, restore and move to Trash"
        case .officialDelete: "Official session deletion"
        case .desktopCleanup: "Desktop residue cleanup"
        }
    }
}

public enum CodexCompatibilityStatus: String, Codable, Sendable {
    case supportedByBuild, needsBehaviorVerification, incompatible, unavailable
    public var label: String {
        switch self {
        case .supportedByBuild: "Supported by this build"
        case .needsBehaviorVerification: "Further verification needed"
        case .incompatible: "Incompatible"
        case .unavailable: "Could not check"
        }
    }
}

public struct CodexCompatibilityFeatureResult: Codable, Equatable, Sendable, Identifiable {
    public let feature: CodexCompatibilityFeature
    public let status: CodexCompatibilityStatus
    public let detail: String
    public var id: CodexCompatibilityFeature { feature }
}

public struct CodexCompatibilityRuntime: Codable, Equatable, Sendable {
    public let path: String
    public let version: String
    public let sha256: String
}

public enum CodexCompatibilityDatabaseIssue: String, Codable, Sendable {
    case unavailable, version, table, columns, indexes, triggers, foreignKeys

    public var detail: String {
        switch self {
        case .unavailable: "Could not read database metadata."
        case .version: "The database version is not recognized."
        case .table: "A required ordinary table is missing or has changed kind."
        case .columns: "Required columns or their supported definitions have changed."
        case .indexes: "The supported index set has changed."
        case .triggers: "Unreviewed triggers could change the cleanup's effects."
        case .foreignKeys: "Unreviewed foreign-key relationships require adaptation."
        }
    }
}

/// Metadata-only diagnostics. Never includes raw DDL, row values or user paths.
public struct CodexCompatibilityDatabaseCheck: Codable, Equatable, Sendable, Identifiable {
    public let database: CodexGhostRepairSnapshotAnalysisDatabase
    public let issue: CodexCompatibilityDatabaseIssue?
    public var readFailure: CodexCompatibilityReadFailure? = nil
    public var id: CodexGhostRepairSnapshotAnalysisDatabase { database }
    public var fileName: String { database.canonicalFile.rawValue }
    public var label: String { issue == nil ? "Structure check passed" : issue == .unavailable ? "Could not check" : "Structure changed" }
}

/// Inspection evidence is deliberately not a mutation permit. In particular,
/// schema compatibility cannot manufacture behavioral acceptance for Delete.
public struct CodexCompatibilityReport: Codable, Equatable, Sendable {
    public static let policyRevision = 4
    public let revision: Int
    public let checkedAt: Date
    public let provider: CodexCompatibilityRuntime
    public let desktop: CodexCompatibilityRuntime?
    public let environmentFingerprint: String
    public let desktopSchemaProfile: String?
    public let results: [CodexCompatibilityFeatureResult]
    public let notes: [String]
    public var behavior: CodexCompatibilityBehaviorReport? = nil
    public var databaseChecks: [CodexCompatibilityDatabaseCheck]? = nil
    public var desktopApplication: CodexCompatibilityDesktopApplication? = nil
    public var diagnosticRunID: UUID? = nil
    public var installation: CodexCompatibilityInstallation? = nil

    /// Display only; actual admission also rechecks the live environment and identity.
    public func hasVerifiedBehavior(for feature: CodexCompatibilityFeature) -> Bool {
        guard revision == Self.policyRevision,
              [.archiveRestore, .officialDelete].contains(feature),
              let behavior, behavior.revision == CodexCompatibilityBehaviorReport.policyRevision,
              checkedAt <= Date().addingTimeInterval(5),
              behavior.checkedAt <= Date().addingTimeInterval(5) else { return false }
        let required: [CodexCompatibilityFeature] = feature == .officialDelete
            ? [.browsing, .archiveRestore, .officialDelete] : [.browsing, .archiveRestore]
        guard required.allSatisfy({ candidate in
            let matches = results.filter { $0.feature == candidate }
            return matches.count == 1
                && [.supportedByBuild, .needsBehaviorVerification].contains(matches[0].status)
        }) else { return false }
        let observations = behavior.results.filter { $0.feature == feature }
        return observations.count == 1 && observations[0].status == .passed
    }
}

public enum CodexCompatibilityBehaviorStatus: String, Codable, Sendable {
    case passed, failed, notTested
    public var label: String {
        switch self {
        case .passed: "Passed"
        case .failed: "Failed"
        case .notTested: "Skipped"
        }
    }
}

public struct CodexCompatibilityBehaviorResult: Codable, Equatable, Sendable, Identifiable {
    public let feature: CodexCompatibilityFeature
    public let status: CodexCompatibilityBehaviorStatus
    public let detail: String
    public var id: CodexCompatibilityFeature { feature }
}

/// Saved observations, not a permit. The client admission boundary checks these
/// against the current environment before issuing short-lived in-memory evidence.
public struct CodexCompatibilityBehaviorReport: Codable, Equatable, Sendable {
    public static let policyRevision = 1
    public let revision: Int
    public let checkedAt: Date
    public let results: [CodexCompatibilityBehaviorResult]
}

public struct CodexCompatibilityRequest: Equatable, Sendable {
    public let providerExecutable: URL
    public let codexHome: URL?
    public let diagnosticRunID: UUID?
    public init(providerExecutable: URL, codexHome: URL?, diagnosticRunID: UUID? = nil) {
        self.providerExecutable = providerExecutable
        self.codexHome = codexHome
        self.diagnosticRunID = diagnosticRunID
    }
}

/// Startup comparison only. It reuses evidence; it never runs acceptance tests.
public struct CodexCompatibilityReview: Equatable, Sendable {
    public let report: CodexCompatibilityReport?
    public let isCurrent: Bool
    public let environmentFingerprint: String
    public let providerVersion: String?
    public let desktopVersion: String?
    public var metadataUnavailable = false
}

public protocol CodexCompatibilityInspecting: Sendable {
    func takeDiagnostics(runID: UUID) async -> [DiagnosticEvent]
    func inspect(_ request: CodexCompatibilityRequest) async throws -> CodexCompatibilityReport
    func savedReport() async throws -> CodexCompatibilityReport?
    func isCurrent(_ report: CodexCompatibilityReport, request: CodexCompatibilityRequest) async -> Bool
    func reviewSavedCompatibility(_ request: CodexCompatibilityRequest) async throws -> CodexCompatibilityReview
    func verifyBehavior(_ request: CodexCompatibilityRequest, confirmedFingerprint: String,
                        progress: @escaping @Sendable (String) async -> Void) async throws -> CodexCompatibilityReport
}

extension CodexCompatibilityInspecting {
    public func takeDiagnostics(runID: UUID) async -> [DiagnosticEvent] { [] }
    public func verifyBehavior(_ request: CodexCompatibilityRequest, confirmedFingerprint: String,
                               progress: @escaping @Sendable (String) async -> Void) async throws -> CodexCompatibilityReport {
        throw CodexCompatibilityInspector.CheckError.unavailable
    }
}

enum CodexCompatibilityEvaluator {
    static func results(
        version: String, browsing: Bool, archive: Bool, restore: Bool, delete: Bool,
        desktopVersion: String?, desktopSchemaProfile: String?, desktopMetadataAvailable: Bool,
        desktopDatabaseChecks: [CodexCompatibilityDatabaseCheck] = [], desktopIdentityVerified: Bool = true
    ) -> [CodexCompatibilityFeatureResult] {
        func result(_ feature: CodexCompatibilityFeature, schema: Bool, admitted: Bool) -> CodexCompatibilityFeatureResult {
            .init(feature: feature,
                  status: !schema ? .incompatible : admitted ? .supportedByBuild : .needsBehaviorVerification,
                  detail: !schema ? "The required interface or response format changed."
                    : admitted ? "The required interface matches this build's supported contract. Normal operation checks still apply."
                    : "Interface checks passed, but this runtime's behavior has not been verified. No new mutation permission was granted.")
        }
        let source = CodexGhostRepairSnapshotRequestBoundProfileSelection.selectProfile(exactRuntimeVersion: version)
        let databaseMismatch = desktopDatabaseChecks.contains { $0.issue != nil }
        let desktopPairMatches = source.map {
            $0.ownerRuntimeProfileIdentifier == desktopVersion.map { "desktop-bundled-\($0)" }
                && $0.databaseSchemaProfileIdentifier == desktopSchemaProfile
        } ?? false
        return [
            result(.browsing, schema: browsing, admitted: true),
            result(.archiveRestore, schema: browsing && archive && restore,
                   admitted: CodexAppServerProvider.supportsVerifiedLifecycleContract(version)),
            result(.officialDelete, schema: browsing && delete,
                   admitted: CodexAppServerProvider.supportsVerifiedDeleteContract(version)),
            .init(feature: .desktopCleanup,
                  status: !desktopMetadataAvailable ? .unavailable
                    : desktopSchemaProfile == nil || databaseMismatch ? .incompatible
                    : desktopPairMatches ? .supportedByBuild : !desktopIdentityVerified ? .unavailable : .needsBehaviorVerification,
                  detail: !desktopMetadataAvailable ? "Desktop App identity, bundled runtime or database metadata could not be verified. Review the App and database checks below. Other features are assessed separately."
                    : desktopSchemaProfile == nil || databaseMismatch ? "Required database structure differs from the supported cleanup contract. Review the database checks below."
                    : desktopPairMatches ? (desktopIdentityVerified
                        ? "Desktop table definitions match a supported runtime pair. Cleanup still performs its complete source, backup and exact-selection checks."
                        : "This known runtime pair matches the built-in cleanup contract. App signature verification is unavailable; this does not revoke built-in support or admit unknown Desktop versions. Normal cleanup checks still apply.")
                    : !desktopIdentityVerified ? "This runtime pair is not built-in and its Desktop App identity could not be verified. New Desktop cleanup remains restricted."
                    : "Desktop table definitions match a known profile, but the runtime pair still needs behavioral verification.")
        ]
    }
}
