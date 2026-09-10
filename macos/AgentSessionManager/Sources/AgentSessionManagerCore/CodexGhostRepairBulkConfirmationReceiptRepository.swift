import CSQLite3
import Foundation

struct CodexGhostRepairBulkStoredReceiptPayload:
    Codable,
    Hashable
{
    let receipt: CodexGhostRepairBulkConfirmationReceipt
}

struct CodexGhostRepairBulkConfirmationReceiptPersistedRow {
    let operationID: UUID
    let receiptID: UUID
    let challengeDigest: String
    let confirmationPhraseHash: String
    let selectedCount: Int
    let confirmedAtMilliseconds: Int64
    let receiptDigest: String
    let encodedPayload: String
    let payloadHash: String
    let confirmationRecorded: Int64
    let repairClaimCreated: Int64
    let repairMutationAuthority: Int64
    let automaticRetryAllowed: Int64

    func decodeValidated(
        savedPreviewRequestID: UUID,
        challenge: CodexGhostRepairBulkConfirmationChallenge
    ) throws -> CodexGhostRepairBulkConfirmationReceipt {
        guard payloadHash == SQLiteStateStore.hashBulkPreviewPayload(
            encodedPayload
        ) else {
            throw PersistentStateError.invalidRecord(
                "Whole-batch receipt payload hash does not match."
            )
        }
        let payload: CodexGhostRepairBulkStoredReceiptPayload =
            try SQLiteStateStore.decodeBulkPreviewPayload(encodedPayload)
        let receipt = payload.receipt
        guard receipt.operationID == operationID,
              receipt.receiptID == receiptID,
              receipt.savedPreviewRequestID == savedPreviewRequestID,
              receipt.challengeDigest == challengeDigest,
              receipt.confirmationPhraseHash == confirmationPhraseHash,
              receipt.selectedCount == selectedCount,
              receipt.confirmedAtMilliseconds
                == confirmedAtMilliseconds,
              receipt.receiptDigest == receiptDigest,
              confirmationRecorded == 1,
              repairClaimCreated == 0,
              repairMutationAuthority == 0,
              automaticRetryAllowed == 0 else {
            throw PersistentStateError.invalidRecord(
                "Whole-batch receipt columns and payload disagree."
            )
        }
        try receipt.validate(challenge: challenge)
        return receipt
    }
}

struct CodexGhostRepairBulkConfirmationConsumption {
    let receipt: CodexGhostRepairBulkConfirmationReceipt
    let newlyConfirmed: Bool
}

public enum CodexGhostRepairBulkConfirmationReceiptCoordinatorFactory {
    /// Construction is zero-I/O. The only effect of an explicit valid call is
    /// one manager-owned confirmation receipt; Codex is never contacted.
    public static func packagedReceiptOnly()
        -> any CodexGhostRepairBulkConfirmationReceiptCoordinating
    {
        CodexGhostRepairBulkConfirmationReceiptLiveCoordinator()
    }
}

public enum CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinatorFactory {
    /// Construction is zero-I/O. The existing manager-owned v19 database is
    /// opened read-only only after one explicit exact challenge-bound request.
    public static func packagedReadOnly()
        -> any CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinating
    {
        CodexGhostRepairBulkConfirmationReceiptRecoveryLiveCoordinator()
    }
}

public actor CodexGhostRepairBulkConfirmationReceiptRecoveryUnavailableCoordinator:
    CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinating
{
    public nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationReceiptRecoveryCapabilities
            .unavailable

    public init() {}

    public func recoverReceipt(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest
    ) async -> CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome {
        .recoveryRequired(
            request: request,
            reason: .unavailable,
            message: "Exact whole-batch confirmation receipt recovery is unavailable. Keep the operation reference and do not retry confirmation."
        )
    }
}

actor CodexGhostRepairBulkConfirmationReceiptRecoveryLiveCoordinator:
    CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationReceiptRecoveryCapabilities
            .packagedReadOnly
    private let databaseURLProvider: @Sendable () throws -> URL
    private let fileExists: @Sendable (String) -> Bool
    private let nowMilliseconds: @Sendable () -> Int64

    init(
        databaseURLProvider: @escaping @Sendable () throws -> URL = {
            try StateStoreLocation.applicationSupportDatabaseURL()
        },
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) {
        self.databaseURLProvider = databaseURLProvider
        self.fileExists = fileExists
        self.nowMilliseconds = nowMilliseconds
    }

    func recoverReceipt(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest
    ) async -> CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome {
        let databaseURL: URL
        do {
            databaseURL = try databaseURLProvider()
        } catch {
            return required(
                request: request,
                reason: .unavailable,
                message: "The manager state database location is unavailable. Keep the operation reference and do not retry confirmation."
            )
        }
        guard fileExists(databaseURL.path) else {
            return required(
                request: request,
                reason: .databaseMissing,
                message: "The manager state database is missing. This does not prove that confirmation was not recorded. Keep the operation reference and do not retry confirmation."
            )
        }
        do {
            let reader = try CodexGhostRepairReadOnlyManagerStateStore(
                databaseURL: databaseURL
            )
            defer { reader.close() }
            guard let evidence = try reader
                .confirmationReceiptRecoveryEvidence(request: request) else {
                return required(
                    request: request,
                    reason: .challengeMissing,
                    message: "The exact saved whole-batch challenge is missing. Keep the operation reference and do not retry confirmation."
                )
            }
            switch evidence {
            case .challengeWithoutReceipt:
                let now = nowMilliseconds()
                guard now >= request.challenge.generatedAtMilliseconds else {
                    return required(
                        request: request,
                        reason: .evidenceInvalid,
                        message: "The recovery clock precedes the exact challenge. Keep the operation reference and do not retry confirmation."
                    )
                }
                if now >= request.challenge.expiresAtMilliseconds {
                    return required(
                        request: request,
                        reason: .challengeExpiredWithoutReceipt,
                        message: "The exact challenge is expired and no durable receipt was found. This recovery result does not authorize another confirmation attempt."
                    )
                }
                return required(
                    request: request,
                    reason: .receiptAbsent,
                    message: "No durable receipt was found for the exact unexpired challenge. This does not authorize another confirmation attempt."
                )
            case let .confirmed(receipt):
                return .confirmed(request: request, receipt: receipt)
            case let .executionJournalPresent(receipt, phase):
                return .executionRecoveryRequired(
                    request: request,
                    receipt: receipt,
                    phase: phase,
                    message: "A \(phase.rawValue) execution journal already owns this confirmed operation. Receipt-only recovery cannot restart Final Review or execution."
                )
            }
        } catch {
            return required(
                request: request,
                reason: .evidenceInvalid,
                message: "The exact challenge or receipt evidence is incomplete, mismatched, or tampered. Keep the operation reference and do not retry confirmation."
            )
        }
    }

    private func required(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest,
        reason: CodexGhostRepairBulkConfirmationReceiptRecoveryReason,
        message: String
    ) -> CodexGhostRepairBulkConfirmationReceiptRecoveryOutcome {
        .recoveryRequired(
            request: request,
            reason: reason,
            message: message
        )
    }
}

public actor CodexGhostRepairBulkConfirmationReceiptUnavailableCoordinator:
    CodexGhostRepairBulkConfirmationReceiptCoordinating
{
    public nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationReceiptCapabilities.unavailable

    public init() {}

    public func confirm(
        savedPreviewRequestID: UUID,
        exactConfirmationPhrase: String
    ) async -> CodexGhostRepairBulkConfirmationReceiptOutcome {
        .rejected(
            requestID: savedPreviewRequestID,
            message: "Whole-batch confirmation is unavailable."
        )
    }
}

actor CodexGhostRepairBulkConfirmationReceiptLiveCoordinator:
    CodexGhostRepairBulkConfirmationReceiptCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationReceiptCapabilities
            .packagedReceiptOnly
    private let databaseURLProvider: @Sendable () throws -> URL
    private let nowMilliseconds: @Sendable () -> Int64

    init(
        databaseURLProvider: @escaping @Sendable () throws -> URL = {
            try StateStoreLocation.applicationSupportDatabaseURL()
        },
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) {
        self.databaseURLProvider = databaseURLProvider
        self.nowMilliseconds = nowMilliseconds
    }

    func confirm(
        savedPreviewRequestID: UUID,
        exactConfirmationPhrase: String
    ) async -> CodexGhostRepairBulkConfirmationReceiptOutcome {
        do {
            let store = try SQLiteStateStore(
                databaseURL: databaseURLProvider()
            )
            defer { store.close() }
            guard try store.codexGhostRepairBulkChallenge(
                savedPreviewRequestID: savedPreviewRequestID
            ) != nil else {
                return .notFound(requestID: savedPreviewRequestID)
            }
            let consumption = try store
                .consumeCodexGhostRepairBulkConfirmation(
                    savedPreviewRequestID: savedPreviewRequestID,
                    exactConfirmationPhrase: exactConfirmationPhrase,
                    confirmedAtMilliseconds: nowMilliseconds()
                )
            guard consumption.receipt.wholeBatchConfirmationRecorded,
                  !consumption.receipt.createsRepairClaim,
                  !consumption.receipt.repairClaimCreated,
                  !consumption.receipt.repairMutationAuthority else {
                return .outcomeUnknown(
                    requestID: savedPreviewRequestID,
                    message: "The saved whole-batch receipt could not be verified at the confirmation-only boundary. Do not retry confirmation."
                )
            }
            return consumption.newlyConfirmed
                ? .confirmed(consumption.receipt)
                : .alreadyConfirmed(consumption.receipt)
        } catch PersistentStateError.confirmationMismatch {
            return .rejected(
                requestID: savedPreviewRequestID,
                message: "The confirmation phrase does not match this whole batch."
            )
        } catch CodexGhostRepairError.previewExpired {
            return .rejected(
                requestID: savedPreviewRequestID,
                message: "The whole-batch confirmation has expired. Build a new Preview."
            )
        } catch {
            return .outcomeUnknown(
                requestID: savedPreviewRequestID,
                message: "The whole-batch confirmation outcome is unknown. Keep this operation reference and do not retry confirmation."
            )
        }
    }
}

extension SQLiteStateStore {
    func consumeCodexGhostRepairBulkConfirmation(
        savedPreviewRequestID: UUID,
        exactConfirmationPhrase: String,
        confirmedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkConfirmationConsumption {
        try withLockedDatabase { database in
            try transaction(database) {
                guard let challenge = try loadCodexGhostRepairBulkChallenge(
                    savedPreviewRequestID: savedPreviewRequestID,
                    database: database
                ) else {
                    throw PersistentStateError.invalidRecord(
                        "Whole-batch challenge is missing."
                    )
                }
                guard exactConfirmationPhrase
                        == challenge.confirmationPhrase else {
                    throw PersistentStateError.confirmationMismatch
                }
                if let existing = try loadCodexGhostRepairBulkReceipt(
                    savedPreviewRequestID: savedPreviewRequestID,
                    database: database
                ) {
                    try existing.validate(challenge: challenge)
                    return .init(
                        receipt: existing,
                        newlyConfirmed: false
                    )
                }
                guard confirmedAtMilliseconds
                        >= challenge.generatedAtMilliseconds,
                      confirmedAtMilliseconds
                        < challenge.expiresAtMilliseconds else {
                    throw CodexGhostRepairError.previewExpired
                }
                let receipt = try CodexGhostRepairBulkConfirmationReceipt(
                    receiptID: UUID(),
                    challenge: challenge,
                    confirmedAtMilliseconds: confirmedAtMilliseconds
                )
                let payload = CodexGhostRepairBulkStoredReceiptPayload(
                    receipt: receipt
                )
                let encoded = try Self.encodeBulkPreviewPayload(payload)
                let payloadHash = Self.hashBulkPreviewPayload(encoded)
                try execute(
                    """
                    INSERT INTO codex_ghost_repair_bulk_confirmation_receipts (
                        operation_id, receipt_id, saved_preview_request_id,
                        challenge_digest, confirmation_phrase_hash,
                        selected_count, confirmed_at_ms, receipt_digest,
                        payload_json, payload_hash, confirmation_recorded,
                        repair_claim_created, repair_mutation_authority,
                        automatic_retry_allowed
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, 0, 0)
                    """,
                    values: [
                        .text(receipt.operationID.uuidString.lowercased()),
                        .text(receipt.receiptID.uuidString.lowercased()),
                        .text(savedPreviewRequestID.uuidString.lowercased()),
                        .text(receipt.challengeDigest),
                        .text(receipt.confirmationPhraseHash),
                        .int64(Int64(receipt.selectedCount)),
                        .int64(receipt.confirmedAtMilliseconds),
                        .text(receipt.receiptDigest),
                        .text(encoded),
                        .text(payloadHash),
                    ],
                    database: database
                )
                guard let readback = try loadCodexGhostRepairBulkReceipt(
                    savedPreviewRequestID: savedPreviewRequestID,
                    database: database
                ), readback == receipt else {
                    throw PersistentStateError.invalidRecord(
                        "Whole-batch confirmation receipt readback did not match."
                    )
                }
                return .init(receipt: readback, newlyConfirmed: true)
            }
        }
    }

    func codexGhostRepairBulkConfirmationReceipt(
        savedPreviewRequestID: UUID
    ) throws -> CodexGhostRepairBulkConfirmationReceipt? {
        try withLockedDatabase { database in
            try loadCodexGhostRepairBulkReceipt(
                savedPreviewRequestID: savedPreviewRequestID,
                database: database
            )
        }
    }

    func codexGhostRepairBulkConfirmationReceipt(
        receiptID: UUID
    ) throws -> CodexGhostRepairBulkConfirmationReceipt? {
        try withLockedDatabase { database in
            let rows = try query(
                """
                SELECT saved_preview_request_id
                FROM codex_ghost_repair_bulk_confirmation_receipts
                WHERE receipt_id = ?
                """,
                values: [.text(receiptID.uuidString.lowercased())],
                database: database
            ) { statement -> UUID in
                try Self.bulkCanonicalUUID(requiredText(statement, 0))
            }
            guard rows.count <= 1 else {
                throw PersistentStateError.invalidRecord(
                    "Duplicate whole-batch confirmation receipt IDs."
                )
            }
            guard let savedPreviewRequestID = rows.first,
                  let receipt = try loadCodexGhostRepairBulkReceipt(
                      savedPreviewRequestID: savedPreviewRequestID,
                      database: database
                  ),
                  receipt.receiptID == receiptID else {
                return nil
            }
            return receipt
        }
    }

    func loadCodexGhostRepairBulkReceipt(
        savedPreviewRequestID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkConfirmationReceipt? {
        let rows = try query(
            """
            SELECT operation_id, receipt_id, challenge_digest,
                   confirmation_phrase_hash, selected_count,
                   confirmed_at_ms, receipt_digest, payload_json,
                   payload_hash, confirmation_recorded,
                   repair_claim_created, repair_mutation_authority,
                   automatic_retry_allowed
            FROM codex_ghost_repair_bulk_confirmation_receipts
            WHERE saved_preview_request_id = ?
            """,
            values: [
                .text(savedPreviewRequestID.uuidString.lowercased()),
            ],
            database: database
        ) { statement -> CodexGhostRepairBulkConfirmationReceiptPersistedRow in
            try .init(
                operationID: Self.bulkCanonicalUUID(
                    requiredText(statement, 0)
                ),
                receiptID: Self.bulkCanonicalUUID(
                    requiredText(statement, 1)
                ),
                challengeDigest: requiredText(statement, 2),
                confirmationPhraseHash: requiredText(statement, 3),
                selectedCount: Int(sqlite3_column_int64(statement, 4)),
                confirmedAtMilliseconds:
                    sqlite3_column_int64(statement, 5),
                receiptDigest: requiredText(statement, 6),
                encodedPayload: requiredText(statement, 7),
                payloadHash: requiredText(statement, 8),
                confirmationRecorded:
                    sqlite3_column_int64(statement, 9),
                repairClaimCreated:
                    sqlite3_column_int64(statement, 10),
                repairMutationAuthority:
                    sqlite3_column_int64(statement, 11),
                automaticRetryAllowed: sqlite3_column_int64(statement, 12)
            )
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate whole-batch confirmation receipts."
            )
        }
        guard let row = rows.first else { return nil }
        guard let challenge = try loadCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: savedPreviewRequestID,
            database: database
        ) else {
            throw PersistentStateError.invalidRecord(
                "Whole-batch receipt lost its challenge."
            )
        }
        return try row.decodeValidated(
            savedPreviewRequestID: savedPreviewRequestID,
            challenge: challenge
        )
    }
}
