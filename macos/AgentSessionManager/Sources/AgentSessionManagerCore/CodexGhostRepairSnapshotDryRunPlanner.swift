import Foundation

public enum CodexGhostRepairSnapshotDryRunBlockerCode:
    String,
    Encodable,
    Hashable,
    Sendable
{
    case invalidPreviewLifetime
    case invalidFrozenSelection
    case snapshotEvidenceDrift
    case invalidDatabaseContract
    case invalidTargetEvidence
    case invalidProtectionEvidence
    case unexpectedSideReference
    case mixedCategory
}

public struct CodexGhostRepairSnapshotDryRunBlocker:
    Encodable,
    Hashable,
    Sendable
{
    public let code: CodexGhostRepairSnapshotDryRunBlockerCode
    public let threadID: String?

    public init(
        code: CodexGhostRepairSnapshotDryRunBlockerCode,
        threadID: String? = nil
    ) {
        self.code = code
        self.threadID = threadID
    }
}

public enum CodexGhostRepairSnapshotDryRunLogicalEffectKind:
    String,
    Codable,
    Hashable,
    Sendable
{
    case removeCatalogRow
    case removeReviewedSessionSummaries
    case archiveAutomationRun
    case incrementCatalogRevision
    case incrementObservationSequence
}

public struct CodexGhostRepairSnapshotDryRunLogicalEffect:
    Codable,
    Hashable,
    Sendable
{
    public let kind: CodexGhostRepairSnapshotDryRunLogicalEffectKind
    public let threadID: String?
    public let amount: Int

    public init(
        kind: CodexGhostRepairSnapshotDryRunLogicalEffectKind,
        threadID: String? = nil,
        amount: Int
    ) {
        self.kind = kind
        self.threadID = threadID
        self.amount = amount
    }
}

public enum CodexGhostRepairSnapshotDryRunLiveCapability:
    String,
    Codable,
    Hashable,
    Sendable
{
    /// Category A is analyzable, but M2 evidence never authorizes execution.
    case requiresMilestone3FreshAuthority
    /// Category B remains blocked until its continuity contract is completed.
    case unavailableCategoryBContinuity
}

public struct CodexGhostRepairSnapshotDryRunItem:
    Codable,
    Hashable,
    Sendable
{
    public let threadID: String
    public let category: CodexGhostRepairCategory
    public let catalogRowDigest: String
    public let automationRunRowDigest: String?
    public let automationDefinitionRowDigest: String?
    public let references: CodexGhostRepairSnapshotAnalysisReferenceCounts
    public let protectionEvidence: CodexGhostRepairProtectionEvidence
    public let experimentalAbsenceEvidence:
        CodexGhostRepairExperimentalAbsenceEvidence
    public let expectedLogicalEffects:
        [CodexGhostRepairSnapshotDryRunLogicalEffect]

    public var exposesPrivateRowValues: Bool { false }
}

private struct CodexGhostRepairSnapshotDryRunPreviewPayload:
    Encodable,
    Hashable
{
    let previewID: UUID
    let generatedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let snapshotIdentity: CodexGhostRepairSnapshotAnalysisIdentity
    let sourceLayoutIdentifier: String
    let category: CodexGhostRepairCategory
    let targetThreadIDs: [String]
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    let items: [CodexGhostRepairSnapshotDryRunItem]
    let authorityAudit: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let operationalAudit: CodexGhostRepairExecutionGate
    let expectedBatchEffects:
        [CodexGhostRepairSnapshotDryRunLogicalEffect]
    let liveCapability: CodexGhostRepairSnapshotDryRunLiveCapability
}

public struct CodexGhostRepairSnapshotDryRunPreview:
    Codable,
    Hashable,
    Sendable
{
    public let previewID: UUID
    public let generatedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let snapshotIdentity: CodexGhostRepairSnapshotAnalysisIdentity
    public let sourceLayoutIdentifier: String
    public let category: CodexGhostRepairCategory
    public let targetThreadIDs: [String]
    public let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    public let items: [CodexGhostRepairSnapshotDryRunItem]
    public let authorityAudit: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    public let operationalAudit: CodexGhostRepairExecutionGate
    public let expectedBatchEffects:
        [CodexGhostRepairSnapshotDryRunLogicalEffect]
    public let liveCapability: CodexGhostRepairSnapshotDryRunLiveCapability
    public let previewDigest: String
    public let dryRunToken: String

    public var allOrNothing: Bool { true }
    public var silentSelectionShrinkAllowed: Bool { false }
    public var exposesPrivateRowValues: Bool { false }
    public var persistsPreview: Bool { false }
    public var readsLiveCodexDatabase: Bool { false }
    public var writesCodexDatabase: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    fileprivate init(
        previewID: UUID,
        generatedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        snapshotIdentity: CodexGhostRepairSnapshotAnalysisIdentity,
        sourceLayoutIdentifier: String,
        category: CodexGhostRepairCategory,
        targetThreadIDs: [String],
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence],
        items: [CodexGhostRepairSnapshotDryRunItem],
        authorityAudit: CodexGhostRepairSnapshotAnalysisAuthorityEvidence,
        operationalAudit: CodexGhostRepairExecutionGate,
        expectedBatchEffects:
            [CodexGhostRepairSnapshotDryRunLogicalEffect],
        liveCapability: CodexGhostRepairSnapshotDryRunLiveCapability
    ) throws {
        let payload = CodexGhostRepairSnapshotDryRunPreviewPayload(
            previewID: previewID,
            generatedAtMilliseconds: generatedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds,
            snapshotIdentity: snapshotIdentity,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            category: category,
            targetThreadIDs: targetThreadIDs,
            databases: databases,
            items: items,
            authorityAudit: authorityAudit,
            operationalAudit: operationalAudit,
            expectedBatchEffects: expectedBatchEffects,
            liveCapability: liveCapability
        )
        let digest = try CodexGhostRepairHasher.hash(payload)
        self.previewID = previewID
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.snapshotIdentity = snapshotIdentity
        self.sourceLayoutIdentifier = sourceLayoutIdentifier
        self.category = category
        self.targetThreadIDs = targetThreadIDs
        self.databases = databases
        self.items = items
        self.authorityAudit = authorityAudit
        self.operationalAudit = operationalAudit
        self.expectedBatchEffects = expectedBatchEffects
        self.liveCapability = liveCapability
        previewDigest = digest
        dryRunToken = "GHOST-DRY-RUN-"
            + digest.dropFirst("sha256:".count).prefix(12).uppercased()
    }

    private enum CodingKeys: String, CodingKey {
        case previewID
        case generatedAtMilliseconds
        case expiresAtMilliseconds
        case snapshotIdentity
        case sourceLayoutIdentifier
        case category
        case targetThreadIDs
        case databases
        case items
        case authorityAudit
        case operationalAudit
        case expectedBatchEffects
        case liveCapability
        case previewDigest
        case dryRunToken
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedDigest = try values.decode(
            String.self,
            forKey: .previewDigest
        )
        let storedToken = try values.decode(
            String.self,
            forKey: .dryRunToken
        )
        try self.init(
            previewID: try values.decode(UUID.self, forKey: .previewID),
            generatedAtMilliseconds: try values.decode(
                Int64.self,
                forKey: .generatedAtMilliseconds
            ),
            expiresAtMilliseconds: try values.decode(
                Int64.self,
                forKey: .expiresAtMilliseconds
            ),
            snapshotIdentity: try values.decode(
                CodexGhostRepairSnapshotAnalysisIdentity.self,
                forKey: .snapshotIdentity
            ),
            sourceLayoutIdentifier: try values.decode(
                String.self,
                forKey: .sourceLayoutIdentifier
            ),
            category: try values.decode(
                CodexGhostRepairCategory.self,
                forKey: .category
            ),
            targetThreadIDs: try values.decode(
                [String].self,
                forKey: .targetThreadIDs
            ),
            databases: try values.decode(
                [CodexGhostRepairSnapshotAnalysisDatabaseEvidence].self,
                forKey: .databases
            ),
            items: try values.decode(
                [CodexGhostRepairSnapshotDryRunItem].self,
                forKey: .items
            ),
            authorityAudit: try values.decode(
                CodexGhostRepairSnapshotAnalysisAuthorityEvidence.self,
                forKey: .authorityAudit
            ),
            operationalAudit: try values.decode(
                CodexGhostRepairExecutionGate.self,
                forKey: .operationalAudit
            ),
            expectedBatchEffects: try values.decode(
                [CodexGhostRepairSnapshotDryRunLogicalEffect].self,
                forKey: .expectedBatchEffects
            ),
            liveCapability: try values.decode(
                CodexGhostRepairSnapshotDryRunLiveCapability.self,
                forKey: .liveCapability
            )
        )
        guard previewDigest == storedDigest,
              dryRunToken == storedToken else {
            throw DecodingError.dataCorruptedError(
                forKey: .previewDigest,
                in: values,
                debugDescription:
                    "Dry-run Preview digest or token does not match its payload."
            )
        }
    }
}

public enum CodexGhostRepairSnapshotDryRunPlanningOutcome:
    Hashable,
    Sendable
{
    case preview(CodexGhostRepairSnapshotDryRunPreview)
    case blocked([CodexGhostRepairSnapshotDryRunBlocker])
}

extension CodexGhostRepairSnapshotDryRunPreview {
    func validateForPersistence() throws {
        let payload = CodexGhostRepairSnapshotDryRunPreviewPayload(
            previewID: previewID,
            generatedAtMilliseconds: generatedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds,
            snapshotIdentity: snapshotIdentity,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            category: category,
            targetThreadIDs: targetThreadIDs,
            databases: databases,
            items: items,
            authorityAudit: authorityAudit,
            operationalAudit: operationalAudit,
            expectedBatchEffects: expectedBatchEffects,
            liveCapability: liveCapability
        )
        let expectedDigest = try CodexGhostRepairHasher.hash(payload)
        let expectedToken = "GHOST-DRY-RUN-"
            + expectedDigest.dropFirst("sha256:".count)
                .prefix(12).uppercased()
        var databaseVersions:
            [CodexGhostRepairSnapshotAnalysisDatabase: Int32] = [:]
        for database in databases {
            guard databaseVersions.updateValue(
                database.schemaVersion,
                forKey: database.database
            ) == nil else {
                throw PersistentStateError.invalidRecord(
                    "Dry-run Preview database contract contains duplicates."
                )
            }
        }
        let expectedItemEffects: (CodexGhostRepairSnapshotDryRunItem) -> Bool = {
            item in
            switch category {
            case .ordinary:
                return item.automationRunRowDigest == nil
                    && item.automationDefinitionRowDigest == nil
                    && item.expectedLogicalEffects == [
                        .init(
                            kind: .removeCatalogRow,
                            threadID: item.threadID,
                            amount: 1
                        ),
                    ]
            case .automation:
                return item.automationRunRowDigest != nil
                    && item.automationDefinitionRowDigest != nil
                    && item.expectedLogicalEffects == [
                        .init(
                            kind: .removeCatalogRow,
                            threadID: item.threadID,
                            amount: 1
                        ),
                        .init(
                            kind: .archiveAutomationRun,
                            threadID: item.threadID,
                            amount: 1
                        ),
                    ]
            }
        }
        let expectedBatchEffects = [
            CodexGhostRepairSnapshotDryRunLogicalEffect(
                kind: .incrementCatalogRevision,
                amount: targetThreadIDs.count
            ),
            CodexGhostRepairSnapshotDryRunLogicalEffect(
                kind: .incrementObservationSequence,
                amount: targetThreadIDs.count
            ),
        ]

        guard generatedAtMilliseconds >= 0,
              expiresAtMilliseconds > generatedAtMilliseconds,
              expiresAtMilliseconds - generatedAtMilliseconds
                <= 15 * 60 * 1_000,
              (1...2).contains(targetThreadIDs.count),
              targetThreadIDs == targetThreadIDs.sorted(),
              Set(targetThreadIDs).count == targetThreadIDs.count,
              snapshotIdentity.targetThreadIDs == targetThreadIDs,
              sourceLayoutIdentifier
                == CodexGhostRepairSnapshotSourceLayout.identifier,
              databases.map(\.database)
                == CodexGhostRepairSnapshotAnalysisDatabase.allCases,
              Set(databases.map(\.database)).count == databases.count,
              databases.allSatisfy({
                  $0.integrityCheckPassed
                    && $0.foreignKeyViolationCount == 0
              }),
              databaseVersions[.desktop] == 32,
              databaseVersions[.summaries] == 2,
              databaseVersions[.state] == 0,
              databaseVersions[.threadHistory] == 0,
              items.map(\.threadID) == targetThreadIDs,
              items.allSatisfy({
                  $0.category == category
                    && $0.references.total == 0
                    && $0.protectionEvidence.threadID == $0.threadID
                    && $0.protectionEvidence.isEligible
                    && $0.experimentalAbsenceEvidence.requestedThreadID
                        == $0.threadID
                    && !$0.experimentalAbsenceEvidence.officialGuarantee
                    && !$0.experimentalAbsenceEvidence.provesOfficialAbsence
                    && !$0.experimentalAbsenceEvidence.confirmationAuthority
                    && !$0.experimentalAbsenceEvidence.repairMutationAuthority
                    && $0.experimentalAbsenceEvidence
                        .sourceLayoutIdentifier == sourceLayoutIdentifier
                    && $0.experimentalAbsenceEvidence.databases.map(\.database)
                        == databases.map(\.database)
                    && $0.experimentalAbsenceEvidence.databases
                        .map(\.schemaVersion) == databases.map(\.schemaVersion)
                    && Self.isSHA256($0.catalogRowDigest)
                    && ($0.automationRunRowDigest.map(Self.isSHA256) ?? true)
                    && ($0.automationDefinitionRowDigest
                        .map(Self.isSHA256) ?? true)
                    && expectedItemEffects($0)
              }),
              authorityAudit.catalogRevision >= 0,
              authorityAudit.observationSequence >= 0,
              Self.isSHA256(authorityAudit.metadataRowDigest),
              Self.isSHA256(authorityAudit.localSyncRowDigest),
              expectedBatchEffects == self.expectedBatchEffects,
              liveCapability == (category == .ordinary
                  ? .requiresMilestone3FreshAuthority
                  : .unavailableCategoryBContinuity),
              previewDigest == expectedDigest,
              dryRunToken == expectedToken,
              !confirmationAuthority,
              !repairMutationAuthority else {
            throw PersistentStateError.invalidRecord(
                "Dry-run Preview persistence contract is invalid."
            )
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

public struct CodexGhostRepairSnapshotDryRunPlannerCapabilities:
    Hashable,
    Sendable
{
    public let pureDeterministicPlanningAvailable: Bool

    public var acceptsCallerPath: Bool { false }
    public var opensSQLite: Bool { false }
    public var readsLiveCodexDatabase: Bool { false }
    public var writesFilesystem: Bool { false }
    public var persistsPreview: Bool { false }
    public var automaticPlanning: Bool { false }
    public var automaticRetry: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let dryRunOnly = Self(
        pureDeterministicPlanningAvailable: true
    )
}

/// M2d is a pure transformation over already frozen evidence. It has no
/// filesystem, SQLite, official transport, persistence, or repair executor.
public enum CodexGhostRepairSnapshotDryRunPlanner {
    public static let capabilities =
        CodexGhostRepairSnapshotDryRunPlannerCapabilities.dryRunOnly

    public static func plan(
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        snapshotEvidence: CodexGhostRepairSnapshotAnalysisReadback,
        protectionEvidence: [CodexGhostRepairProtectionEvidence],
        experimentalAbsenceEvidence:
            [CodexGhostRepairExperimentalAbsenceEvidence],
        operationalAudit: CodexGhostRepairExecutionGate,
        previewID: UUID,
        generatedAtMilliseconds: Int64,
        lifetimeMilliseconds: Int64
    ) -> CodexGhostRepairSnapshotDryRunPlanningOutcome {
        guard generatedAtMilliseconds >= 0,
              lifetimeMilliseconds > 0,
              lifetimeMilliseconds <= 15 * 60 * 1_000,
              !generatedAtMilliseconds
                .addingReportingOverflow(lifetimeMilliseconds).overflow else {
            return blocked(.invalidPreviewLifetime)
        }
        let expiresAtMilliseconds =
            generatedAtMilliseconds + lifetimeMilliseconds

        guard (1...2).contains(identity.targetThreadIDs.count),
              identity.targetThreadIDs == identity.targetThreadIDs.sorted(),
              Set(identity.targetThreadIDs).count
                == identity.targetThreadIDs.count else {
            return blocked(.invalidFrozenSelection)
        }
        guard snapshotEvidence.identity == identity,
              snapshotEvidence.sourceLayoutIdentifier
                == CodexGhostRepairSnapshotSourceLayout.identifier else {
            return blocked(.snapshotEvidenceDrift)
        }
        guard validDatabaseContract(snapshotEvidence.databases),
              validAuthority(snapshotEvidence.authority) else {
            return blocked(.invalidDatabaseContract)
        }
        guard snapshotEvidence.targets.map(\.threadID)
                == identity.targetThreadIDs else {
            return blocked(.snapshotEvidenceDrift)
        }

        var protectionByID: [String: CodexGhostRepairProtectionEvidence] = [:]
        for evidence in protectionEvidence {
            guard protectionByID.updateValue(
                evidence,
                forKey: evidence.threadID
            ) == nil else {
                return blocked(.invalidProtectionEvidence)
            }
        }
        guard Set(protectionByID.keys) == Set(identity.targetThreadIDs) else {
            return blocked(.invalidProtectionEvidence)
        }
        var experimentalByID:
            [String: CodexGhostRepairExperimentalAbsenceEvidence] = [:]
        for evidence in experimentalAbsenceEvidence {
            guard experimentalByID.updateValue(
                evidence,
                forKey: evidence.requestedThreadID
            ) == nil else {
                return blocked(.invalidProtectionEvidence)
            }
        }
        guard Set(experimentalByID.keys) == Set(identity.targetThreadIDs) else {
            return blocked(.invalidProtectionEvidence)
        }

        var categories: [CodexGhostRepairCategory] = []
        var items: [CodexGhostRepairSnapshotDryRunItem] = []
        for target in snapshotEvidence.targets {
            guard let protection = protectionByID[target.threadID],
                  let experimental = experimentalByID[target.threadID],
                  experimental.provider == .codex,
                  experimental.sourceLayoutIdentifier
                    == snapshotEvidence.sourceLayoutIdentifier,
                  experimental.databases.map(\.database)
                    == snapshotEvidence.databases.map(\.database),
                  experimental.databases.map(\.schemaVersion)
                    == snapshotEvidence.databases.map(\.schemaVersion),
                  !experimental.officialGuarantee,
                  !experimental.provesOfficialAbsence,
                  protection.isEligible else {
                return blocked(
                    .invalidProtectionEvidence,
                    threadID: target.threadID
                )
            }
            guard target.references.total == 0 else {
                return blocked(
                    .unexpectedSideReference,
                    threadID: target.threadID
                )
            }
            guard target.catalogRowDigests.count == 1,
                  validDigests(target.catalogRowDigests),
                  validDigests(target.automationRunRowDigests),
                  validDigests(target.automationDefinitionRowDigests) else {
                return blocked(
                    .invalidTargetEvidence,
                    threadID: target.threadID
                )
            }

            let category: CodexGhostRepairCategory
            let automationRunDigest: String?
            let automationDefinitionDigest: String?
            let itemEffects: [CodexGhostRepairSnapshotDryRunLogicalEffect]
            if target.rowContract == .categoryAEligible,
               target.automationRunRowDigests.isEmpty,
               target.automationDefinitionRowDigests.isEmpty {
                category = .ordinary
                automationRunDigest = nil
                automationDefinitionDigest = nil
                itemEffects = [
                    .init(
                        kind: .removeCatalogRow,
                        threadID: target.threadID,
                        amount: 1
                    ),
                ]
            } else if target.rowContract == .categoryBEligible,
                      target.automationRunRowDigests.count == 1,
                      target.automationDefinitionRowDigests.count == 1 {
                category = .automation
                automationRunDigest = target.automationRunRowDigests[0]
                automationDefinitionDigest =
                    target.automationDefinitionRowDigests[0]
                itemEffects = [
                    .init(
                        kind: .removeCatalogRow,
                        threadID: target.threadID,
                        amount: 1
                    ),
                    .init(
                        kind: .archiveAutomationRun,
                        threadID: target.threadID,
                        amount: 1
                    ),
                ]
            } else {
                return blocked(
                    .invalidTargetEvidence,
                    threadID: target.threadID
                )
            }
            categories.append(category)
            items.append(.init(
                threadID: target.threadID,
                category: category,
                catalogRowDigest: target.catalogRowDigests[0],
                automationRunRowDigest: automationRunDigest,
                automationDefinitionRowDigest: automationDefinitionDigest,
                references: target.references,
                protectionEvidence: protection,
                experimentalAbsenceEvidence: experimental,
                expectedLogicalEffects: itemEffects
            ))
        }

        guard let category = categories.first,
              categories.allSatisfy({ $0 == category }) else {
            return blocked(.mixedCategory)
        }
        let count = identity.targetThreadIDs.count
        let batchEffects = [
            CodexGhostRepairSnapshotDryRunLogicalEffect(
                kind: .incrementCatalogRevision,
                amount: count
            ),
            CodexGhostRepairSnapshotDryRunLogicalEffect(
                kind: .incrementObservationSequence,
                amount: count
            ),
        ]
        let liveCapability: CodexGhostRepairSnapshotDryRunLiveCapability =
            category == .ordinary
                ? .requiresMilestone3FreshAuthority
                : .unavailableCategoryBContinuity

        do {
            return .preview(try .init(
                previewID: previewID,
                generatedAtMilliseconds: generatedAtMilliseconds,
                expiresAtMilliseconds: expiresAtMilliseconds,
                snapshotIdentity: identity,
                sourceLayoutIdentifier: snapshotEvidence.sourceLayoutIdentifier,
                category: category,
                targetThreadIDs: identity.targetThreadIDs,
                databases: snapshotEvidence.databases,
                items: items,
                authorityAudit: snapshotEvidence.authority,
                operationalAudit: operationalAudit,
                expectedBatchEffects: batchEffects,
                liveCapability: liveCapability
            ))
        } catch {
            return blocked(.invalidTargetEvidence)
        }
    }

    private static func blocked(
        _ code: CodexGhostRepairSnapshotDryRunBlockerCode,
        threadID: String? = nil
    ) -> CodexGhostRepairSnapshotDryRunPlanningOutcome {
        .blocked([.init(code: code, threadID: threadID)])
    }

    private static func validDatabaseContract(
        _ evidence: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    ) -> Bool {
        guard evidence.count
                == CodexGhostRepairSnapshotAnalysisDatabase.allCases.count,
              evidence.map(\.database)
                == CodexGhostRepairSnapshotAnalysisDatabase.allCases,
              Set(evidence.map(\.database)).count == evidence.count,
              evidence.allSatisfy({
                  $0.integrityCheckPassed
                    && $0.foreignKeyViolationCount == 0
              }) else {
            return false
        }
        let versions = Dictionary(
            uniqueKeysWithValues: evidence.map { ($0.database, $0.schemaVersion) }
        )
        return versions[.desktop] == 32
            && versions[.summaries] == 2
            && versions[.state] == 0
            && versions[.threadHistory] == 0
    }

    private static func validAuthority(
        _ evidence: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    ) -> Bool {
        evidence.catalogRevision >= 0
            && evidence.observationSequence >= 0
            && validDigest(evidence.metadataRowDigest)
            && validDigest(evidence.localSyncRowDigest)
    }

    private static func validDigests(_ values: [String]) -> Bool {
        Set(values).count == values.count && values.allSatisfy(validDigest)
    }

    private static func validDigest(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}
