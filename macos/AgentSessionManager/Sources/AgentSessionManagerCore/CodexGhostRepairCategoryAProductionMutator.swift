import CSQLite3
import Darwin
import Foundation

enum CodexGhostRepairCategoryAProductionMutationFault: Sendable {
    case none
    case explicitBusyBeforeTransaction
    case afterCommitBeforeReadback
}

struct CodexGhostRepairCategoryAProductionMutatorCapabilities:
    Equatable,
    Sendable
{
    let acceptsCallerPath = false
    let maximumTargetCount = 2
    let categoryAOnly = true
    let fixedDatabaseGroupCount = 5
    let desktopWriteDatabaseCount = 1
    let readbackOnlyDatabaseCount = 4
    let requiresDurableExternalClaim = true
    let requiresExactSnapshotFingerprint = true
    let requiresFreshOperationalGate = true
    let automaticRetryAllowed = false
    let automaticRestoreAllowed = false
}

struct CodexGhostRepairCategoryARepairSnapshotBaseline: Sendable {
    let sourceFingerprintHash: String
    let manifestHash: String
    let files: [CodexGhostRepairSnapshotPublishedFileEvidence]
}

protocol CodexGhostRepairCategoryARepairSnapshotBaselineResolving: Sendable {
    func baseline(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) async throws -> CodexGhostRepairCategoryARepairSnapshotBaseline
}

struct CodexGhostRepairCategoryAProductionSnapshotBaselineResolver:
    CodexGhostRepairCategoryARepairSnapshotBaselineResolving,
    Sendable
{
    private let destination: CodexGhostRepairSnapshotPreparedDestination
    private let journal: CodexGhostRepairSnapshotAcquisitionJournal

    static func production() -> Self {
        let destination = CodexGhostRepairSnapshotPreparedDestination.production()
        return Self(
            destination: destination,
            journal: .production(destination: destination)
        )
    }

    init(
        destination: CodexGhostRepairSnapshotPreparedDestination,
        journal: CodexGhostRepairSnapshotAcquisitionJournal
    ) {
        self.destination = destination
        self.journal = journal
    }

    func baseline(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) async throws -> CodexGhostRepairCategoryARepairSnapshotBaseline {
        let destinationBinding = try await destination.bindPrepared()
        guard destinationBinding.bindingHash
                == binding.draft.snapshotDestinationBindingHash,
              let snapshotID = UUID(uuidString: binding.snapshotReference),
              snapshotID.uuidString.lowercased()
                == binding.snapshotReference.lowercased() else {
            throw CodexGhostRepairError.targetDrift(
                "Category A published snapshot destination drifted."
            )
        }
        let acquisition = try await journal.readback(
            snapshotID: snapshotID,
            destinationBinding: destinationBinding
        )
        guard acquisition.targetThreadIDs == binding.draft.targetThreadIDs,
              acquisition.sourceFingerprintHash
                == binding.snapshotSourceFingerprintHash,
              acquisition.destinationBindingHash
                == binding.draft.snapshotDestinationBindingHash,
              acquisition.recordHash
                == binding.draft.snapshotAcquisitionRecordHash else {
            throw CodexGhostRepairError.targetDrift(
                "Category A published snapshot acquisition drifted."
            )
        }
        let location = try await destination.location(for: destinationBinding)
        let access = try CodexGhostRepairSnapshotPublishedInventoryCollector
            .analysisAccess(
                snapshotID: snapshotID,
                acquisition: acquisition,
                binding: destinationBinding,
                location: location
            )
        guard access.manifest.manifestHash == binding.snapshotManifestHash,
              access.manifest.sourceFingerprintHash
                == binding.snapshotSourceFingerprintHash,
              access.publishedEvidence.publicationReceiptHash
                == binding.draft.snapshotPublicationReceiptHash else {
            throw CodexGhostRepairError.targetDrift(
                "Category A published snapshot identity drifted."
            )
        }
        return .init(
            sourceFingerprintHash: access.manifest.sourceFingerprintHash,
            manifestHash: access.manifest.manifestHash,
            files: access.manifest.files
        )
    }
}

private struct CodexGhostRepairCategoryAProductionMutationItem:
    Equatable,
    Sendable
{
    let threadID: String
    let catalogRowDigest: String?
}

private struct CodexGhostRepairCategoryAProductionDesktopState:
    Equatable,
    Sendable
{
    let items: [CodexGhostRepairCategoryAProductionMutationItem]
    let authority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence
    let schemaVersion: Int32
    let integrityPassed: Bool
    let foreignKeyViolationCount: Int
}

/// Shipping-internal, no-path Category A mutator. Construction performs no
/// I/O. The only write path is reached after the external manager journal has
/// durably consumed one confirmation and created one exact claim.
actor CodexGhostRepairCategoryAProductionMutator:
    CodexGhostRepairCategoryARepairMutating
{
    static let capabilities =
        CodexGhostRepairCategoryAProductionMutatorCapabilities()

    private let bundle: CodexGhostRepairProductionRepairBundle
    private let source: CodexGhostRepairSnapshotCanonicalSource
    private let gateSource: any CodexGhostRepairExecutionGateSource
    private let baselineResolver:
        any CodexGhostRepairCategoryARepairSnapshotBaselineResolving
    private let fault: CodexGhostRepairCategoryAProductionMutationFault

    static func production() -> Self {
        Self(
            bundle: .production(),
            source: .production(),
            gateSource: CodexGhostRepairSnapshotOperationalGateSource
                .production(),
            baselineResolver:
                CodexGhostRepairCategoryAProductionSnapshotBaselineResolver
                    .production(),
            fault: .none
        )
    }

    init(
        bundle: CodexGhostRepairProductionRepairBundle,
        source: CodexGhostRepairSnapshotCanonicalSource,
        gateSource: any CodexGhostRepairExecutionGateSource,
        baselineResolver:
            any CodexGhostRepairCategoryARepairSnapshotBaselineResolving,
        fault: CodexGhostRepairCategoryAProductionMutationFault = .none
    ) {
        self.bundle = bundle
        self.source = source
        self.gateSource = gateSource
        self.baselineResolver = baselineResolver
        self.fault = fault
    }

    func executeOnce(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) async throws -> CodexGhostRepairCategoryARepairExecutionObservation {
        try Self.validate(binding: binding, claim: claim)
        let baseline = try await baselineResolver.baseline(binding: binding)
        guard baseline.sourceFingerprintHash
                == binding.snapshotSourceFingerprintHash,
              baseline.manifestHash == binding.snapshotManifestHash else {
            return .init(outcome: .notAttempted, mutationAttemptedOnce: false)
        }
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .init(outcome: .notAttempted, mutationAttemptedOnce: false)
        }

        let frozenFingerprint = try source.fingerprint()
        try frozenFingerprint.validateHash()
        guard frozenFingerprint.fingerprintHash
                == binding.snapshotSourceFingerprintHash else {
            return .init(outcome: .notAttempted, mutationAttemptedOnce: false)
        }

        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .init(outcome: .notAttempted, mutationAttemptedOnce: false)
        }
        let resolution = try bundle.resolveForPreflight()
        let desktopURL = resolution.databaseURL(for: .desktop)

        do {
            if fault == .explicitBusyBeforeTransaction {
                throw CodexGhostRepairError.sqlite(
                    operation: "begin",
                    code: SQLITE_BUSY,
                    message: "Deterministic production-mutator busy fault."
                )
            }
            let database = try CodexGhostRepairProductionSQLite(
                url: desktopURL,
                readOnly: false
            )
            defer { database.close() }
            try database.execute("BEGIN IMMEDIATE")
            do {
                let transactionBefore = try Self.inspect(
                    database: database,
                    targetThreadIDs: binding.draft.targetThreadIDs
                )
                guard Self.matchesBefore(
                    transactionBefore,
                    binding: binding,
                    claim: claim
                ) else {
                    try database.execute("ROLLBACK")
                    return .init(
                        outcome: .notAttempted,
                        mutationAttemptedOnce: false
                    )
                }
                try Self.apply(
                    database: database,
                    binding: binding,
                    claim: claim
                )
                let transactionAfter = try Self.inspect(
                    database: database,
                    targetThreadIDs: binding.draft.targetThreadIDs
                )
                guard Self.matchesAfter(
                    transactionAfter,
                    before: transactionBefore,
                    binding: binding
                ) else {
                    throw CodexGhostRepairError.targetDrift(
                        "Category A transaction readback was not exact."
                    )
                }
                try database.execute("COMMIT")
            } catch {
                try? database.execute("ROLLBACK")
                throw error
            }
            if fault == .afterCommitBeforeReadback {
                throw CodexGhostRepairError.injectedInterruption
            }
        } catch {
            return try await classifyByReadback(
                binding: binding,
                claim: claim,
                baseline: baseline,
                mutationAttemptedOnce: true
            )
        }

        return try await classifyByReadback(
            binding: binding,
            claim: claim,
            baseline: baseline,
            mutationAttemptedOnce: true
        )
    }

    func recoverByReadback(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) async throws -> CodexGhostRepairCategoryARepairExecutionObservation {
        try Self.validate(binding: binding, claim: claim)
        let baseline = try await baselineResolver.baseline(binding: binding)
        return try await classifyByReadback(
            binding: binding,
            claim: claim,
            baseline: baseline,
            mutationAttemptedOnce: true
        )
    }

    private func classifyByReadback(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence,
        baseline: CodexGhostRepairCategoryARepairSnapshotBaseline,
        mutationAttemptedOnce: Bool
    ) async throws -> CodexGhostRepairCategoryARepairExecutionObservation {
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .init(
                outcome: .unknown,
                mutationAttemptedOnce: mutationAttemptedOnce
            )
        }
        let resolution = try bundle.resolveForPreflight()
        let database = try CodexGhostRepairProductionSQLite(
            url: resolution.databaseURL(for: .desktop),
            readOnly: true
        )
        let observed: CodexGhostRepairCategoryAProductionDesktopState
        do {
            observed = try Self.inspect(
                database: database,
                targetThreadIDs: binding.draft.targetThreadIDs
            )
        } catch {
            database.close()
            throw error
        }
        database.close()
        let afterFingerprint = try source.fingerprint()
        try afterFingerprint.validateHash()
        guard Self.readbackOnlyFilesUnchanged(
            baseline: baseline,
            after: afterFingerprint
        ) else {
            return .init(
                outcome: .unknown,
                mutationAttemptedOnce: mutationAttemptedOnce
            )
        }
        guard try await gateSource.ghostRepairExecutionGate().isClear else {
            return .init(
                outcome: .unknown,
                mutationAttemptedOnce: mutationAttemptedOnce
            )
        }
        if Self.matchesAfter(
            observed,
            beforeAuthority: claim.freshEvidence.freshAuthority,
            binding: binding
        ) {
            return .init(
                outcome: .success,
                mutationAttemptedOnce: mutationAttemptedOnce
            )
        }
        if Self.matchesBefore(observed, binding: binding, claim: claim) {
            return .init(
                outcome: mutationAttemptedOnce ? .explicitFailure : .notAttempted,
                mutationAttemptedOnce: mutationAttemptedOnce
            )
        }
        return .init(
            outcome: .unknown,
            mutationAttemptedOnce: mutationAttemptedOnce
        )
    }

    private static func validate(
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) throws {
        try binding.validateDigest()
        try claim.validateDigest()
        let draft = binding.draft
        guard claim.operationID == binding.operationID,
              claim.draftDigest == draft.draftDigest,
              claim.executionSnapshotManifestHash
                == binding.snapshotManifestHash,
              claim.freshEvidence.items == draft.itemChanges.map({
                  .init(
                      threadID: $0.threadID,
                      catalogRowDigest: $0.catalogRowDigest
                  )
              }),
              claim.freshEvidence.databaseExpectations
                == draft.databaseExpectations,
              claim.freshEvidence.protectionComplete,
              claim.freshEvidence.operationalGateClear,
              draft.category == .ordinary,
              (1...capabilities.maximumTargetCount).contains(
                  draft.targetThreadIDs.count
              ),
              draft.targetThreadIDs == draft.targetThreadIDs.sorted(),
              Set(draft.targetThreadIDs).count == draft.targetThreadIDs.count,
              draft.itemChanges.map(\.threadID) == draft.targetThreadIDs,
              draft.itemChanges.allSatisfy({
                  $0.effect == .init(
                      kind: .removeCatalogRow,
                      threadID: $0.threadID,
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
              draft.databaseExpectations.count
                == capabilities.fixedDatabaseGroupCount,
              draft.databaseExpectations.filter({
                  $0.role == .futureSingleTransactionMutation
              }).map(\.database) == [.desktop],
              draft.allOrNothing,
              !draft.silentSelectionShrinkAllowed,
              !draft.partialLogicalOutcomeAllowed else {
            throw CodexGhostRepairError.invalidPlan(
                "Production mutator requires one exact claimed Category A scope."
            )
        }
    }

    private static func inspect(
        database: CodexGhostRepairProductionSQLite,
        targetThreadIDs: [String]
    ) throws -> CodexGhostRepairCategoryAProductionDesktopState {
        let items = try targetThreadIDs.map { threadID in
            let rows = try database.query(
                "SELECT * FROM local_thread_catalog "
                    + "WHERE thread_id = ? ORDER BY host_id",
                bindings: [.text(threadID)],
                maximumRows: 2
            )
            guard rows.count <= 1 else {
                throw CodexGhostRepairError.invalidDatabaseContract(
                    "Category A catalog multiplicity exceeded one."
                )
            }
            return CodexGhostRepairCategoryAProductionMutationItem(
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
        let metadataRows = try database.query(
            "SELECT * FROM local_thread_catalog_metadata WHERE id = 1",
            maximumRows: 2
        )
        let syncRows = try database.query(
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
                "Category A authority rows are unavailable."
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
                "Category A watermark evidence is invalid."
            )
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
            schemaVersion: try database.schemaVersion(),
            integrityPassed: try database.integrityPassed(),
            foreignKeyViolationCount: try database.foreignKeyViolationCount()
        )
    }

    private static func matchesBefore(
        _ state: CodexGhostRepairCategoryAProductionDesktopState,
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) -> Bool {
        guard state.items == binding.draft.itemChanges.map({
                  .init(
                      threadID: $0.threadID,
                      catalogRowDigest: $0.catalogRowDigest
                  )
              }),
              state.authority == claim.freshEvidence.freshAuthority,
              state.integrityPassed,
              state.foreignKeyViolationCount == 0 else {
            return false
        }
        return binding.draft.databaseExpectations.first(where: {
            $0.database == .desktop
        })?.admittedSchemaVersion == state.schemaVersion
    }

    private static func matchesAfter(
        _ state: CodexGhostRepairCategoryAProductionDesktopState,
        before: CodexGhostRepairCategoryAProductionDesktopState,
        binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) -> Bool {
        matchesAfter(
            state,
            beforeAuthority: before.authority,
            binding: binding
        ) && state.schemaVersion == before.schemaVersion
    }

    private static func matchesAfter(
        _ state: CodexGhostRepairCategoryAProductionDesktopState,
        beforeAuthority: CodexGhostRepairSnapshotAnalysisAuthorityEvidence,
        binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) -> Bool {
        let increment = Int64(binding.draft.targetThreadIDs.count)
        return state.items == binding.draft.targetThreadIDs.map {
            .init(threadID: $0, catalogRowDigest: nil)
        }
            && state.authority.catalogRevision
                == beforeAuthority.catalogRevision + increment
            && state.authority.observationSequence
                == beforeAuthority.observationSequence + increment
            && state.authority.watermarkUpdatedAt
                == beforeAuthority.watermarkUpdatedAt
            && state.integrityPassed
            && state.foreignKeyViolationCount == 0
            && binding.draft.databaseExpectations.first(where: {
                $0.database == .desktop
            })?.admittedSchemaVersion == state.schemaVersion
    }

    private static func apply(
        database: CodexGhostRepairProductionSQLite,
        binding: CodexGhostRepairCategoryAPreparedRepairBinding,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) throws {
        for threadID in binding.draft.targetThreadIDs {
            try database.execute(
                "DELETE FROM local_thread_catalog "
                    + "WHERE host_id = 'local' AND thread_id = ?",
                bindings: [.text(threadID)]
            )
            guard database.changeCount == 1 else {
                throw CodexGhostRepairError.targetDrift(
                    "Category A exact catalog row count drifted."
                )
            }
        }
        let increment = Int64(binding.draft.targetThreadIDs.count)
        let authority = claim.freshEvidence.freshAuthority
        try database.execute(
            "UPDATE local_thread_catalog_metadata "
                + "SET catalog_revision = ? "
                + "WHERE id = 1 AND catalog_revision = ?",
            bindings: [
                .integer(authority.catalogRevision + increment),
                .integer(authority.catalogRevision),
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
                .integer(authority.observationSequence + increment),
                .integer(authority.observationSequence),
            ]
        )
        guard database.changeCount == 1 else {
            throw CodexGhostRepairError.authorityDrift
        }
    }

    private static func readbackOnlyFilesUnchanged(
        baseline: CodexGhostRepairCategoryARepairSnapshotBaseline,
        after: CodexGhostRepairSnapshotCanonicalFingerprint
    ) -> Bool {
        let desktopFiles: Set<String> = [
            CodexGhostRepairSnapshotCanonicalFile.desktop.rawValue,
            CodexGhostRepairSnapshotCanonicalFile.desktopWAL.rawValue,
            CodexGhostRepairSnapshotCanonicalFile.desktopSHM.rawValue,
            CodexGhostRepairSnapshotCanonicalFile.desktopJournal.rawValue,
        ]
        let expected = baseline.files.filter {
            !desktopFiles.contains($0.fileName)
        }.map {
            ($0.fileName, $0.exists, $0.size, $0.sha256)
        }
        let observed = after.files.filter {
            !desktopFiles.contains($0.fileName)
        }.map {
            ($0.fileName, $0.exists, $0.size, $0.sha256)
        }
        return expected.elementsEqual(observed, by: ==)
    }
}

enum CodexGhostRepairProductionSQLiteBinding {
    case integer(Int64)
    case text(String)
}

final class CodexGhostRepairProductionSQLite {
    private var database: OpaquePointer?

    /// No filesystem path is accepted: compatibility probes use synthetic rows only.
    init(inMemory: Void) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(":memory:", &pointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw CodexCompatibilityInspector.CheckError.unavailable
        }
        database = pointer
    }

    init(url: URL, readOnly: Bool) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Fixed Codex database is unavailable."
            )
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Fixed Codex database is not a regular file."
            )
        }
        guard status.st_uid == geteuid() else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Fixed Codex database is not owned by the current user."
            )
        }
        guard status.st_nlink == 1 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Fixed Codex database has \(status.st_nlink) hard links; "
                    + "exactly one is required."
            )
        }
        guard status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            let permissions = String(
                format: "%03o",
                status.st_mode & mode_t(0o777)
            )
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Fixed Codex database is writable by group or other "
                    + "accounts (mode \(permissions))."
            )
        }
        var pointer: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE)
            | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let result = sqlite3_open_v2(url.path, &pointer, flags, nil)
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw CodexGhostRepairError.sqlite(
                operation: "open",
                code: result,
                message: "Fixed Desktop database open failed."
            )
        }
        database = pointer
        guard sqlite3_busy_timeout(pointer, 50) == SQLITE_OK else {
            close()
            throw CodexGhostRepairError.sqlite(
                operation: "busy-timeout",
                code: SQLITE_ERROR,
                message: "Desktop database busy timeout setup failed."
            )
        }
    }

    var changeCount: Int32 { database.map(sqlite3_changes) ?? 0 }

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
                "Desktop schema version is unavailable."
            )
        }
        return Int32(value)
    }

    func integrityPassed() throws -> Bool {
        let rows = try query("PRAGMA integrity_check", maximumRows: 2)
        return rows.count == 1
            && rows[0].fields.first?.value == .text("ok")
    }

    func foreignKeyViolationCount() throws -> Int {
        try query("PRAGMA foreign_key_check", maximumRows: 1).count
    }

    func execute(
        _ sql: String,
        bindings: [CodexGhostRepairProductionSQLiteBinding] = []
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
        bindings: [CodexGhostRepairProductionSQLiteBinding] = [],
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
                        "Desktop SQLite value type is unsupported."
                    )
                }
                fields.append(.init(name: name, value: value))
            }
            rows.append(.init(fields: fields))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw CodexGhostRepairError.invalidDatabaseContract(
                "Desktop database is closed."
            )
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw sqliteError(operation: "prepare")
        }
        return statement
    }

    private func bind(
        _ bindings: [CodexGhostRepairProductionSQLiteBinding],
        to statement: OpaquePointer
    ) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .text(value):
                result = value.withCString {
                    sqlite3_bind_text(
                        statement,
                        index,
                        $0,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
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
            return .invalidDatabaseContract(
                "Desktop database error is unavailable."
            )
        }
        return .sqlite(
            operation: operation,
            code: sqlite3_errcode(database),
            message: "Desktop database operation failed."
        )
    }
}
