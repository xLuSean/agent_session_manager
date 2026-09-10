@testable import AgentSessionManagerCore
import CSQLite3
import Darwin
import Foundation
import XCTest

#if AGENT_SESSION_MANAGER_RESEARCH

@_silgen_name("fork")
private func asmFreshRecoveryTestFork() -> pid_t

final class CodexGhostRepairBulkProductionMutatorTests: XCTestCase {
    func testManualResidueCleanupPreservesOtherSummariesAndPausedAutomation() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, reviewedResidue: true)
        let summaries = fixture.codexHome.appendingPathComponent("sqlite/codex-thread-summaries-dev.db")
        let before = try CodexGhostRepairProductionSQLite(url: fixture.desktopURL, readOnly: true)
        let definitions = try before.query("SELECT * FROM automations ORDER BY id", maximumRows: 10)
        before.close()
        XCTAssertEqual(fixture.storedPreview.preview.selectedItems.map { $0.reviewedResidue?.summaryRowDigests.count }, [1, 1])
        XCTAssertEqual(try CodexGhostRepairBulkBackupBoundOperationPlan.decodeValidated(fixture.livePlan.encodedForPersistence()), fixture.livePlan)
        let result = try await fixture.liveMutator().executeOnce(plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog", at: fixture.desktopURL), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM thread_turn_summaries", at: summaries), 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM thread_turn_summaries WHERE summary = 'summary-2'", at: summaries), 1)
        let after = try CodexGhostRepairProductionSQLite(url: fixture.desktopURL, readOnly: true)
        defer { after.close() }
        XCTAssertEqual(try after.query("SELECT * FROM automations ORDER BY id", maximumRows: 10), definitions)
        let recovered = try await fixture.liveMutator().recoverByReadback(plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(recovered, .success)
    }

    func testManualSummaryFailureRollsBackWholeAttachedTransaction() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, reviewedResidue: true)
        let summaries = fixture.codexHome.appendingPathComponent("sqlite/codex-thread-summaries-dev.db")
        let result = try await fixture.liveMutator(fault: .afterSummaryRemoval).executeOnce(
            plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(result, .explicitFailure)
        XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog", at: fixture.desktopURL), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM thread_turn_summaries", at: summaries), 3)
    }

    func testManualSummaryContentDriftIsRejectedEvenWithSameCount() throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, reviewedResidue: true)
        try execute("UPDATE thread_turn_summaries SET summary = 'changed' WHERE summary = 'summary-0'",
                    at: fixture.codexHome.appendingPathComponent("sqlite/codex-thread-summaries-dev.db"))
        let state = try CodexGhostRepairBulkLiveMixedMutator.inspect(selectedItems: fixture.livePlan.selectedItems, resolution: fixture.bundle.resolveForPreflight())
        XCTAssertFalse(CodexGhostRepairBulkLiveMixedMutator.matchesFrozenTargets(state, selectedItems: fixture.livePlan.selectedItems))
    }

    func testManualSummaryCommitInterruptionRecoversWithoutRepeatingMutation() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, reviewedResidue: true)
        let result = try await fixture.liveMutator(fault: .afterCommitBeforeReadback).executeOnce(
            plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(result, .success)
        let recovered = try await fixture.liveMutator().recoverByReadback(plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(recovered, .success)
        XCTAssertEqual(try scalar("SELECT catalog_revision FROM local_thread_catalog_metadata WHERE id = 1", at: fixture.desktopURL), 1002)
    }

    func testManualPartialCrossDatabaseOutcomeStaysUnknownAndNeverReplays() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, reviewedResidue: true)
        let summaries = fixture.codexHome.appendingPathComponent("sqlite/codex-thread-summaries-dev.db")
        // Model a crash where only one database's changes survived.
        try execute("DELETE FROM thread_turn_summaries WHERE summary = 'summary-0'", at: summaries)
        let result = try await fixture.liveMutator().recoverByReadback(
            plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt)
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog", at: fixture.desktopURL), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM thread_turn_summaries", at: summaries), 2)
    }

    func testProductionSQLiteAcceptsCurrentCodex0644Protection() throws {
        let fixture = try makeFixture(itemCount: 2)
        XCTAssertEqual(chmod(fixture.desktopURL.path, 0o644), 0)

        let database = try CodexGhostRepairProductionSQLite(
            url: fixture.desktopURL,
            readOnly: true
        )
        defer { database.close() }

        XCTAssertTrue(try database.integrityPassed())
    }

    func testProductionSQLiteRejectsGroupWritableDatabase() throws {
        let fixture = try makeFixture(itemCount: 2)
        XCTAssertEqual(chmod(fixture.desktopURL.path, 0o664), 0)

        XCTAssertThrowsError(
            try CodexGhostRepairProductionSQLite(
                url: fixture.desktopURL,
                readOnly: true
            )
        ) { error in
            guard case let CodexGhostRepairError.invalidProtectionEvidence(
                message
            ) = error
            else {
                return XCTFail("Expected invalid protection evidence, got \(error).")
            }
            XCTAssertEqual(
                message,
                "Fixed Codex database is writable by group or other "
                    + "accounts (mode 664)."
            )
        }
    }

    func testProductionSQLiteRejectsHardLinkedDatabase() throws {
        let fixture = try makeFixture(itemCount: 2)
        let additionalLink = fixture.parent.appendingPathComponent(
            "unexpected-desktop-link.sqlite"
        )
        try FileManager.default.linkItem(
            at: fixture.desktopURL,
            to: additionalLink
        )

        XCTAssertThrowsError(
            try CodexGhostRepairProductionSQLite(
                url: fixture.desktopURL,
                readOnly: true
            )
        ) { error in
            guard case let CodexGhostRepairError.invalidProtectionEvidence(
                message
            ) = error
            else {
                return XCTFail("Expected invalid protection evidence, got \(error).")
            }
            XCTAssertEqual(
                message,
                "Fixed Codex database has 2 hard links; exactly one is required."
            )
        }
    }

    func testFinalReviewAllowsUnrelatedChangeSinceFrozenPreview()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        try execute(
            "INSERT INTO local_thread_catalog VALUES('local', "
                + "'unselected-session', 0, 'unrelated')",
            at: fixture.desktopURL
        )
        try execute(
            "UPDATE sentinel SET value = 'normal-later-codex-activity' "
                + "WHERE id = 1",
            at: fixture.stateURL
        )
        try execute(
            "UPDATE local_thread_catalog_metadata "
                + "SET catalog_revision = 1001 WHERE id = 1",
            at: fixture.desktopURL
        )
        try execute(
            "UPDATE local_thread_catalog_sync_state "
                + "SET observation_sequence = 2001 WHERE host_id = 'local'",
            at: fixture.desktopURL
        )
        let currentFingerprint = try fixture.source.fingerprint()
        XCTAssertNotEqual(
            currentFingerprint.fingerprintHash,
            fixture.storedPreview.frozenSource?.sourceFingerprintHash
        )
        let currentBackup = try CodexGhostRepairBulkLiveBackupReceipt(
            destination: fixture.livePlan.destination,
            sourceFingerprint: currentFingerprint,
            capturedAtMilliseconds: 1_500
        )
        let revalidator = try CodexGhostRepairBulkLiveTargetRevalidator(
            repairResolution: fixture.bundle.resolveForPreflight(),
            gateSource: AlwaysClearBulkRepairGate(),
            fingerprintReader: { try fixture.source.fingerprint() },
            nowMilliseconds: { 1_550 }
        )

        let result = try await revalidator.revalidate(
            storedPreview: fixture.storedPreview,
            resolution: fixture.bulkResolution,
            verifiedBackup: currentBackup
        )

        XCTAssertEqual(
            result.frozenSourceDigest,
            fixture.storedPreview.frozenSource?.sourceDigest
        )
        XCTAssertEqual(result.backupReceiptDigest, currentBackup.receiptDigest)
        XCTAssertEqual(result.databaseEvidence.count, 4)
        XCTAssertEqual(result.alreadyAbsentThreadIDs, [])
        XCTAssertEqual(result.authority.catalogRevision, 1_001)
        XCTAssertEqual(result.authority.observationSequence, 2_001)
        let plan = try CodexGhostRepairBulkBackupBoundOperationPlan.prepare(
            coldReadback: fixture.storedPreview,
            resolution: fixture.bulkResolution,
            destination: fixture.livePlan.destination,
            verifiedBackup: currentBackup,
            liveRevalidation: result,
            plannedAtMilliseconds: 1_550
        )
        XCTAssertEqual(plan.authority, result.authority)
        XCTAssertNotEqual(
            plan.authority,
            fixture.storedPreview.frozenSource?.authority
        )
        let claim = try CodexGhostRepairBulkLiveMixedClaim(
            claimID: UUID(),
            plan: plan,
            claimedAtMilliseconds: 1_600
        )
        let attempt = try CodexGhostRepairBulkLiveMixedAttempt(
            claim: claim,
            attemptedAtMilliseconds: 1_700
        )
        let mutator = CodexGhostRepairBulkLiveMixedMutator(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedAllowedParentURL: fixture.parent,
            gateSource: AlwaysClearBulkRepairGate(),
            backupReader: FixedBulkLiveBackupReadback(value: currentBackup)
        )
        let mutationOutcome = try await mutator.executeOnce(
            plan: plan,
            claim: claim,
            attempt: attempt
        )
        XCTAssertEqual(mutationOutcome, .success)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog "
                + "WHERE thread_id = 'unselected-session'",
            at: fixture.desktopURL
        ), 1)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 1)
    }

    func testFinalReviewAllowsVolatileSHMChangeDuringTargetInspection()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        let before = try fixture.source.fingerprint()
        let after = try replacingFingerprintMember(
            .stateSHM,
            in: before,
            seed: 8_001
        )
        XCTAssertNotEqual(before.fingerprintHash, after.fingerprintHash)
        let backup = try CodexGhostRepairBulkLiveBackupReceipt(
            destination: fixture.livePlan.destination,
            sourceFingerprint: before,
            capturedAtMilliseconds: 1_500
        )
        let fingerprints = SequentialBulkFingerprintReader([before, after])
        let revalidator = try CodexGhostRepairBulkLiveTargetRevalidator(
            repairResolution: fixture.bundle.resolveForPreflight(),
            gateSource: AlwaysClearBulkRepairGate(),
            fingerprintReader: { try fingerprints.next() },
            nowMilliseconds: { 1_550 }
        )

        let result = try await revalidator.revalidate(
            storedPreview: fixture.storedPreview,
            resolution: fixture.bulkResolution,
            verifiedBackup: backup
        )

        XCTAssertEqual(result.backupReceiptDigest, backup.receiptDigest)
        XCTAssertEqual(result.alreadyAbsentThreadIDs, [])
    }

    func testFinalReviewRejectsStableMemberChangeDuringTargetInspection()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        let before = try fixture.source.fingerprint()
        let after = try replacingFingerprintMember(
            .desktop,
            in: before,
            seed: 8_002
        )
        let backup = try CodexGhostRepairBulkLiveBackupReceipt(
            destination: fixture.livePlan.destination,
            sourceFingerprint: before,
            capturedAtMilliseconds: 1_500
        )
        let fingerprints = SequentialBulkFingerprintReader([before, after])
        let revalidator = try CodexGhostRepairBulkLiveTargetRevalidator(
            repairResolution: fixture.bundle.resolveForPreflight(),
            gateSource: AlwaysClearBulkRepairGate(),
            fingerprintReader: { try fingerprints.next() },
            nowMilliseconds: { 1_550 }
        )

        do {
            _ = try await revalidator.revalidate(
                storedPreview: fixture.storedPreview,
                resolution: fixture.bulkResolution,
                verifiedBackup: backup
            )
            XCTFail("Expected stable source drift to stop Final Review.")
        } catch let error as CodexGhostRepairError {
            guard case let .targetDrift(detail) = error else {
                return XCTFail("Expected target drift, received \(error).")
            }
            XCTAssertEqual(
                detail,
                "Stable Codex source member codex-dev.db changed during "
                    + "target inspection."
            )
        }
    }

    func testFinalReviewRejectsSelectedSideReferenceDriftEvenWithFreshBackup()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        try execute(
            "INSERT INTO inbox_items(thread_id) VALUES ('\(identifier(0))')",
            at: fixture.desktopURL
        )
        let currentFingerprint = try fixture.source.fingerprint()
        let currentBackup = try CodexGhostRepairBulkLiveBackupReceipt(
            destination: fixture.livePlan.destination,
            sourceFingerprint: currentFingerprint,
            capturedAtMilliseconds: 1_500
        )
        let revalidator = try CodexGhostRepairBulkLiveTargetRevalidator(
            repairResolution: fixture.bundle.resolveForPreflight(),
            gateSource: AlwaysClearBulkRepairGate(),
            fingerprintReader: { try fixture.source.fingerprint() },
            nowMilliseconds: { 1_550 }
        )

        do {
            _ = try await revalidator.revalidate(
                storedPreview: fixture.storedPreview,
                resolution: fixture.bulkResolution,
                verifiedBackup: currentBackup
            )
            XCTFail("Expected selected target drift to stop Final Review.")
        } catch let error as CodexGhostRepairError {
            guard case let .targetDrift(detail) = error else {
                return XCTFail("Expected target drift, received \(error).")
            }
            XCTAssertEqual(
                detail,
                "Selected session \(identifier(0)) now has protected side references."
            )
        }
    }

    func testFinalReviewAllowsSelectedDisplayAndAutomationRefreshDrift()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10, desktopSchema: 33)
        try execute(
            "UPDATE local_thread_catalog SET title = 'refreshed-title', "
                + "missing_candidate = 0 "
                + "WHERE thread_id = '\(identifier(0))'",
            at: fixture.desktopURL
        )
        try execute(
            "UPDATE automation_runs SET status = 'PENDING_REVIEW', "
                + "updated_at = 1499 WHERE thread_id = '\(identifier(1))'",
            at: fixture.desktopURL
        )
        try execute(
            "UPDATE automations SET notification_policy = 'refreshed' "
                + "WHERE id = 'automation-1'",
            at: fixture.desktopURL
        )
        let currentFingerprint = try fixture.source.fingerprint()
        let currentBackup = try CodexGhostRepairBulkLiveBackupReceipt(
            destination: fixture.livePlan.destination,
            sourceFingerprint: currentFingerprint,
            capturedAtMilliseconds: 1_500
        )
        let revalidator = try CodexGhostRepairBulkLiveTargetRevalidator(
            repairResolution: fixture.bundle.resolveForPreflight(),
            gateSource: AlwaysClearBulkRepairGate(),
            fingerprintReader: { try fixture.source.fingerprint() },
            nowMilliseconds: { 1_550 }
        )

        let result = try await revalidator.revalidate(
            storedPreview: fixture.storedPreview,
            resolution: fixture.bulkResolution,
            verifiedBackup: currentBackup
        )

        XCTAssertEqual(
            result.selectedThreadIDsDigest,
            try CodexGhostRepairHasher.hash(
                fixture.livePlan.selectedThreadIDs
            )
        )
    }

    func testFinalReviewRejectsAutomationEligibilityDrift() async throws {
        let fixture = try makeFixture(itemCount: 10, desktopSchema: 33)
        try execute(
            "UPDATE automation_runs SET status = 'ARCHIVED', "
                + "archived_reason = 'auto' "
                + "WHERE thread_id = '\(identifier(1))'",
            at: fixture.desktopURL
        )
        let currentFingerprint = try fixture.source.fingerprint()
        let currentBackup = try CodexGhostRepairBulkLiveBackupReceipt(
            destination: fixture.livePlan.destination,
            sourceFingerprint: currentFingerprint,
            capturedAtMilliseconds: 1_500
        )
        let revalidator = try CodexGhostRepairBulkLiveTargetRevalidator(
            repairResolution: fixture.bundle.resolveForPreflight(),
            gateSource: AlwaysClearBulkRepairGate(),
            fingerprintReader: { try fixture.source.fingerprint() },
            nowMilliseconds: { 1_550 }
        )

        do {
            _ = try await revalidator.revalidate(
                storedPreview: fixture.storedPreview,
                resolution: fixture.bulkResolution,
                verifiedBackup: currentBackup
            )
            XCTFail("Expected automation eligibility drift to stop Final Review.")
        } catch let error as CodexGhostRepairError {
            guard case let .targetDrift(detail) = error else {
                return XCTFail("Expected target drift, received \(error).")
            }
            XCTAssertEqual(
                detail,
                "Selected session \(identifier(1)) changed automation eligibility fields."
            )
        }
    }

    func testPackagedPlanPreparerRunsExact148ItemProductionSequence()
        async throws
    {
        let fixture = try makeFixture(itemCount: 148)
        let managerRoot = fixture.parent.appendingPathComponent(
            "manager",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managerRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = managerRoot.appendingPathComponent(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector
                .markerFileName
        )
        try Data(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector
                .markerContents.utf8
        ).write(to: marker)
        XCTAssertEqual(chmod(marker.path, 0o600), 0)
        let storageRoot = managerRoot.appendingPathComponent(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector
                .ghostRepairDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storageRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let source = fixture.source
        let frozenAuthority = try XCTUnwrap(
            fixture.storedPreview.frozenSource
        ).authority
        let repairResolution = try fixture.bundle.resolveForPreflight()
        let backupEnvironment = try CodexGhostRepairBulkLiveBackupEnvironment(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedSourceAllowedParentURL: fixture.parent,
            testOwnedManagerRootURL: managerRoot,
            testOwnedManagerAllowedParentURL: fixture.parent,
            nowMilliseconds: { 1_400 }
        )
        let preparer = CodexGhostRepairBulkPackagedPlanPreparer(
            storeProvider: {
                try SQLiteStateStore(databaseURL: fixture.managerStateURL)
            },
            resolutionProvider: { storedPreview in
                let resolution = try CodexGhostRepairBulkProductionBundle(
                    coldReadback: storedPreview,
                    testOwnedCodexHomeURL: fixture.codexHome,
                    testOwnedAllowedParentURL: fixture.parent
                ).resolveForTestOwnedAdoption()
                return (resolution, .v149DesktopV32)
            },
            maintenanceObserverProvider: { profile in
                CodexGhostRepairBulkProductionMaintenanceObserver(
                    profile: profile,
                    gateSource: AlwaysClearBulkRepairGate(),
                    fingerprintReader: { try source.fingerprint() },
                    authorityReader: { _ in frozenAuthority },
                    sourceAdmission: { _ in true },
                    nowMilliseconds: { 1_350 }
                )
            },
            backupTransportProvider: { resolution, window in
                try CodexGhostRepairBulkLiveBackupTransport(
                    resolution: resolution,
                    maintenanceWindow: window,
                    environment: backupEnvironment
                )
            },
            targetRevalidatorProvider: { _ in
                try CodexGhostRepairBulkLiveTargetRevalidator(
                    repairResolution: repairResolution,
                    gateSource: AlwaysClearBulkRepairGate(),
                    fingerprintReader: { try source.fingerprint() },
                    nowMilliseconds: { 1_500 }
                )
            }
        )

        let prepared = try await preparer.prepare(
            confirmationReceiptID: fixture.confirmationReceipt.receiptID
        )

        XCTAssertEqual(prepared.receipt, fixture.confirmationReceipt)
        XCTAssertEqual(prepared.plan.selectedCount, 148)
        XCTAssertEqual(prepared.plan.ordinaryCount, 74)
        XCTAssertEqual(prepared.plan.automationCount, 74)
        XCTAssertEqual(prepared.plan.backup.files.count, 20)
        XCTAssertFalse(prepared.plan.createsClaim)
        XCTAssertFalse(prepared.plan.repairMutationAuthority)

        let journal = CodexGhostRepairBulkLivePackagedExecutionJournal {
            try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        }
        let mutator = CodexGhostRepairBulkLiveMixedMutator(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedAllowedParentURL: fixture.parent,
            gateSource: AlwaysClearBulkRepairGate(),
            backupReader: FixedBulkLiveBackupReadback(
                value: prepared.plan.backup,
                fails: false
            )
        )
        let runner = CodexGhostRepairBulkLiveOneShotCoordinator(
            journal: journal,
            mutator: mutator,
            nowMilliseconds: { 1_600 },
            makeUUID: {
                UUID(
                    uuidString: "92000000-0000-4000-8000-000000000001"
                )!
            }
        )
        _ = try await runner.prepare(
            plan: prepared.plan,
            confirmationReceipt: prepared.receipt
        )
        let report = try await runner.execute(
            requestID: prepared.plan.requestID,
            expectedPlanDigest: prepared.plan.planDigest
        )
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.count, 148)
        XCTAssertEqual(
            try scalar("SELECT count(*) FROM local_thread_catalog", at: fixture.desktopURL),
            0
        )
    }

    func testM4f20DesktopV33Exact148MixedBatchIsAtomicAndColdRecoverable()
        async throws
    {
        let fixture = try makeFixture(itemCount: 148, desktopSchema: 33)

        let coordinator = fixture.liveCoordinator()
        _ = try await coordinator.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let report = try await coordinator.execute(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.count, 148)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 0)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM automation_runs WHERE status = 'ARCHIVED' "
                + "AND archived_reason = 'auto' AND updated_at = 1600",
            at: fixture.desktopURL
        ), 74)
        XCTAssertEqual(try scalar(
            "SELECT catalog_revision FROM local_thread_catalog_metadata "
                + "WHERE id = 1",
            at: fixture.desktopURL
        ), 1_148)

        let replay = try await coordinator.execute(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest
        )
        XCTAssertEqual(replay, report)
    }

    func testM4f20DesktopV33NewAutomationFieldDriftStopsWholeBatch()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10, desktopSchema: 33)
        try execute(
            "UPDATE automations SET notification_policy = 'drifted' "
                + "WHERE id = 'automation-1'",
            at: fixture.desktopURL
        )

        let outcome = try await fixture.liveMutator().executeOnce(
            plan: fixture.livePlan,
            claim: fixture.liveClaim,
            attempt: fixture.liveAttempt
        )

        XCTAssertEqual(outcome, .notAttempted)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 10)
    }

    func testM4f17ExactPlanUsesOneMixedTransactionAndColdReadback()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        let outcome = try await fixture.liveMutator().executeOnce(
            plan: fixture.livePlan,
            claim: fixture.liveClaim,
            attempt: fixture.liveAttempt
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 0)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM automation_runs WHERE status = 'ARCHIVED' "
                + "AND archived_reason = 'auto' AND updated_at = 1600",
            at: fixture.desktopURL
        ), 5)
        XCTAssertEqual(try scalar(
            "SELECT catalog_revision FROM local_thread_catalog_metadata "
                + "WHERE id = 1",
            at: fixture.desktopURL
        ), 1_010)
        let recovered = try await fixture.liveMutator().recoverByReadback(
            plan: fixture.livePlan,
            claim: fixture.liveClaim,
            attempt: fixture.liveAttempt
        )
        XCTAssertEqual(recovered, .success)
    }

    func testLiveExecutorAllowsVolatileSHMChangeAfterVerifiedBackup()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        let shmURL = CodexGhostRepairSnapshotCanonicalFile.stateSHM.sourceURL(
            codexHomeURL: fixture.codexHome,
            sqliteRootURL: fixture.codexHome.appendingPathComponent(
                "sqlite",
                isDirectory: true
            )
        )
        try Data("volatile WAL index".utf8).write(to: shmURL)
        XCTAssertEqual(chmod(shmURL.path, 0o600), 0)

        let outcome = try await fixture.liveMutator().executeOnce(
            plan: fixture.livePlan,
            claim: fixture.liveClaim,
            attempt: fixture.liveAttempt
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 0)
    }

    func testLiveBatchKeepsAlreadyAbsentTargetsAndDeletesTheRemainder()
        async throws
    {
        let alreadyAbsentIndices = Set(0..<12)
        let fixture = try makeFixture(
            itemCount: 135,
            desktopSchema: 33,
            alreadyAbsentIndices: alreadyAbsentIndices
        )

        XCTAssertEqual(fixture.livePlan.selectedCount, 135)
        XCTAssertEqual(fixture.livePlan.alreadyAbsentCount, 12)
        XCTAssertEqual(fixture.livePlan.actionableCount, 129)
        XCTAssertEqual(fixture.livePlan.catalogDeletionCount, 123)
        XCTAssertEqual(
            fixture.livePlan.selectedItems.filter {
                [.alreadyAbsent, .archiveAutomation]
                    .contains($0.expectedEffect)
            }.map(\.threadID),
            alreadyAbsentIndices.sorted().map(identifier)
        )

        let coordinator = fixture.liveCoordinator()
        _ = try await coordinator.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let report = try await coordinator.execute(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest
        )

        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.count, 135)
        XCTAssertEqual(
            report.items.filter { $0.outcome == .alreadyAbsent }
                .map(\.threadID),
            alreadyAbsentIndices.sorted()
                .filter { $0.isMultiple(of: 2) }
                .map(identifier)
        )
        XCTAssertEqual(
            report.items.filter { $0.outcome == .success }.count,
            129
        )
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 0)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM automation_runs WHERE status = 'ARCHIVED' "
                + "AND archived_reason = 'auto' AND updated_at = 1600",
            at: fixture.desktopURL
        ), 67)
        XCTAssertEqual(try scalar(
            "SELECT catalog_revision FROM local_thread_catalog_metadata "
                + "WHERE id = 1",
            at: fixture.desktopURL
        ), 1_135)
        XCTAssertEqual(try scalar(
            "SELECT observation_sequence "
                + "FROM local_thread_catalog_sync_state "
                + "WHERE host_id = 'local'",
            at: fixture.desktopURL
        ), 2_135)
    }

    func testInitiallyClearAndGhostTargetsStayInOneDurableMixedBatch() async throws {
        let clear = Set([0, 2, 4, 6, 8, 10])
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 148, initiallyAbsentIndices: clear)
        XCTAssertEqual(fixture.inventory.items.filter { $0.initiallyAbsent == true }.count, 6)
        XCTAssertEqual(fixture.storedPreview.preview.selectedItems.count, 148)
        XCTAssertEqual(fixture.livePlan.catalogDeletionCount, 142)
        XCTAssertEqual(fixture.livePlan.alreadyAbsentCount, 6)
        XCTAssertEqual(fixture.livePlan.selectedItems.filter { $0.catalogRowDigest == nil }.count, 6)
        let coordinator = fixture.liveCoordinator()
        _ = try await coordinator.prepare(plan: fixture.livePlan, confirmationReceipt: fixture.confirmationReceipt)
        let report = try await coordinator.execute(requestID: fixture.livePlan.requestID, expectedPlanDigest: fixture.livePlan.planDigest)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.count, 148)
        XCTAssertEqual(report.items.filter { $0.outcome == .alreadyAbsent }.map(\.threadID), clear.sorted().map(identifier))
        XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog", at: fixture.desktopURL), 0)
        XCTAssertEqual(try scalar("SELECT catalog_revision FROM local_thread_catalog_metadata", at: fixture.desktopURL), 1148)
        // A cold reconstruction must retain the same exact terminal result.
        let cold = fixture.liveCoordinator()
        let reread = try await cold.execute(requestID: fixture.livePlan.requestID, expectedPlanDigest: fixture.livePlan.planDigest)
        XCTAssertEqual(reread, report)
    }

    func testInitiallyClearTargetReappearingBlocksTheEntireMixedBatch() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 10, initiallyAbsentIndices: [0, 2])
        let id = identifier(0)
        try execute("INSERT INTO local_thread_catalog VALUES('local', '\(id)', 1, 'Reappeared')", at: fixture.desktopURL)
        let frozen = fixture.livePlan.selectedItems
        let observed = try CodexGhostRepairBulkLiveMixedMutator.inspect(selectedItems: frozen, resolution: fixture.bundle.resolveForPreflight())
        XCTAssertTrue(CodexGhostRepairBulkLiveMixedMutator.frozenTargetMismatch(observed, selectedItems: frozen, allowAlreadyAbsent: true)?.contains("reappeared") == true)
        XCTAssertEqual(frozen.first { $0.threadID == id }?.expectedEffect, .alreadyAbsent)
        let coordinator = fixture.liveCoordinator()
        _ = try await coordinator.prepare(plan: fixture.livePlan, confirmationReceipt: fixture.confirmationReceipt)
        let report = try await coordinator.execute(requestID: fixture.livePlan.requestID, expectedPlanDigest: fixture.livePlan.planDigest)
        XCTAssertNotEqual(report.outcome, .success)
        XCTAssertEqual(try scalar("SELECT count(*) FROM local_thread_catalog", at: fixture.desktopURL), 9)
    }

    func testM4f17SourceDriftStopsBeforeTransaction() async throws {
        let fixture = try makeFixture(itemCount: 2)
        try execute(
            "UPDATE sentinel SET value = 'drifted' WHERE id = 1",
            at: fixture.stateURL
        )
        let outcome = try await fixture.liveMutator().executeOnce(
            plan: fixture.livePlan,
            claim: fixture.liveClaim,
            attempt: fixture.liveAttempt
        )
        XCTAssertEqual(outcome, .notAttempted)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)
    }

    func testM4f17BusyFailsOnceAndReadbackDoesNotRetry() async throws {
        let fixture = try makeFixture(itemCount: 2)
        let failed = try await fixture.liveMutator(
            fault: .explicitBusyBeforeTransaction
        ).executeOnce(
            plan: fixture.livePlan,
            claim: fixture.liveClaim,
            attempt: fixture.liveAttempt
        )
        XCTAssertEqual(failed, .explicitFailure)
        let recovered = try await fixture.liveMutator().recoverByReadback(
            plan: fixture.livePlan,
            claim: fixture.liveClaim,
            attempt: fixture.liveAttempt
        )
        XCTAssertEqual(recovered, .explicitFailure)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)
    }

    func testM4f17CommitInterruptionUsesReadbackOnlyRecovery()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let interrupted = try await fixture.liveMutator(
            fault: .afterCommitBeforeReadback
        ).executeOnce(
            plan: fixture.livePlan,
            claim: fixture.liveClaim,
            attempt: fixture.liveAttempt
        )
        XCTAssertEqual(interrupted, .success)
        let recovered = try await fixture.liveMutator().recoverByReadback(
            plan: fixture.livePlan,
            claim: fixture.liveClaim,
            attempt: fixture.liveAttempt
        )
        XCTAssertEqual(recovered, .success)
        XCTAssertEqual(try scalar(
            "SELECT catalog_revision FROM local_thread_catalog_metadata "
                + "WHERE id = 1",
            at: fixture.desktopURL
        ), 1_002)
    }

    func testM4f17BackupReadbackFailureStopsBeforeMutation() async throws {
        let fixture = try makeFixture(itemCount: 2)
        let mutator = fixture.liveMutator(backupFails: true)
        do {
            _ = try await mutator.executeOnce(
                plan: fixture.livePlan,
                claim: fixture.liveClaim,
                attempt: fixture.liveAttempt
            )
            XCTFail("Expected exact backup readback failure.")
        } catch {
            XCTAssertNotNil(error as? CodexGhostRepairError)
        }
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)
    }

    func testM4f17ProductionConstructionIsPathFreeAndAuthorityFree() throws {
        let fixture = try makeFixture(itemCount: 2)
        _ = CodexGhostRepairBulkLiveMixedMutator.production(
            backupReader: FixedBulkLiveBackupReadback(
                value: fixture.livePlan.backup
            ),
            profile: .v149DesktopV32
        )
        let value = CodexGhostRepairBulkLiveMixedMutatorCapabilities()
        XCTAssertTrue(value.productionFactoryAvailable)
        XCTAssertFalse(value.productionConstructionPerformsIO)
        XCTAssertFalse(value.productionFactoryAcceptsCallerPath)
        XCTAssertEqual(value.maximumTargetCount, 500)
        XCTAssertTrue(value.exactBackupBoundPlanRequired)
        XCTAssertTrue(value.exactVerifiedBackupReadbackRequired)
        XCTAssertTrue(value.durableExternalClaimAndAttemptRequired)
        XCTAssertTrue(value.freshOperationalGateRequired)
        XCTAssertTrue(value.singleDesktopTransaction)
        XCTAssertTrue(value.mixedOrdinaryAndAutomation)
        XCTAssertEqual(value.readbackOnlyDatabaseCount, 4)
        XCTAssertFalse(value.automaticRetryAllowed)
        XCTAssertFalse(value.automaticRestoreAllowed)
        XCTAssertFalse(value.appWiringAvailable)
        XCTAssertFalse(value.liveExecutionAuthorized)
        XCTAssertFalse(value.repairMutationAuthority)
    }

    func testM4f18PersistsOneAttemptAndReplaysExactTerminalReport()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        let coordinator = fixture.liveCoordinator()
        let prepared = try await coordinator.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        XCTAssertEqual(prepared.phase, .prepared)

        let first = try await coordinator.execute(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest
        )
        let second = try await coordinator.execute(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.outcome, .success)
        XCTAssertEqual(first.items.count, 10)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 0)
        XCTAssertEqual(try scalar(
            "SELECT catalog_revision FROM local_thread_catalog_metadata "
                + "WHERE id = 1",
            at: fixture.desktopURL
        ), 1_010)

        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { store.close() }
        let record = try XCTUnwrap(
            store.codexGhostRepairBulkLiveExecutionJournal(
                requestID: fixture.livePlan.requestID
            )
        )
        XCTAssertEqual(record.phase, .terminal)
        XCTAssertEqual(record.mutationAttemptCount, 1)
        XCTAssertEqual(record.report, first)
        XCTAssertFalse(record.automaticRetryAllowed)
        XCTAssertFalse(record.automaticRestoreAllowed)
        XCTAssertFalse(record.silentSelectionShrinkAllowed)
    }

    func testM4f18ColdRestartAfterClaimFinalizesWithoutAttempt()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let interrupted = fixture.liveCoordinator(fault: .afterClaim)
        _ = try await interrupted.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        do {
            _ = try await interrupted.execute(
                requestID: fixture.livePlan.requestID,
                expectedPlanDigest: fixture.livePlan.planDigest
            )
            XCTFail("Expected deterministic interruption after claim.")
        } catch {
            XCTAssertNotNil(error as? CodexGhostRepairError)
        }

        let cold = fixture.liveCoordinator()
        let report = try await cold.execute(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest
        )
        XCTAssertEqual(report.outcome, .notAttempted)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)

        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { store.close() }
        let record = try XCTUnwrap(
            store.codexGhostRepairBulkLiveExecutionJournal(
                requestID: fixture.livePlan.requestID
            )
        )
        XCTAssertEqual(record.phase, .terminal)
        XCTAssertEqual(record.mutationAttemptCount, 0)
        XCTAssertNil(record.attempt)
    }

    func testM4f18ColdRestartAfterAttemptUsesReadbackOnly()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let interrupted = fixture.liveCoordinator(fault: .afterAttempt)
        _ = try await interrupted.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        do {
            _ = try await interrupted.execute(
                requestID: fixture.livePlan.requestID,
                expectedPlanDigest: fixture.livePlan.planDigest
            )
            XCTFail("Expected deterministic interruption after attempt.")
        } catch {
            XCTAssertNotNil(error as? CodexGhostRepairError)
        }

        let cold = fixture.liveCoordinator()
        let report = try await cold.execute(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest
        )
        XCTAssertEqual(report.outcome, .explicitFailure)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)
        XCTAssertEqual(try scalar(
            "SELECT catalog_revision FROM local_thread_catalog_metadata "
                + "WHERE id = 1",
            at: fixture.desktopURL
        ), 1_000)

        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { store.close() }
        let record = try XCTUnwrap(
            store.codexGhostRepairBulkLiveExecutionJournal(
                requestID: fixture.livePlan.requestID
            )
        )
        XCTAssertEqual(record.phase, .terminal)
        XCTAssertEqual(record.mutationAttemptCount, 1)
    }

    func testM4f18RejectsReceiptFromAnotherExactBatch() async throws {
        let fixture = try makeFixture(itemCount: 2)
        let other = try makeFixture(itemCount: 2)
        do {
            _ = try await fixture.liveCoordinator().prepare(
                plan: fixture.livePlan,
                confirmationReceipt: other.confirmationReceipt
            )
            XCTFail("Expected exact receipt mismatch.")
        } catch {
            XCTAssertNotNil(error as? PersistentStateError)
        }
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)
    }

    func testM4f18JournalColumnTamperFailsClosed() async throws {
        let fixture = try makeFixture(itemCount: 2)
        _ = try await fixture.liveCoordinator().prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        try execute(
            "UPDATE codex_ghost_repair_bulk_live_execution_journal "
                + "SET selected_count = 3",
            at: fixture.managerStateURL
        )
        let store = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { store.close() }
        XCTAssertThrowsError(
            try store.codexGhostRepairBulkLiveExecutionJournal(
                requestID: fixture.livePlan.requestID
            )
        )
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)
    }

    func testM4f18ProductionConstructionIsZeroIOAndAuthorityFree() throws {
        let fixture = try makeFixture(itemCount: 2)
        _ = CodexGhostRepairBulkLiveOneShotCoordinator.production(
            backupReader: FixedBulkLiveBackupReadback(
                value: fixture.livePlan.backup
            ),
            profile: .v149DesktopV32
        )
        let value = CodexGhostRepairBulkLiveOneShotCapabilities()
        XCTAssertTrue(value.productionFactoryAvailable)
        XCTAssertFalse(value.productionConstructionPerformsIO)
        XCTAssertFalse(value.productionFactoryAcceptsCallerPath)
        XCTAssertTrue(value.exactConfirmationReceiptRequired)
        XCTAssertTrue(value.exactBackupBoundPlanRequired)
        XCTAssertTrue(value.durableClaimBeforeAttempt)
        XCTAssertTrue(value.durableAttemptBeforeMutation)
        XCTAssertEqual(value.maximumMutationAttemptCount, 1)
        XCTAssertTrue(value.coldRestartUsesReadbackOnly)
        XCTAssertTrue(value.itemizedTerminalReport)
        XCTAssertFalse(value.automaticRetryAllowed)
        XCTAssertFalse(value.automaticRestoreAllowed)
        XCTAssertFalse(value.silentSelectionShrinkAllowed)
        XCTAssertTrue(value.appWiringAvailable)
        XCTAssertFalse(value.liveExecutionAuthorized)
        XCTAssertFalse(value.repairMutationAuthority)
    }

    func testPackagedBridgeUsesExactReceiptPlanAndOneShotReport()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        let preparer = FixedBulkPackagedPlanPreparer(
            value: .init(
                plan: fixture.livePlan,
                receipt: fixture.confirmationReceipt
            )
        )
        let coordinator = CodexGhostRepairBulkPackagedRepairCoordinator(
            planPreparer: preparer,
            runnerFactory: { _ in fixture.liveCoordinator() }
        )
        let reviewOutcome = await coordinator.prepareFinalReview(
            request: .init(
                requestID: UUID(),
                confirmationReceiptID:
                    fixture.confirmationReceipt.receiptID
            )
        )
        guard case let .ready(review) = reviewOutcome else {
            return XCTFail("Expected exact packaged Final Review.")
        }
        XCTAssertEqual(
            review.operationID,
            fixture.confirmationReceipt.operationID
        )
        XCTAssertEqual(review.selectedCount, 10)
        XCTAssertEqual(review.reviewDigest, fixture.livePlan.planDigest)

        let execution = await coordinator.execute(
            request: .init(requestID: UUID(), review: review)
        )
        guard case let .completed(report) = execution else {
            return XCTFail("Expected itemized packaged terminal Report.")
        }
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.itemReports.count, 10)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 0)

        let replay = await coordinator.execute(
            request: .init(requestID: UUID(), review: review)
        )
        XCTAssertEqual(replay, execution)
    }

    func testPackagedBridgeReportsExactClaimBeforeAttemptStopReason()
        async
    {
        let coordinator = CodexGhostRepairBulkPackagedRepairCoordinator(
            planPreparer: FailingBulkPackagedPlanPreparer(
                error: CodexGhostRepairError.executionGateBlocked
            ),
            runnerFactory: { _ in
                throw CodexGhostRepairError.invalidPlan(
                    "Runner must not be created after a preparation failure."
                )
            }
        )

        let outcome = await coordinator.prepareFinalReview(
            request: CodexGhostRepairBulkRepairReviewRequest(
                requestID: UUID(),
                confirmationReceiptID: UUID()
            )
        )

        XCTAssertEqual(
            outcome,
            CodexGhostRepairBulkRepairReviewOutcome.awaitingShutdown(
                message: "Final Review stopped: Codex or another app-server still has a Codex database open. Nothing was executed."
            )
        )
    }

    func testPackagedBridgeKeepsExactTargetDriftReasonVisible() async {
        let threadID = identifier(0)
        let coordinator = CodexGhostRepairBulkPackagedRepairCoordinator(
            planPreparer: FailingBulkPackagedPlanPreparer(
                error: CodexGhostRepairError.targetDrift(
                    "Selected session \(threadID) now has protected side references."
                )
            ),
            runnerFactory: { _ in
                throw CodexGhostRepairError.invalidPlan(
                    "Runner must not be created after target drift."
                )
            }
        )

        let outcome = await coordinator.prepareFinalReview(
            request: .init(
                requestID: UUID(),
                confirmationReceiptID: UUID()
            )
        )

        XCTAssertEqual(
            outcome,
            .blocked(
                message: "Final Review stopped before claim: Selected session "
                    + "\(threadID) now has protected side references. Nothing was executed."
            )
        )
    }

    func testPackagedBridgeDoesNotOfferShutdownContinuationAfterPlanPreparation() async throws {
        let fixture = try makeFixture(itemCount: 1)
        let coordinator = CodexGhostRepairBulkPackagedRepairCoordinator(
            planPreparer: FixedBulkPackagedPlanPreparer(value: .init(
                plan: fixture.livePlan, receipt: fixture.confirmationReceipt)),
            runnerFactory: { _ in throw CodexGhostRepairError.executionGateBlocked }
        )
        let outcome = await coordinator.prepareFinalReview(request: .init(
            requestID: UUID(), confirmationReceiptID: fixture.confirmationReceipt.receiptID))
        guard case .blocked = outcome else {
            return XCTFail("Only the pre-plan shutdown gate may offer continuation")
        }
    }

    func testPackagedBridgeKeepsExactProtectionFailureVisible() async {
        let coordinator = CodexGhostRepairBulkPackagedRepairCoordinator(
            planPreparer: FailingBulkPackagedPlanPreparer(
                error: CodexGhostRepairError.invalidProtectionEvidence(
                    "The operation-backup directory is unavailable."
                )
            ),
            runnerFactory: { _ in
                throw CodexGhostRepairError.invalidPlan(
                    "Runner must not be created after a preparation failure."
                )
            }
        )

        let outcome = await coordinator.prepareFinalReview(
            request: .init(
                requestID: UUID(),
                confirmationReceiptID: UUID()
            )
        )

        XCTAssertEqual(
            outcome,
            .blocked(
                message: "Final Review stopped before claim: a required protection check failed. The operation-backup directory is unavailable. Nothing was executed."
            )
        )
    }

    func testCallerPathFreeCompositionRunsOneExactPipelineAndReplaysReport()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        let composition = try fixture.composition()
        let reviewOutcome = await composition.prepareFinalReview(
            request: .init(
                requestID: UUID(),
                confirmationReceiptID: fixture.draft.confirmationReceiptID
            )
        )
        guard case let .ready(review) = reviewOutcome else {
            return XCTFail("Expected one exact final Review: \(reviewOutcome)")
        }
        XCTAssertEqual(review.selectedCount, 10)
        XCTAssertEqual(review.ordinaryCount, 5)
        XCTAssertEqual(review.automationCount, 5)

        let request = CodexGhostRepairBulkRepairExecutionRequest(
            requestID: UUID(), review: review
        )
        let first = await composition.execute(request: request)
        let second = await composition.execute(request: request)
        guard case let .completed(firstReport) = first,
              case let .completed(secondReport) = second else {
            return XCTFail("Expected one durable terminal Report.")
        }
        XCTAssertEqual(firstReport, secondReport)
        XCTAssertEqual(firstReport.outcome, .success)
        XCTAssertEqual(firstReport.itemReports.count, 10)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 0)
        XCTAssertEqual(try scalar(
            "SELECT catalog_revision FROM local_thread_catalog_metadata "
                + "WHERE id = 1",
            at: fixture.desktopURL
        ), 1_010)

        let capabilities = composition.compositionCapabilities
        XCTAssertFalse(capabilities.acceptsCallerPath)
        XCTAssertTrue(capabilities.exactPlanToTerminalReport)
        XCTAssertTrue(capabilities.operationBoundBackupReadback)
        XCTAssertTrue(capabilities.oneShotManagerJournal)
        XCTAssertFalse(capabilities.appWiringAvailable)
        XCTAssertFalse(capabilities.acceptsLiveCodexRoot)
    }

    func testMixedBatchUsesExternalClaimAndOneDesktopTransaction()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        let outcome = try await fixture.mutator().executeOnce(
            draft: fixture.draft,
            claim: fixture.claim,
            attempt: fixture.attempt
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 0)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM automation_runs WHERE status = 'ARCHIVED' "
                + "AND archived_reason = 'auto' AND updated_at = 1600",
            at: fixture.desktopURL
        ), 5)
        XCTAssertEqual(try scalar(
            "SELECT catalog_revision FROM local_thread_catalog_metadata "
                + "WHERE id = 1",
            at: fixture.desktopURL
        ), 1_010)
        XCTAssertEqual(try scalar(
            "SELECT observation_sequence "
                + "FROM local_thread_catalog_sync_state "
                + "WHERE host_id = 'local'",
            at: fixture.desktopURL
        ), 2_010)

        let recovered = try await fixture.mutator().recoverByReadback(
            draft: fixture.draft,
            claim: fixture.claim,
            attempt: fixture.attempt
        )
        XCTAssertEqual(recovered, .success)
        XCTAssertEqual(try scalar(
            "SELECT catalog_revision FROM local_thread_catalog_metadata "
                + "WHERE id = 1",
            at: fixture.desktopURL
        ), 1_010)
    }

    func testSourceDriftStopsBeforeDesktopMutation() async throws {
        let fixture = try makeFixture(itemCount: 2)
        try execute(
            "UPDATE sentinel SET value = 'drifted' WHERE id = 1",
            at: fixture.stateURL
        )

        let outcome = try await fixture.mutator().executeOnce(
            draft: fixture.draft,
            claim: fixture.claim,
            attempt: fixture.attempt
        )

        XCTAssertEqual(outcome, .notAttempted)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)
    }

    func testColdReadbackRejectsUnexpectedAutomationFieldDrift()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let outcome = try await fixture.mutator().executeOnce(
            draft: fixture.draft,
            claim: fixture.claim,
            attempt: fixture.attempt
        )
        XCTAssertEqual(outcome, .success)

        try execute(
            "UPDATE automation_runs SET archived_user_message = 'unexpected' "
                + "WHERE thread_id = '\(identifier(1))'",
            at: fixture.desktopURL
        )
        let recovered = try await fixture.mutator().recoverByReadback(
            draft: fixture.draft,
            claim: fixture.claim,
            attempt: fixture.attempt
        )

        XCTAssertEqual(recovered, .unknown)
    }

    func testBusyIsExplicitFailureAndReadbackNeverRetries() async throws {
        let fixture = try makeFixture(itemCount: 2)
        let failed = try await fixture.mutator(
            fault: .explicitBusyBeforeTransaction
        ).executeOnce(
            draft: fixture.draft,
            claim: fixture.claim,
            attempt: fixture.attempt
        )
        let recovered = try await fixture.mutator().recoverByReadback(
            draft: fixture.draft,
            claim: fixture.claim,
            attempt: fixture.attempt
        )

        XCTAssertEqual(failed, .explicitFailure)
        XCTAssertEqual(recovered, .explicitFailure)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)
    }

    func testCommitInterruptionRecoversSuccessWithoutSecondTransaction()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let first = try await fixture.mutator(
            fault: .afterCommitBeforeReadback
        ).executeOnce(
            draft: fixture.draft,
            claim: fixture.claim,
            attempt: fixture.attempt
        )
        let recovered = try await fixture.mutator().recoverByReadback(
            draft: fixture.draft,
            claim: fixture.claim,
            attempt: fixture.attempt
        )

        XCTAssertEqual(first, .success)
        XCTAssertEqual(recovered, .success)
        XCTAssertEqual(try scalar(
            "SELECT catalog_revision FROM local_thread_catalog_metadata "
                + "WHERE id = 1",
            at: fixture.desktopURL
        ), 1_002)
    }

    func testBackupReceiptMismatchFailsBeforeMutation() async throws {
        let fixture = try makeFixture(itemCount: 2)
        let mismatched = try CodexGhostRepairBulkExecutionBackupReceipt(
            operationID: fixture.draft.operationID,
            planDigest: fixture.draft.planDigest,
            selectedThreadIDs: fixture.draft.selectedThreadIDs,
            sourceFingerprintHash: hash(999),
            files: fixture.draft.backup.files,
            capturedAtMilliseconds: fixture.draft.backup.capturedAtMilliseconds
        )
        let mutator = try CodexGhostRepairBulkProductionMutator(
            bundle: fixture.bundle,
            source: fixture.source,
            gateSource: AlwaysClearBulkRepairGate(),
            backupResolver: FixedBulkBackupReadback(value: mismatched)
        )

        do {
            _ = try await mutator.executeOnce(
                draft: fixture.draft,
                claim: fixture.claim,
                attempt: fixture.attempt
            )
            XCTFail("Expected exact backup mismatch.")
        } catch {
            XCTAssertNotNil(error as? CodexGhostRepairError)
        }
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)
    }

    func testCapabilitiesRemainTestOwnedAndNonReplaying() {
        let value = CodexGhostRepairBulkProductionMutator.capabilities
        XCTAssertFalse(value.acceptsCallerPath)
        XCTAssertEqual(value.maximumTargetCount, 500)
        XCTAssertTrue(value.mixedCategoryBatch)
        XCTAssertEqual(value.fixedDatabaseGroupCount, 5)
        XCTAssertEqual(value.desktopWriteDatabaseCount, 1)
        XCTAssertEqual(value.readbackOnlyDatabaseCount, 4)
        XCTAssertTrue(value.requiresDurableExternalClaimAndAttempt)
        XCTAssertTrue(value.requiresExactOperationBoundBackup)
        XCTAssertTrue(value.requiresFreshOperationalGate)
        XCTAssertTrue(value.testOwnedCanonicalSourceOnly)
        XCTAssertFalse(value.automaticRetryAllowed)
        XCTAssertFalse(value.automaticRestoreAllowed)
        XCTAssertFalse(value.appWiringAvailable)
        XCTAssertFalse(value.acceptsLiveCodexRoot)
    }

    func testShippingRecoveryFacadeReadsExpiredExact148TerminalWithoutWrites()
        async throws
    {
        let fixture = try makeFixture(itemCount: 148)
        let runner = fixture.liveCoordinator()
        _ = try await runner.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let terminal = try await runner.execute(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest
        )
        XCTAssertLessThan(
            fixture.livePlan.expiresAtMilliseconds,
            Int64(Date().timeIntervalSince1970 * 1_000)
        )
        let before = try durableFileContents(
            in: fixture.managerStateURL.deletingLastPathComponent()
        )
        let coordinator = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { fixture.managerStateURL }
        )

        let previous = await coordinator.readPreviousOperations()
        guard case let .observed(summaries) = previous,
              summaries.count == 1,
              let summary = summaries.first else {
            return XCTFail("Expected one durable v19 operation summary.")
        }
        XCTAssertEqual(summary.identity.requestID, fixture.livePlan.requestID)
        XCTAssertEqual(
            summary.identity.operationID,
            fixture.confirmationReceipt.operationID
        )
        XCTAssertEqual(summary.confirmationReceiptID, fixture.confirmationReceipt.receiptID)
        XCTAssertEqual(summary.selectedCount, 148)
        XCTAssertEqual(summary.phase, .terminal)
        XCTAssertEqual(summary.mutationAttemptCount, 1)
        XCTAssertTrue(summary.hasTerminalReport)

        let readback = await coordinator.readOperation(identity: summary.identity)
        guard case let .terminal(readSummary, report) = readback else {
            return XCTFail("Expected exact terminal durable readback.")
        }
        XCTAssertEqual(readSummary, summary)
        XCTAssertEqual(report.operationID, fixture.confirmationReceipt.operationID)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.itemReports.count, 148)
        XCTAssertEqual(
            report.itemReports.map(\.threadID),
            terminal.items.map(\.threadID)
        )
        XCTAssertEqual(report.reportDigest, terminal.reportDigest)
        XCTAssertEqual(
            try durableFileContents(
                in: fixture.managerStateURL.deletingLastPathComponent()
            ),
            before
        )
    }

    func testShippingRecoveryFacadeLeavesPreparedAndAttemptedRecordsUnresolved()
        async throws
    {
        let preparedFixture = try makeFixture(itemCount: 10)
        let preparedRunner = preparedFixture.liveCoordinator()
        _ = try await preparedRunner.prepare(
            plan: preparedFixture.livePlan,
            confirmationReceipt: preparedFixture.confirmationReceipt
        )
        let preparedCoordinator = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { preparedFixture.managerStateURL }
        )
        let preparedIdentity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: preparedFixture.livePlan.requestID,
            operationID: preparedFixture.confirmationReceipt.operationID
        )
        let prepared = await preparedCoordinator.readOperation(
            identity: preparedIdentity
        )
        guard case let .recoveryRequired(summary, message) = prepared else {
            return XCTFail("Expected prepared operation to remain unresolved.")
        }
        XCTAssertEqual(summary.phase, .prepared)
        XCTAssertEqual(summary.mutationAttemptCount, 0)
        XCTAssertFalse(summary.hasTerminalReport)
        XCTAssertTrue(message.contains("no recorded mutation attempt"))
        XCTAssertTrue(message.contains("does not prove"))

        let claimedFixture = try makeFixture(itemCount: 10)
        let claimedStore = try SQLiteStateStore(
            databaseURL: claimedFixture.managerStateURL
        )
        _ = try claimedStore.prepareCodexGhostRepairBulkLiveExecutionJournal(
            plan: claimedFixture.livePlan,
            confirmationReceipt: claimedFixture.confirmationReceipt
        )
        _ = try claimedStore.claimCodexGhostRepairBulkLiveExecution(
            requestID: claimedFixture.livePlan.requestID,
            expectedPlanDigest: claimedFixture.livePlan.planDigest,
            claimID: UUID(),
            claimedAtMilliseconds: 1_600
        )
        claimedStore.close()
        let claimedCoordinator = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { claimedFixture.managerStateURL }
        )
        let claimed = await claimedCoordinator.readOperation(identity: .init(
            requestID: claimedFixture.livePlan.requestID,
            operationID: claimedFixture.confirmationReceipt.operationID
        ))
        guard case let .recoveryRequired(claimedSummary, claimedMessage)
                = claimed else {
            return XCTFail("Expected claimed operation to require recovery.")
        }
        XCTAssertEqual(claimedSummary.phase, .claimed)
        XCTAssertEqual(claimedSummary.mutationAttemptCount, 0)
        XCTAssertFalse(claimedSummary.hasTerminalReport)
        XCTAssertTrue(claimedMessage.contains("outcome"))
        XCTAssertTrue(claimedMessage.contains("cannot retry or finalize"))

        let attemptedFixture = try makeFixture(itemCount: 10)
        let attemptedRunner = attemptedFixture.liveCoordinator(fault: .afterAttempt)
        _ = try await attemptedRunner.prepare(
            plan: attemptedFixture.livePlan,
            confirmationReceipt: attemptedFixture.confirmationReceipt
        )
        do {
            _ = try await attemptedRunner.execute(
                requestID: attemptedFixture.livePlan.requestID,
                expectedPlanDigest: attemptedFixture.livePlan.planDigest
            )
            XCTFail("Expected deterministic interruption after the attempt journal.")
        } catch CodexGhostRepairError.injectedInterruption {
            // The v19 journal intentionally remains attempted and nonterminal.
        }
        let attemptedCoordinator = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { attemptedFixture.managerStateURL }
        )
        let attempted = await attemptedCoordinator.readOperation(identity: .init(
            requestID: attemptedFixture.livePlan.requestID,
            operationID: attemptedFixture.confirmationReceipt.operationID
        ))
        guard case let .recoveryRequired(attemptedSummary, attemptedMessage)
                = attempted else {
            return XCTFail("Expected attempted operation to require recovery.")
        }
        XCTAssertEqual(attemptedSummary.phase, .attempted)
        XCTAssertEqual(attemptedSummary.mutationAttemptCount, 1)
        XCTAssertFalse(attemptedSummary.hasTerminalReport)
        XCTAssertTrue(attemptedMessage.contains("outcome remains unresolved"))
        XCTAssertTrue(attemptedMessage.contains("does not inspect private Codex data"))
    }

    func testShippingRecoveryFacadeRejectsIdentityAndChecksumTampering()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        let runner = fixture.liveCoordinator()
        _ = try await runner.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let coordinator = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { fixture.managerStateURL }
        )
        let wrongIdentity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: fixture.livePlan.requestID,
            operationID: UUID()
        )
        let wrongIdentityReadback = await coordinator.readOperation(
            identity: wrongIdentity
        )
        XCTAssertEqual(
            wrongIdentityReadback,
            .notFound(identity: wrongIdentity)
        )

        try execute(
            "UPDATE codex_ghost_repair_bulk_live_execution_journal "
                + "SET payload_hash = 'sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'",
            at: fixture.managerStateURL
        )
        guard case .unavailable = await coordinator.readPreviousOperations()
        else {
            return XCTFail("Expected checksummed discovery to fail closed.")
        }
        let exactIdentity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: fixture.livePlan.requestID,
            operationID: fixture.confirmationReceipt.operationID
        )
        guard case .unavailable = await coordinator.readOperation(
            identity: exactIdentity
        ) else {
            return XCTFail("Expected checksummed exact readback to fail closed.")
        }
    }

    func testShippingRecoveryFacadeReadsCommittedWALWithoutChangingJournal()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10)
        let writer = try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        defer { writer.close() }
        let persisted = try writer.prepareCodexGhostRepairBulkLiveExecutionJournal(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let walURL = URL(fileURLWithPath: fixture.managerStateURL.path + "-wal")
        let walSize = try walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertGreaterThan(walSize ?? 0, 0)
        let before = try durableFileContents(
            in: fixture.managerStateURL.deletingLastPathComponent()
        )
        let coordinator = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { fixture.managerStateURL }
        )

        let readback = await coordinator.readOperation(identity: .init(
            requestID: fixture.livePlan.requestID,
            operationID: fixture.confirmationReceipt.operationID
        ))

        guard case let .recoveryRequired(summary, _) = readback else {
            return XCTFail("Expected committed WAL journal to be readable.")
        }
        XCTAssertEqual(summary.phase, .prepared)
        XCTAssertEqual(
            try writer.codexGhostRepairBulkLiveExecutionJournal(
                requestID: fixture.livePlan.requestID
            ),
            persisted
        )
        XCTAssertEqual(
            try durableFileContents(
                in: fixture.managerStateURL.deletingLastPathComponent()
            ),
            before
        )
    }

    func testShippingRecoveryFacadeDoesNotBootstrapOrListReceiptOnlyState()
        async throws
    {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "bulk-recovery-missing-\(UUID().uuidString)",
                isDirectory: true
            )
        let missingDatabase = missingRoot.appendingPathComponent("state.sqlite")
        let missingCoordinator = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { missingDatabase }
        )
        let missingPrevious = await missingCoordinator.readPreviousOperations()
        XCTAssertEqual(missingPrevious, .empty)
        let missingIdentity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: UUID(), operationID: UUID()
        )
        let missingReadback = await missingCoordinator.readOperation(
            identity: missingIdentity
        )
        XCTAssertEqual(missingReadback, .notFound(identity: missingIdentity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path))

        let receiptOnly = try makeFixture(itemCount: 10)
        let receiptOnlyCoordinator = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { receiptOnly.managerStateURL }
        )
        let receiptOnlyPrevious = await receiptOnlyCoordinator
            .readPreviousOperations()
        XCTAssertEqual(receiptOnlyPrevious, .empty)
        let receiptOnlyIdentity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: receiptOnly.livePlan.requestID,
            operationID: receiptOnly.confirmationReceipt.operationID
        )
        let receiptOnlyReadback = await receiptOnlyCoordinator.readOperation(
            identity: receiptOnlyIdentity
        )
        XCTAssertEqual(
            receiptOnlyReadback,
            .notFound(identity: receiptOnlyIdentity)
        )
    }

    func testShippingRecoveryFacadeReportsDiscoveryLimitWithoutChoosing()
        async throws
    {
        let fixture = try makeFixture(itemCount: 1)
        let runner = fixture.liveCoordinator()
        _ = try await runner.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        for index in 0..<CodexGhostRepairBulkRecoveryLiveCoordinator
            .maximumDiscoveredOperations {
            let requestID = String(
                format: "30000000-0000-4000-8000-%012d", index + 1
            )
            let receiptID = String(
                format: "40000000-0000-4000-8000-%012d", index + 1
            )
            try execute(
                "INSERT INTO codex_ghost_repair_bulk_live_execution_journal "
                    + "(request_id, confirmation_receipt_id, "
                    + "confirmation_receipt_digest, plan_digest, "
                    + "backup_receipt_digest, selected_count, phase, "
                    + "payload_json, payload_hash, mutation_attempt_count, "
                    + "automatic_retry_allowed, automatic_restore_allowed, "
                    + "silent_selection_shrink_allowed) VALUES ("
                    + "'\(requestID)', '\(receiptID)', 'receipt-\(index)', "
                    + "'plan-\(index)', 'backup', 1, 'prepared', '{}', "
                    + "'sha256:00', 0, 0, 0, 0)",
                at: fixture.managerStateURL
            )
        }
        let coordinator = CodexGhostRepairBulkRecoveryLiveCoordinator(
            databaseURLProvider: { fixture.managerStateURL }
        )
        guard case let .limitExceeded(limit, foundAtLeast, message) =
                await coordinator.readPreviousOperations() else {
            return XCTFail("Expected explicit discovery overflow.")
        }
        XCTAssertEqual(
            limit,
            CodexGhostRepairBulkRecoveryLiveCoordinator
                .maximumDiscoveredOperations
        )
        XCTAssertEqual(foundAtLeast, limit + 1)
        XCTAssertTrue(message.contains("No operation was selected"))

        let knownIdentity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: fixture.livePlan.requestID,
            operationID: fixture.confirmationReceipt.operationID
        )
        guard case let .recoveryRequired(summary, _) =
                await coordinator.readOperation(identity: knownIdentity) else {
            return XCTFail("Known exact identity must remain independently readable.")
        }
        XCTAssertEqual(summary.identity, knownIdentity)
    }

    func testShippingRecoveryFacadeCapabilitiesAreDurableReadOnly() {
        let value = CodexGhostRepairBulkRecoveryCapabilities.packagedReadOnly
        XCTAssertTrue(value.explicitReadbackAvailable)
        XCTAssertTrue(value.readsManagerOwnedState)
        XCTAssertFalse(value.readsCodexData)
        XCTAssertFalse(value.writesManagerOwnedRecords)
        XCTAssertTrue(value.mayUpdateSQLiteCoordination)
        XCTAssertFalse(value.createsChallenge)
        XCTAssertFalse(value.createsReceipt)
        XCTAssertFalse(value.confirmationAuthority)
        XCTAssertFalse(value.claimAuthority)
        XCTAssertFalse(value.repairMutationAuthority)
        XCTAssertFalse(value.retryAuthority)
        XCTAssertFalse(value.restoreAuthority)
        _ = CodexGhostRepairBulkRecoveryCoordinatorFactory.packagedReadOnly()
    }

    func testFreshRecoveryCapabilitiesExposeOnlyExplicitReadbackFinalization() {
        let value = CodexGhostRepairBulkFreshRecoveryCapabilities
            .packagedExplicit
        XCTAssertTrue(value.explicitRecoveryAvailable)
        XCTAssertTrue(value.readsManagerOwnedState)
        XCTAssertTrue(value.readsCodexData)
        XCTAssertTrue(value.finalizesOriginalJournal)
        XCTAssertFalse(value.createsPreview)
        XCTAssertFalse(value.createsChallenge)
        XCTAssertFalse(value.createsReceipt)
        XCTAssertFalse(value.createsClaim)
        XCTAssertFalse(value.recordsMutationAttempt)
        XCTAssertFalse(value.repairMutationAuthority)
        XCTAssertFalse(value.retryAuthority)
        XCTAssertFalse(value.restoreAuthority)
        XCTAssertFalse(value.createsToken)
        _ = CodexGhostRepairBulkFreshRecoveryCoordinatorFactory
            .packagedExplicit()
    }

    func testFreshRecoveryLeavesPreparedWithoutClaimOrAttempt()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let journal = freshJournal(fixture)
        _ = try await journal.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let outcome = await freshCoordinator(fixture).recoverOperation(
            identity: freshIdentity(fixture)
        )
        guard case let .recoveryRequired(summary, message) = outcome else {
            return XCTFail("Prepared operation must remain unresolved: \(outcome)")
        }
        XCTAssertEqual(summary.phase, .prepared)
        XCTAssertEqual(summary.mutationAttemptCount, 0)
        XCTAssertTrue(message.contains("cannot invent a claim"))
        let observedRecord = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        let record = try XCTUnwrap(observedRecord)
        XCTAssertEqual(record.phase, .prepared)
        XCTAssertNil(record.claim)
        XCTAssertNil(record.attempt)
    }

    func testFreshRecoveryFinalizesClaimedExactInitialWithoutAttempt()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let (journal, _, _) = try await unresolvedFixture(
            fixture,
            attempted: false
        )
        let beforeStore = try SQLiteStateStore(
            databaseURL: fixture.managerStateURL
        )
        let beforePreview = try beforeStore.codexGhostRepairBulkPreview(
            requestID: fixture.livePlan.requestID
        )
        let beforeChallenge = try beforeStore.codexGhostRepairBulkChallenge(
            savedPreviewRequestID: fixture.livePlan.requestID
        )
        let beforeReceipt = try beforeStore
            .codexGhostRepairBulkConfirmationReceipt(
                savedPreviewRequestID: fixture.livePlan.requestID
            )
        beforeStore.close()
        let outcome = await freshCoordinator(fixture).recoverOperation(
            identity: freshIdentity(fixture)
        )
        guard case let .terminal(summary, report, source) = outcome else {
            return XCTFail("Claimed initial state should finalize safely: \(outcome)")
        }
        XCTAssertEqual(source, .freshlyFinalized)
        XCTAssertEqual(summary.phase, .terminal)
        XCTAssertEqual(summary.mutationAttemptCount, 0)
        XCTAssertEqual(report.outcome, .notAttempted)
        let observedRecord = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        let record = try XCTUnwrap(observedRecord)
        XCTAssertEqual(record.phase, .terminal)
        XCTAssertNil(record.attempt)
        let afterStore = try SQLiteStateStore(
            databaseURL: fixture.managerStateURL
        )
        defer { afterStore.close() }
        XCTAssertEqual(
            try afterStore.codexGhostRepairBulkPreview(
                requestID: fixture.livePlan.requestID
            ),
            beforePreview
        )
        XCTAssertEqual(
            try afterStore.codexGhostRepairBulkChallenge(
                savedPreviewRequestID: fixture.livePlan.requestID
            ),
            beforeChallenge
        )
        XCTAssertEqual(
            try afterStore.codexGhostRepairBulkConfirmationReceipt(
                savedPreviewRequestID: fixture.livePlan.requestID
            ),
            beforeReceipt
        )
    }

    func testFreshRecoveryFinalizesAttemptedInitialAsExplicitFailure()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let (journal, _, _) = try await unresolvedFixture(
            fixture,
            attempted: true
        )
        let outcome = await freshCoordinator(fixture).recoverOperation(
            identity: freshIdentity(fixture)
        )
        guard case let .terminal(summary, report, source) = outcome else {
            return XCTFail("Attempted initial state should finalize failure.")
        }
        XCTAssertEqual(source, .freshlyFinalized)
        XCTAssertEqual(summary.mutationAttemptCount, 1)
        XCTAssertEqual(report.outcome, .explicitFailure)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 2)
        let terminalRecord = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        XCTAssertEqual(terminalRecord?.mutationAttemptCount, 1)
    }

    func testFreshRecoveryFinalizesAttemptedFinalAsSuccessWithoutMutation()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let (journal, claim, attempt) = try await unresolvedFixture(
            fixture,
            attempted: true
        )
        let executionOutcome = try await fixture.liveMutator().executeOnce(
            plan: fixture.livePlan,
            claim: claim,
            attempt: try XCTUnwrap(attempt)
        )
        XCTAssertEqual(executionOutcome, .success)
        let outcome = await freshCoordinator(fixture).recoverOperation(
            identity: freshIdentity(fixture)
        )
        guard case let .terminal(summary, report, _) = outcome else {
            return XCTFail("Attempted final state should recover success.")
        }
        XCTAssertEqual(summary.mutationAttemptCount, 1)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(try scalar(
            "SELECT count(*) FROM local_thread_catalog",
            at: fixture.desktopURL
        ), 0)
        let terminalRecord = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        XCTAssertEqual(terminalRecord?.phase, .terminal)
    }

    func testFreshRecoveryFinalizesAttemptedIntermediateAsUnknown()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let (journal, _, _) = try await unresolvedFixture(
            fixture,
            attempted: true
        )
        try execute(
            "DELETE FROM local_thread_catalog WHERE thread_id = '\(identifier(0))'",
            at: fixture.desktopURL
        )
        let outcome = await freshCoordinator(fixture).recoverOperation(
            identity: freshIdentity(fixture)
        )
        guard case let .terminal(summary, report, _) = outcome else {
            return XCTFail("Intermediate attempted state should terminalize unknown.")
        }
        XCTAssertEqual(summary.mutationAttemptCount, 1)
        XCTAssertEqual(report.outcome, .unknown)
        let terminalRecord = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        XCTAssertEqual(terminalRecord?.report?.outcome, .unknown)
    }

    func testFreshRecoveryDesktopDriftDuringReadbackDoesNotFinalize()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let (journal, _, _) = try await unresolvedFixture(
            fixture,
            attempted: true
        )
        let reader = CodexGhostRepairBulkLiveMixedMutator(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedAllowedParentURL: fixture.parent,
            profile: fixture.profile,
            gateSource: AlwaysClearBulkRepairGate(),
            backupReader: FixedBulkLiveBackupReadback(
                value: fixture.livePlan.backup
            ),
            afterFreshRecoveryInspectionForTesting: {
                try BulkShippingCompositionTestFixture.execute(
                    "DELETE FROM local_thread_catalog WHERE thread_id = '\(BulkShippingCompositionTestFixture.identifier(0))'",
                    at: fixture.desktopURL
                )
            }
        )
        let outcome = await freshCoordinator(
            fixture,
            readback: reader
        ).recoverOperation(identity: freshIdentity(fixture))
        guard case .recoveryRequired = outcome else {
            return XCTFail("Desktop drift must remain unresolved.")
        }
        let unresolvedRecord = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        XCTAssertEqual(unresolvedRecord?.phase, .attempted)
    }

    func testFreshRecoveryRejectsReceiptAndSchemaDriftWithoutFinalization()
        async throws
    {
        let receiptFixture = try makeFixture(itemCount: 2)
        let (receiptJournal, _, _) = try await unresolvedFixture(
            receiptFixture,
            attempted: true
        )
        try execute(
            "UPDATE codex_ghost_repair_bulk_confirmation_receipts SET selected_count = 3",
            at: receiptFixture.managerStateURL
        )
        guard case .unavailable = await freshCoordinator(receiptFixture)
            .recoverOperation(identity: freshIdentity(receiptFixture)) else {
            return XCTFail("Receipt tamper must fail before private readback.")
        }
        let receiptRecord = try await receiptJournal.record(
            requestID: receiptFixture.livePlan.requestID
        )
        XCTAssertEqual(receiptRecord?.phase, .attempted)

        let schemaFixture = try makeFixture(itemCount: 2)
        let (schemaJournal, _, _) = try await unresolvedFixture(
            schemaFixture,
            attempted: true
        )
        try execute("PRAGMA user_version = 33", at: schemaFixture.desktopURL)
        guard case .recoveryRequired = await freshCoordinator(schemaFixture)
            .recoverOperation(identity: freshIdentity(schemaFixture)) else {
            return XCTFail("Source schema drift must remain unresolved.")
        }
        let schemaRecord = try await schemaJournal.record(
            requestID: schemaFixture.livePlan.requestID
        )
        XCTAssertEqual(schemaRecord?.phase, .attempted)
    }

    func testFreshRecoveryRejectsIncompleteFiveDatabaseGateEvidence()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let (journal, _, _) = try await unresolvedFixture(
            fixture,
            attempted: true
        )
        let reader = CodexGhostRepairBulkLiveMixedMutator(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedAllowedParentURL: fixture.parent,
            profile: fixture.profile,
            gateSource: IncompleteFreshRecoveryGate(),
            backupReader: FixedBulkLiveBackupReadback(
                value: fixture.livePlan.backup
            )
        )
        let outcome = await freshCoordinator(fixture, readback: reader)
            .recoverOperation(identity: freshIdentity(fixture))
        guard case .recoveryRequired = outcome else {
            return XCTFail("Nil state/history handle evidence must fail closed.")
        }
        let record = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        XCTAssertEqual(record?.phase, .attempted)
        XCTAssertNil(record?.report)
    }

    func testFreshRecoveryMissingManagerDatabaseDoesNotBootstrap() async {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fresh-recovery-missing-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = parent.appendingPathComponent("state.sqlite")
        let coordinator = CodexGhostRepairBulkFreshRecoveryLiveCoordinator(
            databaseURLProvider: { databaseURL },
            operationExclusion: .init(databaseURL: databaseURL),
            readbackProvider: { _ in
                throw CodexGhostRepairError.recoveryRequired
            }
        )
        let identity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: UUID(),
            operationID: UUID()
        )
        let outcome = await coordinator.recoverOperation(identity: identity)
        XCTAssertEqual(outcome, .notFound(identity: identity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testFreshRecoveryOperationExclusionIsNonblockingAndReleasable()
        throws
    {
        let fixture = try makeFixture(itemCount: 1)
        let first = CodexGhostRepairBulkOperationExclusion(
            databaseURL: fixture.managerStateURL
        )
        let second = CodexGhostRepairBulkOperationExclusion(
            databaseURL: fixture.managerStateURL
        )
        let lease = try first.acquire()
        XCTAssertThrowsError(try second.acquire())
        lease.release()
        let next = try second.acquire()
        next.release()
    }

    func testFreshRecoveryOperationExclusionSurvivesSQLiteOpenAcrossProcess()
        throws
    {
        let fixture = try makeFixture(itemCount: 1)
        var ready = [Int32](repeating: -1, count: 2)
        var release = [Int32](repeating: -1, count: 2)
        guard pipe(&ready) == 0 else {
            return XCTFail("Could not create child-ready pipe.")
        }
        guard pipe(&release) == 0 else {
            _ = close(ready[0])
            _ = close(ready[1])
            return XCTFail("Could not create child-release pipe.")
        }
        let directoryDescriptor = open(
            fixture.managerStateURL.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard directoryDescriptor >= 0 else {
            ready.forEach { _ = close($0) }
            release.forEach { _ = close($0) }
            return XCTFail("Could not open the test-owned manager directory.")
        }
        let child = asmFreshRecoveryTestFork()
        guard child >= 0 else {
            _ = close(directoryDescriptor)
            ready.forEach { _ = close($0) }
            release.forEach { _ = close($0) }
            return XCTFail("Could not create the cross-process lock child.")
        }
        if child == 0 {
            _ = close(ready[0])
            _ = close(release[1])
            guard flock(directoryDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                _exit(10)
            }
            var byte: UInt8 = 1
            guard write(ready[1], &byte, 1) == 1 else { _exit(11) }
            guard read(release[0], &byte, 1) == 1 else { _exit(12) }
            _exit(0)
        }
        _ = close(ready[1])
        _ = close(release[0])
        _ = close(directoryDescriptor)
        var childReaped = false
        defer {
            _ = close(ready[0])
            _ = close(release[1])
            if !childReaped {
                _ = kill(child, SIGKILL)
                var cleanupStatus: Int32 = 0
                _ = waitpid(child, &cleanupStatus, 0)
            }
        }
        var readyPoll = pollfd(
            fd: ready[0],
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        guard poll(&readyPoll, 1, 5_000) == 1,
              (readyPoll.revents & Int16(POLLIN)) != 0 else {
            return XCTFail("Cross-process child did not acquire the lease in time.")
        }
        var readyByte: UInt8 = 0
        guard read(ready[0], &readyByte, 1) == 1, readyByte == 1 else {
            return XCTFail("Cross-process child lease handshake failed.")
        }

        // Opening and closing SQLite must not release another process's
        // directory lease, unlike a record lock on the database file itself.
        XCTAssertEqual(
            try scalar("PRAGMA user_version", at: fixture.managerStateURL),
            Int(SQLiteStateStore.currentSchemaVersion)
        )
        let exclusion = CodexGhostRepairBulkOperationExclusion(
            databaseURL: fixture.managerStateURL
        )
        XCTAssertThrowsError(try exclusion.acquire())
        var releaseByte: UInt8 = 1
        guard write(release[1], &releaseByte, 1) == 1 else {
            return XCTFail("Could not release the cross-process child.")
        }
        var exitPoll = pollfd(
            fd: ready[0],
            events: Int16(POLLHUP),
            revents: 0
        )
        guard poll(&exitPoll, 1, 5_000) == 1,
              (exitPoll.revents & Int16(POLLHUP)) != 0 else {
            return XCTFail("Cross-process child did not exit in time.")
        }
        var status: Int32 = 0
        XCTAssertEqual(waitpid(child, &status, 0), child)
        childReaped = true
        XCTAssertEqual(status & 0x7f, 0)
        XCTAssertEqual((status >> 8) & 0xff, 0)

        let lease = try exclusion.acquire()
        lease.release()
    }

    func testFreshRecoveryClockRollbackLeavesOriginalPhaseUntouched()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let (journal, _, _) = try await unresolvedFixture(
            fixture,
            attempted: false
        )
        let coordinator = freshCoordinator(
            fixture,
            nowMilliseconds: { 1_599 }
        )
        let outcome = await coordinator.recoverOperation(
            identity: freshIdentity(fixture)
        )
        guard case let .recoveryRequired(_, message) = outcome else {
            return XCTFail("A backward clock must not synthesize completion time.")
        }
        XCTAssertTrue(message.contains("time moved behind"))
        let record = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        XCTAssertEqual(record?.phase, .claimed)
        XCTAssertEqual(record?.mutationAttemptCount, 0)
    }

    func testFreshRecoveryCASDoesNotOverwriteCompetingTerminalReport()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let (journal, claim, attempt) = try await unresolvedFixture(
            fixture,
            attempted: true
        )
        let competing = try CodexGhostRepairBulkLiveTerminalReport(
            reportID: UUID(uuidString: "95000000-0000-4000-8000-000000000001")!,
            plan: fixture.livePlan,
            receipt: fixture.confirmationReceipt,
            claim: claim,
            attempt: try XCTUnwrap(attempt),
            outcome: .explicitFailure,
            completedAtMilliseconds: 1_800
        )
        let reader = CodexGhostRepairBulkLiveMixedMutator(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedAllowedParentURL: fixture.parent,
            profile: fixture.profile,
            gateSource: AlwaysClearBulkRepairGate(),
            backupReader: FixedBulkLiveBackupReadback(
                value: fixture.livePlan.backup
            ),
            afterFreshRecoveryInspectionForTesting: {
                let competingStore = try SQLiteStateStore(
                    databaseURL: fixture.managerStateURL
                )
                defer { competingStore.close() }
                try competingStore.recordCodexGhostRepairBulkLiveTerminalReport(
                    competing
                )
            }
        )
        let outcome = await freshCoordinator(fixture, readback: reader)
            .recoverOperation(identity: freshIdentity(fixture))
        guard case let .recoveryRequired(_, message) = outcome else {
            return XCTFail("CAS phase drift must not be overwritten.")
        }
        XCTAssertTrue(message.contains("uncertain"))
        let record = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        XCTAssertEqual(record?.phase, .terminal)
        XCTAssertEqual(record?.report, competing)
    }

    func testFreshRecoveryCASRevalidatesReceiptAfterPrivateReadback()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let (journal, _, _) = try await unresolvedFixture(
            fixture,
            attempted: true
        )
        let reader = CodexGhostRepairBulkLiveMixedMutator(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedAllowedParentURL: fixture.parent,
            profile: fixture.profile,
            gateSource: AlwaysClearBulkRepairGate(),
            backupReader: FixedBulkLiveBackupReadback(
                value: fixture.livePlan.backup
            ),
            afterFreshRecoveryInspectionForTesting: {
                try BulkShippingCompositionTestFixture.execute(
                    "UPDATE codex_ghost_repair_bulk_confirmation_receipts SET selected_count = 3",
                    at: fixture.managerStateURL
                )
            }
        )
        let outcome = await freshCoordinator(fixture, readback: reader)
            .recoverOperation(identity: freshIdentity(fixture))
        guard case let .recoveryRequired(_, message) = outcome else {
            return XCTFail("Receipt drift at CAS must remain unresolved.")
        }
        XCTAssertTrue(message.contains("uncertain"))
        let record = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        XCTAssertEqual(record?.phase, .attempted)
        XCTAssertNil(record?.report)
    }

    func testFreshRecoveryPostCommitFaultReportsUncertainPersistence()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        let (journal, _, _) = try await unresolvedFixture(
            fixture,
            attempted: false
        )
        let coordinator = freshCoordinator(
            fixture,
            afterFinalizationForTesting: {
                throw CodexGhostRepairError.recoveryRequired
            }
        )
        let outcome = await coordinator.recoverOperation(
            identity: freshIdentity(fixture)
        )
        guard case let .recoveryRequired(_, message) = outcome else {
            return XCTFail("Post-COMMIT fault must not be reported as clean.")
        }
        XCTAssertTrue(message.contains("uncertain"))
        XCTAssertFalse(message.contains("no journal record was changed"))
        let record = try await journal.record(
            requestID: fixture.livePlan.requestID
        )
        XCTAssertEqual(record?.phase, .terminal)
        XCTAssertEqual(record?.report?.outcome, .notAttempted)
    }

    func testFreshRecoveryManagerVersionDriftDoesNotMigrateOrBootstrap()
        async throws
    {
        let fixture = try makeFixture(itemCount: 2)
        _ = try await unresolvedFixture(
            fixture,
            attempted: true
        )
        try execute("PRAGMA user_version = 18", at: fixture.managerStateURL)
        let beforeNames = try Set(FileManager.default.contentsOfDirectory(
            atPath: fixture.parent.path
        ))
        let outcome = await freshCoordinator(fixture).recoverOperation(
            identity: freshIdentity(fixture)
        )
        guard case .unavailable = outcome else {
            return XCTFail("A non-current manager schema must fail closed.")
        }
        XCTAssertEqual(
            try scalar("PRAGMA user_version", at: fixture.managerStateURL),
            18
        )
        let afterNames = try Set(FileManager.default.contentsOfDirectory(
            atPath: fixture.parent.path
        ))
        XCTAssertEqual(afterNames, beforeNames)
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM codex_ghost_repair_bulk_live_execution_journal WHERE phase = 'attempted'",
                at: fixture.managerStateURL
            ),
            1
        )
    }

    private func freshJournal(
        _ fixture: Fixture
    ) -> CodexGhostRepairBulkLivePackagedExecutionJournal {
        CodexGhostRepairBulkLivePackagedExecutionJournal {
            try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        }
    }

    private func unresolvedFixture(
        _ fixture: Fixture,
        attempted: Bool
    ) async throws -> (
        CodexGhostRepairBulkLivePackagedExecutionJournal,
        CodexGhostRepairBulkLiveMixedClaim,
        CodexGhostRepairBulkLiveMixedAttempt?
    ) {
        let journal = freshJournal(fixture)
        _ = try await journal.prepare(
            plan: fixture.livePlan,
            confirmationReceipt: fixture.confirmationReceipt
        )
        let claim = try await journal.claim(
            requestID: fixture.livePlan.requestID,
            expectedPlanDigest: fixture.livePlan.planDigest,
            claimID: UUID(),
            claimedAtMilliseconds: 1_600
        )
        let attempt: CodexGhostRepairBulkLiveMixedAttempt? = if attempted {
            try await journal.recordAttempt(
                requestID: fixture.livePlan.requestID,
                expectedClaimDigest: claim.claimDigest,
                attemptedAtMilliseconds: 1_700
            )
        } else {
            nil
        }
        return (journal, claim, attempt)
    }

    private func freshCoordinator(
        _ fixture: Fixture,
        readback: (any CodexGhostRepairBulkFreshRecoveryReading)? = nil,
        nowMilliseconds: @escaping @Sendable () -> Int64 = { 1_800 },
        afterFinalizationForTesting:
            @escaping @Sendable () throws -> Void = {}
    ) -> CodexGhostRepairBulkFreshRecoveryLiveCoordinator {
        CodexGhostRepairBulkFreshRecoveryLiveCoordinator(
            databaseURLProvider: { fixture.managerStateURL },
            operationExclusion: .init(
                databaseURL: fixture.managerStateURL
            ),
            readbackProvider: { profile in
                XCTAssertEqual(profile, fixture.profile)
                return readback ?? fixture.liveMutator()
            },
            nowMilliseconds: nowMilliseconds,
            makeUUID: {
                UUID(uuidString: "94000000-0000-4000-8000-000000000001")!
            },
            afterFinalizationForTesting: afterFinalizationForTesting
        )
    }

    private func freshIdentity(
        _ fixture: Fixture
    ) -> CodexGhostRepairBulkRecoveryOperationIdentity {
        .init(
            requestID: fixture.livePlan.requestID,
            operationID: fixture.confirmationReceipt.operationID
        )
    }

    private func durableFileContents(
        in directory: URL
    ) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return [:]
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return try Dictionary(uniqueKeysWithValues: names.sorted().compactMap {
            name in
            guard !name.hasSuffix("-shm") else { return nil }
            let url = directory.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            return (name, try Data(contentsOf: url))
        })
    }

    private typealias Fixture = BulkShippingCompositionTestFixture.Value

    private func makeFixture(
        itemCount: Int,
        desktopSchema: Int32 = 32,
        alreadyAbsentIndices: Set<Int> = []
    ) throws -> Fixture {
        try BulkShippingCompositionTestFixture.make(
            itemCount: itemCount,
            desktopSchema: desktopSchema,
            alreadyAbsentIndices: alreadyAbsentIndices
        )
    }

    private func replacingFingerprintMember(
        _ member: CodexGhostRepairSnapshotCanonicalFile,
        in fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        seed: Int
    ) throws -> CodexGhostRepairSnapshotCanonicalFingerprint {
        try BulkShippingCompositionTestFixture.replacingFingerprintMember(
            member,
            in: fingerprint,
            seed: seed
        )
    }

    private func execute(_ sql: String, at url: URL) throws {
        try BulkShippingCompositionTestFixture.execute(sql, at: url)
    }

    private func scalar(_ sql: String, at url: URL) throws -> Int {
        try BulkShippingCompositionTestFixture.scalar(sql, at: url)
    }

    private func identifier(_ index: Int) -> String {
        BulkShippingCompositionTestFixture.identifier(index)
    }

    private func hash(_ seed: Int) -> String {
        BulkShippingCompositionTestFixture.hash(seed)
    }
}

private struct IncompleteFreshRecoveryGate:
    CodexGhostRepairExecutionGateSource,
    Sendable
{
    func ghostRepairExecutionGate() -> CodexGhostRepairExecutionGate {
        CodexGhostRepairExecutionGate(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            stateOpenHandleCount: nil,
            threadHistoryOpenHandleCount: nil,
            capacitySufficient: true,
            desktopProcessEvidence: [],
            openHandleOwnerEvidence: []
        )
    }
}


#endif
