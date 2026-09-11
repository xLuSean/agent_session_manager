import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexSessionFileSizeTests: XCTestCase {
    func testDeletedSpaceCountsOnlySuccessfulIDsWithKnownBeforeAndZeroAfter() {
        let summary = DeletedConversationSpaceSummary(
            verifiedDeletedSessionIDs: ["a", "b", "c", "d"],
            before: ["a": 1_000, "b": 2_000, "c": 3_000, "unrelated": 9_000],
            after: ["a": 0, "b": 1, "d": 0, "unrelated": 0])
        XCTAssertEqual(summary.measuredBytes, 1_000)
        XCTAssertEqual(summary.measuredSessionCount, 1)
        XCTAssertEqual(summary.deletedSessionCount, 4)
        XCTAssertFalse(summary.isComplete)
    }

    func testDeletedSpaceDistinguishesKnownZeroFromUnavailableAndChecksOverflow() {
        let knownZero = DeletedConversationSpaceSummary(verifiedDeletedSessionIDs: ["a"], before: ["a": 0], after: ["a": 0])
        XCTAssertEqual(knownZero.measuredBytes, 0)
        XCTAssertTrue(knownZero.isComplete)
        let unavailable = DeletedConversationSpaceSummary(verifiedDeletedSessionIDs: ["a"], before: [:], after: ["a": 0])
        XCTAssertNil(unavailable.measuredBytes)
        XCTAssertFalse(unavailable.isComplete)
        let overflow = DeletedConversationSpaceSummary(verifiedDeletedSessionIDs: ["a", "b"], before: ["a": .max, "b": 1], after: ["a": 0, "b": 0])
        XCTAssertNil(overflow.measuredBytes)
        XCTAssertFalse(overflow.isComplete)
    }

    func testDeletedSpaceSumsCompleteBatchAndExcludesUnsuccessfulItems() {
        let summary = DeletedConversationSpaceSummary(verifiedDeletedSessionIDs: ["a", "b"], before: ["a": 31_100_000, "b": 538_000, "failed": 500], after: ["a": 0, "b": 0, "failed": 0])
        XCTAssertEqual(summary.measuredBytes, 31_638_000)
        XCTAssertEqual(summary.measuredSessionCount, 2)
        XCTAssertTrue(summary.isComplete)
        let none = DeletedConversationSpaceSummary(verifiedDeletedSessionIDs: [], before: ["failed": 500], after: [:])
        XCTAssertEqual(none.measuredBytes, 0)
        XCTAssertEqual(none.deletedSessionCount, 0)
    }

    private let first = "019f64bd-dc48-7470-a9e1-ed6b085e96c1"
    private let second = "019f6a30-7922-7b62-a773-e95674a56cd2"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-file-sizes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        cleanup.arguments = ["trash", root.path]
        try cleanup.run()
        cleanup.waitUntilExit()
        XCTAssertEqual(cleanup.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testSumsAllOldAndCurrentFilesInBothRootsWithoutReadingContents() async throws {
        try file("sessions/2026/09/09/rollout-old-\(first).jsonl", bytes: 12)
        try file("sessions/2026/09/09/rollout-current-\(first).jsonl", bytes: 23)
        try file("archived_sessions/rollout-archived-\(first).jsonl", bytes: 34)
        // Neither unrelated data nor same-ID backups belong to the total.
        try file("backups/rollout-\(first).jsonl", bytes: 1_000)
        try file("sessions/notes-\(first).jsonl", bytes: 1_000)
        try file("sessions/rollout-\(first).jsonl.bak", bytes: 1_000)
        try file("state_5.sqlite", bytes: 1_000)
        let sizes = await CodexSessionFileSizeReader().sizes(homeURL: root, sessionIDs: [first, second, "invalid"])
        XCTAssertEqual(sizes, [first: 69, second: 0])
    }

    func testRefreshMeasuresGrowthAndFilesNoLongerInTranscriptRoots() async throws {
        let path = "sessions/rollout-\(first).jsonl"
        try file(path, bytes: 10)
        let reader = CodexSessionFileSizeReader()
        let before = await reader.sizes(homeURL: root, sessionIDs: [first])
        XCTAssertEqual(before[first], 10)
        try file(path, bytes: 100)
        let grown = await reader.sizes(homeURL: root, sessionIDs: [first])
        XCTAssertEqual(grown[first], 100)
        try FileManager.default.moveItem(at: root.appendingPathComponent(path), to: root.appendingPathComponent("retained-test-file"))
        let after = await reader.sizes(homeURL: root, sessionIDs: [first])
        XCTAssertEqual(after[first], 0)
    }

    func testMissingHomeIsUnknownButMissingTranscriptDirectoriesAreZero() async {
        let reader = CodexSessionFileSizeReader()
        let missing = await reader.sizes(homeURL: root.appendingPathComponent("missing"), sessionIDs: [first])
        let empty = await reader.sizes(homeURL: root, sessionIDs: [first])
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(empty[first], 0)
    }

    func testUnexpectedRootTypeAndTraversalLimitDoNotReturnPartialSizes() async throws {
        try file("sessions/rollout-\(first).jsonl", bytes: 10)
        try file("sessions/rollout-\(second).jsonl", bytes: 20)
        let limited = await CodexSessionFileSizeReader(maximumEntries: 1).sizes(homeURL: root, sessionIDs: [first, second])
        XCTAssertTrue(limited.isEmpty)
        try file("archived_sessions", bytes: 1)
        let invalid = await CodexSessionFileSizeReader().sizes(homeURL: root, sessionIDs: [first])
        XCTAssertTrue(invalid.isEmpty)
    }

    func testDoesNotFollowSymlinkDirectoriesOrFiles() async throws {
        try file("outside/rollout-\(first).jsonl", bytes: 10)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("sessions"),
            withDestinationURL: root.appendingPathComponent("outside"))
        let linkedRoot = await CodexSessionFileSizeReader().sizes(homeURL: root, sessionIDs: [first])
        XCTAssertTrue(linkedRoot.isEmpty)
        let otherHome = root.appendingPathComponent("other-home")
        try file("other-home/sessions/rollout-\(second).jsonl", bytes: 20)
        try FileManager.default.createSymbolicLink(
            at: otherHome.appendingPathComponent("sessions/rollout-\(first).jsonl"),
            withDestinationURL: root.appendingPathComponent("outside/rollout-\(first).jsonl"))
        let linkedFile = await CodexSessionFileSizeReader().sizes(homeURL: otherHome, sessionIDs: [first])
        XCTAssertTrue(linkedFile.isEmpty)
    }

    func testAmbiguousMultiIDFileIsNotDoubleCountedOrReportedAsZero() async throws {
        try file("sessions/rollout-\(first)_\(second).jsonl", bytes: 10)
        let result = await CodexSessionFileSizeReader().inspect(homeURL: root, sessionIDs: [first, second])
        XCTAssertTrue(result.sizes.isEmpty)
        XCTAssertEqual(result.issues, [first: .invalidHeader, second: .invalidHeader])
    }

    func testMultiGigabyteFilesUseBoundedHeadersAndSumOldCurrentAndArchivedFiles() async throws {
        try file("sessions/rollout-old-\(first).jsonl", bytes: 35)
        // Sparse files exercise multi-GB logical sizes without allocating a multi-GB fixture.
        try metadataFile("sessions/2026/09/01/rollout-\(first)_\(second).jsonl",
                         payload: ["id": first, "session_id": first], bytes: 3_650_000_000, padding: 50_000)
        try metadataFile("archived_sessions/rollout-current-\(first)_\(second).jsonl",
                         payload: ["id": first], bytes: 250_000_000)
        let result = await CodexSessionFileSizeReader().inspect(homeURL: root, sessionIDs: [first, second])
        XCTAssertEqual(result.sizes, [first: 3_900_000_035, second: 0])
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertGreaterThan(result.headerBytesRead, 50_000)
        XCTAssertLessThanOrEqual(result.headerBytesRead, 80 * 1024)
    }

    func testMetadataIDVariantsResolveTheOwnerInsteadOfAssumingFilenamePosition() async throws {
        let payloads: [[String: Any]] = [
            ["id": first], ["session_id": first], ["id": first, "session_id": first],
            ["id": first.uppercased()], ["id": second]
        ]
        for (index, payload) in payloads.enumerated() {
            let home = root.appendingPathComponent("case-\(index)")
            try metadataFile("case-\(index)/sessions/rollout-\(first)_\(second).jsonl", payload: payload, bytes: 4_096)
            let result = await CodexSessionFileSizeReader().inspect(homeURL: home, sessionIDs: [first, second])
            XCTAssertEqual(result.sizes, index == 4 ? [first: 0, second: 4_096] : [first: 4_096, second: 0])
            XCTAssertTrue(result.issues.isEmpty)
        }
    }

    func testInvalidOrConflictingMetadataDoesNotInventAnOwner() async throws {
        let foreign = "11111111-1111-4111-8111-111111111111"
        let cases: [(payload: [String: Any], issue: SessionFileSizeIssue)] = [
            ([:], .invalidHeader), (["id": 42], .invalidHeader),
            (["id": first, "session_id": NSNull()], .invalidHeader),
            (["id": "invalid"], .invalidHeader),
            (["id": first, "session_id": second], .conflictingIdentity),
            (["id": foreign], .conflictingIdentity)
        ]
        for (index, item) in cases.enumerated() {
            let home = root.appendingPathComponent("case-\(index)")
            try metadataFile("case-\(index)/sessions/rollout-\(first)_\(second).jsonl", payload: item.payload, bytes: 4_096)
            let result = await CodexSessionFileSizeReader().inspect(homeURL: home, sessionIDs: [first, second])
            XCTAssertTrue(result.sizes.isEmpty)
            XCTAssertEqual(result.issues, [first: item.issue, second: item.issue])
        }
        try metadataFile("wrong-type/sessions/rollout-\(first)_\(second).jsonl",
                         payload: ["id": first], bytes: 4_096, recordType: "response_item")
        let wrongType = await CodexSessionFileSizeReader().inspect(
            homeURL: root.appendingPathComponent("wrong-type"), sessionIDs: [first])
        XCTAssertEqual(wrongType.issues[first], .invalidHeader)
        XCTAssertNil(wrongType.sizes[first])
    }

    func testReadCapsStopAtTheHeaderAndWholeScanLimits() async throws {
        try metadataFile("per-file/sessions/rollout-\(first)_\(second).jsonl",
                         payload: ["id": first], bytes: 1_000_000, padding: 300_000)
        let perFile = await CodexSessionFileSizeReader(maximumHeaderBytes: .max).inspect(
            homeURL: root.appendingPathComponent("per-file"), sessionIDs: [first])
        XCTAssertEqual(perFile.issues[first], .headerTooLarge)
        XCTAssertEqual(perFile.headerBytesRead, 256 * 1024)
        XCTAssertNil(perFile.sizes[first])

        for index in 1...2 {
            try metadataFile("whole-scan/sessions/rollout-\(index)-\(first)_\(second).jsonl",
                             payload: ["id": first], bytes: 4_096, padding: 300)
        }
        let budget = await CodexSessionFileSizeReader(maximumHeaderBytes: 512, maximumTotalHeaderBytes: 768).inspect(
            homeURL: root.appendingPathComponent("whole-scan"), sessionIDs: [first])
        XCTAssertEqual(budget.issues[first], .headerBudgetExceeded)
        XCTAssertEqual(budget.headerBytesRead, 768)
        XCTAssertNil(budget.sizes[first])
    }

    func testUnknownMultiIDFileInvalidatesItsOwnersButNotUnrelatedMeasuredSessions() async throws {
        let unrelated = "22222222-2222-4222-8222-222222222222"
        try file("sessions/rollout-old-\(first).jsonl", bytes: 10)
        try file("sessions/rollout-\(unrelated).jsonl", bytes: 500)
        try file("sessions/rollout-\(first)_\(second).jsonl", bytes: 10)
        let result = await CodexSessionFileSizeReader().inspect(homeURL: root, sessionIDs: [first, second, unrelated])
        XCTAssertEqual(result.sizes, [unrelated: 500])
        XCTAssertEqual(result.issues, [first: .invalidHeader, second: .invalidHeader])
    }

    func testRequestForSuffixIDDoesNotCountAnotherSessionsFile() async throws {
        try metadataFile("sessions/rollout-\(first)_\(second).jsonl", payload: ["id": first], bytes: 4_096)
        let result = await CodexSessionFileSizeReader().inspect(homeURL: root, sessionIDs: [second])
        XCTAssertEqual(result.sizes, [second: 0])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testMultiIDRefreshReadsCurrentIdentityAndSizeWithoutKeepingOldMetadata() async throws {
        let path = "sessions/rollout-\(first)_\(second).jsonl"
        let reader = CodexSessionFileSizeReader()
        try metadataFile(path, payload: ["id": first], bytes: 4_096)
        let before = await reader.sizes(homeURL: root, sessionIDs: [first, second])
        XCTAssertEqual(before, [first: 4_096, second: 0])
        try metadataFile(path, payload: ["id": second], bytes: 8_192)
        let after = await reader.sizes(homeURL: root, sessionIDs: [first, second])
        XCTAssertEqual(after, [first: 0, second: 8_192])
    }

    func testDeletedSpaceUsesResolvedMultiIDTotalsAndRequiresNoRemainingFiles() async throws {
        let old = "sessions/rollout-old-\(first).jsonl"
        let current = "sessions/rollout-\(first)_\(second).jsonl"
        try file(old, bytes: 10)
        try metadataFile(current, payload: ["id": first], bytes: 4_096)
        let reader = CodexSessionFileSizeReader()
        let before = await reader.sizes(homeURL: root, sessionIDs: [first])
        try FileManager.default.moveItem(at: root.appendingPathComponent(current), to: root.appendingPathComponent("retained-current"))
        let partial = await reader.sizes(homeURL: root, sessionIDs: [first])
        XCTAssertNil(DeletedConversationSpaceSummary(verifiedDeletedSessionIDs: [first], before: before, after: partial).measuredBytes)
        try FileManager.default.moveItem(at: root.appendingPathComponent(old), to: root.appendingPathComponent("retained-old"))
        let after = await reader.sizes(homeURL: root, sessionIDs: [first])
        let summary = DeletedConversationSpaceSummary(verifiedDeletedSessionIDs: [first], before: before, after: after)
        XCTAssertEqual(summary.measuredBytes, 4_106)
        XCTAssertTrue(summary.isComplete)
    }

    func testCancelledScanReturnsAReasonWithoutReadingHeaders() async throws {
        try metadataFile("sessions/rollout-\(first)_\(second).jsonl", payload: ["id": first], bytes: 4_096)
        let home = root!
        let id = first
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CodexSessionFileSizeReader().inspect(homeURL: home, sessionIDs: [id])
        }
        let result = await task.value
        XCTAssertTrue(result.sizes.isEmpty)
        XCTAssertEqual(result.issues[first], .cancelled)
        XCTAssertEqual(result.headerBytesRead, 0)
    }

    private func metadataFile(_ path: String, payload: [String: Any], bytes: UInt64,
                              padding: Int = 0, recordType: String = "session_meta") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var fields = payload
        fields["fixture_padding"] = String(repeating: "x", count: padding)
        var header = try JSONSerialization.data(withJSONObject: ["type": recordType, "payload": fields], options: [.sortedKeys])
        header.append(10)
        XCTAssertLessThanOrEqual(UInt64(header.count), bytes)
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
    }

    private func file(_ path: String, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: bytes).write(to: url)
    }
}
