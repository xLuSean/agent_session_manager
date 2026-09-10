#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import CSQLite3
import Foundation
import XCTest

final class CodexGhostRepairDisposableSnapshotAcquirerTests: XCTestCase {
    func testStableSourcePublishesPrivateExactSnapshotReadableByE25() async throws {
        let fixture = try makeFixture(label: #function)
        let sourceBefore = try sourceFileState(fixture.bundle)
        let gates = SequencedAcquisitionGateSource([clearGate, clearGate])
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: fixture.bundle,
            destination: fixture.destination,
            gateSource: gates,
            journal: fixture.journal,
            capacityProbe: fixture.capacityProbe
        )
        let snapshotID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

        let result = try await acquirer.acquire(snapshotID: snapshotID)

        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 2)
        XCTAssertEqual(result.manifest.snapshotID, snapshotID)
        XCTAssertTrue(result.manifest.preflightGate.isClear)
        XCTAssertTrue(result.manifest.postCopyGate.isClear)
        XCTAssertEqual(result.manifest.files.count, 12)
        XCTAssertEqual(result.manifest.files.filter(\.exists).count, 3)
        XCTAssertTrue(result.manifest.capacity.isSufficient)
        XCTAssertEqual(result.manifest.capacity.reservedCopyCount, 2)
        try result.manifest.validateHash()
        let journalReadback = try await fixture.journal.readback(snapshotID: snapshotID)
        XCTAssertEqual(journalReadback.durableRecord.status, .published)
        XCTAssertEqual(journalReadback.observedStatus, .published)
        XCTAssertEqual(
            journalReadback.durableRecord.manifestHash,
            result.manifest.manifestHash
        )
        XCTAssertFalse(journalReadback.recoveryMutationAuthority)
        XCTAssertEqual(try sourceFileState(fixture.bundle), sourceBefore)
        XCTAssertTrue(
            result.bundle.rootURL.path.hasPrefix(
                fixture.destination.snapshotsRootURL.path + "/"
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.quarantineRoot(snapshotID: snapshotID).path
            )
        )
        XCTAssertNil(try fixture.destination.partialRecord(snapshotID: snapshotID))
        let rootAttributes = try FileManager.default.attributesOfItem(
            atPath: result.bundle.rootURL.path
        )
        XCTAssertEqual(
            (rootAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        let manifestAttributes = try FileManager.default.attributesOfItem(
            atPath: result.manifestURL.path
        )
        XCTAssertEqual(
            (manifestAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(
                atPath: result.bundle.rootURL.path
            )),
            Set([
                "codex-dev.db",
                "codex-thread-summaries-dev.db",
                "codex-history-snapshots-dev.db",
                CodexGhostRepairDisposableSnapshotAcquirer.manifestFileName,
                CodexGhostRepairDisposableBundle.markerFileName,
            ])
        )
        XCTAssertEqual(
            try Data(contentsOf: result.bundle.desktopDatabaseURL),
            try Data(contentsOf: fixture.bundle.desktopDatabaseURL)
        )
        for sourceURL in databaseURLs(fixture.bundle) {
            let destination = result.bundle.rootURL.appendingPathComponent(
                sourceURL.lastPathComponent
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: destination.path
            )
            XCTAssertEqual(
                (attributes[.posixPermissions] as? NSNumber)?.intValue,
                0o600
            )
            for suffix in ["-wal", "-shm", "-journal"] {
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: destination.path + suffix
                    )
                )
            }
        }
        let evidence = try CodexGhostRepairDisposableSnapshotReader.read(
            bundle: result.bundle,
            targetIDs: [fixture.threadID]
        )
        XCTAssertEqual(evidence.targets.map(\.threadID), [fixture.threadID])
        XCTAssertTrue(evidence.satisfiesPrivacyContract)

        let manifestJSON = String(
            data: try Data(contentsOf: result.manifestURL),
            encoding: .utf8
        )!
        XCTAssertFalse(manifestJSON.contains(fixture.bundle.rootURL.path))
        XCTAssertTrue(manifestJSON.contains("sourceRootDigest"))
    }

    func testStableSidecarsAreCopiedExactlyWithoutOpeningSQLite() async throws {
        let fixture = try makeFixture(label: #function)
        try createSentinelSidecars(for: fixture.bundle)
        let sourceBefore = try sourceFileState(fixture.bundle)
        let gates = SequencedAcquisitionGateSource([clearGate, clearGate])
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: fixture.bundle,
            destination: fixture.destination,
            gateSource: gates,
            journal: fixture.journal,
            capacityProbe: fixture.capacityProbe
        )

        let result = try await acquirer.acquire(snapshotID: UUID())

        XCTAssertEqual(result.manifest.files.filter(\.exists).count, 12)
        XCTAssertEqual(
            result.manifest.capacity.sourceBytes,
            try totalSourceBytes(fixture.bundle)
        )
        let observedCapacityURLs = await fixture.capacityProbe.observedURLs()
        XCTAssertEqual(
            observedCapacityURLs,
            [fixture.destination.applicationSupportDirectoryURL]
        )
        XCTAssertEqual(try sourceFileState(fixture.bundle), sourceBefore)
        for sourceURL in databaseURLs(fixture.bundle) {
            for suffix in ["-wal", "-shm", "-journal"] {
                let sourceSidecar = URL(fileURLWithPath: sourceURL.path + suffix)
                let destinationSidecar = result.bundle.rootURL.appendingPathComponent(
                    sourceURL.lastPathComponent + suffix
                )
                XCTAssertEqual(
                    try Data(contentsOf: destinationSidecar),
                    try Data(contentsOf: sourceSidecar)
                )
            }
        }
    }

    func testInsufficientSidecarAwareCapacityStopsBeforeStorageOrCopy() async throws {
        let fixture = try makeFixture(label: #function)
        try createSentinelSidecars(for: fixture.bundle)
        let sourceBytes = try totalSourceBytes(fixture.bundle)
        let requiredBytes = sourceBytes * 2
            + fixture.destination.fixedCapacityHeadroomBytes
        let capacity = RecordingSnapshotCapacityProbe(
            availableBytes: requiredBytes - 1
        )
        let gates = SequencedAcquisitionGateSource([clearGate])
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: fixture.bundle,
            destination: fixture.destination,
            gateSource: gates,
            journal: fixture.journal,
            capacityProbe: capacity
        )
        let snapshotID = UUID()

        let error = await XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(snapshotID: snapshotID)
        )

        XCTAssertEqual(error as? CodexGhostRepairError, .executionGateBlocked)
        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.destination.journalRootURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.quarantineRoot(snapshotID: snapshotID).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.publishedRoot(snapshotID: snapshotID).path
            )
        )
        let journalReadback = try await fixture.journal.readback(snapshotID: snapshotID)
        XCTAssertEqual(journalReadback.durableRecord.status, .failedWithoutPartial)
        XCTAssertNil(journalReadback.partial)
        let observedCapacityURLs = await capacity.observedURLs()
        XCTAssertEqual(
            observedCapacityURLs,
            [fixture.destination.applicationSupportDirectoryURL]
        )
    }

    func testSourceAndManagerApplicationSupportDestinationMustBeDisjoint() async throws {
        let fixture = try makeFixture(label: #function)
        let overlappingDestination = try CodexGhostRepairDisposableSnapshotDestination(
            applicationSupportDirectoryURL: fixture.bundle.rootURL,
            allowedParentURL: fixture.bundle.allowedParentURL,
            fixedCapacityHeadroomBytes: 0
        )
        let gates = SequencedAcquisitionGateSource([clearGate])
        let capacity = RecordingSnapshotCapacityProbe(availableBytes: .max)
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: fixture.bundle,
            destination: overlappingDestination,
            gateSource: gates,
            journal: CodexGhostRepairSnapshotJournal(
                destination: overlappingDestination
            ),
            capacityProbe: capacity
        )

        let error = await XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(snapshotID: UUID())
        )

        guard case .invalidDisposablePath = error as? CodexGhostRepairError else {
            return XCTFail(
                "Expected invalidDisposablePath, found \(String(describing: error))"
            )
        }
        let gateCallCount = await gates.callCount()
        let observedCapacityURLs = await capacity.observedURLs()
        XCTAssertEqual(gateCallCount, 0)
        XCTAssertTrue(observedCapacityURLs.isEmpty)
    }

    func testPreflightAndPostCopyGateFailuresNeverPublishMarker() async throws {
        let preflightFixture = try makeFixture(label: "\(#function)-preflight")
        let preflightID = UUID()
        let preflightAcquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: preflightFixture.bundle,
            destination: preflightFixture.destination,
            gateSource: SequencedAcquisitionGateSource([blockedGate]),
            journal: preflightFixture.journal,
            capacityProbe: preflightFixture.capacityProbe
        )
        let preflightError = await XCTAssertThrowsErrorAsync(
            try await preflightAcquirer.acquire(snapshotID: preflightID)
        )
        XCTAssertEqual(
            preflightError as? CodexGhostRepairError,
            .executionGateBlocked
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: preflightFixture.destination
                    .quarantineRoot(snapshotID: preflightID).path
            )
        )
        let postFixture = try makeFixture(label: "\(#function)-post")
        let postID = UUID()
        let postAcquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: postFixture.bundle,
            destination: postFixture.destination,
            gateSource: SequencedAcquisitionGateSource([clearGate, blockedGate]),
            journal: postFixture.journal,
            capacityProbe: postFixture.capacityProbe
        )
        let postError = await XCTAssertThrowsErrorAsync(
            try await postAcquirer.acquire(snapshotID: postID)
        )
        XCTAssertEqual(postError as? CodexGhostRepairError, .executionGateBlocked)
        let postRoot = postFixture.destination.quarantineRoot(snapshotID: postID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: postRoot.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: postFixture.destination.publishedRoot(snapshotID: postID).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: postRoot.appendingPathComponent(
                    CodexGhostRepairDisposableBundle.markerFileName
                ).path
            )
        )
        XCTAssertThrowsError(
            try CodexGhostRepairDisposableBundle(
                rootURL: postRoot,
                allowedParentURL: postFixture.destination.quarantineRootURL
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: postRoot.appendingPathComponent(
                    CodexGhostRepairDisposableSnapshotAcquirer.manifestFileName
                ).path
            )
        )
        let quarantineRecord = try XCTUnwrap(
            postFixture.destination.partialRecord(snapshotID: postID)
        )
        XCTAssertEqual(quarantineRecord.status, .unpublishedPartial)
        XCTAssertFalse(quarantineRecord.markerPresent)
        XCTAssertFalse(quarantineRecord.manifestPresent)
        XCTAssertFalse(quarantineRecord.recoveryMutationAuthority)
        let postJournal = try await postFixture.journal.readback(snapshotID: postID)
        XCTAssertEqual(postJournal.durableRecord.status, .unpublishedPartial)
        XCTAssertEqual(postJournal.observedStatus, .unpublishedPartial)
    }

    func testInterruptedAfterMoveBeforeMarkerStaysUnpublishedAndReadbackOnly() async throws {
        let fixture = try makeFixture(label: #function)
        let snapshotID = UUID()
        let gates = SequencedAcquisitionGateSource([clearGate, clearGate])
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: fixture.bundle,
            destination: fixture.destination,
            gateSource: gates,
            journal: fixture.journal,
            capacityProbe: fixture.capacityProbe
        )

        let error = await XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(
                snapshotID: snapshotID,
                afterMoveBeforeMarkerForTesting: {
                    throw TestSnapshotInterruption.injected
                }
            )
        )

        guard case .snapshotAcquisitionFailed = error as? CodexGhostRepairError else {
            return XCTFail(
                "Expected snapshotAcquisitionFailed, found \(String(describing: error))"
            )
        }
        let publishedRoot = fixture.destination.publishedRoot(snapshotID: snapshotID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedRoot.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.quarantineRoot(snapshotID: snapshotID).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: publishedRoot.appendingPathComponent(
                    CodexGhostRepairDisposableBundle.markerFileName
                ).path
            )
        )
        XCTAssertThrowsError(
            try CodexGhostRepairDisposableBundle(
                rootURL: publishedRoot,
                allowedParentURL: fixture.destination.snapshotsRootURL
            )
        )
        let partial = try XCTUnwrap(
            fixture.destination.partialRecord(snapshotID: snapshotID)
        )
        XCTAssertEqual(partial.status, .publicationInterrupted)
        XCTAssertTrue(partial.manifestPresent)
        XCTAssertFalse(partial.markerPresent)
        XCTAssertFalse(partial.recoveryMutationAuthority)
    }

    func testInterruptedAfterMarkerIsRecoveredAsPublishedWithoutRetryAuthority() async throws {
        let fixture = try makeFixture(label: #function)
        let snapshotID = UUID()
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: fixture.bundle,
            destination: fixture.destination,
            gateSource: SequencedAcquisitionGateSource([clearGate, clearGate]),
            journal: fixture.journal,
            capacityProbe: fixture.capacityProbe
        )

        let error = await XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(
                snapshotID: snapshotID,
                afterMarkerBeforeJournalForTesting: {
                    throw TestSnapshotInterruption.injected
                }
            )
        )

        guard case .snapshotAcquisitionFailed = error as? CodexGhostRepairError else {
            return XCTFail(
                "Expected snapshotAcquisitionFailed, found \(String(describing: error))"
            )
        }
        XCTAssertNil(try fixture.destination.partialRecord(snapshotID: snapshotID))
        let readback = try await fixture.journal.readback(snapshotID: snapshotID)
        XCTAssertEqual(readback.durableRecord.status, .published)
        XCTAssertEqual(readback.observedStatus, .published)
        XCTAssertNotNil(readback.durableRecord.manifestHash)
        XCTAssertFalse(readback.recoveryMutationAuthority)
    }

    func testSourceIdentityDriftAndSymlinkedSidecarFailClosedUnpublished() async throws {
        let driftFixture = try makeFixture(label: "\(#function)-drift")
        let driftID = UUID()
        let originalSummaries = try Data(
            contentsOf: driftFixture.bundle.summariesDatabaseURL
        )
        let driftAcquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: driftFixture.bundle,
            destination: driftFixture.destination,
            gateSource: SequencedAcquisitionGateSource([clearGate, clearGate]),
            journal: driftFixture.journal,
            capacityProbe: driftFixture.capacityProbe
        )
        let driftError = await XCTAssertThrowsErrorAsync(
            try await driftAcquirer.acquire(
                snapshotID: driftID,
                afterCopyForTesting: {
                    try originalSummaries.write(
                        to: driftFixture.bundle.summariesDatabaseURL,
                        options: .atomic
                    )
                }
            )
        )
        guard case .targetDrift = driftError as? CodexGhostRepairError else {
            return XCTFail("Expected targetDrift, found \(String(describing: driftError))")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: driftFixture.destination.quarantineRoot(snapshotID: driftID)
                    .appendingPathComponent(
                        CodexGhostRepairDisposableBundle.markerFileName
                    ).path
            )
        )

        let symlinkFixture = try makeFixture(label: "\(#function)-symlink")
        let outside = symlinkFixture.bundle.allowedParentURL.appendingPathComponent(
            "outside-wal"
        )
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: URL(fileURLWithPath: symlinkFixture.bundle.desktopDatabaseURL.path + "-wal"),
            withDestinationURL: outside
        )
        let symlinkID = UUID()
        let symlinkAcquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: symlinkFixture.bundle,
            destination: symlinkFixture.destination,
            gateSource: SequencedAcquisitionGateSource([clearGate]),
            journal: symlinkFixture.journal,
            capacityProbe: symlinkFixture.capacityProbe
        )
        let symlinkError = await XCTAssertThrowsErrorAsync(
            try await symlinkAcquirer.acquire(snapshotID: symlinkID)
        )
        guard case .snapshotAcquisitionFailed = symlinkError as? CodexGhostRepairError else {
            return XCTFail(
                "Expected snapshotAcquisitionFailed, found \(String(describing: symlinkError))"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: symlinkFixture.destination
                    .quarantineRoot(snapshotID: symlinkID).path
            )
        )
    }

    func testSameSnapshotIDCannotReplayOrOverwritePublishedSnapshot() async throws {
        let fixture = try makeFixture(label: #function)
        let gates = SequencedAcquisitionGateSource([clearGate, clearGate])
        let acquirer = CodexGhostRepairDisposableSnapshotAcquirer(
            source: fixture.bundle,
            destination: fixture.destination,
            gateSource: gates,
            journal: fixture.journal,
            capacityProbe: fixture.capacityProbe
        )
        let snapshotID = UUID()
        let first = try await acquirer.acquire(snapshotID: snapshotID)
        let firstManifest = try Data(contentsOf: first.manifestURL)

        let replayError = await XCTAssertThrowsErrorAsync(
            try await acquirer.acquire(snapshotID: snapshotID)
        )
        XCTAssertEqual(replayError as? CodexGhostRepairError, .claimAlreadyExists)

        let gateCallCount = await gates.callCount()
        XCTAssertEqual(gateCallCount, 2)
        XCTAssertEqual(try Data(contentsOf: first.manifestURL), firstManifest)
        try first.manifest.validateHash()
    }

    func testJournalRestartReadbackFindsAcquiringPartialWithoutRetryAuthority() async throws {
        let fixture = try makeFixture(label: #function)
        let snapshotID = UUID()
        try fixture.destination.preparePrivateDirectories()
        _ = try await fixture.journal.begin(
            snapshotID: snapshotID,
            sourceRootDigest: try CodexGhostRepairHasher.hash(fixture.bundle.rootURL.path),
            nowMilliseconds: 1_000
        )
        try await fixture.journal.markAcquiring(
            snapshotID: snapshotID,
            nowMilliseconds: 1_001
        )
        try createQuarantinePartial(
            destination: fixture.destination,
            snapshotID: snapshotID,
            contents: "interrupted copy"
        )

        let restartedJournal = CodexGhostRepairSnapshotJournal(
            destination: fixture.destination
        )
        let readback = try await restartedJournal.readback(snapshotID: snapshotID)

        XCTAssertEqual(readback.durableRecord.status, .acquiring)
        XCTAssertEqual(readback.observedStatus, .unpublishedPartial)
        XCTAssertEqual(readback.partial?.status, .unpublishedPartial)
        XCTAssertFalse(readback.recoveryMutationAuthority)
        let journalRecords = try await restartedJournal.records()
        XCTAssertEqual(journalRecords.count, 1)
    }

    func testExactQuarantineTrashPreviewClaimsOnceAndUsesFreshReadback() async throws {
        let fixture = try makeFixture(label: #function)
        try fixture.destination.preparePrivateDirectories()
        let firstID = UUID()
        let secondID = UUID()
        try createQuarantinePartial(
            destination: fixture.destination,
            snapshotID: firstID,
            contents: "first"
        )
        try createQuarantinePartial(
            destination: fixture.destination,
            snapshotID: secondID,
            contents: "second"
        )
        let fakeTrash = fixture.destination.allowedParentURL.appendingPathComponent(
            "Fake Trash",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: false)
        let transport = RecordingQuarantineTrashTransport(
            fakeTrashRoot: fakeTrash,
            behavior: .moveAll
        )
        let coordinator = CodexGhostRepairQuarantineTrashCoordinator(
            destination: fixture.destination,
            transport: transport
        )
        let previewID = UUID()
        let preview = try await coordinator.prepare(
            previewID: previewID,
            snapshotIDs: [secondID, firstID],
            nowMilliseconds: 2_000
        )

        XCTAssertEqual(
            preview.targets.map(\.snapshotID),
            [firstID, secondID].sorted { $0.uuidString < $1.uuidString }
        )
        XCTAssertFalse(preview.recoveryMutationAuthority)
        let report = try await coordinator.execute(
            previewID: previewID,
            expectedManifestHash: preview.manifestHash,
            nowMilliseconds: 2_001
        )

        XCTAssertEqual(report.outcome, .movedToTrash)
        XCTAssertTrue(report.items.allSatisfy(\.absentFromQuarantine))
        XCTAssertTrue(report.mutationAttemptedOnce)
        XCTAssertFalse(report.mutationRetryAllowed)
        XCTAssertFalse(report.recoveredByReadback)
        var transportCallCount = await transport.callCount()
        let movedURLs = await transport.movedURLs()
        XCTAssertEqual(transportCallCount, 1)
        XCTAssertEqual(movedURLs.count, 2)

        let replay = await XCTAssertThrowsErrorAsync(
            try await coordinator.execute(
                previewID: previewID,
                expectedManifestHash: preview.manifestHash,
                nowMilliseconds: 2_002
            )
        )
        XCTAssertEqual(replay as? CodexGhostRepairError, .claimAlreadyExists)
        transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 1)
    }

    func testQuarantineTrashDriftFailsBeforeClaimAndTransport() async throws {
        let fixture = try makeFixture(label: #function)
        try fixture.destination.preparePrivateDirectories()
        let snapshotID = UUID()
        let partialFile = try createQuarantinePartial(
            destination: fixture.destination,
            snapshotID: snapshotID,
            contents: "before"
        )
        let fakeTrash = fixture.destination.allowedParentURL.appendingPathComponent(
            "Fake Trash",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: false)
        let transport = RecordingQuarantineTrashTransport(
            fakeTrashRoot: fakeTrash,
            behavior: .moveAll
        )
        let coordinator = CodexGhostRepairQuarantineTrashCoordinator(
            destination: fixture.destination,
            transport: transport
        )
        let preview = try await coordinator.prepare(
            previewID: UUID(),
            snapshotIDs: [snapshotID],
            nowMilliseconds: 3_000
        )
        try Data("after".utf8).write(to: partialFile, options: .atomic)

        let error = await XCTAssertThrowsErrorAsync(
            try await coordinator.execute(
                previewID: preview.id,
                expectedManifestHash: preview.manifestHash,
                nowMilliseconds: 3_001
            )
        )

        guard case .targetDrift = error as? CodexGhostRepairError else {
            return XCTFail("Expected targetDrift, found \(String(describing: error))")
        }
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destination.quarantineRoot(snapshotID: snapshotID).path
            )
        )
    }

    func testTrashTransportPartialFailureProducesReadbackReportWithoutRetry() async throws {
        let fixture = try makeFixture(label: #function)
        try fixture.destination.preparePrivateDirectories()
        let firstID = UUID()
        let secondID = UUID()
        try createQuarantinePartial(
            destination: fixture.destination,
            snapshotID: firstID,
            contents: "first"
        )
        try createQuarantinePartial(
            destination: fixture.destination,
            snapshotID: secondID,
            contents: "second"
        )
        let fakeTrash = fixture.destination.allowedParentURL.appendingPathComponent(
            "Fake Trash",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: false)
        let transport = RecordingQuarantineTrashTransport(
            fakeTrashRoot: fakeTrash,
            behavior: .moveFirstThenThrow
        )
        let coordinator = CodexGhostRepairQuarantineTrashCoordinator(
            destination: fixture.destination,
            transport: transport
        )
        let preview = try await coordinator.prepare(
            previewID: UUID(),
            snapshotIDs: [firstID, secondID],
            nowMilliseconds: 4_000
        )

        let report = try await coordinator.execute(
            previewID: preview.id,
            expectedManifestHash: preview.manifestHash,
            nowMilliseconds: 4_001
        )

        XCTAssertEqual(report.outcome, .partial)
        XCTAssertEqual(report.items.filter(\.absentFromQuarantine).count, 1)
        XCTAssertTrue(report.recoveredByReadback)
        XCTAssertFalse(report.mutationRetryAllowed)
        var transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 1)
        let recovered = try await coordinator.recover(
            previewID: preview.id,
            nowMilliseconds: 4_002
        )
        XCTAssertEqual(recovered, report)
        transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 1)
    }

    private struct Fixture {
        let bundle: CodexGhostRepairDisposableBundle
        let destination: CodexGhostRepairDisposableSnapshotDestination
        let journal: CodexGhostRepairSnapshotJournal
        let capacityProbe: RecordingSnapshotCapacityProbe
        let threadID: String
    }

    private var clearGate: CodexGhostRepairExecutionGate {
        CodexGhostRepairExecutionGate(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: true
        )
    }

    private var blockedGate: CodexGhostRepairExecutionGate {
        CodexGhostRepairExecutionGate(
            codexFullyExited: false,
            desktopOpenHandleCount: 1,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: true
        )
    }

    private func makeFixture(label: String) throws -> Fixture {
        let sanitized = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e26-\(sanitized)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let root = parent.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data(CodexGhostRepairDisposableBundle.markerContents.utf8).write(
            to: root.appendingPathComponent(CodexGhostRepairDisposableBundle.markerFileName)
        )
        let desktop = root.appendingPathComponent("codex-dev.db")
        let summaries = root.appendingPathComponent("codex-thread-summaries-dev.db")
        let history = root.appendingPathComponent("codex-history-snapshots-dev.db")
        try createDesktopFixture(at: desktop)
        try createSideFixture(at: summaries, version: 2, table: "thread_turn_summaries")
        try createSideFixture(
            at: history,
            version: 3,
            table: "app_server_history_snapshots"
        )
        let threadID = "e26-target"
        try executeSQL(
            "INSERT INTO local_thread_catalog(host_id,thread_id,missing_candidate,private_title) VALUES ('local','\(threadID)',0,'private title')",
            at: desktop
        )
        let applicationSupport = parent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: false
        )
        let destination = try CodexGhostRepairDisposableSnapshotDestination(
            applicationSupportDirectoryURL: applicationSupport,
            allowedParentURL: parent,
            fixedCapacityHeadroomBytes: 4_096
        )
        return Fixture(
            bundle: try CodexGhostRepairDisposableBundle(
                rootURL: root,
                allowedParentURL: parent
            ),
            destination: destination,
            journal: CodexGhostRepairSnapshotJournal(destination: destination),
            capacityProbe: RecordingSnapshotCapacityProbe(availableBytes: .max),
            threadID: threadID
        )
    }

    private func createDesktopFixture(at url: URL) throws {
        try createEmptySQLite(at: url, version: 32)
        try executeSQL(
            """
            CREATE TABLE local_thread_catalog(host_id TEXT NOT NULL, thread_id TEXT NOT NULL, missing_candidate INTEGER NOT NULL, private_title TEXT, PRIMARY KEY(host_id,thread_id));
            CREATE TABLE automation_runs(thread_id TEXT PRIMARY KEY, automation_id TEXT NOT NULL, status TEXT NOT NULL, archived_reason TEXT, updated_at INTEGER NOT NULL, archived_user_message TEXT, archived_assistant_message TEXT);
            CREATE TABLE automations(id TEXT PRIMARY KEY, status TEXT NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE inbox_items(thread_id TEXT);
            CREATE TABLE thread_timeline_ledger(thread_id TEXT);
            CREATE TABLE local_thread_catalog_metadata(id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL);
            CREATE TABLE local_thread_catalog_sync_state(host_id TEXT PRIMARY KEY, observation_sequence INTEGER NOT NULL, watermark_updated_at INTEGER NOT NULL);
            INSERT INTO local_thread_catalog_metadata(id,catalog_revision) VALUES (1,100);
            INSERT INTO local_thread_catalog_sync_state(host_id,observation_sequence,watermark_updated_at) VALUES ('local',200,300);
            """,
            at: url
        )
    }

    private func createSideFixture(at url: URL, version: Int, table: String) throws {
        try createEmptySQLite(at: url, version: version)
        try executeSQL("CREATE TABLE \(table)(thread_id TEXT)", at: url)
    }

    private func createEmptySQLite(at url: URL, version: Int) throws {
        var database: OpaquePointer?
        try check(sqlite3_open(url.path, &database), database: database)
        guard let database else { throw TestSQLiteError.open }
        defer { sqlite3_close_v2(database) }
        try check(
            sqlite3_exec(database, "PRAGMA journal_mode=DELETE", nil, nil, nil),
            database: database
        )
        try check(
            sqlite3_exec(database, "PRAGMA user_version=\(version)", nil, nil, nil),
            database: database
        )
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        try check(sqlite3_open(url.path, &database), database: database)
        guard let database else { throw TestSQLiteError.open }
        defer { sqlite3_close_v2(database) }
        try check(sqlite3_exec(database, sql, nil, nil, nil), database: database)
    }

    private func createSentinelSidecars(for bundle: CodexGhostRepairDisposableBundle) throws {
        for database in databaseURLs(bundle) {
            for suffix in ["-wal", "-shm", "-journal"] {
                try Data("E26 stable sentinel \(suffix)".utf8).write(
                    to: URL(fileURLWithPath: database.path + suffix)
                )
            }
        }
    }

    @discardableResult
    private func createQuarantinePartial(
        destination: CodexGhostRepairDisposableSnapshotDestination,
        snapshotID: UUID,
        contents: String
    ) throws -> URL {
        let root = destination.quarantineRoot(snapshotID: snapshotID)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(root.path, S_IRWXU), 0)
        let file = root.appendingPathComponent("partial.db")
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func sourceFileState(
        _ bundle: CodexGhostRepairDisposableBundle
    ) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for database in databaseURLs(bundle) {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let url = suffix.isEmpty
                    ? database
                    : URL(fileURLWithPath: database.path + suffix)
                if FileManager.default.fileExists(atPath: url.path) {
                    result[url.path] = try Data(contentsOf: url)
                }
            }
        }
        return result
    }

    private func totalSourceBytes(
        _ bundle: CodexGhostRepairDisposableBundle
    ) throws -> UInt64 {
        try sourceFileState(bundle).values.reduce(0) { partial, data in
            partial + UInt64(data.count)
        }
    }

    private func databaseURLs(_ bundle: CodexGhostRepairDisposableBundle) -> [URL] {
        [
            bundle.desktopDatabaseURL,
            bundle.summariesDatabaseURL,
            bundle.historyDatabaseURL,
        ]
    }

    private func check(_ code: Int32, database: OpaquePointer?) throws {
        guard code == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw TestSQLiteError.sqlite(code, message)
        }
    }

    private enum TestSQLiteError: Error {
        case open
        case sqlite(Int32, String)
    }

    private enum TestSnapshotInterruption: Error {
        case injected
    }
}

private actor SequencedAcquisitionGateSource: CodexGhostRepairExecutionGateSource {
    private let gates: [CodexGhostRepairExecutionGate]
    private var index = 0

    init(_ gates: [CodexGhostRepairExecutionGate]) {
        self.gates = gates
    }

    func ghostRepairExecutionGate() async throws -> CodexGhostRepairExecutionGate {
        guard index < gates.count else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "No deterministic E26 gate remains."
            )
        }
        defer { index += 1 }
        return gates[index]
    }

    func callCount() -> Int { index }
}

private actor RecordingSnapshotCapacityProbe:
    CodexGhostRepairSnapshotCapacityProbing
{
    private let availableBytes: UInt64
    private var urls: [URL] = []

    init(availableBytes: UInt64) {
        self.availableBytes = availableBytes
    }

    func availableCapacity(at url: URL) async throws -> UInt64 {
        urls.append(url)
        return availableBytes
    }

    func observedURLs() -> [URL] { urls }
}

private actor RecordingQuarantineTrashTransport:
    CodexGhostRepairQuarantineTrashTransport
{
    enum Behavior: Sendable {
        case moveAll
        case moveFirstThenThrow
    }

    private let fakeTrashRoot: URL
    private let behavior: Behavior
    private var calls = 0
    private var moved: [URL] = []

    init(fakeTrashRoot: URL, behavior: Behavior) {
        self.fakeTrashRoot = fakeTrashRoot
        self.behavior = behavior
    }

    func moveToTrash(_ exactURLs: [URL]) async throws {
        calls += 1
        for (index, url) in exactURLs.enumerated() {
            let destination = fakeTrashRoot.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            moved.append(url)
            if behavior == .moveFirstThenThrow, index == 0 {
                throw TestTrashTransportError.injectedAfterFirstMove
            }
        }
    }

    func callCount() -> Int { calls }
    func movedURLs() -> [URL] { moved }

    private enum TestTrashTransportError: Error {
        case injectedAfterFirstMove
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Error? {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
#endif
