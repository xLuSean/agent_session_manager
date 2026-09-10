import Foundation

enum CodexGhostRepairCategoryASavedPreviewOutcome: Sendable {
    case preview(CodexGhostRepairSnapshotDryRunPreview)
    case notFound
    case unavailable
}

protocol CodexGhostRepairCategoryASavedPreviewReading: Sendable {
    func preview(
        requestID: UUID
    ) async -> CodexGhostRepairCategoryASavedPreviewOutcome
}

actor CodexGhostRepairCategoryAPackagedSavedPreviewReader:
    CodexGhostRepairCategoryASavedPreviewReading
{
    private let coordinator:
        any CodexGhostRepairSnapshotDryRunReadbackCoordinating

    static func production() -> Self {
        Self(
            coordinator:
                CodexGhostRepairSnapshotDryRunReadbackCoordinatorFactory
                    .packagedReadOnly()
        )
    }

    init(
        coordinator:
            any CodexGhostRepairSnapshotDryRunReadbackCoordinating
    ) {
        self.coordinator = coordinator
    }

    func preview(
        requestID: UUID
    ) async -> CodexGhostRepairCategoryASavedPreviewOutcome {
        let outcome = await coordinator.readback(requestID: requestID)
        switch outcome {
        case let .observed(evidence):
            guard evidence.requestID == requestID,
                  evidence.durableReadbackMatched,
                  !evidence.confirmationAuthority,
                  !evidence.repairMutationAuthority,
                  !evidence.preview.confirmationAuthority,
                  !evidence.preview.repairMutationAuthority else {
                return .unavailable
            }
            return .preview(evidence.preview)
        case .notFound:
            return .notFound
        case .unavailable:
            return .unavailable
        }
    }
}

struct CodexGhostRepairCategoryARepairReviewMaterial: Sendable {
    let review: CodexGhostRepairCategoryAExecutionReviewEvidence
    let buildIdentifier: String
    let observedAtMilliseconds: Int64
}

enum CodexGhostRepairCategoryARepairReviewMaterialOutcome: Sendable {
    case material(CodexGhostRepairCategoryARepairReviewMaterial)
    case blocked(CodexGhostRepairCategoryARepairReviewBlocker)
    case unavailable
}

protocol CodexGhostRepairCategoryARepairReviewMaterialCollecting: Sendable {
    func collect(
        draft: CodexGhostRepairCategoryAExecutionDraft
    ) async -> CodexGhostRepairCategoryARepairReviewMaterialOutcome
}

protocol CodexGhostRepairCategoryARepairChallengeJournaling: Sendable {
    func saveAndReadback(
        _ binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) async throws -> CodexGhostRepairCategoryAPreparedRepairBinding
}

actor CodexGhostRepairCategoryAPackagedChallengeJournal:
    CodexGhostRepairCategoryARepairChallengeJournaling
{
    private let storeProvider: @Sendable () throws -> SQLiteStateStore

    /// Construction is zero-I/O and accepts no path. The manager-owned store
    /// is resolved only after an explicit review reaches durable persistence.
    static func production() -> Self {
        Self(storeProvider: {
            try SQLiteStateStore(
                databaseURL:
                    StateStoreLocation.applicationSupportDatabaseURL()
            )
        })
    }

    init(
        storeProvider: @escaping @Sendable () throws -> SQLiteStateStore
    ) {
        self.storeProvider = storeProvider
    }

    func saveAndReadback(
        _ binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) async throws -> CodexGhostRepairCategoryAPreparedRepairBinding {
        let store = try storeProvider()
        defer { store.close() }
        let readback = try store.saveCodexGhostRepairCategoryAPreparedBinding(
            binding
        )
        guard let state = try store.codexGhostRepairCategoryAOperation(
            operationID: binding.operationID
        ) else {
            throw PersistentStateError.invalidRecord(
                "M3i durable operation readback is missing."
            )
        }
        guard state.status == .prepared,
              state.challenge == binding.challenge,
              state.receipt == nil,
              state.claim == nil,
              state.report == nil,
              !state.automaticRetryAllowed,
              !state.repairMutationAuthority,
              readback == binding else {
            throw PersistentStateError.invalidRecord(
                "M3i durable prepared binding readback did not match."
            )
        }
        return readback
    }
}

/// M3h review-only composition. It turns one exact durable M2 Preview plus
/// freshly collected review material into one durable, authority-free M3
/// challenge. It cannot consume confirmation or execute a repair.
actor CodexGhostRepairCategoryARepairReviewCoordinator:
    CodexGhostRepairCategoryARepairCoordinator
{
    nonisolated let capabilities =
        CodexGhostRepairCategoryARepairCapabilities.packagedReviewOnly

    private let savedPreviewReader:
        any CodexGhostRepairCategoryASavedPreviewReading
    private let reviewCollector:
        any CodexGhostRepairCategoryARepairReviewMaterialCollecting
    private let journal:
        any CodexGhostRepairCategoryARepairChallengeJournaling
    private let nowMilliseconds: @Sendable () -> Int64

    init(
        savedPreviewReader:
            any CodexGhostRepairCategoryASavedPreviewReading,
        reviewCollector:
            any CodexGhostRepairCategoryARepairReviewMaterialCollecting,
        journal: any CodexGhostRepairCategoryARepairChallengeJournaling,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.savedPreviewReader = savedPreviewReader
        self.reviewCollector = reviewCollector
        self.journal = journal
        self.nowMilliseconds = nowMilliseconds
    }

    func prepareReview(
        request: CodexGhostRepairCategoryARepairReviewRequest
    ) async -> CodexGhostRepairCategoryARepairReviewOutcome {
        let saved = await savedPreviewReader.preview(
            requestID: request.savedPreviewRequestID
        )
        let preview: CodexGhostRepairSnapshotDryRunPreview
        switch saved {
        case let .preview(value):
            preview = value
        case .notFound:
            return blocked(.savedPreviewUnavailable)
        case .unavailable:
            return unavailable()
        }

        let now = nowMilliseconds()
        let draftOutcome = CodexGhostRepairCategoryAExecutionContract.freeze(
            preview: preview,
            operationID: request.requestID,
            observedAtMilliseconds: now
        )
        let draft: CodexGhostRepairCategoryAExecutionDraft
        switch draftOutcome {
        case let .draft(value):
            draft = value
        case let .blocked(blocker):
            return blocked(Self.map(blocker))
        }

        let materialOutcome = await reviewCollector.collect(draft: draft)
        let material: CodexGhostRepairCategoryARepairReviewMaterial
        switch materialOutcome {
        case let .material(value):
            material = value
        case let .blocked(blocker):
            return blocked(blocker)
        case .unavailable:
            return unavailable()
        }

        let challengeOutcome =
            CodexGhostRepairCategoryAExecutionPreparation.prepareChallenge(
                draft: draft,
                review: material.review,
                buildIdentifier: material.buildIdentifier,
                observedAtMilliseconds: material.observedAtMilliseconds
            )
        let challenge: CodexGhostRepairCategoryAConfirmationChallenge
        switch challengeOutcome {
        case let .challenge(value):
            challenge = value
        case let .blocked(blocker):
            return blocked(Self.map(blocker))
        }

        do {
            let binding = try CodexGhostRepairCategoryAPreparedRepairBinding(
                savedPreviewRequestID: request.savedPreviewRequestID,
                draft: draft,
                review: material.review,
                challenge: challenge
            )
            let durable = try await journal.saveAndReadback(binding)
            guard durable == binding else {
                return blocked(.persistenceUnavailable)
            }
            return .ready(try Self.publicChallenge(durable))
        } catch {
            return blocked(.persistenceUnavailable)
        }
    }

    func confirmAndRepair(
        request _: CodexGhostRepairCategoryARepairExecutionRequest
    ) async -> CodexGhostRepairCategoryARepairExecutionOutcome {
        .unavailable(
            message:
                "This build can prepare a durable review only; Category A repair execution is unavailable."
        )
    }

    private func blocked(
        _ blocker: CodexGhostRepairCategoryARepairReviewBlocker
    ) -> CodexGhostRepairCategoryARepairReviewOutcome {
        .blocked(
            blocker,
            message:
                "Fresh Category A repair review stopped safely at \(blocker.rawValue). No confirmation or repair authority was created."
        )
    }

    private func unavailable()
        -> CodexGhostRepairCategoryARepairReviewOutcome
    {
        .unavailable(
            message:
                "Fresh Category A repair review could not produce bounded evidence. No confirmation or repair authority was created."
        )
    }

    private static func publicChallenge(
        _ binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) throws -> CodexGhostRepairCategoryARepairChallenge {
        let challenge = binding.challenge
        return try CodexGhostRepairCategoryARepairChallenge(
            operationID: challenge.operationID,
            savedPreviewRequestID: binding.savedPreviewRequestID,
            snapshotReference: binding.snapshotReference,
            snapshotManifestHash: binding.snapshotManifestHash,
            snapshotSourceFingerprintHash:
                binding.snapshotSourceFingerprintHash,
            preparedBindingDigest: binding.bindingDigest,
            targetThreadIDs: challenge.targetThreadIDs,
            buildIdentifier: challenge.buildIdentifier,
            draftDigest: challenge.draftDigest,
            reviewDigest: challenge.reviewDigest,
            challengeDigest: challenge.challengeDigest,
            confirmationToken: challenge.confirmationToken,
            generatedAt: Date(
                timeIntervalSince1970:
                    Double(challenge.generatedAtMilliseconds) / 1_000
            ),
            expiresAt: Date(
                timeIntervalSince1970:
                    Double(challenge.expiresAtMilliseconds) / 1_000
            )
        )
    }

    private static func map(
        _ blocker: CodexGhostRepairCategoryAExecutionDraftBlocker
    ) -> CodexGhostRepairCategoryARepairReviewBlocker {
        switch blocker {
        case .invalidPreview: .savedPreviewUnavailable
        case .previewExpired: .savedPreviewExpired
        case .categoryUnavailable: .categoryNotSupported
        case .invalidDatabaseScope: .schemaDrift
        case .invalidLogicalEffects: .targetDrift
        }
    }

    private static func map(
        _ blocker: CodexGhostRepairCategoryAExecutionPreparationBlocker
    ) -> CodexGhostRepairCategoryARepairReviewBlocker {
        switch blocker {
        case .invalidDraft, .draftExpired: .savedPreviewExpired
        case .invalidReview: .protectionUnavailable
        case .targetDrift: .targetDrift
        case .protectionUnavailable: .protectionUnavailable
        case .operationalGateBlocked: .operatingConditionsBlocked
        case .schemaDrift: .schemaDrift
        }
    }
}

enum CodexGhostRepairCategoryARepairReviewCoordinatorFactory {
    /// Shipping-internal production review candidate. Construction is
    /// path-free and zero-I/O; it remains unreachable from the App until the
    /// later no-launch UI wiring stage.
    static func packagedProductionReview(
        appServerConfiguration: CodexAppServerConfiguration = .init()
    ) -> any CodexGhostRepairCategoryARepairCoordinator {
        packagedReviewOnly(
            reviewCollector:
                CodexGhostRepairCategoryAProductionReviewMaterialCollector
                    .production(
                        appServerConfiguration: appServerConfiguration
                    )
        )
    }

    /// No caller path and construction performs no I/O. The returned
    /// coordinator reaches manager readback, fresh review collection, and
    /// challenge persistence only after an explicit prepareReview request.
    static func packagedReviewOnly(
        reviewCollector:
            any CodexGhostRepairCategoryARepairReviewMaterialCollecting
    ) -> any CodexGhostRepairCategoryARepairCoordinator {
        CodexGhostRepairCategoryARepairReviewCoordinator(
            savedPreviewReader:
                CodexGhostRepairCategoryAPackagedSavedPreviewReader
                    .production(),
            reviewCollector: reviewCollector,
            journal:
                CodexGhostRepairCategoryAPackagedChallengeJournal
                    .production()
        )
    }
}
