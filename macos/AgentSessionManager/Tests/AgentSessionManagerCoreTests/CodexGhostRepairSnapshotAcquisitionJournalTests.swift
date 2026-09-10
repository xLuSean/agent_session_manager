@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairSnapshotAcquisitionJournalTests: XCTestCase {
    func testProductionConstructionIsPathFreeAndJournalOnly() {
        let journal = CodexGhostRepairSnapshotAcquisitionJournal.production()

        XCTAssertTrue(journal.capabilities.writesAppOwnedJournal)
        XCTAssertFalse(journal.capabilities.acceptsCallerPath)
        XCTAssertFalse(journal.capabilities.copiesDatabaseFiles)
        XCTAssertFalse(journal.capabilities.publishesSnapshots)
        XCTAssertFalse(journal.capabilities.retriesAcquisition)
        XCTAssertFalse(journal.capabilities.cleanupAuthority)
        XCTAssertFalse(journal.capabilities.repairMutationAuthority)
    }

    func testPrepareWritesExclusive0600RecordAndReadsBackExactly() async throws {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()

        let record = try await fixture.journal.prepare(
            snapshotID: snapshotID,
            targetThreadIDs: ["thread-a", "thread-b"],
            sourceFingerprint: fixture.sourceFingerprint,
            destinationBinding: fixture.destinationBinding
        )

        try record.validateHash()
        XCTAssertEqual(record.status, .prepared)
        XCTAssertEqual(record.targetThreadIDs, ["thread-a", "thread-b"])
        XCTAssertEqual(record.preparedAtMilliseconds, 1_750_000_000_123)
        XCTAssertFalse(record.recoveryMutationAuthority)
        XCTAssertFalse(record.retryAllowed)
        let url = fixture.journalURL(snapshotID)
        var status = stat()
        XCTAssertEqual(lstat(url.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o7777, 0o600)
        let readback = try await fixture.journal.readback(
            snapshotID: snapshotID,
            destinationBinding: fixture.destinationBinding
        )
        XCTAssertEqual(readback, record)
    }

    func testSameSnapshotIDCannotReplayOrOverwriteRecord() async throws {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()
        let first = try await fixture.journal.prepare(
            snapshotID: snapshotID,
            targetThreadIDs: ["thread-a"],
            sourceFingerprint: fixture.sourceFingerprint,
            destinationBinding: fixture.destinationBinding
        )
        let bytesBefore = try Data(contentsOf: fixture.journalURL(snapshotID))

        await XCTAssertJournalThrows(
            try await fixture.journal.prepare(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-b"],
                sourceFingerprint: fixture.sourceFingerprint,
                destinationBinding: fixture.destinationBinding
            )
        ) { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .claimAlreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL(snapshotID)), bytesBefore)
        let readback = try await fixture.journal.readback(
            snapshotID: snapshotID,
            destinationBinding: fixture.destinationBinding
        )
        XCTAssertEqual(readback, first)
    }

    func testDestinationDriftStopsBeforeJournalEffect() async throws {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()
        XCTAssertEqual(chmod(fixture.quarantineURL.path, 0o755), 0)

        await XCTAssertJournalThrows(
            try await fixture.journal.prepare(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-a"],
                sourceFingerprint: fixture.sourceFingerprint,
                destinationBinding: fixture.destinationBinding
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.journalURL(snapshotID).path)
        )
    }

    func testInvalidSelectionStopsBeforeJournalEffect() async throws {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()

        await XCTAssertJournalThrows(
            try await fixture.journal.prepare(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-b", "thread-a"],
                sourceFingerprint: fixture.sourceFingerprint,
                destinationBinding: fixture.destinationBinding
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.journalURL(snapshotID).path)
        )
    }

    func testTamperedRecordIsRecoveryRequiredAndNeverRewritten() async throws {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()
        _ = try await fixture.journal.prepare(
            snapshotID: snapshotID,
            targetThreadIDs: ["thread-a"],
            sourceFingerprint: fixture.sourceFingerprint,
            destinationBinding: fixture.destinationBinding
        )
        let url = fixture.journalURL(snapshotID)
        try Data("tampered".utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        let bytesBefore = try Data(contentsOf: url)

        await XCTAssertJournalThrows(
            try await fixture.journal.readback(
                snapshotID: snapshotID,
                destinationBinding: fixture.destinationBinding
            )
        )
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
    }

    private struct Fixture {
        let journal: CodexGhostRepairSnapshotAcquisitionJournal
        let sourceFingerprint: CodexGhostRepairSnapshotCanonicalFingerprint
        let destinationBinding: CodexGhostRepairSnapshotPreparedDestinationBinding
        let journalRootURL: URL
        let quarantineURL: URL

        func journalURL(_ id: UUID) -> URL {
            journalRootURL.appendingPathComponent(
                "snapshot-\(id.uuidString.lowercased()).acquisition-v1.json"
            )
        }
    }

    private func makeFixture(label: String) async throws -> Fixture {
        let safe = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-m1b4-\(safe)-\(UUID().uuidString)",
            isDirectory: true
        )
        let codexHome = parent.appendingPathComponent(".codex", isDirectory: true)
        let sqlite = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        let appSupport = parent.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sqlite, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for url in [parent, codexHome, sqlite, appSupport] {
            XCTAssertEqual(chmod(url.path, 0o700), 0)
        }
        let sourceMarker = codexHome.appendingPathComponent(
            CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerFileName
        )
        try Data(
            CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerContents.utf8
        ).write(to: sourceMarker)
        XCTAssertEqual(chmod(sourceMarker.path, 0o600), 0)
        for file in CodexGhostRepairSnapshotCanonicalFile.allCases
            where file.isRequiredDatabase {
            let url = file.sourceURL(
                codexHomeURL: codexHome,
                sqliteRootURL: sqlite
            )
            try Data("M1b-4 \(file.rawValue)\n".utf8).write(to: url)
            XCTAssertEqual(chmod(url.path, 0o600), 0)
        }
        let destinationMarker = parent.appendingPathComponent(
            CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                .testRootMarkerFileName
        )
        try Data(
            CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                .testRootMarkerContents.utf8
        ).write(to: destinationMarker)
        XCTAssertEqual(chmod(destinationMarker.path, 0o600), 0)
        let entries = CodexGhostRepairDestinationCanaryFixedLayout.entries(
            applicationSupport: appSupport
        )
        for entry in entries {
            let mode: mode_t = entry.directory == .applicationBundleRoot ? 0o755 : 0o700
            try FileManager.default.createDirectory(
                at: entry.url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)]
            )
            XCTAssertEqual(chmod(entry.url.path, mode), 0)
        }
        let prepared = CodexGhostRepairSnapshotPreparedDestination(
            testOwnedApplicationSupportDirectory: appSupport,
            testOwnedAllowedParentURL: parent,
            capacityProbe: JournalCapacityProbe()
        )
        let binding = try await prepared.bindPrepared()
        let source = CodexGhostRepairSnapshotCanonicalSource(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: parent
        )
        let urls = Dictionary(uniqueKeysWithValues: entries.map { ($0.directory, $0.url) })
        return Fixture(
            journal: CodexGhostRepairSnapshotAcquisitionJournal(
                destination: prepared,
                clock: { Date(timeIntervalSince1970: 1_750_000_000.123) }
            ),
            sourceFingerprint: try source.fingerprint(),
            destinationBinding: binding,
            journalRootURL: try XCTUnwrap(urls[.journal]),
            quarantineURL: try XCTUnwrap(urls[.quarantine])
        )
    }
}

private struct JournalCapacityProbe:
    CodexGhostRepairSnapshotDestinationCapacityProbing
{
    func availableCapacity(at _: URL) async throws -> UInt64 { .max }
}

private func XCTAssertJournalThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw")
    } catch {
        handler(error)
    }
}
