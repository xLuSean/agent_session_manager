import Darwin
import Foundation

public enum CodexGhostRepairSnapshotReadbackState:
    String,
    Equatable,
    Sendable
{
    case preparedOnly
    case unpublishedPartial
    case publicationInterrupted
    case published
    case movedToTrash
}

public struct CodexGhostRepairSnapshotReadbackItem: Equatable, Sendable {
    public let reference: String
    public let state: CodexGhostRepairSnapshotReadbackState
    public let targetCount: Int
    public let acquisitionRecordHash: String
    public let manifestHash: String?
    public let publicationReceiptHash: String?
    public let observedRegularFileCount: Int
    public let actualPublishedBytes: UInt64?

    public init(
        reference: String,
        state: CodexGhostRepairSnapshotReadbackState,
        targetCount: Int,
        acquisitionRecordHash: String,
        manifestHash: String?,
        publicationReceiptHash: String?,
        observedRegularFileCount: Int,
        actualPublishedBytes: UInt64?
    ) {
        self.reference = reference
        self.state = state
        self.targetCount = targetCount
        self.acquisitionRecordHash = acquisitionRecordHash
        self.manifestHash = manifestHash
        self.publicationReceiptHash = publicationReceiptHash
        self.observedRegularFileCount = observedRegularFileCount
        self.actualPublishedBytes = actualPublishedBytes
    }

    public var retryAllowed: Bool { false }
    public var cleanupAuthority: Bool { false }
    public var snapshotAcquisitionAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public struct CodexGhostRepairSnapshotReadbackInventory:
    Equatable,
    Sendable
{
    public let snapshots: [CodexGhostRepairSnapshotReadbackItem]
    public let totalPublishedBytes: UInt64

    public init(
        snapshots: [CodexGhostRepairSnapshotReadbackItem],
        totalPublishedBytes: UInt64
    ) {
        self.snapshots = snapshots
        self.totalPublishedBytes = totalPublishedBytes
    }

    public var pathRedacted: Bool { true }
    public var rawDatabaseContentsOpened: Int { 0 }
    public var retryAllowed: Bool { false }
    public var cleanupAuthority: Bool { false }
    public var snapshotAcquisitionAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public enum CodexGhostRepairSnapshotReadbackOutcome: Equatable, Sendable {
    case observed(CodexGhostRepairSnapshotReadbackInventory)
    case unavailable(message: String)
}

public struct CodexGhostRepairSnapshotReadbackCapabilities:
    Equatable,
    Sendable
{
    public let readbackAvailable: Bool

    public var acceptsCallerPath: Bool { false }
    public var opensRawDatabaseContents: Bool { false }
    public var writesFilesystem: Bool { false }
    public var retryAllowed: Bool { false }
    public var cleanupAuthority: Bool { false }
    public var snapshotAcquisitionAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let packagedReadOnly = Self(readbackAvailable: true)
    public static let unavailable = Self(readbackAvailable: false)

    private init(readbackAvailable: Bool) {
        self.readbackAvailable = readbackAvailable
    }
}

public protocol CodexGhostRepairSnapshotReadbackCoordinator: Sendable {
    var capabilities: CodexGhostRepairSnapshotReadbackCapabilities { get }
    func readback() async -> CodexGhostRepairSnapshotReadbackOutcome
}

protocol CodexGhostRepairSnapshotRecoveryInventoryReading: Sendable {
    func readbackInventory() async throws
        -> CodexGhostRepairSnapshotRecoveryInventory
}

/// Public no-path facade for explicit cold-start readback. It can only return
/// path-redacted app-owned journal and filesystem evidence. Errors are reduced
/// to a stable message so clear paths or private metadata cannot cross the App
/// boundary.
actor CodexGhostRepairSnapshotPackagedReadbackCoordinator:
    CodexGhostRepairSnapshotReadbackCoordinator
{
    nonisolated let capabilities =
        CodexGhostRepairSnapshotReadbackCapabilities.packagedReadOnly

    private let reader: any CodexGhostRepairSnapshotRecoveryInventoryReading

    static func production() -> Self {
        Self(reader: CodexGhostRepairSnapshotRecoveryReader.production())
    }

    init(reader: any CodexGhostRepairSnapshotRecoveryInventoryReading) {
        self.reader = reader
    }

    func readback() async -> CodexGhostRepairSnapshotReadbackOutcome {
        do {
            let inventory = try await reader.readbackInventory()
            return .observed(CodexGhostRepairSnapshotReadbackInventory(
                snapshots: inventory.snapshots.map(Self.publicItem),
                totalPublishedBytes: inventory.totalPublishedBytes
            ))
        } catch {
            return .unavailable(
                message: "Fixed Ghost Repair snapshot readback is unavailable; do not retry acquisition or clean up automatically."
            )
        }
    }

    private static func publicItem(
        _ evidence: CodexGhostRepairSnapshotRecoveryEvidence
    ) -> CodexGhostRepairSnapshotReadbackItem {
        CodexGhostRepairSnapshotReadbackItem(
            reference: evidence.snapshotID.uuidString.lowercased(),
            state: publicState(evidence.state),
            targetCount: evidence.targetCount,
            acquisitionRecordHash: evidence.acquisitionRecordHash,
            manifestHash: evidence.publishedEvidence?.manifestHash,
            publicationReceiptHash:
                evidence.publishedEvidence?.publicationReceiptHash,
            observedRegularFileCount: evidence.observedFileNames.count,
            actualPublishedBytes: evidence.publishedEvidence?.actualBytes
        )
    }

    private static func publicState(
        _ state: CodexGhostRepairSnapshotPublicationRecoveryState
    ) -> CodexGhostRepairSnapshotReadbackState {
        switch state {
        case .preparedOnly: .preparedOnly
        case .unpublishedPartial: .unpublishedPartial
        case .publicationInterrupted: .publicationInterrupted
        case .published: .published
        case .movedToTrash: .movedToTrash
        }
    }
}

public enum CodexGhostRepairSnapshotReadbackCoordinatorFactory {
    public static func packagedReadOnly()
        -> any CodexGhostRepairSnapshotReadbackCoordinator
    {
        CodexGhostRepairSnapshotPackagedReadbackCoordinator.production()
    }
}

struct CodexGhostRepairSnapshotRecoveryInventory: Equatable, Sendable {
    let snapshots: [CodexGhostRepairSnapshotRecoveryEvidence]
    let totalPublishedBytes: UInt64

    let pathRedacted = true
    let rawDatabaseContentsOpened = 0
    let retryAllowed = false
    let recoveryMutationAuthority = false
    let cleanupAuthority = false
    let snapshotAcquisitionAuthority = false
    let repairMutationAuthority = false
}

struct CodexGhostRepairSnapshotRecoveryEvidence: Equatable, Sendable {
    let snapshotID: UUID
    let state: CodexGhostRepairSnapshotPublicationRecoveryState
    let targetThreadIDs: [String]
    let preparedAtMilliseconds: Int64
    let sourceFingerprintHash: String
    let destinationBindingHash: String
    let observedFileNames: [String]
    let acquisitionRecordHash: String
    let publishedEvidence: CodexGhostRepairSnapshotPublishedEvidence?

    var targetCount: Int { targetThreadIDs.count }

    let retryAllowed = false
    let recoveryMutationAuthority = false
    let cleanupAuthority = false
    let snapshotAcquisitionAuthority = false
    let repairMutationAuthority = false
}

/// Core-internal metadata-only reader shared by packaged cold readback and the
/// publisher's exact recovery method. It owns no source, gate, write, retry,
/// cleanup, or repair capability.
struct CodexGhostRepairSnapshotRecoveryReader:
    CodexGhostRepairSnapshotRecoveryInventoryReading,
    Sendable
{
    private struct RootNames: Equatable {
        let snapshots: [String]
        let quarantine: [String]
        let journal: [String]
        let trash: [String]
    }

    private static let maximumObservedSnapshots = 64

    private let destination: CodexGhostRepairSnapshotPreparedDestination
    private let journal: CodexGhostRepairSnapshotAcquisitionJournal
    private let publishedInventory:
        CodexGhostRepairSnapshotPublishedInventoryCollector

    static func production() -> Self {
        let destination = CodexGhostRepairSnapshotPreparedDestination.production()
        let journal = CodexGhostRepairSnapshotAcquisitionJournal.production(
            destination: destination
        )
        return Self(
            destination: destination,
            journal: journal,
            publishedInventory:
                CodexGhostRepairSnapshotPublishedInventoryCollector(
                    destination: destination,
                    journal: journal
                )
        )
    }

    init(
        destination: CodexGhostRepairSnapshotPreparedDestination,
        journal: CodexGhostRepairSnapshotAcquisitionJournal,
        publishedInventory:
            CodexGhostRepairSnapshotPublishedInventoryCollector
    ) {
        self.destination = destination
        self.journal = journal
        self.publishedInventory = publishedInventory
    }

    func readbackInventory() async throws
        -> CodexGhostRepairSnapshotRecoveryInventory
    {
        let binding = try await destination.bindPrepared()
        let location = try await destination.location(for: binding)
        let before = try Self.rootNames(location)
        let index = try Self.index(before, location: location)

        var snapshots: [CodexGhostRepairSnapshotRecoveryEvidence] = []
        var totalPublishedBytes: UInt64 = 0
        for snapshotID in index.acquisitionIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            let evidence = try await readback(
                snapshotID: snapshotID,
                destinationBinding: binding,
                rootNames: before,
                index: index,
                location: location
            )
            if evidence.state == .published,
               let bytes = evidence.publishedEvidence?.actualBytes {
                let (next, overflow) = totalPublishedBytes
                    .addingReportingOverflow(bytes)
                guard !overflow else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Snapshot recovery byte count overflowed."
                    )
                }
                totalPublishedBytes = next
            }
            snapshots.append(evidence)
        }

        let after = try Self.rootNames(location)
        try await destination.validateFresh(binding)
        guard after == before else {
            throw CodexGhostRepairError.targetDrift(
                "Snapshot recovery roots drifted during readback."
            )
        }
        return CodexGhostRepairSnapshotRecoveryInventory(
            snapshots: snapshots,
            totalPublishedBytes: totalPublishedBytes
        )
    }

    func readback(
        snapshotID: UUID,
        destinationBinding: CodexGhostRepairSnapshotPreparedDestinationBinding
    ) async throws -> CodexGhostRepairSnapshotPublicationRecoveryEvidence {
        let location = try await destination.location(for: destinationBinding)
        let names = try Self.rootNames(location)
        let index = try Self.index(names, location: location)
        guard index.acquisitionIDs.contains(snapshotID) else {
            throw CodexGhostRepairError.recoveryRequired
        }
        let evidence = try await readback(
            snapshotID: snapshotID,
            destinationBinding: destinationBinding,
            rootNames: names,
            index: index,
            location: location
        )
        let after = try Self.rootNames(location)
        try await destination.validateFresh(destinationBinding)
        guard after == names else {
            throw CodexGhostRepairError.targetDrift(
                "Snapshot recovery roots drifted during exact readback."
            )
        }
        return CodexGhostRepairSnapshotPublicationRecoveryEvidence(
            snapshotID: evidence.snapshotID,
            state: evidence.state,
            observedFileNames: evidence.observedFileNames,
            acquisitionRecordHash: evidence.acquisitionRecordHash,
            manifestPresent: evidence.observedFileNames.contains(
                CodexGhostRepairSnapshotPublishedFormat.manifestFileName
            ),
            publicationReceiptPresent:
                index.publicationIDs.contains(snapshotID),
            markerPresent: evidence.observedFileNames.contains(
                CodexGhostRepairSnapshotPublishedFormat.markerFileName
            )
        )
    }

    private func readback(
        snapshotID: UUID,
        destinationBinding: CodexGhostRepairSnapshotPreparedDestinationBinding,
        rootNames: RootNames,
        index: (
            acquisitionIDs: Set<UUID>,
            publicationIDs: Set<UUID>,
            snapshotIDs: Set<UUID>,
            quarantineIDs: Set<UUID>,
            retiredIDs: Set<UUID>
        ),
        location: CodexGhostRepairSnapshotPreparedDestination.Location
    ) async throws -> CodexGhostRepairSnapshotRecoveryEvidence {
        let acquisition = try await journal.readback(
            snapshotID: snapshotID,
            destinationBinding: destinationBinding
        )
        let inSnapshots = index.snapshotIDs.contains(snapshotID)
        let inQuarantine = index.quarantineIDs.contains(snapshotID)
        let receiptPresent = index.publicationIDs.contains(snapshotID)
        let inTrash = index.retiredIDs.contains(snapshotID)
        guard [inSnapshots, inQuarantine, inTrash].filter({ $0 }).count <= 1 else {
            throw CodexGhostRepairError.recoveryRequired
        }

        let observedNames: [String]
        let state: CodexGhostRepairSnapshotPublicationRecoveryState
        var published: CodexGhostRepairSnapshotPublishedEvidence?
        if inQuarantine {
            observedNames = try Self.partialNames(
                location.quarantineRootURL.appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedInventoryCollector
                        .snapshotDirectoryName(snapshotID),
                    isDirectory: true
                )
            )
            guard !receiptPresent,
                  !observedNames.contains(
                    CodexGhostRepairSnapshotPublishedFormat.markerFileName
                  ) else {
                throw CodexGhostRepairError.recoveryRequired
            }
            state = .unpublishedPartial
        } else if inSnapshots {
            let root = location.snapshotsRootURL.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(snapshotID),
                isDirectory: true
            )
            observedNames = try Self.partialNames(root)
            if observedNames.contains(
                CodexGhostRepairSnapshotPublishedFormat.markerFileName
            ) {
                guard receiptPresent else {
                    throw CodexGhostRepairError.recoveryRequired
                }
                published = try CodexGhostRepairSnapshotPublishedInventoryCollector
                    .inspectPublishedSnapshot(
                        snapshotID: snapshotID,
                        acquisition: acquisition,
                        binding: destinationBinding,
                        location: location
                    )
                state = .published
            } else {
                state = .publicationInterrupted
            }
        } else if inTrash {
            guard receiptPresent else {
                throw CodexGhostRepairError.recoveryRequired
            }
            let movedLocation = CodexGhostRepairSnapshotPreparedDestination.Location(
                applicationSupportURL: location.applicationSupportURL,
                bundleRootURL: location.bundleRootURL,
                storageRootURL: location.storageRootURL,
                snapshotsRootURL: location.trashRootURL,
                quarantineRootURL: location.quarantineRootURL,
                journalRootURL: location.journalRootURL,
                trashRootURL: location.trashRootURL
            )
            let root = location.trashRootURL.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(snapshotID),
                isDirectory: true
            )
            observedNames = try Self.partialNames(root)
            published = try CodexGhostRepairSnapshotPublishedInventoryCollector
                .inspectPublishedSnapshot(
                    snapshotID: snapshotID,
                    acquisition: acquisition,
                    binding: destinationBinding,
                    location: movedLocation
                )
            state = .movedToTrash
        } else {
            guard !receiptPresent else {
                throw CodexGhostRepairError.recoveryRequired
            }
            observedNames = []
            state = .preparedOnly
        }

        return CodexGhostRepairSnapshotRecoveryEvidence(
            snapshotID: snapshotID,
            state: state,
            targetThreadIDs: acquisition.targetThreadIDs,
            preparedAtMilliseconds: acquisition.preparedAtMilliseconds,
            sourceFingerprintHash: acquisition.sourceFingerprintHash,
            destinationBindingHash: acquisition.destinationBindingHash,
            observedFileNames: observedNames,
            acquisitionRecordHash: acquisition.recordHash,
            publishedEvidence: published
        )
    }

    private static func rootNames(
        _ location: CodexGhostRepairSnapshotPreparedDestination.Location
    ) throws -> RootNames {
        RootNames(
            snapshots: try boundedNames(location.snapshotsRootURL),
            quarantine: try boundedNames(location.quarantineRootURL),
            journal: try boundedNames(
                location.journalRootURL,
                maximum: maximumObservedSnapshots * 2 + 1
            ),
            trash: try boundedNames(location.trashRootURL, maximum: 256)
        )
    }

    private static func boundedNames(
        _ root: URL,
        maximum: Int = maximumObservedSnapshots
    ) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).sorted()
        guard names.count <= maximum else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot recovery inventory exceeds its fixed read bound."
            )
        }
        return names
    }

    private static func index(
        _ names: RootNames,
        location: CodexGhostRepairSnapshotPreparedDestination.Location
    ) throws -> (
        acquisitionIDs: Set<UUID>,
        publicationIDs: Set<UUID>,
        snapshotIDs: Set<UUID>,
        quarantineIDs: Set<UUID>,
        retiredIDs: Set<UUID>
    ) {
        let journalIndex = try CodexGhostRepairSnapshotPublishedInventoryCollector
            .journalIndex(
                names: names.journal,
                trashDirectoryName: location.trashRootURL.lastPathComponent
            )
        guard journalIndex.acquisitionIDs.count <= maximumObservedSnapshots else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot recovery inventory exceeds its fixed snapshot bound."
            )
        }
        let snapshots = try Set(names.snapshots.map(
            CodexGhostRepairSnapshotPublishedInventoryCollector.snapshotID
        ))
        let quarantine = try Set(names.quarantine.map(
            CodexGhostRepairSnapshotPublishedInventoryCollector.snapshotID
        ))
        let retired = try CodexGhostRepairSnapshotCleanupLedger
            .retiredSnapshotIDs(location: location)
        guard snapshots.isDisjoint(with: quarantine),
              snapshots.isDisjoint(with: retired),
              quarantine.isDisjoint(with: retired),
              snapshots.union(quarantine).union(retired).isSubset(
                of: journalIndex.acquisitionIDs
              ),
              journalIndex.publicationIDs.isSubset(
                of: journalIndex.acquisitionIDs
              ) else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return (
            journalIndex.acquisitionIDs,
            journalIndex.publicationIDs,
            snapshots,
            quarantine,
            retired
        )
    }

    private static func partialNames(_ root: URL) throws -> [String] {
        var directory = stat()
        guard lstat(root.path, &directory) == 0,
              (directory.st_mode & S_IFMT) == S_IFDIR,
              directory.st_uid == geteuid(),
              directory.st_mode & 0o7777 == 0o700 else {
            throw CodexGhostRepairError.recoveryRequired
        }
        let allowed = Set(
            CodexGhostRepairSnapshotCanonicalFile.allCases.map(\.rawValue)
                + [
                    CodexGhostRepairSnapshotPublishedFormat.manifestFileName,
                    CodexGhostRepairSnapshotPublishedFormat.markerFileName,
                ]
        )
        let names = try boundedNames(root, maximum: allowed.count)
        guard Set(names).isSubset(of: allowed) else {
            throw CodexGhostRepairError.recoveryRequired
        }
        for name in names {
            var entry = stat()
            guard lstat(root.appendingPathComponent(name).path, &entry) == 0,
                  (entry.st_mode & S_IFMT) == S_IFREG,
                  entry.st_uid == geteuid(),
                  entry.st_mode & 0o7777 == 0o600 else {
                throw CodexGhostRepairError.recoveryRequired
            }
        }
        return names
    }
}
