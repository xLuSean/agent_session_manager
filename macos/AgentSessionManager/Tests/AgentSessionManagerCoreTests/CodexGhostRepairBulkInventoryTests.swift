@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairBulkInventoryTests: XCTestCase {
    private let snapshotReference = "11111111-2222-4333-8444-555555555555"

    func testTitlesAreDisplayOnlySurviveManualReviewAndNeverEnterPersistedEvidence() throws {
        let id = canonicalID(1)
        let original = target(id: id, contract: .categoryAEligible)
        var titled = original
        titled.displayTitle = "私人週報標題"
        XCTAssertEqual(titled, original)
        XCTAssertEqual(titled.hashValue, original.hashValue)
        func scan(_ target: CodexGhostRepairSnapshotAnalysisTargetEvidence) throws -> CodexGhostRepairBulkInventory {
            try CodexGhostRepairBulkInventoryComposer.compose(snapshot: snapshotEvidence(targets: [target]),
                officialInventory: officialInventory(), exactObservations: [exactObservation(id: id)])
        }
        let untitledScan = try scan(original)
        let titledScan = try scan(titled)
        XCTAssertEqual(titledScan, untitledScan)
        XCTAssertEqual(titledScan.displayTitle(for: id), titled.displayTitle)
        XCTAssertEqual(try titledScan.reviewingKnownResidue(true).displayTitle(for: id), titled.displayTitle)
        let encoded = try JSONEncoder().encode(titledScan)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("私人週報標題"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(titled), as: UTF8.self).contains("私人週報標題"))
        XCTAssertNil(try JSONDecoder().decode(CodexGhostRepairBulkInventory.self, from: encoded).displayTitle(for: id))
        let preview = try CodexGhostRepairBulkPreviewFactory.buildAuthorityFree(
            inventory: titledScan, selectedThreadIDs: [id], generatedAtMilliseconds: 1_000)
        let frozen = try CodexGhostRepairBulkFrozenPlanSourceBuilder.build(inventory: titledScan, preview: preview)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(frozen), as: UTF8.self).contains("私人週報標題"))
    }

    func testManualReviewOnlyAdmitsKnownResidueAndResetsToProtectedScan() throws {
        let ids = (1...8).map(canonicalID)
        var targets = ids.map { target(id: $0, contract: .categoryAEligible, references: references(summaries: 1)) }
        for index in targets.indices { targets[index].summaryRowDigests = [digest("summary-\(index)")] }
        targets[1] = target(id: ids[1], contract: .unsupported)
        targets[1].pausedAutomationReviewable = true
        targets[2] = target(id: ids[2], contract: .unsupported, references: references(summaries: 1))
        targets[2].summaryRowDigests = [digest("unknown")]
        targets[7].summaryRowDigests = nil // Counts alone cannot authorize content deletion.
        var observations = ids.map { exactObservation(id: $0) }
        observations[3] = exactObservation(id: ids[3], pinned: true)
        observations[4] = exactObservation(id: ids[4], descendantCount: 1)
        observations[5] = exactObservation(id: ids[5], exactReadNotLoaded: false, exactReadErrorCode: 0, exactReadPresent: true)
        observations[6] = exactObservation(id: ids[6], exactReadNotLoaded: false, exactReadErrorCode: -32000)
        let scan = try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: snapshotEvidence(targets: targets), officialInventory: officialInventory(), exactObservations: observations
        )
        XCTAssertEqual(scan.eligibleItemCount, 0)
        let manual = try scan.reviewingKnownResidue(true)
        XCTAssertEqual(manual.eligibleThreadIDs, Array(ids.prefix(2)))
        XCTAssertNotEqual(manual.inventoryDigest, scan.inventoryDigest)
        XCTAssertEqual(try manual.reviewingKnownResidue(false), scan)
        XCTAssertEqual(try CodexGhostRepairBulkInventoryBuilder.build(input: XCTUnwrap(manual.sourceEvidence)), manual)
        XCTAssertEqual(manual.items[5].blockers, [.exactReadPresent])
        XCTAssertEqual(manual.items[0].reviewedResidue?.summaryRowDigests.count, 1)
    }

    func testHistoricalScaleFixtureClassifiesExact148ItemsWithoutSilentShrink()
        throws
    {
        let ids = (1...148).map(canonicalID)
        let targets = ids.enumerated().map { offset, id in
            switch offset {
            case 0..<48:
                target(id: id, contract: .categoryAEligible)
            case 48..<145:
                target(id: id, contract: .categoryBEligible)
            default:
                target(
                    id: id,
                    contract: .categoryAEligible,
                    references: references(summaries: 1)
                )
            }
        }
        let observations = ids.reversed().map { exactObservation(id: $0) }

        let inventory = try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: snapshotEvidence(targets: targets),
            officialInventory: officialInventory(),
            exactObservations: observations
        )

        XCTAssertEqual(inventory.observedCatalogItemCount, 148)
        XCTAssertEqual(inventory.confirmedGhostCount, 148)
        XCTAssertEqual(inventory.eligibleItemCount, 145)
        XCTAssertEqual(inventory.blockedItemCount, 3)
        XCTAssertEqual(inventory.notGhostItemCount, 0)
        XCTAssertEqual(inventory.ordinaryEligibleItemCount, 48)
        XCTAssertEqual(inventory.automationEligibleItemCount, 97)
        XCTAssertEqual(inventory.eligibleThreadIDs.count, 145)
        XCTAssertEqual(inventory.items.map(\.threadID), ids)
        XCTAssertEqual(
            inventory.items.suffix(3).map(\.blockers),
            Array(
                repeating: [.summaryRecordsPresent],
                count: 3
            )
        )
        XCTAssertTrue(inventory.automaticallyClassified)
        XCTAssertFalse(inventory.requiresCallerSuppliedThreadIDs)
        XCTAssertFalse(inventory.persistsPreview)
        XCTAssertFalse(inventory.repairPreviewAuthority)
        XCTAssertFalse(inventory.repairMutationAuthority)
        XCTAssertTrue(inventory.inventoryDigest.hasPrefix("sha256:"))
        XCTAssertEqual(inventory.inventoryDigest.count, 71)
        XCTAssertEqual(
            Set(inventory.items.map(\.evidenceDigest)).count,
            148
        )

        let canonicalProtectionOrder = try CodexGhostRepairBulkInventoryComposer
            .compose(
                snapshot: snapshotEvidence(targets: targets),
                officialInventory: officialInventory(),
                exactObservations: ids.map { exactObservation(id: $0) }
            )
        XCTAssertEqual(
            inventory.inventoryDigest,
            canonicalProtectionOrder.inventoryDigest
        )
    }

    func testComposerDerivesCandidatesFromCompleteOfficialInventory() throws {
        let ids = (1...4).map(canonicalID)
        let targets = [
            target(id: ids[0], contract: .categoryAEligible),
            target(id: ids[1], contract: .categoryAEligible),
            target(id: ids[2], contract: .categoryAEligible),
            target(id: ids[3], contract: .categoryBEligible),
        ]

        let inventory = try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: snapshotEvidence(targets: targets),
            officialInventory: officialInventory(
                active: [ids[0]],
                archived: [ids[1]]
            ),
            exactObservations: [
                exactObservation(id: ids[2]),
                exactObservation(id: ids[3]),
            ]
        )

        XCTAssertEqual(inventory.observedCatalogItemCount, 4)
        XCTAssertEqual(inventory.notGhostItemCount, 2)
        XCTAssertEqual(inventory.confirmedGhostCount, 2)
        XCTAssertEqual(inventory.eligibleItemCount, 2)
        XCTAssertEqual(inventory.ordinaryEligibleItemCount, 1)
        XCTAssertEqual(inventory.automationEligibleItemCount, 1)
        XCTAssertEqual(inventory.eligibleThreadIDs, [ids[2], ids[3]])
        let digest = inventory.inventoryDigest
        XCTAssertEqual(inventory.items.filter { inventory.matches($0, filter: .active) }.map(\.threadID), [ids[0]])
        XCTAssertEqual(inventory.items.filter { inventory.matches($0, filter: .archived) }.map(\.threadID), [ids[1]])
        XCTAssertEqual(inventory.items.filter { inventory.matches($0, filter: .needsAttention) }.map(\.threadID), [ids[2], ids[3]])
        XCTAssertEqual(inventory.items.filter { inventory.matches($0, filter: .notGhost) }.count, 2)
        XCTAssertEqual(inventory.items.filter { inventory.matches($0, filter: .all) }.count, 4)
        XCTAssertEqual(inventory.inventoryDigest, digest)
    }

    func testComposerRejectsMissingExtraOrIncompleteOfficialEvidence() {
        let ids = (1...2).map(canonicalID)
        let targets = ids.map { target(id: $0, contract: .categoryAEligible) }
        let snapshot = snapshotEvidence(targets: targets)

        XCTAssertThrowsError(
            try CodexGhostRepairBulkInventoryComposer.compose(
                snapshot: snapshot,
                officialInventory: officialInventory(complete: false),
                exactObservations: ids.map { exactObservation(id: $0) }
            )
        )
        XCTAssertThrowsError(
            try CodexGhostRepairBulkInventoryComposer.compose(
                snapshot: snapshot,
                officialInventory: officialInventory(),
                exactObservations: [exactObservation(id: ids[0])]
            )
        )
        XCTAssertThrowsError(
            try CodexGhostRepairBulkInventoryComposer.compose(
                snapshot: snapshot,
                officialInventory: officialInventory(active: [ids[0]]),
                exactObservations: ids.map { exactObservation(id: $0) }
            )
        )
    }

    func testSkippedPresentAndFailedReadsHaveDistinctNonDeletableReasons() throws {
        let ids = (1...4).map(canonicalID)
        let inventory = try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: snapshotEvidence(targets: [
                target(id: ids[0], contract: .categoryAEligible,
                       references: references(canonicalState: 1)),
                target(id: ids[1], contract: .categoryAEligible),
                target(id: ids[2], contract: .categoryAEligible),
                target(id: ids[3], contract: .categoryBEligible,
                       references: references(summaries: 1)),
            ]),
            officialInventory: officialInventory(),
            exactObservations: [
                exactObservation(id: ids[1], exactReadNotLoaded: false,
                                 exactReadErrorCode: 0, exactReadPresent: true),
                exactObservation(id: ids[2], exactReadNotLoaded: false,
                                 exactReadErrorCode: -32000),
                exactObservation(id: ids[3]),
            ]
        )

        XCTAssertEqual(inventory.items.map(\.blockers), [
            [.canonicalStatePresent, .exactReadNotPerformed],
            [.exactReadPresent],
            [.exactReadUnavailable],
            [.summaryRecordsPresent],
        ])
        XCTAssertEqual(inventory.items[0].retentionExplanation, "Local session data exists — kept")
        XCTAssertEqual(inventory.items.filter { inventory.matches($0, filter: .localData) }.map(\.threadID), [ids[0]])
        XCTAssertEqual(inventory.items.filter { inventory.matches($0, filter: .unconfirmed) }.map(\.threadID), [ids[1], ids[2]])
        XCTAssertEqual(inventory.items.filter { inventory.matches($0, filter: .blocked) }.map(\.threadID), [ids[3]])
        XCTAssertEqual(inventory.items[1].retentionExplanation, "Codex can read this session — kept")
        XCTAssertNil(inventory.items[2].retentionExplanation)
        XCTAssertEqual(inventory.confirmedGhostCount, 1)
        XCTAssertEqual(inventory.eligibleItemCount, 0)
        XCTAssertEqual(inventory.blockedItemCount, 4)
        XCTAssertTrue(inventory.items.allSatisfy { !$0.selectable })
        let roundTrip = try JSONDecoder().decode(
            CodexGhostRepairBulkInventory.self,
            from: JSONEncoder().encode(inventory)
        )
        XCTAssertEqual(roundTrip, inventory)
    }

    func testPresentReadCannotContradictAbsentObservation() {
        let id = canonicalID(1)
        XCTAssertThrowsError(try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: snapshotEvidence(targets: [target(id: id, contract: .categoryAEligible)]),
            officialInventory: officialInventory(),
            exactObservations: [exactObservation(id: id, exactReadPresent: true)]
        ))
    }

    func testClassificationSeparatesNormalUnconfirmedAndBlockedRows() throws {
        let ids = (1...4).map(canonicalID)
        let targets = [
            target(id: ids[0], contract: .categoryAEligible),
            target(id: ids[1], contract: .categoryAEligible),
            target(id: ids[2], contract: .categoryAEligible),
            target(
                id: ids[3],
                contract: .unsupported,
                references: references(timeline: 1)
            ),
        ]
        let protections = [
            protection(
                id: ids[0],
                activeInventoryPresent: true,
                exactReadNotLoaded: false,
                exactReadErrorCode: 0
            ),
            protection(
                id: ids[1],
                inventoryComplete: false,
                exactReadNotLoaded: false,
                exactReadErrorCode: 0
            ),
            protection(id: ids[2], pinned: true, descendantCount: 2),
            protection(id: ids[3]),
        ]

        let inventory = try CodexGhostRepairBulkInventoryBuilder.build(
            input: input(targets: targets, protections: protections)
        )

        XCTAssertEqual(inventory.notGhostItemCount, 1)
        XCTAssertEqual(inventory.confirmedGhostCount, 2)
        XCTAssertEqual(inventory.eligibleItemCount, 0)
        XCTAssertEqual(inventory.blockedItemCount, 3)
        XCTAssertEqual(inventory.items[0].disposition, .notGhost)
        XCTAssertEqual(inventory.items[0].blockers, [])
        XCTAssertEqual(inventory.items[1].disposition, .unconfirmed)
        XCTAssertEqual(
            inventory.items[1].blockers,
            [.incompleteOfficialInventory, .exactReadUnavailable]
        )
        XCTAssertEqual(inventory.items[2].disposition, .blocked)
        XCTAssertEqual(inventory.items[2].category, .ordinary)
        XCTAssertEqual(
            inventory.items[2].blockers,
            [.pinned, .descendantsPresent]
        )
        XCTAssertEqual(inventory.items[3].disposition, .blocked)
        XCTAssertNil(inventory.items[3].category)
        XCTAssertEqual(
            inventory.items[3].blockers,
            [.unsupportedRowShape, .sideReferencesPresent]
        )
        XCTAssertTrue(inventory.items[2].confirmedGhost)
        XCTAssertFalse(inventory.items[2].selectable)
        XCTAssertFalse(inventory.items[2].repairPreviewAuthority)
        XCTAssertFalse(inventory.items[2].repairMutationAuthority)
    }

    func testDuplicateOrMissingProtectionEvidenceFailsWholeInventory() {
        let ids = (1...2).map(canonicalID)
        let targets = ids.map { target(id: $0, contract: .categoryAEligible) }
        let duplicate = protection(id: ids[0])

        XCTAssertThrowsError(
            try CodexGhostRepairBulkInventoryBuilder.build(
                input: input(
                    targets: targets,
                    protections: [duplicate, duplicate]
                )
            )
        ) { error in
            guard case CodexGhostRepairError.invalidProtectionEvidence = error
            else {
                return XCTFail("Expected exact protection evidence rejection")
            }
        }
    }

    func testUnadmittedDatabaseContractFailsBeforeClassification() {
        let id = canonicalID(1)
        var source = input(
            targets: [target(id: id, contract: .categoryAEligible)],
            protections: [protection(id: id)]
        )
        source = CodexGhostRepairBulkInventoryInput(
            snapshotReference: source.snapshotReference,
            sourceLayoutIdentifier: source.sourceLayoutIdentifier,
            sourceFingerprintHash: source.sourceFingerprintHash,
            manifestHash: source.manifestHash,
            databases: databaseEvidence(desktopVersion: 34),
            targets: source.targets,
            protectionEvidence: source.protectionEvidence,
            authority: source.authority
        )

        XCTAssertThrowsError(
            try CodexGhostRepairBulkInventoryBuilder.build(input: source)
        ) { error in
            guard case CodexGhostRepairError.invalidDatabaseContract = error
            else {
                return XCTFail("Expected version-bound database rejection")
            }
        }
    }

    func testV151RuntimePairsClassifyExact148ItemsWithoutSilentShrink()
        throws
    {
        let ids = (1...148).map(canonicalID)
        let targets = ids.enumerated().map { offset, id in
            switch offset {
            case 0..<48:
                target(id: id, contract: .categoryAEligible)
            case 48..<145:
                target(id: id, contract: .categoryBEligible)
            default:
                target(
                    id: id,
                    contract: .categoryAEligible,
                    references: references(summaries: 1)
                )
            }
        }
        let snapshot = snapshotEvidence(
            targets: targets,
            sourceLayoutIdentifier:
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v151SourceLayoutIdentifier,
            desktopSchemaVersion: 33
        )

        for runtime in ["0.151.0-alpha.7.2", "0.151.0"] {
            let inventory = try CodexGhostRepairBulkInventoryComposer.compose(
                snapshot: snapshot,
                officialInventory: officialInventory(
                    runtimeVersion: runtime
                ),
                exactObservations: ids.reversed().map {
                    exactObservation(id: $0)
                }
            )

            XCTAssertEqual(inventory.observedCatalogItemCount, 148)
            XCTAssertEqual(inventory.confirmedGhostCount, 148)
            XCTAssertEqual(inventory.eligibleItemCount, 145)
            XCTAssertEqual(inventory.blockedItemCount, 3)
            XCTAssertEqual(inventory.ordinaryEligibleItemCount, 48)
            XCTAssertEqual(inventory.automationEligibleItemCount, 97)
            XCTAssertEqual(inventory.items.map(\.threadID), ids)
            XCTAssertFalse(inventory.repairPreviewAuthority)
            XCTAssertFalse(inventory.repairMutationAuthority)
        }
    }

    func testCurrentV152RuntimeClassifiesExact148ItemsWithoutSilentShrink()
        throws
    {
        let ids = (1...148).map(canonicalID)
        let targets = ids.enumerated().map { offset, id in
            switch offset {
            case 0..<48:
                target(id: id, contract: .categoryAEligible)
            case 48..<145:
                target(id: id, contract: .categoryBEligible)
            default:
                target(
                    id: id,
                    contract: .categoryAEligible,
                    references: references(summaries: 1)
                )
            }
        }
        let snapshot = snapshotEvidence(
            targets: targets,
            sourceLayoutIdentifier:
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v152SourceLayoutIdentifier,
            desktopSchemaVersion: 34
        )

        let inventory = try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: snapshot,
            officialInventory: officialInventory(runtimeVersion: "0.152.1"),
            exactObservations: ids.reversed().map {
                exactObservation(id: $0)
            }
        )

        XCTAssertEqual(inventory.observedCatalogItemCount, 148)
        XCTAssertEqual(inventory.confirmedGhostCount, 148)
        XCTAssertEqual(inventory.eligibleItemCount, 145)
        XCTAssertEqual(inventory.blockedItemCount, 3)
        XCTAssertEqual(inventory.ordinaryEligibleItemCount, 48)
        XCTAssertEqual(inventory.automationEligibleItemCount, 97)
        XCTAssertEqual(inventory.items.map(\.threadID), ids)
        XCTAssertFalse(inventory.repairPreviewAuthority)
        XCTAssertFalse(inventory.repairMutationAuthority)
    }

    func testCurrentV153PairClassifiesExact148ItemsWithoutSilentShrink()
        throws
    {
        let ids = (1...148).map(canonicalID)
        let targets = ids.enumerated().map { offset, id in
            switch offset {
            case 0..<48:
                target(id: id, contract: .categoryAEligible)
            case 48..<145:
                target(id: id, contract: .categoryBEligible)
            default:
                target(
                    id: id,
                    contract: .categoryAEligible,
                    references: references(summaries: 1)
                )
            }
        }
        let snapshot = snapshotEvidence(
            targets: targets,
            sourceLayoutIdentifier:
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v153SourceLayoutIdentifier,
            desktopSchemaVersion: 34
        )

        let inventory = try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: snapshot,
            officialInventory: officialInventory(runtimeVersion: "0.153.2"),
            exactObservations: ids.reversed().map {
                exactObservation(id: $0)
            }
        )

        XCTAssertEqual(inventory.observedCatalogItemCount, 148)
        XCTAssertEqual(inventory.confirmedGhostCount, 148)
        XCTAssertEqual(inventory.eligibleItemCount, 145)
        XCTAssertEqual(inventory.blockedItemCount, 3)
        XCTAssertEqual(inventory.ordinaryEligibleItemCount, 48)
        XCTAssertEqual(inventory.automationEligibleItemCount, 97)
        XCTAssertEqual(inventory.items.map(\.threadID), ids)
        XCTAssertFalse(inventory.repairPreviewAuthority)
        XCTAssertFalse(inventory.repairMutationAuthority)
    }

    func testCurrentV1534PairClassifiesExact148ItemsWithoutSilentShrink()
        throws
    {
        let ids = (1...148).map(canonicalID)
        let targets = ids.enumerated().map { offset, id in
            switch offset {
            case 0..<48:
                target(id: id, contract: .categoryAEligible)
            case 48..<145:
                target(id: id, contract: .categoryBEligible)
            default:
                target(
                    id: id,
                    contract: .categoryAEligible,
                    references: references(summaries: 1)
                )
            }
        }
        let snapshot = snapshotEvidence(
            targets: targets,
            sourceLayoutIdentifier:
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v1534SourceLayoutIdentifier,
            desktopSchemaVersion: 34
        )

        let inventory = try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: snapshot,
            officialInventory: officialInventory(runtimeVersion: "0.153.4"),
            exactObservations: ids.reversed().map {
                exactObservation(id: $0)
            }
        )

        XCTAssertEqual(inventory.observedCatalogItemCount, 148)
        XCTAssertEqual(inventory.confirmedGhostCount, 148)
        XCTAssertEqual(inventory.eligibleItemCount, 145)
        XCTAssertEqual(inventory.blockedItemCount, 3)
        XCTAssertEqual(inventory.ordinaryEligibleItemCount, 48)
        XCTAssertEqual(inventory.automationEligibleItemCount, 97)
        XCTAssertEqual(inventory.items.map(\.threadID), ids)
        XCTAssertFalse(inventory.repairPreviewAuthority)
        XCTAssertFalse(inventory.repairMutationAuthority)
    }

    func testRuntimeSourceAndSchemaCrossPairDriftFailClosed() {
        let id = canonicalID(1)
        let target = target(id: id, contract: .categoryAEligible)
        let v149 = snapshotEvidence(targets: [target])
        let v151 = snapshotEvidence(
            targets: [target],
            sourceLayoutIdentifier:
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v151SourceLayoutIdentifier,
            desktopSchemaVersion: 33
        )

        XCTAssertThrowsError(try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: v149,
            officialInventory: officialInventory(runtimeVersion: "0.151.0"),
            exactObservations: [exactObservation(id: id)]
        ))
        XCTAssertThrowsError(try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: v151,
            officialInventory: officialInventory(
                runtimeVersion: "codex-cli 0.149.0"
            ),
            exactObservations: [exactObservation(id: id)]
        ))
        XCTAssertThrowsError(try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: v151,
            officialInventory: officialInventory(runtimeVersion: "0.151.1"),
            exactObservations: [exactObservation(id: id)]
        ))

        let mismatchedSource = input(
            targets: [target],
            protections: [protection(id: id)],
            sourceLayoutIdentifier:
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v151SourceLayoutIdentifier,
            desktopSchemaVersion: 32
        )
        XCTAssertThrowsError(
            try CodexGhostRepairBulkInventoryBuilder.build(
                input: mismatchedSource
            )
        )
    }

    func testOfficialInventoryAboveBoundReturnsNoReducedInventory() {
        let id = canonicalID(20_000)
        let snapshot = snapshotEvidence(targets: [
            target(id: id, contract: .categoryAEligible),
        ])

        XCTAssertThrowsError(try CodexGhostRepairBulkInventoryComposer.compose(
            snapshot: snapshot,
            officialInventory: officialInventory(
                active: (1...10_001).map(canonicalID)
            ),
            exactObservations: [exactObservation(id: id)]
        ))
    }

    private func input(
        targets: [CodexGhostRepairSnapshotAnalysisTargetEvidence],
        protections: [CodexGhostRepairProtectionEvidence],
        sourceLayoutIdentifier: String =
            CodexGhostRepairSnapshotSourceLayout.identifier,
        desktopSchemaVersion: Int32 = 32
    ) -> CodexGhostRepairBulkInventoryInput {
        CodexGhostRepairBulkInventoryInput(
            snapshotReference: snapshotReference,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            sourceFingerprintHash: digest("source"),
            manifestHash: digest("manifest"),
            databases: databaseEvidence(
                desktopVersion: desktopSchemaVersion
            ),
            targets: targets,
            protectionEvidence: protections,
            authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence(
                catalogRevision: 2_235,
                observationSequence: 3_920,
                watermarkUpdatedAt: 1_777_777_777,
                metadataRowDigest: digest("metadata"),
                localSyncRowDigest: digest("local-sync")
            )
        )
    }

    private func snapshotEvidence(
        targets: [CodexGhostRepairSnapshotAnalysisTargetEvidence],
        sourceLayoutIdentifier: String =
            CodexGhostRepairSnapshotSourceLayout.identifier,
        desktopSchemaVersion: Int32 = 32
    ) -> CodexGhostRepairBulkInventorySnapshotEvidence {
        let source = input(
            targets: targets,
            protections: targets.map { protection(id: $0.threadID) },
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            desktopSchemaVersion: desktopSchemaVersion
        )
        return .init(
            snapshotReference: source.snapshotReference,
            sourceLayoutIdentifier: source.sourceLayoutIdentifier,
            sourceFingerprintHash: source.sourceFingerprintHash,
            manifestHash: source.manifestHash,
            readback: .init(
                databases: source.databases,
                targets: source.targets,
                authority: source.authority,
                sourceFingerprintHash: source.sourceFingerprintHash
            )
        )
    }

    private func officialInventory(
        runtimeVersion: String = "codex-cli 0.149.0",
        complete: Bool = true,
        active: [String] = [],
        archived: [String] = []
    ) -> CodexGhostRepairBulkOfficialInventoryEvidence {
        .init(
            runtimeVersion: runtimeVersion,
            complete: complete,
            activeThreadIDs: active,
            archivedThreadIDs: archived
        )
    }

    private func exactObservation(
        id: String,
        exactReadNotLoaded: Bool = true,
        exactReadErrorCode: Int = -32600,
        pinned: Bool = false,
        descendantCount: Int = 0,
        exactReadPresent: Bool = false
    ) -> CodexGhostRepairBulkExactObservation {
        .init(
            threadID: id,
            exactReadNotLoaded: exactReadNotLoaded,
            exactReadErrorCode: exactReadErrorCode,
            pinned: pinned,
            descendantCount: descendantCount,
            exactReadPresent: exactReadPresent
        )
    }

    private func databaseEvidence(
        desktopVersion: Int32
    ) -> [CodexGhostRepairSnapshotAnalysisDatabaseEvidence] {
        [
            .init(
                database: .desktop,
                schemaVersion: desktopVersion,
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

    private func target(
        id: String,
        contract: CodexGhostRepairSnapshotAnalysisRowContract,
        references: CodexGhostRepairSnapshotAnalysisReferenceCounts? = nil
    ) -> CodexGhostRepairSnapshotAnalysisTargetEvidence {
        CodexGhostRepairSnapshotAnalysisTargetEvidence(
            threadID: id,
            catalogRowDigests: [digest("catalog-\(id)")],
            automationRunRowDigests: contract == .categoryBEligible
                ? [digest("run-\(id)")] : [],
            automationDefinitionRowDigests: contract == .categoryBEligible
                ? [digest("definition-\(id)")] : [],
            references: references ?? self.references(),
            rowContract: contract
        )
    }

    private func references(
        inbox: Int = 0,
        timeline: Int = 0,
        summaries: Int = 0,
        canonicalState: Int = 0,
        threadTurns: Int = 0,
        threadItems: Int = 0,
        historyProjection: Int = 0
    ) -> CodexGhostRepairSnapshotAnalysisReferenceCounts {
        .init(
            inbox: inbox,
            timeline: timeline,
            summaries: summaries,
            canonicalState: canonicalState,
            threadTurns: threadTurns,
            threadItems: threadItems,
            historyProjection: historyProjection
        )
    }

    private func protection(
        id: String,
        inventoryComplete: Bool = true,
        activeInventoryPresent: Bool = false,
        archivedInventoryPresent: Bool = false,
        exactReadNotLoaded: Bool = true,
        exactReadErrorCode: Int = -32600,
        pinned: Bool = false,
        descendantCount: Int = 0
    ) -> CodexGhostRepairProtectionEvidence {
        .init(
            threadID: id,
            inventoryComplete: inventoryComplete,
            activeInventoryPresent: activeInventoryPresent,
            archivedInventoryPresent: archivedInventoryPresent,
            exactReadNotLoaded: exactReadNotLoaded,
            exactReadErrorCode: exactReadErrorCode,
            pinned: pinned,
            descendantCount: descendantCount
        )
    }

    private func canonicalID(_ value: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", value)
    }

    private func digest(_ seed: String) -> String {
        try! CodexGhostRepairHasher.hash(seed)
    }
}
