import XCTest
@testable import AgentSessionManagerCore

final class CodexCompatibilityBindingTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)
    private let binding = CodexCompatibilityBinding(revision: 1, runtimeVersion: "0.999.0",
        environmentFingerprint: "fixture-environment", features: [.archiveRestore, .officialDelete])

    func testSingleExecutorsCarryVerifiedBindingAndReadBackOutcome() async throws {
        for operation: PersistentOperation in [.archive, .restore, .permanentlyDelete] {
            let session = AgentSession(system: .codex, nativeID: "00000000-0000-4000-8000-000000000001",
                title: "Fixture", workingDirectory: "/tmp/fixture", updatedAt: time, sizeBytes: nil,
                nativeState: operation == .archive ? .active : .archived,
                descendantCount: 0, descendantCountKnown: true)
            let initial = snapshot([session], at: time)
            let checkpoint = initial.checkpoint
            let item = PersistentPreviewItem(managerKey: session.id, nativeSessionID: session.nativeID,
                expectedNativeState: session.nativeState,
                expectedProtectionHash: try ArchiveExecutionHasher.protectionHash(for: session),
                expectedTitle: session.title, expectedProjectID: nil, knownSizeBytes: nil)
            let mutation: TrashMembershipMutation? = operation == .permanentlyDelete ? .remove : nil
            let hash = try ArchiveExecutionHasher.manifestHash(provider: .codex, operation: operation,
                providerInventoryHash: initial.inventoryHash, runtimeVersion: binding.runtimeVersion,
                compatibilityBinding: binding, reconciliationTimestamp: time, createdAt: time,
                expiresAt: time.addingTimeInterval(300), trashMembershipMutation: mutation, items: [item])
            let preview = PersistentOperationPreview(id: UUID(), provider: .codex, operation: operation,
                status: .executing, confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash("confirm"),
                manifestHash: hash, providerInventoryHash: initial.inventoryHash, trashMembershipMutation: mutation,
                createdAt: time, expiresAt: time.addingTimeInterval(300), items: [item])
            var after = session
            after.nativeState = operation == .restore ? .active : .archived
            let transport = BindingTransport(snapshots: [initial,
                snapshot(operation == .permanentlyDelete ? [] : [after], at: time.addingTimeInterval(20))])
            let now = time.addingTimeInterval(10)
            let outcome: ArchiveExecutionOutcome
            switch operation {
            case .archive:
                outcome = try await ArchiveMutationExecutor(transport: transport, now: { now })
                    .execute(preview: preview, checkpoint: checkpoint, confirmationToken: "confirm").outcome
            case .restore:
                outcome = try await RestoreMutationExecutor(transport: transport, now: { now })
                    .execute(preview: preview, checkpoint: checkpoint, confirmationToken: "confirm").outcome
            default:
                outcome = try await DeleteMutationExecutor(transport: transport, now: { now })
                    .execute(preview: preview, checkpoint: checkpoint, confirmationToken: "confirm").outcome
            }
            XCTAssertEqual(outcome, .success)
            let received = await transport.bindings
            XCTAssertFalse(received.isEmpty)
            XCTAssertTrue(received.allSatisfy { $0 == binding })
        }
    }

    func testManifestAndInventoryHashesBindEnvironmentWhileOldNilHashStaysStable() throws {
        let changed = CodexCompatibilityBinding(revision: 1, runtimeVersion: binding.runtimeVersion,
            environmentFingerprint: "replaced", features: binding.features)
        func manifest(_ value: CodexCompatibilityBinding?) throws -> String {
            try ArchiveExecutionHasher.manifestHash(provider: .codex, operation: .archive,
                providerInventoryHash: "same", runtimeVersion: binding.runtimeVersion,
                compatibilityBinding: value, reconciliationTimestamp: time, createdAt: time,
                expiresAt: time.addingTimeInterval(300), items: [])
        }
        XCTAssertNotEqual(try manifest(binding), try manifest(changed))
        XCTAssertNotEqual(try manifest(binding), try manifest(nil))
        XCTAssertEqual(try InventorySnapshotHasher.hash(provider: .codex, sessions: []),
                       try InventorySnapshotHasher.hash(provider: .codex, sessions: [], compatibilityBinding: nil))
        XCTAssertNotEqual(try InventorySnapshotHasher.hash(provider: .codex, sessions: [], compatibilityBinding: binding),
                          try InventorySnapshotHasher.hash(provider: .codex, sessions: [], compatibilityBinding: changed))
    }

    private func snapshot(_ sessions: [AgentSession], at: Date) -> ProviderInventorySnapshot {
        .init(provider: .codex, runtimeVersion: binding.runtimeVersion, compatibilityBinding: binding,
              inventoryHash: "fixture-hash", observedAt: at, inventoryComplete: true,
              protectionComplete: true, sessions: sessions)
    }
}

private actor BindingTransport: ArchiveMutationTransport, RestoreMutationTransport, DeleteMutationTransport {
    var snapshots: [ProviderInventorySnapshot]
    var bindings: [CodexCompatibilityBinding?] = []
    init(snapshots: [ProviderInventorySnapshot]) { self.snapshots = snapshots }
    func inventorySnapshot() throws -> ProviderInventorySnapshot { snapshots.removeFirst() }
    func archive(nativeSessionID: String) throws { throw CodexAppServerError.exactReadUnavailable }
    func restore(nativeSessionID: String) throws { throw CodexAppServerError.exactReadUnavailable }
    func delete(nativeSessionID: String) throws { throw CodexAppServerError.exactReadUnavailable }
    func archive(nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) { bindings.append(expectedCompatibility) }
    func restore(nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) { bindings.append(expectedCompatibility) }
    func delete(nativeSessionID: String, expectedCompatibility: CodexCompatibilityBinding?) { bindings.append(expectedCompatibility) }
    func exactReadObservation(nativeSessionID: String, auditedRuntimeVersion: String) -> DeleteExactReadObservation {
        .unavailable(observedAt: Date(), errorCode: "unbound", message: "Expected a binding")
    }
    func exactReadObservation(nativeSessionID: String, auditedRuntimeVersion: String,
                              expectedCompatibility: CodexCompatibilityBinding?) -> DeleteExactReadObservation {
        bindings.append(expectedCompatibility)
        return .absent(nativeSessionID: nativeSessionID, observedAt: Date(timeIntervalSince1970: 1_800_000_020),
                       runtimeVersion: auditedRuntimeVersion)
    }
}
