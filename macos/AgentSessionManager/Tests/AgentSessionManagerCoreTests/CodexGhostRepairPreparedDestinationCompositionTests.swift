#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairPreparedDestinationCompositionTests: XCTestCase {
    func testPreparedDestinationPublishesThroughManagerJournaledLayout() async throws {
        let fixture = try makeFixture(label: #function, includeSidecars: true)
        let prepared = try makePreparedDestination(fixture)
        let source = try makeSource(fixture)
        let gates = E35SequencedGateSource([clearGate, clearGate])
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            canonicalSource: source,
            preparedDestination: prepared,
            gateSource: gates,
            capacityProbe: E35CapacityProbe(availableBytes: .max)
        )
        let snapshotID = UUID()

        let acquisition = try await acquirer.acquire(snapshotID: snapshotID)

        XCTAssertTrue(
            acquisition.bundle.rootURL.path.hasPrefix(
                fixture.location.snapshotsRootURL.path + "/"
            )
        )
        XCTAssertEqual(acquisition.manifest.files.count, 12)
        XCTAssertTrue(acquisition.manifest.files.allSatisfy(\.exists))
        XCTAssertEqual(
            acquisition.manifest.sourceRootDigest,
            source.canonicalCodexHomeDigest
        )
        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 2)
        XCTAssertFalse(prepared.liveSourceAuthority)
        XCTAssertFalse(prepared.repairMutationAuthority)
        XCTAssertTrue(prepared.preparationBindingHash.hasPrefix("sha256:"))
        try prepared.validateFresh()

        let journal = CodexGhostRepairSnapshotJournal(
            preparedDestination: prepared
        )
        let readback = try await journal.readback(snapshotID: snapshotID)
        XCTAssertEqual(readback.durableRecord.status, .published)
        XCTAssertEqual(readback.observedStatus, .published)
        XCTAssertFalse(readback.recoveryMutationAuthority)
    }

    func testIncompleteOrDriftedPreparationCannotCreateTypedDestination() throws {
        let incomplete = try makeFixture(label: "\(#function)-incomplete")
        let incompletePreparer = try makePreparer(incomplete)
        let incompleteReport = try incompletePreparer.inspect()

        XCTAssertThrowsError(
            try incompletePreparer.preparedSnapshotDestination(
                expectedReport: incompleteReport,
                fixedCapacityHeadroomBytes: 0
            )
        )

        let drifted = try makeFixture(label: "\(#function)-drifted")
        let driftedPreparer = try makePreparer(drifted)
        let completed = try driftedPreparer.prepare()
        XCTAssertEqual(chmod(drifted.location.snapshotsRootURL.path, 0o755), 0)

        XCTAssertThrowsError(
            try driftedPreparer.preparedSnapshotDestination(
                expectedReport: completed,
                fixedCapacityHeadroomBytes: 0
            )
        )
    }

    func testMarkerDriftAfterAdapterStopsBeforeJournalAndGate() async throws {
        let fixture = try makeFixture(label: #function)
        let prepared = try makePreparedDestination(fixture)
        let gates = E35SequencedGateSource([clearGate, clearGate])
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            canonicalSource: try makeSource(fixture),
            preparedDestination: prepared,
            gateSource: gates,
            capacityProbe: E35CapacityProbe(availableBytes: .max)
        )
        try Data("drifted marker\n".utf8).write(to: fixture.destinationMarkerURL)

        let error = await E35XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(snapshotID: UUID())
        )

        guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
            return XCTFail("Expected invalidProtectionEvidence, found \(String(describing: error))")
        }
        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 0)
        let journal = CodexGhostRepairSnapshotJournal(
            preparedDestination: prepared
        )
        let records = try await journal.records()
        XCTAssertEqual(records, [])
    }

    func testExistingSafeBundleRootIsNotChmoddedByJournalBegin() async throws {
        let fixture = try makeFixture(label: #function, existingBundleMode: 0o755)
        let bundleBefore = try attributes(fixture.location.bundleSupportRootURL)
        let prepared = try makePreparedDestination(fixture)
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            canonicalSource: try makeSource(fixture),
            preparedDestination: prepared,
            gateSource: E35SequencedGateSource([clearGate, clearGate]),
            capacityProbe: E35CapacityProbe(availableBytes: .max)
        )

        _ = try await acquirer.acquire(snapshotID: UUID())
        let bundleAfter = try attributes(fixture.location.bundleSupportRootURL)

        XCTAssertEqual(bundleAfter.inode, bundleBefore.inode)
        XCTAssertEqual(bundleAfter.mode, 0o755)
        let privateModes = try [
            fixture.location.storageRootURL,
            fixture.location.snapshotsRootURL,
            fixture.location.quarantineRootURL,
            fixture.location.journalRootURL,
            fixture.location.trashJournalRootURL,
        ].map { try attributes($0).mode }
        XCTAssertTrue(privateModes.allSatisfy { $0 == 0o700 })
    }

    func testPreparedDestinationCannotReplayPublishedSnapshot() async throws {
        let fixture = try makeFixture(label: #function)
        let prepared = try makePreparedDestination(fixture)
        let gates = E35SequencedGateSource([clearGate, clearGate])
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            canonicalSource: try makeSource(fixture),
            preparedDestination: prepared,
            gateSource: gates,
            capacityProbe: E35CapacityProbe(availableBytes: .max)
        )
        let snapshotID = UUID()
        let first = try await acquirer.acquire(snapshotID: snapshotID)
        let manifestBefore = try Data(contentsOf: first.manifestURL)

        let error = await E35XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(snapshotID: snapshotID)
        )

        XCTAssertEqual(error as? CodexGhostRepairError, .claimAlreadyExists)
        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 2)
        XCTAssertEqual(try Data(contentsOf: first.manifestURL), manifestBefore)
    }

    func testOverlappingCanonicalSourceStopsBeforeJournalAndGate() async throws {
        let fixture = try makeFixture(
            label: #function,
            applicationSupportInsideCodexHome: true
        )
        let prepared = try makePreparedDestination(fixture)
        let gates = E35SequencedGateSource([clearGate])
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            canonicalSource: try makeSource(fixture),
            preparedDestination: prepared,
            gateSource: gates,
            capacityProbe: E35CapacityProbe(availableBytes: .max)
        )

        let error = await E35XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(snapshotID: UUID())
        )

        guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
            return XCTFail("Expected invalidProtectionEvidence, found \(String(describing: error))")
        }
        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 0)
        let journal = CodexGhostRepairSnapshotJournal(
            preparedDestination: prepared
        )
        let records = try await journal.records()
        XCTAssertEqual(records, [])
    }

    private struct Fixture: @unchecked Sendable {
        let parent: URL
        let codexHome: URL
        let configuration: CodexGhostRepairOperationalGateConfiguration
        let location: StateStoreLocation.GhostRepairDestinationLocation
        let destinationMarkerURL: URL
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

    private func makeFixture(
        label: String,
        includeSidecars: Bool = false,
        existingBundleMode: mode_t? = nil,
        applicationSupportInsideCodexHome: Bool = false
    ) throws -> Fixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e35-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(parent.path, 0o700), 0)

        let destinationMarkerURL = parent.appendingPathComponent(
            CodexGhostRepairDestinationPreparer.testRootMarkerFileName
        )
        try Data(
            CodexGhostRepairDestinationPreparer.testRootMarkerContents.utf8
        ).write(to: destinationMarkerURL)
        XCTAssertEqual(chmod(destinationMarkerURL.path, 0o600), 0)

        let codexHome = parent.appendingPathComponent(".codex", isDirectory: true)
        let sqliteRoot = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sqliteRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(codexHome.path, 0o700), 0)
        XCTAssertEqual(chmod(sqliteRoot.path, 0o700), 0)
        try Data(
            CodexGhostRepairCanonicalAcquisitionSource.testMirrorMarkerContents.utf8
        ).write(
            to: codexHome.appendingPathComponent(
                CodexGhostRepairCanonicalAcquisitionSource.testMirrorMarkerFileName
            )
        )
        for file in CodexGhostRepairCanonicalSourceFile.allCases {
            guard file.isRequiredDatabase || includeSidecars else { continue }
            let url = sqliteRoot.appendingPathComponent(file.rawValue)
            try Data("E35 \(file.rawValue)\n".utf8).write(to: url)
            XCTAssertEqual(chmod(url.path, 0o600), 0)
        }

        let applicationSupportParent = applicationSupportInsideCodexHome
            ? codexHome
            : parent
        let applicationSupport = applicationSupportParent.appendingPathComponent(
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
        if let existingBundleMode {
            try FileManager.default.createDirectory(
                at: location.bundleSupportRootURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: existingBundleMode)]
            )
            XCTAssertEqual(chmod(location.bundleSupportRootURL.path, existingBundleMode), 0)
        }
        return Fixture(
            parent: parent,
            codexHome: codexHome,
            configuration: CodexGhostRepairOperationalGateConfiguration(
                codexHomeURL: codexHome,
                backupVolumeProbeURL: applicationSupport,
                fixedCapacityHeadroomBytes: 4_096
            ),
            location: location,
            destinationMarkerURL: destinationMarkerURL
        )
    }

    private func makePreparer(
        _ fixture: Fixture
    ) throws -> CodexGhostRepairDestinationPreparer {
        try CodexGhostRepairDestinationPreparer(
            location: fixture.location,
            testOwnedAllowedParentURL: fixture.parent
        )
    }

    private func makePreparedDestination(
        _ fixture: Fixture
    ) throws -> CodexGhostRepairPreparedSnapshotDestination {
        let preparer = try makePreparer(fixture)
        let report = try preparer.prepare()
        return try preparer.preparedSnapshotDestination(
            expectedReport: report,
            fixedCapacityHeadroomBytes: 4_096
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

    private func attributes(_ url: URL) throws -> (inode: NSNumber, mode: Int) {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return (
            try XCTUnwrap(values[.systemFileNumber] as? NSNumber),
            try XCTUnwrap(values[.posixPermissions] as? NSNumber).intValue
        )
    }
}

private actor E35SequencedGateSource: CodexGhostRepairExecutionGateSource {
    private var gates: [CodexGhostRepairExecutionGate]
    private var calls = 0

    init(_ gates: [CodexGhostRepairExecutionGate]) {
        self.gates = gates
    }

    func ghostRepairExecutionGate() async throws -> CodexGhostRepairExecutionGate {
        guard calls < gates.count else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E35 gate sequence was exhausted."
            )
        }
        defer { calls += 1 }
        return gates[calls]
    }

    func callCount() -> Int { calls }
}

private struct E35CapacityProbe: CodexGhostRepairSnapshotCapacityProbing {
    let availableBytes: UInt64

    func availableCapacity(at _: URL) async throws -> UInt64 {
        availableBytes
    }
}

private func E35XCTAssertThrowsErrorAsync<T>(
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
#endif
