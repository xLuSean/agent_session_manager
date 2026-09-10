import CryptoKit
import Darwin
import Foundation

struct CodexGhostRepairSnapshotQuarantinePublisherCapabilities: Sendable {
    let readsFixedRawDatabaseFiles = true
    let writesAppOwnedQuarantineFiles = true
    let publishesAppOwnedSnapshots = true
    let writesCodexDatabaseFiles = false
    let acceptsCallerPath = false
    let retriesAcquisition = false
    let automaticCleanupAuthority = false
    let repairMutationAuthority = false
}

enum CodexGhostRepairSnapshotPublicationRecoveryState:
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

struct CodexGhostRepairSnapshotPublicationRecoveryEvidence:
    Equatable,
    Sendable
{
    let snapshotID: UUID
    let state: CodexGhostRepairSnapshotPublicationRecoveryState
    let observedFileNames: [String]
    let acquisitionRecordHash: String
    let manifestPresent: Bool
    let publicationReceiptPresent: Bool
    let markerPresent: Bool

    let retryAllowed = false
    let recoveryMutationAuthority = false
    let automaticCleanupAuthority = false
    let repairMutationAuthority = false
}

struct CodexGhostRepairSnapshotPublishedAcquisition: Equatable, Sendable {
    let snapshotID: UUID
    let acquisitionRecordHash: String
    let manifestHash: String
    let publicationReceiptHash: String
    let sourceFingerprintHash: String
    let destinationBindingHash: String
    let publishedEvidence: CodexGhostRepairSnapshotPublishedEvidence

    let writesCodexDatabaseFiles = false
    let repairMutationAuthority = false
}

/// M1b-6 narrow app-owned raw snapshot publisher. The base production factory
/// remains permanently gate-blocked. M1b-9 adds a separate internal factory
/// that composes the fixed read-only production operational gate, but only the
/// default-blocked packaged coordinator may construct it. Every attempted copy
/// is journal-first, one-shot, and leaves only readback authority after
/// interruption.
actor CodexGhostRepairSnapshotQuarantinePublisher {
    typealias Clock = @Sendable () -> Date

    nonisolated let capabilities =
        CodexGhostRepairSnapshotQuarantinePublisherCapabilities()

    private let source: CodexGhostRepairSnapshotCanonicalSource
    private let destination: CodexGhostRepairSnapshotPreparedDestination
    private let journal: CodexGhostRepairSnapshotAcquisitionJournal
    private let inventory: CodexGhostRepairSnapshotPublishedInventoryCollector
    private let recoveryReader: CodexGhostRepairSnapshotRecoveryReader
    private let gateSource: any CodexGhostRepairExecutionGateSource
    private let clock: Clock

    static func production() -> Self {
        production(
            gateSource: CodexGhostRepairUnavailableExecutionGateSource()
        )
    }

    static func productionOperationalGateCandidate(
        profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32
    ) -> Self {
        production(
            gateSource:
                CodexGhostRepairSnapshotOperationalGateSource.production(),
            profile: profile
        )
    }

    private static func production(
        gateSource: any CodexGhostRepairExecutionGateSource,
        profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32
    ) -> Self {
        let destination = CodexGhostRepairSnapshotPreparedDestination.production()
        let journal = CodexGhostRepairSnapshotAcquisitionJournal.production(
            destination: destination
        )
        return Self(
            source: .production(profile: profile),
            destination: destination,
            journal: journal,
            inventory: CodexGhostRepairSnapshotPublishedInventoryCollector(
                destination: destination,
                journal: journal
            ),
            gateSource: gateSource,
            clock: { Date() }
        )
    }

    func inspectAdmissionProfileBound(
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection,
        currentRequest: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        guard currentRequest == selection.request,
              source.profile == selection.sourceProfile else {
            return .unavailable(
                message: "Snapshot request and exact packaged profile no longer match. No snapshot was started."
            )
        }
        return await inspectAdmission(
            targetThreadIDs: currentRequest.targetThreadIDs
        )
    }

    init(
        source: CodexGhostRepairSnapshotCanonicalSource,
        destination: CodexGhostRepairSnapshotPreparedDestination,
        journal: CodexGhostRepairSnapshotAcquisitionJournal,
        inventory: CodexGhostRepairSnapshotPublishedInventoryCollector,
        gateSource: any CodexGhostRepairExecutionGateSource,
        clock: @escaping Clock = { Date() }
    ) {
        self.source = source
        self.destination = destination
        self.journal = journal
        self.inventory = inventory
        self.recoveryReader = CodexGhostRepairSnapshotRecoveryReader(
            destination: destination,
            journal: journal,
            publishedInventory: inventory
        )
        self.gateSource = gateSource
        self.clock = clock
    }

    /// Performs the same path-free retention and destination-capacity checks
    /// used before journal creation. This method is read-only: it creates no
    /// snapshot ID, journal, quarantine directory, or repair authority.
    func inspectAdmission(
        targetThreadIDs: [String]
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        do {
            try Self.validateTargetThreadIDs(targetThreadIDs)
            let gate = try await gateSource.ghostRepairExecutionGate()
            guard gate.isClear else {
                return .blocked(
                    evidence: nil,
                    message: "Snapshot operating conditions changed. Run one fresh Safety Review before continuing."
                )
            }

            let binding = try await destination.bindPrepared()
            let sourceEvidence = try source.fingerprint()
            try sourceEvidence.validateHash()
            let sourceBytes = try Self.sourceBytes(sourceEvidence)
            let prospectiveBytes = try Self.admissionBytes(sourceBytes)
            let now = try Self.milliseconds(clock())
            let retention = try await inventory.assess(
                binding: binding,
                prospectiveSnapshotBytes: prospectiveBytes,
                nowMilliseconds: now
            )
            let capacity = try await destination.capacityEvidence(
                for: binding,
                sourceBytes: sourceBytes
            )
            let evidence = Self.admissionEvidence(
                retention: retention,
                capacity: capacity
            )
            if let message = evidence.userFacingBlockReason {
                return .blocked(evidence: evidence, message: message)
            }
            return .allowed(evidence)
        } catch {
            return .unavailable(
                message: "Snapshot storage readiness could not be verified. No snapshot was started."
            )
        }
    }

    func acquire(
        snapshotID: UUID,
        targetThreadIDs: [String],
        afterCopyForTesting: (@Sendable () throws -> Void)? = nil,
        afterMoveForTesting: (@Sendable () throws -> Void)? = nil,
        afterReceiptForTesting: (@Sendable () throws -> Void)? = nil
    ) async throws -> CodexGhostRepairSnapshotPublishedAcquisition {
        try await acquire(
            snapshotID: snapshotID,
            targetThreadIDs: targetThreadIDs,
            prepublicationSchemaVerification: nil,
            afterCopyForTesting: afterCopyForTesting,
            afterMoveForTesting: afterMoveForTesting,
            afterReceiptForTesting: afterReceiptForTesting
        )
    }

    func acquireProfileBound(
        snapshotID: UUID,
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection,
        currentRequest: CodexGhostRepairSnapshotActionRequest,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory,
        afterCopyForTesting: (@Sendable () throws -> Void)? = nil
    ) async throws -> CodexGhostRepairSnapshotPublishedAcquisition {
        guard currentRequest == selection.request,
              source.profile == selection.sourceProfile else {
            throw CodexGhostRepairError.targetDrift(
                "Snapshot publisher and exact request profile do not match."
            )
        }
        return try await acquire(
            snapshotID: snapshotID,
            targetThreadIDs: currentRequest.targetThreadIDs,
            prepublicationSchemaVerification: { root, fingerprint, profile in
                try CodexGhostRepairSnapshotPrepublicationSchemaVerifier.verify(
                    quarantineRoot: root,
                    fingerprint: fingerprint,
                    profile: profile,
                    workspaceFactory: workspaceFactory
                )
            },
            afterCopyForTesting: afterCopyForTesting,
            afterMoveForTesting: nil,
            afterReceiptForTesting: nil
        )
    }

    private func acquire(
        snapshotID: UUID,
        targetThreadIDs: [String],
        prepublicationSchemaVerification: (@Sendable (
            URL,
            CodexGhostRepairSnapshotCanonicalFingerprint,
            CodexGhostRepairSnapshotSourceProfile
        ) throws -> Void)?,
        afterCopyForTesting: (@Sendable () throws -> Void)?,
        afterMoveForTesting: (@Sendable () throws -> Void)?,
        afterReceiptForTesting: (@Sendable () throws -> Void)?
    ) async throws -> CodexGhostRepairSnapshotPublishedAcquisition {
        try Self.validateTargetThreadIDs(targetThreadIDs)
        let firstGate = try await gateSource.ghostRepairExecutionGate()
        guard firstGate.isClear else {
            throw CodexGhostRepairError.executionGateBlocked
        }

        let binding = try await destination.bindPrepared()
        let location = try await destination.location(for: binding)
        try Self.requireAbsentPublication(
            snapshotID: snapshotID,
            location: location
        )
        let sourceBefore = try source.fingerprint()
        try sourceBefore.validateHash()
        let sourceBytes = try Self.sourceBytes(sourceBefore)
        let admissionBytes = try Self.admissionBytes(sourceBytes)
        let now = try Self.milliseconds(clock())
        let retentionBefore = try await inventory.assess(
            binding: binding,
            prospectiveSnapshotBytes: admissionBytes,
            nowMilliseconds: now
        )
        guard retentionBefore.verdict == .allowed else {
            throw CodexGhostRepairError.executionGateBlocked
        }
        let capacityBefore = try await destination.capacityEvidence(
            for: binding,
            sourceBytes: sourceBytes
        )
        guard capacityBefore.isSufficient else {
            throw CodexGhostRepairError.executionGateBlocked
        }

        let acquisition = try await journal.prepare(
            snapshotID: snapshotID,
            targetThreadIDs: targetThreadIDs,
            sourceFingerprint: sourceBefore,
            destinationBinding: binding
        )

        do {
            let freshGate = try await gateSource.ghostRepairExecutionGate()
            guard freshGate.isClear else {
                throw CodexGhostRepairError.executionGateBlocked
            }
            try await destination.validateFresh(binding)
            try Self.requireAbsentPublication(
                snapshotID: snapshotID,
                location: location
            )
            let freshSource = try source.fingerprint()
            guard freshSource == sourceBefore else {
                throw CodexGhostRepairError.targetDrift(
                    "Canonical snapshot source drifted before copy."
                )
            }
            let retentionFresh = try await inventory.assess(
                binding: binding,
                prospectiveSnapshotBytes: admissionBytes,
                nowMilliseconds: now
            )
            guard retentionFresh == retentionBefore,
                  retentionFresh.verdict == .allowed else {
                throw CodexGhostRepairError.targetDrift(
                    "Published retention evidence drifted before copy."
                )
            }
            let capacityFresh = try await destination.capacityEvidence(
                for: binding,
                sourceBytes: sourceBytes
            )
            guard capacityFresh.isSufficient,
                  capacityFresh.bindingHash == capacityBefore.bindingHash,
                  capacityFresh.requiredBytes == capacityBefore.requiredBytes,
                  capacityFresh.sourceBytes == capacityBefore.sourceBytes else {
                throw CodexGhostRepairError.executionGateBlocked
            }

            let quarantineRoot = location.quarantineRootURL.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(snapshotID),
                isDirectory: true
            )
            let publishedRoot = location.snapshotsRootURL.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(snapshotID),
                isDirectory: true
            )
            try Self.createExclusivePrivateDirectory(quarantineRoot)
            for (file, evidence) in zip(
                source.profile.files,
                sourceBefore.files
            ) where evidence.exists {
                try Self.copy(
                    source: source,
                    file: file,
                    expected: evidence,
                    to: quarantineRoot.appendingPathComponent(evidence.fileName)
                )
            }
            try afterCopyForTesting?()

            let sourceAfter = try source.fingerprint()
            guard sourceAfter == sourceBefore else {
                throw CodexGhostRepairError.targetDrift(
                    "Canonical snapshot source drifted during copy."
                )
            }
            let postCopyGate = try await gateSource.ghostRepairExecutionGate()
            guard postCopyGate.isClear else {
                throw CodexGhostRepairError.executionGateBlocked
            }
            try await destination.validateFresh(binding)
            try Self.validateQuarantine(
                root: quarantineRoot,
                fingerprint: sourceBefore
            )
            try prepublicationSchemaVerification?(
                quarantineRoot,
                sourceBefore,
                source.profile
            )
            try Self.validateQuarantine(
                root: quarantineRoot,
                fingerprint: sourceBefore
            )

            let manifest = try CodexGhostRepairSnapshotPublishedManifest(
                snapshotID: snapshotID,
                sourceFingerprint: sourceBefore,
                destinationBinding: binding,
                acquiredAtMilliseconds: acquisition.preparedAtMilliseconds
            )
            try Self.writeDurableExclusive(
                try Self.encode(manifest),
                to: quarantineRoot.appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedFormat.manifestFileName
                )
            )
            try Self.validateManifestReadback(manifest, root: quarantineRoot)
            try Self.atomicPublish(
                quarantineRoot: quarantineRoot,
                publishedRoot: publishedRoot
            )
            try afterMoveForTesting?()

            let receipt = try CodexGhostRepairSnapshotPublicationReceipt(
                snapshotID: snapshotID,
                acquisitionRecordHash: acquisition.recordHash,
                manifestHash: manifest.manifestHash,
                destinationBindingHash: binding.bindingHash,
                publishedAtMilliseconds: try Self.milliseconds(clock())
            )
            try Self.writeDurableExclusive(
                try Self.encode(receipt),
                to: location.journalRootURL.appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedInventoryCollector
                        .publicationReceiptName(snapshotID)
                )
            )
            try afterReceiptForTesting?()
            try Self.writeDurableExclusive(
                Data(CodexGhostRepairSnapshotPublishedFormat.markerContents.utf8),
                to: publishedRoot.appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedFormat.markerFileName
                )
            )

            let readback = try await inventory.inventory(binding: binding)
            guard let publishedEvidence = readback.snapshots.first(where: {
                $0.snapshotID == snapshotID
            }), readback.snapshots.filter({ $0.snapshotID == snapshotID }).count == 1,
                  publishedEvidence.manifestHash == manifest.manifestHash,
                  publishedEvidence.publicationReceiptHash == receipt.receiptHash else {
                throw CodexGhostRepairError.recoveryRequired
            }
            return CodexGhostRepairSnapshotPublishedAcquisition(
                snapshotID: snapshotID,
                acquisitionRecordHash: acquisition.recordHash,
                manifestHash: manifest.manifestHash,
                publicationReceiptHash: receipt.receiptHash,
                sourceFingerprintHash: sourceBefore.fingerprintHash,
                destinationBindingHash: binding.bindingHash,
                publishedEvidence: publishedEvidence
            )
        } catch let error as CodexGhostRepairError {
            throw error
        } catch {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                error.localizedDescription
            )
        }
    }

    func recoveryReadback(
        snapshotID: UUID,
        destinationBinding: CodexGhostRepairSnapshotPreparedDestinationBinding
    ) async throws -> CodexGhostRepairSnapshotPublicationRecoveryEvidence {
        try await recoveryReader.readback(
            snapshotID: snapshotID,
            destinationBinding: destinationBinding
        )
    }

    private static func validateTargetThreadIDs(_ ids: [String]) throws {
        guard (1...10).contains(ids.count),
              ids == ids.sorted(),
              Set(ids).count == ids.count,
              ids.allSatisfy({
                  !$0.isEmpty
                      && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
              }) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot publication requires exact sorted target IDs."
            )
        }
    }

    private static func sourceBytes(
        _ fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint
    ) throws -> UInt64 {
        var total: UInt64 = 0
        for file in fingerprint.files where file.exists {
            guard let size = file.size else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot source size evidence is incomplete."
                )
            }
            let (next, overflow) = total.addingReportingOverflow(size)
            guard !overflow else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot source byte count overflowed."
                )
            }
            total = next
        }
        return total
    }

    private static func admissionEvidence(
        retention: CodexGhostRepairSnapshotRetentionAssessment,
        capacity: CodexGhostRepairSnapshotDestinationCapacityEvidence
    ) -> CodexGhostRepairSnapshotAdmissionEvidence {
        var blockers: [CodexGhostRepairSnapshotAdmissionBlocker] = []
        if case let .blocked(retentionBlocks) = retention.verdict {
            for block in retentionBlocks {
                switch block {
                case .maximumSnapshotCountExceeded:
                    blockers.append(.maximumSnapshotCountExceeded)
                case .maximumTotalBytesExceeded:
                    blockers.append(.maximumTotalBytesExceeded)
                case .maximumPublishedAgeExceeded:
                    blockers.append(.maximumPublishedAgeExceeded)
                }
            }
        }
        if !capacity.isSufficient {
            blockers.append(.destinationCapacityInsufficient)
        }
        return CodexGhostRepairSnapshotAdmissionEvidence(
            publishedSnapshotCount: retention.inventory.snapshots.count,
            maximumSnapshotCount: retention.policy.maximumSnapshotCount,
            publishedBytes: retention.inventory.totalBytes,
            maximumTotalBytes: UInt64(retention.policy.maximumTotalBytes),
            prospectiveSnapshotBytes: retention.prospectiveSnapshotBytes,
            oldestPublishedAgeMilliseconds:
                retention.oldestPublishedAgeMilliseconds,
            maximumPublishedAgeMilliseconds:
                retention.policy.maximumAgeMilliseconds,
            destinationRequiredBytes: capacity.requiredBytes,
            destinationAvailableBytes: capacity.availableBytes,
            blockers: blockers
        )
    }

    private static func admissionBytes(_ sourceBytes: UInt64) throws -> UInt64 {
        let markerBytes = UInt64(
            CodexGhostRepairSnapshotPublishedFormat.markerContents.utf8.count
        )
        let (withManifest, firstOverflow) = sourceBytes.addingReportingOverflow(
            1_048_576
        )
        let (total, secondOverflow) = withManifest.addingReportingOverflow(
            markerBytes
        )
        guard !firstOverflow, !secondOverflow else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot retention reservation overflowed."
            )
        }
        return total
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value <= Double(Int64.max) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot publication timestamp is invalid."
            )
        }
        return Int64(value.rounded(.down))
    }

    private static func requireAbsentPublication(
        snapshotID: UUID,
        location: CodexGhostRepairSnapshotPreparedDestination.Location
    ) throws {
        let name = CodexGhostRepairSnapshotPublishedInventoryCollector
            .snapshotDirectoryName(snapshotID)
        let quarantine = location.quarantineRootURL.appendingPathComponent(name)
        let published = location.snapshotsRootURL.appendingPathComponent(name)
        let receipt = location.journalRootURL.appendingPathComponent(
            CodexGhostRepairSnapshotPublishedInventoryCollector
                .publicationReceiptName(snapshotID)
        )
        guard !exists(quarantine), !exists(published), !exists(receipt) else {
            throw CodexGhostRepairError.claimAlreadyExists
        }
    }

    private static func createExclusivePrivateDirectory(_ url: URL) throws {
        guard Darwin.mkdir(url.path, S_IRWXU) == 0 else {
            if errno == EEXIST { throw CodexGhostRepairError.claimAlreadyExists }
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Quarantine directory creation failed."
            )
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Quarantine directory readback failed."
            )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fchmod(descriptor, S_IRWXU) == 0,
              fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o700,
              fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Quarantine directory durability failed."
            )
        }
        try fsyncDirectory(url.deletingLastPathComponent())
    }

    private static func copy(
        source: CodexGhostRepairSnapshotCanonicalSource,
        file: CodexGhostRepairSnapshotCanonicalFile,
        expected: CodexGhostRepairSnapshotCanonicalFileEvidence,
        to destination: URL
    ) throws {
        let descriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Quarantine file creation failed."
            )
        }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Quarantine file permission readback failed."
            )
        }
        try source.streamRawRead(file, expected: expected) { data in
            try writeAll(data, descriptor: descriptor)
        }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Quarantine file durability failed."
            )
        }
    }

    private static func validateQuarantine(
        root: URL,
        fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint
    ) throws {
        let names = try partialNames(root)
        let expectedNames = fingerprint.files.filter { $0.exists }.map {
            $0.fileName
        }.sorted()
        guard names == expectedNames else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Quarantine membership readback mismatch."
            )
        }
        for file in fingerprint.files where file.exists {
            let url = root.appendingPathComponent(file.fileName)
            let readback = try privateFileHash(url)
            guard readback.size == file.size,
                  readback.sha256 == file.sha256 else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "Quarantine content readback mismatch."
                )
            }
        }
    }

    private static func validateManifestReadback(
        _ expected: CodexGhostRepairSnapshotPublishedManifest,
        root: URL
    ) throws {
        let data = try readPrivateFile(
            root.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedFormat.manifestFileName
            ),
            maximumBytes: 1_048_576
        )
        let observed = try JSONDecoder().decode(
            CodexGhostRepairSnapshotPublishedManifest.self,
            from: data
        )
        try observed.validateHash()
        guard observed == expected else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Published manifest durable readback mismatch."
            )
        }
    }

    private static func atomicPublish(
        quarantineRoot: URL,
        publishedRoot: URL
    ) throws {
        guard !exists(publishedRoot),
              Darwin.rename(quarantineRoot.path, publishedRoot.path) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Atomic snapshot publication move failed."
            )
        }
        try fsyncDirectory(quarantineRoot.deletingLastPathComponent())
        try fsyncDirectory(publishedRoot.deletingLastPathComponent())
    }

    private static func partialNames(_ root: URL) throws -> [String] {
        var status = stat()
        guard lstat(root.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o700 else {
            throw CodexGhostRepairError.recoveryRequired
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).sorted()
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

    private static func privateFileHash(_ url: URL) throws
        -> (size: UInt64, sha256: String)
    {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Quarantine readback open failed."
            )
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(),
              before.st_mode & 0o7777 == 0o600,
              before.st_size >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Quarantine readback metadata failed."
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw CodexGhostRepairError.snapshotAcquisitionFailed(
                    "Quarantine readback failed."
                )
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_mode == after.st_mode,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw CodexGhostRepairError.targetDrift(
                "Quarantine file drifted during readback."
            )
        }
        return (
            UInt64(after.st_size),
            "sha256:" + hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private static func writeDurableExclusive(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EEXIST { throw CodexGhostRepairError.claimAlreadyExists }
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Publication evidence creation failed."
            )
        }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Publication evidence permission failed."
            )
        }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Publication evidence durability failed."
            )
        }
        try fsyncDirectory(url.deletingLastPathComponent())
        let readback = try readPrivateFile(url, maximumBytes: UInt64(data.count))
        guard readback == data else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Publication evidence durable readback mismatch."
            )
        }
    }

    private static func readPrivateFile(
        _ url: URL,
        maximumBytes: UInt64
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Private publication evidence is unavailable."
            )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o600,
              status.st_size >= 0,
              UInt64(status.st_size) <= maximumBytes else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Private publication evidence is unsafe or unbounded."
            )
        }
        return FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).readDataToEndOfFile()
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw CodexGhostRepairError.snapshotAcquisitionFailed(
                        "Private snapshot write failed."
                    )
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
    }

    private static func fsyncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Snapshot parent directory is unavailable."
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Snapshot parent directory fsync failed."
            )
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func exists(_ url: URL) -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 { return true }
        return errno != ENOENT
    }
}
