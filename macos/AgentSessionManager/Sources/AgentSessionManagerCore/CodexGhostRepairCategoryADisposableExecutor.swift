import CryptoKit
import CSQLite3
import Darwin
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH

enum CodexGhostRepairCategoryADisposableFault: Sendable {
    case none
    case explicitBusyBeforeTransaction
    case afterClaim
    case afterCommitBeforeReport
}

struct CodexGhostRepairCategoryADisposableExecutorCapabilities:
    Equatable,
    Sendable
{
    let testOwnedDisposableCopiesOnly = true
    let maximumTargetCount = 2
    let categoryAOnly = true
    let exactDesktopTransaction = true
    let readbackOnlyDatabaseCount = 4
    let durableClaimBeforeMutation = true
    let durableReportReadback = true
    let replaysMutation = false
    let retriesUnknown = false
    let acceptsLiveCodexRoot = false
    let appWiringAvailable = false
    let packagedRepairAuthority = false
}

struct CodexGhostRepairCategoryADisposableItemState:
    Codable,
    Hashable,
    Sendable
{
    let threadID: String
    let catalogRowDigest: String?
}

struct CodexGhostRepairCategoryADisposableDatabaseState:
    Codable,
    Hashable,
    Sendable
{
    let database: CodexGhostRepairProductionRepairDatabase
    let present: Bool
    let schemaVersion: Int32?
    let fileHash: String?
}

struct CodexGhostRepairCategoryADisposableState:
    Codable,
    Hashable,
    Sendable
{
    let items: [CodexGhostRepairCategoryADisposableItemState]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let metadataRow: CodexGhostRepairSQLiteRow
    let localSyncRow: CodexGhostRepairSQLiteRow
    let databaseStates:
        [CodexGhostRepairCategoryADisposableDatabaseState]
    let untouchedDesktopSentinelHash: String
}

private struct CodexGhostRepairCategoryADisposableClaim:
    Codable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let draftDigest: String
    let targetThreadIDs: [String]
    let beforeState: CodexGhostRepairCategoryADisposableState
    let claimedAtMilliseconds: Int64
}

private struct CodexGhostRepairCategoryADisposableAttempt:
    Codable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let draftDigest: String
    let claimHash: String
    let attemptedAtMilliseconds: Int64
}

struct CodexGhostRepairCategoryADisposableReportItem:
    Codable,
    Hashable,
    Sendable
{
    let threadID: String
    let outcome: CodexGhostRepairCategoryAItemOutcome
}

struct CodexGhostRepairCategoryADisposableReport:
    Codable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let draftDigest: String
    let completedAtMilliseconds: Int64
    let outcome: CodexGhostRepairCategoryABatchOutcome
    let items: [CodexGhostRepairCategoryADisposableReportItem]
    let durableClaimCreated: Bool
    let mutationAttemptedOnce: Bool
    let recoveredByReadback: Bool
    let readbackOnlyDatabasesUnchanged: Bool
    let automaticRetryAllowed: Bool
    let liveCodexRootAccessed: Bool
    let appRepairAuthority: Bool
}

/// Marker-protected M3c bundle. It intentionally requires a test-owned mirror
/// and derives every database and evidence path from fixed names.
struct CodexGhostRepairCategoryADisposableBundle: Sendable {
    static let markerFileName =
        ".agent-session-manager-m3c-category-a-disposable-v1"
    static let markerContents =
        "Agent Session Manager M3c Category A disposable mirror v1\n"
    static let evidenceDirectoryName = "m3c-category-a-executions"

    let resolution: CodexGhostRepairProductionRepairBundle.Resolution
    let evidenceRootURL: URL

    init(
        testOwnedCodexHomeURL: URL,
        testOwnedAllowedParentURL: URL
    ) throws {
        let codexHome = testOwnedCodexHomeURL.standardizedFileURL
        let allowedParent = testOwnedAllowedParentURL.standardizedFileURL
        let liveCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
        guard codexHome.path != allowedParent.path,
              Self.isDescendant(codexHome, of: allowedParent),
              codexHome.path != liveCodexHome.path,
              !Self.isDescendant(codexHome, of: liveCodexHome) else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M3c disposable root escaped its test-owned boundary."
            )
        }
        let marker = codexHome.appendingPathComponent(Self.markerFileName)
        guard try String(contentsOf: marker, encoding: .utf8)
                == Self.markerContents else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M3c disposable root marker is missing or invalid."
            )
        }
        let resolved = try CodexGhostRepairProductionRepairBundle(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: allowedParent
        ).resolveForPreflight()
        for database in CodexGhostRepairProductionRepairDatabase.allCases
            where database.isRequired {
            try Self.requireOwnerPrivateRegularFile(
                resolved.databaseURL(for: database)
            )
        }
        let evidenceRoot = codexHome.appendingPathComponent(
            Self.evidenceDirectoryName,
            isDirectory: true
        )
        try Self.requireOwnerPrivateDirectory(evidenceRoot)
        resolution = resolved
        evidenceRootURL = evidenceRoot
    }

    fileprivate func paths(for operationID: UUID) -> EvidencePaths {
        let directory = evidenceRootURL.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
        return EvidencePaths(
            directory: directory,
            claim: directory.appendingPathComponent("claim.json"),
            attempt: directory.appendingPathComponent("attempt.json"),
            report: directory.appendingPathComponent("report.json")
        )
    }

    func validateFreshLayout() throws {
        try Self.requireOwnerPrivateDirectory(evidenceRootURL)
        for database in CodexGhostRepairProductionRepairDatabase.allCases {
            let url = resolution.databaseURL(for: database)
            if database.isRequired
                || FileManager.default.fileExists(atPath: url.path) {
                try Self.requireOwnerPrivateRegularFile(url)
            }
        }
    }

    fileprivate struct EvidencePaths {
        let directory: URL
        let claim: URL
        let attempt: URL
        let report: URL
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        child.path.hasPrefix(parent.path + "/")
    }

    private static func requireOwnerPrivateRegularFile(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M3c required fixed database is not an owner-private regular file."
            )
        }
    }

    private static func requireOwnerPrivateDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M3c evidence root is not an owner-private directory."
            )
        }
    }
}

actor CodexGhostRepairCategoryADisposableExecutor {
    static let capabilities =
        CodexGhostRepairCategoryADisposableExecutorCapabilities()

    private let bundle: CodexGhostRepairCategoryADisposableBundle
    private let now: @Sendable () -> Date

    init(
        bundle: CodexGhostRepairCategoryADisposableBundle,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.bundle = bundle
        self.now = now
    }

    func execute(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        executionAuthority:
            CodexGhostRepairSnapshotAnalysisAuthorityEvidence? = nil,
        observedAtMilliseconds: Int64,
        fault: CodexGhostRepairCategoryADisposableFault = .none
    ) throws -> CodexGhostRepairCategoryADisposableReport {
        try validate(draft: draft, observedAtMilliseconds: observedAtMilliseconds)
        try bundle.validateFreshLayout()
        let expectedAuthority = executionAuthority ?? draft.authorityAudit
        let paths = bundle.paths(for: draft.operationID)
        if FileManager.default.fileExists(atPath: paths.report.path) {
            return try validatedReport(
                try readEnvelope(at: paths.report),
                draft: draft
            )
        }
        guard !FileManager.default.fileExists(atPath: paths.directory.path) else {
            throw CodexGhostRepairError.recoveryRequired
        }
        try createExclusiveDirectory(paths.directory)

        let before = try inspect(targetThreadIDs: draft.targetThreadIDs)
        guard matchesInitial(
            before,
            draft: draft,
            expectedAuthority: expectedAuthority
        ) else {
            let report = makeReport(
                draft: draft,
                outcome: .notAttempted,
                durableClaimCreated: false,
                mutationAttemptedOnce: false,
                recoveredByReadback: false,
                readbackOnlyDatabasesUnchanged: true
            )
            try writeEnvelope(report, to: paths.report)
            return report
        }

        let claim = CodexGhostRepairCategoryADisposableClaim(
            operationID: draft.operationID,
            draftDigest: draft.draftDigest,
            targetThreadIDs: draft.targetThreadIDs,
            beforeState: before,
            claimedAtMilliseconds: milliseconds(now())
        )
        try writeEnvelope(claim, to: paths.claim)
        if fault == .afterClaim {
            throw CodexGhostRepairError.injectedInterruption
        }

        let attempt = CodexGhostRepairCategoryADisposableAttempt(
            operationID: draft.operationID,
            draftDigest: draft.draftDigest,
            claimHash: try CodexGhostRepairHasher.hash(claim),
            attemptedAtMilliseconds: milliseconds(now())
        )
        try writeEnvelope(attempt, to: paths.attempt)

        do {
            if fault == .explicitBusyBeforeTransaction {
                throw CodexGhostRepairError.sqlite(
                    operation: "begin",
                    code: SQLITE_BUSY,
                    message: "deterministic disposable busy"
                )
            }
            try apply(draft: draft, claim: claim)
        } catch {
            let observed = try? inspect(
                targetThreadIDs: draft.targetThreadIDs
            )
            let unchanged = observed == claim.beforeState
            let report = makeReport(
                draft: draft,
                outcome: unchanged ? .explicitFailure : .unknown,
                durableClaimCreated: true,
                mutationAttemptedOnce: true,
                recoveredByReadback: true,
                readbackOnlyDatabasesUnchanged:
                    observed.map {
                        readbackOnlyDatabasesUnchanged(
                            before: claim.beforeState,
                            after: $0
                        )
                    } ?? false
            )
            try writeEnvelope(report, to: paths.report)
            return report
        }
        if fault == .afterCommitBeforeReport {
            throw CodexGhostRepairError.injectedInterruption
        }

        let after = try inspect(targetThreadIDs: draft.targetThreadIDs)
        let exactFinal = matchesFinal(
            after,
            draft: draft,
            claim: claim
        )
        let report = makeReport(
            draft: draft,
            outcome: exactFinal ? .success : .unknown,
            durableClaimCreated: true,
            mutationAttemptedOnce: true,
            recoveredByReadback: true,
            readbackOnlyDatabasesUnchanged:
                readbackOnlyDatabasesUnchanged(
                    before: before,
                    after: after
                )
        )
        try writeEnvelope(report, to: paths.report)
        return report
    }

    func recoverByReadback(
        draft: CodexGhostRepairCategoryAExecutionDraft
    ) throws -> CodexGhostRepairCategoryADisposableReport {
        try draft.validateDigest()
        try bundle.validateFreshLayout()
        let paths = bundle.paths(for: draft.operationID)
        if FileManager.default.fileExists(atPath: paths.report.path) {
            return try validatedReport(
                try readEnvelope(at: paths.report),
                draft: draft
            )
        }
        let claim: CodexGhostRepairCategoryADisposableClaim = try readEnvelope(
            at: paths.claim
        )
        guard claim.operationID == draft.operationID,
              claim.draftDigest == draft.draftDigest,
              claim.targetThreadIDs == draft.targetThreadIDs else {
            throw CodexGhostRepairError.invalidPlan(
                "M3c durable claim does not match the exact draft."
            )
        }
        let attempted = FileManager.default.fileExists(atPath: paths.attempt.path)
        if attempted {
            let attempt: CodexGhostRepairCategoryADisposableAttempt =
                try readEnvelope(at: paths.attempt)
            let expectedClaimHash = try CodexGhostRepairHasher.hash(claim)
            guard attempt.operationID == draft.operationID,
                  attempt.draftDigest == draft.draftDigest,
                  attempt.claimHash == expectedClaimHash else {
                throw CodexGhostRepairError.invalidPlan(
                    "M3c durable attempt evidence does not match the claim."
                )
            }
        }

        let observed = try inspect(targetThreadIDs: draft.targetThreadIDs)
        let outcome: CodexGhostRepairCategoryABatchOutcome
        if matchesFinal(observed, draft: draft, claim: claim) {
            outcome = .success
        } else if observed == claim.beforeState {
            outcome = attempted ? .explicitFailure : .notAttempted
        } else {
            outcome = .unknown
        }
        let report = makeReport(
            draft: draft,
            outcome: outcome,
            durableClaimCreated: true,
            mutationAttemptedOnce: attempted,
            recoveredByReadback: true,
            readbackOnlyDatabasesUnchanged:
                readbackOnlyDatabasesUnchanged(
                    before: claim.beforeState,
                    after: observed
                )
        )
        try writeEnvelope(report, to: paths.report)
        return report
    }

    func inspectForProductionRecipe(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        freshEvidence: CodexGhostRepairCategoryAFreshExecutionEvidence
    ) throws -> CodexGhostRepairCategoryADisposableState {
        try draft.validateDigest()
        try freshEvidence.validateDigest()
        let state = try inspect(targetThreadIDs: draft.targetThreadIDs)
        guard freshEvidence.items == state.items.compactMap({ item in
                  item.catalogRowDigest.map {
                      .init(threadID: item.threadID, catalogRowDigest: $0)
                  }
              }),
              freshEvidence.freshAuthority == state.authority,
              freshEvidence.databaseExpectations == draft.databaseExpectations,
              matchesSchemas(state, draft: draft) else {
            throw CodexGhostRepairError.authorityDrift
        }
        return state
    }

    func hasDurableExecutionEvidence(operationID: UUID) -> Bool {
        FileManager.default.fileExists(
            atPath: bundle.paths(for: operationID).directory.path
        )
    }

    private func validate(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        observedAtMilliseconds: Int64
    ) throws {
        try draft.validateDigest()
        guard observedAtMilliseconds >= draft.preparedAtMilliseconds,
              observedAtMilliseconds < draft.expiresAtMilliseconds else {
            throw CodexGhostRepairError.previewExpired
        }
        guard draft.category == .ordinary,
              (1...Self.capabilities.maximumTargetCount).contains(
                  draft.targetThreadIDs.count
              ),
              Set(draft.targetThreadIDs).count == draft.targetThreadIDs.count,
              draft.itemChanges.map(\.threadID) == draft.targetThreadIDs,
              zip(draft.targetThreadIDs, draft.itemChanges).allSatisfy({
                  $0.0 == $0.1.threadID
                      && $0.1.effect == .init(
                          kind: .removeCatalogRow,
                          threadID: $0.0,
                          amount: 1
                      )
              }),
              draft.expectedBatchEffects == [
                  .init(
                      kind: .incrementCatalogRevision,
                      amount: draft.targetThreadIDs.count
                  ),
                  .init(
                      kind: .incrementObservationSequence,
                      amount: draft.targetThreadIDs.count
                  ),
              ],
              draft.databaseExpectations.count == 5,
              draft.databaseExpectations.filter(\.required).count == 4,
              draft.databaseExpectations.filter({
                  $0.role == .futureSingleTransactionMutation
              }).map(\.database) == [.desktop],
              draft.allOrNothing,
              !draft.silentSelectionShrinkAllowed,
              !draft.partialLogicalOutcomeAllowed else {
            throw CodexGhostRepairError.invalidPlan(
                "M3c requires one exact Category A all-or-nothing draft."
            )
        }
    }

    private func validatedReport(
        _ report: CodexGhostRepairCategoryADisposableReport,
        draft: CodexGhostRepairCategoryAExecutionDraft
    ) throws -> CodexGhostRepairCategoryADisposableReport {
        guard report.operationID == draft.operationID,
              report.draftDigest == draft.draftDigest,
              report.items.map(\.threadID) == draft.targetThreadIDs,
              report.items.allSatisfy({
                  $0.outcome == report.outcome.itemOutcome
              }),
              !report.automaticRetryAllowed,
              !report.liveCodexRootAccessed,
              !report.appRepairAuthority else {
            throw CodexGhostRepairError.invalidPlan(
                "M3c durable Report does not match the exact draft."
            )
        }
        return report
    }

    private func matchesInitial(
        _ state: CodexGhostRepairCategoryADisposableState,
        draft: CodexGhostRepairCategoryAExecutionDraft,
        expectedAuthority:
            CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    ) -> Bool {
        guard state.items == draft.itemChanges.map({
                  .init(
                      threadID: $0.threadID,
                      catalogRowDigest: $0.catalogRowDigest
                  )
              }),
              state.authority == expectedAuthority else {
            return false
        }
        return matchesSchemas(state, draft: draft)
    }

    private func matchesSchemas(
        _ state: CodexGhostRepairCategoryADisposableState,
        draft: CodexGhostRepairCategoryAExecutionDraft
    ) -> Bool {
        let observedSchemas = Dictionary(uniqueKeysWithValues:
            state.databaseStates.map { ($0.database, $0.schemaVersion) }
        )
        return draft.databaseExpectations.allSatisfy { expectation in
            if expectation.required {
                observedSchemas[expectation.database]
                    == expectation.admittedSchemaVersion
            } else {
                true
            }
        }
    }

    private func matchesFinal(
        _ state: CodexGhostRepairCategoryADisposableState,
        draft: CodexGhostRepairCategoryAExecutionDraft,
        claim: CodexGhostRepairCategoryADisposableClaim
    ) -> Bool {
        guard state.items == draft.targetThreadIDs.map({
                  .init(threadID: $0, catalogRowDigest: nil)
              }),
              state.databaseStates.map({ ($0.database, $0.schemaVersion) })
                .elementsEqual(
                    claim.beforeState.databaseStates.map {
                        ($0.database, $0.schemaVersion)
                    },
                    by: ==
                ),
              state.untouchedDesktopSentinelHash
                == claim.beforeState.untouchedDesktopSentinelHash,
              readbackOnlyDatabasesUnchanged(
                  before: claim.beforeState,
                  after: state
              ) else {
            return false
        }
        let count = Int64(draft.targetThreadIDs.count)
        guard let expectedMetadata = try? claim.beforeState.metadataRow
                .replacing(
                    "catalog_revision",
                    with: .integer(
                        claim.beforeState.authority.catalogRevision + count
                    )
                ),
              let expectedSync = try? claim.beforeState.localSyncRow.replacing(
                  "observation_sequence",
                  with: .integer(
                      claim.beforeState.authority.observationSequence + count
                  )
              ),
              state.metadataRow == expectedMetadata,
              state.localSyncRow == expectedSync else {
            return false
        }
        return state.authority == .init(
            catalogRevision:
                claim.beforeState.authority.catalogRevision + count,
            observationSequence:
                claim.beforeState.authority.observationSequence + count,
            watermarkUpdatedAt:
                claim.beforeState.authority.watermarkUpdatedAt,
            metadataRowDigest:
                (try? CodexGhostRepairHasher.hash(expectedMetadata)) ?? "",
            localSyncRowDigest:
                (try? CodexGhostRepairHasher.hash(expectedSync)) ?? ""
        )
    }

    private func readbackOnlyDatabasesUnchanged(
        before: CodexGhostRepairCategoryADisposableState,
        after: CodexGhostRepairCategoryADisposableState
    ) -> Bool {
        before.databaseStates.filter { $0.database != .desktop }
            == after.databaseStates.filter { $0.database != .desktop }
    }

    private func makeReport(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        outcome: CodexGhostRepairCategoryABatchOutcome,
        durableClaimCreated: Bool,
        mutationAttemptedOnce: Bool,
        recoveredByReadback: Bool,
        readbackOnlyDatabasesUnchanged: Bool
    ) -> CodexGhostRepairCategoryADisposableReport {
        .init(
            operationID: draft.operationID,
            draftDigest: draft.draftDigest,
            completedAtMilliseconds: milliseconds(now()),
            outcome: outcome,
            items: draft.targetThreadIDs.map {
                .init(threadID: $0, outcome: outcome.itemOutcome)
            },
            durableClaimCreated: durableClaimCreated,
            mutationAttemptedOnce: mutationAttemptedOnce,
            recoveredByReadback: recoveredByReadback,
            readbackOnlyDatabasesUnchanged:
                readbackOnlyDatabasesUnchanged,
            automaticRetryAllowed: false,
            liveCodexRootAccessed: false,
            appRepairAuthority: false
        )
    }

    private func apply(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        claim: CodexGhostRepairCategoryADisposableClaim
    ) throws {
        let database = try M3cSQLite(
            url: bundle.resolution.databaseURL(for: .desktop),
            readOnly: false
        )
        defer { database.close() }
        try database.execute("BEGIN IMMEDIATE")
        do {
            let transactionState = try inspect(
                targetThreadIDs: draft.targetThreadIDs,
                desktopDatabase: database
            )
            guard transactionState == claim.beforeState else {
                throw CodexGhostRepairError.targetDrift(
                    "M3c transaction state drifted from the durable claim."
                )
            }
            for change in draft.itemChanges {
                try database.execute(
                    "DELETE FROM local_thread_catalog "
                        + "WHERE host_id = 'local' AND thread_id = ?",
                    bindings: [.text(change.threadID)]
                )
                guard database.changeCount == 1 else {
                    throw CodexGhostRepairError.targetDrift(
                        "M3c exact catalog row count drifted."
                    )
                }
            }
            let count = Int64(draft.targetThreadIDs.count)
            try database.execute(
                "UPDATE local_thread_catalog_metadata "
                    + "SET catalog_revision = ? "
                    + "WHERE id = 1 AND catalog_revision = ?",
                bindings: [
                    .integer(
                        claim.beforeState.authority.catalogRevision + count
                    ),
                    .integer(claim.beforeState.authority.catalogRevision),
                ]
            )
            guard database.changeCount == 1 else {
                throw CodexGhostRepairError.authorityDrift
            }
            try database.execute(
                "UPDATE local_thread_catalog_sync_state "
                    + "SET observation_sequence = ? "
                    + "WHERE host_id = 'local' AND observation_sequence = ?",
                bindings: [
                    .integer(
                        claim.beforeState.authority.observationSequence + count
                    ),
                    .integer(
                        claim.beforeState.authority.observationSequence
                    ),
                ]
            )
            guard database.changeCount == 1 else {
                throw CodexGhostRepairError.authorityDrift
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private func inspect(
        targetThreadIDs: [String],
        desktopDatabase: M3cSQLite? = nil
    ) throws -> CodexGhostRepairCategoryADisposableState {
        try bundle.validateFreshLayout()
        let ownsDesktop = desktopDatabase == nil
        let desktop = try desktopDatabase ?? M3cSQLite(
            url: bundle.resolution.databaseURL(for: .desktop),
            readOnly: true
        )
        defer { if ownsDesktop { desktop.close() } }

        let items = try targetThreadIDs.map { threadID in
            let rows = try desktop.query(
                "SELECT * FROM local_thread_catalog "
                    + "WHERE thread_id = ? ORDER BY host_id",
                bindings: [.text(threadID)],
                maximumRows: 2
            )
            guard rows.count <= 1 else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "M3c exact catalog row multiplicity exceeded one."
                )
            }
            return CodexGhostRepairCategoryADisposableItemState(
                threadID: threadID,
                catalogRowDigest: try rows.first.map {
                    try CodexGhostRepairHasher.hash(
                        $0.privacyPreserving(
                            cleartextFields: CodexGhostRepairPrivacyContract.catalog
                        )
                    )
                }
            )
        }
        let metadataRows = try desktop.query(
            "SELECT * FROM local_thread_catalog_metadata WHERE id = 1",
            maximumRows: 2
        )
        let syncRows = try desktop.query(
            "SELECT * FROM local_thread_catalog_sync_state "
                + "WHERE host_id = 'local'",
            maximumRows: 2
        )
        guard metadataRows.count == 1,
              syncRows.count == 1,
              case let .integer(catalogRevision)? = metadataRows[0].value(
                  named: "catalog_revision"
              ),
              case let .integer(observationSequence)? = syncRows[0].value(
                  named: "observation_sequence"
              ) else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M3c authority rows are unavailable."
            )
        }
        let metadata = try metadataRows[0].privacyPreserving(
            cleartextFields: CodexGhostRepairPrivacyContract.metadata
        )
        let sync = try syncRows[0].privacyPreserving(
            cleartextFields: CodexGhostRepairPrivacyContract.localSync
        )
        let watermark: Double?
        switch sync.value(named: "watermark_updated_at") {
        case let .integer(value): watermark = Double(value)
        case let .real(value): watermark = value
        case .null: watermark = nil
        default:
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M3c watermark evidence is invalid."
            )
        }
        let sentinel = try desktop.query(
            "SELECT * FROM m3c_untouched_sentinel ORDER BY id",
            maximumRows: 2
        )
        guard sentinel.count == 1 else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M3c disposable sentinel is unavailable."
            )
        }

        var databaseStates:
            [CodexGhostRepairCategoryADisposableDatabaseState] = []
        for database in CodexGhostRepairProductionRepairDatabase.allCases {
            let url = bundle.resolution.databaseURL(for: database)
            let present = FileManager.default.fileExists(atPath: url.path)
            if !present {
                guard !database.isRequired else {
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "M3c required fixed database is missing."
                    )
                }
                databaseStates.append(.init(
                    database: database,
                    present: false,
                    schemaVersion: nil,
                    fileHash: nil
                ))
                continue
            }
            let schema: Int32
            if database == .desktop {
                schema = try desktop.schemaVersion()
            } else {
                let readOnly = try M3cSQLite(url: url, readOnly: true)
                schema = try readOnly.schemaVersion()
                readOnly.close()
            }
            databaseStates.append(.init(
                database: database,
                present: true,
                schemaVersion: schema,
                fileHash: database == .desktop ? nil : try fileHash(url)
            ))
        }
        return .init(
            items: items,
            authority: .init(
                catalogRevision: catalogRevision,
                observationSequence: observationSequence,
                watermarkUpdatedAt: watermark,
                metadataRowDigest: try CodexGhostRepairHasher.hash(metadata),
                localSyncRowDigest: try CodexGhostRepairHasher.hash(sync)
            ),
            metadataRow: metadata,
            localSyncRow: sync,
            databaseStates: databaseStates,
            untouchedDesktopSentinelHash:
                try CodexGhostRepairHasher.hash(sentinel)
        )
    }
}

private struct M3cEnvelope<Payload: Codable & Hashable>:
    Codable,
    Hashable
{
    let payload: Payload
    let payloadHash: String

    init(_ payload: Payload) throws {
        self.payload = payload
        payloadHash = try CodexGhostRepairHasher.hash(payload)
    }
}

private func writeEnvelope<Payload: Codable & Hashable>(
    _ payload: Payload,
    to url: URL
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try writeExclusive(try encoder.encode(M3cEnvelope(payload)), to: url)
    let observed: Payload = try readEnvelope(at: url)
    guard observed == payload else {
        throw CodexGhostRepairError.invalidPlan(
            "M3c durable evidence readback mismatch."
        )
    }
}

private func readEnvelope<Payload: Codable & Hashable>(at url: URL) throws
    -> Payload
{
    var status = stat()
    guard lstat(url.path, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_uid == getuid(),
          status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
        throw CodexGhostRepairError.invalidPlan(
            "M3c durable evidence is not an owner-private regular file."
        )
    }
    let envelope = try JSONDecoder().decode(
        M3cEnvelope<Payload>.self,
        from: Data(contentsOf: url)
    )
    let expectedHash = try CodexGhostRepairHasher.hash(envelope.payload)
    guard envelope.payloadHash == expectedHash else {
        throw CodexGhostRepairError.invalidPlan(
            "M3c durable evidence checksum mismatch."
        )
    }
    return envelope.payload
}

private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
}

private func createExclusiveDirectory(_ url: URL) throws {
    guard mkdir(url.path, S_IRWXU) == 0 else {
        if errno == EEXIST { throw CodexGhostRepairError.recoveryRequired }
        throw CodexGhostRepairError.invalidDisposablePath(
            "M3c could not create its exact operation directory."
        )
    }
    let parent = url.deletingLastPathComponent()
    let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY)
    if descriptor >= 0 {
        _ = fsync(descriptor)
        Darwin.close(descriptor)
    }
}

private func writeExclusive(_ data: Data, to url: URL) throws {
    let descriptor = Darwin.open(
        url.path,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
        if errno == EEXIST { throw CodexGhostRepairError.claimAlreadyExists }
        throw CodexGhostRepairError.invalidDisposablePath(
            "M3c durable evidence creation failed."
        )
    }
    defer { Darwin.close(descriptor) }
    try data.withUnsafeBytes { buffer in
        guard var pointer = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            let count = Darwin.write(descriptor, pointer, remaining)
            guard count > 0 else {
                throw CodexGhostRepairError.invalidDisposablePath(
                    "M3c durable evidence write failed."
                )
            }
            pointer = pointer.advanced(by: count)
            remaining -= count
        }
    }
    guard fsync(descriptor) == 0 else {
        throw CodexGhostRepairError.invalidDisposablePath(
            "M3c durable evidence fsync failed."
        )
    }
    let parent = url.deletingLastPathComponent()
    let directoryDescriptor = Darwin.open(
        parent.path,
        O_RDONLY | O_DIRECTORY
    )
    if directoryDescriptor >= 0 {
        _ = fsync(directoryDescriptor)
        Darwin.close(directoryDescriptor)
    }
}

private func fileHash(_ url: URL) throws -> String {
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
}

private enum M3cBinding {
    case integer(Int64)
    case text(String)
}

private final class M3cSQLite {
    private var database: OpaquePointer?

    init(url: URL, readOnly: Bool) throws {
        var pointer: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE)
            | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &pointer, flags, nil)
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw CodexGhostRepairError.sqlite(
                operation: "open",
                code: result,
                message: "M3c fixed disposable database open failed."
            )
        }
        database = pointer
        guard sqlite3_busy_timeout(pointer, 50) == SQLITE_OK else {
            close()
            throw CodexGhostRepairError.sqlite(
                operation: "busy-timeout",
                code: SQLITE_ERROR,
                message: "M3c busy timeout setup failed."
            )
        }
    }

    var changeCount: Int32 {
        database.map(sqlite3_changes) ?? 0
    }

    func close() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    func schemaVersion() throws -> Int32 {
        let rows = try query("PRAGMA user_version", maximumRows: 2)
        guard rows.count == 1,
              case let .integer(value)? = rows[0].fields.first?.value else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "M3c schema version is unavailable."
            )
        }
        return Int32(value)
    }

    func execute(
        _ sql: String,
        bindings: [M3cBinding] = []
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(operation: "execute")
        }
    }

    func query(
        _ sql: String,
        bindings: [M3cBinding] = [],
        maximumRows: Int
    ) throws -> [CodexGhostRepairSQLiteRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [CodexGhostRepairSQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW, rows.count < maximumRows else {
                throw sqliteError(operation: "query")
            }
            var fields: [CodexGhostRepairSQLiteField] = []
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(
                    cString: sqlite3_column_name(statement, index)
                )
                let value: CodexGhostRepairSQLiteValue
                switch sqlite3_column_type(statement, index) {
                case SQLITE_NULL: value = .null
                case SQLITE_INTEGER:
                    value = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    value = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    value = sqlite3_column_text(statement, index).map {
                        .text(String(cString: $0))
                    } ?? .null
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    value = sqlite3_column_blob(statement, index).map {
                        .blob(Data(bytes: $0, count: count))
                    } ?? .blob(Data())
                default:
                    throw CodexGhostRepairError.invalidDatabaseContract(
                        "M3c SQLite value type is unsupported."
                    )
                }
                fields.append(.init(name: name, value: value))
            }
            rows.append(.init(fields: fields))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw CodexGhostRepairError.sqlite(
                operation: "prepare",
                code: SQLITE_MISUSE,
                message: "M3c database is closed."
            )
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        )
        guard result == SQLITE_OK, let statement else {
            throw sqliteError(operation: "prepare")
        }
        return statement
    }

    private func bind(
        _ bindings: [M3cBinding],
        to statement: OpaquePointer
    ) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .text(value):
                result = value.withCString { pointer in
                    sqlite3_bind_text(
                        statement,
                        index,
                        pointer,
                        -1,
                        unsafeBitCast(
                            -1,
                            to: sqlite3_destructor_type.self
                        )
                    )
                }
            }
            guard result == SQLITE_OK else {
                throw sqliteError(operation: "bind")
            }
        }
    }

    private func sqliteError(operation: String) -> CodexGhostRepairError {
        guard let database else {
            return .sqlite(
                operation: operation,
                code: SQLITE_MISUSE,
                message: "M3c database is closed."
            )
        }
        return .sqlite(
            operation: operation,
            code: sqlite3_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}

#endif
