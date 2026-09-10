import CSQLite3
import Foundation

enum CodexGhostRepairCategoryAExecutionOperationStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case prepared
    case authorized
    case claimed
    case terminal
}

struct CodexGhostRepairCategoryAExecutionOperationState:
    Equatable,
    Sendable
{
    let status: CodexGhostRepairCategoryAExecutionOperationStatus
    let challenge: CodexGhostRepairCategoryAConfirmationChallenge
    let receipt: CodexGhostRepairCategoryAAuthorizationReceipt?
    let claim: CodexGhostRepairCategoryAExecutionClaimEvidence?
    let report: CodexGhostRepairCategoryAExecutionTerminalReport?

    var automaticRetryAllowed: Bool { false }
    var repairMutationAuthority: Bool { false }
}

enum CodexGhostRepairCategoryAAuthorizationConsumeResult:
    Equatable,
    Sendable
{
    case consumed(CodexGhostRepairCategoryAAuthorizationReceipt)
    case existingReceipt(CodexGhostRepairCategoryAAuthorizationReceipt)
    case existingReport(CodexGhostRepairCategoryAExecutionTerminalReport)
}

enum CodexGhostRepairCategoryAExecutionClaimResult:
    Equatable,
    Sendable
{
    case claimed(CodexGhostRepairCategoryAExecutionClaimEvidence)
    case recoveryRequired(CodexGhostRepairCategoryAExecutionClaimEvidence)
    case existingReport(CodexGhostRepairCategoryAExecutionTerminalReport)
}

extension SQLiteStateStore {
    @discardableResult
    func saveCodexGhostRepairCategoryAPreparedBinding(
        _ binding: CodexGhostRepairCategoryAPreparedRepairBinding
    ) throws -> CodexGhostRepairCategoryAPreparedRepairBinding {
        try binding.validateDigest()
        let challenge = binding.challenge
        try validateM3eChallenge(challenge)
        let challengeJSON = try encodeM3e(challenge)
        let challengePayloadHash = try CodexGhostRepairHasher.hash(challenge)
        let bindingJSON = try encodeM3e(binding)
        let bindingPayloadHash = try CodexGhostRepairHasher.hash(binding)

        try withLockedDatabase { database in
            try transaction(database) {
                if let existing = try loadM3eOperation(
                    operationID: binding.operationID,
                    database: database
                ) {
                    guard existing.status == .prepared,
                          existing.challenge == challenge,
                          existing.receipt == nil,
                          existing.claim == nil,
                          existing.report == nil else {
                        throw PersistentStateError.invalidRecord(
                            "Prepared Category A operation already belongs to different evidence."
                        )
                    }
                } else {
                    try execute(
                        """
                        INSERT INTO codex_ghost_repair_category_a_operations (
                            operation_id, status, draft_digest,
                            challenge_digest, expires_at_ms, target_count,
                            payload_json, payload_hash,
                            confirmation_authority,
                            repair_mutation_authority
                        ) VALUES (?, 'prepared', ?, ?, ?, ?, ?, ?, 0, 0)
                        """,
                        values: [
                            .text(binding.operationID.uuidString.lowercased()),
                            .text(challenge.draftDigest),
                            .text(challenge.challengeDigest),
                            .int64(challenge.expiresAtMilliseconds),
                            .int64(Int64(challenge.targetThreadIDs.count)),
                            .text(challengeJSON),
                            .text(challengePayloadHash),
                        ],
                        database: database
                    )
                }

                if let existing = try loadM3iPreparedBinding(
                    operationID: binding.operationID,
                    database: database
                ) {
                    guard existing == binding else {
                        throw PersistentStateError.invalidRecord(
                            "Prepared Category A binding already differs."
                        )
                    }
                    return
                }
                try execute(
                    """
                    INSERT INTO
                        codex_ghost_repair_category_a_prepared_bindings (
                            operation_id, saved_preview_request_id,
                            snapshot_reference, snapshot_manifest_hash,
                            source_fingerprint_hash, binding_digest,
                            payload_json, payload_hash,
                            confirmation_authority,
                            repair_mutation_authority
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
                    """,
                    values: [
                        .text(binding.operationID.uuidString.lowercased()),
                        .text(
                            binding.savedPreviewRequestID.uuidString
                                .lowercased()
                        ),
                        .text(binding.snapshotReference),
                        .text(binding.snapshotManifestHash),
                        .text(binding.snapshotSourceFingerprintHash),
                        .text(binding.bindingDigest),
                        .text(bindingJSON),
                        .text(bindingPayloadHash),
                    ],
                    database: database
                )
            }
        }
        guard let readback = try codexGhostRepairCategoryAPreparedBinding(
            operationID: binding.operationID
        ), readback == binding else {
            throw PersistentStateError.invalidRecord(
                "Prepared Category A binding durable readback did not match."
            )
        }
        return readback
    }

    func codexGhostRepairCategoryAPreparedBinding(
        operationID: UUID
    ) throws -> CodexGhostRepairCategoryAPreparedRepairBinding? {
        try withLockedDatabase { database in
            try loadM3iPreparedBinding(
                operationID: operationID,
                database: database
            )
        }
    }

    @discardableResult
    func saveCodexGhostRepairCategoryAChallenge(
        _ challenge: CodexGhostRepairCategoryAConfirmationChallenge
    ) throws -> CodexGhostRepairCategoryAExecutionOperationState {
        try validateM3eChallenge(challenge)
        let encoded = try encodeM3e(challenge)
        let payloadHash = try CodexGhostRepairHasher.hash(challenge)

        try withLockedDatabase { database in
            try transaction(database) {
                if let existing = try loadM3eOperation(
                    operationID: challenge.operationID,
                    database: database
                ) {
                    guard existing.challenge == challenge else {
                        throw PersistentStateError.invalidRecord(
                            "M3e operation ID already belongs to different evidence."
                        )
                    }
                    return
                }
                try execute(
                    """
                    INSERT INTO codex_ghost_repair_category_a_operations (
                        operation_id, status, draft_digest, challenge_digest,
                        expires_at_ms, target_count, payload_json, payload_hash,
                        confirmation_authority, repair_mutation_authority
                    ) VALUES (?, 'prepared', ?, ?, ?, ?, ?, ?, 0, 0)
                    """,
                    values: [
                        .text(challenge.operationID.uuidString.lowercased()),
                        .text(challenge.draftDigest),
                        .text(challenge.challengeDigest),
                        .int64(challenge.expiresAtMilliseconds),
                        .int64(Int64(challenge.targetThreadIDs.count)),
                        .text(encoded),
                        .text(payloadHash),
                    ],
                    database: database
                )
            }
        }
        return try requiredM3eOperation(challenge.operationID)
    }

    func codexGhostRepairCategoryAOperation(
        operationID: UUID
    ) throws -> CodexGhostRepairCategoryAExecutionOperationState? {
        try withLockedDatabase { database in
            try loadM3eOperation(
                operationID: operationID,
                database: database
            )
        }
    }

    func consumeCodexGhostRepairCategoryAAuthorization(
        operationID: UUID,
        confirmationToken: String,
        confirmedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairCategoryAAuthorizationConsumeResult {
        let result: CodexGhostRepairCategoryAAuthorizationConsumeResult =
            try withLockedDatabase { database in
            try transaction(database) {
                () -> CodexGhostRepairCategoryAAuthorizationConsumeResult in
                guard let existing = try loadM3eOperation(
                    operationID: operationID,
                    database: database
                ) else {
                    throw PersistentStateError.invalidRecord(
                        "M3e confirmation challenge is missing."
                    )
                }
                if let report = existing.report {
                    return .existingReport(report)
                }
                if let receipt = existing.receipt {
                    return .existingReceipt(receipt)
                }
                guard existing.status == .prepared else {
                    throw PersistentStateError.invalidRecord(
                        "M3e challenge is not prepared."
                    )
                }
                let receipt = try CodexGhostRepairCategoryAExecutionPreparation
                    .consumeAuthorization(
                        challenge: existing.challenge,
                        confirmationToken: confirmationToken,
                        confirmedAtMilliseconds: confirmedAtMilliseconds
                    )
                try insertM3eReceipt(receipt, database: database)
                try updateM3eStatus(
                    operationID: operationID,
                    from: .prepared,
                    to: .authorized,
                    database: database
                )
                return .consumed(receipt)
            }
        }
        _ = try requiredM3eOperation(operationID)
        return result
    }

    func claimCodexGhostRepairCategoryAExecution(
        _ claim: CodexGhostRepairCategoryAExecutionClaimEvidence
    ) throws -> CodexGhostRepairCategoryAExecutionClaimResult {
        try claim.validateDigest()
        let result: CodexGhostRepairCategoryAExecutionClaimResult =
            try withLockedDatabase { database in
            try transaction(database) {
                () -> CodexGhostRepairCategoryAExecutionClaimResult in
                guard let existing = try loadM3eOperation(
                    operationID: claim.operationID,
                    database: database
                ) else {
                    throw PersistentStateError.invalidRecord(
                        "M3e authorized operation is missing."
                    )
                }
                if let report = existing.report {
                    return .existingReport(report)
                }
                if let durableClaim = existing.claim {
                    guard durableClaim == claim else {
                        throw PersistentStateError.invalidRecord(
                            "M3e operation already has a different claim."
                        )
                    }
                    return .recoveryRequired(durableClaim)
                }
                let preparedBinding = try loadM3iPreparedBinding(
                    operationID: claim.operationID,
                    database: database
                )
                guard existing.status == .authorized,
                      let receipt = existing.receipt,
                      claim.draftDigest == existing.challenge.draftDigest,
                      claim.receiptDigest == receipt.receiptDigest,
                      claim.freshEvidence.items.map(\.threadID)
                        == existing.challenge.targetThreadIDs,
                      preparedBinding == nil
                        || claim.executionSnapshotManifestHash
                            == preparedBinding?.snapshotManifestHash else {
                    throw PersistentStateError.invalidRecord(
                        "M3e claim does not match the authorized exact operation and backup."
                    )
                }
                try insertM3eClaim(claim, database: database)
                try updateM3eStatus(
                    operationID: claim.operationID,
                    from: .authorized,
                    to: .claimed,
                    database: database
                )
                return .claimed(claim)
            }
        }
        _ = try requiredM3eOperation(claim.operationID)
        return result
    }

    func finalizeCodexGhostRepairCategoryAExecution(
        _ report: CodexGhostRepairCategoryAExecutionTerminalReport
    ) throws {
        try report.validateDigest()
        try withLockedDatabase { database in
            try transaction(database) {
                guard let existing = try loadM3eOperation(
                    operationID: report.operationID,
                    database: database
                ), let receipt = existing.receipt else {
                    throw PersistentStateError.invalidRecord(
                        "M3e authorized operation is missing."
                    )
                }
                if let durableReport = existing.report {
                    guard durableReport == report else {
                        throw PersistentStateError.invalidRecord(
                            "M3e operation already has a different terminal Report."
                        )
                    }
                    return
                }
                guard report.draftDigest == existing.challenge.draftDigest,
                      report.receiptDigest == receipt.receiptDigest,
                      report.targetThreadIDs
                        == existing.challenge.targetThreadIDs else {
                    throw PersistentStateError.invalidRecord(
                        "M3e Report does not match the authorized exact operation."
                    )
                }
                switch existing.status {
                case .authorized:
                    guard existing.claim == nil,
                          report.claimDigest == nil,
                          report.outcome == .notAttempted,
                          !report.mutationAttemptedOnce else {
                        throw PersistentStateError.invalidRecord(
                            "M3e preclaim terminal Report must be notAttempted."
                        )
                    }
                case .claimed:
                    guard let claim = existing.claim,
                          report.claimDigest == claim.claimDigest else {
                        throw PersistentStateError.invalidRecord(
                            "M3e claimed Report does not match its durable claim."
                        )
                    }
                case .prepared, .terminal:
                    throw PersistentStateError.invalidRecord(
                        "M3e operation cannot finalize from its current state."
                    )
                }
                try insertM3eReport(report, database: database)
                try updateM3eStatus(
                    operationID: report.operationID,
                    from: existing.status,
                    to: .terminal,
                    database: database
                )
            }
        }
        let observed = try requiredM3eOperation(report.operationID)
        guard observed.status == .terminal,
              observed.report == report,
              !observed.automaticRetryAllowed,
              !observed.repairMutationAuthority else {
            throw PersistentStateError.invalidRecord(
                "M3e terminal Report durable readback did not match."
            )
        }
    }
}

private extension SQLiteStateStore {
    func loadM3iPreparedBinding(
        operationID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairCategoryAPreparedRepairBinding? {
        let rows = try query(
            """
            SELECT saved_preview_request_id, snapshot_reference,
                   snapshot_manifest_hash, source_fingerprint_hash,
                   binding_digest, payload_json, payload_hash,
                   confirmation_authority, repair_mutation_authority
            FROM codex_ghost_repair_category_a_prepared_bindings
            WHERE operation_id = ?
            """,
            values: [.text(operationID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairCategoryAPreparedRepairBinding in
            let requestIDText = try requiredText(statement, 0)
            let snapshotReference = try requiredText(statement, 1)
            let snapshotManifestHash = try requiredText(statement, 2)
            let sourceFingerprintHash = try requiredText(statement, 3)
            let bindingDigest = try requiredText(statement, 4)
            let encoded = try requiredText(statement, 5)
            let payloadHash = try requiredText(statement, 6)
            let confirmationAuthority = sqlite3_column_int64(statement, 7)
            let repairAuthority = sqlite3_column_int64(statement, 8)
            let binding: CodexGhostRepairCategoryAPreparedRepairBinding =
                try decodeM3e(encoded)
            try binding.validateDigest()
            guard let requestID = UUID(uuidString: requestIDText),
                  binding.operationID == operationID,
                  binding.savedPreviewRequestID == requestID,
                  binding.snapshotReference == snapshotReference,
                  binding.snapshotManifestHash == snapshotManifestHash,
                  binding.snapshotSourceFingerprintHash
                    == sourceFingerprintHash,
                  binding.bindingDigest == bindingDigest,
                  try CodexGhostRepairHasher.hash(binding) == payloadHash,
                  confirmationAuthority == 0,
                  repairAuthority == 0 else {
                throw PersistentStateError.invalidRecord(
                    "Prepared Category A binding columns and payload disagree."
                )
            }
            return binding
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate prepared Category A binding rows."
            )
        }
        return rows.first
    }

    func requiredM3eOperation(
        _ operationID: UUID
    ) throws -> CodexGhostRepairCategoryAExecutionOperationState {
        guard let operation = try codexGhostRepairCategoryAOperation(
            operationID: operationID
        ) else {
            throw PersistentStateError.invalidRecord(
                "M3e durable operation readback is missing."
            )
        }
        return operation
    }

    func validateM3eChallenge(
        _ challenge: CodexGhostRepairCategoryAConfirmationChallenge
    ) throws {
        try challenge.validateDigest()
        guard (1...2).contains(challenge.targetThreadIDs.count),
              challenge.targetThreadIDs == challenge.targetThreadIDs.sorted(),
              Set(challenge.targetThreadIDs).count
                == challenge.targetThreadIDs.count,
              challenge.expiresAtMilliseconds
                > challenge.generatedAtMilliseconds,
              !challenge.confirmationAuthority,
              !challenge.repairMutationAuthority,
              !challenge.filesystemAuthority,
              !challenge.codexSQLiteAuthority else {
            throw PersistentStateError.invalidRecord(
                "M3e confirmation challenge scope is invalid."
            )
        }
    }

    func loadM3eOperation(
        operationID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairCategoryAExecutionOperationState? {
        let rows = try query(
            """
            SELECT status, draft_digest, challenge_digest, expires_at_ms,
                   target_count, payload_json, payload_hash,
                   confirmation_authority, repair_mutation_authority
            FROM codex_ghost_repair_category_a_operations
            WHERE operation_id = ?
            """,
            values: [.text(operationID.uuidString.lowercased())],
            database: database
        ) { statement -> (
            CodexGhostRepairCategoryAExecutionOperationStatus,
            CodexGhostRepairCategoryAConfirmationChallenge
        ) in
            guard let status = CodexGhostRepairCategoryAExecutionOperationStatus(
                rawValue: try requiredText(statement, 0)
            ) else {
                throw PersistentStateError.invalidRecord(
                    "M3e operation status is unknown."
                )
            }
            let draftDigest = try requiredText(statement, 1)
            let challengeDigest = try requiredText(statement, 2)
            let expiresAt = sqlite3_column_int64(statement, 3)
            let targetCount = Int(sqlite3_column_int64(statement, 4))
            let encoded = try requiredText(statement, 5)
            let payloadHash = try requiredText(statement, 6)
            let confirmationAuthority = sqlite3_column_int64(statement, 7)
            let repairAuthority = sqlite3_column_int64(statement, 8)
            let challenge: CodexGhostRepairCategoryAConfirmationChallenge =
                try decodeM3e(encoded)
            try validateM3eChallenge(challenge)
            guard challenge.operationID == operationID,
                  challenge.draftDigest == draftDigest,
                  challenge.challengeDigest == challengeDigest,
                  challenge.expiresAtMilliseconds == expiresAt,
                  challenge.targetThreadIDs.count == targetCount,
                  try CodexGhostRepairHasher.hash(challenge) == payloadHash,
                  confirmationAuthority == 0,
                  repairAuthority == 0 else {
                throw PersistentStateError.invalidRecord(
                    "M3e operation columns and challenge disagree."
                )
            }
            return (status, challenge)
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate M3e operation rows."
            )
        }
        guard let (status, challenge) = rows.first else { return nil }
        let receipt = try loadM3eReceipt(
            operationID: operationID,
            database: database
        )
        let claim = try loadM3eClaim(
            operationID: operationID,
            database: database
        )
        let report = try loadM3eReport(
            operationID: operationID,
            database: database
        )
        let validState: Bool
        switch status {
        case .prepared:
            validState = receipt == nil && claim == nil && report == nil
        case .authorized:
            validState = receipt != nil && claim == nil && report == nil
        case .claimed:
            validState = receipt != nil && claim != nil && report == nil
        case .terminal:
            validState = receipt != nil && report != nil
        }
        guard validState else {
            throw PersistentStateError.invalidRecord(
                "M3e durable operation state is internally inconsistent."
            )
        }
        if let receipt {
            guard receipt.challengeDigest == challenge.challengeDigest,
                  receipt.confirmationTokenHash
                    == (try CodexGhostRepairHasher.hash(
                        challenge.confirmationToken
                    )) else {
                throw PersistentStateError.invalidRecord(
                    "M3e authorization does not match its challenge."
                )
            }
        }
        if let claim, let receipt {
            guard claim.draftDigest == challenge.draftDigest,
                  claim.receiptDigest == receipt.receiptDigest,
                  claim.freshEvidence.items.map(\.threadID)
                    == challenge.targetThreadIDs else {
                throw PersistentStateError.invalidRecord(
                    "M3e execution claim does not match its operation."
                )
            }
        }
        if let report, let receipt {
            guard report.draftDigest == challenge.draftDigest,
                  report.receiptDigest == receipt.receiptDigest,
                  report.targetThreadIDs == challenge.targetThreadIDs else {
                throw PersistentStateError.invalidRecord(
                    "M3e terminal Report does not match its operation."
                )
            }
            if let claim {
                guard report.claimDigest == claim.claimDigest else {
                    throw PersistentStateError.invalidRecord(
                        "M3e terminal Report does not match its claim."
                    )
                }
            } else {
                guard report.claimDigest == nil,
                      report.outcome == .notAttempted,
                      !report.mutationAttemptedOnce else {
                    throw PersistentStateError.invalidRecord(
                        "M3e preclaim Report has an invalid outcome."
                    )
                }
            }
        }
        return .init(
            status: status,
            challenge: challenge,
            receipt: receipt,
            claim: claim,
            report: report
        )
    }

    func insertM3eReceipt(
        _ receipt: CodexGhostRepairCategoryAAuthorizationReceipt,
        database: OpaquePointer
    ) throws {
        try receipt.validateDigest()
        let encoded = try encodeM3e(receipt)
        try execute(
            """
            INSERT INTO codex_ghost_repair_category_a_authorizations (
                operation_id, receipt_digest, confirmed_at_ms,
                payload_json, payload_hash, repair_mutation_authority
            ) VALUES (?, ?, ?, ?, ?, 0)
            """,
            values: [
                .text(receipt.operationID.uuidString.lowercased()),
                .text(receipt.receiptDigest),
                .int64(receipt.confirmedAtMilliseconds),
                .text(encoded),
                .text(try CodexGhostRepairHasher.hash(receipt)),
            ],
            database: database
        )
    }

    func insertM3eClaim(
        _ claim: CodexGhostRepairCategoryAExecutionClaimEvidence,
        database: OpaquePointer
    ) throws {
        let encoded = try encodeM3e(claim)
        try execute(
            """
            INSERT INTO codex_ghost_repair_category_a_execution_claims (
                operation_id, claim_digest, claimed_at_ms,
                payload_json, payload_hash, repair_mutation_authority
            ) VALUES (?, ?, ?, ?, ?, 0)
            """,
            values: [
                .text(claim.operationID.uuidString.lowercased()),
                .text(claim.claimDigest),
                .int64(claim.claimedAtMilliseconds),
                .text(encoded),
                .text(try CodexGhostRepairHasher.hash(claim)),
            ],
            database: database
        )
    }

    func insertM3eReport(
        _ report: CodexGhostRepairCategoryAExecutionTerminalReport,
        database: OpaquePointer
    ) throws {
        let encoded = try encodeM3e(report)
        try execute(
            """
            INSERT INTO codex_ghost_repair_category_a_execution_reports (
                operation_id, report_digest, completed_at_ms, outcome,
                payload_json, payload_hash, automatic_retry_allowed
            ) VALUES (?, ?, ?, ?, ?, ?, 0)
            """,
            values: [
                .text(report.operationID.uuidString.lowercased()),
                .text(report.reportDigest),
                .int64(report.completedAtMilliseconds),
                .text(report.outcome.rawValue),
                .text(encoded),
                .text(try CodexGhostRepairHasher.hash(report)),
            ],
            database: database
        )
    }

    func loadM3eReceipt(
        operationID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairCategoryAAuthorizationReceipt? {
        let rows = try query(
            """
            SELECT receipt_digest, confirmed_at_ms, payload_json, payload_hash,
                   repair_mutation_authority
            FROM codex_ghost_repair_category_a_authorizations
            WHERE operation_id = ?
            """,
            values: [.text(operationID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairCategoryAAuthorizationReceipt in
            let digest = try requiredText(statement, 0)
            let confirmedAt = sqlite3_column_int64(statement, 1)
            let encoded = try requiredText(statement, 2)
            let payloadHash = try requiredText(statement, 3)
            let authority = sqlite3_column_int64(statement, 4)
            let receipt: CodexGhostRepairCategoryAAuthorizationReceipt =
                try decodeM3e(encoded)
            try receipt.validateDigest()
            guard receipt.operationID == operationID,
                  receipt.receiptDigest == digest,
                  receipt.confirmedAtMilliseconds == confirmedAt,
                  try CodexGhostRepairHasher.hash(receipt) == payloadHash,
                  authority == 0 else {
                throw PersistentStateError.invalidRecord(
                    "M3e authorization columns and payload disagree."
                )
            }
            return receipt
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate M3e authorization rows."
            )
        }
        return rows.first
    }

    func loadM3eClaim(
        operationID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairCategoryAExecutionClaimEvidence? {
        let rows = try query(
            """
            SELECT claim_digest, claimed_at_ms, payload_json, payload_hash,
                   repair_mutation_authority
            FROM codex_ghost_repair_category_a_execution_claims
            WHERE operation_id = ?
            """,
            values: [.text(operationID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairCategoryAExecutionClaimEvidence in
            let digest = try requiredText(statement, 0)
            let claimedAt = sqlite3_column_int64(statement, 1)
            let encoded = try requiredText(statement, 2)
            let payloadHash = try requiredText(statement, 3)
            let authority = sqlite3_column_int64(statement, 4)
            let claim: CodexGhostRepairCategoryAExecutionClaimEvidence =
                try decodeM3e(encoded)
            try claim.validateDigest()
            guard claim.operationID == operationID,
                  claim.claimDigest == digest,
                  claim.claimedAtMilliseconds == claimedAt,
                  try CodexGhostRepairHasher.hash(claim) == payloadHash,
                  authority == 0 else {
                throw PersistentStateError.invalidRecord(
                    "M3e claim columns and payload disagree."
                )
            }
            return claim
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate M3e execution claim rows."
            )
        }
        return rows.first
    }

    func loadM3eReport(
        operationID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairCategoryAExecutionTerminalReport? {
        let rows = try query(
            """
            SELECT report_digest, completed_at_ms, outcome, payload_json,
                   payload_hash, automatic_retry_allowed
            FROM codex_ghost_repair_category_a_execution_reports
            WHERE operation_id = ?
            """,
            values: [.text(operationID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairCategoryAExecutionTerminalReport in
            let digest = try requiredText(statement, 0)
            let completedAt = sqlite3_column_int64(statement, 1)
            let outcome = try requiredText(statement, 2)
            let encoded = try requiredText(statement, 3)
            let payloadHash = try requiredText(statement, 4)
            let retry = sqlite3_column_int64(statement, 5)
            let report: CodexGhostRepairCategoryAExecutionTerminalReport =
                try decodeM3e(encoded)
            try report.validateDigest()
            guard report.operationID == operationID,
                  report.reportDigest == digest,
                  report.completedAtMilliseconds == completedAt,
                  report.outcome.rawValue == outcome,
                  try CodexGhostRepairHasher.hash(report) == payloadHash,
                  retry == 0 else {
                throw PersistentStateError.invalidRecord(
                    "M3e Report columns and payload disagree."
                )
            }
            return report
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate M3e terminal Report rows."
            )
        }
        return rows.first
    }

    func updateM3eStatus(
        operationID: UUID,
        from: CodexGhostRepairCategoryAExecutionOperationStatus,
        to: CodexGhostRepairCategoryAExecutionOperationStatus,
        database: OpaquePointer
    ) throws {
        try execute(
            """
            UPDATE codex_ghost_repair_category_a_operations
            SET status = ?
            WHERE operation_id = ? AND status = ?
            """,
            values: [
                .text(to.rawValue),
                .text(operationID.uuidString.lowercased()),
                .text(from.rawValue),
            ],
            database: database
        )
        guard sqlite3_changes(database) == 1 else {
            throw PersistentStateError.invalidRecord(
                "M3e atomic state transition lost its expected source state."
            )
        }
    }

    func encodeM3e<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PersistentStateError.invalidRecord(
                "M3e payload is not valid UTF-8."
            )
        }
        return text
    }

    func decodeM3e<T: Decodable>(_ text: String) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw PersistentStateError.invalidRecord(
                "M3e payload is not valid UTF-8."
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
