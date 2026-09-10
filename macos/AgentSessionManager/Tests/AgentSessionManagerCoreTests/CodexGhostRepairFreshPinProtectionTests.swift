@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairFreshPinProtectionTests: XCTestCase {
    func testPinAddedAfterPreviewStopsFinalReview() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        try writePins([fixture.livePlan.selectedThreadIDs[0]], fixture)
        let revalidator = try revalidator(fixture)
        do {
            _ = try await revalidator.revalidate(
                storedPreview: fixture.storedPreview,
                resolution: fixture.bulkResolution,
                verifiedBackup: fixture.livePlan.backup
            )
            XCTFail("A newly pinned target must stop Final Review.")
        } catch CodexGhostRepairError.invalidProtectionEvidence { }
        try assertCatalogCount(2, fixture)
    }

    func testPinAddedAfterFinalReviewStopsWholeMixedBatch() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        _ = try await revalidator(fixture).revalidate(
            storedPreview: fixture.storedPreview,
            resolution: fixture.bulkResolution,
            verifiedBackup: fixture.livePlan.backup
        )
        // The second item is an automation session; one pin protects the whole batch.
        try writePins([fixture.livePlan.selectedThreadIDs[1]], fixture)
        let result = try await fixture.liveMutator().executeOnce(
            plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt
        )
        XCTAssertEqual(result, .notAttempted)
        try assertCatalogCount(2, fixture)
    }

    func testUnknownOrMalformedPinStateCannotAuthorizeMutation() async throws {
        for state in ["{}", "null", "{", #"{"pinned-thread-ids":null}"#,
                      #"{"pinned-thread-ids":[""]}"#,
                      #"{"pinned-thread-ids":["not-a-session-id"]}"#] {
            let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
            try Data(state.utf8).write(to: stateURL(fixture))
            let result = try await fixture.liveMutator().executeOnce(
                plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt
            )
            XCTAssertEqual(result, .notAttempted, state)
            try assertCatalogCount(2, fixture)
        }
    }

    func testPinChangeImmediatelyBeforeSQLRollsBackWithoutMutation() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2, reviewedResidue: true)
        let state = stateURL(fixture)
        let pins = try JSONSerialization.data(withJSONObject: [
            "pinned-thread-ids": [fixture.livePlan.selectedThreadIDs[0]],
        ])
        let mutator = CodexGhostRepairBulkLiveMixedMutator(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedAllowedParentURL: fixture.parent,
            gateSource: AlwaysClearBulkRepairGate(),
            backupReader: FixedBulkLiveBackupReadback(value: fixture.livePlan.backup),
            beforeMutationForTesting: { try pins.write(to: state) }
        )
        let before = try CodexGhostRepairBulkLiveMixedMutator.inspect(
            selectedItems: fixture.livePlan.selectedItems,
            resolution: fixture.bundle.resolveForPreflight()
        )
        let result = try await mutator.executeOnce(
            plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt
        )
        XCTAssertEqual(result, .notAttempted)
        let after = try CodexGhostRepairBulkLiveMixedMutator.inspect(
            selectedItems: fixture.livePlan.selectedItems,
            resolution: fixture.bundle.resolveForPreflight()
        )
        XCTAssertEqual(after, before, "Catalog, summaries and automation evidence must remain unchanged.")
    }

    func testDuplicateAndNoncanonicalPinsAreRejected() throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        let id = "aaaaaaaa-0000-4000-8000-000000000001"
        for pins in [[id, id], [id.uppercased()], [" " + id]] {
            try writePins(pins, fixture)
            XCTAssertThrowsError(try CodexGhostRepairFreshPinProtection.requireUnpinned(
                fixture.livePlan.selectedThreadIDs, codexHomeURL: fixture.codexHome
            ))
        }
    }

    func testSymlinkAndHardlinkPinFilesAreRejected() throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        let state = stateURL(fixture)
        let saved = fixture.parent.appendingPathComponent("saved-state.json")
        try FileManager.default.moveItem(at: state, to: saved)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: saved)
        XCTAssertThrowsError(try CodexGhostRepairFreshPinProtection.requireUnpinned(
            fixture.livePlan.selectedThreadIDs, codexHomeURL: fixture.codexHome
        ))
        try FileManager.default.moveItem(at: state, to: fixture.parent.appendingPathComponent("saved-link"))
        try FileManager.default.linkItem(at: saved, to: state)
        XCTAssertThrowsError(try CodexGhostRepairFreshPinProtection.requireUnpinned(
            fixture.livePlan.selectedThreadIDs, codexHomeURL: fixture.codexHome
        ))
    }

    func testMissingPinFileCannotAuthorizeMutation() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        try FileManager.default.moveItem(at: stateURL(fixture),
                                        to: fixture.parent.appendingPathComponent("saved-state.json"))
        let result = try await fixture.liveMutator().executeOnce(
            plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt
        )
        XCTAssertEqual(result, .notAttempted)
        try assertCatalogCount(2, fixture)
    }

    func testUnrelatedPinAllowsCleanupAndLaterPinDoesNotBreakRecovery() async throws {
        let fixture = try BulkShippingCompositionTestFixture.make(itemCount: 2)
        try writePins(["aaaaaaaa-0000-4000-8000-000000000001"], fixture)
        _ = try await revalidator(fixture).revalidate(
            storedPreview: fixture.storedPreview,
            resolution: fixture.bulkResolution,
            verifiedBackup: fixture.livePlan.backup
        )
        let result = try await fixture.liveMutator().executeOnce(
            plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt
        )
        XCTAssertEqual(result, .success)
        try assertCatalogCount(0, fixture)
        try writePins(fixture.livePlan.selectedThreadIDs, fixture)
        let recovered = try await fixture.liveMutator().recoverByReadback(
            plan: fixture.livePlan, claim: fixture.liveClaim, attempt: fixture.liveAttempt
        )
        XCTAssertEqual(recovered, .success)
    }

    private func revalidator(_ fixture: BulkShippingCompositionTestFixture.Value) throws
        -> CodexGhostRepairBulkLiveTargetRevalidator {
        try .init(repairResolution: fixture.bundle.resolveForPreflight(),
                  gateSource: AlwaysClearBulkRepairGate(),
                  fingerprintReader: { try fixture.source.fingerprint() },
                  nowMilliseconds: { 1_550 })
    }

    private func stateURL(_ fixture: BulkShippingCompositionTestFixture.Value) -> URL {
        fixture.codexHome.appendingPathComponent(".codex-global-state.json")
    }

    private func writePins(_ ids: [String], _ fixture: BulkShippingCompositionTestFixture.Value) throws {
        try JSONSerialization.data(withJSONObject: ["pinned-thread-ids": ids])
            .write(to: stateURL(fixture))
    }

    private func assertCatalogCount(_ expected: Int, _ fixture: BulkShippingCompositionTestFixture.Value) throws {
        let database = try CodexGhostRepairProductionSQLite(url: fixture.desktopURL, readOnly: true)
        defer { database.close() }
        XCTAssertEqual(try database.query("SELECT thread_id FROM local_thread_catalog", maximumRows: 10).count,
                       expected)
    }
}
