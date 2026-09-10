import Foundation

public enum CodexGhostRepairProtectionBlocker: String, Codable, Hashable, Sendable {
    case incompleteInventory
    case activeInventoryPresent
    case archivedInventoryPresent
    case exactAbsenceUnavailable
    case pinned
    case descendantsPresent
}

public enum CodexGhostRepairOperationalBlocker: String, Codable, Hashable, Sendable {
    case codexStillRunning
    case desktopDatabaseOpen
    case summariesDatabaseOpen
    case historyDatabaseOpen
    case stateDatabaseOpen
    case threadHistoryDatabaseOpen
    case backupCapacityInsufficient

    public var userFacingDescription: String {
        switch self {
        case .codexStillRunning:
            "Codex Desktop is still running"
        case .desktopDatabaseOpen:
            "codex-dev.db still has an open handle"
        case .summariesDatabaseOpen:
            "codex-thread-summaries-dev.db still has an open handle"
        case .historyDatabaseOpen:
            "Legacy codex-history-snapshots-dev.db still has an open handle"
        case .stateDatabaseOpen:
            "state_5.sqlite still has an open handle"
        case .threadHistoryDatabaseOpen:
            "thread_history_1.sqlite still has an open handle"
        case .backupCapacityInsufficient:
            "Snapshot capacity is insufficient"
        }
    }
}

/// Snapshot-specific protection evidence. It proves only that the exact
/// manager Deleted target is omitted from one complete Active + Archived
/// inventory and is neither pinned nor the parent of a fresh descendant. It
/// deliberately carries no exact-read absence claim or repair eligibility.
public struct CodexGhostRepairSnapshotProtectionEvidence:
    Equatable,
    Sendable
{
    public let threadID: String
    public let inventoryComplete: Bool
    public let activeInventoryPresent: Bool
    public let archivedInventoryPresent: Bool
    public let pinned: Bool
    public let descendantCount: Int

    public var isEligibleForSnapshot: Bool {
        inventoryComplete
            && !activeInventoryPresent
            && !archivedInventoryPresent
            && !pinned
            && descendantCount == 0
    }

    public var blockers: [CodexGhostRepairProtectionBlocker] {
        var result: [CodexGhostRepairProtectionBlocker] = []
        if !inventoryComplete { result.append(.incompleteInventory) }
        if activeInventoryPresent { result.append(.activeInventoryPresent) }
        if archivedInventoryPresent { result.append(.archivedInventoryPresent) }
        if pinned { result.append(.pinned) }
        if descendantCount > 0 { result.append(.descendantsPresent) }
        return result
    }
}

/// UI-safe read-only evidence. This value can describe whether the official
/// protection and operational gates are clear, but it is never a Preview or
/// mutation authority.
public struct CodexGhostRepairReadOnlyReview: Equatable, Sendable {
    public let targetThreadIDs: [String]
    public let runtimeVersion: String
    public let inventoryHash: String
    public let observedAt: Date
    public let protectionEvidence: [CodexGhostRepairProtectionEvidence]
    public let snapshotProtectionEvidence:
        [CodexGhostRepairSnapshotProtectionEvidence]
    public let exactReadbacks: [ExactSessionReadbackEvidence]
    public let evidenceUnavailableReason: String?
    public let snapshotEvidenceUnavailableReason: String?
    public let executionGate: CodexGhostRepairExecutionGate

    public init(
        targetThreadIDs: [String],
        runtimeVersion: String,
        inventoryHash: String,
        observedAt: Date,
        protectionEvidence: [CodexGhostRepairProtectionEvidence],
        snapshotProtectionEvidence:
            [CodexGhostRepairSnapshotProtectionEvidence],
        exactReadbacks: [ExactSessionReadbackEvidence],
        evidenceUnavailableReason: String? = nil,
        snapshotEvidenceUnavailableReason: String? = nil,
        executionGate: CodexGhostRepairExecutionGate
    ) {
        self.targetThreadIDs = targetThreadIDs
        self.runtimeVersion = runtimeVersion
        self.inventoryHash = inventoryHash
        self.observedAt = observedAt
        self.protectionEvidence = protectionEvidence
        self.snapshotProtectionEvidence = snapshotProtectionEvidence
        self.exactReadbacks = exactReadbacks
        self.evidenceUnavailableReason = evidenceUnavailableReason
        self.snapshotEvidenceUnavailableReason =
            snapshotEvidenceUnavailableReason
        self.executionGate = executionGate
    }

    public var officialEvidenceEligible: Bool {
        evidenceUnavailableReason == nil
            && protectionEvidence.count == targetThreadIDs.count
            && protectionEvidence.allSatisfy(\.isEligible)
    }

    public var operationalGateClear: Bool { executionGate.isClear }

    public var snapshotEvidenceEligible: Bool {
        snapshotEvidenceUnavailableReason == nil
            && snapshotProtectionEvidence.count == targetThreadIDs.count
            && snapshotProtectionEvidence.allSatisfy(\.isEligibleForSnapshot)
    }

    /// Shipping code has no private-SQLite Preview or executor authority.
    public var liveRepairAvailable: Bool { false }
}

/// Freezes exact snapshot-specific evidence into an App-state request. Official
/// exact-read absence remains separate and is not required here. This value
/// contains no path, file handle, repair Preview, or mutation authority.
public struct CodexGhostRepairSnapshotActionRequest: Equatable, Sendable {
    public let targetThreadIDs: [String]
    public let runtimeVersion: String
    public let inventoryHash: String
    public let reviewObservedAt: Date
    public let snapshotProtectionEvidence:
        [CodexGhostRepairSnapshotProtectionEvidence]
    public let reviewedExecutionGate: CodexGhostRepairExecutionGate
    public let initialWitnessEvidence:
        CodexGhostRepairInitialWitnessEvidence?

    public var liveFilesystemAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public init(review: CodexGhostRepairReadOnlyReview) throws {
        try self.init(review: review, initialWitnessEvidence: nil)
    }

    /// Binds metadata-only initial discovery provenance to the otherwise
    /// unchanged Snapshot request. The profile remains exact, while the
    /// discovery fingerprint is provenance rather than an authorization gate;
    /// the publisher performs its own fresh coherent fingerprint and copy.
    public init(
        review: CodexGhostRepairReadOnlyReview,
        initialWitnessEvidence:
            CodexGhostRepairInitialWitnessEvidence
    ) throws {
        try self.init(
            review: review,
            initialWitnessEvidence: Optional(initialWitnessEvidence)
        )
    }

    private init(
        review: CodexGhostRepairReadOnlyReview,
        initialWitnessEvidence:
            CodexGhostRepairInitialWitnessEvidence?
    ) throws {
        guard (1...10).contains(review.targetThreadIDs.count),
              review.targetThreadIDs == review.targetThreadIDs.sorted(),
              Set(review.targetThreadIDs).count == review.targetThreadIDs.count,
              review.targetThreadIDs.allSatisfy({
                  !$0.isEmpty
                      && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
              }),
              !review.runtimeVersion.isEmpty,
              !review.inventoryHash.isEmpty,
              review.snapshotEvidenceEligible,
              review.operationalGateClear else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot action requires exact inventory-omission protection and a clear operating gate."
            )
        }
        if let evidence = initialWitnessEvidence {
            guard evidence.threadIDs == review.targetThreadIDs,
                  evidence.runtimeVersion == review.runtimeVersion,
                  let profile =
                    CodexGhostRepairSnapshotRequestBoundProfileSelection
                        .selectProfile(
                            exactRuntimeVersion: review.runtimeVersion
                        ),
                  evidence.sourceLayoutIdentifier == profile.identifier,
                  Self.isCanonicalSHA256(evidence.sourceFingerprintHash)
            else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Initial witness provenance does not match the exact reviewed Snapshot request."
                )
            }
        }
        targetThreadIDs = review.targetThreadIDs
        runtimeVersion = review.runtimeVersion
        inventoryHash = review.inventoryHash
        reviewObservedAt = review.observedAt
        snapshotProtectionEvidence = review.snapshotProtectionEvidence
        reviewedExecutionGate = review.executionGate
        self.initialWitnessEvidence = initialWitnessEvidence
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

/// UI-only result vocabulary for snapshot coordinators. Production adapters
/// must be authorized separately and cannot infer filesystem
/// or repair authority from any case below.
public enum CodexGhostRepairSnapshotActionOutcome: Equatable, Sendable {
    case unavailable(message: String)
    case blocked(message: String)
    case succeeded(reference: String)
    case recoveryRequired(reference: String, message: String)
    case failed(message: String)
}

public enum CodexGhostRepairSnapshotAdmissionBlocker:
    String,
    Equatable,
    Sendable
{
    case maximumSnapshotCountExceeded
    case maximumTotalBytesExceeded
    case maximumPublishedAgeExceeded
    case destinationCapacityInsufficient
}

/// Path-free, read-only evidence used by the App before it offers Create
/// Snapshot. It describes the same retention and destination-capacity gates
/// that the publisher rechecks immediately before its durable journal.
public struct CodexGhostRepairSnapshotAdmissionEvidence:
    Equatable,
    Sendable
{
    public let publishedSnapshotCount: Int
    public let maximumSnapshotCount: Int
    public let publishedBytes: UInt64
    public let maximumTotalBytes: UInt64
    public let prospectiveSnapshotBytes: UInt64
    public let oldestPublishedAgeMilliseconds: Int64?
    public let maximumPublishedAgeMilliseconds: Int64
    public let destinationRequiredBytes: UInt64
    public let destinationAvailableBytes: UInt64
    public let blockers: [CodexGhostRepairSnapshotAdmissionBlocker]

    public var isAllowed: Bool { blockers.isEmpty }
    public var automaticDeletionAuthority: Bool { false }
    public var snapshotAcquisitionAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public init(
        publishedSnapshotCount: Int,
        maximumSnapshotCount: Int,
        publishedBytes: UInt64,
        maximumTotalBytes: UInt64,
        prospectiveSnapshotBytes: UInt64,
        oldestPublishedAgeMilliseconds: Int64?,
        maximumPublishedAgeMilliseconds: Int64,
        destinationRequiredBytes: UInt64,
        destinationAvailableBytes: UInt64,
        blockers: [CodexGhostRepairSnapshotAdmissionBlocker]
    ) {
        self.publishedSnapshotCount = publishedSnapshotCount
        self.maximumSnapshotCount = maximumSnapshotCount
        self.publishedBytes = publishedBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.prospectiveSnapshotBytes = prospectiveSnapshotBytes
        self.oldestPublishedAgeMilliseconds = oldestPublishedAgeMilliseconds
        self.maximumPublishedAgeMilliseconds = maximumPublishedAgeMilliseconds
        self.destinationRequiredBytes = destinationRequiredBytes
        self.destinationAvailableBytes = destinationAvailableBytes
        self.blockers = blockers
    }

    public var userFacingBlockReason: String? {
        guard !blockers.isEmpty else { return nil }
        var reasons: [String] = []
        if blockers.contains(.maximumSnapshotCountExceeded) {
            reasons.append(
                "snapshot storage already contains \(publishedSnapshotCount) of \(maximumSnapshotCount) allowed published snapshots"
            )
        }
        if blockers.contains(.maximumTotalBytesExceeded) {
            reasons.append("the retained snapshot byte limit would be exceeded")
        }
        if blockers.contains(.maximumPublishedAgeExceeded) {
            reasons.append("an existing published snapshot is older than the retention limit")
        }
        if blockers.contains(.destinationCapacityInsufficient) {
            reasons.append("the destination volume does not have enough free capacity")
        }
        return "Create Snapshot is blocked because "
            + reasons.joined(separator: "; ")
            + ". Existing snapshots are never deleted automatically."
    }
}

public enum CodexGhostRepairSnapshotAdmissionOutcome: Equatable, Sendable {
    case allowed(CodexGhostRepairSnapshotAdmissionEvidence)
    case blocked(
        evidence: CodexGhostRepairSnapshotAdmissionEvidence?,
        message: String
    )
    case unavailable(message: String)
}

public enum CodexGhostRepairSnapshotAcquisitionEffect:
    String,
    Equatable,
    Sendable
{
    case unavailable
    case testOwnedRawDatabaseSnapshot
    case fixedManagerRawDatabaseSnapshot

    public var readsCodexDatabaseFiles: Bool {
        self != .unavailable
    }

    public var writesCodexDatabaseFiles: Bool { false }
    public var acceptsCallerPath: Bool { false }
    public var grantsRepairAuthority: Bool { false }
}

public struct CodexGhostRepairSnapshotActionCapabilities:
    Equatable,
    Sendable
{
    public let acquisitionAvailable: Bool
    public let effect: CodexGhostRepairSnapshotAcquisitionEffect

    public var repairMutationAuthority: Bool { false }

    public static let unavailable = Self(
        acquisitionAvailable: false,
        effect: .unavailable
    )
    /// The fixed shipping backend is compiled and path-free, but its live
    /// acquisition entry point remains deliberately unavailable.
    public static let packagedFixedManagerSnapshotBlocked = Self(
        acquisitionAvailable: false,
        effect: .fixedManagerRawDatabaseSnapshot
    )
    public static let testOwnedRawDatabaseSnapshot = Self(
        acquisitionAvailable: true,
        effect: .testOwnedRawDatabaseSnapshot
    )
    public static let fixedManagerRawDatabaseSnapshot = Self(
        acquisitionAvailable: true,
        effect: .fixedManagerRawDatabaseSnapshot
    )

    private init(
        acquisitionAvailable: Bool,
        effect: CodexGhostRepairSnapshotAcquisitionEffect
    ) {
        self.acquisitionAvailable = acquisitionAvailable
        self.effect = effect
    }
}

public protocol CodexGhostRepairSnapshotActionCoordinator: Sendable {
    var capabilities: CodexGhostRepairSnapshotActionCapabilities { get }

    func inspectAdmission(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome

    func perform(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotActionOutcome
}

/// Shipping default for E37. It performs no I/O and cannot create a snapshot.
public struct CodexGhostRepairSnapshotActionUnavailableCoordinator:
    CodexGhostRepairSnapshotActionCoordinator
{
    public init() {}

    public var capabilities: CodexGhostRepairSnapshotActionCapabilities {
        .unavailable
    }

    public func inspectAdmission(
        request _: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        .unavailable(
            message: "Live Ghost Repair snapshot admission is not available in this build."
        )
    }

    public func perform(
        request _: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotActionOutcome {
        .unavailable(
            message: "Live Ghost Repair snapshot acquisition is not available in this build."
        )
    }
}

public extension CodexGhostRepairProtectionEvidence {
    var blockers: [CodexGhostRepairProtectionBlocker] {
        var result: [CodexGhostRepairProtectionBlocker] = []
        if !inventoryComplete { result.append(.incompleteInventory) }
        if activeInventoryPresent { result.append(.activeInventoryPresent) }
        if archivedInventoryPresent { result.append(.archivedInventoryPresent) }
        if !exactReadNotLoaded || exactReadErrorCode != -32600 {
            result.append(.exactAbsenceUnavailable)
        }
        if pinned { result.append(.pinned) }
        if descendantCount > 0 { result.append(.descendantsPresent) }
        return result
    }
}

public extension CodexGhostRepairExecutionGate {
    var blockingDesktopProcessEvidence:
        [CodexGhostRepairDesktopProcessEvidence]
    {
        (desktopProcessEvidence ?? []).filter(\.blocksSnapshotAcquisition)
    }

    var nonBlockingDesktopProcessEvidence:
        [CodexGhostRepairDesktopProcessEvidence]
    {
        (desktopProcessEvidence ?? []).filter {
            !$0.blocksSnapshotAcquisition
        }
    }

    var blockers: [CodexGhostRepairOperationalBlocker] {
        var result: [CodexGhostRepairOperationalBlocker] = []
        if !codexFullyExited { result.append(.codexStillRunning) }
        if desktopOpenHandleCount != 0 { result.append(.desktopDatabaseOpen) }
        if summariesOpenHandleCount != 0 { result.append(.summariesDatabaseOpen) }
        if historyOpenHandleCount != 0 { result.append(.historyDatabaseOpen) }
        if (stateOpenHandleCount ?? 0) != 0 { result.append(.stateDatabaseOpen) }
        if (threadHistoryOpenHandleCount ?? 0) != 0 {
            result.append(.threadHistoryDatabaseOpen)
        }
        if !capacitySufficient { result.append(.backupCapacityInsufficient) }
        return result
    }

    var userFacingBlockerDescriptions: [String] {
        blockers.flatMap { blocker in
            if blocker == .codexStillRunning,
               !blockingDesktopProcessEvidence.isEmpty {
                return blockingDesktopProcessEvidence.map(
                    \.userFacingDescription
                )
            }
            return [blocker.userFacingDescription]
        }
    }
}

public enum CodexGhostRepairReadOnlyReviewBuilder {
    public static func build(
        targetThreadIDs: [String],
        snapshot: CodexGhostRepairSafetySnapshot
    ) throws -> CodexGhostRepairReadOnlyReview {
        guard (1...10).contains(targetThreadIDs.count) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "A read-only review requires 1–10 exact target IDs."
            )
        }
        let sortedTargets = targetThreadIDs.sorted()
        guard Set(sortedTargets).count == sortedTargets.count,
              sortedTargets.allSatisfy({
                  !$0.isEmpty
                      && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
              }) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "A read-only review requires unique, non-empty, unmodified exact IDs."
            )
        }
        let sortedReadbacks = snapshot.exactReadbacks.sorted {
            $0.nativeSessionID < $1.nativeSessionID
        }
        guard sortedReadbacks.map(\.nativeSessionID) == sortedTargets,
              sortedReadbacks.allSatisfy({ $0.provider == .codex }) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact readbacks must match the frozen Codex target set."
            )
        }
        guard let runtimeVersion = snapshot.inventory.runtimeVersion,
              !runtimeVersion.isEmpty else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact Codex runtime version is required."
            )
        }
        let snapshotEvidence: [CodexGhostRepairSnapshotProtectionEvidence]
        let snapshotEvidenceUnavailableReason: String?
        do {
            snapshotEvidence = try snapshotProtectionEvidence(
                targetThreadIDs: sortedTargets,
                snapshot: snapshot
            )
            snapshotEvidenceUnavailableReason = nil
        } catch {
            snapshotEvidence = []
            snapshotEvidenceUnavailableReason = error.localizedDescription
        }
        do {
            let collected = try CodexGhostRepairSafetyCollector.collect(
                targetThreadIDs: sortedTargets,
                snapshot: snapshot
            )
            return CodexGhostRepairReadOnlyReview(
                targetThreadIDs: sortedTargets,
                runtimeVersion: runtimeVersion,
                inventoryHash: snapshot.inventory.inventoryHash,
                observedAt: snapshot.inventory.observedAt,
                protectionEvidence: collected.protectionEvidence,
                snapshotProtectionEvidence: snapshotEvidence,
                exactReadbacks: sortedReadbacks,
                snapshotEvidenceUnavailableReason:
                    snapshotEvidenceUnavailableReason,
                executionGate: collected.executionGate
            )
        } catch {
            return CodexGhostRepairReadOnlyReview(
                targetThreadIDs: sortedTargets,
                runtimeVersion: runtimeVersion,
                inventoryHash: snapshot.inventory.inventoryHash,
                observedAt: snapshot.inventory.observedAt,
                protectionEvidence: [],
                snapshotProtectionEvidence: snapshotEvidence,
                exactReadbacks: sortedReadbacks,
                evidenceUnavailableReason: error.localizedDescription,
                snapshotEvidenceUnavailableReason:
                    snapshotEvidenceUnavailableReason,
                executionGate: snapshot.executionGate
            )
        }
    }

    private static func snapshotProtectionEvidence(
        targetThreadIDs: [String],
        snapshot: CodexGhostRepairSafetySnapshot
    ) throws -> [CodexGhostRepairSnapshotProtectionEvidence] {
        let inventory = snapshot.inventory
        guard inventory.provider == .codex,
              inventory.inventoryComplete,
              inventory.protectionComplete,
              inventory.archiveScopeComplete,
              snapshot.pinnedInventoryComplete else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot protection requires complete inventory, pin, and descendant evidence."
            )
        }

        var sessionsByID: [String: AgentSession] = [:]
        for session in inventory.sessions {
            guard session.system == .codex,
                  sessionsByID.updateValue(
                      session,
                      forKey: session.nativeID
                  ) == nil else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot inventory contains invalid or duplicate Codex sessions."
                )
            }
        }

        let descendantsByParent = try descendantIndex(
            nodes: inventory.archiveScopeNodes
        )
        return try targetThreadIDs.map { threadID in
            let session = sessionsByID[threadID]
            return CodexGhostRepairSnapshotProtectionEvidence(
                threadID: threadID,
                inventoryComplete: true,
                activeInventoryPresent: session?.nativeState == .active,
                archivedInventoryPresent: session?.nativeState == .archived,
                pinned: snapshot.pinnedThreadIDs.contains(threadID),
                descendantCount: try recursiveDescendantCount(
                    rootID: threadID,
                    descendantsByParent: descendantsByParent
                )
            )
        }
    }

    private static func descendantIndex(
        nodes: [ArchiveScopeNode]
    ) throws -> [String: [String]] {
        var seen: Set<String> = []
        var result: [String: [String]] = [:]
        for node in nodes {
            guard node.managerKey == "codex:\(node.nativeSessionID)",
                  seen.insert(node.nativeSessionID).inserted else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Snapshot descendant graph contains invalid or duplicate nodes."
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
                    "Snapshot descendant graph contains a cycle or duplicate path."
                )
            }
            queue.append(contentsOf: descendantsByParent[childID] ?? [])
        }
        return visited.count - 1
    }
}
