import XCTest
@testable import AgentSessionManagerCore

final class CodexGhostRepairBulkRepairActionTests: XCTestCase {
    func testPackagedDefaultIsUnavailableAndAuthorityFree() async {
        let coordinator = CodexGhostRepairBulkRepairCoordinatorFactory
            .packagedDefaultBlocked()

        XCTAssertEqual(coordinator.capabilities, .unavailable)
        XCTAssertFalse(coordinator.capabilities.reviewAvailable)
        XCTAssertFalse(coordinator.capabilities.executionAvailable)
        XCTAssertFalse(coordinator.capabilities.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.automaticRetryAllowed)
        XCTAssertFalse(coordinator.capabilities.automaticRestoreAllowed)
        XCTAssertFalse(coordinator.capabilities.silentSelectionShrinkAllowed)
    }

    func testPackagedProductionConstructionExposesWholeBatchActionsWithoutIO()
    {
        let coordinator = CodexGhostRepairBulkRepairCoordinatorFactory
            .packagedProduction()

        XCTAssertTrue(coordinator.capabilities.reviewAvailable)
        XCTAssertTrue(coordinator.capabilities.executionAvailable)
        XCTAssertFalse(coordinator.capabilities.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.automaticRetryAllowed)
        XCTAssertFalse(coordinator.capabilities.automaticRestoreAllowed)
        XCTAssertFalse(coordinator.capabilities.silentSelectionShrinkAllowed)
    }

    func testExactHistoricalScaleReviewAndReportRemainWholeBatch()
        throws
    {
        let operationID = UUID()
        let receiptID = UUID()
        let review = try CodexGhostRepairBulkFinalReview(
            operationID: operationID,
            confirmationReceiptID: receiptID,
            selectedCount: 148,
            ordinaryCount: 100,
            automationCount: 48,
            blockedOutsideBatchCount: 0,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceProfile.v151DesktopV33.identifier,
            reviewDigest: digest("a")
        )
        let items = (0..<148).map { index in
            CodexGhostRepairBulkRepairItemReport(
                threadID: String(
                    format: "00000000-0000-4000-8000-%012d",
                    index
                ),
                category: index < 100 ? .ordinary : .automation,
                outcome: .success
            )
        }
        let report = try CodexGhostRepairBulkRepairReport(
            operationID: operationID,
            outcome: .success,
            itemReports: items,
            reportDigest: digest("b")
        )

        XCTAssertEqual(review.selectedCount, 148)
        XCTAssertEqual(report.itemReports.count, 148)
        XCTAssertEqual(Set(report.itemReports.map(\.threadID)).count, 148)
        XCTAssertTrue(review.allOrNothing)
        XCTAssertFalse(review.automaticRetryAllowed)
        XCTAssertFalse(review.automaticRestoreAllowed)
        XCTAssertFalse(review.silentSelectionShrinkAllowed)
        XCTAssertFalse(report.automaticRetryAllowed)
        XCTAssertFalse(report.automaticRestoreAllowed)
    }

    func testInvalidCountsAndNonItemizedReportsFailClosed() {
        XCTAssertThrowsError(
            try CodexGhostRepairBulkFinalReview(
                operationID: UUID(),
                confirmationReceiptID: UUID(),
                selectedCount: 148,
                ordinaryCount: 99,
                automationCount: 48,
                blockedOutsideBatchCount: 0,
                sourceLayoutIdentifier:
                    CodexGhostRepairSnapshotSourceProfile.v151DesktopV33.identifier,
                reviewDigest: digest("c")
            )
        )
        XCTAssertThrowsError(
            try CodexGhostRepairBulkRepairReport(
                operationID: UUID(),
                outcome: .success,
                itemReports: [],
                reportDigest: digest("d")
            )
        )
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}
