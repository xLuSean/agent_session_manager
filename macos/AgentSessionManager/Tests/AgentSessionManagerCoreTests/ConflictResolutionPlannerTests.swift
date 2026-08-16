@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class ConflictResolutionPlannerTests: XCTestCase {
    func testActiveTrashConflictProducesReadyAcceptAndBlockedReapplyOptions() throws {
        let state = ReconciledSessionState(
            managerKey: "codex:conflict",
            liveSession: session("conflict", state: .active),
            trashMembership: membership("conflict"),
            status: .nativeActiveTrashConflict,
            isStableForLifecyclePreview: false
        )

        let preview = try ConflictResolutionPlanner.preview(
            for: state,
            checkpoint: checkpoint(inventoryComplete: true, protectionComplete: false)
        )

        XCTAssertEqual(preview.nativeSessionID, "conflict")
        XCTAssertEqual(preview.observedNativeState, .active)
        XCTAssertEqual(preview.options.map(\.action), [.acceptNativeRestore, .reapplyTrashIntent])
        XCTAssertEqual(preview.options.map(\.readiness), [.readyToApply, .blocked])
        XCTAssertTrue(preview.options[1].reason.contains("protection evidence is incomplete"))
    }

    func testExternallyMissingNeverOffersDeletionAcknowledgementAsReady() throws {
        let state = ReconciledSessionState(
            managerKey: "codex:missing",
            liveSession: nil,
            trashMembership: membership("missing"),
            status: .externallyMissing,
            isStableForLifecyclePreview: false
        )

        let preview = try ConflictResolutionPlanner.preview(
            for: state,
            checkpoint: checkpoint(inventoryComplete: true, protectionComplete: false),
            exactReadback: readback("missing", status: .present)
        )

        XCTAssertEqual(preview.options.map(\.action), [.keepPending, .acknowledgeExternalDeletion])
        XCTAssertEqual(preview.options.map(\.readiness), [.previewOnly, .blocked])
        XCTAssertTrue(preview.options[1].reason.contains("still exists"))
        XCTAssertEqual(preview.exactReadback?.status, .present)
    }

    func testDocumentedExactAbsenceCouldMakeAcknowledgementPreviewOnly() throws {
        let state = ReconciledSessionState(
            managerKey: "codex:missing",
            liveSession: nil,
            trashMembership: membership("missing"),
            status: .externallyMissing,
            isStableForLifecyclePreview: false
        )

        let preview = try ConflictResolutionPlanner.preview(
            for: state,
            checkpoint: checkpoint(inventoryComplete: true, protectionComplete: false),
            exactReadback: readback("missing", status: .absent)
        )

        XCTAssertEqual(preview.options[1].action, .acknowledgeExternalDeletion)
        XCTAssertEqual(preview.options[1].readiness, .previewOnly)
        XCTAssertTrue(preview.options[1].reason.contains("Apply is still not implemented"))
    }

    func testAbsentStatusWithoutMatchingContractRemainsBlocked() throws {
        let state = ReconciledSessionState(
            managerKey: "codex:missing",
            liveSession: nil,
            trashMembership: membership("missing"),
            status: .externallyMissing,
            isStableForLifecyclePreview: false
        )
        let uncontracted = ExactSessionReadbackEvidence(
            provider: .codex,
            nativeSessionID: "missing",
            status: .absent,
            observedAt: Date(timeIntervalSince1970: 201),
            runtimeVersion: "test-runtime",
            evidenceKind: .documentedNotFound,
            rpcCode: 404,
            message: "Missing contract"
        )

        XCTAssertFalse(uncontracted.provesAbsence)
        let preview = try ConflictResolutionPlanner.preview(
            for: state,
            checkpoint: checkpoint(inventoryComplete: true, protectionComplete: false),
            exactReadback: uncontracted
        )
        XCTAssertEqual(preview.options[1].readiness, .blocked)
        XCTAssertTrue(preview.options[1].reason.contains("No documented authoritative"))
    }

    func testExactReadbackIdentityMismatchFailsClosed() {
        let state = ReconciledSessionState(
            managerKey: "codex:missing",
            liveSession: nil,
            trashMembership: membership("missing"),
            status: .externallyMissing,
            isStableForLifecyclePreview: false
        )

        XCTAssertThrowsError(
            try ConflictResolutionPlanner.preview(
                for: state,
                checkpoint: checkpoint(inventoryComplete: true, protectionComplete: false),
                exactReadback: readback("different", status: .present)
            )
        ) { error in
            XCTAssertEqual(error as? ConflictResolutionPlanningError, .identityMismatch)
        }
    }

    func testIncompleteInventoryCannotProduceResolutionPreview() {
        let state = ReconciledSessionState(
            managerKey: "codex:missing",
            liveSession: nil,
            trashMembership: membership("missing"),
            status: .externallyMissing,
            isStableForLifecyclePreview: false
        )

        XCTAssertThrowsError(
            try ConflictResolutionPlanner.preview(
                for: state,
                checkpoint: checkpoint(inventoryComplete: false, protectionComplete: false)
            )
        ) { error in
            XCTAssertEqual(error as? ConflictResolutionPlanningError, .incompleteInventory)
        }
    }

    func testNormalStateCannotProduceResolutionPreview() {
        let state = ReconciledSessionState(
            managerKey: "codex:active",
            liveSession: session("active", state: .active),
            trashMembership: nil,
            status: .active,
            isStableForLifecyclePreview: false
        )

        XCTAssertThrowsError(
            try ConflictResolutionPlanner.preview(
                for: state,
                checkpoint: checkpoint(inventoryComplete: true, protectionComplete: false)
            )
        ) { error in
            XCTAssertEqual(
                error as? ConflictResolutionPlanningError,
                .notAResolvableConflict(.active)
            )
        }
    }

    private func session(_ nativeID: String, state: NativeSessionState) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: nativeID,
            workingDirectory: "/tmp/project",
            updatedAt: Date(timeIntervalSince1970: 100),
            sizeBytes: nil,
            nativeState: state,
            protection: SessionProtection(
                isPinnedKnown: false,
                isRunningKnown: false,
                isCurrentKnown: false,
                hasPinnedDescendantKnown: false
            )
        )
    }

    private func membership(_ nativeID: String) -> TrashMembershipRecord {
        TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: nativeID,
            managerKey: "codex:\(nativeID)",
            titleAtEntry: nativeID,
            workingDirectoryAtEntry: "/tmp/project",
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: "old-hash",
            enteredAt: Date(timeIntervalSince1970: 90),
            lastReconciledAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func checkpoint(
        inventoryComplete: Bool,
        protectionComplete: Bool
    ) -> ProviderCheckpointRecord {
        ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "test-runtime",
            inventoryHash: "current-hash",
            refreshedAt: Date(timeIntervalSince1970: 200),
            inventoryComplete: inventoryComplete,
            protectionComplete: protectionComplete
        )
    }

    private func readback(
        _ nativeID: String,
        status: ExactSessionReadbackStatus
    ) -> ExactSessionReadbackEvidence {
        let absenceContract = status == .absent
            ? ExactSessionAbsenceContract(
                provider: .codex,
                runtimeVersion: "test-runtime",
                rpcCode: 404,
                identifier: "future-documented-test-contract",
                officialSourceURL: URL(string: "https://developers.openai.com/codex/app-server/")!
            )
            : nil
        return ExactSessionReadbackEvidence(
            provider: .codex,
            nativeSessionID: nativeID,
            status: status,
            observedAt: Date(timeIntervalSince1970: 201),
            runtimeVersion: "test-runtime",
            evidenceKind: status == .absent ? .documentedNotFound : .exactMatch,
            rpcCode: status == .absent ? 404 : nil,
            absenceContract: absenceContract,
            message: "test evidence"
        )
    }
}
