@testable import AgentSessionManagerCore
import CSQLite3
import Darwin
import Foundation
import XCTest

#if AGENT_SESSION_MANAGER_RESEARCH

final class CodexGhostRepairCategoryADisposableExecutorTests:
    XCTestCase
{
    private let targetA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let targetB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"

    func testOneAndTwoItemCategoryAExecuteExactTransaction() async throws {
        for targets in [[targetA], [targetA, targetB]] {
            let fixture = try makeFixture(targets: targets)
            let draft = try makeDraft(fixture: fixture, targets: targets)
            let executor = CodexGhostRepairCategoryADisposableExecutor(
                bundle: fixture.bundle,
                now: { Date(timeIntervalSince1970: 3) }
            )

            let report = try await executor.execute(
                draft: draft,
                observedAtMilliseconds: 2_000
            )

            XCTAssertEqual(report.outcome, .success)
            XCTAssertEqual(
                report.items.map(\.outcome),
                Array(
                    repeating: CodexGhostRepairCategoryAItemOutcome.success,
                    count: targets.count
                )
            )
            XCTAssertTrue(report.durableClaimCreated)
            XCTAssertTrue(report.mutationAttemptedOnce)
            XCTAssertTrue(report.recoveredByReadback)
            XCTAssertTrue(report.readbackOnlyDatabasesUnchanged)
            XCTAssertFalse(report.automaticRetryAllowed)
            XCTAssertFalse(report.liveCodexRootAccessed)
            XCTAssertFalse(report.appRepairAuthority)
            XCTAssertEqual(
                try scalar(
                    "SELECT count(*) FROM local_thread_catalog",
                    at: fixture.desktopURL
                ),
                0
            )
            XCTAssertEqual(
                try scalar(
                    "SELECT catalog_revision "
                        + "FROM local_thread_catalog_metadata WHERE id = 1",
                    at: fixture.desktopURL
                ),
                10 + targets.count
            )
            XCTAssertEqual(
                try scalar(
                    "SELECT observation_sequence "
                        + "FROM local_thread_catalog_sync_state "
                        + "WHERE host_id = 'local'",
                    at: fixture.desktopURL
                ),
                20 + targets.count
            )
        }
    }

    func testPreclaimDriftFailsWholeSetAndCannotReplay() async throws {
        let fixture = try makeFixture(targets: [targetA, targetB])
        let draft = try makeDraft(
            fixture: fixture,
            targets: [targetA, targetB]
        )
        try executeSQL(
            "UPDATE local_thread_catalog SET missing_candidate = 1 "
                + "WHERE thread_id = '\(targetB)'",
            at: fixture.desktopURL
        )
        let executor = CodexGhostRepairCategoryADisposableExecutor(
            bundle: fixture.bundle
        )

        let report = try await executor.execute(
            draft: draft,
            observedAtMilliseconds: 2_000
        )

        XCTAssertEqual(report.outcome, .notAttempted)
        XCTAssertFalse(report.durableClaimCreated)
        XCTAssertFalse(report.mutationAttemptedOnce)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            2
        )
        XCTAssertEqual(
            try scalar(
                "SELECT catalog_revision "
                    + "FROM local_thread_catalog_metadata WHERE id = 1",
                at: fixture.desktopURL
            ),
            10
        )

        try executeSQL(
            "UPDATE local_thread_catalog SET missing_candidate = 0 "
                + "WHERE thread_id = '\(targetB)'",
            at: fixture.desktopURL
        )
        let replay = try await executor.execute(
            draft: draft,
            observedAtMilliseconds: 2_000
        )
        XCTAssertEqual(replay, report)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            2
        )
    }

    func testBusyIsExplicitFailureAndNeverRetries() async throws {
        let fixture = try makeFixture(targets: [targetA])
        let draft = try makeDraft(fixture: fixture, targets: [targetA])
        let executor = CodexGhostRepairCategoryADisposableExecutor(
            bundle: fixture.bundle
        )

        let report = try await executor.execute(
            draft: draft,
            observedAtMilliseconds: 2_000,
            fault: .explicitBusyBeforeTransaction
        )

        XCTAssertEqual(report.outcome, .explicitFailure)
        XCTAssertTrue(report.durableClaimCreated)
        XCTAssertTrue(report.mutationAttemptedOnce)
        XCTAssertFalse(report.automaticRetryAllowed)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            1
        )
        let replay = try await executor.execute(
            draft: draft,
            observedAtMilliseconds: 2_000
        )
        XCTAssertEqual(replay, report)
    }

    func testClaimBeforeAttemptRecoversNotAttemptedWithoutReplay()
        async throws
    {
        let fixture = try makeFixture(targets: [targetA])
        let draft = try makeDraft(fixture: fixture, targets: [targetA])
        let first = CodexGhostRepairCategoryADisposableExecutor(
            bundle: fixture.bundle
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await first.execute(
                draft: draft,
                observedAtMilliseconds: 2_000,
                fault: .afterClaim
            )
        } verify: { error in
            XCTAssertEqual(
                error as? CodexGhostRepairError,
                .injectedInterruption
            )
        }

        let restarted = CodexGhostRepairCategoryADisposableExecutor(
            bundle: fixture.bundle
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await restarted.execute(
                draft: draft,
                observedAtMilliseconds: 2_000
            )
        } verify: { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .recoveryRequired)
        }
        let report = try await restarted.recoverByReadback(draft: draft)
        XCTAssertEqual(report.outcome, .notAttempted)
        XCTAssertFalse(report.mutationAttemptedOnce)
        XCTAssertTrue(report.recoveredByReadback)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            1
        )
    }

    func testCommitBeforeReportRecoversSuccessAndDoesNotReplay()
        async throws
    {
        let fixture = try makeFixture(targets: [targetA, targetB])
        let draft = try makeDraft(
            fixture: fixture,
            targets: [targetA, targetB]
        )
        let first = CodexGhostRepairCategoryADisposableExecutor(
            bundle: fixture.bundle
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await first.execute(
                draft: draft,
                observedAtMilliseconds: 2_000,
                fault: .afterCommitBeforeReport
            )
        } verify: { error in
            XCTAssertEqual(
                error as? CodexGhostRepairError,
                .injectedInterruption
            )
        }

        let restarted = CodexGhostRepairCategoryADisposableExecutor(
            bundle: fixture.bundle
        )
        let report = try await restarted.recoverByReadback(draft: draft)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertTrue(report.mutationAttemptedOnce)
        XCTAssertTrue(report.recoveredByReadback)
        XCTAssertTrue(report.readbackOnlyDatabasesUnchanged)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            0
        )
        let replay = try await restarted.execute(
            draft: draft,
            observedAtMilliseconds: 2_000
        )
        XCTAssertEqual(replay, report)
        XCTAssertEqual(
            try scalar(
                "SELECT catalog_revision "
                    + "FROM local_thread_catalog_metadata WHERE id = 1",
                at: fixture.desktopURL
            ),
            12
        )
    }

    func testPostclaimUnexpectedStateIsUnknownAndNotRetried()
        async throws
    {
        let fixture = try makeFixture(targets: [targetA, targetB])
        let draft = try makeDraft(
            fixture: fixture,
            targets: [targetA, targetB]
        )
        let first = CodexGhostRepairCategoryADisposableExecutor(
            bundle: fixture.bundle
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await first.execute(
                draft: draft,
                observedAtMilliseconds: 2_000,
                fault: .afterClaim
            )
        }
        try executeSQL(
            "UPDATE local_thread_catalog SET missing_candidate = 1 "
                + "WHERE thread_id = '\(targetB)'",
            at: fixture.desktopURL
        )

        let restarted = CodexGhostRepairCategoryADisposableExecutor(
            bundle: fixture.bundle
        )
        let report = try await restarted.recoverByReadback(draft: draft)
        XCTAssertEqual(report.outcome, .unknown)
        XCTAssertFalse(report.mutationAttemptedOnce)
        XCTAssertFalse(report.automaticRetryAllowed)
        XCTAssertEqual(
            report.items.map(\.outcome),
            [.unknown, .unknown]
        )
        let replay = try await restarted.execute(
            draft: draft,
            observedAtMilliseconds: 2_000
        )
        XCTAssertEqual(replay, report)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            2
        )
    }

    func testCapabilitiesAndBundleRejectLiveRoot() throws {
        let capabilities =
            CodexGhostRepairCategoryADisposableExecutor.capabilities
        XCTAssertTrue(capabilities.testOwnedDisposableCopiesOnly)
        XCTAssertEqual(capabilities.maximumTargetCount, 2)
        XCTAssertTrue(capabilities.categoryAOnly)
        XCTAssertTrue(capabilities.exactDesktopTransaction)
        XCTAssertEqual(capabilities.readbackOnlyDatabaseCount, 4)
        XCTAssertTrue(capabilities.durableClaimBeforeMutation)
        XCTAssertTrue(capabilities.durableReportReadback)
        XCTAssertFalse(capabilities.replaysMutation)
        XCTAssertFalse(capabilities.retriesUnknown)
        XCTAssertFalse(capabilities.acceptsLiveCodexRoot)
        XCTAssertFalse(capabilities.appWiringAvailable)
        XCTAssertFalse(capabilities.packagedRepairAuthority)

        let live = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        XCTAssertThrowsError(
            try CodexGhostRepairCategoryADisposableBundle(
                testOwnedCodexHomeURL: live,
                testOwnedAllowedParentURL:
                    live.deletingLastPathComponent()
            )
        )
    }

    private struct Fixture {
        let root: URL
        let bundle: CodexGhostRepairCategoryADisposableBundle
        let desktopURL: URL
        let targets: [String]
        let catalogDigests: [String: String]
        let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    }

    private func makeFixture(targets: [String]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-session-manager-m3c-\(UUID().uuidString)",
                isDirectory: true
            )
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sqlite = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        let evidence = codexHome.appendingPathComponent(
            CodexGhostRepairCategoryADisposableBundle.evidenceDirectoryName,
            isDirectory: true
        )
        try makeDirectory(root)
        try makeDirectory(codexHome)
        try makeDirectory(sqlite)
        try makeDirectory(evidence)
        try Data(
            CodexGhostRepairCategoryADisposableBundle.markerContents.utf8
        ).write(to: codexHome.appendingPathComponent(
            CodexGhostRepairCategoryADisposableBundle.markerFileName
        ))

        let desktop = sqlite.appendingPathComponent("codex-dev.db")
        let summaries = sqlite.appendingPathComponent(
            "codex-thread-summaries-dev.db"
        )
        let legacy = sqlite.appendingPathComponent(
            "codex-history-snapshots-dev.db"
        )
        let state = codexHome.appendingPathComponent("state_5.sqlite")
        let history = codexHome.appendingPathComponent(
            "thread_history_1.sqlite"
        )
        try createDesktopDatabase(at: desktop, targets: targets)
        try createSentinelDatabase(at: summaries, schemaVersion: 2)
        try createSentinelDatabase(at: state, schemaVersion: 0)
        try createSentinelDatabase(at: history, schemaVersion: 0)
        try createSentinelDatabase(at: legacy, schemaVersion: 3)
        for url in [desktop, summaries, state, history, legacy] {
            XCTAssertEqual(chmod(url.path, S_IRUSR | S_IWUSR), 0)
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
            .init(name: "catalog_revision", value: .integer(10)),
        ])
        let sync = CodexGhostRepairSQLiteRow(fields: [
            .init(name: "host_id", value: .text("local")),
            .init(name: "observation_sequence", value: .integer(20)),
            .init(name: "watermark_updated_at", value: .integer(30)),
        ])
        let authority = CodexGhostRepairSnapshotAnalysisAuthorityEvidence(
            catalogRevision: 10,
            observationSequence: 20,
            watermarkUpdatedAt: 30,
            metadataRowDigest: try CodexGhostRepairHasher.hash(metadata),
            localSyncRowDigest: try CodexGhostRepairHasher.hash(sync)
        )
        return Fixture(
            root: root,
            bundle: try .init(
                testOwnedCodexHomeURL: codexHome,
                testOwnedAllowedParentURL: root
            ),
            desktopURL: desktop,
            targets: targets,
            catalogDigests: catalogDigests,
            authority: authority
        )
    }

    private func makeDraft(
        fixture: Fixture,
        targets: [String]
    ) throws -> CodexGhostRepairCategoryAExecutionDraft {
        let identity = try CodexGhostRepairSnapshotAnalysisIdentity(
            snapshotID: UUID(),
            targetThreadIDs: targets,
            preparedAtMilliseconds: 100,
            publishedAtMilliseconds: 200,
            sourceFingerprintHash: digest("1"),
            destinationBindingHash: digest("2"),
            acquisitionRecordHash: digest("3"),
            manifestHash: digest("4"),
            publicationReceiptHash: digest("5"),
            observedRegularFileCount: 10,
            actualPublishedBytes: 1_000
        )
        let databases = databaseEvidence()
        let readback = CodexGhostRepairSnapshotAnalysisReadback(
            identity: identity,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: databases,
            targets: targets.map { threadID in
                .init(
                    threadID: threadID,
                    catalogRowDigests: [fixture.catalogDigests[threadID]!],
                    automationRunRowDigests: [],
                    automationDefinitionRowDigests: [],
                    references: .init(
                        inbox: 0,
                        timeline: 0,
                        summaries: 0,
                        canonicalState: 0,
                        threadTurns: 0,
                        threadItems: 0,
                        historyProjection: 0
                    ),
                    rowContract: .categoryAEligible
                )
            },
            authority: fixture.authority
        )
        let protection = targets.map { threadID in
            CodexGhostRepairProtectionEvidence(
                threadID: threadID,
                inventoryComplete: true,
                activeInventoryPresent: false,
                archivedInventoryPresent: false,
                exactReadNotLoaded: true,
                exactReadErrorCode: -32600,
                pinned: false,
                descendantCount: 0
            )
        }
        let experimental = targets.map { threadID in
            CodexGhostRepairExperimentalAbsenceEvidence(
                provider: .codex,
                requestedThreadID: threadID,
                runtimeVersion: "0.149.0",
                method: .threadRead,
                rpcCode: -32600,
                contractIdentifier:
                    "codex-ghost-repair-experimental-absence",
                contractVersion: 1,
                responseShapeIdentifier: "rpc-error-code-message-v1",
                canonicalResponseHash: digest("6"),
                compatibilityFixtureHash: digest("7"),
                packagedCanaryEvidenceHash: digest("8"),
                sourceLayoutIdentifier:
                    CodexGhostRepairSnapshotSourceLayout.identifier,
                databases: databases.map {
                    .init(
                        database: $0.database,
                        schemaVersion: $0.schemaVersion
                    )
                }
            )
        }
        let outcome = CodexGhostRepairSnapshotDryRunPlanner.plan(
            identity: identity,
            snapshotEvidence: readback,
            protectionEvidence: protection,
            experimentalAbsenceEvidence: experimental,
            operationalAudit: .init(
                codexFullyExited: true,
                desktopOpenHandleCount: 0,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                stateOpenHandleCount: 0,
                threadHistoryOpenHandleCount: 0,
                capacitySufficient: true
            ),
            previewID: UUID(),
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
        )
        guard case let .preview(preview) = outcome,
              case let .draft(draft) =
                CodexGhostRepairCategoryAExecutionContract.freeze(
                    preview: preview,
                    operationID: UUID(),
                    observedAtMilliseconds: 2_000
                ) else {
            throw TestError.previewUnavailable
        }
        return draft
    }

    private func databaseEvidence()
        -> [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    {
        [
            .init(
                database: .desktop,
                schemaVersion: 32,
                integrityCheckPassed: true,
                foreignKeyViolationCount: 0
            ),
            .init(
                database: .summaries,
                schemaVersion: 2,
                integrityCheckPassed: true,
                foreignKeyViolationCount: 0
            ),
            .init(
                database: .state,
                schemaVersion: 0,
                integrityCheckPassed: true,
                foreignKeyViolationCount: 0
            ),
            .init(
                database: .threadHistory,
                schemaVersion: 0,
                integrityCheckPassed: true,
                foreignKeyViolationCount: 0
            ),
        ]
    }

    private func createDesktopDatabase(
        at url: URL,
        targets: [String]
    ) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open(url.path, &pointer) == SQLITE_OK, let pointer else {
            throw TestError.sqlite
        }
        defer { sqlite3_close_v2(pointer) }
        try executeSQL("PRAGMA user_version = 32", database: pointer)
        try executeSQL(
            "CREATE TABLE local_thread_catalog("
                + "host_id TEXT NOT NULL, thread_id TEXT NOT NULL, "
                + "missing_candidate INTEGER NOT NULL, "
                + "PRIMARY KEY(host_id, thread_id))",
            database: pointer
        )
        try executeSQL(
            "CREATE TABLE local_thread_catalog_metadata("
                + "id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL)",
            database: pointer
        )
        try executeSQL(
            "CREATE TABLE local_thread_catalog_sync_state("
                + "host_id TEXT PRIMARY KEY, "
                + "observation_sequence INTEGER NOT NULL, "
                + "watermark_updated_at INTEGER NOT NULL)",
            database: pointer
        )
        try executeSQL(
            "CREATE TABLE m3c_untouched_sentinel("
                + "id INTEGER PRIMARY KEY, value TEXT NOT NULL)",
            database: pointer
        )
        try executeSQL(
            "INSERT INTO local_thread_catalog_metadata VALUES (1, 10)",
            database: pointer
        )
        try executeSQL(
            "INSERT INTO local_thread_catalog_sync_state "
                + "VALUES ('local', 20, 30)",
            database: pointer
        )
        try executeSQL(
            "INSERT INTO m3c_untouched_sentinel VALUES (1, 'unchanged')",
            database: pointer
        )
        for threadID in targets {
            try executeSQL(
                "INSERT INTO local_thread_catalog VALUES "
                    + "('local', '\(threadID)', 0)",
                database: pointer
            )
        }
    }

    private func createSentinelDatabase(
        at url: URL,
        schemaVersion: Int32
    ) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open(url.path, &pointer) == SQLITE_OK, let pointer else {
            throw TestError.sqlite
        }
        defer { sqlite3_close_v2(pointer) }
        try executeSQL(
            "PRAGMA user_version = \(schemaVersion)",
            database: pointer
        )
        try executeSQL(
            "CREATE TABLE sentinel(id INTEGER PRIMARY KEY, value TEXT)",
            database: pointer
        )
        try executeSQL(
            "INSERT INTO sentinel VALUES (1, 'unchanged')",
            database: pointer
        )
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(url.path, S_IRWXU), 0)
    }

    private func scalar(_ sql: String, at url: URL) throws -> Int {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &pointer,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let pointer else {
            throw TestError.sqlite
        }
        defer { sqlite3_close_v2(pointer) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw TestError.sqlite
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestError.sqlite
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open(url.path, &pointer) == SQLITE_OK, let pointer else {
            throw TestError.sqlite
        }
        defer { sqlite3_close_v2(pointer) }
        try executeSQL(sql, database: pointer)
    }

    private func executeSQL(
        _ sql: String,
        database: OpaquePointer
    ) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        if let error { sqlite3_free(error) }
        guard result == SQLITE_OK else { throw TestError.sqlite }
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }

    private enum TestError: Error {
        case previewUnavailable
        case sqlite
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}

#endif
