#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import CryptoKit
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairPublishedSnapshotRetentionTests: XCTestCase {
    func testEmptyFixedRootAllowsFirstProspectiveSnapshot() async throws {
        let fixture = try makeFixture(label: #function)
        let assessment = try await fixture.collector.assess(
            policy: try policy(count: 2, bytes: 10_000, age: 1_000),
            prospectiveSnapshotBytes: 100,
            nowMilliseconds: 1_000
        )

        XCTAssertEqual(assessment.inventory.snapshots, [])
        XCTAssertEqual(assessment.inventory.totalBytes, 0)
        XCTAssertEqual(assessment.verdict, .allowed)
        XCTAssertNil(assessment.oldestPublishedAgeMilliseconds)
        XCTAssertTrue(assessment.inventory.fixedSnapshotsRootOnly)
        XCTAssertEqual(assessment.inventory.rawDatabaseContentsOpened, 0)
        XCTAssertFalse(assessment.automaticDeletionAllowed)
        XCTAssertFalse(assessment.snapshotAcquisitionAuthority)
        XCTAssertFalse(assessment.recoveryMutationAuthority)
        XCTAssertFalse(assessment.repairMutationAuthority)
    }

    func testPublishedInventoryIsDeterministicAndMatchesManifestJournal() async throws {
        let fixture = try makeFixture(label: #function)
        let later = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!
        let earlier = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        try fixture.publish(snapshotID: later, publishedAt: 900, bytesPerDatabase: 13)
        try fixture.publish(snapshotID: earlier, publishedAt: 800, bytesPerDatabase: 11)

        let first = try await fixture.collector.inventory()
        let second = try await fixture.collector.inventory()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.snapshots.map(\.snapshotID), [earlier, later])
        XCTAssertEqual(first.snapshots.map(\.publishedAtMilliseconds), [800, 900])
        XCTAssertTrue(first.snapshots.allSatisfy { !$0.rawDatabaseContentVerified })
        XCTAssertEqual(
            first.totalBytes,
            first.snapshots.reduce(0) { $0 + $1.actualBytes }
        )
        XCTAssertTrue(first.snapshots.allSatisfy { $0.regularFileCount == 5 })
    }

    func testCountQuotaBlocksWithoutChangingPublishedFiles() async throws {
        let fixture = try makeFixture(label: #function)
        try fixture.publish(snapshotID: UUID(), publishedAt: 900, bytesPerDatabase: 8)
        let before = try treeFingerprint(fixture.prepared.destination.storageRootURL)

        let assessment = try await fixture.collector.assess(
            policy: try policy(count: 1, bytes: .max, age: 1_000),
            prospectiveSnapshotBytes: 1,
            nowMilliseconds: 1_000
        )

        XCTAssertEqual(
            assessment.verdict,
            .blocked([.maximumSnapshotCountExceeded])
        )
        XCTAssertEqual(
            try treeFingerprint(fixture.prepared.destination.storageRootURL),
            before
        )
        XCTAssertFalse(assessment.automaticDeletionAllowed)
    }

    func testByteQuotaBlocksWithoutSilentCleanup() async throws {
        let fixture = try makeFixture(label: #function)
        try fixture.publish(snapshotID: UUID(), publishedAt: 900, bytesPerDatabase: 8)
        let inventory = try await fixture.collector.inventory()
        let before = try treeFingerprint(fixture.prepared.destination.storageRootURL)

        let assessment = try await fixture.collector.assess(
            policy: try policy(
                count: 10,
                bytes: inventory.totalBytes,
                age: 1_000
            ),
            prospectiveSnapshotBytes: 1,
            nowMilliseconds: 1_000
        )

        XCTAssertEqual(
            assessment.verdict,
            .blocked([.maximumTotalBytesExceeded])
        )
        XCTAssertEqual(
            try treeFingerprint(fixture.prepared.destination.storageRootURL),
            before
        )
    }

    func testAgeQuotaBlocksAndReportsOldestPublishedAge() async throws {
        let fixture = try makeFixture(label: #function)
        try fixture.publish(snapshotID: UUID(), publishedAt: 500, bytesPerDatabase: 8)

        let assessment = try await fixture.collector.assess(
            policy: try policy(count: 10, bytes: .max, age: 499),
            prospectiveSnapshotBytes: 1,
            nowMilliseconds: 1_000
        )

        XCTAssertEqual(assessment.oldestPublishedAgeMilliseconds, 500)
        XCTAssertEqual(
            assessment.verdict,
            .blocked([.maximumPublishedAgeExceeded])
        )
    }

    func testNonCanonicalSnapshotEntryFailsClosed() async throws {
        let fixture = try makeFixture(label: #function)
        let unsupported = fixture.prepared.destination.snapshotsRootURL
            .appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unsupported,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(unsupported.path, 0o700), 0)

        let error = await XCTAssertThrowsErrorAsync(
            try await fixture.collector.inventory()
        )

        guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
            return XCTFail("Expected invalidProtectionEvidence, found \(String(describing: error))")
        }
    }

    func testPublishedDirectoryWithoutMatchingJournalFailsClosed() async throws {
        let fixture = try makeFixture(label: #function)
        let snapshotID = UUID()
        try fixture.publish(snapshotID: snapshotID, publishedAt: 900, bytesPerDatabase: 8)
        let record = fixture.journalRecordURL(snapshotID)
        try FileManager.default.moveItem(
            at: record,
            to: record.deletingLastPathComponent().appendingPathComponent("detached-record")
        )

        let error = await XCTAssertThrowsErrorAsync(
            try await fixture.collector.inventory()
        )

        guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
            return XCTFail("Expected invalidProtectionEvidence, found \(String(describing: error))")
        }
    }

    func testPublishedJournalWithoutDirectoryFailsClosed() async throws {
        let fixture = try makeFixture(label: #function)
        try fixture.writePublishedJournalOnly(snapshotID: UUID(), publishedAt: 900)

        let error = await XCTAssertThrowsErrorAsync(
            try await fixture.collector.inventory()
        )

        guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
            return XCTFail("Expected invalidProtectionEvidence, found \(String(describing: error))")
        }
    }

    func testPrivateFileMetadataDriftFailsClosed() async throws {
        let fixture = try makeFixture(label: #function)
        let snapshotID = UUID()
        try fixture.publish(snapshotID: snapshotID, publishedAt: 900, bytesPerDatabase: 8)
        let database = fixture.prepared.destination.publishedRoot(snapshotID: snapshotID)
            .appendingPathComponent("codex-dev.db")
        XCTAssertEqual(chmod(database.path, 0o644), 0)

        let error = await XCTAssertThrowsErrorAsync(
            try await fixture.collector.inventory()
        )

        guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
            return XCTFail("Expected invalidProtectionEvidence, found \(String(describing: error))")
        }
    }

    func testRawDatabaseContentIsNotUsedAsRetentionIntegrityAuthority() async throws {
        let fixture = try makeFixture(label: #function)
        let snapshotID = UUID()
        try fixture.publish(snapshotID: snapshotID, publishedAt: 900, bytesPerDatabase: 8)
        let first = try await fixture.collector.inventory()
        let database = fixture.prepared.destination.publishedRoot(snapshotID: snapshotID)
            .appendingPathComponent("codex-dev.db")
        let original = try attributes(database)
        try Data(repeating: 0x58, count: 8).write(to: database)
        XCTAssertEqual(chmod(database.path, 0o600), 0)
        var times = [
            timespec(tv_sec: original.accessSeconds, tv_nsec: original.accessNanoseconds),
            timespec(
                tv_sec: original.modificationSeconds,
                tv_nsec: original.modificationNanoseconds
            ),
        ]
        XCTAssertEqual(utimensat(AT_FDCWD, database.path, &times, 0), 0)

        let second = try await fixture.collector.inventory()

        XCTAssertEqual(second, first)
        XCTAssertEqual(second.rawDatabaseContentsOpened, 0)
        XCTAssertFalse(try XCTUnwrap(second.snapshots.first).rawDatabaseContentVerified)
    }

    func testPreparedDestinationDriftStopsInventory() async throws {
        let fixture = try makeFixture(label: #function)
        XCTAssertEqual(
            chmod(fixture.prepared.destination.snapshotsRootURL.path, 0o755),
            0
        )

        let error = await XCTAssertThrowsErrorAsync(
            try await fixture.collector.inventory()
        )

        guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
            return XCTFail("Expected invalidProtectionEvidence, found \(String(describing: error))")
        }
    }

    func testPolicyRejectsUnboundedZeroLimits() throws {
        XCTAssertThrowsError(
            try CodexGhostRepairPublishedSnapshotRetentionPolicy(
                maximumSnapshotCount: 0,
                maximumTotalBytes: 1,
                maximumAgeMilliseconds: 1
            )
        )
        XCTAssertThrowsError(
            try CodexGhostRepairPublishedSnapshotRetentionPolicy(
                maximumSnapshotCount: 1,
                maximumTotalBytes: 0,
                maximumAgeMilliseconds: 1
            )
        )
        XCTAssertThrowsError(
            try CodexGhostRepairPublishedSnapshotRetentionPolicy(
                maximumSnapshotCount: 1,
                maximumTotalBytes: 1,
                maximumAgeMilliseconds: 0
            )
        )
    }

    private struct Fixture: @unchecked Sendable {
        let parent: URL
        let prepared: CodexGhostRepairPreparedSnapshotDestination
        let collector: CodexGhostRepairPublishedSnapshotRetentionCollector

        func publish(
            snapshotID: UUID,
            publishedAt: Int64,
            bytesPerDatabase: Int
        ) throws {
            let root = prepared.destination.publishedRoot(snapshotID: snapshotID)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(root.path, 0o700) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }

            var files: [CodexGhostRepairSnapshotFileEvidence] = []
            for (index, sourceFile) in CodexGhostRepairCanonicalSourceFile.allCases
                .enumerated()
            {
                let exists = sourceFile.isRequiredDatabase
                if exists {
                    let data = Data(
                        repeating: UInt8((index + 1) & 0xff),
                        count: bytesPerDatabase
                    )
                    let url = root.appendingPathComponent(sourceFile.rawValue)
                    try data.write(to: url, options: .withoutOverwriting)
                    guard chmod(url.path, 0o600) == 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                files.append(
                    CodexGhostRepairSnapshotFileEvidence(
                        fileName: sourceFile.rawValue,
                        exists: exists,
                        device: exists ? 1 : nil,
                        inode: exists ? UInt64(index + 1) : nil,
                        mode: exists ? UInt32(S_IFREG | 0o600) : nil,
                        size: exists ? UInt64(bytesPerDatabase) : nil,
                        modificationSeconds: exists ? 1 : nil,
                        modificationNanoseconds: exists ? 0 : nil,
                        sha256: exists ? "sha256:test-\(index)" : nil
                    )
                )
            }
            let gate = CodexGhostRepairExecutionGate(
                codexFullyExited: true,
                desktopOpenHandleCount: 0,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                capacitySufficient: true
            )
            let sourceRootDigest = try CodexGhostRepairHasher.hash(
                "source-\(snapshotID.uuidString.lowercased())"
            )
            let manifest = try CodexGhostRepairSnapshotAcquisitionManifest(
                snapshotID: snapshotID,
                sourceRootDigest: sourceRootDigest,
                sourceFingerprintHash: try CodexGhostRepairHasher.hash(files),
                files: files,
                capacity: CodexGhostRepairSnapshotCapacityEvidence(
                    sourceBytes: UInt64(bytesPerDatabase * 3),
                    reservedCopyCount: 2,
                    fixedHeadroomBytes: 0,
                    requiredBytes: UInt64(bytesPerDatabase * 6),
                    availableBytes: .max,
                    destinationVolumeDigest: try CodexGhostRepairHasher.hash(
                        prepared.destination.applicationSupportDirectoryURL.path
                    )
                ),
                preflightGate: gate,
                postCopyGate: gate
            )
            try E39WriteJSON(
                manifest,
                to: root.appendingPathComponent(
                    CodexGhostRepairDisposableSnapshotAcquirer.manifestFileName
                )
            )
            try E39WritePrivate(
                Data(CodexGhostRepairDisposableBundle.markerContents.utf8),
                to: root.appendingPathComponent(
                    CodexGhostRepairDisposableBundle.markerFileName
                )
            )
            let record = try CodexGhostRepairSnapshotJournalRecord(
                snapshotID: snapshotID,
                status: .published,
                sourceRootDigest: sourceRootDigest,
                observedRootDigest: try CodexGhostRepairHasher.hash(root.path),
                manifestHash: manifest.manifestHash,
                failureDigest: nil,
                updatedAtMilliseconds: publishedAt
            )
            try E39WriteJSON(record, to: journalRecordURL(snapshotID))
        }

        func writePublishedJournalOnly(snapshotID: UUID, publishedAt: Int64) throws {
            let record = try CodexGhostRepairSnapshotJournalRecord(
                snapshotID: snapshotID,
                status: .published,
                sourceRootDigest: "sha256:source",
                observedRootDigest: "sha256:missing",
                manifestHash: "sha256:missing",
                failureDigest: nil,
                updatedAtMilliseconds: publishedAt
            )
            try E39WriteJSON(record, to: journalRecordURL(snapshotID))
        }

        func journalRecordURL(_ snapshotID: UUID) -> URL {
            prepared.destination.journalRootURL.appendingPathComponent(
                CodexGhostRepairSnapshotJournal.recordPrefix
                    + snapshotID.uuidString.lowercased()
                    + CodexGhostRepairSnapshotJournal.recordSuffix
            )
        }
    }

    private func makeFixture(label: String) throws -> Fixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e39-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        let marker = parent.appendingPathComponent(
            CodexGhostRepairDestinationPreparer.testRootMarkerFileName
        )
        try writePrivate(
            Data(CodexGhostRepairDestinationPreparer.testRootMarkerContents.utf8),
            to: marker
        )
        let applicationSupport = parent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(applicationSupport.path, 0o700), 0)
        let location = try StateStoreLocation.ghostRepairDestinationLocation(
            applicationSupportDirectory: applicationSupport
        )
        let preparer = try CodexGhostRepairDestinationPreparer(
            location: location,
            testOwnedAllowedParentURL: parent
        )
        let report = try preparer.prepare()
        let prepared = try preparer.preparedSnapshotDestination(
            expectedReport: report,
            fixedCapacityHeadroomBytes: 0
        )
        return Fixture(
            parent: parent,
            prepared: prepared,
            collector: CodexGhostRepairPublishedSnapshotRetentionCollector(
                preparedDestination: prepared
            )
        )
    }

    private func policy(count: Int, bytes: UInt64, age: Int64) throws
        -> CodexGhostRepairPublishedSnapshotRetentionPolicy
    {
        try CodexGhostRepairPublishedSnapshotRetentionPolicy(
            maximumSnapshotCount: count,
            maximumTotalBytes: bytes,
            maximumAgeMilliseconds: age
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writePrivate(try encoder.encode(value), to: url)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        guard chmod(url.path, 0o600) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func treeFingerprint(_ root: URL) throws -> String {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        )
        var lines: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            var line = url.path.replacingOccurrences(of: root.path, with: "")
            line += "|d=\(values.isDirectory == true)"
            line += "|f=\(values.isRegularFile == true)"
            line += "|l=\(values.isSymbolicLink == true)"
            line += "|s=\(values.fileSize ?? -1)"
            if values.isRegularFile == true {
                line += "|h=\(SHA256.hash(data: try Data(contentsOf: url)))"
            }
            lines.append(line)
        }
        return lines.sorted().joined(separator: "\n")
    }

    private func attributes(_ url: URL) throws -> (
        accessSeconds: Int,
        accessNanoseconds: Int,
        modificationSeconds: Int,
        modificationNanoseconds: Int
    ) {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return (
            Int(status.st_atimespec.tv_sec),
            Int(status.st_atimespec.tv_nsec),
            Int(status.st_mtimespec.tv_sec),
            Int(status.st_mtimespec.tv_nsec)
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T
) async -> Error? {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.")
        return nil
    } catch {
        return error
    }
}

private func E39WriteJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try E39WritePrivate(try encoder.encode(value), to: url)
}

private func E39WritePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
    guard chmod(url.path, 0o600) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}
#endif
