@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairSnapshotPreparedDestinationTests: XCTestCase {
    func testProductionConstructionIsPathFreeAndZeroIO() {
        let destination =
            CodexGhostRepairSnapshotPreparedDestination.production()

        XCTAssertTrue(destination.capabilities.bindsFixedPreparedLayout)
        XCTAssertTrue(destination.capabilities.readsDirectoryMetadata)
        XCTAssertTrue(destination.capabilities.probesDestinationCapacity)
        XCTAssertFalse(destination.capabilities.acceptsCallerPath)
        XCTAssertFalse(destination.capabilities.createsDirectories)
        XCTAssertFalse(destination.capabilities.copiesDatabaseFiles)
        XCTAssertFalse(destination.capabilities.publishesSnapshots)
        XCTAssertFalse(destination.capabilities.cleanupAuthority)
        XCTAssertFalse(destination.capabilities.repairMutationAuthority)
    }

    func testReadyLayoutProducesPathRedactedBindingWithoutEffects() async throws {
        let fixture = try makeFixture(label: #function)
        let before = try directoryReadback(fixture)

        let binding = try await fixture.destination.bindPrepared()

        try binding.validateHash()
        XCTAssertTrue(binding.pathRedacted)
        XCTAssertTrue(binding.storageRootDigest.hasPrefix("sha256:"))
        XCTAssertTrue(binding.bindingHash.hasPrefix("sha256:"))
        XCTAssertEqual(binding.policy.maximumSnapshotCount, 3)
        XCTAssertEqual(binding.policy.maximumTotalBytes, 4_294_967_296)
        XCTAssertEqual(binding.policy.maximumAgeMilliseconds, 2_592_000_000)
        XCTAssertEqual(binding.directories.count, 6)
        XCTAssertTrue(binding.directories.allSatisfy { $0.status == .ready })
        XCTAssertFalse(binding.snapshotAcquisitionAuthority)
        XCTAssertFalse(binding.repairMutationAuthority)
        XCTAssertEqual(try directoryReadback(fixture), before)
    }

    func testMissingDirectoryCannotBindPreparedDestination() async throws {
        let fixture = try makeFixture(
            label: #function,
            omittedDirectory: .trash
        )

        await XCTAssertThrowsErrorAsync(
            try await fixture.destination.bindPrepared()
        ) { error in
            guard case .invalidProtectionEvidence =
                    error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testUnsafePrivateDirectoryCannotBindPreparedDestination() async throws {
        let fixture = try makeFixture(
            label: #function,
            unsafeDirectory: .snapshots
        )

        await XCTAssertThrowsErrorAsync(
            try await fixture.destination.bindPrepared()
        ) { error in
            guard case .invalidProtectionEvidence =
                    error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testBindingDriftFailsFreshValidation() async throws {
        let fixture = try makeFixture(label: #function)
        let binding = try await fixture.destination.bindPrepared()
        let quarantine = try XCTUnwrap(
            fixture.urls[.quarantine]
        )
        XCTAssertEqual(chmod(quarantine.path, 0o755), 0)

        await XCTAssertThrowsErrorAsync(
            try await fixture.destination.validateFresh(binding)
        ) { error in
            guard case .invalidProtectionEvidence =
                    error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testCapacityEvidenceUsesTwoCopiesAndFixedHeadroom() async throws {
        let probe = PreparedDestinationCapacityProbe(availableBytes: 80_000_000)
        let fixture = try makeFixture(label: #function, probe: probe)
        let binding = try await fixture.destination.bindPrepared()

        let evidence = try await fixture.destination.capacityEvidence(
            for: binding,
            sourceBytes: 5_000_000
        )

        XCTAssertEqual(evidence.bindingHash, binding.bindingHash)
        XCTAssertEqual(evidence.reservedCopyCount, 2)
        XCTAssertEqual(evidence.fixedHeadroomBytes, 67_108_864)
        XCTAssertEqual(evidence.requiredBytes, 77_108_864)
        XCTAssertEqual(evidence.availableBytes, 80_000_000)
        XCTAssertTrue(evidence.isSufficient)
        XCTAssertTrue(evidence.destinationVolumeDigest.hasPrefix("sha256:"))
        XCTAssertFalse(evidence.automaticDeletionAuthority)
        XCTAssertFalse(evidence.snapshotAcquisitionAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testInsufficientCapacityIsEvidenceAndDoesNotDelete() async throws {
        let probe = PreparedDestinationCapacityProbe(availableBytes: 1)
        let fixture = try makeFixture(label: #function, probe: probe)
        let before = try directoryReadback(fixture)
        let binding = try await fixture.destination.bindPrepared()

        let evidence = try await fixture.destination.capacityEvidence(
            for: binding,
            sourceBytes: 1_024
        )

        XCTAssertFalse(evidence.isSufficient)
        XCTAssertFalse(evidence.automaticDeletionAuthority)
        XCTAssertEqual(try directoryReadback(fixture), before)
    }

    func testCapacityArithmeticOverflowFailsBeforeProbe() async throws {
        let probe = PreparedDestinationCapacityProbe(availableBytes: .max)
        let fixture = try makeFixture(label: #function, probe: probe)
        let binding = try await fixture.destination.bindPrepared()

        await XCTAssertThrowsErrorAsync(
            try await fixture.destination.capacityEvidence(
                for: binding,
                sourceBytes: .max
            )
        ) { error in
            guard case .invalidProtectionEvidence =
                    error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 0)
    }

    private struct Fixture {
        let parent: URL
        let applicationSupport: URL
        let urls: [CodexGhostRepairDestinationCanaryDirectory: URL]
        let destination: CodexGhostRepairSnapshotPreparedDestination
    }

    private struct DirectoryReadback: Equatable {
        let directory: CodexGhostRepairDestinationCanaryDirectory
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
    }

    private func makeFixture(
        label: String,
        omittedDirectory: CodexGhostRepairDestinationCanaryDirectory? = nil,
        unsafeDirectory: CodexGhostRepairDestinationCanaryDirectory? = nil,
        probe: PreparedDestinationCapacityProbe =
            PreparedDestinationCapacityProbe(availableBytes: .max)
    ) throws -> Fixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-m1b3-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        let applicationSupport = parent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(parent.path, 0o700) == 0,
              chmod(applicationSupport.path, 0o700) == 0 else {
            throw PreparedDestinationTestError.chmodFailed
        }
        let marker = parent.appendingPathComponent(
            CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                .testRootMarkerFileName
        )
        try Data(
            CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                .testRootMarkerContents.utf8
        ).write(to: marker)
        guard chmod(marker.path, 0o600) == 0 else {
            throw PreparedDestinationTestError.chmodFailed
        }

        let entries = CodexGhostRepairDestinationCanaryFixedLayout.entries(
            applicationSupport: applicationSupport
        )
        var urls: [CodexGhostRepairDestinationCanaryDirectory: URL] = [:]
        for entry in entries {
            urls[entry.directory] = entry.url
            guard entry.directory != omittedDirectory else { continue }
            let permissions: mode_t = entry.directory == .applicationBundleRoot
                ? 0o755
                : entry.directory == unsafeDirectory ? 0o755 : 0o700
            try FileManager.default.createDirectory(
                at: entry.url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: permissions)]
            )
            guard chmod(entry.url.path, permissions) == 0 else {
                throw PreparedDestinationTestError.chmodFailed
            }
        }
        return Fixture(
            parent: parent,
            applicationSupport: applicationSupport,
            urls: urls,
            destination: CodexGhostRepairSnapshotPreparedDestination(
                testOwnedApplicationSupportDirectory: applicationSupport,
                testOwnedAllowedParentURL: parent,
                capacityProbe: probe
            )
        )
    }

    private func directoryReadback(_ fixture: Fixture) throws
        -> [DirectoryReadback]
    {
        try fixture.urls.map { directory, url in
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw PreparedDestinationTestError.statFailed
            }
            return DirectoryReadback(
                directory: directory,
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                mode: UInt32(status.st_mode & 0o7777)
            )
        }.sorted { $0.directory.rawValue < $1.directory.rawValue }
    }
}

private actor PreparedDestinationCapacityProbe:
    CodexGhostRepairSnapshotDestinationCapacityProbing
{
    private let availableBytes: UInt64
    private var calls = 0

    init(availableBytes: UInt64) {
        self.availableBytes = availableBytes
    }

    func availableCapacity(at _: URL) async throws -> UInt64 {
        calls += 1
        return availableBytes
    }

    func callCount() -> Int { calls }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw")
    } catch {
        errorHandler(error)
    }
}

private enum PreparedDestinationTestError: Error {
    case chmodFailed
    case statFailed
}
