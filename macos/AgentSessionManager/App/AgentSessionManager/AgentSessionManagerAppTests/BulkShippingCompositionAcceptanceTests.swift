@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

@MainActor
final class BulkShippingCompositionAcceptanceTests: XCTestCase {
    func testExact148CanonicalDeleteHandoffBindsPreparedPlanAndVerifiesTerminalCleanup()
        async throws
    {
        let reportID = UUID(
            uuidString: "94000000-0000-4000-8000-000000000148"
        )!
        let harness = try await BulkShippingAcceptanceHarness.make(
            canonicalDeleteReportID: reportID
        )
        let expectedIDs = harness.fixture.inventory.eligibleThreadIDs

        // The native Delete RPC and readback are deliberately not invoked in
        // this composition test. Their canonical report and durable tombstones
        // are deterministic inputs; the App handoff, prepared-plan binding,
        // mixed transaction, terminal journal, and linkage readback are real.
        guard case let .status(context, .prepared(handoff, binding)) =
                harness.model.nativeDeleteDesktopCleanupState else {
            return XCTFail(
                "Expected the App to bind its exact prepared cleanup operation."
            )
        }
        XCTAssertEqual(context.canonicalDeleteReportID, reportID)
        XCTAssertEqual(context.expectedNativeSessionIDs, expectedIDs)
        XCTAssertEqual(context.nativeDeleteItemCount, 148)
        XCTAssertEqual(handoff.nativeSessionIDs.count, 148)
        XCTAssertEqual(handoff.nativeSessionIDs, expectedIDs)
        XCTAssertEqual(binding.bulkIdentity, harness.identity)
        XCTAssertEqual(binding.items.count, 148)
        XCTAssertEqual(binding.items.map(\.nativeSessionID), expectedIDs)

        let execution = Task { @MainActor in
            await harness.model.executeGhostRepairBulkOneShot()
        }
        let pauseResult = await XCTWaiter.fulfillment(
            of: [harness.terminalReadbackReached],
            timeout: 10
        )
        guard pauseResult == .completed else {
            execution.cancel()
            return XCTFail("Real transaction did not reach terminal readback.")
        }
        await harness.pause.release()
        await execution.value

        await harness.model.readNativeDeleteDesktopCleanupStatus()
        guard case let .status(verifiedContext, .verified(
            verifiedHandoff,
            verifiedBinding,
            completedAtMilliseconds
        )) = harness.model.nativeDeleteDesktopCleanupState else {
            return XCTFail("Expected verified exact terminal cleanup status.")
        }
        XCTAssertEqual(verifiedContext, context)
        XCTAssertEqual(verifiedHandoff, handoff)
        XCTAssertEqual(verifiedBinding, binding)
        XCTAssertGreaterThan(completedAtMilliseconds, 0)
        XCTAssertEqual(
            try BulkShippingCompositionTestFixture.scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: harness.fixture.desktopURL
            ),
            0
        )
    }

    func testExact148ShippingCompositionPreservesIdentityAndColdReadsTerminalReport()
        async throws
    {
        let harness = try await BulkShippingAcceptanceHarness.make()
        let fixture = harness.fixture
        let model = harness.model
        let challenge = harness.challenge
        let confirmedReceipt = harness.confirmedReceipt
        let frozenSelection = harness.frozenSelection
        let terminalReadbackReached = harness.terminalReadbackReached
        let pause = harness.pause

        let execution = Task { @MainActor in
            await model.executeGhostRepairBulkOneShot()
        }
        let pauseResult = await XCTWaiter.fulfillment(
            of: [terminalReadbackReached],
            timeout: 10
        )
        guard pauseResult == .completed else {
            execution.cancel()
            return XCTFail(
                "Real runner never reached terminal readback before timeout."
            )
        }

        // The transaction and fresh readback have completed, but the App
        // still owns the exact in-flight identity until the coordinator returns.
        model.setGhostRepairBulkItemSelected(
            fixture.inventory.eligibleThreadIDs[0],
            isSelected: false
        )
        model.clearGhostRepairBulkSelection()
        XCTAssertFalse(
            model.setGhostRepairBulkReconciliationEnabled(false)
        )
        XCTAssertFalse(model.setGhostRepairBulkInventoryPresented(false))
        XCTAssertEqual(model.ghostRepairBulkSelection, frozenSelection)
        XCTAssertEqual(
            model.ghostRepairBulkConfirmationReceipt?.operationID,
            challenge.operationID
        )
        XCTAssertEqual(
            model.ghostRepairBulkConfirmationReceipt?.receiptID,
            confirmedReceipt.receiptID
        )
        XCTAssertTrue(model.isGhostRepairBulkInventoryPresented)

        await pause.release()
        await execution.value
        guard case let .completed(report) = model.ghostRepairBulkRepairState
        else {
            return XCTFail("Expected the exact itemized terminal Report.")
        }
        XCTAssertEqual(report.operationID, challenge.operationID)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.itemReports.count, 148)
        XCTAssertEqual(
            report.itemReports.count { $0.category == .ordinary },
            74
        )
        XCTAssertEqual(
            report.itemReports.count { $0.category == .automation },
            74
        )
        XCTAssertEqual(
            report.itemReports.map(\.threadID),
            fixture.inventory.eligibleThreadIDs
        )
        XCTAssertEqual(
            try BulkShippingCompositionTestFixture.scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            0
        )

        XCTAssertTrue(model.setGhostRepairBulkInventoryPresented(false))
        XCTAssertFalse(model.isGhostRepairBulkInventoryPresented)
        model.presentGhostRepairBulkInventory()
        XCTAssertTrue(model.isGhostRepairBulkInventoryPresented)
        guard case let .completed(reopenedReport) =
                model.ghostRepairBulkRepairState else {
            return XCTFail("Reopening must retain the terminal Report.")
        }
        XCTAssertEqual(reopenedReport, report)
        XCTAssertEqual(
            model.ghostRepairBulkConfirmationReceipt?.operationID,
            challenge.operationID
        )

        await model.executeGhostRepairBulkOneShot()
        guard case let .completed(reenteredReport) =
                model.ghostRepairBulkRepairState else {
            return XCTFail("Terminal re-entry must retain the same Report.")
        }
        XCTAssertEqual(reenteredReport, report)

        let identity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: confirmedReceipt.savedPreviewRequestID,
            operationID: challenge.operationID
        )
        try assertTerminalJournal(
            identity: identity,
            databaseURL: fixture.managerStateURL
        )

        let coldModel = SessionManagerModel(
            diagnosticLogStore: DiagnosticLogStore.productionInMemory(),
            ghostRepairSnapshotReadbackEnabled: false,
            ghostRepairSnapshotReadbackPreferenceWriter: { _ in },
            ghostRepairBulkRecoveryCoordinator:
                CodexGhostRepairBulkRecoveryLiveCoordinator(
                    databaseURLProvider: { fixture.managerStateURL }
                ),
            ghostRepairBulkReconciliationEnabled: true,
            ghostRepairBulkReconciliationPreferenceWriter: { _ in },
            stateStoreFactory: {
                try SQLiteStateStore(databaseURL: fixture.managerStateURL)
            }
        )
        await coldModel.loadGhostRepairBulkPreviousOperations()
        guard case let .observed(previous) =
                coldModel.ghostRepairBulkPreviousOperationsState else {
            return XCTFail("Expected durable v19 operation discovery after restart.")
        }
        XCTAssertEqual(previous.map(\.identity), [identity])
        coldModel.setGhostRepairBulkRecoveryOperationSelected(identity)
        await coldModel.readSelectedGhostRepairBulkRecoveryOperation()
        guard case let .terminal(summary, coldReport) =
                coldModel.ghostRepairBulkRecoveryReadbackState else {
            return XCTFail("Expected exact durable terminal readback after restart.")
        }
        XCTAssertEqual(summary.identity, identity)
        XCTAssertEqual(summary.mutationAttemptCount, 1)
        XCTAssertEqual(coldReport, report)
        try assertTerminalJournal(
            identity: identity,
            databaseURL: fixture.managerStateURL
        )
        XCTAssertEqual(
            try BulkShippingCompositionTestFixture.scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: fixture.desktopURL
            ),
            0
        )
    }

    func testExact148InitialWitnessDiscoveryFromZeroDeletedRowsReachesTerminalReadback()
        async throws
    {
        let harness = try await BulkShippingAcceptanceHarness.make(
            useInitialWitnessDiscovery: true
        )
        XCTAssertTrue(harness.model.sessionRows.isEmpty)
        guard case let .ready(snapshotReference) =
                harness.model.ghostRepairBulkPreparationState else {
            return XCTFail(
                "Expected initial discovery to reach the verified Snapshot inventory."
            )
        }
        XCTAssertEqual(
            snapshotReference,
            harness.fixture.inventory.snapshotReference
        )
        let expectedWitnessIDs = Array(
            harness.fixture.inventory.eligibleThreadIDs.prefix(10)
        )
        let initialTrace = await harness.initialWitnessAudit.snapshot()
        XCTAssertEqual(initialTrace.discoveryCount, 1)
        XCTAssertEqual(initialTrace.admissionRequests.count, 1)
        XCTAssertEqual(initialTrace.snapshotRequests.count, 1)
        XCTAssertEqual(
            initialTrace.admissionRequests.first?.targetThreadIDs,
            expectedWitnessIDs
        )
        XCTAssertEqual(
            initialTrace.snapshotRequests.first?.targetThreadIDs,
            expectedWitnessIDs
        )
        XCTAssertEqual(
            initialTrace.admissionRequests.first?.initialWitnessEvidence,
            initialTrace.snapshotRequests.first?.initialWitnessEvidence
        )

        let execution = Task { @MainActor in
            await harness.model.executeGhostRepairBulkOneShot()
        }
        let pauseResult = await XCTWaiter.fulfillment(
            of: [harness.terminalReadbackReached],
            timeout: 10
        )
        guard pauseResult == .completed else {
            execution.cancel()
            return XCTFail(
                "Initial discovery composition did not reach terminal readback."
            )
        }
        await harness.pause.release()
        await execution.value

        guard case let .completed(report) =
                harness.model.ghostRepairBulkRepairState else {
            return XCTFail("Expected the exact itemized terminal Report.")
        }
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.itemReports.count, 148)
        XCTAssertEqual(
            report.itemReports.count { $0.category == .ordinary },
            74
        )
        XCTAssertEqual(
            report.itemReports.count { $0.category == .automation },
            74
        )
        XCTAssertEqual(
            report.itemReports.map(\.threadID),
            harness.fixture.inventory.eligibleThreadIDs
        )
        XCTAssertEqual(
            try BulkShippingCompositionTestFixture.scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: harness.fixture.desktopURL
            ),
            0
        )
    }

    func testExact148AfterClaimColdRecoveryRecordsNotAttemptedWithoutDelete()
        async throws
    {
        let harness = try await BulkShippingAcceptanceHarness.make(
            runnerFault: .afterClaim
        )
        let privateStateBeforeExecution = try stablePrivateEvidence(
            harness.fixture
        )
        await harness.model.executeGhostRepairBulkOneShot()
        guard case .recoveryRequired = harness.model.ghostRepairBulkRepairState
        else {
            return XCTFail("After-claim interruption must require recovery.")
        }

        let claimed = try journalRecord(for: harness)
        XCTAssertEqual(claimed.phase, .claimed)
        XCTAssertNotNil(claimed.claim)
        XCTAssertNil(claimed.attempt)
        XCTAssertEqual(claimed.mutationAttemptCount, 0)
        XCTAssertEqual(
            try stablePrivateEvidence(harness.fixture),
            privateStateBeforeExecution
        )
        XCTAssertEqual(
            try BulkShippingCompositionTestFixture.scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: harness.fixture.desktopURL
            ),
            148
        )

        let coldModel = harness.makeColdModel()
        await coldModel.loadGhostRepairBulkPreviousOperations()
        coldModel.setGhostRepairBulkRecoveryOperationSelected(harness.identity)
        await coldModel.readSelectedGhostRepairBulkRecoveryOperation()
        guard case let .recoveryRequired(unresolvedSummary, _) =
                coldModel.ghostRepairBulkRecoveryReadbackState else {
            return XCTFail("Claimed journal must first read as unresolved.")
        }
        XCTAssertEqual(unresolvedSummary.phase, .claimed)
        XCTAssertEqual(unresolvedSummary.mutationAttemptCount, 0)
        await coldModel.recoverSelectedGhostRepairBulkOperationFreshly()
        guard case let .terminal(summary, report, source) =
                coldModel.ghostRepairBulkFreshRecoveryState else {
            return XCTFail("Expected fresh zero-attempt recovery after restart.")
        }
        XCTAssertEqual(source, .freshlyFinalized)
        XCTAssertEqual(summary.identity, harness.identity)
        XCTAssertEqual(summary.mutationAttemptCount, 0)
        XCTAssertEqual(report.outcome, .notAttempted)
        XCTAssertEqual(report.itemReports.count, 148)
        XCTAssertTrue(
            report.itemReports.allSatisfy { $0.outcome == .notAttempted }
        )
        assertExactItemIdentity(report, fixture: harness.fixture)
        XCTAssertEqual(coldModel.ghostRepairBulkRecoveryReadbackState, .idle)

        let terminal = try journalRecord(for: harness)
        XCTAssertEqual(terminal.phase, .terminal)
        XCTAssertEqual(terminal.claim, claimed.claim)
        XCTAssertNil(terminal.attempt)
        XCTAssertEqual(terminal.mutationAttemptCount, 0)
        XCTAssertEqual(
            try BulkShippingCompositionTestFixture.scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: harness.fixture.desktopURL
            ),
            148
        )
        XCTAssertEqual(
            try stablePrivateEvidence(harness.fixture),
            privateStateBeforeExecution
        )

        await coldModel.recoverSelectedGhostRepairBulkOperationFreshly()
        guard case let .terminal(_, repeatedReport, repeatedSource) =
                coldModel.ghostRepairBulkFreshRecoveryState else {
            return XCTFail("Repeated recovery must return the existing Report.")
        }
        XCTAssertEqual(repeatedSource, .existingJournal)
        XCTAssertEqual(repeatedReport, report)
        XCTAssertNotNil(coldModel.ghostRepairBulkExecutionBlockedReason)
        await coldModel.executeGhostRepairBulkOneShot()
        XCTAssertEqual(coldModel.ghostRepairBulkFreshRecoveryState,
                       .terminal(summary: summary, report: report,
                                 source: .existingJournal))
        XCTAssertEqual(try journalRecord(for: harness).mutationAttemptCount, 0)
    }

    func testExact148CommittedMutationColdRecoveryFinalizesOriginalReport()
        async throws
    {
        let harness = try await BulkShippingAcceptanceHarness.make(
            journalTransform: { FinalizeFailingBulkJournal(base: $0) }
        )
        await harness.model.executeGhostRepairBulkOneShot()
        guard case .recoveryRequired = harness.model.ghostRepairBulkRepairState
        else {
            return XCTFail("Finalize interruption must require recovery.")
        }

        let attempted = try journalRecord(for: harness)
        XCTAssertEqual(attempted.phase, .attempted)
        XCTAssertNotNil(attempted.claim)
        XCTAssertNotNil(attempted.attempt)
        XCTAssertEqual(attempted.mutationAttemptCount, 1)
        XCTAssertEqual(
            try BulkShippingCompositionTestFixture.scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: harness.fixture.desktopURL
            ),
            0
        )
        let privateStateBeforeRecovery = try stablePrivateEvidence(
            harness.fixture
        )

        let coldModel = harness.makeColdModel()
        await coldModel.loadGhostRepairBulkPreviousOperations()
        coldModel.setGhostRepairBulkRecoveryOperationSelected(harness.identity)
        await coldModel.readSelectedGhostRepairBulkRecoveryOperation()
        guard case let .recoveryRequired(unresolvedSummary, _) =
                coldModel.ghostRepairBulkRecoveryReadbackState else {
            return XCTFail("Attempted journal must first read as unresolved.")
        }
        XCTAssertEqual(unresolvedSummary.phase, .attempted)
        XCTAssertEqual(unresolvedSummary.mutationAttemptCount, 1)
        await coldModel.recoverSelectedGhostRepairBulkOperationFreshly()
        guard case let .terminal(summary, report, source) =
                coldModel.ghostRepairBulkFreshRecoveryState else {
            return XCTFail("Expected fresh committed-state recovery after restart.")
        }
        XCTAssertEqual(source, .freshlyFinalized)
        XCTAssertEqual(summary.identity, harness.identity)
        XCTAssertEqual(summary.mutationAttemptCount, 1)
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.itemReports.count, 148)
        XCTAssertEqual(
            report.itemReports.count { $0.category == .ordinary },
            74
        )
        XCTAssertEqual(
            report.itemReports.count { $0.category == .automation },
            74
        )
        assertExactItemIdentity(report, fixture: harness.fixture)
        XCTAssertEqual(coldModel.ghostRepairBulkRecoveryReadbackState, .idle)

        let terminal = try journalRecord(for: harness)
        XCTAssertEqual(terminal.phase, .terminal)
        XCTAssertEqual(terminal.claim, attempted.claim)
        XCTAssertEqual(terminal.attempt, attempted.attempt)
        XCTAssertEqual(terminal.mutationAttemptCount, 1)
        XCTAssertEqual(
            try stablePrivateEvidence(harness.fixture),
            privateStateBeforeRecovery
        )

        await coldModel.recoverSelectedGhostRepairBulkOperationFreshly()
        guard case let .terminal(_, repeatedReport, repeatedSource) =
                coldModel.ghostRepairBulkFreshRecoveryState else {
            return XCTFail("Repeated recovery must return the existing Report.")
        }
        XCTAssertEqual(repeatedSource, .existingJournal)
        XCTAssertEqual(repeatedReport, report)
        XCTAssertEqual(try journalRecord(for: harness).mutationAttemptCount, 1)
        XCTAssertEqual(
            try stablePrivateEvidence(harness.fixture),
            privateStateBeforeRecovery
        )
    }

    func testExact148PreparedPlanClosureIsDurableAndNeverExecutes()
        async throws
    {
        let harness = try await BulkShippingAcceptanceHarness.make()
        let privateStateBeforeClosure = try stablePrivateEvidence(
            harness.fixture
        )

        await harness.model.reviewCurrentGhostRepairBulkPreparedClosure()
        guard case let .reviewReady(preview) =
                harness.model.ghostRepairBulkPreparedClosureState else {
            return XCTFail("Expected exact prepared-plan closure review.")
        }
        XCTAssertEqual(preview.identity, harness.identity)
        assertExactClosureItemIdentity(
            preview.selectedItems,
            fixture: harness.fixture
        )

        await harness.model.closeGhostRepairBulkPreparedOperation()
        guard case let .closedBeforeAttempt(summary, closure, newlyClosed) =
                harness.model.ghostRepairBulkPreparedClosureState else {
            return XCTFail("Expected distinct closed-before-attempt result.")
        }
        XCTAssertTrue(newlyClosed)
        XCTAssertEqual(summary.identity, harness.identity)
        XCTAssertEqual(summary.phase, .closedBeforeAttempt)
        XCTAssertEqual(summary.mutationAttemptCount, 0)
        XCTAssertFalse(summary.hasTerminalReport)
        XCTAssertEqual(closure.identity, harness.identity)
        assertExactClosureItemIdentity(
            closure.selectedItems,
            fixture: harness.fixture
        )
        guard case let .closedBeforeAttempt(repairClosure) =
                harness.model.ghostRepairBulkRepairState else {
            return XCTFail("Closure must not be presented as a Repair Report.")
        }
        XCTAssertEqual(repairClosure, closure)

        let closedJournal = try journalRecord(for: harness)
        XCTAssertEqual(closedJournal.phase, .closedBeforeAttempt)
        XCTAssertNil(closedJournal.claim)
        XCTAssertNil(closedJournal.attempt)
        XCTAssertNil(closedJournal.report)
        XCTAssertEqual(closedJournal.closure, closure)
        XCTAssertEqual(closedJournal.mutationAttemptCount, 0)
        XCTAssertEqual(
            try BulkShippingCompositionTestFixture.scalar(
                "SELECT count(*) FROM local_thread_catalog",
                at: harness.fixture.desktopURL
            ),
            148
        )
        XCTAssertEqual(
            try stablePrivateEvidence(harness.fixture),
            privateStateBeforeClosure
        )

        await harness.model.executeGhostRepairBulkOneShot()
        XCTAssertEqual(
            harness.model.ghostRepairBulkRepairState,
            .closedBeforeAttempt(closure)
        )
        XCTAssertEqual(try journalRecord(for: harness), closedJournal)

        let coldModel = harness.makeColdModel()
        await coldModel.loadGhostRepairBulkPreviousOperations()
        coldModel.setGhostRepairBulkRecoveryOperationSelected(harness.identity)
        await coldModel.readSelectedGhostRepairBulkRecoveryOperation()
        guard case let .closedBeforeAttempt(coldSummary, coldClosure) =
                coldModel.ghostRepairBulkRecoveryReadbackState else {
            return XCTFail("Expected durable cold closure readback.")
        }
        XCTAssertEqual(coldSummary, summary)
        XCTAssertEqual(coldClosure, closure)
        assertExactClosureItemIdentity(
            coldClosure.selectedItems,
            fixture: harness.fixture
        )

        await coldModel.readSelectedGhostRepairBulkRecoveryOperation()
        guard case let .closedBeforeAttempt(_, repeatedClosure) =
                coldModel.ghostRepairBulkRecoveryReadbackState else {
            return XCTFail("Repeated closure readback must remain closed.")
        }
        XCTAssertEqual(repeatedClosure, closure)
        XCTAssertEqual(try journalRecord(for: harness), closedJournal)
        XCTAssertEqual(
            try stablePrivateEvidence(harness.fixture),
            privateStateBeforeClosure
        )
    }

    private func journalRecord(
        for harness: BulkShippingAcceptanceHarness
    ) throws -> CodexGhostRepairBulkLiveJournalRecord {
        let store = try SQLiteStateStore(
            databaseURL: harness.fixture.managerStateURL
        )
        defer { store.close() }
        return try XCTUnwrap(
            store.codexGhostRepairBulkLiveExecutionJournal(
                requestID: harness.identity.requestID
            )
        )
    }

    private func stablePrivateEvidence(
        _ fixture: BulkShippingCompositionTestFixture.Value
    ) throws -> [CodexGhostRepairSnapshotCanonicalFileEvidence] {
        try fixture.source.fingerprint().files.filter {
            !$0.fileName.hasSuffix("-shm")
        }
    }

    private func assertExactItemIdentity(
        _ report: CodexGhostRepairBulkRepairReport,
        fixture: BulkShippingCompositionTestFixture.Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = fixture.inventory.items.compactMap { item in
            item.selectable ? item.category.map { (item.threadID, $0) } : nil
        }
        let actual = report.itemReports.map { ($0.threadID, $0.category) }
        XCTAssertEqual(
            actual.map { "\($0.0)|\($0.1)" },
            expected.map { "\($0.0)|\($0.1)" },
            file: file,
            line: line
        )
    }

    private func assertExactClosureItemIdentity(
        _ items: [CodexGhostRepairBulkPreparedClosureItem],
        fixture: BulkShippingCompositionTestFixture.Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = fixture.inventory.items.compactMap { item in
            item.selectable ? item.category.map { (item.threadID, $0) } : nil
        }
        let actual = items.map { ($0.threadID, $0.category) }
        XCTAssertEqual(
            actual.map { "\($0.0)|\($0.1)" },
            expected.map { "\($0.0)|\($0.1)" },
            file: file,
            line: line
        )
    }

    private func assertTerminalJournal(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        databaseURL: URL
    ) throws {
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        let record = try XCTUnwrap(
            store.codexGhostRepairBulkLiveExecutionJournal(
                requestID: identity.requestID
            )
        )
        XCTAssertEqual(record.confirmationReceipt.operationID, identity.operationID)
        XCTAssertEqual(record.phase, .terminal)
        XCTAssertEqual(record.mutationAttemptCount, 1)
        XCTAssertEqual(record.report?.items.count, 148)
    }

}

@MainActor
private struct BulkShippingAcceptanceHarness {
    typealias JournalTransform = @Sendable (
        any CodexGhostRepairBulkLiveExecutionJournaling
    ) -> any CodexGhostRepairBulkLiveExecutionJournaling

    let fixture: BulkShippingCompositionTestFixture.Value
    let model: SessionManagerModel
    let challenge: CodexGhostRepairBulkConfirmationChallenge
    let confirmedReceipt: CodexGhostRepairBulkConfirmationReceipt
    let frozenSelection: Set<String>
    let terminalReadbackReached: XCTestExpectation
    let pause: ReturnPause
    let freshRecoveryCoordinator:
        any CodexGhostRepairBulkFreshRecoveryCoordinating
    let preparedClosureCoordinator:
        any CodexGhostRepairBulkPreparedClosureCoordinating
    let canonicalDeleteReport: NativeDeleteReport?
    let initialWitnessAudit: InitialWitnessCompositionAudit

    var identity: CodexGhostRepairBulkRecoveryOperationIdentity {
        .init(
            requestID: confirmedReceipt.savedPreviewRequestID,
            operationID: challenge.operationID
        )
    }

    func makeColdModel() -> SessionManagerModel {
        SessionManagerModel(
            diagnosticLogStore: DiagnosticLogStore.productionInMemory(),
            ghostRepairSnapshotReadbackEnabled: false,
            ghostRepairSnapshotReadbackPreferenceWriter: { _ in },
            ghostRepairBulkRecoveryCoordinator:
                CodexGhostRepairBulkRecoveryLiveCoordinator(
                    databaseURLProvider: { fixture.managerStateURL }
                ),
            ghostRepairBulkFreshRecoveryCoordinator:
                freshRecoveryCoordinator,
            ghostRepairBulkPreparedClosureCoordinator:
                preparedClosureCoordinator,
            ghostRepairBulkReconciliationEnabled: true,
            ghostRepairBulkReconciliationPreferenceWriter: { _ in },
            stateStoreFactory: {
                try SQLiteStateStore(databaseURL: fixture.managerStateURL)
            }
        )
    }

    static func make(
        runnerFault: CodexGhostRepairBulkLiveOneShotFault = .none,
        journalTransform: @escaping JournalTransform = { $0 },
        canonicalDeleteReportID: UUID? = nil,
        useInitialWitnessDiscovery: Bool = false
    ) async throws -> Self {
        let fixture = try BulkShippingCompositionTestFixture.make(
            itemCount: 148,
            desktopSchema: 34,
            profile: .v1534DesktopV34,
            runtimeVersion: "0.153.4"
        )
        let nowMilliseconds: @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
        let canonicalDeleteReport = try canonicalDeleteReportID.map {
            try makeCanonicalDeleteReport(
                reportID: $0,
                nativeSessionIDs: fixture.inventory.eligibleThreadIDs
            )
        }
        let initialWitnessAudit = InitialWitnessCompositionAudit()
        if let canonicalDeleteReport {
            let seedingStore = try SQLiteStateStore(
                databaseURL: fixture.managerStateURL
            )
            defer { seedingStore.close() }
            try seedCanonicalDeleteTombstones(
                report: canonicalDeleteReport,
                store: seedingStore
            )
        }
        let managerRoot = try makePreparedManagerRoot(in: fixture.parent)
        let frozenAuthority = try XCTUnwrap(
            fixture.storedPreview.frozenSource
        ).authority
        let repairResolution = try fixture.bundle.resolveForPreflight()
        let backupEnvironment = try CodexGhostRepairBulkLiveBackupEnvironment(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedSourceAllowedParentURL: fixture.parent,
            testOwnedManagerRootURL: managerRoot,
            testOwnedManagerAllowedParentURL: fixture.parent,
            profile: .v1534DesktopV34,
            nowMilliseconds: nowMilliseconds
        )
        let planPreparer = CodexGhostRepairBulkPackagedPlanPreparer(
            storeProvider: {
                try SQLiteStateStore(databaseURL: fixture.managerStateURL)
            },
            resolutionProvider: { storedPreview in
                let resolution = try CodexGhostRepairBulkProductionBundle(
                    coldReadback: storedPreview,
                    testOwnedCodexHomeURL: fixture.codexHome,
                    testOwnedAllowedParentURL: fixture.parent
                ).resolveForTestOwnedAdoption()
                return (resolution, .v1534DesktopV34)
            },
            maintenanceObserverProvider: { profile in
                CodexGhostRepairBulkProductionMaintenanceObserver(
                    profile: profile,
                    gateSource: AlwaysClearBulkRepairGate(),
                    fingerprintReader: { try fixture.source.fingerprint() },
                    authorityReader: { _ in frozenAuthority },
                    sourceAdmission: { _ in true },
                    nowMilliseconds: nowMilliseconds
                )
            },
            backupTransportProvider: { resolution, window in
                try CodexGhostRepairBulkLiveBackupTransport(
                    resolution: resolution,
                    maintenanceWindow: window,
                    environment: backupEnvironment
                )
            },
            targetRevalidatorProvider: { profile in
                XCTAssertEqual(profile, .v1534DesktopV34)
                return try CodexGhostRepairBulkLiveTargetRevalidator(
                    repairResolution: repairResolution,
                    gateSource: AlwaysClearBulkRepairGate(),
                    fingerprintReader: { try fixture.source.fingerprint() },
                    nowMilliseconds: nowMilliseconds
                )
            }
        )
        let baseJournal = CodexGhostRepairBulkLivePackagedExecutionJournal {
            try SQLiteStateStore(databaseURL: fixture.managerStateURL)
        }
        let journal = journalTransform(baseJournal)
        let realMutator = CodexGhostRepairBulkLiveMixedMutator(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedAllowedParentURL: fixture.parent,
            profile: .v1534DesktopV34,
            gateSource: AlwaysClearBulkRepairGate(),
            backupReader: TestOwnedBackupReader(environment: backupEnvironment)
        )
        let operationExclusion = CodexGhostRepairBulkOperationExclusion(
            databaseURL: fixture.managerStateURL
        )
        let realRunner = CodexGhostRepairBulkLiveOneShotCoordinator(
            journal: journal,
            mutator: realMutator,
            nowMilliseconds: nowMilliseconds,
            makeUUID: {
                UUID(uuidString: "93000000-0000-4000-8000-000000000001")!
            },
            fault: runnerFault,
            operationExclusion: operationExclusion
        )
        let freshRecoveryCoordinator =
            CodexGhostRepairBulkFreshRecoveryLiveCoordinator(
                databaseURLProvider: { fixture.managerStateURL },
                operationExclusion: operationExclusion,
                readbackProvider: { profile in
                    XCTAssertEqual(profile, .v1534DesktopV34)
                    return realMutator
                },
                nowMilliseconds: nowMilliseconds,
                makeUUID: {
                    UUID(
                        uuidString:
                            "93000000-0000-4000-8000-000000000002"
                    )!
                }
            )
        let preparedClosureCoordinator =
            CodexGhostRepairBulkPreparedClosureLiveCoordinator(
                databaseURLProvider: { fixture.managerStateURL },
                operationExclusion: operationExclusion,
                nowMilliseconds: nowMilliseconds,
                makeUUID: {
                    UUID(
                        uuidString:
                            "93000000-0000-4000-8000-000000000003"
                    )!
                }
            )
        let terminalReadbackReached = XCTestExpectation(
            description: "real terminal readback completed before App return"
        )
        let pause = ReturnPause(pausedExpectation: terminalReadbackReached)
        let pausingRunner = PausingAfterTerminalReadbackRunner(
            base: realRunner,
            pause: pause
        )
        let repairCoordinator = CodexGhostRepairBulkPackagedRepairCoordinator(
            planPreparer: planPreparer,
            runnerFactory: { profileIdentifier in
                guard profileIdentifier
                        == CodexGhostRepairSnapshotSourceProfile
                            .v1534DesktopV34.identifier else {
                    throw CodexGhostRepairError.authorityDrift
                }
                return pausingRunner
            }
        )
        let desktopCleanupCoordinator:
            (any CodexDesktopCleanupLinkageCoordinating)?
        if canonicalDeleteReport != nil {
            desktopCleanupCoordinator = CodexDesktopCleanupLinkageCoordinator(
                testStore: try SQLiteStateStore(
                    databaseURL: fixture.managerStateURL
                ),
                nowMilliseconds: nowMilliseconds
            )
        } else {
            desktopCleanupCoordinator = nil
        }
        let model = SessionManagerModel(
            diagnosticLogStore: DiagnosticLogStore.productionInMemory(),
            ghostRepairReadOnlySafetySource:
                DeterministicSnapshotWitnessSafetySource(
                    runtimeVersion: "0.153.4"
                ),
            ghostRepairSnapshotActionCoordinator:
                useInitialWitnessDiscovery
                    ? SyntheticPublishedSnapshotActionCoordinator(
                        snapshotReference:
                            fixture.inventory.snapshotReference,
                        audit: initialWitnessAudit
                    )
                    : nil,
            ghostRepairSnapshotAdmissionInspector:
                useInitialWitnessDiscovery
                    ? DeterministicInitialWitnessAdmissionInspector(
                        audit: initialWitnessAudit
                    )
                    : nil,
            ghostRepairInitialWitnessDiscovery:
                useInitialWitnessDiscovery
                    ? DeterministicInitialWitnessDiscovery(
                        threadIDs: Array(
                            fixture.inventory.eligibleThreadIDs.prefix(10)
                        ),
                        audit: initialWitnessAudit
                    )
                    : nil,
            ghostRepairSnapshotReadbackEnabled: false,
            ghostRepairSnapshotReadbackPreferenceWriter: { _ in },
            ghostRepairBulkInventoryCoordinator: ExactInventoryCoordinator(
                inventory: fixture.inventory,
                resumableSnapshotReference:
                    useInitialWitnessDiscovery
                        ? nil
                        : fixture.inventory.snapshotReference
            ),
            ghostRepairBulkPreviewPersister: ManagerPreviewPersister(
                databaseURL: fixture.managerStateURL
            ),
            ghostRepairBulkPreviewReadbackCoordinator:
                CodexGhostRepairBulkPreviewLiveReadbackCoordinator(
                    databaseURLProvider: { fixture.managerStateURL }
                ),
            ghostRepairBulkConfirmationChallengeCoordinator:
                CodexGhostRepairBulkConfirmationLiveCoordinator(
                    databaseURLProvider: { fixture.managerStateURL },
                    nowMilliseconds: nowMilliseconds
                ),
            ghostRepairBulkConfirmationReceiptCoordinator:
                CodexGhostRepairBulkConfirmationReceiptLiveCoordinator(
                    databaseURLProvider: { fixture.managerStateURL },
                    nowMilliseconds: nowMilliseconds
                ),
            ghostRepairBulkRepairCoordinator: repairCoordinator,
            ghostRepairBulkRecoveryCoordinator:
                CodexGhostRepairBulkRecoveryLiveCoordinator(
                    databaseURLProvider: { fixture.managerStateURL }
                ),
            ghostRepairBulkFreshRecoveryCoordinator:
                freshRecoveryCoordinator,
            ghostRepairBulkPreparedClosureCoordinator:
                preparedClosureCoordinator,
            nativeDeleteDesktopCleanupCoordinator:
                desktopCleanupCoordinator,
            ghostRepairBulkReconciliationEnabled: true,
            ghostRepairBulkReconciliationPreferenceWriter: { _ in },
            stateStoreFactory: {
                try SQLiteStateStore(databaseURL: fixture.managerStateURL)
            }
        )

        // Deterministic official-evidence input; the shipping bridge, v19
        // journal, backup I/O, mixed transaction, and readback remain real.
        if let canonicalDeleteReport {
            model.sessionRows = canonicalDeleteReport.items.map { item in
                SessionPresentation(deleted: DeletedSessionRecord(
                    provider: .codex,
                    nativeSessionID: item.nativeSessionID,
                    managerKey: item.managerKey,
                    titleAtDeletion: item.title,
                    workingDirectoryAtDeletion: item.workingDirectory,
                    providerInventoryHashAtDeletion:
                        "native-delete-inventory",
                    deletedAt: Date(timeIntervalSince1970: 1_000),
                    deleteReportID: canonicalDeleteReport.id
                ))
            }
            model.latestNativeDeleteReport = canonicalDeleteReport
            model.queueNativeDeleteDesktopCleanup(
                report: canonicalDeleteReport
            )
            model.presentQueuedNativeDeleteDesktopCleanup()
            await model.prepareGhostRepairBulkInventory()
        } else if useInitialWitnessDiscovery {
            XCTAssertTrue(model.sessionRows.isEmpty)
            await model.prepareGhostRepairBulkInventory()
            model.presentGhostRepairBulkInventory()
            model.selectAllEligibleGhostRepairBulkItems()
        } else {
            model.ghostRepairBulkSnapshotReferenceDraft =
                fixture.inventory.snapshotReference
            await model.observeGhostRepairBulkInventory()
            model.presentGhostRepairBulkInventory()
            model.selectAllEligibleGhostRepairBulkItems()
        }
        let frozenSelection = model.ghostRepairBulkSelection
        XCTAssertEqual(frozenSelection.count, 148)
        await model.buildGhostRepairBulkPreview()

        guard case let .ready(challenge) =
                model.ghostRepairBulkConfirmationChallengeState else {
            XCTFail(
                "Expected one exact 148-item confirmation challenge; "
                    + "inventory=\(model.ghostRepairBulkInventoryState), "
                    + "preview=\(model.ghostRepairBulkPreviewState), "
                    + "readback=\(model.ghostRepairBulkPreviewReadbackState), "
                    + "challenge=\(model.ghostRepairBulkConfirmationChallengeState)"
            )
            throw HarnessError.unexpectedState
        }
        XCTAssertEqual(challenge.ordinaryCount, 74)
        XCTAssertEqual(challenge.automationCount, 74)
        model.ghostRepairBulkConfirmationPhraseDraft = challenge.confirmationPhrase
        await model.confirmGhostRepairBulkBatch()
        let confirmedReceipt = try XCTUnwrap(
            model.ghostRepairBulkConfirmationReceipt
        )
        XCTAssertEqual(confirmedReceipt.operationID, challenge.operationID)
        await model.prepareGhostRepairBulkFinalReview()
        guard case let .reviewReady(review) = model.ghostRepairBulkRepairState
        else {
            XCTFail(
                "Expected the real packaged 148-item Final Review; state="
                    + "\(model.ghostRepairBulkRepairState)"
            )
            throw HarnessError.unexpectedState
        }
        XCTAssertEqual(review.operationID, challenge.operationID)
        XCTAssertEqual(review.selectedCount, 148)

        return Self(
            fixture: fixture,
            model: model,
            challenge: challenge,
            confirmedReceipt: confirmedReceipt,
            frozenSelection: frozenSelection,
            terminalReadbackReached: terminalReadbackReached,
            pause: pause,
            freshRecoveryCoordinator: freshRecoveryCoordinator,
            preparedClosureCoordinator: preparedClosureCoordinator,
            canonicalDeleteReport: canonicalDeleteReport,
            initialWitnessAudit: initialWitnessAudit
        )
    }

    private static func makeCanonicalDeleteReport(
        reportID: UUID,
        nativeSessionIDs: [String]
    ) throws -> NativeDeleteReport {
        NativeDeleteReport(
            id: reportID,
            previewID: UUID(
                uuidString: "94000000-0000-4000-8000-000000000149"
            )!,
            outcome: .success,
            completedAt: Date(timeIntervalSince1970: 1_000),
            items: nativeSessionIDs.map { nativeSessionID in
                NativeDeleteReportItem(
                    managerKey: "codex:\(nativeSessionID)",
                    nativeSessionID: nativeSessionID,
                    title: nativeSessionID,
                    projectName: nil,
                    workingDirectory: "/projects/default",
                    outcome: .success,
                    observedNativeState: .absent,
                    errorCode: nil,
                    message: nil
                )
            },
            recoveredAfterInterruption: false
        )
    }

    private static func seedCanonicalDeleteTombstones(
        report: NativeDeleteReport,
        store: SQLiteStateStore
    ) throws {
        try store.upsertProviderCheckpoint(
            ProviderCheckpointRecord(
                provider: .codex,
                runtimeVersion: "0.153.4",
                inventoryHash: "native-delete-inventory",
                refreshedAt: Date(timeIntervalSince1970: 1_000),
                inventoryComplete: true,
                protectionComplete: true
            )
        )
        try store.withLockedDatabase { database in
            for item in report.items {
                try store.execute(
                    """
                    INSERT INTO deleted_sessions (
                        provider, native_session_id, manager_key,
                        title_at_deletion, project_id_at_deletion,
                        working_directory_at_deletion, known_size_bytes,
                        provider_inventory_hash_at_deletion, deleted_at,
                        delete_report_id
                    ) VALUES ('codex', ?, ?, ?, NULL, ?, NULL, ?, ?, ?)
                    """,
                    values: [
                        .text(item.nativeSessionID),
                        .text(item.managerKey),
                        .text(item.title),
                        .text(item.workingDirectory ?? "/projects/default"),
                        .text("native-delete-inventory"),
                        .text("1970-01-01T00:16:40.000Z"),
                        .text(report.id.uuidString.lowercased()),
                    ],
                    database: database
                )
            }
        }
    }

    private static func makePreparedManagerRoot(in parent: URL) throws -> URL {
        let managerRoot = parent.appendingPathComponent(
            "shipping-manager",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managerRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = managerRoot.appendingPathComponent(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector.markerFileName
        )
        try Data(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector
                .markerContents.utf8
        ).write(to: marker)
        XCTAssertEqual(chmod(marker.path, 0o600), 0)
        try FileManager.default.createDirectory(
            at: managerRoot.appendingPathComponent(
                CodexGhostRepairBulkFixedBackupDestinationTestInspector
                    .ghostRepairDirectoryName,
                isDirectory: true
            ),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return managerRoot
    }

    private enum HarnessError: Error {
        case unexpectedState
    }
}

private struct DeterministicInitialWitnessDiscovery:
    CodexGhostRepairInitialWitnessDiscovering,
    Sendable
{
    let threadIDs: [String]
    let audit: InitialWitnessCompositionAudit
    let capabilities =
        CodexGhostRepairInitialWitnessDiscoveryCapabilities.packagedReadOnly

    func discover() async -> CodexGhostRepairInitialWitnessDiscoveryOutcome {
        await audit.recordDiscovery()
        return .discovered(CodexGhostRepairInitialWitnessEvidence(
            threadIDs: threadIDs,
            runtimeVersion: "0.153.4",
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceProfile
                    .v1534DesktopV34.identifier,
            sourceFingerprintHash: "sha256:" + String(repeating: "a", count: 64)
        ))
    }
}

private struct DeterministicInitialWitnessAdmissionInspector:
    CodexGhostRepairSnapshotAdmissionInspecting,
    Sendable
{
    let audit: InitialWitnessCompositionAudit
    let capabilities =
        CodexGhostRepairSnapshotAdmissionInspectorCapabilities
            .packagedFixedReadOnly

    func inspect(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        await audit.recordAdmission(request)
        return .allowed(CodexGhostRepairSnapshotAdmissionEvidence(
            publishedSnapshotCount: 0,
            maximumSnapshotCount: 3,
            publishedBytes: 0,
            maximumTotalBytes: 4_294_967_296,
            prospectiveSnapshotBytes: 1,
            oldestPublishedAgeMilliseconds: nil,
            maximumPublishedAgeMilliseconds: 2_592_000_000,
            destinationRequiredBytes: 1,
            destinationAvailableBytes: 2,
            blockers: []
        ))
    }
}

/// App composition substitute for the already-prepared test-owned Snapshot.
/// Core separately verifies canonical copying; this fake proves that the App
/// cannot skip admission or alter the exact ten discovery witnesses before it
/// enters the real 148-item inventory, transaction, and terminal readback.
private struct SyntheticPublishedSnapshotActionCoordinator:
    CodexGhostRepairSnapshotActionCoordinator,
    Sendable
{
    let snapshotReference: String
    let audit: InitialWitnessCompositionAudit
    let capabilities =
        CodexGhostRepairSnapshotActionCapabilities.testOwnedRawDatabaseSnapshot

    func inspectAdmission(
        request _: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        .unavailable(
            message: "The separate deterministic admission inspector owns this check."
        )
    }

    func perform(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotActionOutcome {
        await audit.recordSnapshot(request)
        return .succeeded(reference: snapshotReference)
    }
}

private actor InitialWitnessCompositionAudit {
    struct Snapshot: Sendable {
        let discoveryCount: Int
        let admissionRequests: [CodexGhostRepairSnapshotActionRequest]
        let snapshotRequests: [CodexGhostRepairSnapshotActionRequest]
    }

    private var discoveryCount = 0
    private var admissionRequests: [CodexGhostRepairSnapshotActionRequest] = []
    private var snapshotRequests: [CodexGhostRepairSnapshotActionRequest] = []

    func recordDiscovery() {
        discoveryCount += 1
    }

    func recordAdmission(_ request: CodexGhostRepairSnapshotActionRequest) {
        admissionRequests.append(request)
    }

    func recordSnapshot(_ request: CodexGhostRepairSnapshotActionRequest) {
        snapshotRequests.append(request)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            discoveryCount: discoveryCount,
            admissionRequests: admissionRequests,
            snapshotRequests: snapshotRequests
        )
    }
}

private struct ExactInventoryCoordinator:
    CodexGhostRepairBulkInventoryCoordinating,
    Sendable
{
    let capabilities = CodexGhostRepairBulkInventoryCapabilities
        .packagedReadOnlyCandidate
    let inventory: CodexGhostRepairBulkInventory
    let resumableSnapshotReference: String?

    func resumablePublishedSnapshotReference(
        targetThreadIDs: [String]
    ) async throws -> String? {
        guard !targetThreadIDs.isEmpty,
              Set(targetThreadIDs).isSubset(
                of: Set(inventory.eligibleThreadIDs)
              ) else {
            return nil
        }
        return resumableSnapshotReference
    }

    func observe(
        request: CodexGhostRepairBulkInventoryRequest
    ) async -> CodexGhostRepairBulkInventoryOutcome {
        guard request.snapshotReference == inventory.snapshotReference else {
            return .unavailable(
                requestID: request.requestID,
                failure: .init(stage: .snapshotRead)
            )
        }
        return .inventory(requestID: request.requestID, inventory: inventory)
    }
}

/// Deterministic admission input for the bounded Snapshot witnesses only. It
/// has no lifecycle or database transport; the acceptance target below remains
/// the real App handoff, journal, binding, transaction, and readback chain.
private struct DeterministicSnapshotWitnessSafetySource:
    CodexGhostRepairReadOnlySafetySource,
    Sendable
{
    let runtimeVersion: String

    func ghostRepairSafetySnapshot(
        targetThreadIDs: [String]
    ) async throws -> CodexGhostRepairSafetySnapshot {
        let contract = ExactSessionAbsenceContract(
            provider: .codex,
            runtimeVersion: runtimeVersion,
            rpcCode: -32600,
            identifier: "shipping-composition-fixture",
            officialSourceURL: URL(
                string: "https://developers.openai.com/codex/app-server"
            )!
        )
        return CodexGhostRepairSafetySnapshot(
            inventory: ProviderInventorySnapshot(
                provider: .codex,
                runtimeVersion: runtimeVersion,
                inventoryHash: "native-delete-inventory",
                observedAt: Date(timeIntervalSince1970: 1_000),
                inventoryComplete: true,
                protectionComplete: true,
                sessions: [],
                archiveScopeNodes: [],
                archiveScopeComplete: true
            ),
            exactReadbacks: targetThreadIDs.map { nativeSessionID in
                ExactSessionReadbackEvidence(
                    provider: .codex,
                    nativeSessionID: nativeSessionID,
                    status: .absent,
                    observedAt: Date(timeIntervalSince1970: 1_000),
                    runtimeVersion: runtimeVersion,
                    evidenceKind: .documentedNotFound,
                    rpcCode: -32600,
                    absenceContract: contract,
                    message: "deterministic fixture absence"
                )
            },
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            executionGate: .completeFiveDatabaseClearForBulkTests
        )
    }
}

private actor ManagerPreviewPersister: CodexGhostRepairBulkPreviewPersisting {
    let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func persist(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        inventory: CodexGhostRepairBulkInventory
    ) throws -> CodexGhostRepairBulkPreviewPersistenceReceipt {
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        let stored = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            inventory: inventory
        )
        return .init(
            requestID: stored.requestID,
            previewID: stored.preview.previewID,
            payloadHash: stored.payloadHash,
            frozenSourceDigest: stored.frozenSource?.sourceDigest,
            durableReadbackMatched: true
        )
    }
}

private actor FinalizeFailingBulkJournal:
    CodexGhostRepairBulkLiveExecutionJournaling
{
    let base: any CodexGhostRepairBulkLiveExecutionJournaling

    init(base: any CodexGhostRepairBulkLiveExecutionJournaling) {
        self.base = base
    }

    func prepare(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        confirmationReceipt: CodexGhostRepairBulkConfirmationReceipt
    ) async throws -> CodexGhostRepairBulkLiveJournalRecord {
        try await base.prepare(
            plan: plan,
            confirmationReceipt: confirmationReceipt
        )
    }

    func record(
        requestID: UUID
    ) async throws -> CodexGhostRepairBulkLiveJournalRecord? {
        try await base.record(requestID: requestID)
    }

    func claim(
        requestID: UUID,
        expectedPlanDigest: String,
        claimID: UUID,
        claimedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairBulkLiveMixedClaim {
        try await base.claim(
            requestID: requestID,
            expectedPlanDigest: expectedPlanDigest,
            claimID: claimID,
            claimedAtMilliseconds: claimedAtMilliseconds
        )
    }

    func recordAttempt(
        requestID: UUID,
        expectedClaimDigest: String,
        attemptedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairBulkLiveMixedAttempt {
        try await base.recordAttempt(
            requestID: requestID,
            expectedClaimDigest: expectedClaimDigest,
            attemptedAtMilliseconds: attemptedAtMilliseconds
        )
    }

    func finalize(
        report _: CodexGhostRepairBulkLiveTerminalReport
    ) async throws -> CodexGhostRepairBulkLiveJournalRecord {
        throw CodexGhostRepairError.recoveryRequired
    }
}

private struct TestOwnedBackupReader:
    CodexGhostRepairBulkLiveMixedBackupReading,
    Sendable
{
    let environment: CodexGhostRepairBulkLiveBackupEnvironment

    func readExactBackup(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan
    ) async throws -> CodexGhostRepairBulkLiveBackupReceipt {
        try await environment.readExactBackup(destination: plan.destination)
    }
}

private actor PausingAfterTerminalReadbackRunner:
    CodexGhostRepairBulkOneShotRunning
{
    let base: CodexGhostRepairBulkLiveOneShotCoordinator
    let pause: ReturnPause

    init(
        base: CodexGhostRepairBulkLiveOneShotCoordinator,
        pause: ReturnPause
    ) {
        self.base = base
        self.pause = pause
    }

    func prepare(
        plan: CodexGhostRepairBulkBackupBoundOperationPlan,
        confirmationReceipt: CodexGhostRepairBulkConfirmationReceipt
    ) async throws -> CodexGhostRepairBulkLiveJournalRecord {
        try await base.prepare(
            plan: plan,
            confirmationReceipt: confirmationReceipt
        )
    }

    func execute(
        requestID: UUID,
        expectedPlanDigest: String
    ) async throws -> CodexGhostRepairBulkLiveTerminalReport {
        let report = try await base.execute(
            requestID: requestID,
            expectedPlanDigest: expectedPlanDigest
        )
        await pause.pauseBeforeReturn()
        return report
    }
}

private actor ReturnPause {
    nonisolated let pausedExpectation: XCTestExpectation
    private var waitForRelease: CheckedContinuation<Void, Never>?

    init(pausedExpectation: XCTestExpectation) {
        self.pausedExpectation = pausedExpectation
    }

    func pauseBeforeReturn() async {
        pausedExpectation.fulfill()
        guard !Task.isCancelled else { return }
        await withCheckedContinuation { waitForRelease = $0 }
    }

    func release() {
        waitForRelease?.resume()
        waitForRelease = nil
    }
}
