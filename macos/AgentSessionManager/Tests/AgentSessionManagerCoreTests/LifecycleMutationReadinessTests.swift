import XCTest
@testable import AgentSessionManagerCore

final class LifecycleMutationReadinessTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testEvidenceReadyArchiveStillRequiresExecutor() {
        let readiness = ArchiveMutationReadinessAssessor.assess(
            session: session(),
            selectionCount: 1,
            diagnostics: diagnostics(),
            checkpoint: checkpoint(),
            reconciliationStable: true,
            writerAuthority: verifiedWriterAuthority()
        )

        XCTAssertTrue(readiness.isEvidenceReady)
        XCTAssertFalse(readiness.isExecutionEnabled)
        XCTAssertEqual(readiness.primaryBlockedReason, "The manager Archive executor is not implemented or authorized yet; no native mutation will run.")
        XCTAssertEqual(readiness.items.last?.requirement, .executor)
        XCTAssertEqual(readiness.items.last?.verdict, .blocked)
    }

    func testSeparateAppServerAllowsBoundedAttemptWithoutImplyingWriterClearance() {
        let readiness = ArchiveMutationReadinessAssessor.assess(
            session: session(),
            selectionCount: 1,
            diagnostics: diagnostics(),
            checkpoint: checkpoint(),
            reconciliationStable: true
        )

        XCTAssertEqual(verdict(.writerAuthority, in: readiness), .attemptMayFail)
        XCTAssertTrue(readiness.isEvidenceReady)
        XCTAssertTrue(readiness.hasAttemptRisk)
        XCTAssertFalse(readiness.isExecutionEnabled)
        XCTAssertTrue(
            readiness.items.first { $0.requirement == .writerAuthority }?
                .explanation.contains("separate App Server process") == true
        )
        XCTAssertTrue(
            readiness.items.first { $0.requirement == .writerAuthority }?
                .explanation.contains("not verified clearance") == true
        )
    }

    func testWriterAuthorityMustMatchExactRuntimeBoundCheckpoint() {
        let stale = LifecycleWriterAuthorityEvidence(
            nativeSessionID: session().nativeID,
            runtimeVersion: "0.146.0",
            inventoryHash: "stale-inventory",
            observedAt: observedAt.addingTimeInterval(-1),
            status: .verifiedClear,
            source: .officialLifecycleHost,
            explanation: "Should not be accepted."
        )
        let readiness = ArchiveMutationReadinessAssessor.assess(
            session: session(),
            selectionCount: 1,
            diagnostics: diagnostics(),
            checkpoint: checkpoint(),
            reconciliationStable: true,
            writerAuthority: stale,
            executorAvailable: true
        )

        XCTAssertEqual(verdict(.writerAuthority, in: readiness), .attemptMayFail)
        XCTAssertTrue(readiness.hasAttemptRisk)
        XCTAssertTrue(readiness.isExecutionEnabled)
    }

    func testObservedWriterBlocksArchive() {
        let occupied = LifecycleWriterAuthorityEvidence(
            nativeSessionID: session().nativeID,
            runtimeVersion: "0.147.0",
            inventoryHash: "inventory",
            observedAt: observedAt,
            status: .writerPresent,
            source: .officialLifecycleHost,
            explanation: "The official lifecycle host reports an active writer."
        )
        let readiness = ArchiveMutationReadinessAssessor.assess(
            session: session(),
            selectionCount: 1,
            diagnostics: diagnostics(),
            checkpoint: checkpoint(),
            reconciliationStable: true,
            writerAuthority: occupied,
            executorAvailable: true
        )

        XCTAssertEqual(verdict(.writerAuthority, in: readiness), .blocked)
        XCTAssertFalse(readiness.isExecutionEnabled)
    }

    func testCurrentRuntimeFailsClosedOnUnknownProtectionEvidence() {
        let unknown = SessionProtection(
            isPinnedKnown: false,
            isRunningKnown: false,
            isCurrentKnown: false,
            hasPinnedDescendantKnown: false
        )
        let readiness = ArchiveMutationReadinessAssessor.assess(
            session: session(protection: unknown),
            selectionCount: 1,
            diagnostics: diagnostics(protectionComplete: false),
            checkpoint: checkpoint(protectionComplete: false),
            reconciliationStable: true
        )

        XCTAssertFalse(readiness.isEvidenceReady)
        XCTAssertFalse(readiness.isExecutionEnabled)
        XCTAssertEqual(verdict(.pinned, in: readiness), .unavailable)
        XCTAssertEqual(verdict(.running, in: readiness), .attemptMayFail)
        XCTAssertEqual(verdict(.current, in: readiness), .attemptMayFail)
        XCTAssertEqual(verdict(.pinnedDescendant, in: readiness), .unavailable)
    }

    func testUnknownRunningAndCurrentAllowAuditedAttemptButRemainVisible() {
        let unknownCrossHostState = SessionProtection(
            isRunningKnown: false,
            isCurrentKnown: false
        )
        let readiness = ArchiveMutationReadinessAssessor.assess(
            session: session(protection: unknownCrossHostState),
            selectionCount: 1,
            diagnostics: diagnostics(protectionComplete: false),
            checkpoint: checkpoint(protectionComplete: false),
            reconciliationStable: true,
            executorAvailable: true
        )

        XCTAssertEqual(verdict(.writerAuthority, in: readiness), .attemptMayFail)
        XCTAssertEqual(verdict(.pinned, in: readiness), .satisfied)
        XCTAssertEqual(verdict(.running, in: readiness), .attemptMayFail)
        XCTAssertEqual(verdict(.current, in: readiness), .attemptMayFail)
        XCTAssertEqual(verdict(.pinnedDescendant, in: readiness), .satisfied)
        XCTAssertTrue(readiness.hasAttemptRisk)
        XCTAssertTrue(readiness.isEvidenceReady)
        XCTAssertTrue(readiness.isExecutionEnabled)
        XCTAssertNil(readiness.primaryBlockedReason)
    }

    func testPositiveRunningOrCurrentProtectionStillBlocksAttempt() {
        let protectedStates = [
            SessionProtection(isRunning: true),
            SessionProtection(isCurrent: true),
        ]

        for protection in protectedStates {
            let readiness = ArchiveMutationReadinessAssessor.assess(
                session: session(protection: protection),
                selectionCount: 1,
                diagnostics: diagnostics(),
                checkpoint: checkpoint(),
                reconciliationStable: true,
                executorAvailable: true
            )

            XCTAssertFalse(readiness.isEvidenceReady)
            XCTAssertFalse(readiness.isExecutionEnabled)
            XCTAssertTrue(
                verdict(.running, in: readiness) == .blocked
                    || verdict(.current, in: readiness) == .blocked
            )
        }
    }

    func testProtectedSessionIsBlockedEvenWhenEvidenceIsKnown() {
        let readiness = ArchiveMutationReadinessAssessor.assess(
            session: session(protection: SessionProtection(isPinned: true)),
            selectionCount: 1,
            diagnostics: diagnostics(),
            checkpoint: checkpoint(),
            reconciliationStable: true,
            executorAvailable: true
        )

        XCTAssertEqual(verdict(.pinned, in: readiness), .blocked)
        XCTAssertFalse(readiness.isEvidenceReady)
        XCTAssertFalse(readiness.isExecutionEnabled)
    }

    func testFirstArchiveSliceRejectsDescendantAffectedSet() {
        let readiness = ArchiveMutationReadinessAssessor.assess(
            session: session(descendantCount: 2),
            selectionCount: 1,
            diagnostics: diagnostics(),
            checkpoint: checkpoint(),
            reconciliationStable: true,
            executorAvailable: true
        )

        XCTAssertEqual(verdict(.descendants, in: readiness), .blocked)
        XCTAssertFalse(readiness.isEvidenceReady)
    }

    func testSelectionRuntimeAndCheckpointDriftFailClosed() {
        let mismatchedCheckpoint = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "0.146.0",
            inventoryHash: "inventory",
            refreshedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: true
        )
        let readiness = ArchiveMutationReadinessAssessor.assess(
            session: session(),
            selectionCount: 2,
            diagnostics: diagnostics(),
            checkpoint: mismatchedCheckpoint,
            reconciliationStable: false,
            executorAvailable: true
        )

        XCTAssertEqual(verdict(.exactSelection, in: readiness), .blocked)
        XCTAssertEqual(verdict(.stableReconciliation, in: readiness), .blocked)
        XCTAssertEqual(verdict(.runtimeBinding, in: readiness), .unavailable)
        XCTAssertFalse(readiness.isExecutionEnabled)
    }

    func testNativeInterfaceDoesNotImplyMutationCapability() {
        var capabilities = SessionCapabilities.codexLiveReadOnly
        capabilities.hasNativeArchiveInterface = true
        capabilities.hasNativeUnarchiveInterface = true

        XCTAssertEqual(capabilities.hasNativeArchiveInterface, true)
        XCTAssertEqual(capabilities.hasNativeUnarchiveInterface, true)
        XCTAssertFalse(capabilities.canArchive)
        XCTAssertFalse(capabilities.canUnarchive)
        XCTAssertFalse(capabilities.canDelete)
    }

    func testLifecycleContractIsAllowListedToAuditedRuntime() {
        XCTAssertTrue(CodexAppServerProvider.supportsVerifiedLifecycleContract("0.147.0"))
        XCTAssertTrue(CodexAppServerProvider.supportsVerifiedLifecycleContract("0.147.0-alpha.6.5"))
        XCTAssertFalse(CodexAppServerProvider.supportsVerifiedLifecycleContract("0.146.0"))
        XCTAssertFalse(CodexAppServerProvider.supportsVerifiedLifecycleContract("0.148.0"))
        XCTAssertFalse(CodexAppServerProvider.supportsVerifiedLifecycleContract("0.147.01"))
        XCTAssertFalse(CodexAppServerProvider.supportsVerifiedLifecycleContract(nil))
    }

    private func verdict(
        _ requirement: LifecycleReadinessRequirement,
        in readiness: LifecycleMutationReadiness
    ) -> LifecycleReadinessVerdict? {
        readiness.items.first { $0.requirement == requirement }?.verdict
    }

    private func session(
        protection: SessionProtection = SessionProtection(),
        descendantCount: Int = 0
    ) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: "01900000-0000-7000-8000-000000000001",
            title: "Archive readiness fixture",
            workingDirectory: "/Users/example/Project",
            updatedAt: observedAt,
            sizeBytes: nil,
            nativeState: .active,
            protection: protection,
            descendantCount: descendantCount,
            descendantCountKnown: true
        )
    }

    private func diagnostics(protectionComplete: Bool = true) -> ProviderDiagnostics {
        var capabilities = SessionCapabilities.codexLiveReadOnly
        capabilities.hasNativeArchiveInterface = true
        capabilities.hasNativeUnarchiveInterface = true
        capabilities.canReadPinnedState = true
        capabilities.canReadRunningState = true
        capabilities.canReadCurrentState = true
        capabilities.canReadDescendants = true
        return ProviderDiagnostics(
            system: .codex,
            connectionState: .ready,
            runtimeVersion: "0.147.0",
            lastRefreshedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: protectionComplete,
            capabilities: capabilities
        )
    }

    private func checkpoint(protectionComplete: Bool = true) -> ProviderCheckpointRecord {
        ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: "0.147.0",
            inventoryHash: "inventory",
            refreshedAt: observedAt,
            inventoryComplete: true,
            protectionComplete: protectionComplete
        )
    }

    private func verifiedWriterAuthority() -> LifecycleWriterAuthorityEvidence {
        LifecycleWriterAuthorityEvidence(
            nativeSessionID: session().nativeID,
            runtimeVersion: "0.147.0",
            inventoryHash: "inventory",
            observedAt: observedAt,
            status: .verifiedClear,
            source: .officialLifecycleHost,
            explanation: "The official lifecycle host verified writer clearance for this exact session."
        )
    }
}
