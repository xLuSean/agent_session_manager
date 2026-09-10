@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class ConflictResolutionPlannerTests: XCTestCase {
    func testActiveTrashConflictProducesReadyAcceptAndBlockedReapplyWhenProtectionIsIncomplete() throws {
        let state = ReconciledSessionState(
            managerKey: "codex:conflict",
            liveSession: session("conflict", state: .active),
            trashMembership: membership("conflict"),
            status: .nativeActiveTrashConflict,
            isStableForLifecyclePreview: false
        )

        let preview = try ConflictResolutionPlanner.preview(
            for: state,
            checkpoint: checkpoint(
                inventoryComplete: true,
                protectionComplete: false,
                runtimeVersion: "0.148.0"
            )
        )

        XCTAssertEqual(preview.nativeSessionID, "conflict")
        XCTAssertEqual(preview.observedNativeState, .active)
        XCTAssertEqual(preview.options.map(\.action), [.acceptNativeRestore, .reapplyTrashIntent])
        XCTAssertEqual(preview.options.map(\.readiness), [.readyToApply, .blocked])
        XCTAssertTrue(preview.options[1].reason.contains("protection evidence is incomplete"))
    }

    func testActiveTrashConflictMakesReapplyReadyWhenArchiveEvidenceIsEligible() throws {
        let state = ReconciledSessionState(
            managerKey: "codex:conflict",
            liveSession: session(
                "conflict",
                state: .active,
                protection: SessionProtection()
            ),
            trashMembership: membership("conflict"),
            status: .nativeActiveTrashConflict,
            isStableForLifecyclePreview: false
        )
        let auditedCheckpoint = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "0.148.0",
            inventoryHash: "current-hash",
            refreshedAt: Date(timeIntervalSince1970: 200),
            inventoryComplete: true,
            protectionComplete: true
        )

        let preview = try ConflictResolutionPlanner.preview(
            for: state,
            checkpoint: auditedCheckpoint
        )

        XCTAssertEqual(preview.options.map(\.readiness), [.readyToApply, .readyToApply])
        XCTAssertTrue(preview.options[1].reason.contains("official Archive"))
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
        XCTAssertTrue(preview.options[1].reason.contains("operation-specific dual readback"))
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
        XCTAssertTrue(preview.options[1].reason.contains("version-audited"))
    }

    func testAuditedDualAbsenceMakesExternalDeletionReady() throws {
        let state = ReconciledSessionState(
            managerKey: "codex:missing",
            liveSession: nil,
            trashMembership: membership("missing"),
            status: .externallyMissing,
            isStableForLifecyclePreview: false
        )
        let frozenCheckpoint = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "0.148.0",
            inventoryHash: "inventory",
            refreshedAt: Date(timeIntervalSince1970: 200),
            inventoryComplete: true,
            protectionComplete: false
        )
        let evidence = ExternalDeletionReadbackEvidence(
            provider: .codex,
            nativeSessionID: "missing",
            runtimeVersion: "0.148.0",
            inventoryHash: "inventory",
            inventoryObservedAt: Date(timeIntervalSince1970: 201),
            exactReadObservedAt: Date(timeIntervalSince1970: 202),
            rpcCode: -32600,
            message: "thread not loaded: missing"
        )

        let preview = try ConflictResolutionPlanner.preview(
            for: state,
            checkpoint: frozenCheckpoint,
            externalDeletionEvidence: evidence
        )

        XCTAssertEqual(preview.options[1].readiness, .readyToApply)
        XCTAssertEqual(preview.externalDeletionEvidence, evidence)
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

    private func session(
        _ nativeID: String,
        state: NativeSessionState,
        protection: SessionProtection = SessionProtection(
            isPinnedKnown: false,
            isRunningKnown: false,
            isCurrentKnown: false,
            hasPinnedDescendantKnown: false
        )
    ) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: nativeID,
            workingDirectory: "/tmp/project",
            updatedAt: Date(timeIntervalSince1970: 100),
            sizeBytes: nil,
            nativeState: state,
            protection: protection
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
        protectionComplete: Bool,
        runtimeVersion: String = "test-runtime"
    ) -> ProviderCheckpointRecord {
        ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: runtimeVersion,
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
