import CryptoKit
import Darwin
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH
enum CodexGhostRepairSnapshotJournalStatus: String, Codable, Hashable, Sendable {
    case prepared
    case acquiring
    case published
    case failedWithoutPartial
    case unpublishedPartial
    case publicationInterrupted
}

struct CodexGhostRepairSnapshotJournalRecord: Codable, Hashable, Sendable {
    private struct Payload: Codable, Hashable {
        let snapshotID: UUID
        let status: CodexGhostRepairSnapshotJournalStatus
        let sourceRootDigest: String
        let observedRootDigest: String?
        let manifestHash: String?
        let failureDigest: String?
        let updatedAtMilliseconds: Int64
    }

    let snapshotID: UUID
    let status: CodexGhostRepairSnapshotJournalStatus
    let sourceRootDigest: String
    let observedRootDigest: String?
    let manifestHash: String?
    let failureDigest: String?
    let updatedAtMilliseconds: Int64
    let recordHash: String

    init(
        snapshotID: UUID,
        status: CodexGhostRepairSnapshotJournalStatus,
        sourceRootDigest: String,
        observedRootDigest: String?,
        manifestHash: String?,
        failureDigest: String?,
        updatedAtMilliseconds: Int64
    ) throws {
        let payload = Payload(
            snapshotID: snapshotID,
            status: status,
            sourceRootDigest: sourceRootDigest,
            observedRootDigest: observedRootDigest,
            manifestHash: manifestHash,
            failureDigest: failureDigest,
            updatedAtMilliseconds: updatedAtMilliseconds
        )
        self.snapshotID = snapshotID
        self.status = status
        self.sourceRootDigest = sourceRootDigest
        self.observedRootDigest = observedRootDigest
        self.manifestHash = manifestHash
        self.failureDigest = failureDigest
        self.updatedAtMilliseconds = updatedAtMilliseconds
        recordHash = try CodexGhostRepairHasher.hash(payload)
    }

    func validateHash() throws {
        let expected = try CodexGhostRepairHasher.hash(
            Payload(
                snapshotID: snapshotID,
                status: status,
                sourceRootDigest: sourceRootDigest,
                observedRootDigest: observedRootDigest,
                manifestHash: manifestHash,
                failureDigest: failureDigest,
                updatedAtMilliseconds: updatedAtMilliseconds
            )
        )
        guard expected == recordHash else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "snapshot journal checksum mismatch"
            )
        }
    }
}
struct CodexGhostRepairSnapshotJournalReadback: Hashable, Sendable {
    let durableRecord: CodexGhostRepairSnapshotJournalRecord
    let observedStatus: CodexGhostRepairSnapshotJournalStatus
    let partial: CodexGhostRepairSnapshotPartialRecord?
    let recoveryMutationAuthority: Bool
}

/// E29 app-owned, file-backed journal. It stores only digests and bounded
/// lifecycle facts. Recovery is readback-only and cannot retry acquisition.
actor CodexGhostRepairSnapshotJournal {
    static let recordPrefix = "snapshot-"
    static let recordSuffix = ".journal-v1.json"

    private let destination: CodexGhostRepairDisposableSnapshotDestination
    private let preBeginValidator: (@Sendable () throws -> Void)?

    init(destination: CodexGhostRepairDisposableSnapshotDestination) {
        self.destination = destination
        preBeginValidator = nil
    }

    init(preparedDestination: CodexGhostRepairPreparedSnapshotDestination) {
        destination = preparedDestination.destination
        preBeginValidator = {
            try preparedDestination.validateFresh()
        }
    }

    func begin(
        snapshotID: UUID,
        sourceRootDigest: String,
        nowMilliseconds: Int64
    ) throws -> CodexGhostRepairSnapshotJournalRecord {
        try preBeginValidator?()
        try destination.preparePrivateDirectories()
        let record = try CodexGhostRepairSnapshotJournalRecord(
            snapshotID: snapshotID,
            status: .prepared,
            sourceRootDigest: sourceRootDigest,
            observedRootDigest: nil,
            manifestHash: nil,
            failureDigest: nil,
            updatedAtMilliseconds: nowMilliseconds
        )
        try CodexGhostRepairDurableJSON.writeExclusive(record, to: recordURL(snapshotID))
        return try read(snapshotID: snapshotID)
    }

    func markAcquiring(snapshotID: UUID, nowMilliseconds: Int64) throws {
        let current = try read(snapshotID: snapshotID)
        guard current.status == .prepared else {
            throw CodexGhostRepairError.recoveryRequired
        }
        try replace(
            current,
            status: .acquiring,
            partial: nil,
            manifestHash: nil,
            failureDigest: nil,
            nowMilliseconds: nowMilliseconds
        )
    }

    func markPublished(
        snapshotID: UUID,
        manifestHash: String,
        nowMilliseconds: Int64
    ) throws {
        let current = try read(snapshotID: snapshotID)
        guard current.status == .acquiring else {
            throw CodexGhostRepairError.recoveryRequired
        }
        let rootDigest = try CodexGhostRepairHasher.hash(
            destination.publishedRoot(snapshotID: snapshotID).path
        )
        try replace(
            current,
            status: .published,
            partial: rootDigest,
            manifestHash: manifestHash,
            failureDigest: nil,
            nowMilliseconds: nowMilliseconds
        )
    }

    func markFailure(
        snapshotID: UUID,
        error: Error,
        nowMilliseconds: Int64
    ) throws {
        let current = try read(snapshotID: snapshotID)
        guard current.status == .prepared || current.status == .acquiring else {
            throw CodexGhostRepairError.recoveryRequired
        }
        let partial = try destination.partialRecord(snapshotID: snapshotID)
        let publishedManifestHash = try completePublishedManifestHash(snapshotID: snapshotID)
        let status: CodexGhostRepairSnapshotJournalStatus
        if publishedManifestHash != nil {
            status = .published
        } else {
            switch partial?.status {
            case .unpublishedPartial: status = .unpublishedPartial
            case .publicationInterrupted: status = .publicationInterrupted
            case nil: status = .failedWithoutPartial
            }
        }
        try replace(
            current,
            status: status,
            partial: publishedManifestHash == nil
                ? partial?.partialRootDigest
                : try CodexGhostRepairHasher.hash(
                    destination.publishedRoot(snapshotID: snapshotID).path
                ),
            manifestHash: publishedManifestHash,
            failureDigest: try CodexGhostRepairHasher.hash(
                String(describing: error)
            ),
            nowMilliseconds: nowMilliseconds
        )
    }

    func readback(snapshotID: UUID) throws -> CodexGhostRepairSnapshotJournalReadback {
        let record = try read(snapshotID: snapshotID)
        let partial = try destination.partialRecord(snapshotID: snapshotID)
        let publishedManifestHash = try completePublishedManifestHash(snapshotID: snapshotID)
        let observedStatus: CodexGhostRepairSnapshotJournalStatus
        if publishedManifestHash != nil {
            observedStatus = .published
        } else if let partial {
            observedStatus = partial.status == .unpublishedPartial
                ? .unpublishedPartial
                : .publicationInterrupted
        } else {
            observedStatus = record.status
        }
        return CodexGhostRepairSnapshotJournalReadback(
            durableRecord: record,
            observedStatus: observedStatus,
            partial: partial,
            recoveryMutationAuthority: false
        )
    }

    func records() throws -> [CodexGhostRepairSnapshotJournalReadback] {
        guard FileManager.default.fileExists(atPath: destination.journalRootURL.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            atPath: destination.journalRootURL.path
        )
        .filter { $0.hasPrefix(Self.recordPrefix) && $0.hasSuffix(Self.recordSuffix) }
        .compactMap(Self.snapshotID(fromRecordFileName:))
        .sorted { $0.uuidString < $1.uuidString }
        .map { try readback(snapshotID: $0) }
    }

    private func read(snapshotID: UUID) throws -> CodexGhostRepairSnapshotJournalRecord {
        let record = try CodexGhostRepairDurableJSON.read(
            CodexGhostRepairSnapshotJournalRecord.self,
            from: recordURL(snapshotID)
        )
        try record.validateHash()
        guard record.snapshotID == snapshotID else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "snapshot journal identity mismatch"
            )
        }
        return record
    }

    private func replace(
        _ current: CodexGhostRepairSnapshotJournalRecord,
        status: CodexGhostRepairSnapshotJournalStatus,
        partial: String?,
        manifestHash: String?,
        failureDigest: String?,
        nowMilliseconds: Int64
    ) throws {
        let replacement = try CodexGhostRepairSnapshotJournalRecord(
            snapshotID: current.snapshotID,
            status: status,
            sourceRootDigest: current.sourceRootDigest,
            observedRootDigest: partial,
            manifestHash: manifestHash,
            failureDigest: failureDigest,
            updatedAtMilliseconds: nowMilliseconds
        )
        try CodexGhostRepairDurableJSON.replace(
            replacement,
            at: recordURL(current.snapshotID)
        )
        guard try read(snapshotID: current.snapshotID) == replacement else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "snapshot journal durable readback mismatch"
            )
        }
    }

    private func recordURL(_ snapshotID: UUID) -> URL {
        destination.journalRootURL.appendingPathComponent(
            Self.recordPrefix + snapshotID.uuidString.lowercased() + Self.recordSuffix
        )
    }

    private func completePublishedManifestHash(snapshotID: UUID) throws -> String? {
        let root = destination.publishedRoot(snapshotID: snapshotID)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                CodexGhostRepairDisposableBundle.markerFileName
            ).path
        ) else { return nil }
        _ = try CodexGhostRepairDisposableBundle(
            rootURL: root,
            allowedParentURL: destination.snapshotsRootURL
        )
        let manifest = try CodexGhostRepairDurableJSON.read(
            CodexGhostRepairSnapshotAcquisitionManifest.self,
            from: root.appendingPathComponent(
                CodexGhostRepairDisposableSnapshotAcquirer.manifestFileName
            )
        )
        try manifest.validateHash()
        guard manifest.snapshotID == snapshotID else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "published snapshot manifest identity mismatch"
            )
        }
        return manifest.manifestHash
    }

    private static func snapshotID(fromRecordFileName name: String) -> UUID? {
        guard name.hasPrefix(recordPrefix), name.hasSuffix(recordSuffix) else { return nil }
        return UUID(
            uuidString: String(name.dropFirst(recordPrefix.count).dropLast(recordSuffix.count))
        )
    }
}

struct CodexGhostRepairQuarantineTrashTarget: Codable, Hashable, Sendable {
    let snapshotID: UUID
    let rootDigest: String
    let directoryDevice: UInt64
    let directoryInode: UInt64
    let files: [CodexGhostRepairSnapshotFileEvidence]
}

struct CodexGhostRepairQuarantineTrashPreview: Codable, Hashable, Sendable {
    private struct Payload: Codable, Hashable {
        let id: UUID
        let createdAtMilliseconds: Int64
        let targets: [CodexGhostRepairQuarantineTrashTarget]
    }

    let id: UUID
    let createdAtMilliseconds: Int64
    let targets: [CodexGhostRepairQuarantineTrashTarget]
    let manifestHash: String

    var recoveryMutationAuthority: Bool { false }

    init(
        id: UUID,
        createdAtMilliseconds: Int64,
        targets: [CodexGhostRepairQuarantineTrashTarget]
    ) throws {
        guard !targets.isEmpty,
              Set(targets.map(\.snapshotID)).count == targets.count else {
            throw CodexGhostRepairError.invalidPlan(
                "quarantine Trash Preview requires unique exact snapshot IDs"
            )
        }
        let sorted = targets.sorted { $0.snapshotID.uuidString < $1.snapshotID.uuidString }
        self.id = id
        self.createdAtMilliseconds = createdAtMilliseconds
        self.targets = sorted
        manifestHash = try CodexGhostRepairHasher.hash(
            Payload(id: id, createdAtMilliseconds: createdAtMilliseconds, targets: sorted)
        )
    }

    func validateHash() throws {
        let expected = try CodexGhostRepairHasher.hash(
            Payload(id: id, createdAtMilliseconds: createdAtMilliseconds, targets: targets)
        )
        guard expected == manifestHash else {
            throw CodexGhostRepairError.invalidPlan(
                "quarantine Trash Preview checksum mismatch"
            )
        }
    }
}

enum CodexGhostRepairQuarantineTrashOutcome: String, Codable, Hashable, Sendable {
    case movedToTrash
    case partial
    case notMoved
}

struct CodexGhostRepairQuarantineTrashReportItem: Codable, Hashable, Sendable {
    let snapshotID: UUID
    let absentFromQuarantine: Bool
}

struct CodexGhostRepairQuarantineTrashReport: Codable, Hashable, Sendable {
    private struct Payload: Codable, Hashable {
        let previewID: UUID
        let previewManifestHash: String
        let completedAtMilliseconds: Int64
        let outcome: CodexGhostRepairQuarantineTrashOutcome
        let items: [CodexGhostRepairQuarantineTrashReportItem]
        let mutationAttemptedOnce: Bool
        let mutationRetryAllowed: Bool
        let recoveredByReadback: Bool
    }

    let previewID: UUID
    let previewManifestHash: String
    let completedAtMilliseconds: Int64
    let outcome: CodexGhostRepairQuarantineTrashOutcome
    let items: [CodexGhostRepairQuarantineTrashReportItem]
    let mutationAttemptedOnce: Bool
    let mutationRetryAllowed: Bool
    let recoveredByReadback: Bool
    let reportHash: String

    init(
        previewID: UUID,
        previewManifestHash: String,
        completedAtMilliseconds: Int64,
        outcome: CodexGhostRepairQuarantineTrashOutcome,
        items: [CodexGhostRepairQuarantineTrashReportItem],
        mutationAttemptedOnce: Bool,
        mutationRetryAllowed: Bool,
        recoveredByReadback: Bool
    ) throws {
        let payload = Payload(
            previewID: previewID,
            previewManifestHash: previewManifestHash,
            completedAtMilliseconds: completedAtMilliseconds,
            outcome: outcome,
            items: items,
            mutationAttemptedOnce: mutationAttemptedOnce,
            mutationRetryAllowed: mutationRetryAllowed,
            recoveredByReadback: recoveredByReadback
        )
        self.previewID = previewID
        self.previewManifestHash = previewManifestHash
        self.completedAtMilliseconds = completedAtMilliseconds
        self.outcome = outcome
        self.items = items
        self.mutationAttemptedOnce = mutationAttemptedOnce
        self.mutationRetryAllowed = mutationRetryAllowed
        self.recoveredByReadback = recoveredByReadback
        reportHash = try CodexGhostRepairHasher.hash(payload)
    }

    func validateHash() throws {
        let expected = try CodexGhostRepairHasher.hash(
            Payload(
                previewID: previewID,
                previewManifestHash: previewManifestHash,
                completedAtMilliseconds: completedAtMilliseconds,
                outcome: outcome,
                items: items,
                mutationAttemptedOnce: mutationAttemptedOnce,
                mutationRetryAllowed: mutationRetryAllowed,
                recoveredByReadback: recoveredByReadback
            )
        )
        guard expected == reportHash else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "quarantine Trash Report checksum mismatch"
            )
        }
    }
}

protocol CodexGhostRepairQuarantineTrashTransport: Sendable {
    func moveToTrash(_ exactURLs: [URL]) async throws
}

/// E29 test-owned exact-quarantine cleanup. No production Trash transport is
/// provided; callers must inject one, and recovery never receives transport.
actor CodexGhostRepairQuarantineTrashCoordinator {
    private let destination: CodexGhostRepairDisposableSnapshotDestination
    private let transport: any CodexGhostRepairQuarantineTrashTransport

    init(
        destination: CodexGhostRepairDisposableSnapshotDestination,
        transport: any CodexGhostRepairQuarantineTrashTransport
    ) {
        self.destination = destination
        self.transport = transport
    }

    func prepare(
        previewID: UUID,
        snapshotIDs: [UUID],
        nowMilliseconds: Int64
    ) throws -> CodexGhostRepairQuarantineTrashPreview {
        try destination.preparePrivateDirectories()
        guard !snapshotIDs.isEmpty, Set(snapshotIDs).count == snapshotIDs.count else {
            throw CodexGhostRepairError.invalidPlan(
                "quarantine Trash selection must contain unique exact IDs"
            )
        }
        let targets = try snapshotIDs.map { try freezeTarget(snapshotID: $0) }
        let preview = try CodexGhostRepairQuarantineTrashPreview(
            id: previewID,
            createdAtMilliseconds: nowMilliseconds,
            targets: targets
        )
        try CodexGhostRepairDurableJSON.writeExclusive(
            preview,
            to: previewURL(previewID)
        )
        let readback = try readPreview(previewID)
        guard readback == preview else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "quarantine Trash Preview durable readback mismatch"
            )
        }
        return readback
    }

    func execute(
        previewID: UUID,
        expectedManifestHash: String,
        nowMilliseconds: Int64
    ) async throws -> CodexGhostRepairQuarantineTrashReport {
        let preview = try readPreview(previewID)
        guard preview.manifestHash == expectedManifestHash else {
            throw CodexGhostRepairError.confirmationMismatch
        }
        guard !FileManager.default.fileExists(atPath: claimURL(previewID).path) else {
            throw CodexGhostRepairError.claimAlreadyExists
        }
        for target in preview.targets {
            guard try freezeTarget(snapshotID: target.snapshotID) == target else {
                throw CodexGhostRepairError.targetDrift(
                    "quarantine snapshot changed after Preview"
                )
            }
        }
        try CodexGhostRepairDurableJSON.writeExclusive(
            try CodexGhostRepairQuarantineTrashClaim(
                previewID: preview.id,
                previewManifestHash: preview.manifestHash,
                claimedAtMilliseconds: nowMilliseconds
            ),
            to: claimURL(previewID)
        )
        do {
            try await transport.moveToTrash(
                preview.targets.map { destination.quarantineRoot(snapshotID: $0.snapshotID) }
            )
        } catch {
            return try finalize(
                preview: preview,
                nowMilliseconds: nowMilliseconds,
                recoveredByReadback: true
            )
        }
        return try finalize(
            preview: preview,
            nowMilliseconds: nowMilliseconds,
            recoveredByReadback: false
        )
    }

    func recover(
        previewID: UUID,
        nowMilliseconds: Int64
    ) throws -> CodexGhostRepairQuarantineTrashReport {
        let claim = try CodexGhostRepairDurableJSON.read(
            CodexGhostRepairQuarantineTrashClaim.self,
            from: claimURL(previewID)
        )
        try claim.validateHash()
        let preview = try readPreview(previewID)
        guard claim.previewID == preview.id,
              claim.previewManifestHash == preview.manifestHash else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return try finalize(
            preview: preview,
            nowMilliseconds: nowMilliseconds,
            recoveredByReadback: true
        )
    }

    private func freezeTarget(snapshotID: UUID) throws
        -> CodexGhostRepairQuarantineTrashTarget
    {
        let partial = try destination.partialRecord(snapshotID: snapshotID)
        guard partial?.status == .unpublishedPartial else {
            throw CodexGhostRepairError.invalidPlan(
                "only exact unpublished Quarantine snapshots may move to Trash"
            )
        }
        let root = destination.quarantineRoot(snapshotID: snapshotID)
        var rootStatus = stat()
        guard lstat(root.path, &rootStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR,
              (rootStatus.st_mode & 0o777) == 0o700 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "quarantine target is not a private real directory"
            )
        }
        let files = try partial!.fileNames.map { name in
            try Self.fileEvidence(root.appendingPathComponent(name), name: name)
        }
        return CodexGhostRepairQuarantineTrashTarget(
            snapshotID: snapshotID,
            rootDigest: try CodexGhostRepairHasher.hash(root.path),
            directoryDevice: UInt64(rootStatus.st_dev),
            directoryInode: UInt64(rootStatus.st_ino),
            files: files
        )
    }

    private func finalize(
        preview: CodexGhostRepairQuarantineTrashPreview,
        nowMilliseconds: Int64,
        recoveredByReadback: Bool
    ) throws -> CodexGhostRepairQuarantineTrashReport {
        if FileManager.default.fileExists(atPath: reportURL(preview.id).path) {
            let report = try CodexGhostRepairDurableJSON.read(
                CodexGhostRepairQuarantineTrashReport.self,
                from: reportURL(preview.id)
            )
            try report.validateHash()
            guard report.previewID == preview.id,
                  report.previewManifestHash == preview.manifestHash else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return report
        }
        let items = preview.targets.map {
            CodexGhostRepairQuarantineTrashReportItem(
                snapshotID: $0.snapshotID,
                absentFromQuarantine: !FileManager.default.fileExists(
                    atPath: destination.quarantineRoot(snapshotID: $0.snapshotID).path
                )
            )
        }
        let absentCount = items.filter(\.absentFromQuarantine).count
        let outcome: CodexGhostRepairQuarantineTrashOutcome = absentCount == items.count
            ? .movedToTrash
            : (absentCount == 0 ? .notMoved : .partial)
        let report = try CodexGhostRepairQuarantineTrashReport(
            previewID: preview.id,
            previewManifestHash: preview.manifestHash,
            completedAtMilliseconds: nowMilliseconds,
            outcome: outcome,
            items: items,
            mutationAttemptedOnce: true,
            mutationRetryAllowed: false,
            recoveredByReadback: recoveredByReadback
        )
        try CodexGhostRepairDurableJSON.writeExclusive(report, to: reportURL(preview.id))
        let readback = try CodexGhostRepairDurableJSON.read(
            CodexGhostRepairQuarantineTrashReport.self,
            from: reportURL(preview.id)
        )
        try readback.validateHash()
        guard readback == report else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "quarantine Trash Report durable readback mismatch"
            )
        }
        return readback
    }

    private func readPreview(_ previewID: UUID) throws
        -> CodexGhostRepairQuarantineTrashPreview
    {
        let preview = try CodexGhostRepairDurableJSON.read(
            CodexGhostRepairQuarantineTrashPreview.self,
            from: previewURL(previewID)
        )
        try preview.validateHash()
        guard preview.id == previewID else {
            throw CodexGhostRepairError.invalidPlan("quarantine Trash Preview ID mismatch")
        }
        return preview
    }

    private func previewURL(_ id: UUID) -> URL {
        destination.trashJournalRootURL.appendingPathComponent(
            "preview-\(id.uuidString.lowercased()).json"
        )
    }

    private func claimURL(_ id: UUID) -> URL {
        destination.trashJournalRootURL.appendingPathComponent(
            "claim-\(id.uuidString.lowercased()).json"
        )
    }

    private func reportURL(_ id: UUID) -> URL {
        destination.trashJournalRootURL.appendingPathComponent(
            "report-\(id.uuidString.lowercased()).json"
        )
    }

    private static func fileEvidence(_ url: URL, name: String) throws
        -> CodexGhostRepairSnapshotFileEvidence
    {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "quarantine contains a non-regular entry"
            )
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "quarantine entry could not be opened safely"
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == status.st_dev,
              opened.st_ino == status.st_ino else {
            throw CodexGhostRepairError.targetDrift(
                "quarantine entry identity drifted while opening"
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "quarantine entry hash read failed"
                )
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == opened.st_dev,
              after.st_ino == opened.st_ino,
              after.st_mode == opened.st_mode,
              after.st_size == opened.st_size,
              after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else {
            throw CodexGhostRepairError.targetDrift(
                "quarantine entry drifted while hashing"
            )
        }
        return CodexGhostRepairSnapshotFileEvidence(
            fileName: name,
            exists: true,
            device: UInt64(after.st_dev),
            inode: UInt64(after.st_ino),
            mode: UInt32(after.st_mode),
            size: UInt64(after.st_size),
            modificationSeconds: Int64(after.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(after.st_mtimespec.tv_nsec),
            sha256: "sha256:" + hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }
}

private struct CodexGhostRepairQuarantineTrashClaim: Codable, Hashable, Sendable {
    private struct Payload: Codable, Hashable {
        let previewID: UUID
        let previewManifestHash: String
        let claimedAtMilliseconds: Int64
    }

    let previewID: UUID
    let previewManifestHash: String
    let claimedAtMilliseconds: Int64
    let claimHash: String

    init(
        previewID: UUID,
        previewManifestHash: String,
        claimedAtMilliseconds: Int64
    ) throws {
        let payload = Payload(
            previewID: previewID,
            previewManifestHash: previewManifestHash,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
        self.previewID = previewID
        self.previewManifestHash = previewManifestHash
        self.claimedAtMilliseconds = claimedAtMilliseconds
        claimHash = try CodexGhostRepairHasher.hash(payload)
    }

    func validateHash() throws {
        let expected = try CodexGhostRepairHasher.hash(
            Payload(
                previewID: previewID,
                previewManifestHash: previewManifestHash,
                claimedAtMilliseconds: claimedAtMilliseconds
            )
        )
        guard expected == claimHash else {
            throw CodexGhostRepairError.recoveryRequired
        }
    }
}

private enum CodexGhostRepairDurableJSON {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func writeExclusive<T: Encodable>(_ value: T, to url: URL) throws {
        try write(encode(value), to: url, exclusive: true)
    }

    static func replace<T: Encodable>(_ value: T, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".replacement-\(UUID().uuidString.lowercased()).json"
        )
        try write(encode(value), to: temporary, exclusive: true)
        guard rename(temporary.path, url.path) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "durable journal replacement failed"
            )
        }
        try fsyncParent(url)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func write(_ data: Data, to url: URL, exclusive: Bool) throws {
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | (exclusive ? O_EXCL : O_TRUNC)
        let descriptor = Darwin.open(url.path, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw CodexGhostRepairError.claimAlreadyExists }
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "durable journal file creation failed"
            )
        }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                guard count > 0 else {
                    throw CodexGhostRepairError.snapshotAcquisitionFailed(
                        "durable journal write failed"
                    )
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "durable journal fsync failed"
            )
        }
        try fsyncParent(url)
    }

    private static func fsyncParent(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "durable journal parent could not be opened"
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "durable journal parent fsync failed"
            )
        }
    }
}
#endif
