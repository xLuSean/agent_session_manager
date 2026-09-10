@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class CodexGhostRepairSnapshotDryRunPreviewRepositoryTests:
    XCTestCase
{
    private let requestID = UUID(
        uuidString: "11111111-2222-4333-8444-555555555555"
    )!
    private let previewID = UUID(
        uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!
    private let target = "019f64d8-4be2-7c60-91ba-8687501cfd66"

    func testPreviewPersistsWithExactImmediateAndColdReadback() throws {
        let databaseURL = try makeDatabaseURL()
        let preview = try makePreview()
        let store = try SQLiteStateStore(databaseURL: databaseURL)

        let stored = try store.saveCodexGhostRepairSnapshotDryRunPreview(
            requestID: requestID,
            preview: preview
        )

        XCTAssertEqual(stored.preview, preview)
        XCTAssertTrue(stored.persistsPreview)
        XCTAssertFalse(stored.confirmationAuthority)
        XCTAssertFalse(stored.repairMutationAuthority)
        XCTAssertEqual(
            try store.codexGhostRepairSnapshotDryRunPreview(
                requestID: requestID
            ),
            stored
        )
        store.close()

        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        defer { reopened.close() }
        XCTAssertEqual(
            try reopened.codexGhostRepairSnapshotDryRunPreview(
                requestID: requestID
            ),
            stored
        )
    }

    func testExactRequestReplayIsIdempotent() throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        let preview = try makePreview()

        let first = try store.saveCodexGhostRepairSnapshotDryRunPreview(
            requestID: requestID,
            preview: preview
        )
        let replay = try store.saveCodexGhostRepairSnapshotDryRunPreview(
            requestID: requestID,
            preview: preview
        )

        XCTAssertEqual(replay, first)
        XCTAssertEqual(try rowCount(at: databaseURL), 1)
    }

    func testChangedRequestPayloadAndReusedPreviewIdentityFailClosed() throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        let preview = try makePreview()
        _ = try store.saveCodexGhostRepairSnapshotDryRunPreview(
            requestID: requestID,
            preview: preview
        )

        XCTAssertThrowsError(
            try store.saveCodexGhostRepairSnapshotDryRunPreview(
                requestID: requestID,
                preview: makePreview(
                    previewID: UUID(
                        uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
                    )!
                )
            )
        )
        XCTAssertThrowsError(
            try store.saveCodexGhostRepairSnapshotDryRunPreview(
                requestID: UUID(
                    uuidString: "22222222-3333-4444-8555-666666666666"
                )!,
                preview: preview
            )
        )
        XCTAssertEqual(try rowCount(at: databaseURL), 1)
    }

    func testTamperedPayloadIsRejectedByDurableReadback() throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        _ = try store.saveCodexGhostRepairSnapshotDryRunPreview(
            requestID: requestID,
            preview: makePreview()
        )

        try execute(
            "UPDATE codex_ghost_repair_dry_run_previews SET payload_json = '{}'",
            at: databaseURL
        )

        XCTAssertThrowsError(
            try store.codexGhostRepairSnapshotDryRunPreview(
                requestID: requestID
            )
        )
    }

    func testSchemaForbidsConfirmationAndRepairAuthority() throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        _ = try store.saveCodexGhostRepairSnapshotDryRunPreview(
            requestID: requestID,
            preview: makePreview()
        )

        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_dry_run_previews SET confirmation_authority = 1",
            at: databaseURL
        ))
        XCTAssertThrowsError(try execute(
            "UPDATE codex_ghost_repair_dry_run_previews SET repair_mutation_authority = 1",
            at: databaseURL
        ))
        XCTAssertEqual(try rowCount(at: databaseURL), 1)
    }

    func testPackagedReadbackUsesExactColdReadOnlyRecord() async throws {
        let databaseURL = try makeDatabaseURL()
        let preview = try makePreview()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let stored = try store.saveCodexGhostRepairSnapshotDryRunPreview(
            requestID: requestID,
            preview: preview
        )
        store.close()
        let bytesBefore = try Data(contentsOf: databaseURL)
        let attributesBefore = try FileManager.default.attributesOfItem(
            atPath: databaseURL.path
        )

        let coordinator =
            CodexGhostRepairSnapshotDryRunLiveReadbackCoordinator(
                databaseURLProvider: { databaseURL }
            )
        let outcome = await coordinator.readback(requestID: requestID)

        guard case let .observed(evidence) = outcome else {
            return XCTFail("Expected exact saved Preview readback")
        }
        XCTAssertEqual(evidence.requestID, requestID)
        XCTAssertEqual(evidence.preview, preview)
        XCTAssertEqual(evidence.payloadHash, stored.payloadHash)
        XCTAssertTrue(evidence.durableReadbackMatched)
        XCTAssertFalse(evidence.readsPublishedSnapshot)
        XCTAssertFalse(evidence.readsCodexData)
        XCTAssertFalse(evidence.writesFilesystem)
        XCTAssertFalse(evidence.confirmationAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)
        XCTAssertEqual(try Data(contentsOf: databaseURL), bytesBefore)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: databaseURL.path)[
                .modificationDate
            ] as? Date,
            attributesBefore[.modificationDate] as? Date
        )
    }

    func testPackagedReadbackNotFoundDoesNotFallbackOrCreate() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        store.close()
        let coordinator =
            CodexGhostRepairSnapshotDryRunLiveReadbackCoordinator(
                databaseURLProvider: { databaseURL }
            )

        let notFound = await coordinator.readback(requestID: requestID)
        XCTAssertEqual(notFound, .notFound(requestID: requestID))

        let missingURL = databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("missing.sqlite")
        let missingCoordinator =
            CodexGhostRepairSnapshotDryRunLiveReadbackCoordinator(
                databaseURLProvider: { missingURL }
            )
        guard case .unavailable = await missingCoordinator.readback(
            requestID: requestID
        ) else {
            return XCTFail("Expected a path-redacted unavailable result")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
    }

    func testPackagedReadbackRejectsTamperedPayloadWithoutRetry() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        _ = try store.saveCodexGhostRepairSnapshotDryRunPreview(
            requestID: requestID,
            preview: makePreview()
        )
        store.close()
        try execute(
            "UPDATE codex_ghost_repair_dry_run_previews SET payload_json = '{}'",
            at: databaseURL
        )
        let coordinator =
            CodexGhostRepairSnapshotDryRunLiveReadbackCoordinator(
                databaseURLProvider: { databaseURL }
            )

        guard case let .unavailable(returnedID, message) =
            await coordinator.readback(requestID: requestID) else {
            return XCTFail("Expected tampered evidence to fail closed")
        }
        XCTAssertEqual(returnedID, requestID)
        XCTAssertFalse(message.contains(databaseURL.path))
        XCTAssertFalse(message.contains("payload_json"))
    }

    func testVerificationBundleContainsAllExactFieldsWithoutNewAuthority() throws {
        let preview = try makePreview()
        let payloadHash = digest("9")
        let bundle = CodexGhostRepairSnapshotDryRunVerificationBundle(
            preview: preview,
            requestID: requestID,
            payloadHash: payloadHash,
            durableReadbackMatched: true
        )

        XCTAssertEqual(
            bundle.text,
            """
            Ghost Repair Snapshot Dry-run Verification Bundle
            Schema: ghost-repair-preview-verification-v1
            Snapshot UUID: 2deddc76-ba46-4eb5-b0f0-7aac17ce2790
            Request ID: 11111111-2222-4333-8444-555555555555
            Preview ID: aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
            Preview digest: \(preview.previewDigest)
            Dry-run token: \(preview.dryRunToken)
            Payload hash: \(payloadHash)
            Exact readback: Matched
            Target IDs:
            - 019f64d8-4be2-7c60-91ba-8687501cfd66
            Confirmation authority: None
            Repair mutation authority: None
            """
        )
        XCTAssertFalse(bundle.text.contains("/Users/"))
        XCTAssertFalse(bundle.readsPublishedSnapshot)
        XCTAssertFalse(bundle.readsCodexData)
        XCTAssertFalse(bundle.readsManagerOwnedState)
        XCTAssertFalse(bundle.writesManagerOwnedState)
        XCTAssertFalse(bundle.retryAuthority)
        XCTAssertFalse(bundle.confirmationAuthority)
        XCTAssertFalse(bundle.repairMutationAuthority)
    }

    private func makePreview(
        previewID: UUID? = nil
    ) throws -> CodexGhostRepairSnapshotDryRunPreview {
        let identity = try CodexGhostRepairSnapshotAnalysisIdentity(
            snapshotID: UUID(
                uuidString: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
            )!,
            targetThreadIDs: [target],
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
        let databases = makeDatabases()
        let readback = CodexGhostRepairSnapshotAnalysisReadback(
            identity: identity,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: databases,
            targets: [
                .init(
                    threadID: target,
                    catalogRowDigests: [digest("a")],
                    automationRunRowDigests: [],
                    automationDefinitionRowDigests: [],
                    references: zeroReferences(),
                    rowContract: .categoryAEligible
                ),
            ],
            authority: .init(
                catalogRevision: 10,
                observationSequence: 20,
                watermarkUpdatedAt: 30,
                metadataRowDigest: digest("d"),
                localSyncRowDigest: digest("e")
            )
        )
        let protection = CodexGhostRepairProtectionEvidence(
            threadID: target,
            inventoryComplete: true,
            activeInventoryPresent: false,
            archivedInventoryPresent: false,
            exactReadNotLoaded: true,
            exactReadErrorCode: -32600,
            pinned: false,
            descendantCount: 0
        )
        let experimental = CodexGhostRepairExperimentalAbsenceEvidence(
            provider: .codex,
            requestedThreadID: target,
            runtimeVersion: "0.149.0",
            method: .threadRead,
            rpcCode: -32600,
            contractIdentifier: "codex-ghost-repair-experimental-absence",
            contractVersion: 1,
            responseShapeIdentifier: "rpc-error-code-message-v1",
            canonicalResponseHash: digest("f"),
            compatibilityFixtureHash: digest("1"),
            packagedCanaryEvidenceHash: digest("2"),
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: databases.map {
                .init(database: $0.database, schemaVersion: $0.schemaVersion)
            }
        )
        let outcome = CodexGhostRepairSnapshotDryRunPlanner.plan(
            identity: identity,
            snapshotEvidence: readback,
            protectionEvidence: [protection],
            experimentalAbsenceEvidence: [experimental],
            operationalAudit: .init(
                codexFullyExited: true,
                desktopOpenHandleCount: 0,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                stateOpenHandleCount: 0,
                threadHistoryOpenHandleCount: 0,
                capacitySufficient: true
            ),
            previewID: previewID ?? self.previewID,
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
        )
        guard case let .preview(preview) = outcome else {
            throw NSError(
                domain: "CodexGhostRepairSnapshotDryRunPreviewRepositoryTests",
                code: 1
            )
        }
        return preview
    }

    private func makeDatabases()
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

    private func zeroReferences()
        -> CodexGhostRepairSnapshotAnalysisReferenceCounts
    {
        .init(
            inbox: 0,
            timeline: 0,
            summaries: 0,
            canonicalState: 0,
            threadTurns: 0,
            threadItems: 0,
            historyProjection: 0
        )
    }

    private func makeDatabaseURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root.appendingPathComponent("manager.sqlite3")
    }

    private func rowCount(at databaseURL: URL) throws -> Int {
        try withDatabase(at: databaseURL) { database in
            var statement: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM codex_ghost_repair_dry_run_previews"
            guard sqlite3_prepare_v2(
                database,
                sql,
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw sqliteError(database)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(database)
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func execute(_ sql: String, at databaseURL: URL) throws {
        try withDatabase(at: databaseURL) { database in
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw sqliteError(database)
            }
        }
    }

    private func withDatabase<T>(
        at databaseURL: URL,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "SQLite", code: Int(result))
        }
        defer { sqlite3_close_v2(database) }
        return try body(database)
    }

    private func sqliteError(_ database: OpaquePointer) -> NSError {
        NSError(
            domain: "SQLite",
            code: Int(sqlite3_errcode(database)),
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(cString: sqlite3_errmsg(database)),
            ]
        )
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}
