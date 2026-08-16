@testable import AgentSessionManagerCore
import AgentSessionManagerFixtures
import Foundation
import XCTest

final class FixtureOperationHistoryLedgerTests: XCTestCase {
    func testRecordConvertsFixtureReportWithoutClaimingReleasedBytes() throws {
        let ledger = FixtureOperationHistoryLedger()
        let bundle = fixtureBundle(
            number: 1,
            operation: .emptyTrash,
            before: .trash,
            observed: .deleted,
            completedAt: date(20)
        )

        try ledger.record(preview: bundle.preview, report: bundle.report)
        let page = try ledger.operationHistory()

        XCTAssertEqual(page.entries.count, 1)
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.reportID, bundle.report.id)
        XCTAssertEqual(entry.operation, .permanentlyDelete)
        XCTAssertEqual(entry.outcome, .success)
        XCTAssertEqual(entry.startedAt, bundle.preview.generatedAt)
        XCTAssertEqual(entry.completedAt, bundle.report.completedAt)
        XCTAssertEqual(entry.verifiedReleasedBytes, 0)
        XCTAssertFalse(entry.releasedBytesComplete)
        XCTAssertEqual(entry.items[0].nativeSessionID, "fixture-session-1")
        XCTAssertEqual(entry.items[0].projectID, "fixture:project-1")
        XCTAssertEqual(entry.items[0].expectedNativeState, .archived)
        XCTAssertEqual(entry.items[0].observedNativeState, .absent)
        XCTAssertNil(entry.items[0].verifiedReleasedBytes)
        XCTAssertNil(entry.items[0].errorMessage)
    }

    func testQueryUsesSharedFiltersSearchAndStableKeysetPagination() throws {
        let ledger = FixtureOperationHistoryLedger()
        let first = fixtureBundle(number: 1, operation: .archive, completedAt: date(20))
        let second = fixtureBundle(number: 2, operation: .restore, before: .archive, observed: .active, completedAt: date(30))
        let third = fixtureBundle(number: 3, operation: .restore, before: .archive, observed: .active, completedAt: date(30))
        try ledger.record(preview: first.preview, report: first.report)
        try ledger.record(preview: second.preview, report: second.report)
        try ledger.record(preview: third.preview, report: third.report)

        let firstPage = try ledger.operationHistory(OperationHistoryQuery(limit: 2))
        XCTAssertEqual(firstPage.entries.map(\.reportID), [third.report.id, second.report.id])
        XCTAssertEqual(
            firstPage.nextCursor,
            OperationHistoryCursor(completedAt: date(30), reportID: second.report.id)
        )

        let secondPage = try ledger.operationHistory(
            OperationHistoryQuery(cursor: firstPage.nextCursor, limit: 2)
        )
        XCTAssertEqual(secondPage.entries.map(\.reportID), [first.report.id])
        XCTAssertNil(secondPage.nextCursor)

        XCTAssertEqual(
            try ledger.operationHistory(
                OperationHistoryQuery(operation: .restore, searchText: "fixture title 3")
            ).entries.map(\.reportID),
            [third.report.id]
        )
        XCTAssertEqual(
            try ledger.operationHistory(
                OperationHistoryQuery(searchText: "fixture:project-2")
            ).entries.map(\.reportID),
            [second.report.id]
        )
        XCTAssertTrue(
            try ledger.operationHistory(OperationHistoryQuery(searchText: "%")).entries.isEmpty
        )
    }

    func testMoveToArchiveRemainsDistinctInHistory() throws {
        let ledger = FixtureOperationHistoryLedger()
        let bundle = fixtureBundle(
            number: 8,
            operation: .moveToArchive,
            before: .trash,
            observed: .archive,
            completedAt: date(40)
        )

        try ledger.record(preview: bundle.preview, report: bundle.report)

        XCTAssertEqual(try ledger.operationHistory().entries.first?.operation, .moveToArchive)
        XCTAssertEqual(
            try ledger.operationHistory(OperationHistoryQuery(operation: .archive)).entries.count,
            0
        )
    }

    func testRetentionIsBoundedPerProvider() throws {
        let ledger = try FixtureOperationHistoryLedger(maximumReportsPerProvider: 2)
        for number in 1 ... 3 {
            let bundle = fixtureBundle(
                number: number,
                provider: .codex,
                completedAt: date(Double(number))
            )
            try ledger.record(preview: bundle.preview, report: bundle.report)
        }
        for number in 4 ... 5 {
            let bundle = fixtureBundle(
                number: number,
                provider: .claudeCode,
                completedAt: date(Double(number))
            )
            try ledger.record(preview: bundle.preview, report: bundle.report)
        }

        XCTAssertEqual(ledger.count, 4)
        XCTAssertEqual(
            try ledger.operationHistory(OperationHistoryQuery(provider: .codex)).entries
                .map(\.reportID),
            [reportID(3), reportID(2)]
        )
        XCTAssertEqual(
            try ledger.operationHistory(OperationHistoryQuery(provider: .claudeCode)).entries
                .map(\.reportID),
            [reportID(5), reportID(4)]
        )
    }

    func testMismatchedReportFailsWithoutPartialInsertAndClearRemovesHistory() throws {
        let ledger = FixtureOperationHistoryLedger()
        let valid = fixtureBundle(number: 1, operation: .archive, completedAt: date(10))
        try ledger.record(preview: valid.preview, report: valid.report)

        let mismatched = OperationReport(
            id: reportID(2),
            previewID: valid.preview.id,
            provider: valid.preview.provider,
            operation: valid.preview.operation,
            completedAt: date(20),
            items: [
                OperationResultItem(
                    managerKey: "codex:different",
                    nativeID: "different",
                    title: "Different",
                    projectName: nil,
                    workingDirectory: "/tmp/fixture",
                    beforeCollection: .active,
                    observedFinalCollection: .archive,
                    success: true,
                    note: "fixture"
                ),
            ]
        )

        XCTAssertThrowsError(try ledger.record(preview: valid.preview, report: mismatched))
        XCTAssertEqual(ledger.count, 1)
        ledger.removeAll()
        XCTAssertEqual(ledger.count, 0)
        XCTAssertTrue(try ledger.operationHistory().entries.isEmpty)
    }

    func testRemoveDeletesOnlyExactFrozenReportIDs() throws {
        let ledger = FixtureOperationHistoryLedger()
        let first = fixtureBundle(number: 1, completedAt: date(10))
        let second = fixtureBundle(number: 2, completedAt: date(20))
        let third = fixtureBundle(number: 3, completedAt: date(30))
        try ledger.record(preview: first.preview, report: first.report)
        try ledger.record(preview: second.preview, report: second.report)
        try ledger.record(preview: third.preview, report: third.report)

        XCTAssertEqual(
            try ledger.remove(reportIDs: [first.report.id, third.report.id]),
            2
        )
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(
            try ledger.operationHistory().entries.map(\.reportID),
            [second.report.id]
        )
        XCTAssertThrowsError(try ledger.remove(reportIDs: [first.report.id]))
        XCTAssertEqual(ledger.count, 1)
    }

    private typealias Bundle = (preview: OperationPreview, report: OperationReport)

    private func fixtureBundle(
        number: Int,
        provider: AgentSystem = .codex,
        operation: SessionOperation = .archive,
        before: SessionCollection = .active,
        observed: SessionCollection = .archive,
        completedAt: Date
    ) -> Bundle {
        let managerKey = "\(provider.rawValue):fixture-session-\(number)"
        let preview = OperationPreview(
            id: previewID(number),
            provider: provider,
            operation: operation,
            confirmationToken: "FIXTURE-TOKEN-\(number)",
            generatedAt: completedAt.addingTimeInterval(-2),
            items: [
                OperationPreviewItem(
                    managerKey: managerKey,
                    nativeID: "fixture-session-\(number)",
                    title: "Fixture Title \(number)",
                    projectID: "fixture:project-\(number)",
                    projectName: "Project \(number)",
                    workingDirectory: "/tmp/fixture-\(number)",
                    beforeCollection: before,
                    targetCollection: operation.targetCollection(from: before),
                    sizeBytes: Int64(number * 100)
                ),
            ],
            warnings: []
        )
        let report = OperationReport(
            id: reportID(number),
            previewID: preview.id,
            provider: provider,
            operation: operation,
            completedAt: completedAt,
            items: [
                OperationResultItem(
                    managerKey: managerKey,
                    nativeID: "fixture-session-\(number)",
                    title: "Fixture Title \(number)",
                    projectName: "Project \(number)",
                    workingDirectory: "/tmp/fixture-\(number)",
                    beforeCollection: before,
                    observedFinalCollection: observed,
                    success: true,
                    note: "Verified in fixture provider; no real agent session was changed."
                ),
            ]
        )
        return (preview, report)
    }

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + seconds)
    }

    private func previewID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    private func reportID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", number))!
    }
}
