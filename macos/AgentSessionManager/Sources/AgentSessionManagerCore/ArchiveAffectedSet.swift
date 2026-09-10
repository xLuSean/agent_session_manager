import CryptoKit
import Foundation

public struct ArchiveScopeNode: Codable, Hashable, Sendable {
    public let managerKey: String
    public let nativeSessionID: String
    public let parentNativeSessionID: String?
    public let title: String
    public let nativeState: NativeSessionState
    public let protection: SessionProtection
    public let descendantCount: Int
    public let descendantCountKnown: Bool
    public let projectID: String?
    public let workingDirectory: String?
    public let knownSizeBytes: Int64?

    public init(
        managerKey: String,
        nativeSessionID: String,
        parentNativeSessionID: String? = nil,
        title: String,
        nativeState: NativeSessionState,
        protection: SessionProtection,
        descendantCount: Int = 0,
        descendantCountKnown: Bool = true,
        projectID: String? = nil,
        workingDirectory: String? = nil,
        knownSizeBytes: Int64? = nil
    ) {
        self.managerKey = managerKey
        self.nativeSessionID = nativeSessionID
        self.parentNativeSessionID = parentNativeSessionID
        self.title = title
        self.nativeState = nativeState
        self.protection = protection
        self.descendantCount = descendantCount
        self.descendantCountKnown = descendantCountKnown
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.knownSizeBytes = knownSizeBytes
    }
}

public enum ArchiveAffectedRole: String, Codable, Hashable, Sendable {
    case selectedRoot
    case descendant
}

public struct ArchiveAffectedItem: Identifiable, Codable, Hashable, Sendable {
    public let managerKey: String
    public let nativeSessionID: String
    public let parentNativeSessionID: String?
    public let title: String
    public let role: ArchiveAffectedRole
    public let depth: Int
    public let nativeState: NativeSessionState
    public let protection: SessionProtection
    public let descendantCount: Int
    public let descendantCountKnown: Bool
    public let projectID: String?
    public let workingDirectory: String?
    public let knownSizeBytes: Int64?

    public var id: String { managerKey }

    public init(
        managerKey: String,
        nativeSessionID: String,
        parentNativeSessionID: String?,
        title: String,
        role: ArchiveAffectedRole,
        depth: Int,
        nativeState: NativeSessionState,
        protection: SessionProtection,
        descendantCount: Int,
        descendantCountKnown: Bool,
        projectID: String?,
        workingDirectory: String? = nil,
        knownSizeBytes: Int64?
    ) {
        self.managerKey = managerKey
        self.nativeSessionID = nativeSessionID
        self.parentNativeSessionID = parentNativeSessionID
        self.title = title
        self.role = role
        self.depth = depth
        self.nativeState = nativeState
        self.protection = protection
        self.descendantCount = descendantCount
        self.descendantCountKnown = descendantCountKnown
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.knownSizeBytes = knownSizeBytes
    }
}

public struct ArchiveAffectedSet: Codable, Hashable, Sendable {
    public let selectedRootNativeSessionID: String
    public let items: [ArchiveAffectedItem]

    public var descendantCount: Int {
        items.filter { $0.role == .descendant }.count
    }
}

public enum ArchiveAffectedSetError: Error, Equatable, LocalizedError {
    case graphIncomplete
    case duplicateNativeSessionID(String)
    case invalidManagerKey(nativeSessionID: String)
    case selectedRootNotFound(String)
    case graphCycle(String)

    public var errorDescription: String? {
        switch self {
        case .graphIncomplete:
            "Archive affected set is unavailable because the descendant graph is incomplete."
        case let .duplicateNativeSessionID(id):
            "Archive affected set contains duplicate native session ID: \(id)."
        case let .invalidManagerKey(id):
            "Archive affected set manager key does not match native session ID: \(id)."
        case let .selectedRootNotFound(id):
            "Selected Archive root was not found in the complete graph: \(id)."
        case let .graphCycle(id):
            "Archive descendant graph contains a cycle involving: \(id)."
        }
    }
}

/// Builds the exact set App Server may archive when `thread/archive` is sent
/// for one root. It never calls a provider and never silently drops a protected
/// descendant; protection is frozen on every returned item for later gating.
public enum ArchiveAffectedSetPlanner {
    public static func plan(
        selectedRootNativeSessionID: String,
        snapshot: ProviderInventorySnapshot
    ) throws -> ArchiveAffectedSet {
        guard snapshot.provider == .codex else {
            throw PersistentStateError.providerMismatch(
                expected: .codex,
                found: snapshot.provider
            )
        }
        return try plan(
            selectedRootNativeSessionID: selectedRootNativeSessionID,
            nodes: snapshot.archiveScopeNodes,
            graphComplete: snapshot.archiveScopeComplete
        )
    }

    public static func plan(
        selectedRootNativeSessionID: String,
        nodes: [ArchiveScopeNode],
        graphComplete: Bool
    ) throws -> ArchiveAffectedSet {
        guard graphComplete else { throw ArchiveAffectedSetError.graphIncomplete }

        var byID: [String: ArchiveScopeNode] = [:]
        for node in nodes {
            guard node.managerKey == "\(AgentSystem.codex.rawValue):\(node.nativeSessionID)" else {
                throw ArchiveAffectedSetError.invalidManagerKey(nativeSessionID: node.nativeSessionID)
            }
            guard byID.updateValue(node, forKey: node.nativeSessionID) == nil else {
                throw ArchiveAffectedSetError.duplicateNativeSessionID(node.nativeSessionID)
            }
        }
        guard let root = byID[selectedRootNativeSessionID] else {
            throw ArchiveAffectedSetError.selectedRootNotFound(selectedRootNativeSessionID)
        }

        let children = Dictionary(grouping: nodes.compactMap { node in
            node.parentNativeSessionID.map { ($0, node.nativeSessionID) }
        }, by: { $0.0 }).mapValues { values in
            values.map(\.1).sorted()
        }

        var items = [affectedItem(root, role: .selectedRoot, depth: 0)]
        var visited: Set<String> = [root.nativeSessionID]
        var queue = (children[root.nativeSessionID] ?? []).map { ($0, 1) }
        var index = 0
        while index < queue.count {
            let (nativeID, depth) = queue[index]
            index += 1
            guard visited.insert(nativeID).inserted else {
                throw ArchiveAffectedSetError.graphCycle(nativeID)
            }
            guard let node = byID[nativeID] else {
                // `children` is built from the same node set, so this only
                // protects future refactors from returning a partial item.
                throw ArchiveAffectedSetError.selectedRootNotFound(nativeID)
            }
            items.append(affectedItem(node, role: .descendant, depth: depth))
            queue.append(contentsOf: (children[nativeID] ?? []).map { ($0, depth + 1) })
        }

        return ArchiveAffectedSet(
            selectedRootNativeSessionID: selectedRootNativeSessionID,
            items: items
        )
    }

    private static func affectedItem(
        _ node: ArchiveScopeNode,
        role: ArchiveAffectedRole,
        depth: Int
    ) -> ArchiveAffectedItem {
        ArchiveAffectedItem(
            managerKey: node.managerKey,
            nativeSessionID: node.nativeSessionID,
            parentNativeSessionID: node.parentNativeSessionID,
            title: node.title,
            role: role,
            depth: depth,
            nativeState: node.nativeState,
            protection: node.protection,
            descendantCount: node.descendantCount,
            descendantCountKnown: node.descendantCountKnown,
            projectID: node.projectID,
            workingDirectory: node.workingDirectory,
            knownSizeBytes: node.knownSizeBytes
        )
    }
}

public enum ArchiveAffectedSetPersistence {
    public static func frozenItems(
        from affectedSet: ArchiveAffectedSet
    ) throws -> [PersistentPreviewItem] {
        try affectedSet.items.map { item in
            PersistentPreviewItem(
                managerKey: item.managerKey,
                nativeSessionID: item.nativeSessionID,
                expectedNativeState: item.nativeState,
                expectedProtectionHash: try ArchiveExecutionHasher.protectionHash(
                    nativeSessionID: item.nativeSessionID,
                    protection: item.protection,
                    descendantCount: item.descendantCount,
                    descendantCountKnown: item.descendantCountKnown
                ),
                expectedTitle: item.title,
                expectedProjectID: item.projectID,
                expectedWorkingDirectory: item.workingDirectory,
                knownSizeBytes: item.knownSizeBytes,
                archiveAffectedRole: item.role,
                parentNativeSessionID: item.parentNativeSessionID,
                archiveAffectedDepth: item.depth
            )
        }
    }

    public static func hash(items: [PersistentPreviewItem]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let normalized = items.sorted { $0.managerKey < $1.managerKey }
        let digest = SHA256.hash(data: try encoder.encode(normalized))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Builds only a durable `prepared` Preview. The existing single-item executor
/// intentionally rejects descendant-aware item sets until batch/affected-set
/// execution and per-item readback have a separate audited implementation.
enum ArchiveAffectedSetPreviewFactory {
    static func makePreparedPreview(
        selectedRootNativeSessionID: String,
        snapshot: ProviderInventorySnapshot,
        operation: PersistentOperation = .archive,
        trashMembershipMutation: TrashMembershipMutation? = nil,
        expectedTrashMembershipSetHash: String? = nil,
        confirmationToken: String,
        previewID: UUID,
        createdAt: Date,
        expiresAt: Date
    ) throws -> PersistentOperationPreview {
        let createdAt = PersistentTimestamp.canonical(createdAt)
        let expiresAt = PersistentTimestamp.canonical(expiresAt)
        guard snapshot.inventoryComplete else {
            throw PersistentStateError.invalidRecord(
                "Archive affected-set Preview requires complete inventory."
            )
        }
        guard let runtimeVersion = snapshot.runtimeVersion, !runtimeVersion.isEmpty else {
            throw PersistentStateError.invalidRecord(
                "Archive affected-set Preview requires a runtime-bound checkpoint."
            )
        }
        let affectedSet = try ArchiveAffectedSetPlanner.plan(
            selectedRootNativeSessionID: selectedRootNativeSessionID,
            snapshot: snapshot
        )
        guard affectedSet.items.first?.nativeState == .active else {
            throw PersistentStateError.invalidRecord(
                "Selected Archive root must be natively Active."
            )
        }
        guard affectedSet.items.allSatisfy({
            $0.nativeState != .unavailable
                && !$0.protection.blocksArchiveAttempt
        }) else {
            throw PersistentStateError.invalidRecord(
                "Every affected Archive item requires clear positive protection and known pin evidence."
            )
        }
        let items = try ArchiveAffectedSetPersistence.frozenItems(from: affectedSet)
        let affectedSetHash = try ArchiveAffectedSetPersistence.hash(items: items)
        let manifestHash = try ArchiveExecutionHasher.manifestHash(
            provider: .codex,
            operation: operation,
            providerInventoryHash: snapshot.inventoryHash,
            runtimeVersion: runtimeVersion,
            compatibilityBinding: snapshot.compatibilityBinding,
            reconciliationTimestamp: snapshot.observedAt,
            createdAt: createdAt,
            expiresAt: expiresAt,
            affectedSetHash: affectedSetHash,
            trashMembershipMutation: trashMembershipMutation,
            expectedTrashMembershipSetHash: expectedTrashMembershipSetHash,
            items: items
        )
        return PersistentOperationPreview(
            id: previewID,
            provider: .codex,
            operation: operation,
            status: .prepared,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                confirmationToken
            ),
            manifestHash: manifestHash,
            providerInventoryHash: snapshot.inventoryHash,
            affectedSetHash: affectedSetHash,
            trashMembershipMutation: trashMembershipMutation,
            expectedTrashMembershipSetHash: expectedTrashMembershipSetHash,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: items
        )
    }
}
