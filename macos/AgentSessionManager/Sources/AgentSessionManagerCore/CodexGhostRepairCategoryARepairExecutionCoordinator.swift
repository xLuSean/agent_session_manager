import Foundation

struct CodexGhostRepairCategoryARepairExecutionObservation: Sendable {
    let outcome: CodexGhostRepairCategoryABatchOutcome
    let mutationAttemptedOnce: Bool
}

protocol CodexGhostRepairCategoryARepairFreshEvidenceCollecting: Sendable {
    func collect(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) async -> CodexGhostRepairCategoryAFreshExecutionEvidence?
}

protocol CodexGhostRepairCategoryARepairMutating: Sendable {
    func executeOnce(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) async throws -> CodexGhostRepairCategoryARepairExecutionObservation

    func recoverByReadback(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) async throws -> CodexGhostRepairCategoryARepairExecutionObservation
}

protocol CodexGhostRepairCategoryARepairExecutionJournaling: Sendable {
    func preparedBinding(
        operationID: UUID
    ) async throws -> CodexGhostRepairCategoryAPreparedRepairBinding?

    func operation(
        operationID: UUID
    ) async throws -> CodexGhostRepairCategoryAExecutionOperationState?

    func consumeAuthorization(
        operationID: UUID,
        confirmationToken: String,
        confirmedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairCategoryAAuthorizationConsumeResult

    func claim(
        _ evidence: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) async throws -> CodexGhostRepairCategoryAExecutionClaimResult

    func finalize(
        _ report: CodexGhostRepairCategoryAExecutionTerminalReport
    ) async throws -> CodexGhostRepairCategoryAExecutionTerminalReport
}

actor CodexGhostRepairCategoryAPackagedExecutionJournal:
    CodexGhostRepairCategoryARepairExecutionJournaling
{
    private let storeProvider: @Sendable () throws -> SQLiteStateStore

    static func production() -> Self {
        Self(storeProvider: {
            try SQLiteStateStore(
                databaseURL: StateStoreLocation.applicationSupportDatabaseURL()
            )
        })
    }

    init(storeProvider: @escaping @Sendable () throws -> SQLiteStateStore) {
        self.storeProvider = storeProvider
    }

    func preparedBinding(
        operationID: UUID
    ) throws -> CodexGhostRepairCategoryAPreparedRepairBinding? {
        let store = try storeProvider()
        defer { store.close() }
        return try store.codexGhostRepairCategoryAPreparedBinding(
            operationID: operationID
        )
    }

    func operation(
        operationID: UUID
    ) throws -> CodexGhostRepairCategoryAExecutionOperationState? {
        let store = try storeProvider()
        defer { store.close() }
        return try store.codexGhostRepairCategoryAOperation(
            operationID: operationID
        )
    }

    func consumeAuthorization(
        operationID: UUID,
        confirmationToken: String,
        confirmedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairCategoryAAuthorizationConsumeResult {
        let store = try storeProvider()
        defer { store.close() }
        return try store.consumeCodexGhostRepairCategoryAAuthorization(
            operationID: operationID,
            confirmationToken: confirmationToken,
            confirmedAtMilliseconds: confirmedAtMilliseconds
        )
    }

    func claim(
        _ evidence: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) throws -> CodexGhostRepairCategoryAExecutionClaimResult {
        let store = try storeProvider()
        defer { store.close() }
        return try store.claimCodexGhostRepairCategoryAExecution(evidence)
    }

    func finalize(
        _ report: CodexGhostRepairCategoryAExecutionTerminalReport
    ) throws -> CodexGhostRepairCategoryAExecutionTerminalReport {
        let store = try storeProvider()
        defer { store.close() }
        try store.finalizeCodexGhostRepairCategoryAExecution(report)
        guard let readback = try store.codexGhostRepairCategoryAOperation(
            operationID: report.operationID
        )?.report, readback == report else {
            throw PersistentStateError.invalidRecord(
                "Category A terminal Report durable readback did not match."
            )
        }
        return readback
    }
}

actor CodexGhostRepairCategoryAProductionFreshExecutionCollector:
    CodexGhostRepairCategoryARepairFreshEvidenceCollecting
{
    private let reviewCollector:
        any CodexGhostRepairCategoryARepairReviewMaterialCollecting

    static func production(
        appServerConfiguration: CodexAppServerConfiguration = .init()
    ) -> Self {
        Self(
            reviewCollector:
                CodexGhostRepairCategoryAProductionReviewMaterialCollector
                    .production(
                        appServerConfiguration: appServerConfiguration
                    )
        )
    }

    init(
        reviewCollector:
            any CodexGhostRepairCategoryARepairReviewMaterialCollecting
    ) {
        self.reviewCollector = reviewCollector
    }

    func collect(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) async -> CodexGhostRepairCategoryAFreshExecutionEvidence? {
        let outcome = await reviewCollector.collect(draft: binding.draft)
        guard case let .material(material) = outcome,
              material.review.items == binding.review.items,
              material.review.protectionEvidenceHash
                == binding.review.protectionEvidenceHash,
              material.review.protectionComplete,
              material.review.operationalGateClear,
              material.review.databaseExpectations
                == binding.draft.databaseExpectations else {
            return nil
        }
        return try? .init(
            items: material.review.items.map {
                .init(
                    threadID: $0.threadID,
                    catalogRowDigest: $0.catalogRowDigest
                )
            },
            protectionEvidenceHash:
                material.review.protectionEvidenceHash,
            protectionComplete: material.review.protectionComplete,
            operationalGateEvidenceHash:
                material.review.operationalGateEvidenceHash,
            operationalGateClear: material.review.operationalGateClear,
            databaseExpectations: material.review.databaseExpectations,
            freshAuthority: material.review.authorityAudit,
            observedAtMilliseconds: material.review.observedAtMilliseconds
        )
    }
}

/// Confirmation and execution composition for one durable prepared binding.
/// A repeated call can only read an existing receipt, claim or Report. It
/// never invokes the mutator after authorization has already been consumed.
actor CodexGhostRepairCategoryARepairExecutionCoordinator:
    CodexGhostRepairCategoryARepairCoordinator
{
    nonisolated let capabilities =
        CodexGhostRepairCategoryARepairCapabilities.packagedExecutionCandidate

    private let reviewCoordinator:
        any CodexGhostRepairCategoryARepairCoordinator
    private let journal:
        any CodexGhostRepairCategoryARepairExecutionJournaling
    private let freshCollector:
        any CodexGhostRepairCategoryARepairFreshEvidenceCollecting
    private let mutator: any CodexGhostRepairCategoryARepairMutating
    private let nowMilliseconds: @Sendable () -> Int64

    init(
        reviewCoordinator: any CodexGhostRepairCategoryARepairCoordinator,
        journal: any CodexGhostRepairCategoryARepairExecutionJournaling,
        freshCollector:
            any CodexGhostRepairCategoryARepairFreshEvidenceCollecting,
        mutator: any CodexGhostRepairCategoryARepairMutating,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.reviewCoordinator = reviewCoordinator
        self.journal = journal
        self.freshCollector = freshCollector
        self.mutator = mutator
        self.nowMilliseconds = nowMilliseconds
    }

    func prepareReview(
        request: CodexGhostRepairCategoryARepairReviewRequest
    ) async -> CodexGhostRepairCategoryARepairReviewOutcome {
        await reviewCoordinator.prepareReview(request: request)
    }

    func confirmAndRepair(
        request: CodexGhostRepairCategoryARepairExecutionRequest
    ) async -> CodexGhostRepairCategoryARepairExecutionOutcome {
        do {
            guard let binding = try await journal.preparedBinding(
                operationID: request.challenge.operationID
            ), Self.matches(request.challenge, binding: binding) else {
                return unavailable("The exact prepared repair binding is unavailable.")
            }

            if let state = try await journal.operation(
                operationID: binding.operationID
            ), let report = state.report {
                return try completed(report)
            }

            let now = nowMilliseconds()
            let consume = try await journal.consumeAuthorization(
                operationID: binding.operationID,
                confirmationToken: request.exactConfirmationToken,
                confirmedAtMilliseconds: now
            )
            switch consume {
            case let .existingReport(report):
                return try completed(report)
            case let .existingReceipt(receipt):
                return try await recoverConsumed(
                    binding: binding,
                    receipt: receipt,
                    completedAtMilliseconds: now
                )
            case let .consumed(receipt):
                return try await executeNewAuthorization(
                    binding: binding,
                    receipt: receipt,
                    now: now
                )
            }
        } catch PersistentStateError.confirmationMismatch {
            return unavailable("The exact confirmation token did not match.")
        } catch {
            return .recoveryRequired(
                operationID: request.challenge.operationID,
                message:
                    "The one-shot operation could not prove a terminal outcome. Do not retry the repair."
            )
        }
    }

    private func executeNewAuthorization(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        receipt: CodexGhostRepairCategoryAAuthorizationReceipt,
        now: Int64
    ) async throws -> CodexGhostRepairCategoryARepairExecutionOutcome {
        guard let fresh = await freshCollector.collect(binding: binding) else {
            return try await terminal(
                binding: binding,
                receipt: receipt,
                claim: nil,
                outcome: .notAttempted,
                mutationAttemptedOnce: false,
                completedAtMilliseconds: now
            )
        }
        let claim: CodexGhostRepairCategoryAExecutionClaimEvidence
        do {
            claim = try CodexGhostRepairCategoryAExecutionPreparation
                .prepareClaimEvidence(
                    draft: binding.draft,
                    review: binding.review,
                    challenge: binding.challenge,
                    receipt: receipt,
                    executionSnapshotManifestHash:
                        binding.snapshotManifestHash,
                    freshEvidence: fresh,
                    executionAtMilliseconds: now,
                    claimedAtMilliseconds: now
                )
        } catch {
            return try await terminal(
                binding: binding,
                receipt: receipt,
                claim: nil,
                outcome: .notAttempted,
                mutationAttemptedOnce: false,
                completedAtMilliseconds: now
            )
        }

        switch try await journal.claim(claim) {
        case let .existingReport(report):
            return try completed(report)
        case let .recoveryRequired(durableClaim):
            return try await recoverClaimed(
                binding: binding,
                receipt: receipt,
                claim: durableClaim,
                completedAtMilliseconds: now
            )
        case .claimed:
            do {
                let observed = try await mutator.executeOnce(
                    binding: binding,
                    claim: claim
                )
                return try await terminal(
                    binding: binding,
                    receipt: receipt,
                    claim: claim,
                    outcome: observed.outcome,
                    mutationAttemptedOnce:
                        observed.mutationAttemptedOnce,
                    completedAtMilliseconds: nowMilliseconds()
                )
            } catch {
                return try await recoverClaimed(
                    binding: binding,
                    receipt: receipt,
                    claim: claim,
                    completedAtMilliseconds: nowMilliseconds()
                )
            }
        }
    }

    private func recoverConsumed(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        receipt: CodexGhostRepairCategoryAAuthorizationReceipt,
        completedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairCategoryARepairExecutionOutcome {
        guard let state = try await journal.operation(
            operationID: binding.operationID
        ) else {
            throw PersistentStateError.invalidRecord(
                "Authorized Category A operation is missing."
            )
        }
        if let report = state.report { return try completed(report) }
        guard state.receipt == receipt else {
            throw PersistentStateError.invalidRecord(
                "Authorized Category A receipt drifted."
            )
        }
        guard let claim = state.claim else {
            return try await terminal(
                binding: binding,
                receipt: receipt,
                claim: nil,
                outcome: .notAttempted,
                mutationAttemptedOnce: false,
                completedAtMilliseconds: completedAtMilliseconds
            )
        }
        return try await recoverClaimed(
            binding: binding,
            receipt: receipt,
            claim: claim,
            completedAtMilliseconds: completedAtMilliseconds
        )
    }

    private func recoverClaimed(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        receipt: CodexGhostRepairCategoryAAuthorizationReceipt,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence,
        completedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairCategoryARepairExecutionOutcome {
        let observed: CodexGhostRepairCategoryARepairExecutionObservation
        do {
            observed = try await mutator.recoverByReadback(
                binding: binding,
                claim: claim
            )
        } catch {
            observed = .init(outcome: .unknown, mutationAttemptedOnce: true)
        }
        return try await terminal(
            binding: binding,
            receipt: receipt,
            claim: claim,
            outcome: observed.outcome,
            mutationAttemptedOnce: observed.mutationAttemptedOnce,
            completedAtMilliseconds: completedAtMilliseconds
        )
    }

    private func terminal(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        receipt: CodexGhostRepairCategoryAAuthorizationReceipt,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence?,
        outcome: CodexGhostRepairCategoryABatchOutcome,
        mutationAttemptedOnce: Bool,
        completedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairCategoryARepairExecutionOutcome {
        let report = try CodexGhostRepairCategoryAExecutionPreparation
            .terminalReport(
                challenge: binding.challenge,
                receipt: receipt,
                claim: claim,
                outcome: outcome,
                mutationAttemptedOnce: mutationAttemptedOnce,
                completedAtMilliseconds: completedAtMilliseconds
            )
        return try completed(try await journal.finalize(report))
    }

    private func completed(
        _ report: CodexGhostRepairCategoryAExecutionTerminalReport
    ) throws -> CodexGhostRepairCategoryARepairExecutionOutcome {
        try report.validateDigest()
        let publicOutcome = Self.publicOutcome(report.outcome)
        return .completed(try .init(
            operationID: report.operationID,
            outcome: publicOutcome,
            itemOutcomes: zip(
                report.targetThreadIDs,
                report.itemOutcomes
            ).map { threadID, outcome in
                .init(
                    threadID: threadID,
                    outcome: Self.publicOutcome(outcome)
                )
            },
            reportDigest: report.reportDigest
        ))
    }

    private func unavailable(
        _ message: String
    ) -> CodexGhostRepairCategoryARepairExecutionOutcome {
        .unavailable(message: message)
    }

    private static func matches(
        _ publicChallenge: CodexGhostRepairCategoryARepairChallenge,
        binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) -> Bool {
        let challenge = binding.challenge
        return publicChallenge.operationID == binding.operationID
            && publicChallenge.savedPreviewRequestID
                == binding.savedPreviewRequestID
            && publicChallenge.snapshotReference == binding.snapshotReference
            && publicChallenge.snapshotManifestHash
                == binding.snapshotManifestHash
            && publicChallenge.snapshotSourceFingerprintHash
                == binding.snapshotSourceFingerprintHash
            && publicChallenge.preparedBindingDigest == binding.bindingDigest
            && publicChallenge.targetThreadIDs == challenge.targetThreadIDs
            && publicChallenge.buildIdentifier == challenge.buildIdentifier
            && publicChallenge.draftDigest == challenge.draftDigest
            && publicChallenge.reviewDigest == challenge.reviewDigest
            && publicChallenge.challengeDigest == challenge.challengeDigest
            && publicChallenge.confirmationToken
                == challenge.confirmationToken
            && Int64(publicChallenge.generatedAt.timeIntervalSince1970 * 1_000)
                == challenge.generatedAtMilliseconds
            && Int64(publicChallenge.expiresAt.timeIntervalSince1970 * 1_000)
                == challenge.expiresAtMilliseconds
    }

    private static func publicOutcome(
        _ outcome: CodexGhostRepairCategoryABatchOutcome
    ) -> CodexGhostRepairCategoryARepairObservedOutcome {
        switch outcome {
        case .success: .success
        case .explicitFailure: .explicitFailure
        case .unknown: .unknown
        case .notAttempted: .notAttempted
        }
    }

    private static func publicOutcome(
        _ outcome: CodexGhostRepairCategoryAItemOutcome
    ) -> CodexGhostRepairCategoryARepairObservedOutcome {
        switch outcome {
        case .success: .success
        case .alreadyAbsent: .success
        case .explicitFailure: .explicitFailure
        case .unknown: .unknown
        case .notAttempted: .notAttempted
        }
    }
}

enum CodexGhostRepairCategoryARepairExecutionCoordinatorFactory {
    /// Shipping production composition. Construction is caller-path-free and
    /// zero-I/O. Every read and the one possible Desktop transaction remain
    /// behind an explicit App review followed by an exact confirmation.
    static func packagedProduction(
        appServerConfiguration: CodexAppServerConfiguration = .init()
    ) -> any CodexGhostRepairCategoryARepairCoordinator {
        let reviewCollector =
            CodexGhostRepairCategoryAProductionReviewMaterialCollector
                .production(
                    appServerConfiguration: appServerConfiguration
                )
        return CodexGhostRepairCategoryARepairExecutionCoordinator(
            reviewCoordinator:
                CodexGhostRepairCategoryARepairReviewCoordinatorFactory
                    .packagedReviewOnly(
                        reviewCollector: reviewCollector
                    ),
            journal:
                CodexGhostRepairCategoryAPackagedExecutionJournal
                    .production(),
            freshCollector:
                CodexGhostRepairCategoryAProductionFreshExecutionCollector(
                    reviewCollector: reviewCollector
                ),
            mutator: CodexGhostRepairCategoryAProductionMutator.production()
        )
    }
}
