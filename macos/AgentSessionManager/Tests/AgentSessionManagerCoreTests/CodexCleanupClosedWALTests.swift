@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class CodexCleanupClosedWALTests: XCTestCase {
    func testClosedWALAuthorityReadPreservesSourceAndAllowsMaintenanceWindow() async throws {
        try await checkClosedWAL(preserveSidecars: false)
    }

    func testClosedPersistentWALAuthorityReadPreservesSourceAndAllowsMaintenanceWindow() async throws {
        try await checkClosedWAL(preserveSidecars: true)
    }

    func testClosedWALFullCleanupAndColdReadback() async throws {
        try await checkFullCleanup(preserveSidecars: false)
    }

    func testClosedPersistentWALFullCleanupAndColdReadback() async throws {
        try await checkFullCleanup(preserveSidecars: true)
    }

    func testClosedWALSummaryCleanupPreservesUnselectedRows() async throws {
        try await checkFullCleanup(preserveSidecars: false, reviewedResidue: true)
    }

    func testPersistentWALSummaryCleanupPreservesUnselectedRows() async throws {
        try await checkFullCleanup(preserveSidecars: true, reviewedResidue: true)
    }

    func testRealtimeProfileReviewedCleanupBacksUpAndPreservesPausedSchedule() async throws {
        try await checkFullCleanup(preserveSidecars: false, reviewedResidue: true,
                                   profile: .v166DesktopV34Realtime, runtime: "0.164.0")
    }

    func testProductionCleanupLeavesDevelopmentCatalogUntouchedWhenSummariesDoNotExist() async throws {
        try await checkFullCleanup(preserveSidecars: false, profile: .v166Production, runtime: "0.164.0", omitSummaries: true)
    }

    func testProductionCleanupReadsAndBacksUpItsOwnSummaries() async throws {
        try await checkFullCleanup(preserveSidecars: true, reviewedResidue: true, profile: .v166Production, runtime: "0.164.0")
    }

    private func checkFullCleanup(preserveSidecars: Bool, reviewedResidue: Bool = false,
                                  profile: CodexGhostRepairSnapshotSourceProfile = .v156DesktopV34Extended,
                                  runtime: String = "0.157.1", omitSummaries: Bool = false) async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, desktopSchema: 34,
            profile: profile, runtimeVersion: runtime, reviewedResidue: reviewedResidue, omitProductionSummaries: omitSummaries)
        defer { trashFixture(fixture.parent) }
        let repairResolution = try fixture.bundle.resolveForPreflight(profile: profile)
        let development = fixture.codexHome.appendingPathComponent("sqlite/codex-dev.db")
        if profile == .v166Production {
            try BulkShippingCompositionTestFixture.createExtendedDesktop(at: development, itemCount: 2)
            XCTAssertEqual(try CodexGhostRepairInstalledSourceProfileReader.read(exactRuntimeVersion: runtime, databaseURL: fixture.desktopURL), .v166Production)
        }
        let otherCatalogBefore = profile == .v166Production ? try Data(contentsOf: development) : nil
        for database in [CodexGhostRepairProductionRepairDatabase.desktop, .summaries, .state, .threadHistory] where !omitSummaries || database != .summaries {
            try closeWAL(at: repairResolution.databaseURL(for: database), preserveSidecars: preserveSidecars)
        }
        let managerRoot = fixture.parent.appendingPathComponent("manager", isDirectory: true)
        try FileManager.default.createDirectory(at: managerRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let marker = managerRoot.appendingPathComponent(CodexGhostRepairBulkFixedBackupDestinationTestInspector.markerFileName)
        try Data(CodexGhostRepairBulkFixedBackupDestinationTestInspector.markerContents.utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        try FileManager.default.createDirectory(at: managerRoot.appendingPathComponent(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector.ghostRepairDirectoryName),
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let environment = try CodexGhostRepairBulkLiveBackupEnvironment(
            testOwnedCodexHomeURL: fixture.codexHome, testOwnedSourceAllowedParentURL: fixture.parent,
            testOwnedManagerRootURL: managerRoot, testOwnedManagerAllowedParentURL: fixture.parent,
            profile: profile, nowMilliseconds: { 1_400 })
        let source = fixture.source
        let preparer = CodexGhostRepairBulkPackagedPlanPreparer(
            storeProvider: { try SQLiteStateStore(databaseURL: fixture.managerStateURL) },
            resolutionProvider: { preview in
                let resolution = try CodexGhostRepairBulkProductionBundle(coldReadback: preview,
                    testOwnedCodexHomeURL: fixture.codexHome, testOwnedAllowedParentURL: fixture.parent)
                    .resolveForTestOwnedAdoption()
                return (resolution, profile)
            },
            maintenanceObserverProvider: { profile in
                CodexGhostRepairBulkProductionMaintenanceObserver(profile: profile,
                    gateSource: ClosedWALGate(), fingerprintReader: { try source.fingerprint() },
                    authorityReader: { try CodexGhostRepairBulkProductionMaintenanceObserver.readAuthority(
                        source: source, resolution: $0) }, sourceAdmission: { _ in true },
                    nowMilliseconds: { 1_350 })
            },
            backupTransportProvider: { resolution, window in
                try CodexGhostRepairBulkLiveBackupTransport(resolution: resolution,
                    maintenanceWindow: window, environment: environment)
            },
            targetRevalidatorProvider: { _ in
                try CodexGhostRepairBulkLiveTargetRevalidator(repairResolution: repairResolution,
                    gateSource: ClosedWALGate(), fingerprintReader: { try source.fingerprint() },
                    nowMilliseconds: { 1_500 })
            })
        let prepared = try await preparer.prepare(confirmationReceiptID: fixture.confirmationReceipt.receiptID)
        let journal = CodexGhostRepairBulkLivePackagedExecutionJournal {
            try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        }
        func makeMutator() -> CodexGhostRepairBulkLiveMixedMutator {
            .init(testOwnedCodexHomeURL: fixture.codexHome, testOwnedAllowedParentURL: fixture.parent,
                profile: profile, gateSource: ClosedWALGate(), backupReader: FixedBulkLiveBackupReadback(
                    value: prepared.plan.backup, fails: false))
        }
        let runner = CodexGhostRepairBulkLiveOneShotCoordinator(journal: journal, mutator: makeMutator(),
            nowMilliseconds: { 1_600 }, makeUUID: { UUID() })
        _ = try await runner.prepare(plan: prepared.plan, confirmationReceipt: prepared.receipt)
        let report = try await runner.execute(requestID: prepared.plan.requestID,
            expectedPlanDigest: prepared.plan.planDigest)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.count, 2)
        try CodexGhostRepairProductionSQLite.withReadOnly(at: fixture.desktopURL) { desktop in
            if reviewedResidue {
                XCTAssertEqual(try desktop.query("SELECT status FROM automations WHERE id = 'automation-1'", maximumRows: 1)
                    .first?.value(named: "status"), .text("PAUSED"))
                XCTAssertEqual(try desktop.query("SELECT status FROM automation_runs WHERE automation_id = 'automation-1'", maximumRows: 1)
                    .first?.value(named: "status"), .text("ARCHIVED"))
            }
            XCTAssertEqual(try desktop.query("SELECT count(*) AS count FROM local_thread_catalog WHERE host_id = 'local'", maximumRows: 1)
                .first?.value(named: "count"), .integer(0))
            XCTAssertEqual(try desktop.query("SELECT count(*) AS count FROM local_thread_catalog WHERE host_id = 'remote'", maximumRows: 1)
                .first?.value(named: "count"), .integer(1))
            XCTAssertEqual(try desktop.query("SELECT catalog_revision FROM local_thread_catalog_metadata", maximumRows: 1)
                .first?.value(named: "catalog_revision"), .integer(1002))
        }
        if let otherCatalogBefore {
            XCTAssertEqual(try Data(contentsOf: development), otherCatalogBefore)
            XCTAssertTrue(prepared.plan.backup.files.contains { $0.fileName == "codex.db" && $0.present })
            XCTAssertFalse(prepared.plan.backup.files.contains { $0.fileName == "codex-dev.db" })
            XCTAssertEqual(prepared.plan.backup.files.first { $0.fileName == "codex-thread-summaries.db" }?.present, !omitSummaries)
        }
        if omitSummaries {
            XCTAssertTrue(try CodexGhostRepairSnapshotCanonicalFile.productionSummariesAbsent(at: repairResolution.databaseURL(for: .summaries)))
        } else {
            try CodexGhostRepairProductionSQLite.withReadOnly(at: repairResolution.databaseURL(for: .summaries)) { summaries in
                XCTAssertEqual(try summaries.query("SELECT count(*) AS count FROM thread_turn_summaries", maximumRows: 1)
                    .first?.value(named: "count"), .integer(reviewedResidue ? 1 : 0))
            }
        }
        // A fresh coordinator must read the completed journal without replaying cleanup.
        let cold = CodexGhostRepairBulkLiveOneShotCoordinator(journal: journal, mutator: makeMutator(),
            nowMilliseconds: { 1_700 }, makeUUID: { UUID() })
        let coldReport = try await cold.execute(requestID: prepared.plan.requestID,
            expectedPlanDigest: prepared.plan.planDigest)
        XCTAssertEqual(coldReport, report)
    }

    private func closeWAL(at url: URL, preserveSidecars: Bool) throws {
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode = WAL; PRAGMA application_id = 0;", nil, nil, nil), SQLITE_OK)
        var enabled: Int32 = preserveSidecars ? 1 : 0
        XCTAssertEqual(sqlite3_file_control(writer, "main", SQLITE_FCNTL_PERSIST_WAL, &enabled), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        // Changing journal mode alone does not create a WAL. The header write
        // above forces one, so these cases exercise genuinely different files.
        XCTAssertEqual(FileManager.default.fileExists(atPath: url.path + "-wal"), preserveSidecars)
        XCTAssertEqual(FileManager.default.fileExists(atPath: url.path + "-shm"), preserveSidecars)
    }

    private func trashFixture(_ url: URL) {
        do { _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        catch { XCTFail("Synthetic fixture could not be moved to Trash: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReadOnlyInspectionIncludesExistingUncheckpointedWAL() throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        defer { trashFixture(fixture.parent) }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.desktopURL.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer,
            "PRAGMA journal_mode=WAL; UPDATE local_thread_catalog_metadata SET catalog_revision=1007;",
            nil, nil, nil), SQLITE_OK)
        try CodexGhostRepairProductionSQLite.withReadOnly(at: fixture.desktopURL) { database in
            XCTAssertEqual(try database.query("SELECT catalog_revision FROM local_thread_catalog_metadata", maximumRows: 1)
                .first?.value(named: "catalog_revision"), .integer(1007))
        }
    }

    func testSingleFileInspectionCannotBypassAnExistingSQLiteTransaction() throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        defer { trashFixture(fixture.parent) }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.desktopURL.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try CodexGhostRepairProductionSQLite.withReadOnly(at: fixture.desktopURL) { _ in
            XCTFail("An existing transaction must prevent single-file inspection")
        })
        var contender: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.desktopURL.path, &contender), SQLITE_OK)
        defer { sqlite3_close(contender) }
        XCTAssertEqual(sqlite3_exec(contender, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_BUSY,
            "A failed read must not release another connection's lock")
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
    }

    private func checkClosedWAL(preserveSidecars: Bool) async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, desktopSchema: 34,
            profile: .v156DesktopV34Extended, runtimeVersion: "0.157.1")
        defer { trashFixture(fixture.parent) }
        try closeWAL(at: fixture.desktopURL, preserveSidecars: preserveSidecars)
        let before = try fixture.source.fingerprint()
        let observer = CodexGhostRepairBulkProductionMaintenanceObserver(
            profile: .v156DesktopV34Extended,
            gateSource: ClosedWALGate(),
            fingerprintReader: { try fixture.source.fingerprint() },
            authorityReader: { resolution in
                try CodexGhostRepairBulkProductionMaintenanceObserver.readAuthority(
                    source: fixture.source, resolution: resolution)
            }, sourceAdmission: { _ in true }, nowMilliseconds: { 1_350 })
        let collector = try CodexGhostRepairBulkFreshMaintenanceCollector(
            resolution: fixture.bulkResolution, observer: observer)
        let first = try await collector.collectFresh(phase: .beforeBackup)
        let second = try await collector.collectFresh(phase: .beforeBackupRepeat)
        let after = try fixture.source.fingerprint()
        XCTAssertEqual(before.fingerprintHash, after.fingerprintHash,
                       "Read-only checks must not create source WAL/SHM files after Codex exits.")
        _ = try CodexGhostRepairBulkMaintenanceWindow(before: first, after: second)
    }
}

private struct ClosedWALGate: CodexGhostRepairExecutionGateSource {
    func ghostRepairExecutionGate() async throws -> CodexGhostRepairExecutionGate {
        .init(codexFullyExited: true, desktopOpenHandleCount: 0, summariesOpenHandleCount: 0,
              historyOpenHandleCount: 0, stateOpenHandleCount: 0, threadHistoryOpenHandleCount: 0,
              capacitySufficient: true, desktopProcessEvidence: [], openHandleOwnerEvidence: [])
    }
}
