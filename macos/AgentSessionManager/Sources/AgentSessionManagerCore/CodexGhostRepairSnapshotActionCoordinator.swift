import Foundation

protocol CodexGhostRepairSnapshotPublishing: Sendable {
    func inspectAdmission(
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome

    func publish(
        snapshotID: UUID,
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    ) async throws -> UUID
}

private struct CodexGhostRepairSnapshotQuarantinePublishingAdapter:
    CodexGhostRepairSnapshotPublishing
{
    typealias PublisherFactory = @Sendable (
        CodexGhostRepairSnapshotSourceProfile
    ) -> CodexGhostRepairSnapshotQuarantinePublisher

    let publisherFactory: PublisherFactory
    let workspaceFactory: CodexGhostRepairSnapshotAnalysisWorkspaceFactory

    static func production() -> Self {
        Self(
            publisherFactory: {
                .productionOperationalGateCandidate(profile: $0)
            },
            workspaceFactory: .production()
        )
    }

    func inspectAdmission(
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        await requestBoundPublisher(selection: selection).inspectAdmission(
            request: selection.request
        )
    }

    func publish(
        snapshotID: UUID,
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    ) async throws -> UUID {
        try await requestBoundPublisher(selection: selection).acquire(
            snapshotID: snapshotID,
            request: selection.request
        ).snapshotID
    }

    private func requestBoundPublisher(
        selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
    ) -> CodexGhostRepairSnapshotRequestBoundPublisher {
        .init(
            selection: selection,
            publisher: publisherFactory(selection.sourceProfile),
            workspaceFactory: workspaceFactory
        )
    }
}

/// Composition seam between the public App action contract and the internal
/// fixed source/destination publisher. M1b-12 exposes the enabled composition
/// only through an explicit, no-path packaged factory. The App still owns the
/// default-off preference, exact reviewed request, visible button, and
/// single-flight guards; constructing this actor never performs I/O.
actor CodexGhostRepairSnapshotPackagedCoordinator:
    CodexGhostRepairSnapshotActionCoordinator
{
    nonisolated let capabilities: CodexGhostRepairSnapshotActionCapabilities

    private let publisher: any CodexGhostRepairSnapshotPublishing

    static func productionDefaultBlocked() -> Self {
        Self(
            publisher: CodexGhostRepairSnapshotQuarantinePublishingAdapter
                .production(),
            acquisitionAvailable: false
        )
    }

    static func productionExplicitAction() -> Self {
        Self(
            publisher: CodexGhostRepairSnapshotQuarantinePublishingAdapter
                .production(),
            acquisitionAvailable: true
        )
    }

    init(
        publisher: any CodexGhostRepairSnapshotPublishing,
        acquisitionAvailable: Bool
    ) {
        self.publisher = publisher
        capabilities = acquisitionAvailable
            ? .fixedManagerRawDatabaseSnapshot
            : .packagedFixedManagerSnapshotBlocked
    }

    func inspectAdmission(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotAdmissionOutcome {
        guard capabilities.acquisitionAvailable else {
            return .unavailable(
                message: "Packaged raw database snapshot acquisition is assembled but live use is not authorized."
            )
        }
        guard let selection = try? CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        ) else {
            return .unavailable(
                message: "This snapshot build has no exact audited packaged profile for the observed Codex runtime."
            )
        }
        return await publisher.inspectAdmission(
            selection: selection
        )
    }

    func perform(
        request: CodexGhostRepairSnapshotActionRequest
    ) async -> CodexGhostRepairSnapshotActionOutcome {
        guard capabilities.acquisitionAvailable else {
            return .unavailable(
                message: "Packaged raw database snapshot acquisition is assembled but live use is not authorized."
            )
        }
        guard let selection = try? CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        ) else {
            return .unavailable(
                message: "This snapshot build has no exact audited packaged profile for the observed Codex runtime."
            )
        }

        // Recheck the read-only admission immediately before allocating the
        // one-shot snapshot identity. A known journal-free quota/capacity stop
        // is a normal blocked result, never a recovery-required result.
        switch await publisher.inspectAdmission(
            selection: selection
        ) {
        case .allowed:
            break
        case let .blocked(_, message):
            return .blocked(message: message)
        case let .unavailable(message):
            return .unavailable(message: message)
        }

        let snapshotID = UUID()
        do {
            let publishedID = try await publisher.publish(
                snapshotID: snapshotID,
                selection: selection
            )
            guard publishedID == snapshotID else {
                return .recoveryRequired(
                    reference: Self.reference(snapshotID),
                    message: Self.recoveryMessage(snapshotID: snapshotID)
                )
            }
            return .succeeded(reference: Self.reference(snapshotID))
        } catch {
            // Once the publisher is entered, the coordinator cannot infer
            // whether its exclusive journal was durably created. Fail closed:
            // preserve the exact reference and allow readback only, never an
            // automatic retry or a replacement UUID.
            return .recoveryRequired(
                reference: Self.reference(snapshotID),
                message: Self.recoveryMessage(
                    snapshotID: snapshotID,
                    stoppedStage: Self.pathRedactedStoppedStage(error)
                )
            )
        }
    }

    private static func reference(_ snapshotID: UUID) -> String {
        snapshotID.uuidString.lowercased()
    }

    private static func recoveryMessage(
        snapshotID: UUID,
        stoppedStage: String? = nil
    ) -> String {
        let stage = stoppedStage.map { " Stopped stage: \($0)." } ?? ""
        return "Snapshot \(snapshotID.uuidString.lowercased()) requires exact journal and filesystem readback; do not retry or clean up automatically.\(stage)"
    }

    private static func pathRedactedStoppedStage(_ error: Error) -> String {
        switch error as? CodexGhostRepairError {
        case .invalidDatabaseContract:
            "post-copy database schema verification"
        case .targetDrift:
            "post-copy source identity verification"
        case .executionGateBlocked:
            "post-copy operating-condition verification"
        case .snapshotAcquisitionFailed:
            "snapshot acquisition and publication"
        case .claimAlreadyExists:
            "exclusive snapshot journal claim"
        case .recoveryRequired:
            "durable journal or filesystem readback"
        case .sqlite:
            "post-copy database verification"
        case .invalidDisposablePath, .invalidPlan,
             .invalidProtectionEvidence, .previewExpired,
             .confirmationMismatch, .authorityDrift, .backupFailed,
             .injectedInterruption, .none:
            "snapshot acquisition and publication"
        }
    }
}

/// The only public construction seam visible to the App. Construction is
/// zero-I/O and accepts no path. The enabled factory exposes one explicit
/// snapshot action, but never grants repair or Codex database write authority.
public enum CodexGhostRepairSnapshotActionCoordinatorFactory {
    public static func packagedDefaultBlocked()
        -> any CodexGhostRepairSnapshotActionCoordinator
    {
        CodexGhostRepairSnapshotPackagedCoordinator.productionDefaultBlocked()
    }

    public static func packagedExplicitAction()
        -> any CodexGhostRepairSnapshotActionCoordinator
    {
        CodexGhostRepairSnapshotPackagedCoordinator.productionExplicitAction()
    }
}
