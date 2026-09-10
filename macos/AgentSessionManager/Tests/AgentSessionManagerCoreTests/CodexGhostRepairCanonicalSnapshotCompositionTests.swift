#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairCanonicalSnapshotCompositionTests: XCTestCase {
    func testCanonicalSourcePublishesThroughExistingJournaledPipeline() async throws {
        let fixture = try makeFixture(label: #function, includeSidecars: true)
        let source = try makeSource(fixture)
        let sourceBefore = try source.fingerprint()
        let gates = E32SequencedGateSource(gates: [clearGate, clearGate])
        let acquirer = makeAcquirer(
            fixture: fixture,
            source: source,
            gates: gates
        )
        let snapshotID = UUID()

        let result = try await acquirer.acquire(snapshotID: snapshotID)

        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 2)
        XCTAssertEqual(result.manifest.files, sourceBefore)
        XCTAssertEqual(result.manifest.files.count, 12)
        XCTAssertTrue(result.manifest.files.allSatisfy(\.exists))
        XCTAssertEqual(
            result.manifest.sourceRootDigest,
            source.canonicalCodexHomeDigest
        )
        XCTAssertTrue(result.manifest.capacity.isSufficient)
        try result.manifest.validateHash()
        XCTAssertEqual(try source.fingerprint(), sourceBefore)

        for evidence in sourceBefore where evidence.exists {
            let sourceRead = try XCTUnwrap(
                source.rawRead(
                    try XCTUnwrap(
                        CodexGhostRepairCanonicalSourceFile(
                            rawValue: evidence.fileName
                        )
                    )
                )
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: result.bundle.rootURL.appendingPathComponent(
                        evidence.fileName
                    )
                ),
                sourceRead.bytes
            )
        }
        let journal = try await fixture.journal.readback(snapshotID: snapshotID)
        XCTAssertEqual(journal.durableRecord.status, .published)
        XCTAssertEqual(journal.observedStatus, .published)
        XCTAssertFalse(journal.recoveryMutationAuthority)
    }

    func testBlockedPreflightStopsBeforeFirstCanonicalSourceOpen() async throws {
        let fixture = try makeFixture(label: #function)
        let source = try makeSource(fixture)
        try setSourceFilePermissions(fixture, permissions: 0o000)
        let gates = E32SequencedGateSource(gates: [blockedGate])
        let acquirer = makeAcquirer(
            fixture: fixture,
            source: source,
            gates: gates
        )
        let snapshotID = UUID()

        let error = await E32XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(snapshotID: snapshotID)
        )

        XCTAssertEqual(error as? CodexGhostRepairError, .executionGateBlocked)
        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.quarantineRoot(
                    snapshotID: snapshotID
                ).path
            )
        )
        let journal = try await fixture.journal.readback(snapshotID: snapshotID)
        XCTAssertEqual(journal.durableRecord.status, .failedWithoutPartial)
        XCTAssertNil(journal.partial)
    }

    func testClearPreflightCompletesBeforeFirstCanonicalSourceOpen() async throws {
        let fixture = try makeFixture(label: #function)
        let source = try makeSource(fixture)
        try setSourceFilePermissions(fixture, permissions: 0o000)
        let gates = E32SequencedGateSource(
            gates: [clearGate, clearGate],
            beforeReturn: [{
                try Self.setSourceFilePermissions(fixture, permissions: 0o600)
            }, nil]
        )
        let acquirer = makeAcquirer(
            fixture: fixture,
            source: source,
            gates: gates
        )

        let result = try await acquirer.acquire(snapshotID: UUID())

        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 2)
        XCTAssertEqual(result.manifest.files.filter(\.exists).count, 3)
        XCTAssertTrue(result.manifest.preflightGate.isClear)
        XCTAssertTrue(result.manifest.postCopyGate.isClear)
    }

    func testCanonicalDriftAfterCopyStopsBeforeSecondGateAndPublication() async throws {
        let fixture = try makeFixture(label: #function)
        let source = try makeSource(fixture)
        let gates = E32SequencedGateSource(gates: [clearGate, clearGate])
        let acquirer = makeAcquirer(
            fixture: fixture,
            source: source,
            gates: gates
        )
        let snapshotID = UUID()

        let error = await E32XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(
                snapshotID: snapshotID,
                afterCopyForTesting: {
                    try Data("drifted after copy".utf8).write(
                        to: fixture.configuration.desktopDatabaseURL,
                        options: .atomic
                    )
                    guard chmod(
                        fixture.configuration.desktopDatabaseURL.path,
                        0o600
                    ) == 0 else {
                        throw E32TestError.chmodFailed
                    }
                }
            )
        )

        guard case .targetDrift = error as? CodexGhostRepairError else {
            return XCTFail("Expected targetDrift, found \(String(describing: error))")
        }
        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.publishedRoot(
                    snapshotID: snapshotID
                ).path
            )
        )
        let partial = try XCTUnwrap(
            fixture.destination.partialRecord(snapshotID: snapshotID)
        )
        XCTAssertEqual(partial.status, .unpublishedPartial)
        XCTAssertFalse(partial.markerPresent)
        let journal = try await fixture.journal.readback(snapshotID: snapshotID)
        XCTAssertEqual(journal.observedStatus, .unpublishedPartial)
        XCTAssertFalse(journal.recoveryMutationAuthority)
    }

    func testCanonicalSourceAndDestinationOverlapFailsBeforeJournalOrGate() async throws {
        let fixture = try makeFixture(label: #function)
        let source = try makeSource(fixture)
        let overlappingApplicationSupport = fixture.codexHome.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: overlappingApplicationSupport,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let overlappingDestination = try CodexGhostRepairDisposableSnapshotDestination(
            applicationSupportDirectoryURL: overlappingApplicationSupport,
            allowedParentURL: fixture.parent,
            fixedCapacityHeadroomBytes: 0
        )
        let overlappingJournal = CodexGhostRepairSnapshotJournal(
            destination: overlappingDestination
        )
        let gates = E32SequencedGateSource(gates: [clearGate])
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            canonicalSource: source,
            destination: overlappingDestination,
            gateSource: gates,
            journal: overlappingJournal,
            capacityProbe: E32CapacityProbe(availableBytes: .max)
        )

        let error = await E32XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(snapshotID: UUID())
        )

        guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
            return XCTFail(
                "Expected invalidProtectionEvidence, found \(String(describing: error))"
            )
        }
        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: overlappingDestination.journalRootURL.path
            )
        )
    }

    func testCanonicalCompositionCannotReplayPublishedSnapshot() async throws {
        let fixture = try makeFixture(label: #function)
        let source = try makeSource(fixture)
        let gates = E32SequencedGateSource(gates: [clearGate, clearGate])
        let acquirer = makeAcquirer(
            fixture: fixture,
            source: source,
            gates: gates
        )
        let snapshotID = UUID()
        let first = try await acquirer.acquire(snapshotID: snapshotID)
        let firstManifest = try Data(contentsOf: first.manifestURL)

        let error = await E32XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(snapshotID: snapshotID)
        )

        XCTAssertEqual(error as? CodexGhostRepairError, .claimAlreadyExists)
        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 2)
        XCTAssertEqual(try Data(contentsOf: first.manifestURL), firstManifest)
    }

    private struct Fixture: @unchecked Sendable {
        let parent: URL
        let codexHome: URL
        let sqliteRoot: URL
        let configuration: CodexGhostRepairOperationalGateConfiguration
        let destination: CodexGhostRepairDisposableSnapshotDestination
        let journal: CodexGhostRepairSnapshotJournal
        let capacityProbe: E32CapacityProbe
    }

    private var clearGate: CodexGhostRepairExecutionGate {
        CodexGhostRepairExecutionGate(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: true
        )
    }

    private var blockedGate: CodexGhostRepairExecutionGate {
        CodexGhostRepairExecutionGate(
            codexFullyExited: false,
            desktopOpenHandleCount: 1,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: true
        )
    }

    private func makeFixture(
        label: String,
        includeSidecars: Bool = false
    ) throws -> Fixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e32-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let codexHome = parent.appendingPathComponent(".codex", isDirectory: true)
        let sqliteRoot = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sqliteRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(codexHome.path, 0o700) == 0,
              chmod(sqliteRoot.path, 0o700) == 0 else {
            throw E32TestError.chmodFailed
        }
        try Data(
            CodexGhostRepairCanonicalAcquisitionSource.testMirrorMarkerContents.utf8
        ).write(
            to: codexHome.appendingPathComponent(
                CodexGhostRepairCanonicalAcquisitionSource.testMirrorMarkerFileName
            )
        )
        let databaseContents = [
            "codex-dev.db": "E32 raw desktop bytes\n",
            "codex-thread-summaries-dev.db": "E32 raw summaries bytes\n",
            "codex-history-snapshots-dev.db": "E32 raw history bytes\n",
        ]
        for (name, contents) in databaseContents {
            let database = sqliteRoot.appendingPathComponent(name)
            try Data(contents.utf8).write(to: database)
            guard chmod(database.path, 0o600) == 0 else {
                throw E32TestError.chmodFailed
            }
            if includeSidecars {
                for suffix in ["-wal", "-shm", "-journal"] {
                    let sidecar = URL(fileURLWithPath: database.path + suffix)
                    try Data("\(name)\(suffix)".utf8).write(to: sidecar)
                    guard chmod(sidecar.path, 0o600) == 0 else {
                        throw E32TestError.chmodFailed
                    }
                }
            }
        }
        let applicationSupport = parent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = try CodexGhostRepairDisposableSnapshotDestination(
            applicationSupportDirectoryURL: applicationSupport,
            allowedParentURL: parent,
            fixedCapacityHeadroomBytes: 4_096
        )
        let configuration = CodexGhostRepairOperationalGateConfiguration(
            codexHomeURL: codexHome,
            backupVolumeProbeURL: applicationSupport,
            fixedCapacityHeadroomBytes: 4_096
        )
        let capacityProbe = E32CapacityProbe(availableBytes: .max)
        return Fixture(
            parent: parent,
            codexHome: codexHome,
            sqliteRoot: sqliteRoot,
            configuration: configuration,
            destination: destination,
            journal: CodexGhostRepairSnapshotJournal(destination: destination),
            capacityProbe: capacityProbe
        )
    }

    private func makeSource(
        _ fixture: Fixture
    ) throws -> CodexGhostRepairCanonicalAcquisitionSource {
        try CodexGhostRepairCanonicalAcquisitionSource(
            operationalGateConfiguration: fixture.configuration,
            testOwnedAllowedParentURL: fixture.parent
        )
    }

    private func makeAcquirer(
        fixture: Fixture,
        source: CodexGhostRepairCanonicalAcquisitionSource,
        gates: E32SequencedGateSource
    ) -> CodexGhostRepairDisposableSnapshotAcquirer {
        CodexGhostRepairDisposableSnapshotAcquirer(
            canonicalSource: source,
            destination: fixture.destination,
            gateSource: gates,
            journal: fixture.journal,
            capacityProbe: fixture.capacityProbe
        )
    }

    private static func setSourceFilePermissions(
        _ fixture: Fixture,
        permissions: mode_t
    ) throws {
        for file in CodexGhostRepairCanonicalSourceFile.allCases {
            let path = fixture.sqliteRoot.appendingPathComponent(file.rawValue).path
            if FileManager.default.fileExists(atPath: path),
               chmod(path, permissions) != 0 {
                throw E32TestError.chmodFailed
            }
        }
    }

    private func setSourceFilePermissions(
        _ fixture: Fixture,
        permissions: mode_t
    ) throws {
        try Self.setSourceFilePermissions(fixture, permissions: permissions)
    }
}

private actor E32SequencedGateSource: CodexGhostRepairExecutionGateSource {
    private let gates: [CodexGhostRepairExecutionGate]
    private let beforeReturn: [(@Sendable () throws -> Void)?]
    private var calls = 0

    init(
        gates: [CodexGhostRepairExecutionGate],
        beforeReturn: [(@Sendable () throws -> Void)?] = []
    ) {
        self.gates = gates
        self.beforeReturn = beforeReturn
    }

    func ghostRepairExecutionGate() async throws -> CodexGhostRepairExecutionGate {
        let index = calls
        calls += 1
        guard index < gates.count else { throw E32TestError.unexpectedGateCall }
        if index < beforeReturn.count {
            try beforeReturn[index]?()
        }
        return gates[index]
    }

    func callCount() -> Int { calls }
}

private actor E32CapacityProbe: CodexGhostRepairSnapshotCapacityProbing {
    private let availableBytes: UInt64

    init(availableBytes: UInt64) {
        self.availableBytes = availableBytes
    }

    func availableCapacity(at _: URL) async throws -> UInt64 {
        availableBytes
    }
}

private enum E32TestError: Error {
    case chmodFailed
    case unexpectedGateCall
}

private func E32XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Error? {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
#endif
