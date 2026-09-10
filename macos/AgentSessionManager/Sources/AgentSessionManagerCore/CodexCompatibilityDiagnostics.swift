import Foundation

/// Only controlled stages and numeric codes cross the diagnostic boundary.
/// Never retain sqlite3_errmsg, SQL, NSError descriptions/userInfo, or paths.
public struct CodexCompatibilityReadFailure: Error, Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case fileMetadata, fileValidation, open, transaction, prepare, readOnly, step, rowLimit, version
        case singleFileLock, sidecars, sourceChanged
    }
    public enum Source: String, Codable, Sendable { case sqlite, cocoa, posix, validation, other }
    public let stage: Stage
    public let source: Source
    public let code: Int
    public var systemCode: Int?
    public var sidecars: CodexCompatibilitySidecars?

    public var detail: String {
        let hint = source == .sqlite && (code & 255 == 5 || code & 255 == 6)
            ? " The database was busy or locked."
            : source == .sqlite && code & 255 == 14 ? " SQLite could not open the database." : ""
        let recovery = stage == .singleFileLock
            ? " A safe single-file read could not acquire access. Close Codex and its CLI sessions, then check again."
            : stage == .sourceChanged || stage == .sidecars ? " Database files changed or could not be verified. Check again when Codex is idle." : ""
        return "Metadata could not be read at \(stage.rawValue) (\(source.rawValue) code \(code)).\(hint)\(recovery) This is not a schema incompatibility result."
    }

    static func fileError(_ error: Error) -> Self {
        let error = error as NSError
        return .init(stage: .fileMetadata,
                     source: error.domain == NSCocoaErrorDomain ? .cocoa : error.domain == NSPOSIXErrorDomain ? .posix : .other,
                     code: error.code)
    }
}

/// Presentation only. It never changes cached evidence or operation admission.
public enum CodexCompatibilityPresentation {
    public static func completion(_ report: CodexCompatibilityReport, behaviorRun: Bool) -> String {
        if behaviorRun, let results = report.behavior?.results {
            return "Isolated tests finished: \(results.filter { $0.status == .passed }.count) passed, \(results.filter { $0.status == .failed }.count) failed, \(results.filter { $0.status == .notTested }.count) skipped."
        }
        let unchecked = report.results.filter { $0.status == .unavailable }.count
        let incompatible = report.results.filter { $0.status == .incompatible }.count
        return "Interface check finished: \(unchecked) could not be checked, \(incompatible) incompatible. Review feature results below; isolated tests are separate."
    }

    public static func label(saved: String, isCurrent: Bool, isChecking: Bool, isComparing: Bool) -> String {
        if isChecking { return "Verifying… · Previous: \(saved)" }
        if isComparing { return "Comparing… · Previous: \(saved)" }
        return isCurrent ? saved : "Recheck required"
    }
}

public enum CodexCompatibilityDiagnosticError {
    public static func metadata(_ error: Error) -> [String: String] {
        if let error = error as? CodexCompatibilityInspector.CheckError {
            let reason: String
            switch error {
            case .unavailable: reason = "unavailable"
            case .metadataUnavailable: reason = "metadataUnavailable"
            case .invalidReport: reason = "invalidReport"
            case .changed: reason = "environmentChanged"
            case .processFailed: reason = "processFailed"
            case .timedOut: reason = "timedOut"
            case .admissionRequired: reason = "admissionRequired"
            case .processExit(let code): return ["error_source": "runtimeExit", "error_code": String(code)]
            }
            return ["error_source": "compatibility", "reason": reason]
        }
        if error is CancellationError { return ["error_source": "cancellation"] }
        let failure = CodexCompatibilityReadFailure.fileError(error)
        return ["error_source": failure.source.rawValue, "error_code": String(failure.code)]
    }
}
