import Foundation

/// One shipping-safe definition of the manager-owned destination layout.
/// URLs stay Core-internal and never cross the path-redacted public evidence
/// boundary.
enum CodexGhostRepairDestinationCanaryFixedLayout {
    static let ghostRepairDirectoryName = "GhostRepair"
    static let snapshotsDirectoryName = "Snapshots"
    static let quarantineDirectoryName = "Quarantine"
    static let journalDirectoryName = "Journal"
    static let trashDirectoryName = "Trash"

    struct Entry: Sendable {
        let directory: CodexGhostRepairDestinationCanaryDirectory
        let url: URL
        let parent: CodexGhostRepairDestinationCanaryDirectory?
    }

    static let preparationOrder: [
        CodexGhostRepairDestinationCanaryDirectory
    ] = [
        .ghostRepairRoot,
        .snapshots,
        .quarantine,
        .journal,
        .trash,
    ]

    static func entries(applicationSupport: URL) -> [Entry] {
        let bundle = applicationSupport.appendingPathComponent(
            StateStoreLocation.defaultBundleIdentifier,
            isDirectory: true
        )
        let ghostRepair = bundle.appendingPathComponent(
            ghostRepairDirectoryName,
            isDirectory: true
        )
        let journal = ghostRepair.appendingPathComponent(
            journalDirectoryName,
            isDirectory: true
        )
        return [
            Entry(
                directory: .applicationBundleRoot,
                url: bundle,
                parent: nil
            ),
            Entry(
                directory: .ghostRepairRoot,
                url: ghostRepair,
                parent: .applicationBundleRoot
            ),
            Entry(
                directory: .snapshots,
                url: ghostRepair.appendingPathComponent(
                    snapshotsDirectoryName,
                    isDirectory: true
                ),
                parent: .ghostRepairRoot
            ),
            Entry(
                directory: .quarantine,
                url: ghostRepair.appendingPathComponent(
                    quarantineDirectoryName,
                    isDirectory: true
                ),
                parent: .ghostRepairRoot
            ),
            Entry(
                directory: .journal,
                url: journal,
                parent: .ghostRepairRoot
            ),
            Entry(
                directory: .trash,
                url: journal.appendingPathComponent(
                    trashDirectoryName,
                    isDirectory: true
                ),
                parent: .journal
            ),
        ]
    }
}
