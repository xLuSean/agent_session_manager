import Foundation

public enum StateStoreLocationError: Error, Equatable, LocalizedError {
    case applicationSupportUnavailable
    case invalidBundleIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The user Application Support directory is unavailable."
        case let .invalidBundleIdentifier(identifier):
            "Invalid state-store bundle identifier: \(identifier)"
        }
    }
}

public enum StateStoreLocation {
    public static let defaultBundleIdentifier = "com.sean.AgentSessionManager"
    public static let databaseFileName = "state.sqlite"
    public static let diagnosticLogFileName = "diagnostic-events.jsonl"

    /// Resolves through FileManager so a future sandboxed build naturally uses
    /// its container Application Support directory instead of a hard-coded path.
    public static func applicationSupportDatabaseURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = defaultBundleIdentifier
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StateStoreLocationError.applicationSupportUnavailable
        }
        return try databaseURL(
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: bundleIdentifier
        )
    }

    public static func applicationSupportDiagnosticLogURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = defaultBundleIdentifier
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StateStoreLocationError.applicationSupportUnavailable
        }
        return try diagnosticLogURL(
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: bundleIdentifier
        )
    }

    public static func databaseURL(
        applicationSupportDirectory: URL,
        bundleIdentifier: String = defaultBundleIdentifier
    ) throws -> URL {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              !identifier.contains("/"),
              identifier != ".",
              identifier != ".." else {
            throw StateStoreLocationError.invalidBundleIdentifier(bundleIdentifier)
        }
        return applicationSupportDirectory
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent(databaseFileName, isDirectory: false)
    }

    public static func diagnosticLogURL(
        applicationSupportDirectory: URL,
        bundleIdentifier: String = defaultBundleIdentifier
    ) throws -> URL {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              !identifier.contains("/"),
              identifier != ".",
              identifier != ".." else {
            throw StateStoreLocationError.invalidBundleIdentifier(bundleIdentifier)
        }
        return applicationSupportDirectory
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent(diagnosticLogFileName, isDirectory: false)
    }
}
