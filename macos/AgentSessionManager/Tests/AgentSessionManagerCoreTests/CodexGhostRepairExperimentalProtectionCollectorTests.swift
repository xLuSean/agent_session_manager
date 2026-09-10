@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairExperimentalProtectionCollectorTests:
    XCTestCase
{
    private let targetA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let targetB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"
    private let present = "019f6500-1111-7222-8333-444444444444"
    private let child = "019f6501-1111-7222-8333-444444444444"

    func testExactObservationProducesIdentityBoundExperimentalAudit()
        throws
    {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let readback = makeReadback(identity: identity)

        let audit = try collect(
            identity: identity,
            readback: readback,
            observation: makeObservation(targets: [targetA, targetB])
        )

        XCTAssertEqual(audit.identity, identity)
        XCTAssertEqual(
            audit.protectionEvidence.map(\.threadID),
            [targetA, targetB]
        )
        XCTAssertTrue(audit.protectionEvidence.allSatisfy(\.isEligible))
        XCTAssertEqual(
            audit.experimentalAbsenceEvidence.map(\.requestedThreadID),
            [targetA, targetB]
        )
        XCTAssertTrue(audit.experimentalAbsenceEvidence.allSatisfy {
            !$0.officialGuarantee
                && !$0.provesOfficialAbsence
                && !$0.confirmationAuthority
                && !$0.repairMutationAuthority
        })
        XCTAssertTrue(audit.operationalAudit.isClear)
    }

    func testDeterministicSourceComposesThroughM2eIntoPreview() async throws {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let readback = makeReadback(identity: identity)
        let source = CodexGhostRepairDeterministicExperimentalProtectionSource(
            registry: try makeRegistry(),
            observation: makeObservation(targets: [targetA, targetB])
        )
        let coordinator =
            CodexGhostRepairSnapshotDryRunAnalysisCandidateCoordinator(
                identityCoordinator: IdentitySource(identity: identity),
                reader: ReadbackSource(readback: readback),
                protectionSource: source
            )
        let requestID = UUID(
            uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!

        let outcome = await coordinator.analyze(request: .init(
            requestID: requestID,
            snapshotReference: identity.snapshotReference,
            previewID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!,
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
        ))

        guard case let .preview(returnedID, preview) = outcome else {
            return XCTFail("Expected M2e Experimental dry-run Preview")
        }
        XCTAssertEqual(returnedID, requestID)
        XCTAssertEqual(preview.targetThreadIDs, [targetA, targetB])
        XCTAssertEqual(
            preview.items.map {
                $0.experimentalAbsenceEvidence.requestedThreadID
            },
            [targetA, targetB]
        )
        XCTAssertTrue(preview.items.allSatisfy {
            !$0.experimentalAbsenceEvidence.officialGuarantee
                && !$0.experimentalAbsenceEvidence.provesOfficialAbsence
        })
        XCTAssertFalse(preview.confirmationAuthority)
        XCTAssertFalse(preview.repairMutationAuthority)
    }

    func testEmptyRegistryOrExperimentalResponseDriftFailsClosed()
        throws
    {
        let identity = try makeIdentity(targets: [targetA])
        let readback = makeReadback(identity: identity)
        XCTAssertThrowsError(
            try CodexGhostRepairExperimentalProtectionCollector.collect(
                identity: identity,
                snapshotEvidence: readback,
                registry: .init(),
                observation: makeObservation(targets: [targetA])
            )
        )

        var drifted = makeObservation(targets: [targetA])
        drifted = replacingFailures(drifted) { failure in
            .init(
                threadID: failure.threadID,
                provider: failure.provider,
                runtimeVersion: failure.runtimeVersion,
                method: failure.method,
                errorKind: failure.errorKind,
                rpcCode: failure.rpcCode,
                responseShapeIdentifier: failure.responseShapeIdentifier,
                message: "thread not loaded"
            )
        }
        XCTAssertThrowsError(try collect(
            identity: identity,
            readback: readback,
            observation: drifted
        ))
    }

    func testIncompleteInventoryPinOrDescendantEvidenceFailsClosed()
        throws
    {
        let identity = try makeIdentity(targets: [targetA])
        let readback = makeReadback(identity: identity)

        for observation in [
            makeObservation(targets: [targetA], inventoryComplete: false),
            makeObservation(
                targets: [targetA],
                pinnedInventoryComplete: false
            ),
            makeObservation(
                targets: [targetA],
                descendantGraphComplete: false
            ),
        ] {
            XCTAssertThrowsError(try collect(
                identity: identity,
                readback: readback,
                observation: observation
            ))
        }
    }

    func testPresentControlMustRoundTripAndExistInFreshInventory()
        throws
    {
        let identity = try makeIdentity(targets: [targetA])
        let readback = makeReadback(identity: identity)

        XCTAssertThrowsError(try collect(
            identity: identity,
            readback: readback,
            observation: makeObservation(
                targets: [targetA],
                presentReturnedID: child
            )
        ))
        XCTAssertThrowsError(try collect(
            identity: identity,
            readback: readback,
            observation: makeObservation(
                targets: [targetA],
                activeThreadIDs: []
            )
        ))
    }

    func testTargetResurfacingOrExactFailureSetDriftFailsClosed()
        throws
    {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let readback = makeReadback(identity: identity)

        XCTAssertThrowsError(try collect(
            identity: identity,
            readback: readback,
            observation: makeObservation(
                targets: [targetA, targetB],
                activeThreadIDs: [present, targetA]
            )
        ))
        var missingOne = makeObservation(targets: [targetA, targetB])
        missingOne = replacingFailures(
            missingOne,
            with: Array(missingOne.exactReadFailures.dropLast())
        )
        XCTAssertThrowsError(try collect(
            identity: identity,
            readback: readback,
            observation: missingOne
        ))
    }

    func testPinnedAndDescendantEvidenceRemainVisibleToPlanner() async throws {
        let identity = try makeIdentity(targets: [targetA])
        let readback = makeReadback(identity: identity)
        let observation = makeObservation(
            targets: [targetA],
            pinnedThreadIDs: [targetA],
            descendantNodes: [
                .init(threadID: child, parentThreadID: targetA),
            ]
        )
        let audit = try collect(
            identity: identity,
            readback: readback,
            observation: observation
        )
        XCTAssertTrue(audit.protectionEvidence[0].pinned)
        XCTAssertEqual(audit.protectionEvidence[0].descendantCount, 1)
        XCTAssertFalse(audit.protectionEvidence[0].isEligible)

        let coordinator =
            CodexGhostRepairSnapshotDryRunAnalysisCandidateCoordinator(
                identityCoordinator: IdentitySource(identity: identity),
                reader: ReadbackSource(readback: readback),
                protectionSource:
                    CodexGhostRepairDeterministicExperimentalProtectionSource(
                        registry: try makeRegistry(),
                        observation: observation
                    )
            )
        let outcome = await coordinator.analyze(request: .init(
            requestID: UUID(),
            snapshotReference: identity.snapshotReference,
            previewID: UUID(),
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
        ))
        guard case let .blocked(_, blockers) = outcome else {
            return XCTFail("Expected pinned/descendant selection to block")
        }
        XCTAssertEqual(
            blockers,
            [.init(code: .invalidProtectionEvidence, threadID: targetA)]
        )
    }

    func testSnapshotIdentitySchemaAndGraphDriftFailClosed() throws {
        let identity = try makeIdentity(targets: [targetA])
        let other = try makeIdentity(
            snapshotID: UUID(
                uuidString: "cccccccc-dddd-4eee-8fff-000000000000"
            )!,
            targets: [targetA]
        )
        XCTAssertThrowsError(try collect(
            identity: identity,
            readback: makeReadback(identity: other),
            observation: makeObservation(targets: [targetA])
        ))

        var databases = makeDatabases()
        databases[0] = .init(
            database: .desktop,
            schemaVersion: 31,
            integrityCheckPassed: true,
            foreignKeyViolationCount: 0
        )
        XCTAssertThrowsError(try collect(
            identity: identity,
            readback: makeReadback(identity: identity, databases: databases),
            observation: makeObservation(targets: [targetA])
        ))
        XCTAssertThrowsError(try collect(
            identity: identity,
            readback: makeReadback(identity: identity),
            observation: makeObservation(
                targets: [targetA],
                descendantNodes: [
                    .init(threadID: child, parentThreadID: child),
                ]
            )
        ))
    }

    private func collect(
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        readback: CodexGhostRepairSnapshotAnalysisReadback,
        observation: CodexGhostRepairExperimentalProtectionObservation
    ) throws -> CodexGhostRepairSnapshotDryRunProtectionAudit {
        try CodexGhostRepairExperimentalProtectionCollector.collect(
            identity: identity,
            snapshotEvidence: readback,
            registry: makeRegistry(),
            observation: observation
        )
    }

    private func makeRegistry()
        throws -> CodexGhostRepairExperimentalAbsenceRegistry
    {
        let contract = try CodexGhostRepairExperimentalAbsenceContract(
            identifier: "codex-ghost-repair-experimental-absence",
            version: 1,
            provider: .codex,
            runtimeVersion: "0.149.0",
            method: .threadRead,
            errorKind: .rpcError,
            rpcCode: -32600,
            responseShapeIdentifier: "rpc-error-code-message-v1",
            exactMessageTemplate: "thread not loaded: {thread_id}",
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: makeDatabaseContracts()
        )
        let admission = try CodexGhostRepairExperimentalAbsenceAdmission(
            contract: contract,
            compatibilityFixtureHash: digest("1"),
            packagedCanaryEvidenceHash: digest("2"),
            presentControlThreadIDHash: digest("3"),
            missingFixtureThreadIDHashes: [digest("4")],
            presentControlVerified: true,
            missingFixtureVerified: true
        )
        return try .init(admissions: [admission])
    }

    private func makeIdentity(
        snapshotID: UUID = UUID(
            uuidString: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
        )!,
        targets: [String]
    ) throws -> CodexGhostRepairSnapshotAnalysisIdentity {
        try .init(
            snapshotID: snapshotID,
            targetThreadIDs: targets,
            preparedAtMilliseconds: 100,
            publishedAtMilliseconds: 200,
            sourceFingerprintHash: digest("3"),
            destinationBindingHash: digest("4"),
            acquisitionRecordHash: digest("5"),
            manifestHash: digest("6"),
            publicationReceiptHash: digest("7"),
            observedRegularFileCount: 10,
            actualPublishedBytes: 1_000
        )
    }

    private func makeReadback(
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]? = nil
    ) -> CodexGhostRepairSnapshotAnalysisReadback {
        .init(
            identity: identity,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: databases ?? makeDatabases(),
            targets: identity.targetThreadIDs.map {
                .init(
                    threadID: $0,
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
                )
            },
            authority: .init(
                catalogRevision: 10,
                observationSequence: 20,
                watermarkUpdatedAt: 30,
                metadataRowDigest: digest("b"),
                localSyncRowDigest: digest("c")
            )
        )
    }

    private func makeObservation(
        targets: [String],
        inventoryComplete: Bool = true,
        activeThreadIDs: [String]? = nil,
        pinnedThreadIDs: Set<String> = [],
        pinnedInventoryComplete: Bool = true,
        descendantNodes: [CodexGhostRepairExperimentalDescendantNode] = [],
        descendantGraphComplete: Bool = true,
        presentReturnedID: String? = nil
    ) -> CodexGhostRepairExperimentalProtectionObservation {
        .init(
            provider: .codex,
            runtimeVersion: "0.149.0",
            inventoryComplete: inventoryComplete,
            activeThreadIDs: activeThreadIDs ?? [present],
            archivedThreadIDs: [],
            pinnedThreadIDs: pinnedThreadIDs,
            pinnedInventoryComplete: pinnedInventoryComplete,
            descendantNodes: descendantNodes,
            descendantGraphComplete: descendantGraphComplete,
            presentControlThreadID: present,
            presentControlReturnedThreadID: presentReturnedID ?? present,
            exactReadFailures: targets.map {
                .init(
                    threadID: $0,
                    provider: .codex,
                    runtimeVersion: "0.149.0",
                    method: .threadRead,
                    errorKind: .rpcError,
                    rpcCode: -32600,
                    responseShapeIdentifier: "rpc-error-code-message-v1",
                    message: "thread not loaded: \($0)"
                )
            },
            operationalAudit: clearGate()
        )
    }

    private func replacingFailures(
        _ observation: CodexGhostRepairExperimentalProtectionObservation,
        transform:
            (CodexGhostRepairExperimentalExactReadFailureObservation)
                -> CodexGhostRepairExperimentalExactReadFailureObservation
    ) -> CodexGhostRepairExperimentalProtectionObservation {
        replacingFailures(
            observation,
            with: observation.exactReadFailures.map(transform)
        )
    }

    private func replacingFailures(
        _ observation: CodexGhostRepairExperimentalProtectionObservation,
        with failures:
            [CodexGhostRepairExperimentalExactReadFailureObservation]
    ) -> CodexGhostRepairExperimentalProtectionObservation {
        .init(
            provider: observation.provider,
            runtimeVersion: observation.runtimeVersion,
            inventoryComplete: observation.inventoryComplete,
            activeThreadIDs: observation.activeThreadIDs,
            archivedThreadIDs: observation.archivedThreadIDs,
            pinnedThreadIDs: observation.pinnedThreadIDs,
            pinnedInventoryComplete: observation.pinnedInventoryComplete,
            descendantNodes: observation.descendantNodes,
            descendantGraphComplete: observation.descendantGraphComplete,
            presentControlThreadID: observation.presentControlThreadID,
            presentControlReturnedThreadID:
                observation.presentControlReturnedThreadID,
            exactReadFailures: failures,
            operationalAudit: observation.operationalAudit
        )
    }

    private func makeDatabaseContracts()
        -> [CodexGhostRepairExperimentalDatabaseContract]
    {
        [
            .init(database: .desktop, schemaVersion: 32),
            .init(database: .summaries, schemaVersion: 2),
            .init(database: .state, schemaVersion: 0),
            .init(database: .threadHistory, schemaVersion: 0),
        ]
    }

    private func makeDatabases()
        -> [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    {
        makeDatabaseContracts().map {
            .init(
                database: $0.database,
                schemaVersion: $0.schemaVersion,
                integrityCheckPassed: true,
                foreignKeyViolationCount: 0
            )
        }
    }

    private func clearGate() -> CodexGhostRepairExecutionGate {
        .init(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            stateOpenHandleCount: 0,
            threadHistoryOpenHandleCount: 0,
            capacitySufficient: true
        )
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}

private struct IdentitySource:
    CodexGhostRepairSnapshotAnalysisIdentityCoordinator
{
    let capabilities =
        CodexGhostRepairSnapshotAnalysisIdentityCapabilities.packagedReadOnly
    let identity: CodexGhostRepairSnapshotAnalysisIdentity

    func resolve(
        request: CodexGhostRepairSnapshotAnalysisRequest
    ) async -> CodexGhostRepairSnapshotAnalysisIdentityOutcome {
        .resolved(identity)
    }
}

private struct ReadbackSource: CodexGhostRepairSnapshotAnalysisReading {
    let capabilities =
        CodexGhostRepairSnapshotAnalysisReaderCapabilities.packagedReadOnly
    let readback: CodexGhostRepairSnapshotAnalysisReadback

    func read(
        identity: CodexGhostRepairSnapshotAnalysisIdentity
    ) async -> CodexGhostRepairSnapshotAnalysisReadOutcome {
        .read(readback)
    }
}
