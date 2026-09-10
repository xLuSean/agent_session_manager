@testable import AgentSessionManagerCore
import Foundation
import XCTest

#if AGENT_SESSION_MANAGER_RESEARCH

final class CodexGhostRepairBulkMaintenanceCollectorTests: XCTestCase {
    func testExact148BeforeAfterWindowMatchesSameBundle() async throws {
        let resolution = try makeResolution(
            ordinary: 48,
            automation: 97,
            blocked: 3
        )
        let observer = MaintenanceObserver([
            observation(at: 2_000),
            observation(at: 3_000),
        ])
        let collector = try CodexGhostRepairBulkFreshMaintenanceCollector(
            resolution: resolution,
            observer: observer,
            collectionID: {
                UUID(uuidString: "99999999-0000-4000-8000-000000000001")!
            }
        )

        let before = try await collector.collectFresh(
            phase: .beforeBackup
        )
        let after = try await collector.collectFresh(
            phase: .afterBackup
        )
        let window = try CodexGhostRepairBulkMaintenanceWindow(
            before: before,
            after: after
        )

        XCTAssertEqual(before.bundleDigest, resolution.bundleDigest)
        XCTAssertEqual(before.selectedCount, 145)
        XCTAssertEqual(before.ordinaryCount, 48)
        XCTAssertEqual(before.automationCount, 97)
        XCTAssertEqual(before.blockedOutsideBatchCount, 3)
        XCTAssertEqual(before.databaseContracts.count, 5)
        XCTAssertEqual(after.bundleDigest, resolution.bundleDigest)
        XCTAssertEqual(window.bundleDigest, resolution.bundleDigest)
        XCTAssertFalse(window.driftDetected)
        XCTAssertFalse(window.createsBackup)
        XCTAssertFalse(window.createsClaim)
        XCTAssertFalse(window.repairMutationAuthority)
        let observedPhases = await observer.phases()
        let observedCallCount = await observer.callCount()
        XCTAssertEqual(observedPhases, [.beforeBackup, .afterBackup])
        XCTAssertEqual(observedCallCount, 2)

        let capabilities = collector.capabilities
        XCTAssertEqual(capabilities.maximumTargetCount, 500)
        XCTAssertTrue(capabilities.exactBundleRequired)
        XCTAssertTrue(capabilities.freshObservationPerCall)
        XCTAssertTrue(capabilities.processEvidenceRequired)
        XCTAssertTrue(capabilities.fiveDatabaseHandleOwnerEvidenceRequired)
        XCTAssertTrue(capabilities.beforeAfterDriftRejected)
        XCTAssertFalse(capabilities.acceptsCallerPath)
        XCTAssertFalse(capabilities.acceptsLiveCodexRoot)
        XCTAssertFalse(capabilities.createsBackup)
        XCTAssertFalse(capabilities.createsClaim)
        XCTAssertFalse(capabilities.opensSQLite)
        XCTAssertFalse(capabilities.appWiringAvailable)
        XCTAssertFalse(capabilities.automaticRetryAllowed)
        XCTAssertFalse(capabilities.repairMutationAuthority)
    }

    func testEveryCallCollectsFreshInsteadOfCachingGreen() async throws {
        let resolution = try makeResolution(
            ordinary: 2,
            automation: 1,
            blocked: 0
        )
        let observer = MaintenanceObserver([
            observation(at: 10),
            observation(at: 11),
        ])
        let collector = try CodexGhostRepairBulkFreshMaintenanceCollector(
            resolution: resolution,
            observer: observer
        )

        let first = try await collector.collectFresh(phase: .beforeBackup)
        let second = try await collector.collectFresh(phase: .beforeBackup)

        XCTAssertNotEqual(first.readbackDigest, second.readbackDigest)
        XCTAssertEqual(first.maintenance.observedAtMilliseconds, 10)
        XCTAssertEqual(second.maintenance.observedAtMilliseconds, 11)
        let observedCallCount = await observer.callCount()
        XCTAssertEqual(observedCallCount, 2)
    }

    func testRepeatBeforeBackupWindowKeepsStableDestinationIdentity()
        async throws
    {
        let resolution = try makeResolution(
            ordinary: 2,
            automation: 1,
            blocked: 0
        )
        let firstWindow = try CodexGhostRepairBulkMaintenanceWindow(
            before: .init(
                collectionID: UUID(),
                phase: .beforeBackup,
                resolution: resolution,
                maintenance: .init(
                    runtimeVersion: "0.149.0",
                    executionGate: gate(),
                    sourceFingerprintHash: hash(600),
                    authorityDigest: hash(601),
                    observedAtMilliseconds: 10
                )
            ),
            after: .init(
                collectionID: UUID(),
                phase: .beforeBackupRepeat,
                resolution: resolution,
                maintenance: .init(
                    runtimeVersion: "0.149.0",
                    executionGate: gate(),
                    sourceFingerprintHash: hash(600),
                    authorityDigest: hash(601),
                    observedAtMilliseconds: 11
                )
            )
        )
        let coldRestartWindow = try CodexGhostRepairBulkMaintenanceWindow(
            before: .init(
                collectionID: UUID(),
                phase: .beforeBackup,
                resolution: resolution,
                maintenance: .init(
                    runtimeVersion: "0.149.0",
                    executionGate: gate(),
                    sourceFingerprintHash: hash(600),
                    authorityDigest: hash(601),
                    observedAtMilliseconds: 20
                )
            ),
            after: .init(
                collectionID: UUID(),
                phase: .beforeBackupRepeat,
                resolution: resolution,
                maintenance: .init(
                    runtimeVersion: "0.149.0",
                    executionGate: gate(),
                    sourceFingerprintHash: hash(600),
                    authorityDigest: hash(601),
                    observedAtMilliseconds: 21
                )
            )
        )

        XCTAssertEqual(firstWindow.windowDigest, coldRestartWindow.windowDigest)
        XCTAssertNotEqual(
            firstWindow.before.readbackDigest,
            coldRestartWindow.before.readbackDigest
        )
        XCTAssertNotEqual(
            firstWindow.after.readbackDigest,
            coldRestartWindow.after.readbackDigest
        )
    }

    func testAnyOfFiveOpenHandleCountsStopsCollection() async throws {
        let resolution = try makeResolution(
            ordinary: 1,
            automation: 1,
            blocked: 0
        )
        let blockedGates = [
            gate(desktop: 1),
            gate(summaries: 1),
            gate(history: 1),
            gate(state: 1),
            gate(threadHistory: 1),
        ]

        for blockedGate in blockedGates {
            let observer = MaintenanceObserver([
                observation(at: 10, gate: blockedGate),
            ])
            let collector = try CodexGhostRepairBulkFreshMaintenanceCollector(
                resolution: resolution,
                observer: observer
            )
            await XCTAssertThrowsErrorAsync(
                try await collector.collectFresh(phase: .beforeBackup)
            )
            let observedCallCount = await observer.callCount()
            XCTAssertEqual(observedCallCount, 1)
        }
    }

    func testMissingProcessOwnerOrNewDatabaseCountsFailsClosed() async throws {
        let resolution = try makeResolution(
            ordinary: 1,
            automation: 0,
            blocked: 0
        )
        let incomplete = [
            gate(processEvidence: nil),
            gate(ownerEvidence: nil),
            gate(state: nil),
            gate(threadHistory: nil),
        ]

        for item in incomplete {
            let collector = try CodexGhostRepairBulkFreshMaintenanceCollector(
                resolution: resolution,
                observer: MaintenanceObserver([
                    observation(at: 10, gate: item),
                ])
            )
            await XCTAssertThrowsErrorAsync(
                try await collector.collectFresh(phase: .beforeBackup)
            )
        }
    }

    func testBeforeAfterFingerprintAuthorityAndRuntimeDriftAreRejected()
        async throws
    {
        let resolution = try makeResolution(
            ordinary: 2,
            automation: 2,
            blocked: 1
        )
        let cases: [(
            CodexGhostRepairBulkFreshMaintenanceObservation,
            CodexGhostRepairBulkFreshMaintenanceObservation
        )] = [
            (
                observation(at: 10, fingerprint: hash(1)),
                observation(at: 11, fingerprint: hash(2))
            ),
            (
                observation(at: 10, authority: hash(3)),
                observation(at: 11, authority: hash(4))
            ),
            (
                observation(at: 10, runtime: "0.149.0"),
                observation(at: 11, runtime: "codex-cli 0.149.0")
            ),
        ]

        for observations in cases {
            let collector = try CodexGhostRepairBulkFreshMaintenanceCollector(
                resolution: resolution,
                observer: MaintenanceObserver([
                    observations.0,
                    observations.1,
                ])
            )
            let before = try await collector.collectFresh(
                phase: .beforeBackup
            )
            let after = try await collector.collectFresh(
                phase: .afterBackup
            )
            XCTAssertThrowsError(
                try CodexGhostRepairBulkMaintenanceWindow(
                    before: before,
                    after: after
                )
            )
        }
    }

    func testBlockedObservationIsNotRetriedAutomatically() async throws {
        let resolution = try makeResolution(
            ordinary: 1,
            automation: 1,
            blocked: 0
        )
        let observer = MaintenanceObserver([
            observation(at: 10, gate: gate(desktop: 1)),
            observation(at: 11),
        ])
        let collector = try CodexGhostRepairBulkFreshMaintenanceCollector(
            resolution: resolution,
            observer: observer
        )

        await XCTAssertThrowsErrorAsync(
            try await collector.collectFresh(phase: .beforeBackup)
        )
        let observedCallCount = await observer.callCount()
        XCTAssertEqual(observedCallCount, 1)
    }

    private func makeResolution(
        ordinary: Int,
        automation: Int,
        blocked: Int
    ) throws -> CodexGhostRepairBulkProductionBundle.Resolution {
        let inventory = try makeInventory(
            ordinary: ordinary,
            automation: automation,
            blocked: blocked
        )
        let preview = try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: inventory.eligibleThreadIDs,
            previewID: UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!,
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 901_000
        )
        let requestID = UUID(
            uuidString: "11111111-2222-4333-8444-555555555555"
        )!
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: true
        )
        let databaseURL = storeRoot.appendingPathComponent("manager.sqlite3")
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            inventory: inventory
        )
        store.close()
        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        let stored = try XCTUnwrap(
            reopened.codexGhostRepairBulkPreview(requestID: requestID)
        )
        reopened.close()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try CodexGhostRepairBulkProductionBundle(
            coldReadback: stored,
            testOwnedCodexHomeURL: parent.appendingPathComponent(
                "codex-home",
                isDirectory: true
            ),
            testOwnedAllowedParentURL: parent
        ).resolveForTestOwnedAdoption()
    }

    private func makeInventory(
        ordinary: Int,
        automation: Int,
        blocked: Int
    ) throws -> CodexGhostRepairBulkInventory {
        let identifiers = (1...(ordinary + automation + blocked)).map {
            String(
                format: "00000000-0000-4000-8000-%012llx",
                Int64($0)
            )
        }
        let targets = identifiers.enumerated().map { index, threadID in
            let isAutomation = index >= ordinary
                && index < ordinary + automation
            return CodexGhostRepairSnapshotAnalysisTargetEvidence(
                threadID: threadID,
                catalogRowDigests: [hash(index + 100)],
                automationRunRowDigests: isAutomation
                    ? [hash(index + 200)] : [],
                automationStableFieldsDigests: isAutomation
                    ? [hash(index + 300)] : [],
                automationDefinitionRowDigests: isAutomation
                    ? [hash(index + 400)] : [],
                references: .init(
                    inbox: 0,
                    timeline: 0,
                    summaries: 0,
                    canonicalState: 0,
                    threadTurns: 0,
                    threadItems: 0,
                    historyProjection: 0
                ),
                rowContract: isAutomation
                    ? .categoryBEligible : .categoryAEligible
            )
        }
        let protections = identifiers.enumerated().map { index, threadID in
            CodexGhostRepairProtectionEvidence(
                threadID: threadID,
                inventoryComplete: true,
                activeInventoryPresent: false,
                archivedInventoryPresent: false,
                exactReadNotLoaded: true,
                exactReadErrorCode: -32600,
                pinned: index >= ordinary + automation,
                descendantCount: 0
            )
        }
        return try CodexGhostRepairBulkInventoryBuilder.build(input: .init(
            snapshotReference: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790",
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            sourceFingerprintHash: hash(500),
            manifestHash: hash(501),
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
            targets: targets,
            protectionEvidence: protections,
            authority: .init(
                catalogRevision: 10,
                observationSequence: 20,
                watermarkUpdatedAt: 30,
                metadataRowDigest: hash(502),
                localSyncRowDigest: hash(503)
            )
        ))
    }

    private func observation(
        at timestamp: Int64,
        gate: CodexGhostRepairExecutionGate? = nil,
        runtime: String = "0.149.0",
        fingerprint: String? = nil,
        authority: String? = nil
    ) -> CodexGhostRepairBulkFreshMaintenanceObservation {
        .init(
            runtimeVersion: runtime,
            executionGate: gate ?? self.gate(),
            sourceFingerprintHash: fingerprint ?? hash(600),
            authorityDigest: authority ?? hash(601),
            observedAtMilliseconds: timestamp
        )
    }

    private func gate(
        desktop: Int = 0,
        summaries: Int = 0,
        history: Int = 0,
        state: Int? = 0,
        threadHistory: Int? = 0,
        processEvidence: [CodexGhostRepairDesktopProcessEvidence]? = [],
        ownerEvidence: [CodexGhostRepairOpenHandleOwnerEvidence]? = []
    ) -> CodexGhostRepairExecutionGate {
        .init(
            codexFullyExited: true,
            desktopOpenHandleCount: desktop,
            summariesOpenHandleCount: summaries,
            historyOpenHandleCount: history,
            stateOpenHandleCount: state,
            threadHistoryOpenHandleCount: threadHistory,
            capacitySufficient: true,
            desktopProcessEvidence: processEvidence,
            openHandleOwnerEvidence: ownerEvidence
        )
    }

    private func hash(_ value: Int) -> String {
        String(format: "sha256:%064llx", Int64(value))
    }
}

private actor MaintenanceObserver:
    CodexGhostRepairBulkFreshMaintenanceObserving
{
    private var observations:
        [CodexGhostRepairBulkFreshMaintenanceObservation]
    private var observedPhases:
        [CodexGhostRepairBulkMaintenanceCollectionPhase] = []

    init(_ observations: [CodexGhostRepairBulkFreshMaintenanceObservation]) {
        self.observations = observations
    }

    func observeFreshMaintenance(
        resolution _: CodexGhostRepairBulkProductionBundle.Resolution,
        phase: CodexGhostRepairBulkMaintenanceCollectionPhase
    ) async throws -> CodexGhostRepairBulkFreshMaintenanceObservation {
        observedPhases.append(phase)
        guard !observations.isEmpty else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return observations.removeFirst()
    }

    func phases() -> [CodexGhostRepairBulkMaintenanceCollectionPhase] {
        observedPhases
    }

    func callCount() -> Int { observedPhases.count }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}

#endif
