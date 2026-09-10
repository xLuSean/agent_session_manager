import Darwin
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH
struct CodexGhostRepairPublishedSnapshotRetentionPolicy: Hashable, Sendable {
    let maximumSnapshotCount: Int
    let maximumTotalBytes: UInt64
    let maximumAgeMilliseconds: Int64

    init(
        maximumSnapshotCount: Int,
        maximumTotalBytes: UInt64,
        maximumAgeMilliseconds: Int64
    ) throws {
        guard maximumSnapshotCount > 0,
              maximumTotalBytes > 0,
              maximumAgeMilliseconds > 0 else {
            throw CodexGhostRepairError.invalidPlan(
                "E39 retention limits must all be positive."
            )
        }
        self.maximumSnapshotCount = maximumSnapshotCount
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumAgeMilliseconds = maximumAgeMilliseconds
    }
}

struct CodexGhostRepairPublishedSnapshotEvidence: Hashable, Sendable {
    let snapshotID: UUID
    let publishedAtMilliseconds: Int64
    let snapshotRootDigest: String
    let manifestHash: String
    let regularFileCount: Int
    let actualBytes: UInt64

    /// E39 intentionally reads only metadata plus the marker, manifest, and
    /// matching journal. Raw snapshot contents are not integrity evidence.
    let rawDatabaseContentVerified = false
}

struct CodexGhostRepairPublishedSnapshotInventory: Hashable, Sendable {
    let storageRootDigest: String
    let snapshots: [CodexGhostRepairPublishedSnapshotEvidence]
    let totalBytes: UInt64

    let fixedSnapshotsRootOnly = true
    let rawDatabaseContentsOpened = 0
    let snapshotDeletionAuthority = false
    let repairMutationAuthority = false
}

enum CodexGhostRepairPublishedSnapshotAdmissionBlock: String, Hashable, Sendable {
    case maximumSnapshotCountExceeded
    case maximumTotalBytesExceeded
    case maximumPublishedAgeExceeded
}

enum CodexGhostRepairPublishedSnapshotAdmissionVerdict: Hashable, Sendable {
    case allowed
    case blocked([CodexGhostRepairPublishedSnapshotAdmissionBlock])
}

struct CodexGhostRepairPublishedSnapshotRetentionAssessment: Hashable, Sendable {
    let inventory: CodexGhostRepairPublishedSnapshotInventory
    let policy: CodexGhostRepairPublishedSnapshotRetentionPolicy
    let prospectiveSnapshotBytes: UInt64
    let oldestPublishedAgeMilliseconds: Int64?
    let verdict: CodexGhostRepairPublishedSnapshotAdmissionVerdict

    /// Over quota blocks acquisition. It never selects or deletes snapshots.
    let automaticDeletionAllowed = false
    let snapshotAcquisitionAuthority = false
    let recoveryMutationAuthority = false
    let repairMutationAuthority = false
}

/// E39 read-only retention evidence for E35 test-owned, fixed Snapshots roots.
/// It does not open raw SQLite contents and exposes no cleanup operation.
struct CodexGhostRepairPublishedSnapshotRetentionCollector: Sendable {
    private struct FileMetadata: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let ownerUID: UInt32
        let size: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private static let snapshotPrefix = "snapshot-"
    private static let maximumObservedSnapshotCount = 10_000
    private static let maximumManifestBytes: UInt64 = 1_048_576
    private static let maximumJournalRecordBytes: UInt64 = 65_536

    private let preparedDestination: CodexGhostRepairPreparedSnapshotDestination
    private let destination: CodexGhostRepairDisposableSnapshotDestination

    init(preparedDestination: CodexGhostRepairPreparedSnapshotDestination) {
        self.preparedDestination = preparedDestination
        destination = preparedDestination.destination
    }

    func assess(
        policy: CodexGhostRepairPublishedSnapshotRetentionPolicy,
        prospectiveSnapshotBytes: UInt64,
        nowMilliseconds: Int64
    ) async throws -> CodexGhostRepairPublishedSnapshotRetentionAssessment {
        guard prospectiveSnapshotBytes > 0, nowMilliseconds >= 0 else {
            throw CodexGhostRepairError.invalidPlan(
                "E39 requires positive prospective bytes and a non-negative clock."
            )
        }
        let inventory = try await inventory()
        let (prospectiveCount, countOverflow) = inventory.snapshots.count
            .addingReportingOverflow(1)
        let (prospectiveTotalBytes, bytesOverflow) = inventory.totalBytes
            .addingReportingOverflow(prospectiveSnapshotBytes)
        guard !countOverflow, !bytesOverflow else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 prospective retention arithmetic overflowed."
            )
        }

        var oldestAge: Int64?
        for snapshot in inventory.snapshots {
            guard snapshot.publishedAtMilliseconds >= 0,
                  snapshot.publishedAtMilliseconds <= nowMilliseconds else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 published snapshot time is unavailable or in the future."
                )
            }
            let age = nowMilliseconds - snapshot.publishedAtMilliseconds
            oldestAge = max(oldestAge ?? age, age)
        }

        var blocks: [CodexGhostRepairPublishedSnapshotAdmissionBlock] = []
        if prospectiveCount > policy.maximumSnapshotCount {
            blocks.append(.maximumSnapshotCountExceeded)
        }
        if prospectiveTotalBytes > policy.maximumTotalBytes {
            blocks.append(.maximumTotalBytesExceeded)
        }
        if let oldestAge, oldestAge > policy.maximumAgeMilliseconds {
            blocks.append(.maximumPublishedAgeExceeded)
        }
        return CodexGhostRepairPublishedSnapshotRetentionAssessment(
            inventory: inventory,
            policy: policy,
            prospectiveSnapshotBytes: prospectiveSnapshotBytes,
            oldestPublishedAgeMilliseconds: oldestAge,
            verdict: blocks.isEmpty ? .allowed : .blocked(blocks)
        )
    }

    func inventory() async throws -> CodexGhostRepairPublishedSnapshotInventory {
        try preparedDestination.validateFresh()
        let snapshotsRootBefore = try directoryMetadata(
            destination.snapshotsRootURL,
            label: "Snapshots root"
        )
        let namesBefore = try FileManager.default.contentsOfDirectory(
            atPath: destination.snapshotsRootURL.path
        ).sorted()
        guard namesBefore.count <= Self.maximumObservedSnapshotCount else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 published snapshot inventory exceeds its fixed read bound."
            )
        }
        let journalRecords = try readValidatedJournalRecords()
        let journalByID = Dictionary(
            uniqueKeysWithValues: journalRecords.map { ($0.snapshotID, $0) }
        )

        var snapshots: [CodexGhostRepairPublishedSnapshotEvidence] = []
        for name in namesBefore {
            let snapshotID = try exactSnapshotID(from: name)
            guard let readback = journalByID[snapshotID] else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 published snapshot has no matching journal record."
                )
            }
            snapshots.append(
                try inspectSnapshot(
                    snapshotID: snapshotID,
                    directoryName: name,
                    journalRecord: readback
                )
            )
        }

        let publishedJournalIDs = Set(
            journalRecords.compactMap { record in
                record.status == .published ? record.snapshotID : nil
            }
        )
        guard publishedJournalIDs == Set(snapshots.map(\.snapshotID)) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 published snapshot directories and journal records disagree."
            )
        }

        var totalBytes: UInt64 = 0
        for snapshot in snapshots {
            let (next, overflow) = totalBytes.addingReportingOverflow(
                snapshot.actualBytes
            )
            guard !overflow else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 published snapshot bytes overflowed."
                )
            }
            totalBytes = next
        }

        let namesAfter = try FileManager.default.contentsOfDirectory(
            atPath: destination.snapshotsRootURL.path
        ).sorted()
        let snapshotsRootAfter = try directoryMetadata(
            destination.snapshotsRootURL,
            label: "Snapshots root"
        )
        let revalidatedSnapshots = try namesBefore.map { name in
            let snapshotID = try exactSnapshotID(from: name)
            guard let record = journalByID[snapshotID] else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 published snapshot lost its matching journal record."
                )
            }
            return try inspectSnapshot(
                snapshotID: snapshotID,
                directoryName: name,
                journalRecord: record
            )
        }
        try preparedDestination.validateFresh()
        guard namesAfter == namesBefore,
              snapshotsRootAfter == snapshotsRootBefore,
              revalidatedSnapshots == snapshots else {
            throw CodexGhostRepairError.targetDrift(
                "E39 Snapshots root drifted during retention inventory."
            )
        }

        return CodexGhostRepairPublishedSnapshotInventory(
            storageRootDigest: preparedDestination.storageRootDigest,
            snapshots: snapshots.sorted {
                $0.snapshotID.uuidString < $1.snapshotID.uuidString
            },
            totalBytes: totalBytes
        )
    }

    private func readValidatedJournalRecords() throws
        -> [CodexGhostRepairSnapshotJournalRecord]
    {
        let rootBefore = try directoryMetadata(
            destination.journalRootURL,
            label: "Journal root"
        )
        let names = try FileManager.default.contentsOfDirectory(
            atPath: destination.journalRootURL.path
        ).sorted()
        guard names.count <= Self.maximumObservedSnapshotCount + 1 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 snapshot journal inventory exceeds its fixed read bound."
            )
        }
        var records: [CodexGhostRepairSnapshotJournalRecord] = []
        var recordMetadata: [String: FileMetadata] = [:]
        for name in names {
            if name == CodexGhostRepairDisposableSnapshotDestination
                .trashJournalDirectoryName {
                _ = try directoryMetadata(
                    destination.trashJournalRootURL,
                    label: "Trash journal root"
                )
                continue
            }
            guard name.hasPrefix(CodexGhostRepairSnapshotJournal.recordPrefix),
                  name.hasSuffix(CodexGhostRepairSnapshotJournal.recordSuffix),
                  let snapshotID = journalSnapshotID(from: name),
                  name == journalRecordName(snapshotID) else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 Journal contains an unsupported entry."
                )
            }
            let metadata = try regularFileMetadata(
                destination.journalRootURL.appendingPathComponent(name),
                label: "snapshot journal record"
            )
            recordMetadata[name] = metadata
            guard metadata.size <= Self.maximumJournalRecordBytes else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 journal record exceeds its fixed read bound."
                )
            }
            let record = try JSONDecoder().decode(
                CodexGhostRepairSnapshotJournalRecord.self,
                from: try boundedRead(
                    destination.journalRootURL.appendingPathComponent(name),
                    expected: metadata,
                    maximumBytes: Self.maximumJournalRecordBytes,
                    label: "snapshot journal record"
                )
            )
            try record.validateHash()
            guard record.snapshotID == snapshotID else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 journal filename and durable identity disagree."
                )
            }
            records.append(record)
        }
        guard Set(records.map(\.snapshotID)).count == records.count else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 journal contains duplicate snapshot identities."
            )
        }
        let namesAfter = try FileManager.default.contentsOfDirectory(
            atPath: destination.journalRootURL.path
        ).sorted()
        let rootAfter = try directoryMetadata(
            destination.journalRootURL,
            label: "Journal root"
        )
        var metadataAfter: [String: FileMetadata] = [:]
        for name in recordMetadata.keys {
            metadataAfter[name] = try regularFileMetadata(
                destination.journalRootURL.appendingPathComponent(name),
                label: "snapshot journal record"
            )
        }
        guard namesAfter == names,
              rootAfter == rootBefore,
              metadataAfter == recordMetadata else {
            throw CodexGhostRepairError.targetDrift(
                "E39 snapshot journal drifted during retention inventory."
            )
        }
        return records.sorted { $0.snapshotID.uuidString < $1.snapshotID.uuidString }
    }

    private func inspectSnapshot(
        snapshotID: UUID,
        directoryName: String,
        journalRecord: CodexGhostRepairSnapshotJournalRecord
    ) throws -> CodexGhostRepairPublishedSnapshotEvidence {
        let root = destination.snapshotsRootURL.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        let directoryBefore = try directoryMetadata(root, label: "published snapshot")
        let namesBefore = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).sorted()
        let metadataBefore = try Dictionary(
            uniqueKeysWithValues: namesBefore.map { name in
                (name, try regularFileMetadata(
                    root.appendingPathComponent(name),
                    label: "published snapshot file"
                ))
            }
        )

        let markerName = CodexGhostRepairDisposableBundle.markerFileName
        let manifestName = CodexGhostRepairDisposableSnapshotAcquirer.manifestFileName
        guard let markerMetadata = metadataBefore[markerName],
              markerMetadata.size == UInt64(
                CodexGhostRepairDisposableBundle.markerContents.utf8.count
              ),
              let markerData = try? boundedRead(
                root.appendingPathComponent(markerName),
                expected: markerMetadata,
                maximumBytes: UInt64(
                    CodexGhostRepairDisposableBundle.markerContents.utf8.count
                ),
                label: "published snapshot marker"
              ),
              String(data: markerData, encoding: .utf8)
                == CodexGhostRepairDisposableBundle.markerContents,
              let manifestMetadata = metadataBefore[manifestName],
              manifestMetadata.size <= Self.maximumManifestBytes else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 published marker or bounded manifest evidence is unavailable."
            )
        }

        let manifest = try JSONDecoder().decode(
            CodexGhostRepairSnapshotAcquisitionManifest.self,
            from: try boundedRead(
                root.appendingPathComponent(manifestName),
                expected: manifestMetadata,
                maximumBytes: Self.maximumManifestBytes,
                label: "published snapshot manifest"
            )
        )
        try manifest.validateHash()
        guard manifest.snapshotID == snapshotID,
              Set(manifest.files.map(\.fileName)).count == manifest.files.count,
              Set(manifest.files.map(\.fileName))
                == Set(CodexGhostRepairCanonicalSourceFile.allCases.map(\.rawValue)) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 published manifest identity or file scope is invalid."
            )
        }

        let expectedNames = Set(
            manifest.files.filter(\.exists).map(\.fileName)
                + [markerName, manifestName]
        )
        guard Set(namesBefore) == expectedNames else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 published snapshot file membership drifted."
            )
        }
        for file in manifest.files {
            let metadata = metadataBefore[file.fileName]
            if file.exists {
                guard let metadata,
                      let expectedSize = file.size,
                      metadata.size == expectedSize else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "E39 published snapshot file metadata disagrees with manifest."
                    )
                }
            } else if metadata != nil {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 absent manifest sidecar appeared in published storage."
                )
            }
        }

        let record = journalRecord
        let rootDigest = try CodexGhostRepairHasher.hash(root.path)
        guard record.snapshotID == snapshotID,
              record.status == .published,
              record.sourceRootDigest == manifest.sourceRootDigest,
              record.observedRootDigest == rootDigest,
              record.manifestHash == manifest.manifestHash else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 published snapshot and journal evidence disagree."
            )
        }

        var actualBytes: UInt64 = 0
        for metadata in metadataBefore.values {
            let (next, overflow) = actualBytes.addingReportingOverflow(metadata.size)
            guard !overflow else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 published snapshot bytes overflowed."
                )
            }
            actualBytes = next
        }

        let namesAfter = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).sorted()
        let metadataAfter = try Dictionary(
            uniqueKeysWithValues: namesAfter.map { name in
                (name, try regularFileMetadata(
                    root.appendingPathComponent(name),
                    label: "published snapshot file"
                ))
            }
        )
        let directoryAfter = try directoryMetadata(root, label: "published snapshot")
        guard namesAfter == namesBefore,
              metadataAfter == metadataBefore,
              directoryAfter == directoryBefore else {
            throw CodexGhostRepairError.targetDrift(
                "E39 published snapshot drifted during retention inventory."
            )
        }

        return CodexGhostRepairPublishedSnapshotEvidence(
            snapshotID: snapshotID,
            publishedAtMilliseconds: record.updatedAtMilliseconds,
            snapshotRootDigest: rootDigest,
            manifestHash: manifest.manifestHash,
            regularFileCount: namesBefore.count,
            actualBytes: actualBytes
        )
    }

    private func exactSnapshotID(from name: String) throws -> UUID {
        guard name.hasPrefix(Self.snapshotPrefix),
              let snapshotID = UUID(
                uuidString: String(name.dropFirst(Self.snapshotPrefix.count))
              ),
              name == Self.snapshotPrefix + snapshotID.uuidString.lowercased() else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 Snapshots root contains a non-canonical entry."
            )
        }
        return snapshotID
    }

    private func journalSnapshotID(from name: String) -> UUID? {
        UUID(
            uuidString: String(
                name.dropFirst(CodexGhostRepairSnapshotJournal.recordPrefix.count)
                    .dropLast(CodexGhostRepairSnapshotJournal.recordSuffix.count)
            )
        )
    }

    private func journalRecordName(_ snapshotID: UUID) -> String {
        CodexGhostRepairSnapshotJournal.recordPrefix
            + snapshotID.uuidString.lowercased()
            + CodexGhostRepairSnapshotJournal.recordSuffix
    }

    private func directoryMetadata(_ url: URL, label: String) throws -> FileMetadata {
        let metadata = try metadata(url, label: label)
        guard metadata.mode & UInt32(S_IFMT) == UInt32(S_IFDIR),
              metadata.ownerUID == geteuid(),
              metadata.mode & 0o777 == 0o700 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 \(label) is not an owner-private real directory."
            )
        }
        return metadata
    }

    private func regularFileMetadata(_ url: URL, label: String) throws -> FileMetadata {
        let metadata = try metadata(url, label: label)
        guard metadata.mode & UInt32(S_IFMT) == UInt32(S_IFREG),
              metadata.ownerUID == geteuid(),
              metadata.mode & 0o777 == 0o600 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 \(label) is not an owner-private regular file."
            )
        }
        return metadata
    }

    private func metadata(_ url: URL, label: String) throws -> FileMetadata {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_size >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 \(label) metadata is unavailable."
            )
        }
        return FileMetadata(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            ownerUID: status.st_uid,
            size: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private func boundedRead(
        _ url: URL,
        expected: FileMetadata,
        maximumBytes: UInt64,
        label: String
    ) throws -> Data {
        guard expected.size <= maximumBytes, expected.size <= UInt64(Int.max) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 \(label) exceeds its fixed read bound."
            )
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 \(label) could not be opened safely."
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              try metadata(opened) == expected else {
            throw CodexGhostRepairError.targetDrift(
                "E39 \(label) identity drifted before read."
            )
        }
        var data = Data()
        data.reserveCapacity(Int(expected.size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 \(label) read failed."
                )
            }
            if count == 0 { break }
            guard data.count <= Int(maximumBytes) - count else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "E39 \(label) exceeded its fixed read bound."
                )
            }
            data.append(buffer, count: count)
        }
        guard data.count == Int(expected.size),
              fstat(descriptor, &opened) == 0,
              try metadata(opened) == expected else {
            throw CodexGhostRepairError.targetDrift(
                "E39 \(label) drifted during read."
            )
        }
        return data
    }

    private func metadata(_ status: stat) throws -> FileMetadata {
        guard status.st_size >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E39 file size evidence is invalid."
            )
        }
        return FileMetadata(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            ownerUID: status.st_uid,
            size: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }
}
#endif
