import CSQLite3
import CryptoKit
import Darwin
import Foundation

public enum CodexGhostRepairSnapshotAnalysisDatabase:
    String,
    CaseIterable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case desktop
    case summaries
    case state
    case threadHistory

    var canonicalFile: CodexGhostRepairSnapshotCanonicalFile {
        switch self {
        case .desktop: .desktop
        case .summaries: .summaries
        case .state: .state
        case .threadHistory: .threadHistory
        }
    }
}

public struct CodexGhostRepairSnapshotAnalysisDatabaseEvidence:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let database: CodexGhostRepairSnapshotAnalysisDatabase
    public let schemaVersion: Int32
    public let integrityCheckPassed: Bool
    public let foreignKeyViolationCount: Int

    public var queryOnly: Bool { true }
    public var fixedStatementsOnly: Bool { true }
    public var statementCount: Int { 4 }
}

public struct CodexGhostRepairSnapshotAnalysisReadback:
    Encodable,
    Equatable,
    Hashable,
    Sendable
{
    public let identity: CodexGhostRepairSnapshotAnalysisIdentity
    public let sourceLayoutIdentifier: String
    public let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    public let targets: [CodexGhostRepairSnapshotAnalysisTargetEvidence]
    public let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence

    public var rawDatabaseContentsOpened: Int { databases.count }
    public var acceptsCallerPath: Bool { false }
    public var exposesGenericSQL: Bool { false }
    public var exposesDatabaseHandle: Bool { false }
    public var writesFilesystem: Bool { true }
    public var writesPublishedSnapshot: Bool { false }
    public var usesEphemeralAnalysisWorkspace: Bool { true }
    public var retainsAnalysisWorkspace: Bool { false }
    public var persistsRepairPreview: Bool { false }
    public var repairPreviewAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public struct CodexGhostRepairSnapshotAnalysisReferenceCounts:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let inbox: Int
    public let timeline: Int
    public let summaries: Int
    public let canonicalState: Int
    public let threadTurns: Int
    public let threadItems: Int
    public let historyProjection: Int

    public var total: Int {
        inbox + timeline + summaries + canonicalState + threadTurns
            + threadItems + historyProjection
    }
}

public enum CodexGhostRepairSnapshotAnalysisRowContract:
    String,
    Encodable,
    Equatable,
    Hashable,
    Sendable
{
    case categoryAEligible
    case categoryBEligible
    case unsupported
}

public struct CodexGhostRepairSnapshotAnalysisTargetEvidence:
    Encodable,
    Equatable,
    Hashable,
    Sendable
{
    var hasNoResidue: Bool {
        catalogRowDigests.isEmpty && automationRunRowDigests.isEmpty
            && automationStableFieldsDigests.isEmpty
            && automationDefinitionRowDigests.isEmpty && references.total == 0
    }
    public let threadID: String
    public let catalogRowDigests: [String]
    public let automationRunRowDigests: [String]
    public let automationStableFieldsDigests: [String]
    public let automationDefinitionRowDigests: [String]
    public let references: CodexGhostRepairSnapshotAnalysisReferenceCounts
    public let rowContract: CodexGhostRepairSnapshotAnalysisRowContract
    public var summaryRowDigests: [String]? = nil
    public var pausedAutomationReviewable: Bool? = nil
    /// Ephemeral UI metadata, excluded from hashes and persisted evidence.
    var displayTitle: String? = nil

    private enum CodingKeys: String, CodingKey {
        case threadID, catalogRowDigests, automationRunRowDigests
        case automationStableFieldsDigests, automationDefinitionRowDigests
        case references, rowContract, summaryRowDigests, pausedAutomationReviewable
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadID == rhs.threadID
            && lhs.catalogRowDigests == rhs.catalogRowDigests
            && lhs.automationRunRowDigests == rhs.automationRunRowDigests
            && lhs.automationStableFieldsDigests == rhs.automationStableFieldsDigests
            && lhs.automationDefinitionRowDigests == rhs.automationDefinitionRowDigests
            && lhs.references == rhs.references && lhs.rowContract == rhs.rowContract
            && lhs.summaryRowDigests == rhs.summaryRowDigests
            && lhs.pausedAutomationReviewable == rhs.pausedAutomationReviewable
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(threadID)
        hasher.combine(catalogRowDigests)
        hasher.combine(automationRunRowDigests)
        hasher.combine(automationStableFieldsDigests)
        hasher.combine(automationDefinitionRowDigests)
        hasher.combine(references)
        hasher.combine(rowContract)
        hasher.combine(summaryRowDigests)
        hasher.combine(pausedAutomationReviewable)
    }

    public var catalogRowCount: Int { catalogRowDigests.count }
    public var automationRunRowCount: Int { automationRunRowDigests.count }
    public var automationDefinitionRowCount: Int {
        automationDefinitionRowDigests.count
    }
    public var exposesPrivateRowValues: Bool { false }

    public init(
        threadID: String,
        catalogRowDigests: [String],
        automationRunRowDigests: [String],
        automationStableFieldsDigests: [String] = [],
        automationDefinitionRowDigests: [String],
        references: CodexGhostRepairSnapshotAnalysisReferenceCounts,
        rowContract: CodexGhostRepairSnapshotAnalysisRowContract
    ) {
        self.threadID = threadID
        self.catalogRowDigests = catalogRowDigests
        self.automationRunRowDigests = automationRunRowDigests
        self.automationStableFieldsDigests = automationStableFieldsDigests
        self.automationDefinitionRowDigests = automationDefinitionRowDigests
        self.references = references
        self.rowContract = rowContract
    }
}

public struct CodexGhostRepairSnapshotAnalysisAuthorityEvidence:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let catalogRevision: Int64
    public let observationSequence: Int64
    public let watermarkUpdatedAt: Double?
    public let metadataRowDigest: String
    public let localSyncRowDigest: String

    public var exposesPrivateRowValues: Bool { false }
    public var repairAuthority: Bool { false }
}

public enum CodexGhostRepairSnapshotAnalysisFailureReason:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case freshIdentityUnavailable = "fresh-identity-unavailable"
    case publishedAccessPreflightUnavailable =
        "published-access-preflight-unavailable"
    case publishedSourcePreflightUnavailable =
        "published-source-preflight-unavailable"
    case workspaceCreationUnavailable = "workspace-creation-unavailable"
    case workspaceCopyUnavailable = "workspace-copy-unavailable"
    case workspacePreflightUnavailable = "workspace-preflight-unavailable"
    case desktopOpenUnavailable = "desktop-open-unavailable"
    case summariesOpenUnavailable = "summaries-open-unavailable"
    case stateOpenUnavailable = "state-open-unavailable"
    case threadHistoryOpenUnavailable = "thread-history-open-unavailable"
    case desktopContractUnavailable = "desktop-contract-unavailable"
    case summariesContractUnavailable = "summaries-contract-unavailable"
    case stateContractUnavailable = "state-contract-unavailable"
    case threadHistoryContractUnavailable =
        "thread-history-contract-unavailable"
    case targetEvidenceUnavailable = "target-evidence-unavailable"
    case authorityEvidenceUnavailable = "authority-evidence-unavailable"
    case databaseCloseUnavailable = "database-close-unavailable"
    case workspacePostflightUnavailable = "workspace-postflight-unavailable"
    case publishedSourcePostflightUnavailable =
        "published-source-postflight-unavailable"
    case workspaceCleanupUnavailable = "workspace-cleanup-unavailable"
    case publishedAccessPostflightUnavailable =
        "published-access-postflight-unavailable"
    case publishedAccessDrift = "published-access-drift"
    case unexpected = "unexpected-reader-failure"

    public var pathRedacted: Bool { true }
    public var rawErrorIncluded: Bool { false }
    public var retryAuthority: Bool { false }
    public var repairAuthority: Bool { false }
}

enum CodexGhostRepairSnapshotAnalysisFailurePoint:
    CaseIterable,
    Equatable,
    Sendable
{
    case freshIdentity
    case publishedAccessPreflight
    case publishedSourcePreflight
    case workspaceCreation
    case workspaceCopy
    case workspacePreflight
    case desktopOpen
    case summariesOpen
    case stateOpen
    case threadHistoryOpen
    case desktopContract
    case summariesContract
    case stateContract
    case threadHistoryContract
    case targetEvidence
    case authorityEvidence
    case databaseClose
    case workspacePostflight
    case publishedSourcePostflight
    case workspaceCleanup
    case publishedAccessPostflight
    case publishedAccessDrift
    case unexpected

    var failureReason: CodexGhostRepairSnapshotAnalysisFailureReason {
        switch self {
        case .freshIdentity: .freshIdentityUnavailable
        case .publishedAccessPreflight:
            .publishedAccessPreflightUnavailable
        case .publishedSourcePreflight:
            .publishedSourcePreflightUnavailable
        case .workspaceCreation: .workspaceCreationUnavailable
        case .workspaceCopy: .workspaceCopyUnavailable
        case .workspacePreflight: .workspacePreflightUnavailable
        case .desktopOpen: .desktopOpenUnavailable
        case .summariesOpen: .summariesOpenUnavailable
        case .stateOpen: .stateOpenUnavailable
        case .threadHistoryOpen: .threadHistoryOpenUnavailable
        case .desktopContract: .desktopContractUnavailable
        case .summariesContract: .summariesContractUnavailable
        case .stateContract: .stateContractUnavailable
        case .threadHistoryContract: .threadHistoryContractUnavailable
        case .targetEvidence: .targetEvidenceUnavailable
        case .authorityEvidence: .authorityEvidenceUnavailable
        case .databaseClose: .databaseCloseUnavailable
        case .workspacePostflight: .workspacePostflightUnavailable
        case .publishedSourcePostflight:
            .publishedSourcePostflightUnavailable
        case .workspaceCleanup: .workspaceCleanupUnavailable
        case .publishedAccessPostflight:
            .publishedAccessPostflightUnavailable
        case .publishedAccessDrift: .publishedAccessDrift
        case .unexpected: .unexpected
        }
    }
}

public enum CodexGhostRepairSnapshotAnalysisReadOutcome:
    Equatable,
    Sendable
{
    case read(CodexGhostRepairSnapshotAnalysisReadback)
    case unavailable(reason: CodexGhostRepairSnapshotAnalysisFailureReason)
}

public struct CodexGhostRepairSnapshotAnalysisReaderCapabilities:
    Equatable,
    Sendable
{
    public let fixedPublishedSnapshotReadAvailable: Bool

    public var acceptsCallerPath: Bool { false }
    public var opensOnlyRequiredDatabases: Bool { true }
    public var usesSQLiteReadOnly: Bool { true }
    public var usesNoFollowIdentityGuard: Bool { true }
    public var usesQueryOnly: Bool { true }
    public var usesAuthorizer: Bool { true }
    public var exposesGenericSQL: Bool { false }
    public var exposesDatabaseHandle: Bool { false }
    public var readsSessionRows: Bool { true }
    public var returnsOnlyPrivacyPreservingRowDigests: Bool { true }
    public var writesFilesystem: Bool {
        fixedPublishedSnapshotReadAvailable
    }
    public var writesPublishedSnapshot: Bool { false }
    public var usesEphemeralAnalysisWorkspace: Bool {
        fixedPublishedSnapshotReadAvailable
    }
    public var retainsAnalysisWorkspace: Bool { false }
    public var persistsRepairPreview: Bool { false }
    public var automaticRead: Bool { false }
    public var automaticRetry: Bool { false }
    public var repairPreviewAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let packagedReadOnly = Self(
        fixedPublishedSnapshotReadAvailable: true
    )
    public static let unavailable = Self(
        fixedPublishedSnapshotReadAvailable: false
    )

    private init(fixedPublishedSnapshotReadAvailable: Bool) {
        self.fixedPublishedSnapshotReadAvailable =
            fixedPublishedSnapshotReadAvailable
    }
}

public protocol CodexGhostRepairSnapshotAnalysisReading: Sendable {
    var capabilities: CodexGhostRepairSnapshotAnalysisReaderCapabilities {
        get
    }

    func read(
        identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) async -> CodexGhostRepairSnapshotAnalysisReadOutcome
}

protocol CodexGhostRepairBulkSnapshotCatalogReading: Sendable {
    func readBulkCatalog(
        snapshotReference: String
    ) async throws -> CodexGhostRepairBulkInventorySnapshotEvidence
}

protocol CodexGhostRepairSnapshotPublishedAnalysisAccessResolving: Sendable {
    func access(
        for identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) async throws
        -> CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess
}

struct CodexGhostRepairSnapshotPublishedAnalysisSource:
    CodexGhostRepairSnapshotPublishedAnalysisAccessResolving,
    Sendable
{
    private let destination: CodexGhostRepairSnapshotPreparedDestination
    private let journal: CodexGhostRepairSnapshotAcquisitionJournal

    static func production() -> Self {
        let destination = CodexGhostRepairSnapshotPreparedDestination.production()
        return Self(
            destination: destination,
            journal: .production(destination: destination)
        )
    }

    init(
        destination: CodexGhostRepairSnapshotPreparedDestination,
        journal: CodexGhostRepairSnapshotAcquisitionJournal
    ) {
        self.destination = destination
        self.journal = journal
    }

    func access(
        for identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) async throws
        -> CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess
    {
        let binding = try await destination.bindPrepared()
        guard binding.bindingHash == identity.destinationBindingHash else {
            throw CodexGhostRepairError.targetDrift(
                "Published snapshot destination binding drifted."
            )
        }
        let snapshotID = try Self.snapshotID(identity.snapshotReference)
        let acquisition = try await journal.readback(
            snapshotID: snapshotID,
            destinationBinding: binding
        )
        guard acquisition.targetThreadIDs == identity.targetThreadIDs,
              acquisition.preparedAtMilliseconds
                == identity.preparedAtMilliseconds,
              acquisition.sourceFingerprintHash
                == identity.sourceFingerprintHash,
              acquisition.destinationBindingHash
                == identity.destinationBindingHash,
              acquisition.recordHash == identity.acquisitionRecordHash else {
            throw CodexGhostRepairError.targetDrift(
                "Published snapshot acquisition evidence drifted."
            )
        }
        let location = try await destination.location(for: binding)
        let access = try CodexGhostRepairSnapshotPublishedInventoryCollector
            .analysisAccess(
                snapshotID: snapshotID,
                acquisition: acquisition,
                binding: binding,
                location: location
            )
        let existingFileCount = access.manifest.files.filter(\.exists).count + 2
        guard CodexGhostRepairSnapshotSourceProfile.admitted(
                sourceLayoutIdentifier:
                    access.manifest.sourceLayoutIdentifier
              ) != nil,
              access.manifest.manifestHash == identity.manifestHash,
              access.publishedEvidence.publicationReceiptHash
                == identity.publicationReceiptHash,
              access.publishedEvidence.publishedAtMilliseconds
                == identity.publishedAtMilliseconds,
              access.publishedEvidence.regularFileCount
                == identity.observedRegularFileCount,
              access.publishedEvidence.actualBytes
                == identity.actualPublishedBytes,
              existingFileCount == identity.observedRegularFileCount else {
            throw CodexGhostRepairError.targetDrift(
                "Published snapshot analysis identity drifted."
            )
        }
        return access
    }

    private static func snapshotID(_ reference: String) throws -> UUID {
        guard let value = UUID(uuidString: reference),
              value.uuidString.lowercased() == reference else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot reference is invalid."
            )
        }
        return value
    }
}

/// M2 shipping reader. It consumes only an M2a frozen identity, resolves the
/// fixed manager-owned published snapshot again, opens exactly four required
/// databases, and runs only the fixed M2b health and M2c row statements.
/// Private row values are reduced to deterministic digests before crossing the
/// public API. Generic SQL, database handles, Preview persistence, and repair
/// authority are deliberately absent from this slice.
actor CodexGhostRepairSnapshotPackagedAnalysisReader:
    CodexGhostRepairSnapshotAnalysisReading,
    CodexGhostRepairBulkSnapshotCatalogReading
{
    nonisolated let capabilities =
        CodexGhostRepairSnapshotAnalysisReaderCapabilities.packagedReadOnly

    private let identityResolver:
        any CodexGhostRepairSnapshotAnalysisIdentityCoordinator
    private let accessResolver:
        any CodexGhostRepairSnapshotPublishedAnalysisAccessResolving
    private let workspaceFactory:
        CodexGhostRepairSnapshotAnalysisWorkspaceFactory

    static func production() -> Self {
        Self(
            identityResolver:
                CodexGhostRepairSnapshotAnalysisIdentityCoordinatorFactory
                    .packagedReadOnly(),
            accessResolver: CodexGhostRepairSnapshotPublishedAnalysisSource
                .production(),
            workspaceFactory: .production()
        )
    }

    init(
        identityResolver:
            any CodexGhostRepairSnapshotAnalysisIdentityCoordinator,
        accessResolver:
            any CodexGhostRepairSnapshotPublishedAnalysisAccessResolving,
        workspaceFactory:
            CodexGhostRepairSnapshotAnalysisWorkspaceFactory = .production()
    ) {
        self.identityResolver = identityResolver
        self.accessResolver = accessResolver
        self.workspaceFactory = workspaceFactory
    }

    func read(
        identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) async -> CodexGhostRepairSnapshotAnalysisReadOutcome {
        let fresh = await identityResolver.resolve(request: .init(
            snapshotReference: identity.snapshotReference
        ))
        guard case let .resolved(freshIdentity) = fresh,
              freshIdentity == identity else {
            return .unavailable(
                reason: CodexGhostRepairSnapshotAnalysisFailurePoint
                    .freshIdentity.failureReason
            )
        }
        let before: CodexGhostRepairSnapshotPublishedInventoryCollector
            .AnalysisAccess
        do {
            before = try await accessResolver.access(for: identity)
        } catch {
            return .unavailable(
                reason: CodexGhostRepairSnapshotAnalysisFailurePoint
                    .publishedAccessPreflight.failureReason
            )
        }
        let result: CodexGhostRepairSnapshotQueryOnlyBundle.Result
        do {
            result = try CodexGhostRepairSnapshotQueryOnlyBundle.read(
                access: before,
                targetThreadIDs: identity.targetThreadIDs,
                workspaceFactory: workspaceFactory
            )
        } catch {
            return .unavailable(
                reason: CodexGhostRepairSnapshotQueryOnlyBundle
                    .failureReason(for: error)
            )
        }
        guard let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
                sourceLayoutIdentifier:
                    before.manifest.sourceLayoutIdentifier
              ),
              profile.admits(databases: result.databases) else {
            return .unavailable(
                reason: CodexGhostRepairSnapshotAnalysisFailurePoint
                    .publishedAccessDrift.failureReason
            )
        }
        let after: CodexGhostRepairSnapshotPublishedInventoryCollector
            .AnalysisAccess
        do {
            after = try await accessResolver.access(for: identity)
        } catch {
            return .unavailable(
                reason: CodexGhostRepairSnapshotAnalysisFailurePoint
                    .publishedAccessPostflight.failureReason
            )
        }
        guard after == before else {
            return .unavailable(
                reason: CodexGhostRepairSnapshotAnalysisFailurePoint
                    .publishedAccessDrift.failureReason
            )
        }
        return .read(CodexGhostRepairSnapshotAnalysisReadback(
            identity: identity,
            sourceLayoutIdentifier: profile.identifier,
            databases: result.databases,
            targets: result.targets,
            authority: result.authority
        ))
    }

    func readBulkCatalog(
        snapshotReference: String
    ) async throws -> CodexGhostRepairBulkInventorySnapshotEvidence {
        let fresh = await identityResolver.resolve(request: .init(
            snapshotReference: snapshotReference
        ))
        guard case let .resolved(identity) = fresh,
              identity.snapshotReference == snapshotReference else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk snapshot identity is unavailable."
            )
        }
        let before = try await accessResolver.access(for: identity)
        let result = try CodexGhostRepairSnapshotQueryOnlyBundle.readBulk(
            access: before,
            workspaceFactory: workspaceFactory
        )
        guard let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
                sourceLayoutIdentifier:
                    before.manifest.sourceLayoutIdentifier
              ),
              profile.admits(databases: result.databases) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk snapshot source profile and schema do not match."
            )
        }
        let after = try await accessResolver.access(for: identity)
        guard after == before else {
            throw CodexGhostRepairError.targetDrift(
                "Bulk snapshot access drifted."
            )
        }
        return .init(
            snapshotReference: identity.snapshotReference,
            sourceLayoutIdentifier: profile.identifier,
            sourceFingerprintHash: identity.sourceFingerprintHash,
            manifestHash: identity.manifestHash,
            readback: .init(
                databases: result.databases,
                targets: result.targets,
                authority: result.authority,
                sourceFingerprintHash: identity.sourceFingerprintHash
            )
        )
    }
}

struct CodexGhostRepairSnapshotAnalysisWorkspaceFactory: Sendable {
    private let parentURL: URL

    static func production() -> Self {
        Self(parentURL: FileManager.default.temporaryDirectory)
    }

    init(testOwnedParentURL: URL) {
        parentURL = testOwnedParentURL
    }

    private init(parentURL: URL) {
        self.parentURL = parentURL
    }

    func create() throws -> CodexGhostRepairSnapshotAnalysisWorkspace {
        var parentStatus = stat()
        guard lstat(parentURL.path, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR,
              parentStatus.st_uid == geteuid(),
              parentStatus.st_mode & 0o022 == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis workspace parent is unsafe."
            )
        }
        var template = Array(
            parentURL.appendingPathComponent(
                "agent-session-manager-snapshot-analysis-XXXXXX",
                isDirectory: true
            ).path.utf8CString
        )
        guard let created = template.withUnsafeMutableBufferPointer({ buffer in
            Darwin.mkdtemp(buffer.baseAddress)
        }) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis workspace could not be created."
            )
        }
        let rootURL = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        do {
            guard chmod(rootURL.path, 0o700) == 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot analysis workspace permissions are unavailable."
                )
            }
            return try CodexGhostRepairSnapshotAnalysisWorkspace(rootURL: rootURL)
        } catch {
            let primaryError = error
            do {
                try FileManager.default.removeItem(at: rootURL)
            } catch {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot analysis workspace initialization cleanup failed."
                )
            }
            throw primaryError
        }
    }
}

struct CodexGhostRepairSnapshotAnalysisWorkspace {
    let rootURL: URL

    init(rootURL: URL) throws {
        var status = stat()
        let descriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis workspace identity is unavailable."
            )
        }
        defer { Darwin.close(descriptor) }
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o700 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis workspace is unsafe."
            )
        }
        self.rootURL = rootURL
    }

    func remove() throws {
        try FileManager.default.removeItem(at: rootURL)
        var status = stat()
        guard lstat(rootURL.path, &status) != 0, errno == ENOENT else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis workspace cleanup could not be verified."
            )
        }
    }
}

public enum CodexGhostRepairSnapshotAnalysisReaderFactory {
    public static func packagedReadOnly()
        -> any CodexGhostRepairSnapshotAnalysisReading
    {
        CodexGhostRepairSnapshotPackagedAnalysisReader.production()
    }
}

enum CodexGhostRepairSnapshotAnalysisAuthorizer {
    private static let allowedTables: Set<String> = [
        "local_thread_catalog",
        "automation_runs",
        "automations",
        "inbox_items",
        "thread_timeline_ledger",
        "local_thread_catalog_metadata",
        "local_thread_catalog_sync_state",
        "thread_turn_summaries",
        "threads",
        "thread_turns",
        "thread_items",
        "thread_history_projection_state",
    ]

    private static let allowedIndexes: Set<String> = [
        "automations_owner_idx",
        "local_thread_catalog_created_idx",
        "local_thread_catalog_cwd_created_idx",
        "local_thread_catalog_cwd_updated_idx",
        "local_thread_catalog_origin_updated_idx",
        "local_thread_catalog_project_updated_idx",
        "local_thread_catalog_thread_lookup_idx",
        "local_thread_catalog_updated_idx",
    ]

    static func decision(
        actionCode: Int32,
        parameterOne: String?,
        parameterTwo: String?
    ) -> Int32 {
        switch actionCode {
        case SQLITE_SELECT:
            return SQLITE_OK
        case SQLITE_READ:
            return parameterOne.map(allowedTables.contains) == true
                ? SQLITE_OK : SQLITE_DENY
        case SQLITE_FUNCTION:
            return [parameterOne, parameterTwo]
                .compactMap { $0?.lowercased() }
                .contains("count") ? SQLITE_OK : SQLITE_DENY
        case SQLITE_PRAGMA:
            if ["table_info", "index_list"].contains(
                parameterOne?.lowercased() ?? ""
            ) {
                return parameterTwo.map(allowedTables.contains) == true
                    ? SQLITE_OK : SQLITE_DENY
            }
            if parameterOne?.lowercased() == "index_info" {
                return parameterTwo.map(allowedIndexes.contains) == true
                    ? SQLITE_OK : SQLITE_DENY
            }
            guard parameterTwo == nil else { return SQLITE_DENY }
            return [
                "query_only",
                "user_version",
                "integrity_check",
                "foreign_key_check",
            ].contains(parameterOne?.lowercased() ?? "")
                ? SQLITE_OK : SQLITE_DENY
        default:
            return SQLITE_DENY
        }
    }
}

struct CodexGhostRepairCanonicalQueryReadback: Sendable {
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let targets: [CodexGhostRepairSnapshotAnalysisTargetEvidence]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let sourceFingerprintHash: String
}

struct CodexGhostRepairBulkCatalogQueryReadback: Sendable {
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let targets: [CodexGhostRepairSnapshotAnalysisTargetEvidence]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let sourceFingerprintHash: String

    var acceptsCallerThreadIDs: Bool { false }
    var exposesGenericSQL: Bool { false }
    var writesCanonicalSource: Bool { false }
    var persistsPreview: Bool { false }
    var repairPreviewAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }
}

struct CodexGhostRepairInitialWitnessCatalogReadback: Sendable {
    let sourceLayoutIdentifier: String
    let sourceFingerprintHash: String
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let threadIDs: [String]

    var exposesPrivateRowEvidence: Bool { false }
    var acceptsCallerThreadIDs: Bool { false }
    var exposesGenericSQL: Bool { false }
    var writesCanonicalSource: Bool { false }
    var usesTemporaryWorkspace: Bool { true }
    var writesTemporaryWorkspace: Bool { true }
    var publishesSnapshot: Bool { false }
    var persistsPreview: Bool { false }
    var repairMutationAuthority: Bool { false }
}

enum CodexGhostRepairCanonicalQueryOnlyReader {
    static func read(
        source: CodexGhostRepairSnapshotCanonicalSource,
        targetThreadIDs: [String],
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> CodexGhostRepairCanonicalQueryReadback {
        let readback = try CodexGhostRepairSnapshotQueryOnlyBundle
            .readCanonicalSource(
                source: source,
                targetThreadIDs: targetThreadIDs,
                workspaceFactory: workspaceFactory
            )
        return .init(
            databases: readback.result.databases,
            targets: readback.result.targets,
            authority: readback.result.authority,
            sourceFingerprintHash: readback.sourceFingerprintHash
        )
    }
}

enum CodexGhostRepairBulkCanonicalQueryOnlyReader {
    static func readExactCleanupScope(
        source: CodexGhostRepairSnapshotCanonicalSource,
        targetThreadIDs: [String],
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> CodexGhostRepairBulkCatalogQueryReadback {
        let readback = try CodexGhostRepairSnapshotQueryOnlyBundle
            .readExactCleanupScope(
                source: source,
                targetThreadIDs: targetThreadIDs,
                workspaceFactory: workspaceFactory
            )
        return .init(
            databases: readback.result.databases,
            targets: readback.result.targets,
            authority: readback.result.authority,
            sourceFingerprintHash: readback.sourceFingerprintHash
        )
    }

    static func read(
        source: CodexGhostRepairSnapshotCanonicalSource,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> CodexGhostRepairBulkCatalogQueryReadback {
        let readback = try CodexGhostRepairSnapshotQueryOnlyBundle
            .readBulkCanonicalSource(
                source: source,
                workspaceFactory: workspaceFactory
            )
        return .init(
            databases: readback.result.databases,
            targets: readback.result.targets,
            authority: readback.result.authority,
            sourceFingerprintHash: readback.sourceFingerprintHash
        )
    }
}

enum CodexGhostRepairInitialWitnessCanonicalQueryOnlyReader {
    static func read(
        source: CodexGhostRepairSnapshotCanonicalSource,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> CodexGhostRepairInitialWitnessCatalogReadback {
        try CodexGhostRepairSnapshotQueryOnlyBundle
            .readInitialWitnessCatalog(
                source: source,
                workspaceFactory: workspaceFactory
            )
    }
}

enum CodexGhostRepairSnapshotPrepublicationSchemaVerifier {
    static func verify(
        quarantineRoot: URL,
        fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        profile: CodexGhostRepairSnapshotSourceProfile,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws {
        do {
            try CodexGhostRepairSnapshotQueryOnlyBundle.verifyPrepublicationCopy(
                quarantineRoot: quarantineRoot,
                fingerprint: fingerprint,
                profile: profile,
                workspaceFactory: workspaceFactory
            )
        } catch {
            // Preserve the no-path diagnostic boundary while allowing the App
            // coordinator to name the actual stopped stage. The detailed
            // failure reason remains available to read-only analysis callers;
            // the shipping Snapshot action exposes only the schema stage.
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Prepublication database contract verification failed."
            )
        }
    }
}

private enum CodexGhostRepairSnapshotQueryOnlyBundle {
    struct Result {
        let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
        let targets: [CodexGhostRepairSnapshotAnalysisTargetEvidence]
        let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    }

    private struct DiagnosticFailure: Error {
        let point: CodexGhostRepairSnapshotAnalysisFailurePoint
    }

    static func failureReason(
        for error: Error
    ) -> CodexGhostRepairSnapshotAnalysisFailureReason {
        (error as? DiagnosticFailure)?.point.failureReason
            ?? CodexGhostRepairSnapshotAnalysisFailurePoint
                .unexpected.failureReason
    }

    private static func diagnosed<Value>(
        _ point: CodexGhostRepairSnapshotAnalysisFailurePoint,
        _ operation: () throws -> Value
    ) throws -> Value {
        do {
            return try operation()
        } catch let failure as DiagnosticFailure {
            throw failure
        } catch {
            throw DiagnosticFailure(point: point)
        }
    }

    private struct FileObservation: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let owner: UInt32
        let size: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let sha256: String
    }

    private enum Binding {
        case text(String)
    }

    private enum TargetScope {
        case exact([String])
        case completeLocalCatalog
    }

    private enum ReferenceStatement {
        case inbox
        case timeline
        case summaries
        case canonicalState
        case threadTurns
        case threadItems
        case historyProjection
    }

    static func verifyPrepublicationCopy(
        quarantineRoot: URL,
        fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        profile: CodexGhostRepairSnapshotSourceProfile,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws {
        guard fingerprint.sourceLayoutIdentifier == profile.identifier,
              profile.validates(files: fingerprint.files) else {
            throw DiagnosticFailure(point: .desktopContract)
        }
        let files = fingerprint.files.map {
            CodexGhostRepairSnapshotPublishedFileEvidence(
                fileName: $0.fileName,
                exists: $0.exists,
                size: $0.size,
                sha256: $0.sha256
            )
        }
        let quarantineBefore = try diagnosed(.publishedSourcePreflight) {
            try observeFiles(rootURL: quarantineRoot, files: files)
        }
        let workspace = try diagnosed(.workspaceCreation) {
            try workspaceFactory.create()
        }
        var cleanupAttempted = false
        do {
            try diagnosed(.workspaceCopy) {
                for file in files where file.exists {
                    let expected = try requiredObservation(
                        quarantineBefore[file.fileName],
                        fileName: file.fileName
                    )
                    try copyRegularFileExactly(
                        source: quarantineRoot.appendingPathComponent(
                            file.fileName
                        ),
                        destination: workspace.rootURL.appendingPathComponent(
                            file.fileName
                        ),
                        expected: expected
                    )
                }
            }
            try diagnosed(.workspacePreflight) {
                try validateWorkspaceMembership(
                    workspace: workspace,
                    files: files
                )
            }
            let workspaceBefore = try diagnosed(.workspacePreflight) {
                try observeFiles(rootURL: workspace.rootURL, files: files)
            }
            let result = try readWorkspace(
                rootURL: workspace.rootURL,
                observations: workspaceBefore,
                targetScope: .completeLocalCatalog
            )
            guard profile.admits(databases: result.databases) else {
                throw DiagnosticFailure(point: .desktopContract)
            }
            try diagnosed(.workspacePostflight) {
                try validateWorkspaceMembership(
                    workspace: workspace,
                    files: files,
                    allowingGeneratedSQLiteSharedMemory: true
                )
            }
            let immutableWorkspaceAfter = try diagnosed(
                .workspacePostflight
            ) {
                try observeFiles(
                    rootURL: workspace.rootURL,
                    files: files,
                    excludingSQLiteSharedMemory: true
                )
            }
            let immutableWorkspaceBefore = workspaceBefore.filter {
                !$0.key.hasSuffix("-shm")
            }
            guard immutableWorkspaceAfter == immutableWorkspaceBefore else {
                throw DiagnosticFailure(point: .workspacePostflight)
            }
            let quarantineAfter = try diagnosed(.publishedSourcePostflight) {
                try observeFiles(rootURL: quarantineRoot, files: files)
            }
            guard quarantineAfter == quarantineBefore else {
                throw DiagnosticFailure(point: .publishedSourcePostflight)
            }
            cleanupAttempted = true
            try diagnosed(.workspaceCleanup) { try workspace.remove() }
        } catch {
            let primary = error
            guard !cleanupAttempted else { throw primary }
            cleanupAttempted = true
            do { try workspace.remove() } catch {
                throw DiagnosticFailure(point: .workspaceCleanup)
            }
            throw primary
        }
    }

    static func read(
        access:
            CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess,
        targetThreadIDs: [String],
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> Result {
        guard (1...10).contains(targetThreadIDs.count),
              Set(targetThreadIDs).count == targetThreadIDs.count,
              targetThreadIDs == targetThreadIDs.sorted() else {
            throw DiagnosticFailure(point: .targetEvidence)
        }
        return try read(
            access: access,
            targetScope: .exact(targetThreadIDs),
            workspaceFactory: workspaceFactory
        )
    }

    static func readBulk(
        access:
            CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> Result {
        try read(
            access: access,
            targetScope: .completeLocalCatalog,
            workspaceFactory: workspaceFactory
        )
    }

    private static func read(
        access:
            CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess,
        targetScope: TargetScope,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> Result {
        let sourceBefore = try diagnosed(.publishedSourcePreflight) {
            try observeFiles(access: access)
        }
        let workspace = try diagnosed(.workspaceCreation) {
            try workspaceFactory.create()
        }
        var cleanupAttempted = false
        do {
            try diagnosed(.workspaceCopy) {
                try copyPublishedFiles(
                    access: access,
                    sourceObservations: sourceBefore,
                    workspace: workspace
                )
            }
            try diagnosed(.workspacePreflight) {
                try validateWorkspaceMembership(
                    workspace: workspace,
                    manifest: access.manifest
                )
            }
            let workspaceBefore = try diagnosed(
                .workspacePreflight
            ) {
                try observeFiles(
                    rootURL: workspace.rootURL,
                    manifest: access.manifest
                )
            }
            let result = try readWorkspace(
                rootURL: workspace.rootURL,
                observations: workspaceBefore,
                targetScope: targetScope
            )
            guard let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
                    sourceLayoutIdentifier:
                        access.manifest.sourceLayoutIdentifier
                  ),
                  profile.admits(databases: result.databases) else {
                throw DiagnosticFailure(point: .desktopContract)
            }
            try diagnosed(.workspacePostflight) {
                try validateWorkspaceMembership(
                    workspace: workspace,
                    manifest: access.manifest,
                    allowingGeneratedSQLiteSharedMemory: true
                )
            }
            let immutableWorkspaceAfter = try diagnosed(
                .workspacePostflight
            ) {
                try observeFiles(
                    rootURL: workspace.rootURL,
                    manifest: access.manifest,
                    excludingSQLiteSharedMemory: true
                )
            }
            let immutableWorkspaceBefore = workspaceBefore.filter {
                !$0.key.hasSuffix("-shm")
            }
            guard immutableWorkspaceAfter == immutableWorkspaceBefore else {
                throw DiagnosticFailure(
                    point: .workspacePostflight
                )
            }
            let sourceAfter = try diagnosed(.publishedSourcePostflight) {
                try observeFiles(access: access)
            }
            guard sourceAfter == sourceBefore else {
                throw DiagnosticFailure(
                    point: .publishedSourcePostflight
                )
            }
            cleanupAttempted = true
            try diagnosed(.workspaceCleanup) {
                try workspace.remove()
            }
            return result
        } catch {
            let primaryError = error
            guard !cleanupAttempted else {
                throw primaryError
            }
            cleanupAttempted = true
            do {
                try workspace.remove()
            } catch {
                throw DiagnosticFailure(
                    point: .workspaceCleanup
                )
            }
            throw primaryError
        }
    }

    /// M3i fresh-review reader. It never opens the canonical databases with
    /// SQLite. Fixed raw files are copied through the no-path source into one
    /// owner-private temporary workspace, queried there, and then removed.
    static func readCanonicalSource(
        source: CodexGhostRepairSnapshotCanonicalSource,
        targetThreadIDs: [String],
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> (result: Result, sourceFingerprintHash: String) {
        guard (1...2).contains(targetThreadIDs.count),
              Set(targetThreadIDs).count == targetThreadIDs.count,
              targetThreadIDs == targetThreadIDs.sorted() else {
            throw DiagnosticFailure(point: .targetEvidence)
        }
        return try readCanonicalSource(
            source: source,
            targetScope: .exact(targetThreadIDs),
            workspaceFactory: workspaceFactory
        )
    }

    /// M4a fixed bulk inventory reader. The canonical source contract still
    /// rejects caller-supplied paths and never opens the canonical databases
    /// with SQLite. The shared canonical-copy path enumerates the complete
    /// local catalog with one fixed statement.
    static func readBulkCanonicalSource(
        source: CodexGhostRepairSnapshotCanonicalSource,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> (result: Result, sourceFingerprintHash: String) {
        try readCanonicalSource(
            source: source,
            targetScope: .completeLocalCatalog,
            workspaceFactory: workspaceFactory
        )
    }

    /// Read-only absence verification for a reviewed native Delete handoff.
    /// Missing catalog rows still get all automation and side-reference queries.
    static func readExactCleanupScope(
        source: CodexGhostRepairSnapshotCanonicalSource,
        targetThreadIDs: [String],
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> (result: Result, sourceFingerprintHash: String) {
        guard (1...CodexGhostRepairBulkPreview.maximumSelectedItems)
                .contains(targetThreadIDs.count),
              Set(targetThreadIDs).count == targetThreadIDs.count,
              targetThreadIDs == targetThreadIDs.sorted(),
              targetThreadIDs.allSatisfy({
                UUID(uuidString: $0)?.uuidString.lowercased() == $0
              }) else {
            throw DiagnosticFailure(point: .targetEvidence)
        }
        return try readCanonicalSource(
            source: source,
            targetScope: .exact(targetThreadIDs),
            workspaceFactory: workspaceFactory
        )
    }

    /// Initial discovery is intentionally narrower than Bulk inventory. It
    /// copies the fixed canonical source into the same owner-private temporary
    /// workspace, validates the exact database profile, and returns only the
    /// sorted local catalog identities. It does not read catalog row bodies,
    /// automation records, side references, or authority counters.
    static func readInitialWitnessCatalog(
        source: CodexGhostRepairSnapshotCanonicalSource,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> CodexGhostRepairInitialWitnessCatalogReadback {
        let sourceBefore = try diagnosed(.publishedSourcePreflight) {
            let value = try source.fingerprint()
            try value.validateHash()
            return value
        }
        let workspace = try diagnosed(.workspaceCreation) {
            try workspaceFactory.create()
        }
        var cleanupAttempted = false
        do {
            try diagnosed(.workspaceCopy) {
                try copyCanonicalFiles(
                    source: source,
                    fingerprint: sourceBefore,
                    workspace: workspace
                )
            }
            let publishedFiles = sourceBefore.files.map {
                CodexGhostRepairSnapshotPublishedFileEvidence(
                    fileName: $0.fileName,
                    exists: $0.exists,
                    size: $0.size,
                    sha256: $0.sha256
                )
            }
            try diagnosed(.workspacePreflight) {
                try validateWorkspaceMembership(
                    workspace: workspace,
                    files: publishedFiles
                )
            }
            let workspaceBefore = try diagnosed(.workspacePreflight) {
                try observeFiles(
                    rootURL: workspace.rootURL,
                    files: publishedFiles
                )
            }
            let result = try readInitialWitnessCatalogWorkspace(
                rootURL: workspace.rootURL,
                observations: workspaceBefore
            )
            guard source.profile.admits(databases: result.databases) else {
                throw DiagnosticFailure(point: .desktopContract)
            }
            try diagnosed(.workspacePostflight) {
                try validateWorkspaceMembership(
                    workspace: workspace,
                    files: publishedFiles,
                    allowingGeneratedSQLiteSharedMemory: true
                )
            }
            let immutableAfter = try diagnosed(.workspacePostflight) {
                try observeFiles(
                    rootURL: workspace.rootURL,
                    files: publishedFiles,
                    excludingSQLiteSharedMemory: true
                )
            }
            let immutableBefore = workspaceBefore.filter {
                !$0.key.hasSuffix("-shm")
            }
            guard immutableAfter == immutableBefore else {
                throw DiagnosticFailure(point: .workspacePostflight)
            }
            let sourceAfter = try diagnosed(.publishedSourcePostflight) {
                try source.fingerprint()
            }
            guard sourceAfter == sourceBefore else {
                throw DiagnosticFailure(point: .publishedSourcePostflight)
            }
            cleanupAttempted = true
            try diagnosed(.workspaceCleanup) { try workspace.remove() }
            return CodexGhostRepairInitialWitnessCatalogReadback(
                sourceLayoutIdentifier: source.profile.identifier,
                sourceFingerprintHash: sourceBefore.fingerprintHash,
                databases: result.databases,
                threadIDs: result.threadIDs
            )
        } catch {
            let primary = error
            guard !cleanupAttempted else { throw primary }
            cleanupAttempted = true
            do { try workspace.remove() } catch {
                throw DiagnosticFailure(point: .workspaceCleanup)
            }
            throw primary
        }
    }

    private static func readCanonicalSource(
        source: CodexGhostRepairSnapshotCanonicalSource,
        targetScope: TargetScope,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) throws -> (result: Result, sourceFingerprintHash: String) {
        let sourceBefore = try diagnosed(.publishedSourcePreflight) {
            let value = try source.fingerprint()
            try value.validateHash()
            return value
        }
        let workspace = try diagnosed(.workspaceCreation) {
            try workspaceFactory.create()
        }
        var cleanupAttempted = false
        do {
            try diagnosed(.workspaceCopy) {
                try copyCanonicalFiles(
                    source: source,
                    fingerprint: sourceBefore,
                    workspace: workspace
                )
            }
            let publishedFiles = sourceBefore.files.map {
                CodexGhostRepairSnapshotPublishedFileEvidence(
                    fileName: $0.fileName,
                    exists: $0.exists,
                    size: $0.size,
                    sha256: $0.sha256
                )
            }
            try diagnosed(.workspacePreflight) {
                try validateWorkspaceMembership(
                    workspace: workspace,
                    files: publishedFiles
                )
            }
            let workspaceBefore = try diagnosed(.workspacePreflight) {
                try observeFiles(
                    rootURL: workspace.rootURL,
                    files: publishedFiles
                )
            }
            let result = try readWorkspace(
                rootURL: workspace.rootURL,
                observations: workspaceBefore,
                targetScope: targetScope
            )
            guard source.profile.admits(databases: result.databases) else {
                throw DiagnosticFailure(point: .desktopContract)
            }
            try diagnosed(.workspacePostflight) {
                try validateWorkspaceMembership(
                    workspace: workspace,
                    files: publishedFiles,
                    allowingGeneratedSQLiteSharedMemory: true
                )
            }
            let immutableAfter = try diagnosed(.workspacePostflight) {
                try observeFiles(
                    rootURL: workspace.rootURL,
                    files: publishedFiles,
                    excludingSQLiteSharedMemory: true
                )
            }
            let immutableBefore = workspaceBefore.filter {
                !$0.key.hasSuffix("-shm")
            }
            guard immutableAfter == immutableBefore else {
                throw DiagnosticFailure(point: .workspacePostflight)
            }
            let sourceAfter = try diagnosed(.publishedSourcePostflight) {
                try source.fingerprint()
            }
            guard sourceAfter == sourceBefore else {
                throw DiagnosticFailure(point: .publishedSourcePostflight)
            }
            cleanupAttempted = true
            try diagnosed(.workspaceCleanup) { try workspace.remove() }
            return (result, sourceBefore.fingerprintHash)
        } catch {
            let primary = error
            guard !cleanupAttempted else { throw primary }
            cleanupAttempted = true
            do { try workspace.remove() } catch {
                throw DiagnosticFailure(point: .workspaceCleanup)
            }
            throw primary
        }
    }

    private static func readWorkspace(
        rootURL: URL,
        observations: [String: FileObservation],
        targetScope: TargetScope
    ) throws -> Result {
        var connections: [
            CodexGhostRepairSnapshotAnalysisDatabase: QueryOnlySQLite
        ] = [:]
        do {
            for database in CodexGhostRepairSnapshotAnalysisDatabase.allCases {
                let canonical = database.canonicalFile
                connections[database] = try diagnosed(
                    openFailurePoint(for: database)
                ) {
                    guard observations[canonical.rawValue] != nil else {
                        throw CodexGhostRepairError.invalidDatabaseContract(
                            "Published snapshot omitted a required analysis database."
                        )
                    }
                    return try QueryOnlySQLite(
                        url: rootURL.appendingPathComponent(
                            canonical.rawValue
                        ),
                        expected: try requiredObservation(
                            observations[canonical.rawValue],
                            fileName: canonical.rawValue
                        )
                    )
                }
            }

            guard let desktop = connections[.desktop],
                  let profile = CodexGhostRepairDatabaseSchemaProfile.admitted(
                      desktopUserVersion: try desktop.schemaVersion()
                  ) else {
                throw DiagnosticFailure(point: .desktopContract)
            }

            let databases = try CodexGhostRepairSnapshotAnalysisDatabase
                .allCases.map { database in
                    try diagnosed(contractFailurePoint(for: database)) {
                        guard let connection = connections[database] else {
                            throw CodexGhostRepairError.invalidDatabaseContract(
                                "Published snapshot database connection is unavailable."
                            )
                        }
                        try connection.validateM2cContract(
                            for: database,
                            profile: profile
                        )
                        return CodexGhostRepairSnapshotAnalysisDatabaseEvidence(
                            database: database,
                            schemaVersion: try connection.schemaVersion(),
                            integrityCheckPassed: try connection.integrityCheck(),
                            foreignKeyViolationCount:
                                try connection.foreignKeyViolationCount()
                        )
                    }
                }

            let targets = try diagnosed(.targetEvidence) {
                guard let desktop = connections[.desktop],
                      let summaries = connections[.summaries],
                      let state = connections[.state],
                      let history = connections[.threadHistory] else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot fixed database set is incomplete."
                    )
                }
                let targetThreadIDs: [String]
                switch targetScope {
                case let .exact(exact):
                    targetThreadIDs = exact
                case .completeLocalCatalog:
                    targetThreadIDs = try completeLocalCatalogThreadIDs(
                        desktop: desktop
                    )
                }
                return try targetThreadIDs.map { threadID in
                    try targetEvidence(
                        threadID: threadID,
                        desktop: desktop,
                        summaries: summaries,
                        state: state,
                        history: history
                    )
                }
            }
            let authority = try diagnosed(.authorityEvidence) {
                guard let desktop = connections[.desktop] else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot authority database is unavailable."
                    )
                }
                return try authorityEvidence(desktop: desktop)
            }

            try diagnosed(.databaseClose) {
                for database in CodexGhostRepairSnapshotAnalysisDatabase.allCases {
                    try connections[database]?.finish()
                }
            }
            connections.removeAll()

            return Result(
                databases: databases,
                targets: targets,
                authority: authority
            )
        } catch {
            connections.values.forEach { $0.close() }
            throw error
        }
    }

    private static func readInitialWitnessCatalogWorkspace(
        rootURL: URL,
        observations: [String: FileObservation]
    ) throws -> (
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence],
        threadIDs: [String]
    ) {
        var connections: [
            CodexGhostRepairSnapshotAnalysisDatabase: QueryOnlySQLite
        ] = [:]
        do {
            for database in CodexGhostRepairSnapshotAnalysisDatabase.allCases {
                let canonical = database.canonicalFile
                connections[database] = try diagnosed(
                    openFailurePoint(for: database)
                ) {
                    guard observations[canonical.rawValue] != nil else {
                        throw CodexGhostRepairError.invalidDatabaseContract(
                            "Initial witness discovery omitted a required analysis database."
                        )
                    }
                    return try QueryOnlySQLite(
                        url: rootURL.appendingPathComponent(
                            canonical.rawValue
                        ),
                        expected: try requiredObservation(
                            observations[canonical.rawValue],
                            fileName: canonical.rawValue
                        )
                    )
                }
            }

            guard let desktop = connections[.desktop],
                  let profile = CodexGhostRepairDatabaseSchemaProfile.admitted(
                      desktopUserVersion: try desktop.schemaVersion()
                  ) else {
                throw DiagnosticFailure(point: .desktopContract)
            }

            let databases = try CodexGhostRepairSnapshotAnalysisDatabase
                .allCases.map { database in
                    try diagnosed(contractFailurePoint(for: database)) {
                        guard let connection = connections[database] else {
                            throw CodexGhostRepairError.invalidDatabaseContract(
                                "Initial witness database connection is unavailable."
                            )
                        }
                        try connection.validateM2cContract(
                            for: database,
                            profile: profile
                        )
                        return CodexGhostRepairSnapshotAnalysisDatabaseEvidence(
                            database: database,
                            schemaVersion: try connection.schemaVersion(),
                            integrityCheckPassed: try connection.integrityCheck(),
                            foreignKeyViolationCount:
                                try connection.foreignKeyViolationCount()
                        )
                    }
                }
            let threadIDs = try diagnosed(.targetEvidence) {
                try completeLocalCatalogThreadIDs(desktop: desktop)
            }

            try diagnosed(.databaseClose) {
                for database in CodexGhostRepairSnapshotAnalysisDatabase.allCases {
                    try connections[database]?.finish()
                }
            }
            connections.removeAll()
            return (databases, threadIDs)
        } catch {
            connections.values.forEach { $0.close() }
            throw error
        }
    }

    private static func completeLocalCatalogThreadIDs(
        desktop: QueryOnlySQLite
    ) throws -> [String] {
        let rows = try desktop.query(
            .catalogInventory,
            maximumRows:
                CodexGhostRepairBulkInventory.maximumObservedCatalogItems
        )
        let identifiers = try rows.map { row -> String in
            guard row.fields.count == 1,
                  case let .text(value)? = row.value(named: "thread_id"),
                  let identifier = UUID(uuidString: value),
                  identifier.uuidString.lowercased() == value else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot catalog identity is invalid."
                )
            }
            return value
        }
        guard identifiers == identifiers.sorted(),
              Set(identifiers).count == identifiers.count else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Published snapshot catalog inventory is not canonical."
            )
        }
        return identifiers
    }

    private static func openFailurePoint(
        for database: CodexGhostRepairSnapshotAnalysisDatabase
    ) -> CodexGhostRepairSnapshotAnalysisFailurePoint {
        switch database {
        case .desktop: .desktopOpen
        case .summaries: .summariesOpen
        case .state: .stateOpen
        case .threadHistory: .threadHistoryOpen
        }
    }

    private static func contractFailurePoint(
        for database: CodexGhostRepairSnapshotAnalysisDatabase
    ) -> CodexGhostRepairSnapshotAnalysisFailurePoint {
        switch database {
        case .desktop: .desktopContract
        case .summaries: .summariesContract
        case .state: .stateContract
        case .threadHistory: .threadHistoryContract
        }
    }

    private static func targetEvidence(
        threadID: String,
        desktop: QueryOnlySQLite,
        summaries: QueryOnlySQLite,
        state: QueryOnlySQLite,
        history: QueryOnlySQLite
    ) throws -> CodexGhostRepairSnapshotAnalysisTargetEvidence {
        let catalogRows = try desktop.query(
            .catalog,
            bindings: [.text(threadID)],
            maximumRows: 2
        )
        let automationRows = try desktop.query(
            .automationRun,
            bindings: [.text(threadID)],
            maximumRows: 2
        )
        var definitionRows: [CodexGhostRepairSQLiteRow] = []
        for automation in automationRows {
            guard case let .text(automationID)? = automation.value(
                named: "automation_id"
            ) else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot automation identity is invalid."
                )
            }
            definitionRows.append(contentsOf: try desktop.query(
                .automationDefinition,
                bindings: [.text(automationID)],
                maximumRows: 2
            ))
            guard definitionRows.count <= 2 else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot automation definitions exceeded their bound."
                )
            }
        }
        let references = CodexGhostRepairSnapshotAnalysisReferenceCounts(
            inbox: try desktop.referenceCount(
                .inbox,
                threadID: threadID
            ),
            timeline: try desktop.referenceCount(
                .timeline,
                threadID: threadID
            ),
            summaries: try summaries.referenceCount(
                .summaries,
                threadID: threadID
            ),
            canonicalState: try state.referenceCount(
                .canonicalState,
                threadID: threadID
            ),
            threadTurns: try history.referenceCount(
                .threadTurns,
                threadID: threadID
            ),
            threadItems: try history.referenceCount(
                .threadItems,
                threadID: threadID
            ),
            historyProjection: try history.referenceCount(
                .historyProjection,
                threadID: threadID
            )
        )
        let rowContract = targetRowContract(
            threadID: threadID,
            catalogRows: catalogRows,
            automationRows: automationRows,
            definitionRows: definitionRows
        )
        var result = CodexGhostRepairSnapshotAnalysisTargetEvidence(
            threadID: threadID,
            catalogRowDigests: try catalogRows.map {
                try CodexGhostRepairBulkTargetEvidenceContract
                    .catalogAuthorizationDigest($0)
            },
            automationRunRowDigests: try automationRows.map {
                try CodexGhostRepairHasher.hash($0)
            },
            automationStableFieldsDigests: try automationRows.map {
                try CodexGhostRepairBulkTargetEvidenceContract
                    .automationIdentityDigest($0)
            },
            automationDefinitionRowDigests: try definitionRows.map {
                try CodexGhostRepairBulkTargetEvidenceContract
                    .automationDefinitionAuthorizationDigest($0)
            },
            references: references,
            rowContract: rowContract
        )
        let titleValues = [catalogRows.first?.value(named: "display_title"),
                           automationRows.first?.value(named: "thread_title")]
        result.displayTitle = titleValues.compactMap { value -> String? in
            guard case let .text(title)? = value else { return nil }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(512))
        }.first
        // Summary content leaves this reader only as hashes; titles stay in memory.
        if references.summaries > 0 && references.summaries <= 100 {
            result.summaryRowDigests = try summaries.query(
                .summaryRows, bindings: [.text(threadID)], maximumRows: 100
            ).map { try CodexGhostRepairHasher.hash($0) }.sorted()
        }
        if rowContract == .unsupported,
           definitionRows.first?.value(named: "status") == .text("PAUSED"),
           targetRowContract(threadID: threadID, catalogRows: catalogRows,
                             automationRows: automationRows, definitionRows: definitionRows,
                             allowPaused: true) == .categoryBEligible {
            result.pausedAutomationReviewable = true
        }
        return result
    }

    private static func targetRowContract(
        threadID: String,
        catalogRows: [CodexGhostRepairSQLiteRow],
        automationRows: [CodexGhostRepairSQLiteRow],
        definitionRows: [CodexGhostRepairSQLiteRow],
        allowPaused: Bool = false
    ) -> CodexGhostRepairSnapshotAnalysisRowContract {
        guard catalogRows.count == 1,
              catalogRows[0].value(named: "thread_id") == .text(threadID),
              catalogRows[0].value(named: "host_id") == .text("local") else {
            return .unsupported
        }
        if automationRows.isEmpty, definitionRows.isEmpty {
            return .categoryAEligible
        }
        guard automationRows.count == 1,
              definitionRows.count == 1,
              [.text("ACCEPTED"), .text("PENDING_REVIEW")].contains(
                automationRows[0].value(named: "status")
              ),
              automationRows[0].value(named: "archived_reason") == .null,
              isNullOrEmptyText(
                automationRows[0].value(named: "archived_user_message")
              ),
              isNullOrEmptyText(
                automationRows[0].value(named: "archived_assistant_message")
              ),
              (definitionRows[0].value(named: "status") == .text("ACTIVE")
                || (allowPaused && definitionRows[0].value(named: "status") == .text("PAUSED"))) else {
            return .unsupported
        }
        return .categoryBEligible
    }

    private static func isNullOrEmptyText(
        _ value: CodexGhostRepairSQLiteValue?
    ) -> Bool {
        value == .null || value == .text("")
    }

    private static func authorityEvidence(
        desktop: QueryOnlySQLite
    ) throws -> CodexGhostRepairSnapshotAnalysisAuthorityEvidence {
        let metadata = try desktop.query(.metadata, maximumRows: 2)
        let sync = try desktop.query(.localSync, maximumRows: 2)
        guard metadata.count == 1,
              sync.count == 1,
              case let .integer(catalogRevision)? = metadata[0].value(
                named: "catalog_revision"
              ),
              case let .integer(observationSequence)? = sync[0].value(
                named: "observation_sequence"
              ),
              catalogRevision >= 0,
              observationSequence >= 0 else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Published snapshot authority counters are unavailable."
            )
        }
        let watermark: Double?
        switch sync[0].value(named: "watermark_updated_at") {
        case let .real(value): watermark = value
        case let .integer(value): watermark = Double(value)
        case .null: watermark = nil
        default:
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Published snapshot watermark evidence is invalid."
            )
        }
        return .init(
            catalogRevision: catalogRevision,
            observationSequence: observationSequence,
            watermarkUpdatedAt: watermark,
            metadataRowDigest: try CodexGhostRepairHasher.hash(metadata[0]),
            localSyncRowDigest: try CodexGhostRepairHasher.hash(sync[0])
        )
    }

    private static func requiredObservation(
        _ value: FileObservation?,
        fileName: String
    ) throws -> FileObservation {
        guard let value else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Published snapshot omitted required fixed file \(fileName)."
            )
        }
        return value
    }

    private static func observeFiles(
        access:
            CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess
    ) throws -> [String: FileObservation] {
        try observeFiles(
            rootURL: access.snapshotRootURL,
            manifest: access.manifest
        )
    }

    private static func observeFiles(
        rootURL: URL,
        manifest: CodexGhostRepairSnapshotPublishedManifest,
        excludingSQLiteSharedMemory: Bool = false
    ) throws -> [String: FileObservation] {
        try observeFiles(
            rootURL: rootURL,
            files: manifest.files,
            excludingSQLiteSharedMemory: excludingSQLiteSharedMemory
        )
    }

    private static func observeFiles(
        rootURL: URL,
        files: [CodexGhostRepairSnapshotPublishedFileEvidence],
        excludingSQLiteSharedMemory: Bool = false
    ) throws -> [String: FileObservation] {
        try Dictionary(uniqueKeysWithValues: files.compactMap {
            file in
            guard file.exists,
                  !excludingSQLiteSharedMemory
                    || !file.fileName.hasSuffix("-shm") else { return nil }
            let observed = try observeFile(
                rootURL.appendingPathComponent(file.fileName),
                expected: file
            )
            return (file.fileName, observed)
        })
    }

    private static func copyPublishedFiles(
        access:
            CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess,
        sourceObservations: [String: FileObservation],
        workspace: CodexGhostRepairSnapshotAnalysisWorkspace
    ) throws {
        for file in access.manifest.files where file.exists {
            guard let expected = sourceObservations[file.fileName],
                  CodexGhostRepairSnapshotCanonicalFile(
                    rawValue: file.fileName
                  ) != nil else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Published snapshot workspace input is invalid."
                )
            }
            try copyRegularFileExactly(
                source: access.snapshotRootURL.appendingPathComponent(
                    file.fileName
                ),
                destination: workspace.rootURL.appendingPathComponent(
                    file.fileName
                ),
                expected: expected
            )
        }
    }

    private static func validateWorkspaceMembership(
        workspace: CodexGhostRepairSnapshotAnalysisWorkspace,
        manifest: CodexGhostRepairSnapshotPublishedManifest,
        allowingGeneratedSQLiteSharedMemory: Bool = false
    ) throws {
        try validateWorkspaceMembership(
            workspace: workspace,
            files: manifest.files,
            allowingGeneratedSQLiteSharedMemory:
                allowingGeneratedSQLiteSharedMemory
        )
    }

    private static func validateWorkspaceMembership(
        workspace: CodexGhostRepairSnapshotAnalysisWorkspace,
        files: [CodexGhostRepairSnapshotPublishedFileEvidence],
        allowingGeneratedSQLiteSharedMemory: Bool = false
    ) throws {
        let expected = files.filter(\.exists).map(\.fileName)
        let observed = try FileManager.default.contentsOfDirectory(
            at: workspace.rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ).map(\.lastPathComponent).sorted()
        let expectedSet = Set(expected)
        let observedSet = Set(observed)
        guard expectedSet.count == expected.count,
              observedSet.count == observed.count else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis workspace membership is invalid."
            )
        }
        guard allowingGeneratedSQLiteSharedMemory else {
            guard observedSet == expectedSet else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot analysis workspace membership is invalid."
                )
            }
            return
        }
        let allowedGenerated = allowedGeneratedSharedMemoryNames(files: files)
        let generated = observedSet.subtracting(expectedSet)
        guard expectedSet.isSubset(of: observedSet),
              generated.isSubset(of: allowedGenerated) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis workspace membership is invalid."
            )
        }
        for fileName in generated {
            try validateGeneratedSharedMemory(
                workspace.rootURL.appendingPathComponent(fileName)
            )
        }
    }

    private static func allowedGeneratedSharedMemoryNames(
        manifest: CodexGhostRepairSnapshotPublishedManifest
    ) -> Set<String> {
        allowedGeneratedSharedMemoryNames(files: manifest.files)
    }

    private static func allowedGeneratedSharedMemoryNames(
        files: [CodexGhostRepairSnapshotPublishedFileEvidence]
    ) -> Set<String> {
        let existing = Set(files.filter(\.exists).map(\.fileName))
        return Set(CodexGhostRepairSnapshotAnalysisDatabase.allCases.compactMap {
            database in
            let main = database.canonicalFile.rawValue
            let wal = main + "-wal"
            let sharedMemory = main + "-shm"
            guard existing.contains(main),
                  existing.contains(wal),
                  !existing.contains(sharedMemory),
                  CodexGhostRepairSnapshotCanonicalFile(rawValue: wal) != nil,
                  CodexGhostRepairSnapshotCanonicalFile(
                    rawValue: sharedMemory
                  ) != nil else { return nil }
            return sharedMemory
        })
    }

    private static func copyCanonicalFiles(
        source: CodexGhostRepairSnapshotCanonicalSource,
        fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        workspace: CodexGhostRepairSnapshotAnalysisWorkspace
    ) throws {
        for (file, evidence) in zip(
            source.profile.files,
            fingerprint.files
        ) where evidence.exists {
            let destination = workspace.rootURL.appendingPathComponent(
                evidence.fileName
            )
            let descriptor = Darwin.open(
                destination.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Fresh review workspace file could not be created."
                )
            }
            var primaryError: Error?
            do {
                guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Fresh review workspace file permissions are unavailable."
                    )
                }
                try source.streamRawRead(
                    file,
                    expected: evidence
                ) { data in
                    var written = 0
                    while written < data.count {
                        let count = data.withUnsafeBytes { bytes in
                            Darwin.write(
                                descriptor,
                                bytes.baseAddress!.advanced(by: written),
                                data.count - written
                            )
                        }
                        guard count > 0 else {
                            return
                        }
                        written += count
                    }
                    guard written == data.count else {
                        throw CodexGhostRepairError.invalidProtectionEvidence(
                            "Fresh review workspace copy was incomplete."
                        )
                    }
                }
                guard fsync(descriptor) == 0 else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Fresh review workspace file could not be synchronized."
                    )
                }
            } catch {
                primaryError = error
            }
            let closeResult = Darwin.close(descriptor)
            if let primaryError { throw primaryError }
            guard closeResult == 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Fresh review workspace file could not be closed."
                )
            }
        }
    }

    private static func validateGeneratedSharedMemory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis generated shared memory is unavailable."
            )
        }
        defer { Darwin.close(descriptor) }
        var held = stat()
        var path = stat()
        guard fstat(descriptor, &held) == 0,
              lstat(url.path, &path) == 0,
              (held.st_mode & S_IFMT) == S_IFREG,
              held.st_uid == geteuid(),
              held.st_mode & 0o7777 == 0o600,
              held.st_nlink == 1,
              held.st_size >= 0,
              held.st_dev == path.st_dev,
              held.st_ino == path.st_ino,
              held.st_mode == path.st_mode,
              held.st_uid == path.st_uid else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis generated shared memory is unsafe."
            )
        }
    }

    private static func copyRegularFileExactly(
        source: URL,
        destination: URL,
        expected: FileObservation
    ) throws {
        let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot workspace source could not be opened."
            )
        }
        defer { Darwin.close(sourceDescriptor) }
        var sourceBefore = stat()
        guard fstat(sourceDescriptor, &sourceBefore) == 0,
              try metadata(sourceBefore, hash: expected.sha256) == expected else {
            throw CodexGhostRepairError.targetDrift(
                "Published snapshot workspace source drifted before copy."
            )
        }
        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis workspace file could not be created."
            )
        }
        defer { Darwin.close(destinationDescriptor) }
        guard fchmod(destinationDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot analysis workspace file permissions are unavailable."
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let readCount = Darwin.read(sourceDescriptor, &buffer, buffer.count)
            if readCount < 0, errno == EINTR { continue }
            guard readCount >= 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Published snapshot workspace copy read failed."
                )
            }
            if readCount == 0 { break }
            hasher.update(data: Data(buffer[0..<readCount]))
            var offset = 0
            while offset < readCount {
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        readCount - offset
                    )
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Snapshot analysis workspace copy write failed."
                    )
                }
                offset += written
            }
        }
        let copiedHash = "sha256:" + hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        var sourceAfter = stat()
        guard copiedHash == expected.sha256,
              fsync(destinationDescriptor) == 0,
              fstat(sourceDescriptor, &sourceAfter) == 0,
              try metadata(sourceAfter, hash: expected.sha256) == expected else {
            throw CodexGhostRepairError.targetDrift(
                "Published snapshot workspace copy did not match its source."
            )
        }
    }

    private static func observeFile(
        _ url: URL,
        expected: CodexGhostRepairSnapshotPublishedFileEvidence
    ) throws -> FileObservation {
        guard let expectedSize = expected.size,
              let expectedHash = expected.sha256 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot file hash evidence is incomplete."
            )
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot analysis file could not be opened."
            )
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot analysis file metadata is unavailable."
            )
        }
        let initial = try metadata(before, hash: "")
        guard initial.size == expectedSize else {
            throw CodexGhostRepairError.targetDrift(
                "Published snapshot analysis file size drifted."
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Published snapshot analysis file read failed."
                )
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        let hash = "sha256:" + hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        var after = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(url.path, &pathAfter) == 0 else {
            throw CodexGhostRepairError.targetDrift(
                "Published snapshot analysis file drifted during read."
            )
        }
        let observed = try metadata(after, hash: hash)
        let pathObserved = try metadata(pathAfter, hash: hash)
        guard observed == pathObserved,
              observed.device == initial.device,
              observed.inode == initial.inode,
              observed.mode == initial.mode,
              observed.owner == initial.owner,
              observed.size == initial.size,
              observed.modificationSeconds == initial.modificationSeconds,
              observed.modificationNanoseconds
                == initial.modificationNanoseconds,
              hash == expectedHash else {
            throw CodexGhostRepairError.targetDrift(
                "Published snapshot analysis file identity or hash drifted."
            )
        }
        return observed
    }

    private static func metadata(
        _ status: stat,
        hash: String
    ) throws -> FileObservation {
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o600,
              status.st_size >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot analysis file evidence is unsafe."
            )
        }
        return FileObservation(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            owner: status.st_uid,
            size: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            sha256: hash
        )
    }

    private final class QueryOnlySQLite {
        private var database: OpaquePointer?
        private var guardDescriptor: Int32 = -1
        private let url: URL
        private let expected: FileObservation

        init(url: URL, expected: FileObservation) throws {
            self.url = url
            self.expected = expected
            guardDescriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
            guard guardDescriptor >= 0 else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot database identity guard failed."
                )
            }
            do {
                try validateGuardedPath()
            } catch {
                Darwin.close(guardDescriptor)
                guardDescriptor = -1
                throw error
            }
            var pointer: OpaquePointer?
            let result = sqlite3_open_v2(
                url.path,
                &pointer,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard result == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close_v2(pointer) }
                Darwin.close(guardDescriptor)
                guardDescriptor = -1
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot database could not be opened read-only."
                )
            }
            database = pointer
            do {
                guard sqlite3_db_readonly(pointer, "main") == 1 else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot database is not SQLite read-only."
                    )
                }
                try validateGuardedPath()
                try executeSetup("PRAGMA query_only=ON")
                guard sqlite3_busy_timeout(pointer, 250) == SQLITE_OK,
                      sqlite3_set_authorizer(
                        pointer,
                        codexGhostRepairSnapshotAnalysisAuthorize,
                        nil
                      ) == SQLITE_OK,
                      try scalarInteger(.queryOnly) == 1 else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot query-only setup failed."
                    )
                }
            } catch {
                close()
                throw error
            }
        }

        func close() {
            if let database {
                sqlite3_set_authorizer(database, nil, nil)
                sqlite3_close_v2(database)
                self.database = nil
            }
            if guardDescriptor >= 0 {
                Darwin.close(guardDescriptor)
                guardDescriptor = -1
            }
        }

        func finish() throws {
            if let database {
                sqlite3_set_authorizer(database, nil, nil)
                let closeResult = sqlite3_close_v2(database)
                self.database = nil
                guard closeResult == SQLITE_OK else {
                    close()
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot database did not close cleanly."
                    )
                }
            }
            try validateGuardedPath()
            Darwin.close(guardDescriptor)
            guardDescriptor = -1
        }

        func schemaVersion() throws -> Int32 {
            let value = try scalarInteger(.schemaVersion)
            guard value >= 0, value <= Int64(Int32.max) else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot schema version is invalid."
                )
            }
            return Int32(value)
        }

        func validateM2cContract(
            for database: CodexGhostRepairSnapshotAnalysisDatabase,
            profile: CodexGhostRepairDatabaseSchemaProfile
        ) throws {
            guard let expectedVersion = profile.databaseVersions[database],
                  try schemaVersion() == expectedVersion else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot database version is unsupported."
                )
            }
            if database == .desktop {
                try validateDesktopContract(profile.desktopTables)
                return
            }
            guard let contracts = CodexGhostRepairReferencedTables.byDatabase[database] else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot database contract is unavailable."
                )
            }
            for contract in contracts {
                let rows = try query(
                    .tableInfo(contract.table),
                    maximumRows: max(contract.columns.count + 1, 64)
                )
                let observed = try rows.map { row -> String in
                    guard case let .text(name)? = row.value(named: "name") else {
                        throw CodexGhostRepairError.invalidDatabaseContract(
                            "Published snapshot table metadata is invalid."
                        )
                    }
                    return name
                }
                let valid = contract.exact
                    ? observed == contract.columns
                    : contract.columns.allSatisfy(observed.contains)
                guard valid else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot table contract is unsupported."
                    )
                }
            }
        }

        private func validateDesktopContract(
            _ contracts: [CodexGhostRepairSQLiteTableContract]
        ) throws {
            for contract in contracts {
                let rows = try query(
                    .tableInfo(contract.table),
                    maximumRows: max(contract.columns.count + 1, 64)
                )
                let observed = try rows.map { row in
                    guard case let .text(name)? = row.value(named: "name"),
                          case let .text(type)? = row.value(named: "type"),
                          case let .integer(notNull)? = row.value(named: "notnull"),
                          case let .integer(primaryKey)? = row.value(named: "pk") else {
                        throw CodexGhostRepairError.invalidDatabaseContract(
                            "Published snapshot table metadata is invalid."
                        )
                    }
                    let defaultValue: String?
                    switch row.value(named: "dflt_value") {
                    case let .text(value)?: defaultValue = value
                    case .null?: defaultValue = nil
                    default:
                        throw CodexGhostRepairError.invalidDatabaseContract(
                            "Published snapshot column default is invalid."
                        )
                    }
                    return CodexGhostRepairSQLiteColumnContract(
                        name: name,
                        declaredType: type.uppercased(),
                        notNull: notNull == 1,
                        defaultValue: defaultValue,
                        primaryKeyPosition: Int(primaryKey)
                    )
                }
                guard observed == contract.columns else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot table contract is unsupported."
                    )
                }
                try validateCustomIndexes(contract)
            }
        }

        private func validateCustomIndexes(
            _ contract: CodexGhostRepairSQLiteTableContract
        ) throws {
            let rows = try query(
                .indexList(contract.table),
                maximumRows: 64
            )
            let custom = try rows.compactMap { row
                -> CodexGhostRepairSQLiteIndexContract? in
                guard case let .text(origin)? = row.value(named: "origin") else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot index metadata is invalid."
                    )
                }
                guard origin == "c" else { return nil }
                guard case let .text(name)? = row.value(named: "name"),
                      case let .integer(unique)? = row.value(named: "unique"),
                      case let .integer(partial)? = row.value(named: "partial") else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot index metadata is invalid."
                    )
                }
                let columns = try query(
                    .indexInfo(name),
                    maximumRows: 16
                ).map { columnRow -> String in
                    guard case let .text(column)? = columnRow.value(named: "name") else {
                        throw CodexGhostRepairError.invalidDatabaseContract(
                            "Published snapshot index column is invalid."
                        )
                    }
                    return column
                }
                return .init(
                    name: name,
                    unique: unique == 1,
                    partial: partial == 1,
                    columns: columns
                )
            }
            guard custom.sorted(by: { $0.name < $1.name })
                    == contract.customIndexes.sorted(by: { $0.name < $1.name }) else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot custom index contract is unsupported."
                )
            }
        }

        func integrityCheck() throws -> Bool {
            let rows = try query(.integrityCheck, maximumRows: 2)
            guard rows.count == 1,
                  rows[0].fields.count == 1,
                  rows[0].fields[0].value == .text("ok") else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot integrity check failed."
                )
            }
            return true
        }

        func foreignKeyViolationCount() throws -> Int {
            let rows = try query(.foreignKeyCheck, maximumRows: 1)
            guard rows.isEmpty else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot foreign-key check failed."
                )
            }
            return 0
        }

        func referenceCount(
            _ reference: ReferenceStatement,
            threadID: String
        ) throws -> Int {
            let rows = try query(
                .referenceCount(reference),
                bindings: [.text(threadID)],
                maximumRows: 1
            )
            guard rows.count == 1,
                  case let .integer(value)? = rows[0].value(named: "count"),
                  value >= 0,
                  value <= Int64(Int.max) else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot side-reference count is invalid."
                )
            }
            return Int(value)
        }

        private func scalarInteger(_ statement: Statement) throws -> Int64 {
            let rows = try query(statement, maximumRows: 1)
            guard rows.count == 1,
                  case let .integer(value) = rows[0].fields.first?.value else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot integer read failed."
                )
            }
            return value
        }

        private func executeSetup(_ sql: String) throws {
            guard let database,
                  sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot query-only setup failed."
                )
            }
        }

        private func validateGuardedPath() throws {
            guard guardDescriptor >= 0 else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot database identity guard is closed."
                )
            }
            var descriptorStatus = stat()
            var pathStatus = stat()
            guard fstat(guardDescriptor, &descriptorStatus) == 0,
                  lstat(url.path, &pathStatus) == 0,
                  Self.matches(descriptorStatus, expected: expected),
                  Self.matches(pathStatus, expected: expected) else {
                throw CodexGhostRepairError.targetDrift(
                    "Published snapshot database identity drifted."
                )
            }
        }

        private static func matches(
            _ status: stat,
            expected: FileObservation
        ) -> Bool {
            (status.st_mode & S_IFMT) == S_IFREG
                && UInt64(status.st_dev) == expected.device
                && UInt64(status.st_ino) == expected.inode
                && UInt32(status.st_mode) == expected.mode
                && status.st_uid == expected.owner
                && status.st_size >= 0
                && UInt64(status.st_size) == expected.size
                && Int64(status.st_mtimespec.tv_sec)
                    == expected.modificationSeconds
                && Int64(status.st_mtimespec.tv_nsec)
                    == expected.modificationNanoseconds
        }

        func query(
            _ statement: Statement,
            bindings: [Binding] = [],
            maximumRows: Int
        ) throws -> [CodexGhostRepairSQLiteRow] {
            guard let database else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot database is closed."
                )
            }
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                statement.sql,
                -1,
                &prepared,
                nil
            ) == SQLITE_OK, let prepared else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot fixed statement could not be prepared."
                )
            }
            defer { sqlite3_finalize(prepared) }
            guard sqlite3_stmt_readonly(prepared) == 1 else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Published snapshot statement is not read-only."
                )
            }
            for (offset, binding) in bindings.enumerated() {
                let result: Int32
                switch binding {
                case let .text(value):
                    result = value.withCString { pointer in
                        sqlite3_bind_text(
                            prepared,
                            Int32(offset + 1),
                            pointer,
                            -1,
                            unsafeBitCast(
                                -1,
                                to: sqlite3_destructor_type.self
                            )
                        )
                    }
                }
                guard result == SQLITE_OK else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot fixed statement binding failed."
                    )
                }
            }
            var rows: [CodexGhostRepairSQLiteRow] = []
            while true {
                let result = sqlite3_step(prepared)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW, rows.count < maximumRows else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "Published snapshot fixed statement exceeded its row bound."
                    )
                }
                var fields: [CodexGhostRepairSQLiteField] = []
                for index in 0..<sqlite3_column_count(prepared) {
                    let name = String(cString: sqlite3_column_name(prepared, index))
                    let value: CodexGhostRepairSQLiteValue
                    switch sqlite3_column_type(prepared, index) {
                    case SQLITE_NULL:
                        value = .null
                    case SQLITE_INTEGER:
                        value = .integer(sqlite3_column_int64(prepared, index))
                    case SQLITE_FLOAT:
                        value = .real(sqlite3_column_double(prepared, index))
                    case SQLITE_TEXT:
                        value = sqlite3_column_text(prepared, index).map {
                            .text(String(cString: $0))
                        } ?? .null
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(prepared, index))
                        if count == 0 {
                            value = .blob(Data())
                        } else if let bytes = sqlite3_column_blob(prepared, index) {
                            value = .blob(Data(bytes: bytes, count: count))
                        } else {
                            value = .null
                        }
                    default:
                        throw CodexGhostRepairError.invalidDatabaseContract(
                            "Published snapshot returned an unknown SQLite value."
                        )
                    }
                    fields.append(.init(name: name, value: value))
                }
                rows.append(.init(fields: fields))
            }
            return rows
        }

        enum Statement {
            case queryOnly
            case schemaVersion
            case integrityCheck
            case foreignKeyCheck
            case tableInfo(String)
            case indexList(String)
            case indexInfo(String)
            case catalogInventory
            case catalog
            case automationRun
            case automationDefinition
            case referenceCount(ReferenceStatement)
            case summaryRows
            case metadata
            case localSync

            var sql: String {
                switch self {
                case .queryOnly: "PRAGMA query_only"
                case .schemaVersion: "PRAGMA user_version"
                case .integrityCheck: "PRAGMA integrity_check"
                case .foreignKeyCheck: "PRAGMA foreign_key_check"
                case let .tableInfo(table): "PRAGMA table_info('\(table)')"
                case let .indexList(table): "PRAGMA index_list('\(table)')"
                case let .indexInfo(index): "PRAGMA index_info('\(index)')"
                case .catalogInventory:
                    "SELECT thread_id FROM local_thread_catalog WHERE host_id = 'local' ORDER BY thread_id"
                case .catalog:
                    "SELECT * FROM local_thread_catalog WHERE thread_id = ? ORDER BY host_id"
                case .automationRun:
                    "SELECT * FROM automation_runs WHERE thread_id = ? ORDER BY automation_id"
                case .automationDefinition:
                    "SELECT * FROM automations WHERE id = ? ORDER BY id"
                case .summaryRows:
                    "SELECT * FROM thread_turn_summaries WHERE thread_id = ? ORDER BY principal_key, host_key"
                case let .referenceCount(reference):
                    switch reference {
                    case .inbox:
                        "SELECT count(*) AS count FROM inbox_items WHERE thread_id = ?"
                    case .timeline:
                        "SELECT count(*) AS count FROM thread_timeline_ledger WHERE thread_id = ?"
                    case .summaries:
                        "SELECT count(*) AS count FROM thread_turn_summaries WHERE thread_id = ?"
                    case .canonicalState:
                        "SELECT count(*) AS count FROM threads WHERE id = ?"
                    case .threadTurns:
                        "SELECT count(*) AS count FROM thread_turns WHERE thread_id = ?"
                    case .threadItems:
                        "SELECT count(*) AS count FROM thread_items WHERE thread_id = ?"
                    case .historyProjection:
                        "SELECT count(*) AS count FROM thread_history_projection_state WHERE thread_id = ?"
                    }
                case .metadata:
                    "SELECT * FROM local_thread_catalog_metadata WHERE id = 1"
                case .localSync:
                    "SELECT * FROM local_thread_catalog_sync_state WHERE host_id = 'local'"
                }
            }
        }
    }
}

private func codexGhostRepairSnapshotAnalysisAuthorize(
    _ context: UnsafeMutableRawPointer?,
    _ actionCode: Int32,
    _ parameterOne: UnsafePointer<CChar>?,
    _ parameterTwo: UnsafePointer<CChar>?,
    _ databaseName: UnsafePointer<CChar>?,
    _ triggerName: UnsafePointer<CChar>?
) -> Int32 {
    _ = context
    _ = databaseName
    _ = triggerName
    return CodexGhostRepairSnapshotAnalysisAuthorizer.decision(
        actionCode: actionCode,
        parameterOne: parameterOne.map(String.init(cString:)),
        parameterTwo: parameterTwo.map(String.init(cString:))
    )
}
