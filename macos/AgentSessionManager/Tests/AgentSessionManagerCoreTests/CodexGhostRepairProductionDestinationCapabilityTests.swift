#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairProductionDestinationCapabilityTests: XCTestCase {
    func testInspectIsZeroEffectAndCarriesInjectedRetentionPolicy() throws {
        let fixture = try makeFixture(label: #function)
        let policy = try makePolicy(count: 3, bytes: 4_096, age: 60_000)
        let capability = try makeCapability(fixture: fixture, policy: policy)

        let report = try capability.inspect()

        XCTAssertEqual(report.status, .requiresPreparation)
        XCTAssertEqual(report.retentionPolicy, policy)
        XCTAssertNil(report.productionPolicy)
        XCTAssertEqual(report.createdDirectories, [])
        XCTAssertNil(report.failureDigest)
        XCTAssertTrue(report.directories.allSatisfy { !$0.exists })
        XCTAssertFalse(report.automaticResumeAllowed)
        XCTAssertFalse(report.snapshotAcquisitionAuthority)
        XCTAssertFalse(report.officialAbsenceAuthority)
        XCTAssertFalse(report.repairMutationAuthority)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.bundleSupportRootURL.path
            )
        )
    }

    func testPrepareCreatesOnlyFixedSixDirectoriesWithExactReadback() throws {
        let fixture = try makeFixture(label: #function)
        let capability = try makeCapability(fixture: fixture)

        let report = try capability.prepare()

        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(
            report.createdDirectories,
            CodexGhostRepairDestinationDirectory.allCases
        )
        XCTAssertTrue(report.directories.allSatisfy(\.exists))
        XCTAssertTrue(report.directories.allSatisfy(\.permissionContractSatisfied))
        XCTAssertTrue(report.directories.allSatisfy { $0.mode == 0o700 })
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.storageRootURL.path
            ).sorted(),
            ["Journal", "Quarantine", "Snapshots"]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.journalRootURL.path
            ),
            ["Trash"]
        )
    }

    func testRepeatedPreparePreservesEveryExistingDirectory() throws {
        let fixture = try makeFixture(label: #function)
        let capability = try makeCapability(fixture: fixture)
        let first = try capability.prepare()
        let identities = Dictionary(
            uniqueKeysWithValues: first.directories.compactMap { evidence in
                evidence.inode.map { (evidence.directory, $0) }
            }
        )

        let second = try capability.prepare()

        XCTAssertEqual(second.status, .ready)
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

    func testExistingSafeBundleRootIsNotChmoddedOrReplaced() throws {
        let fixture = try makeFixture(label: #function)
        try FileManager.default.createDirectory(
            at: fixture.bundleSupportRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertEqual(chmod(fixture.bundleSupportRootURL.path, 0o755), 0)
        let before = try directoryIdentity(fixture.bundleSupportRootURL)
        let capability = try makeCapability(fixture: fixture)

        let report = try capability.prepare()
        let after = try directoryIdentity(fixture.bundleSupportRootURL)
        let bundle = try XCTUnwrap(
            report.directories.first { $0.directory == .bundleSupport }
        )

        XCTAssertEqual(before.device, after.device)
        XCTAssertEqual(before.inode, after.inode)
        XCTAssertEqual(after.mode, 0o755)
        XCTAssertEqual(bundle.mode, 0o755)
        XCTAssertFalse(report.createdDirectories.contains(.bundleSupport))
        XCTAssertTrue(
            report.directories
                .filter { $0.directory != .bundleSupport }
                .allSatisfy { $0.mode == 0o700 }
        )
    }

    func testFileSymlinkAndUnsafePermissionCollisionsFailClosed() throws {
        let fileFixture = try makeFixture(label: "\(#function)-file")
        try FileManager.default.createDirectory(
            at: fileFixture.bundleSupportRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("collision".utf8).write(to: fileFixture.storageRootURL)
        XCTAssertThrowsError(try makeCapability(fixture: fileFixture))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileFixture.snapshotsRootURL.path)
        )

        let symlinkFixture = try makeFixture(label: "\(#function)-symlink")
        let outside = symlinkFixture.allowedParent.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: symlinkFixture.bundleSupportRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkFixture.storageRootURL,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try makeCapability(fixture: symlinkFixture))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])

        let unsafeFixture = try makeFixture(label: "\(#function)-unsafe")
        let unsafeCapability = try makeCapability(fixture: unsafeFixture)
        try FileManager.default.createDirectory(
            at: unsafeFixture.bundleSupportRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: unsafeFixture.storageRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(unsafeFixture.storageRootURL.path, 0o770), 0)
        XCTAssertThrowsError(try unsafeCapability.prepare())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: unsafeFixture.snapshotsRootURL.path)
        )
    }

    func testFailureReturnsReadbackOnlyPartialAndExplicitRetryMayResume() throws {
        let fixture = try makeFixture(label: #function)
        let injector = E41DirectoryFailureInjector(failAtCall: 4)
        let interrupted = try makeCapability(
            fixture: fixture,
            directoryCreator: { try injector.create($0) }
        )

        let partial = try interrupted.prepare()

        XCTAssertEqual(partial.status, .partialSafePrefix)
        XCTAssertEqual(
            partial.createdDirectories,
            [.bundleSupport, .storage, .snapshots]
        )
        XCTAssertNotNil(partial.failureDigest)
        XCTAssertFalse(partial.automaticResumeAllowed)
        XCTAssertEqual(
            partial.directories.filter(\.exists).map(\.directory),
            [.bundleSupport, .storage, .snapshots]
        )
        let preserved = Dictionary(
            uniqueKeysWithValues: partial.directories.compactMap { evidence in
                evidence.inode.map { (evidence.directory, $0) }
            }
        )

        let resumed = try makeCapability(fixture: fixture)
        let completed = try resumed.prepare()

        XCTAssertEqual(completed.status, .ready)
        XCTAssertEqual(
            completed.createdDirectories,
            [.quarantine, .journal, .trashJournal]
        )
        for evidence in completed.directories where preserved[evidence.directory] != nil {
            XCTAssertEqual(evidence.inode, preserved[evidence.directory])
        }
    }

    func testMarkerDriftAfterSafePrefixStopsBeforeNextEffect() throws {
        let fixture = try makeFixture(label: #function)
        let injector = E41DirectoryFailureInjector(
            failAtCall: 3,
            beforeFailure: {
                try Data("drifted\n".utf8).write(to: fixture.markerURL)
            }
        )
        let capability = try makeCapability(
            fixture: fixture,
            directoryCreator: { try injector.create($0) }
        )

        XCTAssertThrowsError(try capability.prepare())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.bundleSupportRootURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.storageRootURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.snapshotsRootURL.path)
        )
    }

    func testMissingMarkerAndEscapedMirrorCannotConstructCapability() throws {
        let missing = try makeFixture(label: "\(#function)-missing", marker: false)
        XCTAssertThrowsError(try makeCapability(fixture: missing))

        let destination = try makeFixture(label: "\(#function)-destination")
        let other = try makeFixture(label: "\(#function)-other")
        XCTAssertThrowsError(
            try CodexGhostRepairProductionDestinationCapability(
                testOwnedApplicationSupportDirectory: destination.applicationSupport,
                testOwnedAllowedParentURL: other.allowedParent,
                retentionPolicy: makePolicy()
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.bundleSupportRootURL.path)
        )
    }

    func testPolicyHasNoImplicitProductionDefault() throws {
        let firstFixture = try makeFixture(label: "\(#function)-first")
        let secondFixture = try makeFixture(label: "\(#function)-second")
        let firstPolicy = try makePolicy(count: 1, bytes: 1_024, age: 2_000)
        let secondPolicy = try makePolicy(count: 9, bytes: 99_999, age: 8_000)

        XCTAssertEqual(
            try makeCapability(fixture: firstFixture, policy: firstPolicy)
                .inspect().retentionPolicy,
            firstPolicy
        )
        XCTAssertEqual(
            try makeCapability(fixture: secondFixture, policy: secondPolicy)
                .inspect().retentionPolicy,
            secondPolicy
        )
        XCTAssertNotEqual(firstPolicy, secondPolicy)
    }

    private func makePolicy(
        count: Int = 5,
        bytes: UInt64 = 1_048_576,
        age: Int64 = 86_400_000
    ) throws -> CodexGhostRepairPublishedSnapshotRetentionPolicy {
        try CodexGhostRepairPublishedSnapshotRetentionPolicy(
            maximumSnapshotCount: count,
            maximumTotalBytes: bytes,
            maximumAgeMilliseconds: age
        )
    }

    private func makeCapability(
        fixture: E41Fixture,
        policy: CodexGhostRepairPublishedSnapshotRetentionPolicy? = nil,
        directoryCreator: @escaping CodexGhostRepairProductionDestinationCapability
            .DirectoryCreator = { url in
                guard mkdir(url.path, S_IRWXU) == 0 else {
                    throw E41DestinationTestError.mkdirFailed
                }
            }
    ) throws -> CodexGhostRepairProductionDestinationCapability {
        try CodexGhostRepairProductionDestinationCapability(
            testOwnedApplicationSupportDirectory: fixture.applicationSupport,
            testOwnedAllowedParentURL: fixture.allowedParent,
            retentionPolicy: policy ?? makePolicy(),
            directoryCreator: directoryCreator
        )
    }

    private func makeFixture(label: String, marker: Bool = true) throws -> E41Fixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let allowedParent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e41-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: allowedParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(allowedParent.path, 0o700), 0)
        let markerURL = allowedParent.appendingPathComponent(
            CodexGhostRepairProductionDestinationCapability.testRootMarkerFileName,
            isDirectory: false
        )
        if marker {
            try Data(
                CodexGhostRepairProductionDestinationCapability
                    .testRootMarkerContents.utf8
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
        let location = try StateStoreLocation.ghostRepairDestinationLocation(
            applicationSupportDirectory: applicationSupport
        )
        return E41Fixture(
            allowedParent: allowedParent,
            markerURL: markerURL,
            applicationSupport: applicationSupport,
            bundleSupportRootURL: location.bundleSupportRootURL,
            storageRootURL: location.storageRootURL,
            snapshotsRootURL: location.snapshotsRootURL,
            journalRootURL: location.journalRootURL
        )
    }

    private func directoryIdentity(_ url: URL) throws
        -> (device: UInt64, inode: UInt64, mode: UInt32)
    {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw E41DestinationTestError.metadataUnavailable
        }
        return (
            UInt64(status.st_dev),
            UInt64(status.st_ino),
            UInt32(status.st_mode & 0o777)
        )
    }
}

private struct E41Fixture: @unchecked Sendable {
    let allowedParent: URL
    let markerURL: URL
    let applicationSupport: URL
    let bundleSupportRootURL: URL
    let storageRootURL: URL
    let snapshotsRootURL: URL
    let journalRootURL: URL
}

private enum E41DestinationTestError: Error {
    case injected
    case mkdirFailed
    case metadataUnavailable
}

private final class E41DirectoryFailureInjector: @unchecked Sendable {
    private let failAtCall: Int
    private let beforeFailure: (() throws -> Void)?
    private var calls = 0
    private let lock = NSLock()

    init(failAtCall: Int, beforeFailure: (() throws -> Void)? = nil) {
        self.failAtCall = failAtCall
        self.beforeFailure = beforeFailure
    }

    func create(_ url: URL) throws {
        lock.lock()
        calls += 1
        let shouldFail = calls == failAtCall
        lock.unlock()
        if shouldFail {
            try beforeFailure?()
            throw E41DestinationTestError.injected
        }
        guard mkdir(url.path, S_IRWXU) == 0 else {
            throw E41DestinationTestError.mkdirFailed
        }
    }
}
#endif
