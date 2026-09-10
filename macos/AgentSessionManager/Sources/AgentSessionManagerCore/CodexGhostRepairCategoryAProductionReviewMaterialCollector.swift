import Foundation

struct CodexGhostRepairCategoryAProductionDatabaseReviewReadback: Sendable {
    let result: CodexGhostRepairCanonicalQueryReadback
    let operationalGate: CodexGhostRepairExecutionGate
}

enum CodexGhostRepairCategoryAProductionDatabaseReviewOutcome: Sendable {
    case read(CodexGhostRepairCategoryAProductionDatabaseReviewReadback)
    case blocked(CodexGhostRepairCategoryARepairReviewBlocker)
    case unavailable
}

protocol CodexGhostRepairCategoryAProductionDatabaseReviewReading: Sendable {
    func read(targetThreadIDs: [String]) async
        -> CodexGhostRepairCategoryAProductionDatabaseReviewOutcome
}

/// Opens no live SQLite connection. It requires a clear production gate,
/// streams the fixed canonical raw files into an owner-private temporary copy,
/// runs the existing fixed query-only reader there, removes that copy, and
/// requires another clear gate before returning privacy-safe evidence.
actor CodexGhostRepairCategoryAProductionDatabaseReviewReader:
    CodexGhostRepairCategoryAProductionDatabaseReviewReading
{
    private let source: CodexGhostRepairSnapshotCanonicalSource
    private let gateSource: any CodexGhostRepairExecutionGateSource
    private let workspaceFactory:
        CodexGhostRepairSnapshotAnalysisWorkspaceFactory

    static func production(
        gateSource: any CodexGhostRepairExecutionGateSource
    ) -> Self {
        Self(
            source: .production(),
            gateSource: gateSource,
            workspaceFactory: .production()
        )
    }

    init(
        source: CodexGhostRepairSnapshotCanonicalSource,
        gateSource: any CodexGhostRepairExecutionGateSource,
        workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory
    ) {
        self.source = source
        self.gateSource = gateSource
        self.workspaceFactory = workspaceFactory
    }

    func read(targetThreadIDs: [String]) async
        -> CodexGhostRepairCategoryAProductionDatabaseReviewOutcome
    {
        let before: CodexGhostRepairExecutionGate
        do { before = try await gateSource.ghostRepairExecutionGate() }
        catch { return .unavailable }
        guard before.isClear else {
            return .blocked(.operatingConditionsBlocked)
        }
        let result: CodexGhostRepairCanonicalQueryReadback
        do {
            result = try CodexGhostRepairCanonicalQueryOnlyReader.read(
                    source: source,
                    targetThreadIDs: targetThreadIDs,
                    workspaceFactory: workspaceFactory
                )
        } catch {
            return .blocked(.schemaDrift)
        }
        let after: CodexGhostRepairExecutionGate
        do { after = try await gateSource.ghostRepairExecutionGate() }
        catch { return .unavailable }
        guard after.isClear else {
            return .blocked(.operatingConditionsBlocked)
        }
        return .read(.init(result: result, operationalGate: after))
    }
}

struct CodexGhostRepairCategoryAProductionProtectionReadback: Sendable {
    let protectionEvidenceHash: String
    let protectionComplete: Bool
    let operationalGateEvidenceHash: String
    let operationalGateClear: Bool
    let runtimeVersion: String
}

enum CodexGhostRepairCategoryAProductionProtectionOutcome: Sendable {
    case read(CodexGhostRepairCategoryAProductionProtectionReadback)
    case blocked(CodexGhostRepairCategoryARepairReviewBlocker)
    case unavailable
}

protocol CodexGhostRepairCategoryAProductionProtectionReading: Sendable {
    func read(
        targetThreadIDs: [String],
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    ) async -> CodexGhostRepairCategoryAProductionProtectionOutcome
}

private struct CodexGhostRepairCategoryAProductionProtectionPayload:
    Codable,
    Hashable
{
    let provider: AgentSystem
    let runtimeVersion: String
    let activeThreadIDs: [String]
    let archivedThreadIDs: [String]
    let pinnedThreadIDs: [String]
    let descendantNodes: [String]
    let presentControlThreadID: String
    let targetContractHashes: [String]
}

actor CodexGhostRepairCategoryAProductionProtectionReader:
    CodexGhostRepairCategoryAProductionProtectionReading
{
    private let transport:
        any CodexGhostRepairExperimentalObservationTransport
    private let registry: CodexGhostRepairExperimentalAbsenceRegistry

    static func production(
        gateSource: any CodexGhostRepairExecutionGateSource,
        appServerConfiguration: CodexAppServerConfiguration = .init()
    ) -> Self {
        let transport = CodexGhostRepairExperimentalAppServerObservationAdapter(
            source: CodexGhostRepairExperimentalReadOnlyAppServerSource(
                configuration: appServerConfiguration
            ),
            executionGateSource: gateSource
        )
        return Self(
            transport: transport,
            registry: .packagedReviewedV1()
        )
    }

    init(
        transport: any CodexGhostRepairExperimentalObservationTransport,
        registry: CodexGhostRepairExperimentalAbsenceRegistry
    ) {
        self.transport = transport
        self.registry = registry
    }

    func read(
        targetThreadIDs: [String],
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    ) async -> CodexGhostRepairCategoryAProductionProtectionOutcome {
        guard (1...2).contains(targetThreadIDs.count),
              targetThreadIDs == targetThreadIDs.sorted(),
              Set(targetThreadIDs).count == targetThreadIDs.count else {
            return .blocked(.targetDrift)
        }
        let inventory: CodexGhostRepairExperimentalTransportInventory
        do { inventory = try await transport.inventory() }
        catch { return .unavailable }
        guard inventory.provider == .codex,
              inventory.inventoryComplete,
              inventory.pinnedInventoryComplete,
              inventory.descendantGraphComplete,
              CodexGhostRepairSnapshotSourceLayout.supports(
                runtimeVersion: inventory.runtimeVersion
              ) else {
            return .blocked(.protectionUnavailable)
        }
        let active = Set(inventory.activeThreadIDs)
        let archived = Set(inventory.archivedThreadIDs)
        guard active.count == inventory.activeThreadIDs.count,
              archived.count == inventory.archivedThreadIDs.count,
              active.isDisjoint(with: archived),
              active.isDisjoint(with: targetThreadIDs),
              archived.isDisjoint(with: targetThreadIDs),
              inventory.pinnedThreadIDs.isDisjoint(
                with: targetThreadIDs
              ),
              Self.descendantCounts(
                nodes: inventory.descendantNodes,
                targets: targetThreadIDs
              ) == Array(repeating: 0, count: targetThreadIDs.count) else {
            return .blocked(.targetDrift)
        }
        guard let control = active.union(archived)
            .subtracting(targetThreadIDs).sorted().first else {
            return .blocked(.protectionUnavailable)
        }
        do {
            guard case let .present(returned) = try await transport.exactRead(
                threadID: control
            ), returned == control else {
                return .blocked(.protectionUnavailable)
            }
        } catch { return .unavailable }

        var contractHashes: [String] = []
        for threadID in targetThreadIDs {
            let raw: CodexGhostRepairExperimentalTransportExactReadOutcome
            do { raw = try await transport.exactRead(threadID: threadID) }
            catch { return .unavailable }
            guard case let .failure(kind, code, shape, message) = raw else {
                return .blocked(.targetDrift)
            }
            let outcome = registry.evaluate(.init(
                provider: inventory.provider,
                requestedThreadID: threadID,
                runtimeVersion: inventory.runtimeVersion,
                method: .threadRead,
                errorKind: kind,
                rpcCode: code,
                responseShapeIdentifier: shape,
                message: message,
                sourceLayoutIdentifier:
                    CodexGhostRepairSnapshotSourceLayout.identifier,
                databases: databases
            ))
            guard case let .matched(evidence) = outcome else {
                return .blocked(.protectionUnavailable)
            }
            contractHashes.append(evidence.canonicalResponseHash)
        }
        let gate: CodexGhostRepairExecutionGate
        do { gate = try await transport.operationalAudit() }
        catch { return .unavailable }
        guard gate.isClear else {
            return .blocked(.operatingConditionsBlocked)
        }
        do {
            let descendants = inventory.descendantNodes.map {
                "\($0.threadID):\($0.parentThreadID ?? "")"
            }.sorted()
            let protectionHash = try CodexGhostRepairHasher.hash(
                CodexGhostRepairCategoryAProductionProtectionPayload(
                    provider: inventory.provider,
                    runtimeVersion: inventory.runtimeVersion,
                    activeThreadIDs: inventory.activeThreadIDs.sorted(),
                    archivedThreadIDs: inventory.archivedThreadIDs.sorted(),
                    pinnedThreadIDs: inventory.pinnedThreadIDs.sorted(),
                    descendantNodes: descendants,
                    presentControlThreadID: control,
                    targetContractHashes: contractHashes
                )
            )
            return .read(.init(
                protectionEvidenceHash: protectionHash,
                protectionComplete: true,
                operationalGateEvidenceHash:
                    try CodexGhostRepairHasher.hash(gate),
                operationalGateClear: true,
                runtimeVersion: inventory.runtimeVersion
            ))
        } catch { return .unavailable }
    }

    private static func descendantCounts(
        nodes: [CodexGhostRepairExperimentalDescendantNode],
        targets: [String]
    ) -> [Int]? {
        var children: [String: [String]] = [:]
        var seen: Set<String> = []
        for node in nodes {
            guard seen.insert(node.threadID).inserted else { return nil }
            if let parent = node.parentThreadID {
                guard parent != node.threadID else { return nil }
                children[parent, default: []].append(node.threadID)
            }
        }
        return targets.map { target in
            var visited: Set<String> = [target]
            var queue = children[target] ?? []
            var offset = 0
            while offset < queue.count {
                let child = queue[offset]
                offset += 1
                guard visited.insert(child).inserted else { return -1 }
                queue.append(contentsOf: children[child] ?? [])
            }
            return visited.count - 1
        }
    }
}

/// M3i review material collector. Production construction is path-free and
/// zero-I/O; every read happens only after an explicit M3 review request.
actor CodexGhostRepairCategoryAProductionReviewMaterialCollector:
    CodexGhostRepairCategoryARepairReviewMaterialCollecting
{
    private let databaseReader:
        any CodexGhostRepairCategoryAProductionDatabaseReviewReading
    private let protectionReader:
        any CodexGhostRepairCategoryAProductionProtectionReading
    private let reviewID: @Sendable () -> UUID
    private let nowMilliseconds: @Sendable () -> Int64
    private let buildIdentifier: @Sendable () -> String

    static func production(
        appServerConfiguration: CodexAppServerConfiguration = .init()
    ) -> Self {
        let gate = CodexGhostRepairSnapshotOperationalGateSource.production()
        return Self(
            databaseReader:
                CodexGhostRepairCategoryAProductionDatabaseReviewReader
                    .production(gateSource: gate),
            protectionReader:
                CodexGhostRepairCategoryAProductionProtectionReader
                    .production(
                        gateSource: gate,
                        appServerConfiguration: appServerConfiguration
                    ),
            reviewID: { UUID() },
            nowMilliseconds: {
                Int64(Date().timeIntervalSince1970 * 1_000)
            },
            buildIdentifier: {
                let identifier = Bundle.main.bundleIdentifier
                    ?? "com.sean.AgentSessionManager"
                let short = Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "development"
                let build = Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "development"
                return "\(identifier)@\(short)+\(build)"
            }
        )
    }

    init(
        databaseReader:
            any CodexGhostRepairCategoryAProductionDatabaseReviewReading,
        protectionReader:
            any CodexGhostRepairCategoryAProductionProtectionReading,
        reviewID: @escaping @Sendable () -> UUID,
        nowMilliseconds: @escaping @Sendable () -> Int64,
        buildIdentifier: @escaping @Sendable () -> String
    ) {
        self.databaseReader = databaseReader
        self.protectionReader = protectionReader
        self.reviewID = reviewID
        self.nowMilliseconds = nowMilliseconds
        self.buildIdentifier = buildIdentifier
    }

    func collect(
        draft: CodexGhostRepairCategoryAExecutionDraft
    ) async -> CodexGhostRepairCategoryARepairReviewMaterialOutcome {
        let databaseOutcome = await databaseReader.read(
            targetThreadIDs: draft.targetThreadIDs
        )
        let readback: CodexGhostRepairCategoryAProductionDatabaseReviewReadback
        switch databaseOutcome {
        case let .read(value): readback = value
        case let .blocked(blocker): return .blocked(blocker)
        case .unavailable: return .unavailable
        }
        guard readback.result.sourceFingerprintHash
                == draft.snapshotSourceFingerprintHash,
              readback.result.targets.map(\.threadID)
                == draft.targetThreadIDs,
              readback.result.targets.allSatisfy({ target in
                  target.rowContract == .categoryAEligible
                      && target.catalogRowDigests.count == 1
                      && target.automationRunRowDigests.isEmpty
                      && target.automationDefinitionRowDigests.isEmpty
                      && target.references.total == 0
              }) else {
            return .blocked(.targetDrift)
        }
        let items = readback.result.targets.map {
            CodexGhostRepairCategoryAExecutionReviewItem(
                threadID: $0.threadID,
                catalogRowDigest: $0.catalogRowDigests[0]
            )
        }
        guard items == draft.itemChanges.map({
            .init(
                threadID: $0.threadID,
                catalogRowDigest: $0.catalogRowDigest
            )
        }), Self.schemasMatch(
            readback.result.databases,
            draft.databaseExpectations
        ) else {
            return .blocked(.schemaDrift)
        }
        let protectionOutcome = await protectionReader.read(
            targetThreadIDs: draft.targetThreadIDs,
            databases: readback.result.databases
        )
        let protection: CodexGhostRepairCategoryAProductionProtectionReadback
        switch protectionOutcome {
        case let .read(value): protection = value
        case let .blocked(blocker): return .blocked(blocker)
        case .unavailable: return .unavailable
        }
        guard protection.protectionComplete,
              protection.operationalGateClear,
              readback.operationalGate.isClear,
              CodexGhostRepairSnapshotSourceLayout.supports(
                runtimeVersion: protection.runtimeVersion
              ) else {
            return .blocked(.protectionUnavailable)
        }
        do {
            let review = try CodexGhostRepairCategoryAExecutionReviewEvidence(
                reviewID: reviewID(),
                items: items,
                protectionEvidenceHash:
                    protection.protectionEvidenceHash,
                protectionComplete: true,
                operationalGateEvidenceHash:
                    protection.operationalGateEvidenceHash,
                operationalGateClear: true,
                databaseExpectations: draft.databaseExpectations,
                authorityAudit: readback.result.authority,
                observedAtMilliseconds: nowMilliseconds()
            )
            return .material(.init(
                review: review,
                buildIdentifier: buildIdentifier(),
                observedAtMilliseconds: review.observedAtMilliseconds
            ))
        } catch { return .unavailable }
    }

    private static func schemasMatch(
        _ observed: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence],
        _ expected: [CodexGhostRepairCategoryADatabaseExpectation]
    ) -> Bool {
        let versions = Dictionary(uniqueKeysWithValues: observed.map {
            ($0.database.rawValue, $0.schemaVersion)
        })
        return expected.allSatisfy { item in
            guard item.required,
                  item.database != .legacyHistory,
                  let expectedVersion = item.admittedSchemaVersion else {
                return !item.required && item.database == .legacyHistory
            }
            return versions[item.database.rawValue] == expectedVersion
        }
    }
}
