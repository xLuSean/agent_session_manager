@testable import AgentSessionManagerCore
import Foundation
import XCTest

#if AGENT_SESSION_MANAGER_RESEARCH

final class CodexGhostRepairBulkProductionBundleTests: XCTestCase {
    private let requestID = UUID(
        uuidString: "11111111-2222-4333-8444-555555555555"
    )!
    private let previewID = UUID(
        uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!

    func testExact148ColdReadbackAdoptsDedicatedMixedBundle() throws {
        let stored = try makeColdReadback(
            ordinary: 48,
            automation: 97,
            blocked: 3
        )
        let roots = makeNonexistentTestRoots()
        let bundle = try CodexGhostRepairBulkProductionBundle(
            coldReadback: stored,
            testOwnedCodexHomeURL: roots.codexHome,
            testOwnedAllowedParentURL: roots.parent
        )
        let resolution = try bundle.resolveForTestOwnedAdoption()

        XCTAssertEqual(resolution.requestID, requestID)
        XCTAssertEqual(resolution.previewID, previewID)
        XCTAssertEqual(resolution.selectedCount, 145)
        XCTAssertEqual(resolution.ordinaryCount, 48)
        XCTAssertEqual(resolution.automationCount, 97)
        XCTAssertEqual(resolution.blockedOutsideBatchCount, 3)
        XCTAssertEqual(
            resolution.selectedThreadIDs,
            stored.preview.selectedThreadIDs
        )
        XCTAssertEqual(
            resolution.frozenSourceDigest,
            stored.frozenSource?.sourceDigest
        )
        XCTAssertEqual(resolution.databaseContracts.count, 5)
        XCTAssertEqual(
            resolution.databaseContracts.filter(\.required).count,
            4
        )
        XCTAssertEqual(
            resolution.databaseContracts.filter {
                $0.role == .futureSingleTransactionMutation
            }.map(\.database),
            [.desktop]
        )
        XCTAssertTrue(resolution.allOrNothing)
        XCTAssertTrue(resolution.selectedOnlySource)
        XCTAssertFalse(resolution.pathIncludedInBundleDigest)
        XCTAssertFalse(resolution.acceptsLiveCodexRoot)
        XCTAssertFalse(resolution.createsBackup)
        XCTAssertFalse(resolution.createsClaim)
        XCTAssertFalse(resolution.repairMutationAuthority)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.parent.path
        ))

        let capabilities = bundle.capabilities
        XCTAssertEqual(capabilities.maximumTargetCount, 500)
        XCTAssertTrue(capabilities.mixedOrdinaryAndAutomation)
        XCTAssertTrue(capabilities.exactColdReadbackSourceRequired)
        XCTAssertTrue(capabilities.selectedOnlySourceRequired)
        XCTAssertFalse(capabilities.acceptsCallerPath)
        XCTAssertFalse(capabilities.constructionPerformsIO)
        XCTAssertFalse(capabilities.resolutionPerformsIO)
        XCTAssertFalse(capabilities.opensFilesystem)
        XCTAssertFalse(capabilities.opensSQLite)
        XCTAssertFalse(capabilities.createsBackup)
        XCTAssertFalse(capabilities.createsClaim)
        XCTAssertFalse(capabilities.repairMutationAuthority)

        let oldSingleItemCapabilities =
            CodexGhostRepairProductionRepairBundleCapabilities()
        XCTAssertEqual(oldSingleItemCapabilities.maximumTargetCount, 2)
        XCTAssertTrue(oldSingleItemCapabilities.categoryAOnly)
    }

    func testBundleDigestIsStableAndExcludesTestRoot() throws {
        let stored = try makeColdReadback(
            ordinary: 3,
            automation: 2,
            blocked: 1
        )
        let firstRoots = makeNonexistentTestRoots()
        let secondRoots = makeNonexistentTestRoots()
        let first = try CodexGhostRepairBulkProductionBundle(
            coldReadback: stored,
            testOwnedCodexHomeURL: firstRoots.codexHome,
            testOwnedAllowedParentURL: firstRoots.parent
        ).resolveForTestOwnedAdoption()
        let second = try CodexGhostRepairBulkProductionBundle(
            coldReadback: stored,
            testOwnedCodexHomeURL: secondRoots.codexHome,
            testOwnedAllowedParentURL: secondRoots.parent
        ).resolveForTestOwnedAdoption()

        XCTAssertEqual(first.bundleDigest, second.bundleDigest)
        XCTAssertNotEqual(
            first.testOwnedCodexHomeURL,
            second.testOwnedCodexHomeURL
        )
        XCTAssertEqual(
            first.databaseURL(for: .desktop).lastPathComponent,
            CodexGhostRepairSnapshotCanonicalFile.desktop.rawValue
        )
        XCTAssertEqual(
            first.databaseURL(for: .summaries).lastPathComponent,
            CodexGhostRepairSnapshotCanonicalFile.summaries.rawValue
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: firstRoots.parent.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: secondRoots.parent.path
        ))
    }

    func testProductionResolutionIsCallerPathFreeAndProfileBound() throws {
        let stored = try makeColdReadback(
            ordinary: 48,
            automation: 97,
            blocked: 3
        )
        let production = try CodexGhostRepairBulkProductionBundle(
            productionColdReadback: stored
        )
        let resolved = try production.resolveForProduction()
        let expectedHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL

        XCTAssertTrue(production.capabilities.productionFactoryAvailable)
        XCTAssertFalse(
            production.capabilities.productionFactoryAcceptsCallerPath
        )
        XCTAssertTrue(resolved.acceptsLiveCodexRoot)
        XCTAssertEqual(resolved.testOwnedCodexHomeURL, expectedHome)
        XCTAssertEqual(
            resolved.sourceLayoutIdentifier,
            try XCTUnwrap(stored.frozenSource).sourceLayoutIdentifier
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: expectedHome.appendingPathComponent(
                "m4f-production-resolution-must-not-create"
            ).path
        ))

        let testRoots = makeNonexistentTestRoots()
        let testBundle = try CodexGhostRepairBulkProductionBundle(
            coldReadback: stored,
            testOwnedCodexHomeURL: testRoots.codexHome,
            testOwnedAllowedParentURL: testRoots.parent
        )
        XCTAssertFalse(
            try testBundle.resolveForTestOwnedAdoption().acceptsLiveCodexRoot
        )
        XCTAssertThrowsError(try testBundle.resolveForProduction())
    }

    func testLegacyPreviewWithoutFrozenSourceCannotBeAdopted() throws {
        let databaseURL = try makeDatabaseURL()
        let inventory = try makeFrozenInventory(
            ordinary: 2,
            automation: 1,
            blocked: 0
        )
        let preview = try makePreview(inventory: inventory)
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview
        )
        store.close()
        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        defer { reopened.close() }
        let stored = try XCTUnwrap(
            reopened.codexGhostRepairBulkPreview(requestID: requestID)
        )
        let roots = makeNonexistentTestRoots()

        XCTAssertNil(stored.frozenSource)
        XCTAssertThrowsError(try CodexGhostRepairBulkProductionBundle(
            coldReadback: stored,
            testOwnedCodexHomeURL: roots.codexHome,
            testOwnedAllowedParentURL: roots.parent
        ))
    }

    func testLiveAndEscapedRootsFailBeforeAnyIO() throws {
        let stored = try makeColdReadback(
            ordinary: 1,
            automation: 1,
            blocked: 0
        )
        let live = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let liveBundle = try CodexGhostRepairBulkProductionBundle(
            coldReadback: stored,
            testOwnedCodexHomeURL: live,
            testOwnedAllowedParentURL:
                FileManager.default.homeDirectoryForCurrentUser
        )
        XCTAssertThrowsError(
            try liveBundle.resolveForTestOwnedAdoption()
        )

        let roots = makeNonexistentTestRoots()
        let escaped = try CodexGhostRepairBulkProductionBundle(
            coldReadback: stored,
            testOwnedCodexHomeURL: roots.parent
                .deletingLastPathComponent()
                .appendingPathComponent("escaped", isDirectory: true),
            testOwnedAllowedParentURL: roots.parent
        )
        XCTAssertThrowsError(try escaped.resolveForTestOwnedAdoption())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.parent.path
        ))
    }

    func testProductionMaintenanceRunsGateBeforeSourceAndAuthorityReads()
        async throws
    {
        let fingerprint = try CodexGhostRepairSnapshotCanonicalFingerprint(
            profile: .v149DesktopV32,
            sourceRootDigest: hash(800_001),
            files: CodexGhostRepairSnapshotCanonicalFile.allCases.map {
                .init(
                    fileName: $0.rawValue,
                    exists: false,
                    device: nil,
                    inode: nil,
                    mode: nil,
                    size: nil,
                    modificationSeconds: nil,
                    modificationNanoseconds: nil,
                    sha256: nil
                )
            }
        )
        let stored = try makeColdReadback(
            ordinary: 1,
            automation: 1,
            blocked: 0,
            sourceFingerprintHash: fingerprint.fingerprintHash
        )
        let resolution = try CodexGhostRepairBulkProductionBundle(
            productionColdReadback: stored
        ).resolveForProduction()
        let reads = MaintenanceReadCounter()
        let blocked = CodexGhostRepairBulkProductionMaintenanceObserver(
            profile: .v149DesktopV32,
            gateSource: FixedBulkProductionGateSource(.init(
                codexFullyExited: false,
                desktopOpenHandleCount: 1,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                stateOpenHandleCount: 0,
                threadHistoryOpenHandleCount: 0,
                capacitySufficient: true,
                desktopProcessEvidence: [],
                openHandleOwnerEvidence: []
            )),
            fingerprintReader: {
                reads.recordFingerprint()
                return fingerprint
            },
            authorityReader: { _ in
                reads.recordAuthority()
                return resolution.authority
            },
            nowMilliseconds: { 10 }
        )

        do {
            _ = try await blocked.observeFreshMaintenance(
                resolution: resolution,
                phase: .beforeBackup
            )
            XCTFail("Blocked operating conditions must stop before reads.")
        } catch {}
        XCTAssertEqual(reads.snapshot(), [0, 0])

        let laterFingerprint = try CodexGhostRepairSnapshotCanonicalFingerprint(
            profile: .v149DesktopV32,
            sourceRootDigest: hash(800_002),
            files: fingerprint.files
        )
        let laterAuthority = CodexGhostRepairSnapshotAnalysisAuthorityEvidence(
            catalogRevision: resolution.authority.catalogRevision + 1,
            observationSequence: resolution.authority.observationSequence + 1,
            watermarkUpdatedAt: resolution.authority.watermarkUpdatedAt,
            metadataRowDigest: hash(800_003),
            localSyncRowDigest: hash(800_004)
        )
        let clear = CodexGhostRepairBulkProductionMaintenanceObserver(
            profile: .v149DesktopV32,
            gateSource: FixedBulkProductionGateSource(.init(
                codexFullyExited: true,
                desktopOpenHandleCount: 0,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                stateOpenHandleCount: 0,
                threadHistoryOpenHandleCount: 0,
                capacitySufficient: true,
                desktopProcessEvidence: [],
                openHandleOwnerEvidence: []
            )),
            fingerprintReader: {
                reads.recordFingerprint()
                return laterFingerprint
            },
            authorityReader: { _ in
                reads.recordAuthority()
                return laterAuthority
            },
            nowMilliseconds: { 11 }
        )
        let observation = try await clear.observeFreshMaintenance(
            resolution: resolution,
            phase: .beforeBackupRepeat
        )

        XCTAssertEqual(observation.runtimeVersion, "0.149.0")
        XCTAssertEqual(
            observation.sourceFingerprintHash,
            laterFingerprint.fingerprintHash
        )
        XCTAssertNotEqual(
            observation.sourceFingerprintHash,
            resolution.sourceFingerprintHash
        )
        XCTAssertEqual(
            observation.authorityDigest,
            try CodexGhostRepairHasher.hash(laterAuthority)
        )
        XCTAssertEqual(reads.snapshot(), [1, 1])
    }

    private func makeColdReadback(
        ordinary: Int,
        automation: Int,
        blocked: Int,
        sourceFingerprintHash: String? = nil
    ) throws -> CodexGhostRepairBulkStoredPreview {
        let inventory = try makeFrozenInventory(
            ordinary: ordinary,
            automation: automation,
            blocked: blocked,
            sourceFingerprintHash: sourceFingerprintHash
        )
        let preview = try makePreview(inventory: inventory)
        let databaseURL = try makeDatabaseURL()
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            inventory: inventory
        )
        store.close()
        let reopened = try SQLiteStateStore(databaseURL: databaseURL)
        defer { reopened.close() }
        return try XCTUnwrap(
            reopened.codexGhostRepairBulkPreview(requestID: requestID)
        )
    }

    private func makePreview(
        inventory: CodexGhostRepairBulkInventory
    ) throws -> CodexGhostRepairBulkPreview {
        try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: inventory.eligibleThreadIDs,
            previewID: previewID,
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 901_000
        )
    }

    private func makeFrozenInventory(
        ordinary: Int,
        automation: Int,
        blocked: Int,
        sourceFingerprintHash: String? = nil
    ) throws -> CodexGhostRepairBulkInventory {
        let count = ordinary + automation + blocked
        let identifiers = (1...count).map { index in
            String(
                format: "00000000-0000-4000-8000-%012llx",
                Int64(index)
            )
        }
        let targets = identifiers.enumerated().map { index, threadID in
            let automationItem = index >= ordinary
                && index < ordinary + automation
            return CodexGhostRepairSnapshotAnalysisTargetEvidence(
                threadID: threadID,
                catalogRowDigests: [hash(index + 101)],
                automationRunRowDigests: automationItem
                    ? [hash(index + 1_001)] : [],
                automationStableFieldsDigests: automationItem
                    ? [hash(index + 1_501)] : [],
                automationDefinitionRowDigests: automationItem
                    ? [hash(index + 2_001)] : [],
                references: .init(
                    inbox: 0,
                    timeline: 0,
                    summaries: 0,
                    canonicalState: 0,
                    threadTurns: 0,
                    threadItems: 0,
                    historyProjection: 0
                ),
                rowContract: automationItem
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
            sourceFingerprintHash: sourceFingerprintHash ?? hash(700_001),
            manifestHash: hash(700_002),
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
                metadataRowDigest: hash(700_003),
                localSyncRowDigest: hash(700_004)
            )
        ))
    }

    private func makeDatabaseURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root.appendingPathComponent("manager.sqlite3")
    }

    private func makeNonexistentTestRoots() -> (parent: URL, codexHome: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (
            parent,
            parent.appendingPathComponent("codex-home", isDirectory: true)
        )
    }

    private func hash(_ value: Int) -> String {
        String(format: "sha256:%064llx", Int64(value))
    }
}

private actor FixedBulkProductionGateSource:
    CodexGhostRepairExecutionGateSource
{
    private let gate: CodexGhostRepairExecutionGate

    init(_ gate: CodexGhostRepairExecutionGate) {
        self.gate = gate
    }

    func ghostRepairExecutionGate() async throws
        -> CodexGhostRepairExecutionGate
    {
        gate
    }
}

private final class MaintenanceReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprintReads = 0
    private var authorityReads = 0

    func recordFingerprint() {
        lock.lock()
        fingerprintReads += 1
        lock.unlock()
    }

    func recordAuthority() {
        lock.lock()
        authorityReads += 1
        lock.unlock()
    }

    func snapshot() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return [fingerprintReads, authorityReads]
    }
}

#endif
