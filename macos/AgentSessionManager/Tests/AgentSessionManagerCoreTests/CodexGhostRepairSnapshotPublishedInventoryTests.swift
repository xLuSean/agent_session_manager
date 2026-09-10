@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairSnapshotPublishedInventoryTests: XCTestCase {
    func testCleanupFactoryExposesExactRecoverableMoveOnly() {
        let coordinator =
            CodexGhostRepairSnapshotCleanupCoordinatorFactory.packaged()

        XCTAssertTrue(coordinator.capabilities.inspectionAvailable)
        XCTAssertTrue(coordinator.capabilities.moveToManagerTrashAvailable)
        XCTAssertFalse(coordinator.capabilities.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.permanentDeletionAuthority)
        XCTAssertFalse(coordinator.capabilities.opensRawDatabaseContents)
        XCTAssertFalse(coordinator.capabilities.codexDatabaseMutationAuthority)
        XCTAssertFalse(coordinator.capabilities.automaticCleanupAuthority)
        XCTAssertFalse(coordinator.capabilities.retryAllowed)
    }

    func testCleanupInspectProtectsActivePreviewAndLeavesExpiredHistoryEligible()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let protected = UUID()
        let eligible = UUID()
        try await fixture.publish(snapshotID: protected, publishedAt: 800)
        try await fixture.publish(snapshotID: eligible, publishedAt: 700)
        let dependencies = CleanupDependencyReader(values: [
            protected.uuidString.lowercased(): .init(
                activePreviewCount: 1,
                nonterminalRepairCount: 0,
                historicalReferenceCount: 1
            ),
            eligible.uuidString.lowercased(): .init(
                activePreviewCount: 0,
                nonterminalRepairCount: 0,
                historicalReferenceCount: 2
            ),
        ])
        let coordinator = fixture.cleanupCoordinator(dependencies: dependencies)

        let outcome = await coordinator.inspect()

        guard case let .observed(inventory) = outcome else {
            return XCTFail("Expected exact cleanup inventory")
        }
        XCTAssertEqual(inventory.activeSnapshotCount, 2)
        XCTAssertEqual(inventory.maximumSnapshotCount, 3)
        XCTAssertEqual(inventory.snapshots.map(\.reference), [
            eligible.uuidString.lowercased(),
            protected.uuidString.lowercased(),
        ])
        XCTAssertTrue(inventory.snapshots[0].canMoveToTrash)
        XCTAssertEqual(inventory.snapshots[0].historicalReferenceCount, 2)
        XCTAssertEqual(
            inventory.snapshots[1].eligibility,
            .protectedByActivePreview(count: 1)
        )
        XCTAssertFalse(inventory.snapshots[1].canMoveToTrash)
        XCTAssertFalse(inventory.permanentDeletionAuthority)
        XCTAssertFalse(inventory.codexDatabaseMutationAuthority)
    }

    func testCleanupMovesOneExactSnapshotAndCannotReplay() async throws {
        let fixture = try await makeFixture(label: #function)
        let selected = UUID()
        let retained = UUID()
        try await fixture.publish(snapshotID: selected, publishedAt: 700)
        try await fixture.publish(snapshotID: retained, publishedAt: 800)
        let dependencies = CleanupDependencyReader(values: [:])
        let coordinator = fixture.cleanupCoordinator(dependencies: dependencies)

        let prepared = await coordinator.prepare(
            snapshotReference: selected.uuidString.lowercased()
        )
        guard case let .ready(review) = prepared else {
            return XCTFail("Expected exact cleanup review")
        }
        XCTAssertEqual(review.snapshot.reference, selected.uuidString.lowercased())
        XCTAssertEqual(review.activeSnapshotCountBefore, 2)
        XCTAssertEqual(review.activeSnapshotCountAfter, 1)
        XCTAssertFalse(review.permanentDeletionAuthority)

        let outcome = await coordinator.execute(operationID: review.operationID)
        guard case let .completed(report) = outcome else {
            return XCTFail("Expected one exact completed move, got \(outcome)")
        }
        XCTAssertEqual(report.snapshotReference, selected.uuidString.lowercased())
        XCTAssertTrue(report.movedToManagerTrash)
        XCTAssertEqual(report.exactItemCount, 1)
        XCTAssertEqual(report.activeSnapshotCountAfter, 1)
        XCTAssertFalse(report.permanentDeletionPerformed)
        XCTAssertFalse(report.codexDatabaseMutated)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.snapshotRoot(selected).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.trashRoot.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(selected)
            ).path
        ))

        let active = try await fixture.collector.inventory(binding: fixture.binding)
        XCTAssertEqual(active.snapshots.map(\.snapshotID), [retained])
        let cold = try await fixture.recoveryReader().readbackInventory()
        XCTAssertEqual(
            cold.snapshots.map(\.state).sorted(by: { $0.rawValue < $1.rawValue }),
            [.movedToTrash, .published].sorted(by: { $0.rawValue < $1.rawValue })
        )
        XCTAssertEqual(cold.totalPublishedBytes, active.totalBytes)

        let replay = await coordinator.execute(operationID: review.operationID)
        guard case .recoveryRequired = replay else {
            return XCTFail("Claimed one-shot cleanup must never replay")
        }
    }

    func testCleanupDependencyDriftAfterReviewStopsBeforeMove() async throws {
        let fixture = try await makeFixture(label: #function)
        let selected = UUID()
        try await fixture.publish(snapshotID: selected, publishedAt: 700)
        let dependencies = MutableCleanupDependencyReader()
        let coordinator = fixture.cleanupCoordinator(dependencies: dependencies)
        guard case let .ready(review) = await coordinator.prepare(
            snapshotReference: selected.uuidString.lowercased()
        ) else {
            return XCTFail("Expected cleanup review")
        }
        await dependencies.set(.init(
            activePreviewCount: 0,
            nonterminalRepairCount: 1,
            historicalReferenceCount: 1
        ), for: selected.uuidString.lowercased())

        let outcome = await coordinator.execute(operationID: review.operationID)

        guard case .rejected = outcome else {
            return XCTFail("Fresh repair dependency must reject before claim")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.snapshotRoot(selected).path
        ))
    }

    func testPackagedReadbackFactoryExposesOnlyMetadataReadback() {
        let coordinator =
            CodexGhostRepairSnapshotReadbackCoordinatorFactory.packagedReadOnly()

        XCTAssertTrue(coordinator.capabilities.readbackAvailable)
        XCTAssertFalse(coordinator.capabilities.acceptsCallerPath)
        XCTAssertFalse(coordinator.capabilities.opensRawDatabaseContents)
        XCTAssertFalse(coordinator.capabilities.writesFilesystem)
        XCTAssertFalse(coordinator.capabilities.retryAllowed)
        XCTAssertFalse(coordinator.capabilities.cleanupAuthority)
        XCTAssertFalse(coordinator.capabilities.snapshotAcquisitionAuthority)
        XCTAssertFalse(coordinator.capabilities.repairMutationAuthority)
    }

    func testColdReadbackClassifiesAllDurableAcquisitionStates() async throws {
        let fixture = try await makeFixture(label: #function)
        let prepared = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let partial = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let interrupted = UUID(
            uuidString: "00000000-0000-4000-8000-000000000003"
        )!
        let published = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
        for snapshotID in [prepared, partial, interrupted] {
            _ = try await fixture.journal.prepare(
                snapshotID: snapshotID,
                targetThreadIDs: ["thread-\(snapshotID.uuidString.lowercased())"],
                sourceFingerprint: fixture.fingerprint,
                destinationBinding: fixture.binding
            )
        }
        try fixture.writePartial(
            snapshotID: partial,
            root: fixture.quarantineRoot
        )
        try fixture.writePartial(
            snapshotID: interrupted,
            root: fixture.snapshotsRoot
        )
        try await fixture.publish(snapshotID: published, publishedAt: 900)

        let reader = fixture.recoveryReader()
        let internalInventory = try await reader.readbackInventory()
        let coordinator = CodexGhostRepairSnapshotPackagedReadbackCoordinator(
            reader: reader
        )
        let outcome = await coordinator.readback()

        XCTAssertEqual(
            internalInventory.snapshots.map(\.state),
            [.preparedOnly, .unpublishedPartial, .publicationInterrupted, .published]
        )
        XCTAssertGreaterThan(internalInventory.totalPublishedBytes, 0)
        guard case let .observed(inventory) = outcome else {
            return XCTFail("Expected packaged cold readback evidence")
        }
        XCTAssertEqual(
            inventory.snapshots.map(\.state),
            [.preparedOnly, .unpublishedPartial, .publicationInterrupted, .published]
        )
        XCTAssertEqual(inventory.snapshots.map(\.targetCount), [1, 1, 1, 1])
        XCTAssertEqual(inventory.totalPublishedBytes, internalInventory.totalPublishedBytes)
        XCTAssertEqual(inventory.rawDatabaseContentsOpened, 0)
        XCTAssertTrue(inventory.pathRedacted)
        XCTAssertFalse(inventory.retryAllowed)
        XCTAssertFalse(inventory.cleanupAuthority)
        XCTAssertFalse(inventory.snapshotAcquisitionAuthority)
        XCTAssertFalse(inventory.repairMutationAuthority)
        XCTAssertNil(inventory.snapshots[0].manifestHash)
        XCTAssertNotNil(inventory.snapshots[3].manifestHash)
        XCTAssertNotNil(inventory.snapshots[3].publicationReceiptHash)
        XCTAssertNotNil(inventory.snapshots[3].actualPublishedBytes)
    }

    func testColdReadbackRejectsUnknownJournalEntryWithoutRetryAuthority()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        try PublishedInventoryWritePrivate(
            Data("unsupported".utf8),
            to: fixture.journalRoot.appendingPathComponent("unsupported.txt")
        )
        let coordinator = CodexGhostRepairSnapshotPackagedReadbackCoordinator(
            reader: fixture.recoveryReader()
        )

        let outcome = await coordinator.readback()

        guard case let .unavailable(message) = outcome else {
            return XCTFail("Expected unavailable cold readback")
        }
        XCTAssertEqual(
            message,
            "Fixed Ghost Repair snapshot readback is unavailable; do not retry acquisition or clean up automatically."
        )
        XCTAssertFalse(message.contains(fixture.journalRoot.path))
        XCTAssertFalse(coordinator.capabilities.retryAllowed)
        XCTAssertFalse(coordinator.capabilities.cleanupAuthority)
    }

    func testM2AnalysisIdentityResolvesOnlyFreshPublishedEvidence()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID(
            uuidString: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
        )!
        let targetThreadIDs = [
            "019f64d8-4be2-7c60-91ba-8687501cfd66",
            "019f64e3-ba20-7792-a7ab-1433db7ed8ec",
        ]
        try await fixture.publish(
            snapshotID: snapshotID,
            publishedAt: 900,
            targetThreadIDs: targetThreadIDs
        )
        let reader = fixture.recoveryReader()
        let internalInventory = try await reader.readbackInventory()
        let coordinator =
            CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator(
                reader: reader
            )

        let outcome = await coordinator.resolve(request: .init(
            snapshotReference: snapshotID.uuidString.lowercased()
        ))

        guard case let .resolved(identity) = outcome,
              let observed = internalInventory.snapshots.first else {
            return XCTFail("Expected fresh published M2 identity")
        }
        XCTAssertEqual(identity.snapshotReference, snapshotID.uuidString.lowercased())
        XCTAssertEqual(identity.targetThreadIDs, targetThreadIDs)
        XCTAssertEqual(identity.acquisitionRecordHash, observed.acquisitionRecordHash)
        XCTAssertEqual(identity.manifestHash, observed.publishedEvidence?.manifestHash)
        XCTAssertEqual(
            identity.publicationReceiptHash,
            observed.publishedEvidence?.publicationReceiptHash
        )
        XCTAssertEqual(identity.rawDatabaseContentsOpened, 0)
        XCTAssertFalse(identity.repairPreviewAuthority)
        XCTAssertFalse(identity.repairMutationAuthority)
    }

    func testProductionConstructionIsPathFreeMetadataOnlyAndReadOnly() {
        let collector =
            CodexGhostRepairSnapshotPublishedInventoryCollector.production()

        XCTAssertTrue(collector.capabilities.readsFixedPublishedInventory)
        XCTAssertFalse(collector.capabilities.opensRawDatabaseContents)
        XCTAssertFalse(collector.capabilities.acceptsCallerPath)
        XCTAssertFalse(collector.capabilities.writesFilesystem)
        XCTAssertFalse(collector.capabilities.automaticDeletionAuthority)
        XCTAssertFalse(collector.capabilities.cleanupAuthority)
        XCTAssertFalse(collector.capabilities.snapshotAcquisitionAuthority)
        XCTAssertFalse(collector.capabilities.repairMutationAuthority)
    }

    func testEmptyPublishedRootAllowsFirstProspectiveSnapshot() async throws {
        let fixture = try await makeFixture(label: #function)

        let assessment = try await fixture.collector.assess(
            binding: fixture.binding,
            prospectiveSnapshotBytes: 100,
            nowMilliseconds: 1_000
        )

        XCTAssertEqual(assessment.inventory.snapshots, [])
        XCTAssertEqual(assessment.inventory.totalBytes, 0)
        XCTAssertEqual(assessment.verdict, .allowed)
        XCTAssertNil(assessment.oldestPublishedAgeMilliseconds)
        XCTAssertEqual(assessment.inventory.rawDatabaseContentsOpened, 0)
        XCTAssertFalse(assessment.automaticDeletionAuthority)
        XCTAssertFalse(assessment.cleanupAuthority)
        XCTAssertFalse(assessment.snapshotAcquisitionAuthority)
        XCTAssertFalse(assessment.recoveryMutationAuthority)
        XCTAssertFalse(assessment.repairMutationAuthority)
    }

    func testPublishedInventoryBindsAcquisitionManifestReceiptAndMembership()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let later = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!
        let earlier = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        try await fixture.publish(snapshotID: later, publishedAt: 900)
        try await fixture.publish(snapshotID: earlier, publishedAt: 800)

        let first = try await fixture.collector.inventory(binding: fixture.binding)
        let second = try await fixture.collector.inventory(binding: fixture.binding)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.snapshots.map(\.snapshotID), [earlier, later])
        XCTAssertEqual(first.snapshots.map(\.publishedAtMilliseconds), [800, 900])
        XCTAssertTrue(first.snapshots.allSatisfy { !$0.rawDatabaseContentVerified })
        XCTAssertEqual(first.rawDatabaseContentsOpened, 0)
        XCTAssertEqual(
            first.totalBytes,
            first.snapshots.reduce(0) { $0 + $1.actualBytes }
        )
        XCTAssertTrue(first.snapshots.allSatisfy { $0.regularFileCount == 6 })
    }

    func testCountQuotaBlocksFourthSnapshotWithoutDeletingAnything() async throws {
        let fixture = try await makeFixture(label: #function)
        for _ in 0..<3 {
            try await fixture.publish(snapshotID: UUID(), publishedAt: 900)
        }
        let namesBefore = try fixture.storageNames()

        let assessment = try await fixture.collector.assess(
            binding: fixture.binding,
            prospectiveSnapshotBytes: 1,
            nowMilliseconds: 1_000
        )

        XCTAssertEqual(
            assessment.verdict,
            .blocked([.maximumSnapshotCountExceeded])
        )
        XCTAssertEqual(try fixture.storageNames(), namesBefore)
        XCTAssertFalse(assessment.automaticDeletionAuthority)
    }

    func testByteQuotaBlocksWithoutAutomaticCleanup() async throws {
        let fixture = try await makeFixture(label: #function)

        let assessment = try await fixture.collector.assess(
            binding: fixture.binding,
            prospectiveSnapshotBytes: 4_294_967_297,
            nowMilliseconds: 1_000
        )

        XCTAssertEqual(
            assessment.verdict,
            .blocked([.maximumTotalBytesExceeded])
        )
        XCTAssertEqual(try fixture.storageNames().snapshots, [])
    }

    func testAgeQuotaBlocksAndReportsOldestAge() async throws {
        let fixture = try await makeFixture(label: #function)
        try await fixture.publish(snapshotID: UUID(), publishedAt: 500)

        let assessment = try await fixture.collector.assess(
            binding: fixture.binding,
            prospectiveSnapshotBytes: 1,
            nowMilliseconds: 2_592_000_501
        )

        XCTAssertEqual(assessment.oldestPublishedAgeMilliseconds, 2_592_000_001)
        XCTAssertEqual(
            assessment.verdict,
            .blocked([.maximumPublishedAgeExceeded])
        )
    }

    func testUnsupportedSnapshotEntryFailsClosed() async throws {
        let fixture = try await makeFixture(label: #function)
        let unsupported = fixture.snapshotsRoot.appendingPathComponent(
            "notes", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unsupported,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(unsupported.path, 0o700), 0)

        await XCTAssertPublishedInventoryThrows(
            try await fixture.collector.inventory(binding: fixture.binding)
        )
    }

    func testPublicationReceiptMismatchFailsClosed() async throws {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()
        try await fixture.publish(snapshotID: snapshotID, publishedAt: 900)
        let receiptURL = fixture.receiptURL(snapshotID)
        try Data("tampered".utf8).write(to: receiptURL)
        XCTAssertEqual(chmod(receiptURL.path, 0o600), 0)

        await XCTAssertPublishedInventoryThrows(
            try await fixture.collector.inventory(binding: fixture.binding)
        )
    }

    func testRawDatabaseBytesAreNeverOpenedAsRetentionEvidence() async throws {
        let fixture = try await makeFixture(label: #function)
        let snapshotID = UUID()
        try await fixture.publish(snapshotID: snapshotID, publishedAt: 900)
        let first = try await fixture.collector.inventory(binding: fixture.binding)
        let rawDatabase = fixture.snapshotRoot(snapshotID).appendingPathComponent(
            CodexGhostRepairSnapshotCanonicalFile.desktop.rawValue
        )
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: rawDatabase.path)[.size]
                as? NSNumber
        ).intValue
        try Data(repeating: 0x58, count: size).write(to: rawDatabase)
        XCTAssertEqual(chmod(rawDatabase.path, 0o600), 0)

        let second = try await fixture.collector.inventory(binding: fixture.binding)

        XCTAssertEqual(second, first)
        XCTAssertEqual(second.rawDatabaseContentsOpened, 0)
    }

    func testPreparedDestinationDriftStopsInventory() async throws {
        let fixture = try await makeFixture(label: #function)
        XCTAssertEqual(chmod(fixture.snapshotsRoot.path, 0o755), 0)

        await XCTAssertPublishedInventoryThrows(
            try await fixture.collector.inventory(binding: fixture.binding)
        )
    }

    private struct StorageNames: Equatable {
        let snapshots: [String]
        let journal: [String]
    }

    private struct Fixture {
        let destination: CodexGhostRepairSnapshotPreparedDestination
        let journal: CodexGhostRepairSnapshotAcquisitionJournal
        let collector: CodexGhostRepairSnapshotPublishedInventoryCollector
        let binding: CodexGhostRepairSnapshotPreparedDestinationBinding
        let fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint
        let snapshotsRoot: URL
        let quarantineRoot: URL
        let journalRoot: URL
        let trashRoot: URL

        func snapshotRoot(_ snapshotID: UUID) -> URL {
            snapshotsRoot.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(snapshotID),
                isDirectory: true
            )
        }

        func receiptURL(_ snapshotID: UUID) -> URL {
            journalRoot.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .publicationReceiptName(snapshotID)
            )
        }

        func recoveryReader() -> CodexGhostRepairSnapshotRecoveryReader {
            CodexGhostRepairSnapshotRecoveryReader(
                destination: destination,
                journal: journal,
                publishedInventory: collector
            )
        }

        func cleanupCoordinator(
            dependencies: any CodexGhostRepairSnapshotCleanupDependencyReading
        ) -> CodexGhostRepairSnapshotCleanupCoordinator {
            CodexGhostRepairSnapshotCleanupCoordinator(
                destination: destination,
                inventoryCollector: collector,
                dependencyReader: dependencies,
                clock: { Date(timeIntervalSince1970: 1) }
            )
        }

        func writePartial(snapshotID: UUID, root: URL) throws {
            let directory = root.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(snapshotID),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(directory.path, 0o700) == 0 else {
                throw PublishedInventoryTestError.chmodFailed
            }
            try PublishedInventoryWritePrivate(
                Data("partial".utf8),
                to: directory.appendingPathComponent(
                    CodexGhostRepairSnapshotCanonicalFile.desktop.rawValue
                )
            )
        }

        func storageNames() throws -> StorageNames {
            StorageNames(
                snapshots: try FileManager.default.contentsOfDirectory(
                    atPath: snapshotsRoot.path
                ).sorted(),
                journal: try FileManager.default.contentsOfDirectory(
                    atPath: journalRoot.path
                ).sorted()
            )
        }

        func publish(
            snapshotID: UUID,
            publishedAt: Int64,
            targetThreadIDs: [String]? = nil
        ) async throws {
            let acquisition = try await journal.prepare(
                snapshotID: snapshotID,
                targetThreadIDs: targetThreadIDs
                    ?? ["thread-\(snapshotID.uuidString.lowercased())"],
                sourceFingerprint: fingerprint,
                destinationBinding: binding
            )
            let root = snapshotRoot(snapshotID)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(root.path, 0o700) == 0 else {
                throw PublishedInventoryTestError.chmodFailed
            }
            for file in fingerprint.files where file.exists {
                let size = Int(try XCTUnwrap(file.size))
                try PublishedInventoryWritePrivate(
                    Data(repeating: 0x41, count: size),
                    to: root.appendingPathComponent(file.fileName)
                )
            }
            let manifest = try CodexGhostRepairSnapshotPublishedManifest(
                snapshotID: snapshotID,
                sourceFingerprint: fingerprint,
                destinationBinding: binding,
                acquiredAtMilliseconds: acquisition.preparedAtMilliseconds
            )
            try PublishedInventoryWriteJSON(
                manifest,
                to: root.appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedFormat.manifestFileName
                )
            )
            let receipt = try CodexGhostRepairSnapshotPublicationReceipt(
                snapshotID: snapshotID,
                acquisitionRecordHash: acquisition.recordHash,
                manifestHash: manifest.manifestHash,
                destinationBindingHash: binding.bindingHash,
                publishedAtMilliseconds: publishedAt
            )
            try PublishedInventoryWriteJSON(receipt, to: receiptURL(snapshotID))
            try PublishedInventoryWritePrivate(
                Data(CodexGhostRepairSnapshotPublishedFormat.markerContents.utf8),
                to: root.appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedFormat.markerFileName
                )
            )
        }
    }

    private func makeFixture(label: String) async throws -> Fixture {
        let safe = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-m1b5-\(safe)-\(UUID().uuidString)",
            isDirectory: true
        )
        let codexHome = parent.appendingPathComponent(".codex", isDirectory: true)
        let sqlite = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        let appSupport = parent.appendingPathComponent(
            "Application Support", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sqlite,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in [parent, codexHome, sqlite, appSupport] {
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
        }
        try PublishedInventoryWritePrivate(
            Data(
                CodexGhostRepairSnapshotCanonicalSource
                    .testMirrorMarkerContents.utf8
            ),
            to: codexHome.appendingPathComponent(
                CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerFileName
            )
        )
        for file in CodexGhostRepairSnapshotCanonicalFile.allCases
            where file.isRequiredDatabase {
            try PublishedInventoryWritePrivate(
                Data("M1b-5 \(file.rawValue)\n".utf8),
                to: file.sourceURL(
                    codexHomeURL: codexHome,
                    sqliteRootURL: sqlite
                )
            )
        }
        try PublishedInventoryWritePrivate(
            Data(
                CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                    .testRootMarkerContents.utf8
            ),
            to: parent.appendingPathComponent(
                CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                    .testRootMarkerFileName
            )
        )
        let entries = CodexGhostRepairDestinationCanaryFixedLayout.entries(
            applicationSupport: appSupport
        )
        for entry in entries {
            let mode: mode_t = entry.directory == .applicationBundleRoot
                ? 0o755 : 0o700
            try FileManager.default.createDirectory(
                at: entry.url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)]
            )
            XCTAssertEqual(chmod(entry.url.path, mode), 0)
        }
        let urls = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.directory, $0.url) }
        )
        let destination = CodexGhostRepairSnapshotPreparedDestination(
            testOwnedApplicationSupportDirectory: appSupport,
            testOwnedAllowedParentURL: parent,
            capacityProbe: PublishedInventoryCapacityProbe()
        )
        let binding = try await destination.bindPrepared()
        let source = CodexGhostRepairSnapshotCanonicalSource(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: parent
        )
        let fingerprint = try source.fingerprint()
        let journal = CodexGhostRepairSnapshotAcquisitionJournal(
            destination: destination,
            clock: { Date(timeIntervalSince1970: 0.5) }
        )
        return Fixture(
            destination: destination,
            journal: journal,
            collector: CodexGhostRepairSnapshotPublishedInventoryCollector(
                destination: destination,
                journal: journal
            ),
            binding: binding,
            fingerprint: fingerprint,
            snapshotsRoot: try XCTUnwrap(urls[.snapshots]),
            quarantineRoot: try XCTUnwrap(urls[.quarantine]),
            journalRoot: try XCTUnwrap(urls[.journal]),
            trashRoot: try XCTUnwrap(urls[.trash])
        )
    }
}

private struct CleanupDependencyReader:
    CodexGhostRepairSnapshotCleanupDependencyReading
{
    let values: [String: CodexGhostRepairSnapshotCleanupDependencyEvidence]

    func evidence(
        snapshotReference: String,
        nowMilliseconds _: Int64
    ) async throws -> CodexGhostRepairSnapshotCleanupDependencyEvidence {
        values[snapshotReference] ?? .init(
            activePreviewCount: 0,
            nonterminalRepairCount: 0,
            historicalReferenceCount: 0
        )
    }
}

private actor MutableCleanupDependencyReader:
    CodexGhostRepairSnapshotCleanupDependencyReading
{
    private var values: [String: CodexGhostRepairSnapshotCleanupDependencyEvidence]
        = [:]

    func set(
        _ evidence: CodexGhostRepairSnapshotCleanupDependencyEvidence,
        for reference: String
    ) {
        values[reference] = evidence
    }

    func evidence(
        snapshotReference: String,
        nowMilliseconds _: Int64
    ) async throws -> CodexGhostRepairSnapshotCleanupDependencyEvidence {
        values[snapshotReference] ?? .init(
            activePreviewCount: 0,
            nonterminalRepairCount: 0,
            historicalReferenceCount: 0
        )
    }
}

private struct PublishedInventoryCapacityProbe:
    CodexGhostRepairSnapshotDestinationCapacityProbing
{
    func availableCapacity(at _: URL) async throws -> UInt64 { .max }
}

private enum PublishedInventoryTestError: Error {
    case chmodFailed
}

private func PublishedInventoryWriteJSON<T: Encodable>(
    _ value: T,
    to url: URL
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try PublishedInventoryWritePrivate(try encoder.encode(value), to: url)
}

private func PublishedInventoryWritePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
    guard chmod(url.path, 0o600) == 0 else {
        throw PublishedInventoryTestError.chmodFailed
    }
}

private func XCTAssertPublishedInventoryThrows<T>(
    _ expression: @autoclosure () async throws -> T
) async {
    do {
        _ = try await expression()
        XCTFail("Expected published inventory operation to throw")
    } catch {}
}
