import CryptoKit
import Foundation

public enum SnapshotCoordinatorError: Error, Equatable, LocalizedError {
    case diagnosticsProviderMismatch(expected: AgentSystem, found: AgentSystem)
    case staleSnapshot(existing: Date, incoming: Date)
    case conflictingSnapshotTimestamp(Date)

    public var errorDescription: String? {
        switch self {
        case let .diagnosticsProviderMismatch(expected, found):
            "Diagnostics provider mismatch: expected \(expected.rawValue), found \(found.rawValue)."
        case let .staleSnapshot(existing, incoming):
            "Snapshot is stale: existing checkpoint \(existing) is newer than incoming \(incoming)."
        case let .conflictingSnapshotTimestamp(timestamp):
            "Different inventory snapshots share refresh timestamp \(timestamp)."
        }
    }
}

public enum CheckpointCommitDisposition: String, Codable, Sendable {
    case advanced
    case unchanged
    case skippedIncompleteInventory
    case skippedExecutingRecovery
}

public struct CoordinatedSessionSnapshot: Equatable, Sendable {
    public let snapshot: ProviderInventorySnapshot
    public let diagnostics: ProviderDiagnostics
    public let reconciliation: ReconciliationResult
    public let checkpointDisposition: CheckpointCommitDisposition

    public init(
        snapshot: ProviderInventorySnapshot,
        diagnostics: ProviderDiagnostics,
        reconciliation: ReconciliationResult,
        checkpointDisposition: CheckpointCommitDisposition
    ) {
        self.snapshot = snapshot
        self.diagnostics = diagnostics
        self.reconciliation = reconciliation
        self.checkpointDisposition = checkpointDisposition
    }
}

/// Coordinates one read-only provider refresh with manager-owned SQLite state.
/// It never calls Preview/Execute and never mutates native session state.
public actor SessionSnapshotCoordinator {
    private let provider: any SessionProvider
    private let store: SQLiteStateStore
    private let now: @Sendable () -> Date

    public init(
        provider: any SessionProvider,
        store: SQLiteStateStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.store = store
        self.now = now
    }

    public func refresh() async throws -> CoordinatedSessionSnapshot {
        // SessionProvider implementations update diagnostics as part of their
        // sessions() refresh. Read diagnostics only after that call completes.
        let sessions = try await provider.sessions()
        let diagnostics = await provider.diagnostics()
        guard diagnostics.system == provider.system else {
            throw SnapshotCoordinatorError.diagnosticsProviderMismatch(
                expected: provider.system,
                found: diagnostics.system
            )
        }

        // SQLite stores ISO-8601 timestamps at millisecond precision. Normalize
        // before reconciliation so the returned checkpoint is exactly the same
        // value that durable readback observes.
        let observedAt = canonicalCheckpointDate(diagnostics.lastRefreshedAt ?? now())
        let archiveScope = if let scopedProvider = provider as? any ArchiveScopeSnapshotProviding {
            await scopedProvider.archiveScopeSnapshot()
        } else {
            ArchiveScopeSnapshot(nodes: [], isComplete: false)
        }
        let inventoryHash = try InventorySnapshotHasher.hash(
            provider: provider.system,
            sessions: sessions,
            archiveScopeNodes: archiveScope.nodes,
            archiveScopeComplete: archiveScope.isComplete
        )
        let inventoryComplete = diagnostics.inventoryComplete
            && diagnostics.connectionState != .unavailable
        let protectionComplete = diagnostics.protectionComplete
        let checkpoint = ProviderCheckpointRecord(
            provider: provider.system,
            runtimeVersion: diagnostics.runtimeVersion,
            inventoryHash: inventoryHash,
            refreshedAt: observedAt,
            inventoryComplete: inventoryComplete,
            protectionComplete: protectionComplete,
            lastErrorCode: checkpointErrorCode(
                inventoryComplete: inventoryComplete,
                protectionComplete: protectionComplete
            ),
            lastErrorMessage: checkpointErrorMessage(
                inventoryComplete: inventoryComplete,
                protectionComplete: protectionComplete
            )
        )
        let snapshot = ProviderInventorySnapshot(
            provider: provider.system,
            runtimeVersion: diagnostics.runtimeVersion,
            inventoryHash: inventoryHash,
            observedAt: observedAt,
            inventoryComplete: inventoryComplete,
            protectionComplete: protectionComplete,
            sessions: sessions,
            archiveScopeNodes: archiveScope.nodes,
            archiveScopeComplete: archiveScope.isComplete,
            errorCode: checkpoint.lastErrorCode,
            errorMessage: checkpoint.lastErrorMessage
        )
        let memberships = try store.trashMemberships(for: provider.system)
        let reconciliation = try SessionStateReconciler.reconcile(
            snapshot: snapshot,
            trashMemberships: memberships
        )

        guard inventoryComplete else {
            // Partial snapshots are useful for in-memory diagnostics only. They
            // never replace the last authoritative complete checkpoint.
            return CoordinatedSessionSnapshot(
                snapshot: snapshot,
                diagnostics: diagnostics,
                reconciliation: reconciliation,
                checkpointDisposition: .skippedIncompleteInventory
            )
        }

        guard try !store.hasExecutingOperationPreview(for: provider.system) else {
            // Preserve the exact claim-time checkpoint. Recovery owns the next
            // read-only inventory observation and must run before normal
            // checkpoint advancement can resume.
            return CoordinatedSessionSnapshot(
                snapshot: snapshot,
                diagnostics: diagnostics,
                reconciliation: reconciliation,
                checkpointDisposition: .skippedExecutingRecovery
            )
        }

        let existing = try store.providerCheckpoint(for: provider.system)
        if let existing {
            guard observedAt >= existing.refreshedAt else {
                throw SnapshotCoordinatorError.staleSnapshot(
                    existing: existing.refreshedAt,
                    incoming: observedAt
                )
            }
            if observedAt == existing.refreshedAt, existing != checkpoint {
                throw SnapshotCoordinatorError.conflictingSnapshotTimestamp(observedAt)
            }
        }

        try store.commitReconciliationCheckpoint(
            checkpoint,
            expectedTrashManagerKeys: Set(memberships.map(\.managerKey))
        )
        return CoordinatedSessionSnapshot(
            snapshot: snapshot,
            diagnostics: diagnostics,
            reconciliation: reconciliation,
            checkpointDisposition: existing == nil || observedAt > existing!.refreshedAt
                ? .advanced
                : .unchanged
        )
    }

    private func checkpointErrorCode(
        inventoryComplete: Bool,
        protectionComplete: Bool
    ) -> String? {
        if !inventoryComplete { return "inventory-incomplete" }
        if !protectionComplete { return "protection-incomplete" }
        return nil
    }

    private func canonicalCheckpointDate(_ date: Date) -> Date {
        Date(
            timeIntervalSince1970:
                (date.timeIntervalSince1970 * 1_000).rounded() / 1_000
        )
    }

    private func checkpointErrorMessage(
        inventoryComplete: Bool,
        protectionComplete: Bool
    ) -> String? {
        if !inventoryComplete {
            return "Provider inventory was incomplete; authoritative checkpoint was not advanced."
        }
        if !protectionComplete {
            return "Inventory is complete, but lifecycle protection evidence remains incomplete."
        }
        return nil
    }
}

public enum InventorySnapshotHasher {
    public static func hash(
        provider: AgentSystem,
        sessions: [AgentSession],
        archiveScopeNodes: [ArchiveScopeNode] = [],
        archiveScopeComplete: Bool = false
    ) throws -> String {
        var normalized: [AgentSession] = []
        normalized.reserveCapacity(sessions.count)
        for var session in sessions.sorted(by: { $0.id < $1.id }) {
            guard session.system == provider else {
                throw PersistentStateError.providerMismatch(
                    expected: provider,
                    found: session.system
                )
            }
            // Manager Trash intent is not provider inventory and must not affect
            // the native snapshot hash.
            session.isTrashMember = false
            normalized.append(session)
        }
        let normalizedScope = try archiveScopeNodes.sorted { $0.managerKey < $1.managerKey }.map { node in
            guard node.managerKey == "\(provider.rawValue):\(node.nativeSessionID)" else {
                throw PersistentStateError.invalidRecord(
                    "Archive scope manager key is inconsistent with provider."
                )
            }
            return node
        }
        let payload = InventoryHashPayload(
            provider: provider,
            sessions: normalized,
            archiveScopeNodes: normalizedScope,
            archiveScopeComplete: archiveScopeComplete
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct InventoryHashPayload: Encodable {
    let provider: AgentSystem
    let sessions: [AgentSession]
    let archiveScopeNodes: [ArchiveScopeNode]
    let archiveScopeComplete: Bool
}
