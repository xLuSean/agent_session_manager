import Foundation

enum CodexGhostRepairBulkProductionDatabaseRole:
    String,
    Codable,
    Equatable,
    Sendable
{
    case futureSingleTransactionMutation
    case validationReadbackOnly
}

enum CodexGhostRepairBulkProductionDatabase:
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

    var required: Bool {
        switch self {
        case .legacyHistory: false
        default: true
        }
    }

    var role: CodexGhostRepairBulkProductionDatabaseRole {
        switch self {
        case .desktop: .futureSingleTransactionMutation
        default: .validationReadbackOnly
        }
    }
}

struct CodexGhostRepairBulkProductionBundleCapabilities:
    Equatable,
    Sendable
{
    let productionFactoryAvailable = true
    let sourceLayoutIdentifier =
        CodexGhostRepairSnapshotSourceLayout.identifier
    let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems
    let mixedOrdinaryAndAutomation = true
    let exactColdReadbackSourceRequired = true
    let selectedOnlySourceRequired = true
    let databaseGroupCount = 5
    let requiredDatabaseCount = 4
    let futureTransactionDatabaseCount = 1
    let acceptsCallerPath = false
    let constructionPerformsIO = false
    let resolutionPerformsIO = false
    let opensFilesystem = false
    let opensSQLite = false
    let createsBackup = false
    let createsClaim = false
    let writesCodexDatabaseFiles = false
    let productionFactoryAcceptsCallerPath = false
    let repairMutationAuthority = false
}

private struct CodexGhostRepairBulkProductionBundleDigestPayload:
    Codable,
    Hashable
{
    let requestID: UUID
    let previewID: UUID
    let previewPayloadHash: String
    let previewManifestDigest: String
    let frozenSourceDigest: String
    let snapshotReference: String
    let snapshotManifestHash: String
    let sourceLayoutIdentifier: String
    let sourceFingerprintHash: String
    let inventoryDigest: String
    let selectedThreadIDs: [String]
    let ordinaryCount: Int
    let automationCount: Int
    let blockedOutsideBatchCount: Int
    let databases: [CodexGhostRepairBulkProductionBundleDatabaseContract]
}

struct CodexGhostRepairBulkProductionBundleDatabaseContract:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let database: CodexGhostRepairBulkProductionDatabase
    let canonicalFileName: String
    let required: Bool
    let role: CodexGhostRepairBulkProductionDatabaseRole
}

/// M4f-12's dedicated bulk boundary. It is deliberately separate from the
/// old one- or two-item Category A bundle. This slice accepts only an exact
/// Manager SQLite cold readback that already includes M4f-11 selected-only
/// evidence. Production resolution uses the fixed Codex home without a caller
/// path, while internal tests use a separately bounded lexical test-owned root.
/// Construction and resolution perform zero I/O and grant no mutation authority.
struct CodexGhostRepairBulkProductionBundle: Sendable {
    private enum SourceBoundary: Sendable {
        case production
        case test(TestBoundary)
    }

    struct Resolution: Sendable {
        let requestID: UUID
        let previewID: UUID
        let previewManifestDigest: String
        let frozenSourceDigest: String
        let snapshotReference: String
        let snapshotManifestHash: String
        let sourceLayoutIdentifier: String
        let sourceFingerprintHash: String
        let inventoryDigest: String
        let selectedThreadIDs: [String]
        let ordinaryCount: Int
        let automationCount: Int
        let blockedOutsideBatchCount: Int
        let databaseContracts:
            [CodexGhostRepairBulkProductionBundleDatabaseContract]
        let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
        let bundleDigest: String
        let testOwnedCodexHomeURL: URL
        let testOwnedSQLiteRootURL: URL
        let databaseURLs:
            [CodexGhostRepairBulkProductionDatabase: URL]
        let acceptsLiveCodexRoot: Bool

        var selectedCount: Int { selectedThreadIDs.count }
        var allOrNothing: Bool { true }
        var selectedOnlySource: Bool { true }
        var pathIncludedInBundleDigest: Bool { false }
        var createsBackup: Bool { false }
        var createsClaim: Bool { false }
        var repairMutationAuthority: Bool { false }

        func databaseURL(
            for database: CodexGhostRepairBulkProductionDatabase
        ) -> URL {
            databaseURLs[database]!
        }
    }

    private struct TestBoundary: Sendable {
        let codexHomeURL: URL
        let allowedParentURL: URL
    }

    let capabilities = CodexGhostRepairBulkProductionBundleCapabilities()

    private let storedPreview: CodexGhostRepairBulkStoredPreview
    private let sourceBoundary: SourceBoundary

    init(
        coldReadback storedPreview: CodexGhostRepairBulkStoredPreview,
        testOwnedCodexHomeURL: URL,
        testOwnedAllowedParentURL: URL
    ) throws {
        try Self.validate(storedPreview)
        self.storedPreview = storedPreview
        sourceBoundary = .test(.init(
            codexHomeURL: testOwnedCodexHomeURL,
            allowedParentURL: testOwnedAllowedParentURL
        ))
    }

    /// Caller-path-free, zero-I/O production construction. The canonical
    /// Codex home is resolved only by `resolveForProduction()`.
    init(productionColdReadback storedPreview: CodexGhostRepairBulkStoredPreview)
        throws
    {
        try Self.validate(storedPreview)
        self.storedPreview = storedPreview
        sourceBoundary = .production
    }

    private static func validate(
        _ storedPreview: CodexGhostRepairBulkStoredPreview
    ) throws {
        guard let source = storedPreview.frozenSource else {
            throw PersistentStateError.invalidRecord(
                "Bulk production bundle requires the exact frozen source."
            )
        }
        try storedPreview.preview.validateForPersistence()
        try source.validate(preview: storedPreview.preview)
        guard Self.isSHA256(storedPreview.payloadHash),
              storedPreview.preview.selectedThreadIDs
                == source.selectedThreadIDs,
              !storedPreview.confirmationAuthority,
              !storedPreview.repairMutationAuthority else {
            throw PersistentStateError.invalidRecord(
                "Bulk production bundle cold readback is invalid."
            )
        }
    }

    /// Resolves a fixed five-database shape under one test-owned lexical root.
    /// No file metadata, bytes or SQLite state are read here.
    func resolveForTestOwnedAdoption() throws -> Resolution {
        guard case let .test(testBoundary) = sourceBoundary else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk production bundle is not test-owned."
            )
        }
        let codexHome = testBoundary.codexHomeURL.standardizedFileURL
        let parent = testBoundary.allowedParentURL.standardizedFileURL
        let liveCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
        guard codexHome.path != parent.path,
              Self.isDescendant(codexHome, of: parent),
              codexHome.path != liveCodexHome.path,
              !Self.isDescendant(codexHome, of: liveCodexHome) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk production test root escaped its fixed boundary."
            )
        }

        return try makeResolution(
            codexHome: codexHome,
            acceptsLiveCodexRoot: false
        )
    }

    /// Resolves only the fixed current-user Codex home. It performs no I/O and
    /// accepts no caller-supplied path. The frozen source layout must match one
    /// packaged source profile before this live-root identity is returned.
    func resolveForProduction() throws -> Resolution {
        guard case .production = sourceBoundary,
              let source = storedPreview.frozenSource,
              CodexGhostRepairSnapshotSourceProfile.admitted(
                  sourceLayoutIdentifier: source.sourceLayoutIdentifier
              ) != nil else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk production source layout is not packaged."
            )
        }
        let codexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
        return try makeResolution(
            codexHome: codexHome,
            acceptsLiveCodexRoot: true
        )
    }

    private func makeResolution(
        codexHome: URL,
        acceptsLiveCodexRoot: Bool
    ) throws -> Resolution {
        let source = storedPreview.frozenSource!
        try source.validate(preview: storedPreview.preview)
        let sqliteRoot = codexHome.appendingPathComponent(
            "sqlite",
            isDirectory: true
        )
        let contracts = CodexGhostRepairBulkProductionDatabase.allCases.map {
            database in
            CodexGhostRepairBulkProductionBundleDatabaseContract(
                database: database,
                canonicalFileName: database.canonicalFile.rawValue,
                required: database.required,
                role: database.role
            )
        }
        let urls = Dictionary(uniqueKeysWithValues:
            CodexGhostRepairBulkProductionDatabase.allCases.map { database in
                (
                    database,
                    database.canonicalFile.sourceURL(
                        codexHomeURL: codexHome,
                        sqliteRootURL: sqliteRoot
                    )
                )
            }
        )
        let ordinaryCount = source.selectedItems.count {
            $0.category == .ordinary
        }
        let automationCount = source.selectedItems.count {
            $0.category == .automation
        }
        let payload = CodexGhostRepairBulkProductionBundleDigestPayload(
            requestID: storedPreview.requestID,
            previewID: storedPreview.preview.previewID,
            previewPayloadHash: storedPreview.payloadHash,
            previewManifestDigest: storedPreview.preview.manifestDigest,
            frozenSourceDigest: source.sourceDigest,
            snapshotReference: source.snapshotReference,
            snapshotManifestHash: source.snapshotManifestHash,
            sourceLayoutIdentifier: source.sourceLayoutIdentifier,
            sourceFingerprintHash: source.sourceFingerprintHash,
            inventoryDigest: source.inventoryDigest,
            selectedThreadIDs: source.selectedThreadIDs,
            ordinaryCount: ordinaryCount,
            automationCount: automationCount,
            blockedOutsideBatchCount: source.blockedOutsideBatchCount,
            databases: contracts
        )
        let resolution = Resolution(
            requestID: storedPreview.requestID,
            previewID: storedPreview.preview.previewID,
            previewManifestDigest: storedPreview.preview.manifestDigest,
            frozenSourceDigest: source.sourceDigest,
            snapshotReference: source.snapshotReference,
            snapshotManifestHash: source.snapshotManifestHash,
            sourceLayoutIdentifier: source.sourceLayoutIdentifier,
            sourceFingerprintHash: source.sourceFingerprintHash,
            inventoryDigest: source.inventoryDigest,
            selectedThreadIDs: source.selectedThreadIDs,
            ordinaryCount: ordinaryCount,
            automationCount: automationCount,
            blockedOutsideBatchCount: source.blockedOutsideBatchCount,
            databaseContracts: contracts,
            authority: source.authority,
            bundleDigest: try CodexGhostRepairHasher.hash(payload),
            testOwnedCodexHomeURL: codexHome,
            testOwnedSQLiteRootURL: sqliteRoot,
            databaseURLs: urls,
            acceptsLiveCodexRoot: acceptsLiveCodexRoot
        )
        guard resolution.selectedCount
                <= CodexGhostRepairBulkPreview.maximumSelectedItems,
              resolution.selectedCount > 0,
              resolution.ordinaryCount + resolution.automationCount
                == resolution.selectedCount,
              resolution.databaseContracts.count == 5,
              resolution.databaseContracts.filter({ $0.required }).count == 4,
              resolution.databaseContracts.filter({
                  $0.role == .futureSingleTransactionMutation
              }).count == 1,
              resolution.allOrNothing,
              resolution.selectedOnlySource,
              !resolution.pathIncludedInBundleDigest,
              !resolution.createsBackup,
              !resolution.createsClaim,
              !resolution.repairMutationAuthority else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk production bundle contract is invalid."
            )
        }
        return resolution
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && childComponents.prefix(parentComponents.count)
                == parentComponents[...]
    }
}
