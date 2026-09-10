import Foundation

public enum CodexGhostRepairExperimentalCompatibilityFailureStage:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case requestValidation = "request-validation"
    case snapshotIdentity = "snapshot-identity"
    case snapshotReadback = "snapshot-readback"
    case appServerInventory = "app-server-inventory"
    case inventoryValidation = "inventory-validation"
    case presentControlRead = "present-control-read"
    case targetExactRead = "target-exact-read"
    case operationalAudit = "operational-audit"
    case resultIdentity = "result-identity"
    case evidenceValidation = "evidence-validation"
}

public enum CodexGhostRepairExperimentalCompatibilityFailureReason:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case invalidRequest = "invalid-request"
    case snapshotIdentityUnavailable = "snapshot-identity-unavailable"
    case snapshotReadUnavailable = "snapshot-read-unavailable"
    case inventoryReadFailed = "inventory-read-failed"
    case inventoryIncomplete = "inventory-incomplete"
    case inventoryInvalid = "inventory-invalid"
    case noPresentControl = "no-present-control"
    case presentControlReadFailed = "present-control-read-failed"
    case presentControlMismatch = "present-control-mismatch"
    case targetReadFailed = "target-read-failed"
    case targetUnexpectedlyPresent = "target-unexpectedly-present"
    case operationalAuditFailed = "operational-audit-failed"
    case observationIdentityMismatch = "observation-identity-mismatch"
    case evidenceInvalid = "evidence-invalid"
    case observationUnavailable = "observation-unavailable"
}

public struct CodexGhostRepairExperimentalCompatibilityFailure:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let stage: CodexGhostRepairExperimentalCompatibilityFailureStage
    public let reason: CodexGhostRepairExperimentalCompatibilityFailureReason
    public let snapshotReadReason:
        CodexGhostRepairSnapshotAnalysisFailureReason?

    public init(
        stage: CodexGhostRepairExperimentalCompatibilityFailureStage,
        reason: CodexGhostRepairExperimentalCompatibilityFailureReason,
        snapshotReadReason:
            CodexGhostRepairSnapshotAnalysisFailureReason? = nil
    ) {
        self.stage = stage
        self.reason = reason
        self.snapshotReadReason = snapshotReadReason
    }

    public var pathRedacted: Bool { true }
    public var rawErrorIncluded: Bool { false }
    public var previewCreated: Bool { false }
    public var previewPersisted: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
    public var automaticRetry: Bool { false }
}

public struct CodexGhostRepairExperimentalCompatibilityEvidence:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let requestID: UUID
    public let snapshotIdentity: CodexGhostRepairSnapshotAnalysisIdentity
    public let provider: AgentSystem
    public let runtimeVersion: String
    public let method: CodexGhostRepairExperimentalAbsenceMethod
    public let errorKind: CodexGhostRepairExperimentalAbsenceErrorKind
    public let rpcCode: Int
    public let responseShapeIdentifier: String
    public let exactMessageTemplate: String
    public let sourceLayoutIdentifier: String
    public let databases: [CodexGhostRepairExperimentalDatabaseContract]
    public let presentControlThreadIDHash: String
    public let targetThreadIDs: [String]
    public let operationalAudit: CodexGhostRepairExecutionGate
    public let canonicalEvidenceHash: String

    public var pathRedacted: Bool { true }
    public var previewCreated: Bool { false }
    public var previewPersisted: Bool { false }
    public var officialGuarantee: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

enum CodexGhostRepairExperimentalCompatibilityEvidenceBuilder {
    static func build(
        requestID: UUID,
        identity: CodexGhostRepairSnapshotAnalysisIdentity,
        snapshotEvidence: CodexGhostRepairSnapshotAnalysisReadback,
        observation: CodexGhostRepairExperimentalProtectionObservation
    ) throws -> CodexGhostRepairExperimentalCompatibilityEvidence {
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
        let active = try exactIDSet(observation.activeThreadIDs)
        let archived = try exactIDSet(observation.archivedThreadIDs)
        guard active.isDisjoint(with: archived),
              active.isDisjoint(with: targets),
              archived.isDisjoint(with: targets),
              observation.pinnedThreadIDs.allSatisfy(isCanonicalUUID),
              isCanonicalUUID(observation.presentControlThreadID),
              observation.presentControlReturnedThreadID
                == observation.presentControlThreadID,
              !targets.contains(observation.presentControlThreadID),
              active.contains(observation.presentControlThreadID)
                || archived.contains(observation.presentControlThreadID),
              snapshotEvidence.databases.map(\.database)
                == CodexGhostRepairSnapshotAnalysisDatabase.allCases,
              snapshotEvidence.databases.allSatisfy({
                  $0.integrityCheckPassed
                    && $0.foreignKeyViolationCount == 0
              }) else {
            throw invalidEvidence()
        }

        let descendants = try canonicalDescendants(
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

        var canonicalFailures: [CanonicalFailure] = []
        var commonTemplate: String?
        for target in targets {
            guard let failure = failuresByID[target],
                  failure.provider == observation.provider,
                  failure.runtimeVersion == observation.runtimeVersion,
                  failure.method == .threadRead,
                  failure.errorKind == .rpcError,
                  failure.rpcCode == -32600,
                  failure.responseShapeIdentifier
                    == "rpc-error-code-message-v1" else {
                throw invalidEvidence()
            }
            let template = try exactTemplate(
                message: failure.message,
                threadID: target
            )
            if let commonTemplate, commonTemplate != template {
                throw invalidEvidence()
            }
            commonTemplate = template
            canonicalFailures.append(.init(
                threadID: target,
                method: failure.method,
                errorKind: failure.errorKind,
                rpcCode: failure.rpcCode,
                responseShapeIdentifier: failure.responseShapeIdentifier,
                exactMessageTemplate: template
            ))
        }
        guard let exactMessageTemplate = commonTemplate else {
            throw invalidEvidence()
        }

        let databases = snapshotEvidence.databases.map {
            CodexGhostRepairExperimentalDatabaseContract(
                database: $0.database,
                schemaVersion: $0.schemaVersion
            )
        }
        let canonical = CanonicalEvidence(
            requestID: requestID,
            snapshotIdentity: identity,
            provider: observation.provider,
            runtimeVersion: observation.runtimeVersion,
            presentControlThreadID: observation.presentControlThreadID,
            activeThreadIDs: active.sorted(),
            archivedThreadIDs: archived.sorted(),
            pinnedThreadIDs: observation.pinnedThreadIDs.sorted(),
            descendants: descendants,
            failures: canonicalFailures,
            sourceLayoutIdentifier: snapshotEvidence.sourceLayoutIdentifier,
            databases: snapshotEvidence.databases,
            operationalAudit: observation.operationalAudit
        )
        let evidenceHash = try CodexGhostRepairHasher.hash(canonical)
        let presentControlThreadIDHash = try CodexGhostRepairHasher.hash(
            observation.presentControlThreadID
        )
        return .init(
            requestID: requestID,
            snapshotIdentity: identity,
            provider: observation.provider,
            runtimeVersion: observation.runtimeVersion,
            method: .threadRead,
            errorKind: .rpcError,
            rpcCode: -32600,
            responseShapeIdentifier: "rpc-error-code-message-v1",
            exactMessageTemplate: exactMessageTemplate,
            sourceLayoutIdentifier: snapshotEvidence.sourceLayoutIdentifier,
            databases: databases,
            presentControlThreadIDHash: presentControlThreadIDHash,
            targetThreadIDs: targets,
            operationalAudit: observation.operationalAudit,
            canonicalEvidenceHash: evidenceHash
        )
    }

    private struct CanonicalEvidence: Encodable {
        let requestID: UUID
        let snapshotIdentity: CodexGhostRepairSnapshotAnalysisIdentity
        let provider: AgentSystem
        let runtimeVersion: String
        let presentControlThreadID: String
        let activeThreadIDs: [String]
        let archivedThreadIDs: [String]
        let pinnedThreadIDs: [String]
        let descendants: [CanonicalDescendant]
        let failures: [CanonicalFailure]
        let sourceLayoutIdentifier: String
        let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
        let operationalAudit: CodexGhostRepairExecutionGate
    }

    private struct CanonicalFailure: Encodable {
        let threadID: String
        let method: CodexGhostRepairExperimentalAbsenceMethod
        let errorKind: CodexGhostRepairExperimentalAbsenceErrorKind
        let rpcCode: Int
        let responseShapeIdentifier: String
        let exactMessageTemplate: String
    }

    private struct CanonicalDescendant: Encodable, Comparable {
        let threadID: String
        let parentThreadID: String?

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.threadID != rhs.threadID {
                return lhs.threadID < rhs.threadID
            }
            return (lhs.parentThreadID ?? "") < (rhs.parentThreadID ?? "")
        }
    }

    private static func exactTemplate(
        message: String,
        threadID: String
    ) throws -> String {
        guard message.components(separatedBy: threadID).count == 2 else {
            throw invalidEvidence()
        }
        let value = message.replacingOccurrences(
            of: threadID,
            with: "{thread_id}"
        )
        guard !value.contains("\n"),
              !value.contains("\r"),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw invalidEvidence()
        }
        return value
    }

    private static func exactIDSet(_ values: [String]) throws -> Set<String> {
        guard Set(values).count == values.count,
              values.allSatisfy(isCanonicalUUID) else {
            throw invalidEvidence()
        }
        return Set(values)
    }

    private static func canonicalDescendants(
        _ values: [CodexGhostRepairExperimentalDescendantNode]
    ) throws -> [CanonicalDescendant] {
        var seen: Set<String> = []
        var result: [CanonicalDescendant] = []
        for value in values {
            guard isCanonicalUUID(value.threadID),
                  seen.insert(value.threadID).inserted,
                  value.parentThreadID.map(isCanonicalUUID) ?? true,
                  value.parentThreadID != value.threadID else {
                throw invalidEvidence()
            }
            result.append(.init(
                threadID: value.threadID,
                parentThreadID: value.parentThreadID
            ))
        }
        return result.sorted()
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func invalidEvidence() -> CodexGhostRepairError {
        .invalidProtectionEvidence(
            "Experimental compatibility evidence is incomplete or drifted."
        )
    }
}

actor CodexGhostRepairExperimentalCompatibilityReviewCoordinator:
    CodexGhostRepairSnapshotDryRunAnalysisCoordinating
{
    nonisolated let capabilities:
        CodexGhostRepairSnapshotDryRunAnalysisCapabilities

    private let identityCoordinator:
        any CodexGhostRepairSnapshotAnalysisIdentityCoordinator
    private let reader: any CodexGhostRepairSnapshotAnalysisReading
    private let observer:
        any CodexGhostRepairExperimentalObservationCoordinating
    private let registry: CodexGhostRepairExperimentalAbsenceRegistry?
    private let previewPersister:
        (any CodexGhostRepairSnapshotDryRunPreviewPersisting)?

    init(
        identityCoordinator:
            any CodexGhostRepairSnapshotAnalysisIdentityCoordinator,
        reader: any CodexGhostRepairSnapshotAnalysisReading,
        observer: any CodexGhostRepairExperimentalObservationCoordinating,
        registry: CodexGhostRepairExperimentalAbsenceRegistry? = nil,
        previewPersister:
            (any CodexGhostRepairSnapshotDryRunPreviewPersisting)? = nil
    ) {
        let admitted = registry?.isEmpty == false
            && previewPersister != nil
        capabilities = admitted
            ? .packagedAdmittedPreview
            : .packagedCompatibilityReview
        self.identityCoordinator = identityCoordinator
        self.reader = reader
        self.observer = observer
        self.registry = admitted ? registry : nil
        self.previewPersister = admitted ? previewPersister : nil
    }

    func analyze(
        request: CodexGhostRepairSnapshotDryRunAnalysisRequest
    ) async -> CodexGhostRepairSnapshotDryRunAnalysisOutcome {
        let identityOutcome = await identityCoordinator.resolve(
            request: .init(snapshotReference: request.snapshotReference)
        )
        guard case let .resolved(identity) = identityOutcome else {
            return unavailable(
                request.requestID,
                stage: .snapshotIdentity,
                reason: .snapshotIdentityUnavailable
            )
        }
        let readOutcome = await reader.read(identity: identity)
        guard case let .read(snapshotEvidence) = readOutcome else {
            guard case let .unavailable(snapshotReadReason) = readOutcome else {
                return unavailable(
                    request.requestID,
                    stage: .snapshotReadback,
                    reason: .snapshotReadUnavailable
                )
            }
            return unavailable(
                request.requestID,
                stage: .snapshotReadback,
                reason: .snapshotReadUnavailable,
                snapshotReadReason: snapshotReadReason
            )
        }
        let observed = await observer.observe(request: .init(
            requestID: request.requestID,
            identity: identity
        ))
        guard case let .observed(result) = observed else {
            guard case let .unavailable(observedRequestID, failure) = observed,
                  observedRequestID == request.requestID else {
                return unavailable(
                    request.requestID,
                    stage: .resultIdentity,
                    reason: .observationIdentityMismatch
                )
            }
            return .compatibilityUnavailable(
                requestID: request.requestID,
                failure: failure
            )
        }
        guard result.requestID == request.requestID,
              result.identity == identity else {
            return unavailable(
                request.requestID,
                stage: .resultIdentity,
                reason: .observationIdentityMismatch
            )
        }
        do {
            let evidence = try CodexGhostRepairExperimentalCompatibilityEvidenceBuilder
                .build(
                    requestID: request.requestID,
                    identity: identity,
                    snapshotEvidence: snapshotEvidence,
                    observation: result.observation
                )
            guard let registry, let previewPersister else {
                return .compatibilityReview(
                    requestID: request.requestID,
                    evidence: evidence
                )
            }
            let audit: CodexGhostRepairSnapshotDryRunProtectionAudit
            do {
                audit = try CodexGhostRepairExperimentalProtectionCollector
                    .collect(
                        identity: identity,
                        snapshotEvidence: snapshotEvidence,
                        registry: registry,
                        observation: result.observation
                    )
            } catch {
                // Structurally valid evidence that does not match the exact
                // reviewed admission remains review-only. It never falls back
                // to an approximate contract or an older Preview.
                return .compatibilityReview(
                    requestID: request.requestID,
                    evidence: evidence
                )
            }
            switch CodexGhostRepairSnapshotDryRunPlanner.plan(
                identity: identity,
                snapshotEvidence: snapshotEvidence,
                protectionEvidence: audit.protectionEvidence,
                experimentalAbsenceEvidence:
                    audit.experimentalAbsenceEvidence,
                operationalAudit: audit.operationalAudit,
                previewID: request.previewID,
                generatedAtMilliseconds: request.generatedAtMilliseconds,
                lifetimeMilliseconds: request.lifetimeMilliseconds
            ) {
            case let .blocked(blockers):
                return .blocked(
                    requestID: request.requestID,
                    blockers: blockers
                )
            case let .preview(preview):
                let receipt: CodexGhostRepairSnapshotDryRunPersistenceReceipt
                do {
                    receipt = try await previewPersister.persist(
                        requestID: request.requestID,
                        preview: preview
                    )
                } catch {
                    return persistenceUnavailable(
                        request: request,
                        reason: .writeOrReadbackFailed
                    )
                }
                guard receipt.requestID == request.requestID,
                      receipt.previewID == preview.previewID,
                      receipt.durableReadbackMatched,
                      receipt.payloadHash.hasPrefix("sha256:"),
                      receipt.payloadHash.count == 71,
                      !receipt.confirmationAuthority,
                      !receipt.repairMutationAuthority else {
                    return persistenceUnavailable(
                        request: request,
                        reason: .receiptIdentityMismatch
                    )
                }
                return .persistedPreview(
                    requestID: request.requestID,
                    preview: preview,
                    receipt: receipt
                )
            }
        } catch {
            return unavailable(
                request.requestID,
                stage: .evidenceValidation,
                reason: .evidenceInvalid
            )
        }
    }

    private func persistenceUnavailable(
        request: CodexGhostRepairSnapshotDryRunAnalysisRequest,
        reason: CodexGhostRepairSnapshotDryRunPersistenceFailureReason
    ) -> CodexGhostRepairSnapshotDryRunAnalysisOutcome {
        .persistenceUnavailable(
            requestID: request.requestID,
            failure: .init(
                snapshotReference: request.snapshotReference,
                reason: reason
            )
        )
    }

    private func unavailable(
        _ requestID: UUID,
        stage: CodexGhostRepairExperimentalCompatibilityFailureStage,
        reason: CodexGhostRepairExperimentalCompatibilityFailureReason,
        snapshotReadReason:
            CodexGhostRepairSnapshotAnalysisFailureReason? = nil
    ) -> CodexGhostRepairSnapshotDryRunAnalysisOutcome {
        .compatibilityUnavailable(
            requestID: requestID,
            failure: .init(
                stage: stage,
                reason: reason,
                snapshotReadReason: snapshotReadReason
            )
        )
    }
}

struct CodexGhostRepairExperimentalReadOnlyAppServerSource:
    CodexInventorySource,
    Sendable
{
    private let source: any CodexInventorySource

    init(configuration: CodexAppServerConfiguration) {
        source = CodexAppServerClient.ghostRepairProduction(configuration: configuration)
    }

    func inventory() async throws -> CodexInventorySnapshot {
        try await source.inventory()
    }

    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot {
        try await source.exactRead(threadID: threadID)
    }
}

public extension CodexGhostRepairSnapshotDryRunAnalysisCoordinatorFactory {
    /// Construction is zero-I/O. Only the existing explicit M2l button can
    /// trigger fixed snapshot reads and read-only App Server observation.
    /// The empty shipping admission registry is intentionally not consulted:
    /// this M2n coordinator can return compatibility evidence, never a Preview.
    static func packagedCompatibilityReview(
        executionGateSource: any CodexGhostRepairExecutionGateSource,
        appServerConfiguration: CodexAppServerConfiguration = .init()
    ) -> any CodexGhostRepairSnapshotDryRunAnalysisCoordinating {
        let transport = CodexGhostRepairExperimentalAppServerObservationAdapter(
            source: CodexGhostRepairExperimentalReadOnlyAppServerSource(
                configuration: appServerConfiguration
            ),
            executionGateSource: executionGateSource
        )
        return CodexGhostRepairExperimentalCompatibilityReviewCoordinator(
            identityCoordinator:
                CodexGhostRepairSnapshotAnalysisIdentityCoordinatorFactory
                    .packagedReadOnly(),
            reader: CodexGhostRepairSnapshotAnalysisReaderFactory
                .packagedReadOnly(),
            observer:
                CodexGhostRepairExperimentalObservationCandidateCoordinator(
                    transport: transport
                )
        )
    }

    /// Construction is zero-I/O. The reviewed registry embeds only exact
    /// version/schema contracts and path-free canary hashes. The manager-owned
    /// state store is opened only after planning succeeds, and the UI receives
    /// a Preview only after exact durable readback.
    static func packagedAdmittedPreview(
        executionGateSource: any CodexGhostRepairExecutionGateSource,
        appServerConfiguration: CodexAppServerConfiguration = .init()
    ) -> any CodexGhostRepairSnapshotDryRunAnalysisCoordinating {
        let registry = CodexGhostRepairExperimentalAbsenceRegistry
            .packagedReviewedV1()
        guard !registry.isEmpty else {
            return packagedCompatibilityReview(
                executionGateSource: executionGateSource,
                appServerConfiguration: appServerConfiguration
            )
        }
        let transport = CodexGhostRepairExperimentalAppServerObservationAdapter(
            source: CodexGhostRepairExperimentalReadOnlyAppServerSource(
                configuration: appServerConfiguration
            ),
            executionGateSource: executionGateSource
        )
        return CodexGhostRepairExperimentalCompatibilityReviewCoordinator(
            identityCoordinator:
                CodexGhostRepairSnapshotAnalysisIdentityCoordinatorFactory
                    .packagedReadOnly(),
            reader: CodexGhostRepairSnapshotAnalysisReaderFactory
                .packagedReadOnly(),
            observer:
                CodexGhostRepairExperimentalObservationCandidateCoordinator(
                    transport: transport
                ),
            registry: registry,
            previewPersister:
                CodexGhostRepairSnapshotDryRunLivePreviewPersister()
        )
    }
}
