@testable import AgentSessionManagerCore
import CSQLite3
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairCategoryAProductionMutatorTests: XCTestCase {
    private let support = M3eCategoryATestFixture()

    func testOneAndTwoItemClaimedCategoryAExecutesExactDesktopTransaction()
        async throws
    {
        for targets in [[support.targetA], [support.targetA, support.targetB]] {
            let fixture = try makeFixture(targets: targets)
            let mutator = fixture.mutator()

            let observed = try await mutator.executeOnce(
                binding: fixture.binding,
                claim: fixture.claim
            )

            XCTAssertEqual(observed.outcome, .success)
            XCTAssertTrue(observed.mutationAttemptedOnce)
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

    func testSourceDriftBeforeTransactionStopsWithoutMutation() async throws {
        let fixture = try makeFixture(targets: [support.targetA])
        try executeSQL(
            "UPDATE sentinel SET value = 'drifted' WHERE id = 1",
            at: fixture.summariesURL
        )

        let observed = try await fixture.mutator().executeOnce(
            binding: fixture.binding,
            claim: fixture.claim
        )

        XCTAssertEqual(observed.outcome, .notAttempted)
        XCTAssertFalse(observed.mutationAttemptedOnce)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            1
        )
    }

    func testBusyIsExplicitFailureAndRecoveryNeverReplays() async throws {
        let fixture = try makeFixture(targets: [support.targetA])
        let busy = fixture.mutator(fault: .explicitBusyBeforeTransaction)

        let failed = try await busy.executeOnce(
            binding: fixture.binding,
            claim: fixture.claim
        )
        let recovered = try await fixture.mutator().recoverByReadback(
            binding: fixture.binding,
            claim: fixture.claim
        )

        XCTAssertEqual(failed.outcome, .explicitFailure)
        XCTAssertTrue(failed.mutationAttemptedOnce)
        XCTAssertEqual(recovered.outcome, .explicitFailure)
        XCTAssertTrue(recovered.mutationAttemptedOnce)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            1
        )
    }

    func testCommitInterruptionRecoversSuccessWithoutSecondTransaction()
        async throws
    {
        let fixture = try makeFixture(
            targets: [support.targetA, support.targetB]
        )
        let interrupted = fixture.mutator(
            fault: .afterCommitBeforeReadback
        )

        let first = try await interrupted.executeOnce(
            binding: fixture.binding,
            claim: fixture.claim
        )
        let recovered = try await fixture.mutator().recoverByReadback(
            binding: fixture.binding,
            claim: fixture.claim
        )

        XCTAssertEqual(first.outcome, .success)
        XCTAssertEqual(recovered.outcome, .success)
        XCTAssertEqual(
            try scalar(
                "SELECT catalog_revision "
                    + "FROM local_thread_catalog_metadata WHERE id = 1",
                at: fixture.desktopURL
            ),
            12
        )
    }

    func testReadbackOnlyDatabaseDriftAfterClaimIsUnknown() async throws {
        let fixture = try makeFixture(targets: [support.targetA])
        try executeSQL(
            "UPDATE sentinel SET value = 'unexpected' WHERE id = 1",
            at: fixture.stateURL
        )

        let recovered = try await fixture.mutator().recoverByReadback(
            binding: fixture.binding,
            claim: fixture.claim
        )

        XCTAssertEqual(recovered.outcome, .unknown)
        XCTAssertTrue(recovered.mutationAttemptedOnce)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            1
        )
    }

    func testCapabilitiesRemainNarrowAndProductionConstructionIsZeroIO()
        throws
    {
        let capabilities = CodexGhostRepairCategoryAProductionMutator.capabilities
        XCTAssertFalse(capabilities.acceptsCallerPath)
        XCTAssertEqual(capabilities.maximumTargetCount, 2)
        XCTAssertTrue(capabilities.categoryAOnly)
        XCTAssertEqual(capabilities.fixedDatabaseGroupCount, 5)
        XCTAssertEqual(capabilities.desktopWriteDatabaseCount, 1)
        XCTAssertEqual(capabilities.readbackOnlyDatabaseCount, 4)
        XCTAssertTrue(capabilities.requiresDurableExternalClaim)
        XCTAssertTrue(capabilities.requiresExactSnapshotFingerprint)
        XCTAssertTrue(capabilities.requiresFreshOperationalGate)
        XCTAssertFalse(capabilities.automaticRetryAllowed)
        XCTAssertFalse(capabilities.automaticRestoreAllowed)

        _ = CodexGhostRepairCategoryAProductionMutator.production()
    }

    private struct Fixture {
        let root: URL
        let codexHome: URL
        let source: CodexGhostRepairSnapshotCanonicalSource
        let bundle: CodexGhostRepairProductionRepairBundle
        let baseline: CodexGhostRepairCategoryARepairSnapshotBaseline
        let binding: CodexGhostRepairCategoryAPreparedRepairBinding
        let claim: CodexGhostRepairCategoryAExecutionClaimEvidence
        let desktopURL: URL
        let summariesURL: URL
        let stateURL: URL

        func mutator(
            fault: CodexGhostRepairCategoryAProductionMutationFault = .none
        ) -> CodexGhostRepairCategoryAProductionMutator {
            .init(
                bundle: bundle,
                source: source,
                gateSource: AlwaysClearRepairGate(),
                baselineResolver: FixedRepairBaseline(value: baseline),
                fault: fault
            )
        }
    }

    private func makeFixture(targets: [String]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-m3i-d-\(UUID().uuidString)",
            isDirectory: true
        )
        let codexHome = root.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        let sqlite = codexHome.appendingPathComponent(
            "sqlite",
            isDirectory: true
        )
        try makeDirectory(root)
        try makeDirectory(codexHome)
        try makeDirectory(sqlite)
        let marker = codexHome.appendingPathComponent(
            CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerFileName
        )
        try Data(
            CodexGhostRepairSnapshotCanonicalSource
                .testMirrorMarkerContents.utf8
        ).write(to: marker)

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
        try createSentinelDatabase(at: legacy, schemaVersion: 3)
        try createSentinelDatabase(at: state, schemaVersion: 0)
        try createSentinelDatabase(at: history, schemaVersion: 0)
        for url in [desktop, summaries, legacy, state, history] {
            XCTAssertEqual(chmod(url.path, S_IRUSR | S_IWUSR), 0)
        }

        let source = CodexGhostRepairSnapshotCanonicalSource(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: root
        )
        let fingerprint = try source.fingerprint()
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
                            cleartextFields:
                                CodexGhostRepairPrivacyContract.catalog
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
        let draft = try support.draft(
            targets: targets,
            catalogDigests: catalogDigests,
            sourceAuthority: authority,
            sourceFingerprintHash: fingerprint.fingerprintHash
        )
        let review = try support.review(draft: draft)
        let challenge = try support.challenge(draft: draft, review: review)
        let binding = try CodexGhostRepairCategoryAPreparedRepairBinding(
            savedPreviewRequestID: UUID(),
            draft: draft,
            review: review,
            challenge: challenge
        )
        let receipt = try support.receipt(challenge: challenge)
        let fresh = try support.freshEvidence(
            draft: draft,
            review: review,
            freshAuthority: authority
        )
        let claim = try CodexGhostRepairCategoryAExecutionPreparation
            .prepareClaimEvidence(
                draft: draft,
                review: review,
                challenge: challenge,
                receipt: receipt,
                executionSnapshotManifestHash: binding.snapshotManifestHash,
                freshEvidence: fresh,
                executionAtMilliseconds: 2_600,
                claimedAtMilliseconds: 2_500
            )
        let baseline = CodexGhostRepairCategoryARepairSnapshotBaseline(
            sourceFingerprintHash: fingerprint.fingerprintHash,
            manifestHash: binding.snapshotManifestHash,
            files: fingerprint.files.map {
                .init(
                    fileName: $0.fileName,
                    exists: $0.exists,
                    size: $0.size,
                    sha256: $0.sha256
                )
            }
        )
        return Fixture(
            root: root,
            codexHome: codexHome,
            source: source,
            bundle: .init(
                testOwnedCodexHomeURL: codexHome,
                testOwnedAllowedParentURL: root
            ),
            baseline: baseline,
            binding: binding,
            claim: claim,
            desktopURL: desktop,
            summariesURL: summaries,
            stateURL: state
        )
    }

    private func createDesktopDatabase(
        at url: URL,
        targets: [String]
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK,
              let database else { throw TestError.sqlite }
        defer { sqlite3_close_v2(database) }
        try executeSQL("PRAGMA user_version = 32", database: database)
        try executeSQL(
            "CREATE TABLE local_thread_catalog("
                + "host_id TEXT NOT NULL, thread_id TEXT NOT NULL, "
                + "missing_candidate INTEGER NOT NULL, "
                + "PRIMARY KEY(host_id, thread_id))",
            database: database
        )
        try executeSQL(
            "CREATE TABLE local_thread_catalog_metadata("
                + "id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL)",
            database: database
        )
        try executeSQL(
            "CREATE TABLE local_thread_catalog_sync_state("
                + "host_id TEXT PRIMARY KEY, "
                + "observation_sequence INTEGER NOT NULL, "
                + "watermark_updated_at INTEGER NOT NULL)",
            database: database
        )
        try executeSQL(
            "INSERT INTO local_thread_catalog_metadata VALUES (1, 10)",
            database: database
        )
        try executeSQL(
            "INSERT INTO local_thread_catalog_sync_state "
                + "VALUES ('local', 20, 30)",
            database: database
        )
        for threadID in targets {
            try executeSQL(
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
        try executeSQL(
            "PRAGMA user_version = \(schemaVersion)",
            database: database
        )
        try executeSQL(
            "CREATE TABLE sentinel(id INTEGER PRIMARY KEY, value TEXT)",
            database: database
        )
        try executeSQL(
            "INSERT INTO sentinel VALUES (1, 'unchanged')",
            database: database
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

    private func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK,
              let database else { throw TestError.sqlite }
        defer { sqlite3_close_v2(database) }
        try executeSQL(sql, database: database)
    }

    private func executeSQL(
        _ sql: String,
        database: OpaquePointer
    ) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        if let message { sqlite3_free(message) }
        guard result == SQLITE_OK else { throw TestError.sqlite }
    }

    private func scalar(_ sql: String, at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database else { throw TestError.sqlite }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement else { throw TestError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestError.sqlite
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private enum TestError: Error { case sqlite }
}

private struct FixedRepairBaseline:
    CodexGhostRepairCategoryARepairSnapshotBaselineResolving,
    Sendable
{
    let value: CodexGhostRepairCategoryARepairSnapshotBaseline

    func baseline(
        binding _: CodexGhostRepairCategoryAPreparedRepairBinding
    ) -> CodexGhostRepairCategoryARepairSnapshotBaseline { value }
}

private struct AlwaysClearRepairGate:
    CodexGhostRepairExecutionGateSource,
    Sendable
{
    func ghostRepairExecutionGate() -> CodexGhostRepairExecutionGate {
        .init(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            stateOpenHandleCount: 0,
            threadHistoryOpenHandleCount: 0,
            capacitySufficient: true
        )
    }
}
