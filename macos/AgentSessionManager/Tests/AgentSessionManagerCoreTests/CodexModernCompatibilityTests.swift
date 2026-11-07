import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexModernCompatibilityTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("asm-modern-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        try FileManager.default.trashItem(at: root, resultingItemURL: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRootedRealtimeMetadataIsReadOnlyAndDistinctFromTimedHistory() throws {
        let history = try fixture()
        let before = try Data(contentsOf: history)
        let metadata = try CodexCompatibilityDatabase.metadata(at: history)
        XCTAssertNil(metadata.check?.issue)
        XCTAssertEqual(metadata.userVersion, 0)
        XCTAssertEqual(metadata.check?.schemaProfileIdentifier, "thread-history-rooted-realtime")
        XCTAssertEqual(try Data(contentsOf: history), before)
        XCTAssertTrue(CodexCompatibilitySidecars.read(at: history).allMissing)
    }

    func testSameVersionRejectsIncompleteColumnsIndexesTriggersAndForeignKeys() throws {
        let mutations = [
            "ALTER TABLE thread_turns DROP COLUMN root_turn_id;",
            "ALTER TABLE thread_realtime_items ADD COLUMN changed TEXT;",
            "DROP TABLE thread_realtime_items;",
            "DROP INDEX idx_thread_realtime_items_boundary; CREATE INDEX idx_thread_realtime_items_boundary ON thread_realtime_items(thread_id, rollout_ordinal) WHERE item_type = 'different';",
            "DROP TRIGGER thread_realtime_items_projection_cleanup; CREATE TRIGGER thread_realtime_items_projection_cleanup AFTER DELETE ON thread_history_projection_state BEGIN DELETE FROM thread_realtime_items; END;",
            "CREATE TABLE unreviewed(thread_id TEXT REFERENCES thread_turns(thread_id));",
        ]
        for sql in mutations {
            let history = try fixture()
            try BulkShippingCompositionTestFixture.execute(sql, at: history)
            let metadata = try CodexCompatibilityDatabase.metadata(at: history)
            XCTAssertEqual(metadata.userVersion, 0)
            XCTAssertNotNil(metadata.check?.issue, sql)
        }
        for (before, after) in [("root_turn_id TEXT", "root_turn_id INTEGER"),
                                ("created_at_ms INTEGER NOT NULL", "created_at_ms TEXT NOT NULL")] {
            let history = try fixture(schema: CodexRealtimeHistoryTestFixture.schema.replacingOccurrences(of: before, with: after))
            XCTAssertEqual(try CodexCompatibilityDatabase.metadata(at: history).check?.issue, .columns)
        }
    }

    func testInstalledProfileRequiresCompleteDesktopAndHistoryPair() throws {
        let sqlite = root.appendingPathComponent("sqlite")
        try FileManager.default.createDirectory(at: sqlite, withIntermediateDirectories: false)
        let desktop = sqlite.appendingPathComponent("codex-dev.db")
        try BulkShippingCompositionTestFixture.createExtendedDesktop(at: desktop, itemCount: 0, profile: .desktopV34Async)
        let history = root.appendingPathComponent("thread_history_1.sqlite")
        try BulkShippingCompositionTestFixture.execute(CodexRealtimeHistoryTestFixture.schema, at: history)
        for runtime in ["0.164.0", "0.166.0-alpha.5.1"] {
            XCTAssertEqual(try CodexGhostRepairInstalledSourceProfileReader.read(exactRuntimeVersion: runtime, databaseURL: desktop), .v166DesktopV34Realtime)
        }
        try BulkShippingCompositionTestFixture.execute("ALTER TABLE thread_turns ADD COLUMN unreviewed TEXT", at: history)
        XCTAssertNil(try CodexGhostRepairInstalledSourceProfileReader.read(exactRuntimeVersion: "0.164.0", databaseURL: desktop))
        XCTAssertNil(try CodexGhostRepairInstalledSourceProfileReader.read(exactRuntimeVersion: "0.164.1", databaseURL: desktop))
    }

    func testOfficialProjectCatalogRequiresEveryPageWithoutRepeatedCursorOrID() throws {
        let first = "01900000-0000-7000-8000-000000000001"
        let second = "01900000-0000-7000-8000-000000000002"
        var cursors: [String?] = []
        let result = try CodexProjectCatalog.collect { cursor in
            cursors.append(cursor)
            return .init(data: [.init(id: cursor == nil ? first : second, name: "Project", roots: [.init(path: "/tmp/project")], position: cursor == nil ? 0 : 1)], nextCursor: cursor == nil ? "page2" : nil)
        }
        XCTAssertEqual(result.map(\.id), [first, second])
        XCTAssertEqual(cursors, [nil, "page2"])
        XCTAssertThrowsError(try CodexProjectCatalog.collect { _ in
            .init(data: [], nextCursor: "same")
        })
        XCTAssertThrowsError(try CodexProjectCatalog.collect { cursor in
            .init(data: [.init(id: first, name: "Project", roots: [], position: 0)], nextCursor: cursor == nil ? "next" : nil)
        })
        XCTAssertThrowsError(try CodexProjectCatalog.collect { _ in
            .init(data: [.init(id: first, name: "Project", roots: [.init(path: "relative")], position: 0)], nextCursor: nil)
        })
        var page = 0
        XCTAssertThrowsError(try CodexProjectCatalog.collect { _ in
            page += 1
            return .init(data: [], nextCursor: "page-\(page)")
        })
        XCTAssertEqual(page, 20)
    }

    func testRealtimeEvidenceCannotBeOmittedOrReviewedAway() throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, desktopSchema: 34,
            profile: .v166DesktopV34Realtime, runtimeVersion: "0.164.0")
        let source = try XCTUnwrap(fixture.inventory.sourceEvidence)
        func input(_ realtime: Int?) -> CodexGhostRepairBulkInventoryInput {
            let targets = source.targets.map { target in
                var refs = target.references; refs.realtimeItems = realtime
                return CodexGhostRepairSnapshotAnalysisTargetEvidence(threadID: target.threadID,
                    catalogRowDigests: target.catalogRowDigests, automationRunRowDigests: target.automationRunRowDigests,
                    automationStableFieldsDigests: target.automationStableFieldsDigests,
                    automationDefinitionRowDigests: target.automationDefinitionRowDigests,
                    references: refs, rowContract: target.rowContract)
            }
            return .init(snapshotReference: source.snapshotReference, sourceLayoutIdentifier: source.sourceLayoutIdentifier,
                sourceFingerprintHash: source.sourceFingerprintHash, manifestHash: source.manifestHash,
                databases: source.databases, targets: targets, protectionEvidence: source.protectionEvidence, authority: source.authority)
        }
        XCTAssertThrowsError(try CodexGhostRepairBulkInventoryBuilder.build(input: input(nil)))
        let protected = try CodexGhostRepairBulkInventoryBuilder.build(input: input(1))
        XCTAssertEqual(protected.eligibleItemCount, 0)
        XCTAssertEqual(try protected.reviewingKnownResidue(true).eligibleItemCount, 0)
        XCTAssertEqual(try CodexGhostRepairBulkInventoryBuilder.build(input: input(0)).eligibleItemCount, 2)
        var old = source.targets[0].references; old.realtimeItems = nil
        let encoded = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("realtimeItems"))
        XCTAssertNil(try JSONDecoder().decode(CodexGhostRepairSnapshotAnalysisReferenceCounts.self, from: encoded).realtimeItems)
    }

    private func fixture(schema: String = CodexRealtimeHistoryTestFixture.schema) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("thread_history_1.sqlite")
        try BulkShippingCompositionTestFixture.execute(schema, at: file)
        return file
    }
}
