import Foundation

/// M2i is a read-only adapter over the already separated inventory source.
/// It has no public factory or direct App call site and cannot name lifecycle
/// mutation methods. M2n constructs it privately behind an authority-free
/// compatibility-review factory. Construction performs no I/O.
actor CodexGhostRepairExperimentalAppServerObservationAdapter:
    CodexGhostRepairExperimentalObservationTransport
{
    private static let responseShapeIdentifier =
        "rpc-error-code-message-v1"

    private let source: any CodexInventorySource
    private let executionGateSource:
        any CodexGhostRepairExecutionGateSource

    init(
        source: any CodexInventorySource,
        executionGateSource: any CodexGhostRepairExecutionGateSource
    ) {
        self.source = source
        self.executionGateSource = executionGateSource
    }

    func inventory() async throws
        -> CodexGhostRepairExperimentalTransportInventory
    {
        let snapshot = try await source.inventory()
        let records = snapshot.active
            + snapshot.archived
            + snapshot.descendantRecords
        let pinEvidenceConsistent = snapshot.desktopPinStateAvailable
            && records.allSatisfy { record in
                guard let serverValue = record.isPinned else { return true }
                return serverValue
                    == snapshot.desktopPinnedThreadIDs.contains(record.id)
            }

        return .init(
            provider: .codex,
            runtimeVersion: snapshot.runtimeVersion ?? "",
            inventoryComplete: !snapshot.isTruncated,
            activeThreadIDs: snapshot.active.map(\.id),
            archivedThreadIDs: snapshot.archived.map(\.id),
            pinnedThreadIDs: snapshot.desktopPinnedThreadIDs,
            pinnedInventoryComplete: pinEvidenceConsistent,
            descendantNodes: snapshot.descendantRecords.map {
                .init(
                    threadID: $0.id,
                    parentThreadID: $0.parentThreadId
                )
            },
            descendantGraphComplete: snapshot.descendantGraphComplete
        )
    }

    func exactRead(
        threadID: String
    ) async throws -> CodexGhostRepairExperimentalTransportExactReadOutcome {
        do {
            let snapshot = try await source.exactRead(threadID: threadID)
            return .present(returnedThreadID: snapshot.thread.id)
        } catch let CodexAppServerError.rpcError(code, message) {
            return .failure(
                errorKind: .rpcError,
                rpcCode: code,
                responseShapeIdentifier: Self.responseShapeIdentifier,
                message: message
            )
        } catch {
            throw error
        }
    }

    func operationalAudit() async throws -> CodexGhostRepairExecutionGate {
        try await executionGateSource.ghostRepairExecutionGate()
    }
}
