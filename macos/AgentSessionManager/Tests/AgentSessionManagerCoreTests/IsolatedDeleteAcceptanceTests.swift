import CryptoKit
import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class IsolatedDeleteAcceptanceTests: XCTestCase {
    func testIsolatedRuntimeEnvironmentBeforeCreation() async throws {
#if ASM_ISOLATED_DELETE_ACCEPTANCE
        let context = try IsolatedDeleteAcceptanceContext.load()

        XCTAssertEqual(context.runtimeVersion, "0.153.4")
        XCTAssertEqual(context.codexHomeURL.deletingLastPathComponent(), context.rootURL)
        XCTAssertEqual(context.executableURL.deletingLastPathComponent(), context.rootURL)
        XCTAssertEqual(context.workingDirectoryURL.deletingLastPathComponent(), context.rootURL)

        // Exercise App Server startup before the one-shot mutation claim. A
        // successful --version probe alone does not prove config loading works.
        let source = CodexAppServerClient(configuration: .isolatedDeleteAcceptance(
            executableURL: context.executableURL,
            codexHomeURL: context.codexHomeURL,
            timeout: 20
        ))
        let initial = try await source.inventory()
        try assertCompleteRawInventory(initial, containsOnly: nil)
#else
        throw XCTSkip(
            "The isolated Delete smoke test exists only in its compile-only acceptance build."
        )
#endif
    }

    func testOfficialIsolatedDeleteWhenExplicitlyEnabled() async throws {
#if ASM_ISOLATED_DELETE_ACCEPTANCE
        guard ProcessInfo.processInfo.environment["ASM_ISOLATED_DELETE_ACCEPTANCE"] == "1" else {
            throw XCTSkip(
                "The isolated Delete acceptance requires the one-shot sandbox runner."
            )
        }
        let context = try IsolatedDeleteAcceptanceContext.load()
        let configuration = CodexAppServerConfiguration.isolatedDeleteAcceptance(
            executableURL: context.executableURL,
            codexHomeURL: context.codexHomeURL,
            timeout: 20
        )
        let source = CodexAppServerClient(configuration: configuration)

        try context.writeStage(index: 1, name: "before-initial-inventory")
        let initial = try await source.inventory()
        try assertCompleteRawInventory(initial, containsOnly: nil)

        try context.writeStage(index: 2, name: "before-official-create")
        let creation = try await source.startIsolatedDeleteAcceptanceThread(
            workingDirectoryURL: context.workingDirectoryURL,
            didCreate: { nativeSessionID in
                try context.writeStage(
                    index: 3,
                    name: "official-create-returned-before-test-turn",
                    nativeSessionID: nativeSessionID
                )
            }
        )
        let created = creation.thread
        // A separate App Server process must see the persisted thread. The
        // creation response and same-process in-memory reads are insufficient.
        let persisted = try await source.exactRead(threadID: created.id)
        guard persisted.runtimeVersion == context.runtimeVersion,
              persisted.thread.id == created.id,
              persisted.thread.cwd == context.workingDirectoryURL.path else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "fresh exact read must identify the same persisted test thread"
            )
        }
        let createdInventory = try await source.inventory()
        try assertCompleteRawInventory(createdInventory, containsOnly: created.id)
        guard created.cwd == context.workingDirectoryURL.path else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "the created session working directory changed"
            )
        }

        let managerDirectory = context.rootURL.appendingPathComponent(
            "manager",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managerDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let store = try SQLiteStateStore(
            databaseURL: managerDirectory.appendingPathComponent("acceptance.sqlite3")
        )
        defer { store.close() }

        let transport = IsolatedDeleteAcceptanceTransport(
            source: source,
            nativeSessionID: created.id,
            workingDirectory: context.workingDirectoryURL.path
        )
        let activeSnapshot = try await transport.inventorySnapshot()
        let activeSession = try XCTUnwrap(activeSnapshot.sessions.first)
        guard activeSnapshot.sessions.count == 1,
              activeSession.nativeID == created.id,
              activeSession.nativeState == .active else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "the sole created session must still be Active before Archive"
            )
        }
        try store.upsertProviderCheckpoint(activeSnapshot.checkpoint)

        let archiveCoordinator = CodexNativeArchiveCoordinator(
            store: store,
            transport: transport,
            executionGate: IsolatedDeleteAcceptanceExecutionGate(),
            now: { Date() },
            makePreviewID: { UUID() },
            makeReportID: { UUID() }
        )
        let trashPreview = try await archiveCoordinator.prepare(
            managerKey: activeSession.id,
            snapshot: activeSnapshot,
            checkpoint: activeSnapshot.checkpoint,
            operation: .moveToTrash,
            lifetime: 120
        )
        try context.writeStage(
            index: 4,
            name: "before-official-archive",
            nativeSessionID: created.id
        )
        let archiveReport = try await archiveCoordinator.execute(
            preview: trashPreview,
            confirmationToken: trashPreview.confirmationToken
        )
        let trashAfterArchive = try store.trashMemberships(for: .codex)
        guard archiveReport.outcome == .success,
              archiveReport.items.count == 1,
              archiveReport.items[0].nativeSessionID == created.id,
              archiveReport.items[0].outcome == .success,
              archiveReport.items[0].observedNativeState == .archived,
              trashAfterArchive.count == 1,
              trashAfterArchive[0].nativeSessionID == created.id else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "official Archive and manager Trash registration must both succeed"
            )
        }

        let archivedSnapshot = try await transport.inventorySnapshot()
        let archivedSession = try XCTUnwrap(archivedSnapshot.sessions.first)
        guard archivedSnapshot.sessions.count == 1,
              archivedSession.nativeID == created.id,
              archivedSession.nativeState == .archived else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "the sole created session must be Archived before Delete"
            )
        }
        try store.upsertProviderCheckpoint(archivedSnapshot.checkpoint)

        let deleteCoordinator = CodexNativeDeleteCoordinator(
            store: store,
            transport: transport,
            executionGate: IsolatedDeleteAcceptanceExecutionGate(),
            now: { Date() },
            makePreviewID: { UUID() },
            makeReportID: { UUID() }
        )
        let deletePreview = try await deleteCoordinator.prepare(
            managerKey: archivedSession.id,
            snapshot: archivedSnapshot,
            checkpoint: archivedSnapshot.checkpoint,
            lifetime: 120
        )
        try context.writeStage(
            index: 5,
            name: "before-official-delete",
            nativeSessionID: created.id
        )
        let deleteReport = try await deleteCoordinator.execute(
            preview: deletePreview,
            confirmationToken: deletePreview.confirmationToken
        )
        guard deleteReport.outcome == .success,
              deleteReport.items.count == 1,
              deleteReport.items[0].nativeSessionID == created.id,
              deleteReport.items[0].outcome == .success,
              deleteReport.items[0].observedNativeState == .absent else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "official Delete must have one exact successful itemized result"
            )
        }

        let finalInventory = try await source.inventory()
        try assertCompleteRawInventory(finalInventory, containsOnly: nil)
        let storedPreview = try XCTUnwrap(store.operationPreview(id: deletePreview.id))
        let memberships = try store.trashMemberships(for: .codex)
        let tombstones = try store.deletedSessions(for: .codex)
        let counts = await transport.callCounts()
        guard counts.archive == 1,
              counts.delete == 1,
              storedPreview.status == .consumed,
              memberships.isEmpty,
              tombstones.count == 1,
              tombstones[0].nativeSessionID == created.id,
              tombstones[0].deleteReportID == deleteReport.id else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "durable Delete completion does not match the sole created session"
            )
        }

        try context.writeStage(
            index: 6,
            name: "final-success",
            nativeSessionID: created.id
        )

        let result: [String: Any] = [
            "schemaVersion": 1,
            "kind": "asm-isolated-delete-0.153.4-result",
            "status": "success",
            "runtimeVersion": "0.153.4",
            "nativeSessionID": created.id,
            "initialAllSourceCount": initial.descendantRecords.count,
            "createdMainCount": createdInventory.active.count
                + createdInventory.archived.count,
            "createdAllSourceCount": createdInventory.descendantRecords.count,
            "creationMethod": "thread/start+turn/start+bounded-stop",
            "creationTurnStatus": creation.turnStatus,
            "creationInterruptRequestCount": creation.interruptRequestCount,
            "archiveOutcome": archiveReport.outcome.rawValue,
            "deleteOutcome": deleteReport.outcome.rawValue,
            "archiveRequestCount": counts.archive,
            "deleteRequestCount": counts.delete,
            "finalMainCount": finalInventory.active.count + finalInventory.archived.count,
            "finalAllSourceCount": finalInventory.descendantRecords.count,
            "previewStatus": storedPreview.status.rawValue,
            "trashMembershipCount": memberships.count,
            "tombstoneCount": tombstones.count,
        ]
        let marker = try JSONSerialization.data(
            withJSONObject: result,
            options: [.sortedKeys]
        )
        print(
            "ASM_ISOLATED_DELETE_RESULT="
                + String(decoding: marker, as: UTF8.self)
        )
#else
        throw XCTSkip(
            "The isolated Delete acceptance cannot run without its compile-only admission."
        )
#endif
    }

#if ASM_ISOLATED_DELETE_ACCEPTANCE
    private func assertCompleteRawInventory(
        _ snapshot: CodexInventorySnapshot,
        containsOnly nativeSessionID: String?
    ) throws {
        guard snapshot.runtimeVersion == "0.153.4",
              !snapshot.isTruncated,
              snapshot.descendantGraphComplete else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "fresh complete exact-runtime all-source inventory is required"
            )
        }
        let main = snapshot.active + snapshot.archived
        if let nativeSessionID {
            guard main.map(\.id) == [nativeSessionID],
                  snapshot.descendantRecords.map(\.id) == [nativeSessionID],
                  main.first?.cwd == snapshot.descendantRecords.first?.cwd else {
                throw IsolatedDeleteAcceptanceError.isolationEvidence(
                    "normal and all-source inventory must contain only the created ID; "
                        + "mainCount=\(main.count), allSourceCount=\(snapshot.descendantRecords.count)"
                )
            }
        } else {
            guard main.isEmpty, snapshot.descendantRecords.isEmpty else {
                throw IsolatedDeleteAcceptanceError.isolationEvidence(
                    "the isolated provider home must be empty"
                )
            }
        }
    }
#endif
}

#if ASM_ISOLATED_DELETE_ACCEPTANCE
private struct IsolatedDeleteAcceptanceContext {
    static let expectedRuntimeSHA256 =
        "b973d440acac501fd2594a43e7ca9ce41e0a65b9dfb28d0d7a7837c99e1261e3"

    let rootURL: URL
    let codexHomeURL: URL
    let executableURL: URL
    let workingDirectoryURL: URL
    let runtimeVersion = "0.153.4"

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        guard environment["ASM_ISOLATED_DELETE_ACCEPTANCE"] == "1" else {
            throw IsolatedDeleteAcceptanceError.invalidEnvironment("opt-in is missing")
        }
        let forbiddenKeys = environment.keys.filter { key in
            let normalized = key.uppercased()
            return normalized.contains("TOKEN")
                || normalized.contains("SECRET")
                || normalized.contains("API_KEY")
                || normalized.contains("APIKEY")
                || normalized.contains("AUTH")
        }
        guard forbiddenKeys.isEmpty else {
            throw IsolatedDeleteAcceptanceError.invalidEnvironment(
                "credential-bearing environment keys are forbidden"
            )
        }
        guard let rootText = environment["ASM_ISOLATED_DELETE_ROOT"],
              let codexHomeText = environment["ASM_ISOLATED_CODEX_HOME"],
              let executableText = environment["ASM_ISOLATED_DELETE_EXECUTABLE"],
              let cwdText = environment["ASM_ISOLATED_DELETE_CWD"],
              let homeText = environment["HOME"],
              let inheritedCodexHome = environment["CODEX_HOME"] else {
            throw IsolatedDeleteAcceptanceError.invalidEnvironment(
                "exact isolated paths are required"
            )
        }

        let rootURL = canonical(URL(fileURLWithPath: rootText, isDirectory: true))
        guard rootURL.deletingLastPathComponent().path == "/private/tmp",
              rootURL.lastPathComponent.hasPrefix("asm-isolated-delete-") else {
            throw IsolatedDeleteAcceptanceError.invalidEnvironment(
                "the root must be one direct private temporary directory"
            )
        }
        let codexHomeURL = canonical(URL(fileURLWithPath: codexHomeText, isDirectory: true))
        let executableURL = canonical(URL(fileURLWithPath: executableText))
        let workingDirectoryURL = canonical(URL(fileURLWithPath: cwdText, isDirectory: true))
        let homeURL = canonical(URL(fileURLWithPath: homeText, isDirectory: true))
        guard codexHomeURL == rootURL.appendingPathComponent("codex", isDirectory: true),
              executableURL == rootURL.appendingPathComponent("codex-runtime"),
              workingDirectoryURL == rootURL.appendingPathComponent("project", isDirectory: true),
              homeURL == rootURL.appendingPathComponent("home", isDirectory: true),
              canonical(URL(fileURLWithPath: inheritedCodexHome, isDirectory: true))
                == codexHomeURL else {
            throw IsolatedDeleteAcceptanceError.invalidEnvironment(
                "isolated paths are not confined to the exact root"
            )
        }
        guard FileManager.default.fileExists(atPath: codexHomeURL.path),
              FileManager.default.fileExists(atPath: workingDirectoryURL.path),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw IsolatedDeleteAcceptanceError.invalidEnvironment(
                "isolated directories or executable are unavailable"
            )
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: executableURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              sha256(try Data(contentsOf: executableURL)) == expectedRuntimeSHA256 else {
            throw IsolatedDeleteAcceptanceError.invalidEnvironment(
                "the copied provider executable identity does not match"
            )
        }

        return Self(
            rootURL: rootURL,
            codexHomeURL: codexHomeURL,
            executableURL: executableURL,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func writeStage(
        index: Int,
        name: String,
        nativeSessionID: String? = nil
    ) throws {
        guard (1...6).contains(index), !name.isEmpty else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "the acceptance stage record is invalid"
            )
        }
        if let nativeSessionID, UUID(uuidString: nativeSessionID) == nil {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "the acceptance stage session ID is invalid"
            )
        }
        var record: [String: Any] = [
            "schemaVersion": 1,
            "kind": "asm-isolated-delete-stage",
            "runtimeVersion": runtimeVersion,
            "stageIndex": index,
            "stage": name,
        ]
        if let nativeSessionID {
            record["nativeSessionID"] = nativeSessionID
        }
        let data = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        let url = rootURL.appendingPathComponent(
            String(format: "acceptance-stage-%02d.json", index)
        )
        try data.write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }
}

private enum IsolatedDeleteAcceptanceError: Error, Equatable, LocalizedError {
    case invalidEnvironment(String)
    case isolationEvidence(String)
    case targetMismatch

    var errorDescription: String? {
        switch self {
        case let .invalidEnvironment(message):
            "Isolated Delete acceptance rejected its environment: \(message)."
        case let .isolationEvidence(message):
            "Isolated Delete acceptance rejected protection evidence: \(message)."
        case .targetMismatch:
            "Isolated Delete acceptance transport received an unexpected session ID."
        }
    }
}

private struct IsolatedDeleteAcceptanceCallCounts: Sendable {
    let archive: Int
    let delete: Int
}

/// Delegates every provider call to the real production transports. The only
/// supplemented evidence is negative host protection justified by the runner's
/// exclusive empty home. Actual all-source descendant completeness and zero
/// descendants remain mandatory and are never synthesized.
private actor IsolatedDeleteAcceptanceTransport:
    ArchiveMutationTransport,
    DeleteMutationTransport
{
    private let archiveBase: CodexArchiveMutationTransport
    private let deleteBase: CodexDeleteMutationTransport
    private let nativeSessionID: String
    private let workingDirectory: String
    private var archiveCalls = 0
    private var deleteCalls = 0

    init(
        source: CodexAppServerClient,
        nativeSessionID: String,
        workingDirectory: String
    ) {
        self.archiveBase = CodexArchiveMutationTransport(source: source)
        self.deleteBase = CodexDeleteMutationTransport(source: source)
        self.nativeSessionID = nativeSessionID
        self.workingDirectory = workingDirectory
    }

    func inventorySnapshot() async throws -> ProviderInventorySnapshot {
        try attest(try await deleteBase.inventorySnapshot())
    }

    func archive(nativeSessionID: String) async throws {
        try requireExactTarget(nativeSessionID)
        archiveCalls += 1
        try await archiveBase.archive(nativeSessionID: nativeSessionID)
    }

    func delete(nativeSessionID: String) async throws {
        try requireExactTarget(nativeSessionID)
        deleteCalls += 1
        try await deleteBase.delete(nativeSessionID: nativeSessionID)
    }

    func exactReadObservation(
        nativeSessionID: String,
        auditedRuntimeVersion: String
    ) async -> DeleteExactReadObservation {
        do {
            try requireExactTarget(nativeSessionID)
        } catch {
            return .unavailable(
                observedAt: Date(),
                errorCode: "isolated_delete_target_mismatch",
                message: error.localizedDescription
            )
        }
        return await deleteBase.exactReadObservation(
            nativeSessionID: nativeSessionID,
            auditedRuntimeVersion: auditedRuntimeVersion
        )
    }

    func callCounts() -> IsolatedDeleteAcceptanceCallCounts {
        IsolatedDeleteAcceptanceCallCounts(
            archive: archiveCalls,
            delete: deleteCalls
        )
    }

    private func attest(
        _ snapshot: ProviderInventorySnapshot
    ) throws -> ProviderInventorySnapshot {
        guard snapshot.provider == .codex,
              snapshot.runtimeVersion == "0.153.4",
              snapshot.inventoryComplete,
              snapshot.archiveScopeComplete else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "complete exact-runtime main and all-source inventory is required"
            )
        }
        if snapshot.sessions.isEmpty, snapshot.archiveScopeNodes.isEmpty {
            // This is the real complete post-Delete absence observation. It is
            // returned unchanged at the domain boundary and never attested or
            // synthesized by the test wrapper.
            return snapshot
        }
        guard
              snapshot.sessions.count == 1,
              snapshot.archiveScopeNodes.count == 1,
              var session = snapshot.sessions.first,
              let node = snapshot.archiveScopeNodes.first,
              session.nativeID == nativeSessionID,
              node.nativeSessionID == nativeSessionID,
              session.workingDirectory == workingDirectory,
              node.workingDirectory == workingDirectory,
              session.descendantCountKnown,
              node.descendantCountKnown,
              session.descendantCount == 0,
              node.descendantCount == 0 else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "one complete exact zero-descendant inventory item is required"
            )
        }
        let observed = [session.protection, node.protection]
        guard observed.allSatisfy({
            !$0.isPinned && !$0.isRunning && !$0.isCurrent && !$0.hasPinnedDescendant
        }) else {
            throw IsolatedDeleteAcceptanceError.isolationEvidence(
                "positive pin, running, current, or descendant evidence cannot be overridden"
            )
        }

        let clearProtection = try ProtectionAuthorityPolicy.resolve(
            system: .codex,
            observations: [
                ProtectionAuthorityObservation(
                    kind: .pinned,
                    isProtected: false,
                    source: .explicitCrossHostAuthority,
                    scope: .allRelevantHosts
                ),
                ProtectionAuthorityObservation(
                    kind: .running,
                    isProtected: false,
                    source: .explicitCrossHostAuthority,
                    scope: .allRelevantHosts
                ),
                ProtectionAuthorityObservation(
                    kind: .current,
                    isProtected: false,
                    source: .explicitCrossHostAuthority,
                    scope: .allRelevantHosts
                ),
                ProtectionAuthorityObservation(
                    kind: .pinnedDescendant,
                    isProtected: false,
                    source: .codexCompleteDescendantGraph,
                    scope: .completeProviderGraph
                ),
            ]
        )
        session.protection = clearProtection
        let attestedNode = ArchiveScopeNode(
            managerKey: node.managerKey,
            nativeSessionID: node.nativeSessionID,
            parentNativeSessionID: node.parentNativeSessionID,
            title: node.title,
            nativeState: node.nativeState,
            protection: clearProtection,
            descendantCount: node.descendantCount,
            descendantCountKnown: node.descendantCountKnown,
            projectID: node.projectID,
            workingDirectory: node.workingDirectory,
            knownSizeBytes: node.knownSizeBytes
        )
        let sessions = [session]
        let nodes = [attestedNode]
        return ProviderInventorySnapshot(
            provider: snapshot.provider,
            runtimeVersion: snapshot.runtimeVersion,
            inventoryHash: try InventorySnapshotHasher.hash(
                provider: snapshot.provider,
                sessions: sessions,
                archiveScopeNodes: nodes,
                archiveScopeComplete: true
            ),
            observedAt: snapshot.observedAt,
            inventoryComplete: snapshot.inventoryComplete,
            protectionComplete: true,
            sessions: sessions,
            archiveScopeNodes: nodes,
            archiveScopeComplete: true,
            errorCode: snapshot.errorCode,
            errorMessage: snapshot.errorMessage
        )
    }

    private func requireExactTarget(_ candidate: String) throws {
        guard candidate == nativeSessionID else {
            throw IsolatedDeleteAcceptanceError.targetMismatch
        }
    }
}

private struct IsolatedDeleteAcceptanceExecutionGate: CodexLifecycleExecutionChecking {
    func requireCodexDesktopExited() async throws {
        // The external sandbox runner owns the exclusive-home process boundary.
        // This test-only gate must never be treated as production Desktop proof.
    }
}
#endif
