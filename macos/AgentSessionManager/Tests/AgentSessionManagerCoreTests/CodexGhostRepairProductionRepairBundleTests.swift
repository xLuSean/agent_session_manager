@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairProductionRepairBundleTests: XCTestCase {
    func testProductionConstructionIsPathFreeZeroIOAndAuthorityFree() {
        let bundle = CodexGhostRepairProductionRepairBundle.production()

        XCTAssertEqual(
            bundle.capabilities.sourceLayoutIdentifier,
            "codex-cli-0.149.0-paginated-v1"
        )
        XCTAssertFalse(bundle.capabilities.acceptsCallerPath)
        XCTAssertFalse(bundle.capabilities.constructionPerformsIO)
        XCTAssertFalse(bundle.capabilities.opensFilesystem)
        XCTAssertFalse(bundle.capabilities.opensSQLite)
        XCTAssertFalse(bundle.capabilities.createsBackup)
        XCTAssertFalse(bundle.capabilities.createsClaim)
        XCTAssertFalse(bundle.capabilities.writesCodexDatabaseFiles)
        XCTAssertFalse(bundle.capabilities.repairMutationAuthority)
        XCTAssertEqual(bundle.capabilities.maximumTargetCount, 2)
        XCTAssertTrue(bundle.capabilities.categoryAOnly)
    }

    func testExplicitResolutionDerivesExactFiveDatabaseLayoutWithoutIO()
        throws
    {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = parent.appendingPathComponent(
            "nonexistent-codex-home",
            isDirectory: true
        )
        let bundle = CodexGhostRepairProductionRepairBundle(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: parent
        )

        let resolution = try bundle.resolveForPreflight()

        XCTAssertEqual(resolution.codexHomeURL, codexHome.standardizedFileURL)
        XCTAssertEqual(
            resolution.sqliteRootURL,
            codexHome.appendingPathComponent("sqlite", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertEqual(
            CodexGhostRepairProductionRepairDatabase.allCases.map {
                resolution.databaseURL(for: $0).lastPathComponent
            },
            [
                "codex-dev.db",
                "codex-thread-summaries-dev.db",
                "state_5.sqlite",
                "thread_history_1.sqlite",
                "codex-history-snapshots-dev.db",
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testOnlyDesktopIsInFutureTransactionFootprint() {
        let databases = CodexGhostRepairProductionRepairDatabase.allCases

        XCTAssertEqual(databases.count, 5)
        XCTAssertEqual(databases.filter(\.isRequired).count, 4)
        XCTAssertEqual(
            databases.filter {
                $0.role == .futureSingleTransactionMutation
            },
            [.desktop]
        )
        XCTAssertEqual(
            databases.filter { $0.role == .validationReadbackOnly }.count,
            4
        )
        XCTAssertFalse(
            CodexGhostRepairProductionRepairDatabase.legacyHistory.isRequired
        )
    }

    func testTestResolutionRejectsRootOutsideAllowedParent() {
        let allowed = URL(fileURLWithPath: "/tmp/m3a-allowed", isDirectory: true)
        let escaped = URL(fileURLWithPath: "/tmp/m3a-escaped", isDirectory: true)
        let bundle = CodexGhostRepairProductionRepairBundle(
            testOwnedCodexHomeURL: escaped,
            testOwnedAllowedParentURL: allowed
        )

        XCTAssertThrowsError(try bundle.resolveForPreflight()) { error in
            guard case .invalidProtectionEvidence =
                    error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }

    func testTestResolutionRejectsLiveCodexHome() {
        let liveCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let bundle = CodexGhostRepairProductionRepairBundle(
            testOwnedCodexHomeURL: liveCodexHome,
            testOwnedAllowedParentURL: liveCodexHome.deletingLastPathComponent()
        )

        XCTAssertThrowsError(try bundle.resolveForPreflight()) { error in
            guard case .invalidProtectionEvidence =
                    error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidProtectionEvidence, found \(error)")
            }
        }
    }
}
