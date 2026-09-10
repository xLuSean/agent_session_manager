import Foundation

public struct CodexGhostRepairBulkInventoryRequest:
    Equatable,
    Hashable,
    Sendable
{
    public let requestID: UUID
    public let snapshotReference: String

    public init(requestID: UUID, snapshotReference: String) {
        self.requestID = requestID
        self.snapshotReference = snapshotReference
    }

    public var acceptsCallerPath: Bool { false }
    public var acceptsCallerThreadIDs: Bool { false }
    public var automaticObservation: Bool { false }
    public var persistsPreview: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public struct CodexGhostRepairBulkInventoryCapabilities:
    Equatable,
    Hashable,
    Sendable
{
    public let observationAvailable: Bool
    public let canonicalSourceQueryAvailable: Bool
    public let publishedSnapshotQueryAvailable: Bool
    public let officialInventoryAvailable: Bool
    public let exactReadAvailable: Bool

    public var acceptsCallerPath: Bool { false }
    public var acceptsCallerThreadIDs: Bool { false }
    public var automaticObservation: Bool { false }
    public var automaticRetry: Bool { false }
    public var writesPublishedSnapshot: Bool { false }
    public var persistsPreview: Bool { false }
    public var officialLifecycleAuthority: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let unavailable = Self(
        observationAvailable: false,
        canonicalSourceQueryAvailable: false,
        publishedSnapshotQueryAvailable: false,
        officialInventoryAvailable: false,
        exactReadAvailable: false
    )

    static let packagedReadOnlyCandidate = Self(
        observationAvailable: true,
        canonicalSourceQueryAvailable: false,
        publishedSnapshotQueryAvailable: true,
        officialInventoryAvailable: true,
        exactReadAvailable: true
    )

    static let packagedLiveScan = Self(
        observationAvailable: true,
        canonicalSourceQueryAvailable: true,
        publishedSnapshotQueryAvailable: false,
        officialInventoryAvailable: true,
        exactReadAvailable: true
    )
}

public enum CodexGhostRepairBulkInventoryFailureStage:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case requestValidation = "request-validation"
    case snapshotRead = "snapshot-read"
    case canonicalSourceRead = "canonical-source-read"
    case officialInventory = "official-inventory"
    case snapshotProfile = "snapshot-profile"
    case presentControl = "present-control"
    case candidateExactRead = "candidate-exact-read"
    case composition = "composition"
    case busy
    case unavailable
}

public struct CodexGhostRepairBulkInventoryFailure:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let stage: CodexGhostRepairBulkInventoryFailureStage

    public var pathRedacted: Bool { true }
    public var rawErrorIncluded: Bool { false }
    public var partialInventoryPresented: Bool { false }
    public var automaticRetry: Bool { false }
    public var persistsPreview: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public enum CodexGhostRepairBulkInventoryOutcome:
    Equatable,
    Hashable,
    Sendable
{
    case inventory(
        requestID: UUID,
        inventory: CodexGhostRepairBulkInventory
    )
    case unavailable(
        requestID: UUID,
        failure: CodexGhostRepairBulkInventoryFailure
    )

    public var requestID: UUID {
        switch self {
        case let .inventory(requestID, _),
             let .unavailable(requestID, _):
            requestID
        }
    }

    public var persistsPreview: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public protocol CodexGhostRepairBulkInventoryCoordinating: Sendable {
    var capabilities: CodexGhostRepairBulkInventoryCapabilities { get }

    /// True only after an exact, fresh, all-database zero-residue read. A
    /// missing inventory item alone is never evidence of Desktop absence.
    func verifyNoDesktopResidue(handoff: CodexDesktopCleanupHandoff) async -> Bool
    func observeCleanup(request: CodexGhostRepairBulkInventoryRequest,
                        handoff: CodexDesktopCleanupHandoff) async -> CodexGhostRepairBulkInventoryOutcome

    /// Resolves only a previously published manager-owned Snapshot whose
    /// frozen witness IDs exactly match the current reviewed witnesses. This
    /// lets an explicit preparation intent continue after an App upgrade
    /// without creating a duplicate Snapshot or asking for UUID copy/paste.
    func resumablePublishedSnapshotReference(
        targetThreadIDs: [String]
    ) async throws -> String?

    func observe(
        request: CodexGhostRepairBulkInventoryRequest
    ) async -> CodexGhostRepairBulkInventoryOutcome
}

public extension CodexGhostRepairBulkInventoryCoordinating {
    func observeCleanup(request: CodexGhostRepairBulkInventoryRequest,
                        handoff: CodexDesktopCleanupHandoff) async -> CodexGhostRepairBulkInventoryOutcome {
        await observe(request: request)
    }
    func verifyNoDesktopResidue(handoff: CodexDesktopCleanupHandoff) async -> Bool {
        false
    }

    func resumablePublishedSnapshotReference(
        targetThreadIDs _: [String]
    ) async throws -> String? {
        nil
    }
}

protocol CodexGhostRepairBulkOfficialObservationTransport: Sendable {
    func inventory() async throws
        -> CodexGhostRepairExperimentalTransportInventory
    func exactRead(
        threadID: String
    ) async throws -> CodexGhostRepairExperimentalTransportExactReadOutcome
}

extension CodexGhostRepairExperimentalAppServerObservationAdapter:
    CodexGhostRepairBulkOfficialObservationTransport
{}

actor CodexGhostRepairBulkInventoryCandidateCoordinator:
    CodexGhostRepairBulkInventoryCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkInventoryCapabilities.packagedReadOnlyCandidate

    private let snapshotReader:
        any CodexGhostRepairBulkSnapshotCatalogReading
    private let transport:
        any CodexGhostRepairBulkOfficialObservationTransport
    private let absenceRegistry: CodexGhostRepairExperimentalAbsenceRegistry
    private let versionSpecificRegistry:
        CodexGhostRepairVersionSpecificReadOnlyRegistry
    private let resumeResolver:
        any CodexGhostRepairBulkPublishedSnapshotResumeResolving
    private var activeRequestID: UUID?

    init(
        snapshotReader: any CodexGhostRepairBulkSnapshotCatalogReading,
        transport: any CodexGhostRepairBulkOfficialObservationTransport,
        absenceRegistry: CodexGhostRepairExperimentalAbsenceRegistry,
        versionSpecificRegistry:
            CodexGhostRepairVersionSpecificReadOnlyRegistry = .packagedCurrent(),
        resumeResolver:
            any CodexGhostRepairBulkPublishedSnapshotResumeResolving =
                CodexGhostRepairBulkPublishedSnapshotResumeUnavailable()
    ) {
        self.snapshotReader = snapshotReader
        self.transport = transport
        self.absenceRegistry = absenceRegistry
        self.versionSpecificRegistry = versionSpecificRegistry
        self.resumeResolver = resumeResolver
    }

    func resumablePublishedSnapshotReference(
        targetThreadIDs: [String]
    ) async throws -> String? {
        try await resumeResolver.resolve(
            exactTargetThreadIDs: targetThreadIDs
        )
    }

    func observe(
        request: CodexGhostRepairBulkInventoryRequest
    ) async -> CodexGhostRepairBulkInventoryOutcome {
        guard activeRequestID == nil else {
            return unavailable(request.requestID, stage: .busy)
        }
        activeRequestID = request.requestID
        defer { activeRequestID = nil }

        guard Self.isCanonicalUUID(request.snapshotReference) else {
            return unavailable(request.requestID, stage: .requestValidation)
        }

        let snapshot: CodexGhostRepairBulkInventorySnapshotEvidence
        do {
            snapshot = try await snapshotReader.readBulkCatalog(
                snapshotReference: request.snapshotReference
            )
        } catch {
            return unavailable(request.requestID, stage: .snapshotRead)
        }
        guard snapshot.snapshotReference == request.snapshotReference else {
            return unavailable(request.requestID, stage: .snapshotRead)
        }

        let observed: CodexGhostRepairExperimentalTransportInventory
        do {
            observed = try await transport.inventory()
        } catch {
            return unavailable(request.requestID, stage: .officialInventory)
        }

        let validated: ValidatedOfficialInventory
        do {
            validated = try Self.validateOfficialInventory(observed)
        } catch {
            return unavailable(request.requestID, stage: .officialInventory)
        }

        guard CodexGhostRepairPackagedReadOnlyProfileCatalog.supportsPair(
            runtimeVersion: observed.runtimeVersion,
            sourceLayoutIdentifier: snapshot.sourceLayoutIdentifier,
            databases: snapshot.readback.databases
        ) else {
            return unavailable(request.requestID, stage: .snapshotProfile)
        }

        guard let presentControlID = validated.active
            .union(validated.archived).sorted().first else {
            return unavailable(request.requestID, stage: .presentControl)
        }
        do {
            let control = try await transport.exactRead(
                threadID: presentControlID
            )
            guard case let .present(returnedThreadID) = control,
                  returnedThreadID == presentControlID else {
                return unavailable(request.requestID, stage: .presentControl)
            }
        } catch {
            return unavailable(request.requestID, stage: .presentControl)
        }

        let official = validated.active.union(validated.archived)
        let candidateIDs = snapshot.readback.targets.map(\.threadID)
            .filter { !official.contains($0) }
        var exact: [CodexGhostRepairBulkExactObservation] = []
        exact.reserveCapacity(candidateIDs.count)
        for threadID in candidateIDs {
            let read: CodexGhostRepairExperimentalTransportExactReadOutcome
            do {
                read = try await transport.exactRead(threadID: threadID)
            } catch {
                return unavailable(
                    request.requestID,
                    stage: .candidateExactRead
                )
            }

            let absence: (notLoaded: Bool, rpcCode: Int)
            switch read {
            case let .present(returnedThreadID):
                guard returnedThreadID == threadID else {
                    return unavailable(
                        request.requestID,
                        stage: .candidateExactRead
                    )
                }
                absence = (false, 0)
            case let .failure(
                errorKind,
                rpcCode,
                responseShapeIdentifier,
                message
            ):
                let observation = CodexGhostRepairExperimentalAbsenceObservation(
                    provider: observed.provider,
                    requestedThreadID: threadID,
                    runtimeVersion: observed.runtimeVersion,
                    method: .threadRead,
                    errorKind: errorKind,
                    rpcCode: rpcCode,
                    responseShapeIdentifier: responseShapeIdentifier,
                    message: message,
                    sourceLayoutIdentifier:
                        snapshot.sourceLayoutIdentifier,
                    databases: snapshot.readback.databases
                )
                let legacy = absenceRegistry.evaluate(observation)
                let versionSpecific = versionSpecificRegistry.evaluate(
                    observation,
                    freshPresentControlVerified: true
                )
                if case .matched = legacy {
                    absence = (true, rpcCode)
                } else if case .matched = versionSpecific {
                    absence = (true, rpcCode)
                } else {
                    absence = (false, rpcCode)
                }
            }

            exact.append(.init(
                threadID: threadID,
                exactReadNotLoaded: absence.notLoaded,
                exactReadErrorCode: absence.rpcCode,
                pinned: validated.pinned.contains(threadID),
                descendantCount: validated.descendantCounts[threadID] ?? 0,
                exactReadPresent: {
                    if case .present = read { return true }
                    return false
                }()
            ))
        }

        do {
            let inventory = try CodexGhostRepairBulkInventoryComposer.compose(
                snapshot: snapshot,
                officialInventory: .init(
                    runtimeVersion: observed.runtimeVersion,
                    complete: true,
                    activeThreadIDs: validated.active.sorted(),
                    archivedThreadIDs: validated.archived.sorted()
                ),
                exactObservations: exact
            )
            return .inventory(
                requestID: request.requestID,
                inventory: inventory
            )
        } catch {
            return unavailable(request.requestID, stage: .composition)
        }
    }

    private func unavailable(
        _ requestID: UUID,
        stage: CodexGhostRepairBulkInventoryFailureStage
    ) -> CodexGhostRepairBulkInventoryOutcome {
        .unavailable(
            requestID: requestID,
            failure: .init(stage: stage)
        )
    }

    fileprivate struct ValidatedOfficialInventory {
        let active: Set<String>
        let archived: Set<String>
        let pinned: Set<String>
        let descendantCounts: [String: Int]
    }

    fileprivate static func validateOfficialInventory(
        _ value: CodexGhostRepairExperimentalTransportInventory
    ) throws -> ValidatedOfficialInventory {
        guard value.provider == .codex,
              value.inventoryComplete,
              value.pinnedInventoryComplete,
              value.descendantGraphComplete,
              CodexGhostRepairPackagedReadOnlyProfileCatalog
                .supportsObservationRuntime(
                    value.runtimeVersion
              ) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk official inventory is incomplete."
            )
        }
        let active = try canonicalSet(value.activeThreadIDs)
        let archived = try canonicalSet(value.archivedThreadIDs)
        guard active.isDisjoint(with: archived),
              value.pinnedThreadIDs.count <= 10_000,
              value.pinnedThreadIDs.allSatisfy(isCanonicalUUID) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk official inventory identity evidence is invalid."
            )
        }
        let descendants = try descendantCounts(value.descendantNodes)
        return .init(
            active: active,
            archived: archived,
            pinned: value.pinnedThreadIDs,
            descendantCounts: descendants
        )
    }

    private static func canonicalSet(
        _ values: [String]
    ) throws -> Set<String> {
        guard values.count <= 10_000,
              Set(values).count == values.count,
              values.allSatisfy(isCanonicalUUID) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk official inventory IDs are invalid."
            )
        }
        return Set(values)
    }

    private static func descendantCounts(
        _ nodes: [CodexGhostRepairExperimentalDescendantNode]
    ) throws -> [String: Int] {
        guard nodes.count <= 10_000 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Bulk descendant graph exceeded its bound."
            )
        }
        var seen: Set<String> = []
        var children: [String: [String]] = [:]
        for node in nodes {
            guard isCanonicalUUID(node.threadID),
                  seen.insert(node.threadID).inserted else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Bulk descendant graph identity is invalid."
                )
            }
            if let parent = node.parentThreadID {
                guard isCanonicalUUID(parent), parent != node.threadID else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Bulk descendant graph parent is invalid."
                    )
                }
                children[parent, default: []].append(node.threadID)
            }
        }

        var result: [String: Int] = [:]
        let roots = seen.union(children.keys)
        for root in roots {
            var visited: Set<String> = [root]
            var queue = children[root] ?? []
            var index = 0
            while index < queue.count {
                let child = queue[index]
                index += 1
                guard visited.insert(child).inserted else {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Bulk descendant graph contains a cycle."
                    )
                }
                queue.append(contentsOf: children[child] ?? [])
            }
            result[root] = visited.count - 1
        }
        return result
    }

    fileprivate static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

protocol CodexGhostRepairBulkLiveCatalogReading: Sendable {
    func readExactCleanupScope(
        profile: CodexGhostRepairSnapshotSourceProfile,
        targetThreadIDs: [String]
    ) throws -> CodexGhostRepairBulkCatalogQueryReadback

    func read(
        profile: CodexGhostRepairSnapshotSourceProfile
    ) throws -> CodexGhostRepairBulkCatalogQueryReadback
}

extension CodexGhostRepairBulkLiveCatalogReading {
    func readExactCleanupScope(
        profile: CodexGhostRepairSnapshotSourceProfile,
        targetThreadIDs: [String]
    ) throws -> CodexGhostRepairBulkCatalogQueryReadback {
        throw SessionManagerError.unsupportedOperation("Exact Desktop absence read unavailable.")
    }
}

struct CodexGhostRepairBulkLiveCatalogReader:
    CodexGhostRepairBulkLiveCatalogReading,
    Sendable
{
    private let workspaceFactory:
        CodexGhostRepairSnapshotAnalysisWorkspaceFactory

    static func production() -> Self {
        Self(workspaceFactory: .production())
    }

    init(workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory) {
        self.workspaceFactory = workspaceFactory
    }

    func readExactCleanupScope(
        profile: CodexGhostRepairSnapshotSourceProfile,
        targetThreadIDs: [String]
    ) throws -> CodexGhostRepairBulkCatalogQueryReadback {
        try CodexGhostRepairBulkCanonicalQueryOnlyReader.readExactCleanupScope(
            source: .production(profile: profile),
            targetThreadIDs: targetThreadIDs,
            workspaceFactory: workspaceFactory
        )
    }

    func read(
        profile: CodexGhostRepairSnapshotSourceProfile
    ) throws -> CodexGhostRepairBulkCatalogQueryReadback {
        try CodexGhostRepairBulkCanonicalQueryOnlyReader.read(
            source: .production(profile: profile),
            workspaceFactory: workspaceFactory
        )
    }
}

/// Shipping Ghost detection follows the validated Desktop cleanup sequence:
/// one fresh local canonical read plus one exact App Server read for every
/// locally absent candidate. A generated scan UUID names the in-memory frozen
/// evidence; no published Snapshot is required or accepted.
actor CodexGhostRepairBulkLiveScanCoordinator:
    CodexGhostRepairBulkInventoryCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkInventoryCapabilities.packagedLiveScan

    private let liveReader: any CodexGhostRepairBulkLiveCatalogReading
    private let transport:
        any CodexGhostRepairBulkOfficialObservationTransport
    private let absenceRegistry: CodexGhostRepairExperimentalAbsenceRegistry
    private let versionSpecificRegistry:
        CodexGhostRepairVersionSpecificReadOnlyRegistry
    private var activeRequestID: UUID?

    func observeCleanup(request: CodexGhostRepairBulkInventoryRequest,
                        handoff: CodexDesktopCleanupHandoff) async -> CodexGhostRepairBulkInventoryOutcome {
        do { try handoff.validate() } catch {
            return unavailable(request.requestID, stage: .requestValidation)
        }
        return await observe(request: request, cleanupHandoff: handoff)
    }

    func verifyNoDesktopResidue(handoff: CodexDesktopCleanupHandoff) async -> Bool {
        guard activeRequestID == nil else { return false }
        activeRequestID = UUID()
        defer { activeRequestID = nil }
        do {
            try handoff.validate()
            let observed = try await transport.inventory()
            let validated = try CodexGhostRepairBulkInventoryCandidateCoordinator
                .validateOfficialInventory(observed)
            guard validated.active.union(validated.archived)
                    .isDisjoint(with: handoff.nativeSessionIDs),
                  let profile = CodexGhostRepairSnapshotRequestBoundProfileSelection
                    .selectProfile(exactRuntimeVersion: observed.runtimeVersion) else {
                return false
            }
            let readback = try liveReader.readExactCleanupScope(
                profile: profile,
                targetThreadIDs: handoff.nativeSessionIDs
            )
            return profile.admits(databases: readback.databases)
                && CodexGhostRepairPackagedReadOnlyProfileCatalog.supportsPair(
                    runtimeVersion: observed.runtimeVersion,
                    sourceLayoutIdentifier: profile.identifier,
                    databases: readback.databases
                )
                && Self.isSHA256(readback.sourceFingerprintHash)
                && readback.targets.map(\.threadID).sorted() == handoff.nativeSessionIDs
                && readback.targets.allSatisfy {
                    $0.catalogRowDigests.isEmpty
                        && $0.automationRunRowDigests.isEmpty
                        && $0.automationStableFieldsDigests.isEmpty
                        && $0.automationDefinitionRowDigests.isEmpty
                        && $0.references.total == 0
                }
        } catch {
            return false
        }
    }

    init(
        liveReader: any CodexGhostRepairBulkLiveCatalogReading,
        transport: any CodexGhostRepairBulkOfficialObservationTransport,
        absenceRegistry: CodexGhostRepairExperimentalAbsenceRegistry,
        versionSpecificRegistry:
            CodexGhostRepairVersionSpecificReadOnlyRegistry = .packagedCurrent()
    ) {
        self.liveReader = liveReader
        self.transport = transport
        self.absenceRegistry = absenceRegistry
        self.versionSpecificRegistry = versionSpecificRegistry
    }

    func observe(
        request: CodexGhostRepairBulkInventoryRequest
    ) async -> CodexGhostRepairBulkInventoryOutcome {
        await observe(request: request, cleanupHandoff: nil)
    }

    private func observe(
        request: CodexGhostRepairBulkInventoryRequest,
        cleanupHandoff: CodexDesktopCleanupHandoff?
    ) async -> CodexGhostRepairBulkInventoryOutcome {
        guard activeRequestID == nil else {
            return unavailable(request.requestID, stage: .busy)
        }
        activeRequestID = request.requestID
        defer { activeRequestID = nil }

        guard Self.isCanonicalUUID(request.snapshotReference) else {
            return unavailable(request.requestID, stage: .requestValidation)
        }

        let observed: CodexGhostRepairExperimentalTransportInventory
        do {
            observed = try await transport.inventory()
        } catch {
            return unavailable(request.requestID, stage: .officialInventory)
        }

        let validated:
            CodexGhostRepairBulkInventoryCandidateCoordinator
                .ValidatedOfficialInventory
        let profile: CodexGhostRepairSnapshotSourceProfile
        do {
            validated = try CodexGhostRepairBulkInventoryCandidateCoordinator
                .validateOfficialInventory(observed)
            guard let selected =
                CodexGhostRepairSnapshotRequestBoundProfileSelection
                    .selectProfile(
                        exactRuntimeVersion: observed.runtimeVersion
                    )
            else {
                return unavailable(request.requestID, stage: .snapshotProfile)
            }
            profile = selected
        } catch {
            return unavailable(request.requestID, stage: .officialInventory)
        }

        let live: CodexGhostRepairBulkCatalogQueryReadback
        do {
            if let cleanupHandoff {
                live = try liveReader.readExactCleanupScope(
                    profile: profile, targetThreadIDs: cleanupHandoff.nativeSessionIDs
                )
                guard live.targets.map(\.threadID).sorted() == cleanupHandoff.nativeSessionIDs else {
                    return unavailable(request.requestID, stage: .canonicalSourceRead)
                }
            } else {
                live = try liveReader.read(profile: profile)
            }
        } catch {
            return unavailable(request.requestID, stage: .canonicalSourceRead)
        }
        guard profile.admits(databases: live.databases),
              CodexGhostRepairPackagedReadOnlyProfileCatalog.supportsPair(
                runtimeVersion: observed.runtimeVersion,
                sourceLayoutIdentifier: profile.identifier,
                databases: live.databases
              ),
              Self.isSHA256(live.sourceFingerprintHash) else {
            return unavailable(request.requestID, stage: .snapshotProfile)
        }

        guard let presentControlID = validated.active
            .union(validated.archived).sorted().first else {
            return unavailable(request.requestID, stage: .presentControl)
        }
        do {
            let control = try await transport.exactRead(
                threadID: presentControlID
            )
            guard case let .present(returnedThreadID) = control,
                  returnedThreadID == presentControlID else {
                return unavailable(request.requestID, stage: .presentControl)
            }
        } catch {
            return unavailable(request.requestID, stage: .presentControl)
        }

        let official = validated.active.union(validated.archived)
        let candidateIDs = live.targets.compactMap { target in
            !official.contains(target.threadID)
                && target.references.canonicalState == 0
                ? target.threadID : nil
        }
        var exact: [CodexGhostRepairBulkExactObservation] = []
        exact.reserveCapacity(candidateIDs.count)
        for threadID in candidateIDs {
            let read: CodexGhostRepairExperimentalTransportExactReadOutcome
            do {
                read = try await transport.exactRead(threadID: threadID)
            } catch {
                return unavailable(
                    request.requestID,
                    stage: .candidateExactRead
                )
            }

            let absence: (notLoaded: Bool, rpcCode: Int)
            switch read {
            case let .present(returnedThreadID):
                guard returnedThreadID == threadID else {
                    return unavailable(
                        request.requestID,
                        stage: .candidateExactRead
                    )
                }
                absence = (false, 0)
            case let .failure(
                errorKind,
                rpcCode,
                responseShapeIdentifier,
                message
            ):
                let observation = CodexGhostRepairExperimentalAbsenceObservation(
                    provider: observed.provider,
                    requestedThreadID: threadID,
                    runtimeVersion: observed.runtimeVersion,
                    method: .threadRead,
                    errorKind: errorKind,
                    rpcCode: rpcCode,
                    responseShapeIdentifier: responseShapeIdentifier,
                    message: message,
                    sourceLayoutIdentifier: profile.identifier,
                    databases: live.databases
                )
                let legacy = absenceRegistry.evaluate(observation)
                let versionSpecific = versionSpecificRegistry.evaluate(
                    observation,
                    freshPresentControlVerified: true
                )
                if case .matched = legacy {
                    absence = (true, rpcCode)
                } else if case .matched = versionSpecific {
                    absence = (true, rpcCode)
                } else {
                    absence = (false, rpcCode)
                }
            }

            exact.append(.init(
                threadID: threadID,
                exactReadNotLoaded: absence.notLoaded,
                exactReadErrorCode: absence.rpcCode,
                pinned: validated.pinned.contains(threadID),
                descendantCount: validated.descendantCounts[threadID] ?? 0,
                exactReadPresent: {
                    if case .present = read { return true }
                    return false
                }()
            ))
        }

        do {
            let manifestHash = try CodexGhostRepairHasher.hash(
                LiveScanManifest(
                    scanReference: request.snapshotReference,
                    runtimeVersion: observed.runtimeVersion,
                    sourceLayoutIdentifier: profile.identifier,
                    sourceFingerprintHash: live.sourceFingerprintHash,
                    databases: live.databases,
                    targets: live.targets,
                    authority: live.authority
                )
            )
            let inventory = try CodexGhostRepairBulkInventoryComposer.compose(
                snapshot: .init(
                    snapshotReference: request.snapshotReference,
                    sourceLayoutIdentifier: profile.identifier,
                    sourceFingerprintHash: live.sourceFingerprintHash,
                    manifestHash: manifestHash,
                    readback: live
                ),
                officialInventory: .init(
                    runtimeVersion: observed.runtimeVersion,
                    complete: true,
                    activeThreadIDs: validated.active.sorted(),
                    archivedThreadIDs: validated.archived.sorted()
                ),
                exactObservations: exact
            )
            return .inventory(
                requestID: request.requestID,
                inventory: inventory
            )
        } catch {
            return unavailable(request.requestID, stage: .composition)
        }
    }

    private func unavailable(
        _ requestID: UUID,
        stage: CodexGhostRepairBulkInventoryFailureStage
    ) -> CodexGhostRepairBulkInventoryOutcome {
        .unavailable(
            requestID: requestID,
            failure: .init(stage: stage)
        )
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }

    private struct LiveScanManifest: Encodable {
        let scanReference: String
        let runtimeVersion: String
        let sourceLayoutIdentifier: String
        let sourceFingerprintHash: String
        let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
        let targets: [CodexGhostRepairSnapshotAnalysisTargetEvidence]
        let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    }
}

private struct CodexGhostRepairBulkInventoryUnavailableCoordinator:
    CodexGhostRepairBulkInventoryCoordinating
{
    let capabilities = CodexGhostRepairBulkInventoryCapabilities.unavailable

    func observe(
        request: CodexGhostRepairBulkInventoryRequest
    ) async -> CodexGhostRepairBulkInventoryOutcome {
        .unavailable(
            requestID: request.requestID,
            failure: .init(stage: .unavailable)
        )
    }
}

public enum CodexGhostRepairBulkInventoryCoordinatorFactory {
    public static func packagedDefaultUnavailable()
        -> any CodexGhostRepairBulkInventoryCoordinating
    {
        CodexGhostRepairBulkInventoryUnavailableCoordinator()
    }

    /// Constructs the packaged, authority-free coordinator without performing
    /// any observation. I/O begins only when the caller explicitly invokes
    /// `observe(request:)` with one exact published snapshot UUID.
    public static func packagedExplicitReadOnly()
        -> any CodexGhostRepairBulkInventoryCoordinating
    {
        CodexGhostRepairBulkInventoryInternalFactory
            .packagedLiveScan()
    }
}

enum CodexGhostRepairBulkInventoryInternalFactory {
    static func packagedLiveScan(
        configuration: CodexAppServerConfiguration = .init()
    ) -> any CodexGhostRepairBulkInventoryCoordinating {
        CodexGhostRepairBulkLiveScanCoordinator(
            liveReader: CodexGhostRepairBulkLiveCatalogReader.production(),
            transport: CodexGhostRepairExperimentalAppServerObservationAdapter(
                source: CodexAppServerClient.ghostRepairProduction(configuration: configuration),
                executionGateSource:
                    CodexGhostRepairUnavailableExecutionGateSource()
            ),
            absenceRegistry: .packagedReviewedV1(),
            versionSpecificRegistry: .packagedCurrent()
        )
    }

    static func packagedReadOnlyCandidate(
        configuration: CodexAppServerConfiguration = .init()
    ) -> any CodexGhostRepairBulkInventoryCoordinating {
        let snapshotReader =
            CodexGhostRepairSnapshotPackagedAnalysisReader.production()
        return CodexGhostRepairBulkInventoryCandidateCoordinator(
            snapshotReader: snapshotReader,
            transport: CodexGhostRepairExperimentalAppServerObservationAdapter(
                source: CodexAppServerClient.ghostRepairProduction(configuration: configuration),
                executionGateSource:
                    CodexGhostRepairUnavailableExecutionGateSource()
            ),
            absenceRegistry: .packagedReviewedV1(),
            versionSpecificRegistry: .packagedCurrent(),
            resumeResolver:
                CodexGhostRepairBulkPublishedSnapshotResumeResolver.production(
                    snapshotReader: snapshotReader
                )
        )
    }
}

protocol CodexGhostRepairBulkPublishedSnapshotResumeResolving: Sendable {
    func resolve(
        exactTargetThreadIDs: [String]
    ) async throws -> String?
}

struct CodexGhostRepairBulkPublishedSnapshotResumeUnavailable:
    CodexGhostRepairBulkPublishedSnapshotResumeResolving
{
    func resolve(
        exactTargetThreadIDs _: [String]
    ) async throws -> String? {
        nil
    }
}

struct CodexGhostRepairBulkPublishedSnapshotResumeResolver:
    CodexGhostRepairBulkPublishedSnapshotResumeResolving,
    Sendable
{
    private let reader: any CodexGhostRepairSnapshotRecoveryInventoryReading
    private let snapshotReader:
        any CodexGhostRepairBulkSnapshotCatalogReading
    private let requiredSourceLayoutIdentifier: String

    static func production(
        snapshotReader: any CodexGhostRepairBulkSnapshotCatalogReading
    ) -> Self {
        Self(
            reader: CodexGhostRepairSnapshotRecoveryReader.production(),
            snapshotReader: snapshotReader,
            requiredSourceLayoutIdentifier:
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v1534SourceLayoutIdentifier
        )
    }

    init(
        reader: any CodexGhostRepairSnapshotRecoveryInventoryReading,
        snapshotReader: any CodexGhostRepairBulkSnapshotCatalogReading,
        requiredSourceLayoutIdentifier: String =
            CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v1534SourceLayoutIdentifier
    ) {
        self.reader = reader
        self.snapshotReader = snapshotReader
        self.requiredSourceLayoutIdentifier = requiredSourceLayoutIdentifier
    }

    func resolve(
        exactTargetThreadIDs: [String]
    ) async throws -> String? {
        guard (1...10).contains(exactTargetThreadIDs.count),
              exactTargetThreadIDs == exactTargetThreadIDs.sorted(),
              Set(exactTargetThreadIDs).count == exactTargetThreadIDs.count,
              exactTargetThreadIDs.allSatisfy(Self.isCanonicalUUID) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Snapshot resume requires exact bounded witness IDs."
            )
        }
        let inventory = try await reader.readbackInventory()
        let matches = inventory.snapshots.filter {
            $0.state == .published
                && $0.targetThreadIDs == exactTargetThreadIDs
                && $0.publishedEvidence != nil
        }
        let newestFirst = matches.sorted { lhs, rhs in
            let lhsPublished = lhs.publishedEvidence?.publishedAtMilliseconds
                ?? -1
            let rhsPublished = rhs.publishedEvidence?.publishedAtMilliseconds
                ?? -1
            if lhsPublished != rhsPublished {
                return lhsPublished > rhsPublished
            }
            return lhs.snapshotID.uuidString > rhs.snapshotID.uuidString
        }

        for candidate in newestFirst {
            let reference = candidate.snapshotID.uuidString.lowercased()
            guard let published = candidate.publishedEvidence,
                  let snapshot = try? await snapshotReader.readBulkCatalog(
                    snapshotReference: reference
                  ),
                  snapshot.snapshotReference == reference,
                  snapshot.sourceLayoutIdentifier
                    == requiredSourceLayoutIdentifier,
                  snapshot.sourceFingerprintHash
                    == candidate.sourceFingerprintHash,
                  snapshot.manifestHash == published.manifestHash,
                  snapshot.readback.targets.map(\.threadID)
                    == exactTargetThreadIDs,
                  CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .supportsSource(
                        sourceLayoutIdentifier:
                            snapshot.sourceLayoutIdentifier,
                        databases: snapshot.readback.databases
                    ) else {
                continue
            }
            return reference
        }
        return nil
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}
