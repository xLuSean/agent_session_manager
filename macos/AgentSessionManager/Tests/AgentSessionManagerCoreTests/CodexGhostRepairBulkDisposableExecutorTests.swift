@testable import AgentSessionManagerCore
import CSQLite3
import Darwin
import Foundation
import XCTest

#if AGENT_SESSION_MANAGER_RESEARCH

final class CodexGhostRepairBulkDisposableExecutorTests: XCTestCase {
    func testSupportedWholeBatchSizesRemainAtomic() async throws {
        for itemCount in [1, 2, 10, 500] {
            let fixture = try makeFixture(
                itemCount: itemCount,
                blockedCount: 0
            )
            let executor = CodexGhostRepairBulkDisposableExecutor(
                bundle: fixture.bundle,
                nowMilliseconds: { 1_500 }
            )

            let report = try await executor.execute(plan: fixture.plan)

            XCTAssertEqual(report.outcome, .success)
            XCTAssertEqual(report.items.count, itemCount)
            XCTAssertTrue(report.items.allSatisfy {
                $0.outcome == .success
            })
            XCTAssertEqual(
                try scalar(
                    "SELECT count(*) FROM local_thread_catalog",
                    at: fixture.bundle.desktopURL
                ),
                0
            )
            XCTAssertEqual(
                try scalar(
                    "SELECT catalog_revision FROM "
                        + "local_thread_catalog_metadata WHERE id = 1",
                    at: fixture.bundle.desktopURL
                ),
                Int64(1_000 + itemCount)
            )
        }
    }

    func testExact148MixedBatchApplies145InOneAtomicOutcome() async throws {
        let fixture = try makeFixture(itemCount: 148, blockedCount: 3)
        let executor = CodexGhostRepairBulkDisposableExecutor(
            bundle: fixture.bundle,
            nowMilliseconds: { 1_500 }
        )

        let report = try await executor.execute(plan: fixture.plan)

        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.count, 145)
        XCTAssertEqual(
            report.items.map(\.threadID),
            fixture.plan.selectedThreadIDs
        )
        XCTAssertEqual(
            report.items.filter { $0.category == .ordinary }.count,
            fixture.ordinarySelectedCount
        )
        XCTAssertEqual(
            report.items.filter { $0.category == .automation }.count,
            fixture.automationSelectedCount
        )
        XCTAssertTrue(report.items.allSatisfy { $0.outcome == .success })
        XCTAssertTrue(report.durableClaimCreated)
        XCTAssertTrue(report.mutationAttemptedOnce)
        XCTAssertTrue(report.recoveredByReadback)
        XCTAssertTrue(report.readOnlyDatabasesUnchanged)
        XCTAssertFalse(report.automaticRetryAllowed)
        XCTAssertFalse(report.liveCodexRootAccessed)
        XCTAssertFalse(report.appRepairAuthority)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.bundle.desktopURL
            ),
            3
        )
        XCTAssertEqual(
            try scalar(
                "SELECT catalog_revision FROM "
                    + "local_thread_catalog_metadata WHERE id = 1",
                at: fixture.bundle.desktopURL
            ),
            1_145
        )
        XCTAssertEqual(
            try scalar(
                "SELECT observation_sequence FROM "
                    + "local_thread_catalog_sync_state "
                    + "WHERE host_id = 'local'",
                at: fixture.bundle.desktopURL
            ),
            2_145
        )
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM automation_runs "
                    + "WHERE status = 'ARCHIVED' "
                    + "AND archived_reason = 'auto'",
                at: fixture.bundle.desktopURL
            ),
            Int64(fixture.automationSelectedCount)
        )
        XCTAssertEqual(
            try scalar(
                "SELECT count(DISTINCT updated_at) FROM automation_runs "
                    + "WHERE status = 'ARCHIVED'",
                at: fixture.bundle.desktopURL
            ),
            1
        )
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM automations WHERE status = 'ACTIVE'",
                at: fixture.bundle.desktopURL
            ),
            Int64(fixture.totalAutomationCount)
        )
    }

    func testOneSelectedReferenceDriftStopsWhole145BeforeClaim() async throws {
        let fixture = try makeFixture(itemCount: 148, blockedCount: 3)
        let drifted = fixture.plan.selectedThreadIDs[70]
        try executeSQL(
            "INSERT INTO inbox_items(thread_id) VALUES ('\(drifted)')",
            at: fixture.bundle.desktopURL
        )
        let executor = CodexGhostRepairBulkDisposableExecutor(
            bundle: fixture.bundle,
            nowMilliseconds: { 1_500 }
        )

        let report = try await executor.execute(plan: fixture.plan)

        XCTAssertEqual(report.outcome, .notAttempted)
        XCTAssertFalse(report.durableClaimCreated)
        XCTAssertFalse(report.mutationAttemptedOnce)
        XCTAssertTrue(report.items.allSatisfy {
            $0.outcome == .notAttempted
        })
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.bundle.desktopURL
            ),
            148
        )
        XCTAssertEqual(
            try scalar(
                "SELECT catalog_revision FROM "
                    + "local_thread_catalog_metadata WHERE id = 1",
                at: fixture.bundle.desktopURL
            ),
            1_000
        )
    }

    func testExplicitBusyConsumesAttemptAndNeverRetries() async throws {
        let fixture = try makeFixture(itemCount: 12, blockedCount: 2)
        let executor = CodexGhostRepairBulkDisposableExecutor(
            bundle: fixture.bundle,
            nowMilliseconds: { 1_500 }
        )

        let report = try await executor.execute(
            plan: fixture.plan,
            fault: .explicitBusyBeforeTransaction
        )
        let replay = try await executor.execute(plan: fixture.plan)

        XCTAssertEqual(report.outcome, .explicitFailure)
        XCTAssertEqual(replay, report)
        XCTAssertTrue(report.durableClaimCreated)
        XCTAssertTrue(report.mutationAttemptedOnce)
        XCTAssertFalse(report.automaticRetryAllowed)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.bundle.desktopURL
            ),
            12
        )
    }

    func testCommitBeforeReportRecoversExactMixedSuccessWithoutReplay()
        async throws
    {
        let fixture = try makeFixture(itemCount: 30, blockedCount: 0)
        let first = CodexGhostRepairBulkDisposableExecutor(
            bundle: fixture.bundle,
            nowMilliseconds: { 1_500 }
        )
        await assertM4cThrows {
            _ = try await first.execute(
                plan: fixture.plan,
                fault: .afterCommitBeforeReport
            )
        } verify: { error in
            XCTAssertEqual(
                error as? CodexGhostRepairError,
                .injectedInterruption
            )
        }

        let restarted = CodexGhostRepairBulkDisposableExecutor(
            bundle: fixture.bundle,
            nowMilliseconds: { 1_600 }
        )
        let report = try await restarted.recoverByReadback(
            plan: fixture.plan
        )
        let replay = try await restarted.execute(plan: fixture.plan)

        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(replay, report)
        XCTAssertTrue(report.mutationAttemptedOnce)
        XCTAssertTrue(report.recoveredByReadback)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.bundle.desktopURL
            ),
            0
        )
        XCTAssertEqual(
            try scalar(
                "SELECT catalog_revision FROM "
                    + "local_thread_catalog_metadata WHERE id = 1",
                at: fixture.bundle.desktopURL
            ),
            1_030
        )
    }

    func testClaimWithoutAttemptRequiresReadbackAndDoesNotMutate()
        async throws
    {
        let fixture = try makeFixture(itemCount: 20, blockedCount: 0)
        let first = CodexGhostRepairBulkDisposableExecutor(
            bundle: fixture.bundle,
            nowMilliseconds: { 1_500 }
        )
        await assertM4cThrows {
            _ = try await first.execute(
                plan: fixture.plan,
                fault: .afterClaim
            )
        }
        let restarted = CodexGhostRepairBulkDisposableExecutor(
            bundle: fixture.bundle,
            nowMilliseconds: { 1_600 }
        )
        await assertM4cThrows {
            _ = try await restarted.execute(plan: fixture.plan)
        } verify: { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .recoveryRequired)
        }

        let report = try await restarted.recoverByReadback(
            plan: fixture.plan
        )

        XCTAssertEqual(report.outcome, .notAttempted)
        XCTAssertFalse(report.mutationAttemptedOnce)
        XCTAssertFalse(report.automaticRetryAllowed)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.bundle.desktopURL
            ),
            20
        )
    }

    func testReadOnlySideDatabaseDriftAfterClaimReturnsUnknownWithoutRetry()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        let first = CodexGhostRepairBulkDisposableExecutor(
            bundle: fixture.bundle,
            nowMilliseconds: { 1_500 }
        )
        await assertM4cThrows {
            _ = try await first.execute(
                plan: fixture.plan,
                fault: .afterClaim
            )
        }
        try executeSQL(
            "INSERT INTO thread_turn_summaries VALUES ('unrelated-drift')",
            at: fixture.bundle.databaseURL(.summaries)
        )
        let restarted = CodexGhostRepairBulkDisposableExecutor(
            bundle: fixture.bundle,
            nowMilliseconds: { 1_600 }
        )

        let report = try await restarted.recoverByReadback(
            plan: fixture.plan
        )
        let replay = try await restarted.execute(plan: fixture.plan)

        XCTAssertEqual(report.outcome, .unknown)
        XCTAssertEqual(replay, report)
        XCTAssertFalse(report.mutationAttemptedOnce)
        XCTAssertFalse(report.readOnlyDatabasesUnchanged)
        XCTAssertFalse(report.automaticRetryAllowed)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.bundle.desktopURL
            ),
            10
        )
    }

    func testTamperedDurableReportIsRejectedInsteadOfTrustedOrRetried()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        let executor = CodexGhostRepairBulkDisposableExecutor(
            bundle: fixture.bundle,
            nowMilliseconds: { 1_500 }
        )
        _ = try await executor.execute(plan: fixture.plan)
        let reportURL = fixture.bundle.evidenceRootURL
            .appendingPathComponent(
                fixture.plan.operationID.uuidString.lowercased()
            )
            .appendingPathComponent("report.json")
        var bytes = try Data(contentsOf: reportURL)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: reportURL, options: [.atomic])
        XCTAssertEqual(chmod(reportURL.path, S_IRUSR | S_IWUSR), 0)

        await assertM4cThrows {
            _ = try await executor.execute(plan: fixture.plan)
        }
    }

    func testPlanRejectsReceiptFromAnotherConfirmedPreview() throws {
        let first = try makeFixture(itemCount: 10, blockedCount: 0)
        let second = try makeFixture(itemCount: 11, blockedCount: 0)

        XCTAssertThrowsError(try CodexGhostRepairBulkExecutionPlan.prepare(
            operationID: UUID(),
            preview: first.preview,
            challenge: first.challenge,
            receipt: second.receipt,
            frozenInventoryInput: first.inventoryInput,
            plannedAtMilliseconds: 1_300
        ))
    }

    private struct Fixture {
        let bundle: CodexGhostRepairBulkDisposableBundle
        let inventoryInput: CodexGhostRepairBulkInventoryInput
        let preview: CodexGhostRepairBulkPreview
        let challenge: CodexGhostRepairBulkConfirmationChallenge
        let receipt: CodexGhostRepairBulkConfirmationReceipt
        let plan: CodexGhostRepairBulkExecutionPlan
        let ordinarySelectedCount: Int
        let automationSelectedCount: Int
        let totalAutomationCount: Int
    }

    private func makeFixture(itemCount: Int, blockedCount: Int) throws
        -> Fixture
    {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-m4c-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(CodexGhostRepairBulkDisposableBundle.markerContents.utf8)
            .write(to: root.appendingPathComponent(
                CodexGhostRepairBulkDisposableBundle.markerFileName
            ))
        let evidence = root.appendingPathComponent(
            CodexGhostRepairBulkDisposableBundle.evidenceDirectoryName
        )
        try FileManager.default.createDirectory(
            at: evidence,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let desktop = root.appendingPathComponent("codex-dev.db")
        let summaries = root.appendingPathComponent(
            "codex-thread-summaries-dev.db"
        )
        let state = root.appendingPathComponent("state_5.sqlite")
        let history = root.appendingPathComponent("thread_history_1.sqlite")
        try createDesktop(at: desktop)
        try createSQLite(
            at: summaries,
            version: 2,
            sql: "CREATE TABLE thread_turn_summaries(thread_id TEXT)"
        )
        try createSQLite(
            at: state,
            version: 0,
            sql: "CREATE TABLE threads(id TEXT)"
        )
        try createSQLite(
            at: history,
            version: 0,
            sql: """
            CREATE TABLE thread_turns(thread_id TEXT);
            CREATE TABLE thread_items(thread_id TEXT);
            CREATE TABLE thread_history_projection_state(thread_id TEXT);
            """
        )
        for url in [
            root.appendingPathComponent(
                CodexGhostRepairBulkDisposableBundle.markerFileName
            ),
            desktop, summaries, state, history,
        ] {
            XCTAssertEqual(chmod(url.path, S_IRUSR | S_IWUSR), 0)
        }

        var targets: [CodexGhostRepairSnapshotAnalysisTargetEvidence] = []
        var protection: [CodexGhostRepairProtectionEvidence] = []
        var totalAutomationCount = 0
        for index in 0..<itemCount {
            let threadID = identifier(index)
            let category: CodexGhostRepairCategory = index.isMultiple(of: 2)
                ? .ordinary : .automation
            try executeSQL(
                "INSERT INTO local_thread_catalog "
                    + "VALUES ('local','\(threadID)',0,'title-\(index)')",
                at: desktop
            )
            if category == .automation {
                totalAutomationCount += 1
                try executeSQL(
                    "INSERT INTO automation_runs VALUES "
                        + "('\(threadID)','automation-\(index)',"
                        + "'ACCEPTED',NULL,\(10_000 + index),NULL,NULL,"
                        + "'private-\(index)')",
                    at: desktop
                )
                try executeSQL(
                    "INSERT INTO automations VALUES "
                        + "('automation-\(index)','ACTIVE',"
                        + "'definition-\(index)')",
                    at: desktop
                )
            }
            let catalogRows = try rows(
                "SELECT * FROM local_thread_catalog WHERE thread_id = ?",
                value: threadID,
                at: desktop
            )
            let automationRows = try rows(
                "SELECT * FROM automation_runs WHERE thread_id = ?",
                value: threadID,
                at: desktop
            )
            let definitionRows = category == .automation
                ? try rows(
                    "SELECT * FROM automations WHERE id = ?",
                    value: "automation-\(index)",
                    at: desktop
                ) : []
            targets.append(.init(
                threadID: threadID,
                catalogRowDigests: try catalogRows.map {
                    try CodexGhostRepairBulkTargetEvidenceContract
                        .catalogAuthorizationDigest($0)
                },
                automationRunRowDigests: try automationRows.map {
                    try CodexGhostRepairHasher.hash($0)
                },
                automationStableFieldsDigests: try automationRows.map {
                    try CodexGhostRepairBulkTargetEvidenceContract
                        .automationIdentityDigest($0)
                },
                automationDefinitionRowDigests: try definitionRows.map {
                    try CodexGhostRepairBulkTargetEvidenceContract
                        .automationDefinitionAuthorizationDigest($0)
                },
                references: .init(
                    inbox: 0,
                    timeline: 0,
                    summaries: 0,
                    canonicalState: 0,
                    threadTurns: 0,
                    threadItems: 0,
                    historyProjection: 0
                ),
                rowContract: category == .ordinary
                    ? .categoryAEligible : .categoryBEligible
            ))
            let blocked = index >= itemCount - blockedCount
            protection.append(.init(
                threadID: threadID,
                inventoryComplete: true,
                activeInventoryPresent: false,
                archivedInventoryPresent: false,
                exactReadNotLoaded: true,
                exactReadErrorCode: -32600,
                pinned: blocked,
                descendantCount: 0
            ))
        }
        let metadata = try rows(
            "SELECT * FROM local_thread_catalog_metadata WHERE id = 1",
            at: desktop
        )[0]
        let sync = try rows(
            "SELECT * FROM local_thread_catalog_sync_state "
                + "WHERE host_id = 'local'",
            at: desktop
        )[0]
        let databaseEvidence: [
            CodexGhostRepairSnapshotAnalysisDatabaseEvidence
        ] = [
            .init(database: .desktop, schemaVersion: 32,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
            .init(database: .summaries, schemaVersion: 2,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
            .init(database: .state, schemaVersion: 0,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
            .init(database: .threadHistory, schemaVersion: 0,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
        ]
        let input = CodexGhostRepairBulkInventoryInput(
            snapshotReference: "10000000-0000-4000-8000-000000000001",
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            sourceFingerprintHash: hash(1),
            manifestHash: hash(2),
            databases: databaseEvidence,
            targets: targets,
            protectionEvidence: protection,
            authority: .init(
                catalogRevision: 1_000,
                observationSequence: 2_000,
                watermarkUpdatedAt: 3_000,
                metadataRowDigest: try CodexGhostRepairHasher.hash(metadata),
                localSyncRowDigest: try CodexGhostRepairHasher.hash(sync)
            )
        )
        let inventory = try CodexGhostRepairBulkInventoryBuilder.build(
            input: input
        )
        let selected = inventory.eligibleThreadIDs
        let preview = try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: selected,
            previewID: UUID(),
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 10_000
        )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: UUID(),
            savedPreviewRequestID: UUID(),
            preview: preview,
            previewPayloadHash: hash(3),
            generatedAtMilliseconds: 1_100
        )
        let receipt = try CodexGhostRepairBulkConfirmationReceipt(
            receiptID: UUID(),
            challenge: challenge,
            confirmedAtMilliseconds: 1_200
        )
        let plan = try CodexGhostRepairBulkExecutionPlan.prepare(
            operationID: challenge.operationID,
            preview: preview,
            challenge: challenge,
            receipt: receipt,
            frozenInventoryInput: input,
            plannedAtMilliseconds: 1_300
        )
        let bundle = try CodexGhostRepairBulkDisposableBundle(
            rootURL: root,
            allowedParentURL: parent
        )
        return .init(
            bundle: bundle,
            inventoryInput: input,
            preview: preview,
            challenge: challenge,
            receipt: receipt,
            plan: plan,
            ordinarySelectedCount:
                preview.selectedItems.count { $0.category == .ordinary },
            automationSelectedCount:
                preview.selectedItems.count { $0.category == .automation },
            totalAutomationCount: totalAutomationCount
        )
    }

    private func createDesktop(at url: URL) throws {
        try createSQLite(
            at: url,
            version: 32,
            sql: """
            CREATE TABLE local_thread_catalog(
              host_id TEXT NOT NULL, thread_id TEXT NOT NULL,
              missing_candidate INTEGER NOT NULL, private_title TEXT,
              PRIMARY KEY(host_id, thread_id));
            CREATE TABLE automation_runs(
              thread_id TEXT PRIMARY KEY, automation_id TEXT NOT NULL,
              status TEXT NOT NULL, archived_reason TEXT, updated_at INTEGER,
              archived_user_message TEXT, archived_assistant_message TEXT,
              private_payload TEXT);
            CREATE TABLE automations(
              id TEXT PRIMARY KEY, status TEXT NOT NULL, private_prompt TEXT);
            CREATE TABLE inbox_items(thread_id TEXT);
            CREATE TABLE thread_timeline_ledger(thread_id TEXT);
            CREATE TABLE local_thread_catalog_metadata(
              id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL);
            CREATE TABLE local_thread_catalog_sync_state(
              host_id TEXT PRIMARY KEY, observation_sequence INTEGER NOT NULL,
              watermark_updated_at INTEGER);
            INSERT INTO local_thread_catalog_metadata VALUES (1, 1000);
            INSERT INTO local_thread_catalog_sync_state
              VALUES ('local', 2000, 3000);
            """
        )
    }

    private func createSQLite(at url: URL, version: Int, sql: String) throws {
        var database: OpaquePointer?
        try check(sqlite3_open(url.path, &database), database)
        guard let database else { throw SQLiteTestError.open }
        defer { sqlite3_close_v2(database) }
        try check(
            sqlite3_exec(
                database,
                "PRAGMA user_version=\(version);\(sql)",
                nil,
                nil,
                nil
            ),
            database
        )
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        try check(sqlite3_open(url.path, &database), database)
        guard let database else { throw SQLiteTestError.open }
        defer { sqlite3_close_v2(database) }
        try check(sqlite3_exec(database, sql, nil, nil, nil), database)
    }

    private func rows(
        _ sql: String,
        value: String? = nil,
        at url: URL
    ) throws -> [CodexGhostRepairSQLiteRow] {
        var database: OpaquePointer?
        try check(sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ), database)
        guard let database else { throw SQLiteTestError.open }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil), database)
        guard let statement else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(statement) }
        if let value {
            try check(value.withCString {
                sqlite3_bind_text(
                    statement,
                    1,
                    $0,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }, database)
        }
        var result: [CodexGhostRepairSQLiteRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var fields: [CodexGhostRepairSQLiteField] = []
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                let value: CodexGhostRepairSQLiteValue
                switch sqlite3_column_type(statement, index) {
                case SQLITE_NULL: value = .null
                case SQLITE_INTEGER:
                    value = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    value = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    value = sqlite3_column_text(statement, index).map {
                        .text(String(cString: $0))
                    } ?? .null
                default: throw SQLiteTestError.step
                }
                fields.append(.init(name: name, value: value))
            }
            result.append(.init(fields: fields))
        }
        return result
    }

    private func scalar(_ sql: String, at url: URL) throws -> Int64 {
        var database: OpaquePointer?
        try check(sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ), database)
        guard let database else { throw SQLiteTestError.open }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil), database)
        guard let statement else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteTestError.step
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func check(_ code: Int32, _ database: OpaquePointer?) throws {
        guard code == SQLITE_OK else {
            throw SQLiteTestError.sqlite(
                database.map { String(cString: sqlite3_errmsg($0)) }
                    ?? "unknown"
            )
        }
    }

    private func identifier(_ index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", index + 1)
    }

    private func hash(_ index: Int) -> String {
        "sha256:" + String(format: "%064x", index + 1)
    }

    private enum SQLiteTestError: Error {
        case open
        case prepare
        case step
        case sqlite(String)
    }
}

private func assertM4cThrows<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}

#endif
