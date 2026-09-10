@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairCategoryARepairReviewCoordinatorTests:
    XCTestCase
{
    func testExactPreviewAndFreshReviewProduceDurablePublicChallenge()
        async throws
    {
        let preview = try makePreview(category: .ordinary)
        let reader = M3hSavedPreviewReader(outcome: .preview(preview))
        let collector = M3hReviewCollector(mode: .matching)
        let journal = M3hChallengeJournal()
        let coordinator = makeCoordinator(
            reader: reader,
            collector: collector,
            journal: journal
        )
        let request = request()

        let outcome = await coordinator.prepareReview(request: request)

        guard case let .ready(challenge) = outcome else {
            return XCTFail("Expected one durable review challenge")
        }
        XCTAssertEqual(challenge.operationID, request.requestID)
        XCTAssertEqual(
            challenge.savedPreviewRequestID,
            request.savedPreviewRequestID
        )
        XCTAssertEqual(challenge.targetThreadIDs, [targetA, targetB])
        XCTAssertEqual(
            challenge.snapshotReference,
            "fb3f9168-75db-471b-aa9b-cd8bcea36c03"
        )
        XCTAssertEqual(challenge.snapshotManifestHash, digest("4"))
        XCTAssertEqual(challenge.snapshotSourceFingerprintHash, digest("1"))
        XCTAssertTrue(challenge.preparedBindingDigest.hasPrefix("sha256:"))
        XCTAssertEqual(challenge.confirmationToken.count, 23)
        XCTAssertFalse(challenge.confirmationAuthority)
        XCTAssertFalse(challenge.repairMutationAuthority)
        XCTAssertFalse(challenge.automaticRetryAllowed)
        let saveCount = await journal.saveCount()
        let collectCount = await collector.collectCount()
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(collectCount, 1)
    }

    func testCoordinatorIsReviewOnlyAndCannotExecute() async throws {
        let coordinator = makeCoordinator(
            reader: M3hSavedPreviewReader(outcome: .notFound),
            collector: M3hReviewCollector(mode: .matching),
            journal: M3hChallengeJournal()
        )
        XCTAssertTrue(coordinator.capabilities.reviewAvailable)
        XCTAssertFalse(coordinator.capabilities.executionAvailable)
        XCTAssertFalse(coordinator.capabilities.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.automaticRetryAllowed)

        let result = await coordinator.confirmAndRepair(
            request: .init(
                requestID: UUID(),
                challenge: try publicChallenge(),
                exactConfirmationToken: "M3A-REPAIR-AAAAAAAAAAAA"
            )
        )
        guard case .unavailable = result else {
            return XCTFail("M3h must not execute")
        }
    }

    func testPackagedFactoryConstructionIsNoPathAndReviewOnly() {
        let coordinator =
            CodexGhostRepairCategoryARepairReviewCoordinatorFactory
                .packagedReviewOnly(
                    reviewCollector: M3hReviewCollector(mode: .matching)
                )

        XCTAssertTrue(coordinator.capabilities.reviewAvailable)
        XCTAssertFalse(coordinator.capabilities.executionAvailable)
        XCTAssertFalse(coordinator.capabilities.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.automaticRetryAllowed)
        XCTAssertFalse(coordinator.capabilities.restoreAuthority)
        XCTAssertFalse(coordinator.capabilities.cleanupAuthority)

        let production =
            CodexGhostRepairCategoryARepairReviewCoordinatorFactory
                .packagedProductionReview()
        XCTAssertTrue(production.capabilities.reviewAvailable)
        XCTAssertFalse(production.capabilities.executionAvailable)
        XCTAssertFalse(production.capabilities.acceptsCallerPath)
    }

    func testMissingOrUnavailableSavedPreviewStopsBeforeFreshCollection()
        async
    {
        for saved in [
            CodexGhostRepairCategoryASavedPreviewOutcome.notFound,
            .unavailable,
        ] {
            let collector = M3hReviewCollector(mode: .matching)
            let journal = M3hChallengeJournal()
            let coordinator = makeCoordinator(
                reader: M3hSavedPreviewReader(outcome: saved),
                collector: collector,
                journal: journal
            )
            let result = await coordinator.prepareReview(request: request())
            switch saved {
            case .notFound:
                guard case .blocked(.savedPreviewUnavailable, _) = result
                else { return XCTFail("Expected missing Preview blocker") }
            case .unavailable:
                guard case .unavailable = result else {
                    return XCTFail("Expected unavailable Preview readback")
                }
            case .preview:
                XCTFail("Unexpected Preview case")
            }
            let collectCount = await collector.collectCount()
            let saveCount = await journal.saveCount()
            XCTAssertEqual(collectCount, 0)
            XCTAssertEqual(saveCount, 0)
        }
    }

    func testExpiredOrCategoryBPreviewStopsBeforePersistence() async throws {
        for preview in [
            try makePreview(category: .ordinary),
            try makePreview(category: .automation),
        ] {
            let collector = M3hReviewCollector(mode: .matching)
            let journal = M3hChallengeJournal()
            let observed = preview.category == .ordinary
                ? preview.expiresAtMilliseconds
                : 2_000
            let coordinator = makeCoordinator(
                reader: M3hSavedPreviewReader(outcome: .preview(preview)),
                collector: collector,
                journal: journal,
                now: observed
            )
            let result = await coordinator.prepareReview(request: request())
            if preview.category == .ordinary {
                guard case .blocked(.savedPreviewExpired, _) = result else {
                    return XCTFail("Expected expired Preview blocker")
                }
            } else {
                guard case .blocked(.categoryNotSupported, _) = result else {
                    return XCTFail("Expected Category A-only blocker")
                }
            }
            let saveCount = await journal.saveCount()
            XCTAssertEqual(saveCount, 0)
        }
    }

    func testFreshReviewDriftStopsWithoutDurableChallenge() async throws {
        let journal = M3hChallengeJournal()
        let coordinator = makeCoordinator(
            reader: M3hSavedPreviewReader(
                outcome: .preview(try makePreview(category: .ordinary))
            ),
            collector: M3hReviewCollector(mode: .targetDrift),
            journal: journal
        )

        let result = await coordinator.prepareReview(request: request())

        guard case .blocked(.targetDrift, _) = result else {
            return XCTFail("Expected fresh target drift blocker")
        }
        let saveCount = await journal.saveCount()
        XCTAssertEqual(saveCount, 0)
    }

    func testPersistenceFailureNeverReturnsChallenge() async throws {
        let journal = M3hChallengeJournal(shouldFail: true)
        let coordinator = makeCoordinator(
            reader: M3hSavedPreviewReader(
                outcome: .preview(try makePreview(category: .ordinary))
            ),
            collector: M3hReviewCollector(mode: .matching),
            journal: journal
        )

        let result = await coordinator.prepareReview(request: request())

        guard case .blocked(.persistenceUnavailable, _) = result else {
            return XCTFail("Expected durable persistence blocker")
        }
        let saveCount = await journal.saveCount()
        XCTAssertEqual(saveCount, 1)
    }

    func testPackagedJournalPersistsAndReadsBackExactPreparedChallenge()
        async throws
    {
        let fixture = M3eCategoryATestFixture()
        let draft = try fixture.draft()
        let review = try fixture.review(draft: draft)
        let challenge = try fixture.challenge(draft: draft, review: review)
        let requestID = UUID(
            uuidString: "99999999-8888-4777-8666-555555555555"
        )!
        let binding = try CodexGhostRepairCategoryAPreparedRepairBinding(
            savedPreviewRequestID: requestID,
            draft: draft,
            review: review,
            challenge: challenge
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-session-manager-m3h-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent("manager.sqlite3")
        let journal = CodexGhostRepairCategoryAPackagedChallengeJournal(
            storeProvider: {
                try SQLiteStateStore(databaseURL: databaseURL)
            }
        )

        let readback = try await journal.saveAndReadback(binding)

        XCTAssertEqual(readback, binding)
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        defer { store.close() }
        XCTAssertEqual(
            try store.codexGhostRepairCategoryAPreparedBinding(
                operationID: challenge.operationID
            ),
            binding
        )
        XCTAssertEqual(
            try store.codexGhostRepairCategoryAOperation(
                operationID: challenge.operationID
            )?.status,
            .prepared
        )
    }

    private func makeCoordinator(
        reader: M3hSavedPreviewReader,
        collector: M3hReviewCollector,
        journal: M3hChallengeJournal,
        now: Int64 = 2_000
    ) -> CodexGhostRepairCategoryARepairReviewCoordinator {
        .init(
            savedPreviewReader: reader,
            reviewCollector: collector,
            journal: journal,
            nowMilliseconds: { now }
        )
    }

    private func request() -> CodexGhostRepairCategoryARepairReviewRequest {
        .init(
            requestID: UUID(
                uuidString: "11111111-2222-4333-8444-555555555555"
            )!,
            savedPreviewRequestID: UUID(
                uuidString: "99999999-8888-4777-8666-555555555555"
            )!
        )
    }

    private func publicChallenge()
        throws -> CodexGhostRepairCategoryARepairChallenge
    {
        try .init(
            operationID: request().requestID,
            savedPreviewRequestID: request().savedPreviewRequestID,
            snapshotReference: "fb3f9168-75db-471b-aa9b-cd8bcea36c03",
            snapshotManifestHash: digest("4"),
            snapshotSourceFingerprintHash: digest("1"),
            preparedBindingDigest: digest("5"),
            targetThreadIDs: [targetA],
            buildIdentifier: "test-build",
            draftDigest: digest("1"),
            reviewDigest: digest("2"),
            challengeDigest: digest("3"),
            confirmationToken: "M3A-REPAIR-AAAAAAAAAAAA",
            generatedAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2)
        )
    }

    private func makePreview(
        category: CodexGhostRepairCategory
    ) throws -> CodexGhostRepairSnapshotDryRunPreview {
        let targets = [targetA, targetB]
        let identity = try CodexGhostRepairSnapshotAnalysisIdentity(
            snapshotID: UUID(
                uuidString: "fb3f9168-75db-471b-aa9b-cd8bcea36c03"
            )!,
            targetThreadIDs: targets,
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
        let readback = CodexGhostRepairSnapshotAnalysisReadback(
            identity: identity,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: databases,
            targets: targets.map { threadID in
                .init(
                    threadID: threadID,
                    catalogRowDigests: [digest("a")],
                    automationRunRowDigests:
                        category == .automation ? [digest("b")] : [],
                    automationDefinitionRowDigests:
                        category == .automation ? [digest("c")] : [],
                    references: .init(
                        inbox: 0,
                        timeline: 0,
                        summaries: 0,
                        canonicalState: 0,
                        threadTurns: 0,
                        threadItems: 0,
                        historyProjection: 0
                    ),
                    rowContract: category == .ordinary
                        ? .categoryAEligible
                        : .categoryBEligible
                )
            },
            authority: .init(
                catalogRevision: 10,
                observationSequence: 20,
                watermarkUpdatedAt: 30,
                metadataRowDigest: digest("d"),
                localSyncRowDigest: digest("e")
            )
        )
        let outcome = CodexGhostRepairSnapshotDryRunPlanner.plan(
            identity: identity,
            snapshotEvidence: readback,
            protectionEvidence: targets.map {
                .init(
                    threadID: $0,
                    inventoryComplete: true,
                    activeInventoryPresent: false,
                    archivedInventoryPresent: false,
                    exactReadNotLoaded: true,
                    exactReadErrorCode: -32600,
                    pinned: false,
                    descendantCount: 0
                )
            },
            experimentalAbsenceEvidence: targets.map {
                .init(
                    provider: .codex,
                    requestedThreadID: $0,
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
                    databases: databases.map {
                        .init(
                            database: $0.database,
                            schemaVersion: $0.schemaVersion
                        )
                    }
                )
            },
            operationalAudit: .init(
                codexFullyExited: true,
                desktopOpenHandleCount: 0,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                stateOpenHandleCount: 0,
                threadHistoryOpenHandleCount: 0,
                capacitySufficient: true
            ),
            previewID: UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!,
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
        )
        guard case let .preview(preview) = outcome else {
            throw M3hTestError.previewUnavailable
        }
        return preview
    }

    private var databases:
        [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    {
        [
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
        ]
    }

    private let targetA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let targetB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}

private actor M3hSavedPreviewReader:
    CodexGhostRepairCategoryASavedPreviewReading
{
    private let outcome: CodexGhostRepairCategoryASavedPreviewOutcome

    init(outcome: CodexGhostRepairCategoryASavedPreviewOutcome) {
        self.outcome = outcome
    }

    func preview(
        requestID _: UUID
    ) async -> CodexGhostRepairCategoryASavedPreviewOutcome {
        outcome
    }
}

private actor M3hReviewCollector:
    CodexGhostRepairCategoryARepairReviewMaterialCollecting
{
    enum Mode { case matching, targetDrift }

    private let mode: Mode
    private var calls = 0

    init(mode: Mode) { self.mode = mode }

    func collect(
        draft: CodexGhostRepairCategoryAExecutionDraft
    ) async -> CodexGhostRepairCategoryARepairReviewMaterialOutcome {
        calls += 1
        let items = draft.itemChanges.map {
            CodexGhostRepairCategoryAExecutionReviewItem(
                threadID: $0.threadID,
                catalogRowDigest: mode == .matching
                    ? $0.catalogRowDigest
                    : "sha256:" + String(repeating: "9", count: 64)
            )
        }
        do {
            let review = try CodexGhostRepairCategoryAExecutionReviewEvidence(
                reviewID: UUID(),
                items: items,
                protectionEvidenceHash:
                    "sha256:" + String(repeating: "a", count: 64),
                protectionComplete: true,
                operationalGateEvidenceHash:
                    "sha256:" + String(repeating: "b", count: 64),
                operationalGateClear: true,
                databaseExpectations: draft.databaseExpectations,
                authorityAudit: draft.authorityAudit,
                observedAtMilliseconds: 2_000
            )
            return .material(.init(
                review: review,
                buildIdentifier: "test-build",
                observedAtMilliseconds: 2_000
            ))
        } catch {
            return .unavailable
        }
    }

    func collectCount() -> Int { calls }
}

private actor M3hChallengeJournal:
    CodexGhostRepairCategoryARepairChallengeJournaling
{
    private let shouldFail: Bool
    private var saves = 0

    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }

    func saveAndReadback(
        _ binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) async throws -> CodexGhostRepairCategoryAPreparedRepairBinding {
        saves += 1
        if shouldFail { throw M3hTestError.persistenceUnavailable }
        return binding
    }

    func saveCount() -> Int { saves }
}

private enum M3hTestError: Error {
    case previewUnavailable
    case persistenceUnavailable
}
