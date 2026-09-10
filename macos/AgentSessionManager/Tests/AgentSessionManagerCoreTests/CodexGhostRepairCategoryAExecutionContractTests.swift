@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairCategoryAExecutionContractTests: XCTestCase {
    private let operationID = UUID(
        uuidString: "11111111-2222-4333-8444-555555555555"
    )!
    private let previewID = UUID(
        uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!
    private let targetA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let targetB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"

    func testCategoryAOneAndTwoItemDraftsFreezeExactAllOrNothingScope()
        throws
    {
        for targets in [[targetA], [targetA, targetB]] {
            let preview = try makePreview(
                category: .ordinary,
                targets: targets
            )

            let first = CodexGhostRepairCategoryAExecutionContract.freeze(
                preview: preview,
                operationID: operationID,
                observedAtMilliseconds: 2_000
            )
            let second = CodexGhostRepairCategoryAExecutionContract.freeze(
                preview: preview,
                operationID: operationID,
                observedAtMilliseconds: 2_000
            )

            XCTAssertEqual(first, second)
            guard case let .draft(draft) = first else {
                return XCTFail("Expected Category A execution draft")
            }
            try draft.validateDigest()
            XCTAssertEqual(draft.category, .ordinary)
            XCTAssertEqual(draft.targetThreadIDs, targets)
            XCTAssertEqual(draft.itemChanges.map(\.threadID), targets)
            XCTAssertEqual(draft.authorityAudit.catalogRevision, 10)
            XCTAssertEqual(draft.authorityAudit.observationSequence, 20)
            XCTAssertEqual(draft.authorityAudit.watermarkUpdatedAt, 30)
            XCTAssertEqual(draft.authorityAudit.metadataRowDigest, digest("d"))
            XCTAssertEqual(draft.authorityAudit.localSyncRowDigest, digest("e"))
            XCTAssertTrue(draft.itemChanges.allSatisfy {
                $0.effect.kind == .removeCatalogRow && $0.effect.amount == 1
            })
            XCTAssertEqual(
                draft.expectedBatchEffects,
                [
                    .init(
                        kind: .incrementCatalogRevision,
                        amount: targets.count
                    ),
                    .init(
                        kind: .incrementObservationSequence,
                        amount: targets.count
                    ),
                ]
            )
            XCTAssertTrue(draft.allOrNothing)
            XCTAssertFalse(draft.silentSelectionShrinkAllowed)
            XCTAssertFalse(draft.partialLogicalOutcomeAllowed)
            XCTAssertTrue(draft.requiresFreshExecutionSnapshotBinding)
            XCTAssertTrue(draft.requiresNewExactConfirmation)
            XCTAssertFalse(draft.confirmationAuthority)
            XCTAssertFalse(draft.repairMutationAuthority)
            XCTAssertFalse(draft.automaticRetry)
        }
    }

    func testDraftFreezesFiveDatabaseRolesAndFourAdmittedSchemas()
        throws
    {
        let preview = try makePreview(
            category: .ordinary,
            targets: [targetA]
        )
        guard case let .draft(draft) =
                CodexGhostRepairCategoryAExecutionContract.freeze(
                    preview: preview,
                    operationID: operationID,
                    observedAtMilliseconds: 2_000
                ) else {
            return XCTFail("Expected Category A execution draft")
        }

        XCTAssertEqual(
            draft.databaseExpectations.map(\.database),
            CodexGhostRepairProductionRepairDatabase.allCases
        )
        XCTAssertEqual(draft.databaseExpectations.filter(\.required).count, 4)
        XCTAssertEqual(
            draft.databaseExpectations.filter {
                $0.role == .futureSingleTransactionMutation
            }.map(\.database),
            [.desktop]
        )
        XCTAssertEqual(
            draft.databaseExpectations.map(\.admittedSchemaVersion),
            [32, 2, 0, 0, nil]
        )
    }

    func testCategoryBPreviewIsUnavailableForExecutionDraft() throws {
        let preview = try makePreview(
            category: .automation,
            targets: [targetA]
        )

        XCTAssertEqual(
            CodexGhostRepairCategoryAExecutionContract.freeze(
                preview: preview,
                operationID: operationID,
                observedAtMilliseconds: 2_000
            ),
            .blocked(.categoryUnavailable)
        )
    }

    func testExpiredOrPreGenerationPreviewIsRejected() throws {
        let preview = try makePreview(
            category: .ordinary,
            targets: [targetA]
        )

        for observedAt in [999, preview.expiresAtMilliseconds] {
            XCTAssertEqual(
                CodexGhostRepairCategoryAExecutionContract.freeze(
                    preview: preview,
                    operationID: operationID,
                    observedAtMilliseconds: observedAt
                ),
                .blocked(.previewExpired)
            )
        }
    }

    func testSnapshotOlderThanRepairWindowIsRejected() throws {
        let preview = try makePreview(
            category: .ordinary,
            targets: [targetA]
        )

        XCTAssertEqual(
            CodexGhostRepairCategoryAExecutionContract.freeze(
                preview: preview,
                operationID: operationID,
                observedAtMilliseconds: 900_201
            ),
            .blocked(.previewExpired)
        )
    }

    func testDraftDigestDetectsDecodedTampering() throws {
        let preview = try makePreview(
            category: .ordinary,
            targets: [targetA]
        )
        guard case let .draft(draft) =
                CodexGhostRepairCategoryAExecutionContract.freeze(
                    preview: preview,
                    operationID: operationID,
                    observedAtMilliseconds: 2_000
                ) else {
            return XCTFail("Expected Category A execution draft")
        }
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(draft))
                as? [String: Any]
        )
        object["snapshotManifestHash"] = digest("9")
        let tampered = try JSONDecoder().decode(
            CodexGhostRepairCategoryAExecutionDraft.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertThrowsError(try tampered.validateDigest()) { error in
            guard case .invalidPlan = error as? CodexGhostRepairError else {
                return XCTFail("Expected invalidPlan, found \(error)")
            }
        }
    }

    func testOutcomeVocabularyDoesNotCollapseUnknownOrNotAttempted() {
        XCTAssertEqual(
            CodexGhostRepairCategoryABatchOutcome.success.itemOutcome,
            .success
        )
        XCTAssertEqual(
            CodexGhostRepairCategoryABatchOutcome.explicitFailure.itemOutcome,
            .explicitFailure
        )
        XCTAssertEqual(
            CodexGhostRepairCategoryABatchOutcome.unknown.itemOutcome,
            .unknown
        )
        XCTAssertEqual(
            CodexGhostRepairCategoryABatchOutcome.notAttempted.itemOutcome,
            .notAttempted
        )
    }

    func testCapabilitiesGrantNoIOPersistenceOrRepairAuthority() {
        let capabilities =
            CodexGhostRepairCategoryAExecutionContract.capabilities

        XCTAssertTrue(capabilities.pureDeterministicFreezeAvailable)
        XCTAssertEqual(capabilities.maximumTargetCount, 2)
        XCTAssertTrue(capabilities.categoryAOnly)
        XCTAssertFalse(capabilities.acceptsCallerPath)
        XCTAssertFalse(capabilities.opensFilesystem)
        XCTAssertFalse(capabilities.opensSQLite)
        XCTAssertFalse(capabilities.persistsDraft)
        XCTAssertFalse(capabilities.createsBackup)
        XCTAssertFalse(capabilities.createsClaim)
        XCTAssertFalse(capabilities.confirmationAuthority)
        XCTAssertFalse(capabilities.repairMutationAuthority)
        XCTAssertFalse(capabilities.automaticRetry)
    }

    private func makePreview(
        category: CodexGhostRepairCategory,
        targets: [String]
    ) throws -> CodexGhostRepairSnapshotDryRunPreview {
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
            databases: databases(),
            targets: targets.map { threadID in
                .init(
                    threadID: threadID,
                    catalogRowDigests: [digest("a")],
                    automationRunRowDigests:
                        category == .automation ? [digest("b")] : [],
                    automationDefinitionRowDigests:
                        category == .automation ? [digest("c")] : [],
                    references: zeroReferences(),
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
        let protections = targets.map { threadID in
            CodexGhostRepairProtectionEvidence(
                threadID: threadID,
                inventoryComplete: true,
                activeInventoryPresent: false,
                archivedInventoryPresent: false,
                exactReadNotLoaded: true,
                exactReadErrorCode: -32600,
                pinned: false,
                descendantCount: 0
            )
        }
        let experimental = targets.map { threadID in
            CodexGhostRepairExperimentalAbsenceEvidence(
                provider: .codex,
                requestedThreadID: threadID,
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
                databases: databases().map {
                    .init(
                        database: $0.database,
                        schemaVersion: $0.schemaVersion
                    )
                }
            )
        }
        let outcome = CodexGhostRepairSnapshotDryRunPlanner.plan(
            identity: identity,
            snapshotEvidence: readback,
            protectionEvidence: protections,
            experimentalAbsenceEvidence: experimental,
            operationalAudit: .init(
                codexFullyExited: true,
                desktopOpenHandleCount: 0,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                stateOpenHandleCount: 0,
                threadHistoryOpenHandleCount: 0,
                capacitySufficient: true
            ),
            previewID: previewID,
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
        )
        guard case let .preview(preview) = outcome else {
            throw ContractTestError.previewUnavailable
        }
        return preview
    }

    private func databases()
        -> [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
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

    private func zeroReferences()
        -> CodexGhostRepairSnapshotAnalysisReferenceCounts
    {
        .init(
            inbox: 0,
            timeline: 0,
            summaries: 0,
            canonicalState: 0,
            threadTurns: 0,
            threadItems: 0,
            historyProjection: 0
        )
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }

    private enum ContractTestError: Error {
        case previewUnavailable
    }
}
