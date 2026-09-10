import Foundation

enum CodexGhostRepairProductionRepairDatabaseRole:
    String,
    Codable,
    Equatable,
    Sendable
{
    case futureSingleTransactionMutation
    case validationReadbackOnly
}

/// The complete fixed database set that a packaged Category A repair
/// must account for. Only Desktop may ever enter the transaction write set;
/// every other database is validation/readback evidence.
enum CodexGhostRepairProductionRepairDatabase:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case desktop
    case summaries
    case state
    case threadHistory
    case legacyHistory

    var canonicalFile: CodexGhostRepairSnapshotCanonicalFile {
        switch self {
        case .desktop: .desktop
        case .summaries: .summaries
        case .state: .state
        case .threadHistory: .threadHistory
        case .legacyHistory: .history
        }
    }

    var isRequired: Bool {
        switch self {
        case .legacyHistory: false
        default: true
        }
    }

    var role: CodexGhostRepairProductionRepairDatabaseRole {
        switch self {
        case .desktop: .futureSingleTransactionMutation
        default: .validationReadbackOnly
        }
    }
}

struct CodexGhostRepairProductionRepairBundleCapabilities:
    Equatable,
    Sendable
{
    let sourceLayoutIdentifier =
        CodexGhostRepairSnapshotSourceLayout.identifier
    let acceptsCallerPath = false
    let constructionPerformsIO = false
    let opensFilesystem = false
    let opensSQLite = false
    let createsBackup = false
    let createsClaim = false
    let writesCodexDatabaseFiles = false
    let repairMutationAuthority = false
    let maximumTargetCount = 2
    let categoryAOnly = true
    let databaseGroupCount = 5
    let requiredDatabaseCount = 4
    let futureTransactionDatabaseCount = 1
}

/// A path-free, zero-I/O production capability boundary for M3.
///
/// Construction grants no read, backup, claim, SQLite or repair authority.
/// Explicit resolution only derives the fixed five-database layout; it does
/// not inspect or open any path. Later M3 slices must add their own fresh
/// operational, snapshot, evidence and one-shot authorization gates.
struct CodexGhostRepairProductionRepairBundle: Sendable {
    struct Resolution: Sendable {
        let codexHomeURL: URL
        let sqliteRootURL: URL
        private let databaseURLs:
            [CodexGhostRepairProductionRepairDatabase: URL]

        init(
            codexHomeURL: URL,
            sqliteRootURL: URL,
            databaseURLs:
                [CodexGhostRepairProductionRepairDatabase: URL]
        ) {
            self.codexHomeURL = codexHomeURL
            self.sqliteRootURL = sqliteRootURL
            self.databaseURLs = databaseURLs
        }

        func databaseURL(
            for database: CodexGhostRepairProductionRepairDatabase
        ) -> URL {
            databaseURLs[database]!
        }
    }

    private struct TestBoundary: Sendable {
        let allowedParentURL: URL
    }

    typealias RootResolver = @Sendable () -> URL

    let capabilities = CodexGhostRepairProductionRepairBundleCapabilities()

    private let rootResolver: RootResolver
    private let testBoundary: TestBoundary?

    /// No path parameter and no I/O. The canonical home is resolved only by
    /// an explicit later preflight call.
    static func production() -> Self {
        Self(
            rootResolver: {
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex", isDirectory: true)
            },
            testBoundary: nil
        )
    }

    /// Acceptance seam for lexical, test-owned roots. It intentionally does
    /// not require either path to exist, proving construction remains zero-I/O.
    init(
        testOwnedCodexHomeURL: URL,
        testOwnedAllowedParentURL: URL
    ) {
        rootResolver = { testOwnedCodexHomeURL }
        testBoundary = TestBoundary(
            allowedParentURL: testOwnedAllowedParentURL
        )
    }

    private init(
        rootResolver: @escaping RootResolver,
        testBoundary: TestBoundary?
    ) {
        self.rootResolver = rootResolver
        self.testBoundary = testBoundary
    }

    /// Derives only fixed URLs. No metadata read, file open or SQLite call is
    /// performed here, and the returned shape has no generic-path accessor.
    func resolveForPreflight() throws -> Resolution {
        let codexHome = rootResolver().standardizedFileURL
        let liveCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL

        if let testBoundary {
            let parent = testBoundary.allowedParentURL.standardizedFileURL
            guard codexHome.path != parent.path,
                  Self.isDescendant(codexHome, of: parent),
                  codexHome.path != liveCodexHome.path,
                  !Self.isDescendant(codexHome, of: liveCodexHome) else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Production repair test root escaped its fixed boundary."
                )
            }
        } else {
            guard codexHome.path == liveCodexHome.path else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Production repair source was not the canonical Codex home."
                )
            }
        }

        let sqliteRoot = codexHome.appendingPathComponent(
            "sqlite",
            isDirectory: true
        )
        let urls = Dictionary(uniqueKeysWithValues:
            CodexGhostRepairProductionRepairDatabase.allCases.map { database in
                (
                    database,
                    database.canonicalFile.sourceURL(
                        codexHomeURL: codexHome,
                        sqliteRootURL: sqliteRoot
                    )
                )
            }
        )
        return Resolution(
            codexHomeURL: codexHome,
            sqliteRootURL: sqliteRoot,
            databaseURLs: urls
        )
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && childComponents.prefix(parentComponents.count)
                == parentComponents[...]
    }
}
