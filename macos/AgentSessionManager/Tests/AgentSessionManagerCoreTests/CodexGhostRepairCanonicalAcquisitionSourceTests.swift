#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairCanonicalAcquisitionSourceTests: XCTestCase {
    func testFixedTwelvePathFingerprintAndRawReadsUseNonSQLiteBytes() throws {
        let fixture = try makeFixture(label: #function, includeSidecars: true)
        let source = try makeSource(fixture)

        let evidence = try source.fingerprint()

        XCTAssertEqual(evidence.count, 12)
        XCTAssertEqual(
            evidence.map(\.fileName),
            CodexGhostRepairCanonicalSourceFile.allCases.map(\.rawValue)
        )
        XCTAssertTrue(evidence.allSatisfy(\.exists))
        XCTAssertTrue(evidence.allSatisfy {
            $0.sha256?.hasPrefix("sha256:") == true && $0.sha256?.count == 71
        })
        XCTAssertFalse(source.canonicalCodexHomeDigest.contains(fixture.codexHome.path))
        XCTAssertFalse(source.sqliteRootDigest.contains(fixture.sqliteRoot.path))

        for file in CodexGhostRepairCanonicalSourceFile.allCases {
            let read = try XCTUnwrap(source.rawRead(file))
            XCTAssertEqual(read.evidence.fileName, file.rawValue)
            XCTAssertEqual(
                read.bytes,
                try Data(contentsOf: fixture.sqliteRoot.appendingPathComponent(file.rawValue))
            )
        }
    }

    func testAbsentSidecarsRemainExplicitWhileThreeDatabasesAreRequired() throws {
        let fixture = try makeFixture(label: #function)
        let source = try makeSource(fixture)

        let evidence = try source.fingerprint()

        XCTAssertEqual(evidence.filter(\.exists).map(\.fileName), [
            "codex-dev.db",
            "codex-thread-summaries-dev.db",
            "codex-history-snapshots-dev.db",
        ])
        XCTAssertNil(try source.rawRead(.desktopWAL))
        XCTAssertEqual(
            try XCTUnwrap(source.rawRead(.desktop)).bytes,
            Data("E31 raw non-SQLite desktop\n".utf8)
        )
    }

    func testSourceAndOperationalGateShareOneDerivedCanonicalRoot() throws {
        let fixture = try makeFixture(label: #function)
        let source = try makeSource(fixture)
        let expectedHomeDigest = try CodexGhostRepairHasher.hash(
            fixture.codexHome.standardizedFileURL.resolvingSymlinksInPath().path
        )
        let expectedSQLiteDigest = try CodexGhostRepairHasher.hash(
            fixture.sqliteRoot.standardizedFileURL.resolvingSymlinksInPath().path
        )

        XCTAssertEqual(source.canonicalCodexHomeDigest, expectedHomeDigest)
        XCTAssertEqual(source.sqliteRootDigest, expectedSQLiteDigest)
        XCTAssertEqual(
            fixture.configuration.desktopDatabaseURL.lastPathComponent,
            "codex-dev.db"
        )
        XCTAssertEqual(
            fixture.configuration.summariesDatabaseURL.lastPathComponent,
            "codex-thread-summaries-dev.db"
        )
        XCTAssertEqual(
            fixture.configuration.historyDatabaseURL.lastPathComponent,
            "codex-history-snapshots-dev.db"
        )
    }

    func testMissingMarkerAndRequiredDatabaseFailClosed() throws {
        let missingMarker = try makeFixture(label: "\(#function)-marker")
        try FileManager.default.removeItem(
            at: missingMarker.codexHome.appendingPathComponent(
                CodexGhostRepairCanonicalAcquisitionSource.testMirrorMarkerFileName
            )
        )
        XCTAssertThrowsError(try makeSource(missingMarker)) { error in
            guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }

        let missingDatabase = try makeFixture(label: "\(#function)-database")
        try FileManager.default.removeItem(
            at: missingDatabase.configuration.historyDatabaseURL
        )
        let missingDatabaseSource = try makeSource(missingDatabase)
        XCTAssertThrowsError(try missingDatabaseSource.fingerprint()) { error in
            guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testConstructionBindsCapabilityWithoutOpeningDatabaseFiles() throws {
        let fixture = try makeFixture(label: #function)
        XCTAssertEqual(chmod(fixture.configuration.desktopDatabaseURL.path, 0o000), 0)

        let source = try makeSource(fixture)

        XCTAssertFalse(source.canonicalCodexHomeDigest.isEmpty)
        XCTAssertThrowsError(try source.fingerprint()) { error in
            guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testOutsideParentAndSymlinkedSQLiteRootAreRejected() throws {
        let outside = try makeFixture(label: "\(#function)-outside")
        let unrelatedParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("e31-unrelated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: unrelatedParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertThrowsError(
            try CodexGhostRepairCanonicalAcquisitionSource(
                operationalGateConfiguration: outside.configuration,
                testOwnedAllowedParentURL: unrelatedParent
            )
        )

        let symlink = try makeFixture(label: "\(#function)-symlink")
        let realSQLite = symlink.parent.appendingPathComponent("real-sqlite")
        try FileManager.default.moveItem(at: symlink.sqliteRoot, to: realSQLite)
        try FileManager.default.createSymbolicLink(
            at: symlink.sqliteRoot,
            withDestinationURL: realSQLite
        )
        XCTAssertThrowsError(try makeSource(symlink)) { error in
            guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testSymlinkedFileAndUnsafePermissionsAreRejected() throws {
        let symlink = try makeFixture(label: "\(#function)-symlink")
        let desktop = symlink.configuration.desktopDatabaseURL
        let outside = symlink.parent.appendingPathComponent("outside.db")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: desktop)
        try FileManager.default.createSymbolicLink(
            at: desktop,
            withDestinationURL: outside
        )
        let symlinkSource = try makeSource(symlink)
        XCTAssertThrowsError(try symlinkSource.fingerprint())

        let permissions = try makeFixture(label: "\(#function)-permissions")
        XCTAssertEqual(chmod(permissions.sqliteRoot.path, 0o770), 0)
        XCTAssertThrowsError(try makeSource(permissions)) { error in
            guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }

        let filePermissions = try makeFixture(label: "\(#function)-file-permissions")
        XCTAssertEqual(
            chmod(filePermissions.configuration.summariesDatabaseURL.path, 0o660),
            0
        )
        let filePermissionSource = try makeSource(filePermissions)
        XCTAssertThrowsError(try filePermissionSource.fingerprint()) { error in
            guard case .invalidProtectionEvidence = error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testPathReplacementDuringRawReadIsDetectedAsDrift() throws {
        let fixture = try makeFixture(label: #function)
        let source = try makeSource(fixture)
        let desktop = fixture.configuration.desktopDatabaseURL

        XCTAssertThrowsError(
            try source.rawRead(.desktop) {
                try Data("replacement".utf8).write(to: desktop, options: .atomic)
                XCTAssertEqual(chmod(desktop.path, 0o600), 0)
            }
        ) { error in
            guard case .targetDrift = error as? CodexGhostRepairError else {
                return XCTFail("Expected targetDrift, found \(error)")
            }
        }
    }

    private struct Fixture {
        let parent: URL
        let codexHome: URL
        let sqliteRoot: URL
        let configuration: CodexGhostRepairOperationalGateConfiguration
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
            "agent-session-manager-e31-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let codexHome = parent.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sqliteRoot = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sqliteRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(
            CodexGhostRepairCanonicalAcquisitionSource.testMirrorMarkerContents.utf8
        ).write(
            to: codexHome.appendingPathComponent(
                CodexGhostRepairCanonicalAcquisitionSource.testMirrorMarkerFileName
            )
        )
        let databaseContents = [
            "codex-dev.db": "E31 raw non-SQLite desktop\n",
            "codex-thread-summaries-dev.db": "E31 raw non-SQLite summaries\n",
            "codex-history-snapshots-dev.db": "E31 raw non-SQLite history\n",
        ]
        for (name, contents) in databaseContents {
            let database = sqliteRoot.appendingPathComponent(name)
            try Data(contents.utf8).write(to: database)
            XCTAssertEqual(chmod(database.path, 0o600), 0)
            if includeSidecars {
                for suffix in ["-wal", "-shm", "-journal"] {
                    let sidecar = URL(fileURLWithPath: database.path + suffix)
                    try Data("\(name)\(suffix) raw bytes".utf8).write(to: sidecar)
                    XCTAssertEqual(chmod(sidecar.path, 0o600), 0)
                }
            }
        }
        let configuration = CodexGhostRepairOperationalGateConfiguration(
            codexHomeURL: codexHome,
            backupVolumeProbeURL: parent,
            fixedCapacityHeadroomBytes: 0
        )
        return Fixture(
            parent: parent,
            codexHome: codexHome,
            sqliteRoot: sqliteRoot,
            configuration: configuration
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
}
#endif
