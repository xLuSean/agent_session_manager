@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairSnapshotQuarantinePublisherTests: XCTestCase {
    func testProductionConstructionDisclosesEffectButDefaultGateBlocksLiveUse() {
        let publisher = CodexGhostRepairSnapshotQuarantinePublisher.production()

        XCTAssertTrue(publisher.capabilities.readsFixedRawDatabaseFiles)
        XCTAssertTrue(publisher.capabilities.writesAppOwnedQuarantineFiles)
        XCTAssertTrue(publisher.capabilities.publishesAppOwnedSnapshots)
        XCTAssertFalse(publisher.capabilities.writesCodexDatabaseFiles)
        XCTAssertFalse(publisher.capabilities.acceptsCallerPath)
        XCTAssertFalse(publisher.capabilities.retriesAcquisition)
        XCTAssertFalse(publisher.capabilities.automaticCleanupAuthority)
        XCTAssertFalse(publisher.capabilities.repairMutationAuthority)
    }

    func testClearGatesPublishMarkerLastAndColdReadbackRecognizesSnapshot()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()
        let sourceBefore = try fixture.source.fingerprint()

        let result = try await fixture.publisher.acquire(
            snapshotID: snapshotID,
            targetThreadIDs: ["thread-a", "thread-b"]
        )

        XCTAssertEqual(result.snapshotID, snapshotID)
        XCTAssertEqual(result.sourceFingerprintHash, sourceBefore.fingerprintHash)
        XCTAssertFalse(result.writesCodexDatabaseFiles)
        XCTAssertFalse(result.repairMutationAuthority)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.quarantineRoot(snapshotID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.markerURL(snapshotID).path
        ))
        XCTAssertEqual(try fixture.source.fingerprint(), sourceBefore)

        let freshPublisher = fixture.makePublisher()
        let recovery = try await freshPublisher.recoveryReadback(
            snapshotID: snapshotID,
            destinationBinding: fixture.binding
        )
        XCTAssertEqual(recovery.state, .published)
        XCTAssertTrue(recovery.manifestPresent)
        XCTAssertTrue(recovery.publicationReceiptPresent)
        XCTAssertTrue(recovery.markerPresent)
        XCTAssertFalse(recovery.retryAllowed)
        XCTAssertFalse(recovery.recoveryMutationAuthority)
        XCTAssertFalse(recovery.automaticCleanupAuthority)
    }

    func testColdReadbackAcceptsAllCanonicalMembersButRejectsUnknownMember()
        async throws
    {
        let fixture = try await makeFixture(
            label: #function,
            includeAllCanonicalMembers: true
        )
        let snapshotID = UUID()
        let sourceBefore = try fixture.source.fingerprint()
        _ = try await fixture.publisher.acquire(
            snapshotID: snapshotID,
            targetThreadIDs: ["thread-a"]
        )
        let publishedRoot = fixture.publishedRoot(snapshotID)
        let names = try FileManager.default.contentsOfDirectory(atPath: publishedRoot.path)
        XCTAssertEqual(names.count, CodexGhostRepairSnapshotCanonicalFile.allCases.count + 2)
        XCTAssertGreaterThan(names.count, 16)

        let freshPublisher = fixture.makePublisher()
        let recovery = try await freshPublisher.recoveryReadback(
            snapshotID: snapshotID,
            destinationBinding: fixture.binding
        )
        XCTAssertEqual(recovery.state, .published)
        XCTAssertFalse(recovery.retryAllowed)
        XCTAssertFalse(recovery.recoveryMutationAuthority)
        XCTAssertEqual(try fixture.source.fingerprint(), sourceBefore)

        try PublisherWritePrivate(Data("unexpected".utf8),
                                  to: publishedRoot.appendingPathComponent("unexpected-member"))
        await XCTAssertPublisherThrows(
            try await freshPublisher.recoveryReadback(
                snapshotID: snapshotID,
                destinationBinding: fixture.binding
            )
        ) { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .invalidProtectionEvidence(
                "Snapshot recovery inventory exceeds its fixed read bound."
            ))
        }
        XCTAssertEqual(try fixture.source.fingerprint(), sourceBefore)
    }

    func testV151ProfilePublishesAndColdReadbackPreservesExactIdentity()
        async throws
    {
        let fixture = try await makeFixture(
            label: #function,
            profile: .v151DesktopV33
        )
        let snapshotID = UUID()

        let result = try await fixture.publisher.acquire(
            snapshotID: snapshotID,
            targetThreadIDs: ["thread-a", "thread-b"]
        )
        let manifestData = try Data(contentsOf: fixture.publishedRoot(snapshotID)
            .appendingPathComponent(
                CodexGhostRepairSnapshotPublishedFormat.manifestFileName
            ))
        let manifest = try JSONDecoder().decode(
            CodexGhostRepairSnapshotPublishedManifest.self,
            from: manifestData
        )

        XCTAssertEqual(result.snapshotID, snapshotID)
        XCTAssertEqual(
            manifest.sourceLayoutIdentifier,
            CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v151SourceLayoutIdentifier
        )
        XCTAssertEqual(
            result.sourceFingerprintHash,
            try fixture.source.fingerprint().fingerprintHash
        )
        XCTAssertFalse(result.repairMutationAuthority)
    }

    func testBlockedPreflightDoesNotOpenSourceOrCreateJournal() async throws {
        let blockedGate = PublisherGateSource(gates: [.blocked])
        let fixture = try await makeFixture(
            label: #function,
            gate: blockedGate
        )
        let snapshotID = UUID()
        XCTAssertEqual(chmod(fixture.desktopDatabase.path, 0o000), 0)
        let before = try fixture.storageNames()

        await XCTAssertPublisherThrows(
            try await fixture.publisher.acquire(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-a"]
            )
        ) { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .executionGateBlocked)
        }

        XCTAssertEqual(try fixture.storageNames(), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.acquisitionURL(snapshotID).path
        ))
    }

    func testInsufficientCapacityStopsBeforeJournalAndQuarantine() async throws {
        let fixture = try await makeFixture(
            label: #function,
            capacity: 1
        )
        let snapshotID = UUID()
        let before = try fixture.storageNames()

        await XCTAssertPublisherThrows(
            try await fixture.publisher.acquire(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-a"]
            )
        ) { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .executionGateBlocked)
        }

        XCTAssertEqual(try fixture.storageNames(), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.acquisitionURL(snapshotID).path
        ))
    }

    func testSourceDriftAfterCopyLeavesReadbackOnlyQuarantinePartial()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()
        let desktop = fixture.desktopDatabase

        await XCTAssertPublisherThrows(
            try await fixture.publisher.acquire(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-a"],
                afterCopyForTesting: {
                    try Data("drifted source\n".utf8).write(to: desktop)
                    guard chmod(desktop.path, 0o600) == 0 else {
                        throw PublisherTestError.chmodFailed
                    }
                }
            )
        )

        let recovery = try await fixture.publisher.recoveryReadback(
            snapshotID: snapshotID,
            destinationBinding: fixture.binding
        )
        XCTAssertEqual(recovery.state, .unpublishedPartial)
        XCTAssertFalse(recovery.manifestPresent)
        XCTAssertFalse(recovery.publicationReceiptPresent)
        XCTAssertFalse(recovery.markerPresent)
        XCTAssertFalse(recovery.retryAllowed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.quarantineRoot(snapshotID).path
        ))

        await XCTAssertPublisherThrows(
            try await fixture.publisher.acquire(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-a"]
            )
        ) { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .claimAlreadyExists)
        }
    }

    func testPostCopyGateBlockLeavesPartialAndDoesNotPublish() async throws {
        let gate = PublisherGateSource(gates: [.clear, .clear, .blocked])
        let fixture = try await makeFixture(label: #function, gate: gate)
        let snapshotID = UUID()

        await XCTAssertPublisherThrows(
            try await fixture.publisher.acquire(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-a"]
            )
        ) { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .executionGateBlocked)
        }

        let recovery = try await fixture.publisher.recoveryReadback(
            snapshotID: snapshotID,
            destinationBinding: fixture.binding
        )
        XCTAssertEqual(recovery.state, .unpublishedPartial)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.publishedRoot(snapshotID).path
        ))
    }

    func testMoveInterruptionIsNotPublishedAndCannotReplay() async throws {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()

        await XCTAssertPublisherThrows(
            try await fixture.publisher.acquire(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-a"],
                afterMoveForTesting: { throw PublisherTestError.injectedFailure }
            )
        )

        let recovery = try await fixture.publisher.recoveryReadback(
            snapshotID: snapshotID,
            destinationBinding: fixture.binding
        )
        XCTAssertEqual(recovery.state, .publicationInterrupted)
        XCTAssertTrue(recovery.manifestPresent)
        XCTAssertFalse(recovery.publicationReceiptPresent)
        XCTAssertFalse(recovery.markerPresent)
        XCTAssertFalse(recovery.retryAllowed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.markerURL(snapshotID).path
        ))

        await XCTAssertPublisherThrows(
            try await fixture.publisher.acquire(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-a"]
            )
        ) { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .claimAlreadyExists)
        }
    }

    func testReceiptInterruptionStillRequiresMissingMarkerReadback() async throws {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()

        await XCTAssertPublisherThrows(
            try await fixture.publisher.acquire(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-a"],
                afterReceiptForTesting: { throw PublisherTestError.injectedFailure }
            )
        )

        let recovery = try await fixture.publisher.recoveryReadback(
            snapshotID: snapshotID,
            destinationBinding: fixture.binding
        )
        XCTAssertEqual(recovery.state, .publicationInterrupted)
        XCTAssertTrue(recovery.manifestPresent)
        XCTAssertTrue(recovery.publicationReceiptPresent)
        XCTAssertFalse(recovery.markerPresent)
        XCTAssertFalse(recovery.retryAllowed)
    }

    func testRetentionBlocksFourthSnapshotBeforeItsJournalClaim() async throws {
        let fixture = try await makeFixture(label: #function)
        for index in 0..<3 {
            _ = try await fixture.publisher.acquire(
                snapshotID: UUID(),
                targetThreadIDs: ["thread-\(index)"]
            )
        }
        let fourth = UUID()
        let before = try fixture.storageNames()

        await XCTAssertPublisherThrows(
            try await fixture.publisher.acquire(
                snapshotID: fourth,
                targetThreadIDs: ["thread-fourth"]
            )
        ) { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .executionGateBlocked)
        }

        XCTAssertEqual(try fixture.storageNames(), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.acquisitionURL(fourth).path
        ))
    }

    func testSuccessfulSnapshotCannotBeOverwrittenOrReplayed() async throws {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()
        let first = try await fixture.publisher.acquire(
            snapshotID: snapshotID,
            targetThreadIDs: ["thread-a"]
        )
        let before = try fixture.storageNames()

        await XCTAssertPublisherThrows(
            try await fixture.publisher.acquire(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-b"]
            )
        ) { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .claimAlreadyExists)
        }

        XCTAssertEqual(try fixture.storageNames(), before)
        let inventory = try await fixture.inventory.inventory(binding: fixture.binding)
        XCTAssertEqual(inventory.snapshots.first?.manifestHash, first.manifestHash)
    }

    private struct StorageNames: Equatable {
        let snapshots: [String]
        let quarantine: [String]
        let journal: [String]
    }

    private struct Fixture: @unchecked Sendable {
        let source: CodexGhostRepairSnapshotCanonicalSource
        let destination: CodexGhostRepairSnapshotPreparedDestination
        let journal: CodexGhostRepairSnapshotAcquisitionJournal
        let inventory: CodexGhostRepairSnapshotPublishedInventoryCollector
        let gate: PublisherGateSource
        let publisher: CodexGhostRepairSnapshotQuarantinePublisher
        let binding: CodexGhostRepairSnapshotPreparedDestinationBinding
        let desktopDatabase: URL
        let snapshotsRootURL: URL
        let quarantineRootURL: URL
        let journalRootURL: URL

        func makePublisher() -> CodexGhostRepairSnapshotQuarantinePublisher {
            CodexGhostRepairSnapshotQuarantinePublisher(
                source: source,
                destination: destination,
                journal: journal,
                inventory: inventory,
                gateSource: gate,
                clock: { Date(timeIntervalSince1970: 1) }
            )
        }

        func publishedRoot(_ id: UUID) -> URL {
            snapshotsRootURL.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(id),
                isDirectory: true
            )
        }

        func quarantineRoot(_ id: UUID) -> URL {
            quarantineRootURL.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(id),
                isDirectory: true
            )
        }

        func markerURL(_ id: UUID) -> URL {
            publishedRoot(id).appendingPathComponent(
                CodexGhostRepairSnapshotPublishedFormat.markerFileName
            )
        }

        func acquisitionURL(_ id: UUID) -> URL {
            journalRootURL.appendingPathComponent(
                CodexGhostRepairSnapshotAcquisitionJournal.recordPrefix
                    + id.uuidString.lowercased()
                    + CodexGhostRepairSnapshotAcquisitionJournal.recordSuffix
            )
        }

        func storageNames() throws -> StorageNames {
            StorageNames(
                snapshots: try FileManager.default.contentsOfDirectory(
                    atPath: snapshotsRootURL.path
                ).sorted(),
                quarantine: try FileManager.default.contentsOfDirectory(
                    atPath: quarantineRootURL.path
                ).sorted(),
                journal: try FileManager.default.contentsOfDirectory(
                    atPath: journalRootURL.path
                ).sorted()
            )
        }
    }

    private func makeFixture(
        label: String,
        gate: PublisherGateSource = PublisherGateSource(gates: [.clear]),
        capacity: UInt64 = .max,
        profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32,
        includeAllCanonicalMembers: Bool = false
    ) async throws -> Fixture {
        let safe = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-m1b6-\(safe)-\(UUID().uuidString)",
            isDirectory: true
        )
        let codexHome = parent.appendingPathComponent(".codex", isDirectory: true)
        let sqlite = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        let appSupport = parent.appendingPathComponent(
            "Application Support", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sqlite,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in [parent, codexHome, sqlite, appSupport] {
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
        }
        try PublisherWritePrivate(
            Data(
                CodexGhostRepairSnapshotCanonicalSource
                    .testMirrorMarkerContents.utf8
            ),
            to: codexHome.appendingPathComponent(
                CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerFileName
            )
        )
        for file in CodexGhostRepairSnapshotCanonicalFile.allCases
            where file.isRequiredDatabase || includeAllCanonicalMembers {
            try PublisherWritePrivate(
                Data("M1b-6 \(file.rawValue)\n".utf8),
                to: file.sourceURL(
                    codexHomeURL: codexHome,
                    sqliteRootURL: sqlite
                )
            )
        }
        try PublisherWritePrivate(
            Data(
                CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                    .testRootMarkerContents.utf8
            ),
            to: parent.appendingPathComponent(
                CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                    .testRootMarkerFileName
            )
        )
        let entries = CodexGhostRepairDestinationCanaryFixedLayout.entries(
            applicationSupport: appSupport
        )
        for entry in entries {
            let mode: mode_t = entry.directory == .applicationBundleRoot
                ? 0o755 : 0o700
            try FileManager.default.createDirectory(
                at: entry.url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)]
            )
            XCTAssertEqual(chmod(entry.url.path, mode), 0)
        }
        let urls = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.directory, $0.url) }
        )
        let source = CodexGhostRepairSnapshotCanonicalSource(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: parent,
            profile: profile
        )
        let destination = CodexGhostRepairSnapshotPreparedDestination(
            testOwnedApplicationSupportDirectory: appSupport,
            testOwnedAllowedParentURL: parent,
            capacityProbe: PublisherCapacityProbe(availableBytes: capacity)
        )
        let binding = try await destination.bindPrepared()
        let journal = CodexGhostRepairSnapshotAcquisitionJournal(
            destination: destination,
            clock: { Date(timeIntervalSince1970: 0.5) }
        )
        let inventory = CodexGhostRepairSnapshotPublishedInventoryCollector(
            destination: destination,
            journal: journal
        )
        let publisher = CodexGhostRepairSnapshotQuarantinePublisher(
            source: source,
            destination: destination,
            journal: journal,
            inventory: inventory,
            gateSource: gate,
            clock: { Date(timeIntervalSince1970: 1) }
        )
        return Fixture(
            source: source,
            destination: destination,
            journal: journal,
            inventory: inventory,
            gate: gate,
            publisher: publisher,
            binding: binding,
            desktopDatabase: sqlite.appendingPathComponent(
                CodexGhostRepairSnapshotCanonicalFile.desktop.rawValue
            ),
            snapshotsRootURL: try XCTUnwrap(urls[.snapshots]),
            quarantineRootURL: try XCTUnwrap(urls[.quarantine]),
            journalRootURL: try XCTUnwrap(urls[.journal])
        )
    }
}

private actor PublisherGateSource: CodexGhostRepairExecutionGateSource {
    enum Value { case clear, blocked }

    private var gates: [Value]
    private var index = 0

    init(gates: [Value]) {
        self.gates = gates
    }

    func ghostRepairExecutionGate() async throws -> CodexGhostRepairExecutionGate {
        let value = gates[min(index, gates.count - 1)]
        index += 1
        return CodexGhostRepairExecutionGate(
            codexFullyExited: value == .clear,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: value == .clear
        )
    }
}

private struct PublisherCapacityProbe:
    CodexGhostRepairSnapshotDestinationCapacityProbing
{
    let availableBytes: UInt64
    func availableCapacity(at _: URL) async throws -> UInt64 { availableBytes }
}

private enum PublisherTestError: Error {
    case chmodFailed
    case injectedFailure
}

private func PublisherWritePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
    guard chmod(url.path, 0o600) == 0 else {
        throw PublisherTestError.chmodFailed
    }
}

private func XCTAssertPublisherThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected snapshot publisher operation to throw")
    } catch {
        handler(error)
    }
}
