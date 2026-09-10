import Foundation

struct CodexGhostRepairExperimentalObservationRequest: Sendable {
    let requestID: UUID
    let identity: CodexGhostRepairSnapshotAnalysisIdentity

    var acceptsCallerPath: Bool { false }
    var automaticRead: Bool { false }
    var automaticRetry: Bool { false }
    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }
}

struct CodexGhostRepairExperimentalObservationCapabilities:
    Equatable,
    Sendable
{
    let observationAvailable: Bool
    let inventoryReadAvailable: Bool
    let exactReadAvailable: Bool
    let operationalAuditAvailable: Bool

    var acceptsCallerPath: Bool { false }
    var automaticRead: Bool { false }
    var automaticRetry: Bool { false }
    var writesFilesystem: Bool { false }
    var persistsEvidence: Bool { false }
    var officialLifecycleAuthority: Bool { false }
    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }

    static let unavailable = Self(
        observationAvailable: false,
        inventoryReadAvailable: false,
        exactReadAvailable: false,
        operationalAuditAvailable: false
    )

    static let deterministicCandidate = Self(
        observationAvailable: true,
        inventoryReadAvailable: true,
        exactReadAvailable: true,
        operationalAuditAvailable: true
    )
}

struct CodexGhostRepairExperimentalTransportInventory: Sendable {
    let provider: AgentSystem
    let runtimeVersion: String
    let inventoryComplete: Bool
    let activeThreadIDs: [String]
    let archivedThreadIDs: [String]
    let pinnedThreadIDs: Set<String>
    let pinnedInventoryComplete: Bool
    let descendantNodes: [CodexGhostRepairExperimentalDescendantNode]
    let descendantGraphComplete: Bool
}

enum CodexGhostRepairExperimentalTransportExactReadOutcome: Sendable {
    case present(returnedThreadID: String)
    case failure(
        errorKind: CodexGhostRepairExperimentalAbsenceErrorKind,
        rpcCode: Int,
        responseShapeIdentifier: String,
        message: String
    )
}

protocol CodexGhostRepairExperimentalObservationTransport: Sendable {
    func inventory() async throws
        -> CodexGhostRepairExperimentalTransportInventory
    func exactRead(
        threadID: String
    ) async throws -> CodexGhostRepairExperimentalTransportExactReadOutcome
    func operationalAudit() async throws -> CodexGhostRepairExecutionGate
}

struct CodexGhostRepairExperimentalObservedProtection: Sendable {
    let requestID: UUID
    let identity: CodexGhostRepairSnapshotAnalysisIdentity
    let observation: CodexGhostRepairExperimentalProtectionObservation
}

enum CodexGhostRepairExperimentalObservationOutcome: Sendable {
    case observed(CodexGhostRepairExperimentalObservedProtection)
    case unavailable(
        requestID: UUID,
        failure: CodexGhostRepairExperimentalCompatibilityFailure
    )

    var requestID: UUID {
        switch self {
        case let .observed(result): result.requestID
        case let .unavailable(requestID, _): requestID
        }
    }
}

protocol CodexGhostRepairExperimentalObservationCoordinating: Sendable {
    var capabilities: CodexGhostRepairExperimentalObservationCapabilities {
        get
    }

    func observe(
        request: CodexGhostRepairExperimentalObservationRequest
    ) async -> CodexGhostRepairExperimentalObservationOutcome
}

actor CodexGhostRepairExperimentalObservationCandidateCoordinator:
    CodexGhostRepairExperimentalObservationCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairExperimentalObservationCapabilities
            .deterministicCandidate

    private let transport:
        any CodexGhostRepairExperimentalObservationTransport

    init(transport: any CodexGhostRepairExperimentalObservationTransport) {
        self.transport = transport
    }

    func observe(
        request: CodexGhostRepairExperimentalObservationRequest
    ) async -> CodexGhostRepairExperimentalObservationOutcome {
        let targets = request.identity.targetThreadIDs
        guard (1...2).contains(targets.count),
              targets == targets.sorted(),
              Set(targets).count == targets.count,
              targets.allSatisfy(Self.isCanonicalUUID) else {
            return unavailable(
                request.requestID,
                stage: .requestValidation,
                reason: .invalidRequest
            )
        }

        let inventory: CodexGhostRepairExperimentalTransportInventory
        do {
            inventory = try await transport.inventory()
        } catch {
            return unavailable(
                request.requestID,
                stage: .appServerInventory,
                reason: .inventoryReadFailed
            )
        }
        guard inventory.provider == .codex,
              !inventory.runtimeVersion.isEmpty,
              inventory.inventoryComplete,
              inventory.pinnedInventoryComplete,
              inventory.descendantGraphComplete else {
            return unavailable(
                request.requestID,
                stage: .inventoryValidation,
                reason: .inventoryIncomplete
            )
        }

        let active: Set<String>
        let archived: Set<String>
        do {
            active = try Self.exactIDSet(inventory.activeThreadIDs)
            archived = try Self.exactIDSet(inventory.archivedThreadIDs)
        } catch {
            return unavailable(
                request.requestID,
                stage: .inventoryValidation,
                reason: .inventoryInvalid
            )
        }
        guard active.isDisjoint(with: archived),
              active.isDisjoint(with: targets),
              archived.isDisjoint(with: targets) else {
            return unavailable(
                request.requestID,
                stage: .inventoryValidation,
                reason: .inventoryInvalid
            )
        }
        guard let presentControlThreadID = active
            .union(archived)
            .subtracting(targets)
            .sorted()
            .first else {
            return unavailable(
                request.requestID,
                stage: .inventoryValidation,
                reason: .noPresentControl
            )
        }

        let presentControl: CodexGhostRepairExperimentalTransportExactReadOutcome
        do {
            presentControl = try await transport.exactRead(
                threadID: presentControlThreadID
            )
        } catch {
            return unavailable(
                request.requestID,
                stage: .presentControlRead,
                reason: .presentControlReadFailed
            )
        }
        guard case let .present(returnedThreadID) = presentControl,
              returnedThreadID == presentControlThreadID else {
            return unavailable(
                request.requestID,
                stage: .presentControlRead,
                reason: .presentControlMismatch
            )
        }

        var failures:
            [CodexGhostRepairExperimentalExactReadFailureObservation] = []
        failures.reserveCapacity(targets.count)
        for threadID in targets {
            let read: CodexGhostRepairExperimentalTransportExactReadOutcome
            do {
                read = try await transport.exactRead(threadID: threadID)
            } catch {
                return unavailable(
                    request.requestID,
                    stage: .targetExactRead,
                    reason: .targetReadFailed
                )
            }
            guard case let .failure(
                errorKind,
                rpcCode,
                responseShapeIdentifier,
                message
            ) = read else {
                return unavailable(
                    request.requestID,
                    stage: .targetExactRead,
                    reason: .targetUnexpectedlyPresent
                )
            }
            failures.append(.init(
                threadID: threadID,
                provider: inventory.provider,
                runtimeVersion: inventory.runtimeVersion,
                method: .threadRead,
                errorKind: errorKind,
                rpcCode: rpcCode,
                responseShapeIdentifier: responseShapeIdentifier,
                message: message
            ))
        }

        let audit: CodexGhostRepairExecutionGate
        do {
            audit = try await transport.operationalAudit()
        } catch {
            return unavailable(
                request.requestID,
                stage: .operationalAudit,
                reason: .operationalAuditFailed
            )
        }
        return .observed(.init(
            requestID: request.requestID,
            identity: request.identity,
            observation: .init(
                provider: inventory.provider,
                runtimeVersion: inventory.runtimeVersion,
                inventoryComplete: inventory.inventoryComplete,
                activeThreadIDs: inventory.activeThreadIDs,
                archivedThreadIDs: inventory.archivedThreadIDs,
                pinnedThreadIDs: inventory.pinnedThreadIDs,
                pinnedInventoryComplete: inventory.pinnedInventoryComplete,
                descendantNodes: inventory.descendantNodes,
                descendantGraphComplete: inventory.descendantGraphComplete,
                presentControlThreadID: presentControlThreadID,
                presentControlReturnedThreadID: returnedThreadID,
                exactReadFailures: failures,
                operationalAudit: audit
            )
        ))
    }

    private func unavailable(
        _ requestID: UUID,
        stage: CodexGhostRepairExperimentalCompatibilityFailureStage,
        reason: CodexGhostRepairExperimentalCompatibilityFailureReason
    ) -> CodexGhostRepairExperimentalObservationOutcome {
        .unavailable(
            requestID: requestID,
            failure: .init(stage: stage, reason: reason)
        )
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func exactIDSet(_ values: [String]) throws -> Set<String> {
        guard Set(values).count == values.count,
              values.allSatisfy(isCanonicalUUID) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Experimental inventory IDs are incomplete or invalid."
            )
        }
        return Set(values)
    }
}

private struct CodexGhostRepairUnavailableExperimentalObservationCoordinator:
    CodexGhostRepairExperimentalObservationCoordinating
{
    let capabilities =
        CodexGhostRepairExperimentalObservationCapabilities.unavailable

    func observe(
        request: CodexGhostRepairExperimentalObservationRequest
    ) async -> CodexGhostRepairExperimentalObservationOutcome {
        .unavailable(
            requestID: request.requestID,
            failure: .init(
                stage: .appServerInventory,
                reason: .observationUnavailable
            )
        )
    }
}

enum CodexGhostRepairExperimentalObservationCoordinatorFactory {
    static func packagedDefaultUnavailable()
        -> any CodexGhostRepairExperimentalObservationCoordinating
    {
        CodexGhostRepairUnavailableExperimentalObservationCoordinator()
    }
}
