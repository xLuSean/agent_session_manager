import Foundation

/// One complete, read-only observation used to build or revalidate a Ghost
/// Repair Preview. The source protocol intentionally exposes no lifecycle or
/// database mutation method.
public struct CodexGhostRepairSafetySnapshot: Sendable {
    public let inventory: ProviderInventorySnapshot
    public let exactReadbacks: [ExactSessionReadbackEvidence]
    public let pinnedThreadIDs: Set<String>
    public let pinnedInventoryComplete: Bool
    public let executionGate: CodexGhostRepairExecutionGate

    public init(
        inventory: ProviderInventorySnapshot,
        exactReadbacks: [ExactSessionReadbackEvidence],
        pinnedThreadIDs: Set<String>,
        pinnedInventoryComplete: Bool,
        executionGate: CodexGhostRepairExecutionGate
    ) {
        self.inventory = inventory
        self.exactReadbacks = exactReadbacks
        self.pinnedThreadIDs = pinnedThreadIDs
        self.pinnedInventoryComplete = pinnedInventoryComplete
        self.executionGate = executionGate
    }
}

public protocol CodexGhostRepairReadOnlySafetySource: Sendable {
    func ghostRepairSafetySnapshot(
        targetThreadIDs: [String]
    ) async throws -> CodexGhostRepairSafetySnapshot
}

public struct CodexGhostRepairCollectedSafetyEvidence: Hashable, Sendable {
    public let protectionEvidence: [CodexGhostRepairProtectionEvidence]
    public let executionGate: CodexGhostRepairExecutionGate

    public init(
        protectionEvidence: [CodexGhostRepairProtectionEvidence],
        executionGate: CodexGhostRepairExecutionGate
    ) {
        self.protectionEvidence = protectionEvidence
        self.executionGate = executionGate
    }
}

public enum CodexGhostRepairSafetyCollector {
    public static func collect(
        targetThreadIDs: [String],
        from source: any CodexGhostRepairReadOnlySafetySource
    ) async throws -> CodexGhostRepairCollectedSafetyEvidence {
        let snapshot = try await source.ghostRepairSafetySnapshot(
            targetThreadIDs: targetThreadIDs
        )
        return try collect(targetThreadIDs: targetThreadIDs, snapshot: snapshot)
    }

    public static func collect(
        targetThreadIDs: [String],
        snapshot: CodexGhostRepairSafetySnapshot
    ) throws -> CodexGhostRepairCollectedSafetyEvidence {
        let sortedTargets = targetThreadIDs.sorted()
        guard !sortedTargets.isEmpty,
              Set(sortedTargets).count == sortedTargets.count else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Target IDs must be a non-empty unique set."
            )
        }

        let inventory = snapshot.inventory
        guard inventory.provider == .codex else {
            throw PersistentStateError.providerMismatch(
                expected: .codex,
                found: inventory.provider
            )
        }
        guard inventory.inventoryComplete,
              inventory.protectionComplete,
              inventory.archiveScopeComplete,
              snapshot.pinnedInventoryComplete else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Complete inventory, protection, pin, and descendant evidence is required."
            )
        }
        guard let runtimeVersion = inventory.runtimeVersion,
              !runtimeVersion.isEmpty else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact Codex runtime version is required."
            )
        }

        var sessionsByID: [String: AgentSession] = [:]
        for session in inventory.sessions {
            guard session.system == .codex else {
                throw PersistentStateError.providerMismatch(
                    expected: .codex,
                    found: session.system
                )
            }
            guard sessionsByID.updateValue(session, forKey: session.nativeID) == nil else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Duplicate inventory session: \(session.nativeID)"
                )
            }
        }

        var readbacksByID: [String: ExactSessionReadbackEvidence] = [:]
        for readback in snapshot.exactReadbacks {
            guard readback.provider == .codex else {
                throw PersistentStateError.providerMismatch(
                    expected: .codex,
                    found: readback.provider
                )
            }
            guard readbacksByID.updateValue(readback, forKey: readback.nativeSessionID) == nil else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Duplicate exact readback: \(readback.nativeSessionID)"
                )
            }
        }
        guard Set(readbacksByID.keys) == Set(sortedTargets),
              readbacksByID.count == sortedTargets.count else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact readback set does not match the frozen target set."
            )
        }

        let descendantsByParent = try descendantIndex(
            nodes: inventory.archiveScopeNodes
        )
        let evidence = try sortedTargets.map { threadID in
            guard let readback = readbacksByID[threadID],
                  readback.provesAbsence,
                  readback.rpcCode == -32600 else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Official exact absence is unavailable for \(threadID)."
                )
            }
            if readback.runtimeVersion != runtimeVersion {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Exact readback runtime drifted for \(threadID)."
                )
            }

            let inventorySession = sessionsByID[threadID]
            let activePresent = inventorySession?.nativeState == .active
            let archivedPresent = inventorySession?.nativeState == .archived
            let descendantCount = try recursiveDescendantCount(
                rootID: threadID,
                descendantsByParent: descendantsByParent
            )
            return CodexGhostRepairProtectionEvidence(
                threadID: threadID,
                inventoryComplete: true,
                activeInventoryPresent: activePresent,
                archivedInventoryPresent: archivedPresent,
                exactReadNotLoaded: true,
                exactReadErrorCode: -32600,
                pinned: snapshot.pinnedThreadIDs.contains(threadID),
                descendantCount: descendantCount
            )
        }

        return CodexGhostRepairCollectedSafetyEvidence(
            protectionEvidence: evidence,
            executionGate: snapshot.executionGate
        )
    }

    private static func descendantIndex(
        nodes: [ArchiveScopeNode]
    ) throws -> [String: [String]] {
        var seen: Set<String> = []
        var result: [String: [String]] = [:]
        for node in nodes {
            guard node.managerKey == "codex:\(node.nativeSessionID)" else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Invalid descendant manager key: \(node.nativeSessionID)"
                )
            }
            guard seen.insert(node.nativeSessionID).inserted else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Duplicate descendant node: \(node.nativeSessionID)"
                )
            }
            if let parentID = node.parentNativeSessionID {
                result[parentID, default: []].append(node.nativeSessionID)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    private static func recursiveDescendantCount(
        rootID: String,
        descendantsByParent: [String: [String]]
    ) throws -> Int {
        var visited: Set<String> = [rootID]
        var queue = descendantsByParent[rootID] ?? []
        var index = 0
        while index < queue.count {
            let childID = queue[index]
            index += 1
            guard visited.insert(childID).inserted else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Descendant graph contains a cycle or duplicate path at \(childID)."
                )
            }
            queue.append(contentsOf: descendantsByParent[childID] ?? [])
        }
        return visited.count - 1
    }
}
