@testable import AgentSessionManagerCore
import Foundation
import XCTest

#if AGENT_SESSION_MANAGER_RESEARCH

final class CodexGhostRepairBulkLiveBackupTransportTests: XCTestCase {
    func testProductionFactoryConstructionIsZeroIOAndNotAppAuthority()
        async throws
    {
        let fixture = try LiveBackupFixture()
        let resolution = try makeResolution(
            fixture: fixture,
            ordinary: 1,
            automation: 1,
            blocked: 0
        )
        let fingerprint = try fixture.canonicalSource().fingerprint()
        let transport = try CodexGhostRepairBulkLiveBackupTransport.production(
            resolution: resolution,
            maintenanceWindow: makeWindow(
                resolution,
                fingerprint: fingerprint.fingerprintHash
            )
        )

        let capabilities = transport.capabilities
        XCTAssertEqual(capabilities.fixedCanonicalFileCount, 20)
        XCTAssertTrue(capabilities.productionFactoryAvailable)
        XCTAssertFalse(capabilities.productionConstructionPerformsIO)
        XCTAssertFalse(capabilities.productionFactoryAcceptsCallerPath)
        XCTAssertTrue(capabilities.explicitActionRequired)
        XCTAssertTrue(capabilities.destinationRecordWrittenBeforeRawBytes)
        XCTAssertTrue(capabilities.receiptManifestWrittenLast)
        XCTAssertTrue(capabilities.sourceFingerprintRequiredBeforeAndAfter)
        XCTAssertTrue(capabilities.exactColdReadbackSupported)
        XCTAssertFalse(capabilities.overwritesExistingOperation)
        XCTAssertFalse(capabilities.retriesPartialOperation)
        XCTAssertFalse(capabilities.automaticRestoreAllowed)
        XCTAssertFalse(capabilities.automaticCleanupAllowed)
        XCTAssertFalse(capabilities.opensSQLite)
        XCTAssertFalse(capabilities.createsClaim)
        XCTAssertFalse(capabilities.appWiringAvailable)
        XCTAssertFalse(capabilities.liveExecutionAuthorized)
        XCTAssertFalse(capabilities.repairMutationAuthority)
        XCTAssertTrue(fixture.operationIDs().isEmpty)
    }

    func testExact148TestOwnedBackupWritesRecordFirstAndReceiptLast()
        async throws
    {
        let fixture = try LiveBackupFixture()
        let resolution = try makeResolution(
            fixture: fixture,
            ordinary: 48,
            automation: 97,
            blocked: 3
        )
        let fingerprint = try fixture.canonicalSource().fingerprint()
        let window = try makeWindow(
            resolution,
            fingerprint: fingerprint.fingerprintHash
        )
        let transport = try makeTransport(
            fixture: fixture,
            resolution: resolution,
            window: window
        )

        let destination = try await transport.inspectFreshDestination()
        XCTAssertEqual(destination.state, .available)
        XCTAssertEqual(destination.record.selectedCount, 145)
        XCTAssertEqual(destination.record.ordinaryCount, 48)
        XCTAssertEqual(destination.record.automationCount, 97)
        XCTAssertEqual(destination.record.blockedOutsideBatchCount, 3)

        let receipt = try await transport.createExactBackup(
            destination: destination
        )
        XCTAssertEqual(receipt.bundleDigest, resolution.bundleDigest)
        XCTAssertEqual(receipt.maintenanceWindowDigest, window.windowDigest)
        XCTAssertEqual(receipt.sourceFingerprintHash, fingerprint.fingerprintHash)
        XCTAssertEqual(receipt.files.count, 20)
        XCTAssertEqual(receipt.files.filter(\.present).count, 5)
        XCTAssertTrue(receipt.pathRedacted)
        XCTAssertFalse(receipt.createsClaim)
        XCTAssertFalse(receipt.repairMutationAuthority)

        let members = try fixture.members(destination.record)
        XCTAssertEqual(members.first, "codex-dev.db")
        XCTAssertTrue(members.contains("destination.json"))
        XCTAssertTrue(members.contains("receipt.json"))
        XCTAssertEqual(
            try fixture.destinationRecord(destination.record),
            destination.record
        )
        let exactReadback = try await transport.readExactBackup(
            destination: destination.record
        )
        XCTAssertEqual(exactReadback, receipt)
    }

    func testFreshTransportColdReadsCompleteBackupWithoutOpeningSourceAgain()
        async throws
    {
        let fixture = try LiveBackupFixture()
        let resolution = try makeResolution(
            fixture: fixture,
            ordinary: 2,
            automation: 2,
            blocked: 1
        )
        let fingerprint = try fixture.canonicalSource().fingerprint()
        let window = try makeWindow(
            resolution,
            fingerprint: fingerprint.fingerprintHash
        )
        let first = try makeTransport(
            fixture: fixture,
            resolution: resolution,
            window: window
        )
        let destination = try await first.inspectFreshDestination()
        let created = try await first.createExactBackup(destination: destination)

        try fixture.makeSourceUnreadable()
        let cold = try makeTransport(
            fixture: fixture,
            resolution: resolution,
            window: window
        )
        let readback = try await cold.readExactBackup(
            destination: destination.record
        )

        XCTAssertEqual(readback, created)
    }

    func testRecordOnlyPartialDestinationCannotRetryOrOverwrite()
        async throws
    {
        let fixture = try LiveBackupFixture()
        let resolution = try makeResolution(
            fixture: fixture,
            ordinary: 1,
            automation: 0,
            blocked: 0
        )
        let fingerprint = try fixture.canonicalSource().fingerprint()
        let window = try makeWindow(
            resolution,
            fingerprint: fingerprint.fingerprintHash
        )
        let transport = try makeTransport(
            fixture: fixture,
            resolution: resolution,
            window: window
        )
        let destination = try await transport.inspectFreshDestination()
        try fixture.installRecordOnly(destination.record)

        await XCTAssertThrowsAsync(
            try await transport.createExactBackup(destination: destination)
        )
        XCTAssertEqual(
            try fixture.members(destination.record),
            ["destination.json"]
        )
        XCTAssertFalse(fixture.receiptExists(destination.record))
    }

    func testSourceDriftLeavesReadbackOnlyPartialAndNoRetry()
        async throws
    {
        let fixture = try LiveBackupFixture()
        let resolution = try makeResolution(
            fixture: fixture,
            ordinary: 2,
            automation: 1,
            blocked: 0
        )
        let fingerprint = try fixture.canonicalSource().fingerprint()
        let window = try makeWindow(
            resolution,
            fingerprint: fingerprint.fingerprintHash
        )
        let mutation = OneShotMutation {
            try fixture.appendToDesktopDatabase()
        }
        let transport = try makeTransport(
            fixture: fixture,
            resolution: resolution,
            window: window,
            afterCopiedMember: { count in
                if count == 1 { try mutation.run() }
            }
        )
        let destination = try await transport.inspectFreshDestination()

        await XCTAssertThrowsAsync(
            try await transport.createExactBackup(destination: destination)
        )
        XCTAssertFalse(fixture.receiptExists(destination.record))
        XCTAssertTrue(
            try fixture.members(destination.record).contains("destination.json")
        )
        await XCTAssertThrowsAsync(
            try await transport.createExactBackup(destination: destination)
        )
        XCTAssertFalse(fixture.receiptExists(destination.record))
    }

    func testCopiedMemberTamperingFailsExactColdReadback() async throws {
        let fixture = try LiveBackupFixture()
        let resolution = try makeResolution(
            fixture: fixture,
            ordinary: 1,
            automation: 1,
            blocked: 0
        )
        let fingerprint = try fixture.canonicalSource().fingerprint()
        let window = try makeWindow(
            resolution,
            fingerprint: fingerprint.fingerprintHash
        )
        let transport = try makeTransport(
            fixture: fixture,
            resolution: resolution,
            window: window
        )
        let destination = try await transport.inspectFreshDestination()
        _ = try await transport.createExactBackup(destination: destination)
        try fixture.tamperCopiedDesktop(destination.record)

        await XCTAssertThrowsAsync(
            try await transport.readExactBackup(
                destination: destination.record
            )
        )
    }

    func testExplicitPreparationCreatesOnlyMissingFixedPrivateDirectories()
        async throws
    {
        let fixture = try LiveBackupFixture(createOperationStorage: false)
        let resolution = try makeResolution(
            fixture: fixture,
            ordinary: 1,
            automation: 1,
            blocked: 0
        )
        let fingerprint = try fixture.canonicalSource().fingerprint()
        let transport = try makeTransport(
            fixture: fixture,
            resolution: resolution,
            window: makeWindow(
                resolution,
                fingerprint: fingerprint.fingerprintHash
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.operationRoot.path
        ))
        try await transport.prepareFixedStorageIfNeeded()

        for directory in [
            fixture.operationRoot.deletingLastPathComponent(),
            fixture.operationRoot,
        ] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.path
            )
            XCTAssertEqual(
                (attributes[.posixPermissions] as? NSNumber)?.intValue,
                0o700
            )
        }
        XCTAssertTrue(fixture.operationIDs().isEmpty)
    }

    func testExplicitPreparationRejectsFixedPathCollision() async throws {
        let fixture = try LiveBackupFixture(createOperationStorage: false)
        try Data("collision".utf8).write(
            to: fixture.operationRoot.deletingLastPathComponent()
        )
        let resolution = try makeResolution(
            fixture: fixture,
            ordinary: 1,
            automation: 0,
            blocked: 0
        )
        let fingerprint = try fixture.canonicalSource().fingerprint()
        let transport = try makeTransport(
            fixture: fixture,
            resolution: resolution,
            window: makeWindow(
                resolution,
                fingerprint: fingerprint.fingerprintHash
            )
        )

        await XCTAssertThrowsAsync(
            try await transport.prepareFixedStorageIfNeeded()
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.operationRoot.path
        ))
    }

    private func makeTransport(
        fixture: LiveBackupFixture,
        resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        window: CodexGhostRepairBulkMaintenanceWindow,
        afterCopiedMember: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) throws -> CodexGhostRepairBulkLiveBackupTransport {
        let environment = try CodexGhostRepairBulkLiveBackupEnvironment(
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedSourceAllowedParentURL: fixture.sourceParent,
            testOwnedManagerRootURL: fixture.managerRoot,
            testOwnedManagerAllowedParentURL: fixture.managerParent,
            nowMilliseconds: { 12_345 },
            afterCopiedMemberForTesting: afterCopiedMember
        )
        return try CodexGhostRepairBulkLiveBackupTransport(
            resolution: resolution,
            maintenanceWindow: window,
            environment: environment
        )
    }

    private func makeResolution(
        fixture: LiveBackupFixture,
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
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateRoot,
            withIntermediateDirectories: true
        )
        let store = try SQLiteStateStore(
            databaseURL: stateRoot.appendingPathComponent("manager.sqlite3")
        )
        let requestID = UUID(
            uuidString: "11111111-2222-4333-8444-555555555555"
        )!
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
        return try CodexGhostRepairBulkProductionBundle(
            coldReadback: stored,
            testOwnedCodexHomeURL: fixture.codexHome,
            testOwnedAllowedParentURL: fixture.sourceParent
        ).resolveForTestOwnedAdoption()
    }

    private func makeWindow(
        _ resolution: CodexGhostRepairBulkProductionBundle.Resolution,
        fingerprint: String
    ) throws -> CodexGhostRepairBulkMaintenanceWindow {
        let before = try CodexGhostRepairBulkFreshMaintenanceReadback(
            collectionID: UUID(),
            phase: .beforeBackup,
            resolution: resolution,
            maintenance: maintenance(at: 10, fingerprint: fingerprint)
        )
        let after = try CodexGhostRepairBulkFreshMaintenanceReadback(
            collectionID: UUID(),
            phase: .afterBackup,
            resolution: resolution,
            maintenance: maintenance(at: 11, fingerprint: fingerprint)
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

private final class LiveBackupFixture: @unchecked Sendable {
    let sourceParent: URL
    let codexHome: URL
    let sqliteRoot: URL
    let managerParent: URL
    let managerRoot: URL
    let storageRoot: URL
    let operationRoot: URL

    init(createOperationStorage: Bool = true) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4f15-\(UUID().uuidString)", isDirectory: true)
        sourceParent = root.appendingPathComponent("source", isDirectory: true)
        codexHome = sourceParent.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        sqliteRoot = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        managerParent = root.appendingPathComponent("manager-parent", isDirectory: true)
        managerRoot = managerParent.appendingPathComponent("manager", isDirectory: true)
        storageRoot = managerRoot.appendingPathComponent("GhostRepair", isDirectory: true)
        operationRoot = storageRoot
            .appendingPathComponent("OperationBackups", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        var directories = [
            root,
            sourceParent,
            codexHome,
            sqliteRoot,
            managerParent,
            managerRoot,
            storageRoot,
        ]
        if createOperationStorage {
            directories.append(operationRoot.deletingLastPathComponent())
            directories.append(operationRoot)
        }
        for directory in directories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        try writePrivate(
            Data(CodexGhostRepairSnapshotCanonicalSource
                .testMirrorMarkerContents.utf8),
            to: codexHome.appendingPathComponent(
                CodexGhostRepairSnapshotCanonicalSource
                    .testMirrorMarkerFileName
            )
        )
        try writePrivate(
            Data(CodexGhostRepairBulkFixedBackupDestinationTestInspector
                .markerContents.utf8),
            to: managerRoot.appendingPathComponent(
                CodexGhostRepairBulkFixedBackupDestinationTestInspector
                    .markerFileName
            )
        )
        for file in [
            CodexGhostRepairSnapshotCanonicalFile.desktop,
            .summaries,
            .history,
            .state,
            .threadHistory,
        ] {
            try writePrivate(
                Data("fixture-\(file.rawValue)".utf8),
                to: file.sourceURL(
                    codexHomeURL: codexHome,
                    sqliteRootURL: sqliteRoot
                )
            )
        }
    }

    func canonicalSource() -> CodexGhostRepairSnapshotCanonicalSource {
        .init(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: sourceParent
        )
    }

    func operationIDs() -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: operationRoot.path
        )) ?? []
    }

    func members(
        _ record: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: operationURL(record).path
        ).sorted()
    }

    func destinationRecord(
        _ record: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) throws -> CodexGhostRepairBulkFixedBackupDestinationRecord {
        let data = try Data(contentsOf: operationURL(record)
            .appendingPathComponent("destination.json"))
        return try JSONDecoder().decode(
            CodexGhostRepairBulkFixedBackupDestinationRecord.self,
            from: data
        )
    }

    func installRecordOnly(
        _ record: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) throws {
        let operation = operationURL(record)
        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: operation.path
        )
        try writePrivate(
            try JSONEncoder().encode(record),
            to: operation.appendingPathComponent("destination.json")
        )
    }

    func receiptExists(
        _ record: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) -> Bool {
        FileManager.default.fileExists(
            atPath: operationURL(record)
                .appendingPathComponent("receipt.json").path
        )
    }

    func makeSourceUnreadable() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: codexHome.path
        )
    }

    func appendToDesktopDatabase() throws {
        let url = CodexGhostRepairSnapshotCanonicalFile.desktop.sourceURL(
            codexHomeURL: codexHome,
            sqliteRootURL: sqliteRoot
        )
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("-drift".utf8))
        try handle.synchronize()
    }

    func tamperCopiedDesktop(
        _ record: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) throws {
        let url = operationURL(record).appendingPathComponent("codex-dev.db")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("-tamper".utf8))
        try handle.synchronize()
    }

    private func operationURL(
        _ record: CodexGhostRepairBulkFixedBackupDestinationRecord
    ) -> URL {
        operationRoot.appendingPathComponent(
            record.destinationID,
            isDirectory: true
        )
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private final class OneShotMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    private let action: () throws -> Void

    init(_ action: @escaping () throws -> Void) {
        self.action = action
    }

    func run() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return }
        consumed = true
        try action()
    }
}

private func XCTAssertThrowsAsync<T>(
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
