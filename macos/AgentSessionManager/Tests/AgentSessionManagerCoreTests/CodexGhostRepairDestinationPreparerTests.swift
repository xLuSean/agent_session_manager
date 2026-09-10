#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairDestinationPreparerTests: XCTestCase {
    func testPreparationCreatesOnlyFixedPrivateDirectoriesWithExactReadback() throws {
        let fixture = try makeFixture(label: #function)
        let preparer = try CodexGhostRepairDestinationPreparer(
            location: fixture.location,
            testOwnedAllowedParentURL: fixture.allowedParent
        )

        let before = try preparer.inspect()
        XCTAssertFalse(before.completed)
        XCTAssertTrue(before.directories.allSatisfy { !$0.exists })
        XCTAssertFalse(before.recoveryMutationAuthority)

        let report = try preparer.prepare()

        XCTAssertTrue(report.completed)
        XCTAssertEqual(report.createdDirectories, CodexGhostRepairDestinationDirectory.allCases)
        XCTAssertTrue(report.directories.allSatisfy(\.exists))
        XCTAssertTrue(report.directories.allSatisfy(\.permissionContractSatisfied))
        XCTAssertTrue(report.directories.allSatisfy { $0.mode == 0o700 })
        XCTAssertEqual(report.storageRootDigest, fixture.location.storageRootDigest)
        XCTAssertFalse(report.recoveryMutationAuthority)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.location.storageRootURL.path
            ).sorted(),
            ["Journal", "Quarantine", "Snapshots"]
        )
    }

    func testRepeatedPreparationIsIdempotentAndPreservesDirectoryIdentity() throws {
        let fixture = try makeFixture(label: #function)
        let preparer = try CodexGhostRepairDestinationPreparer(
            location: fixture.location,
            testOwnedAllowedParentURL: fixture.allowedParent
        )
        let first = try preparer.prepare()
        let identities = Dictionary(
            uniqueKeysWithValues: first.directories.compactMap { evidence in
                evidence.inode.map { (evidence.directory, $0) }
            }
        )

        let second = try preparer.prepare()

        XCTAssertTrue(second.completed)
        XCTAssertEqual(second.createdDirectories, [])
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: second.directories.compactMap { evidence in
                    evidence.inode.map { (evidence.directory, $0) }
                }
            ),
            identities
        )
    }

    func testExistingSafeBundleRootIsPreservedWhilePrivateSubtreeUses0700() throws {
        let fixture = try makeFixture(label: #function)
        try FileManager.default.createDirectory(
            at: fixture.location.bundleSupportRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertEqual(chmod(fixture.location.bundleSupportRootURL.path, 0o755), 0)
        let before = try FileManager.default.attributesOfItem(
            atPath: fixture.location.bundleSupportRootURL.path
        )
        let preparer = try CodexGhostRepairDestinationPreparer(
            location: fixture.location,
            testOwnedAllowedParentURL: fixture.allowedParent
        )

        let report = try preparer.prepare()
        let bundleEvidence = try XCTUnwrap(
            report.directories.first { $0.directory == .bundleSupport }
        )
        let after = try FileManager.default.attributesOfItem(
            atPath: fixture.location.bundleSupportRootURL.path
        )

        XCTAssertTrue(report.completed)
        XCTAssertFalse(report.createdDirectories.contains(.bundleSupport))
        XCTAssertEqual(bundleEvidence.mode, 0o755)
        XCTAssertTrue(bundleEvidence.permissionContractSatisfied)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(after[.posixPermissions] as? NSNumber, NSNumber(value: 0o755))
        XCTAssertTrue(
            report.directories
                .filter { $0.directory != .bundleSupport }
                .allSatisfy { $0.mode == 0o700 }
        )
    }

    func testCollisionAndSymlinkDriftFailBeforeAnyFurtherDirectoryCreation() throws {
        let collisionFixture = try makeFixture(label: "\(#function)-collision")
        let collisionPreparer = try CodexGhostRepairDestinationPreparer(
            location: collisionFixture.location,
            testOwnedAllowedParentURL: collisionFixture.allowedParent
        )
        try FileManager.default.createDirectory(
            at: collisionFixture.location.bundleSupportRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("collision".utf8).write(to: collisionFixture.location.storageRootURL)

        XCTAssertThrowsError(try collisionPreparer.prepare())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: collisionFixture.location.snapshotsRootURL.path
            )
        )

        let symlinkFixture = try makeFixture(label: "\(#function)-symlink")
        let symlinkPreparer = try CodexGhostRepairDestinationPreparer(
            location: symlinkFixture.location,
            testOwnedAllowedParentURL: symlinkFixture.allowedParent
        )
        try FileManager.default.createDirectory(
            at: symlinkFixture.location.bundleSupportRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let outside = symlinkFixture.allowedParent.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkFixture.location.storageRootURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try symlinkPreparer.prepare())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outside.path),
            []
        )
    }

    func testUnsafeExistingDirectoryAndMarkerDriftHaveZeroEffect() throws {
        let unsafeFixture = try makeFixture(label: "\(#function)-permissions")
        let unsafePreparer = try CodexGhostRepairDestinationPreparer(
            location: unsafeFixture.location,
            testOwnedAllowedParentURL: unsafeFixture.allowedParent
        )
        try FileManager.default.createDirectory(
            at: unsafeFixture.location.bundleSupportRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(unsafeFixture.location.bundleSupportRootURL.path, 0o770), 0)

        XCTAssertThrowsError(try unsafePreparer.prepare())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: unsafeFixture.location.storageRootURL.path)
        )

        let markerFixture = try makeFixture(label: "\(#function)-marker")
        let markerPreparer = try CodexGhostRepairDestinationPreparer(
            location: markerFixture.location,
            testOwnedAllowedParentURL: markerFixture.allowedParent
        )
        try Data("changed\n".utf8).write(to: markerFixture.markerURL)

        XCTAssertThrowsError(try markerPreparer.prepare())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: markerFixture.location.bundleSupportRootURL.path
            )
        )
    }

    func testPartialFailureIsReadbackOnlyAndFreshPreparationCanComplete() throws {
        let fixture = try makeFixture(label: #function)
        let injector = E34DirectoryFailureInjector(failAtCall: 4)
        let interrupted = try CodexGhostRepairDestinationPreparer(
            location: fixture.location,
            testOwnedAllowedParentURL: fixture.allowedParent,
            directoryCreator: { try injector.create($0) }
        )

        XCTAssertThrowsError(try interrupted.prepare()) { error in
            XCTAssertEqual(error as? E34DestinationTestError, .injected)
        }
        let partial = try interrupted.inspect()
        XCTAssertFalse(partial.completed)
        XCTAssertFalse(partial.recoveryMutationAuthority)
        XCTAssertEqual(
            partial.directories.filter(\.exists).map(\.directory),
            [.bundleSupport, .storage, .snapshots]
        )
        let preserved = Dictionary(
            uniqueKeysWithValues: partial.directories.compactMap { evidence in
                evidence.inode.map { (evidence.directory, $0) }
            }
        )

        let resumed = try CodexGhostRepairDestinationPreparer(
            location: fixture.location,
            testOwnedAllowedParentURL: fixture.allowedParent
        )
        let completed = try resumed.prepare()

        XCTAssertTrue(completed.completed)
        XCTAssertEqual(
            completed.createdDirectories,
            [.quarantine, .journal, .trashJournal]
        )
        for evidence in completed.directories where preserved[evidence.directory] != nil {
            XCTAssertEqual(evidence.inode, preserved[evidence.directory])
        }
    }

    func testInjectedRaceCollisionStopsBeforeFollowingDirectories() throws {
        let fixture = try makeFixture(label: #function)
        let injector = E34DirectoryFailureInjector(
            failAtCall: 4,
            collisionURL: fixture.location.quarantineRootURL
        )
        let preparer = try CodexGhostRepairDestinationPreparer(
            location: fixture.location,
            testOwnedAllowedParentURL: fixture.allowedParent,
            directoryCreator: { try injector.create($0) }
        )

        XCTAssertThrowsError(try preparer.prepare())
        var status = stat()
        XCTAssertEqual(lstat(fixture.location.quarantineRootURL.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.location.journalRootURL.path)
        )
    }

    func testMissingMarkerAndEscapedDestinationCannotConstructCapability() throws {
        let missingMarker = try makeFixture(label: "\(#function)-missing", marker: false)
        XCTAssertThrowsError(
            try CodexGhostRepairDestinationPreparer(
                location: missingMarker.location,
                testOwnedAllowedParentURL: missingMarker.allowedParent
            )
        )

        let destination = try makeFixture(label: "\(#function)-destination")
        let other = try makeFixture(label: "\(#function)-other")
        XCTAssertThrowsError(
            try CodexGhostRepairDestinationPreparer(
                location: destination.location,
                testOwnedAllowedParentURL: other.allowedParent
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.location.bundleSupportRootURL.path
            )
        )
    }

    private func makeFixture(label: String, marker: Bool = true) throws -> E34Fixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let allowedParent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e34-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: allowedParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(allowedParent.path, 0o700), 0)
        let markerURL = allowedParent.appendingPathComponent(
            CodexGhostRepairDestinationPreparer.testRootMarkerFileName,
            isDirectory: false
        )
        if marker {
            try Data(
                CodexGhostRepairDestinationPreparer.testRootMarkerContents.utf8
            ).write(to: markerURL)
            XCTAssertEqual(chmod(markerURL.path, 0o600), 0)
        }
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
        return E34Fixture(
            allowedParent: allowedParent,
            markerURL: markerURL,
            location: try StateStoreLocation.ghostRepairDestinationLocation(
                applicationSupportDirectory: applicationSupport
            )
        )
    }
}

private struct E34Fixture {
    let allowedParent: URL
    let markerURL: URL
    let location: StateStoreLocation.GhostRepairDestinationLocation
}

private enum E34DestinationTestError: Error, Equatable {
    case injected
}

private final class E34DirectoryFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let failAtCall: Int
    private let collisionURL: URL?
    private var callCount = 0

    init(failAtCall: Int, collisionURL: URL? = nil) {
        self.failAtCall = failAtCall
        self.collisionURL = collisionURL
    }

    func create(_ url: URL) throws {
        lock.lock()
        callCount += 1
        let shouldFail = callCount == failAtCall
        lock.unlock()
        if shouldFail {
            if collisionURL == url {
                try Data("race collision".utf8).write(to: url)
            }
            throw E34DestinationTestError.injected
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(url.path, 0o700) == 0 else {
            throw E34DestinationTestError.injected
        }
    }
}
#endif
