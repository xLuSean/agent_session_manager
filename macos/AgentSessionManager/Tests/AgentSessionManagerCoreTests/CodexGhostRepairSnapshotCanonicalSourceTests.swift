@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairSnapshotCanonicalSourceTests: XCTestCase {
    func testProductionConstructionIsPathFreeZeroIOAndReadOnly() {
        let source = CodexGhostRepairSnapshotCanonicalSource.production()

        XCTAssertTrue(source.capabilities.readsFixedRawDatabaseFiles)
        XCTAssertFalse(source.capabilities.writesCodexDatabaseFiles)
        XCTAssertFalse(source.capabilities.acceptsCallerPath)
        XCTAssertFalse(source.capabilities.usesSQLiteAPI)
        XCTAssertFalse(source.capabilities.repairMutationAuthority)
    }

    func testFingerprintCoversFixedV0149FilesWithoutChangingSource() throws {
        let fixture = try makeFixture(
            label: #function,
            includeSidecars: true
        )
        let source = fixture.source
        let before = try fixedFileReadback(fixture)

        let fingerprint = try source.fingerprint()

        try fingerprint.validateHash()
        XCTAssertTrue(fingerprint.sourceRootDigest.hasPrefix("sha256:"))
        XCTAssertTrue(fingerprint.fingerprintHash.hasPrefix("sha256:"))
        XCTAssertEqual(fingerprint.sourceLayoutIdentifier, "codex-cli-0.149.0-paginated-v1")
        XCTAssertEqual(fingerprint.files.count, 20)
        XCTAssertTrue(fingerprint.files.allSatisfy(\.exists))
        XCTAssertEqual(
            fingerprint.files.map(\.fileName),
            CodexGhostRepairSnapshotCanonicalFile.allCases.map(\.rawValue)
        )
        XCTAssertEqual(try fixedFileReadback(fixture), before)
    }

    func testOptionalSidecarsRemainExplicitlyAbsent() throws {
        let fixture = try makeFixture(label: #function)

        let fingerprint = try fixture.source.fingerprint()

        XCTAssertEqual(fingerprint.files.filter(\.exists).count, 4)
        XCTAssertEqual(fingerprint.files.filter { !$0.exists }.count, 16)
        XCTAssertTrue(
            fingerprint.files.filter { !$0.exists }.allSatisfy {
                $0.device == nil && $0.inode == nil && $0.sha256 == nil
            }
        )
    }

    func testV151ProfileUsesSameFixedMembersButDistinctFrozenIdentity() throws {
        let v149 = try makeFixture(label: #function + "-v149")
        let v151 = try makeFixture(
            label: #function + "-v151",
            profile: .v151DesktopV33
        )

        let v149Fingerprint = try v149.source.fingerprint()
        let v151Fingerprint = try v151.source.fingerprint()

        XCTAssertEqual(
            v149Fingerprint.files.map(\.fileName),
            v151Fingerprint.files.map(\.fileName)
        )
        XCTAssertEqual(
            v149.source.profile.databaseSchemaProfileIdentifier,
            "desktop-v32"
        )
        XCTAssertEqual(
            v151.source.profile.databaseSchemaProfileIdentifier,
            "desktop-v33"
        )
        XCTAssertNotEqual(
            v149.source.profile.ownerRuntimeProfileIdentifier,
            v151.source.profile.ownerRuntimeProfileIdentifier
        )
        XCTAssertNotEqual(
            v149.source.profile.layoutDigest,
            v151.source.profile.layoutDigest
        )
        XCTAssertNotEqual(
            v149Fingerprint.sourceLayoutIdentifier,
            v151Fingerprint.sourceLayoutIdentifier
        )
        XCTAssertNotEqual(
            v149Fingerprint.fingerprintHash,
            v151Fingerprint.fingerprintHash
        )
        try v149Fingerprint.validateHash()
        try v151Fingerprint.validateHash()
    }

    func testV152ProfileKeepsFixedMembersButHasIndependentV34Identity() throws {
        let v151 = try makeFixture(
            label: #function + "-v151",
            profile: .v151DesktopV33
        )
        let v152 = try makeFixture(
            label: #function + "-v152",
            profile: .v152DesktopV34
        )

        let v151Fingerprint = try v151.source.fingerprint()
        let v152Fingerprint = try v152.source.fingerprint()

        XCTAssertEqual(
            v151Fingerprint.files.map(\.fileName),
            v152Fingerprint.files.map(\.fileName)
        )
        XCTAssertEqual(
            v152.source.profile.databaseSchemaProfileIdentifier,
            "desktop-v34"
        )
        XCTAssertEqual(
            v152.source.profile.ownerRuntimeProfileIdentifier,
            "desktop-bundled-0.152.1"
        )
        XCTAssertNotEqual(v151.source.profile, v152.source.profile)
        XCTAssertNotEqual(
            v151Fingerprint.sourceLayoutIdentifier,
            v152Fingerprint.sourceLayoutIdentifier
        )
        XCTAssertNotEqual(
            v151Fingerprint.fingerprintHash,
            v152Fingerprint.fingerprintHash
        )
        try v152Fingerprint.validateHash()
    }

    func testV153ProfileKeepsFixedMembersButBindsCurrentDesktopOwner() throws {
        let v152 = try makeFixture(
            label: #function + "-v152",
            profile: .v152DesktopV34
        )
        let v153 = try makeFixture(
            label: #function + "-v153",
            profile: .v153DesktopV34
        )

        let v152Fingerprint = try v152.source.fingerprint()
        let v153Fingerprint = try v153.source.fingerprint()

        XCTAssertEqual(
            v152Fingerprint.files.map(\.fileName),
            v153Fingerprint.files.map(\.fileName)
        )
        XCTAssertEqual(
            v153.source.profile.databaseSchemaProfileIdentifier,
            "desktop-v34"
        )
        XCTAssertEqual(
            v153.source.profile.ownerRuntimeProfileIdentifier,
            "desktop-bundled-0.153.1"
        )
        XCTAssertNotEqual(v152.source.profile, v153.source.profile)
        XCTAssertNotEqual(
            v152Fingerprint.sourceLayoutIdentifier,
            v153Fingerprint.sourceLayoutIdentifier
        )
        XCTAssertNotEqual(
            v152Fingerprint.fingerprintHash,
            v153Fingerprint.fingerprintHash
        )
        try v153Fingerprint.validateHash()
    }

    func testV1534ProfileKeepsFixedMembersButHasIndependentExactOwner() throws {
        let historical = try makeFixture(
            label: #function + "-historical",
            profile: .v153DesktopV34
        )
        let current = try makeFixture(
            label: #function + "-current",
            profile: .v1534DesktopV34
        )

        let historicalFingerprint = try historical.source.fingerprint()
        let currentFingerprint = try current.source.fingerprint()

        XCTAssertEqual(
            historicalFingerprint.files.map(\.fileName),
            currentFingerprint.files.map(\.fileName)
        )
        XCTAssertEqual(
            current.source.profile.databaseSchemaProfileIdentifier,
            "desktop-v34"
        )
        XCTAssertEqual(
            current.source.profile.ownerRuntimeProfileIdentifier,
            "desktop-bundled-0.153.4"
        )
        XCTAssertNotEqual(historical.source.profile, current.source.profile)
        XCTAssertNotEqual(
            historicalFingerprint.sourceLayoutIdentifier,
            currentFingerprint.sourceLayoutIdentifier
        )
        XCTAssertNotEqual(
            historicalFingerprint.fingerprintHash,
            currentFingerprint.fingerprintHash
        )
        try currentFingerprint.validateHash()
    }

    func testMissingRequiredDatabaseFailsClosed() throws {
        let fixture = try makeFixture(
            label: #function,
            omittedRequired: .summaries
        )

        XCTAssertThrowsError(try fixture.source.fingerprint()) { error in
            guard case .invalidProtectionEvidence =
                    error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testSymlinkedFixedFileIsNeverFollowed() throws {
        let fixture = try makeFixture(
            label: #function,
            symlinkedRequired: .desktop
        )

        XCTAssertThrowsError(try fixture.source.fingerprint()) { error in
            guard case .invalidProtectionEvidence =
                    error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testGroupWritableFixedFileFailsClosed() throws {
        let fixture = try makeFixture(
            label: #function,
            groupWritableRequired: .threadHistory
        )

        XCTAssertThrowsError(try fixture.source.fingerprint()) { error in
            guard case .invalidProtectionEvidence =
                    error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testStreamRequiresFrozenEvidenceAndDetectsPathReplacement() throws {
        let fixture = try makeFixture(label: #function)
        let fingerprint = try fixture.source.fingerprint()
        let expected = try XCTUnwrap(
            fingerprint.files.first { $0.fileName == "codex-dev.db" }
        )
        var consumed = Data()

        XCTAssertThrowsError(
            try fixture.source.streamRawRead(
                .desktop,
                expected: expected,
                consume: { consumed.append($0) },
                afterOpenForTesting: {
                    try Data("replacement bytes\n".utf8).write(
                        to: fixture.sqliteRoot.appendingPathComponent(
                            "codex-dev.db"
                        ),
                        options: .atomic
                    )
                    guard chmod(
                        fixture.sqliteRoot.appendingPathComponent(
                            "codex-dev.db"
                        ).path,
                        0o600
                    ) == 0 else {
                        throw SnapshotCanonicalSourceTestError.chmodFailed
                    }
                }
            )
        ) { error in
            guard case .targetDrift = error as? CodexGhostRepairError else {
                return XCTFail("Expected targetDrift, found \(error)")
            }
        }
    }

    func testTestMirrorMarkerIsRequiredAtExplicitReadTime() throws {
        let fixture = try makeFixture(label: #function, includeMarker: false)

        XCTAssertThrowsError(try fixture.source.fingerprint()) { error in
            guard case .invalidProtectionEvidence =
                    error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    private struct Fixture {
        let parent: URL
        let codexHome: URL
        let sqliteRoot: URL
        let source: CodexGhostRepairSnapshotCanonicalSource
    }

    private struct FixedFileReadback: Equatable {
        let fileName: String
        let data: Data
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private func makeFixture(
        label: String,
        includeSidecars: Bool = false,
        includeMarker: Bool = true,
        omittedRequired: CodexGhostRepairSnapshotCanonicalFile? = nil,
        symlinkedRequired: CodexGhostRepairSnapshotCanonicalFile? = nil,
        groupWritableRequired: CodexGhostRepairSnapshotCanonicalFile? = nil,
        profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32
    ) throws -> Fixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-m1b2-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        let codexHome = parent.appendingPathComponent(".codex", isDirectory: true)
        let sqliteRoot = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sqliteRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(parent.path, 0o700) == 0,
              chmod(codexHome.path, 0o700) == 0,
              chmod(sqliteRoot.path, 0o700) == 0 else {
            throw SnapshotCanonicalSourceTestError.chmodFailed
        }
        if includeMarker {
            let marker = codexHome.appendingPathComponent(
                CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerFileName
            )
            try Data(
                CodexGhostRepairSnapshotCanonicalSource
                    .testMirrorMarkerContents.utf8
            ).write(to: marker)
            guard chmod(marker.path, 0o600) == 0 else {
                throw SnapshotCanonicalSourceTestError.chmodFailed
            }
        }

        for file in CodexGhostRepairSnapshotCanonicalFile.allCases {
            guard file != omittedRequired,
                  file.isRequiredDatabase || includeSidecars else { continue }
            let url = file.sourceURL(
                codexHomeURL: codexHome,
                sqliteRootURL: sqliteRoot
            )
            if file == symlinkedRequired {
                let target = parent.appendingPathComponent("symlink-target.db")
                try Data("target\n".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(
                    at: url,
                    withDestinationURL: target
                )
            } else {
                try Data("M1b-2 \(file.rawValue)\n".utf8).write(to: url)
                let permissions: mode_t = file == groupWritableRequired
                    ? 0o620
                    : 0o600
                guard chmod(url.path, permissions) == 0 else {
                    throw SnapshotCanonicalSourceTestError.chmodFailed
                }
            }
        }
        return Fixture(
            parent: parent,
            codexHome: codexHome,
            sqliteRoot: sqliteRoot,
            source: CodexGhostRepairSnapshotCanonicalSource(
                testOwnedCodexHomeURL: codexHome,
                testOwnedAllowedParentURL: parent,
                profile: profile
            )
        )
    }

    private func fixedFileReadback(_ fixture: Fixture) throws
        -> [FixedFileReadback]
    {
        try CodexGhostRepairSnapshotCanonicalFile.allCases.compactMap { file in
            let url = file.sourceURL(
                codexHomeURL: fixture.codexHome,
                sqliteRootURL: fixture.sqliteRoot
            )
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                if errno == ENOENT { return nil }
                throw SnapshotCanonicalSourceTestError.statFailed
            }
            return FixedFileReadback(
                fileName: file.rawValue,
                data: try Data(contentsOf: url),
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                mode: UInt32(status.st_mode),
                size: Int64(status.st_size),
                modificationSeconds: Int64(status.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
            )
        }
    }
}

private enum SnapshotCanonicalSourceTestError: Error {
    case chmodFailed
    case statFailed
}
