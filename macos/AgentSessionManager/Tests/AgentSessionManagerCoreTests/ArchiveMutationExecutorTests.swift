import XCTest
@testable import AgentSessionManagerCore

final class ArchiveMutationExecutorTests: XCTestCase {
    private let nativeID = "01900000-0000-7000-8000-000000000001"
    private let token = "ARCHIVE-267BE00"
    private let runtime = "0.147.0"
    private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testAcknowledgedArchiveRequiresArchivedReadbackForSuccess() async throws {
        let frozen = activeSession()
        let fixture = try makeFixture(session: frozen)
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: snapshot(session: activeSession(state: .archived), hash: "post-archive")
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        let result = try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )

        XCTAssertEqual(result.outcome, .success)
        XCTAssertTrue(result.archiveRequestAcknowledged)
        XCTAssertEqual(result.observedNativeState, .archived)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 2)
        XCTAssertEqual(counts.archive, 1)
        XCTAssertEqual(counts.archiveIDs, [nativeID])
    }

    func testTimeoutIsNeverRetriedAndArchivedReadbackStillProvesSuccess() async throws {
        let fixture = try makeFixture(session: activeSession())
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: snapshot(session: activeSession(state: .archived), hash: "post-timeout"),
            archiveError: CodexAppServerError.responseTimeout
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        let result = try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )

        XCTAssertEqual(result.outcome, .success)
        XCTAssertFalse(result.archiveRequestAcknowledged)
        XCTAssertEqual(result.errorCode, "archive_request_timeout")
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)
        XCTAssertEqual(counts.inventory, 2)
    }

    func testAcknowledgedButStillActiveReadbackIsUnknown() async throws {
        let fixture = try makeFixture(session: activeSession())
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: snapshot(session: activeSession(), hash: "post-active")
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        let result = try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )

        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertEqual(result.observedNativeState, .active)
        XCTAssertEqual(result.errorCode, "archive_not_observed")
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)
    }

    func testRejectedArchivePlusActiveReadbackIsFailure() async throws {
        let fixture = try makeFixture(session: activeSession())
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: snapshot(session: activeSession(), hash: "post-reject"),
            archiveError: CodexAppServerError.rpcError(-32602, "not allowed")
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        let result = try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )

        XCTAssertEqual(result.outcome, .failure)
        XCTAssertEqual(result.errorCode, "archive_request_rpc_-32602")
        XCTAssertEqual(
            result.message,
            "App Server rejected Archive (RPC -32602): not allowed. Exact post-operation inventory readback still verified Active."
        )
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)
    }

    func testActiveWriterRejectionIsActionableAndNeverRetried() async throws {
        let fixture = try makeFixture(session: activeSession())
        let serverMessage = "thread \(nativeID) already has an active writer"
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: snapshot(session: activeSession(), hash: "post-active-writer"),
            archiveError: CodexAppServerError.rpcError(-32600, serverMessage)
        )
        let executor = ArchiveMutationExecutor(
            transport: transport,
            now: { self.createdAt.addingTimeInterval(30) }
        )

        let result = try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )

        XCTAssertEqual(result.outcome, .failure)
        XCTAssertEqual(result.observedNativeState, .active)
        XCTAssertEqual(result.errorCode, "archive_request_busy_active_writer")
        XCTAssertTrue(result.message.contains(serverMessage))
        XCTAssertTrue(result.message.contains("No automatic retry was attempted"))
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)
        XCTAssertEqual(counts.inventory, 2)
    }

    func testWrongConfirmationStopsBeforeInventoryOrArchive() async throws {
        let fixture = try makeFixture(session: activeSession())
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        await XCTAssertThrowsErrorAsync(try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: "WRONG"
        )) { error in
            XCTAssertEqual(error as? ArchiveExecutionError, .confirmationMismatch)
        }
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    func testDisplayOnlyInventoryDriftDoesNotStopExactTargetArchive() async throws {
        let fixture = try makeFixture(session: activeSession())
        let transport = ArchiveTransportStub(
            preflight: snapshot(session: activeSession(title: "drifted"), hash: "different-hash"),
            readback: snapshot(
                session: activeSession(state: .archived),
                hash: "post-archive"
            )
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        let result = try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )

        XCTAssertEqual(result.outcome, .success)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 2)
        XCTAssertEqual(counts.archive, 1)
    }

    func testProtectionDriftStopsBeforeArchiveEvenWithFrozenInventoryHash() async throws {
        let fixture = try makeFixture(session: activeSession())
        let protected = activeSession(protection: SessionProtection(isPinned: true))
        let transport = ArchiveTransportStub(
            preflight: snapshot(session: protected, hash: fixture.checkpoint.inventoryHash),
            readback: fixture.snapshot
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        await XCTAssertThrowsErrorAsync(try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )) { error in
            XCTAssertEqual(error as? ArchiveExecutionError, .protectedSession("Pinned"))
        }
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 0)
    }

    func testUnknownRunningAndCurrentStateMayReachOneArchiveAttempt() async throws {
        let protection = SessionProtection(
            isRunningKnown: false,
            isCurrentKnown: false
        )
        let fixture = try makeFixture(
            session: activeSession(protection: protection),
            protectionComplete: false
        )
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: snapshot(
                session: activeSession(state: .archived, protection: protection),
                hash: "post-unknown-running-current",
                protectionComplete: false
            )
        )
        let executor = ArchiveMutationExecutor(
            transport: transport,
            now: { self.createdAt.addingTimeInterval(30) }
        )

        let result = try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )

        XCTAssertEqual(result.outcome, .success)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 1)
        XCTAssertEqual(counts.inventory, 2)
    }

    func testUnknownPinEvidenceStopsBeforeArchive() async throws {
        let protection = SessionProtection(
            isPinnedKnown: false,
            hasPinnedDescendantKnown: false
        )
        let fixture = try makeFixture(
            session: activeSession(protection: protection),
            protectionComplete: false
        )
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let executor = ArchiveMutationExecutor(
            transport: transport,
            now: { self.createdAt.addingTimeInterval(30) }
        )

        await XCTAssertThrowsErrorAsync(try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )) { error in
            XCTAssertEqual(
                error as? ArchiveExecutionError,
                .protectedSession("Pin state unavailable, Pinned descendant state unavailable")
            )
        }
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 0)
        XCTAssertEqual(counts.inventory, 1)
    }

    func testDescendantScopeDriftStopsBeforeArchive() async throws {
        let fixture = try makeFixture(session: activeSession())
        let withDescendant = activeSession(descendantCount: 1)
        let transport = ArchiveTransportStub(
            preflight: snapshot(session: withDescendant, hash: fixture.checkpoint.inventoryHash),
            readback: fixture.snapshot
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        await XCTAssertThrowsErrorAsync(try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )) { error in
            XCTAssertEqual(error as? ArchiveExecutionError, .descendantScopeChanged(1))
        }
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 0)
    }

    func testManifestTamperingStopsBeforeArchive() async throws {
        let fixture = try makeFixture(session: activeSession(), manifestOverride: "sha256:tampered")
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        await XCTAssertThrowsErrorAsync(try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )) { error in
            XCTAssertEqual(
                error as? ArchiveExecutionError,
                .invalidPreview("canonical manifest hash mismatch")
            )
        }
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.archive, 0)
    }

    func testExpiredPreviewStopsBeforeInventoryOrArchive() async throws {
        let fixture = try makeFixture(session: activeSession())
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let executor = ArchiveMutationExecutor(
            transport: transport,
            now: { self.createdAt.addingTimeInterval(301) }
        )

        await XCTAssertThrowsErrorAsync(try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )) { error in
            XCTAssertEqual(error as? ArchiveExecutionError, .expired)
        }
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    func testUnauditedRuntimeStopsBeforeInventoryOrArchive() async throws {
        let fixture = try makeFixture(session: activeSession(), runtimeVersion: "0.150.0")
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        await XCTAssertThrowsErrorAsync(try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )) { error in
            XCTAssertEqual(
                error as? ArchiveExecutionError,
                .checkpointMismatch("runtime is outside the verified Archive contract")
            )
        }
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 0)
        XCTAssertEqual(counts.archive, 0)
    }

    func testReadbackFailureIsUnknownAndArchiveIsNotRetried() async throws {
        let fixture = try makeFixture(session: activeSession())
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: fixture.snapshot,
            readbackError: CodexAppServerError.responseTimeout
        )
        let executor = ArchiveMutationExecutor(transport: transport, now: { self.createdAt.addingTimeInterval(30) })

        let result = try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )

        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertEqual(result.errorCode, "readback_timeout")
        XCTAssertEqual(result.observedNativeState, .unavailable)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 2)
        XCTAssertEqual(counts.archive, 1)
    }

    func testStaleReadbackIsUnknownAndArchiveIsNotRetried() async throws {
        let fixture = try makeFixture(session: activeSession())
        let transport = ArchiveTransportStub(
            preflight: fixture.snapshot,
            readback: snapshot(
                session: activeSession(state: .archived),
                hash: "stale-readback",
                observedAt: createdAt.addingTimeInterval(20)
            )
        )
        let executor = ArchiveMutationExecutor(
            transport: transport,
            now: { self.createdAt.addingTimeInterval(30) }
        )

        let result = try await executor.execute(
            preview: fixture.preview,
            checkpoint: fixture.checkpoint,
            confirmationToken: token
        )

        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertEqual(result.errorCode, "readback_stale")
        XCTAssertEqual(result.observedNativeState, .unavailable)
        let counts = await transport.callCounts()
        XCTAssertEqual(counts.inventory, 2)
        XCTAssertEqual(counts.archive, 1)
    }

    func testCodexArchiveClientUsesExactOfficialPayload() async throws {
        let executable = try XCTUnwrap(
            Bundle.module.url(forResource: "fake-app-server-archive", withExtension: "sh")
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o100 != 0 else {
            throw XCTSkip("Archive fixture executable bit is unavailable in this build environment.")
        }
        let compatibility = try await CodexCompatibilityTestSupport(executable: executable,
            home: URL(fileURLWithPath: "/tmp"), version: "0.149.0")
        defer { XCTAssertNoThrow(try compatibility.cleanUp()) }
        let source = CodexAppServerClient(configuration: CodexAppServerConfiguration(
            executableURL: executable,
            timeout: 2
        ), compatibilityInspector: compatibility.inspector)

        try await source.archive(threadID: nativeID)
    }

    private func makeFixture(
        session: AgentSession,
        manifestOverride: String? = nil,
        runtimeVersion: String? = nil,
        protectionComplete: Bool = true
    ) throws -> (
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        snapshot: ProviderInventorySnapshot
    ) {
        let inventoryHash = try InventorySnapshotHasher.hash(provider: .codex, sessions: [session])
        let checkpoint = ProviderCheckpointRecord(
            provider: .codex,
            runtimeVersion: runtimeVersion ?? runtime,
            inventoryHash: inventoryHash,
            refreshedAt: createdAt,
            inventoryComplete: true,
            protectionComplete: protectionComplete
        )
        let item = PersistentPreviewItem(
            managerKey: session.id,
            nativeSessionID: session.nativeID,
            expectedNativeState: .active,
            expectedProtectionHash: try ArchiveExecutionHasher.protectionHash(for: session),
            expectedTitle: session.title,
            expectedProjectID: session.project?.id,
            knownSizeBytes: nil
        )
        let expiresAt = createdAt.addingTimeInterval(300)
        let manifestHash = try ArchiveExecutionHasher.manifestHash(
            provider: .codex,
            operation: .archive,
            providerInventoryHash: inventoryHash,
            runtimeVersion: runtimeVersion ?? runtime,
            reconciliationTimestamp: createdAt,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: [item]
        )
        let preview = PersistentOperationPreview(
            id: UUID(uuidString: "267be000-0000-4000-8000-000000000001")!,
            provider: .codex,
            operation: .archive,
            status: .executing,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(token),
            manifestHash: manifestOverride ?? manifestHash,
            providerInventoryHash: inventoryHash,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: [item]
        )
        return (
            preview,
            checkpoint,
            snapshot(
                session: session,
                hash: inventoryHash,
                protectionComplete: protectionComplete
            )
        )
    }

    private func snapshot(
        session: AgentSession,
        hash: String,
        observedAt: Date? = nil,
        protectionComplete: Bool = true
    ) -> ProviderInventorySnapshot {
        ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtime,
            inventoryHash: hash,
            observedAt: observedAt ?? createdAt.addingTimeInterval(40),
            inventoryComplete: true,
            protectionComplete: protectionComplete,
            sessions: [session]
        )
    }

    private func activeSession(
        state: NativeSessionState = .active,
        title: String = "Archive executor fixture",
        protection: SessionProtection = SessionProtection(),
        descendantCount: Int = 0
    ) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: title,
            workingDirectory: "/Users/example/Project",
            updatedAt: createdAt,
            sizeBytes: nil,
            nativeState: state,
            protection: protection,
            descendantCount: descendantCount,
            descendantCountKnown: true
        )
    }
}

private actor ArchiveTransportStub: ArchiveMutationTransport {
    struct Counts: Sendable {
        let inventory: Int
        let archive: Int
        let archiveIDs: [String]
    }

    private let preflight: ProviderInventorySnapshot
    private let readback: ProviderInventorySnapshot
    private let archiveError: Error?
    private let readbackError: Error?
    private var inventoryCalls = 0
    private var archiveCalls = 0
    private var archiveIDs: [String] = []

    init(
        preflight: ProviderInventorySnapshot,
        readback: ProviderInventorySnapshot,
        archiveError: Error? = nil,
        readbackError: Error? = nil
    ) {
        self.preflight = preflight
        self.readback = readback
        self.archiveError = archiveError
        self.readbackError = readbackError
    }

    func inventorySnapshot() throws -> ProviderInventorySnapshot {
        inventoryCalls += 1
        if inventoryCalls > 1, let readbackError { throw readbackError }
        return inventoryCalls == 1 ? preflight : readback
    }

    func archive(nativeSessionID: String) throws {
        archiveCalls += 1
        archiveIDs.append(nativeSessionID)
        if let archiveError { throw archiveError }
    }

    func callCounts() -> Counts {
        Counts(inventory: inventoryCalls, archive: archiveCalls, archiveIDs: archiveIDs)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
