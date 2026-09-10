import Darwin
import Foundation

enum CodexGhostRepairSnapshotPublishedFormat {
    static let snapshotDirectoryPrefix = "snapshot-"
    static let manifestFileName = "snapshot-manifest-v2.json"
    static let markerFileName = ".agent-session-manager-published-snapshot-v2"
    static let markerContents =
        "Agent Session Manager published Ghost Repair snapshot v2\n"
    static let publicationReceiptPrefix = "snapshot-"
    static let publicationReceiptSuffix = ".publication-v2.json"
}

struct CodexGhostRepairSnapshotPublishedFileEvidence:
    Codable,
    Equatable,
    Sendable
{
    let fileName: String
    let exists: Bool
    let size: UInt64?
    let sha256: String?
}

struct CodexGhostRepairSnapshotPublishedManifest:
    Codable,
    Equatable,
    Sendable
{
    private struct Payload: Codable, Equatable {
        let snapshotID: UUID
        let sourceLayoutIdentifier: String
        let sourceFingerprintHash: String
        let destinationBindingHash: String
        let files: [CodexGhostRepairSnapshotPublishedFileEvidence]
        let acquiredAtMilliseconds: Int64
    }

    let snapshotID: UUID
    let sourceLayoutIdentifier: String
    let sourceFingerprintHash: String
    let destinationBindingHash: String
    let files: [CodexGhostRepairSnapshotPublishedFileEvidence]
    let acquiredAtMilliseconds: Int64
    let manifestHash: String

    init(
        snapshotID: UUID,
        sourceFingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        destinationBinding: CodexGhostRepairSnapshotPreparedDestinationBinding,
        acquiredAtMilliseconds: Int64
    ) throws {
        try sourceFingerprint.validateHash()
        try destinationBinding.validateHash()
        let publishedFiles = sourceFingerprint.files.map {
            CodexGhostRepairSnapshotPublishedFileEvidence(
                fileName: $0.fileName,
                exists: $0.exists,
                size: $0.size,
                sha256: $0.sha256
            )
        }
        let payload = Payload(
            snapshotID: snapshotID,
            sourceLayoutIdentifier: sourceFingerprint.sourceLayoutIdentifier,
            sourceFingerprintHash: sourceFingerprint.fingerprintHash,
            destinationBindingHash: destinationBinding.bindingHash,
            files: publishedFiles,
            acquiredAtMilliseconds: acquiredAtMilliseconds
        )
        self.snapshotID = snapshotID
        sourceLayoutIdentifier = sourceFingerprint.sourceLayoutIdentifier
        sourceFingerprintHash = sourceFingerprint.fingerprintHash
        destinationBindingHash = destinationBinding.bindingHash
        files = publishedFiles
        self.acquiredAtMilliseconds = acquiredAtMilliseconds
        manifestHash = try CodexGhostRepairHasher.hash(payload)
        try validateHash()
    }

    func validateHash() throws {
        guard let profile = CodexGhostRepairSnapshotSourceProfile.admitted(
            sourceLayoutIdentifier: sourceLayoutIdentifier
        ) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot manifest source profile is unavailable."
            )
        }
        let expectedNames = profile.files.map(
            \.rawValue
        )
        guard files.map(\.fileName) == expectedNames,
              Set(files.map(\.fileName)).count == files.count,
              acquiredAtMilliseconds >= 0,
              Self.isSHA256(sourceFingerprintHash),
              Self.isSHA256(destinationBindingHash) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot manifest scope is invalid."
            )
        }
        for (file, canonical) in zip(
            files,
            profile.files
        ) {
            if file.exists {
                guard let size = file.size,
                      let sha256 = file.sha256,
                      Self.isSHA256(sha256),
                      size <= UInt64(Int64.max) else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Published snapshot manifest file evidence is invalid."
                    )
                }
            } else {
                guard !canonical.isRequiredDatabase,
                      file.size == nil,
                      file.sha256 == nil else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Published snapshot manifest omitted required evidence."
                    )
                }
            }
        }
        let expected = try CodexGhostRepairHasher.hash(Payload(
            snapshotID: snapshotID,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            sourceFingerprintHash: sourceFingerprintHash,
            destinationBindingHash: destinationBindingHash,
            files: files,
            acquiredAtMilliseconds: acquiredAtMilliseconds
        ))
        guard expected == manifestHash else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot manifest checksum mismatch."
            )
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

struct CodexGhostRepairSnapshotPublicationReceipt:
    Codable,
    Equatable,
    Sendable
{
    private struct Payload: Codable, Equatable {
        let snapshotID: UUID
        let acquisitionRecordHash: String
        let manifestHash: String
        let destinationBindingHash: String
        let publishedAtMilliseconds: Int64
    }

    let snapshotID: UUID
    let acquisitionRecordHash: String
    let manifestHash: String
    let destinationBindingHash: String
    let publishedAtMilliseconds: Int64
    let receiptHash: String

    init(
        snapshotID: UUID,
        acquisitionRecordHash: String,
        manifestHash: String,
        destinationBindingHash: String,
        publishedAtMilliseconds: Int64
    ) throws {
        let payload = Payload(
            snapshotID: snapshotID,
            acquisitionRecordHash: acquisitionRecordHash,
            manifestHash: manifestHash,
            destinationBindingHash: destinationBindingHash,
            publishedAtMilliseconds: publishedAtMilliseconds
        )
        self.snapshotID = snapshotID
        self.acquisitionRecordHash = acquisitionRecordHash
        self.manifestHash = manifestHash
        self.destinationBindingHash = destinationBindingHash
        self.publishedAtMilliseconds = publishedAtMilliseconds
        receiptHash = try CodexGhostRepairHasher.hash(payload)
        try validateHash()
    }

    func validateHash() throws {
        guard publishedAtMilliseconds >= 0,
              Self.isSHA256(acquisitionRecordHash),
              Self.isSHA256(manifestHash),
              Self.isSHA256(destinationBindingHash) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot publication receipt evidence is invalid."
            )
        }
        let expected = try CodexGhostRepairHasher.hash(Payload(
            snapshotID: snapshotID,
            acquisitionRecordHash: acquisitionRecordHash,
            manifestHash: manifestHash,
            destinationBindingHash: destinationBindingHash,
            publishedAtMilliseconds: publishedAtMilliseconds
        ))
        guard expected == receiptHash else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot publication receipt checksum mismatch."
            )
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

struct CodexGhostRepairSnapshotPublishedInventoryCapabilities: Sendable {
    let readsFixedPublishedInventory = true
    let opensRawDatabaseContents = false
    let acceptsCallerPath = false
    let writesFilesystem = false
    let automaticDeletionAuthority = false
    let cleanupAuthority = false
    let snapshotAcquisitionAuthority = false
    let repairMutationAuthority = false
}

struct CodexGhostRepairSnapshotPublishedEvidence: Equatable, Sendable {
    let snapshotID: UUID
    let publishedAtMilliseconds: Int64
    let manifestHash: String
    let publicationReceiptHash: String
    let regularFileCount: Int
    let actualBytes: UInt64

    let rawDatabaseContentVerified = false
}

struct CodexGhostRepairSnapshotPublishedInventory: Equatable, Sendable {
    let destinationBindingHash: String
    let snapshots: [CodexGhostRepairSnapshotPublishedEvidence]
    let totalBytes: UInt64

    let fixedSnapshotsRootOnly = true
    let rawDatabaseContentsOpened = 0
    let automaticDeletionAuthority = false
    let cleanupAuthority = false
    let repairMutationAuthority = false
}

enum CodexGhostRepairSnapshotRetentionBlock: String, Equatable, Sendable {
    case maximumSnapshotCountExceeded
    case maximumTotalBytesExceeded
    case maximumPublishedAgeExceeded
}

enum CodexGhostRepairSnapshotRetentionVerdict: Equatable, Sendable {
    case allowed
    case blocked([CodexGhostRepairSnapshotRetentionBlock])
}

struct CodexGhostRepairSnapshotRetentionAssessment: Equatable, Sendable {
    let inventory: CodexGhostRepairSnapshotPublishedInventory
    let policy: CodexGhostRepairDestinationCanaryPolicyEvidence
    let prospectiveSnapshotBytes: UInt64
    let oldestPublishedAgeMilliseconds: Int64?
    let verdict: CodexGhostRepairSnapshotRetentionVerdict

    let automaticDeletionAuthority = false
    let cleanupAuthority = false
    let snapshotAcquisitionAuthority = false
    let recoveryMutationAuthority = false
    let repairMutationAuthority = false
}

/// Fixed-root, metadata-only published snapshot inventory. It reads only
/// immutable app-owned marker, manifest, acquisition, and publication records.
/// Raw database contents are never opened and over-quota state only blocks the
/// acquisition coordinator.
struct CodexGhostRepairSnapshotPublishedInventoryCollector: Sendable {
    struct AnalysisAccess: Equatable, Sendable {
        let snapshotRootURL: URL
        let manifest: CodexGhostRepairSnapshotPublishedManifest
        let publishedEvidence: CodexGhostRepairSnapshotPublishedEvidence
    }

    private struct Metadata: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let owner: UInt32
        let size: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private static let maximumObservedSnapshots = 64
    private static let maximumManifestBytes: UInt64 = 1_048_576
    private static let maximumReceiptBytes: UInt64 = 65_536

    let capabilities = CodexGhostRepairSnapshotPublishedInventoryCapabilities()

    private let destination: CodexGhostRepairSnapshotPreparedDestination
    private let journal: CodexGhostRepairSnapshotAcquisitionJournal

    static func production(
        destination: CodexGhostRepairSnapshotPreparedDestination = .production()
    ) -> Self {
        Self(
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

    func assess(
        binding: CodexGhostRepairSnapshotPreparedDestinationBinding,
        prospectiveSnapshotBytes: UInt64,
        nowMilliseconds: Int64
    ) async throws -> CodexGhostRepairSnapshotRetentionAssessment {
        guard prospectiveSnapshotBytes > 0, nowMilliseconds >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot retention assessment requires bounded positive input."
            )
        }
        let inventory = try await inventory(binding: binding)
        let (prospectiveCount, countOverflow) = inventory.snapshots.count
            .addingReportingOverflow(1)
        let (prospectiveBytes, bytesOverflow) = inventory.totalBytes
            .addingReportingOverflow(prospectiveSnapshotBytes)
        guard !countOverflow, !bytesOverflow else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot retention admission arithmetic overflowed."
            )
        }

        var oldestAge: Int64?
        for snapshot in inventory.snapshots {
            guard snapshot.publishedAtMilliseconds <= nowMilliseconds else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Published snapshot timestamp is in the future."
                )
            }
            let age = nowMilliseconds - snapshot.publishedAtMilliseconds
            oldestAge = max(oldestAge ?? age, age)
        }

        let policy = binding.policy
        var blocks: [CodexGhostRepairSnapshotRetentionBlock] = []
        if prospectiveCount > policy.maximumSnapshotCount {
            blocks.append(.maximumSnapshotCountExceeded)
        }
        if prospectiveBytes > UInt64(policy.maximumTotalBytes) {
            blocks.append(.maximumTotalBytesExceeded)
        }
        if let oldestAge,
           oldestAge > policy.maximumAgeMilliseconds {
            blocks.append(.maximumPublishedAgeExceeded)
        }
        return CodexGhostRepairSnapshotRetentionAssessment(
            inventory: inventory,
            policy: policy,
            prospectiveSnapshotBytes: prospectiveSnapshotBytes,
            oldestPublishedAgeMilliseconds: oldestAge,
            verdict: blocks.isEmpty ? .allowed : .blocked(blocks)
        )
    }

    func inventory(
        binding: CodexGhostRepairSnapshotPreparedDestinationBinding
    ) async throws -> CodexGhostRepairSnapshotPublishedInventory {
        try await destination.validateFresh(binding)
        let location = try await destination.location(for: binding)
        let snapshotsRootBefore = try Self.directoryMetadata(
            location.snapshotsRootURL
        )
        let journalRootBefore = try Self.directoryMetadata(location.journalRootURL)
        let trashRootBefore = try Self.directoryMetadata(location.trashRootURL)
        let snapshotNamesBefore = try FileManager.default.contentsOfDirectory(
            atPath: location.snapshotsRootURL.path
        ).sorted()
        let journalNamesBefore = try FileManager.default.contentsOfDirectory(
            atPath: location.journalRootURL.path
        ).sorted()
        let trashNamesBefore = try FileManager.default.contentsOfDirectory(
            atPath: location.trashRootURL.path
        ).sorted()
        guard snapshotNamesBefore.count <= Self.maximumObservedSnapshots,
              journalNamesBefore.count <= Self.maximumObservedSnapshots * 3 + 1 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot inventory exceeds its fixed read bound."
            )
        }

        let snapshotIDs = try snapshotNamesBefore.map(Self.snapshotID)
        let journalIndex = try Self.journalIndex(
            names: journalNamesBefore,
            trashDirectoryName: location.trashRootURL.lastPathComponent
        )
        let retiredSnapshotIDs = try CodexGhostRepairSnapshotCleanupLedger
            .retiredSnapshotIDs(location: location)
        guard Set(snapshotIDs).isDisjoint(with: retiredSnapshotIDs),
              Set(snapshotIDs).union(retiredSnapshotIDs)
                == journalIndex.publicationIDs else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Active and retired snapshot directories disagree with publication receipts."
            )
        }

        var acquisitionRecords: [UUID: CodexGhostRepairSnapshotAcquisitionJournalRecord] = [:]
        for snapshotID in journalIndex.acquisitionIDs {
            acquisitionRecords[snapshotID] = try await journal.readback(
                snapshotID: snapshotID,
                destinationBinding: binding
            )
        }

        var evidence: [CodexGhostRepairSnapshotPublishedEvidence] = []
        var totalBytes: UInt64 = 0
        for snapshotID in snapshotIDs {
            guard let acquisition = acquisitionRecords[snapshotID] else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Published snapshot has no acquisition record."
                )
            }
            let observed = try Self.inspectPublishedSnapshot(
                snapshotID: snapshotID,
                acquisition: acquisition,
                binding: binding,
                location: location
            )
            let (next, overflow) = totalBytes.addingReportingOverflow(
                observed.actualBytes
            )
            guard !overflow else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Published snapshot byte inventory overflowed."
                )
            }
            totalBytes = next
            evidence.append(observed)
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
        for snapshotID in retiredSnapshotIDs {
            guard let acquisition = acquisitionRecords[snapshotID] else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Retired snapshot has no acquisition record."
                )
            }
            _ = try Self.inspectPublishedSnapshot(
                snapshotID: snapshotID,
                acquisition: acquisition,
                binding: binding,
                location: movedLocation
            )
        }

        let snapshotNamesAfter = try FileManager.default.contentsOfDirectory(
            atPath: location.snapshotsRootURL.path
        ).sorted()
        let journalNamesAfter = try FileManager.default.contentsOfDirectory(
            atPath: location.journalRootURL.path
        ).sorted()
        let trashNamesAfter = try FileManager.default.contentsOfDirectory(
            atPath: location.trashRootURL.path
        ).sorted()
        let snapshotsRootAfter = try Self.directoryMetadata(
            location.snapshotsRootURL
        )
        let journalRootAfter = try Self.directoryMetadata(location.journalRootURL)
        let trashRootAfter = try Self.directoryMetadata(location.trashRootURL)
        try await destination.validateFresh(binding)
        guard snapshotNamesAfter == snapshotNamesBefore,
              journalNamesAfter == journalNamesBefore,
              trashNamesAfter == trashNamesBefore,
              snapshotsRootAfter == snapshotsRootBefore,
              journalRootAfter == journalRootBefore,
              trashRootAfter == trashRootBefore else {
            throw CodexGhostRepairError.targetDrift(
                "Published snapshot roots drifted during inventory."
            )
        }
        return CodexGhostRepairSnapshotPublishedInventory(
            destinationBindingHash: binding.bindingHash,
            snapshots: evidence.sorted {
                $0.snapshotID.uuidString < $1.snapshotID.uuidString
            },
            totalBytes: totalBytes
        )
    }

    static func inspectPublishedSnapshot(
        snapshotID: UUID,
        acquisition: CodexGhostRepairSnapshotAcquisitionJournalRecord,
        binding: CodexGhostRepairSnapshotPreparedDestinationBinding,
        location: CodexGhostRepairSnapshotPreparedDestination.Location
    ) throws -> CodexGhostRepairSnapshotPublishedEvidence {
        let root = location.snapshotsRootURL.appendingPathComponent(
            snapshotDirectoryName(snapshotID),
            isDirectory: true
        )
        let directoryBefore = try directoryMetadata(root)
        let namesBefore = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).sorted()
        let metadataBefore = try fileMetadataMap(namesBefore, root: root)

        guard let markerMetadata = metadataBefore[
            CodexGhostRepairSnapshotPublishedFormat.markerFileName
        ], markerMetadata.size == UInt64(
            CodexGhostRepairSnapshotPublishedFormat.markerContents.utf8.count
        ), let manifestMetadata = metadataBefore[
            CodexGhostRepairSnapshotPublishedFormat.manifestFileName
        ], manifestMetadata.size <= maximumManifestBytes else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published marker or bounded manifest is unavailable."
            )
        }
        let marker = try boundedRead(
            root.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedFormat.markerFileName
            ),
            expected: markerMetadata,
            maximumBytes: UInt64(
                CodexGhostRepairSnapshotPublishedFormat.markerContents.utf8.count
            )
        )
        guard String(data: marker, encoding: .utf8)
                == CodexGhostRepairSnapshotPublishedFormat.markerContents else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot marker is invalid."
            )
        }
        let manifest = try JSONDecoder().decode(
            CodexGhostRepairSnapshotPublishedManifest.self,
            from: try boundedRead(
                root.appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedFormat.manifestFileName
                ),
                expected: manifestMetadata,
                maximumBytes: maximumManifestBytes
            )
        )
        try manifest.validateHash()
        guard manifest.snapshotID == snapshotID,
              manifest.sourceFingerprintHash == acquisition.sourceFingerprintHash,
              manifest.destinationBindingHash == binding.bindingHash,
              acquisition.destinationBindingHash == binding.bindingHash else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published manifest disagrees with frozen acquisition evidence."
            )
        }

        let expectedNames = Set(
            manifest.files.filter { $0.exists }.map { $0.fileName }
                + [
                    CodexGhostRepairSnapshotPublishedFormat.manifestFileName,
                    CodexGhostRepairSnapshotPublishedFormat.markerFileName,
                ]
        )
        guard Set(namesBefore) == expectedNames else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot file membership is not exact."
            )
        }
        for file in manifest.files where file.exists {
            guard let observed = metadataBefore[file.fileName],
                  observed.size == file.size else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Published snapshot file metadata disagrees with manifest."
                )
            }
        }

        let receiptURL = location.journalRootURL.appendingPathComponent(
            publicationReceiptName(snapshotID)
        )
        let receiptMetadata = try regularFileMetadata(receiptURL)
        guard receiptMetadata.size <= maximumReceiptBytes else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot publication receipt exceeds its fixed bound."
            )
        }
        let receipt = try JSONDecoder().decode(
            CodexGhostRepairSnapshotPublicationReceipt.self,
            from: try boundedRead(
                receiptURL,
                expected: receiptMetadata,
                maximumBytes: maximumReceiptBytes
            )
        )
        try receipt.validateHash()
        guard receipt.snapshotID == snapshotID,
              receipt.acquisitionRecordHash == acquisition.recordHash,
              receipt.manifestHash == manifest.manifestHash,
              receipt.destinationBindingHash == binding.bindingHash,
              receipt.publishedAtMilliseconds >= manifest.acquiredAtMilliseconds else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot publication receipt does not bind the published evidence."
            )
        }

        var actualBytes: UInt64 = 0
        for metadata in metadataBefore.values {
            let (next, overflow) = actualBytes.addingReportingOverflow(metadata.size)
            guard !overflow else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Published snapshot bytes overflowed."
                )
            }
            actualBytes = next
        }

        let namesAfter = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).sorted()
        let metadataAfter = try fileMetadataMap(namesAfter, root: root)
        let directoryAfter = try directoryMetadata(root)
        guard namesAfter == namesBefore,
              metadataAfter == metadataBefore,
              directoryAfter == directoryBefore else {
            throw CodexGhostRepairError.targetDrift(
                "Published snapshot drifted during metadata inventory."
            )
        }
        return CodexGhostRepairSnapshotPublishedEvidence(
            snapshotID: snapshotID,
            publishedAtMilliseconds: receipt.publishedAtMilliseconds,
            manifestHash: manifest.manifestHash,
            publicationReceiptHash: receipt.receiptHash,
            regularFileCount: namesBefore.count,
            actualBytes: actualBytes
        )
    }

    /// Returns an internal, fixed-root capability only after the complete
    /// published snapshot contract has been freshly revalidated. The URL never
    /// crosses the Core public API and does not itself authorize raw reads.
    static func analysisAccess(
        snapshotID: UUID,
        acquisition: CodexGhostRepairSnapshotAcquisitionJournalRecord,
        binding: CodexGhostRepairSnapshotPreparedDestinationBinding,
        location: CodexGhostRepairSnapshotPreparedDestination.Location
    ) throws -> AnalysisAccess {
        let published = try inspectPublishedSnapshot(
            snapshotID: snapshotID,
            acquisition: acquisition,
            binding: binding,
            location: location
        )
        let root = location.snapshotsRootURL.appendingPathComponent(
            snapshotDirectoryName(snapshotID),
            isDirectory: true
        )
        let manifestURL = root.appendingPathComponent(
            CodexGhostRepairSnapshotPublishedFormat.manifestFileName
        )
        let manifestMetadata = try regularFileMetadata(manifestURL)
        guard manifestMetadata.size <= maximumManifestBytes else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot manifest exceeds its fixed bound."
            )
        }
        let manifest = try JSONDecoder().decode(
            CodexGhostRepairSnapshotPublishedManifest.self,
            from: try boundedRead(
                manifestURL,
                expected: manifestMetadata,
                maximumBytes: maximumManifestBytes
            )
        )
        try manifest.validateHash()
        guard manifest.snapshotID == snapshotID,
              manifest.manifestHash == published.manifestHash,
              manifest.sourceFingerprintHash
                == acquisition.sourceFingerprintHash,
              manifest.destinationBindingHash == binding.bindingHash else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published analysis manifest disagrees with frozen evidence."
            )
        }
        return AnalysisAccess(
            snapshotRootURL: root,
            manifest: manifest,
            publishedEvidence: published
        )
    }

    static func journalIndex(
        names: [String],
        trashDirectoryName: String
    ) throws -> (acquisitionIDs: Set<UUID>, publicationIDs: Set<UUID>) {
        var acquisitions = Set<UUID>()
        var publications = Set<UUID>()
        for name in names {
            if name == trashDirectoryName { continue }
            if let snapshotID = exactJournalID(
                name,
                prefix: CodexGhostRepairSnapshotAcquisitionJournal.recordPrefix,
                suffix: CodexGhostRepairSnapshotAcquisitionJournal.recordSuffix
            ) {
                guard acquisitions.insert(snapshotID).inserted else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Duplicate acquisition journal identity."
                    )
                }
            } else if let snapshotID = exactJournalID(
                name,
                prefix: CodexGhostRepairSnapshotPublishedFormat
                    .publicationReceiptPrefix,
                suffix: CodexGhostRepairSnapshotPublishedFormat
                    .publicationReceiptSuffix
            ) {
                guard publications.insert(snapshotID).inserted else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Duplicate publication receipt identity."
                    )
                }
            } else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot Journal contains an unsupported entry."
                )
            }
        }
        guard publications.isSubset(of: acquisitions) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Publication receipt has no acquisition record."
            )
        }
        return (acquisitions, publications)
    }

    static func snapshotID(_ name: String) throws -> UUID {
        let prefix = CodexGhostRepairSnapshotPublishedFormat.snapshotDirectoryPrefix
        guard name.hasPrefix(prefix),
              let snapshotID = UUID(
                  uuidString: String(name.dropFirst(prefix.count))
              ),
              name == snapshotDirectoryName(snapshotID) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshots root contains an unsupported entry."
            )
        }
        return snapshotID
    }

    private static func exactJournalID(
        _ name: String,
        prefix: String,
        suffix: String
    ) -> UUID? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end,
              let snapshotID = UUID(uuidString: String(name[start..<end])),
              name == prefix + snapshotID.uuidString.lowercased() + suffix else {
            return nil
        }
        return snapshotID
    }

    static func snapshotDirectoryName(_ snapshotID: UUID) -> String {
        CodexGhostRepairSnapshotPublishedFormat.snapshotDirectoryPrefix
            + snapshotID.uuidString.lowercased()
    }

    static func publicationReceiptName(_ snapshotID: UUID) -> String {
        CodexGhostRepairSnapshotPublishedFormat.publicationReceiptPrefix
            + snapshotID.uuidString.lowercased()
            + CodexGhostRepairSnapshotPublishedFormat.publicationReceiptSuffix
    }

    private static func directoryMetadata(_ url: URL) throws -> Metadata {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o700 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot directory evidence is unsafe."
            )
        }
        return metadata(status)
    }

    private static func regularFileMetadata(_ url: URL) throws -> Metadata {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o600,
              status.st_size >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot file evidence is unsafe."
            )
        }
        return metadata(status)
    }

    private static func fileMetadataMap(
        _ names: [String],
        root: URL
    ) throws -> [String: Metadata] {
        try Dictionary(uniqueKeysWithValues: names.map {
            ($0, try regularFileMetadata(root.appendingPathComponent($0)))
        })
    }

    private static func metadata(_ status: stat) -> Metadata {
        Metadata(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            owner: status.st_uid,
            size: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private static func boundedRead(
        _ url: URL,
        expected: Metadata,
        maximumBytes: UInt64
    ) throws -> Data {
        guard expected.size <= maximumBytes,
              expected.size <= UInt64(Int.max) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published metadata record exceeds its read bound."
            )
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published metadata record could not be opened."
            )
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              metadata(before) == expected else {
            throw CodexGhostRepairError.targetDrift(
                "Published metadata record drifted before read."
            )
        }
        let data = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).readDataToEndOfFile()
        var after = stat()
        var pathAfter = stat()
        guard data.count == Int(expected.size),
              fstat(descriptor, &after) == 0,
              lstat(url.path, &pathAfter) == 0,
              metadata(after) == expected,
              metadata(pathAfter) == expected else {
            throw CodexGhostRepairError.targetDrift(
                "Published metadata record drifted during read."
            )
        }
        return data
    }
}
