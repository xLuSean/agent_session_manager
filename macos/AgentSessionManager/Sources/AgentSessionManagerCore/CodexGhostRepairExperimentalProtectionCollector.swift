import Foundation

struct CodexGhostRepairExperimentalExactReadFailureObservation: Sendable {
    let threadID: String
    let provider: AgentSystem
    let runtimeVersion: String
    let method: CodexGhostRepairExperimentalAbsenceMethod
    let errorKind: CodexGhostRepairExperimentalAbsenceErrorKind
    let rpcCode: Int
    let responseShapeIdentifier: String
    let message: String
}

struct CodexGhostRepairExperimentalDescendantNode: Hashable, Sendable {
    let threadID: String
    let parentThreadID: String?
}

struct CodexGhostRepairExperimentalProtectionObservation: Sendable {
    let provider: AgentSystem
    let runtimeVersion: String
    let inventoryComplete: Bool
    let activeThreadIDs: [String]
    let archivedThreadIDs: [String]
    let pinnedThreadIDs: Set<String>
    let pinnedInventoryComplete: Bool
    let descendantNodes: [CodexGhostRepairExperimentalDescendantNode]
    let descendantGraphComplete: Bool
    let presentControlThreadID: String
    let presentControlReturnedThreadID: String
    let exactReadFailures:
        [CodexGhostRepairExperimentalExactReadFailureObservation]
    let operationalAudit: CodexGhostRepairExecutionGate
}

enum CodexGhostRepairExperimentalProtectionCollector {
    static func collect(
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        snapshotEvidence: CodexGhostRepairSnapshotAnalysisReadback,
        registry: CodexGhostRepairExperimentalAbsenceRegistry,
        observation: CodexGhostRepairExperimentalProtectionObservation
    ) throws -> CodexGhostRepairSnapshotDryRunProtectionAudit {
        guard snapshotEvidence.identity == identity,
              snapshotEvidence.sourceLayoutIdentifier
                == CodexGhostRepairSnapshotSourceLayout.identifier,
              observation.provider == .codex,
              !observation.runtimeVersion.isEmpty,
              observation.inventoryComplete,
              observation.pinnedInventoryComplete,
              observation.descendantGraphComplete else {
            throw invalidEvidence()
        }
        let targets = identity.targetThreadIDs
        guard (1...2).contains(targets.count),
              targets == targets.sorted(),
              Set(targets).count == targets.count else {
            throw invalidEvidence()
        }

        let active = try exactIDSet(observation.activeThreadIDs)
        let archived = try exactIDSet(observation.archivedThreadIDs)
        guard active.isDisjoint(with: archived),
              observation.pinnedThreadIDs.allSatisfy(isCanonicalUUID),
              isCanonicalUUID(observation.presentControlThreadID),
              observation.presentControlReturnedThreadID
                == observation.presentControlThreadID,
              !targets.contains(observation.presentControlThreadID),
              active.contains(observation.presentControlThreadID)
                || archived.contains(observation.presentControlThreadID) else {
            throw invalidEvidence()
        }

        let descendantsByParent = try descendantIndex(
            observation.descendantNodes
        )
        var failuresByID:
            [String: CodexGhostRepairExperimentalExactReadFailureObservation]
            = [:]
        for failure in observation.exactReadFailures {
            guard failuresByID.updateValue(
                failure,
                forKey: failure.threadID
            ) == nil else {
                throw invalidEvidence()
            }
        }
        guard Set(failuresByID.keys) == Set(targets) else {
            throw invalidEvidence()
        }

        var protection: [CodexGhostRepairProtectionEvidence] = []
        var experimental: [CodexGhostRepairExperimentalAbsenceEvidence] = []
        for threadID in targets {
            guard !active.contains(threadID),
                  !archived.contains(threadID),
                  let failure = failuresByID[threadID],
                  failure.threadID == threadID,
                  failure.provider == observation.provider,
                  failure.runtimeVersion == observation.runtimeVersion else {
                throw invalidEvidence()
            }
            let outcome = registry.evaluate(.init(
                provider: failure.provider,
                requestedThreadID: threadID,
                runtimeVersion: failure.runtimeVersion,
                method: failure.method,
                errorKind: failure.errorKind,
                rpcCode: failure.rpcCode,
                responseShapeIdentifier: failure.responseShapeIdentifier,
                message: failure.message,
                sourceLayoutIdentifier:
                    snapshotEvidence.sourceLayoutIdentifier,
                databases: snapshotEvidence.databases
            ))
            guard case let .matched(experimentalEvidence) = outcome else {
                throw invalidEvidence()
            }
            let descendantCount = try recursiveDescendantCount(
                rootID: threadID,
                descendantsByParent: descendantsByParent
            )
            protection.append(.init(
                threadID: threadID,
                inventoryComplete: true,
                activeInventoryPresent: false,
                archivedInventoryPresent: false,
                exactReadNotLoaded: true,
                exactReadErrorCode: failure.rpcCode,
                pinned: observation.pinnedThreadIDs.contains(threadID),
                descendantCount: descendantCount
            ))
            experimental.append(experimentalEvidence)
        }

        return .init(
            identity: identity,
            protectionEvidence: protection,
            experimentalAbsenceEvidence: experimental,
            operationalAudit: observation.operationalAudit
        )
    }

    private static func exactIDSet(_ values: [String]) throws -> Set<String> {
        guard Set(values).count == values.count,
              values.allSatisfy(isCanonicalUUID) else {
            throw invalidEvidence()
        }
        return Set(values)
    }

    private static func descendantIndex(
        _ nodes: [CodexGhostRepairExperimentalDescendantNode]
    ) throws -> [String: [String]] {
        var seen: Set<String> = []
        var result: [String: [String]] = [:]
        for node in nodes {
            guard isCanonicalUUID(node.threadID),
                  seen.insert(node.threadID).inserted else {
                throw invalidEvidence()
            }
            if let parent = node.parentThreadID {
                guard isCanonicalUUID(parent), parent != node.threadID else {
                    throw invalidEvidence()
                }
                result[parent, default: []].append(node.threadID)
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
            let child = queue[index]
            index += 1
            guard visited.insert(child).inserted else {
                throw invalidEvidence()
            }
            queue.append(contentsOf: descendantsByParent[child] ?? [])
        }
        return visited.count - 1
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func invalidEvidence() -> CodexGhostRepairError {
        .invalidProtectionEvidence(
            "Experimental protection evidence is incomplete or drifted."
        )
    }
}
