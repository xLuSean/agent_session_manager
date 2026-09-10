@testable import AgentSessionManagerCore
import Foundation
import XCTest

#if AGENT_SESSION_MANAGER_RESEARCH

final class CodexGhostRepairBulkFixedBackupDestinationTests: XCTestCase {
    func testExact148DestinationIsDeterministicAvailableAndAuthorityFree()
        async throws
    {
        let fixture = try DestinationFixture()
        let bundle = try makeResolution(ordinary: 48, automation: 97, blocked: 3)
        let window = try makeWindow(bundle)
        let inspector = try fixture.inspector()
        let resolver = try CodexGhostRepairBulkFixedBackupDestinationResolver(
            resolution: bundle,
            maintenanceWindow: window,
            inspector: inspector
        )

        let first = try await resolver.inspectFresh()
        let second = try await resolver.inspectFresh()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.state, .available)
        XCTAssertEqual(first.destinationID, bundle.requestID.uuidString.lowercased())
        XCTAssertEqual(first.record.selectedCount, 145)
        XCTAssertEqual(first.record.ordinaryCount, 48)
        XCTAssertEqual(first.record.automationCount, 97)
        XCTAssertEqual(first.record.blockedOutsideBatchCount, 3)
        XCTAssertTrue(first.canCreateNewBackup)
        XCTAssertFalse(first.coldReadbackMatched)
        XCTAssertTrue(first.pathRedacted)
        XCTAssertFalse(first.overwriteAllowed)
        XCTAssertFalse(first.createsDirectory)
        XCTAssertFalse(first.createsBackupBytes)
        XCTAssertFalse(first.createsClaim)
        XCTAssertFalse(first.repairMutationAuthority)

        let capabilities = resolver.capabilities
        XCTAssertTrue(capabilities.exactBundleRequired)
        XCTAssertTrue(capabilities.exactMaintenanceWindowRequired)
        XCTAssertTrue(capabilities.fixedManagerNamespace)
        XCTAssertTrue(capabilities.operationIdentityIsDeterministic)
        XCTAssertTrue(capabilities.inspectionIsFreshPerCall)
        XCTAssertTrue(capabilities.coldReadbackSupported)
        XCTAssertFalse(capabilities.acceptsCallerPath)
        XCTAssertFalse(capabilities.overwritesExistingOperation)
        XCTAssertFalse(capabilities.createsDirectory)
        XCTAssertFalse(capabilities.createsBackupBytes)
        XCTAssertFalse(capabilities.opensCodexSource)
        XCTAssertFalse(capabilities.opensSQLite)
        XCTAssertFalse(capabilities.createsClaim)
        XCTAssertFalse(capabilities.automaticRetryAllowed)
        XCTAssertFalse(capabilities.automaticCleanupAllowed)
        XCTAssertFalse(capabilities.acceptsLiveCodexRoot)
        XCTAssertFalse(capabilities.appWiringAvailable)
        XCTAssertFalse(capabilities.repairMutationAuthority)
    }

    func testExactPreexistingRecordColdReadsAfterFreshConstruction()
        async throws
    {
        let fixture = try DestinationFixture()
        let bundle = try makeResolution(ordinary: 3, automation: 2, blocked: 1)
        let window = try makeWindow(bundle)
        let firstResolver = try CodexGhostRepairBulkFixedBackupDestinationResolver(
            resolution: bundle,
            maintenanceWindow: window,
            inspector: fixture.inspector()
        )
        let available = try await firstResolver.inspectFresh()
        try fixture.installExactRecord(available.record)

        let coldResolver = try CodexGhostRepairBulkFixedBackupDestinationResolver(
            resolution: bundle,
            maintenanceWindow: window,
            inspector: fixture.inspector()
        )
        let readback = try await coldResolver.inspectFresh()

        XCTAssertEqual(readback.record, available.record)
        XCTAssertEqual(readback.state, .exactColdReadback)
        XCTAssertFalse(readback.canCreateNewBackup)
        XCTAssertTrue(readback.coldReadbackMatched)
        XCTAssertFalse(readback.overwriteAllowed)
    }

    func testSameResolverDoesNotCacheAvailableState() async throws {
        let fixture = try DestinationFixture()
        let bundle = try makeResolution(ordinary: 2, automation: 2, blocked: 0)
        let window = try makeWindow(bundle)
        let resolver = try CodexGhostRepairBulkFixedBackupDestinationResolver(
            resolution: bundle,
            maintenanceWindow: window,
            inspector: fixture.inspector()
        )

        let available = try await resolver.inspectFresh()
        try fixture.installExactRecord(available.record)
        let readback = try await resolver.inspectFresh()

        XCTAssertEqual(available.state, .available)
        XCTAssertEqual(readback.state, .exactColdReadback)
    }

    func testPartialExtraAndMismatchedExistingDestinationsFailClosed()
        async throws
    {
        let scenarios: [DestinationFixture.ExistingState] = [
            .emptyDirectory,
            .extraMember,
            .mismatchedRecord,
        ]
        for scenario in scenarios {
            let fixture = try DestinationFixture()
            let bundle = try makeResolution(ordinary: 1, automation: 1, blocked: 0)
            let window = try makeWindow(bundle)
            let resolver = try CodexGhostRepairBulkFixedBackupDestinationResolver(
                resolution: bundle,
                maintenanceWindow: window,
                inspector: fixture.inspector()
            )
            let available = try await resolver.inspectFresh()
            try fixture.install(scenario, expected: available.record)

            await XCTAssertThrowsErrorAsync(
                try await resolver.inspectFresh()
            )
        }
    }

    func testBundleOrWindowDriftCannotReuseExactDestination() async throws {
        let fixture = try DestinationFixture()
        let firstBundle = try makeResolution(
            ordinary: 2,
            automation: 1,
            blocked: 0,
            requestID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        )
        let firstWindow = try makeWindow(firstBundle)
        let firstResolver = try CodexGhostRepairBulkFixedBackupDestinationResolver(
            resolution: firstBundle,
            maintenanceWindow: firstWindow,
            inspector: fixture.inspector()
        )
        let first = try await firstResolver.inspectFresh()
        try fixture.installExactRecord(first.record)

        let secondBundle = try makeResolution(
            ordinary: 2,
            automation: 1,
            blocked: 0,
            requestID: UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
        )
        let secondResolver = try CodexGhostRepairBulkFixedBackupDestinationResolver(
            resolution: secondBundle,
            maintenanceWindow: makeWindow(secondBundle),
            inspector: fixture.inspector()
        )
        let second = try await secondResolver.inspectFresh()

        XCTAssertNotEqual(first.destinationID, second.destinationID)
        XCTAssertNotEqual(first.record.recordDigest, second.record.recordDigest)
        XCTAssertEqual(second.state, .available)

        let driftedWindow = try makeWindow(
            firstBundle,
            fingerprint: hash(888)
        )
        let driftedResolver = try CodexGhostRepairBulkFixedBackupDestinationResolver(
            resolution: firstBundle,
            maintenanceWindow: driftedWindow,
            inspector: fixture.inspector()
        )
        await XCTAssertThrowsErrorAsync(
            try await driftedResolver.inspectFresh()
        )
    }

    func testBlockedInspectionIsNotRetriedAutomatically() async throws {
        let bundle = try makeResolution(ordinary: 1, automation: 0, blocked: 0)
        let inspector = CountingDestinationInspector(
            storageRootDigest: hash(900),
            outcomes: [.failure(CodexGhostRepairError.backupFailed("blocked")),
                       .success(.available)]
        )
        let resolver = try CodexGhostRepairBulkFixedBackupDestinationResolver(
            resolution: bundle,
            maintenanceWindow: makeWindow(bundle),
            inspector: inspector
        )

        await XCTAssertThrowsErrorAsync(
            try await resolver.inspectFresh()
        )
        let calls = await inspector.callCount()
        XCTAssertEqual(calls, 1)
    }

    private func makeResolution(
        ordinary: Int,
        automation: Int,
        blocked: Int,
        requestID: UUID = UUID(
            uuidString: "11111111-2222-4333-8444-555555555555"
        )!
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
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateRoot,
            withIntermediateDirectories: true
        )
        let store = try SQLiteStateStore(
            databaseURL: stateRoot.appendingPathComponent("manager.sqlite3")
        )
        _ = try store.saveCodexGhostRepairBulkPreview(
            requestID: requestID,
            preview: preview,
            inventory: inventory
        )
        store.close()
        let reopened = try SQLiteStateStore(
            databaseURL: stateRoot.appendingPathComponent("manager.sqlite3")
        )
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

    private func makeWindow(
        _ resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        fingerprint: String? = nil
    ) throws -> CodexGhostRepairBulkMaintenanceWindow {
        let source = fingerprint ?? hash(600)
        let before = try CodexGhostRepairBulkFreshMaintenanceReadback(
            collectionID: UUID(),
            phase: .beforeBackup,
            resolution: resolution,
            maintenance: maintenance(at: 10, fingerprint: source)
        )
        let after = try CodexGhostRepairBulkFreshMaintenanceReadback(
            collectionID: UUID(),
            phase: .afterBackup,
            resolution: resolution,
            maintenance: maintenance(at: 11, fingerprint: source)
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
            authorityDigest: hash(601),
            observedAtMilliseconds: timestamp
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

private final class DestinationFixture: @unchecked Sendable {
    enum ExistingState {
        case emptyDirectory
        case extraMember
        case mismatchedRecord
    }

    let allowedParent: URL
    let managerRoot: URL
    let operationRoot: URL

    init() throws {
        allowedParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4f14-\(UUID().uuidString)", isDirectory: true)
        managerRoot = allowedParent.appendingPathComponent(
            "manager",
            isDirectory: true
        )
        let storageRoot = managerRoot.appendingPathComponent(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector
                .ghostRepairDirectoryName,
            isDirectory: true
        )
        let operationBackups = storageRoot.appendingPathComponent(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector
                .operationBackupsDirectoryName,
            isDirectory: true
        )
        operationRoot = operationBackups.appendingPathComponent(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector
                .versionDirectoryName,
            isDirectory: true
        )
        for directory in [
            allowedParent,
            managerRoot,
            storageRoot,
            operationBackups,
            operationRoot,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        let marker = managerRoot.appendingPathComponent(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector.markerFileName
        )
        try Data(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector
                .markerContents.utf8
        ).write(to: marker)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: marker.path
        )
    }

    func inspector() throws
        -> CodexGhostRepairBulkFixedBackupDestinationTestInspector
    {
        try .init(
            testOwnedManagerRootURL: managerRoot,
            testOwnedAllowedParentURL: allowedParent
        )
    }

    func installExactRecord(
        _ record: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) throws {
        let destination = try makeDestination(record.destinationID)
        let recordURL = destination.appendingPathComponent(
            CodexGhostRepairBulkFixedBackupDestinationTestInspector.recordFileName
        )
        try JSONEncoder().encode(record).write(to: recordURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: recordURL.path
        )
    }

    func install(
        _ state: ExistingState,
        expected: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) throws {
        switch state {
        case .emptyDirectory:
            _ = try makeDestination(expected.destinationID)
        case .extraMember:
            try installExactRecord(expected)
            let extra = operationRoot
                .appendingPathComponent(expected.destinationID, isDirectory: true)
                .appendingPathComponent("unexpected")
            try Data("x".utf8).write(to: extra)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: extra.path
            )
        case .mismatchedRecord:
            var data = try JSONEncoder().encode(expected)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            object["bundleDigest"] = String(
                format: "sha256:%064llx",
                Int64(999)
            )
            data = try JSONSerialization.data(withJSONObject: object)
            let destination = try makeDestination(expected.destinationID)
            let recordURL = destination.appendingPathComponent(
                CodexGhostRepairBulkFixedBackupDestinationTestInspector
                    .recordFileName
            )
            try data.write(to: recordURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: recordURL.path
            )
        }
    }

    private func makeDestination(_ destinationID: String) throws -> URL {
        let destination = operationRoot.appendingPathComponent(
            destinationID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: destination.path
        )
        return destination
    }
}

private actor CountingDestinationInspector:
    CodexGhostRepairBulkFixedBackupDestinationInspecting
{
    nonisolated let storageRootDigest: String
    private var outcomes:
        [Result<CodexGhostRepairBulkFixedBackupDestinationState, Error>]
    private var calls = 0

    init(
        storageRootDigest: String,
        outcomes: [
            Result<CodexGhostRepairBulkFixedBackupDestinationState, Error>
        ]
    ) {
        self.storageRootDigest = storageRootDigest
        self.outcomes = outcomes
    }

    func inspectFresh(
        record _: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) throws -> CodexGhostRepairBulkFixedBackupDestinationState {
        calls += 1
        guard !outcomes.isEmpty else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return try outcomes.removeFirst().get()
    }

    func storageRootDigestFresh() -> String { storageRootDigest }

    func callCount() -> Int { calls }
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
