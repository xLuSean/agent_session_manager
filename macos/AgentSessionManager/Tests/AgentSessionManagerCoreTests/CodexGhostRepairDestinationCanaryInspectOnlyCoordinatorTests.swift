@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairDestinationCanaryInspectOnlyCoordinatorTests:
    XCTestCase
{
    func testConstructionPerformsNoIOAndDefersAllValidation() {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e49-no-io-\(UUID().uuidString)",
            isDirectory: true
        )
        let applicationSupport = parent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )

        let coordinator = CodexGhostRepairDestinationCanaryInspectOnlyCoordinator(
            testOwnedApplicationSupportDirectory: applicationSupport,
            testOwnedAllowedParentURL: parent
        )

        XCTAssertEqual(coordinator.capabilities, .inspectOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testMissingLayoutIsStablePathRedactedAndCreatesNothing() async throws {
        let fixture = try makeFixture(label: #function)
        let before = try FileManager.default.contentsOfDirectory(
            atPath: fixture.applicationSupport.path
        )
        let first = makeCoordinator(
            fixture,
            clock: { Date(timeIntervalSince1970: 1_000) }
        )
        let second = makeCoordinator(
            fixture,
            clock: { Date(timeIntervalSince1970: 2_000) }
        )

        let firstEvidence = try inspectionEvidence(
            await first.inspect(requestID: UUID())
        )
        let secondEvidence = try inspectionEvidence(
            await second.inspect(requestID: UUID())
        )

        XCTAssertEqual(firstEvidence.evidenceToken, secondEvidence.evidenceToken)
        XCTAssertNotEqual(firstEvidence.observedAt, secondEvidence.observedAt)
        XCTAssertEqual(
            Set(firstEvidence.missingDirectories),
            Set(CodexGhostRepairDestinationCanaryDirectory.allCases)
        )
        XCTAssertEqual(firstEvidence.policy.identifier, "ghost-repair-retention-v1")
        XCTAssertEqual(firstEvidence.policy.maximumSnapshotCount, 3)
        XCTAssertEqual(firstEvidence.policy.maximumTotalBytes, 4_294_967_296)
        XCTAssertEqual(firstEvidence.policy.maximumAgeMilliseconds, 2_592_000_000)
        XCTAssertTrue(firstEvidence.pathRedacted)
        XCTAssertFalse(firstEvidence.filesystemAuthority)
        XCTAssertFalse(firstEvidence.snapshotAuthority)
        XCTAssertFalse(firstEvidence.officialAbsenceAuthority)
        XCTAssertFalse(firstEvidence.repairMutationAuthority)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.applicationSupport.path
            ),
            before
        )
    }

    func testReadyLayoutPreservesExactIdentityAndModes() async throws {
        let fixture = try makeFixture(label: #function)
        let urls = try createReadyLayout(fixture, bundleMode: 0o700)
        let before = try urls.map(directoryIdentity)

        let evidence = try inspectionEvidence(
            await makeCoordinator(fixture).inspect(requestID: UUID())
        )

        XCTAssertTrue(evidence.isReady)
        XCTAssertTrue(evidence.directories.allSatisfy { $0.status == .ready })
        XCTAssertEqual(try urls.map(directoryIdentity), before)
        XCTAssertEqual(
            evidence.directories.map(\.observedMode),
            Array(repeating: Optional(0o700), count: 6)
        )
    }

    func testOwnerControlled0755BundleRootIsAcceptedWithoutChmod() async throws {
        let fixture = try makeFixture(label: #function)
        let urls = try createReadyLayout(fixture, bundleMode: 0o755)
        let before = try directoryIdentity(urls[0])

        let evidence = try inspectionEvidence(
            await makeCoordinator(fixture).inspect(requestID: UUID())
        )

        let bundle = try XCTUnwrap(evidence.directories.first {
            $0.directory == .applicationBundleRoot
        })
        XCTAssertEqual(bundle.status, .ready)
        XCTAssertEqual(bundle.permissionRequirement, .ownerControlled)
        XCTAssertEqual(bundle.observedMode, 0o755)
        XCTAssertEqual(try directoryIdentity(urls[0]), before)
        XCTAssertTrue(evidence.directories
            .filter { $0.directory != .applicationBundleRoot }
            .allSatisfy {
                $0.permissionRequirement == .ownerPrivate0700
                    && $0.observedMode == 0o700
            })
    }

    func testUnsafePrivateDirectoryBlocksWithPathRedactedEvidence() async throws {
        let fixture = try makeFixture(label: #function)
        let urls = try createReadyLayout(fixture, bundleMode: 0o755)
        XCTAssertEqual(chmod(urls[2].path, 0o755), 0)

        let outcome = await makeCoordinator(fixture).inspect(requestID: UUID())

        guard case let .blocked(evidence, message) = outcome else {
            return XCTFail("Unsafe private directory must block inspection")
        }
        XCTAssertEqual(
            evidence?.directories.first { $0.directory == .snapshots }?.status,
            .unsafe
        )
        XCTAssertFalse(message.contains(fixture.allowedParent.path))
        XCTAssertFalse(message.contains("/Users/"))
        XCTAssertTrue(message.contains("unsafe-fixed-layout"))
    }

    func testFixedPathFileCollisionBlocksWithoutOpeningItAsDirectory() async throws {
        let fixture = try makeFixture(label: #function)
        try FileManager.default.createDirectory(
            at: fixture.bundleRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try Data("collision".utf8).write(to: fixture.ghostRepairRoot)

        let outcome = await makeCoordinator(fixture).inspect(requestID: UUID())

        guard case let .blocked(evidence, message) = outcome else {
            return XCTFail("Fixed path collision must block inspection")
        }
        XCTAssertEqual(
            evidence?.directories.first {
                $0.directory == .ghostRepairRoot
            }?.status,
            .collision
        )
        XCTAssertTrue(message.contains("Clear filesystem paths are unavailable"))
    }

    func testFixedPathSymlinkCollisionIsNotFollowed() async throws {
        let fixture = try makeFixture(label: #function)
        try FileManager.default.createDirectory(
            at: fixture.bundleRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let target = fixture.allowedParent.appendingPathComponent(
            "symlink-target",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.ghostRepairRoot,
            withDestinationURL: target
        )

        let outcome = await makeCoordinator(fixture).inspect(requestID: UUID())

        guard case let .blocked(evidence, _) = outcome else {
            return XCTFail("Symlink must be classified as a collision")
        }
        XCTAssertEqual(
            evidence?.directories.first {
                $0.directory == .ghostRepairRoot
            }?.status,
            .collision
        )
    }

    func testInvalidMarkerStopsBeforeFixedLayoutReadback() async throws {
        let fixture = try makeFixture(label: #function)
        try Data("drift".utf8).write(to: fixture.markerURL)
        XCTAssertEqual(chmod(fixture.markerURL.path, 0o600), 0)
        try Data("would-be-collision".utf8).write(to: fixture.bundleRoot)

        let outcome = await makeCoordinator(fixture).inspect(requestID: UUID())

        guard case let .blocked(evidence, message) = outcome else {
            return XCTFail("Marker drift must fail closed")
        }
        XCTAssertNil(evidence)
        XCTAssertTrue(message.contains("invalid-test-marker"))
        XCTAssertFalse(message.contains(fixture.allowedParent.path))
    }

    func testApplicationSupportOutsideAllowedParentFailsClosed() async throws {
        let fixture = try makeFixture(label: #function)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e49-outside-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(outside.path, 0o700), 0)
        let coordinator = CodexGhostRepairDestinationCanaryInspectOnlyCoordinator(
            testOwnedApplicationSupportDirectory: outside,
            testOwnedAllowedParentURL: fixture.allowedParent
        )

        let outcome = await coordinator.inspect(requestID: UUID())

        guard case let .blocked(evidence, message) = outcome else {
            return XCTFail("Escaped test root must fail closed")
        }
        XCTAssertNil(evidence)
        XCTAssertTrue(message.contains("invalid-test-boundary"))
    }

    func testPrepareIsAlwaysUnavailableAndCreatesNothing() async throws {
        let fixture = try makeFixture(label: #function)
        let coordinator = makeCoordinator(fixture)
        let evidence = try inspectionEvidence(
            await coordinator.inspect(requestID: UUID())
        )
        let request = try CodexGhostRepairDestinationCanaryPreparationRequest(
            evidence: evidence
        )
        let before = try FileManager.default.contentsOfDirectory(
            atPath: fixture.applicationSupport.path
        )

        let outcome = await coordinator.prepare(request: request)

        guard case let .unavailable(message) = outcome else {
            return XCTFail("Inspect-only coordinator must never prepare")
        }
        XCTAssertTrue(message.contains("not included"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.applicationSupport.path
            ),
            before
        )
    }

    func testProductionFactoryCanBeTypeCheckedWithoutInvocation() {
        let factory: (
            @escaping CodexGhostRepairDestinationCanaryInspectOnlyCoordinator.Clock
        ) -> CodexGhostRepairDestinationCanaryInspectOnlyCoordinator =
            CodexGhostRepairDestinationCanaryInspectOnlyCoordinator.production(clock:)

        _ = factory
    }

    private func makeCoordinator(
        _ fixture: E49Fixture,
        clock: @escaping @Sendable () -> Date = {
            Date(timeIntervalSince1970: 1_000)
        }
    ) -> CodexGhostRepairDestinationCanaryInspectOnlyCoordinator {
        CodexGhostRepairDestinationCanaryInspectOnlyCoordinator(
            testOwnedApplicationSupportDirectory: fixture.applicationSupport,
            testOwnedAllowedParentURL: fixture.allowedParent,
            clock: clock
        )
    }

    private func inspectionEvidence(
        _ outcome: CodexGhostRepairDestinationCanaryInspectionOutcome
    ) throws -> CodexGhostRepairDestinationCanaryEvidence {
        switch outcome {
        case let .needsPreparation(evidence), let .ready(evidence):
            return evidence
        default:
            throw E49TestError.unexpectedOutcome
        }
    }

    private func makeFixture(label: String) throws -> E49Fixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let allowedParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-session-manager-e49-\(safeLabel)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: allowedParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(allowedParent.path, 0o700), 0)
        let markerURL = allowedParent.appendingPathComponent(
            CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                .testRootMarkerFileName,
            isDirectory: false
        )
        try Data(
            CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                .testRootMarkerContents.utf8
        ).write(to: markerURL)
        XCTAssertEqual(chmod(markerURL.path, 0o600), 0)
        let applicationSupport = allowedParent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(applicationSupport.path, 0o700), 0)
        let bundleRoot = applicationSupport.appendingPathComponent(
            StateStoreLocation.defaultBundleIdentifier,
            isDirectory: true
        )
        let ghostRepairRoot = bundleRoot.appendingPathComponent(
            "GhostRepair",
            isDirectory: true
        )
        return E49Fixture(
            allowedParent: allowedParent,
            applicationSupport: applicationSupport,
            markerURL: markerURL,
            bundleRoot: bundleRoot,
            ghostRepairRoot: ghostRepairRoot
        )
    }

    private func createReadyLayout(
        _ fixture: E49Fixture,
        bundleMode: mode_t
    ) throws -> [URL] {
        let snapshots = fixture.ghostRepairRoot.appendingPathComponent(
            "Snapshots",
            isDirectory: true
        )
        let quarantine = fixture.ghostRepairRoot.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        let journal = fixture.ghostRepairRoot.appendingPathComponent(
            "Journal",
            isDirectory: true
        )
        let trash = journal.appendingPathComponent("Trash", isDirectory: true)
        let urls = [
            fixture.bundleRoot,
            fixture.ghostRepairRoot,
            snapshots,
            quarantine,
            journal,
            trash,
        ]
        for (index, url) in urls.enumerated() {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: index == 0 ? bundleMode : 0o700]
            )
            XCTAssertEqual(chmod(url.path, index == 0 ? bundleMode : 0o700), 0)
        }
        return urls
    }

    private func directoryIdentity(_ url: URL) throws -> E49DirectoryIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw E49TestError.metadataUnavailable
        }
        return E49DirectoryIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode & 0o7777),
            ownerUID: UInt32(status.st_uid)
        )
    }
}

private struct E49Fixture: Sendable {
    let allowedParent: URL
    let applicationSupport: URL
    let markerURL: URL
    let bundleRoot: URL
    let ghostRepairRoot: URL
}

private struct E49DirectoryIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let ownerUID: UInt32
}

private enum E49TestError: Error {
    case metadataUnavailable
    case unexpectedOutcome
}
