@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairSnapshotDryRunPlannerTests: XCTestCase {
    private let previewID = UUID(
        uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!
    private let targetA = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let targetB = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"

    func testCategoryATwoItemPreviewIsDeterministicAndAuthorityFree() throws {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let readback = makeReadback(
            identity: identity,
            categories: [.ordinary, .ordinary]
        )
        let protection = [targetA, targetB].map {
            makeProtection($0)
        }

        let first = plan(
            identity: identity,
            readback: readback,
            protection: protection
        )
        let second = plan(
            identity: identity,
            readback: readback,
            protection: Array(protection.reversed())
        )

        guard case let .preview(preview) = first else {
            return XCTFail("Expected Category A dry-run Preview")
        }
        XCTAssertEqual(first, second)
        XCTAssertEqual(preview.category, .ordinary)
        XCTAssertEqual(preview.targetThreadIDs, [targetA, targetB])
        XCTAssertEqual(preview.items.count, 2)
        XCTAssertTrue(preview.items.allSatisfy {
            $0.expectedLogicalEffects.map(\.kind) == [.removeCatalogRow]
        })
        XCTAssertEqual(
            preview.expectedBatchEffects,
            [
                .init(kind: .incrementCatalogRevision, amount: 2),
                .init(kind: .incrementObservationSequence, amount: 2),
            ]
        )
        XCTAssertEqual(
            preview.liveCapability,
            .requiresMilestone3FreshAuthority
        )
        XCTAssertEqual(preview.expiresAtMilliseconds, 901_000)
        XCTAssertTrue(preview.operationalAudit.isClear)
        XCTAssertTrue(preview.previewDigest.hasPrefix("sha256:"))
        XCTAssertTrue(preview.dryRunToken.hasPrefix("GHOST-DRY-RUN-"))
        XCTAssertTrue(preview.allOrNothing)
        XCTAssertFalse(preview.silentSelectionShrinkAllowed)
        XCTAssertFalse(preview.exposesPrivateRowValues)
        XCTAssertFalse(preview.persistsPreview)
        XCTAssertFalse(preview.readsLiveCodexDatabase)
        XCTAssertFalse(preview.writesCodexDatabase)
        XCTAssertFalse(preview.confirmationAuthority)
        XCTAssertFalse(preview.repairMutationAuthority)
    }

    func testCategoryBOneItemShowsAnalysisButLiveCapabilityIsUnavailable()
        throws
    {
        let identity = try makeIdentity(targets: [targetA])
        let outcome = plan(
            identity: identity,
            readback: makeReadback(
                identity: identity,
                categories: [.automation]
            ),
            protection: [makeProtection(targetA)]
        )

        guard case let .preview(preview) = outcome else {
            return XCTFail("Expected Category B analysis Preview")
        }
        XCTAssertEqual(preview.category, .automation)
        XCTAssertEqual(
            preview.items[0].expectedLogicalEffects.map(\.kind),
            [.removeCatalogRow, .archiveAutomationRun]
        )
        XCTAssertEqual(
            preview.liveCapability,
            .unavailableCategoryBContinuity
        )
        XCTAssertFalse(preview.confirmationAuthority)
        XCTAssertFalse(preview.repairMutationAuthority)
    }

    func testCategoryAAndBAcceptExactOneAndTwoItemShapes() throws {
        for category in [
            CodexGhostRepairCategory.ordinary,
            .automation,
        ] {
            for targets in [[targetA], [targetA, targetB]] {
                let identity = try makeIdentity(targets: targets)
                let outcome = plan(
                    identity: identity,
                    readback: makeReadback(
                        identity: identity,
                        categories: Array(
                            repeating: category,
                            count: targets.count
                        )
                    ),
                    protection: targets.map { makeProtection($0) }
                )
                guard case let .preview(preview) = outcome else {
                    return XCTFail(
                        "Expected exact \(category.rawValue)-\(targets.count) Preview"
                    )
                }
                XCTAssertEqual(preview.category, category)
                XCTAssertEqual(preview.targetThreadIDs, targets)
                XCTAssertEqual(preview.items.count, targets.count)
            }
        }
    }

    func testMixedCategoriesBlockWholeSelection() throws {
        let identity = try makeIdentity(targets: [targetA, targetB])

        assertBlocked(
            plan(
                identity: identity,
                readback: makeReadback(
                    identity: identity,
                    categories: [.ordinary, .automation]
                ),
                protection: [targetA, targetB].map {
                    makeProtection($0)
                }
            ),
            code: .mixedCategory
        )
    }

    func testSnapshotIdentityDriftBlocksBeforePlanning() throws {
        let identity = try makeIdentity(targets: [targetA])
        let otherIdentity = try makeIdentity(
            snapshotID: UUID(
                uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
            )!,
            targets: [targetA]
        )

        assertBlocked(
            plan(
                identity: identity,
                readback: makeReadback(
                    identity: otherIdentity,
                    categories: [.ordinary]
                ),
                protection: [makeProtection(targetA)]
            ),
            code: .snapshotEvidenceDrift
        )
    }

    func testSchemaOrHealthDriftBlocksWholeSelection() throws {
        let identity = try makeIdentity(targets: [targetA])
        var databases = makeDatabases()
        databases[0] = .init(
            database: .desktop,
            schemaVersion: 31,
            integrityCheckPassed: true,
            foreignKeyViolationCount: 0
        )

        assertBlocked(
            plan(
                identity: identity,
                readback: makeReadback(
                    identity: identity,
                    categories: [.ordinary],
                    databases: databases
                ),
                protection: [makeProtection(targetA)]
            ),
            code: .invalidDatabaseContract
        )
    }

    func testUnexpectedSideReferenceBlocksExactTarget() throws {
        let identity = try makeIdentity(targets: [targetA])
        let references = CodexGhostRepairSnapshotAnalysisReferenceCounts(
            inbox: 1,
            timeline: 0,
            summaries: 0,
            canonicalState: 0,
            threadTurns: 0,
            threadItems: 0,
            historyProjection: 0
        )

        assertBlocked(
            plan(
                identity: identity,
                readback: makeReadback(
                    identity: identity,
                    categories: [.ordinary],
                    references: references
                ),
                protection: [makeProtection(targetA)]
            ),
            code: .unexpectedSideReference,
            threadID: targetA
        )
    }

    func testMissingOrIneligibleProtectionEvidenceBlocksWithoutShrink()
        throws
    {
        let identity = try makeIdentity(targets: [targetA, targetB])
        let readback = makeReadback(
            identity: identity,
            categories: [.ordinary, .ordinary]
        )

        assertBlocked(
            plan(
                identity: identity,
                readback: readback,
                protection: [makeProtection(targetA)]
            ),
            code: .invalidProtectionEvidence
        )
        assertBlocked(
            plan(
                identity: identity,
                readback: readback,
                protection: [
                    makeProtection(targetA),
                    makeProtection(targetB, pinned: true),
                ]
            ),
            code: .invalidProtectionEvidence,
            threadID: targetB
        )
    }

    func testInvalidRowMultiplicityAndLifetimeFailClosed() throws {
        let identity = try makeIdentity(targets: [targetA])
        var readback = makeReadback(
            identity: identity,
            categories: [.ordinary]
        )
        readback = .init(
            identity: readback.identity,
            sourceLayoutIdentifier: readback.sourceLayoutIdentifier,
            databases: readback.databases,
            targets: [
                .init(
                    threadID: targetA,
                    catalogRowDigests: [digest("a"), digest("b")],
                    automationRunRowDigests: [],
                    automationDefinitionRowDigests: [],
                    references: zeroReferences(),
                    rowContract: .categoryAEligible
                ),
            ],
            authority: readback.authority
        )
        assertBlocked(
            plan(
                identity: identity,
                readback: readback,
                protection: [makeProtection(targetA)]
            ),
            code: .invalidTargetEvidence,
            threadID: targetA
        )

        assertBlocked(
            CodexGhostRepairSnapshotDryRunPlanner.plan(
                identity: identity,
                snapshotEvidence: makeReadback(
                    identity: identity,
                    categories: [.ordinary]
                ),
                protectionEvidence: [makeProtection(targetA)],
                experimentalAbsenceEvidence: [
                    makeExperimental(targetA),
                ],
                operationalAudit: clearGate(),
                previewID: previewID,
                generatedAtMilliseconds: 1_000,
                lifetimeMilliseconds: 0
            ),
            code: .invalidPreviewLifetime
        )
    }

    func testCapabilitiesExposeNoIOPersistenceOrRepairAuthority() {
        let capabilities = CodexGhostRepairSnapshotDryRunPlanner.capabilities

        XCTAssertTrue(capabilities.pureDeterministicPlanningAvailable)
        XCTAssertFalse(capabilities.acceptsCallerPath)
        XCTAssertFalse(capabilities.opensSQLite)
        XCTAssertFalse(capabilities.readsLiveCodexDatabase)
        XCTAssertFalse(capabilities.writesFilesystem)
        XCTAssertFalse(capabilities.persistsPreview)
        XCTAssertFalse(capabilities.automaticPlanning)
        XCTAssertFalse(capabilities.automaticRetry)
        XCTAssertFalse(capabilities.confirmationAuthority)
        XCTAssertFalse(capabilities.repairMutationAuthority)
    }

    func testUnsupportedPrivacySafeRowContractBlocksPlanning() throws {
        let identity = try makeIdentity(targets: [targetA])
        let readback = makeReadback(
            identity: identity,
            categories: [.ordinary]
        )
        let target = readback.targets[0]
        let unsupported = CodexGhostRepairSnapshotAnalysisReadback(
            identity: readback.identity,
            sourceLayoutIdentifier: readback.sourceLayoutIdentifier,
            databases: readback.databases,
            targets: [
                .init(
                    threadID: target.threadID,
                    catalogRowDigests: target.catalogRowDigests,
                    automationRunRowDigests: target.automationRunRowDigests,
                    automationDefinitionRowDigests:
                        target.automationDefinitionRowDigests,
                    references: target.references,
                    rowContract: .unsupported
                ),
            ],
            authority: readback.authority
        )

        assertBlocked(
            plan(
                identity: identity,
                readback: unsupported,
                protection: [makeProtection(targetA)]
            ),
            code: .invalidTargetEvidence,
            threadID: targetA
        )
    }

    private func plan(
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        readback: CodexGhostRepairSnapshotAnalysisReadback,
        protection: [CodexGhostRepairProtectionEvidence]
    ) -> CodexGhostRepairSnapshotDryRunPlanningOutcome {
        CodexGhostRepairSnapshotDryRunPlanner.plan(
            identity: identity,
            snapshotEvidence: readback,
            protectionEvidence: protection,
            experimentalAbsenceEvidence: protection.map {
                makeExperimental($0.threadID)
            },
            operationalAudit: clearGate(),
            previewID: previewID,
            generatedAtMilliseconds: 1_000,
            lifetimeMilliseconds: 900_000
        )
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
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        categories: [CodexGhostRepairCategory],
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]? = nil,
        references: CodexGhostRepairSnapshotAnalysisReferenceCounts? = nil
    ) -> CodexGhostRepairSnapshotAnalysisReadback {
        let targets = zip(identity.targetThreadIDs, categories).map {
            threadID, category in
            CodexGhostRepairSnapshotAnalysisTargetEvidence(
                threadID: threadID,
                catalogRowDigests: [digest("a")],
                automationRunRowDigests:
                    category == .automation ? [digest("b")] : [],
                automationDefinitionRowDigests:
                    category == .automation ? [digest("c")] : [],
                references: references ?? zeroReferences(),
                rowContract: category == .ordinary
                    ? .categoryAEligible
                    : .categoryBEligible
            )
        }
        return .init(
            identity: identity,
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: databases ?? makeDatabases(),
            targets: targets,
            authority: .init(
                catalogRevision: 10,
                observationSequence: 20,
                watermarkUpdatedAt: 30,
                metadataRowDigest: digest("d"),
                localSyncRowDigest: digest("e")
            )
        )
    }

    private func makeDatabases()
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

    private func makeProtection(
        _ threadID: String,
        pinned: Bool = false
    ) -> CodexGhostRepairProtectionEvidence {
        .init(
            threadID: threadID,
            inventoryComplete: true,
            activeInventoryPresent: false,
            archivedInventoryPresent: false,
            exactReadNotLoaded: true,
            exactReadErrorCode: -32600,
            pinned: pinned,
            descendantCount: 0
        )
    }

    private func makeExperimental(
        _ threadID: String
    ) -> CodexGhostRepairExperimentalAbsenceEvidence {
        .init(
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
            databases: [
                .init(database: .desktop, schemaVersion: 32),
                .init(database: .summaries, schemaVersion: 2),
                .init(database: .state, schemaVersion: 0),
                .init(database: .threadHistory, schemaVersion: 0),
            ]
        )
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

    private func assertBlocked(
        _ outcome: CodexGhostRepairSnapshotDryRunPlanningOutcome,
        code: CodexGhostRepairSnapshotDryRunBlockerCode,
        threadID: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .blocked(blockers) = outcome else {
            return XCTFail("Expected blocked dry-run planning", file: file, line: line)
        }
        XCTAssertEqual(
            blockers,
            [.init(code: code, threadID: threadID)],
            file: file,
            line: line
        )
    }
}
