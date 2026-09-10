import Foundation

/// Exact, content-redacted scope for the explicit manual-review mode.
/// It never authorizes deletion of an automation definition or a live session.
public struct CodexGhostRepairReviewedSessionResidue: Codable, Equatable, Hashable, Sendable {
    public let summaryRowDigests: [String]
    public let pausedAutomation: Bool

    var isValid: Bool {
        (pausedAutomation || !summaryRowDigests.isEmpty)
            && summaryRowDigests.count <= 100
            && summaryRowDigests == summaryRowDigests.sorted()
            && summaryRowDigests.allSatisfy {
                $0.hasPrefix("sha256:") && $0.count == 71
                    && $0.dropFirst(7).allSatisfy(\.isHexDigit)
            }
    }
}

public enum CodexGhostRepairBulkInventoryDisposition:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case notGhost = "not-ghost"
    case eligible
    case blocked
    case unconfirmed
}

public enum CodexGhostRepairBulkInventoryBlocker:
    String,
    CaseIterable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case incompleteOfficialInventory = "incomplete-official-inventory"
    case canonicalStatePresent = "canonical-state-present"
    case exactReadNotPerformed = "exact-read-not-performed"
    case exactReadPresent = "exact-read-present"
    case exactReadUnavailable = "exact-read-unavailable"
    case exactReadContractMismatch = "exact-read-contract-mismatch"
    case pinned = "pinned"
    case descendantsPresent = "descendants-present"
    case unsupportedRowShape = "unsupported-row-shape"
    case sideReferencesPresent = "side-references-present"
    case summaryRecordsPresent = "summary-records-present"
}

public struct CodexGhostRepairBulkInventoryItem:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let threadID: String
    public let disposition: CodexGhostRepairBulkInventoryDisposition
    public let category: CodexGhostRepairCategory?
    public let blockers: [CodexGhostRepairBulkInventoryBlocker]
    public let evidenceDigest: String
    /// Nil preserves the encoded shape of pre-existing inventories.
    public var initiallyAbsent: Bool? = nil
    public var reviewedResidue: CodexGhostRepairReviewedSessionResidue? = nil

    public var confirmedGhost: Bool {
        disposition == .eligible || disposition == .blocked
    }

    public var selectable: Bool { disposition == .eligible }

    /// Explain why a retained item is not a deletion candidate without
    /// presenting a skipped read as a broken or missing conversation.
    public var retentionExplanation: String? {
        if blockers.contains(.canonicalStatePresent) {
            return "Local session data exists — kept"
        }
        if blockers.contains(.exactReadPresent) {
            return "Codex can read this session — kept"
        }
        return nil
    }
    public var repairPreviewAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

}

/// Presentation only: filtering never changes the frozen evidence or cleanup authority.
public enum CodexGhostRepairInventoryFilter: String, CaseIterable, Sendable {
    case needsAttention = "Needs attention"
    case eligible = "Eligible ghosts"
    case blocked = "Blocked ghosts"
    case localData = "Local session data — kept"
    case unconfirmed = "Other unconfirmed"
    case active = "Active"
    case archived = "Archive"
    case notGhost = "All normal sessions"
    case all = "All scanned items"
}

public struct CodexGhostRepairBulkInventory:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    /// This is an inventory/readback bound. A later mutation milestone must
    /// define and test its own product batch limit independently.
    public static let maximumObservedCatalogItems = 10_000

    public let snapshotReference: String
    public let sourceLayoutIdentifier: String
    public let items: [CodexGhostRepairBulkInventoryItem]
    public let inventoryDigest: String
    /// The exact private evidence used to produce this public inventory. It is
    /// carried only in memory so Core can freeze the selected subset together
    /// with a Preview. It is deliberately excluded from Codable, equality and
    /// hashing so serializing the public inventory can never persist the full
    /// observed catalog evidence by accident.
    let sourceEvidence: CodexGhostRepairBulkInventoryInput?
    /// Display-only metadata. Existing Codable, equality and hash intentionally omit it.
    let displayTitles: [String: String]

    public func displayTitle(for threadID: String) -> String? {
        displayTitles[threadID]
    }

    public var manualReviewEnabled: Bool { sourceEvidence?.allowReviewedResidue == true }

    public func threadIDs(matching filter: CodexGhostRepairInventoryFilter) -> Set<String> {
        if filter == .active || filter == .archived {
            let officialIDs = Set((sourceEvidence?.protectionEvidence ?? []).filter {
                filter == .active ? $0.activeInventoryPresent : $0.archivedInventoryPresent
            }.map(\.threadID))
            return Set(items.filter {
                $0.disposition == .notGhost && officialIDs.contains($0.threadID)
            }.map(\.threadID))
        }
        return Set(items.filter { matches($0, filter: filter) }.map(\.threadID))
    }

    public func matches(_ item: CodexGhostRepairBulkInventoryItem,
                        filter: CodexGhostRepairInventoryFilter) -> Bool {
        switch filter {
        case .needsAttention: return item.disposition != .notGhost
        case .eligible: return item.disposition == .eligible
        case .blocked: return item.disposition == .blocked
        case .localData:
            return item.disposition == .unconfirmed && item.blockers.contains(.canonicalStatePresent)
        case .unconfirmed:
            return item.disposition == .unconfirmed && !item.blockers.contains(.canonicalStatePresent)
        case .active, .archived:
            guard item.disposition == .notGhost,
                  let evidence = sourceEvidence?.protectionEvidence.first(where: {
                      $0.threadID == item.threadID
                  }) else { return false }
            return filter == .active ? evidence.activeInventoryPresent : evidence.archivedInventoryPresent
        case .notGhost: return item.disposition == .notGhost
        case .all: return true
        }
    }

    /// Does not override positive/uncertain reads, pins, descendants or unknown shapes.
    public func reviewingKnownResidue(_ enabled: Bool) throws -> Self {
        guard var input = sourceEvidence else {
            throw CodexGhostRepairError.invalidPlan("A fresh scan is required for manual review.")
        }
        input.allowReviewedResidue = enabled
        return try CodexGhostRepairBulkInventoryBuilder.build(input: input)
    }

    init(
        snapshotReference: String,
        sourceLayoutIdentifier: String,
        items: [CodexGhostRepairBulkInventoryItem],
        inventoryDigest: String,
        sourceEvidence: CodexGhostRepairBulkInventoryInput? = nil,
        displayTitles: [String: String] = [:]
    ) {
        self.snapshotReference = snapshotReference
        self.sourceLayoutIdentifier = sourceLayoutIdentifier
        self.items = items
        self.inventoryDigest = inventoryDigest
        self.sourceEvidence = sourceEvidence
        self.displayTitles = sourceEvidence.map { input in
            Dictionary(uniqueKeysWithValues: input.targets.compactMap { target in
                target.displayTitle.map { (target.threadID, $0) }
            })
        } ?? displayTitles
    }

    public var observedCatalogItemCount: Int { items.count }
    public var confirmedGhostCount: Int {
        items.filter(\.confirmedGhost).count
    }
    public var eligibleItemCount: Int {
        items.count { $0.disposition == .eligible }
    }
    public var blockedItemCount: Int {
        items.count {
            $0.disposition == .blocked || $0.disposition == .unconfirmed
        }
    }
    public var notGhostItemCount: Int {
        items.count { $0.disposition == .notGhost }
    }
    public var ordinaryEligibleItemCount: Int {
        items.count {
            $0.disposition == .eligible && $0.category == .ordinary
        }
    }
    public var automationEligibleItemCount: Int {
        items.count {
            $0.disposition == .eligible && $0.category == .automation
        }
    }
    public var eligibleThreadIDs: [String] {
        items.filter(\.selectable).map(\.threadID)
    }

    public var automaticallyClassified: Bool { true }
    public var requiresCallerSuppliedThreadIDs: Bool { false }
    public var persistsPreview: Bool { false }
    public var repairPreviewAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    private enum CodingKeys: String, CodingKey {
        case snapshotReference
        case sourceLayoutIdentifier
        case items
        case inventoryDigest
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            snapshotReference: try values.decode(
                String.self,
                forKey: .snapshotReference
            ),
            sourceLayoutIdentifier: try values.decode(
                String.self,
                forKey: .sourceLayoutIdentifier
            ),
            items: try values.decode(
                [CodexGhostRepairBulkInventoryItem].self,
                forKey: .items
            ),
            inventoryDigest: try values.decode(
                String.self,
                forKey: .inventoryDigest
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(snapshotReference, forKey: .snapshotReference)
        try values.encode(
            sourceLayoutIdentifier,
            forKey: .sourceLayoutIdentifier
        )
        try values.encode(items, forKey: .items)
        try values.encode(inventoryDigest, forKey: .inventoryDigest)
    }

    public static func == (
        lhs: CodexGhostRepairBulkInventory,
        rhs: CodexGhostRepairBulkInventory
    ) -> Bool {
        lhs.snapshotReference == rhs.snapshotReference
            && lhs.sourceLayoutIdentifier == rhs.sourceLayoutIdentifier
            && lhs.items == rhs.items
            && lhs.inventoryDigest == rhs.inventoryDigest
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(snapshotReference)
        hasher.combine(sourceLayoutIdentifier)
        hasher.combine(items)
        hasher.combine(inventoryDigest)
    }
}

struct CodexGhostRepairBulkInventorySnapshotEvidence: Sendable {
    let snapshotReference: String
    let sourceLayoutIdentifier: String
    let sourceFingerprintHash: String
    let manifestHash: String
    let readback: CodexGhostRepairBulkCatalogQueryReadback
}

struct CodexGhostRepairBulkOfficialInventoryEvidence: Sendable {
    let runtimeVersion: String
    let complete: Bool
    let activeThreadIDs: [String]
    let archivedThreadIDs: [String]
}

struct CodexGhostRepairBulkExactObservation: Sendable {
    let threadID: String
    let exactReadNotLoaded: Bool
    let exactReadErrorCode: Int
    let pinned: Bool
    let descendantCount: Int
    var exactReadPresent: Bool = false
}

enum CodexGhostRepairBulkInventoryComposer {
    static func compose(
        snapshot: CodexGhostRepairBulkInventorySnapshotEvidence,
        officialInventory: CodexGhostRepairBulkOfficialInventoryEvidence,
        exactObservations: [CodexGhostRepairBulkExactObservation]
    ) throws -> CodexGhostRepairBulkInventory {
        guard officialInventory.complete,
              CodexGhostRepairPackagedReadOnlyProfileCatalog.supportsPair(
                runtimeVersion: officialInventory.runtimeVersion,
                sourceLayoutIdentifier: snapshot.sourceLayoutIdentifier,
                databases: snapshot.readback.databases
              ) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk inventory requires complete version-matched official inventory."
            )
        }
        let active = try canonicalInventorySet(
            officialInventory.activeThreadIDs
        )
        let archived = try canonicalInventorySet(
            officialInventory.archivedThreadIDs
        )
        guard active.isDisjoint(with: archived) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Official active and archived inventory overlap."
            )
        }

        let observedIDs = snapshot.readback.targets.map(\.threadID)
        let official = active.union(archived)
        let targetByID = Dictionary(
            uniqueKeysWithValues: snapshot.readback.targets.map {
                ($0.threadID, $0)
            }
        )
        let candidateIDs = observedIDs.filter { threadID in
            !official.contains(threadID)
                && targetByID[threadID]?.references.canonicalState == 0
        }
        let exactByID = try exactObservationMap(
            exactObservations,
            candidateIDs: candidateIDs
        )
        let protection = try observedIDs.map { threadID in
            if official.contains(threadID) {
                return CodexGhostRepairProtectionEvidence(
                    threadID: threadID,
                    inventoryComplete: true,
                    activeInventoryPresent: active.contains(threadID),
                    archivedInventoryPresent: archived.contains(threadID),
                    exactReadNotLoaded: false,
                    exactReadErrorCode: 0,
                    pinned: false,
                    descendantCount: 0
                )
            }
            guard targetByID[threadID]?.references.canonicalState == 0 else {
                return CodexGhostRepairProtectionEvidence(
                    threadID: threadID,
                    inventoryComplete: true,
                    activeInventoryPresent: false,
                    archivedInventoryPresent: false,
                    exactReadNotLoaded: false,
                    exactReadErrorCode: 0,
                    pinned: false,
                    descendantCount: 0
                )
            }
            guard let exact = exactByID[threadID] else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Bulk inventory exact observation is incomplete."
                )
            }
            return CodexGhostRepairProtectionEvidence(
                threadID: threadID,
                inventoryComplete: true,
                activeInventoryPresent: false,
                archivedInventoryPresent: false,
                exactReadNotLoaded: exact.exactReadNotLoaded,
                exactReadErrorCode: exact.exactReadErrorCode,
                pinned: exact.pinned,
                descendantCount: exact.descendantCount
            )
        }
        return try CodexGhostRepairBulkInventoryBuilder.build(input: .init(
            snapshotReference: snapshot.snapshotReference,
            sourceLayoutIdentifier: snapshot.sourceLayoutIdentifier,
            sourceFingerprintHash: snapshot.sourceFingerprintHash,
            manifestHash: snapshot.manifestHash,
            databases: snapshot.readback.databases,
            targets: snapshot.readback.targets,
            protectionEvidence: protection,
            authority: snapshot.readback.authority
        ), exactReadPresentThreadIDs: Set(exactObservations.filter(\.exactReadPresent).map(\.threadID)))
    }

    private static func canonicalInventorySet(
        _ identifiers: [String]
    ) throws -> Set<String> {
        guard identifiers == identifiers.sorted(),
              Set(identifiers).count == identifiers.count,
              identifiers.count <= 10_000,
              identifiers.allSatisfy(isCanonicalUUID) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Official bulk inventory is not complete canonical evidence."
            )
        }
        return Set(identifiers)
    }

    private static func exactObservationMap(
        _ observations: [CodexGhostRepairBulkExactObservation],
        candidateIDs: [String]
    ) throws -> [String: CodexGhostRepairBulkExactObservation] {
        let identifiers = observations.map(\.threadID)
        guard Set(identifiers).count == identifiers.count,
              Set(identifiers) == Set(candidateIDs),
              observations.allSatisfy({
                  isCanonicalUUID($0.threadID) && $0.descendantCount >= 0
              }) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk inventory requires exact observation for every and only candidate row."
            )
        }
        return Dictionary(uniqueKeysWithValues: observations.map {
            ($0.threadID, $0)
        })
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

struct CodexGhostRepairBulkInventoryInput: Sendable {
    let snapshotReference: String
    let sourceLayoutIdentifier: String
    let sourceFingerprintHash: String
    let manifestHash: String
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let targets: [CodexGhostRepairSnapshotAnalysisTargetEvidence]
    let protectionEvidence: [CodexGhostRepairProtectionEvidence]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    var allowReviewedResidue: Bool = false
    var exactReadPresentThreadIDs: Set<String> = []
}

enum CodexGhostRepairBulkInventoryBuilder {
    private static let admittedSourceLayouts: Set<String> = [
        "codex-cli-0.149.0-paginated-v1",
        CodexGhostRepairPackagedReadOnlyProfileCatalog
            .v151SourceLayoutIdentifier,
        CodexGhostRepairPackagedReadOnlyProfileCatalog
            .v152SourceLayoutIdentifier,
        CodexGhostRepairPackagedReadOnlyProfileCatalog
            .v153SourceLayoutIdentifier,
        CodexGhostRepairPackagedReadOnlyProfileCatalog
            .v1534SourceLayoutIdentifier,
    ]

    static func build(
        input: CodexGhostRepairBulkInventoryInput,
        exactReadPresentThreadIDs: Set<String> = []
    ) throws -> CodexGhostRepairBulkInventory {
        var input = input
        input.exactReadPresentThreadIDs.formUnion(exactReadPresentThreadIDs)
        let exactReadPresentThreadIDs = input.exactReadPresentThreadIDs
        try validateSource(input)

        let protectionByID = try exactProtectionMap(
            input.protectionEvidence,
            targetIDs: input.targets.map(\.threadID)
        )
        guard exactReadPresentThreadIDs.allSatisfy({ id in
            guard let evidence = protectionByID[id] else { return false }
            return !evidence.exactReadNotLoaded && evidence.exactReadErrorCode == 0
        }) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Exact-readable inventory evidence contradicts its read outcome."
            )
        }
        let items = try input.targets.map { target in
            guard let protection = protectionByID[target.threadID] else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Bulk inventory protection evidence is incomplete."
                )
            }
            return try classify(
                target: target,
                protection: protection,
                exactReadPresent: exactReadPresentThreadIDs.contains(target.threadID),
                allowReviewedResidue: input.allowReviewedResidue
            )
        }

        let digestPayload = DigestPayload(
            snapshotReference: input.snapshotReference,
            sourceLayoutIdentifier: input.sourceLayoutIdentifier,
            sourceFingerprintHash: input.sourceFingerprintHash,
            manifestHash: input.manifestHash,
            databases: input.databases,
            items: items,
            authority: input.authority
        )
        return CodexGhostRepairBulkInventory(
            snapshotReference: input.snapshotReference,
            sourceLayoutIdentifier: input.sourceLayoutIdentifier,
            items: items,
            inventoryDigest: try CodexGhostRepairHasher.hash(digestPayload),
            sourceEvidence: input
        )
    }

    private static func classify(
        target: CodexGhostRepairSnapshotAnalysisTargetEvidence,
        protection: CodexGhostRepairProtectionEvidence,
        exactReadPresent: Bool,
        allowReviewedResidue: Bool
    ) throws -> CodexGhostRepairBulkInventoryItem {
        if protection.activeInventoryPresent
            || protection.archivedInventoryPresent
        {
            return try item(
                target: target,
                protection: protection,
                disposition: .notGhost,
                category: nil,
                blockers: []
            )
        }

        var blockers: [CodexGhostRepairBulkInventoryBlocker] = []
        if !protection.inventoryComplete {
            blockers.append(.incompleteOfficialInventory)
        }
        if target.references.canonicalState != 0 {
            blockers.append(.canonicalStatePresent)
            // The composer deliberately excludes these IDs from exact reads.
            blockers.append(.exactReadNotPerformed)
        } else if exactReadPresent {
            blockers.append(.exactReadPresent)
        } else if !protection.exactReadNotLoaded {
            blockers.append(.exactReadUnavailable)
        } else if protection.exactReadErrorCode != -32600 {
            blockers.append(.exactReadContractMismatch)
        }

        let exactAbsenceConfirmed = protection.inventoryComplete
            && target.references.canonicalState == 0
            && protection.exactReadNotLoaded
            && protection.exactReadErrorCode == -32600
        guard exactAbsenceConfirmed else {
            return try item(
                target: target,
                protection: protection,
                disposition: .unconfirmed,
                category: nil,
                blockers: canonical(blockers)
            )
        }

        if protection.pinned { blockers.append(.pinned) }
        if protection.descendantCount != 0 {
            blockers.append(.descendantsPresent)
        }
        if target.hasNoResidue, blockers.isEmpty {
            var result = try item(target: target, protection: protection,
                                  disposition: .eligible, category: .ordinary, blockers: [])
            result.initiallyAbsent = true
            return result
        }
        if target.rowContract == .unsupported {
            blockers.append(.unsupportedRowShape)
        }
        if target.references.summaries != 0 {
            blockers.append(.summaryRecordsPresent)
        }
        if target.references.total - target.references.summaries != 0 {
            blockers.append(.sideReferencesPresent)
        }

        var category: CodexGhostRepairCategory? = switch target.rowContract {
        case .categoryAEligible: .ordinary
        case .categoryBEligible: .automation
        case .unsupported: nil
        }
        var reviewedResidue: CodexGhostRepairReviewedSessionResidue?
        if allowReviewedResidue,
           !blockers.isEmpty,
           blockers.allSatisfy({ $0 == .summaryRecordsPresent || $0 == .unsupportedRowShape }),
           target.references.total == target.references.summaries,
           (category != nil || target.pausedAutomationReviewable == true),
           target.references.summaries == (target.summaryRowDigests ?? []).count {
            let scope = CodexGhostRepairReviewedSessionResidue(
                summaryRowDigests: target.summaryRowDigests ?? [],
                pausedAutomation: target.pausedAutomationReviewable == true
            )
            if scope.isValid {
                reviewedResidue = scope
                if scope.pausedAutomation { category = .automation }
                blockers = []
            }
        }
        let disposition: CodexGhostRepairBulkInventoryDisposition =
            blockers.isEmpty ? .eligible : .blocked
        var result = try item(
            target: target,
            protection: protection,
            disposition: disposition,
            category: category,
            blockers: canonical(blockers)
        )
        result.reviewedResidue = reviewedResidue
        return result
    }

    private static func item(
        target: CodexGhostRepairSnapshotAnalysisTargetEvidence,
        protection: CodexGhostRepairProtectionEvidence,
        disposition: CodexGhostRepairBulkInventoryDisposition,
        category: CodexGhostRepairCategory?,
        blockers: [CodexGhostRepairBulkInventoryBlocker]
    ) throws -> CodexGhostRepairBulkInventoryItem {
        let evidence = ItemDigestPayload(
            target: target,
            protection: protection,
            disposition: disposition,
            category: category,
            blockers: blockers
        )
        return CodexGhostRepairBulkInventoryItem(
            threadID: target.threadID,
            disposition: disposition,
            category: category,
            blockers: blockers,
            evidenceDigest: try CodexGhostRepairHasher.hash(evidence)
        )
    }

    private static func validateSource(
        _ input: CodexGhostRepairBulkInventoryInput
    ) throws {
        guard let snapshotID = UUID(uuidString: input.snapshotReference),
              snapshotID.uuidString.lowercased() == input.snapshotReference,
              admittedSourceLayouts.contains(input.sourceLayoutIdentifier),
              isSHA256(input.sourceFingerprintHash),
              isSHA256(input.manifestHash),
              (0...CodexGhostRepairBulkInventory.maximumObservedCatalogItems)
                .contains(input.targets.count),
              input.targets.map(\.threadID)
                == input.targets.map(\.threadID).sorted(),
              Set(input.targets.map(\.threadID)).count == input.targets.count,
              input.targets.allSatisfy(validTarget),
              isSHA256(input.authority.metadataRowDigest),
              isSHA256(input.authority.localSyncRowDigest) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk inventory source evidence is invalid."
            )
        }

        guard CodexGhostRepairPackagedReadOnlyProfileCatalog.supportsSource(
            sourceLayoutIdentifier: input.sourceLayoutIdentifier,
            databases: input.databases
        ) else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Bulk inventory requires the admitted four-database contract."
            )
        }
    }

    private static func exactProtectionMap(
        _ evidence: [CodexGhostRepairProtectionEvidence],
        targetIDs: [String]
    ) throws -> [String: CodexGhostRepairProtectionEvidence] {
        let evidenceIDs = evidence.map(\.threadID)
        guard evidence.count == targetIDs.count,
              Set(evidenceIDs).count == evidenceIDs.count,
              Set(evidenceIDs) == Set(targetIDs),
              evidence.allSatisfy({ $0.descendantCount >= 0 }) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk inventory requires one exact protection result per observed catalog row."
            )
        }
        return Dictionary(uniqueKeysWithValues: evidence.map {
            ($0.threadID, $0)
        })
    }

    private static func validTarget(
        _ target: CodexGhostRepairSnapshotAnalysisTargetEvidence
    ) -> Bool {
        guard let threadID = UUID(uuidString: target.threadID),
              threadID.uuidString.lowercased() == target.threadID,
              target.references.inbox >= 0,
              target.references.timeline >= 0,
              target.references.summaries >= 0,
              target.references.canonicalState >= 0,
              target.references.threadTurns >= 0,
              target.references.threadItems >= 0,
              target.references.historyProjection >= 0 else {
            return false
        }
        return (
            target.catalogRowDigests
                + target.automationRunRowDigests
                + target.automationDefinitionRowDigests
        ).allSatisfy(isSHA256)
    }

    private static func canonical(
        _ blockers: [CodexGhostRepairBulkInventoryBlocker]
    ) -> [CodexGhostRepairBulkInventoryBlocker] {
        CodexGhostRepairBulkInventoryBlocker.allCases.filter {
            blockers.contains($0)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

private struct ItemDigestPayload: Encodable {
    let target: CodexGhostRepairSnapshotAnalysisTargetEvidence
    let protection: CodexGhostRepairProtectionEvidence
    let disposition: CodexGhostRepairBulkInventoryDisposition
    let category: CodexGhostRepairCategory?
    let blockers: [CodexGhostRepairBulkInventoryBlocker]
}

private struct DigestPayload: Encodable {
    let snapshotReference: String
    let sourceLayoutIdentifier: String
    let sourceFingerprintHash: String
    let manifestHash: String
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let items: [CodexGhostRepairBulkInventoryItem]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
}
