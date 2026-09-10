import Darwin
import Foundation

struct CodexGhostRepairSnapshotAcquisitionJournalCapabilities: Sendable {
    let writesAppOwnedJournal = true
    let acceptsCallerPath = false
    let copiesDatabaseFiles = false
    let publishesSnapshots = false
    let retriesAcquisition = false
    let cleanupAuthority = false
    let repairMutationAuthority = false
}

enum CodexGhostRepairSnapshotAcquisitionJournalStatus:
    String,
    Codable,
    Sendable
{
    case prepared
}

struct CodexGhostRepairSnapshotAcquisitionJournalRecord:
    Codable,
    Equatable,
    Sendable
{
    private struct Payload: Codable, Equatable {
        let snapshotID: UUID
        let status: CodexGhostRepairSnapshotAcquisitionJournalStatus
        let targetThreadIDs: [String]
        let sourceFingerprintHash: String
        let destinationBindingHash: String
        let preparedAtMilliseconds: Int64
    }

    let snapshotID: UUID
    let status: CodexGhostRepairSnapshotAcquisitionJournalStatus
    let targetThreadIDs: [String]
    let sourceFingerprintHash: String
    let destinationBindingHash: String
    let preparedAtMilliseconds: Int64
    let recordHash: String

    var recoveryMutationAuthority: Bool { false }
    var retryAllowed: Bool { false }
    var snapshotPublicationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }

    init(
        snapshotID: UUID,
        targetThreadIDs: [String],
        sourceFingerprintHash: String,
        destinationBindingHash: String,
        preparedAtMilliseconds: Int64
    ) throws {
        guard (1...10).contains(targetThreadIDs.count),
              targetThreadIDs == targetThreadIDs.sorted(),
              Set(targetThreadIDs).count == targetThreadIDs.count,
              targetThreadIDs.allSatisfy({
                  !$0.isEmpty
                      && $0 == $0.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      )
              }),
              Self.isSHA256(sourceFingerprintHash),
              Self.isSHA256(destinationBindingHash),
              preparedAtMilliseconds >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot journal requires exact frozen preparation evidence."
            )
        }
        let payload = Payload(
            snapshotID: snapshotID,
            status: .prepared,
            targetThreadIDs: targetThreadIDs,
            sourceFingerprintHash: sourceFingerprintHash,
            destinationBindingHash: destinationBindingHash,
            preparedAtMilliseconds: preparedAtMilliseconds
        )
        self.snapshotID = snapshotID
        status = .prepared
        self.targetThreadIDs = targetThreadIDs
        self.sourceFingerprintHash = sourceFingerprintHash
        self.destinationBindingHash = destinationBindingHash
        self.preparedAtMilliseconds = preparedAtMilliseconds
        recordHash = try CodexGhostRepairHasher.hash(payload)
    }

    func validateHash() throws {
        let expected = try CodexGhostRepairHasher.hash(Payload(
            snapshotID: snapshotID,
            status: status,
            targetThreadIDs: targetThreadIDs,
            sourceFingerprintHash: sourceFingerprintHash,
            destinationBindingHash: destinationBindingHash,
            preparedAtMilliseconds: preparedAtMilliseconds
        ))
        guard expected == recordHash else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot acquisition journal checksum mismatch."
            )
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

/// M1b-4 journal-first boundary. The only effect is one exclusive, durable,
/// app-owned preparation record. Recovery can read it but cannot copy, retry,
/// publish, clean up, or repair.
actor CodexGhostRepairSnapshotAcquisitionJournal {
    static let recordPrefix = "snapshot-"
    static let recordSuffix = ".acquisition-v1.json"
    static let maximumRecordBytes = 64 * 1_024

    typealias Clock = @Sendable () -> Date

    nonisolated let capabilities =
        CodexGhostRepairSnapshotAcquisitionJournalCapabilities()

    private let destination: CodexGhostRepairSnapshotPreparedDestination
    private let clock: Clock

    static func production(
        destination: CodexGhostRepairSnapshotPreparedDestination = .production(),
        clock: @escaping Clock = { Date() }
    ) -> Self {
        Self(destination: destination, clock: clock)
    }

    init(
        destination: CodexGhostRepairSnapshotPreparedDestination,
        clock: @escaping Clock = { Date() }
    ) {
        self.destination = destination
        self.clock = clock
    }

    func prepare(
        snapshotID: UUID,
        targetThreadIDs: [String],
        sourceFingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        destinationBinding: CodexGhostRepairSnapshotPreparedDestinationBinding
    ) async throws -> CodexGhostRepairSnapshotAcquisitionJournalRecord {
        try sourceFingerprint.validateHash()
        try destinationBinding.validateHash()
        let location = try await destination.location(for: destinationBinding)
        let milliseconds = try Self.milliseconds(clock())
        let record = try CodexGhostRepairSnapshotAcquisitionJournalRecord(
            snapshotID: snapshotID,
            targetThreadIDs: targetThreadIDs,
            sourceFingerprintHash: sourceFingerprint.fingerprintHash,
            destinationBindingHash: destinationBinding.bindingHash,
            preparedAtMilliseconds: milliseconds
        )
        try await destination.validateFresh(destinationBinding)
        try Self.writeExclusive(record, to: Self.recordURL(
            snapshotID: snapshotID,
            journalRootURL: location.journalRootURL
        ))
        let readback = try Self.read(
            snapshotID: snapshotID,
            journalRootURL: location.journalRootURL
        )
        guard readback == record else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Snapshot journal durable readback did not match."
            )
        }
        return readback
    }

    func readback(
        snapshotID: UUID,
        destinationBinding: CodexGhostRepairSnapshotPreparedDestinationBinding
    ) async throws -> CodexGhostRepairSnapshotAcquisitionJournalRecord {
        let location = try await destination.location(for: destinationBinding)
        return try Self.read(
            snapshotID: snapshotID,
            journalRootURL: location.journalRootURL
        )
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= 0,
              value <= Double(Int64.max) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot journal timestamp is invalid."
            )
        }
        return Int64(value.rounded(.down))
    }

    private static func recordURL(snapshotID: UUID, journalRootURL: URL) -> URL {
        journalRootURL.appendingPathComponent(
            recordPrefix + snapshotID.uuidString.lowercased() + recordSuffix,
            isDirectory: false
        )
    }

    private static func writeExclusive<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumRecordBytes else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot journal record exceeds its fixed bound."
            )
        }
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EEXIST { throw CodexGhostRepairError.claimAlreadyExists }
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Snapshot journal exclusive creation failed."
            )
        }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw CodexGhostRepairError.snapshotAcquisitionFailed(
                        "Snapshot journal durable write failed."
                    )
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Snapshot journal durability check failed."
            )
        }
        try fsyncDirectory(url.deletingLastPathComponent())
    }

    private static func read(
        snapshotID: UUID,
        journalRootURL: URL
    ) throws -> CodexGhostRepairSnapshotAcquisitionJournalRecord {
        let url = recordURL(snapshotID: snapshotID, journalRootURL: journalRootURL)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.recoveryRequired
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o600,
              status.st_size >= 0,
              status.st_size <= maximumRecordBytes else {
            throw CodexGhostRepairError.recoveryRequired
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = handle.readDataToEndOfFile()
        let record = try JSONDecoder().decode(
            CodexGhostRepairSnapshotAcquisitionJournalRecord.self,
            from: data
        )
        try record.validateHash()
        guard record.snapshotID == snapshotID else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return record
    }

    private static func fsyncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Snapshot journal directory is unavailable."
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.snapshotAcquisitionFailed(
                "Snapshot journal directory fsync failed."
            )
        }
    }
}
