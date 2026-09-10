import Foundation

/// Version-exact mappings that may convert one official `thread/read` RPC
/// response into absence evidence. An empty registry is the shipping-safe
/// default: undocumented or version-drifted responses remain unavailable.
public struct CodexGhostRepairAbsenceContractRegistry: Sendable {
    private struct Key: Hashable, Sendable {
        let runtimeVersion: String
        let rpcCode: Int
    }

    private let contracts: [Key: ExactSessionAbsenceContract]

    public init() {
        contracts = [:]
    }

    public init(contracts: [ExactSessionAbsenceContract]) throws {
        var indexed: [Key: ExactSessionAbsenceContract] = [:]
        for contract in contracts {
            guard contract.provider == .codex,
                  !contract.runtimeVersion.isEmpty,
                  contract.rpcCode == -32600,
                  !contract.identifier.isEmpty,
                  contract.officialSourceURL.scheme == "https" else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Absence contracts must be Codex -32600, version-exact, named, and HTTPS-backed."
                )
            }
            let key = Key(
                runtimeVersion: contract.runtimeVersion,
                rpcCode: contract.rpcCode
            )
            guard indexed.updateValue(contract, forKey: key) == nil else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Duplicate absence contract for \(contract.runtimeVersion) / \(contract.rpcCode)."
                )
            }
        }
        self.contracts = indexed
    }

    fileprivate func contract(
        runtimeVersion: String,
        rpcCode: Int
    ) -> ExactSessionAbsenceContract? {
        contracts[Key(runtimeVersion: runtimeVersion, rpcCode: rpcCode)]
    }
}

/// Supplies process, open-handle, and backup-capacity evidence without giving
/// the official inventory adapter any database or lifecycle mutation method.
public protocol CodexGhostRepairExecutionGateSource: Sendable {
    func ghostRepairExecutionGate() async throws -> CodexGhostRepairExecutionGate
}

/// Safe default used until a separately verified operational gate adapter is
/// injected. It can never authorize execution.
public struct CodexGhostRepairUnavailableExecutionGateSource:
    CodexGhostRepairExecutionGateSource,
    Sendable
{
    public init() {}

    public func ghostRepairExecutionGate() async throws -> CodexGhostRepairExecutionGate {
        CodexGhostRepairExecutionGate(
            codexFullyExited: false,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: false
        )
    }
}

/// Live-backed, read-only bridge from one fresh Codex App Server inventory to
/// the Ghost Repair safety collector. The stored source is deliberately erased
/// to `CodexInventorySource`; this type has no lifecycle or SQLite transport.
public actor CodexGhostRepairLiveReadOnlySafetySource:
    CodexGhostRepairReadOnlySafetySource
{
    private let source: any CodexInventorySource
    private let absenceContracts: CodexGhostRepairAbsenceContractRegistry
    private let executionGateSource: any CodexGhostRepairExecutionGateSource

    public init(
        configuration: CodexAppServerConfiguration = CodexAppServerConfiguration(),
        absenceContracts: CodexGhostRepairAbsenceContractRegistry,
        executionGateSource: any CodexGhostRepairExecutionGateSource =
            CodexGhostRepairUnavailableExecutionGateSource()
    ) {
        self.source = CodexAppServerClient.ghostRepairProduction(configuration: configuration)
        self.absenceContracts = absenceContracts
        self.executionGateSource = executionGateSource
    }

    init(
        source: any CodexInventorySource,
        absenceContracts: CodexGhostRepairAbsenceContractRegistry,
        executionGateSource: any CodexGhostRepairExecutionGateSource
    ) {
        self.source = source
        self.absenceContracts = absenceContracts
        self.executionGateSource = executionGateSource
    }

    public func ghostRepairSafetySnapshot(
        targetThreadIDs: [String]
    ) async throws -> CodexGhostRepairSafetySnapshot {
        guard (1...10).contains(targetThreadIDs.count),
              Set(targetThreadIDs).count == targetThreadIDs.count,
              targetThreadIDs.allSatisfy({
                  !$0.isEmpty
                      && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
              }) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Target IDs must be 1–10 unique, non-empty, unmodified exact IDs."
            )
        }

        // One raw inventory supplies Active, Archived, pin, descendant, runtime,
        // and completeness evidence. Do not assemble these from separate refreshes.
        let rawInventory = try await source.inventory()
        let inventory = try Self.ghostRepairInventory(from: rawInventory)

        var exactReadbacks: [ExactSessionReadbackEvidence] = []
        exactReadbacks.reserveCapacity(targetThreadIDs.count)
        for threadID in targetThreadIDs {
            exactReadbacks.append(await exactReadback(
                threadID: threadID,
                inventoryRuntimeVersion: rawInventory.runtimeVersion
            ))
        }

        let executionGate = try await executionGateSource.ghostRepairExecutionGate()
        return CodexGhostRepairSafetySnapshot(
            inventory: inventory,
            exactReadbacks: exactReadbacks,
            pinnedThreadIDs: rawInventory.desktopPinnedThreadIDs,
            pinnedInventoryComplete: rawInventory.desktopPinStateAvailable,
            executionGate: executionGate
        )
    }

    private static func ghostRepairInventory(
        from rawInventory: CodexInventorySnapshot
    ) throws -> ProviderInventorySnapshot {
        let generic = try CodexProviderInventorySnapshotBuilder.make(from: rawInventory)
        // Generic lifecycle protection also requires current-task authority for
        // every listed session. A Ghost Repair target is absent from both lists;
        // its relevant live protection is instead the stable global pin set,
        // complete descendant graph, and exact not-loaded readback validated by
        // the collector. Preserve that narrower meaning explicitly here.
        return ProviderInventorySnapshot(
            provider: generic.provider,
            runtimeVersion: generic.runtimeVersion,
            inventoryHash: generic.inventoryHash,
            observedAt: generic.observedAt,
            inventoryComplete: generic.inventoryComplete,
            protectionComplete: !rawInventory.isTruncated
                && rawInventory.desktopPinStateAvailable
                && rawInventory.descendantGraphComplete,
            sessions: generic.sessions,
            archiveScopeNodes: generic.archiveScopeNodes,
            archiveScopeComplete: generic.archiveScopeComplete,
            errorCode: generic.errorCode,
            errorMessage: generic.errorMessage
        )
    }

    private func exactReadback(
        threadID: String,
        inventoryRuntimeVersion: String?
    ) async -> ExactSessionReadbackEvidence {
        do {
            let snapshot = try await source.exactRead(threadID: threadID)
            guard snapshot.thread.id == threadID else {
                return ExactSessionReadbackEvidence(
                    provider: .codex,
                    nativeSessionID: threadID,
                    status: .unavailable,
                    observedAt: snapshot.observedAt,
                    runtimeVersion: snapshot.runtimeVersion,
                    evidenceKind: .identityMismatch,
                    message: "thread/read returned a different native session ID."
                )
            }
            return ExactSessionReadbackEvidence(
                provider: .codex,
                nativeSessionID: threadID,
                status: .present,
                observedAt: snapshot.observedAt,
                runtimeVersion: snapshot.runtimeVersion,
                evidenceKind: .exactMatch,
                message: "Official thread/read returned this exact persisted thread without resuming it."
            )
        } catch {
            let failure = Self.exactReadbackFailure(error)
            if let runtimeVersion = inventoryRuntimeVersion,
               let rpcCode = failure.rpcCode,
               let contract = absenceContracts.contract(
                   runtimeVersion: runtimeVersion,
                   rpcCode: rpcCode
               ) {
                return ExactSessionReadbackEvidence(
                    provider: .codex,
                    nativeSessionID: threadID,
                    status: .absent,
                    observedAt: Date(),
                    runtimeVersion: runtimeVersion,
                    evidenceKind: .documentedNotFound,
                    rpcCode: rpcCode,
                    absenceContract: contract,
                    message: error.localizedDescription
                )
            }
            return ExactSessionReadbackEvidence(
                provider: .codex,
                nativeSessionID: threadID,
                status: .unavailable,
                observedAt: Date(),
                runtimeVersion: inventoryRuntimeVersion,
                evidenceKind: failure.kind,
                rpcCode: failure.rpcCode,
                message: error.localizedDescription
            )
        }
    }

    private static func exactReadbackFailure(
        _ error: Error
    ) -> (kind: ExactSessionReadbackEvidenceKind, rpcCode: Int?) {
        guard let appServerError = error as? CodexAppServerError else {
            return (.unknownFailure, nil)
        }
        switch appServerError {
        case let .rpcError(code, _): return (.rpcError, code)
        case .responseTimeout: return (.timeout, nil)
        case .exactReadUnavailable: return (.sourceUnavailable, nil)
        case .malformedResponse: return (.malformedResponse, nil)
        case .executableNotFound, .launchFailed, .processExited:
            return (.processFailure, nil)
        }
    }
}
