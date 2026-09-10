@testable import AgentSessionManagerCore
import Foundation
import XCTest

#if AGENT_SESSION_MANAGER_RESEARCH

final class CodexGhostRepairBulkBackupBoundOperationPlanTests: XCTestCase {
    private let requestID = UUID(
        uuidString: "11111111-2222-4333-8444-555555555555"
    )!
    private let previewID = UUID(
        uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!

    func testExact148PlanBindsColdSourceBundleBackupAndExpectedEffects()
        throws
    {
        let evidence = try makeEvidence(
            ordinary: 48,
            automation: 97,
            blocked: 3
        )
        let plan = try makePlan(evidence)

        XCTAssertEqual(plan.requestID, requestID)
        XCTAssertEqual(plan.previewID, previewID)
        XCTAssertEqual(plan.selectedCount, 145)
        XCTAssertEqual(plan.ordinaryCount, 48)
        XCTAssertEqual(plan.automationCount, 97)
        XCTAssertEqual(plan.blockedOutsideBatchCount, 3)
        XCTAssertEqual(plan.catalogRevisionIncrement, 145)
        XCTAssertEqual(plan.observationSequenceIncrement, 145)
        XCTAssertEqual(plan.databaseEvidence.count, 4)
        XCTAssertEqual(plan.databaseContracts.count, 5)
        XCTAssertEqual(
            plan.selectedItems.filter {
                $0.expectedEffect == .removeCatalogRow
            }.count,
            48
        )
        XCTAssertEqual(
            plan.selectedItems.filter {
                $0.expectedEffect
                    == .removeCatalogRowAndArchiveAutomation
            }.count,
            97
        )
        XCTAssertEqual(plan.bundleDigest, evidence.resolution.bundleDigest)
        XCTAssertEqual(
            plan.destination.recordDigest,
            evidence.destination.recordDigest
        )
        XCTAssertEqual(plan.backup.receiptDigest, evidence.backup.receiptDigest)
        XCTAssertTrue(plan.allOrNothing)
        XCTAssertFalse(plan.silentSelectionShrinkAllowed)
        XCTAssertTrue(plan.pathRedacted)
        XCTAssertFalse(plan.createsClaim)
        XCTAssertFalse(plan.invokesMutator)
        XCTAssertFalse(plan.appWiringAvailable)
        XCTAssertFalse(plan.liveExecutionAuthorized)
        XCTAssertFalse(plan.repairMutationAuthority)

        let capabilities =
            CodexGhostRepairBulkBackupBoundOperationPlanCapabilities()
        XCTAssertEqual(capabilities.maximumTargetCount, 500)
        XCTAssertTrue(capabilities.exactColdReadbackSourceRequired)
        XCTAssertTrue(capabilities.exactProductionBundleRequired)
        XCTAssertTrue(capabilities.exactVerifiedBackupRequired)
        XCTAssertTrue(capabilities.mixedOrdinaryAndAutomation)
        XCTAssertTrue(capabilities.allOrNothing)
        XCTAssertTrue(capabilities.deterministicPersistencePayload)
        XCTAssertFalse(capabilities.acceptsCallerPath)
        XCTAssertFalse(capabilities.performsIO)
        XCTAssertFalse(capabilities.opensSQLite)
        XCTAssertFalse(capabilities.createsBackup)
        XCTAssertFalse(capabilities.createsClaim)
        XCTAssertFalse(capabilities.invokesMutator)
        XCTAssertFalse(capabilities.appWiringAvailable)
        XCTAssertFalse(capabilities.liveExecutionAuthorized)
        XCTAssertFalse(capabilities.repairMutationAuthority)
    }

    func testPersistencePayloadColdReadbackIsExact() throws {
        let evidence = try makeEvidence(
            ordinary: 3,
            automation: 2,
            blocked: 1
        )
        let original = try makePlan(evidence)
        let data = try original.encodedForPersistence()
        let cold = try CodexGhostRepairBulkBackupBoundOperationPlan
            .decodeValidated(data)

        XCTAssertEqual(cold, original)
        XCTAssertEqual(cold.planDigest, original.planDigest)
        XCTAssertEqual(cold.selectedThreadIDs, original.selectedThreadIDs)
    }

    func testAlreadyAbsentTargetsRemainWithCategorySpecificEffects()
        throws
    {
        let evidence = try makeEvidence(
            ordinary: 3,
            automation: 2,
            blocked: 1
        )
        let selected = try XCTUnwrap(evidence.stored.frozenSource)
            .selectedThreadIDs
        let alreadyAbsent = [selected[0], selected[4]].sorted()
        let plan = try CodexGhostRepairBulkBackupBoundOperationPlan.prepare(
            coldReadback: evidence.stored,
            resolution: evidence.resolution,
            destination: evidence.destination,
            verifiedBackup: evidence.backup,
            liveRevalidation: try revalidation(
                evidence,
                alreadyAbsentThreadIDs: alreadyAbsent
            ),
            plannedAtMilliseconds: 2_001
        )

        XCTAssertEqual(plan.selectedThreadIDs, selected)
        XCTAssertEqual(plan.selectedCount, 5)
        XCTAssertEqual(plan.alreadyAbsentCount, 2)
        XCTAssertEqual(plan.actionableCount, 4)
        XCTAssertEqual(plan.catalogDeletionCount, 3)
        XCTAssertEqual(plan.catalogRevisionIncrement, 3)
        XCTAssertEqual(plan.observationSequenceIncrement, 3)
        XCTAssertEqual(
            plan.selectedItems.filter {
                [.alreadyAbsent, .archiveAutomation]
                    .contains($0.expectedEffect)
            }.map(\.threadID),
            alreadyAbsent
        )
        XCTAssertEqual(
            plan.selectedItems.first {
                $0.threadID == selected[4]
            }?.expectedEffect,
            .archiveAutomation
        )
        XCTAssertFalse(plan.silentSelectionShrinkAllowed)

        let cold = try CodexGhostRepairBulkBackupBoundOperationPlan
            .decodeValidated(plan.encodedForPersistence())
        XCTAssertEqual(cold, plan)
    }

    func testTamperedPersistencePayloadFailsColdReadback() throws {
        let original = try makePlan(makeEvidence(
            ordinary: 2,
            automation: 1,
            blocked: 3
        ))
        let data = try original.encodedForPersistence()
        var text = try XCTUnwrap(String(data: data, encoding: .utf8))
        text = text.replacingOccurrences(
            of: "\"blockedOutsideBatchCount\":3",
            with: "\"blockedOutsideBatchCount\":4"
        )
        XCTAssertThrowsError(
            try CodexGhostRepairBulkBackupBoundOperationPlan.decodeValidated(
                Data(text.utf8)
            )
        )
    }

    func testDifferentBundleCannotReuseVerifiedBackup() throws {
        let first = try makeEvidence(
            ordinary: 2,
            automation: 1,
            blocked: 0
        )
        let second = try makeEvidence(
            ordinary: 1,
            automation: 2,
            blocked: 0,
            requestID: UUID()
        )

        XCTAssertThrowsError(
            try CodexGhostRepairBulkBackupBoundOperationPlan.prepare(
                coldReadback: first.stored,
                resolution: first.resolution,
                destination: first.destination,
                verifiedBackup: second.backup,
                liveRevalidation: try revalidation(first),
                plannedAtMilliseconds: 2_001
            )
        )
    }

    func testSelectionDriftCannotShrinkThePlan() throws {
        let exact = try makeEvidence(
            ordinary: 2,
            automation: 2,
            blocked: 1
        )
        let smaller = try makeEvidence(
            ordinary: 2,
            automation: 1,
            blocked: 1
        )

        XCTAssertThrowsError(
            try CodexGhostRepairBulkBackupBoundOperationPlan.prepare(
                coldReadback: exact.stored,
                resolution: smaller.resolution,
                destination: smaller.destination,
                verifiedBackup: smaller.backup,
                liveRevalidation: try revalidation(smaller),
                plannedAtMilliseconds: 2_001
            )
        )
    }

    func testExpiredPreviewCannotCreatePlan() throws {
        let evidence = try makeEvidence(
            ordinary: 1,
            automation: 1,
            blocked: 0
        )
        XCTAssertThrowsError(
            try CodexGhostRepairBulkBackupBoundOperationPlan.prepare(
                coldReadback: evidence.stored,
                resolution: evidence.resolution,
                destination: evidence.destination,
                verifiedBackup: evidence.backup,
                liveRevalidation: try revalidation(evidence),
                plannedAtMilliseconds:
                    evidence.stored.preview.expiresAtMilliseconds
            )
        )
    }

    private struct Evidence {
        let stored: CodexGhostRepairBulkStoredPreview
        let resolution: CodexGhostRepairBulkProductionBundle.Resolution
        let destination: CodexGhostRepairBulkFixedBackupDestinationRecord
        let backup: CodexGhostRepairBulkLiveBackupReceipt
    }

    private func makePlan(
        _ evidence: Evidence
    ) throws -> CodexGhostRepairBulkBackupBoundOperationPlan {
        try .prepare(
            coldReadback: evidence.stored,
            resolution: evidence.resolution,
            destination: evidence.destination,
            verifiedBackup: evidence.backup,
            liveRevalidation: try revalidation(evidence),
            plannedAtMilliseconds: 2_001
        )
    }

    private func revalidation(
        _ evidence: Evidence,
        alreadyAbsentThreadIDs: [String] = []
    ) throws -> CodexGhostRepairBulkLiveTargetRevalidation {
        try .frozenTestEvidence(
            source: try XCTUnwrap(evidence.stored.frozenSource),
            backup: evidence.backup,
            alreadyAbsentThreadIDs: alreadyAbsentThreadIDs,
            observedAtMilliseconds: 2_001
        )
    }

    private func makeEvidence(
        ordinary: Int,
        automation: Int,
        blocked: Int,
        requestID: UUID? = nil
    ) throws -> Evidence {
        let requestID = requestID ?? self.requestID
        let inventory = try makeInventory(
            ordinary: ordinary,
            automation: automation,
            blocked: blocked
        )
        let preview = try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: inventory.eligibleThreadIDs,
            previewID: previewID,
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 901_000
        )
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateRoot,
            withIntermediateDirectories: true
        )
        let databaseURL = stateRoot.appendingPathComponent("manager.sqlite3")
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

        let sourceParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = sourceParent.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        let resolution = try CodexGhostRepairBulkProductionBundle(
            coldReadback: stored,
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: sourceParent
        ).resolveForTestOwnedAdoption()
        let fingerprint = try makeFingerprint()
        let window = try makeWindow(
            resolution,
            fingerprint: fingerprint.fingerprintHash
        )
        let destination = try CodexGhostRepairBulkFixedBackupDestinationRecord(
            resolution: resolution,
            maintenanceWindow: window,
            storageRootDigest: hash(900_001)
        )
        let backup = try CodexGhostRepairBulkLiveBackupReceipt(
            destination: destination,
            sourceFingerprint: fingerprint,
            capturedAtMilliseconds: 2_000
        )
        return Evidence(
            stored: stored,
            resolution: resolution,
            destination: destination,
            backup: backup
        )
    }

    private func makeWindow(
        _ resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        fingerprint: String
    ) throws -> CodexGhostRepairBulkMaintenanceWindow {
        let before = try CodexGhostRepairBulkFreshMaintenanceReadback(
            collectionID: UUID(),
            phase: .beforeBackup,
            resolution: resolution,
            maintenance: maintenance(at: 1_500, fingerprint: fingerprint)
        )
        let after = try CodexGhostRepairBulkFreshMaintenanceReadback(
            collectionID: UUID(),
            phase: .afterBackup,
            resolution: resolution,
            maintenance: maintenance(at: 1_900, fingerprint: fingerprint)
        )
        return try CodexGhostRepairBulkMaintenanceWindow(
            before: before,
            after: after
        )
    }

    private func maintenance(
        at timestamp: Int64,
        fingerprint: String
    ) throws -> CodexGhostRepairBulkMaintenanceEvidence {
        try .init(
            runtimeVersion: "0.149.0",
            executionGate: .init(
                codexFullyExited: true,
                desktopOpenHandleCount: 0,
                summariesOpenHandleCount: 0,
                historyOpenHandleCount: 0,
                stateOpenHandleCount: 0,
                threadHistoryOpenHandleCount: 0,
                capacitySufficient: true,
                desktopProcessEvidence: [],
                openHandleOwnerEvidence: []
            ),
            sourceFingerprintHash: fingerprint,
            authorityDigest: hash(800_001),
            observedAtMilliseconds: timestamp
        )
    }

    private func makeFingerprint()
        throws -> CodexGhostRepairSnapshotCanonicalFingerprint
    {
        let files = CodexGhostRepairSnapshotCanonicalFile.allCases.map {
            file in
            let present = file.isRequiredDatabase || file == .history
            return CodexGhostRepairSnapshotCanonicalFileEvidence(
                fileName: file.rawValue,
                exists: present,
                device: present ? 1 : nil,
                inode: present ? UInt64(file.rawValue.hashValue.magnitude) : nil,
                mode: present ? 0o100600 : nil,
                size: present ? 128 : nil,
                modificationSeconds: present ? 1 : nil,
                modificationNanoseconds: present ? 0 : nil,
                sha256: present ? hash(700_000 + file.rawValue.count) : nil
            )
        }
        return try CodexGhostRepairSnapshotCanonicalFingerprint(
            profile: .v149DesktopV32,
            sourceRootDigest: hash(700_001),
            files: files
        )
    }

    private func makeInventory(
        ordinary: Int,
        automation: Int,
        blocked: Int
    ) throws -> CodexGhostRepairBulkInventory {
        let identifiers = (1...(ordinary + automation + blocked)).map {
            String(format: "00000000-0000-4000-8000-%012llx", Int64($0))
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
                .init(database: .desktop, schemaVersion: 32,
                      integrityCheckPassed: true, foreignKeyViolationCount: 0),
                .init(database: .summaries, schemaVersion: 2,
                      integrityCheckPassed: true, foreignKeyViolationCount: 0),
                .init(database: .state, schemaVersion: 0,
                      integrityCheckPassed: true, foreignKeyViolationCount: 0),
                .init(database: .threadHistory, schemaVersion: 0,
                      integrityCheckPassed: true, foreignKeyViolationCount: 0),
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

    private func hash(_ value: Int) -> String {
        String(format: "sha256:%064llx", Int64(value))
    }
}

#endif
