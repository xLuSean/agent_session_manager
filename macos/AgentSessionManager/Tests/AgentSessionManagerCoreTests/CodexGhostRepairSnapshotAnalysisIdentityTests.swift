@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairSnapshotAnalysisIdentityTests: XCTestCase {
    private let snapshotID = UUID(
        uuidString: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
    )!
    private let targets = [
        "019f64d8-4be2-7c60-91ba-8687501cfd66",
        "019f64e3-ba20-7792-a7ab-1433db7ed8ec",
    ]

    func testFactoryExposesMetadataIdentityWithoutRepairAuthority() {
        let coordinator =
            CodexGhostRepairSnapshotAnalysisIdentityCoordinatorFactory
                .packagedReadOnly()

        XCTAssertTrue(coordinator.capabilities.identityResolutionAvailable)
        XCTAssertFalse(coordinator.capabilities.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.opensRawDatabaseContents)
        XCTAssertFalse(coordinator.capabilities.writesFilesystem)
        XCTAssertFalse(coordinator.capabilities.persistsRepairPreview)
        XCTAssertFalse(coordinator.capabilities.automaticResolution)
        XCTAssertFalse(coordinator.capabilities.automaticRetry)
        XCTAssertFalse(coordinator.capabilities.snapshotAcquisitionAuthority)
        XCTAssertFalse(coordinator.capabilities.repairPreviewAuthority)
        XCTAssertFalse(coordinator.capabilities.repairMutationAuthority)
    }

    func testExactPublishedReferenceResolvesFrozenPathRedactedIdentity()
        async throws
    {
        let reader = AnalysisIdentityReaderFake(
            inventory: inventory(state: .published)
        )
        let coordinator =
            CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator(
                reader: reader
            )

        let outcome = await coordinator.resolve(request: .init(
            snapshotReference: snapshotID.uuidString.lowercased()
        ))

        guard case let .resolved(identity) = outcome else {
            return XCTFail("Expected frozen published identity")
        }
        XCTAssertEqual(identity.snapshotReference, snapshotID.uuidString.lowercased())
        XCTAssertEqual(identity.targetThreadIDs, targets)
        XCTAssertEqual(identity.preparedAtMilliseconds, 1_000)
        XCTAssertEqual(identity.publishedAtMilliseconds, 2_000)
        XCTAssertEqual(identity.observedRegularFileCount, 10)
        XCTAssertEqual(identity.actualPublishedBytes, 130_700_000)
        XCTAssertTrue(identity.pathRedacted)
        XCTAssertEqual(identity.rawDatabaseContentsOpened, 0)
        XCTAssertFalse(identity.writesFilesystem)
        XCTAssertFalse(identity.persistsRepairPreview)
        XCTAssertFalse(identity.repairPreviewAuthority)
        XCTAssertFalse(identity.repairMutationAuthority)
        let callCount = await reader.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testTenWitnessPublishedReferenceResolvesFrozenIdentity() async {
        let tenTargets = canonicalTargets(count: 10)
        let reader = AnalysisIdentityReaderFake(
            inventory: inventory(
                state: .published,
                targetThreadIDs: tenTargets
            )
        )
        let coordinator =
            CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator(
                reader: reader
            )

        let outcome = await coordinator.resolve(request: .init(
            snapshotReference: snapshotID.uuidString.lowercased()
        ))

        guard case let .resolved(identity) = outcome else {
            return XCTFail("Expected ten-witness published identity")
        }
        XCTAssertEqual(identity.targetThreadIDs, tenTargets)
    }

    func testResumeResolverChoosesLatestExactPublishedTenWitnessSnapshot()
        async throws
    {
        let exactTargets = canonicalTargets(count: 10)
        let olderID = UUID(
            uuidString: "11111111-2222-4333-8444-555555555555"
        )!
        let latestID = UUID(
            uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa"
        )!
        let unrelatedID = UUID(
            uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
        )!
        let reader = AnalysisIdentityReaderFake(inventory: .init(
            snapshots: [
                recoveryEvidence(
                    snapshotID: olderID,
                    targets: exactTargets,
                    publishedAt: 2_000
                ),
                recoveryEvidence(
                    snapshotID: latestID,
                    targets: exactTargets,
                    publishedAt: 3_000
                ),
                recoveryEvidence(
                    snapshotID: unrelatedID,
                    targets: canonicalTargets(count: 9),
                    publishedAt: 4_000
                ),
            ],
            totalPublishedBytes: 390_000_000
        ))
        let resolver = CodexGhostRepairBulkPublishedSnapshotResumeResolver(
            reader: reader,
            snapshotReader: ResumeCatalogReaderFake(evidenceByReference: [
                latestID.uuidString.lowercased(): resumeSnapshotEvidence(
                    snapshotID: latestID,
                    targets: exactTargets
                ),
            ])
        )

        let reference = try await resolver.resolve(
            exactTargetThreadIDs: exactTargets
        )

        XCTAssertEqual(reference, latestID.uuidString.lowercased())
    }

    func testResumeResolverSkipsNewerOldProfileAndChoosesCurrentProfile()
        async throws
    {
        let exactTargets = canonicalTargets(count: 10)
        let currentID = UUID(
            uuidString: "11111111-2222-4333-8444-555555555555"
        )!
        let newerOldID = UUID(
            uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa"
        )!
        let reader = AnalysisIdentityReaderFake(inventory: .init(
            snapshots: [
                recoveryEvidence(
                    snapshotID: currentID,
                    targets: exactTargets,
                    publishedAt: 2_000
                ),
                recoveryEvidence(
                    snapshotID: newerOldID,
                    targets: exactTargets,
                    publishedAt: 3_000
                ),
            ],
            totalPublishedBytes: 260_000_000
        ))
        let resolver = CodexGhostRepairBulkPublishedSnapshotResumeResolver(
            reader: reader,
            snapshotReader: ResumeCatalogReaderFake(evidenceByReference: [
                currentID.uuidString.lowercased(): resumeSnapshotEvidence(
                    snapshotID: currentID,
                    targets: exactTargets
                ),
                newerOldID.uuidString.lowercased(): resumeSnapshotEvidence(
                    snapshotID: newerOldID,
                    targets: exactTargets,
                    sourceLayoutIdentifier:
                        CodexGhostRepairPackagedReadOnlyProfileCatalog
                            .v153SourceLayoutIdentifier
                ),
            ])
        )

        let reference = try await resolver.resolve(
            exactTargetThreadIDs: exactTargets
        )

        XCTAssertEqual(reference, currentID.uuidString.lowercased())
    }

    func testResumeResolverReturnsNilWhenExactWitnessSnapshotIsOldProfile()
        async throws
    {
        let exactTargets = canonicalTargets(count: 10)
        let reader = AnalysisIdentityReaderFake(inventory: .init(
            snapshots: [recoveryEvidence(
                snapshotID: snapshotID,
                targets: exactTargets,
                publishedAt: 3_000
            )],
            totalPublishedBytes: 130_000_000
        ))
        let resolver = CodexGhostRepairBulkPublishedSnapshotResumeResolver(
            reader: reader,
            snapshotReader: ResumeCatalogReaderFake(evidenceByReference: [
                snapshotID.uuidString.lowercased(): resumeSnapshotEvidence(
                    snapshotID: snapshotID,
                    targets: exactTargets,
                    sourceLayoutIdentifier:
                        CodexGhostRepairPackagedReadOnlyProfileCatalog
                            .v153SourceLayoutIdentifier
                ),
            ])
        )

        let reference = try await resolver.resolve(
            exactTargetThreadIDs: exactTargets
        )

        XCTAssertNil(reference)
    }

    func testResumeResolverRejectsMoreThanTenWitnesses() async {
        let resolver = CodexGhostRepairBulkPublishedSnapshotResumeResolver(
            reader: AnalysisIdentityReaderFake(
                inventory: inventory(state: .published)
            ),
            snapshotReader: ResumeCatalogReaderFake(evidenceByReference: [:])
        )

        do {
            _ = try await resolver.resolve(
                exactTargetThreadIDs: canonicalTargets(count: 11)
            )
            XCTFail("Expected the resume witness bound to fail closed")
        } catch {}
    }

    func testInvalidReferenceStopsBeforeInventoryRead() async {
        let reader = AnalysisIdentityReaderFake(
            inventory: inventory(state: .published)
        )
        let coordinator =
            CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator(
                reader: reader
            )

        let outcome = await coordinator.resolve(request: .init(
            snapshotReference: "/tmp/not-a-snapshot"
        ))

        assertUnavailable(outcome)
        let callCount = await reader.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testUnpublishedOrOversizedTargetSetFailsClosed() async {
        let unpublished = AnalysisIdentityReaderFake(
            inventory: inventory(state: .publicationInterrupted)
        )
        let unpublishedCoordinator =
            CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator(
                reader: unpublished
            )
        assertUnavailable(await unpublishedCoordinator.resolve(request: .init(
            snapshotReference: snapshotID.uuidString.lowercased()
        )))

        let oversizedTargets = canonicalTargets(count: 11)

        let oversized = AnalysisIdentityReaderFake(
            inventory: inventory(
                state: .published,
                targetThreadIDs: oversizedTargets
            )
        )
        let oversizedCoordinator =
            CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator(
                reader: oversized
            )
        assertUnavailable(await oversizedCoordinator.resolve(request: .init(
            snapshotReference: snapshotID.uuidString.lowercased()
        )))
    }

    private func canonicalTargets(count: Int) -> [String] {
        (0..<count).map {
            String(
                format: "019f64d8-4be2-7c60-91ba-%012x",
                $0
            )
        }
    }

    private func recoveryEvidence(
        snapshotID: UUID,
        targets: [String],
        publishedAt: Int64
    ) -> CodexGhostRepairSnapshotRecoveryEvidence {
        CodexGhostRepairSnapshotRecoveryEvidence(
            snapshotID: snapshotID,
            state: .published,
            targetThreadIDs: targets,
            preparedAtMilliseconds: 1_000,
            sourceFingerprintHash: hash("a"),
            destinationBindingHash: hash("b"),
            observedFileNames: (0..<10).map { "file-\($0)" },
            acquisitionRecordHash: hash("c"),
            publishedEvidence: .init(
                snapshotID: snapshotID,
                publishedAtMilliseconds: publishedAt,
                manifestHash: hash("d"),
                publicationReceiptHash: hash("e"),
                regularFileCount: 10,
                actualBytes: 130_000_000
            )
        )
    }

    private func resumeSnapshotEvidence(
        snapshotID: UUID,
        targets: [String],
        sourceLayoutIdentifier: String =
            CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v1534SourceLayoutIdentifier
    ) -> CodexGhostRepairBulkInventorySnapshotEvidence {
        let targetEvidence = targets.map { threadID in
            CodexGhostRepairSnapshotAnalysisTargetEvidence(
                threadID: threadID,
                catalogRowDigests: [hash("f")],
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
        }
        let databases = zip(
            CodexGhostRepairSnapshotAnalysisDatabase.allCases,
            [Int32(34), 2, 0, 0]
        ).map {
            CodexGhostRepairSnapshotAnalysisDatabaseEvidence(
                database: $0.0,
                schemaVersion: $0.1,
                integrityCheckPassed: true,
                foreignKeyViolationCount: 0
            )
        }
        return .init(
            snapshotReference: snapshotID.uuidString.lowercased(),
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            sourceFingerprintHash: hash("a"),
            manifestHash: hash("d"),
            readback: .init(
                databases: databases,
                targets: targetEvidence,
                authority: .init(
                    catalogRevision: 1,
                    observationSequence: 2,
                    watermarkUpdatedAt: 3,
                    metadataRowDigest: hash("b"),
                    localSyncRowDigest: hash("c")
                ),
                sourceFingerprintHash: hash("a")
            )
        )
    }

    func testReaderFailureReturnsStablePathRedactedUnavailable() async {
        let reader = AnalysisIdentityReaderFake(error: AnalysisIdentityTestError.failed)
        let coordinator =
            CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator(
                reader: reader
            )

        let outcome = await coordinator.resolve(request: .init(
            snapshotReference: snapshotID.uuidString.lowercased()
        ))

        assertUnavailable(outcome)
        guard case let .unavailable(message) = outcome else { return }
        XCTAssertFalse(message.contains("/Users/"))
        XCTAssertFalse(message.contains("sqlite"))
    }

    private func inventory(
        state: CodexGhostRepairSnapshotPublicationRecoveryState,
        targetThreadIDs: [String]? = nil
    ) -> CodexGhostRepairSnapshotRecoveryInventory {
        let published = state == .published
            ? CodexGhostRepairSnapshotPublishedEvidence(
                snapshotID: snapshotID,
                publishedAtMilliseconds: 2_000,
                manifestHash: hash("d"),
                publicationReceiptHash: hash("e"),
                regularFileCount: 10,
                actualBytes: 130_700_000
            )
            : nil
        return CodexGhostRepairSnapshotRecoveryInventory(
            snapshots: [CodexGhostRepairSnapshotRecoveryEvidence(
                snapshotID: snapshotID,
                state: state,
                targetThreadIDs: targetThreadIDs ?? targets,
                preparedAtMilliseconds: 1_000,
                sourceFingerprintHash: hash("a"),
                destinationBindingHash: hash("b"),
                observedFileNames: (0..<10).map { "file-\($0)" },
                acquisitionRecordHash: hash("c"),
                publishedEvidence: published
            )],
            totalPublishedBytes: published?.actualBytes ?? 0
        )
    }

    private func hash(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }

    private func assertUnavailable(
        _ outcome: CodexGhostRepairSnapshotAnalysisIdentityOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(message) = outcome else {
            return XCTFail("Expected unavailable", file: file, line: line)
        }
        XCTAssertEqual(
            message,
            "Published snapshot analysis identity is unavailable; no repair Preview or mutation authority was created.",
            file: file,
            line: line
        )
    }
}

private actor AnalysisIdentityReaderFake:
    CodexGhostRepairSnapshotRecoveryInventoryReading
{
    private let inventory: CodexGhostRepairSnapshotRecoveryInventory?
    private let error: Error?
    private var calls = 0

    init(inventory: CodexGhostRepairSnapshotRecoveryInventory) {
        self.inventory = inventory
        error = nil
    }

    init(error: Error) {
        inventory = nil
        self.error = error
    }

    func readbackInventory() async throws
        -> CodexGhostRepairSnapshotRecoveryInventory
    {
        calls += 1
        if let error { throw error }
        return try XCTUnwrap(inventory)
    }

    func callCount() -> Int { calls }
}

private struct ResumeCatalogReaderFake:
    CodexGhostRepairBulkSnapshotCatalogReading
{
    let evidenceByReference:
        [String: CodexGhostRepairBulkInventorySnapshotEvidence]

    func readBulkCatalog(
        snapshotReference: String
    ) async throws -> CodexGhostRepairBulkInventorySnapshotEvidence {
        guard let evidence = evidenceByReference[snapshotReference] else {
            throw AnalysisIdentityTestError.failed
        }
        return evidence
    }
}

private enum AnalysisIdentityTestError: Error {
    case failed
}
