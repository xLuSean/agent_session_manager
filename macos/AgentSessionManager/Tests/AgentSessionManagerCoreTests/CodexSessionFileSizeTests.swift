import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexSessionFileSizeTests: XCTestCase {
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
        let sizes = await CodexSessionFileSizeReader().sizes(homeURL: root, sessionIDs: [first, second])
        XCTAssertTrue(sizes.isEmpty)
    }

    private func file(_ path: String, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: bytes).write(to: url)
    }
}
