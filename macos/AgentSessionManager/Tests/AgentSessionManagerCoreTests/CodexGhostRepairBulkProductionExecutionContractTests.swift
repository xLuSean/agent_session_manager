@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

#if AGENT_SESSION_MANAGER_RESEARCH

final class CodexGhostRepairBulkProductionExecutionContractTests:
    XCTestCase
{
    func testHistoricalScaleDraftBindsOnePlanFiveHandleGateAndBackup()
        throws
    {
        let fixture = try makeFixture(itemCount: 148, blockedCount: 3)

        XCTAssertEqual(fixture.plan.selectedThreadIDs.count, 145)
        XCTAssertEqual(fixture.backup.files.count, 20)
        XCTAssertTrue(
            fixture.preBackup.allFiveDatabaseHandleCountsAreZero
        )
        XCTAssertEqual(
            fixture.draft.selectedThreadIDs,
            fixture.plan.selectedThreadIDs
        )
        XCTAssertEqual(
            fixture.draft.confirmationReceiptID,
            fixture.plan.confirmationReceiptID
        )
        XCTAssertEqual(
            fixture.draft.selectedItems.map(\.category),
            fixture.plan.selectedItems.map(\.category)
        )
        XCTAssertEqual(fixture.draft.plan, fixture.plan)
        XCTAssertEqual(fixture.draft.backup, fixture.backup)
        XCTAssertEqual(
            fixture.draft.plan.selectedItems.map(\.catalogRowDigest),
            fixture.plan.selectedItems.map(\.catalogRowDigest)
        )
        XCTAssertEqual(
            fixture.draft.plan.authority,
            fixture.plan.authority
        )
        XCTAssertEqual(
            fixture.draft.plan.databases,
            fixture.plan.databases
        )
        XCTAssertEqual(fixture.draft.blockedOutsideBatchCount, 3)
        XCTAssertTrue(fixture.draft.allOrNothing)
        XCTAssertFalse(fixture.draft.silentSelectionShrinkAllowed)
        XCTAssertFalse(fixture.draft.managerClaimCreated)
        XCTAssertFalse(fixture.draft.executionAvailable)
        XCTAssertFalse(fixture.draft.repairMutationAuthority)
        XCTAssertFalse(fixture.draft.automaticRetryAllowed)
    }

    func testAnyOfFiveOpenHandleCountsBlocksBeforeDraft() throws {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        let roles: [(Int, Int, Int, Int?, Int?)] = [
            (1, 0, 0, 0, 0), (0, 1, 0, 0, 0), (0, 0, 1, 0, 0),
            (0, 0, 0, 1, 0), (0, 0, 0, 0, 1),
        ]
        for role in roles {
            XCTAssertThrowsError(try maintenance(
                at: 1_350,
                fingerprint: fixture.preBackup.sourceFingerprintHash,
                desktop: role.0,
                summaries: role.1,
                history: role.2,
                state: role.3,
                threadHistory: role.4
            ))
        }
    }

    func testMissingFreshProcessOrOwnerEvidenceBlocks() throws {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        XCTAssertThrowsError(try maintenance(
            at: 1_350,
            fingerprint: fixture.preBackup.sourceFingerprintHash,
            processEvidence: nil
        ))
        XCTAssertThrowsError(try maintenance(
            at: 1_350,
            fingerprint: fixture.preBackup.sourceFingerprintHash,
            ownerEvidence: nil
        ))
    }

    func testBackupMembershipAndRequiredDatabaseEvidenceFailClosed()
        throws
    {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        XCTAssertThrowsError(try CodexGhostRepairBulkExecutionBackupReceipt(
            operationID: fixture.plan.operationID,
            planDigest: fixture.plan.planDigest,
            selectedThreadIDs: fixture.plan.selectedThreadIDs,
            sourceFingerprintHash: fixture.preBackup.sourceFingerprintHash,
            files: Array(fixture.backup.files.dropLast()),
            capturedAtMilliseconds: 1_400
        ))
        var files = fixture.backup.files
        files[0] = .init(
            fileName: files[0].fileName,
            present: false,
            byteCount: nil,
            contentHash: nil
        )
        XCTAssertThrowsError(try CodexGhostRepairBulkExecutionBackupReceipt(
            operationID: fixture.plan.operationID,
            planDigest: fixture.plan.planDigest,
            selectedThreadIDs: fixture.plan.selectedThreadIDs,
            sourceFingerprintHash: fixture.preBackup.sourceFingerprintHash,
            files: files,
            capturedAtMilliseconds: 1_400
        ))
    }

    func testSourceOrAuthorityDriftAcrossBackupBlocksWholeBatch() throws {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        let sourceDrift = try maintenance(
            at: 1_450,
            fingerprint: hash(90)
        )
        XCTAssertThrowsError(try CodexGhostRepairBulkProductionExecutionDraft
            .prepare(
                plan: fixture.plan,
                preBackupMaintenance: fixture.preBackup,
                backup: fixture.backup,
                postBackupMaintenance: sourceDrift,
                preparedAtMilliseconds: 1_500
            ))
        let authorityDrift = try maintenance(
            at: 1_450,
            fingerprint: fixture.preBackup.sourceFingerprintHash,
            authority: hash(91)
        )
        XCTAssertThrowsError(try CodexGhostRepairBulkProductionExecutionDraft
            .prepare(
                plan: fixture.plan,
                preBackupMaintenance: fixture.preBackup,
                backup: fixture.backup,
                postBackupMaintenance: authorityDrift,
                preparedAtMilliseconds: 1_500
            ))
    }

    func testContractCapabilitiesDoNotGrantShippingOrLiveAuthority() {
        let capabilities = CodexGhostRepairBulkProductionExecutionCapabilities()
        XCTAssertTrue(capabilities.contractOnly)
        XCTAssertEqual(capabilities.maximumTargetCount, 500)
        XCTAssertTrue(capabilities.requiresFiveDatabaseHandleCounts)
        XCTAssertTrue(capabilities.requiresFreshProcessEvidence)
        XCTAssertTrue(capabilities.requiresOperationBoundVerifiedBackup)
        XCTAssertTrue(capabilities.requiresWholeBatchConfirmationReceipt)
        XCTAssertFalse(capabilities.managerClaimAvailable)
        XCTAssertFalse(capabilities.filesystemMutationAuthority)
        XCTAssertFalse(capabilities.repairMutationAuthority)
        XCTAssertFalse(capabilities.appWiringAvailable)
        XCTAssertFalse(capabilities.acceptsLiveCodexRoot)
    }

    func testManagerJournalPersistsExact148BatchThroughOneTerminalReport()
        throws
    {
        let context = try makeStore()
        defer { context.store.close() }
        let fixture = try makeFixture(
            itemCount: 148,
            blockedCount: 3,
            store: context.store
        )

        let prepared = try context.store
            .prepareCodexGhostRepairBulkExecutionJournal(draft: fixture.draft)
        XCTAssertEqual(prepared.phase, .prepared)
        XCTAssertEqual(prepared.draft.selectedThreadIDs.count, 145)
        XCTAssertEqual(prepared.draft.plan, fixture.plan)
        XCTAssertEqual(prepared.draft.backup, fixture.backup)

        let claim = try context.store.claimCodexGhostRepairBulkExecution(
            operationID: fixture.draft.operationID,
            expectedDraftDigest: fixture.draft.draftDigest,
            claimID: UUID(),
            claimedAtMilliseconds: 1_600
        )
        let attempt = try context.store
            .recordCodexGhostRepairBulkExecutionAttempt(
                operationID: fixture.draft.operationID,
                expectedClaimDigest: claim.claimDigest,
                attemptedAtMilliseconds: 1_700
            )
        let report = try CodexGhostRepairBulkProductionTerminalReport(
            reportID: UUID(),
            draft: fixture.draft,
            claim: claim,
            attempt: attempt,
            outcome: .success,
            completedAtMilliseconds: 1_800
        )
        let terminal = try context.store
            .recordCodexGhostRepairBulkTerminalReport(report)

        XCTAssertEqual(terminal.phase, .terminal)
        XCTAssertEqual(terminal.mutationAttemptCount, 1)
        XCTAssertEqual(terminal.report?.items.count, 145)
        XCTAssertEqual(
            terminal.report?.items.map(\.category),
            fixture.draft.selectedItems.map(\.category)
        )
        XCTAssertTrue(terminal.report?.items.allSatisfy {
            $0.outcome == .success
        } == true)
        XCTAssertFalse(terminal.automaticRetryAllowed)
        XCTAssertFalse(terminal.automaticRestoreAllowed)
        XCTAssertFalse(terminal.silentSelectionShrinkAllowed)

        let cold = try XCTUnwrap(context.store
            .codexGhostRepairBulkExecutionJournal(
                operationID: fixture.draft.operationID
            ))
        XCTAssertEqual(cold.draft.plan, fixture.plan)
        XCTAssertEqual(cold.draft.backup, fixture.backup)
        XCTAssertEqual(cold, terminal)
        XCTAssertEqual(try context.store
            .codexGhostRepairBulkExecutionJournal(
                confirmationReceiptID:
                    fixture.draft.confirmationReceiptID
            ), terminal)
    }

    func testClaimAndAttemptCannotReplay() throws {
        let context = try makeStore()
        defer { context.store.close() }
        let fixture = try makeFixture(
            itemCount: 10,
            blockedCount: 0,
            store: context.store
        )
        _ = try context.store.prepareCodexGhostRepairBulkExecutionJournal(
            draft: fixture.draft
        )
        let claim = try context.store.claimCodexGhostRepairBulkExecution(
            operationID: fixture.draft.operationID,
            expectedDraftDigest: fixture.draft.draftDigest,
            claimID: UUID(),
            claimedAtMilliseconds: 1_600
        )
        XCTAssertThrowsError(try context.store
            .claimCodexGhostRepairBulkExecution(
                operationID: fixture.draft.operationID,
                expectedDraftDigest: fixture.draft.draftDigest,
                claimID: UUID(),
                claimedAtMilliseconds: 1_601
            )) { error in
                XCTAssertEqual(error as? CodexGhostRepairError,
                               .claimAlreadyExists)
            }
        _ = try context.store.recordCodexGhostRepairBulkExecutionAttempt(
            operationID: fixture.draft.operationID,
            expectedClaimDigest: claim.claimDigest,
            attemptedAtMilliseconds: 1_700
        )
        XCTAssertThrowsError(try context.store
            .recordCodexGhostRepairBulkExecutionAttempt(
                operationID: fixture.draft.operationID,
                expectedClaimDigest: claim.claimDigest,
                attemptedAtMilliseconds: 1_701
            )) { error in
                XCTAssertEqual(error as? CodexGhostRepairError,
                               .recoveryRequired)
            }
    }

    func testClaimedCrashCanOnlyBecomeTerminalNotAttempted() throws {
        let context = try makeStore()
        defer { context.store.close() }
        let fixture = try makeFixture(
            itemCount: 10,
            blockedCount: 0,
            store: context.store
        )
        _ = try context.store.prepareCodexGhostRepairBulkExecutionJournal(
            draft: fixture.draft
        )
        let claim = try context.store.claimCodexGhostRepairBulkExecution(
            operationID: fixture.draft.operationID,
            expectedDraftDigest: fixture.draft.draftDigest,
            claimID: UUID(),
            claimedAtMilliseconds: 1_600
        )
        let cold = try XCTUnwrap(context.store
            .codexGhostRepairBulkExecutionJournal(
                operationID: fixture.draft.operationID
            ))
        XCTAssertEqual(cold.phase, .claimed)
        XCTAssertNil(cold.attempt)

        let report = try CodexGhostRepairBulkProductionTerminalReport(
            reportID: UUID(),
            draft: fixture.draft,
            claim: claim,
            attempt: nil,
            outcome: .notAttempted,
            completedAtMilliseconds: 1_700
        )
        let terminal = try context.store
            .recordCodexGhostRepairBulkTerminalReport(report)
        XCTAssertEqual(terminal.phase, .terminal)
        XCTAssertEqual(terminal.mutationAttemptCount, 0)
        XCTAssertThrowsError(try context.store
            .recordCodexGhostRepairBulkTerminalReport(report))
    }

    func testJournalRequiresPersistedExactConfirmationReceipt() throws {
        let context = try makeStore()
        defer { context.store.close() }
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)

        XCTAssertThrowsError(try context.store
            .prepareCodexGhostRepairBulkExecutionJournal(
                draft: fixture.draft
            ))
        XCTAssertNil(try context.store.codexGhostRepairBulkExecutionJournal(
            operationID: fixture.draft.operationID
        ))
    }

    func testJournalRejectsDraftConflictAndPayloadTampering() throws {
        let context = try makeStore()
        defer { context.store.close() }
        let fixture = try makeFixture(
            itemCount: 10,
            blockedCount: 0,
            store: context.store
        )
        _ = try context.store.prepareCodexGhostRepairBulkExecutionJournal(
            draft: fixture.draft
        )
        let changedDraft = try CodexGhostRepairBulkProductionExecutionDraft
            .prepare(
                plan: fixture.plan,
                preBackupMaintenance: fixture.preBackup,
                backup: fixture.backup,
                postBackupMaintenance: try maintenance(
                    at: 1_450,
                    fingerprint: fixture.preBackup.sourceFingerprintHash
                ),
                preparedAtMilliseconds: 1_501
            )
        XCTAssertThrowsError(try context.store
            .prepareCodexGhostRepairBulkExecutionJournal(
                draft: changedDraft
            ))

        context.store.close()
        try tamperJournalPayload(at: context.databaseURL)
        let reopened = try SQLiteStateStore(databaseURL: context.databaseURL)
        defer { reopened.close() }
        XCTAssertThrowsError(try reopened
            .codexGhostRepairBulkExecutionJournal(
                operationID: fixture.draft.operationID
            ))
    }

    func testDeterministicCoordinatorExecutesExactHistoricalBatchOnce()
        async throws
    {
        let fixture = try makeFixture(itemCount: 148, blockedCount: 3)
        let preparer = BulkDraftPreparer(draft: fixture.draft)
        let journal = BulkExecutionJournal()
        let mutator = BulkMutator(executionOutcome: .success)
        let coordinator = CodexGhostRepairBulkRepairExecutionCoordinator(
            draftPreparer: preparer,
            journal: journal,
            mutator: mutator,
            nowMilliseconds: { 1_600 }
        )
        let reviewRequest = CodexGhostRepairBulkRepairReviewRequest(
            requestID: UUID(),
            confirmationReceiptID: fixture.draft.confirmationReceiptID
        )
        let review: CodexGhostRepairBulkFinalReview
        switch await coordinator.prepareFinalReview(request: reviewRequest) {
        case let .ready(value): review = value
        default:
            return XCTFail("Expected exact final Review.")
        }
        XCTAssertEqual(review.selectedCount, 145)
        XCTAssertEqual(review.ordinaryCount, fixture.draft.ordinaryCount)
        XCTAssertEqual(review.automationCount, fixture.draft.automationCount)
        XCTAssertEqual(review.blockedOutsideBatchCount, 3)

        let execution = CodexGhostRepairBulkRepairExecutionRequest(
            requestID: UUID(),
            review: review
        )
        let first = await coordinator.execute(request: execution)
        let second = await coordinator.execute(request: execution)
        for outcome in [first, second] {
            guard case let .completed(report) = outcome else {
                return XCTFail("Expected one durable terminal Report.")
            }
            XCTAssertEqual(report.itemReports.count, 145)
            XCTAssertEqual(
                report.itemReports.map { $0.category },
                fixture.draft.selectedItems.map { $0.category }
            )
            XCTAssertTrue(report.itemReports.allSatisfy {
                $0.outcome == .success
            })
        }
        let executionCount = await mutator.executionCount()
        let recoveryCount = await mutator.recoveryCount()
        let attemptCount = await journal.mutationAttemptCount()
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(attemptCount, 1)
    }

    func testClaimedColdStateFinishesNotAttemptedWithoutMutation()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 2)
        let journal = BulkExecutionJournal()
        let coordinator = CodexGhostRepairBulkRepairExecutionCoordinator(
            draftPreparer: BulkDraftPreparer(draft: fixture.draft),
            journal: journal,
            mutator: BulkMutator(executionOutcome: .success),
            nowMilliseconds: { 1_600 }
        )
        let review = try await preparedReview(
            coordinator: coordinator,
            draft: fixture.draft
        )
        _ = try await journal.claim(
            operationID: fixture.draft.operationID,
            expectedDraftDigest: fixture.draft.draftDigest,
            claimID: UUID(),
            claimedAtMilliseconds: 1_600
        )

        let outcome = await coordinator.execute(request:
            CodexGhostRepairBulkRepairExecutionRequest(
            requestID: UUID(),
            review: review
        ))
        guard case let .completed(report) = outcome else {
            return XCTFail("Expected terminal not-attempted readback.")
        }
        XCTAssertEqual(
            report.outcome,
            CodexGhostRepairBulkRepairObservedOutcome.notAttempted
        )
        XCTAssertTrue(report.itemReports.allSatisfy {
            $0.outcome
                == CodexGhostRepairBulkRepairObservedOutcome.notAttempted
        })
        let attemptCount = await journal.mutationAttemptCount()
        XCTAssertEqual(attemptCount, 0)
    }

    func testAttemptedColdStateUsesReadbackOnlyAndNeverReexecutes()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        let journal = BulkExecutionJournal()
        let mutator = BulkMutator(
            executionOutcome: .explicitFailure,
            recoveryOutcome: .success
        )
        let coordinator = CodexGhostRepairBulkRepairExecutionCoordinator(
            draftPreparer: BulkDraftPreparer(draft: fixture.draft),
            journal: journal,
            mutator: mutator,
            nowMilliseconds: { 1_700 }
        )
        let review = try await preparedReview(
            coordinator: coordinator,
            draft: fixture.draft
        )
        let claim = try await journal.claim(
            operationID: fixture.draft.operationID,
            expectedDraftDigest: fixture.draft.draftDigest,
            claimID: UUID(),
            claimedAtMilliseconds: 1_600
        )
        _ = try await journal.recordAttempt(
            operationID: fixture.draft.operationID,
            expectedClaimDigest: claim.claimDigest,
            attemptedAtMilliseconds: 1_650
        )

        let outcome = await coordinator.execute(request:
            CodexGhostRepairBulkRepairExecutionRequest(
            requestID: UUID(),
            review: review
        ))
        guard case let .completed(report) = outcome else {
            return XCTFail("Expected readback-only terminal Report.")
        }
        XCTAssertEqual(
            report.outcome,
            CodexGhostRepairBulkRepairObservedOutcome.success
        )
        let executionCount = await mutator.executionCount()
        let recoveryCount = await mutator.recoveryCount()
        let attemptCount = await journal.mutationAttemptCount()
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(attemptCount, 1)
    }

    func testReceiptIdentityMismatchBlocksBeforeJournalOrClaim() async throws {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        let journal = BulkExecutionJournal()
        let mutator = BulkMutator(executionOutcome: .success)
        let coordinator = CodexGhostRepairBulkRepairExecutionCoordinator(
            draftPreparer: BulkDraftPreparer(draft: fixture.draft),
            journal: journal,
            mutator: mutator,
            nowMilliseconds: { 1_600 }
        )

        let outcome = await coordinator.prepareFinalReview(request:
            CodexGhostRepairBulkRepairReviewRequest(
            requestID: UUID(),
            confirmationReceiptID: UUID()
        ))
        guard case .blocked = outcome else {
            return XCTFail("Expected exact receipt mismatch to block.")
        }
        let record = await journal.currentRecord()
        let executionCount = await mutator.executionCount()
        XCTAssertNil(record)
        XCTAssertEqual(executionCount, 0)
    }

    func testDraftCollectorSequencesExactPlanTwoMaintenanceReadsAndOneBackup()
        async throws
    {
        let fixture = try makeFixture(itemCount: 148, blockedCount: 3)
        let after = try maintenance(
            at: 1_450,
            fingerprint: fixture.preBackup.sourceFingerprintHash
        )
        let trace = BulkDraftCollectionTrace()
        let collector = CodexGhostRepairBulkProductionDraftCollector(
            planCollector: BulkPlanCollector(
                plan: fixture.plan,
                trace: trace
            ),
            maintenanceCollector: BulkMaintenanceCollector(
                before: fixture.preBackup,
                after: after,
                trace: trace
            ),
            backupCreator: BulkBackupCreator(
                receipt: fixture.backup,
                trace: trace
            ),
            nowMilliseconds: { 1_500 }
        )

        let draft = try await collector.prepareDraft(
            confirmationReceiptID: fixture.plan.confirmationReceiptID
        )

        XCTAssertEqual(draft, fixture.draft)
        let events = await trace.events()
        XCTAssertEqual(events, [
            "plan",
            "maintenance-before-backup",
            "backup-create-or-read",
            "maintenance-after-backup",
        ])
        XCTAssertEqual(collector.capabilities.maintenanceReadCount, 2)
        XCTAssertEqual(collector.capabilities.backupCreateOrReadCount, 1)
        XCTAssertFalse(collector.capabilities.automaticRetryAllowed)
        XCTAssertFalse(collector.capabilities.automaticRestoreAllowed)
        XCTAssertFalse(collector.capabilities.acceptsCallerPath)
        XCTAssertFalse(collector.capabilities.acceptsLiveCodexRoot)
        XCTAssertFalse(collector.capabilities.repairMutationAuthority)
    }

    func testDraftCollectorStopsBeforeBackupWhenFirstMaintenanceReadFails()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        let trace = BulkDraftCollectionTrace()
        let collector = CodexGhostRepairBulkProductionDraftCollector(
            planCollector: BulkPlanCollector(
                plan: fixture.plan,
                trace: trace
            ),
            maintenanceCollector: BulkMaintenanceCollector(
                before: fixture.preBackup,
                after: fixture.preBackup,
                trace: trace,
                failingPhase: .beforeBackup
            ),
            backupCreator: BulkBackupCreator(
                receipt: fixture.backup,
                trace: trace
            ),
            nowMilliseconds: { 1_500 }
        )

        do {
            _ = try await collector.prepareDraft(
                confirmationReceiptID: fixture.plan.confirmationReceiptID
            )
            XCTFail("Expected first maintenance failure.")
        } catch {}
        let events = await trace.events()
        XCTAssertEqual(events, [
            "plan",
            "maintenance-before-backup",
        ])
    }

    func testSecondFinalReviewReadsPreparedJournalWithoutRepeatingDraftOrBackup()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        let preparer = BulkDraftPreparer(draft: fixture.draft)
        let coordinator = CodexGhostRepairBulkRepairExecutionCoordinator(
            draftPreparer: preparer,
            journal: BulkExecutionJournal(),
            mutator: BulkMutator(executionOutcome: .success),
            nowMilliseconds: { 1_600 }
        )
        let request = CodexGhostRepairBulkRepairReviewRequest(
            requestID: UUID(),
            confirmationReceiptID: fixture.draft.confirmationReceiptID
        )

        guard case .ready = await coordinator.prepareFinalReview(
            request: request
        ) else { return XCTFail("Expected first Review.") }
        guard case .ready = await coordinator.prepareFinalReview(
            request: request
        ) else { return XCTFail("Expected prepared journal readback.") }

        let callCount = await preparer.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testColdReviewRestoresAdvancedJournalWithoutPreparingAgain()
        async throws
    {
        let fixture = try makeFixture(itemCount: 10, blockedCount: 0)
        let journal = BulkExecutionJournal()
        _ = try await journal.prepare(draft: fixture.draft)
        _ = try await journal.claim(
            operationID: fixture.draft.operationID,
            expectedDraftDigest: fixture.draft.draftDigest,
            claimID: UUID(),
            claimedAtMilliseconds: 1_600
        )
        let preparer = BulkDraftPreparer(draft: fixture.draft)
        let coordinator = CodexGhostRepairBulkRepairExecutionCoordinator(
            draftPreparer: preparer,
            journal: journal,
            mutator: BulkMutator(executionOutcome: .success),
            nowMilliseconds: { 1_700 }
        )

        let review = try await preparedReview(
            coordinator: coordinator,
            draft: fixture.draft
        )
        let prepareCalls = await preparer.callCount()
        XCTAssertEqual(prepareCalls, 0)

        let outcome = await coordinator.execute(request: .init(
            requestID: UUID(),
            review: review
        ))
        guard case let .completed(report) = outcome else {
            return XCTFail("Expected cold not-attempted terminal Report.")
        }
        XCTAssertEqual(report.outcome, .notAttempted)
    }

    func testOperationBoundBackupCopiesTwentyFilesAndColdReadsWithoutSource()
        async throws
    {
        let production = try makeFixture(itemCount: 148, blockedCount: 3)
        let storage = try makeBackupTransportFixture(label: #function)
        let fingerprint = try storage.source.fingerprint()
        let gate = try maintenance(
            at: 1_350,
            fingerprint: fingerprint.fingerprintHash
        )
        let transport = try CodexGhostRepairBulkOperationBoundBackupTransport(
            source: storage.source,
            testOwnedManagerRootURL: storage.managerRoot,
            testOwnedAllowedParentURL: storage.parent,
            nowMilliseconds: { 1_400 }
        )

        let first = try await transport.createOrReadExactBackup(
            plan: production.plan,
            maintenance: gate
        )
        XCTAssertEqual(first.operationID, production.plan.operationID)
        XCTAssertEqual(first.files.count, 20)
        XCTAssertTrue(first.files.allSatisfy(\.present))
        XCTAssertEqual(first.capturedAtMilliseconds, 1_400)
        XCTAssertTrue(first.readbackVerified)
        XCTAssertFalse(first.restoreAuthority)
        XCTAssertFalse(first.cleanupAuthority)

        let operationDirectory = storage.backupRoot.appendingPathComponent(
            production.plan.operationID.uuidString.lowercased(),
            isDirectory: true
        )
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(
                atPath: operationDirectory.path
            )),
            Set(
                CodexGhostRepairSnapshotCanonicalFile.allCases.map(\.rawValue)
                    + [CodexGhostRepairBulkOperationBoundBackupTransport
                        .manifestFileName]
            )
        )

        // A complete operation backup must cold-read from its own durable
        // bytes. Making every source unreadable proves the second call did not
        // reopen or recopy the source.
        for file in CodexGhostRepairSnapshotCanonicalFile.allCases {
            XCTAssertEqual(chmod(storage.sourceURL(file).path, 0o000), 0)
        }
        let second = try await transport.createOrReadExactBackup(
            plan: production.plan,
            maintenance: gate
        )
        XCTAssertEqual(second, first)
        XCTAssertEqual(transport.capabilities.fixedCanonicalFileCount, 20)
        XCTAssertTrue(transport.capabilities.manifestWrittenLast)
        XCTAssertFalse(transport.capabilities.overwritesExistingOperation)
        XCTAssertFalse(transport.capabilities.retriesPartialOperation)
        XCTAssertFalse(transport.capabilities.acceptsLiveCodexRoot)
        XCTAssertFalse(transport.capabilities.appWiringAvailable)
        XCTAssertFalse(transport.capabilities.repairMutationAuthority)
    }

    func testPartialOperationDirectoryCannotBeRetriedOrOverwritten()
        async throws
    {
        let production = try makeFixture(itemCount: 10, blockedCount: 0)
        let storage = try makeBackupTransportFixture(label: #function)
        let fingerprint = try storage.source.fingerprint()
        let gate = try maintenance(
            at: 1_350,
            fingerprint: fingerprint.fingerprintHash
        )
        let partial = storage.backupRoot.appendingPathComponent(
            production.plan.operationID.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: partial,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let transport = try CodexGhostRepairBulkOperationBoundBackupTransport(
            source: storage.source,
            testOwnedManagerRootURL: storage.managerRoot,
            testOwnedAllowedParentURL: storage.parent
        )

        do {
            _ = try await transport.createOrReadExactBackup(
                plan: production.plan,
                maintenance: gate
            )
            XCTFail("Expected partial operation to fail closed.")
        } catch {
            XCTAssertNotNil(error as? CodexGhostRepairError)
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: partial.path)
                .isEmpty
        )
    }

    func testDurableBackupTamperFailsClosedWithoutRecopy()
        async throws
    {
        let production = try makeFixture(itemCount: 10, blockedCount: 0)
        let storage = try makeBackupTransportFixture(label: #function)
        let fingerprint = try storage.source.fingerprint()
        let gate = try maintenance(
            at: 1_350,
            fingerprint: fingerprint.fingerprintHash
        )
        let transport = try CodexGhostRepairBulkOperationBoundBackupTransport(
            source: storage.source,
            testOwnedManagerRootURL: storage.managerRoot,
            testOwnedAllowedParentURL: storage.parent,
            nowMilliseconds: { 1_400 }
        )
        _ = try await transport.createOrReadExactBackup(
            plan: production.plan,
            maintenance: gate
        )
        let copiedDesktop = storage.backupRoot
            .appendingPathComponent(
                production.plan.operationID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent(
                CodexGhostRepairSnapshotCanonicalFile.desktop.rawValue
            )
        try Data("tampered".utf8).write(to: copiedDesktop)
        XCTAssertEqual(chmod(copiedDesktop.path, 0o600), 0)

        do {
            _ = try await transport.createOrReadExactBackup(
                plan: production.plan,
                maintenance: gate
            )
            XCTFail("Expected durable backup tamper to fail closed.")
        } catch {
            XCTAssertNotNil(error as? CodexGhostRepairError)
        }
        XCTAssertEqual(try Data(contentsOf: copiedDesktop), Data("tampered".utf8))
    }

    func testOperationBackupRejectsProductionSourceCapability() throws {
        let storage = try makeBackupTransportFixture(label: #function)
        XCTAssertThrowsError(
            try CodexGhostRepairBulkOperationBoundBackupTransport(
                source: .production(),
                testOwnedManagerRootURL: storage.managerRoot,
                testOwnedAllowedParentURL: storage.parent
            )
        )
    }

    func testSourceFingerprintMismatchStopsBeforeOperationDirectory()
        async throws
    {
        let production = try makeFixture(itemCount: 10, blockedCount: 0)
        let storage = try makeBackupTransportFixture(label: #function)
        let mismatchedGate = try maintenance(
            at: 1_350,
            fingerprint: hash(9_999)
        )
        let transport = try CodexGhostRepairBulkOperationBoundBackupTransport(
            source: storage.source,
            testOwnedManagerRootURL: storage.managerRoot,
            testOwnedAllowedParentURL: storage.parent
        )

        do {
            _ = try await transport.createOrReadExactBackup(
                plan: production.plan,
                maintenance: mismatchedGate
            )
            XCTFail("Expected source fingerprint mismatch.")
        } catch {
            XCTAssertNotNil(error as? CodexGhostRepairError)
        }
        let operationDirectory = storage.backupRoot.appendingPathComponent(
            production.plan.operationID.uuidString.lowercased(),
            isDirectory: true
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: operationDirectory.path)
        )
    }

    private func preparedReview(
        coordinator: CodexGhostRepairBulkRepairExecutionCoordinator,
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) async throws -> CodexGhostRepairBulkFinalReview {
        let outcome = await coordinator.prepareFinalReview(request: .init(
            requestID: UUID(),
            confirmationReceiptID: draft.confirmationReceiptID
        ))
        guard case let .ready(review) = outcome else {
            throw CodexGhostRepairError.invalidPlan(
                "Expected deterministic final Review."
            )
        }
        return review
    }

    private struct Fixture {
        let plan: CodexGhostRepairBulkExecutionPlan
        let preBackup: CodexGhostRepairBulkMaintenanceEvidence
        let backup: CodexGhostRepairBulkExecutionBackupReceipt
        let draft: CodexGhostRepairBulkProductionExecutionDraft
    }

    private struct StoreContext {
        let store: SQLiteStateStore
        let databaseURL: URL
    }

    private struct BackupTransportFixture {
        let parent: URL
        let codexHome: URL
        let sqliteRoot: URL
        let managerRoot: URL
        let backupRoot: URL
        let source: CodexGhostRepairSnapshotCanonicalSource

        func sourceURL(
            _ file: CodexGhostRepairSnapshotCanonicalFile
        ) -> URL {
            file.sourceURL(
                codexHomeURL: codexHome,
                sqliteRootURL: sqliteRoot
            )
        }
    }

    private func makeBackupTransportFixture(
        label: String
    ) throws -> BackupTransportFixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "bulk-operation-backup-\(safeLabel)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let codexHome = parent.appendingPathComponent(
            "source/.codex",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sqliteRoot = codexHome.appendingPathComponent(
            "sqlite",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sqliteRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sourceMarker = codexHome.appendingPathComponent(
            CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerFileName
        )
        try Data(
            CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerContents.utf8
        ).write(to: sourceMarker)
        XCTAssertEqual(chmod(sourceMarker.path, 0o600), 0)
        for (index, file) in CodexGhostRepairSnapshotCanonicalFile.allCases
            .enumerated() {
            let url = file.sourceURL(
                codexHomeURL: codexHome,
                sqliteRootURL: sqliteRoot
            )
            try Data("bulk-backup-\(index)-\(file.rawValue)".utf8)
                .write(to: url)
            XCTAssertEqual(chmod(url.path, 0o600), 0)
        }

        let managerRoot = parent.appendingPathComponent(
            "manager",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managerRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let managerMarker = managerRoot.appendingPathComponent(
            CodexGhostRepairBulkOperationBoundBackupTransport.markerFileName
        )
        try Data(
            CodexGhostRepairBulkOperationBoundBackupTransport.markerContents.utf8
        ).write(to: managerMarker)
        XCTAssertEqual(chmod(managerMarker.path, 0o600), 0)
        let backupRoot = managerRoot.appendingPathComponent(
            CodexGhostRepairBulkOperationBoundBackupTransport
                .backupDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: backupRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let source = CodexGhostRepairSnapshotCanonicalSource(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: parent
        )
        return .init(
            parent: parent,
            codexHome: codexHome,
            sqliteRoot: sqliteRoot,
            managerRoot: managerRoot,
            backupRoot: backupRoot,
            source: source
        )
    }

    private func makeFixture(
        itemCount: Int,
        blockedCount: Int,
        store: SQLiteStateStore? = nil
    ) throws
        -> Fixture
    {
        var targets: [CodexGhostRepairSnapshotAnalysisTargetEvidence] = []
        var protections: [CodexGhostRepairProtectionEvidence] = []
        for index in 0..<itemCount {
            let threadID = identifier(index)
            let automation = !index.isMultiple(of: 2)
            targets.append(.init(
                threadID: threadID,
                catalogRowDigests: [hash(index + 100)],
                automationRunRowDigests: automation
                    ? [hash(index + 1_000)] : [],
                automationStableFieldsDigests: automation
                    ? [hash(index + 1_500)] : [],
                automationDefinitionRowDigests: automation
                    ? [hash(index + 2_000)] : [],
                references: .init(
                    inbox: 0, timeline: 0, summaries: 0,
                    canonicalState: 0, threadTurns: 0,
                    threadItems: 0, historyProjection: 0
                ),
                rowContract: automation
                    ? .categoryBEligible : .categoryAEligible
            ))
            protections.append(.init(
                threadID: threadID,
                inventoryComplete: true,
                activeInventoryPresent: false,
                archivedInventoryPresent: false,
                exactReadNotLoaded: true,
                exactReadErrorCode: -32600,
                pinned: index >= itemCount - blockedCount,
                descendantCount: 0
            ))
        }
        let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence] = [
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
            databases: databases,
            targets: targets,
            protectionEvidence: protections,
            authority: .init(
                catalogRevision: 1_000,
                observationSequence: 2_000,
                watermarkUpdatedAt: 3_000,
                metadataRowDigest: hash(3),
                localSyncRowDigest: hash(4)
            )
        )
        let inventory = try CodexGhostRepairBulkInventoryBuilder.build(
            input: input
        )
        let preview = try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: inventory.eligibleThreadIDs,
            previewID: UUID(),
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 10_000
        )
        let challenge: CodexGhostRepairBulkConfirmationChallenge
        let receipt: CodexGhostRepairBulkConfirmationReceipt
        if let store {
            let requestID = UUID()
            _ = try store.saveCodexGhostRepairBulkPreview(
                requestID: requestID,
                preview: preview
            )
            challenge = try store.prepareCodexGhostRepairBulkChallenge(
                savedPreviewRequestID: requestID,
                generatedAtMilliseconds: 1_100
            )
            receipt = try store.consumeCodexGhostRepairBulkConfirmation(
                savedPreviewRequestID: requestID,
                exactConfirmationPhrase: challenge.confirmationPhrase,
                confirmedAtMilliseconds: 1_200
            ).receipt
        } else {
            challenge = try CodexGhostRepairBulkConfirmationChallenge(
                operationID: UUID(),
                savedPreviewRequestID: UUID(),
                preview: preview,
                previewPayloadHash: hash(5),
                generatedAtMilliseconds: 1_100
            )
            receipt = try CodexGhostRepairBulkConfirmationReceipt(
                receiptID: UUID(),
                challenge: challenge,
                confirmedAtMilliseconds: 1_200
            )
        }
        let plan = try CodexGhostRepairBulkExecutionPlan.prepare(
            operationID: challenge.operationID,
            preview: preview,
            challenge: challenge,
            receipt: receipt,
            frozenInventoryInput: input,
            plannedAtMilliseconds: 1_300
        )
        let preBackup = try maintenance(at: 1_350, fingerprint: hash(20))
        let files = CodexGhostRepairSnapshotCanonicalFile.allCases.map {
            CodexGhostRepairBulkExecutionBackupFile(
                fileName: $0.rawValue,
                present: true,
                byteCount: 1,
                contentHash: hash(30 + $0.rawValue.count)
            )
        }
        let backup = try CodexGhostRepairBulkExecutionBackupReceipt(
            operationID: plan.operationID,
            planDigest: plan.planDigest,
            selectedThreadIDs: plan.selectedThreadIDs,
            sourceFingerprintHash: preBackup.sourceFingerprintHash,
            files: files,
            capturedAtMilliseconds: 1_400
        )
        let postBackup = try maintenance(at: 1_450, fingerprint: hash(20))
        let draft = try CodexGhostRepairBulkProductionExecutionDraft.prepare(
            plan: plan,
            preBackupMaintenance: preBackup,
            backup: backup,
            postBackupMaintenance: postBackup,
            preparedAtMilliseconds: 1_500
        )
        return .init(
            plan: plan,
            preBackup: preBackup,
            backup: backup,
            draft: draft
        )
    }

    private func maintenance(
        at timestamp: Int64,
        fingerprint: String,
        authority: String = hash(21),
        desktop: Int = 0,
        summaries: Int = 0,
        history: Int = 0,
        state: Int? = 0,
        threadHistory: Int? = 0,
        processEvidence: [CodexGhostRepairDesktopProcessEvidence]? = [],
        ownerEvidence: [CodexGhostRepairOpenHandleOwnerEvidence]? = []
    ) throws -> CodexGhostRepairBulkMaintenanceEvidence {
        try .init(
            runtimeVersion: "0.149.0",
            executionGate: .init(
                codexFullyExited: true,
                desktopOpenHandleCount: desktop,
                summariesOpenHandleCount: summaries,
                historyOpenHandleCount: history,
                stateOpenHandleCount: state,
                threadHistoryOpenHandleCount: threadHistory,
                capacitySufficient: true,
                desktopProcessEvidence: processEvidence,
                openHandleOwnerEvidence: ownerEvidence
            ),
            sourceFingerprintHash: fingerprint,
            authorityDigest: authority,
            observedAtMilliseconds: timestamp
        )
    }

    private func identifier(_ index: Int) -> String {
        String(format: "10000000-0000-4000-8000-%012d", index + 1)
    }

    private static func hash(_ seed: Int) -> String {
        "sha256:" + String(format: "%064x", seed)
    }

    private func hash(_ seed: Int) -> String { Self.hash(seed) }

    private func makeStore() throws -> StoreContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "bulk-production-journal-\(UUID().uuidString)",
                isDirectory: true
            )
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        return .init(
            store: try SQLiteStateStore(databaseURL: databaseURL),
            databaseURL: databaseURL
        )
    }

    private func tamperJournalPayload(at databaseURL: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_close_v2(database) }
        XCTAssertEqual(sqlite3_exec(
            database,
            "UPDATE codex_ghost_repair_bulk_execution_journal SET payload_hash = 'sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'",
            nil,
            nil,
            nil
        ), SQLITE_OK)
    }
}

private actor BulkDraftPreparer:
    CodexGhostRepairBulkProductionDraftPreparing
{
    let draft: CodexGhostRepairBulkProductionExecutionDraft
    private var calls = 0

    init(draft: CodexGhostRepairBulkProductionExecutionDraft) {
        self.draft = draft
    }

    func prepareDraft(
        confirmationReceiptID _: UUID
    ) -> CodexGhostRepairBulkProductionExecutionDraft {
        calls += 1
        return draft
    }

    func callCount() -> Int { calls }
}

private actor BulkExecutionJournal:
    CodexGhostRepairBulkProductionExecutionJournaling
{
    private var stored: CodexGhostRepairBulkProductionJournalRecord?

    func prepare(
        draft: CodexGhostRepairBulkProductionExecutionDraft
    ) throws -> CodexGhostRepairBulkProductionJournalRecord {
        if let stored {
            guard stored.draft == draft else {
                throw PersistentStateError.invalidRecord(
                    "Draft identity changed."
                )
            }
            return stored
        }
        let record = CodexGhostRepairBulkProductionJournalRecord(
            draft: draft,
            phase: .prepared,
            claim: nil,
            attempt: nil,
            report: nil
        )
        try record.validate()
        stored = record
        return record
    }

    func record(
        operationID: UUID
    ) -> CodexGhostRepairBulkProductionJournalRecord? {
        stored?.draft.operationID == operationID ? stored : nil
    }

    func record(
        confirmationReceiptID: UUID
    ) -> CodexGhostRepairBulkProductionJournalRecord? {
        stored?.draft.confirmationReceiptID == confirmationReceiptID
            ? stored : nil
    }

    func claim(
        operationID: UUID,
        expectedDraftDigest: String,
        claimID: UUID,
        claimedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkProductionClaim {
        guard let current = stored,
              current.phase == .prepared,
              current.draft.operationID == operationID,
              current.draft.draftDigest == expectedDraftDigest else {
            throw CodexGhostRepairError.claimAlreadyExists
        }
        let claim = try CodexGhostRepairBulkProductionClaim(
            claimID: claimID,
            draft: current.draft,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
        stored = .init(
            draft: current.draft,
            phase: .claimed,
            claim: claim,
            attempt: nil,
            report: nil
        )
        return claim
    }

    func recordAttempt(
        operationID: UUID,
        expectedClaimDigest: String,
        attemptedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkProductionAttempt {
        guard let current = stored,
              current.phase == .claimed,
              current.draft.operationID == operationID,
              let claim = current.claim,
              claim.claimDigest == expectedClaimDigest else {
            throw CodexGhostRepairError.recoveryRequired
        }
        let attempt = try CodexGhostRepairBulkProductionAttempt(
            claim: claim,
            attemptedAtMilliseconds: attemptedAtMilliseconds
        )
        stored = .init(
            draft: current.draft,
            phase: .attempted,
            claim: claim,
            attempt: attempt,
            report: nil
        )
        return attempt
    }

    func finalize(
        report: CodexGhostRepairBulkProductionTerminalReport
    ) throws -> CodexGhostRepairBulkProductionJournalRecord {
        guard let current = stored,
              let claim = current.claim else {
            throw CodexGhostRepairError.recoveryRequired
        }
        try report.validate(
            draft: current.draft,
            claim: claim,
            attempt: current.attempt
        )
        let terminal = CodexGhostRepairBulkProductionJournalRecord(
            draft: current.draft,
            phase: .terminal,
            claim: claim,
            attempt: current.attempt,
            report: report
        )
        try terminal.validate()
        stored = terminal
        return terminal
    }

    func mutationAttemptCount() -> Int {
        stored?.mutationAttemptCount ?? 0
    }

    func currentRecord() -> CodexGhostRepairBulkProductionJournalRecord? {
        stored
    }
}

private actor BulkMutator: CodexGhostRepairBulkProductionMutating {
    private let executionOutcome: CodexGhostRepairCategoryABatchOutcome
    private let recoveryOutcome: CodexGhostRepairCategoryABatchOutcome
    private var executions = 0
    private var recoveries = 0

    init(
        executionOutcome: CodexGhostRepairCategoryABatchOutcome,
        recoveryOutcome: CodexGhostRepairCategoryABatchOutcome = .unknown
    ) {
        self.executionOutcome = executionOutcome
        self.recoveryOutcome = recoveryOutcome
    }

    func executeOnce(
        draft _: CodexGhostRepairBulkProductionExecutionDraft,
        claim _: CodexGhostRepairBulkProductionClaim,
        attempt _: CodexGhostRepairBulkProductionAttempt
    ) -> CodexGhostRepairCategoryABatchOutcome {
        executions += 1
        return executionOutcome
    }

    func recoverByReadback(
        draft _: CodexGhostRepairBulkProductionExecutionDraft,
        claim _: CodexGhostRepairBulkProductionClaim,
        attempt _: CodexGhostRepairBulkProductionAttempt
    ) -> CodexGhostRepairCategoryABatchOutcome {
        recoveries += 1
        return recoveryOutcome
    }

    func executionCount() -> Int { executions }
    func recoveryCount() -> Int { recoveries }
}

private actor BulkDraftCollectionTrace {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }
    func events() -> [String] { values }
}

private actor BulkPlanCollector:
    CodexGhostRepairBulkProductionPlanCollecting
{
    let plan: CodexGhostRepairBulkExecutionPlan
    let trace: BulkDraftCollectionTrace

    init(
        plan: CodexGhostRepairBulkExecutionPlan,
        trace: BulkDraftCollectionTrace
    ) {
        self.plan = plan
        self.trace = trace
    }

    func collectPlan(
        confirmationReceiptID _: UUID
    ) async -> CodexGhostRepairBulkExecutionPlan {
        await trace.append("plan")
        return plan
    }
}

private actor BulkMaintenanceCollector:
    CodexGhostRepairBulkMaintenanceCollecting
{
    let before: CodexGhostRepairBulkMaintenanceEvidence
    let after: CodexGhostRepairBulkMaintenanceEvidence
    let trace: BulkDraftCollectionTrace
    let failingPhase: CodexGhostRepairBulkMaintenanceCollectionPhase?

    init(
        before: CodexGhostRepairBulkMaintenanceEvidence,
        after: CodexGhostRepairBulkMaintenanceEvidence,
        trace: BulkDraftCollectionTrace,
        failingPhase: CodexGhostRepairBulkMaintenanceCollectionPhase? = nil
    ) {
        self.before = before
        self.after = after
        self.trace = trace
        self.failingPhase = failingPhase
    }

    func collectMaintenance(
        plan _: CodexGhostRepairBulkExecutionPlan,
        phase: CodexGhostRepairBulkMaintenanceCollectionPhase
    ) async throws -> CodexGhostRepairBulkMaintenanceEvidence {
        await trace.append("maintenance-\(phase.rawValue)")
        if phase == failingPhase {
            throw CodexGhostRepairError.executionGateBlocked
        }
        return phase == .beforeBackup ? before : after
    }
}

private actor BulkBackupCreator:
    CodexGhostRepairBulkOperationBoundBackupCreating
{
    let receipt: CodexGhostRepairBulkExecutionBackupReceipt
    let trace: BulkDraftCollectionTrace

    init(
        receipt: CodexGhostRepairBulkExecutionBackupReceipt,
        trace: BulkDraftCollectionTrace
    ) {
        self.receipt = receipt
        self.trace = trace
    }

    func createOrReadExactBackup(
        plan _: CodexGhostRepairBulkExecutionPlan,
        maintenance _: CodexGhostRepairBulkMaintenanceEvidence
    ) async -> CodexGhostRepairBulkExecutionBackupReceipt {
        await trace.append("backup-create-or-read")
        return receipt
    }
}

#endif
