@testable import AgentSessionManagerCore
import XCTest

@MainActor
final class SessionManagerModelTests: XCTestCase {
    func testDeleteSpaceMeasurementUsesOnlySuccessfulAbsentItemsAndOneBatchScan() async {
        let reader = AppTestSessionSizeReader(values: ["a": 0, "b": 0, "failed": 0, "unknown": 0])
        let model = SessionManagerModel(sessionFileSizeReader: reader)
        let report = makeNativeDeleteReport(items: [("a", .success, .absent), ("b", .success, .absent),
                                                   ("failed", .failure, .absent), ("unknown", .success, .unavailable)])
        await model.measureNativeDeleteSpace(report: report, homeURL: URL(fileURLWithPath: "/fixture"),
                                            before: ["a": 100, "b": 200, "failed": 300, "unknown": 400])
        XCTAssertEqual(model.nativeDeleteSpaceReportID, report.id)
        XCTAssertEqual(model.nativeDeleteSpaceSummary?.measuredBytes, 300)
        XCTAssertEqual(model.nativeDeleteSpaceSummary?.deletedSessionCount, 2)
        let requests = await reader.requestedIDs
        XCTAssertEqual(requests, [Set(["a", "b"])])
    }

    func testDeleteSpaceDoesNotInventMissingBaselineOrMeasureRecoveredReport() async {
        let reader = AppTestSessionSizeReader(values: ["a": 0])
        let model = SessionManagerModel(sessionFileSizeReader: reader)
        let report = makeNativeDeleteReport(items: [("a", .success, .absent)])
        await model.measureNativeDeleteSpace(report: report, homeURL: nil, before: ["a": 100])
        XCTAssertNil(model.nativeDeleteSpaceSummary?.measuredBytes)
        let recovered = NativeDeleteReport(id: UUID(), previewID: report.previewID, outcome: report.outcome,
                                           completedAt: report.completedAt, items: report.items, recoveredAfterInterruption: true)
        await model.measureNativeDeleteSpace(report: recovered, homeURL: URL(fileURLWithPath: "/fixture"), before: ["a": 100])
        XCTAssertNotEqual(model.nativeDeleteSpaceReportID, recovered.id)
        let requests = await reader.requestedIDs
        XCTAssertTrue(requests.isEmpty)
    }

    func testDeleteFailureAllowsRetryOnlyWithUnexpiredUnusedPreviewEvidence() {
        let now = Date(timeIntervalSince1970: 1_000)
        let unused = NativeDeleteSubmissionFailure.stopped(
            message: "Quit Codex first.", unusedPreviewExpiresAt: now.addingTimeInterval(60), now: now)
        XCTAssertTrue(unused.canRetry)
        XCTAssertEqual(unused.title, "Deletion has not started")
        XCTAssertTrue(unused.message.contains("Check Again and Delete"))
        for expiry: Date? in [nil, now, now.addingTimeInterval(-1)] {
            let stopped = NativeDeleteSubmissionFailure.stopped(
                message: "Review required.", unusedPreviewExpiresAt: expiry, now: now)
            XCTAssertFalse(stopped.canRetry)
            XCTAssertFalse(stopped.message.contains("No Delete request was sent"))
        }
    }

    func testDeletePreviewKeepsFooterWithinScreenBounds() {
        for screen in [CGSize(width: 1_280, height: 720), CGSize(width: 1_440, height: 900),
                       CGSize(width: 800, height: 600), CGSize(width: 2_560, height: 1_440)] {
            let size = NativeDeletePreviewSheetLayout.size(visibleScreenSize: screen)
            XCTAssertLessThanOrEqual(size.width, screen.width - 80)
            XCTAssertLessThanOrEqual(size.height, screen.height - 120)
            XCTAssertLessThanOrEqual(size.width, 760)
            XCTAssertLessThanOrEqual(size.height, 820)
        }
    }

    func testDeleteFailureReturnsToPreviewWithoutHiddenGlobalAlert() async {
        let model = makeModel(sessions: [])
        let preview = OperationPreview(id: UUID(), provider: .codex, operation: .emptyTrash,
                                       confirmationToken: "fixture", generatedAt: Date(), items: [], warnings: [])
        model.pendingNativeDeletePreview = preview
        let failure = await model.executeNativeDelete(preview, confirmationToken: "fixture")
        XCTAssertNotNil(failure)
        XCTAssertFalse(failure?.canRetry ?? true)
        XCTAssertNil(model.errorMessage, "The visible preview owns submission failures, not an alert behind it")
        XCTAssertNil(model.nativeDeleteSubmissionProgress)
        XCTAssertEqual(model.pendingNativeDeletePreview?.id, preview.id)
    }

    func testPreviousCleanupBlockReturnsActionableFeedbackAndDoesNotConsumePreview() async {
        let model = makeModel(sessions: [],
                              nativeDeleteDesktopCleanupCoordinator: AppTestDesktopCleanupLinkageCoordinator(),
                              bulkReconciliationEnabled: true)
        let report = makeNativeDeleteReport(items: [(AppTestGhostRepairBulkFixture.eligibleA, .success, .absent)])
        model.latestNativeDeleteReport = report
        model.queueNativeDeleteDesktopCleanup(report: report)
        let before = model.nativeDeleteDesktopCleanupState
        let preview = OperationPreview(id: UUID(), provider: .codex, operation: .emptyTrash,
                                       confirmationToken: "fixture", generatedAt: Date(), items: [], warnings: [])
        model.pendingNativeDeletePreview = preview
        for _ in 0..<2 {
            let failure = await model.executeNativeDelete(preview, confirmationToken: "fixture")
            XCTAssertEqual(failure, .cleanupRequired)
            XCTAssertNil(model.errorMessage)
            XCTAssertNil(model.nativeDeleteSubmissionProgress)
            XCTAssertEqual(model.nativeDeleteDesktopCleanupState, before)
            XCTAssertEqual(model.pendingNativeDeletePreview?.id, preview.id)
        }
        model.queueCleanupReviewAfterDeletePreview()
        XCTAssertFalse(model.isGhostRepairBulkInventoryPresented)
        model.presentCleanupAfterDeletePreview()
        XCTAssertTrue(model.isGhostRepairBulkInventoryPresented)
        XCTAssertEqual(model.nativeDeleteDesktopCleanupState, before, "Navigation must not resend or discard cleanup")
        _ = model.setGhostRepairBulkInventoryPresented(false)
        model.presentCleanupAfterDeletePreview()
        XCTAssertFalse(model.isGhostRepairBulkInventoryPresented, "Consume navigation once")
    }

    func testUnreadableMetadataDoesNotAnnounceCodexUpdate() async throws {
        let inspector = AppTestCompatibilityInspector(current: false)
        await inspector.makeMetadataUnavailable()
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector)
        await model.refreshCompatibilityReport()?.value
        XCTAssertFalse(model.isCompatibilityUpdateAlertPresented)
        XCTAssertFalse(model.compatibilityReportIsCurrent)
        XCTAssertTrue(model.compatibilityCheckError?.contains("Database metadata") == true)
        XCTAssertNotNil(model.compatibilityReport, "Keep prior evidence for reference, not admission")
    }

    func testCompatibilityProgressDiagnosticsAndNavigationUseSameCheck() async throws {
        let inspector = AppTestCompatibilityInspector(current: true)
        let store = DiagnosticLogStore.productionInMemory()
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector, diagnosticLogStore: store)
        await model.refreshCompatibilityReport()?.value
        await inspector.setProgressObserver {
            await MainActor.run {
                XCTAssertTrue(model.isCheckingCompatibility)
                XCTAssertFalse(model.compatibilityReportIsCurrent, "UI improvements must not loosen the operation gate")
                XCTAssertEqual(model.compatibilityProgress, "Testing fixture…")
                XCTAssertNotNil(model.compatibilityReport, "Keep prior results for clearly labeled reference")
            }
        }
        await model.checkCodexCompatibility(confirmedBehaviorFingerprint: "fixture")
        XCTAssertFalse(model.isCheckingCompatibility)
        XCTAssertNil(model.compatibilityProgress)
        XCTAssertNotNil(model.compatibilityCompletionMessage)
        let id = try XCTUnwrap(model.compatibilityCheckID)
        let snapshot = try await store.snapshot()
        let events = snapshot.events.filter { $0.category == .compatibility && $0.metadata["check_id"] == id.uuidString }
        XCTAssertTrue(events.contains { $0.message == "Compatibility check started" })
        XCTAssertTrue(events.contains { $0.message == "Compatibility check finished" })
        model.showCompatibilityDiagnostics()
        XCTAssertEqual(model.settingsTab, "logs")
        XCTAssertEqual(model.diagnosticLogRunFilter, id)
    }

    func testFailedCompatibilityCheckHasCorrelatedDiagnosticWithoutRawError() async throws {
        let inspector = AppTestCompatibilityInspector(current: true)
        let store = DiagnosticLogStore.productionInMemory()
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector, diagnosticLogStore: store)
        await inspector.failNextCheck()
        await model.checkCodexCompatibility()
        XCTAssertNotNil(model.compatibilityCheckError)
        XCTAssertFalse(model.isCheckingCompatibility)
        let id = try XCTUnwrap(model.compatibilityCheckID)
        let data = try await store.exportJSONL(compatibilityRunID: id)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Compatibility check stopped"))
        XCTAssertFalse(text.contains("Fixture inspection"))
        XCTAssertFalse(text.contains("/usr/bin/true"))
    }
    func testBehaviorTestsRequireExplicitRequestAndDoNotRunAtStartup() async {
        let inspector = AppTestCompatibilityInspector(current: true)
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector)
        await model.refreshCompatibilityReport()?.value
        await model.checkCodexCompatibility()
        let before = await inspector.behaviorCount
        XCTAssertEqual(before, 0)
        await model.checkCodexCompatibility(confirmedBehaviorFingerprint: "fixture")
        let after = await inspector.behaviorCount
        XCTAssertEqual(after, 1)
        XCTAssertTrue(model.compatibilityReportIsCurrent)
        XCTAssertNil(model.compatibilityProgress)
        XCTAssertFalse(model.isCheckingCompatibility)
        await model.refreshCompatibilityReport()?.value
        let reloaded = await inspector.behaviorCount
        XCTAssertEqual(reloaded, 1)
    }

    func testBehaviorConfirmationCannotSurviveChangedEnvironment() async {
        let inspector = AppTestCompatibilityInspector(current: true)
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector)
        await model.refreshCompatibilityReport()?.value
        await inspector.changeEnvironment("changed")
        await model.checkCodexCompatibility(confirmedBehaviorFingerprint: "fixture")
        XCTAssertNotNil(model.compatibilityCheckError)
        XCTAssertFalse(model.compatibilityReportIsCurrent)
        XCTAssertNil(model.compatibilityProgress)
        let count = await inspector.behaviorCount
        XCTAssertEqual(count, 0)
    }

    func testCompatibilityStartupReusesSavedResultWithoutRunningInspection() async {
        let inspector = AppTestCompatibilityInspector(current: true)
        let provider = CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true")))
        for _ in 0..<2 {
            let model = SessionManagerModel(liveProvider: provider, compatibilityInspector: inspector)
            await model.refreshCompatibilityReport()?.value
            XCTAssertTrue(model.compatibilityReportIsCurrent)
            XCTAssertNil(model.compatibilityNotice)
            XCTAssertFalse(model.isCompatibilityUpdateAlertPresented)
            XCTAssertFalse(model.isComparingCompatibility)
        }
        let calls = await inspector.inspectionCount
        XCTAssertEqual(calls, 0)
    }

    func testChangedRuntimeShowsReminderAndLaterKeepsReviewEntry() async {
        let inspector = AppTestCompatibilityInspector(current: false)
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector)
        await model.refreshCompatibilityReport()?.value
        XCTAssertTrue(model.compatibilityNotice?.title.contains("Codex changed") == true)
        XCTAssertTrue(model.compatibilityNotice?.message.contains("0.999.1") == true)
        XCTAssertTrue(model.isCompatibilityNoticeExpanded)
        XCTAssertTrue(model.isCompatibilityUpdateAlertPresented)
        model.isCompatibilityUpdateAlertPresented = false
        model.deferCompatibilityNotice()
        XCTAssertNotNil(model.compatibilityNotice)
        XCTAssertFalse(model.isCompatibilityNoticeExpanded)
        await model.refreshCompatibilityReport()?.value
        XCTAssertFalse(model.isCompatibilityNoticeExpanded)
        XCTAssertFalse(model.isCompatibilityUpdateAlertPresented)
        await inspector.changeEnvironment("second-update")
        await model.refreshCompatibilityReport()?.value
        XCTAssertTrue(model.isCompatibilityNoticeExpanded)
        XCTAssertTrue(model.isCompatibilityUpdateAlertPresented)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.pendingNativeDeletePreview)
        let calls = await inspector.inspectionCount
        XCTAssertEqual(calls, 0)
    }

    func testForegroundComparisonAlertsAfterPreviouslyCurrentEnvironmentChanges() async {
        let inspector = AppTestCompatibilityInspector(current: true)
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector)
        await model.refreshCompatibilityReport()?.value
        XCTAssertFalse(model.isCompatibilityUpdateAlertPresented)
        await inspector.setCurrent(false)
        await inspector.changeEnvironment("updated-desktop")
        await model.refreshCompatibilityReport()?.value
        XCTAssertTrue(model.isCompatibilityUpdateAlertPresented)
        await inspector.setCurrent(true)
        await model.refreshCompatibilityReport()?.value
        XCTAssertFalse(model.isCompatibilityUpdateAlertPresented)
        let calls = await inspector.inspectionCount
        XCTAssertEqual(calls, 0)
    }

    func testMissingOrBrokenSavedCompatibilityShowsActionableNotice() async {
        let inspector = AppTestCompatibilityInspector(current: false)
        await inspector.omitSavedReport()
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector)
        await model.refreshCompatibilityReport()?.value
        XCTAssertEqual(model.compatibilityNotice?.title, "Check this Codex installation")
        await inspector.failReview()
        await model.refreshCompatibilityReport()?.value
        XCTAssertEqual(model.compatibilityNotice?.title, "Compatibility check needs attention")
        XCTAssertFalse(model.compatibilityReportIsCurrent)
        XCTAssertFalse(model.isComparingCompatibility)
    }

    func testCurrentReportWithUnsupportedFeatureStillExplainsTheLimitation() async {
        let inspector = AppTestCompatibilityInspector(current: true)
        await inspector.addUnsupportedFeature()
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector)
        await model.refreshCompatibilityReport()?.value
        XCTAssertTrue(model.compatibilityReportIsCurrent)
        XCTAssertEqual(model.compatibilityNotice?.title, "Some Codex features need attention")
        XCTAssertTrue(model.compatibilityNotice?.message.contains("Official session deletion") == true)
        XCTAssertFalse(model.isLoading)
    }

    func testCompatibilityCheckPublishesOnlyAStillCurrentReport() async throws {
        let inspector = AppTestCompatibilityInspector(current: true)
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector)
        await model.checkCodexCompatibility()
        XCTAssertNotNil(model.compatibilityReport)
        XCTAssertTrue(model.compatibilityReportIsCurrent)
        XCTAssertFalse(model.isCheckingCompatibility)
        XCTAssertNil(model.compatibilityCheckError)
        await inspector.setCurrent(false)
        await model.refreshCompatibilityReport()?.value
        XCTAssertNotNil(model.compatibilityReport)
        XCTAssertFalse(model.compatibilityReportIsCurrent)
    }

    func testFailedCompatibilityCheckRetainsOldReportButNeverMarksItCurrent() async {
        let inspector = AppTestCompatibilityInspector(current: true)
        let model = SessionManagerModel(
            liveProvider: CodexAppServerProvider(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"))),
            compatibilityInspector: inspector)
        await model.checkCodexCompatibility()
        let previous = model.compatibilityReport
        await inspector.failNextCheck()
        await model.checkCodexCompatibility()
        XCTAssertEqual(model.compatibilityReport, previous)
        XCTAssertFalse(model.compatibilityReportIsCurrent)
        XCTAssertNotNil(model.compatibilityCheckError)
        XCTAssertFalse(model.isCheckingCompatibility)
        XCTAssertNil(model.pendingNativeDeletePreview)
    }

    func testConversationSizesSortNumericallyKeepUnknownLastAndPreserveSearchSelection() async {
        let reader = AppTestSessionSizeReader(values: ["small": 20, "large": 2_000, "zero": 0])
        let model = SessionManagerModel(sessionFileSizeReader: reader)
        let sessions = ["unknown", "small", "large", "zero"].map {
            makeSession(nativeID: $0, title: "Match \($0)", state: .active)
        }
        model.sessionRows = sessions.map(SessionPresentation.init(session:))
        model.selection = [sessions[0].id]
        model.searchText = "Match"
        XCTAssertEqual(model.conversationFileSizeLabel(for: model.sessionRows[0]), "—")
        await model.refreshSessionFileSizes(homeURL: URL(fileURLWithPath: "/test-only"))?.value
        model.sessionListSort = .largest
        XCTAssertEqual(model.filteredSessions.map(\.nativeID), ["large", "small", "zero", "unknown"])
        model.sessionListSort = .smallest
        XCTAssertEqual(model.filteredSessions.map(\.nativeID), ["zero", "small", "large", "unknown"])
        XCTAssertEqual(model.selection, [sessions[0].id])
        XCTAssertEqual(model.searchText, "Match")
        model.sessionListSort = .updated
        XCTAssertEqual(model.filteredSessions.map(\.nativeID), ["unknown", "small", "large", "zero"])
    }

    func testDeletedRowUsesCurrentSizeAndUnavailableRefreshClearsCachedValue() async {
        let reader = AppTestSessionSizeReader(values: ["deleted": 0])
        let model = SessionManagerModel(sessionFileSizeReader: reader)
        let row = makeDeletedPresentation(nativeID: "deleted")
        model.sessionRows = [row]
        XCTAssertNil(model.conversationFileSize(for: row))
        await model.refreshSessionFileSizes(homeURL: URL(fileURLWithPath: "/test-only"))?.value
        XCTAssertEqual(model.conversationFileSize(for: row), 0)
        await reader.replace(values: [:])
        await model.refreshSessionFileSizes(homeURL: URL(fileURLWithPath: "/test-only"))?.value
        XCTAssertNil(model.conversationFileSize(for: row))
        XCTAssertEqual(model.sessionFileSizeIssues["deleted"], .unavailable)
        XCTAssertTrue(model.conversationFileSizeHelp(for: row).contains("Unavailable does not mean zero"))
        XCTAssertFalse(model.isCalculatingSessionFileSizes)
    }

    func testSizeIssueReasonsFollowVisibleScopeAndClearAfterSuccessfulRefresh() async {
        let reader = AppTestSessionSizeInspectionReader(result: .init(
            sizes: ["large": 3_900_000_035, "small": 210_000],
            issues: ["blocked": .conflictingIdentity, "archived": .headerBudgetExceeded]))
        let model = SessionManagerModel(sessionFileSizeReader: reader)
        let large = SessionPresentation(session: makeSession(nativeID: "large", title: "Large", state: .active))
        let small = SessionPresentation(session: makeSession(nativeID: "small", state: .active))
        let blocked = SessionPresentation(session: makeSession(nativeID: "blocked", state: .active))
        let archived = SessionPresentation(session: makeSession(nativeID: "archived", state: .archived))
        model.sessionRows = [small, blocked, large, archived]
        await model.refreshSessionFileSizes(homeURL: URL(fileURLWithPath: "/test-only"))?.value
        model.sessionListSort = .largest
        XCTAssertEqual(model.filteredSessions.map(\.nativeID), ["large", "small", "blocked"])
        XCTAssertEqual(model.conversationFileSizeLabel(for: large), ByteCountFormatter.string(fromByteCount: 3_900_000_035, countStyle: .file))
        XCTAssertEqual(model.unavailableConversationSizeCount, 1)
        XCTAssertTrue(model.conversationFileSizeHelp(for: blocked).contains(SessionFileSizeIssue.conflictingIdentity.explanation))
        XCTAssertFalse(model.conversationFileSizeHelp(for: large).contains("Unavailable"))
        model.searchText = "Large"
        XCTAssertEqual(model.unavailableConversationSizeCount, 0)
        model.selectStatusFilter(.archive)
        XCTAssertEqual(model.unavailableConversationSizeCount, 1)
        XCTAssertTrue(model.conversationFileSizeHelp(for: archived).contains(SessionFileSizeIssue.headerBudgetExceeded.explanation))

        await reader.replace(result: .init(sizes: ["large": 3_900_000_035, "small": 210_000, "blocked": 5, "archived": 8]))
        await model.refreshSessionFileSizes(homeURL: URL(fileURLWithPath: "/test-only"))?.value
        XCTAssertTrue(model.sessionFileSizeIssues.isEmpty)
        XCTAssertEqual(model.unavailableConversationSizeCount, 0)
        XCTAssertEqual(model.conversationFileSize(for: archived), 8)
        XCTAssertFalse(model.conversationFileSizeHelp(for: archived).contains(SessionFileSizeIssue.headerBudgetExceeded.explanation))
    }

    func testUnavailableHomeCancelsOldSizeRequestWithoutReadingDefaultHome() async {
        let reader = AppTestSessionSizeReader(values: ["first": 10])
        let model = SessionManagerModel(sessionFileSizeReader: reader)
        let row = SessionPresentation(session: makeSession(nativeID: "first", state: .active))
        model.sessionRows = [row]
        let oldRequest = model.refreshSessionFileSizes(homeURL: URL(fileURLWithPath: "/test-only"))
        model.refreshSessionFileSizes(homeURL: nil)
        await oldRequest?.value
        XCTAssertNil(model.conversationFileSize(for: row))
        XCTAssertEqual(model.sessionFileSizeIssues["first"], .homeUnavailable)
        XCTAssertTrue(model.conversationFileSizeHelp(for: row).contains(SessionFileSizeIssue.homeUnavailable.explanation))
        XCTAssertFalse(model.isCalculatingSessionFileSizes)
    }

    func testSupplementedSessionCanBeFoundBySourceWithoutClearingSelection() {
        var supplemental = makeSession(nativeID: "supplemental", title: "Automation fixture", state: .active)
        supplemental.supplementalSourceLabel = "Desktop automation · local supplement"
        let normal = makeSession(nativeID: "normal", state: .active)
        let model = makeModel(sessions: [supplemental, normal])
        model.selection = [normal.id]
        model.searchText = "local supplement"
        XCTAssertEqual(model.filteredSessions.map(\.id), [supplemental.id])
        XCTAssertEqual(model.selection, [normal.id])
        XCTAssertEqual(model.filteredSessions.first?.liveSession?.supplementalSourceLabel, supplemental.supplementalSourceLabel)
        model.searchText = ""
        XCTAssertEqual(model.filteredSessions.count, 2)
    }

    func testDeletedRowsBlockAllLifecycleActionsIncludingArchivePreview() {
        let active = makeSession(nativeID: "active", state: .active)
        let model = makeModel(sessions: [active])
        let deleted = makeDeletedPresentation(nativeID: "deleted")
        model.sessionRows.append(deleted)
        model.selection = [deleted.id]
        XCTAssertFalse(model.canRequestPreview(.archive))
        XCTAssertNil(model.pendingNativeArchivePreview)
        for operation: SessionOperation in [.archive, .restore, .moveToTrash, .moveToArchive, .emptyTrash] {
            XCTAssertNotNil(model.blockedReason(for: operation))
            XCTAssertNotNil(model.blockedReason(for: operation, managerKeys: [active.id, deleted.id]))
        }
    }

    func testDeleteReportFitsSmallAndLargeScreensWithoutGrowingWithBatchSize() {
        for screen in [
            CGSize(width: 1_024, height: 600),
            CGSize(width: 1_280, height: 720),
            CGSize(width: 1_440, height: 900),
            CGSize(width: 3_024, height: 1_964)
        ] {
            let size = NativeDeleteReportSheetLayout.size(visibleScreenSize: screen)
            XCTAssertLessThanOrEqual(size.width, screen.width - 80)
            XCTAssertLessThanOrEqual(size.height, screen.height - 120)
            XCTAssertLessThanOrEqual(size.height, 720)
        }
        XCTAssertEqual(NativeDeleteReportSheetLayout.tableHeight(itemCount: 1), 100)
        XCTAssertEqual(NativeDeleteReportSheetLayout.tableHeight(itemCount: 500), 300)
    }

    func testStartsOnCodexActiveInsteadOfAllSessions() {
        let active = makeSession(nativeID: "active", state: .active)
        let archived = makeSession(nativeID: "archived", state: .archived)
        let model = makeModel(sessions: [active, archived])

        XCTAssertEqual(model.selectedSystem, .codex)
        XCTAssertEqual(model.selectedFilter, .active)
        XCTAssertEqual(model.filteredSessions.map(\.nativeID), ["active"])
        XCTAssertEqual(model.navigationTitle, "Active")
    }

    func testProjectScopeAndStatusRemainIndependentFilters() {
        let projectA = SessionProject(id: "project-a", name: "Project A", rootPath: "/projects/a")
        let projectB = SessionProject(id: "project-b", name: "Project B", rootPath: "/projects/b")
        let activeA = makeSession(nativeID: "active-a", state: .active, project: projectA)
        let archivedA = makeSession(nativeID: "archive-a", state: .archived, project: projectA)
        let activeB = makeSession(nativeID: "active-b", state: .active, project: projectB)
        let model = makeModel(sessions: [activeA, archivedA, activeB])
        model.projectCatalog = [projectA, projectB]

        model.selectProject(projectA.id)
        XCTAssertEqual(model.filteredSessions.map(\.nativeID), ["active-a"])
        XCTAssertEqual(model.navigationTitle, "Project A · Active")

        model.selectStatusFilter(.archive)
        XCTAssertEqual(model.filteredSessions.map(\.nativeID), ["archive-a"])
        XCTAssertEqual(model.navigationTitle, "Project A · Archive")
    }

    func testChangingSearchPreservesHiddenCheckboxSelection() {
        let first = makeSession(
            nativeID: "019f64d8-4be2-7c60-91ba-8687501cfd66",
            title: "First",
            state: .active
        )
        let second = makeSession(
            nativeID: "019f64e3-ba20-7792-a7ab-1433db7ed8ec",
            title: "Second",
            state: .active
        )
        let archived = makeSession(nativeID: "archived", state: .archived)
        let model = makeModel(sessions: [first, second, archived])

        model.setSelected(first.id, isSelected: true)
        model.searchText = second.nativeID
        XCTAssertEqual(model.selection, [first.id])
        XCTAssertNil(model.focusedSessionID)

        model.setSelected(second.id, isSelected: true)
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertEqual(model.visibleSelectionCount, 1)

        model.searchText = ""
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertEqual(model.visibleSelectionCount, 2)

        model.selectStatusFilter(.archive)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.focusedSessionID)
    }

    func testSelectedOnlyFilterShowsCheckedRowsWithoutChangingSelection() {
        let first = makeSession(nativeID: "first", title: "First", state: .active)
        let second = makeSession(nativeID: "second", title: "Second", state: .active)
        let third = makeSession(nativeID: "third", title: "Third", state: .active)
        let model = makeModel(sessions: [first, second, third])

        model.setSelected(first.id, isSelected: true)
        model.setSelected(second.id, isSelected: true)
        model.isShowingSelectedSessionsOnly = true

        XCTAssertEqual(Set(model.filteredSessions.map(\.id)), [first.id, second.id])
        XCTAssertEqual(model.selection, [first.id, second.id])

        model.searchText = second.nativeID
        XCTAssertEqual(model.filteredSessions.map(\.id), [second.id])
        XCTAssertEqual(model.selection, [first.id, second.id])

        model.clearSelection()
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.isShowingSelectedSessionsOnly)
        XCTAssertEqual(model.filteredSessions.map(\.id), [second.id])
    }

    func testWithoutSearchSelectAllRemainsAvailableOnlyForFilteredTrash() {
        let active = makeSession(nativeID: "active", state: .active)
        let firstTrash = makeSession(nativeID: "trash-1", title: "Keep", state: .archived, isTrash: true)
        let secondTrash = makeSession(nativeID: "trash-2", title: "Hide", state: .archived, isTrash: true)
        let model = makeModel(sessions: [active, firstTrash, secondTrash])

        XCTAssertFalse(model.showsFilteredSelectionControls)
        model.toggleFilteredSelection()
        XCTAssertTrue(model.selection.isEmpty)

        model.selectStatusFilter(.trash)
        model.searchText = "Keep"
        XCTAssertTrue(model.showsFilteredSelectionControls)
        model.toggleFilteredSelection()
        XCTAssertEqual(model.selection, [firstTrash.id])
        XCTAssertEqual(model.filteredSelectionState, .all)

        model.toggleFilteredSelection()
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.filteredSelectionState, .none)
        model.searchText = ""
        model.toggleFilteredSelection()
        XCTAssertEqual(model.selection, [firstTrash.id, secondTrash.id])
    }

    func testSwitchingStatusClearsSearchSelectionAndSelectedOnlyWithoutLosingProjectScope() {
        let project = SessionProject(id: "project", name: "Project", rootPath: "/project")
        let active = makeSession(nativeID: "active", state: .active, project: project)
        let model = makeModel(sessions: [active])
        model.projectCatalog = [project]
        model.selectProject(project.id)
        for filter: CollectionFilter in [.deleted, .archive, .trash, .all, .pinned, .active] {
            model.searchText = "local supplement"
            model.selection = [active.id]
            model.isShowingSelectedSessionsOnly = true
            model.focusedSessionID = active.id
            model.selectStatusFilter(filter)
            XCTAssertEqual(model.searchText, "")
            XCTAssertTrue(model.selection.isEmpty)
            XCTAssertFalse(model.isShowingSelectedSessionsOnly)
            XCTAssertNil(model.focusedSessionID)
            XCTAssertEqual(model.selectedProjectID, project.id)
        }
    }

    func testActiveToDeletedShowsRecordsAfterClearingCarriedSearch() {
        let model = makeModel(sessions: [makeSession(nativeID: "active", state: .active)])
        let deleted = makeDeletedPresentation(nativeID: "deleted")
        model.sessionRows.append(deleted)
        model.searchText = "local supplement"
        XCTAssertTrue(model.filteredSessions.isEmpty)
        model.selectStatusFilter(.deleted)
        XCTAssertEqual(model.filteredSessions.map(\.id), [deleted.id])
    }

    func testReselectingSameStatusKeepsSearchButClearSearchPreservesCheckboxes() {
        let active = makeSession(nativeID: "active", state: .active)
        let model = makeModel(sessions: [active])
        model.selection = [active.id]
        model.searchText = "no-match"
        model.selectStatusFilter(.active)
        XCTAssertEqual(model.searchText, "no-match")
        XCTAssertTrue(model.hasSessionSearch)
        XCTAssertTrue(model.filteredSessions.isEmpty)
        model.clearSessionSearch()
        XCTAssertFalse(model.hasSessionSearch)
        XCTAssertEqual(model.selection, [active.id])
        XCTAssertEqual(model.filteredSessions.map(\.id), [active.id])
    }

    func testSelectSearchResultsPreservesHiddenSelectionAndTriState() {
        let first = makeSession(nativeID: "first", title: "Match first", state: .active)
        let second = makeSession(nativeID: "second", title: "Match second", state: .active)
        let hidden = makeSession(nativeID: "hidden", title: "Other", state: .active)
        let archived = makeSession(nativeID: "archive", title: "Match archive", state: .archived)
        let model = makeModel(sessions: [first, second, hidden, archived])
        model.searchText = "Match"
        model.selection = [first.id, hidden.id]
        XCTAssertTrue(model.canToggleFilteredSelection)
        XCTAssertEqual(model.filteredSelectionState, .partial)
        model.toggleFilteredSelection()
        XCTAssertEqual(model.selection, [first.id, second.id, hidden.id])
        XCTAssertEqual(model.visibleSelectionCount, 2)
        XCTAssertEqual(model.filteredSelectionState, .all)
        model.toggleFilteredSelection()
        XCTAssertEqual(model.selection, [hidden.id])
        XCTAssertEqual(model.filteredSelectionState, .none)
    }

    func testSelectSearchResultsHonorsProjectScopeAndArchiveStatus() {
        let project = SessionProject(id: "project", name: "Project", rootPath: "/project")
        let archived = makeSession(nativeID: "archive", title: "Match", state: .archived, project: project)
        let otherProject = makeSession(nativeID: "elsewhere", title: "Match", state: .archived)
        let active = makeSession(nativeID: "active", title: "Match", state: .active, project: project)
        let model = makeModel(sessions: [archived, otherProject, active])
        model.projectCatalog = [project]
        model.selectProject(project.id)
        model.selectStatusFilter(.archive)
        model.searchText = "Match"
        model.toggleFilteredSelection()
        XCTAssertEqual(model.selection, [archived.id])
    }

    func testSelectSearchResultsSupportsSupplementSourceAndDeletedRecords() {
        var supplemented = makeSession(nativeID: "supplemented", state: .active)
        supplemented.supplementalSourceLabel = "Desktop automation · local supplement"
        let model = makeModel(sessions: [supplemented, makeSession(nativeID: "normal", state: .active)])
        model.searchText = "local supplement"
        model.toggleFilteredSelection()
        XCTAssertEqual(model.selection, [supplemented.id])
        let deleted = makeDeletedPresentation(nativeID: "deleted-match")
        model.sessionRows.append(deleted)
        model.selectStatusFilter(.deleted)
        model.searchText = "deleted-match"
        model.toggleFilteredSelection()
        XCTAssertEqual(model.selection, [deleted.id])
        XCTAssertNotNil(model.blockedReason(for: .archive))
        XCTAssertNotNil(model.blockedReason(for: .emptyTrash))
    }

    func testSelectSearchResultsDoesNothingForEmptySearchNoMatchesOrLoading() {
        let session = makeSession(nativeID: "target", state: .active)
        let model = makeModel(sessions: [session])
        for query in ["", "   \n"] {
            model.searchText = query
            XCTAssertFalse(model.showsFilteredSelectionControls)
            model.toggleFilteredSelection()
            XCTAssertTrue(model.selection.isEmpty)
        }
        model.searchText = "no-match"
        XCTAssertTrue(model.showsFilteredSelectionControls)
        XCTAssertFalse(model.canToggleFilteredSelection)
        model.toggleFilteredSelection()
        XCTAssertTrue(model.selection.isEmpty)
        model.searchText = session.nativeID
        model.isLoading = true
        XCTAssertFalse(model.canToggleFilteredSelection)
        model.toggleFilteredSelection()
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testSelectedOnlyViewNeverAddsHiddenSearchResults() {
        let first = makeSession(nativeID: "match-first", state: .active)
        let second = makeSession(nativeID: "match-second", state: .active)
        let model = makeModel(sessions: [first, second])
        model.searchText = "match"
        model.selection = [first.id]
        model.isShowingSelectedSessionsOnly = true
        model.toggleFilteredSelection()
        XCTAssertTrue(model.selection.isEmpty)
        model.isShowingSelectedSessionsOnly = false
        model.toggleFilteredSelection()
        XCTAssertEqual(model.selection, [first.id, second.id])
        model.searchText = ""
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertFalse(model.showsFilteredSelectionControls)
    }

    func testArchivePreviewShowsErrorForUnauditedRuntime() async {
        let session = makeSession(nativeID: "archive-candidate", state: .active)
        let model = makeModel(sessions: [session])
        model.selection = [session.id]
        model.providerDiagnostics = [ProviderDiagnostics(
            system: .codex,
            connectionState: .ready,
            runtimeVersion: "0.150.0",
            lastRefreshedAt: Date(timeIntervalSince1970: 1_000),
            inventoryComplete: true,
            protectionComplete: false,
            capabilities: .codexLiveReadOnly
        )]

        await model.requestPreview(.archive)

        XCTAssertNil(model.pendingNativeArchivePreview)
        XCTAssertEqual(
            model.errorMessage,
            "Archive is unavailable because Codex runtime 0.150.0 is outside this version of Agent Session Manager's audited lifecycle allow-list. Open Settings → Compatibility and run the isolated tests to verify this installation. No Archive request was sent."
        )
    }

    func testAuditedArchiveRuntimeDoesNotProduceCompatibilityError() {
        XCTAssertNil(CodexLifecycleMutationKind.archive.compatibilityBlockedReason(
            runtimeVersion: "0.149.0"
        ))
    }

    func testSingleArchiveRoutesDirectlyToGuardedNativePreview() async {
        let session = makeSession(nativeID: "archive-candidate", state: .active)
        let model = makeModel(sessions: [session])
        model.selection = [session.id]
        model.providerDiagnostics = [ProviderDiagnostics(
            system: .codex,
            connectionState: .ready,
            runtimeVersion: "0.153.4",
            lastRefreshedAt: Date(timeIntervalSince1970: 1_000),
            inventoryComplete: true,
            protectionComplete: false,
            capabilities: .codexLiveReadOnly
        )]

        // This fixture has no native coordinator. The direct entry must reach
        // its existing guard, not fall through to a manager-only operation.
        await model.requestPreview(.archive)

        XCTAssertNil(model.pendingNativeArchivePreview)
        XCTAssertNil(model.pendingPreview)
        XCTAssertEqual(
            model.errorMessage,
            "Native Archive Preview is unavailable for the current selection."
        )
    }

    func testPreviewRequestStopsAtModelRuntimeGateBeforeCoordinator() async {
        let session = makeSession(nativeID: "runtime-gated", state: .active)
        let model = makeModel(sessions: [session])
        model.selection = [session.id]
        model.providerDiagnostics = [ProviderDiagnostics(
            system: .codex,
            connectionState: .ready,
            runtimeVersion: "0.150.0",
            lastRefreshedAt: Date(timeIntervalSince1970: 1_000),
            inventoryComplete: true,
            protectionComplete: true,
            capabilities: .codexLiveReadOnly
        )]

        await model.requestPreview(.archive)

        XCTAssertEqual(
            model.errorMessage,
            "Archive is unavailable because Codex runtime 0.150.0 is outside this version of Agent Session Manager's audited lifecycle allow-list. Open Settings → Compatibility and run the isolated tests to verify this installation. No Archive request was sent."
        )
        XCTAssertNil(model.pendingNativeArchivePreview)
        XCTAssertNil(model.pendingPreview)
    }

    func testGhostRepairReviewIsDefaultOffAndDoesNotCallSource() async {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-a"]
        ))
        let model = makeModel(sessions: [], ghostRepairSource: source)
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        XCTAssertEqual(
            model.errorMessage,
            "Enable Bulk Ghost Delete in Settings first."
        )
        let requests = await source.requests
        XCTAssertEqual(requests, [])
        XCTAssertEqual(model.ghostRepairReadOnlyReviewState, .idle)
    }

    func testGhostRepairReviewFreezesExactDeletedSelectionAndStaysReadOnly() async {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-b", "deleted-a"]
        ))
        var persistedValues: [Bool] = []
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            bulkReconciliationPreferenceWriter: { persistedValues.append($0) }
        )
        let first = makeDeletedPresentation(nativeID: "deleted-a")
        let second = makeDeletedPresentation(nativeID: "deleted-b")
        model.sessionRows = [second, first]
        model.selection = [first.id, second.id]

        XCTAssertTrue(model.setGhostRepairBulkReconciliationEnabled(true))
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        XCTAssertEqual(persistedValues, [true])
        let requests = await source.requests
        XCTAssertEqual(requests, [["deleted-a", "deleted-b"]])
        guard case let .ready(review) = model.ghostRepairReadOnlyReviewState else {
            return XCTFail("Expected a completed read-only review")
        }
        XCTAssertEqual(review.targetThreadIDs, ["deleted-a", "deleted-b"])
        XCTAssertTrue(review.officialEvidenceEligible)
        XCTAssertFalse(review.liveRepairAvailable)
    }

    func testGhostRepairReviewSurfacesUndocumentedRPCWithoutCreatingAuthority() async {
        let targetID = "deleted-a"
        let runtimeVersion = "codex-cli 0.149.0"
        let snapshot = CodexGhostRepairSafetySnapshot(
            inventory: ProviderInventorySnapshot(
                provider: .codex,
                runtimeVersion: runtimeVersion,
                inventoryHash: "inventory-hash",
                observedAt: Date(timeIntervalSince1970: 1_000),
                inventoryComplete: true,
                protectionComplete: true,
                sessions: [],
                archiveScopeNodes: [],
                archiveScopeComplete: true
            ),
            exactReadbacks: [ExactSessionReadbackEvidence(
                provider: .codex,
                nativeSessionID: targetID,
                status: .unavailable,
                observedAt: Date(timeIntervalSince1970: 1_000),
                runtimeVersion: runtimeVersion,
                evidenceKind: .rpcError,
                rpcCode: -32600,
                absenceContract: nil,
                message: "thread not loaded: \(targetID)"
            )],
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            executionGate: CodexGhostRepairExecutionGate(
                codexFullyExited: false,
                desktopOpenHandleCount: 1,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                capacitySufficient: true
            )
        )
        let source = AppTestGhostRepairSafetySource(snapshot: snapshot)
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: targetID)
        model.sessionRows = [deleted]
        model.selection = [deleted.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        guard case let .ready(review) = model.ghostRepairReadOnlyReviewState else {
            return XCTFail("Expected an evidence-only completed review")
        }
        XCTAssertEqual(review.targetThreadIDs, [targetID])
        XCTAssertEqual(review.runtimeVersion, runtimeVersion)
        XCTAssertEqual(review.exactReadbacks.first?.evidenceKind, .rpcError)
        XCTAssertEqual(review.exactReadbacks.first?.rpcCode, -32600)
        XCTAssertEqual(
            review.exactReadbacks.first?.message,
            "thread not loaded: \(targetID)"
        )
        XCTAssertNotNil(review.evidenceUnavailableReason)
        XCTAssertFalse(review.officialEvidenceEligible)
        XCTAssertFalse(review.operationalGateClear)
        XCTAssertFalse(review.liveRepairAvailable)
    }

    func testGhostRepairReviewRejectsNonDeletedSelectionBeforeSourceCall() async {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["active"]
        ))
        let active = makeSession(nativeID: "active", state: .active)
        let model = makeModel(
            sessions: [active],
            ghostRepairSource: source,
            bulkReconciliationEnabled: true
        )
        model.selection = [active.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        XCTAssertEqual(
            model.errorMessage,
            "Ghost Repair Safety Review accepts only manager Deleted tombstones from Codex."
        )
        let requests = await source.requests
        XCTAssertEqual(requests, [])
    }

    func testSnapshotActionIsDefaultOffAndDoesNotCallCoordinator() async {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-a"]
        ))
        let coordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "fake-snapshot")]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        await model.requestGhostRepairSnapshotAction(managerKeys: model.selection)

        guard case .unavailable = model.ghostRepairSnapshotActionState else {
            return XCTFail("Snapshot action must start unavailable")
        }
        let requests = await coordinator.requests
        XCTAssertEqual(requests, [])
    }

    func testBulkReconciliationPreferenceHasSingleOwnerAndPersistsChanges() {
        var writtenValues: [Bool] = []
        let model = makeModel(
            sessions: [],
            bulkReconciliationPreferenceWriter: {
                writtenValues.append($0)
            },
            bulkReconciliationEnabled: false
        )

        XCTAssertFalse(model.isGhostRepairBulkReconciliationEnabled)
        XCTAssertTrue(model.setGhostRepairBulkReconciliationEnabled(true))
        XCTAssertEqual(writtenValues, [true])

        XCTAssertTrue(model.setGhostRepairBulkReconciliationEnabled(false))
        XCTAssertFalse(model.isGhostRepairBulkReconciliationEnabled)
        XCTAssertEqual(writtenValues, [true, false])
    }

    func testPriorEnabledSnapshotActionDoesNotRunOnReviewOrSelectionChange()
        async
    {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-a"]
        ))
        let coordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "must-remain-unused")]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)
        guard case .idle = model.ghostRepairSnapshotAdmissionState else {
            return XCTFail("Review must not run Snapshot admission automatically")
        }
        guard case .blocked = model.ghostRepairSnapshotActionState else {
            return XCTFail("Snapshot action must wait for an explicit inspection")
        }
        var requests = await coordinator.requests
        XCTAssertEqual(requests, [])

        model.selection.removeAll()
        guard case .blocked = model.ghostRepairSnapshotActionState else {
            return XCTFail("Selection drift must update readiness only")
        }
        requests = await coordinator.requests
        XCTAssertEqual(requests, [])
    }

    func testSnapshotAdmissionInspectorIsDefaultOffAndNeverRunsFromReview()
        async
    {
        let source = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(targetIDs: ["deleted-a"])
        )
        let inspector = AppTestGhostRepairSnapshotAdmissionInspector(
            outcomes: [.allowed(.appTestAllowed)]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            snapshotAdmissionInspector: inspector
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)
        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)

        guard case .idle = model.ghostRepairSnapshotAdmissionState else {
            return XCTFail("Disabled inspector must remain idle")
        }
        let requests = await inspector.requests
        XCTAssertEqual(requests, [])
    }

    func testExplicitSnapshotAdmissionInspectionUsesExactFrozenReviewOnce()
        async
    {
        let source = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: ["deleted-b", "deleted-a"]
            )
        )
        let inspector = AppTestGhostRepairSnapshotAdmissionInspector(
            outcomes: [.allowed(.appTestAllowed)]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            snapshotAdmissionInspector: inspector,
            bulkReconciliationEnabled: true
        )
        let first = makeDeletedPresentation(nativeID: "deleted-a")
        let second = makeDeletedPresentation(nativeID: "deleted-b")
        model.sessionRows = [second, first]
        model.selection = [first.id, second.id]
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        let requestsBeforeButton = await inspector.requests
        XCTAssertEqual(requestsBeforeButton, [])

        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)

        let requests = await inspector.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.targetThreadIDs,
            ["deleted-a", "deleted-b"]
        )
        guard case let .allowed(request, evidence) =
                model.ghostRepairSnapshotAdmissionState else {
            return XCTFail("Explicit inspection should present typed evidence")
        }
        XCTAssertEqual(request, requests.first)
        XCTAssertEqual(evidence, .appTestAllowed)
    }

    func testAdmissionOperatorDecisionTreatsRepairOnlyUnavailableAsExpected()
        async throws
    {
        let source = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: ["deleted-a"],
                exactAbsenceAvailable: false
            )
        )
        let inspector = AppTestGhostRepairSnapshotAdmissionInspector(
            outcomes: [.allowed(.appTestAllowed)]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            snapshotAdmissionInspector: inspector,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        XCTAssertEqual(
            model.ghostRepairSnapshotAdmissionOperatorDecision.kind,
            .ready
        )
        XCTAssertTrue(
            model.ghostRepairSnapshotAdmissionOperatorDecision.detail
                .contains("expected")
        )
        let beforeReport = try XCTUnwrap(
            model.ghostRepairSnapshotAdmissionReadOnlyReport
        )
        XCTAssertTrue(beforeReport.contains("operator_decision=READY"))
        XCTAssertTrue(
            beforeReport.contains(
                "repair_only_evidence=expected_non_blocking_unavailable"
            )
        )
        XCTAssertTrue(
            beforeReport.contains(
                "live_repair=expected_unavailable_non_blocking"
            )
        )
        XCTAssertTrue(beforeReport.contains("snapshot_admission=not_run"))

        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)

        XCTAssertEqual(
            model.ghostRepairSnapshotAdmissionOperatorDecision.kind,
            .passed
        )
        let afterReport = try XCTUnwrap(
            model.ghostRepairSnapshotAdmissionReadOnlyReport
        )
        XCTAssertTrue(afterReport.contains("operator_decision=PASSED"))
        XCTAssertTrue(afterReport.contains("snapshot_admission=allowed_retained_"))
        XCTAssertTrue(afterReport.contains("snapshot_created=false"))
        XCTAssertTrue(afterReport.contains("preview_created=false"))
        XCTAssertTrue(afterReport.contains("repair_mutation_authority=false"))
        XCTAssertTrue(afterReport.contains("automatic_retry=false"))
    }

    func testAdmissionOperatorDecisionStopsOnActualOperatingBlocker()
        async throws
    {
        let owner = CodexGhostRepairOpenHandleOwnerEvidence(
            databaseRole: .state,
            processIdentifier: 60_884,
            parentProcessIdentifier: 53_739,
            processName: "codex",
            executableName: "codex",
            parentProcessName: "AgentUsageBar",
            processKind: nil,
            fileDescriptorCount: 2
        )
        let source = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: ["deleted-a"],
                exactAbsenceAvailable: false,
                executionGate: CodexGhostRepairExecutionGate(
                    codexFullyExited: true,
                    desktopOpenHandleCount: 0,
                    summariesOpenHandleCount: 0,
                    historyOpenHandleCount: 0,
                    stateOpenHandleCount: 2,
                    threadHistoryOpenHandleCount: 0,
                    capacitySufficient: true,
                    desktopProcessEvidence: [],
                    openHandleOwnerEvidence: [owner]
                )
            )
        )
        let inspector = AppTestGhostRepairSnapshotAdmissionInspector(
            outcomes: [.allowed(.appTestAllowed)]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            snapshotAdmissionInspector: inspector,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        XCTAssertEqual(
            model.ghostRepairSnapshotAdmissionOperatorDecision.kind,
            .stop
        )
        XCTAssertTrue(
            model.ghostRepairSnapshotAdmissionOperatorDecision.title
                .contains("operating conditions")
        )
        XCTAssertTrue(
            model.ghostRepairSnapshotAdmissionOperatorDecision.detail
                .contains("AgentUsageBar (PID 53739)")
        )
        let report = try XCTUnwrap(
            model.ghostRepairSnapshotAdmissionReadOnlyReport
        )
        XCTAssertTrue(report.contains("operator_decision=STOP"))
        XCTAssertTrue(report.contains("operating_conditions=stop"))
        XCTAssertTrue(report.contains("state_open_handle_count=2"))
        XCTAssertTrue(report.contains("open_handle_owner_evidence=collected"))
        XCTAssertTrue(report.contains("open_handle_owner_count=1"))
        XCTAssertTrue(report.contains("open_handle_owner_process_count=1"))
        XCTAssertTrue(report.contains("State (state_5.sqlite): process codex"))
        XCTAssertTrue(report.contains("parent AgentUsageBar (PID 53739)"))
        XCTAssertTrue(report.contains("2 open file descriptors"))
        XCTAssertFalse(report.contains("/Users/"))

        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)
        let requests = await inspector.requests
        XCTAssertEqual(requests, [])
    }

    func testAdmissionReportFailsClosedWhenHandleOwnerEvidenceIsUnavailable()
        async throws
    {
        let source = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: ["deleted-a"],
                exactAbsenceAvailable: false,
                executionGate: CodexGhostRepairExecutionGate(
                    codexFullyExited: true,
                    desktopOpenHandleCount: 0,
                    summariesOpenHandleCount: 0,
                    historyOpenHandleCount: 0,
                    stateOpenHandleCount: 1,
                    threadHistoryOpenHandleCount: 0,
                    capacitySufficient: true,
                    openHandleOwnerEvidence: nil
                )
            )
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        let report = try XCTUnwrap(
            model.ghostRepairSnapshotAdmissionReadOnlyReport
        )
        XCTAssertTrue(report.contains("operator_decision=STOP"))
        XCTAssertTrue(report.contains("open_handle_owner_evidence=unavailable"))
        XCTAssertTrue(report.contains("open_handle_owner_count=unavailable"))
        XCTAssertTrue(
            model.ghostRepairSnapshotAdmissionOperatorDecision.detail
                .contains("owner evidence is unavailable")
        )
    }

    func testSnapshotAdmissionInspectionPreventsReentryAndDiscardsLateResult()
        async
    {
        let source = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(targetIDs: ["deleted-a"])
        )
        let inspector =
            AppTestSuspendingGhostRepairSnapshotAdmissionInspector()
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            snapshotAdmissionInspector: inspector,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        let first = Task { @MainActor in
            await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)
        }
        await inspector.waitUntilRequested()
        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)
        let requestCountAfterReentry = await inspector.requestCount()
        XCTAssertEqual(requestCountAfterReentry, 1)

        XCTAssertTrue(model.setGhostRepairBulkReconciliationEnabled(false))
        await inspector.finish(with: .allowed(.appTestAllowed))
        await first.value

        guard case .idle = model.ghostRepairSnapshotAdmissionState else {
            return XCTFail("A disabled inspector must discard its late result")
        }
        let finalRequestCount = await inspector.requestCount()
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testSnapshotDefaultCoordinatorRequiresExplicitReviewedActionAndExposesReadOnlyInspector() {
        let model = makeModel(
            sessions: [],
            bulkReconciliationEnabled: true
        )

        XCTAssertEqual(
            model.ghostRepairSnapshotActionCapabilities,
            .fixedManagerRawDatabaseSnapshot
        )
        XCTAssertTrue(
            model.ghostRepairSnapshotActionCapabilities.effect
                .readsCodexDatabaseFiles
        )
        XCTAssertTrue(
            model.ghostRepairSnapshotActionCapabilities.acquisitionAvailable
        )
        XCTAssertFalse(
            model.ghostRepairSnapshotActionCapabilities.effect
                .writesCodexDatabaseFiles
        )
        XCTAssertFalse(
            model.ghostRepairSnapshotActionCapabilities.repairMutationAuthority
        )
        XCTAssertEqual(
            model.ghostRepairSnapshotAdmissionInspectorCapabilities,
            .packagedFixedReadOnly
        )
        XCTAssertTrue(
            model.ghostRepairSnapshotAdmissionInspectorCapabilities
                .inspectionAvailable
        )
        guard case .reviewRequired =
            model.ghostRepairSnapshotActionState else {
            return XCTFail("Snapshot publication must require an explicit completed review")
        }
    }

    func testSnapshotActionRequiresSameExactReviewedDeletedSelection() async {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-a", "deleted-b"]
        ))
        let coordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "fake-snapshot")]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        let first = makeDeletedPresentation(nativeID: "deleted-a")
        let second = makeDeletedPresentation(nativeID: "deleted-b")
        model.sessionRows = [first, second]
        model.selection = [first.id, second.id]
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)
        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)
        model.selection = [first.id]

        await model.requestGhostRepairSnapshotAction(managerKeys: model.selection)

        guard case let .blocked(targetIDs, _) = model.ghostRepairSnapshotActionState else {
            return XCTFail("Changed exact selection must be blocked")
        }
        XCTAssertEqual(targetIDs, ["deleted-a", "deleted-b"])
        let requests = await coordinator.requests
        XCTAssertEqual(requests, [])
    }

    func testExplicitSnapshotActionPassesFrozenRequestOnceAndPresentsSuccess() async {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-b", "deleted-a"]
        ))
        let coordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "fake-snapshot-01")]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        let first = makeDeletedPresentation(nativeID: "deleted-a")
        let second = makeDeletedPresentation(nativeID: "deleted-b")
        model.sessionRows = [second, first]
        model.selection = [first.id, second.id]
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)
        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)

        guard case let .ready(readyRequest) = model.ghostRepairSnapshotActionState else {
            return XCTFail("Eligible exact review should become ready")
        }
        XCTAssertEqual(readyRequest.targetThreadIDs, ["deleted-a", "deleted-b"])

        await model.requestGhostRepairSnapshotAction(managerKeys: model.selection)

        let requests = await coordinator.requests
        XCTAssertEqual(requests, [readyRequest])
        XCTAssertEqual(
            model.ghostRepairSnapshotActionState,
            .succeeded(readyRequest, reference: "fake-snapshot-01")
        )
    }

    func testSnapshotQuotaIsVisibleAndBlocksBeforeCreateSnapshotRequest()
        async throws
    {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-a"]
        ))
        let evidence = CodexGhostRepairSnapshotAdmissionEvidence(
            publishedSnapshotCount: 3,
            maximumSnapshotCount: 3,
            publishedBytes: 300,
            maximumTotalBytes: 4_294_967_296,
            prospectiveSnapshotBytes: 100,
            oldestPublishedAgeMilliseconds: 1_000,
            maximumPublishedAgeMilliseconds: 2_592_000_000,
            destinationRequiredBytes: 200,
            destinationAvailableBytes: 1_000,
            blockers: [.maximumSnapshotCountExceeded]
        )
        let coordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "must-not-run")]
        )
        let inspector = AppTestGhostRepairSnapshotAdmissionInspector(
            outcomes: [.blocked(
                evidence: evidence,
                message: evidence.userFacingBlockReason!
            )]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator,
            snapshotAdmissionInspector: inspector,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)
        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)

        guard case let .blocked(request, observedEvidence, admissionMessage) =
                model.ghostRepairSnapshotAdmissionState else {
            return XCTFail("Expected typed snapshot storage admission block")
        }
        XCTAssertEqual(request.targetThreadIDs, ["deleted-a"])
        XCTAssertEqual(observedEvidence, evidence)
        XCTAssertEqual(admissionMessage, evidence.userFacingBlockReason)
        guard case let .blocked(_, message) =
                model.ghostRepairSnapshotActionState else {
            return XCTFail("Quota must block before Create Snapshot is enabled")
        }
        XCTAssertTrue(message.contains("3 of 3"))
        XCTAssertEqual(
            model.ghostRepairSnapshotAdmissionOperatorDecision.kind,
            .stop
        )
        let readOnlyReport = try XCTUnwrap(
            model.ghostRepairSnapshotAdmissionReadOnlyReport
        )
        XCTAssertTrue(readOnlyReport.contains("operator_decision=STOP"))
        XCTAssertTrue(readOnlyReport.contains("snapshot_admission=blocked_"))

        await model.requestGhostRepairSnapshotAction(managerKeys: model.selection)

        let requests = await coordinator.requests
        let admissionRequests = await inspector.requests
        XCTAssertEqual(requests, [])
        XCTAssertEqual(admissionRequests.count, 1)
    }

    func testSnapshotReadinessDoesNotRequireOfficialExactAbsence() async {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-a"],
            exactAbsenceAvailable: false
        ))
        let coordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "snapshot-with-experimental-analysis")]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)
        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)

        guard case let .ready(review) = model.ghostRepairReadOnlyReviewState else {
            return XCTFail("Expected review with separated snapshot evidence")
        }
        XCTAssertFalse(review.officialEvidenceEligible)
        XCTAssertTrue(review.snapshotEvidenceEligible)
        guard case let .ready(request) = model.ghostRepairSnapshotActionState else {
            return XCTFail("Snapshot should be ready from complete omission evidence")
        }
        XCTAssertEqual(request.inventoryHash, "inventory-hash")
        XCTAssertFalse(request.repairMutationAuthority)
    }

    func testSnapshotBlockerMessageAndDiagnosticsExposeExactOperatingFailures()
        async
    {
        let executionGate = CodexGhostRepairExecutionGate(
            codexFullyExited: false,
            desktopOpenHandleCount: 2,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 1,
            capacitySufficient: false,
            desktopProcessEvidence: [
                .init(kind: .codexHelper, processCount: 2),
                .init(kind: .codexCrashReporter, processCount: 1),
                .init(kind: .chatGPTApplication, processCount: 1),
                .init(kind: .chatGPTCrashReporter, processCount: 4),
            ]
        )
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-a"],
            exactAbsenceAvailable: false,
            executionGate: executionGate
        ))
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator:
                AppTestGhostRepairSnapshotActionCoordinator(outcomes: []),
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        guard case let .ready(review) = model.ghostRepairReadOnlyReviewState else {
            return XCTFail("Expected a completed review with exact blockers")
        }
        XCTAssertFalse(review.officialEvidenceEligible)
        XCTAssertTrue(review.snapshotEvidenceEligible)
        XCTAssertEqual(
            review.executionGate.blockers,
            [
                .codexStillRunning,
                .desktopDatabaseOpen,
                .historyDatabaseOpen,
                .backupCapacityInsufficient,
            ]
        )
        guard case let .blocked(_, message) = model.ghostRepairSnapshotActionState else {
            return XCTFail("Expected exact snapshot operating blockers")
        }
        XCTAssertEqual(
            message,
            "Snapshot operating conditions are blocked: Codex helper process is still running (2); ChatGPT main application process is still running (1); codex-dev.db still has an open handle; Legacy codex-history-snapshots-dev.db still has an open handle; Snapshot capacity is insufficient."
        )

        let metadata = SessionManagerModel.ghostRepairReviewDiagnosticMetadata(
            targetThreadIDs: ["deleted-a"],
            review: review
        )
        XCTAssertEqual(metadata["official_evidence_eligible"], "false")
        XCTAssertEqual(metadata["snapshot_evidence_eligible"], "true")
        XCTAssertEqual(metadata["operational_gate_clear"], "false")
        XCTAssertEqual(
            metadata["operational_blockers"],
            "codexStillRunning,desktopDatabaseOpen,historyDatabaseOpen,backupCapacityInsufficient"
        )
        XCTAssertEqual(metadata["codex_fully_exited"], "false")
        XCTAssertEqual(
            metadata["desktop_process_evidence"],
            "codexHelper:2,codexCrashReporter:1,chatGPTApplication:1,chatGPTCrashReporter:4"
        )
        XCTAssertEqual(
            metadata["blocking_desktop_process_evidence"],
            "codexHelper:2,chatGPTApplication:1"
        )
        XCTAssertEqual(
            metadata["non_blocking_desktop_process_evidence"],
            "codexCrashReporter:1,chatGPTCrashReporter:4"
        )
        XCTAssertEqual(metadata["codex_application_process_count"], "0")
        XCTAssertEqual(metadata["codex_helper_process_count"], "2")
        XCTAssertEqual(metadata["codex_crash_reporter_process_count"], "1")
        XCTAssertEqual(metadata["chatgpt_application_process_count"], "1")
        XCTAssertEqual(metadata["chatgpt_helper_process_count"], "0")
        XCTAssertEqual(
            metadata["chatgpt_crash_reporter_process_count"],
            "4"
        )
        XCTAssertEqual(metadata["desktop_open_handle_count"], "2")
        XCTAssertEqual(metadata["summaries_open_handle_count"], "0")
        XCTAssertEqual(metadata["history_open_handle_count"], "1")
        XCTAssertEqual(metadata["state_open_handle_count"], "unavailable")
        XCTAssertEqual(
            metadata["thread_history_open_handle_count"],
            "unavailable"
        )
        XCTAssertEqual(metadata["open_handle_owner_evidence"], "unavailable")
        XCTAssertEqual(
            metadata["unique_open_handle_owner_process_count"],
            "unavailable"
        )
        XCTAssertEqual(metadata["snapshot_capacity_sufficient"], "false")
    }

    func testSnapshotOperatingPreflightIsExplicitAndPathRedacted() async {
        let gate = CodexGhostRepairExecutionGate(
            codexFullyExited: false,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            stateOpenHandleCount: 2,
            capacitySufficient: true,
            desktopProcessEvidence: [
                .init(kind: .chatGPTHelper, processCount: 3),
                .init(kind: .chatGPTCrashReporter, processCount: 4),
            ],
            openHandleOwnerEvidence: [
                .init(
                    databaseRole: .state,
                    processIdentifier: 801,
                    parentProcessIdentifier: 700,
                    processName: "codex",
                    executableName: "codex",
                    parentProcessName: "Electron",
                    processKind: nil,
                    fileDescriptorCount: 2
                ),
            ]
        )
        let source = AppTestGhostRepairOperatingGateSource(gate: gate)
        let model = makeModel(
            sessions: [],
            ghostRepairOperationalGateSource: source
        )

        XCTAssertEqual(model.ghostRepairOperatingPreflightState, .idle)
        let initialRequestCount = await source.requestCount()
        XCTAssertEqual(initialRequestCount, 0)

        await model.inspectGhostRepairOperatingConditions()

        guard case let .observed(observedGate, _) =
            model.ghostRepairOperatingPreflightState else {
            return XCTFail("Explicit preflight should expose exact evidence")
        }
        XCTAssertEqual(observedGate, gate)
        let finalRequestCount = await source.requestCount()
        XCTAssertEqual(finalRequestCount, 1)
        let metadata = SessionManagerModel
            .ghostRepairOperatingGateDiagnosticMetadata(observedGate)
        XCTAssertEqual(
            metadata["desktop_process_evidence"],
            "chatGPTHelper:3,chatGPTCrashReporter:4"
        )
        XCTAssertEqual(metadata["chatgpt_helper_process_count"], "3")
        XCTAssertEqual(
            metadata["non_blocking_desktop_process_evidence"],
            "chatGPTCrashReporter:4"
        )
        XCTAssertEqual(
            metadata["chatgpt_crash_reporter_process_count"],
            "4"
        )
        XCTAssertEqual(
            metadata["open_handle_owner_evidence"],
            "state:pid=801:ppid=700:name=codex:executable=codex:parent_name=Electron:kind=unclassified:fd=2"
        )
        XCTAssertEqual(
            metadata["unique_open_handle_owner_process_count"],
            "1"
        )
        XCTAssertFalse(metadata.values.joined().contains("/Applications"))
        XCTAssertFalse(metadata.values.joined().contains("ChatGPT.app"))
    }

    func testSnapshotOperatingPreflightAllowsCrashReportersWithoutDatabaseHandles()
        async
    {
        let gate = CodexGhostRepairExecutionGate(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: true,
            desktopProcessEvidence: [
                .init(kind: .codexCrashReporter, processCount: 2),
                .init(kind: .chatGPTCrashReporter, processCount: 4),
            ]
        )
        let source = AppTestGhostRepairOperatingGateSource(gate: gate)
        let model = makeModel(
            sessions: [],
            ghostRepairOperationalGateSource: source
        )

        await model.inspectGhostRepairOperatingConditions()

        guard case let .observed(observedGate, _) =
            model.ghostRepairOperatingPreflightState else {
            return XCTFail("Crash-reporter-only evidence should be observable")
        }
        XCTAssertTrue(observedGate.isClear)
        XCTAssertEqual(observedGate.userFacingBlockerDescriptions, [])
        XCTAssertEqual(
            observedGate.nonBlockingDesktopProcessEvidence,
            gate.desktopProcessEvidence
        )
        let metadata = SessionManagerModel
            .ghostRepairOperatingGateDiagnosticMetadata(observedGate)
        XCTAssertEqual(metadata["operational_gate_clear"], "true")
        XCTAssertEqual(metadata["operational_blockers"], "none")
        XCTAssertEqual(
            metadata["non_blocking_desktop_process_evidence"],
            "codexCrashReporter:2,chatGPTCrashReporter:4"
        )
    }

    func testSnapshotOperatingPreflightPreventsReentry() async {
        let source = AppTestSuspendingGhostRepairOperatingGateSource()
        let model = makeModel(
            sessions: [],
            ghostRepairOperationalGateSource: source
        )

        let first = Task { @MainActor in
            await model.inspectGhostRepairOperatingConditions()
        }
        await source.waitUntilRequested()
        await model.inspectGhostRepairOperatingConditions()

        let requestCount = await source.requestCount()
        XCTAssertEqual(requestCount, 1)
        await source.finish(with: .clearForPreflightTests)
        await first.value
        guard case let .observed(gate, _) =
            model.ghostRepairOperatingPreflightState else {
            return XCTFail("The first explicit preflight should complete")
        }
        XCTAssertTrue(gate.isClear)
    }

    func testBulkPreparationNeedsNoSelectionOrSnapshotUUIDAndScansOnce()
        async
    {
        let targetIDs = (0..<12).map {
            String(format: "019f-auto-bulk-%02d", $0)
        }
        let witnessIDs = Array(targetIDs.prefix(10))
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: witnessIDs,
                executionGate: gate
            )
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [
                .succeeded(
                    reference: AppTestGhostRepairBulkFixture.snapshotReference
                )
            ]
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let initialDiscovery = AppTestInitialWitnessDiscovery(
            outcome: .unavailable(message: "must not be called")
        )
        var persistedValues: [Bool] = []
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            bulkReconciliationPreferenceWriter: {
                persistedValues.append($0)
            },
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            initialWitnessDiscovery: initialDiscovery,
            bulkInventoryCoordinator: bulkCoordinator
        )
        model.sessionRows = targetIDs.reversed().map {
            makeDeletedPresentation(nativeID: $0)
        }
        model.selection = []
        model.ghostRepairBulkSnapshotReferenceDraft = ""

        XCTAssertFalse(model.isGhostRepairBulkReconciliationEnabled)
        XCTAssertTrue(model.setGhostRepairBulkReconciliationEnabled(true))
        model.presentGhostRepairBulkInventory()
        await model.prepareGhostRepairBulkInventory()

        XCTAssertEqual(persistedValues, [true])
        XCTAssertTrue(model.isGhostRepairBulkInventoryPresented)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(
            model.ghostRepairBulkPreparationState,
            .ready(
                snapshotReference:
                    AppTestGhostRepairBulkFixture.snapshotReference
            )
        )
        XCTAssertEqual(
            model.ghostRepairBulkInventoryState,
            .ready(AppTestGhostRepairBulkFixture.inventory)
        )
        let safetyRequests = await safetySource.requests
        let snapshotRequests = await snapshotCoordinator.requests
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(safetyRequests, [witnessIDs])
        XCTAssertEqual(
            snapshotRequests.map(\.targetThreadIDs),
            [witnessIDs]
        )
        XCTAssertEqual(bulkRequestCount, 1)
        let initialDiscoveryCount = await initialDiscovery.requestCount()
        XCTAssertEqual(initialDiscoveryCount, 0)
    }

    func testShippingDirectScanSkipsSnapshotPipelineAndSelectsEligibleItems()
        async
    {
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: [AppTestGhostRepairBulkFixture.eligibleA],
                executionGate: gate
            )
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.unavailable(message: "must not be called")]
        )
        let initialDiscovery = AppTestInitialWitnessDiscovery(
            outcome: .unavailable(message: "must not be called")
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory,
            directScan: true
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            initialWitnessDiscovery: initialDiscovery,
            bulkInventoryCoordinator: bulkCoordinator
        )

        XCTAssertTrue(model.setGhostRepairBulkReconciliationEnabled(true))
        await model.prepareGhostRepairBulkInventory()

        guard case let .ready(inventory) =
                model.ghostRepairBulkInventoryState else {
            return XCTFail("Expected direct scan inventory")
        }
        XCTAssertNotNil(UUID(uuidString: inventory.snapshotReference))
        XCTAssertEqual(
            model.ghostRepairBulkSelection,
            Set([
                AppTestGhostRepairBulkFixture.eligibleA,
                AppTestGhostRepairBulkFixture.eligibleB,
            ])
        )
        let bulkRequestCount = await bulkCoordinator.requestCount()
        let resumeRequests = await bulkCoordinator.resumeRequests()
        let snapshotRequests = await snapshotCoordinator.requests
        let discoveryRequestCount = await initialDiscovery.requestCount()
        let safetyRequests = await safetySource.requests
        XCTAssertEqual(bulkRequestCount, 1)
        XCTAssertTrue(resumeRequests.isEmpty)
        XCTAssertTrue(snapshotRequests.isEmpty)
        XCTAssertEqual(discoveryRequestCount, 0)
        XCTAssertTrue(safetyRequests.isEmpty)
    }

    func testBulkPreparationResumesMatchingPublishedSnapshotWithoutCreatingAnother()
        async
    {
        let targetIDs = (0..<10).map {
            String(format: "019f-auto-resume-%02d", $0)
        }
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: targetIDs,
                executionGate: gate
            )
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: []
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory,
            resumableSnapshotReference:
                AppTestGhostRepairBulkFixture.snapshotReference
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )
        model.sessionRows = targetIDs.map {
            makeDeletedPresentation(nativeID: $0)
        }

        await model.prepareGhostRepairBulkInventory()

        XCTAssertEqual(
            model.ghostRepairBulkPreparationState,
            .ready(
                snapshotReference:
                    AppTestGhostRepairBulkFixture.snapshotReference
            )
        )
        let snapshotRequestCount = await snapshotCoordinator.requests.count
        let resumeRequests = await bulkCoordinator.resumeRequests()
        let inventoryRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(snapshotRequestCount, 0)
        XCTAssertEqual(resumeRequests, [targetIDs])
        XCTAssertEqual(inventoryRequestCount, 1)
    }

    func testBlockedAdmissionAllowsFreshExplicitPreparationReview() async {
        let witnessID = "deleted-review-refresh"
        let firstObservedAt = Date(timeIntervalSince1970: 1_000)
        let secondObservedAt = Date(timeIntervalSince1970: 2_000)
        let safetySource = AppTestGhostRepairSafetySource(snapshots: [
            makeGhostRepairSnapshot(
                targetIDs: [witnessID],
                observedAt: firstObservedAt
            ),
            makeGhostRepairSnapshot(
                targetIDs: [witnessID],
                observedAt: secondObservedAt
            ),
        ])
        let blockedEvidence = CodexGhostRepairSnapshotAdmissionEvidence(
            publishedSnapshotCount: 3,
            maximumSnapshotCount: 3,
            publishedBytes: 300,
            maximumTotalBytes: 4_294_967_296,
            prospectiveSnapshotBytes: 100,
            oldestPublishedAgeMilliseconds: 1_000,
            maximumPublishedAgeMilliseconds: 2_592_000_000,
            destinationRequiredBytes: 200,
            destinationAvailableBytes: 1_000,
            blockers: [.maximumSnapshotCountExceeded]
        )
        let admissionInspector = AppTestGhostRepairSnapshotAdmissionInspector(
            outcomes: [
                .blocked(evidence: blockedEvidence, message: "blocked once"),
                .blocked(evidence: blockedEvidence, message: "blocked twice"),
            ]
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "must-not-run")]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            snapshotAdmissionInspector: admissionInspector,
            bulkInventoryCoordinator:
                AppTestGhostRepairBulkInventoryCoordinator(),
            bulkReconciliationEnabled: true
        )
        model.sessionRows = [makeDeletedPresentation(nativeID: witnessID)]

        await model.prepareGhostRepairBulkInventory()
        await model.prepareGhostRepairBulkInventory()

        let safetyRequests = await safetySource.requests
        let admissionRequests = await admissionInspector.requests
        let snapshotRequests = await snapshotCoordinator.requests
        XCTAssertEqual(safetyRequests, [[witnessID], [witnessID]])
        XCTAssertEqual(admissionRequests.count, 2)
        XCTAssertEqual(
            admissionRequests.map(\.reviewObservedAt),
            [firstObservedAt, secondObservedAt]
        )
        XCTAssertTrue(snapshotRequests.isEmpty)
    }

    func testBulkPreparationWithoutDeletedWitnessesStopsBeforeAnyEffect()
        async
    {
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: ["unused"],
                executionGate: gate
            )
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: []
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator()
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )

        await model.prepareGhostRepairBulkInventory()

        guard case let .blocked(message) =
                model.ghostRepairBulkPreparationState else {
            return XCTFail("Expected a visible preparation blocker")
        }
        XCTAssertTrue(message.contains("initial Snapshot witness discovery is unavailable"))
        let safetyRequests = await safetySource.requests
        let snapshotRequestCount = await snapshotCoordinator.requests.count
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(safetyRequests, [])
        XCTAssertEqual(snapshotRequestCount, 0)
        XCTAssertEqual(bulkRequestCount, 0)
    }

    func testBulkPreparationDiscoversInitialWitnessesWithoutManagerRowsOrSelection()
        async
    {
        let witnessIDs = [
            "019f0000-0000-4000-8000-000000000001",
            "019f0000-0000-4000-8000-000000000002",
        ]
        let evidence = makeInitialWitnessEvidence(threadIDs: witnessIDs)
        let discovery = AppTestInitialWitnessDiscovery(
            outcome: .discovered(evidence)
        )
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: witnessIDs,
                executionGate: gate,
                runtimeVersion: evidence.runtimeVersion
            )
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [
                .succeeded(
                    reference: AppTestGhostRepairBulkFixture.snapshotReference
                ),
            ]
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            initialWitnessDiscovery: discovery,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )
        model.sessionRows = []
        model.selection = ["unrelated-user-selection"]

        await model.prepareGhostRepairBulkInventory()

        let discoveryCount = await discovery.requestCount()
        let safetyRequests = await safetySource.requests
        XCTAssertEqual(discoveryCount, 1)
        XCTAssertEqual(safetyRequests, [witnessIDs])
        let snapshotRequests = await snapshotCoordinator.requests
        XCTAssertEqual(snapshotRequests.count, 1)
        XCTAssertEqual(snapshotRequests[0].targetThreadIDs, witnessIDs)
        XCTAssertEqual(snapshotRequests[0].initialWitnessEvidence, evidence)
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(bulkRequestCount, 1)
        XCTAssertEqual(
            model.ghostRepairBulkPreparationState,
            .ready(
                snapshotReference:
                    AppTestGhostRepairBulkFixture.snapshotReference
            )
        )
        XCTAssertEqual(model.selection, ["unrelated-user-selection"])
        XCTAssertTrue(model.sessionRows.isEmpty)
    }

    func testBulkPreparationEmptyInitialDiscoveryHasNoDownstreamEffects()
        async
    {
        let discovery = AppTestInitialWitnessDiscovery(
            outcome: .empty(
                runtimeVersion: "0.153.4",
                sourceLayoutIdentifier:
                    "codex-cli-0.153.4-desktop-v34-20-member-v1",
                sourceFingerprintHash:
                    "sha256:" + String(repeating: "b", count: 64)
            )
        )
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(targetIDs: ["unused"])
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: []
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator()
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            initialWitnessDiscovery: discovery,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )

        await model.prepareGhostRepairBulkInventory()

        let discoveryCount = await discovery.requestCount()
        let safetyRequests = await safetySource.requests
        let snapshotRequestCount = await snapshotCoordinator.requests.count
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(discoveryCount, 1)
        XCTAssertEqual(safetyRequests, [])
        XCTAssertEqual(snapshotRequestCount, 0)
        XCTAssertEqual(bulkRequestCount, 0)
        guard case let .blocked(message) =
                model.ghostRepairBulkPreparationState else {
            return XCTFail("Empty discovery must visibly stop preparation")
        }
        XCTAssertTrue(message.contains("no eligible Snapshot witness"))
    }

    func testBulkPreparationUnavailableInitialDiscoveryHasNoDownstreamEffects()
        async
    {
        let discovery = AppTestInitialWitnessDiscovery(
            outcome: .unavailable(message: "deterministic unavailable")
        )
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(targetIDs: ["unused"])
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: []
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator()
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            initialWitnessDiscovery: discovery,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )

        await model.prepareGhostRepairBulkInventory()

        let discoveryCount = await discovery.requestCount()
        let safetyRequests = await safetySource.requests
        let snapshotRequestCount = await snapshotCoordinator.requests.count
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(discoveryCount, 1)
        XCTAssertEqual(safetyRequests, [])
        XCTAssertEqual(snapshotRequestCount, 0)
        XCTAssertEqual(bulkRequestCount, 0)
    }

    func testBulkPreparationRejectsNonCanonicalOrOverLimitInitialWitnesses()
        async
    {
        let invalidSets = [
            ["not-a-canonical-uuid"],
            (0..<11).map {
                String(format: "019f0000-0000-4000-8000-%012d", $0)
            },
        ]
        for invalidIDs in invalidSets {
            let discovery = AppTestInitialWitnessDiscovery(
                outcome: .discovered(
                    makeInitialWitnessEvidence(threadIDs: invalidIDs)
                )
            )
            let safetySource = AppTestGhostRepairSafetySource(
                snapshot: makeGhostRepairSnapshot(targetIDs: invalidIDs)
            )
            let snapshotCoordinator =
                AppTestGhostRepairSnapshotActionCoordinator(outcomes: [])
            let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator()
            let model = makeModel(
                sessions: [],
                ghostRepairSource: safetySource,
                ghostRepairSnapshotCoordinator: snapshotCoordinator,
                initialWitnessDiscovery: discovery,
                bulkInventoryCoordinator: bulkCoordinator,
                bulkReconciliationEnabled: true
            )

            await model.prepareGhostRepairBulkInventory()

            let safetyRequests = await safetySource.requests
            let snapshotRequestCount = await snapshotCoordinator.requests.count
            let bulkRequestCount = await bulkCoordinator.requestCount()
            XCTAssertEqual(safetyRequests, [])
            XCTAssertEqual(snapshotRequestCount, 0)
            XCTAssertEqual(bulkRequestCount, 0)
        }
    }

    func testBulkPreparationInitialDiscoveryIsSingleFlightAndDisabledLateOutcomeIsIgnored()
        async
    {
        let witnessID = "019f0000-0000-4000-8000-000000000003"
        let discovery = AppTestSuspendingInitialWitnessDiscovery()
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "must-not-run")]
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator()
        let model = makeModel(
            sessions: [],
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            initialWitnessDiscovery: discovery,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )

        let first = Task { @MainActor in
            await model.prepareGhostRepairBulkInventory()
        }
        await discovery.waitUntilRequested()
        await model.prepareGhostRepairBulkInventory()
        let inFlightDiscoveryCount = await discovery.requestCount()
        XCTAssertEqual(inFlightDiscoveryCount, 1)
        XCTAssertTrue(model.setGhostRepairBulkReconciliationEnabled(false))
        await discovery.finish(
            with: .discovered(
                makeInitialWitnessEvidence(threadIDs: [witnessID])
            )
        )
        await first.value

        let finalDiscoveryCount = await discovery.requestCount()
        let snapshotRequestCount = await snapshotCoordinator.requests.count
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(finalDiscoveryCount, 1)
        XCTAssertEqual(snapshotRequestCount, 0)
        XCTAssertEqual(bulkRequestCount, 0)
        XCTAssertEqual(model.ghostRepairBulkInventoryState, .disabled)
    }

    func testBulkPreparationRejectsInitialWitnessRuntimeDriftBeforeAdmission()
        async
    {
        let witnessID = "019f0000-0000-4000-8000-000000000004"
        let evidence = makeInitialWitnessEvidence(threadIDs: [witnessID])
        let discovery = AppTestInitialWitnessDiscovery(
            outcome: .discovered(evidence)
        )
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: [witnessID],
                runtimeVersion: "0.153.3"
            )
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "must-not-run")]
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator()
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            initialWitnessDiscovery: discovery,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )

        await model.prepareGhostRepairBulkInventory()

        let snapshotRequestCount = await snapshotCoordinator.requests.count
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(snapshotRequestCount, 0)
        XCTAssertEqual(bulkRequestCount, 0)
        guard case .blocked = model.ghostRepairBulkPreparationState else {
            return XCTFail("Runtime drift must stop before Admission")
        }
    }

    func testBulkPreparationRejectsPositiveManagerStateDuringInitialWitnessReview()
        async
    {
        let witnessID = "019f0000-0000-4000-8000-000000000005"
        let evidence = makeInitialWitnessEvidence(threadIDs: [witnessID])
        let discovery = AppTestInitialWitnessDiscovery(
            outcome: .discovered(evidence)
        )
        let safetySource = AppTestSuspendingGhostRepairSafetySource()
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "must-not-run")]
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator()
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            initialWitnessDiscovery: discovery,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )
        let preparation = Task { @MainActor in
            await model.prepareGhostRepairBulkInventory()
        }
        await safetySource.waitUntilRequested()
        model.sessionRows = [
            makeSession(nativeID: witnessID, state: .active),
        ].map(
            SessionPresentation.init(session:)
        )
        await safetySource.finish(
            with: makeGhostRepairSnapshot(
                targetIDs: [witnessID],
                runtimeVersion: evidence.runtimeVersion
            )
        )
        await preparation.value

        let snapshotRequestCount = await snapshotCoordinator.requests.count
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(snapshotRequestCount, 0)
        XCTAssertEqual(bulkRequestCount, 0)
        guard case .blocked = model.ghostRepairBulkPreparationState else {
            return XCTFail("Positive manager state must stop the frozen witness")
        }
    }

    func testBulkPreparationRetainsSnapshotOutcomeWhenInitialWitnessDriftsDuringEffect()
        async
    {
        let witnessID = "019f0000-0000-4000-8000-000000000006"
        let evidence = makeInitialWitnessEvidence(threadIDs: [witnessID])
        let discovery = AppTestInitialWitnessDiscovery(
            outcome: .discovered(evidence)
        )
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: [witnessID],
                runtimeVersion: evidence.runtimeVersion
            )
        )
        let snapshotCoordinator =
            AppTestSuspendingGhostRepairSnapshotActionCoordinator()
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator()
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            initialWitnessDiscovery: discovery,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )
        let reference = AppTestGhostRepairBulkFixture.snapshotReference
        let preparation = Task { @MainActor in
            await model.prepareGhostRepairBulkInventory()
        }
        await snapshotCoordinator.waitUntilRequested()
        model.sessionRows = [
            makeSession(nativeID: witnessID, state: .active),
        ].map(
            SessionPresentation.init(session:)
        )
        await snapshotCoordinator.finish(with: .succeeded(reference: reference))
        await preparation.value

        guard case let .succeeded(request, observedReference) =
                model.ghostRepairSnapshotActionState else {
            return XCTFail("Performed Snapshot outcome must remain visible")
        }
        XCTAssertEqual(request.initialWitnessEvidence, evidence)
        XCTAssertEqual(observedReference, reference)
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(bulkRequestCount, 0)
        guard case .blocked = model.ghostRepairBulkPreparationState else {
            return XCTFail("Post-effect target drift must block downstream scan")
        }
    }

    func testBulkPreparationBlocksWhenFrozenWitnessRowsDriftDuringSafetyReview()
        async
    {
        let witnessIDs = ["019f-drift-a", "019f-drift-b"]
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let safetySource = AppTestSuspendingGhostRepairSafetySource()
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [
                .succeeded(reference: AppTestGhostRepairBulkFixture.snapshotReference)
            ]
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )
        model.sessionRows = witnessIDs.map {
            makeDeletedPresentation(nativeID: $0)
        }
        model.selection = []

        let preparation = Task { @MainActor in
            await model.prepareGhostRepairBulkInventory()
        }
        await safetySource.waitUntilRequested()
        model.sessionRows.removeAll { $0.nativeID == witnessIDs[1] }
        await safetySource.finish(
            with: makeGhostRepairSnapshot(
                targetIDs: witnessIDs,
                executionGate: gate
            )
        )
        await preparation.value

        guard case let .blocked(message) =
                model.ghostRepairBulkPreparationState else {
            return XCTFail("Frozen witness drift must block the whole preparation")
        }
        XCTAssertTrue(
            message.contains(
                "frozen initial witness IDs and provenance"
            )
        )
        XCTAssertTrue(model.selection.isEmpty)
        let safetyRequests = await safetySource.requests()
        let snapshotRequestCount = await snapshotCoordinator.requests.count
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(safetyRequests, [witnessIDs])
        XCTAssertEqual(snapshotRequestCount, 0)
        XCTAssertEqual(bulkRequestCount, 0)
    }

    func testReopeningBulkSheetDoesNotReuseBlockedPreparationState() async {
        let witnessID = "019f-reopen-witness"
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: [witnessID],
                executionGate: gate
            )
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [
                .succeeded(reference: AppTestGhostRepairBulkFixture.snapshotReference)
            ]
        )
        let bulkCoordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            bulkInventoryCoordinator: bulkCoordinator,
            bulkReconciliationEnabled: true
        )
        model.selection = []

        model.presentGhostRepairBulkInventory()
        await model.prepareGhostRepairBulkInventory()
        guard case .blocked = model.ghostRepairBulkPreparationState else {
            return XCTFail("The witness-free preparation should be blocked")
        }

        XCTAssertTrue(model.setGhostRepairBulkInventoryPresented(false))
        model.sessionRows = [makeDeletedPresentation(nativeID: witnessID)]
        model.presentGhostRepairBulkInventory()
        await model.prepareGhostRepairBulkInventory()

        XCTAssertTrue(model.isGhostRepairBulkInventoryPresented)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(
            model.ghostRepairBulkPreparationState,
            .ready(
                snapshotReference:
                    AppTestGhostRepairBulkFixture.snapshotReference
            )
        )
        let safetyRequests = await safetySource.requests
        let snapshotRequestCount = await snapshotCoordinator.requests.count
        let bulkRequestCount = await bulkCoordinator.requestCount()
        XCTAssertEqual(safetyRequests, [[witnessID]])
        XCTAssertEqual(snapshotRequestCount, 1)
        XCTAssertEqual(bulkRequestCount, 1)
    }

    func testSimplifiedCleanupConfirmsOnceWaitsForShutdownAndExecutes148Items() async throws {
        let (model, inventory, receipt, repair) = makeSimplifiedCleanupFixture()
        await model.prepareGhostRepairBulkInventory()
        let frozenScan = try XCTUnwrap(model.ghostRepairBulkInventory)
        let selected = model.ghostRepairBulkSelection
        XCTAssertEqual(selected.count, 148)

        // Opening/reviewing the list alone grants no cleanup authority.
        await model.continueGhostCleanupAfterShutdown()
        let initialReviews = await repair.reviewRequestCount()
        XCTAssertEqual(initialReviews, 0)

        await model.confirmGhostCleanup(selectedIDs: selected, inventoryDigest: inventory.inventoryDigest)
        XCTAssertEqual(model.ghostRepairCleanupState, .awaitingShutdown)
        XCTAssertEqual(model.ghostRepairBulkConfirmationPhraseDraft, "")
        model.setGhostRepairManualReviewEnabled(true)
        XCTAssertEqual(model.ghostRepairBulkInventory?.inventoryDigest, inventory.inventoryDigest)
        XCTAssertFalse(model.ghostRepairBulkInventory?.manualReviewEnabled ?? true)
        let reviewsBeforeShutdown = await repair.reviewRequestCount()
        let executionsBeforeShutdown = await repair.executionRequestCount()
        XCTAssertEqual(reviewsBeforeShutdown, 0)
        XCTAssertEqual(executionsBeforeShutdown, 0)
        model.clearGhostRepairBulkSelection()
        XCTAssertEqual(model.ghostRepairBulkSelection, selected)
        await model.confirmGhostCleanup(selectedIDs: selected, inventoryDigest: inventory.inventoryDigest)

        async let first: Void = model.continueGhostCleanupAfterShutdown()
        async let duplicate: Void = model.continueGhostCleanupAfterShutdown()
        _ = await (first, duplicate)
        XCTAssertEqual(model.ghostRepairCleanupState, .finished)
        guard case let .completed(report) = model.ghostRepairBulkRepairState else {
            return XCTFail("Expected automatic cleanup to produce its terminal report")
        }
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(Set(report.itemReports.map(\.threadID)), selected)
        XCTAssertEqual(report.itemReports.count, 148)
        XCTAssertEqual(Set(report.itemReports.map(\.category)), [.ordinary, .automation])
        XCTAssertEqual(model.ghostRepairBulkClearedThreadIDs, selected)
        XCTAssertTrue(model.ghostRepairBulkDisplayedSelection.isEmpty)
        XCTAssertEqual(model.ghostRepairBulkRemainingItems.count, inventory.items.count - selected.count)
        // The original confirmation evidence stays immutable; only display changes.
        XCTAssertEqual(model.ghostRepairBulkInventory, frozenScan)
        XCTAssertEqual(model.ghostRepairBulkSelection, selected)
        model.ghostRepairBulkSearchText = "eligible"
        model.isShowingSelectedGhostRepairBulkItemsOnly = true
        XCTAssertTrue(model.ghostRepairBulkVisibleItems.isEmpty)
        await model.continueGhostCleanupAfterShutdown()
        let receiptCount = await receipt.requestCount()
        let reviewCount = await repair.reviewRequestCount()
        let executionCount = await repair.executionRequestCount()
        XCTAssertEqual(receiptCount, 1)
        XCTAssertEqual(reviewCount, 1)
        XCTAssertEqual(executionCount, 1)
    }

    func testSimplifiedCleanupRejectsChangedConsentAndStopsOnBlockedChecks() async {
        let (model, inventory, receipt, repair) = makeSimplifiedCleanupFixture(reviewBlocked: "Codex is still running.")
        await model.prepareGhostRepairBulkInventory()
        let selected = model.ghostRepairBulkSelection
        await model.confirmGhostCleanup(selectedIDs: selected, inventoryDigest: "changed-scan")
        await model.confirmGhostCleanup(selectedIDs: Set(selected.dropFirst()), inventoryDigest: inventory.inventoryDigest)
        let initialReceipts = await receipt.requestCount()
        XCTAssertEqual(initialReceipts, 0)
        XCTAssertEqual(model.ghostRepairCleanupState, .idle)
        await model.confirmGhostCleanup(selectedIDs: selected, inventoryDigest: inventory.inventoryDigest)
        await model.continueGhostCleanupAfterShutdown()
        XCTAssertEqual(model.ghostRepairCleanupState, .stopped("Codex is still running."))
        await model.continueGhostCleanupAfterShutdown()
        let reviews = await repair.reviewRequestCount()
        let executions = await repair.executionRequestCount()
        XCTAssertEqual(reviews, 1)
        XCTAssertEqual(executions, 0)
    }

    func testSimplifiedCleanupNeverReplaysUnknownExecution() async {
        let (model, inventory, _, repair) = makeSimplifiedCleanupFixture(executionUnknown: true)
        await model.prepareGhostRepairBulkInventory()
        await model.confirmGhostCleanup(selectedIDs: model.ghostRepairBulkSelection, inventoryDigest: inventory.inventoryDigest)
        await model.continueGhostCleanupAfterShutdown()
        guard case .stopped = model.ghostRepairCleanupState,
              case .recoveryRequired = model.ghostRepairBulkRepairState else {
            return XCTFail("Unknown execution must remain stopped for readback")
        }
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        XCTAssertTrue(model.ghostRepairBulkClearedThreadIDs.isEmpty)
        XCTAssertEqual(model.ghostRepairBulkRemainingItems, inventory.items)
        XCTAssertEqual(model.ghostRepairBulkDisplayedSelection, model.ghostRepairBulkSelection)
        await model.continueGhostCleanupAfterShutdown()
        let executions = await repair.executionRequestCount()
        XCTAssertEqual(executions, 1)
    }

    func testShutdownGateAllowsExplicitRecheckWithoutChangingConfirmedBatch() async throws {
        let (model, inventory, receipt, repair) = makeSimplifiedCleanupFixture()
        await repair.setShutdownBlocked(true)
        await model.prepareGhostRepairBulkInventory()
        let selected = model.ghostRepairBulkSelection
        await model.confirmGhostCleanup(selectedIDs: selected, inventoryDigest: inventory.inventoryDigest)
        let confirmed = try XCTUnwrap(model.ghostRepairBulkConfirmationReceipt)
        await model.continueGhostCleanupAfterShutdown()
        XCTAssertEqual(model.ghostRepairCleanupState, .awaitingShutdown)
        XCTAssertNil(model.ghostRepairBulkFinalReviewBlockedReason)
        XCTAssertEqual(model.ghostRepairBulkConfirmationReceipt, confirmed)
        // A second acknowledgement while still occupied does not execute or re-confirm.
        await model.continueGhostCleanupAfterShutdown()
        XCTAssertEqual(model.ghostRepairCleanupState, .awaitingShutdown)
        let before = await repair.executionRequestCount()
        XCTAssertEqual(before, 0)
        model.clearGhostRepairBulkSelection()
        XCTAssertEqual(model.ghostRepairBulkSelection, selected)
        await repair.setShutdownBlocked(false)
        async let first: Void = model.continueGhostCleanupAfterShutdown()
        async let duplicate: Void = model.continueGhostCleanupAfterShutdown()
        _ = await (first, duplicate)
        XCTAssertEqual(model.ghostRepairCleanupState, .finished)
        XCTAssertEqual(model.ghostRepairBulkConfirmationReceipt, confirmed)
        let receipts = await receipt.requestCount()
        let reviews = await repair.reviewRequestCount()
        let executions = await repair.executionRequestCount()
        XCTAssertEqual(receipts, 1)
        XCTAssertEqual(reviews, 3)
        XCTAssertEqual(executions, 1)
    }

    func testDeleteHandoffContinuesSameScopeAfterShutdownGateClears() async throws {
        let f = try makeIntegratedDeleteFixture(selectedCount: 1)
        await f.repair.setShutdownBlocked(true)
        await f.model.continueFreshNativeDeleteCleanup(
            report: f.report, confirmedPreviewID: f.report.previewID,
            confirmedNativeSessionIDs: f.report.items.map(\.nativeSessionID))
        XCTAssertEqual(f.model.ghostRepairCleanupState, .awaitingShutdown)
        let confirmed = try XCTUnwrap(f.model.ghostRepairBulkConfirmationReceipt)
        XCTAssertFalse(f.model.canStartNewGhostRepairBulkPreparation)
        guard case .inventoryReady = f.model.nativeDeleteDesktopCleanupState else {
            return XCTFail("Keep the exact unbound handoff while awaiting shutdown")
        }
        await f.repair.setShutdownBlocked(false)
        await f.model.continueGhostCleanupAfterShutdown()
        XCTAssertEqual(f.model.ghostRepairCleanupState, .finished)
        XCTAssertEqual(f.model.ghostRepairBulkConfirmationReceipt, confirmed)
        XCTAssertEqual(f.model.ghostRepairBulkSelection, Set(f.report.items.map(\.nativeSessionID)))
        XCTAssertTrue(f.model.nativeDeleteDesktopCleanupVerified(reportID: f.report.id))
        let receipts = await f.receipt.requestCount()
        let executions = await f.repair.executionRequestCount()
        XCTAssertEqual(receipts, 1)
        XCTAssertEqual(executions, 1)
    }

    func testSimplifiedCleanupDoesNotConfirmStaleEvidenceAfterSaveFailure() async {
        let (model, inventory, receipt, repair) = makeSimplifiedCleanupFixture(failAfterFirstSave: true)
        await model.prepareGhostRepairBulkInventory()
        await model.buildGhostRepairBulkPreview()
        guard case .ready = model.ghostRepairBulkConfirmationChallengeState else {
            return XCTFail("Expected previously saved evidence")
        }
        await model.confirmGhostCleanup(selectedIDs: model.ghostRepairBulkSelection, inventoryDigest: inventory.inventoryDigest)
        guard case .stopped = model.ghostRepairCleanupState else {
            return XCTFail("A failed fresh save must not reuse the prior challenge")
        }
        let receipts = await receipt.requestCount()
        let executions = await repair.executionRequestCount()
        XCTAssertEqual(receipts, 0)
        XCTAssertEqual(executions, 0)
    }

    func testCleanupDisplayKeepsUnselectedRowsAndDoesNotCarrySuccessIntoNewScan() async {
        let (model, inventory, _, _) = makeSimplifiedCleanupFixture()
        await model.prepareGhostRepairBulkInventory()
        model.clearGhostRepairBulkSelection()
        let selected = Set(inventory.eligibleThreadIDs.prefix(2))
        for id in selected { model.setGhostRepairBulkItemSelected(id, isSelected: true) }
        model.isShowingSelectedGhostRepairBulkItemsOnly = true
        await model.confirmGhostCleanup(selectedIDs: selected, inventoryDigest: inventory.inventoryDigest)
        await model.continueGhostCleanupAfterShutdown()
        XCTAssertEqual(model.ghostRepairBulkClearedThreadIDs, selected)
        XCTAssertTrue(model.ghostRepairBulkDisplayedSelection.isEmpty)
        XCTAssertEqual(model.ghostRepairBulkVisibleItems.count,
                       inventory.items.filter { $0.disposition != .notGhost }.count - 2)
        XCTAssertTrue(Set(model.ghostRepairBulkVisibleItems.map(\.threadID)).isDisjoint(with: selected))
        XCTAssertEqual(model.ghostRepairBulkRemainingItems.filter(\.selectable).count, inventory.eligibleItemCount - 2)
        XCTAssertTrue(model.startNewGhostRepairBulkPreparation())
        XCTAssertNil(model.ghostRepairBulkCompletedScanReport)
        await model.prepareGhostRepairBulkInventory()
        XCTAssertTrue(model.ghostRepairBulkClearedThreadIDs.isEmpty)
        XCTAssertEqual(model.ghostRepairBulkRemainingItems, inventory.items)
    }

    func testGhostTitlesSupportDuplicateNameSearchAndRemainAvailableAfterCleanup() async {
        let base = AppTestGhostRepairBulkFixture.exact148Inventory
        let ids = Array(base.eligibleThreadIDs.prefix(2))
        let named = CodexGhostRepairBulkInventory(snapshotReference: base.snapshotReference,
            sourceLayoutIdentifier: base.sourceLayoutIdentifier, items: base.items,
            inventoryDigest: base.inventoryDigest,
            displayTitles: [ids[0]: "同名每週報告", ids[1]: "同名每週報告"])
        let (model, _, _, _) = makeSimplifiedCleanupFixture(inventoryOverride: named)
        await model.prepareGhostRepairBulkInventory()
        model.ghostRepairBulkSearchText = "每週報告"
        XCTAssertEqual(model.ghostRepairBulkVisibleItems.map(\.threadID), ids)
        XCTAssertNil(model.ghostRepairBulkDisplayTitle(for: base.eligibleThreadIDs[2]))
        model.clearGhostRepairBulkSelection()
        model.setGhostRepairBulkItemSelected(ids[0], isSelected: true)
        await model.confirmGhostCleanup(selectedIDs: [ids[0]], inventoryDigest: named.inventoryDigest)
        await model.continueGhostCleanupAfterShutdown()
        XCTAssertEqual(model.ghostRepairBulkClearedThreadIDs, [ids[0]])
        XCTAssertEqual(model.ghostRepairBulkVisibleItems.map(\.threadID), [ids[1]])
        XCTAssertEqual(model.ghostRepairBulkDisplayTitle(for: ids[0]), "同名每週報告")
        XCTAssertEqual(model.ghostRepairBulkDisplayTitle(for: ids[1]), "同名每週報告")
    }

    private func makeSimplifiedCleanupFixture(
        reviewBlocked: String? = nil,
        executionUnknown: Bool = false,
        failAfterFirstSave: Bool = false,
        inventoryOverride: CodexGhostRepairBulkInventory? = nil
    ) -> (SessionManagerModel, CodexGhostRepairBulkInventory,
          AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator,
          AppTestDynamicGhostRepairBulkRepairCoordinator) {
        let inventory = inventoryOverride ?? AppTestGhostRepairBulkFixture.exact148Inventory
        let store = AppTestGhostRepairBulkPreviewMemoryStore(failAfterFirstSave: failAfterFirstSave)
        let challenge = AppTestDynamicGhostRepairBulkConfirmationCoordinator(previewStore: store)
        let receipt = AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator(challengeCoordinator: challenge)
        let repair = AppTestDynamicGhostRepairBulkRepairCoordinator(
            previewStore: store, receiptCoordinator: receipt,
            reviewBlocked: reviewBlocked, executionUnknown: executionUnknown
        )
        let model = makeModel(
            sessions: [],
            bulkInventoryCoordinator: AppTestGhostRepairBulkInventoryCoordinator(inventory: inventory, directScan: true),
            bulkPreviewPersister: store,
            bulkPreviewReadbackCoordinator: store,
            bulkConfirmationChallengeCoordinator: challenge,
            bulkConfirmationReceiptCoordinator: receipt,
            bulkRepairCoordinator: repair,
            bulkReconciliationEnabled: true
        )
        return (model, inventory, receipt, repair)
    }

    func testFreshDeleteAutomaticallyCleansExactSuccessfulIDsWithPreferenceOff() async throws {
        let fixture = try makeIntegratedDeleteFixture(partial: true)
        await fixture.model.continueFreshNativeDeleteCleanup(
            report: fixture.report, confirmedPreviewID: fixture.report.previewID,
            confirmedNativeSessionIDs: fixture.report.items.map(\.nativeSessionID)
        )
        XCTAssertTrue(fixture.model.nativeDeleteDesktopCleanupVerified(reportID: fixture.report.id))
        XCTAssertEqual(fixture.model.ghostRepairCleanupState, .finished)
        XCTAssertEqual(fixture.model.ghostRepairBulkSelection, Set(AppTestGhostRepairBulkFixture.exact148Inventory.eligibleThreadIDs))
        XCTAssertFalse(fixture.model.isGhostRepairBulkReconciliationEnabled)
        XCTAssertEqual(fixture.model.latestNativeDeleteReport?.id, fixture.report.id)
        await fixture.model.continueFreshNativeDeleteCleanup(
            report: fixture.report, confirmedPreviewID: fixture.report.previewID,
            confirmedNativeSessionIDs: fixture.report.items.map(\.nativeSessionID)
        )
        let receipts = await fixture.receipt.requestCount()
        let executions = await fixture.repair.executionRequestCount()
        XCTAssertEqual(receipts, 1)
        XCTAssertEqual(executions, 1)
        fixture.model.finishNativeDeleteReport(reportID: fixture.report.id)
        XCTAssertEqual(fixture.model.nativeDeleteDesktopCleanupState, .idle)
        XCTAssertFalse(fixture.model.isGhostRepairBulkWorkflowEnabled)
    }

    func testFreshDeleteMixedClearAndGhostIDsKeepOneExactBatchWithoutReplay() async throws {
        let fixture = try makeIntegratedDeleteFixture(initiallyClearCount: 6)
        for _ in 0..<2 {
            await fixture.model.continueFreshNativeDeleteCleanup(
                report: fixture.report, confirmedPreviewID: fixture.report.previewID,
                confirmedNativeSessionIDs: fixture.report.items.map(\.nativeSessionID)
            )
        }
        XCTAssertTrue(fixture.model.nativeDeleteDesktopCleanupVerified(reportID: fixture.report.id),
                      fixture.model.nativeDeleteDesktopCleanupDetail(reportID: fixture.report.id))
        XCTAssertEqual(fixture.model.ghostRepairBulkSelection, Set(fixture.report.items.map(\.nativeSessionID)))
        guard case let .completed(report) = fixture.model.ghostRepairBulkRepairState else {
            return XCTFail("Expected the whole mixed batch's terminal report")
        }
        XCTAssertEqual(report.itemReports.count, 148)
        XCTAssertEqual(report.itemReports.filter { $0.outcome == .alreadyAbsent }.count, 6)
        XCTAssertFalse(fixture.model.isGhostRepairBulkReconciliationEnabled)
        let receipts = await fixture.receipt.requestCount()
        let executions = await fixture.repair.executionRequestCount()
        XCTAssertEqual(receipts, 1)
        XCTAssertEqual(executions, 1)
    }

    func testFreshDeleteKeepsCanonicalResultWhenCleanupShutdownCheckFails() async throws {
        let fixture = try makeIntegratedDeleteFixture(reviewBlocked: "Codex is still running.")
        await fixture.model.continueFreshNativeDeleteCleanup(
            report: fixture.report, confirmedPreviewID: fixture.report.previewID,
            confirmedNativeSessionIDs: fixture.report.items.map(\.nativeSessionID)
        )
        XCTAssertEqual(fixture.model.latestNativeDeleteReport?.id, fixture.report.id)
        XCTAssertFalse(fixture.model.nativeDeleteDesktopCleanupVerified(reportID: fixture.report.id))
        XCTAssertTrue(fixture.model.nativeDeleteDesktopCleanupDetail(reportID: fixture.report.id).contains("Codex is still running"))
        let executions = await fixture.repair.executionRequestCount()
        XCTAssertEqual(executions, 0)
    }

    func testSingleFreshDeleteCleansOnlyItsOwnIDAndReleasesAfterDismissal() async throws {
        let fixture = try makeIntegratedDeleteFixture(selectedCount: 1)
        await fixture.model.continueFreshNativeDeleteCleanup(
            report: fixture.report, confirmedPreviewID: fixture.report.previewID,
            confirmedNativeSessionIDs: fixture.report.items.map(\.nativeSessionID)
        )
        XCTAssertTrue(fixture.model.nativeDeleteDesktopCleanupVerified(reportID: fixture.report.id), fixture.model.nativeDeleteDesktopCleanupDetail(reportID: fixture.report.id))
        XCTAssertEqual(fixture.model.ghostRepairBulkSelection, Set(fixture.report.items.map(\.nativeSessionID)))
        fixture.model.presentQueuedNativeDeleteDesktopCleanup()
        XCTAssertEqual(fixture.model.nativeDeleteDesktopCleanupState, .idle)
        XCTAssertFalse(fixture.model.isGhostRepairBulkWorkflowEnabled)
    }

    func testFreshDeleteUnknownCleanupCannotAutomaticallyRetry() async throws {
        let fixture = try makeIntegratedDeleteFixture(executionUnknown: true)
        for _ in 0..<2 {
            await fixture.model.continueFreshNativeDeleteCleanup(
                report: fixture.report, confirmedPreviewID: fixture.report.previewID,
                confirmedNativeSessionIDs: fixture.report.items.map(\.nativeSessionID)
            )
        }
        XCTAssertFalse(fixture.model.nativeDeleteDesktopCleanupVerified(reportID: fixture.report.id))
        XCTAssertEqual(fixture.model.latestNativeDeleteReport?.id, fixture.report.id)
        let executions = await fixture.repair.executionRequestCount()
        XCTAssertEqual(executions, 1)
    }

    func testFreshDeleteNoResidueFinishesWithoutCreatingCleanupReceipt() async throws {
        let fixture = try makeIntegratedDeleteFixture(noResidue: true)
        await fixture.model.continueFreshNativeDeleteCleanup(
            report: fixture.report, confirmedPreviewID: fixture.report.previewID,
            confirmedNativeSessionIDs: fixture.report.items.map(\.nativeSessionID)
        )
        XCTAssertTrue(fixture.model.nativeDeleteDesktopCleanupVerified(reportID: fixture.report.id))
        let receipts = await fixture.receipt.requestCount()
        let executions = await fixture.repair.executionRequestCount()
        XCTAssertEqual(receipts, 0)
        XCTAssertEqual(executions, 0)
        fixture.model.finishNativeDeleteReport(reportID: fixture.report.id)
        XCTAssertEqual(fixture.model.nativeDeleteDesktopCleanupState, .idle)
        XCTAssertFalse(fixture.model.isGhostRepairBulkWorkflowEnabled)
        // Even after finishing, a stale canonical report grants no new consent.
        await fixture.model.continueFreshNativeDeleteCleanup(
            report: fixture.report, confirmedPreviewID: fixture.report.previewID,
            confirmedNativeSessionIDs: fixture.report.items.map(\.nativeSessionID)
        )
        XCTAssertEqual(fixture.model.nativeDeleteDesktopCleanupState, .idle)
    }

    func testFreshDeleteRejectsChangedConsentAndRecoveredReport() async throws {
        let fixture = try makeIntegratedDeleteFixture()
        await fixture.model.continueFreshNativeDeleteCleanup(
            report: fixture.report, confirmedPreviewID: UUID(),
            confirmedNativeSessionIDs: fixture.report.items.map(\.nativeSessionID)
        )
        await fixture.model.continueFreshNativeDeleteCleanup(
            report: fixture.report, confirmedPreviewID: fixture.report.previewID,
            confirmedNativeSessionIDs: Array(fixture.report.items.dropFirst().map(\.nativeSessionID))
        )
        let recovered = NativeDeleteReport(
            id: fixture.report.id, previewID: fixture.report.previewID,
            outcome: fixture.report.outcome, completedAt: fixture.report.completedAt,
            items: fixture.report.items, recoveredAfterInterruption: true
        )
        await fixture.model.continueFreshNativeDeleteCleanup(
            report: recovered, confirmedPreviewID: recovered.previewID,
            confirmedNativeSessionIDs: recovered.items.map(\.nativeSessionID)
        )
        XCTAssertEqual(fixture.model.nativeDeleteDesktopCleanupState, .idle)
        XCTAssertNil(fixture.model.nativeDeleteAutomaticCleanupReportID)
        let receipts = await fixture.receipt.requestCount()
        XCTAssertEqual(receipts, 0)
    }

    private func makeIntegratedDeleteFixture(
        partial: Bool = false, reviewBlocked: String? = nil,
        executionUnknown: Bool = false, noResidue: Bool = false,
        selectedCount: Int = 148, initiallyClearCount: Int = 0
    ) throws -> (model: SessionManagerModel, report: NativeDeleteReport,
                 receipt: AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator,
                 repair: AppTestDynamicGhostRepairBulkRepairCoordinator) {
        let base = AppTestGhostRepairBulkFixture.exact148Inventory
        let initiallyClearIDs = Set(base.items.filter { $0.category == .ordinary }
            .prefix(initiallyClearCount).map(\.threadID))
        let inventory = CodexGhostRepairBulkInventory(
            snapshotReference: base.snapshotReference, sourceLayoutIdentifier: base.sourceLayoutIdentifier,
            items: base.items.map { item in
                var copy = item
                if initiallyClearIDs.contains(item.threadID) { copy.initiallyAbsent = true }
                return copy
            }, inventoryDigest: base.inventoryDigest
        )
        let selectedIDs = Array(inventory.eligibleThreadIDs.prefix(selectedCount))
        var items = selectedIDs.map { ($0, PersistentItemOutcome.success, NativeSessionState.absent) }
        if partial {
            items.append((UUID().uuidString.lowercased(), .failure, .absent))
            items.append((UUID().uuidString.lowercased(), .success, .unavailable))
        }
        let report = makeNativeDeleteReport(items: items)
        let handoff = try makeDesktopCleanupHandoff(reportID: report.id, nativeSessionIDs: selectedIDs)
        let store = AppTestGhostRepairBulkPreviewMemoryStore()
        let challenge = AppTestDynamicGhostRepairBulkConfirmationCoordinator(previewStore: store)
        let receipt = AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator(challengeCoordinator: challenge)
        let repair = AppTestDynamicGhostRepairBulkRepairCoordinator(
            previewStore: store, receiptCoordinator: receipt,
            reviewBlocked: reviewBlocked, executionUnknown: executionUnknown
        )
        let model = makeModel(
            sessions: [],
            bulkInventoryCoordinator: AppTestGhostRepairBulkInventoryCoordinator(inventory: inventory, directScan: true, noResidue: noResidue),
            bulkPreviewPersister: store, bulkPreviewReadbackCoordinator: store,
            bulkConfirmationChallengeCoordinator: challenge,
            bulkConfirmationReceiptCoordinator: receipt, bulkRepairCoordinator: repair,
            nativeDeleteDesktopCleanupCoordinator: AppTestDynamicDesktopCleanupLinkageCoordinator(handoff: handoff, store: store, receipts: receipt, executionUnknown: executionUnknown),
            bulkReconciliationEnabled: false
        )
        model.latestNativeDeleteReport = report
        return (model, report, receipt, repair)
    }

    func testBulkPreparationContinuesThroughExact148ItemTerminalReport()
        async throws
    {
        let inventory = AppTestGhostRepairBulkFixture.exact148Inventory
        let witnessIDs = Array(inventory.eligibleThreadIDs.prefix(10))
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let safetySource = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(
                targetIDs: witnessIDs,
                executionGate: gate
            )
        )
        let snapshotCoordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [
                .succeeded(reference: inventory.snapshotReference),
            ]
        )
        let inventoryCoordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: inventory
        )
        let previewStore = AppTestGhostRepairBulkPreviewMemoryStore()
        let challengeCoordinator =
            AppTestDynamicGhostRepairBulkConfirmationCoordinator(
                previewStore: previewStore
            )
        let receiptCoordinator =
            AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator(
                challengeCoordinator: challengeCoordinator
            )
        let repairCoordinator = AppTestDynamicGhostRepairBulkRepairCoordinator(
            previewStore: previewStore,
            receiptCoordinator: receiptCoordinator
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: safetySource,
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            ghostRepairSnapshotCoordinator: snapshotCoordinator,
            bulkInventoryCoordinator: inventoryCoordinator,
            bulkPreviewPersister: previewStore,
            bulkPreviewReadbackCoordinator: previewStore,
            bulkConfirmationChallengeCoordinator: challengeCoordinator,
            bulkConfirmationReceiptCoordinator: receiptCoordinator,
            bulkRepairCoordinator: repairCoordinator,
            bulkReconciliationEnabled: true
        )
        model.sessionRows = inventory.eligibleThreadIDs.map {
            makeDeletedPresentation(nativeID: $0)
        }

        await model.prepareGhostRepairBulkInventory()
        model.selectAllEligibleGhostRepairBulkItems()
        await model.buildGhostRepairBulkPreview()

        guard case let .ready(challenge) =
                model.ghostRepairBulkConfirmationChallengeState else {
            return XCTFail(
                "Expected one whole-batch confirmation challenge; preview=\(model.ghostRepairBulkPreviewState), readback=\(model.ghostRepairBulkPreviewReadbackState), challenge=\(model.ghostRepairBulkConfirmationChallengeState)"
            )
        }
        XCTAssertEqual(challenge.selectedCount, 148)
        XCTAssertEqual(challenge.ordinaryCount, 74)
        XCTAssertEqual(challenge.automationCount, 74)
        model.ghostRepairBulkConfirmationPhraseDraft =
            challenge.confirmationPhrase
        await model.confirmGhostRepairBulkBatch()

        XCTAssertEqual(model.ghostRepairBulkRepairState, .idle)
        let reviewRequestCountBeforeExplicitReview =
            await repairCoordinator.reviewRequestCount()
        XCTAssertEqual(reviewRequestCountBeforeExplicitReview, 0)
        await model.prepareGhostRepairBulkFinalReview()

        guard case let .reviewReady(review) =
                model.ghostRepairBulkRepairState else {
            return XCTFail("Expected one exact 148-item final review")
        }
        XCTAssertEqual(review.selectedCount, 148)
        XCTAssertEqual(review.ordinaryCount, 74)
        XCTAssertEqual(review.automationCount, 74)

        await model.executeGhostRepairBulkOneShot()

        guard case let .completed(report) =
                model.ghostRepairBulkRepairState else {
            return XCTFail("Expected one exact 148-item terminal Report")
        }
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.itemReports.count, 148)
        XCTAssertEqual(
            report.itemReports.map(\.threadID),
            inventory.eligibleThreadIDs
        )
        XCTAssertEqual(
            Set(report.itemReports.map(\.category)),
            [.ordinary, .automation]
        )
        let inventoryRequestCount = await inventoryCoordinator.requestCount()
        let challengeRequestCount = await challengeCoordinator.requestCount()
        let receiptRequestCount = await receiptCoordinator.requestCount()
        let reviewRequestCount = await repairCoordinator.reviewRequestCount()
        let executionRequestCount =
            await repairCoordinator.executionRequestCount()
        XCTAssertEqual(inventoryRequestCount, 1)
        XCTAssertEqual(challengeRequestCount, 1)
        XCTAssertEqual(receiptRequestCount, 1)
        XCTAssertEqual(reviewRequestCount, 1)
        XCTAssertEqual(executionRequestCount, 1)
    }

    func testSnapshotActionRecoveryCannotResetOrRetry() async {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-a"]
        ))
        let coordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [
                .recoveryRequired(
                    reference: "snapshot-recovery-reference",
                    message: "Readback is required."
                ),
                .succeeded(reference: "unexpected-retry"),
            ]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)
        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)

        await model.requestGhostRepairSnapshotAction(managerKeys: model.selection)
        guard case let .recoveryRequired(request, reference, message) =
            model.ghostRepairSnapshotActionState else {
            return XCTFail("Expected readback-only recovery state")
        }
        XCTAssertEqual(reference, "snapshot-recovery-reference")
        XCTAssertEqual(message, "Readback is required.")
        let requestsAfterRecovery = await coordinator.requests
        XCTAssertEqual(requestsAfterRecovery.count, 1)

        await model.requestGhostRepairSnapshotAction(managerKeys: model.selection)
        let requestsAfterBlockedRetry = await coordinator.requests
        XCTAssertEqual(requestsAfterBlockedRetry.count, 1)

        let recoveryState = model.ghostRepairSnapshotActionState
        model.resetGhostRepairSnapshotAction()
        XCTAssertEqual(model.ghostRepairSnapshotActionState, recoveryState)
        XCTAssertEqual(request.targetThreadIDs, ["deleted-a"])

        XCTAssertFalse(model.setGhostRepairBulkReconciliationEnabled(false))
        XCTAssertTrue(model.isGhostRepairBulkReconciliationEnabled)
        XCTAssertEqual(
            model.ghostRepairSnapshotRecoveryReference,
            "snapshot-recovery-reference"
        )

        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)
        let requestsAfterBlockedReview = await coordinator.requests
        XCTAssertEqual(requestsAfterBlockedReview.count, 1)
        XCTAssertEqual(model.ghostRepairSnapshotActionState, recoveryState)
    }

    func testOneSnapshotIntentRunsAdmissionThenPublishesExactRequest()
        async
    {
        let source = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(targetIDs: ["deleted-a"])
        )
        let inspector = AppTestGhostRepairSnapshotAdmissionInspector(
            outcomes: [.allowed(.appTestAllowed)]
        )
        let coordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "published-snapshot")]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator,
            snapshotAdmissionInspector: inspector,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        await model.requestGhostRepairSnapshotWithAutomaticAdmission(managerKeys: model.selection)

        let admissionRequests = await inspector.requests
        let snapshotRequests = await coordinator.requests
        XCTAssertEqual(admissionRequests.count, 1)
        XCTAssertEqual(snapshotRequests.count, 1)
        XCTAssertEqual(admissionRequests.first, snapshotRequests.first)
        guard case let .succeeded(request, reference) =
                model.ghostRepairSnapshotActionState else {
            return XCTFail("Expected one combined successful Snapshot action")
        }
        XCTAssertEqual(request.targetThreadIDs, ["deleted-a"])
        XCTAssertEqual(reference, "published-snapshot")
    }

    func testOneSnapshotIntentStopsBeforePublisherWhenAdmissionBlocks()
        async
    {
        let source = AppTestGhostRepairSafetySource(
            snapshot: makeGhostRepairSnapshot(targetIDs: ["deleted-a"])
        )
        let inspector = AppTestGhostRepairSnapshotAdmissionInspector(
            outcomes: [
                .blocked(
                    evidence: .appTestAllowed,
                    message: "Snapshot storage is blocked."
                )
            ]
        )
        let coordinator = AppTestGhostRepairSnapshotActionCoordinator(
            outcomes: [.succeeded(reference: "must-not-publish")]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator,
            snapshotAdmissionInspector: inspector,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)

        await model.requestGhostRepairSnapshotWithAutomaticAdmission(managerKeys: model.selection)
        await model.requestGhostRepairSnapshotWithAutomaticAdmission(managerKeys: model.selection)

        let admissionRequests = await inspector.requests
        let snapshotRequests = await coordinator.requests
        XCTAssertEqual(admissionRequests.count, 1)
        XCTAssertTrue(snapshotRequests.isEmpty)
        guard case let .blocked(_, _, message) =
                model.ghostRepairSnapshotAdmissionState else {
            return XCTFail("Expected terminal blocked Admission state")
        }
        XCTAssertEqual(message, "Snapshot storage is blocked.")
    }

    func testSnapshotActionPreventsReentryAndMapsFailureWithoutRetry() async {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-a"]
        ))
        let coordinator = AppTestSuspendingGhostRepairSnapshotActionCoordinator()
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)
        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)

        let first = Task { @MainActor in
            await model.requestGhostRepairSnapshotAction(managerKeys: model.selection)
        }
        await coordinator.waitUntilRequested()
        guard case .acquiring = model.ghostRepairSnapshotActionState else {
            return XCTFail("First explicit request should own the acquiring state")
        }

        await model.requestGhostRepairSnapshotAction(managerKeys: model.selection)
        let countAfterReentry = await coordinator.requestCount()
        XCTAssertEqual(countAfterReentry, 1)

        await coordinator.finish(
            with: .failed(message: "Deterministic failure.")
        )
        await first.value
        guard case let .failed(_, message) = model.ghostRepairSnapshotActionState else {
            return XCTFail("Expected an itemized failed presentation state")
        }
        XCTAssertEqual(message, "Deterministic failure.")
        let finalRequestCount = await coordinator.requestCount()
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testDisablingSnapshotActionIgnoresLateResultWithoutSecondRequest()
        async
    {
        let source = AppTestGhostRepairSafetySource(snapshot: makeGhostRepairSnapshot(
            targetIDs: ["deleted-a"]
        ))
        let coordinator = AppTestSuspendingGhostRepairSnapshotActionCoordinator()
        let model = makeModel(
            sessions: [],
            ghostRepairSource: source,
            ghostRepairSnapshotCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        let deleted = makeDeletedPresentation(nativeID: "deleted-a")
        model.sessionRows = [deleted]
        model.selection = [deleted.id]
        await model.requestGhostRepairReadOnlyReview(managerKeys: model.selection)
        await model.requestGhostRepairSnapshotAdmissionInspection(managerKeys: model.selection)

        let action = Task { @MainActor in
            await model.requestGhostRepairSnapshotAction(managerKeys: model.selection)
        }
        await coordinator.waitUntilRequested()
        XCTAssertTrue(model.setGhostRepairBulkReconciliationEnabled(false))
        await coordinator.finish(
            with: .succeeded(reference: "late-result-must-not-win")
        )
        await action.value

        guard case .unavailable = model.ghostRepairSnapshotActionState else {
            return XCTFail("Disabled action must ignore a late result")
        }
        let requestCount = await coordinator.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSnapshotReadbackIsDefaultOffAndDoesNotCallCoordinator() async {
        let coordinator = AppTestGhostRepairSnapshotReadbackCoordinator(
            outcomes: [.observed(makeSnapshotReadbackInventory())]
        )
        let model = makeModel(
            sessions: [],
            snapshotReadbackCoordinator: coordinator
        )

        await model.readGhostRepairSnapshotInventory()

        XCTAssertEqual(model.ghostRepairSnapshotReadbackState, .disabled)
        XCTAssertEqual(
            model.errorMessage,
            "Enable the experimental Snapshot Readback in Settings first."
        )
        let readbackCount = await coordinator.requestCount()
        XCTAssertEqual(readbackCount, 0)
    }

    func testSnapshotReadbackPriorEnabledDoesNotRunAutomatically() async {
        let coordinator = AppTestGhostRepairSnapshotReadbackCoordinator(
            outcomes: [.observed(makeSnapshotReadbackInventory())]
        )
        let model = makeModel(
            sessions: [],
            snapshotReadbackCoordinator: coordinator,
            snapshotReadbackEnabled: true
        )

        XCTAssertEqual(model.ghostRepairSnapshotReadbackState, .idle)
        XCTAssertFalse(model.isGhostRepairSnapshotReadbackPresented)
        let readbackCount = await coordinator.requestCount()
        XCTAssertEqual(readbackCount, 0)
        XCTAssertTrue(
            model.ghostRepairSnapshotReadbackCapabilities.readbackAvailable
        )
        XCTAssertFalse(
            model.ghostRepairSnapshotReadbackCapabilities.writesFilesystem
        )
        XCTAssertFalse(
            model.ghostRepairSnapshotReadbackCapabilities.retryAllowed
        )
        XCTAssertFalse(
            model.ghostRepairSnapshotReadbackCapabilities.cleanupAuthority
        )
        XCTAssertFalse(
            model.ghostRepairSnapshotReadbackCapabilities
                .snapshotAcquisitionAuthority
        )
        XCTAssertFalse(
            model.ghostRepairSnapshotReadbackCapabilities.repairMutationAuthority
        )
    }

    func testSnapshotReadbackTogglePersistsAndDisablingClosesSurface() {
        var persistedValues: [Bool] = []
        let model = makeModel(
            sessions: [],
            snapshotReadbackPreferenceWriter: { persistedValues.append($0) }
        )

        model.isGhostRepairSnapshotReadbackEnabled = true
        model.presentGhostRepairSnapshotReadback()
        XCTAssertTrue(model.isGhostRepairSnapshotReadbackPresented)
        XCTAssertEqual(model.ghostRepairSnapshotReadbackState, .idle)

        model.isGhostRepairSnapshotReadbackEnabled = false

        XCTAssertEqual(persistedValues, [true, false])
        XCTAssertFalse(model.isGhostRepairSnapshotReadbackPresented)
        XCTAssertEqual(model.ghostRepairSnapshotReadbackState, .disabled)
    }

    func testSnapshotReadbackUnavailableCapabilityBlocksBeforeCall() async {
        let coordinator = AppTestGhostRepairSnapshotReadbackCoordinator(
            capabilities: .unavailable,
            outcomes: []
        )
        let model = makeModel(
            sessions: [],
            snapshotReadbackCoordinator: coordinator,
            snapshotReadbackEnabled: true
        )

        await model.readGhostRepairSnapshotInventory()

        XCTAssertEqual(model.ghostRepairSnapshotReadbackState, .idle)
        XCTAssertEqual(
            model.errorMessage,
            "Snapshot readback is not available in this build."
        )
        let readbackCount = await coordinator.requestCount()
        XCTAssertEqual(readbackCount, 0)
    }

    func testExplicitSnapshotReadbackPresentsFourPathRedactedStates() async {
        let inventory = makeSnapshotReadbackInventory()
        let coordinator = AppTestGhostRepairSnapshotReadbackCoordinator(
            outcomes: [.observed(inventory)]
        )
        let model = makeModel(
            sessions: [],
            snapshotReadbackCoordinator: coordinator,
            snapshotReadbackEnabled: true
        )

        model.presentGhostRepairSnapshotReadback()
        await model.readGhostRepairSnapshotInventory()

        XCTAssertEqual(
            model.ghostRepairSnapshotReadbackState,
            .observed(inventory)
        )
        let readbackCount = await coordinator.requestCount()
        XCTAssertEqual(readbackCount, 1)
        XCTAssertEqual(
            inventory.snapshots.map(\.state),
            [.preparedOnly, .unpublishedPartial, .publicationInterrupted, .published]
        )
        XCTAssertTrue(inventory.pathRedacted)
        XCTAssertEqual(inventory.rawDatabaseContentsOpened, 0)
        XCTAssertFalse(inventory.retryAllowed)
        XCTAssertFalse(inventory.cleanupAuthority)
        XCTAssertFalse(inventory.snapshotAcquisitionAuthority)
        XCTAssertFalse(inventory.repairMutationAuthority)
    }

    func testSnapshotReadbackPreventsReentryAndIgnoresLateResultAfterDisable()
        async
    {
        let coordinator = AppTestSuspendingGhostRepairSnapshotReadbackCoordinator()
        let model = makeModel(
            sessions: [],
            snapshotReadbackCoordinator: coordinator,
            snapshotReadbackEnabled: true
        )

        let first = Task { @MainActor in
            await model.readGhostRepairSnapshotInventory()
        }
        await coordinator.waitUntilRequested()
        guard case .reading = model.ghostRepairSnapshotReadbackState else {
            return XCTFail("First explicit readback must own the request")
        }

        await model.readGhostRepairSnapshotInventory()
        let countAfterReentry = await coordinator.requestCount()
        XCTAssertEqual(countAfterReentry, 1)
        model.isGhostRepairSnapshotReadbackEnabled = false
        await coordinator.finish(
            with: .observed(makeSnapshotReadbackInventory())
        )
        await first.value

        XCTAssertEqual(model.ghostRepairSnapshotReadbackState, .disabled)
        XCTAssertFalse(model.isGhostRepairSnapshotReadbackPresented)
        let finalReadbackCount = await coordinator.requestCount()
        XCTAssertEqual(finalReadbackCount, 1)
    }

    func testBulkInventoryIsDefaultOffAndNeverObservesAutomatically() async {
        let coordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let model = makeModel(
            sessions: [],
            bulkInventoryCoordinator: coordinator
        )

        model.presentGhostRepairBulkInventory()
        await model.observeGhostRepairBulkInventory()

        XCTAssertEqual(model.ghostRepairBulkInventoryState, .disabled)
        XCTAssertFalse(model.isGhostRepairBulkInventoryPresented)
        let requestCount = await coordinator.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testBulkInventoryExplicitScanKeepsSelectionAcrossSearches() async {
        let coordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let model = makeModel(
            sessions: [],
            bulkInventoryCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSnapshotReferenceDraft =
            AppTestGhostRepairBulkFixture.snapshotReference

        model.presentGhostRepairBulkInventory()
        XCTAssertTrue(model.isGhostRepairBulkInventoryPresented)
        let requestCountBeforeScan = await coordinator.requestCount()
        XCTAssertEqual(requestCountBeforeScan, 0)
        await model.observeGhostRepairBulkInventory()

        XCTAssertEqual(
            model.ghostRepairBulkInventoryState,
            .ready(AppTestGhostRepairBulkFixture.inventory)
        )
        let requestCountAfterScan = await coordinator.requestCount()
        XCTAssertEqual(requestCountAfterScan, 1)
        XCTAssertEqual(model.ghostRepairBulkFilter, .needsAttention)
        XCTAssertEqual(model.ghostRepairBulkVisibleItems.count, 3)
        model.ghostRepairBulkFilter = .all
        XCTAssertEqual(model.ghostRepairBulkVisibleItems.count, 4)

        model.ghostRepairBulkSearchText =
            AppTestGhostRepairBulkFixture.eligibleA
        model.setGhostRepairBulkItemSelected(
            AppTestGhostRepairBulkFixture.eligibleA,
            isSelected: true
        )
        XCTAssertEqual(
            model.ghostRepairBulkSelection,
            [AppTestGhostRepairBulkFixture.eligibleA]
        )

        model.ghostRepairBulkSearchText =
            AppTestGhostRepairBulkFixture.eligibleB
        XCTAssertEqual(
            model.ghostRepairBulkVisibleItems.map(\.threadID),
            [AppTestGhostRepairBulkFixture.eligibleB]
        )
        XCTAssertTrue(
            model.isGhostRepairBulkItemSelected(
                AppTestGhostRepairBulkFixture.eligibleA
            )
        )
        model.setGhostRepairBulkItemSelected(
            AppTestGhostRepairBulkFixture.eligibleB,
            isSelected: true
        )

        model.ghostRepairBulkSearchText = ""
        model.ghostRepairBulkFilter = .notGhost
        XCTAssertEqual(model.ghostRepairBulkVisibleItems.map(\.threadID), [AppTestGhostRepairBulkFixture.notGhost])
        XCTAssertEqual(model.ghostRepairBulkSelection.count, 2)
        model.ghostRepairBulkFilter = .eligible
        model.isShowingSelectedGhostRepairBulkItemsOnly = true
        XCTAssertEqual(
            Set(model.ghostRepairBulkVisibleItems.map(\.threadID)),
            [
                AppTestGhostRepairBulkFixture.eligibleA,
                AppTestGhostRepairBulkFixture.eligibleB,
            ]
        )
    }

    func testBulkInventoryOnlyEligibleItemsCanBeSelected() async {
        let coordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let model = makeModel(
            sessions: [],
            bulkInventoryCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSnapshotReferenceDraft =
            AppTestGhostRepairBulkFixture.snapshotReference
        await model.observeGhostRepairBulkInventory()

        model.setGhostRepairBulkItemSelected(
            AppTestGhostRepairBulkFixture.blocked,
            isSelected: true
        )
        model.setGhostRepairBulkItemSelected(
            AppTestGhostRepairBulkFixture.notGhost,
            isSelected: true
        )
        XCTAssertTrue(model.ghostRepairBulkSelection.isEmpty)

        model.selectAllEligibleGhostRepairBulkItems()
        XCTAssertEqual(
            model.ghostRepairBulkSelection,
            [
                AppTestGhostRepairBulkFixture.eligibleA,
                AppTestGhostRepairBulkFixture.eligibleB,
            ]
        )
        model.clearGhostRepairBulkSelection()
        XCTAssertTrue(model.ghostRepairBulkSelection.isEmpty)
        XCTAssertFalse(model.isShowingSelectedGhostRepairBulkItemsOnly)
    }

    func testBulkInventoryFailureNeverShowsPartialSelection() async {
        let coordinator = AppTestGhostRepairBulkInventoryCoordinator(
            failureStage: .candidateExactRead
        )
        let model = makeModel(
            sessions: [],
            bulkInventoryCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSnapshotReferenceDraft =
            AppTestGhostRepairBulkFixture.snapshotReference

        await model.observeGhostRepairBulkInventory()

        guard case let .unavailable(reference, stage) =
            model.ghostRepairBulkInventoryState else {
            return XCTFail("Expected a terminal no-partial result")
        }
        XCTAssertEqual(reference, AppTestGhostRepairBulkFixture.snapshotReference)
        XCTAssertEqual(stage, .candidateExactRead)
        XCTAssertNil(model.ghostRepairBulkInventory)
        XCTAssertTrue(model.ghostRepairBulkVisibleItems.isEmpty)
        XCTAssertTrue(model.ghostRepairBulkSelection.isEmpty)
    }

    func testBulkInventoryBuildsOneAuthorityFreeWholeBatchPreview() async {
        let coordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let model = makeModel(
            sessions: [],
            bulkInventoryCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSnapshotReferenceDraft =
            AppTestGhostRepairBulkFixture.snapshotReference
        await model.observeGhostRepairBulkInventory()
        model.selectAllEligibleGhostRepairBulkItems()

        await model.buildGhostRepairBulkPreview()

        guard case let .saved(preview, receipt) =
            model.ghostRepairBulkPreviewState else {
            return XCTFail("Expected one complete frozen Preview")
        }
        XCTAssertEqual(
            preview.selectedThreadIDs,
            [
                AppTestGhostRepairBulkFixture.eligibleA,
                AppTestGhostRepairBulkFixture.eligibleB,
            ]
        )
        XCTAssertEqual(preview.ordinarySelectedCount, 1)
        XCTAssertEqual(preview.automationSelectedCount, 1)
        XCTAssertEqual(preview.blockedItems.map(\.threadID), [
            AppTestGhostRepairBulkFixture.blocked,
        ])
        XCTAssertTrue(preview.allOrNothing)
        XCTAssertTrue(preview.singleWholeBatchConfirmationRequired)
        XCTAssertFalse(preview.perItemConfirmationRequired)
        XCTAssertFalse(preview.persistsPreview)
        XCTAssertFalse(preview.confirmationAuthority)
        XCTAssertFalse(preview.repairMutationAuthority)
        XCTAssertEqual(receipt.previewID, preview.previewID)
        XCTAssertTrue(receipt.durableReadbackMatched)
        XCTAssertFalse(receipt.confirmationAuthority)
        XCTAssertFalse(receipt.repairMutationAuthority)
        XCTAssertEqual(
            model.ghostRepairBulkSavedPreviewRequestIDDraft,
            receipt.requestID.uuidString.lowercased()
        )
    }

    func testBulkInventorySelectionChangeInvalidatesFrozenPreview() async {
        let coordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let model = makeModel(
            sessions: [],
            bulkInventoryCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSnapshotReferenceDraft =
            AppTestGhostRepairBulkFixture.snapshotReference
        await model.observeGhostRepairBulkInventory()
        model.selectAllEligibleGhostRepairBulkItems()
        await model.buildGhostRepairBulkPreview()
        XCTAssertNotNil(model.ghostRepairBulkPreview)

        model.ghostRepairBulkSearchText = "automation"
        XCTAssertNotNil(model.ghostRepairBulkPreview)

        model.setGhostRepairBulkItemSelected(
            AppTestGhostRepairBulkFixture.eligibleB,
            isSelected: false
        )
        XCTAssertEqual(model.ghostRepairBulkPreviewState, .idle)
        XCTAssertNil(model.ghostRepairBulkPreview)
    }

    func testBulkPreviewColdStartReadsExactSavedRequestWithoutCodex()
        async
    {
        let memoryStore = AppTestGhostRepairBulkPreviewMemoryStore()
        let inventoryCoordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let first = makeModel(
            sessions: [],
            bulkInventoryCoordinator: inventoryCoordinator,
            bulkPreviewPersister: memoryStore,
            bulkPreviewReadbackCoordinator: memoryStore,
            bulkReconciliationEnabled: true
        )
        first.ghostRepairBulkSnapshotReferenceDraft =
            AppTestGhostRepairBulkFixture.snapshotReference
        await first.observeGhostRepairBulkInventory()
        first.selectAllEligibleGhostRepairBulkItems()
        await first.buildGhostRepairBulkPreview()
        let requestID = first.ghostRepairBulkSavedPreviewRequestIDDraft

        let restarted = makeModel(
            sessions: [],
            bulkPreviewPersister: memoryStore,
            bulkPreviewReadbackCoordinator: memoryStore,
            bulkReconciliationEnabled: true
        )
        restarted.ghostRepairBulkSavedPreviewRequestIDDraft = requestID
        await restarted.readSavedGhostRepairBulkPreview()

        guard case let .observed(evidence) =
            restarted.ghostRepairBulkPreviewReadbackState else {
            return XCTFail("Expected exact cold-start bulk Preview readback")
        }
        XCTAssertEqual(
            evidence.requestID.uuidString.lowercased(),
            requestID
        )
        XCTAssertEqual(evidence.preview.selectedItems.count, 2)
        XCTAssertEqual(evidence.preview.blockedItems.count, 1)
        XCTAssertTrue(evidence.durableReadbackMatched)
        XCTAssertFalse(evidence.readsCodexData)
        XCTAssertFalse(evidence.confirmationAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)
        let inventoryRequestCount = await inventoryCoordinator.requestCount()
        XCTAssertEqual(inventoryRequestCount, 1)
    }

    func testBulkConfirmationRequiresExactColdReadbackBeforeOneChallenge()
        async throws
    {
        let requestID = UUID(
            uuidString: "12345678-1234-4234-8234-123456789abc"
        )!
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: AppTestGhostRepairBulkFixture.inventory,
                selectedThreadIDs: [
                    AppTestGhostRepairBulkFixture.eligibleA,
                    AppTestGhostRepairBulkFixture.eligibleB,
                ],
                generatedAtMilliseconds: 1_000
            )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "f", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let memoryStore = AppTestGhostRepairBulkPreviewMemoryStore()
        _ = try await memoryStore.persist(
            requestID: requestID,
            preview: preview,
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let challengeCoordinator =
            AppTestGhostRepairBulkConfirmationCoordinator(
                outcome: .ready(challenge)
            )
        let model = makeModel(
            sessions: [],
            bulkPreviewReadbackCoordinator: memoryStore,
            bulkConfirmationChallengeCoordinator: challengeCoordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            requestID.uuidString.lowercased()

        await model.prepareGhostRepairBulkConfirmationChallenge()

        XCTAssertEqual(
            model.ghostRepairBulkConfirmationChallengeState,
            .unavailable(
                message: "Press Read Saved Preview for this exact Request ID first."
            )
        )
        let requestsBeforeReadback =
            await challengeCoordinator.requestCount()
        XCTAssertEqual(requestsBeforeReadback, 0)

        await model.readSavedGhostRepairBulkPreview()

        XCTAssertEqual(
            model.ghostRepairBulkConfirmationChallengeState,
            .ready(challenge)
        )
        let requestsAfterReadback =
            await challengeCoordinator.requestCount()
        XCTAssertEqual(requestsAfterReadback, 1)
        XCTAssertFalse(challenge.confirmationAuthority)
        XCTAssertFalse(challenge.repairClaimCreated)
        XCTAssertFalse(challenge.repairMutationAuthority)

        model.ghostRepairBulkSavedPreviewRequestIDDraft = UUID()
            .uuidString.lowercased()
        XCTAssertEqual(model.ghostRepairBulkPreviewReadbackState, .idle)
        XCTAssertEqual(
            model.ghostRepairBulkConfirmationChallengeState,
            .idle
        )
    }

    func testBulkConfirmationRecordsOneReceiptWithoutRepairAuthority()
        async throws
    {
        let requestID = UUID(
            uuidString: "12345678-1234-4234-8234-123456789abc"
        )!
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: AppTestGhostRepairBulkFixture.inventory,
                selectedThreadIDs: [
                    AppTestGhostRepairBulkFixture.eligibleA,
                    AppTestGhostRepairBulkFixture.eligibleB,
                ],
                generatedAtMilliseconds: 1_000
            )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "f", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let receipt = try CodexGhostRepairBulkConfirmationReceipt(
            receiptID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!,
            challenge: challenge,
            confirmedAtMilliseconds: 3_000
        )
        let memoryStore = AppTestGhostRepairBulkPreviewMemoryStore()
        _ = try await memoryStore.persist(
            requestID: requestID,
            preview: preview,
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let challengeCoordinator =
            AppTestGhostRepairBulkConfirmationCoordinator(
                outcome: .ready(challenge)
            )
        let receiptCoordinator =
            AppTestGhostRepairBulkConfirmationReceiptCoordinator(
                expectedPhrase: challenge.confirmationPhrase,
                outcome: .confirmed(receipt)
            )
        let model = makeModel(
            sessions: [],
            bulkPreviewReadbackCoordinator: memoryStore,
            bulkConfirmationChallengeCoordinator: challengeCoordinator,
            bulkConfirmationReceiptCoordinator: receiptCoordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            requestID.uuidString.lowercased()
        await model.readSavedGhostRepairBulkPreview()

        await model.confirmGhostRepairBulkBatch()
        XCTAssertEqual(
            model.ghostRepairBulkConfirmationReceiptState,
            .unavailable(
                message: "Paste the exact whole-batch confirmation phrase."
            )
        )
        let requestsBeforePhrase = await receiptCoordinator.requestCount()
        XCTAssertEqual(requestsBeforePhrase, 0)

        model.ghostRepairBulkConfirmationPhraseDraft = "WRONG PHRASE"
        await model.confirmGhostRepairBulkBatch()

        guard case .unavailable =
                model.ghostRepairBulkConfirmationReceiptState else {
            return XCTFail("Expected a definitive wrong-phrase rejection")
        }
        XCTAssertFalse(model.isGhostRepairBulkProtectedOperationActive)
        let requestsAfterWrongPhrase = await receiptCoordinator.requestCount()
        XCTAssertEqual(requestsAfterWrongPhrase, 1)

        model.ghostRepairBulkConfirmationPhraseDraft =
            challenge.confirmationPhrase
        await model.confirmGhostRepairBulkBatch()

        XCTAssertEqual(
            model.ghostRepairBulkConfirmationReceiptState,
            .confirmed(receipt)
        )
        XCTAssertEqual(model.ghostRepairBulkConfirmationPhraseDraft, "")
        XCTAssertTrue(receipt.wholeBatchConfirmationRecorded)
        XCTAssertFalse(receipt.createsRepairClaim)
        XCTAssertFalse(receipt.repairClaimCreated)
        XCTAssertFalse(receipt.repairMutationAuthority)
        XCTAssertFalse(receipt.automaticRetryAllowed)
        let requestsAfterPhrase = await receiptCoordinator.requestCount()
        XCTAssertEqual(requestsAfterPhrase, 2)

        model.ghostRepairBulkSavedPreviewRequestIDDraft = UUID()
            .uuidString.lowercased()
        XCTAssertEqual(
            model.ghostRepairBulkSavedPreviewRequestIDDraft,
            requestID.uuidString.lowercased()
        )
        XCTAssertEqual(
            model.ghostRepairBulkConfirmationReceiptState,
            .confirmed(receipt)
        )
    }

    func testUnknownBulkConfirmationOutcomeCannotBeRetriedOrReplaced()
        async throws
    {
        let requestID = UUID(
            uuidString: "12345678-1234-4234-8234-123456789abc"
        )!
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: AppTestGhostRepairBulkFixture.inventory,
                selectedThreadIDs: [
                    AppTestGhostRepairBulkFixture.eligibleA,
                    AppTestGhostRepairBulkFixture.eligibleB,
                ],
                generatedAtMilliseconds: 1_000
            )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "f", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let previewStore = AppTestGhostRepairBulkPreviewMemoryStore()
        _ = try await previewStore.persist(
            requestID: requestID,
            preview: preview,
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let receiptCoordinator =
            AppTestGhostRepairBulkConfirmationReceiptCoordinator(
                expectedPhrase: challenge.confirmationPhrase,
                outcome: .outcomeUnknown(
                    requestID: requestID,
                    message: "Confirmation outcome is unknown."
                )
            )
        let recoveredReceipt = try CodexGhostRepairBulkConfirmationReceipt(
            receiptID: UUID(),
            challenge: challenge,
            confirmedAtMilliseconds: 3_000
        )
        let recoveryRequest =
            CodexGhostRepairBulkConfirmationReceiptRecoveryRequest(
                challenge: challenge
            )
        let receiptRecoveryCoordinator =
            AppTestGhostRepairBulkConfirmationReceiptRecoveryCoordinator(
                outcome: .confirmed(
                    request: recoveryRequest,
                    receipt: recoveredReceipt
                )
            )
        let model = makeModel(
            sessions: [],
            bulkPreviewReadbackCoordinator: previewStore,
            bulkConfirmationChallengeCoordinator:
                AppTestGhostRepairBulkConfirmationCoordinator(
                    outcome: .ready(challenge)
                ),
            bulkConfirmationReceiptCoordinator: receiptCoordinator,
            bulkConfirmationReceiptRecoveryCoordinator:
                receiptRecoveryCoordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            requestID.uuidString.lowercased()
        await model.readSavedGhostRepairBulkPreview()
        model.ghostRepairBulkConfirmationPhraseDraft =
            challenge.confirmationPhrase

        await model.confirmGhostRepairBulkBatch()
        await model.confirmGhostRepairBulkBatch()

        XCTAssertTrue(model.isGhostRepairBulkProtectedOperationActive)
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        XCTAssertFalse(model.startNewGhostRepairBulkPreparation())
        XCTAssertNotNil(model.ghostRepairBulkDisableBlockedReason)
        XCTAssertNotNil(model.ghostRepairBulkFreshRecoveryBlockedReason)
        let requestCount = await receiptCoordinator.requestCount()
        XCTAssertEqual(requestCount, 1)

        await model.recoverUnknownGhostRepairBulkConfirmationReceipt()

        XCTAssertEqual(
            model.ghostRepairBulkConfirmationReceiptRecoveryState,
            .confirmed(
                request: recoveryRequest,
                receipt: recoveredReceipt
            )
        )
        XCTAssertEqual(
            model.ghostRepairBulkConfirmationReceiptState,
            .alreadyConfirmed(recoveredReceipt)
        )
        XCTAssertNil(model.ghostRepairBulkFinalReviewBlockedReason)
        let recoveryCount = await receiptRecoveryCoordinator.requestCount()
        XCTAssertEqual(recoveryCount, 1)
    }

    func testSuspendedReceiptRecoveryRejectsReentryAndWrongOutcomeWithoutLocking()
        async throws
    {
        let requestID = UUID(
            uuidString: "12345678-1234-4234-8234-123456789abc"
        )!
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: AppTestGhostRepairBulkFixture.inventory,
                selectedThreadIDs: [
                    AppTestGhostRepairBulkFixture.eligibleA,
                    AppTestGhostRepairBulkFixture.eligibleB,
                ],
                generatedAtMilliseconds: 1_000
            )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "f", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let wrongChallenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: UUID(),
            savedPreviewRequestID: UUID(),
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "e", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let wrongRequest =
            CodexGhostRepairBulkConfirmationReceiptRecoveryRequest(
                challenge: wrongChallenge
            )
        let wrongReceipt = try CodexGhostRepairBulkConfirmationReceipt(
            receiptID: UUID(),
            challenge: wrongChallenge,
            confirmedAtMilliseconds: 3_000
        )
        let previewStore = AppTestGhostRepairBulkPreviewMemoryStore()
        _ = try await previewStore.persist(
            requestID: requestID,
            preview: preview,
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let receiptCoordinator =
            AppTestGhostRepairBulkConfirmationReceiptCoordinator(
                expectedPhrase: challenge.confirmationPhrase,
                outcome: .outcomeUnknown(
                    requestID: requestID,
                    message: "Confirmation outcome is unknown."
                )
            )
        let recoveryCoordinator =
            AppTestSuspendingGhostRepairBulkConfirmationReceiptRecoveryCoordinator()
        let model = makeModel(
            sessions: [],
            bulkPreviewReadbackCoordinator: previewStore,
            bulkConfirmationChallengeCoordinator:
                AppTestGhostRepairBulkConfirmationCoordinator(
                    outcome: .ready(challenge)
                ),
            bulkConfirmationReceiptCoordinator: receiptCoordinator,
            bulkConfirmationReceiptRecoveryCoordinator: recoveryCoordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            requestID.uuidString.lowercased()
        await model.readSavedGhostRepairBulkPreview()
        model.ghostRepairBulkConfirmationPhraseDraft =
            challenge.confirmationPhrase
        await model.confirmGhostRepairBulkBatch()

        let recovery = Task { @MainActor in
            await model.recoverUnknownGhostRepairBulkConfirmationReceipt()
        }
        await recoveryCoordinator.waitUntilRequested()
        await model.recoverUnknownGhostRepairBulkConfirmationReceipt()
        XCTAssertFalse(model.startNewGhostRepairBulkPreparation())
        XCTAssertFalse(model.setGhostRepairBulkReconciliationEnabled(false))
        await model.prepareGhostRepairBulkFinalReview()
        let inFlightCount = await recoveryCoordinator.requestCount()
        XCTAssertEqual(inFlightCount, 1)
        guard case .reading =
                model.ghostRepairBulkConfirmationReceiptRecoveryState else {
            return XCTFail("Expected original receipt recovery to remain visible")
        }

        await recoveryCoordinator.finish(
            with: .confirmed(request: wrongRequest, receipt: wrongReceipt)
        )
        await recovery.value

        guard case let .recoveryRequired(returnedRequest, reason, _) =
                model.ghostRepairBulkConfirmationReceiptRecoveryState else {
            return XCTFail("Expected wrong recovery identity to fail closed")
        }
        XCTAssertEqual(
            returnedRequest,
            .init(challenge: challenge)
        )
        XCTAssertEqual(reason, .evidenceInvalid)
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        XCTAssertNil(
            model.ghostRepairBulkConfirmationReceiptRecoveryBlockedReason
        )
        let confirmationCount = await receiptCoordinator.requestCount()
        XCTAssertEqual(confirmationCount, 1)
    }

    func testExecutionOwnedReceiptRecoveryCanConvergeThroughTerminalReadback()
        async throws
    {
        let requestID = UUID()
        let operationID = UUID()
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: AppTestGhostRepairBulkFixture.inventory,
                selectedThreadIDs: [
                    AppTestGhostRepairBulkFixture.eligibleA,
                    AppTestGhostRepairBulkFixture.eligibleB,
                ],
                generatedAtMilliseconds: 1_000
            )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: operationID,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "d", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let receipt = try CodexGhostRepairBulkConfirmationReceipt(
            receiptID: UUID(),
            challenge: challenge,
            confirmedAtMilliseconds: 3_000
        )
        let recoveryRequest =
            CodexGhostRepairBulkConfirmationReceiptRecoveryRequest(
                challenge: challenge
            )
        let identity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: requestID,
            operationID: operationID
        )
        let report = try CodexGhostRepairBulkRepairReport(
            operationID: operationID,
            outcome: .success,
            itemReports: preview.selectedItems.map {
                .init(
                    threadID: $0.threadID,
                    category: $0.category,
                    outcome: .success
                )
            },
            reportDigest: "sha256:" + String(repeating: "c", count: 64)
        )
        let summary = CodexGhostRepairBulkRecoveryOperationSummary(
            identity: identity,
            confirmationReceiptID: receipt.receiptID,
            selectedCount: 2,
            phase: .terminal,
            mutationAttemptCount: 1,
            recordedAtMilliseconds: 4_000,
            hasTerminalReport: true
        )
        let previewStore = AppTestGhostRepairBulkPreviewMemoryStore()
        _ = try await previewStore.persist(
            requestID: requestID,
            preview: preview,
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let model = makeModel(
            sessions: [],
            bulkPreviewReadbackCoordinator: previewStore,
            bulkConfirmationChallengeCoordinator:
                AppTestGhostRepairBulkConfirmationCoordinator(
                    outcome: .ready(challenge)
                ),
            bulkConfirmationReceiptCoordinator:
                AppTestGhostRepairBulkConfirmationReceiptCoordinator(
                    expectedPhrase: challenge.confirmationPhrase,
                    outcome: .outcomeUnknown(
                        requestID: requestID,
                        message: "Confirmation outcome is unknown."
                    )
                ),
            bulkRecoveryCoordinator:
                AppTestGhostRepairBulkRecoveryCoordinator(
                    previousOutcome: .observed([summary]),
                    operationOutcomes: [
                        identity: .terminal(summary: summary, report: report),
                    ]
                ),
            bulkConfirmationReceiptRecoveryCoordinator:
                AppTestGhostRepairBulkConfirmationReceiptRecoveryCoordinator(
                    outcome: .executionRecoveryRequired(
                        request: recoveryRequest,
                        receipt: receipt,
                        phase: .attempted,
                        message: "Execution journal owns this operation."
                    )
                ),
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            requestID.uuidString.lowercased()
        await model.readSavedGhostRepairBulkPreview()
        model.ghostRepairBulkConfirmationPhraseDraft =
            challenge.confirmationPhrase
        await model.confirmGhostRepairBulkBatch()
        await model.recoverUnknownGhostRepairBulkConfirmationReceipt()

        XCTAssertNotNil(model.ghostRepairBulkFinalReviewBlockedReason)
        XCTAssertEqual(
            model.ghostRepairBulkRepairState,
            .recoveryRequired(
                operationID: operationID,
                message: "Execution journal owns this operation."
            )
        )
        await model.loadGhostRepairBulkPreviousOperations()
        model.setGhostRepairBulkRecoveryOperationSelected(identity)
        await model.readSelectedGhostRepairBulkRecoveryOperation()

        XCTAssertEqual(model.ghostRepairBulkRepairState, .completed(report))
        XCTAssertTrue(model.canStartNewGhostRepairBulkPreparation)
    }

    func testBulkFinalRepairRequiresWholeBatchConfirmationByDefault() async {
        let model = makeModel(
            sessions: [],
            bulkReconciliationEnabled: true
        )

        await model.prepareGhostRepairBulkFinalReview()

        XCTAssertTrue(
            model.ghostRepairBulkRepairCapabilities.reviewAvailable
        )
        XCTAssertTrue(
            model.ghostRepairBulkRepairCapabilities.executionAvailable
        )
        XCTAssertFalse(
            model.ghostRepairBulkRepairCapabilities.automaticRetryAllowed
        )
        XCTAssertEqual(
            model.ghostRepairBulkRepairState,
            .unavailable(
                message: "Record the one whole-batch confirmation first."
            )
        )
    }

    func testBulkColdReadbackExplicitlyAdvancesThroughFinalReviewAndOneShotReport()
        async throws
    {
        let requestID = UUID(
            uuidString: "12345678-1234-4234-8234-123456789abc"
        )!
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: AppTestGhostRepairBulkFixture.inventory,
                selectedThreadIDs: [
                    AppTestGhostRepairBulkFixture.eligibleA,
                    AppTestGhostRepairBulkFixture.eligibleB,
                ],
                generatedAtMilliseconds: 1_000
            )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "f", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let receipt = try CodexGhostRepairBulkConfirmationReceipt(
            receiptID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!,
            challenge: challenge,
            confirmedAtMilliseconds: 3_000
        )
        let review = try CodexGhostRepairBulkFinalReview(
            operationID: receipt.operationID,
            confirmationReceiptID: receipt.receiptID,
            selectedCount: 2,
            ordinaryCount: 1,
            automationCount: 1,
            blockedOutsideBatchCount: 1,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceProfile.v151DesktopV33.identifier,
            reviewDigest: "sha256:" + String(repeating: "1", count: 64)
        )
        let report = try CodexGhostRepairBulkRepairReport(
            operationID: receipt.operationID,
            outcome: .success,
            itemReports: [
                .init(
                    threadID: AppTestGhostRepairBulkFixture.eligibleA,
                    category: .ordinary,
                    outcome: .success
                ),
                .init(
                    threadID: AppTestGhostRepairBulkFixture.eligibleB,
                    category: .automation,
                    outcome: .success
                ),
            ],
            reportDigest: "sha256:" + String(repeating: "2", count: 64)
        )
        let memoryStore = AppTestGhostRepairBulkPreviewMemoryStore()
        _ = try await memoryStore.persist(
            requestID: requestID,
            preview: preview,
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let challengeCoordinator =
            AppTestGhostRepairBulkConfirmationCoordinator(
                outcome: .ready(challenge)
            )
        let receiptCoordinator =
            AppTestGhostRepairBulkConfirmationReceiptCoordinator(
                expectedPhrase: challenge.confirmationPhrase,
                outcome: .confirmed(receipt)
            )
        let repairCoordinator = AppTestGhostRepairBulkRepairCoordinator(
            reviewOutcome: .ready(review),
            executionOutcome: .completed(report)
        )
        let model = makeModel(
            sessions: [],
            bulkPreviewReadbackCoordinator: memoryStore,
            bulkConfirmationChallengeCoordinator: challengeCoordinator,
            bulkConfirmationReceiptCoordinator: receiptCoordinator,
            bulkRepairCoordinator: repairCoordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            requestID.uuidString.lowercased()
        await model.readSavedGhostRepairBulkPreview()
        model.ghostRepairBulkConfirmationPhraseDraft =
            challenge.confirmationPhrase
        await model.confirmGhostRepairBulkBatch()

        XCTAssertEqual(model.ghostRepairBulkRepairState, .idle)
        let reviewRequestCountBeforeExplicitReview =
            await repairCoordinator.reviewRequestCount()
        XCTAssertEqual(reviewRequestCountBeforeExplicitReview, 0)

        await model.prepareGhostRepairBulkFinalReview()
        XCTAssertEqual(model.ghostRepairBulkRepairState, .reviewReady(review))
        let challengeRequestCount =
            await challengeCoordinator.requestCount()
        let receiptRequestCount = await receiptCoordinator.requestCount()
        let reviewRequestCountBeforeExecution =
            await repairCoordinator.reviewRequestCount()
        XCTAssertEqual(challengeRequestCount, 1)
        XCTAssertEqual(receiptRequestCount, 1)
        XCTAssertEqual(reviewRequestCountBeforeExecution, 1)

        await model.executeGhostRepairBulkOneShot()
        XCTAssertEqual(model.ghostRepairBulkRepairState, .completed(report))
        let reviewRequestCount = await repairCoordinator.reviewRequestCount()
        let executionRequestCount =
            await repairCoordinator.executionRequestCount()
        XCTAssertEqual(reviewRequestCount, 1)
        XCTAssertEqual(executionRequestCount, 1)
        XCTAssertFalse(report.automaticRetryAllowed)
        XCTAssertFalse(report.automaticRestoreAllowed)
    }

    func testBulkProtectedOperationRetainsExactOutcomeAcrossReentryAndResetIntents()
        async throws
    {
        let requestID = UUID(
            uuidString: "12345678-1234-4234-8234-123456789abc"
        )!
        let operationID = UUID(
            uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: AppTestGhostRepairBulkFixture.inventory,
                selectedThreadIDs: [
                    AppTestGhostRepairBulkFixture.eligibleA,
                    AppTestGhostRepairBulkFixture.eligibleB,
                ],
                generatedAtMilliseconds: 1_000
            )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: operationID,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "f", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let receipt = try CodexGhostRepairBulkConfirmationReceipt(
            receiptID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!,
            challenge: challenge,
            confirmedAtMilliseconds: 3_000
        )
        let review = try CodexGhostRepairBulkFinalReview(
            operationID: operationID,
            confirmationReceiptID: receipt.receiptID,
            selectedCount: 2,
            ordinaryCount: 1,
            automationCount: 1,
            blockedOutsideBatchCount: 1,
            sourceLayoutIdentifier: preview.sourceLayoutIdentifier,
            reviewDigest: "sha256:" + String(repeating: "1", count: 64)
        )
        let report = try CodexGhostRepairBulkRepairReport(
            operationID: operationID,
            outcome: .success,
            itemReports: preview.selectedItems.map {
                .init(
                    threadID: $0.threadID,
                    category: $0.category,
                    outcome: .success
                )
            },
            reportDigest: "sha256:" + String(repeating: "2", count: 64)
        )
        let previewStore = AppTestGhostRepairBulkPreviewMemoryStore()
        _ = try await previewStore.persist(
            requestID: requestID,
            preview: preview,
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let inventoryCoordinator = AppTestGhostRepairBulkInventoryCoordinator(
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let challengeCoordinator =
            AppTestGhostRepairBulkConfirmationCoordinator(
                outcome: .ready(challenge)
            )
        let receiptCoordinator =
            AppTestSuspendingGhostRepairBulkReceiptCoordinator(
                expectedPhrase: challenge.confirmationPhrase
            )
        let repairCoordinator =
            AppTestSuspendingGhostRepairBulkRepairCoordinator()
        let model = makeModel(
            sessions: [],
            bulkInventoryCoordinator: inventoryCoordinator,
            bulkPreviewReadbackCoordinator: previewStore,
            bulkConfirmationChallengeCoordinator: challengeCoordinator,
            bulkConfirmationReceiptCoordinator: receiptCoordinator,
            bulkRepairCoordinator: repairCoordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSnapshotReferenceDraft =
            AppTestGhostRepairBulkFixture.snapshotReference
        await model.observeGhostRepairBulkInventory()
        model.selectAllEligibleGhostRepairBulkItems()
        let frozenSelection = model.ghostRepairBulkSelection
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            requestID.uuidString.lowercased()
        await model.readSavedGhostRepairBulkPreview()
        model.presentGhostRepairBulkInventory()
        model.ghostRepairBulkConfirmationPhraseDraft =
            challenge.confirmationPhrase

        let confirmation = Task { @MainActor in
            await model.confirmGhostRepairBulkBatch()
        }
        await receiptCoordinator.waitUntilRequested()

        XCTAssertTrue(model.isGhostRepairBulkProtectedOperationActive)
        XCTAssertTrue(model.isGhostRepairBulkOperationInFlight)
        model.setGhostRepairBulkItemSelected(
            AppTestGhostRepairBulkFixture.eligibleB,
            isSelected: false
        )
        model.clearGhostRepairBulkSelection()
        model.selectAllEligibleGhostRepairBulkItems()
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            UUID().uuidString.lowercased()
        await model.observeGhostRepairBulkInventory()
        await model.readSavedGhostRepairBulkPreview()
        await model.confirmGhostRepairBulkBatch()
        XCTAssertFalse(model.setGhostRepairBulkReconciliationEnabled(false))
        XCTAssertFalse(model.setGhostRepairBulkInventoryPresented(false))
        XCTAssertFalse(model.startNewGhostRepairBulkPreparation())
        XCTAssertEqual(model.ghostRepairBulkSelection, frozenSelection)
        XCTAssertEqual(
            model.ghostRepairBulkSavedPreviewRequestIDDraft,
            requestID.uuidString.lowercased()
        )
        let confirmationRequestCount =
            await receiptCoordinator.requestCount()
        let inventoryRequestCount = await inventoryCoordinator.requestCount()
        XCTAssertEqual(confirmationRequestCount, 1)
        XCTAssertEqual(inventoryRequestCount, 1)

        await receiptCoordinator.finish(with: .confirmed(receipt))
        await confirmation.value
        XCTAssertEqual(
            model.ghostRepairBulkConfirmationReceiptState,
            .confirmed(receipt)
        )
        XCTAssertFalse(model.isGhostRepairBulkOperationInFlight)

        let finalReview = Task { @MainActor in
            await model.prepareGhostRepairBulkFinalReview()
        }
        await repairCoordinator.waitUntilReviewRequested()
        await model.prepareGhostRepairBulkFinalReview()
        model.clearGhostRepairBulkSelection()
        XCTAssertFalse(model.setGhostRepairBulkInventoryPresented(false))
        let suspendedReviewRequestCount =
            await repairCoordinator.reviewRequestCount()
        XCTAssertEqual(suspendedReviewRequestCount, 1)
        XCTAssertEqual(model.ghostRepairBulkSelection, frozenSelection)
        await repairCoordinator.finishReview(with: .ready(review))
        await finalReview.value
        XCTAssertEqual(model.ghostRepairBulkRepairState, .reviewReady(review))

        let execution = Task { @MainActor in
            await model.executeGhostRepairBulkOneShot()
        }
        await repairCoordinator.waitUntilExecutionRequested()
        await model.executeGhostRepairBulkOneShot()
        await model.prepareGhostRepairBulkFinalReview()
        model.setGhostRepairBulkItemSelected(
            AppTestGhostRepairBulkFixture.eligibleA,
            isSelected: false
        )
        XCTAssertFalse(model.setGhostRepairBulkReconciliationEnabled(false))
        let suspendedExecutionRequestCount =
            await repairCoordinator.executionRequestCount()
        let finalReviewRequestCount =
            await repairCoordinator.reviewRequestCount()
        XCTAssertEqual(suspendedExecutionRequestCount, 1)
        XCTAssertEqual(finalReviewRequestCount, 1)
        XCTAssertEqual(model.ghostRepairBulkSelection, frozenSelection)
        await repairCoordinator.finishExecution(with: .completed(report))
        await execution.value

        XCTAssertEqual(model.ghostRepairBulkRepairState, .completed(report))
        XCTAssertTrue(model.isGhostRepairBulkProtectedOperationActive)
        XCTAssertFalse(model.isGhostRepairBulkOperationInFlight)
        XCTAssertNil(model.ghostRepairBulkDismissBlockedReason)
        XCTAssertTrue(model.setGhostRepairBulkInventoryPresented(false))
        XCTAssertTrue(model.setGhostRepairBulkReconciliationEnabled(false))
        XCTAssertEqual(model.ghostRepairBulkRepairState, .completed(report))
        XCTAssertTrue(model.setGhostRepairBulkReconciliationEnabled(true))
        model.presentGhostRepairBulkInventory()
        XCTAssertEqual(model.ghostRepairBulkRepairState, .completed(report))

        XCTAssertTrue(model.startNewGhostRepairBulkPreparation())
        XCTAssertFalse(model.isGhostRepairBulkProtectedOperationActive)
        XCTAssertEqual(model.ghostRepairBulkRepairState, .idle)
        XCTAssertTrue(model.ghostRepairBulkSelection.isEmpty)
    }

    func testBulkTerminalReportMustMatchEveryFrozenIdentityAndCategory()
        async throws
    {
        let requestID = UUID(
            uuidString: "12345678-1234-4234-8234-123456789abc"
        )!
        let operationID = UUID(
            uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: AppTestGhostRepairBulkFixture.inventory,
                selectedThreadIDs: [
                    AppTestGhostRepairBulkFixture.eligibleA,
                    AppTestGhostRepairBulkFixture.eligibleB,
                ],
                generatedAtMilliseconds: 1_000
            )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: operationID,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "f", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let receipt = try CodexGhostRepairBulkConfirmationReceipt(
            receiptID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!,
            challenge: challenge,
            confirmedAtMilliseconds: 3_000
        )
        let review = try CodexGhostRepairBulkFinalReview(
            operationID: operationID,
            confirmationReceiptID: receipt.receiptID,
            selectedCount: 2,
            ordinaryCount: 1,
            automationCount: 1,
            blockedOutsideBatchCount: 1,
            sourceLayoutIdentifier: preview.sourceLayoutIdentifier,
            reviewDigest: "sha256:" + String(repeating: "1", count: 64)
        )
        let wrongCategoryReport = try CodexGhostRepairBulkRepairReport(
            operationID: operationID,
            outcome: .success,
            itemReports: [
                .init(
                    threadID: AppTestGhostRepairBulkFixture.eligibleA,
                    category: .automation,
                    outcome: .success
                ),
                .init(
                    threadID: AppTestGhostRepairBulkFixture.eligibleB,
                    category: .ordinary,
                    outcome: .success
                ),
            ],
            reportDigest: "sha256:" + String(repeating: "2", count: 64)
        )
        let previewStore = AppTestGhostRepairBulkPreviewMemoryStore()
        _ = try await previewStore.persist(
            requestID: requestID,
            preview: preview,
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let challengeCoordinator =
            AppTestGhostRepairBulkConfirmationCoordinator(
                outcome: .ready(challenge)
            )
        let receiptCoordinator =
            AppTestGhostRepairBulkConfirmationReceiptCoordinator(
                expectedPhrase: challenge.confirmationPhrase,
                outcome: .confirmed(receipt)
            )
        let repairCoordinator = AppTestGhostRepairBulkRepairCoordinator(
            reviewOutcome: .ready(review),
            executionOutcome: .completed(wrongCategoryReport)
        )
        let model = makeModel(
            sessions: [],
            bulkPreviewReadbackCoordinator: previewStore,
            bulkConfirmationChallengeCoordinator: challengeCoordinator,
            bulkConfirmationReceiptCoordinator: receiptCoordinator,
            bulkRepairCoordinator: repairCoordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            requestID.uuidString.lowercased()
        await model.readSavedGhostRepairBulkPreview()
        model.ghostRepairBulkConfirmationPhraseDraft =
            challenge.confirmationPhrase
        await model.confirmGhostRepairBulkBatch()
        await model.prepareGhostRepairBulkFinalReview()
        await model.executeGhostRepairBulkOneShot()

        XCTAssertEqual(
            model.ghostRepairBulkRepairState,
            .recoveryRequired(
                operationID: operationID,
                message: "Terminal Report did not match the exact batch. Do not retry."
            )
        )
        XCTAssertFalse(model.setGhostRepairBulkReconciliationEnabled(false))
        XCTAssertFalse(model.startNewGhostRepairBulkPreparation())
        await model.executeGhostRepairBulkOneShot()
        let executionRequestCount =
            await repairCoordinator.executionRequestCount()
        XCTAssertEqual(executionRequestCount, 1)
    }

    func testBulkPreviousOperationsDoesNotSilentlyTruncateOrSelect()
        async
    {
        let coordinator = AppTestGhostRepairBulkRecoveryCoordinator(
            previousOutcome: .limitExceeded(
                limit: 100,
                foundAtLeast: 101,
                message: "Too many exact operations."
            )
        )
        let model = makeModel(
            sessions: [],
            bulkRecoveryCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )

        await model.loadGhostRepairBulkPreviousOperations()

        XCTAssertEqual(
            model.ghostRepairBulkPreviousOperationsState,
            .limitExceeded(
                limit: 100,
                foundAtLeast: 101,
                message: "Too many exact operations."
            )
        )
        XCTAssertTrue(model.ghostRepairBulkPreviousOperations.isEmpty)
        XCTAssertNil(model.ghostRepairBulkSelectedRecoveryOperationIdentity)
        let requestCount = await coordinator.previousRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testBulkRecoveryListAndExactReadbackPreventReentryAndSelectionDrift()
        async throws
    {
        let firstIdentity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: UUID(
                uuidString: "11111111-1111-4111-8111-111111111111"
            )!,
            operationID: UUID(
                uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            )!
        )
        let secondIdentity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: UUID(
                uuidString: "22222222-2222-4222-8222-222222222222"
            )!,
            operationID: UUID(
                uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
            )!
        )
        let firstSummary = CodexGhostRepairBulkRecoveryOperationSummary(
            identity: firstIdentity,
            confirmationReceiptID: UUID(),
            selectedCount: 1,
            phase: .attempted,
            mutationAttemptCount: 1,
            recordedAtMilliseconds: 1_000,
            hasTerminalReport: false
        )
        let secondSummary = CodexGhostRepairBulkRecoveryOperationSummary(
            identity: secondIdentity,
            confirmationReceiptID: UUID(),
            selectedCount: 1,
            phase: .terminal,
            mutationAttemptCount: 1,
            recordedAtMilliseconds: 2_000,
            hasTerminalReport: true
        )
        let secondReport = try CodexGhostRepairBulkRepairReport(
            operationID: secondIdentity.operationID,
            outcome: .success,
            itemReports: [
                .init(
                    threadID: AppTestGhostRepairBulkFixture.eligibleA,
                    category: .ordinary,
                    outcome: .success
                ),
            ],
            reportDigest: "sha256:" + String(repeating: "9", count: 64)
        )
        let coordinator =
            AppTestSuspendingGhostRepairBulkRecoveryCoordinator()
        let model = makeModel(
            sessions: [],
            bulkRecoveryCoordinator: coordinator,
            bulkReconciliationEnabled: true
        )

        let list = Task { @MainActor in
            await model.loadGhostRepairBulkPreviousOperations()
        }
        await coordinator.waitUntilPreviousOperationsRequested()
        await model.loadGhostRepairBulkPreviousOperations()
        await model.confirmGhostRepairBulkBatch()
        await model.prepareGhostRepairBulkFinalReview()
        await model.executeGhostRepairBulkOneShot()
        XCTAssertEqual(model.ghostRepairBulkRepairState, .idle)
        XCTAssertEqual(
            model.ghostRepairBulkConfirmationReceiptState,
            .idle
        )
        let listRequestCount = await coordinator.previousRequestCount()
        XCTAssertEqual(listRequestCount, 1)
        await coordinator.finishPreviousOperations(
            with: .observed([firstSummary, secondSummary])
        )
        await list.value

        XCTAssertEqual(
            model.ghostRepairBulkPreviousOperations,
            [firstSummary, secondSummary]
        )
        XCTAssertNil(model.ghostRepairBulkSelectedRecoveryOperationIdentity)
        model.setGhostRepairBulkRecoveryOperationSelected(secondIdentity)

        let readback = Task { @MainActor in
            await model.readSelectedGhostRepairBulkRecoveryOperation()
        }
        await coordinator.waitUntilOperationRequested()
        await model.readSelectedGhostRepairBulkRecoveryOperation()
        await model.confirmGhostRepairBulkBatch()
        await model.prepareGhostRepairBulkFinalReview()
        await model.executeGhostRepairBulkOneShot()
        model.setGhostRepairBulkRecoveryOperationSelected(firstIdentity)
        let operationRequestCount = await coordinator.operationRequestCount()
        XCTAssertEqual(operationRequestCount, 1)
        XCTAssertEqual(
            model.ghostRepairBulkSelectedRecoveryOperationIdentity,
            secondIdentity
        )
        await coordinator.finishOperation(
            with: .terminal(
                summary: secondSummary,
                report: secondReport
            )
        )
        await readback.value

        XCTAssertEqual(
            model.ghostRepairBulkRecoveryReadbackState,
            .terminal(summary: secondSummary, report: secondReport)
        )
        XCTAssertEqual(model.ghostRepairBulkRepairState, .idle)
    }

    func testFreshRecoveryRetainsSingleRequestAndReplacesStaleProjection()
        async throws
    {
        let identity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: UUID(),
            operationID: UUID()
        )
        let attempted = CodexGhostRepairBulkRecoveryOperationSummary(
            identity: identity,
            confirmationReceiptID: UUID(),
            selectedCount: 1,
            phase: .attempted,
            mutationAttemptCount: 1,
            recordedAtMilliseconds: 1_000,
            hasTerminalReport: false
        )
        let terminal = CodexGhostRepairBulkRecoveryOperationSummary(
            identity: identity,
            confirmationReceiptID: attempted.confirmationReceiptID,
            selectedCount: 1,
            phase: .terminal,
            mutationAttemptCount: 1,
            recordedAtMilliseconds: 2_000,
            hasTerminalReport: true
        )
        let report = try CodexGhostRepairBulkRepairReport(
            operationID: identity.operationID,
            outcome: .success,
            itemReports: [
                .init(
                    threadID: AppTestGhostRepairBulkFixture.eligibleA,
                    category: .ordinary,
                    outcome: .success
                ),
            ],
            reportDigest: "sha256:" + String(repeating: "8", count: 64)
        )
        let durable = AppTestGhostRepairBulkRecoveryCoordinator(
            previousOutcome: .observed([attempted]),
            operationOutcomes: [
                identity: .recoveryRequired(
                    summary: attempted,
                    message: "Original outcome is unresolved."
                ),
            ]
        )
        let fresh = AppTestSuspendingGhostRepairBulkFreshRecoveryCoordinator()
        let model = makeModel(
            sessions: [],
            bulkRecoveryCoordinator: durable,
            bulkFreshRecoveryCoordinator: fresh,
            bulkReconciliationEnabled: true
        )
        await model.loadGhostRepairBulkPreviousOperations()
        model.setGhostRepairBulkRecoveryOperationSelected(identity)
        await model.readSelectedGhostRepairBulkRecoveryOperation()
        guard case .recoveryRequired =
                model.ghostRepairBulkRecoveryReadbackState else {
            return XCTFail("Expected stale durable unresolved projection")
        }

        let request = Task { @MainActor in
            await model.recoverSelectedGhostRepairBulkOperationFreshly()
        }
        await fresh.waitUntilRequested()
        await model.recoverSelectedGhostRepairBulkOperationFreshly()
        model.setGhostRepairBulkRecoveryOperationSelected(nil)
        await model.readSelectedGhostRepairBulkRecoveryOperation()
        let inFlightCount = await fresh.requestCount()
        XCTAssertEqual(inFlightCount, 1)
        XCTAssertEqual(
            model.ghostRepairBulkSelectedRecoveryOperationIdentity,
            identity
        )
        guard case .recovering = model.ghostRepairBulkFreshRecoveryState else {
            return XCTFail("Fresh reentry must not overwrite progress")
        }
        XCTAssertEqual(model.ghostRepairBulkRecoveryReadbackState, .idle)

        await fresh.finish(
            with: .terminal(
                summary: terminal,
                report: report,
                source: .freshlyFinalized
            )
        )
        await request.value

        XCTAssertEqual(
            model.ghostRepairBulkFreshRecoveryState,
            .terminal(
                summary: terminal,
                report: report,
                source: .freshlyFinalized
            )
        )
        XCTAssertEqual(model.ghostRepairBulkPreviousOperations, [terminal])
        XCTAssertEqual(model.ghostRepairBulkRecoveryReadbackState, .idle)
    }

    func testUnknownBulkTerminalReportRemainsRecoveryRequiredAndCannotReset()
        async throws
    {
        let requestID = UUID(
            uuidString: "12345678-1234-4234-8234-123456789abc"
        )!
        let operationID = UUID(
            uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: AppTestGhostRepairBulkFixture.inventory,
                selectedThreadIDs: [
                    AppTestGhostRepairBulkFixture.eligibleA,
                    AppTestGhostRepairBulkFixture.eligibleB,
                ],
                generatedAtMilliseconds: 1_000
            )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: operationID,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "f", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let receipt = try CodexGhostRepairBulkConfirmationReceipt(
            receiptID: UUID(),
            challenge: challenge,
            confirmedAtMilliseconds: 3_000
        )
        let review = try CodexGhostRepairBulkFinalReview(
            operationID: operationID,
            confirmationReceiptID: receipt.receiptID,
            selectedCount: 2,
            ordinaryCount: 1,
            automationCount: 1,
            blockedOutsideBatchCount: 1,
            sourceLayoutIdentifier: preview.sourceLayoutIdentifier,
            reviewDigest: "sha256:" + String(repeating: "1", count: 64)
        )
        let report = try CodexGhostRepairBulkRepairReport(
            operationID: operationID,
            outcome: .unknown,
            itemReports: [
                .init(
                    threadID: AppTestGhostRepairBulkFixture.eligibleA,
                    category: .ordinary,
                    outcome: .unknown
                ),
                .init(
                    threadID: AppTestGhostRepairBulkFixture.eligibleB,
                    category: .automation,
                    outcome: .unknown
                ),
            ],
            reportDigest: "sha256:" + String(repeating: "2", count: 64)
        )
        let resolvedReport = try CodexGhostRepairBulkRepairReport(
            operationID: operationID,
            outcome: .success,
            itemReports: preview.selectedItems.map {
                .init(
                    threadID: $0.threadID,
                    category: $0.category,
                    outcome: .success
                )
            },
            reportDigest: "sha256:" + String(repeating: "3", count: 64)
        )
        let recoveryIdentity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: requestID,
            operationID: operationID
        )
        let recoverySummary = CodexGhostRepairBulkRecoveryOperationSummary(
            identity: recoveryIdentity,
            confirmationReceiptID: receipt.receiptID,
            selectedCount: 2,
            phase: .terminal,
            mutationAttemptCount: 1,
            recordedAtMilliseconds: 4_000,
            hasTerminalReport: true
        )
        let previewStore = AppTestGhostRepairBulkPreviewMemoryStore()
        _ = try await previewStore.persist(
            requestID: requestID,
            preview: preview,
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let challengeCoordinator =
            AppTestGhostRepairBulkConfirmationCoordinator(
                outcome: .ready(challenge)
            )
        let receiptCoordinator =
            AppTestGhostRepairBulkConfirmationReceiptCoordinator(
                expectedPhrase: challenge.confirmationPhrase,
                outcome: .confirmed(receipt)
            )
        let repairCoordinator = AppTestGhostRepairBulkRepairCoordinator(
            reviewOutcome: .ready(review),
            executionOutcome: .completed(report)
        )
        let recoveryCoordinator = AppTestGhostRepairBulkRecoveryCoordinator(
            previousOutcome: .observed([recoverySummary]),
            operationOutcomes: [
                recoveryIdentity: .terminal(
                    summary: recoverySummary,
                    report: resolvedReport
                ),
            ]
        )
        let model = makeModel(
            sessions: [],
            bulkPreviewReadbackCoordinator: previewStore,
            bulkConfirmationChallengeCoordinator: challengeCoordinator,
            bulkConfirmationReceiptCoordinator: receiptCoordinator,
            bulkRepairCoordinator: repairCoordinator,
            bulkRecoveryCoordinator: recoveryCoordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            requestID.uuidString.lowercased()
        await model.readSavedGhostRepairBulkPreview()
        model.ghostRepairBulkConfirmationPhraseDraft =
            challenge.confirmationPhrase
        await model.confirmGhostRepairBulkBatch()
        await model.prepareGhostRepairBulkFinalReview()
        await model.executeGhostRepairBulkOneShot()

        XCTAssertEqual(model.ghostRepairBulkRepairState, .completed(report))
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        XCTAssertNotNil(model.ghostRepairBulkDisableBlockedReason)
        XCTAssertFalse(model.startNewGhostRepairBulkPreparation())
        XCTAssertFalse(model.setGhostRepairBulkReconciliationEnabled(false))
        await model.executeGhostRepairBulkOneShot()
        let executionRequestCount =
            await repairCoordinator.executionRequestCount()
        XCTAssertEqual(executionRequestCount, 1)
        XCTAssertEqual(model.ghostRepairBulkRepairState, .completed(report))

        await model.loadGhostRepairBulkPreviousOperations()
        XCTAssertNil(model.ghostRepairBulkSelectedRecoveryOperationIdentity)
        model.setGhostRepairBulkRecoveryOperationSelected(recoveryIdentity)
        await model.readSelectedGhostRepairBulkRecoveryOperation()
        XCTAssertEqual(
            model.ghostRepairBulkRecoveryReadbackState,
            .terminal(summary: recoverySummary, report: resolvedReport)
        )
        XCTAssertEqual(
            model.ghostRepairBulkRepairState,
            .completed(resolvedReport)
        )
        XCTAssertTrue(model.canStartNewGhostRepairBulkPreparation)
        XCTAssertNil(model.ghostRepairBulkDisableBlockedReason)
    }

    func testPreparedPlanClosureRequiresExactReviewAndNeverExecutes()
        async throws
    {
        let fixture = try makePreparedClosureFixture()
        let closureCoordinator =
            AppTestGhostRepairBulkPreparedClosureCoordinator(
                reviewOutcome: .ready(preview: fixture.closurePreview),
                commitOutcome: .closed(
                    summary: fixture.closedSummary,
                    closure: fixture.closure,
                    newlyClosed: true
                )
            )
        let setup = try await makeCurrentPreparedClosureModel(
            fixture: fixture,
            closureCoordinator: closureCoordinator
        )
        let model = setup.model

        XCTAssertEqual(model.ghostRepairBulkRepairState, .reviewReady(fixture.review))
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        XCTAssertNotNil(model.ghostRepairBulkDisableBlockedReason)

        await model.reviewCurrentGhostRepairBulkPreparedClosure()

        XCTAssertEqual(
            model.ghostRepairBulkPreparedClosureState,
            .reviewReady(fixture.closurePreview)
        )
        XCTAssertEqual(
            fixture.closurePreview.selectedItems.map(\.threadID),
            fixture.preview.selectedItems.map(\.threadID)
        )
        XCTAssertEqual(
            fixture.closurePreview.selectedItems.map(\.category),
            fixture.preview.selectedItems.map(\.category)
        )
        await model.closeGhostRepairBulkPreparedOperation()
        await model.executeGhostRepairBulkOneShot()

        XCTAssertEqual(
            model.ghostRepairBulkPreparedClosureState,
            .closedBeforeAttempt(
                summary: fixture.closedSummary,
                closure: fixture.closure,
                newlyClosed: true
            )
        )
        XCTAssertEqual(
            model.ghostRepairBulkRepairState,
            .closedBeforeAttempt(fixture.closure)
        )
        XCTAssertTrue(model.canStartNewGhostRepairBulkPreparation)
        XCTAssertNil(model.ghostRepairBulkDisableBlockedReason)
        let reviewCount = await closureCoordinator.reviewRequestCount()
        let commitCount = await closureCoordinator.commitRequestCount()
        let executionCount = await setup.repairCoordinator
            .executionRequestCount()
        XCTAssertEqual(reviewCount, 1)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(executionCount, 0)
    }

    func testPreparedPlanClosureUncertaintyRetainsExactContextUntilReadback()
        async throws
    {
        let fixture = try makePreparedClosureFixture()
        let closureCoordinator =
            AppTestSuspendingGhostRepairBulkPreparedClosureCoordinator(
                reviewOutcome: .ready(preview: fixture.closurePreview)
            )
        let recoveryCoordinator = AppTestGhostRepairBulkRecoveryCoordinator(
            previousOutcome: .observed([fixture.preparedSummary]),
            operationOutcomes: [
                fixture.closedSummary.identity: .closedBeforeAttempt(
                    summary: fixture.closedSummary,
                    closure: fixture.closure
                ),
            ]
        )
        let setup = try await makeCurrentPreparedClosureModel(
            fixture: fixture,
            closureCoordinator: closureCoordinator,
            recoveryCoordinator: recoveryCoordinator
        )
        let model = setup.model
        await model.reviewCurrentGhostRepairBulkPreparedClosure()

        let close = Task { @MainActor in
            await model.closeGhostRepairBulkPreparedOperation()
        }
        await closureCoordinator.waitUntilCommitRequested()
        await model.closeGhostRepairBulkPreparedOperation()
        await model.executeGhostRepairBulkOneShot()
        XCTAssertFalse(model.startNewGhostRepairBulkPreparation())
        XCTAssertFalse(model.setGhostRepairBulkReconciliationEnabled(false))
        XCTAssertFalse(model.setGhostRepairBulkInventoryPresented(false))
        let suspendedCommitCount = await closureCoordinator.commitRequestCount()
        XCTAssertEqual(suspendedCommitCount, 1)
        let suspendedExecutionCount = await setup.repairCoordinator
            .executionRequestCount()
        XCTAssertEqual(suspendedExecutionCount, 0)

        await closureCoordinator.finishCommit(
            with: .persistenceUncertain(
                identity: fixture.closedSummary.identity,
                message: "Commit acknowledgement was lost."
            )
        )
        await close.value

        XCTAssertEqual(
            model.ghostRepairBulkPreparedClosureState,
            .persistenceUncertain(
                preview: fixture.closurePreview,
                message: "Commit acknowledgement was lost."
            )
        )
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        XCTAssertNotNil(model.ghostRepairBulkDisableBlockedReason)
        XCTAssertTrue(model.setGhostRepairBulkInventoryPresented(false))
        model.presentGhostRepairBulkInventory()
        XCTAssertEqual(
            model.ghostRepairBulkPreparedClosureState,
            .persistenceUncertain(
                preview: fixture.closurePreview,
                message: "Commit acknowledgement was lost."
            )
        )

        await model.readUncertainGhostRepairBulkPreparedClosure()

        XCTAssertEqual(
            model.ghostRepairBulkPreparedClosureState,
            .closedBeforeAttempt(
                summary: fixture.closedSummary,
                closure: fixture.closure,
                newlyClosed: false
            )
        )
        XCTAssertTrue(model.canStartNewGhostRepairBulkPreparation)
        let durableReadCount = await recoveryCoordinator
            .operationRequestCount()
        XCTAssertEqual(durableReadCount, 1)
    }

    func testPreparedPlanClosedByAnotherReviewConvergesThroughCurrentExactRead()
        async throws
    {
        let fixture = try makePreparedClosureFixture()
        let alternate = try makeAlternatePreparedClosureEvidence(
            fixture: fixture
        )
        XCTAssertNotEqual(
            alternate.closure.closureReviewID,
            fixture.closure.closureReviewID
        )
        XCTAssertNotEqual(
            alternate.closure.reviewDigest,
            fixture.closure.reviewDigest
        )
        let closureCoordinator =
            AppTestGhostRepairBulkPreparedClosureCoordinator(
                reviewOutcome: .ready(preview: fixture.closurePreview),
                commitOutcome: .notClosable(
                    summary: fixture.closedSummary,
                    message: "Another app already closed this prepared plan."
                )
            )
        let recoveryCoordinator = AppTestGhostRepairBulkRecoveryCoordinator(
            previousOutcome: .observed([]),
            operationOutcomes: [
                fixture.closedSummary.identity: .closedBeforeAttempt(
                    summary: alternate.summary,
                    closure: alternate.closure
                ),
            ]
        )
        let setup = try await makeCurrentPreparedClosureModel(
            fixture: fixture,
            closureCoordinator: closureCoordinator,
            recoveryCoordinator: recoveryCoordinator
        )
        let model = setup.model

        await model.reviewCurrentGhostRepairBulkPreparedClosure()
        await model.closeGhostRepairBulkPreparedOperation()

        guard case .recoveryRequired =
                model.ghostRepairBulkPreparedClosureState else {
            return XCTFail("Definite concurrent closure must require exact readback")
        }
        XCTAssertNil(model.ghostRepairBulkSelectedRecoveryOperationIdentity)
        XCTAssertNil(model.ghostRepairBulkPreparedClosureRecoveryBlockedReason)
        await model.readUncertainGhostRepairBulkPreparedClosure()

        XCTAssertEqual(
            model.ghostRepairBulkPreparedClosureState,
            .closedBeforeAttempt(
                summary: alternate.summary,
                closure: alternate.closure,
                newlyClosed: false
            )
        )
        XCTAssertEqual(
            model.ghostRepairBulkRepairState,
            .closedBeforeAttempt(alternate.closure)
        )
        XCTAssertTrue(model.canStartNewGhostRepairBulkPreparation)
        let readCount = await recoveryCoordinator.operationRequestCount()
        let executionCount = await setup.repairCoordinator
            .executionRequestCount()
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(executionCount, 0)
    }

    func testConcurrentPreparedClosureDriftRemainsOnOriginalRecoveryContext()
        async throws
    {
        let fixture = try makePreparedClosureFixture()
        let originalItems = fixture.closurePreview.selectedItems
        let driftedEvidence = try [
            makeAlternatePreparedClosureEvidence(
                fixture: fixture,
                confirmationReceiptID: UUID()
            ),
            makeAlternatePreparedClosureEvidence(
                fixture: fixture,
                selectedItems: Array(originalItems.reversed())
            ),
            makeAlternatePreparedClosureEvidence(
                fixture: fixture,
                planDigest: "sha256:" + String(repeating: "1", count: 64)
            ),
            makeAlternatePreparedClosureEvidence(
                fixture: fixture,
                confirmationReceiptDigest:
                    "sha256:" + String(repeating: "2", count: 64)
            ),
            makeAlternatePreparedClosureEvidence(
                fixture: fixture,
                backupReceiptDigest:
                    "sha256:" + String(repeating: "3", count: 64)
            ),
            makeAlternatePreparedClosureEvidence(
                fixture: fixture,
                expectedJournalPayloadHash:
                    "sha256:" + String(repeating: "4", count: 64)
            ),
        ]

        for drifted in driftedEvidence {
            let closureCoordinator =
                AppTestGhostRepairBulkPreparedClosureCoordinator(
                    reviewOutcome: .ready(
                        preview: fixture.closurePreview
                    ),
                    commitOutcome: .notClosable(
                        summary: fixture.closedSummary,
                        message: "Another app already closed this prepared plan."
                    )
                )
            let recoveryCoordinator =
                AppTestGhostRepairBulkRecoveryCoordinator(
                    previousOutcome: .observed([]),
                    operationOutcomes: [
                        fixture.closedSummary.identity:
                            .closedBeforeAttempt(
                                summary: drifted.summary,
                                closure: drifted.closure
                            ),
                    ]
                )
            let setup = try await makeCurrentPreparedClosureModel(
                fixture: fixture,
                closureCoordinator: closureCoordinator,
                recoveryCoordinator: recoveryCoordinator
            )
            let model = setup.model
            await model.reviewCurrentGhostRepairBulkPreparedClosure()
            await model.closeGhostRepairBulkPreparedOperation()
            await model.readUncertainGhostRepairBulkPreparedClosure()

            guard case let .recoveryRequired(summary, _) =
                    model.ghostRepairBulkPreparedClosureState else {
                return XCTFail("Drifted closure must retain recovery-required")
            }
            XCTAssertEqual(summary, fixture.closedSummary)
            XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
            XCTAssertNotNil(model.ghostRepairBulkDisableBlockedReason)
            let executionCount = await setup.repairCoordinator
                .executionRequestCount()
            XCTAssertEqual(executionCount, 0)
        }
    }

    func testUnknownOwnClosureDoesNotAcceptAnotherReviewOfSamePlan()
        async throws
    {
        let fixture = try makePreparedClosureFixture()
        let alternate = try makeAlternatePreparedClosureEvidence(
            fixture: fixture
        )
        let closureCoordinator =
            AppTestGhostRepairBulkPreparedClosureCoordinator(
                reviewOutcome: .ready(preview: fixture.closurePreview),
                commitOutcome: .persistenceUncertain(
                    identity: fixture.closedSummary.identity,
                    message: "Commit acknowledgement was lost."
                )
            )
        let recoveryCoordinator = AppTestGhostRepairBulkRecoveryCoordinator(
            previousOutcome: .observed([]),
            operationOutcomes: [
                fixture.closedSummary.identity: .closedBeforeAttempt(
                    summary: alternate.summary,
                    closure: alternate.closure
                ),
            ]
        )
        let setup = try await makeCurrentPreparedClosureModel(
            fixture: fixture,
            closureCoordinator: closureCoordinator,
            recoveryCoordinator: recoveryCoordinator
        )
        let model = setup.model
        await model.reviewCurrentGhostRepairBulkPreparedClosure()
        await model.closeGhostRepairBulkPreparedOperation()
        await model.readUncertainGhostRepairBulkPreparedClosure()

        guard case let .persistenceUncertain(preview, _) =
                model.ghostRepairBulkPreparedClosureState else {
            return XCTFail("Own uncertain commit requires its exact review evidence")
        }
        XCTAssertEqual(preview, fixture.closurePreview)
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        let executionCount = await setup.repairCoordinator
            .executionRequestCount()
        XCTAssertEqual(executionCount, 0)
    }

    func testLatePreparedClosureResultWithWrongReceiptLineageDoesNotUnlock()
        async throws
    {
        let fixture = try makePreparedClosureFixture()
        let wrongLineage = try makePreparedClosureFixture(
            requestID: fixture.requestID,
            operationID: fixture.operationID,
            receiptID: UUID()
        )
        let closureCoordinator =
            AppTestSuspendingGhostRepairBulkPreparedClosureCoordinator(
                reviewOutcome: .ready(preview: fixture.closurePreview)
            )
        let setup = try await makeCurrentPreparedClosureModel(
            fixture: fixture,
            closureCoordinator: closureCoordinator
        )
        let model = setup.model
        await model.reviewCurrentGhostRepairBulkPreparedClosure()

        let close = Task { @MainActor in
            await model.closeGhostRepairBulkPreparedOperation()
        }
        await closureCoordinator.waitUntilCommitRequested()
        await closureCoordinator.finishCommit(
            with: .closed(
                summary: wrongLineage.closedSummary,
                closure: wrongLineage.closure,
                newlyClosed: true
            )
        )
        await close.value

        guard case let .persistenceUncertain(preview, message) =
                model.ghostRepairBulkPreparedClosureState else {
            return XCTFail("Mismatched late closure evidence must remain unknown")
        }
        XCTAssertEqual(preview, fixture.closurePreview)
        XCTAssertTrue(message.contains("different exact operation"))
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        XCTAssertNotNil(model.ghostRepairBulkDisableBlockedReason)
        await model.closeGhostRepairBulkPreparedOperation()
        await model.executeGhostRepairBulkOneShot()
        let commitCount = await closureCoordinator.commitRequestCount()
        let executionCount = await setup.repairCoordinator
            .executionRequestCount()
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(executionCount, 0)
    }

    func testPreparedClosureReadOnlyMismatchRetainsOriginalReviewAuthority()
        async throws
    {
        let fixture = try makePreparedClosureFixture()
        let wrongLineage = try makePreparedClosureFixture(
            requestID: fixture.requestID,
            operationID: fixture.operationID,
            receiptID: UUID()
        )
        let closureCoordinator =
            AppTestGhostRepairBulkPreparedClosureCoordinator(
                reviewOutcome: .alreadyClosed(
                    summary: wrongLineage.closedSummary,
                    closure: wrongLineage.closure
                ),
                commitOutcome: .unavailable(message: "Unused")
            )
        let setup = try await makeCurrentPreparedClosureModel(
            fixture: fixture,
            closureCoordinator: closureCoordinator
        )
        let model = setup.model

        await model.reviewCurrentGhostRepairBulkPreparedClosure()

        guard case .unavailable =
                model.ghostRepairBulkPreparedClosureState else {
            return XCTFail("Mismatched read-only closure evidence must fail closed")
        }
        XCTAssertEqual(
            model.ghostRepairBulkRepairState,
            .reviewReady(fixture.review)
        )
        XCTAssertNil(model.ghostRepairBulkExecutionBlockedReason)
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        let commitCount = await closureCoordinator.commitRequestCount()
        XCTAssertEqual(commitCount, 0)
    }

    func testDurableAndFreshClosedReadbackCannotReplaceOrdinaryProtectedLineage()
        async throws
    {
        let fixture = try makePreparedClosureFixture()
        let wrongLineage = try makePreparedClosureFixture(
            requestID: fixture.requestID,
            operationID: fixture.operationID,
            receiptID: UUID()
        )
        let unusedClosureCoordinator =
            AppTestGhostRepairBulkPreparedClosureCoordinator(
                reviewOutcome: .unavailable(message: "Unused"),
                commitOutcome: .unavailable(message: "Unused")
            )
        let durable = AppTestGhostRepairBulkRecoveryCoordinator(
            previousOutcome: .observed([wrongLineage.closedSummary]),
            operationOutcomes: [
                wrongLineage.closedSummary.identity: .closedBeforeAttempt(
                    summary: wrongLineage.closedSummary,
                    closure: wrongLineage.closure
                ),
            ]
        )
        let durableSetup = try await makeCurrentPreparedClosureModel(
            fixture: fixture,
            closureCoordinator: unusedClosureCoordinator,
            recoveryCoordinator: durable
        )
        await durableSetup.model.loadGhostRepairBulkPreviousOperations()
        durableSetup.model.setGhostRepairBulkRecoveryOperationSelected(
            fixture.preparedSummary.identity
        )
        await durableSetup.model.readSelectedGhostRepairBulkRecoveryOperation()

        guard case .unavailable =
                durableSetup.model.ghostRepairBulkRecoveryReadbackState else {
            return XCTFail("Durable wrong-lineage closure must be rejected")
        }
        XCTAssertEqual(
            durableSetup.model.ghostRepairBulkRepairState,
            .reviewReady(fixture.review)
        )

        let fresh = AppTestGhostRepairBulkFreshRecoveryCoordinator(
            outcomes: [
                wrongLineage.closedSummary.identity: .closedBeforeAttempt(
                    summary: wrongLineage.closedSummary,
                    closure: wrongLineage.closure
                ),
            ]
        )
        let freshReadySetup = try await makeCurrentPreparedClosureModel(
            fixture: fixture,
            closureCoordinator: unusedClosureCoordinator,
            recoveryCoordinator: AppTestGhostRepairBulkRecoveryCoordinator(
                previousOutcome: .observed([
                    wrongLineage.closedSummary,
                ])
            ),
            freshRecoveryCoordinator: fresh
        )
        await freshReadySetup.model.loadGhostRepairBulkPreviousOperations()
        freshReadySetup.model.setGhostRepairBulkRecoveryOperationSelected(
            fixture.preparedSummary.identity
        )
        await freshReadySetup.model
            .recoverSelectedGhostRepairBulkOperationFreshly()

        guard case .unavailable =
                freshReadySetup.model.ghostRepairBulkFreshRecoveryState else {
            return XCTFail("Fresh wrong-lineage closure must be rejected")
        }
        XCTAssertEqual(
            freshReadySetup.model.ghostRepairBulkRepairState,
            .reviewReady(fixture.review)
        )

        let terminalReport = try CodexGhostRepairBulkRepairReport(
            operationID: fixture.operationID,
            outcome: .success,
            itemReports: fixture.preview.selectedItems.map {
                .init(
                    threadID: $0.threadID,
                    category: $0.category,
                    outcome: .success
                )
            },
            reportDigest: "sha256:" + String(repeating: "9", count: 64)
        )
        let terminalSetup = try await makeCurrentPreparedClosureModel(
            fixture: fixture,
            closureCoordinator: unusedClosureCoordinator,
            recoveryCoordinator: AppTestGhostRepairBulkRecoveryCoordinator(
                previousOutcome: .observed([fixture.closedSummary]),
                operationOutcomes: [
                    fixture.closedSummary.identity: .closedBeforeAttempt(
                        summary: fixture.closedSummary,
                        closure: fixture.closure
                    ),
                ]
            ),
            executionOutcome: .completed(terminalReport)
        )
        await terminalSetup.model.executeGhostRepairBulkOneShot()
        XCTAssertEqual(
            terminalSetup.model.ghostRepairBulkRepairState,
            .completed(terminalReport)
        )
        await terminalSetup.model.loadGhostRepairBulkPreviousOperations()
        terminalSetup.model.setGhostRepairBulkRecoveryOperationSelected(
            fixture.closedSummary.identity
        )
        await terminalSetup.model.readSelectedGhostRepairBulkRecoveryOperation()
        guard case .unavailable =
                terminalSetup.model.ghostRepairBulkRecoveryReadbackState else {
            return XCTFail("Closed-before-attempt cannot replace terminal evidence")
        }
        XCTAssertEqual(
            terminalSetup.model.ghostRepairBulkRepairState,
            .completed(terminalReport)
        )
    }

    func testPreparedClosureUncertainTerminalReadbackConvergesByOutcome()
        async throws
    {
        for outcome in [
            CodexGhostRepairBulkRepairObservedOutcome.success,
            .unknown,
        ] {
            let fixture = try makePreparedClosureFixture()
            let report = try CodexGhostRepairBulkRepairReport(
                operationID: fixture.operationID,
                outcome: outcome,
                itemReports: fixture.preview.selectedItems.map {
                    .init(
                        threadID: $0.threadID,
                        category: $0.category,
                        outcome: outcome == .success ? .success : .unknown
                    )
                },
                reportDigest:
                    "sha256:" + String(
                        repeating: outcome == .success ? "e" : "f",
                        count: 64
                    )
            )
            let terminalSummary =
                CodexGhostRepairBulkRecoveryOperationSummary(
                    identity: fixture.preparedSummary.identity,
                    confirmationReceiptID: fixture.receipt.receiptID,
                    selectedCount: fixture.preview.selectedItems.count,
                    phase: .terminal,
                    mutationAttemptCount: 1,
                    recordedAtMilliseconds: 7_000,
                    hasTerminalReport: true
                )
            let recoveryCoordinator =
                AppTestGhostRepairBulkRecoveryCoordinator(
                    previousOutcome: .observed([fixture.preparedSummary]),
                    operationOutcomes: [
                        fixture.preparedSummary.identity: .terminal(
                            summary: terminalSummary,
                            report: report
                        ),
                    ]
                )
            let closureCoordinator =
                AppTestGhostRepairBulkPreparedClosureCoordinator(
                    reviewOutcome: .ready(
                        preview: fixture.closurePreview
                    ),
                    commitOutcome: .persistenceUncertain(
                        identity: fixture.preparedSummary.identity,
                        message: "Commit result is unknown."
                    )
                )
            let setup = try await makeCurrentPreparedClosureModel(
                fixture: fixture,
                closureCoordinator: closureCoordinator,
                recoveryCoordinator: recoveryCoordinator
            )
            let model = setup.model
            await model.reviewCurrentGhostRepairBulkPreparedClosure()
            await model.closeGhostRepairBulkPreparedOperation()
            await model.readUncertainGhostRepairBulkPreparedClosure()

            XCTAssertEqual(model.ghostRepairBulkRepairState, .completed(report))
            XCTAssertEqual(model.ghostRepairBulkPreparedClosureState, .idle)
            XCTAssertEqual(
                model.canStartNewGhostRepairBulkPreparation,
                outcome == .success
            )
        }
    }

    func testColdPreparedClosureUncertaintyCannotLoseSelectionAndConverges()
        async throws
    {
        let fixture = try makePreparedClosureFixture()
        let recoveryCoordinator = AppTestGhostRepairBulkRecoveryCoordinator(
            previousOutcome: .observed([fixture.preparedSummary]),
            operationOutcomes: [
                fixture.preparedSummary.identity: .closedBeforeAttempt(
                    summary: fixture.closedSummary,
                    closure: fixture.closure
                ),
            ]
        )
        let closureCoordinator =
            AppTestGhostRepairBulkPreparedClosureCoordinator(
                reviewOutcome: .ready(preview: fixture.closurePreview),
                commitOutcome: .persistenceUncertain(
                    identity: fixture.preparedSummary.identity,
                    message: "Commit result is unknown."
                )
            )
        let model = makeModel(
            sessions: [],
            bulkRecoveryCoordinator: recoveryCoordinator,
            bulkPreparedClosureCoordinator: closureCoordinator,
            bulkReconciliationEnabled: true
        )
        await model.loadGhostRepairBulkPreviousOperations()
        model.setGhostRepairBulkRecoveryOperationSelected(
            fixture.preparedSummary.identity
        )
        await model.reviewSelectedGhostRepairBulkPreparedClosure()
        await model.closeGhostRepairBulkPreparedOperation()

        model.setGhostRepairBulkRecoveryOperationSelected(nil)
        XCTAssertEqual(
            model.ghostRepairBulkSelectedRecoveryOperationIdentity,
            fixture.preparedSummary.identity
        )
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        await model.readUncertainGhostRepairBulkPreparedClosure()

        XCTAssertEqual(
            model.ghostRepairBulkPreviousOperations,
            [fixture.closedSummary]
        )
        XCTAssertEqual(
            model.ghostRepairBulkPreparedClosureState,
            .closedBeforeAttempt(
                summary: fixture.closedSummary,
                closure: fixture.closure,
                newlyClosed: false
            )
        )
        XCTAssertTrue(model.canStartNewGhostRepairBulkPreparation)
    }

    func testNativeDeleteDesktopCleanupQueuesOnlyExactSuccessfulAbsentItems()
        throws
    {
        let successfulID = AppTestGhostRepairBulkFixture.eligibleA
        let failedID = AppTestGhostRepairBulkFixture.eligibleB
        let unverifiedID = AppTestGhostRepairBulkFixture.blocked
        let report = makeNativeDeleteReport(items: [
            (successfulID, .success, .absent),
            (failedID, .failure, .absent),
            (unverifiedID, .success, .unavailable),
        ])
        let model = makeModel(
            sessions: [],
            nativeDeleteDesktopCleanupCoordinator:
                AppTestDesktopCleanupLinkageCoordinator(),
            bulkReconciliationEnabled: true
        )
        model.latestNativeDeleteReport = report

        XCTAssertNil(
            model.nativeDeleteDesktopCleanupBlockedReason(report: report)
        )
        model.queueNativeDeleteDesktopCleanup(report: report)

        guard case let .queued(context) =
                model.nativeDeleteDesktopCleanupState else {
            return XCTFail("Expected an exact queued Desktop cleanup handoff.")
        }
        XCTAssertEqual(context.expectedNativeSessionIDs, [successfulID])
        XCTAssertEqual(context.nativeDeleteItemCount, 3)
        XCTAssertTrue(context.isPartialNativeDeleteSuccess)
        XCTAssertEqual(
            model.nativeDeleteDesktopCleanupTargets.map(\.nativeSessionID),
            [successfulID]
        )
        XCTAssertTrue(
            model.nativeDeleteDesktopCleanupSummary?.contains("1 successful items out of 3") == true
        )
        model.presentQueuedNativeDeleteDesktopCleanup()
        XCTAssertTrue(model.isGhostRepairBulkInventoryPresented)
    }

    func testNativeDeleteDesktopCleanupPreparationSelectsExactAllEligibleScope()
        async throws
    {
        let ids = [
            AppTestGhostRepairBulkFixture.eligibleA,
            AppTestGhostRepairBulkFixture.eligibleB,
        ]
        let report = makeNativeDeleteReport(
            items: ids.map { ($0, .success, .absent) }
        )
        let handoff = try makeDesktopCleanupHandoff(
            reportID: report.id,
            nativeSessionIDs: ids
        )
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let linkage = AppTestDesktopCleanupLinkageCoordinator(
            statusOutcomes: [.status(.pending(handoff))]
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: AppTestGhostRepairSafetySource(
                snapshot: makeGhostRepairSnapshot(
                    targetIDs: ids,
                    executionGate: gate
                )
            ),
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            ghostRepairSnapshotCoordinator:
                AppTestGhostRepairSnapshotActionCoordinator(
                    outcomes: [.succeeded(
                        reference: AppTestGhostRepairBulkFixture
                            .snapshotReference
                    )]
                ),
            bulkInventoryCoordinator:
                AppTestGhostRepairBulkInventoryCoordinator(
                    inventory: AppTestGhostRepairBulkFixture.inventory
                ),
            nativeDeleteDesktopCleanupCoordinator: linkage,
            bulkReconciliationEnabled: true
        )
        model.sessionRows = ids.map { makeDeletedPresentation(nativeID: $0) }
        model.latestNativeDeleteReport = report
        model.queueNativeDeleteDesktopCleanup(report: report)

        await model.prepareGhostRepairBulkInventory()

        XCTAssertEqual(model.ghostRepairBulkSelection, Set(ids))
        XCTAssertEqual(
            model.nativeDeleteDesktopCleanupState,
            .inventoryReady(
                NativeDeleteDesktopCleanupContext(
                    canonicalDeleteReportID: report.id,
                    expectedNativeSessionIDs: ids,
                    nativeDeleteItemCount: ids.count
                ),
                handoff
            )
        )
        model.clearGhostRepairBulkSelection()
        XCTAssertEqual(model.ghostRepairBulkSelection, Set(ids))
        XCTAssertNotNil(model.nativeDeleteDesktopCleanupSelectionBlockedReason)
        let reviewRequestCount = await linkage.reviewRequestCount()
        XCTAssertEqual(reviewRequestCount, 0)
    }

    func testNativeDeleteDesktopCleanupBlocksWholeScopeWhenOneItemIsNotGhost()
        async throws
    {
        let ids = [
            AppTestGhostRepairBulkFixture.eligibleA,
            AppTestGhostRepairBulkFixture.notGhost,
        ].sorted()
        let report = makeNativeDeleteReport(
            items: ids.map { ($0, .success, .absent) }
        )
        let handoff = try makeDesktopCleanupHandoff(
            reportID: report.id,
            nativeSessionIDs: ids
        )
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let model = makeModel(
            sessions: [],
            ghostRepairSource: AppTestGhostRepairSafetySource(
                snapshot: makeGhostRepairSnapshot(
                    targetIDs: ids,
                    executionGate: gate
                )
            ),
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            ghostRepairSnapshotCoordinator:
                AppTestGhostRepairSnapshotActionCoordinator(
                    outcomes: [.succeeded(
                        reference: AppTestGhostRepairBulkFixture
                            .snapshotReference
                    )]
                ),
            bulkInventoryCoordinator:
                AppTestGhostRepairBulkInventoryCoordinator(
                    inventory: AppTestGhostRepairBulkFixture.inventory
                ),
            nativeDeleteDesktopCleanupCoordinator:
                AppTestDesktopCleanupLinkageCoordinator(
                    statusOutcomes: [.status(.pending(handoff))]
                ),
            bulkReconciliationEnabled: true
        )
        model.sessionRows = ids.map { makeDeletedPresentation(nativeID: $0) }
        model.latestNativeDeleteReport = report
        model.queueNativeDeleteDesktopCleanup(report: report)

        await model.prepareGhostRepairBulkInventory()

        guard case let .inventoryBlocked(_, _, targets, _) =
                model.nativeDeleteDesktopCleanupState else {
            return XCTFail("A non-eligible requested ID must block the scope.")
        }
        XCTAssertTrue(model.ghostRepairBulkSelection.isEmpty)
        XCTAssertEqual(
            targets.first { $0.nativeSessionID == ids[1] }?.state,
            .blocked
        )
        await model.buildGhostRepairBulkPreview()
        guard case .unavailable = model.ghostRepairBulkPreviewState else {
            return XCTFail("Blocked exact scope must not create a Preview.")
        }
    }

    func testNativeDeleteDesktopCleanupBindingUnknownRetainsIdentityAndCannotExecute()
        async throws
    {
        let ids = [
            AppTestGhostRepairBulkFixture.eligibleA,
            AppTestGhostRepairBulkFixture.eligibleB,
        ]
        let report = makeNativeDeleteReport(
            items: ids.map { ($0, .success, .absent) }
        )
        let handoff = try makeDesktopCleanupHandoff(
            reportID: report.id,
            nativeSessionIDs: ids
        )
        let wrongBinding = try CodexDesktopCleanupBinding(
            canonicalDeleteReportID: report.id,
            handoffDigest: handoff.handoffDigest,
            bulkIdentity: .init(requestID: UUID(), operationID: UUID()),
            confirmationReceiptID: UUID(),
            confirmationReceiptDigest:
                "sha256:" + String(repeating: "1", count: 64),
            planDigest: "sha256:" + String(repeating: "2", count: 64),
            backupReceiptDigest:
                "sha256:" + String(repeating: "3", count: 64),
            preparedJournalPayloadHash:
                "sha256:" + String(repeating: "4", count: 64),
            items: try handoff.items.enumerated().map { index, item in
                try CodexDesktopCleanupBindingItem(
                    managerKey: item.managerKey,
                    nativeSessionID: item.nativeSessionID,
                    deletedAtMilliseconds: item.deletedAtMilliseconds,
                    category: index == 0 ? .ordinary : .automation
                )
            },
            boundAtMilliseconds: 2_000_000
        )
        let linkage = AppTestDesktopCleanupLinkageCoordinator(
            bindOutcomes: [
                .finalizationOutcomeUnknown(
                    reportID: report.id,
                    message: "Post-commit readback was interrupted."
                ),
            ],
            statusOutcomes: [
                .status(.pending(handoff)),
                .status(.pending(handoff)),
                .status(.prepared(handoff, wrongBinding)),
            ]
        )
        let gate = CodexGhostRepairExecutionGate
            .completeFiveDatabaseClearForBulkTests
        let previewStore = AppTestGhostRepairBulkPreviewMemoryStore()
        let challengeCoordinator =
            AppTestDynamicGhostRepairBulkConfirmationCoordinator(
                previewStore: previewStore
            )
        let receiptCoordinator =
            AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator(
                challengeCoordinator: challengeCoordinator
            )
        let repairCoordinator = AppTestDynamicGhostRepairBulkRepairCoordinator(
            previewStore: previewStore,
            receiptCoordinator: receiptCoordinator
        )
        let model = makeModel(
            sessions: [],
            ghostRepairSource: AppTestGhostRepairSafetySource(
                snapshot: makeGhostRepairSnapshot(
                    targetIDs: ids,
                    executionGate: gate
                )
            ),
            ghostRepairOperationalGateSource:
                AppTestGhostRepairOperatingGateSource(gate: gate),
            ghostRepairSnapshotCoordinator:
                AppTestGhostRepairSnapshotActionCoordinator(
                    outcomes: [.succeeded(
                        reference: AppTestGhostRepairBulkFixture
                            .snapshotReference
                    )]
                ),
            bulkInventoryCoordinator:
                AppTestGhostRepairBulkInventoryCoordinator(
                    inventory: AppTestGhostRepairBulkFixture.inventory
                ),
            bulkPreviewPersister: previewStore,
            bulkPreviewReadbackCoordinator: previewStore,
            bulkConfirmationChallengeCoordinator: challengeCoordinator,
            bulkConfirmationReceiptCoordinator: receiptCoordinator,
            bulkRepairCoordinator: repairCoordinator,
            nativeDeleteDesktopCleanupCoordinator: linkage,
            bulkReconciliationEnabled: true
        )
        model.sessionRows = ids.map { makeDeletedPresentation(nativeID: $0) }
        model.latestNativeDeleteReport = report
        model.queueNativeDeleteDesktopCleanup(report: report)
        await model.prepareGhostRepairBulkInventory()
        await model.buildGhostRepairBulkPreview()
        guard case let .ready(challenge) =
                model.ghostRepairBulkConfirmationChallengeState else {
            return XCTFail("Expected the exact handoff challenge.")
        }
        model.ghostRepairBulkConfirmationPhraseDraft =
            challenge.confirmationPhrase
        await model.confirmGhostRepairBulkBatch()
        await model.prepareGhostRepairBulkFinalReview()

        guard case let .bindingRecoveryRequired(
            _, retainedHandoff, retainedIdentity, _
        ) = model.nativeDeleteDesktopCleanupState else {
            return XCTFail("Unknown binding must retain exact recovery state.")
        }
        XCTAssertEqual(retainedHandoff, handoff)
        XCTAssertEqual(retainedIdentity.operationID, challenge.operationID)
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        XCTAssertNotNil(model.ghostRepairBulkExecutionBlockedReason)

        await model.executeGhostRepairBulkOneShot()
        await model.readNativeDeleteDesktopCleanupStatus()

        guard case let .bindingRecoveryRequired(
            _, readbackHandoff, readbackIdentity, _
        ) = model.nativeDeleteDesktopCleanupState else {
            return XCTFail("A pending readback must not discard bind identity.")
        }
        XCTAssertEqual(readbackHandoff, handoff)
        XCTAssertEqual(readbackIdentity, retainedIdentity)
        XCTAssertFalse(model.canStartNewGhostRepairBulkPreparation)
        await model.readNativeDeleteDesktopCleanupStatus()
        guard case let .bindingRecoveryRequired(
            _, driftHandoff, driftIdentity, _
        ) = model.nativeDeleteDesktopCleanupState else {
            return XCTFail("A different binding must retain original identity.")
        }
        XCTAssertEqual(driftHandoff, handoff)
        XCTAssertEqual(driftIdentity, retainedIdentity)
        let bindCount = await linkage.bindRequestCount()
        let statusCount = await linkage.statusRequestCount()
        let executionCount = await repairCoordinator.executionRequestCount()
        XCTAssertEqual(bindCount, 1)
        XCTAssertEqual(statusCount, 3)
        XCTAssertEqual(executionCount, 0)
    }

    func testSnapshotCleanupPresentationPerformsInspectionOnly() async {
        let item = AppTestGhostRepairSnapshotCleanupFixture.item
        let inventory = AppTestGhostRepairSnapshotCleanupFixture.inventory(
            item: item
        )
        let coordinator = AppTestGhostRepairSnapshotCleanupCoordinator(
            inspectionOutcomes: [.observed(inventory)]
        )
        let model = makeModel(
            sessions: [],
            snapshotCleanupCoordinator: coordinator
        )

        await model.presentGhostRepairSnapshotCleanup()

        XCTAssertTrue(model.isGhostRepairSnapshotCleanupPresented)
        XCTAssertEqual(model.ghostRepairSnapshotCleanupState, .observed(inventory))
        let inspectionCount = await coordinator.inspectionCount()
        let preparationCount = await coordinator.preparationCount()
        let executionCount = await coordinator.executionCount()
        XCTAssertEqual(inspectionCount, 1)
        XCTAssertEqual(preparationCount, 0)
        XCTAssertEqual(executionCount, 0)
    }

    func testSnapshotCleanupRequiresReviewAndDoesNotRetryRecovery() async {
        let item = AppTestGhostRepairSnapshotCleanupFixture.item
        let inventory = AppTestGhostRepairSnapshotCleanupFixture.inventory(
            item: item
        )
        let review = AppTestGhostRepairSnapshotCleanupFixture.review(item: item)
        let coordinator = AppTestGhostRepairSnapshotCleanupCoordinator(
            inspectionOutcomes: [.observed(inventory)],
            preparationOutcomes: [.ready(review)],
            executionOutcomes: [
                .recoveryRequired(
                    operationID: review.operationID,
                    message: "Readback required. Do not retry."
                )
            ]
        )
        let model = makeModel(
            sessions: [],
            snapshotCleanupCoordinator: coordinator
        )

        await model.presentGhostRepairSnapshotCleanup()
        await model.prepareGhostRepairSnapshotCleanup(
            reference: item.reference
        )

        XCTAssertEqual(model.ghostRepairSnapshotCleanupState, .reviewReady(review))
        let preparationCount = await coordinator.preparationCount()
        let preReviewExecutionCount = await coordinator.executionCount()
        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(preReviewExecutionCount, 0)

        await model.executeGhostRepairSnapshotCleanup(review: review)
        XCTAssertEqual(
            model.ghostRepairSnapshotCleanupState,
            .recoveryRequired(
                operationID: review.operationID,
                message: "Readback required. Do not retry."
            )
        )
        await model.executeGhostRepairSnapshotCleanup(review: review)
        let finalExecutionCount = await coordinator.executionCount()
        XCTAssertEqual(finalExecutionCount, 1)
    }

    private struct PreparedClosureFixture {
        let requestID: UUID
        let operationID: UUID
        let preview: CodexGhostRepairBulkPreview
        let challenge: CodexGhostRepairBulkConfirmationChallenge
        let receipt: CodexGhostRepairBulkConfirmationReceipt
        let review: CodexGhostRepairBulkFinalReview
        let closurePreview: CodexGhostRepairBulkPreparedClosurePreview
        let preparedSummary: CodexGhostRepairBulkRecoveryOperationSummary
        let closedSummary: CodexGhostRepairBulkRecoveryOperationSummary
        let closure: CodexGhostRepairBulkPreparedClosureRecord
    }

    private struct AlternatePreparedClosureEvidence {
        let summary: CodexGhostRepairBulkRecoveryOperationSummary
        let closure: CodexGhostRepairBulkPreparedClosureRecord
    }

    private func makePreparedClosureFixture(
        requestID: UUID = UUID(),
        operationID: UUID = UUID(),
        receiptID: UUID = UUID()
    ) throws -> PreparedClosureFixture {
        let preview = try CodexGhostRepairBulkPreviewFactory
            .buildAuthorityFree(
                inventory: AppTestGhostRepairBulkFixture.inventory,
                selectedThreadIDs: [
                    AppTestGhostRepairBulkFixture.eligibleA,
                    AppTestGhostRepairBulkFixture.eligibleB,
                ],
                generatedAtMilliseconds: 1_000
            )
        let challenge = try CodexGhostRepairBulkConfirmationChallenge(
            operationID: operationID,
            savedPreviewRequestID: requestID,
            preview: preview,
            previewPayloadHash:
                "sha256:" + String(repeating: "a", count: 64),
            generatedAtMilliseconds: 2_000
        )
        let receipt = try CodexGhostRepairBulkConfirmationReceipt(
            receiptID: receiptID,
            challenge: challenge,
            confirmedAtMilliseconds: 3_000
        )
        let review = try CodexGhostRepairBulkFinalReview(
            operationID: operationID,
            confirmationReceiptID: receiptID,
            selectedCount: preview.selectedItems.count,
            ordinaryCount: preview.ordinarySelectedCount,
            automationCount: preview.automationSelectedCount,
            blockedOutsideBatchCount: 1,
            sourceLayoutIdentifier: preview.sourceLayoutIdentifier,
            reviewDigest: "sha256:" + String(repeating: "b", count: 64)
        )
        let identity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: requestID,
            operationID: operationID
        )
        let selectedItems = preview.selectedItems.map {
            CodexGhostRepairBulkPreparedClosureItem(
                threadID: $0.threadID,
                category: $0.category
            )
        }
        let closurePreview = try CodexGhostRepairBulkPreparedClosurePreview(
            identity: identity,
            confirmationReceiptID: receiptID,
            selectedItems: selectedItems,
            planDigest: review.reviewDigest,
            confirmationReceiptDigest: receipt.receiptDigest,
            backupReceiptDigest:
                "sha256:" + String(repeating: "c", count: 64),
            expectedJournalPayloadHash:
                "sha256:" + String(repeating: "d", count: 64),
            preparedAtMilliseconds: 4_000,
            closureReviewID: UUID(),
            reviewedAtMilliseconds: 5_000
        )
        let preparedSummary = CodexGhostRepairBulkRecoveryOperationSummary(
            identity: identity,
            confirmationReceiptID: receiptID,
            selectedCount: selectedItems.count,
            phase: .prepared,
            mutationAttemptCount: 0,
            recordedAtMilliseconds: 4_000,
            hasTerminalReport: false
        )
        let closure = try CodexGhostRepairBulkPreparedClosureRecord(
            closureID: UUID(),
            preview: closurePreview,
            reason: .userClosedUnstartedPlan,
            closedAtMilliseconds: 6_000
        )
        let closedSummary = CodexGhostRepairBulkRecoveryOperationSummary(
            identity: identity,
            confirmationReceiptID: receiptID,
            selectedCount: selectedItems.count,
            phase: .closedBeforeAttempt,
            mutationAttemptCount: 0,
            recordedAtMilliseconds: 6_000,
            hasTerminalReport: false
        )
        return .init(
            requestID: requestID,
            operationID: operationID,
            preview: preview,
            challenge: challenge,
            receipt: receipt,
            review: review,
            closurePreview: closurePreview,
            preparedSummary: preparedSummary,
            closedSummary: closedSummary,
            closure: closure
        )
    }

    private func makeAlternatePreparedClosureEvidence(
        fixture: PreparedClosureFixture,
        confirmationReceiptID: UUID? = nil,
        selectedItems: [CodexGhostRepairBulkPreparedClosureItem]? = nil,
        planDigest: String? = nil,
        confirmationReceiptDigest: String? = nil,
        backupReceiptDigest: String? = nil,
        expectedJournalPayloadHash: String? = nil
    ) throws -> AlternatePreparedClosureEvidence {
        let preview = try CodexGhostRepairBulkPreparedClosurePreview(
            identity: fixture.closurePreview.identity,
            confirmationReceiptID: confirmationReceiptID
                ?? fixture.closurePreview.confirmationReceiptID,
            selectedItems: selectedItems
                ?? fixture.closurePreview.selectedItems,
            planDigest: planDigest
                ?? fixture.closurePreview.planDigest,
            confirmationReceiptDigest: confirmationReceiptDigest
                ?? fixture.closurePreview.confirmationReceiptDigest,
            backupReceiptDigest: backupReceiptDigest
                ?? fixture.closurePreview.backupReceiptDigest,
            expectedJournalPayloadHash: expectedJournalPayloadHash
                ?? fixture.closurePreview.expectedJournalPayloadHash,
            preparedAtMilliseconds:
                fixture.closurePreview.preparedAtMilliseconds,
            closureReviewID: UUID(),
            reviewedAtMilliseconds:
                fixture.closurePreview.reviewedAtMilliseconds + 100
        )
        let closure = try CodexGhostRepairBulkPreparedClosureRecord(
            closureID: UUID(),
            preview: preview,
            reason: .userClosedUnstartedPlan,
            closedAtMilliseconds: preview.reviewedAtMilliseconds + 100
        )
        return .init(
            summary: .init(
                identity: preview.identity,
                confirmationReceiptID: preview.confirmationReceiptID,
                selectedCount: preview.selectedItems.count,
                phase: .closedBeforeAttempt,
                mutationAttemptCount: 0,
                recordedAtMilliseconds: closure.closedAtMilliseconds,
                hasTerminalReport: false
            ),
            closure: closure
        )
    }

    private func makeCurrentPreparedClosureModel(
        fixture: PreparedClosureFixture,
        closureCoordinator:
            any CodexGhostRepairBulkPreparedClosureCoordinating,
        recoveryCoordinator:
            (any CodexGhostRepairBulkRecoveryCoordinating)? = nil,
        freshRecoveryCoordinator:
            (any CodexGhostRepairBulkFreshRecoveryCoordinating)? = nil,
        executionOutcome: CodexGhostRepairBulkRepairExecutionOutcome =
            .unavailable(message: "Closure tests must not execute.")
    ) async throws -> (
        model: SessionManagerModel,
        repairCoordinator: AppTestGhostRepairBulkRepairCoordinator
    ) {
        let previewStore = AppTestGhostRepairBulkPreviewMemoryStore()
        _ = try await previewStore.persist(
            requestID: fixture.requestID,
            preview: fixture.preview,
            inventory: AppTestGhostRepairBulkFixture.inventory
        )
        let repairCoordinator = AppTestGhostRepairBulkRepairCoordinator(
            reviewOutcome: .ready(fixture.review),
            executionOutcome: executionOutcome
        )
        let model = makeModel(
            sessions: [],
            bulkPreviewReadbackCoordinator: previewStore,
            bulkConfirmationChallengeCoordinator:
                AppTestGhostRepairBulkConfirmationCoordinator(
                    outcome: .ready(fixture.challenge)
                ),
            bulkConfirmationReceiptCoordinator:
                AppTestGhostRepairBulkConfirmationReceiptCoordinator(
                    expectedPhrase: fixture.challenge.confirmationPhrase,
                    outcome: .confirmed(fixture.receipt)
                ),
            bulkRepairCoordinator: repairCoordinator,
            bulkRecoveryCoordinator: recoveryCoordinator,
            bulkFreshRecoveryCoordinator: freshRecoveryCoordinator,
            bulkPreparedClosureCoordinator: closureCoordinator,
            bulkReconciliationEnabled: true
        )
        model.ghostRepairBulkSavedPreviewRequestIDDraft =
            fixture.requestID.uuidString.lowercased()
        await model.readSavedGhostRepairBulkPreview()
        model.ghostRepairBulkConfirmationPhraseDraft =
            fixture.challenge.confirmationPhrase
        await model.confirmGhostRepairBulkBatch()
        await model.prepareGhostRepairBulkFinalReview()
        return (model, repairCoordinator)
    }

    private func makeModel(
        sessions: [AgentSession],
        ghostRepairSource: (any CodexGhostRepairReadOnlySafetySource)? = nil,
        ghostRepairOperationalGateSource:
            (any CodexGhostRepairExecutionGateSource)? = nil,
        bulkReconciliationPreferenceWriter: @escaping (Bool) -> Void = { _ in },
        ghostRepairSnapshotCoordinator:
            (any CodexGhostRepairSnapshotActionCoordinator)? = nil,
        snapshotAdmissionInspector:
            (any CodexGhostRepairSnapshotAdmissionInspecting)? = nil,
        snapshotReadbackCoordinator:
            (any CodexGhostRepairSnapshotReadbackCoordinator)? = nil,
        snapshotCleanupCoordinator:
            (any CodexGhostRepairSnapshotCleanupCoordinating)? = nil,
        initialWitnessDiscovery:
            any CodexGhostRepairInitialWitnessDiscovering =
                CodexGhostRepairInitialWitnessUnavailableDiscovery(),
        snapshotReadbackEnabled: Bool = false,
        snapshotReadbackPreferenceWriter: @escaping (Bool) -> Void = { _ in },
        bulkInventoryCoordinator:
            (any CodexGhostRepairBulkInventoryCoordinating)? = nil,
        bulkPreviewPersister:
            any CodexGhostRepairBulkPreviewPersisting =
                AppTestGhostRepairBulkPreviewPersister(),
        bulkPreviewReadbackCoordinator:
            (any CodexGhostRepairBulkPreviewReadbackCoordinating)? = nil,
        bulkConfirmationChallengeCoordinator:
            (any CodexGhostRepairBulkConfirmationChallengeCoordinating)? = nil,
        bulkConfirmationReceiptCoordinator:
            (any CodexGhostRepairBulkConfirmationReceiptCoordinating)? = nil,
        bulkRepairCoordinator:
            (any CodexGhostRepairBulkRepairCoordinating)? = nil,
        bulkRecoveryCoordinator:
            (any CodexGhostRepairBulkRecoveryCoordinating)? = nil,
        bulkConfirmationReceiptRecoveryCoordinator:
            (any CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinating)? = nil,
        bulkFreshRecoveryCoordinator:
            (any CodexGhostRepairBulkFreshRecoveryCoordinating)? = nil,
        bulkPreparedClosureCoordinator:
            (any CodexGhostRepairBulkPreparedClosureCoordinating)? = nil,
        nativeDeleteDesktopCleanupCoordinator:
            (any CodexDesktopCleanupLinkageCoordinating)? = nil,
        bulkReconciliationEnabled: Bool = false
    ) -> SessionManagerModel {
        let model = SessionManagerModel(
            diagnosticLogStore: DiagnosticLogStore.productionInMemory(),
            ghostRepairReadOnlySafetySource: ghostRepairSource,
            ghostRepairOperationalGateSource:
                ghostRepairOperationalGateSource,
            ghostRepairSnapshotActionCoordinator: ghostRepairSnapshotCoordinator,
            ghostRepairSnapshotAdmissionInspector:
                snapshotAdmissionInspector
                ?? AppTestGhostRepairSnapshotAdmissionInspector(
                    outcomes: [.allowed(.appTestAllowed)]
                ),
            ghostRepairSnapshotReadbackCoordinator: snapshotReadbackCoordinator,
            ghostRepairSnapshotCleanupCoordinator: snapshotCleanupCoordinator,
            ghostRepairInitialWitnessDiscovery: initialWitnessDiscovery,
            ghostRepairSnapshotReadbackEnabled: snapshotReadbackEnabled,
            ghostRepairSnapshotReadbackPreferenceWriter:
                snapshotReadbackPreferenceWriter,
            ghostRepairBulkInventoryCoordinator: bulkInventoryCoordinator,
            ghostRepairBulkPreviewPersister: bulkPreviewPersister,
            ghostRepairBulkPreviewReadbackCoordinator:
                bulkPreviewReadbackCoordinator
                ?? CodexGhostRepairBulkPreviewUnavailableReadbackCoordinator(),
            ghostRepairBulkConfirmationChallengeCoordinator:
                bulkConfirmationChallengeCoordinator,
            ghostRepairBulkConfirmationReceiptCoordinator:
                bulkConfirmationReceiptCoordinator,
            ghostRepairBulkRepairCoordinator: bulkRepairCoordinator,
            ghostRepairBulkRecoveryCoordinator: bulkRecoveryCoordinator,
            ghostRepairBulkConfirmationReceiptRecoveryCoordinator:
                bulkConfirmationReceiptRecoveryCoordinator,
            ghostRepairBulkFreshRecoveryCoordinator:
                bulkFreshRecoveryCoordinator,
            ghostRepairBulkPreparedClosureCoordinator:
                bulkPreparedClosureCoordinator,
            nativeDeleteDesktopCleanupCoordinator:
                nativeDeleteDesktopCleanupCoordinator,
            ghostRepairBulkReconciliationEnabled: bulkReconciliationEnabled,
            ghostRepairBulkReconciliationPreferenceWriter:
                bulkReconciliationPreferenceWriter
        )
        model.sessions = sessions
        model.sessionRows = sessions.map(SessionPresentation.init(session:))
        return model
    }

    private func makeSnapshotReadbackInventory()
        -> CodexGhostRepairSnapshotReadbackInventory
    {
        let states: [CodexGhostRepairSnapshotReadbackState] = [
            .preparedOnly,
            .unpublishedPartial,
            .publicationInterrupted,
            .published,
        ]
        let snapshots = states.enumerated().map { index, state in
            CodexGhostRepairSnapshotReadbackItem(
                reference: String(
                    format: "00000000-0000-4000-8000-%012d",
                    index + 1
                ),
                state: state,
                targetCount: index + 1,
                acquisitionRecordHash: "sha256:acquisition-\(index)",
                manifestHash: state == .published
                    ? "sha256:manifest"
                    : nil,
                publicationReceiptHash: state == .published
                    ? "sha256:receipt"
                    : nil,
                observedRegularFileCount: index,
                actualPublishedBytes: state == .published ? 4_096 : nil
            )
        }
        return CodexGhostRepairSnapshotReadbackInventory(
            snapshots: snapshots,
            totalPublishedBytes: 4_096
        )
    }

    private func makeDeletedPresentation(nativeID: String) -> SessionPresentation {
        SessionPresentation(deleted: DeletedSessionRecord(
            provider: .codex,
            nativeSessionID: nativeID,
            managerKey: "codex:\(nativeID)",
            titleAtDeletion: nativeID,
            workingDirectoryAtDeletion: "/projects/default",
            providerInventoryHashAtDeletion: "delete-inventory",
            deletedAt: Date(timeIntervalSince1970: 1_000)
        ))
    }

    private func makeInitialWitnessEvidence(
        threadIDs: [String],
        runtimeVersion: String = "0.153.4"
    ) -> CodexGhostRepairInitialWitnessEvidence {
        CodexGhostRepairInitialWitnessEvidence(
            threadIDs: threadIDs,
            runtimeVersion: runtimeVersion,
            sourceLayoutIdentifier:
                "codex-cli-0.153.4-desktop-v34-20-member-v1",
            sourceFingerprintHash: "sha256:" + String(repeating: "a", count: 64)
        )
    }

    private func makeNativeDeleteReport(
        items: [(String, PersistentItemOutcome, NativeSessionState)]
    ) -> NativeDeleteReport {
        NativeDeleteReport(
            id: UUID(),
            previewID: UUID(),
            outcome: items.allSatisfy { $0.1 == .success }
                ? .success
                : .partial,
            completedAt: Date(timeIntervalSince1970: 1_000),
            items: items.map { nativeID, outcome, observedState in
                NativeDeleteReportItem(
                    managerKey: "codex:\(nativeID)",
                    nativeSessionID: nativeID,
                    title: nativeID,
                    projectName: nil,
                    workingDirectory: "/projects/default",
                    outcome: outcome,
                    observedNativeState: observedState,
                    errorCode: nil,
                    message: nil
                )
            },
            recoveredAfterInterruption: false
        )
    }

    private func makeDesktopCleanupHandoff(
        reportID: UUID,
        nativeSessionIDs: [String]
    ) throws -> CodexDesktopCleanupHandoff {
        try CodexDesktopCleanupHandoff(
            canonicalDeleteReportID: reportID,
            items: nativeSessionIDs.map {
                try CodexDesktopCleanupHandoffItem(
                    managerKey: "codex:\($0)",
                    nativeSessionID: $0,
                    deletedAtMilliseconds: 1_000_000
                )
            }
        )
    }

    private func makeGhostRepairSnapshot(
        targetIDs: [String],
        exactAbsenceAvailable: Bool = true,
        executionGate: CodexGhostRepairExecutionGate = CodexGhostRepairExecutionGate(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: true
        ),
        runtimeVersion: String = "codex-cli 0.148.0",
        observedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> CodexGhostRepairSafetySnapshot {
        let contract = ExactSessionAbsenceContract(
            provider: .codex,
            runtimeVersion: runtimeVersion,
            rpcCode: -32600,
            identifier: "app-test-contract",
            officialSourceURL: URL(string: "https://developers.openai.com/codex/app-server")!
        )
        return CodexGhostRepairSafetySnapshot(
            inventory: ProviderInventorySnapshot(
                provider: .codex,
                runtimeVersion: runtimeVersion,
                inventoryHash: "inventory-hash",
                observedAt: observedAt,
                inventoryComplete: true,
                protectionComplete: true,
                sessions: [],
                archiveScopeNodes: [],
                archiveScopeComplete: true
            ),
            exactReadbacks: targetIDs.map { targetID in
                if exactAbsenceAvailable {
                    ExactSessionReadbackEvidence(
                        provider: .codex,
                        nativeSessionID: targetID,
                        status: .absent,
                        observedAt: observedAt,
                        runtimeVersion: runtimeVersion,
                        evidenceKind: .documentedNotFound,
                        rpcCode: -32600,
                        absenceContract: contract,
                        message: "not loaded"
                    )
                } else {
                    ExactSessionReadbackEvidence(
                        provider: .codex,
                        nativeSessionID: targetID,
                        status: .unavailable,
                        observedAt: observedAt,
                        runtimeVersion: runtimeVersion,
                        evidenceKind: .rpcError,
                        rpcCode: -32600,
                        message: "undocumented thread/read response"
                    )
                }
            },
            pinnedThreadIDs: [],
            pinnedInventoryComplete: true,
            executionGate: executionGate
        )
    }

    private func makeSession(
        nativeID: String,
        title: String? = nil,
        state: NativeSessionState,
        project: SessionProject? = nil,
        isTrash: Bool = false
    ) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: title ?? nativeID,
            project: project,
            workingDirectory: project?.rootPath ?? "/projects/default",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            sizeBytes: nil,
            nativeState: state,
            isTrashMember: isTrash
        )
    }
}

private actor AppTestSessionSizeReader: SessionFileSizeReading {
    private var values: [String: Int64]
    private(set) var requestedIDs: [Set<String>] = []
    init(values: [String: Int64]) { self.values = values }
    func replace(values: [String: Int64]) { self.values = values }
    func sizes(homeURL: URL, sessionIDs: Set<String>) -> [String: Int64] {
        requestedIDs.append(sessionIDs)
        return values
    }
}

private actor AppTestSessionSizeInspectionReader: SessionFileSizeReading {
    private var result: SessionFileSizeInspection
    init(result: SessionFileSizeInspection) { self.result = result }
    func replace(result: SessionFileSizeInspection) { self.result = result }
    func sizes(homeURL: URL, sessionIDs: Set<String>) -> [String: Int64] { result.sizes }
    func inspect(homeURL: URL, sessionIDs: Set<String>) async -> SessionFileSizeInspection { result }
}

private actor AppTestCompatibilityInspector: CodexCompatibilityInspecting {
    private var progressObserver: (@Sendable () async -> Void)?
    func setProgressObserver(_ observer: @escaping @Sendable () async -> Void) { progressObserver = observer }
    private var current: Bool
    private var fails = false
    private var reviewFails = false
    private var metadataUnavailable = false
    func makeMetadataUnavailable() { metadataUnavailable = true }
    private var hasReport = true
    private var fingerprint = "fixture"
    private var features: [CodexCompatibilityFeatureResult] = []
    private(set) var inspectionCount = 0
    private(set) var behaviorCount = 0
    func verifyBehavior(_ request: CodexCompatibilityRequest, confirmedFingerprint: String,
                        progress: @escaping @Sendable (String) async -> Void) async throws -> CodexCompatibilityReport {
        guard confirmedFingerprint == fingerprint else { throw NSError(domain: "Changed fixture", code: 1) }
        behaviorCount += 1
        await progress("Testing fixture…")
        await progressObserver?()
        return report
    }
    init(current: Bool) { self.current = current }
    func setCurrent(_ value: Bool) { current = value }
    func failNextCheck() { fails = true }
    func failReview() { reviewFails = true }
    func omitSavedReport() { hasReport = false }
    func changeEnvironment(_ value: String) { fingerprint = value }
    func addUnsupportedFeature() {
        features = [.init(feature: .officialDelete, status: .needsBehaviorVerification, detail: "Fixture unverified")]
    }
    func inspect(_ request: CodexCompatibilityRequest) throws -> CodexCompatibilityReport {
        inspectionCount += 1
        if fails { throw NSError(domain: "Fixture inspection", code: 1) }
        return report
    }
    func savedReport() -> CodexCompatibilityReport? { report }
    func isCurrent(_ report: CodexCompatibilityReport, request: CodexCompatibilityRequest) -> Bool { current }
    func reviewSavedCompatibility(_ request: CodexCompatibilityRequest) throws -> CodexCompatibilityReview {
        if reviewFails { throw NSError(domain: "Fixture comparison", code: 1) }
        return .init(report: hasReport ? report : nil, isCurrent: current, environmentFingerprint: fingerprint,
                     providerVersion: current ? "0.999.0" : "0.999.1", desktopVersion: "0.999.0",
                     metadataUnavailable: metadataUnavailable)
    }
    private var report: CodexCompatibilityReport {
        .init(revision: CodexCompatibilityReport.policyRevision, checkedAt: Date(timeIntervalSince1970: 1_000),
              provider: .init(path: "/fixture/codex", version: "0.999.0", sha256: "fixture"), desktop: nil,
              environmentFingerprint: "fixture", desktopSchemaProfile: nil, results: features, notes: [])
    }
}

private actor AppTestGhostRepairSafetySource: CodexGhostRepairReadOnlySafetySource {
    private var snapshots: [CodexGhostRepairSafetySnapshot]
    private(set) var requests: [[String]] = []

    init(snapshot: CodexGhostRepairSafetySnapshot) {
        snapshots = [snapshot]
    }

    init(snapshots: [CodexGhostRepairSafetySnapshot]) {
        precondition(!snapshots.isEmpty)
        self.snapshots = snapshots
    }

    func ghostRepairSafetySnapshot(
        targetThreadIDs: [String]
    ) async throws -> CodexGhostRepairSafetySnapshot {
        requests.append(targetThreadIDs)
        if snapshots.count > 1 {
            return snapshots.removeFirst()
        }
        return snapshots[0]
    }
}

private actor AppTestInitialWitnessDiscovery:
    CodexGhostRepairInitialWitnessDiscovering
{
    nonisolated let capabilities:
        CodexGhostRepairInitialWitnessDiscoveryCapabilities
    private let outcome: CodexGhostRepairInitialWitnessDiscoveryOutcome
    private var requests = 0

    init(
        outcome: CodexGhostRepairInitialWitnessDiscoveryOutcome,
        capabilities: CodexGhostRepairInitialWitnessDiscoveryCapabilities =
            .packagedReadOnly
    ) {
        self.outcome = outcome
        self.capabilities = capabilities
    }

    func discover() async -> CodexGhostRepairInitialWitnessDiscoveryOutcome {
        requests += 1
        return outcome
    }

    func requestCount() -> Int { requests }
}

private actor AppTestSuspendingInitialWitnessDiscovery:
    CodexGhostRepairInitialWitnessDiscovering
{
    nonisolated let capabilities =
        CodexGhostRepairInitialWitnessDiscoveryCapabilities.packagedReadOnly
    private var requests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation:
        CheckedContinuation<
            CodexGhostRepairInitialWitnessDiscoveryOutcome,
            Never
        >?

    func discover() async -> CodexGhostRepairInitialWitnessDiscoveryOutcome {
        requests += 1
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        if requests > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish(with outcome: CodexGhostRepairInitialWitnessDiscoveryOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func requestCount() -> Int { requests }
}

private actor AppTestDynamicDesktopCleanupLinkageCoordinator: CodexDesktopCleanupLinkageCoordinating {
    nonisolated let capabilities = CodexDesktopCleanupLinkageCapabilities.packaged
    let handoff: CodexDesktopCleanupHandoff
    let store: AppTestGhostRepairBulkPreviewMemoryStore
    let receipts: AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator
    let executionUnknown: Bool
    var binding: CodexDesktopCleanupBinding?

    init(handoff: CodexDesktopCleanupHandoff, store: AppTestGhostRepairBulkPreviewMemoryStore,
         receipts: AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator, executionUnknown: Bool) {
        self.handoff = handoff
        self.store = store
        self.receipts = receipts
        self.executionUnknown = executionUnknown
    }

    func reviewCanonicalDelete(reportID: UUID, expectedNativeSessionIDs: [String]) async -> CodexDesktopCleanupReviewOutcome {
        .ready(handoff)
    }

    func readStatus(reportID: UUID) async -> CodexDesktopCleanupStatusOutcome {
        if let binding {
            if executionUnknown { return .status(.outcomeUnknown(handoff, binding)) }
            return .status(.verified(handoff, binding, completedAtMilliseconds: 2_000_000))
        }
        return .status(.pending(handoff))
    }

    func bindPreparedOperation(handoff: CodexDesktopCleanupHandoff,
                               bulkIdentity: CodexGhostRepairBulkRecoveryOperationIdentity) async -> CodexDesktopCleanupBindOutcome {
        guard let receipt = await receipts.receiptForOperation(bulkIdentity.operationID),
              let evidence = await store.evidence(requestID: bulkIdentity.requestID) else {
            return .rejected(message: "Missing fixture receipt.")
        }
        do {
            let value = try CodexDesktopCleanupBinding(
                canonicalDeleteReportID: handoff.canonicalDeleteReportID,
                handoffDigest: handoff.handoffDigest, bulkIdentity: bulkIdentity,
                confirmationReceiptID: receipt.receiptID,
                confirmationReceiptDigest: receipt.receiptDigest,
                planDigest: "sha256:" + String(repeating: "3", count: 64),
                backupReceiptDigest: "sha256:" + String(repeating: "4", count: 64),
                preparedJournalPayloadHash: "sha256:" + String(repeating: "5", count: 64),
                items: try handoff.items.map { item in
                    try CodexDesktopCleanupBindingItem(
                        managerKey: item.managerKey, nativeSessionID: item.nativeSessionID,
                        deletedAtMilliseconds: item.deletedAtMilliseconds,
                        category: evidence.preview.selectedItems.first { $0.threadID == item.nativeSessionID }!.category
                    )
                }, boundAtMilliseconds: 2_000_000
            )
            binding = value
            return .bound(value)
        } catch {
            return .rejected(message: error.localizedDescription)
        }
    }
}

private actor AppTestDesktopCleanupLinkageCoordinator:
    CodexDesktopCleanupLinkageCoordinating
{
    nonisolated let capabilities = CodexDesktopCleanupLinkageCapabilities.packaged
    private var reviewOutcomes: [CodexDesktopCleanupReviewOutcome]
    private var bindOutcomes: [CodexDesktopCleanupBindOutcome]
    private var statusOutcomes: [CodexDesktopCleanupStatusOutcome]
    private var reviewRequests: [(UUID, [String])] = []
    private var bindRequests: [(
        CodexDesktopCleanupHandoff,
        CodexGhostRepairBulkRecoveryOperationIdentity
    )] = []
    private var statusRequests: [UUID] = []

    init(
        reviewOutcomes: [CodexDesktopCleanupReviewOutcome] = [],
        bindOutcomes: [CodexDesktopCleanupBindOutcome] = [],
        statusOutcomes: [CodexDesktopCleanupStatusOutcome] = []
    ) {
        self.reviewOutcomes = reviewOutcomes
        self.bindOutcomes = bindOutcomes
        self.statusOutcomes = statusOutcomes
    }

    func reviewCanonicalDelete(
        reportID: UUID,
        expectedNativeSessionIDs: [String]
    ) async -> CodexDesktopCleanupReviewOutcome {
        reviewRequests.append((reportID, expectedNativeSessionIDs))
        guard !reviewOutcomes.isEmpty else {
            return .notFound(reportID: reportID)
        }
        return reviewOutcomes.removeFirst()
    }

    func bindPreparedOperation(
        handoff: CodexDesktopCleanupHandoff,
        bulkIdentity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexDesktopCleanupBindOutcome {
        bindRequests.append((handoff, bulkIdentity))
        guard !bindOutcomes.isEmpty else {
            return .rejected(message: "No deterministic binding outcome.")
        }
        return bindOutcomes.removeFirst()
    }

    func readStatus(
        reportID: UUID
    ) async -> CodexDesktopCleanupStatusOutcome {
        statusRequests.append(reportID)
        guard !statusOutcomes.isEmpty else {
            return .notFound(reportID: reportID)
        }
        return statusOutcomes.removeFirst()
    }

    func reviewRequestCount() -> Int { reviewRequests.count }
    func bindRequestCount() -> Int { bindRequests.count }
    func statusRequestCount() -> Int { statusRequests.count }
}

private actor AppTestSuspendingGhostRepairSafetySource:
    CodexGhostRepairReadOnlySafetySource
{
    private var requestedTargetIDs: [[String]] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotContinuation:
        CheckedContinuation<CodexGhostRepairSafetySnapshot, Never>?

    func ghostRepairSafetySnapshot(
        targetThreadIDs: [String]
    ) async throws -> CodexGhostRepairSafetySnapshot {
        requestedTargetIDs.append(targetThreadIDs)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            snapshotContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        if !requestedTargetIDs.isEmpty { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func finish(with snapshot: CodexGhostRepairSafetySnapshot) {
        snapshotContinuation?.resume(returning: snapshot)
        snapshotContinuation = nil
    }

    func requests() -> [[String]] { requestedTargetIDs }
}

private actor AppTestGhostRepairOperatingGateSource:
    CodexGhostRepairExecutionGateSource
{
    private var gates: [CodexGhostRepairExecutionGate]
    private var requests = 0

    init(gate: CodexGhostRepairExecutionGate) {
        gates = [gate]
    }

    init(gates: [CodexGhostRepairExecutionGate]) {
        precondition(!gates.isEmpty)
        self.gates = gates
    }

    func ghostRepairExecutionGate() async throws
        -> CodexGhostRepairExecutionGate
    {
        requests += 1
        if gates.count > 1 {
            return gates.removeFirst()
        }
        return gates[0]
    }

    func requestCount() -> Int { requests }
}

private actor AppTestSuspendingGhostRepairOperatingGateSource:
    CodexGhostRepairExecutionGateSource
{
    private var requests = 0
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateContinuation:
        CheckedContinuation<CodexGhostRepairExecutionGate, Never>?

    func ghostRepairExecutionGate() async throws
        -> CodexGhostRepairExecutionGate
    {
        requests += 1
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            gateContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        if requests > 0 { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func requestCount() -> Int { requests }

    func finish(with gate: CodexGhostRepairExecutionGate) {
        gateContinuation?.resume(returning: gate)
        gateContinuation = nil
    }
}

extension CodexGhostRepairExecutionGate {
    fileprivate static let clearForPreflightTests = Self(
        codexFullyExited: true,
        desktopOpenHandleCount: 0,
        summariesOpenHandleCount: 0,
        historyOpenHandleCount: 0,
        capacitySufficient: true,
        desktopProcessEvidence: []
    )

    static let completeFiveDatabaseClearForBulkTests = Self(
        codexFullyExited: true,
        desktopOpenHandleCount: 0,
        summariesOpenHandleCount: 0,
        historyOpenHandleCount: 0,
        stateOpenHandleCount: 0,
        threadHistoryOpenHandleCount: 0,
        capacitySufficient: true,
        desktopProcessEvidence: [],
        openHandleOwnerEvidence: []
    )
}

private actor AppTestGhostRepairSnapshotAdmissionInspector:
    CodexGhostRepairSnapshotAdmissionInspecting
{
    nonisolated let capabilities:
        CodexGhostRepairSnapshotAdmissionInspectorCapabilities =
            .packagedFixedReadOnly
    private var outcomes: [CodexGhostRepairSnapshotAdmissionOutcome]
    private(set) var requests: [CodexGhostRepairSnapshotActionRequest] = []

    init(outcomes: [CodexGhostRepairSnapshotAdmissionOutcome]) {
        self.outcomes = outcomes
    }

    func inspect(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        requests.append(request)
        guard !outcomes.isEmpty else {
            return .unavailable(
                message: "No deterministic inspection outcome was configured."
            )
        }
        return outcomes.removeFirst()
    }
}

private actor AppTestSuspendingGhostRepairSnapshotAdmissionInspector:
    CodexGhostRepairSnapshotAdmissionInspecting
{
    nonisolated let capabilities:
        CodexGhostRepairSnapshotAdmissionInspectorCapabilities =
            .packagedFixedReadOnly
    private var requests: [CodexGhostRepairSnapshotActionRequest] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var outcomeContinuation:
        CheckedContinuation<CodexGhostRepairSnapshotAdmissionOutcome, Never>?

    func inspect(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        requests.append(request)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            outcomeContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func requestCount() -> Int { requests.count }

    func finish(with outcome: CodexGhostRepairSnapshotAdmissionOutcome) {
        outcomeContinuation?.resume(returning: outcome)
        outcomeContinuation = nil
    }
}

private actor AppTestGhostRepairSnapshotActionCoordinator:
    CodexGhostRepairSnapshotActionCoordinator
{
    nonisolated let capabilities:
        CodexGhostRepairSnapshotActionCapabilities =
            .testOwnedRawDatabaseSnapshot
    private var outcomes: [CodexGhostRepairSnapshotActionOutcome]
    private(set) var requests: [CodexGhostRepairSnapshotActionRequest] = []
    private(set) var admissionRequests:
        [CodexGhostRepairSnapshotActionRequest] = []
    private let admissionOutcome: CodexGhostRepairSnapshotAdmissionOutcome

    init(
        outcomes: [CodexGhostRepairSnapshotActionOutcome],
        admissionOutcome: CodexGhostRepairSnapshotAdmissionOutcome =
            .allowed(.appTestAllowed)
    ) {
        self.outcomes = outcomes
        self.admissionOutcome = admissionOutcome
    }

    func inspectAdmission(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        admissionRequests.append(request)
        return admissionOutcome
    }

    func perform(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotActionOutcome {
        requests.append(request)
        guard !outcomes.isEmpty else {
            return .failed(message: "No deterministic outcome was configured.")
        }
        return outcomes.removeFirst()
    }
}

private actor AppTestSuspendingGhostRepairSnapshotActionCoordinator:
    CodexGhostRepairSnapshotActionCoordinator
{
    nonisolated let capabilities:
        CodexGhostRepairSnapshotActionCapabilities =
            .testOwnedRawDatabaseSnapshot
    private var requests: [CodexGhostRepairSnapshotActionRequest] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var outcomeContinuation:
        CheckedContinuation<CodexGhostRepairSnapshotActionOutcome, Never>?

    func inspectAdmission(
        request _: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        .allowed(.appTestAllowed)
    }

    func perform(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotActionOutcome {
        requests.append(request)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            outcomeContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func requestCount() -> Int { requests.count }

    func finish(with outcome: CodexGhostRepairSnapshotActionOutcome) {
        outcomeContinuation?.resume(returning: outcome)
        outcomeContinuation = nil
    }
}

private extension CodexGhostRepairSnapshotAdmissionEvidence {
    static let appTestAllowed = Self(
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
    )
}

private enum AppTestGhostRepairSnapshotCleanupFixture {
    static let operationID = UUID(
        uuidString: "93071F86-42CE-46DC-B65E-55FEC17EED68"
    )!

    static let item = CodexGhostRepairSnapshotCleanupItem(
        reference: "2deddd76-ba46-4eb5-b0f0-7aac17ce2790",
        publishedAtMilliseconds: 1_777_777_777_000,
        actualBytes: 130_700_000,
        activePreviewCount: 0,
        nonterminalRepairCount: 0,
        historicalReferenceCount: 1,
        eligibility: .eligible
    )

    static func inventory(
        item: CodexGhostRepairSnapshotCleanupItem
    ) -> CodexGhostRepairSnapshotCleanupInventory {
        CodexGhostRepairSnapshotCleanupInventory(
            snapshots: [item],
            activeSnapshotCount: 3,
            maximumSnapshotCount: 3,
            totalActiveBytes: 400_000_000
        )
    }

    static func review(
        item: CodexGhostRepairSnapshotCleanupItem
    ) -> CodexGhostRepairSnapshotCleanupReview {
        CodexGhostRepairSnapshotCleanupReview(
            operationID: operationID,
            snapshot: item,
            activeSnapshotCountBefore: 3,
            activeSnapshotCountAfter: 2,
            previewDigest: "sha256:" + String(repeating: "a", count: 64)
        )
    }
}

private actor AppTestGhostRepairSnapshotCleanupCoordinator:
    CodexGhostRepairSnapshotCleanupCoordinating
{
    nonisolated let capabilities:
        CodexGhostRepairSnapshotCleanupCapabilities = .packaged
    private var inspectionOutcomes:
        [CodexGhostRepairSnapshotCleanupInspectionOutcome]
    private var preparationOutcomes:
        [CodexGhostRepairSnapshotCleanupPrepareOutcome]
    private var executionOutcomes:
        [CodexGhostRepairSnapshotCleanupExecutionOutcome]
    private var inspections = 0
    private var preparations: [String] = []
    private var executions: [UUID] = []

    init(
        inspectionOutcomes:
            [CodexGhostRepairSnapshotCleanupInspectionOutcome] = [],
        preparationOutcomes:
            [CodexGhostRepairSnapshotCleanupPrepareOutcome] = [],
        executionOutcomes:
            [CodexGhostRepairSnapshotCleanupExecutionOutcome] = []
    ) {
        self.inspectionOutcomes = inspectionOutcomes
        self.preparationOutcomes = preparationOutcomes
        self.executionOutcomes = executionOutcomes
    }

    func inspect() async -> CodexGhostRepairSnapshotCleanupInspectionOutcome {
        inspections += 1
        guard !inspectionOutcomes.isEmpty else {
            return .unavailable(message: "No inspection outcome configured.")
        }
        return inspectionOutcomes.removeFirst()
    }

    func prepare(
        snapshotReference: String
    ) async -> CodexGhostRepairSnapshotCleanupPrepareOutcome {
        preparations.append(snapshotReference)
        guard !preparationOutcomes.isEmpty else {
            return .unavailable(message: "No preparation outcome configured.")
        }
        return preparationOutcomes.removeFirst()
    }

    func execute(
        operationID: UUID
    ) async -> CodexGhostRepairSnapshotCleanupExecutionOutcome {
        executions.append(operationID)
        guard !executionOutcomes.isEmpty else {
            return .rejected(message: "No execution outcome configured.")
        }
        return executionOutcomes.removeFirst()
    }

    func inspectionCount() -> Int { inspections }
    func preparationCount() -> Int { preparations.count }
    func executionCount() -> Int { executions.count }
}

private actor AppTestGhostRepairSnapshotReadbackCoordinator:
    CodexGhostRepairSnapshotReadbackCoordinator
{
    nonisolated let capabilities:
        CodexGhostRepairSnapshotReadbackCapabilities
    private var outcomes: [CodexGhostRepairSnapshotReadbackOutcome]
    private(set) var readbackCount = 0

    init(
        capabilities: CodexGhostRepairSnapshotReadbackCapabilities =
            .packagedReadOnly,
        outcomes: [CodexGhostRepairSnapshotReadbackOutcome]
    ) {
        self.capabilities = capabilities
        self.outcomes = outcomes
    }

    func readback() async -> CodexGhostRepairSnapshotReadbackOutcome {
        readbackCount += 1
        guard !outcomes.isEmpty else {
            return .unavailable(
                message: "No deterministic readback outcome was configured."
            )
        }
        return outcomes.removeFirst()
    }

    func requestCount() -> Int { readbackCount }
}

private actor AppTestSuspendingGhostRepairSnapshotReadbackCoordinator:
    CodexGhostRepairSnapshotReadbackCoordinator
{
    nonisolated let capabilities:
        CodexGhostRepairSnapshotReadbackCapabilities = .packagedReadOnly
    private(set) var readbackCount = 0
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var outcomeContinuation:
        CheckedContinuation<CodexGhostRepairSnapshotReadbackOutcome, Never>?

    func readback() async -> CodexGhostRepairSnapshotReadbackOutcome {
        readbackCount += 1
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            outcomeContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        if readbackCount > 0 { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func requestCount() -> Int { readbackCount }

    func finish(with outcome: CodexGhostRepairSnapshotReadbackOutcome) {
        outcomeContinuation?.resume(returning: outcome)
        outcomeContinuation = nil
    }
}

private enum AppTestGhostRepairBulkFixture {
    static let snapshotReference =
        "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
    static let eligibleA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    static let eligibleB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"
    static let blocked = "11111111-2222-4333-8444-555555555555"
    static let notGhost = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    static let inventory = CodexGhostRepairBulkInventory(
        snapshotReference: snapshotReference,
        sourceLayoutIdentifier: "codex-cli-0.149.0-paginated-v1",
        items: [
            .init(
                threadID: eligibleA,
                disposition: .eligible,
                category: .ordinary,
                blockers: [],
                evidenceDigest: digest("a")
            ),
            .init(
                threadID: eligibleB,
                disposition: .eligible,
                category: .automation,
                blockers: [],
                evidenceDigest: digest("b")
            ),
            .init(
                threadID: blocked,
                disposition: .blocked,
                category: .ordinary,
                blockers: [.sideReferencesPresent],
                evidenceDigest: digest("c")
            ),
            .init(
                threadID: notGhost,
                disposition: .notGhost,
                category: nil,
                blockers: [],
                evidenceDigest: digest("d")
            ),
        ],
        inventoryDigest: digest("e")
    )

    static let exact148Inventory = CodexGhostRepairBulkInventory(
        snapshotReference: "14800000-0000-4000-8000-000000000148",
        sourceLayoutIdentifier: "codex-cli-0.149.0-paginated-v1",
        items: (1...148).map { index in
            .init(
                threadID: String(
                    format: "00000000-0000-4000-8000-%012d",
                    index
                ),
                disposition: .eligible,
                category: index.isMultiple(of: 2)
                    ? .automation
                    : .ordinary,
                blockers: [],
                evidenceDigest: digest(index.isMultiple(of: 2) ? "8" : "7")
            )
        },
        inventoryDigest: digest("9")
    )

    private static func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}

private actor AppTestGhostRepairBulkInventoryCoordinator:
    CodexGhostRepairBulkInventoryCoordinating
{
    nonisolated let capabilities: CodexGhostRepairBulkInventoryCapabilities
    private let inventory: CodexGhostRepairBulkInventory?
    private let failureStage: CodexGhostRepairBulkInventoryFailureStage?
    private let resumableSnapshotReference: String?
    private let requestBoundScanReference: Bool
    private let noResidue: Bool
    private var requests: [CodexGhostRepairBulkInventoryRequest] = []
    private var requestedResumeTargets: [[String]] = []

    init(
        inventory: CodexGhostRepairBulkInventory? = nil,
        failureStage: CodexGhostRepairBulkInventoryFailureStage? = nil,
        resumableSnapshotReference: String? = nil,
        directScan: Bool = false,
        noResidue: Bool = false
    ) {
        capabilities = directScan
            ? .packagedLiveScan
            : .packagedReadOnlyCandidate
        self.inventory = inventory
        self.failureStage = failureStage
        self.resumableSnapshotReference = resumableSnapshotReference
        requestBoundScanReference = directScan
        self.noResidue = noResidue
    }

    func verifyNoDesktopResidue(handoff: CodexDesktopCleanupHandoff) async -> Bool {
        noResidue
    }

    func resumablePublishedSnapshotReference(
        targetThreadIDs: [String]
    ) async throws -> String? {
        requestedResumeTargets.append(targetThreadIDs)
        return resumableSnapshotReference
    }

    func observe(
        request: CodexGhostRepairBulkInventoryRequest
    ) async -> CodexGhostRepairBulkInventoryOutcome {
        requests.append(request)
        if let failureStage {
            return .unavailable(
                requestID: request.requestID,
                failure: .init(stage: failureStage)
            )
        }
        guard let inventory else {
            return .unavailable(
                requestID: request.requestID,
                failure: .init(stage: .unavailable)
            )
        }
        let returnedInventory: CodexGhostRepairBulkInventory
        if requestBoundScanReference {
            returnedInventory = CodexGhostRepairBulkInventory(
                snapshotReference: request.snapshotReference,
                sourceLayoutIdentifier: inventory.sourceLayoutIdentifier,
                items: inventory.items,
                inventoryDigest: inventory.inventoryDigest,
                displayTitles: inventory.displayTitles
            )
        } else {
            returnedInventory = inventory
        }
        return .inventory(
            requestID: request.requestID,
            inventory: returnedInventory
        )
    }

    func requestCount() -> Int { requests.count }
    func resumeRequests() -> [[String]] { requestedResumeTargets }
}

private actor AppTestGhostRepairBulkPreviewPersister:
    CodexGhostRepairBulkPreviewPersisting
{
    func persist(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        inventory: CodexGhostRepairBulkInventory
    ) async throws -> CodexGhostRepairBulkPreviewPersistenceReceipt {
        .init(
            requestID: requestID,
            previewID: preview.previewID,
            payloadHash: "sha256:" + String(repeating: "f", count: 64),
            frozenSourceDigest:
                "sha256:" + String(repeating: "e", count: 64),
            durableReadbackMatched: true
        )
    }
}

private actor AppTestGhostRepairBulkPreviewMemoryStore:
    CodexGhostRepairBulkPreviewPersisting,
    CodexGhostRepairBulkPreviewReadbackCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkPreviewReadbackCapabilities.packagedReadOnly
    private var records:
        [UUID: CodexGhostRepairBulkPreviewReadbackEvidence] = [:]
    private let failAfterFirstSave: Bool

    init(failAfterFirstSave: Bool = false) {
        self.failAfterFirstSave = failAfterFirstSave
    }

    func persist(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreview,
        inventory: CodexGhostRepairBulkInventory
    ) async throws -> CodexGhostRepairBulkPreviewPersistenceReceipt {
        if failAfterFirstSave && !records.isEmpty {
            throw CocoaError(.fileWriteUnknown)
        }
        let hash = "sha256:" + String(repeating: "a", count: 64)
        let sourceHash = "sha256:" + String(repeating: "b", count: 64)
        records[requestID] = .init(
            requestID: requestID,
            preview: preview,
            payloadHash: hash,
            frozenSourceDigest: sourceHash,
            durableReadbackMatched: true
        )
        return .init(
            requestID: requestID,
            previewID: preview.previewID,
            payloadHash: hash,
            frozenSourceDigest: sourceHash,
            durableReadbackMatched: true
        )
    }

    func readback(
        requestID: UUID
    ) async -> CodexGhostRepairBulkPreviewReadbackOutcome {
        guard let evidence = records[requestID] else {
            return .notFound(requestID: requestID)
        }
        return .observed(evidence)
    }

    func evidence(
        requestID: UUID
    ) -> CodexGhostRepairBulkPreviewReadbackEvidence? {
        records[requestID]
    }
}

private actor AppTestDynamicGhostRepairBulkConfirmationCoordinator:
    CodexGhostRepairBulkConfirmationChallengeCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationCapabilities.packagedEvidenceOnly
    private let previewStore: AppTestGhostRepairBulkPreviewMemoryStore
    private var challenges:
        [UUID: CodexGhostRepairBulkConfirmationChallenge] = [:]
    private var requests: [UUID] = []

    init(previewStore: AppTestGhostRepairBulkPreviewMemoryStore) {
        self.previewStore = previewStore
    }

    func prepareChallenge(
        savedPreviewRequestID: UUID
    ) async -> CodexGhostRepairBulkConfirmationChallengeOutcome {
        requests.append(savedPreviewRequestID)
        guard let evidence = await previewStore.evidence(
            requestID: savedPreviewRequestID
        ) else {
            return .notFound(requestID: savedPreviewRequestID)
        }
        do {
            let challenge = try CodexGhostRepairBulkConfirmationChallenge(
                operationID: UUID(),
                savedPreviewRequestID: savedPreviewRequestID,
                preview: evidence.preview,
                previewPayloadHash: evidence.payloadHash,
                generatedAtMilliseconds:
                    evidence.preview.generatedAtMilliseconds + 1
            )
            challenges[savedPreviewRequestID] = challenge
            return .ready(challenge)
        } catch {
            return .unavailable(
                requestID: savedPreviewRequestID,
                message: error.localizedDescription
            )
        }
    }

    func challenge(
        requestID: UUID
    ) -> CodexGhostRepairBulkConfirmationChallenge? {
        challenges[requestID]
    }

    func requestCount() -> Int { requests.count }
}

private actor AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator:
    CodexGhostRepairBulkConfirmationReceiptCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationReceiptCapabilities
            .packagedReceiptOnly
    private let challengeCoordinator:
        AppTestDynamicGhostRepairBulkConfirmationCoordinator
    private var receipts: [UUID: CodexGhostRepairBulkConfirmationReceipt] = [:]
    private var requests: [(UUID, String)] = []

    init(
        challengeCoordinator:
            AppTestDynamicGhostRepairBulkConfirmationCoordinator
    ) {
        self.challengeCoordinator = challengeCoordinator
    }

    func confirm(
        savedPreviewRequestID: UUID,
        exactConfirmationPhrase: String
    ) async -> CodexGhostRepairBulkConfirmationReceiptOutcome {
        requests.append((savedPreviewRequestID, exactConfirmationPhrase))
        guard let challenge = await challengeCoordinator.challenge(
            requestID: savedPreviewRequestID
        ) else {
            return .notFound(requestID: savedPreviewRequestID)
        }
        guard exactConfirmationPhrase == challenge.confirmationPhrase else {
            return .rejected(
                requestID: savedPreviewRequestID,
                message: "The confirmation phrase does not match this whole batch."
            )
        }
        do {
            let receipt = try CodexGhostRepairBulkConfirmationReceipt(
                receiptID: UUID(),
                challenge: challenge,
                confirmedAtMilliseconds:
                    challenge.generatedAtMilliseconds + 1
            )
            receipts[receipt.receiptID] = receipt
            return .confirmed(receipt)
        } catch {
            return .rejected(
                requestID: savedPreviewRequestID,
                message: error.localizedDescription
            )
        }
    }

    func receipt(
        receiptID: UUID
    ) -> CodexGhostRepairBulkConfirmationReceipt? {
        receipts[receiptID]
    }

    func receiptForOperation(_ operationID: UUID) -> CodexGhostRepairBulkConfirmationReceipt? {
        receipts.values.first { $0.operationID == operationID }
    }

    func requestCount() -> Int { requests.count }
}

private actor AppTestDynamicGhostRepairBulkRepairCoordinator:
    CodexGhostRepairBulkRepairCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkRepairCapabilities.testOwned
    private let previewStore: AppTestGhostRepairBulkPreviewMemoryStore
    private let receiptCoordinator:
        AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator
    private var selectedItemsByOperation:
        [UUID: [CodexGhostRepairBulkPreviewItem]] = [:]
    private var reviewRequests: [CodexGhostRepairBulkRepairReviewRequest] = []
    private var executionRequests:
        [CodexGhostRepairBulkRepairExecutionRequest] = []
    private let reviewBlocked: String?
    private let executionUnknown: Bool
    private var shutdownBlocked = false

    func setShutdownBlocked(_ value: Bool) { shutdownBlocked = value }

    init(
        previewStore: AppTestGhostRepairBulkPreviewMemoryStore,
        receiptCoordinator:
            AppTestDynamicGhostRepairBulkConfirmationReceiptCoordinator,
        reviewBlocked: String? = nil,
        executionUnknown: Bool = false
    ) {
        self.previewStore = previewStore
        self.receiptCoordinator = receiptCoordinator
        self.reviewBlocked = reviewBlocked
        self.executionUnknown = executionUnknown
    }

    func prepareFinalReview(
        request: CodexGhostRepairBulkRepairReviewRequest
    ) async -> CodexGhostRepairBulkRepairReviewOutcome {
        reviewRequests.append(request)
        if shutdownBlocked { return .awaitingShutdown(message: "Database is still open.") }
        if let reviewBlocked { return .blocked(message: reviewBlocked) }
        guard let receipt = await receiptCoordinator.receipt(
            receiptID: request.confirmationReceiptID
        ), let evidence = await previewStore.evidence(
            requestID: receipt.savedPreviewRequestID
        ) else {
            return .blocked(message: "The exact 148-item evidence is missing.")
        }
        do {
            selectedItemsByOperation[receipt.operationID] =
                evidence.preview.selectedItems
            return .ready(
                try CodexGhostRepairBulkFinalReview(
                    operationID: receipt.operationID,
                    confirmationReceiptID: receipt.receiptID,
                    selectedCount: evidence.preview.selectedItems.count,
                    ordinaryCount: evidence.preview.ordinarySelectedCount,
                    automationCount: evidence.preview.automationSelectedCount,
                    alreadyAbsentCount:
                        evidence.preview.selectedItems.filter { $0.initiallyAbsent == true }.count,
                    blockedOutsideBatchCount:
                        evidence.preview.blockedItems.count,
                    sourceLayoutIdentifier:
                        evidence.preview.sourceLayoutIdentifier,
                    reviewDigest:
                        "sha256:" + String(repeating: "3", count: 64)
                )
            )
        } catch {
            return .blocked(message: error.localizedDescription)
        }
    }

    func execute(
        request: CodexGhostRepairBulkRepairExecutionRequest
    ) async -> CodexGhostRepairBulkRepairExecutionOutcome {
        executionRequests.append(request)
        if executionUnknown {
            return .recoveryRequired(operationID: request.review.operationID, message: "Readback required.")
        }
        guard let items = selectedItemsByOperation[request.review.operationID]
        else {
            return .unavailable(message: "The exact frozen selection is missing.")
        }
        do {
            return .completed(
                try CodexGhostRepairBulkRepairReport(
                    operationID: request.review.operationID,
                    outcome: .success,
                    itemReports: items.sorted { $0.threadID < $1.threadID }
                        .map {
                            .init(
                                threadID: $0.threadID,
                                category: $0.category,
                                outcome: $0.initiallyAbsent == true ? .alreadyAbsent : .success
                            )
                        },
                    reportDigest:
                        "sha256:" + String(repeating: "4", count: 64)
                )
            )
        } catch {
            return .recoveryRequired(
                operationID: request.review.operationID,
                message: error.localizedDescription
            )
        }
    }

    func reviewRequestCount() -> Int { reviewRequests.count }
    func executionRequestCount() -> Int { executionRequests.count }
}

private actor AppTestGhostRepairBulkConfirmationCoordinator:
    CodexGhostRepairBulkConfirmationChallengeCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationCapabilities.packagedEvidenceOnly
    private let outcome: CodexGhostRepairBulkConfirmationChallengeOutcome
    private var requests: [UUID] = []

    init(outcome: CodexGhostRepairBulkConfirmationChallengeOutcome) {
        self.outcome = outcome
    }

    func prepareChallenge(
        savedPreviewRequestID: UUID
    ) async -> CodexGhostRepairBulkConfirmationChallengeOutcome {
        requests.append(savedPreviewRequestID)
        return outcome
    }

    func requestCount() -> Int { requests.count }
}

private actor AppTestGhostRepairBulkConfirmationReceiptCoordinator:
    CodexGhostRepairBulkConfirmationReceiptCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationReceiptCapabilities
            .packagedReceiptOnly
    private let expectedPhrase: String
    private let outcome: CodexGhostRepairBulkConfirmationReceiptOutcome
    private var requests: [(UUID, String)] = []

    init(
        expectedPhrase: String,
        outcome: CodexGhostRepairBulkConfirmationReceiptOutcome
    ) {
        self.expectedPhrase = expectedPhrase
        self.outcome = outcome
    }

    func confirm(
        savedPreviewRequestID: UUID,
        exactConfirmationPhrase: String
    ) async -> CodexGhostRepairBulkConfirmationReceiptOutcome {
        requests.append((savedPreviewRequestID, exactConfirmationPhrase))
        guard exactConfirmationPhrase == expectedPhrase else {
            return .rejected(
                requestID: savedPreviewRequestID,
                message: "The confirmation phrase does not match this whole batch."
            )
        }
        return outcome
    }

    func requestCount() -> Int { requests.count }
}

private actor AppTestSuspendingGhostRepairBulkReceiptCoordinator:
    CodexGhostRepairBulkConfirmationReceiptCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationReceiptCapabilities
            .packagedReceiptOnly
    private let expectedPhrase: String
    private var requests: [(UUID, String)] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var outcomeContinuation:
        CheckedContinuation<
            CodexGhostRepairBulkConfirmationReceiptOutcome,
            Never
        >?

    init(expectedPhrase: String) {
        self.expectedPhrase = expectedPhrase
    }

    func confirm(
        savedPreviewRequestID: UUID,
        exactConfirmationPhrase: String
    ) async -> CodexGhostRepairBulkConfirmationReceiptOutcome {
        requests.append((savedPreviewRequestID, exactConfirmationPhrase))
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard exactConfirmationPhrase == expectedPhrase else {
            return .rejected(
                requestID: savedPreviewRequestID,
                message: "Unexpected confirmation phrase."
            )
        }
        return await withCheckedContinuation { continuation in
            outcomeContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func finish(
        with outcome: CodexGhostRepairBulkConfirmationReceiptOutcome
    ) {
        outcomeContinuation?.resume(returning: outcome)
        outcomeContinuation = nil
    }

    func requestCount() -> Int { requests.count }
}

private actor AppTestGhostRepairBulkConfirmationReceiptRecoveryCoordinator:
    CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationReceiptRecoveryCapabilities
            .packagedReadOnly
    private let outcome:
        CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome
    private var requests:
        [CodexGhostRepairBulkConfirmationReceiptRecoveryRequest] = []

    init(outcome: CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome) {
        self.outcome = outcome
    }

    func recoverReceipt(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest
    ) async -> CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome {
        requests.append(request)
        return outcome
    }

    func requestCount() -> Int { requests.count }
}

private actor AppTestSuspendingGhostRepairBulkConfirmationReceiptRecoveryCoordinator:
    CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationReceiptRecoveryCapabilities
            .packagedReadOnly
    private var requests:
        [CodexGhostRepairBulkConfirmationReceiptRecoveryRequest] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation:
        CheckedContinuation<
            CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome,
            Never
        >?

    func recoverReceipt(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest
    ) async -> CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome {
        requests.append(request)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func finish(
        with outcome: CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome
    ) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func requestCount() -> Int { requests.count }
}

private actor AppTestGhostRepairBulkFreshRecoveryCoordinator:
    CodexGhostRepairBulkFreshRecoveryCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkFreshRecoveryCapabilities.packagedExplicit
    private let outcomes:
        [CodexGhostRepairBulkRecoveryOperationIdentity:
            CodexGhostRepairBulkFreshRecoveryOutcome]
    private var requests: [CodexGhostRepairBulkRecoveryOperationIdentity] = []

    init(
        outcomes: [
            CodexGhostRepairBulkRecoveryOperationIdentity:
                CodexGhostRepairBulkFreshRecoveryOutcome
        ]
    ) {
        self.outcomes = outcomes
    }

    func recoverOperation(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkFreshRecoveryOutcome {
        requests.append(identity)
        return outcomes[identity] ?? .notFound(identity: identity)
    }

    func requestCount() -> Int { requests.count }
}

private actor AppTestGhostRepairBulkPreparedClosureCoordinator:
    CodexGhostRepairBulkPreparedClosureCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkPreparedClosureCapabilities.packagedExplicit
    private let reviewOutcome:
        CodexGhostRepairBulkPreparedClosureReviewOutcome
    private let commitOutcome:
        CodexGhostRepairBulkPreparedClosureCommitOutcome
    private var reviewRequests:
        [CodexGhostRepairBulkRecoveryOperationIdentity] = []
    private var commitRequests:
        [CodexGhostRepairBulkPreparedClosurePreview] = []

    init(
        reviewOutcome: CodexGhostRepairBulkPreparedClosureReviewOutcome,
        commitOutcome: CodexGhostRepairBulkPreparedClosureCommitOutcome
    ) {
        self.reviewOutcome = reviewOutcome
        self.commitOutcome = commitOutcome
    }

    func reviewClosure(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkPreparedClosureReviewOutcome {
        reviewRequests.append(identity)
        return reviewOutcome
    }

    func closePreparedOperation(
        _ preview: CodexGhostRepairBulkPreparedClosurePreview
    ) async -> CodexGhostRepairBulkPreparedClosureCommitOutcome {
        commitRequests.append(preview)
        return commitOutcome
    }

    func reviewRequestCount() -> Int { reviewRequests.count }
    func commitRequestCount() -> Int { commitRequests.count }
}

private actor AppTestSuspendingGhostRepairBulkPreparedClosureCoordinator:
    CodexGhostRepairBulkPreparedClosureCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkPreparedClosureCapabilities.packagedExplicit
    private let reviewOutcome:
        CodexGhostRepairBulkPreparedClosureReviewOutcome
    private var commitRequests:
        [CodexGhostRepairBulkPreparedClosurePreview] = []
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitContinuation:
        CheckedContinuation<
            CodexGhostRepairBulkPreparedClosureCommitOutcome,
            Never
        >?

    init(reviewOutcome: CodexGhostRepairBulkPreparedClosureReviewOutcome) {
        self.reviewOutcome = reviewOutcome
    }

    func reviewClosure(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkPreparedClosureReviewOutcome {
        reviewOutcome
    }

    func closePreparedOperation(
        _ preview: CodexGhostRepairBulkPreparedClosurePreview
    ) async -> CodexGhostRepairBulkPreparedClosureCommitOutcome {
        commitRequests.append(preview)
        let waiters = commitWaiters
        commitWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            commitContinuation = continuation
        }
    }

    func waitUntilCommitRequested() async {
        if !commitRequests.isEmpty { return }
        await withCheckedContinuation { commitWaiters.append($0) }
    }

    func finishCommit(
        with outcome: CodexGhostRepairBulkPreparedClosureCommitOutcome
    ) {
        commitContinuation?.resume(returning: outcome)
        commitContinuation = nil
    }

    func commitRequestCount() -> Int { commitRequests.count }
}

private actor AppTestSuspendingGhostRepairBulkFreshRecoveryCoordinator:
    CodexGhostRepairBulkFreshRecoveryCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkFreshRecoveryCapabilities.packagedExplicit
    private var requests: [CodexGhostRepairBulkRecoveryOperationIdentity] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation:
        CheckedContinuation<CodexGhostRepairBulkFreshRecoveryOutcome, Never>?

    func recoverOperation(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkFreshRecoveryOutcome {
        requests.append(identity)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func finish(with outcome: CodexGhostRepairBulkFreshRecoveryOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func requestCount() -> Int { requests.count }
}

private actor AppTestGhostRepairBulkRecoveryCoordinator:
    CodexGhostRepairBulkRecoveryCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkRecoveryCapabilities.packagedReadOnly
    private let previousOutcome:
        CodexGhostRepairBulkPreviousOperationsOutcome
    private let operationOutcomes:
        [CodexGhostRepairBulkRecoveryOperationIdentity:
            CodexGhostRepairBulkRecoveryReadbackOutcome]
    private var previousRequests = 0
    private var operationRequests:
        [CodexGhostRepairBulkRecoveryOperationIdentity] = []

    init(
        previousOutcome: CodexGhostRepairBulkPreviousOperationsOutcome,
        operationOutcomes: [
            CodexGhostRepairBulkRecoveryOperationIdentity:
                CodexGhostRepairBulkRecoveryReadbackOutcome
        ] = [:]
    ) {
        self.previousOutcome = previousOutcome
        self.operationOutcomes = operationOutcomes
    }

    func readPreviousOperations() async
        -> CodexGhostRepairBulkPreviousOperationsOutcome
    {
        previousRequests += 1
        return previousOutcome
    }

    func readOperation(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkRecoveryReadbackOutcome {
        operationRequests.append(identity)
        return operationOutcomes[identity]
            ?? .notFound(identity: identity)
    }

    func previousRequestCount() -> Int { previousRequests }
    func operationRequestCount() -> Int { operationRequests.count }
}

private actor AppTestSuspendingGhostRepairBulkRecoveryCoordinator:
    CodexGhostRepairBulkRecoveryCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkRecoveryCapabilities.packagedReadOnly
    private var previousRequests = 0
    private var operationRequests:
        [CodexGhostRepairBulkRecoveryOperationIdentity] = []
    private var previousWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var previousContinuation:
        CheckedContinuation<
            CodexGhostRepairBulkPreviousOperationsOutcome,
            Never
        >?
    private var operationContinuation:
        CheckedContinuation<
            CodexGhostRepairBulkRecoveryReadbackOutcome,
            Never
        >?

    func readPreviousOperations() async
        -> CodexGhostRepairBulkPreviousOperationsOutcome
    {
        previousRequests += 1
        let waiters = previousWaiters
        previousWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            previousContinuation = continuation
        }
    }

    func readOperation(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) async -> CodexGhostRepairBulkRecoveryReadbackOutcome {
        operationRequests.append(identity)
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            operationContinuation = continuation
        }
    }

    func waitUntilPreviousOperationsRequested() async {
        if previousRequests > 0 { return }
        await withCheckedContinuation { continuation in
            previousWaiters.append(continuation)
        }
    }

    func waitUntilOperationRequested() async {
        if !operationRequests.isEmpty { return }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    func finishPreviousOperations(
        with outcome: CodexGhostRepairBulkPreviousOperationsOutcome
    ) {
        previousContinuation?.resume(returning: outcome)
        previousContinuation = nil
    }

    func finishOperation(
        with outcome: CodexGhostRepairBulkRecoveryReadbackOutcome
    ) {
        operationContinuation?.resume(returning: outcome)
        operationContinuation = nil
    }

    func previousRequestCount() -> Int { previousRequests }
    func operationRequestCount() -> Int { operationRequests.count }
}

private actor AppTestSuspendingGhostRepairBulkRepairCoordinator:
    CodexGhostRepairBulkRepairCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkRepairCapabilities.testOwned
    private var reviewRequests: [CodexGhostRepairBulkRepairReviewRequest] = []
    private var executionRequests:
        [CodexGhostRepairBulkRepairExecutionRequest] = []
    private var reviewWaiters: [CheckedContinuation<Void, Never>] = []
    private var executionWaiters: [CheckedContinuation<Void, Never>] = []
    private var reviewContinuation:
        CheckedContinuation<CodexGhostRepairBulkRepairReviewOutcome, Never>?
    private var executionContinuation:
        CheckedContinuation<CodexGhostRepairBulkRepairExecutionOutcome, Never>?

    func prepareFinalReview(
        request: CodexGhostRepairBulkRepairReviewRequest
    ) async -> CodexGhostRepairBulkRepairReviewOutcome {
        reviewRequests.append(request)
        let waiters = reviewWaiters
        reviewWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            reviewContinuation = continuation
        }
    }

    func execute(
        request: CodexGhostRepairBulkRepairExecutionRequest
    ) async -> CodexGhostRepairBulkRepairExecutionOutcome {
        executionRequests.append(request)
        let waiters = executionWaiters
        executionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            executionContinuation = continuation
        }
    }

    func waitUntilReviewRequested() async {
        if !reviewRequests.isEmpty { return }
        await withCheckedContinuation { continuation in
            reviewWaiters.append(continuation)
        }
    }

    func waitUntilExecutionRequested() async {
        if !executionRequests.isEmpty { return }
        await withCheckedContinuation { continuation in
            executionWaiters.append(continuation)
        }
    }

    func finishReview(with outcome: CodexGhostRepairBulkRepairReviewOutcome) {
        reviewContinuation?.resume(returning: outcome)
        reviewContinuation = nil
    }

    func finishExecution(
        with outcome: CodexGhostRepairBulkRepairExecutionOutcome
    ) {
        executionContinuation?.resume(returning: outcome)
        executionContinuation = nil
    }

    func reviewRequestCount() -> Int { reviewRequests.count }
    func executionRequestCount() -> Int { executionRequests.count }
}

private actor AppTestGhostRepairBulkRepairCoordinator:
    CodexGhostRepairBulkRepairCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkRepairCapabilities.testOwned
    private let reviewOutcome: CodexGhostRepairBulkRepairReviewOutcome
    private let executionOutcome: CodexGhostRepairBulkRepairExecutionOutcome
    private var reviewRequests: [CodexGhostRepairBulkRepairReviewRequest] = []
    private var executionRequests:
        [CodexGhostRepairBulkRepairExecutionRequest] = []

    init(
        reviewOutcome: CodexGhostRepairBulkRepairReviewOutcome,
        executionOutcome: CodexGhostRepairBulkRepairExecutionOutcome
    ) {
        self.reviewOutcome = reviewOutcome
        self.executionOutcome = executionOutcome
    }

    func prepareFinalReview(
        request: CodexGhostRepairBulkRepairReviewRequest
    ) async -> CodexGhostRepairBulkRepairReviewOutcome {
        reviewRequests.append(request)
        return reviewOutcome
    }

    func execute(
        request: CodexGhostRepairBulkRepairExecutionRequest
    ) async -> CodexGhostRepairBulkRepairExecutionOutcome {
        executionRequests.append(request)
        return executionOutcome
    }

    func reviewRequestCount() -> Int { reviewRequests.count }
    func executionRequestCount() -> Int { executionRequests.count }
}
