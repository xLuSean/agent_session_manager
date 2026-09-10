@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairCategoryAProductionReviewMaterialCollectorTests:
    XCTestCase
{
    private let fixture = M3eCategoryATestFixture()

    func testExactFreshDatabaseAndProtectionProduceReviewMaterial()
        async throws
    {
        let draft = try fixture.draft()
        let database = M3iDatabaseReader(outcome: .read(.init(
            result: result(draft: draft),
            operationalGate: clearGate()
        )))
        let protection = M3iProtectionReader(outcome: .read(.init(
            protectionEvidenceHash: fixture.digest("6"),
            protectionComplete: true,
            operationalGateEvidenceHash: fixture.digest("7"),
            operationalGateClear: true,
            runtimeVersion: "0.149.0"
        )))
        let collector = makeCollector(
            database: database,
            protection: protection
        )

        let outcome = await collector.collect(draft: draft)

        guard case let .material(material) = outcome else {
            return XCTFail("Expected fresh production review material")
        }
        XCTAssertEqual(material.review.items.map(\.threadID), draft.targetThreadIDs)
        XCTAssertEqual(
            material.review.items.map(\.catalogRowDigest),
            draft.itemChanges.map(\.catalogRowDigest)
        )
        XCTAssertEqual(material.review.databaseExpectations, draft.databaseExpectations)
        XCTAssertEqual(material.review.authorityAudit.catalogRevision, 1_000)
        XCTAssertTrue(material.review.protectionComplete)
        XCTAssertTrue(material.review.operationalGateClear)
        XCTAssertEqual(material.buildIdentifier, "m3i-tests")
        XCTAssertEqual(material.observedAtMilliseconds, 2_100)
    }

    func testCatalogOrSchemaDriftStopsBeforeProtectionRead() async throws {
        let draft = try fixture.draft()
        var changed = result(draft: draft)
        changed = .init(
            databases: changed.databases.map {
                $0.database == .desktop
                    ? .init(
                        database: .desktop,
                        schemaVersion: 33,
                        integrityCheckPassed: true,
                        foreignKeyViolationCount: 0
                    ) : $0
            },
            targets: changed.targets,
            authority: changed.authority,
            sourceFingerprintHash: changed.sourceFingerprintHash
        )
        let protection = M3iProtectionReader(outcome: .unavailable)
        let collector = makeCollector(
            database: M3iDatabaseReader(outcome: .read(.init(
                result: changed,
                operationalGate: clearGate()
            ))),
            protection: protection
        )

        let outcome = await collector.collect(draft: draft)

        guard case .blocked(.schemaDrift) = outcome else {
            return XCTFail("Expected schema drift blocker")
        }
        let protectionReads = await protection.readCount()
        XCTAssertEqual(protectionReads, 0)
    }

    func testWholeSourceFingerprintDriftStopsBeforeProtectionRead()
        async throws
    {
        let draft = try fixture.draft()
        let unchanged = result(draft: draft)
        let changed = CodexGhostRepairCanonicalQueryReadback(
            databases: unchanged.databases,
            targets: unchanged.targets,
            authority: unchanged.authority,
            sourceFingerprintHash: fixture.digest("9")
        )
        let protection = M3iProtectionReader(outcome: .unavailable)
        let collector = makeCollector(
            database: M3iDatabaseReader(outcome: .read(.init(
                result: changed,
                operationalGate: clearGate()
            ))),
            protection: protection
        )

        let outcome = await collector.collect(draft: draft)

        guard case .blocked(.targetDrift) = outcome else {
            return XCTFail("Expected whole-source drift blocker")
        }
        let protectionReads = await protection.readCount()
        XCTAssertEqual(protectionReads, 0)
    }

    func testBlockedDatabaseAndProtectionOutcomesStayDistinct() async throws {
        let draft = try fixture.draft()
        let databaseBlocked = makeCollector(
            database: M3iDatabaseReader(
                outcome: .blocked(.operatingConditionsBlocked)
            ),
            protection: M3iProtectionReader(outcome: .unavailable)
        )
        guard case .blocked(.operatingConditionsBlocked) =
                await databaseBlocked.collect(draft: draft) else {
            return XCTFail("Expected operating condition blocker")
        }

        let protectionBlocked = makeCollector(
            database: M3iDatabaseReader(outcome: .read(.init(
                result: result(draft: draft),
                operationalGate: clearGate()
            ))),
            protection: M3iProtectionReader(
                outcome: .blocked(.protectionUnavailable)
            )
        )
        guard case .blocked(.protectionUnavailable) =
                await protectionBlocked.collect(draft: draft) else {
            return XCTFail("Expected protection blocker")
        }
    }

    func testProductionFactoryConstructionPerformsNoRead() async {
        let collector = CodexGhostRepairCategoryAProductionReviewMaterialCollector
            .production()
        _ = collector
    }

    func testProductionProtectionReaderRequiresExactExperimentalEvidence()
        async throws
    {
        let draft = try fixture.draft()
        let control = "019f0000-0000-7000-8000-000000000001"
        let transport = M3iProtectionTransport(
            inventory: .init(
                provider: .codex,
                runtimeVersion: "0.149.0",
                inventoryComplete: true,
                activeThreadIDs: [control],
                archivedThreadIDs: [],
                pinnedThreadIDs: [],
                pinnedInventoryComplete: true,
                descendantNodes: [],
                descendantGraphComplete: true
            ),
            exact: [
                control: .present(returnedThreadID: control),
                fixture.targetA: .failure(
                    errorKind: .rpcError,
                    rpcCode: -32600,
                    responseShapeIdentifier: "rpc-error-code-message-v1",
                    message: "thread not loaded: \(fixture.targetA)"
                ),
                fixture.targetB: .failure(
                    errorKind: .rpcError,
                    rpcCode: -32600,
                    responseShapeIdentifier: "rpc-error-code-message-v1",
                    message: "thread not loaded: \(fixture.targetB)"
                ),
            ],
            gate: clearGate()
        )
        let reader = CodexGhostRepairCategoryAProductionProtectionReader(
            transport: transport,
            registry: .packagedReviewedV1()
        )

        let outcome = await reader.read(
            targetThreadIDs: draft.targetThreadIDs,
            databases: databaseEvidence()
        )

        guard case let .read(value) = outcome else {
            return XCTFail("Expected exact Experimental evidence")
        }
        XCTAssertTrue(value.protectionComplete)
        XCTAssertTrue(value.operationalGateClear)
        XCTAssertEqual(value.runtimeVersion, "0.149.0")
        XCTAssertTrue(value.protectionEvidenceHash.hasPrefix("sha256:"))
    }

    func testPinnedTargetFailsBeforeExactRead() async throws {
        let draft = try fixture.draft()
        let transport = M3iProtectionTransport(
            inventory: .init(
                provider: .codex,
                runtimeVersion: "0.149.0",
                inventoryComplete: true,
                activeThreadIDs: [
                    "019f0000-0000-7000-8000-000000000001"
                ],
                archivedThreadIDs: [],
                pinnedThreadIDs: [fixture.targetA],
                pinnedInventoryComplete: true,
                descendantNodes: [],
                descendantGraphComplete: true
            ),
            exact: [:],
            gate: clearGate()
        )
        let reader = CodexGhostRepairCategoryAProductionProtectionReader(
            transport: transport,
            registry: .packagedReviewedV1()
        )

        let outcome = await reader.read(
            targetThreadIDs: draft.targetThreadIDs,
            databases: databaseEvidence()
        )

        guard case .blocked(.targetDrift) = outcome else {
            return XCTFail("Expected pinned target drift")
        }
        let exactReads = await transport.exactReadCount()
        XCTAssertEqual(exactReads, 0)
    }

    private func makeCollector(
        database: M3iDatabaseReader,
        protection: M3iProtectionReader
    ) -> CodexGhostRepairCategoryAProductionReviewMaterialCollector {
        .init(
            databaseReader: database,
            protectionReader: protection,
            reviewID: {
                UUID(uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")!
            },
            nowMilliseconds: { 2_100 },
            buildIdentifier: { "m3i-tests" }
        )
    }

    private func result(
        draft: CodexGhostRepairCategoryAExecutionDraft
    ) -> CodexGhostRepairCanonicalQueryReadback {
        .init(
            databases: databaseEvidence(),
            targets: draft.itemChanges.map {
                .init(
                    threadID: $0.threadID,
                    catalogRowDigests: [$0.catalogRowDigest],
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
                catalogRevision: 1_000,
                observationSequence: 1_010,
                watermarkUpdatedAt: 1_020,
                metadataRowDigest: fixture.digest("d"),
                localSyncRowDigest: fixture.digest("e")
            ),
            sourceFingerprintHash: draft.snapshotSourceFingerprintHash
        )
    }

    private func databaseEvidence()
        -> [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    {
        [
            .init(database: .desktop, schemaVersion: 32,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
            .init(database: .summaries, schemaVersion: 2,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
            .init(database: .state, schemaVersion: 0,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
            .init(database: .threadHistory, schemaVersion: 0,
                  integrityCheckPassed: true, foreignKeyViolationCount: 0),
        ]
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
}

private actor M3iDatabaseReader:
    CodexGhostRepairCategoryAProductionDatabaseReviewReading
{
    let outcome: CodexGhostRepairCategoryAProductionDatabaseReviewOutcome
    init(outcome: CodexGhostRepairCategoryAProductionDatabaseReviewOutcome) {
        self.outcome = outcome
    }
    func read(targetThreadIDs _: [String]) async
        -> CodexGhostRepairCategoryAProductionDatabaseReviewOutcome
    { outcome }
}

private actor M3iProtectionReader:
    CodexGhostRepairCategoryAProductionProtectionReading
{
    let outcome: CodexGhostRepairCategoryAProductionProtectionOutcome
    private var reads = 0
    init(outcome: CodexGhostRepairCategoryAProductionProtectionOutcome) {
        self.outcome = outcome
    }
    func read(
        targetThreadIDs _: [String],
        databases _: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    ) async -> CodexGhostRepairCategoryAProductionProtectionOutcome {
        reads += 1
        return outcome
    }
    func readCount() -> Int { reads }
}

private actor M3iProtectionTransport:
    CodexGhostRepairExperimentalObservationTransport
{
    let inventoryValue: CodexGhostRepairExperimentalTransportInventory
    let exact: [String: CodexGhostRepairExperimentalTransportExactReadOutcome]
    let gate: CodexGhostRepairExecutionGate
    private var exactReads = 0

    init(
        inventory: CodexGhostRepairExperimentalTransportInventory,
        exact: [String: CodexGhostRepairExperimentalTransportExactReadOutcome],
        gate: CodexGhostRepairExecutionGate
    ) {
        inventoryValue = inventory
        self.exact = exact
        self.gate = gate
    }

    func inventory() async throws
        -> CodexGhostRepairExperimentalTransportInventory
    { inventoryValue }

    func exactRead(threadID: String) async throws
        -> CodexGhostRepairExperimentalTransportExactReadOutcome
    {
        exactReads += 1
        guard let value = exact[threadID] else { throw M3iError.unavailable }
        return value
    }

    func operationalAudit() async throws -> CodexGhostRepairExecutionGate {
        gate
    }

    func exactReadCount() -> Int { exactReads }
}

private enum M3iError: Error { case unavailable }
