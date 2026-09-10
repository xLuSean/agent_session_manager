@testable import AgentSessionManagerCore
import Foundation

struct M3eCategoryATestFixture {
    let operationID = UUID(
        uuidString: "11111111-2222-4333-8444-555555555555"
    )!
    let previewID = UUID(
        uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!
    let targetA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    let targetB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"

    func draft(
        targets: [String]? = nil,
        catalogDigests: [String: String]? = nil,
        sourceAuthority:
            CodexGhostRepairSnapshotAnalysisAuthorityEvidence? = nil,
        sourceFingerprintHash: String? = nil
    ) throws -> CodexGhostRepairCategoryAExecutionDraft {
        let selected = targets ?? [targetA, targetB]
        let preview = try preview(
            targets: selected,
            catalogDigests: catalogDigests,
            sourceAuthority: sourceAuthority,
            sourceFingerprintHash: sourceFingerprintHash
        )
        guard case let .draft(draft) =
                CodexGhostRepairCategoryAExecutionContract.freeze(
                    preview: preview,
                    operationID: operationID,
                    observedAtMilliseconds: 2_000
                ) else {
            throw FixtureError.unavailable
        }
        return draft
    }

    func review(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        protectionComplete: Bool = true,
        operationalGateClear: Bool = true,
        catalogRevision: Int64 = 1_000
    ) throws -> CodexGhostRepairCategoryAExecutionReviewEvidence {
        try .init(
            reviewID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!,
            items: draft.itemChanges.map {
                .init(
                    threadID: $0.threadID,
                    catalogRowDigest: $0.catalogRowDigest
                )
            },
            protectionEvidenceHash: digest("6"),
            protectionComplete: protectionComplete,
            operationalGateEvidenceHash: digest("7"),
            operationalGateClear: operationalGateClear,
            databaseExpectations: draft.databaseExpectations,
            authorityAudit: authority(catalogRevision: catalogRevision),
            observedAtMilliseconds: 2_100
        )
    }

    func challenge(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        review: CodexGhostRepairCategoryAExecutionReviewEvidence
    ) throws -> CodexGhostRepairCategoryAConfirmationChallenge {
        let outcome = CodexGhostRepairCategoryAExecutionPreparation
            .prepareChallenge(
                draft: draft,
                review: review,
                buildIdentifier: "m3e-tests",
                observedAtMilliseconds: 2_200
            )
        guard case let .challenge(challenge) = outcome else {
            throw FixtureError.unavailable
        }
        return challenge
    }

    func receipt(
        challenge: CodexGhostRepairCategoryAConfirmationChallenge
    ) throws -> CodexGhostRepairCategoryAAuthorizationReceipt {
        try CodexGhostRepairCategoryAExecutionPreparation.consumeAuthorization(
            challenge: challenge,
            confirmationToken: challenge.confirmationToken,
            confirmedAtMilliseconds: 2_300
        )
    }

    func freshEvidence(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        review: CodexGhostRepairCategoryAExecutionReviewEvidence,
        catalogRevision: Int64 = 2_000,
        freshAuthority:
            CodexGhostRepairSnapshotAnalysisAuthorityEvidence? = nil
    ) throws -> CodexGhostRepairCategoryAFreshExecutionEvidence {
        try .init(
            items: draft.itemChanges.map {
                .init(
                    threadID: $0.threadID,
                    catalogRowDigest: $0.catalogRowDigest
                )
            },
            protectionEvidenceHash: review.protectionEvidenceHash,
            protectionComplete: true,
            operationalGateEvidenceHash: digest("8"),
            operationalGateClear: true,
            databaseExpectations: draft.databaseExpectations,
            freshAuthority:
                freshAuthority ?? authority(catalogRevision: catalogRevision),
            observedAtMilliseconds: 2_400
        )
    }

    func claim(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        review: CodexGhostRepairCategoryAExecutionReviewEvidence,
        challenge: CodexGhostRepairCategoryAConfirmationChallenge,
        receipt: CodexGhostRepairCategoryAAuthorizationReceipt
    ) throws -> CodexGhostRepairCategoryAExecutionClaimEvidence {
        try CodexGhostRepairCategoryAExecutionPreparation.prepareClaimEvidence(
            draft: draft,
            review: review,
            challenge: challenge,
            receipt: receipt,
            executionSnapshotManifestHash: digest("9"),
            freshEvidence: freshEvidence(draft: draft, review: review),
            executionAtMilliseconds: 2_600,
            claimedAtMilliseconds: 2_500
        )
    }

    func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }

    private func authority(
        catalogRevision: Int64
    ) -> CodexGhostRepairSnapshotAnalysisAuthorityEvidence {
        .init(
            catalogRevision: catalogRevision,
            observationSequence: catalogRevision + 10,
            watermarkUpdatedAt: Double(catalogRevision + 20),
            metadataRowDigest: digest("d"),
            localSyncRowDigest: digest("e")
        )
    }

    private func preview(
        targets: [String],
        catalogDigests: [String: String]?,
        sourceAuthority:
            CodexGhostRepairSnapshotAnalysisAuthorityEvidence?,
        sourceFingerprintHash: String?
    ) throws -> CodexGhostRepairSnapshotDryRunPreview {
        let identity = try CodexGhostRepairSnapshotAnalysisIdentity(
            snapshotID: UUID(
                uuidString: "fb3f9168-75db-471b-aa9b-cd8bcea36c03"
            )!,
            targetThreadIDs: targets,
            preparedAtMilliseconds: 100,
            publishedAtMilliseconds: 200,
            sourceFingerprintHash: sourceFingerprintHash ?? digest("1"),
            destinationBindingHash: digest("2"),
            acquisitionRecordHash: digest("3"),
            manifestHash: digest("4"),
            publicationReceiptHash: digest("5"),
            observedRegularFileCount: 10,
            actualPublishedBytes: 1_000
        )
        let databases = databaseEvidence()
        let readback = CodexGhostRepairSnapshotAnalysisReadback(
            identity: identity,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: databases,
            targets: targets.map { threadID in
                .init(
                    threadID: threadID,
                    catalogRowDigests: [
                        catalogDigests?[threadID] ?? digest("a")
                    ],
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
            authority: sourceAuthority ?? authority(catalogRevision: 10)
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
                databases: databases.map {
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
            throw FixtureError.unavailable
        }
        return preview
    }

    private func databaseEvidence()
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

    private enum FixtureError: Error {
        case unavailable
    }
}
