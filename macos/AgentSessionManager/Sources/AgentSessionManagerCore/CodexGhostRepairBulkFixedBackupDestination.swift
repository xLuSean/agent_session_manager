import Darwin
import Foundation

enum CodexGhostRepairBulkFixedBackupDestinationState:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case available
    case exactColdReadback = "exact-cold-readback"
}

struct CodexGhostRepairBulkFixedBackupDestinationCapabilities:
    Equatable,
    Sendable
{
    let exactBundleRequired = true
    let exactMaintenanceWindowRequired = true
    let fixedManagerNamespace = true
    let operationIdentityIsDeterministic = true
    let inspectionIsFreshPerCall = true
    let coldReadbackSupported = true
    let acceptsCallerPath = false
    let overwritesExistingOperation = false
    let createsDirectory = false
    let createsBackupBytes = false
    let opensCodexSource = false
    let opensSQLite = false
    let createsClaim = false
    let automaticRetryAllowed = false
    let automaticCleanupAllowed = false
    let acceptsLiveCodexRoot = false
    let appWiringAvailable = false
    let repairMutationAuthority = false
}

private struct CodexGhostRepairBulkFixedBackupDestinationRecordPayload:
    Codable,
    Hashable
{
    let formatVersion: Int
    let destinationID: String
    let requestID: UUID
    let previewID: UUID
    let bundleDigest: String
    let maintenanceWindowDigest: String
    let selectedCount: Int
    let ordinaryCount: Int
    let automationCount: Int
    let blockedOutsideBatchCount: Int
    let storageRootDigest: String
}

/// Path-redacted identity for the one manager-owned destination associated
/// with an exact M4f-12 bundle and M4f-13 maintenance window. The record is
/// evidence only. It neither reserves the destination nor writes any bytes.
struct CodexGhostRepairBulkFixedBackupDestinationRecord:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    static let formatVersion = 1

    let formatVersion: Int
    let destinationID: String
    let requestID: UUID
    let previewID: UUID
    let bundleDigest: String
    let maintenanceWindowDigest: String
    let selectedCount: Int
    let ordinaryCount: Int
    let automationCount: Int
    let blockedOutsideBatchCount: Int
    let storageRootDigest: String
    let recordDigest: String

    var pathRedacted: Bool { true }
    var createsDirectory: Bool { false }
    var createsBackupBytes: Bool { false }
    var createsClaim: Bool { false }
    var repairMutationAuthority: Bool { false }

    init(
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        maintenanceWindow: CodexGhostRepairBulkMaintenanceWindow,
        storageRootDigest: String
    ) throws {
        guard maintenanceWindow.bundleDigest == resolution.bundleDigest,
              maintenanceWindow.before.requestID == resolution.requestID,
              maintenanceWindow.after.requestID == resolution.requestID,
              maintenanceWindow.before.previewID == resolution.previewID,
              maintenanceWindow.after.previewID == resolution.previewID,
              maintenanceWindow.before.selectedCount == resolution.selectedCount,
              maintenanceWindow.after.selectedCount == resolution.selectedCount,
              maintenanceWindow.before.ordinaryCount == resolution.ordinaryCount,
              maintenanceWindow.after.ordinaryCount == resolution.ordinaryCount,
              maintenanceWindow.before.automationCount == resolution.automationCount,
              maintenanceWindow.after.automationCount == resolution.automationCount,
              maintenanceWindow.before.blockedOutsideBatchCount
                == resolution.blockedOutsideBatchCount,
              maintenanceWindow.after.blockedOutsideBatchCount
                == resolution.blockedOutsideBatchCount,
              Self.isSHA256(storageRootDigest) else {
            throw CodexGhostRepairError.authorityDrift
        }
        let destinationID = resolution.requestID.uuidString.lowercased()
        let payload = CodexGhostRepairBulkFixedBackupDestinationRecordPayload(
            formatVersion: Self.formatVersion,
            destinationID: destinationID,
            requestID: resolution.requestID,
            previewID: resolution.previewID,
            bundleDigest: resolution.bundleDigest,
            maintenanceWindowDigest: maintenanceWindow.windowDigest,
            selectedCount: resolution.selectedCount,
            ordinaryCount: resolution.ordinaryCount,
            automationCount: resolution.automationCount,
            blockedOutsideBatchCount: resolution.blockedOutsideBatchCount,
            storageRootDigest: storageRootDigest
        )
        formatVersion = payload.formatVersion
        self.destinationID = payload.destinationID
        requestID = payload.requestID
        previewID = payload.previewID
        bundleDigest = payload.bundleDigest
        maintenanceWindowDigest = payload.maintenanceWindowDigest
        selectedCount = payload.selectedCount
        ordinaryCount = payload.ordinaryCount
        automationCount = payload.automationCount
        blockedOutsideBatchCount = payload.blockedOutsideBatchCount
        self.storageRootDigest = payload.storageRootDigest
        recordDigest = try CodexGhostRepairHasher.hash(payload)
        try validate()
    }

    func validate() throws {
        let payload = CodexGhostRepairBulkFixedBackupDestinationRecordPayload(
            formatVersion: formatVersion,
            destinationID: destinationID,
            requestID: requestID,
            previewID: previewID,
            bundleDigest: bundleDigest,
            maintenanceWindowDigest: maintenanceWindowDigest,
            selectedCount: selectedCount,
            ordinaryCount: ordinaryCount,
            automationCount: automationCount,
            blockedOutsideBatchCount: blockedOutsideBatchCount,
            storageRootDigest: storageRootDigest
        )
        guard formatVersion == Self.formatVersion,
              destinationID == requestID.uuidString.lowercased(),
              selectedCount > 0,
              selectedCount <= CodexGhostRepairBulkPreview.maximumSelectedItems,
              ordinaryCount >= 0,
              automationCount >= 0,
              ordinaryCount + automationCount == selectedCount,
              blockedOutsideBatchCount >= 0,
              Self.isSHA256(bundleDigest),
              Self.isSHA256(maintenanceWindowDigest),
              Self.isSHA256(storageRootDigest),
              Self.isSHA256(recordDigest),
              try CodexGhostRepairHasher.hash(payload) == recordDigest,
              pathRedacted,
              !createsDirectory,
              !createsBackupBytes,
              !createsClaim,
              !repairMutationAuthority else {
            throw CodexGhostRepairError.invalidPlan(
                "M4f fixed backup destination record is invalid."
            )
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

struct CodexGhostRepairBulkFixedBackupDestinationResolution:
    Equatable,
    Sendable
{
    let record: CodexGhostRepairBulkFixedBackupDestinationRecord
    let state: CodexGhostRepairBulkFixedBackupDestinationState

    var destinationID: String { record.destinationID }
    var canCreateNewBackup: Bool { state == .available }
    var coldReadbackMatched: Bool { state == .exactColdReadback }
    var pathRedacted: Bool { true }
    var overwriteAllowed: Bool { false }
    var createsDirectory: Bool { false }
    var createsBackupBytes: Bool { false }
    var createsClaim: Bool { false }
    var repairMutationAuthority: Bool { false }
}

protocol CodexGhostRepairBulkFixedBackupDestinationInspecting: Sendable {
    func storageRootDigestFresh() async throws -> String

    func inspectFresh(
        record: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) async throws -> CodexGhostRepairBulkFixedBackupDestinationState
}

/// M4f-14's caller-path-free resolver. It derives the same exact destination
/// identity from the bundle and maintenance window on every call, then asks a
/// separately typed backend for fresh state. It never creates or reserves it.
actor CodexGhostRepairBulkFixedBackupDestinationResolver {
    nonisolated let capabilities =
        CodexGhostRepairBulkFixedBackupDestinationCapabilities()

    private let resolution: CodexGhostRepairBulkProductionBundle.Resolution
    private let maintenanceWindow: CodexGhostRepairBulkMaintenanceWindow
    private let inspector:
        any CodexGhostRepairBulkFixedBackupDestinationInspecting
    private var inspectionInProgress = false

    init(
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        maintenanceWindow: CodexGhostRepairBulkMaintenanceWindow,
        inspector: any CodexGhostRepairBulkFixedBackupDestinationInspecting
    ) throws {
        guard resolution.bundleDigest == maintenanceWindow.bundleDigest,
              !resolution.createsBackup,
              !resolution.createsClaim,
              !resolution.repairMutationAuthority,
              !maintenanceWindow.createsBackup,
              !maintenanceWindow.createsClaim,
              !maintenanceWindow.repairMutationAuthority else {
            throw CodexGhostRepairError.authorityDrift
        }
        self.resolution = resolution
        self.maintenanceWindow = maintenanceWindow
        self.inspector = inspector
    }

    func inspectFresh()
        async throws -> CodexGhostRepairBulkFixedBackupDestinationResolution
    {
        guard !inspectionInProgress else {
            throw CodexGhostRepairError.recoveryRequired
        }
        inspectionInProgress = true
        defer { inspectionInProgress = false }

        let record = try CodexGhostRepairBulkFixedBackupDestinationRecord(
            resolution: resolution,
            maintenanceWindow: maintenanceWindow,
            storageRootDigest: try await inspector.storageRootDigestFresh()
        )
        let state = try await inspector.inspectFresh(record: record)
        return CodexGhostRepairBulkFixedBackupDestinationResolution(
            record: record,
            state: state
        )
    }
}

/// Read-only, marker-protected filesystem acceptance backend. Tests may inject
/// a private manager mirror; the resolver itself never accepts a path. This
/// backend recognizes only an absent exact directory or one exact immutable
/// record. Any partial, extra, replaced, or mismatched entry fails closed.
actor CodexGhostRepairBulkFixedBackupDestinationTestInspector:
    CodexGhostRepairBulkFixedBackupDestinationInspecting
{
    static let markerFileName =
        ".agent-session-manager-m4f14-fixed-backup-destination-v1"
    static let markerContents =
        "Agent Session Manager M4f-14 fixed backup destination v1\n"
    static let ghostRepairDirectoryName = "GhostRepair"
    static let operationBackupsDirectoryName = "OperationBackups"
    static let versionDirectoryName = "v1"
    static let recordFileName = "destination.json"

    nonisolated let storageRootDigest: String
    private let operationRootURL: URL

    init(
        testOwnedManagerRootURL: URL,
        testOwnedAllowedParentURL: URL
    ) throws {
        let managerRoot = testOwnedManagerRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let allowedParent = testOwnedAllowedParentURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let liveApplicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.standardizedFileURL.resolvingSymlinksInPath()
        let liveCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard managerRoot.path != allowedParent.path,
              Self.isDescendant(managerRoot, of: allowedParent),
              managerRoot.path != liveCodexHome.path,
              !Self.isDescendant(managerRoot, of: liveCodexHome),
              liveApplicationSupport.map({ managerRoot.path != $0.path }) ?? true,
              liveApplicationSupport.map({
                  !Self.isDescendant(managerRoot, of: $0)
              }) ?? true else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f-14 manager destination escaped its test-owned boundary."
            )
        }
        try Self.requirePrivateDirectory(allowedParent)
        try Self.requirePrivateDirectory(managerRoot)
        let marker = managerRoot.appendingPathComponent(Self.markerFileName)
        try Self.requirePrivateRegularFile(marker)
        guard try String(contentsOf: marker, encoding: .utf8)
                == Self.markerContents else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M4f-14 manager destination marker is missing or invalid."
            )
        }
        let storageRoot = managerRoot.appendingPathComponent(
            Self.ghostRepairDirectoryName,
            isDirectory: true
        )
        let operationBackups = storageRoot.appendingPathComponent(
            Self.operationBackupsDirectoryName,
            isDirectory: true
        )
        let operationRoot = operationBackups.appendingPathComponent(
            Self.versionDirectoryName,
            isDirectory: true
        )
        try Self.requirePrivateDirectory(storageRoot)
        try Self.requirePrivateDirectory(operationBackups)
        try Self.requirePrivateDirectory(operationRoot)
        operationRootURL = operationRoot
        storageRootDigest = try CodexGhostRepairHasher.hash(storageRoot.path)
    }

    func inspectFresh(
        record: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) throws -> CodexGhostRepairBulkFixedBackupDestinationState {
        try record.validate()
        guard record.storageRootDigest == storageRootDigest else {
            throw CodexGhostRepairError.authorityDrift
        }
        try Self.requirePrivateDirectory(operationRootURL)
        let destination = operationRootURL.appendingPathComponent(
            record.destinationID,
            isDirectory: true
        )
        var status = stat()
        if lstat(destination.path, &status) != 0 {
            guard errno == ENOENT else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "M4f-14 destination could not be inspected."
                )
            }
            return .available
        }
        try Self.requirePrivateDirectoryStatus(status)
        let members = try FileManager.default.contentsOfDirectory(
            atPath: destination.path
        )
        guard members == [Self.recordFileName] else {
            throw CodexGhostRepairError.backupFailed(
                "M4f-14 existing destination is partial or has extra members."
            )
        }
        let manifest = destination.appendingPathComponent(Self.recordFileName)
        try Self.requirePrivateRegularFile(manifest)
        let data = try Data(contentsOf: manifest)
        let observed = try JSONDecoder().decode(
            CodexGhostRepairBulkFixedBackupDestinationRecord.self,
            from: data
        )
        try observed.validate()
        guard observed == record else {
            throw CodexGhostRepairError.authorityDrift
        }
        return .exactColdReadback
    }

    func storageRootDigestFresh() -> String {
        storageRootDigest
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "M4f-14 private directory is unavailable."
            )
        }
        try requirePrivateDirectoryStatus(status)
    }

    private static func requirePrivateDirectoryStatus(_ status: stat) throws {
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              (status.st_mode & 0o077) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "M4f-14 directory identity or permission is unsafe."
            )
        }
    }

    private static func requirePrivateRegularFile(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              (status.st_mode & 0o077) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "M4f-14 private record is unsafe."
            )
        }
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && childComponents.prefix(parentComponents.count)
                == parentComponents[...]
    }
}
