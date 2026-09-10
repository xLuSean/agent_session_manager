@testable import AgentSessionManagerCore
import CSQLite3
import Darwin
import Foundation
import XCTest

#if AGENT_SESSION_MANAGER_RESEARCH

final class CodexGhostRepairCategoryAProductionRecipeTests: XCTestCase {
    func testFreshCountersDriveExactOneAndTwoItemRecipe() async throws {
        for targets in targetSets {
            let fixture = try makeFixture(targets: targets)
            let store = try SQLiteStateStore(databaseURL: fixture.storeURL)
            try store.saveCodexGhostRepairCategoryAChallenge(fixture.challenge)
            let coordinator = CodexGhostRepairCategoryAProductionRecipeCoordinator(
                bundle: fixture.recipeBundle,
                journal: store,
                now: { Date(timeIntervalSince1970: 3) }
            )

            let report = try await coordinator.confirmAndExecute(
                draft: fixture.draft,
                review: fixture.review,
                confirmationToken: fixture.challenge.confirmationToken,
                freshEvidence: fixture.freshEvidence,
                confirmedAtMilliseconds: 2_300,
                snapshotAtMilliseconds: 2_500,
                executionAtMilliseconds: 2_600
            )

            XCTAssertEqual(report.outcome, .success)
            XCTAssertTrue(report.mutationAttemptedOnce)
            XCTAssertFalse(report.automaticRetryAllowed)
            XCTAssertEqual(try fixture.catalogCount(), 0)
            XCTAssertEqual(
                try fixture.catalogRevision(),
                fixture.freshAuthority.catalogRevision + Int64(targets.count)
            )
            XCTAssertEqual(
                try fixture.observationSequence(),
                fixture.freshAuthority.observationSequence
                    + Int64(targets.count)
            )
            XCTAssertNotEqual(
                fixture.draft.authorityAudit.catalogRevision,
                fixture.freshAuthority.catalogRevision
            )
            let snapshot = try fixture.recipeBundle.load(
                operationID: fixture.draft.operationID
            )
            XCTAssertEqual(
                snapshot.freshEvidenceDigest,
                fixture.freshEvidence.evidenceDigest
            )
            XCTAssertFalse(snapshot.restoreAuthority)
            XCTAssertFalse(snapshot.cleanupAuthority)
            XCTAssertFalse(snapshot.repairMutationAuthority)
            XCTAssertEqual(
                try store.codexGhostRepairCategoryAOperation(
                    operationID: fixture.draft.operationID
                )?.status,
                .terminal
            )
            store.close()
        }
    }

    func testAuthorizationInterruptionStopsWithoutSnapshotOrReplay()
        async throws
    {
        let fixture = try makeFixture(targets: [targetA, targetB])
        let store = try SQLiteStateStore(databaseURL: fixture.storeURL)
        try store.saveCodexGhostRepairCategoryAChallenge(fixture.challenge)
        let coordinator = CodexGhostRepairCategoryAProductionRecipeCoordinator(
            bundle: fixture.recipeBundle,
            journal: store
        )

        await XCTAssertThrowsM3fError {
            _ = try await coordinator.confirmAndExecute(
                draft: fixture.draft,
                review: fixture.review,
                confirmationToken: fixture.challenge.confirmationToken,
                freshEvidence: fixture.freshEvidence,
                confirmedAtMilliseconds: 2_300,
                snapshotAtMilliseconds: 2_500,
                executionAtMilliseconds: 2_600,
                fault: .afterAuthorization
            )
        }
        let report = try await coordinator.confirmAndExecute(
            draft: fixture.draft,
            review: fixture.review,
            confirmationToken: fixture.challenge.confirmationToken,
            freshEvidence: fixture.freshEvidence,
            confirmedAtMilliseconds: 2_300,
            snapshotAtMilliseconds: 2_500,
            executionAtMilliseconds: 2_700
        )

        XCTAssertEqual(report.outcome, .notAttempted)
        XCTAssertFalse(report.mutationAttemptedOnce)
        XCTAssertEqual(try fixture.catalogCount(), 2)
        XCTAssertThrowsError(
            try fixture.recipeBundle.load(
                operationID: fixture.draft.operationID
            )
        )
        store.close()
    }

    func testManagerClaimInterruptionRecoversByReadbackWithoutMutation()
        async throws
    {
        let fixture = try makeFixture(targets: [targetA])
        var store: SQLiteStateStore? = try SQLiteStateStore(
            databaseURL: fixture.storeURL
        )
        try store?.saveCodexGhostRepairCategoryAChallenge(fixture.challenge)
        var coordinator: CodexGhostRepairCategoryAProductionRecipeCoordinator? =
            .init(bundle: fixture.recipeBundle, journal: store!)

        await XCTAssertThrowsM3fError {
            _ = try await coordinator?.confirmAndExecute(
                draft: fixture.draft,
                review: fixture.review,
                confirmationToken: fixture.challenge.confirmationToken,
                freshEvidence: fixture.freshEvidence,
                confirmedAtMilliseconds: 2_300,
                snapshotAtMilliseconds: 2_500,
                executionAtMilliseconds: 2_600,
                fault: .afterManagerClaim
            )
        }
        coordinator = nil
        store?.close()
        store = try SQLiteStateStore(databaseURL: fixture.storeURL)
        coordinator = .init(bundle: fixture.recipeBundle, journal: store!)

        let report = try await coordinator?.confirmAndExecute(
            draft: fixture.draft,
            review: fixture.review,
            confirmationToken: fixture.challenge.confirmationToken,
            freshEvidence: fixture.freshEvidence,
            confirmedAtMilliseconds: 2_300,
            snapshotAtMilliseconds: 2_500,
            executionAtMilliseconds: 2_700
        )

        XCTAssertEqual(report?.outcome, .notAttempted)
        XCTAssertFalse(report?.mutationAttemptedOnce ?? true)
        XCTAssertEqual(try fixture.catalogCount(), 1)
        XCTAssertEqual(
            try store?.codexGhostRepairCategoryAOperation(
                operationID: fixture.draft.operationID
            )?.status,
            .terminal
        )
        store?.close()
    }

    func testCommitInterruptionRecoversSuccessAndNeverReplays()
        async throws
    {
        let fixture = try makeFixture(targets: [targetA, targetB])
        var store: SQLiteStateStore? = try SQLiteStateStore(
            databaseURL: fixture.storeURL
        )
        try store?.saveCodexGhostRepairCategoryAChallenge(fixture.challenge)
        var coordinator: CodexGhostRepairCategoryAProductionRecipeCoordinator? =
            .init(bundle: fixture.recipeBundle, journal: store!)

        await XCTAssertThrowsM3fError {
            _ = try await coordinator?.confirmAndExecute(
                draft: fixture.draft,
                review: fixture.review,
                confirmationToken: fixture.challenge.confirmationToken,
                freshEvidence: fixture.freshEvidence,
                confirmedAtMilliseconds: 2_300,
                snapshotAtMilliseconds: 2_500,
                executionAtMilliseconds: 2_600,
                fault: .disposableAfterCommit
            )
        }
        coordinator = nil
        store?.close()
        store = try SQLiteStateStore(databaseURL: fixture.storeURL)
        coordinator = .init(bundle: fixture.recipeBundle, journal: store!)

        let recovered = try await coordinator?.confirmAndExecute(
            draft: fixture.draft,
            review: fixture.review,
            confirmationToken: fixture.challenge.confirmationToken,
            freshEvidence: fixture.freshEvidence,
            confirmedAtMilliseconds: 2_300,
            snapshotAtMilliseconds: 2_500,
            executionAtMilliseconds: 2_700
        )
        let duplicate = try await coordinator?.confirmAndExecute(
            draft: fixture.draft,
            review: fixture.review,
            confirmationToken: fixture.challenge.confirmationToken,
            freshEvidence: fixture.freshEvidence,
            confirmedAtMilliseconds: 2_300,
            snapshotAtMilliseconds: 2_500,
            executionAtMilliseconds: 2_800
        )

        XCTAssertEqual(recovered?.outcome, .success)
        XCTAssertEqual(duplicate, recovered)
        XCTAssertEqual(try fixture.catalogCount(), 0)
        XCTAssertEqual(
            try fixture.catalogRevision(),
            fixture.freshAuthority.catalogRevision + 2
        )
        store?.close()
    }

    func testFreshEvidenceDriftFailsWholeSetBeforeSnapshot() async throws {
        let fixture = try makeFixture(targets: [targetA, targetB])
        let store = try SQLiteStateStore(databaseURL: fixture.storeURL)
        try store.saveCodexGhostRepairCategoryAChallenge(fixture.challenge)
        let coordinator = CodexGhostRepairCategoryAProductionRecipeCoordinator(
            bundle: fixture.recipeBundle,
            journal: store
        )
        let wrongAuthority = CodexGhostRepairSnapshotAnalysisAuthorityEvidence(
            catalogRevision: 999,
            observationSequence: 999,
            watermarkUpdatedAt: 999,
            metadataRowDigest: digest("9"),
            localSyncRowDigest: digest("8")
        )
        let drifted = try M3eCategoryATestFixture().freshEvidence(
            draft: fixture.draft,
            review: fixture.review,
            freshAuthority: wrongAuthority
        )

        let report = try await coordinator.confirmAndExecute(
            draft: fixture.draft,
            review: fixture.review,
            confirmationToken: fixture.challenge.confirmationToken,
            freshEvidence: drifted,
            confirmedAtMilliseconds: 2_300,
            snapshotAtMilliseconds: 2_500,
            executionAtMilliseconds: 2_600
        )

        XCTAssertEqual(report.outcome, .notAttempted)
        XCTAssertEqual(try fixture.catalogCount(), 2)
        XCTAssertThrowsError(
            try fixture.recipeBundle.load(
                operationID: fixture.draft.operationID
            )
        )
        store.close()
    }

    func testSnapshotInterruptionConsumesAuthorizationAndNeverExecutes()
        async throws
    {
        let fixture = try makeFixture(targets: [targetA])
        let store = try SQLiteStateStore(databaseURL: fixture.storeURL)
        try store.saveCodexGhostRepairCategoryAChallenge(fixture.challenge)
        let coordinator = CodexGhostRepairCategoryAProductionRecipeCoordinator(
            bundle: fixture.recipeBundle,
            journal: store
        )
        await XCTAssertThrowsM3fError {
            _ = try await coordinator.confirmAndExecute(
                draft: fixture.draft,
                review: fixture.review,
                confirmationToken: fixture.challenge.confirmationToken,
                freshEvidence: fixture.freshEvidence,
                confirmedAtMilliseconds: 2_300,
                snapshotAtMilliseconds: 2_500,
                executionAtMilliseconds: 2_600,
                fault: .afterSnapshot
            )
        }
        XCTAssertNoThrow(
            try fixture.recipeBundle.load(
                operationID: fixture.draft.operationID
            )
        )

        let report = try await coordinator.confirmAndExecute(
            draft: fixture.draft,
            review: fixture.review,
            confirmationToken: fixture.challenge.confirmationToken,
            freshEvidence: fixture.freshEvidence,
            confirmedAtMilliseconds: 2_300,
            snapshotAtMilliseconds: 2_500,
            executionAtMilliseconds: 2_700
        )
        XCTAssertEqual(report.outcome, .notAttempted)
        XCTAssertFalse(report.mutationAttemptedOnce)
        XCTAssertEqual(try fixture.catalogCount(), 1)
        store.close()
    }

    func testDisposableBusyPersistsExplicitFailureWithoutRetry()
        async throws
    {
        let fixture = try makeFixture(targets: [targetA])
        let store = try SQLiteStateStore(databaseURL: fixture.storeURL)
        try store.saveCodexGhostRepairCategoryAChallenge(fixture.challenge)
        let coordinator = CodexGhostRepairCategoryAProductionRecipeCoordinator(
            bundle: fixture.recipeBundle,
            journal: store
        )
        let report = try await coordinator.confirmAndExecute(
            draft: fixture.draft,
            review: fixture.review,
            confirmationToken: fixture.challenge.confirmationToken,
            freshEvidence: fixture.freshEvidence,
            confirmedAtMilliseconds: 2_300,
            snapshotAtMilliseconds: 2_500,
            executionAtMilliseconds: 2_600,
            fault: .disposableBusy
        )
        let duplicate = try await coordinator.confirmAndExecute(
            draft: fixture.draft,
            review: fixture.review,
            confirmationToken: fixture.challenge.confirmationToken,
            freshEvidence: fixture.freshEvidence,
            confirmedAtMilliseconds: 2_300,
            snapshotAtMilliseconds: 2_500,
            executionAtMilliseconds: 2_700
        )

        XCTAssertEqual(report.outcome, .explicitFailure)
        XCTAssertTrue(report.mutationAttemptedOnce)
        XCTAssertEqual(duplicate, report)
        XCTAssertEqual(try fixture.catalogCount(), 1)
        store.close()
    }

    func testClaimedUnexpectedReadbackIsUnknownAndNeverRetried()
        async throws
    {
        let fixture = try makeFixture(targets: [targetA, targetB])
        var store: SQLiteStateStore? = try SQLiteStateStore(
            databaseURL: fixture.storeURL
        )
        try store?.saveCodexGhostRepairCategoryAChallenge(fixture.challenge)
        var coordinator: CodexGhostRepairCategoryAProductionRecipeCoordinator? =
            .init(bundle: fixture.recipeBundle, journal: store!)
        await XCTAssertThrowsM3fError {
            _ = try await coordinator?.confirmAndExecute(
                draft: fixture.draft,
                review: fixture.review,
                confirmationToken: fixture.challenge.confirmationToken,
                freshEvidence: fixture.freshEvidence,
                confirmedAtMilliseconds: 2_300,
                snapshotAtMilliseconds: 2_500,
                executionAtMilliseconds: 2_600,
                fault: .afterManagerClaim
            )
        }
        try fixture.markTargetDrifted(targetB)
        coordinator = nil
        store?.close()
        store = try SQLiteStateStore(databaseURL: fixture.storeURL)
        coordinator = .init(bundle: fixture.recipeBundle, journal: store!)

        let report = try await coordinator?.confirmAndExecute(
            draft: fixture.draft,
            review: fixture.review,
            confirmationToken: fixture.challenge.confirmationToken,
            freshEvidence: fixture.freshEvidence,
            confirmedAtMilliseconds: 2_300,
            snapshotAtMilliseconds: 2_500,
            executionAtMilliseconds: 2_700
        )
        let duplicate = try await coordinator?.confirmAndExecute(
            draft: fixture.draft,
            review: fixture.review,
            confirmationToken: fixture.challenge.confirmationToken,
            freshEvidence: fixture.freshEvidence,
            confirmedAtMilliseconds: 2_300,
            snapshotAtMilliseconds: 2_500,
            executionAtMilliseconds: 2_800
        )

        XCTAssertEqual(report?.outcome, .unknown)
        XCTAssertFalse(report?.mutationAttemptedOnce ?? true)
        XCTAssertEqual(duplicate, report)
        XCTAssertEqual(try fixture.catalogCount(), 2)
        store?.close()
    }

    func testCapabilitiesKeepLiveAndAppAuthorityUnavailable() throws {
        let capabilities =
            CodexGhostRepairCategoryAProductionRecipeCoordinator.capabilities
        XCTAssertTrue(capabilities.markerProtectedTestMirrorsOnly)
        XCTAssertTrue(capabilities.operationBoundExecutionSnapshot)
        XCTAssertTrue(capabilities.freshAuthorityReplacesPreviewCounters)
        XCTAssertTrue(capabilities.managerClaimBeforeMutation)
        XCTAssertEqual(capabilities.desktopOnlyWriteDatabaseCount, 1)
        XCTAssertEqual(capabilities.readbackOnlyDatabaseCount, 4)
        XCTAssertFalse(capabilities.recoveryReplaysMutation)
        XCTAssertFalse(capabilities.acceptsLiveCodexRoot)
        XCTAssertFalse(capabilities.appWiringAvailable)
        XCTAssertFalse(capabilities.packagedRepairAuthority)
    }

    private let targetA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let targetB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"
    private var targetSets: [[String]] { [[targetA], [targetA, targetB]] }

    private struct Fixture {
        let root: URL
        let desktopURL: URL
        let storeURL: URL
        let recipeBundle: CodexGhostRepairCategoryAProductionRecipeBundle
        let draft: CodexGhostRepairCategoryAExecutionDraft
        let review: CodexGhostRepairCategoryAExecutionReviewEvidence
        let challenge: CodexGhostRepairCategoryAConfirmationChallenge
        let freshEvidence: CodexGhostRepairCategoryAFreshExecutionEvidence
        let freshAuthority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence

        func catalogCount() throws -> Int64 {
            try scalar("SELECT count(*) FROM local_thread_catalog")
        }

        func catalogRevision() throws -> Int64 {
            try scalar(
                "SELECT catalog_revision FROM local_thread_catalog_metadata "
                    + "WHERE id = 1"
            )
        }

        func observationSequence() throws -> Int64 {
            try scalar(
                "SELECT observation_sequence "
                    + "FROM local_thread_catalog_sync_state "
                    + "WHERE host_id = 'local'"
            )
        }

        func markTargetDrifted(_ threadID: String) throws {
            var database: OpaquePointer?
            guard sqlite3_open(desktopURL.path, &database) == SQLITE_OK,
                  let database else { throw TestError.sqlite }
            defer { sqlite3_close_v2(database) }
            var message: UnsafeMutablePointer<CChar>?
            let sql = "UPDATE local_thread_catalog "
                + "SET missing_candidate = 1 WHERE thread_id = '\(threadID)'"
            let result = sqlite3_exec(database, sql, nil, nil, &message)
            if let message { sqlite3_free(message) }
            guard result == SQLITE_OK, sqlite3_changes(database) == 1 else {
                throw TestError.sqlite
            }
        }

        private func scalar(_ sql: String) throws -> Int64 {
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                desktopURL.path,
                &database,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK, let database else {
                throw TestError.sqlite
            }
            defer { sqlite3_close_v2(database) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                    == SQLITE_OK,
                  let statement else {
                throw TestError.sqlite
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw TestError.sqlite
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func makeFixture(targets: [String]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-m3f-\(UUID().uuidString)",
            isDirectory: true
        )
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sqliteRoot = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        let executionEvidence = codexHome.appendingPathComponent(
            CodexGhostRepairCategoryADisposableBundle.evidenceDirectoryName,
            isDirectory: true
        )
        let managerRoot = root.appendingPathComponent("manager", isDirectory: true)
        let snapshotRoot = managerRoot.appendingPathComponent(
            CodexGhostRepairCategoryAProductionRecipeBundle.snapshotDirectoryName,
            isDirectory: true
        )
        for directory in [root, codexHome, sqliteRoot, executionEvidence,
                          managerRoot, snapshotRoot] {
            try makeDirectory(directory)
        }
        try Data(CodexGhostRepairCategoryADisposableBundle.markerContents.utf8)
            .write(to: codexHome.appendingPathComponent(
                CodexGhostRepairCategoryADisposableBundle.markerFileName
            ))
        try Data(CodexGhostRepairCategoryAProductionRecipeBundle.markerContents.utf8)
            .write(to: managerRoot.appendingPathComponent(
                CodexGhostRepairCategoryAProductionRecipeBundle.markerFileName
            ))

        let desktop = sqliteRoot.appendingPathComponent("codex-dev.db")
        let summaries = sqliteRoot.appendingPathComponent(
            "codex-thread-summaries-dev.db"
        )
        let legacy = sqliteRoot.appendingPathComponent(
            "codex-history-snapshots-dev.db"
        )
        let state = codexHome.appendingPathComponent("state_5.sqlite")
        let history = codexHome.appendingPathComponent("thread_history_1.sqlite")
        try createDesktopDatabase(at: desktop, targets: targets)
        try createSentinelDatabase(at: summaries, schemaVersion: 2)
        try createSentinelDatabase(at: state, schemaVersion: 0)
        try createSentinelDatabase(at: history, schemaVersion: 0)
        try createSentinelDatabase(at: legacy, schemaVersion: 3)
        for url in [desktop, summaries, state, history, legacy] {
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                throw TestError.permissions
            }
        }

        let catalogDigests = try Dictionary(uniqueKeysWithValues:
            targets.map { threadID in
                let row = CodexGhostRepairSQLiteRow(fields: [
                    .init(name: "host_id", value: .text("local")),
                    .init(name: "thread_id", value: .text(threadID)),
                    .init(name: "missing_candidate", value: .integer(0)),
                ])
                return (
                    threadID,
                    try CodexGhostRepairHasher.hash(
                        row.privacyPreserving(
                            cleartextFields: CodexGhostRepairPrivacyContract.catalog
                        )
                    )
                )
            }
        )
        let metadata = CodexGhostRepairSQLiteRow(fields: [
            .init(name: "id", value: .integer(1)),
            .init(name: "catalog_revision", value: .integer(100)),
        ])
        let sync = CodexGhostRepairSQLiteRow(fields: [
            .init(name: "host_id", value: .text("local")),
            .init(name: "observation_sequence", value: .integer(110)),
            .init(name: "watermark_updated_at", value: .integer(120)),
        ])
        let freshAuthority = CodexGhostRepairSnapshotAnalysisAuthorityEvidence(
            catalogRevision: 100,
            observationSequence: 110,
            watermarkUpdatedAt: 120,
            metadataRowDigest: try CodexGhostRepairHasher.hash(metadata),
            localSyncRowDigest: try CodexGhostRepairHasher.hash(sync)
        )
        let m3e = M3eCategoryATestFixture()
        let draft = try m3e.draft(
            targets: targets,
            catalogDigests: catalogDigests
        )
        let review = try m3e.review(draft: draft)
        let challenge = try m3e.challenge(draft: draft, review: review)
        let freshEvidence = try m3e.freshEvidence(
            draft: draft,
            review: review,
            freshAuthority: freshAuthority
        )
        let disposable = try CodexGhostRepairCategoryADisposableBundle(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: root
        )
        let recipe = try CodexGhostRepairCategoryAProductionRecipeBundle(
            disposableBundle: disposable,
            testOwnedManagerRootURL: managerRoot,
            testOwnedAllowedParentURL: root
        )
        return .init(
            root: root,
            desktopURL: desktop,
            storeURL: managerRoot.appendingPathComponent("state.sqlite"),
            recipeBundle: recipe,
            draft: draft,
            review: review,
            challenge: challenge,
            freshEvidence: freshEvidence,
            freshAuthority: freshAuthority
        )
    }

    private func createDesktopDatabase(at url: URL, targets: [String]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK,
              let database else { throw TestError.sqlite }
        defer { sqlite3_close_v2(database) }
        try execute("PRAGMA user_version = 32", database: database)
        try execute(
            "CREATE TABLE local_thread_catalog("
                + "host_id TEXT NOT NULL, thread_id TEXT NOT NULL, "
                + "missing_candidate INTEGER NOT NULL, "
                + "PRIMARY KEY(host_id, thread_id))",
            database: database
        )
        try execute(
            "CREATE TABLE local_thread_catalog_metadata("
                + "id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL)",
            database: database
        )
        try execute(
            "CREATE TABLE local_thread_catalog_sync_state("
                + "host_id TEXT PRIMARY KEY, "
                + "observation_sequence INTEGER NOT NULL, "
                + "watermark_updated_at INTEGER NOT NULL)",
            database: database
        )
        try execute(
            "CREATE TABLE m3c_untouched_sentinel("
                + "id INTEGER PRIMARY KEY, value TEXT NOT NULL)",
            database: database
        )
        try execute(
            "INSERT INTO local_thread_catalog_metadata VALUES (1, 100)",
            database: database
        )
        try execute(
            "INSERT INTO local_thread_catalog_sync_state "
                + "VALUES ('local', 110, 120)",
            database: database
        )
        try execute(
            "INSERT INTO m3c_untouched_sentinel VALUES (1, 'unchanged')",
            database: database
        )
        for threadID in targets {
            try execute(
                "INSERT INTO local_thread_catalog VALUES "
                    + "('local', '\(threadID)', 0)",
                database: database
            )
        }
    }

    private func createSentinelDatabase(
        at url: URL,
        schemaVersion: Int32
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK,
              let database else { throw TestError.sqlite }
        defer { sqlite3_close_v2(database) }
        try execute("PRAGMA user_version = \(schemaVersion)", database: database)
        try execute(
            "CREATE TABLE sentinel(id INTEGER PRIMARY KEY, value TEXT)",
            database: database
        )
        try execute(
            "INSERT INTO sentinel VALUES (1, 'unchanged')",
            database: database
        )
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        if let message { sqlite3_free(message) }
        guard result == SQLITE_OK else { throw TestError.sqlite }
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw TestError.permissions
        }
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }

    private enum TestError: Error {
        case sqlite
        case permissions
    }
}

private func XCTAssertThrowsM3fError<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? CodexGhostRepairError,
            .injectedInterruption,
            file: file,
            line: line
        )
    }
}

#endif
