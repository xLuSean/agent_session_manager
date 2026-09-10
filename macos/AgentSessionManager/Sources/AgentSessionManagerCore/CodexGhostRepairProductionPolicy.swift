import Foundation

/// Single owner for production snapshot admission limits.
/// These values can block acquisition. They never select, delete, or
/// otherwise mutate an existing snapshot.
struct CodexGhostRepairProductionPolicy: Hashable, Sendable {
    static let initial = CodexGhostRepairProductionPolicy(
        identifier: "ghost-repair-retention-v1",
        version: 1,
        maximumSnapshotCount: 3,
        maximumTotalBytes: 4_294_967_296,
        maximumAgeMilliseconds: 2_592_000_000
    )

    let identifier: String
    let version: Int
    let maximumSnapshotCount: Int
    let maximumTotalBytes: UInt64
    let maximumAgeMilliseconds: Int64

    let destinationCapacityGateStillRequired = true
    let overQuotaBlocksNewAcquisitionOnly = true
    let automaticDeletionAllowed = false
    let policyChangeDeletesExistingSnapshots = false
    let snapshotAcquisitionAuthority = false
    let repairMutationAuthority = false

    private init(
        identifier: String,
        version: Int,
        maximumSnapshotCount: Int,
        maximumTotalBytes: UInt64,
        maximumAgeMilliseconds: Int64
    ) {
        self.identifier = identifier
        self.version = version
        self.maximumSnapshotCount = maximumSnapshotCount
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumAgeMilliseconds = maximumAgeMilliseconds
    }

    #if AGENT_SESSION_MANAGER_RESEARCH
    func publishedSnapshotRetentionPolicy() throws
        -> CodexGhostRepairPublishedSnapshotRetentionPolicy
    {
        try CodexGhostRepairPublishedSnapshotRetentionPolicy(
            maximumSnapshotCount: maximumSnapshotCount,
            maximumTotalBytes: maximumTotalBytes,
            maximumAgeMilliseconds: maximumAgeMilliseconds
        )
    }
    #endif
}
