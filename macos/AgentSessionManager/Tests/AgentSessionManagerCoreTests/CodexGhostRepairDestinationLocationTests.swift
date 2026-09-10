#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairDestinationLocationTests: XCTestCase {
    func testFixedManagerLayoutSharesBundleRootWithoutCreatingDirectories() throws {
        let applicationSupport = try makeApplicationSupport(label: #function)
        let contentsBefore = try FileManager.default.contentsOfDirectory(
            atPath: applicationSupport.path
        )

        let location = try StateStoreLocation.ghostRepairDestinationLocation(
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertEqual(
            location.bundleSupportRootURL,
            applicationSupport.appendingPathComponent(
                StateStoreLocation.defaultBundleIdentifier,
                isDirectory: true
            )
        )
        XCTAssertEqual(
            location.bundleSupportRootURL,
            try StateStoreLocation.databaseURL(
                applicationSupportDirectory: applicationSupport
            ).deletingLastPathComponent()
        )
        XCTAssertEqual(
            location.storageRootURL.lastPathComponent,
            "GhostRepair"
        )
        XCTAssertEqual(location.snapshotsRootURL.lastPathComponent, "Snapshots")
        XCTAssertEqual(location.quarantineRootURL.lastPathComponent, "Quarantine")
        XCTAssertEqual(location.journalRootURL.lastPathComponent, "Journal")
        XCTAssertEqual(location.trashJournalRootURL.lastPathComponent, "Trash")
        XCTAssertEqual(location.capacityProbeURL, applicationSupport)
        XCTAssertFalse(location.storageRootDigest.contains(applicationSupport.path))
        XCTAssertFalse(location.resolutionMutationAuthority)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: applicationSupport.path),
            contentsBefore
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: location.bundleSupportRootURL.path)
        )
    }

    func testExistingOwnerControlledFixedLayoutIsAcceptedReadOnly() throws {
        let applicationSupport = try makeApplicationSupport(label: #function)
        let expected = try fixedURLs(applicationSupport: applicationSupport)
        for directory in expected {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(directory.path, 0o700) == 0 else {
                throw E33TestError.chmodFailed
            }
        }
        let before = try directoryIdentity(expected)

        let location = try StateStoreLocation.ghostRepairDestinationLocation(
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertEqual(location.trashJournalRootURL, expected.last)
        XCTAssertEqual(try directoryIdentity(expected), before)
    }

    func testInvalidBundleIdentifierAndSymlinkedApplicationSupportFailClosed() throws {
        let applicationSupport = try makeApplicationSupport(label: #function)
        XCTAssertThrowsError(
            try StateStoreLocation.ghostRepairDestinationLocation(
                applicationSupportDirectory: applicationSupport,
                bundleIdentifier: "../unsafe"
            )
        ) { error in
            XCTAssertEqual(
                error as? StateStoreLocationError,
                .invalidBundleIdentifier("../unsafe")
            )
        }

        let parent = applicationSupport.deletingLastPathComponent()
        let symlink = parent.appendingPathComponent("Application Support Link")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: applicationSupport
        )
        XCTAssertThrowsError(
            try StateStoreLocation.ghostRepairDestinationLocation(
                applicationSupportDirectory: symlink
            )
        ) { error in
            guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testUnsafeApplicationSupportOrExistingDerivedPathFailsClosed() throws {
        let unsafeBase = try makeApplicationSupport(label: "\(#function)-base")
        XCTAssertEqual(chmod(unsafeBase.path, 0o770), 0)
        XCTAssertThrowsError(
            try StateStoreLocation.ghostRepairDestinationLocation(
                applicationSupportDirectory: unsafeBase
            )
        )

        let symlinkedChild = try makeApplicationSupport(label: "\(#function)-child")
        let bundleRoot = symlinkedChild.appendingPathComponent(
            StateStoreLocation.defaultBundleIdentifier,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let outside = symlinkedChild.deletingLastPathComponent()
            .appendingPathComponent("outside-ghost-repair", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: bundleRoot.appendingPathComponent("GhostRepair"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try StateStoreLocation.ghostRepairDestinationLocation(
                applicationSupportDirectory: symlinkedChild
            )
        )

        let unsafeChild = try makeApplicationSupport(label: "\(#function)-permissions")
        let unsafeBundle = unsafeChild.appendingPathComponent(
            StateStoreLocation.defaultBundleIdentifier,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unsafeBundle,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(unsafeBundle.path, 0o770), 0)
        XCTAssertThrowsError(
            try StateStoreLocation.ghostRepairDestinationLocation(
                applicationSupportDirectory: unsafeChild
            )
        )
    }

    func testResolvedDestinationMustRemainDisjointFromCanonicalSource() throws {
        let parent = try makeParent(label: #function)
        let codexHome = try makeCanonicalMirror(parent: parent)
        let source = try CodexGhostRepairCanonicalAcquisitionSource(
            operationalGateConfiguration: CodexGhostRepairOperationalGateConfiguration(
                codexHomeURL: codexHome,
                backupVolumeProbeURL: parent,
                fixedCapacityHeadroomBytes: 0
            ),
            testOwnedAllowedParentURL: parent
        )
        let overlappingApplicationSupport = codexHome.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: overlappingApplicationSupport,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let overlapping = try StateStoreLocation.ghostRepairDestinationLocation(
            applicationSupportDirectory: overlappingApplicationSupport
        )

        XCTAssertThrowsError(try source.validate(separatedFrom: overlapping)) { error in
            guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }

        let disjointApplicationSupport = parent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: disjointApplicationSupport,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let disjoint = try StateStoreLocation.ghostRepairDestinationLocation(
            applicationSupportDirectory: disjointApplicationSupport
        )
        XCTAssertNoThrow(try source.validate(separatedFrom: disjoint))
    }

    private func makeApplicationSupport(label: String) throws -> URL {
        let parent = try makeParent(label: label)
        let applicationSupport = parent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(applicationSupport.path, 0o700) == 0 else {
            throw E33TestError.chmodFailed
        }
        return applicationSupport
    }

    private func makeParent(label: String) throws -> URL {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e33-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return parent
    }

    private func fixedURLs(applicationSupport: URL) throws -> [URL] {
        let bundleRoot = applicationSupport.appendingPathComponent(
            StateStoreLocation.defaultBundleIdentifier,
            isDirectory: true
        )
        let storage = bundleRoot.appendingPathComponent("GhostRepair", isDirectory: true)
        let journal = storage.appendingPathComponent("Journal", isDirectory: true)
        return [
            bundleRoot,
            storage,
            storage.appendingPathComponent("Snapshots", isDirectory: true),
            storage.appendingPathComponent("Quarantine", isDirectory: true),
            journal,
            journal.appendingPathComponent("Trash", isDirectory: true),
        ]
    }

    private func directoryIdentity(_ urls: [URL]) throws -> [String: NSNumber] {
        var result: [String: NSNumber] = [:]
        for url in urls {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            result[url.path] = attributes[.systemFileNumber] as? NSNumber
        }
        return result
    }

    private func makeCanonicalMirror(parent: URL) throws -> URL {
        let codexHome = parent.appendingPathComponent(".codex", isDirectory: true)
        let sqliteRoot = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sqliteRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(codexHome.path, 0o700) == 0,
              chmod(sqliteRoot.path, 0o700) == 0 else {
            throw E33TestError.chmodFailed
        }
        try Data(
            CodexGhostRepairCanonicalAcquisitionSource.testMirrorMarkerContents.utf8
        ).write(
            to: codexHome.appendingPathComponent(
                CodexGhostRepairCanonicalAcquisitionSource.testMirrorMarkerFileName
            )
        )
        for name in [
            "codex-dev.db",
            "codex-thread-summaries-dev.db",
            "codex-history-snapshots-dev.db",
        ] {
            let database = sqliteRoot.appendingPathComponent(name)
            try Data("E33 \(name)".utf8).write(to: database)
            guard chmod(database.path, 0o600) == 0 else {
                throw E33TestError.chmodFailed
            }
        }
        return codexHome
    }
}

private enum E33TestError: Error {
    case chmodFailed
}
#endif
