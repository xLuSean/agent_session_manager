@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairSnapshotDryRunAnalysisCoordinatorTests:
    XCTestCase
{
    private let target = "019f64d8-4be2-7c60-91ba-8687501cfd66"

    func testPackagedFactoryIsUnavailableAndAuthorityFree() async {
        let coordinator =
            CodexGhostRepairSnapshotDryRunAnalysisCoordinatorFactory
                .packagedDefaultUnavailable()
        let request = makeRequest()

        let outcome = await coordinator.analyze(request: request)

        XCTAssertEqual(outcome.requestID, request.requestID)
        guard case let .unavailable(_, message) = outcome else {
            return XCTFail("Expected packaged analysis to remain unavailable")
        }
        XCTAssertFalse(message.contains("/Users/"))
        XCTAssertFalse(coordinator.capabilities.analysisAvailable)
        XCTAssertFalse(coordinator.capabilities.identityResolutionAvailable)
        XCTAssertFalse(coordinator.capabilities.snapshotQueryAvailable)
        XCTAssertFalse(coordinator.capabilities.protectionAuditAvailable)
        assertAuthorityFree(coordinator.capabilities)
        XCTAssertFalse(outcome.confirmationAuthority)
        XCTAssertFalse(outcome.repairMutationAuthority)
    }

    func testCandidateComposesExactReadOnlyDependenciesInOrder() async throws {
        let recorder = CallRecorder()
        let identity = try makeIdentity()
        let coordinator = makeCoordinator(
            recorder: recorder,
            identityOutcome: .resolved(identity),
            readOutcome: .read(makeReadback(identity: identity)),
            auditResult: .success(makeAudit(identity: identity))
        )
        let request = makeRequest()

        let outcome = await coordinator.analyze(request: request)

        guard case let .preview(requestID, preview) = outcome else {
            return XCTFail("Expected deterministic dry-run Preview")
        }
        XCTAssertEqual(requestID, request.requestID)
        XCTAssertEqual(preview.previewID, request.previewID)
        XCTAssertEqual(preview.snapshotIdentity, identity)
        XCTAssertEqual(preview.targetThreadIDs, [target])
        XCTAssertTrue(preview.operationalAudit.isClear)
        XCTAssertFalse(preview.confirmationAuthority)
        XCTAssertFalse(preview.repairMutationAuthority)
        let calls = await recorder.values()
        XCTAssertEqual(calls, ["identity", "reader", "protection"])
        XCTAssertTrue(coordinator.capabilities.analysisAvailable)
        assertAuthorityFree(coordinator.capabilities)
    }

    func testIdentityUnavailableShortCircuitsReaderAndProtection() async {
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(
            recorder: recorder,
            identityOutcome: .unavailable(message: "unavailable"),
            readOutcome: .unavailable(reason: .unexpected),
            auditResult: .failure(TestError.unavailable)
        )
        let request = makeRequest()

        let outcome = await coordinator.analyze(request: request)

        guard case .unavailable = outcome else {
            return XCTFail("Expected unavailable analysis")
        }
        let calls = await recorder.values()
        XCTAssertEqual(calls, ["identity"])
    }

    func testReaderUnavailableShortCircuitsProtection() async throws {
        let recorder = CallRecorder()
        let identity = try makeIdentity()
        let coordinator = makeCoordinator(
            recorder: recorder,
            identityOutcome: .resolved(identity),
            readOutcome: .unavailable(reason: .desktopContractUnavailable),
            auditResult: .failure(TestError.unavailable)
        )

        let outcome = await coordinator.analyze(request: makeRequest())

        guard case .unavailable = outcome else {
            return XCTFail("Expected unavailable analysis")
        }
        let calls = await recorder.values()
        XCTAssertEqual(calls, ["identity", "reader"])
    }

    func testProtectionIdentityDriftBlocksWholeRequest() async throws {
        let recorder = CallRecorder()
        let identity = try makeIdentity()
        let drifted = try makeIdentity(
            snapshotID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!
        )
        let coordinator = makeCoordinator(
            recorder: recorder,
            identityOutcome: .resolved(identity),
            readOutcome: .read(makeReadback(identity: identity)),
            auditResult: .success(makeAudit(identity: drifted))
        )
        let request = makeRequest()

        let outcome = await coordinator.analyze(request: request)

        XCTAssertEqual(
            outcome,
            .blocked(
                requestID: request.requestID,
                blockers: [.init(code: .snapshotEvidenceDrift)]
            )
        )
        let calls = await recorder.values()
        XCTAssertEqual(calls, ["identity", "reader", "protection"])
    }

    func testProtectionFailureReturnsStablePathRedactedUnavailable()
        async throws
    {
        let identity = try makeIdentity()
        let coordinator = makeCoordinator(
            recorder: CallRecorder(),
            identityOutcome: .resolved(identity),
            readOutcome: .read(makeReadback(identity: identity)),
            auditResult: .failure(TestError.unavailable)
        )

        let outcome = await coordinator.analyze(request: makeRequest())

        guard case let .unavailable(_, message) = outcome else {
            return XCTFail("Expected unavailable analysis")
        }
        XCTAssertEqual(
            message,
            "Snapshot dry-run analysis is unavailable; no Preview persistence, confirmation, or repair authority was created."
        )
        XCTAssertFalse(message.contains("/Users/"))
    }

    func testRequestIdentityRemainsExactAcrossSeparateAnalyses() async throws {
        let identity = try makeIdentity()
        let coordinator = makeCoordinator(
            recorder: CallRecorder(),
            identityOutcome: .resolved(identity),
            readOutcome: .read(makeReadback(identity: identity)),
            auditResult: .success(makeAudit(identity: identity))
        )
        let first = makeRequest(
            requestID: UUID(
                uuidString: "11111111-2222-4333-8444-555555555555"
            )!
        )
        let second = makeRequest(
            requestID: UUID(
                uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa"
            )!
        )

        let firstOutcome = await coordinator.analyze(request: first)
        let secondOutcome = await coordinator.analyze(request: second)

        XCTAssertEqual(firstOutcome.requestID, first.requestID)
        XCTAssertEqual(secondOutcome.requestID, second.requestID)
        XCTAssertNotEqual(firstOutcome.requestID, secondOutcome.requestID)
    }

    func testBlockedOperationalEvidenceIsAuditOnlyInPreview() async throws {
        let identity = try makeIdentity()
        let blockedGate = CodexGhostRepairExecutionGate(
            codexFullyExited: false,
            desktopOpenHandleCount: 1,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            stateOpenHandleCount: 0,
            threadHistoryOpenHandleCount: 0,
            capacitySufficient: true
        )
        let coordinator = makeCoordinator(
            recorder: CallRecorder(),
            identityOutcome: .resolved(identity),
            readOutcome: .read(makeReadback(identity: identity)),
            auditResult: .success(
                .init(
                    identity: identity,
                    protectionEvidence: [makeProtection()],
                    experimentalAbsenceEvidence: [makeExperimental()],
                    operationalAudit: blockedGate
                )
            )
        )

        let outcome = await coordinator.analyze(request: makeRequest())

        guard case let .preview(_, preview) = outcome else {
            return XCTFail("Expected audit-only operational evidence")
        }
        XCTAssertFalse(preview.operationalAudit.isClear)
        XCTAssertFalse(preview.confirmationAuthority)
        XCTAssertFalse(preview.repairMutationAuthority)
    }

    private func makeCoordinator(
        recorder: CallRecorder,
        identityOutcome: CodexGhostRepairSnapshotAnalysisIdentityOutcome,
        readOutcome: CodexGhostRepairSnapshotAnalysisReadOutcome,
        auditResult: Result<
            CodexGhostRepairSnapshotDryRunProtectionAudit,
            Error
        >
    ) -> CodexGhostRepairSnapshotDryRunAnalysisCandidateCoordinator {
        .init(
            identityCoordinator: IdentityFake(
                recorder: recorder,
                outcome: identityOutcome
            ),
            reader: ReaderFake(
                recorder: recorder,
                outcome: readOutcome
            ),
            protectionSource: ProtectionFake(
                recorder: recorder,
                result: auditResult
            )
        )
    }

    private func makeRequest(
        requestID: UUID = UUID(
            uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!
    ) -> CodexGhostRepairSnapshotDryRunAnalysisRequest {
        .init(
            requestID: requestID,
            snapshotReference: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790",
            previewID: UUID(
                uuidString: "cccccccc-dddd-4eee-8fff-000000000000"
            )!,
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
        )
    }

    private func makeIdentity(
        snapshotID: UUID = UUID(
            uuidString: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
        )!
    ) throws -> CodexGhostRepairSnapshotAnalysisIdentity {
        try .init(
            snapshotID: snapshotID,
            targetThreadIDs: [target],
            preparedAtMilliseconds: 100,
            publishedAtMilliseconds: 200,
            sourceFingerprintHash: digest("1"),
            destinationBindingHash: digest("2"),
            acquisitionRecordHash: digest("3"),
            manifestHash: digest("4"),
            publicationReceiptHash: digest("5"),
            observedRegularFileCount: 10,
            actualPublishedBytes: 1_000
        )
    }

    private func makeReadback(
        identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) -> CodexGhostRepairSnapshotAnalysisReadback {
        .init(
            identity: identity,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: [
                .init(
                    database: .desktop,
                    schemaVersion: 32,
                    integrityCheckPassed: true,
                    foreignKeyViolationCount: 0
                ),
                .init(
                    database: .summaries,
                    schemaVersion: 2,
                    integrityCheckPassed: true,
                    foreignKeyViolationCount: 0
                ),
                .init(
                    database: .state,
                    schemaVersion: 0,
                    integrityCheckPassed: true,
                    foreignKeyViolationCount: 0
                ),
                .init(
                    database: .threadHistory,
                    schemaVersion: 0,
                    integrityCheckPassed: true,
                    foreignKeyViolationCount: 0
                ),
            ],
            targets: [
                .init(
                    threadID: target,
                    catalogRowDigests: [digest("a")],
                    automationRunRowDigests: [],
                    automationDefinitionRowDigests: [],
                    references: .init(
                        inbox: 0,
                        timeline: 0,
                        summaries: 0,
                        canonicalState: 0,
                        threadTurns: 0,
                        threadItems: 0,
                        historyProjection: 0
                    ),
                    rowContract: .categoryAEligible
                ),
            ],
            authority: .init(
                catalogRevision: 10,
                observationSequence: 20,
                watermarkUpdatedAt: 30,
                metadataRowDigest: digest("d"),
                localSyncRowDigest: digest("e")
            )
        )
    }

    private func makeAudit(
        identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) -> CodexGhostRepairSnapshotDryRunProtectionAudit {
        .init(
            identity: identity,
            protectionEvidence: [makeProtection()],
            experimentalAbsenceEvidence: [makeExperimental()],
            operationalAudit: .init(
                codexFullyExited: true,
                desktopOpenHandleCount: 0,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                stateOpenHandleCount: 0,
                threadHistoryOpenHandleCount: 0,
                capacitySufficient: true
            )
        )
    }

    private func makeProtection() -> CodexGhostRepairProtectionEvidence {
        .init(
            threadID: target,
            inventoryComplete: true,
            activeInventoryPresent: false,
            archivedInventoryPresent: false,
            exactReadNotLoaded: true,
            exactReadErrorCode: -32600,
            pinned: false,
            descendantCount: 0
        )
    }

    private func makeExperimental()
        -> CodexGhostRepairExperimentalAbsenceEvidence
    {
        .init(
            provider: .codex,
            requestedThreadID: target,
            runtimeVersion: "0.149.0",
            method: .threadRead,
            rpcCode: -32600,
            contractIdentifier:
                "codex-ghost-repair-experimental-absence",
            contractVersion: 1,
            responseShapeIdentifier: "rpc-error-code-message-v1",
            canonicalResponseHash: digest("f"),
            compatibilityFixtureHash: digest("1"),
            packagedCanaryEvidenceHash: digest("2"),
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: [
                .init(database: .desktop, schemaVersion: 32),
                .init(database: .summaries, schemaVersion: 2),
                .init(database: .state, schemaVersion: 0),
                .init(database: .threadHistory, schemaVersion: 0),
            ]
        )
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }

    private func assertAuthorityFree(
        _ capabilities: CodexGhostRepairSnapshotDryRunAnalysisCapabilities,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(capabilities.acceptsCallerPath, file: file, line: line)
        XCTAssertFalse(capabilities.automaticAnalysis, file: file, line: line)
        XCTAssertFalse(capabilities.automaticRetry, file: file, line: line)
        XCTAssertEqual(
            capabilities.writesFilesystem,
            capabilities.analysisAvailable,
            file: file,
            line: line
        )
        XCTAssertEqual(
            capabilities.usesEphemeralAnalysisWorkspace,
            capabilities.analysisAvailable,
            file: file,
            line: line
        )
        XCTAssertFalse(
            capabilities.writesPublishedSnapshot,
            file: file,
            line: line
        )
        XCTAssertFalse(capabilities.persistsPreview, file: file, line: line)
        XCTAssertFalse(
            capabilities.experimentalAbsenceContractAvailable,
            file: file,
            line: line
        )
        XCTAssertFalse(
            capabilities.confirmationAuthority,
            file: file,
            line: line
        )
        XCTAssertFalse(
            capabilities.repairMutationAuthority,
            file: file,
            line: line
        )
    }
}

private enum TestError: Error {
    case unavailable
}

private actor CallRecorder {
    private var calls: [String] = []

    func record(_ value: String) {
        calls.append(value)
    }

    func values() -> [String] {
        calls
    }
}

private struct IdentityFake:
    CodexGhostRepairSnapshotAnalysisIdentityCoordinator
{
    let capabilities =
        CodexGhostRepairSnapshotAnalysisIdentityCapabilities.packagedReadOnly
    let recorder: CallRecorder
    let outcome: CodexGhostRepairSnapshotAnalysisIdentityOutcome

    func resolve(
        request: CodexGhostRepairSnapshotAnalysisRequest
    ) async -> CodexGhostRepairSnapshotAnalysisIdentityOutcome {
        await recorder.record("identity")
        return outcome
    }
}

private struct ReaderFake: CodexGhostRepairSnapshotAnalysisReading {
    let capabilities =
        CodexGhostRepairSnapshotAnalysisReaderCapabilities.packagedReadOnly
    let recorder: CallRecorder
    let outcome: CodexGhostRepairSnapshotAnalysisReadOutcome

    func read(
        identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) async -> CodexGhostRepairSnapshotAnalysisReadOutcome {
        await recorder.record("reader")
        return outcome
    }
}

private struct ProtectionFake:
    CodexGhostRepairSnapshotDryRunProtectionAuditSource
{
    let recorder: CallRecorder
    let result: Result<
        CodexGhostRepairSnapshotDryRunProtectionAudit,
        Error
    >

    func audit(
        requestID: UUID,
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        snapshotEvidence: CodexGhostRepairSnapshotAnalysisReadback
    ) async throws -> CodexGhostRepairSnapshotDryRunProtectionAudit {
        await recorder.record("protection")
        return try result.get()
    }
}
