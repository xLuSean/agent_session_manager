import CSQLite3
import Foundation

struct CodexGhostRepairBulkStoredChallengePayload:
    Codable,
    Hashable
{
    let challenge: CodexGhostRepairBulkConfirmationChallenge
}

struct CodexGhostRepairBulkConfirmationChallengePersistedRow {
    let operationID: UUID
    let previewID: UUID
    let manifestDigest: String
    let previewPayloadHash: String
    let selectedCount: Int
    let ordinaryCount: Int
    let automationCount: Int
    let blockedOutsideBatchCount: Int
    let generatedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let challengeDigest: String
    let confirmationPhrase: String
    let encodedPayload: String
    let payloadHash: String
    let confirmationAuthority: Int64
    let repairClaimCreated: Int64
    let repairMutationAuthority: Int64

    func decodeValidated(
        savedPreviewRequestID: UUID
    ) throws -> CodexGhostRepairBulkConfirmationChallenge {
        guard payloadHash == SQLiteStateStore.hashBulkPreviewPayload(
            encodedPayload
        ) else {
            throw PersistentStateError.invalidRecord(
                "Whole-batch challenge payload hash does not match."
            )
        }
        let payload: CodexGhostRepairBulkStoredChallengePayload =
            try SQLiteStateStore.decodeBulkPreviewPayload(encodedPayload)
        let challenge = payload.challenge
        guard challenge.operationID == operationID,
              challenge.savedPreviewRequestID == savedPreviewRequestID,
              challenge.previewID == previewID,
              challenge.manifestDigest == manifestDigest,
              challenge.previewPayloadHash == previewPayloadHash,
              challenge.selectedCount == selectedCount,
              challenge.ordinaryCount == ordinaryCount,
              challenge.automationCount == automationCount,
              challenge.blockedOutsideBatchCount
                == blockedOutsideBatchCount,
              challenge.generatedAtMilliseconds
                == generatedAtMilliseconds,
              challenge.expiresAtMilliseconds == expiresAtMilliseconds,
              challenge.challengeDigest == challengeDigest,
              challenge.confirmationPhrase == confirmationPhrase,
              confirmationAuthority == 0,
              repairClaimCreated == 0,
              repairMutationAuthority == 0 else {
            throw PersistentStateError.invalidRecord(
                "Whole-batch challenge columns and payload disagree."
            )
        }
        return challenge
    }
}

public enum CodexGhostRepairBulkConfirmationChallengeCoordinatorFactory {
    /// Construction is zero-I/O. One exact manager-owned Preview is read and
    /// one evidence-only challenge is saved only after explicit user action.
    public static func packagedEvidenceOnly()
        -> any CodexGhostRepairBulkConfirmationChallengeCoordinating
    {
        CodexGhostRepairBulkConfirmationLiveCoordinator()
    }
}

public actor CodexGhostRepairBulkConfirmationUnavailableCoordinator:
    CodexGhostRepairBulkConfirmationChallengeCoordinating
{
    public nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationCapabilities.unavailable

    public init() {}

    public func prepareChallenge(
        savedPreviewRequestID: UUID
    ) async -> CodexGhostRepairBulkConfirmationChallengeOutcome {
        .unavailable(
            requestID: savedPreviewRequestID,
            message: "Whole-batch confirmation review is unavailable."
        )
    }
}

actor CodexGhostRepairBulkConfirmationLiveCoordinator:
    CodexGhostRepairBulkConfirmationChallengeCoordinating
{
    nonisolated let capabilities =
        CodexGhostRepairBulkConfirmationCapabilities.packagedEvidenceOnly
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

    func prepareChallenge(
        savedPreviewRequestID: UUID
    ) async -> CodexGhostRepairBulkConfirmationChallengeOutcome {
        do {
            let store = try SQLiteStateStore(
                databaseURL: databaseURLProvider()
            )
            defer { store.close() }
            guard try store.codexGhostRepairBulkPreview(
                requestID: savedPreviewRequestID
            ) != nil else {
                return .notFound(requestID: savedPreviewRequestID)
            }
            let challenge = try store.prepareCodexGhostRepairBulkChallenge(
                savedPreviewRequestID: savedPreviewRequestID,
                generatedAtMilliseconds: nowMilliseconds()
            )
            guard !challenge.confirmationAuthority,
                  !challenge.repairClaimCreated,
                  !challenge.repairMutationAuthority else {
                return .unavailable(
                    requestID: savedPreviewRequestID,
                    message: "Whole-batch challenge exceeded its evidence-only boundary."
                )
            }
            return .ready(challenge)
        } catch {
            return .unavailable(
                requestID: savedPreviewRequestID,
                message: "The exact whole-batch challenge could not be prepared. No confirmation or repair authority was created."
            )
        }
    }
}

extension SQLiteStateStore {
    func prepareCodexGhostRepairBulkChallenge(
        savedPreviewRequestID: UUID,
        generatedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairBulkConfirmationChallenge {
        try withLockedDatabase { database in
            try transaction(database) {
                guard let storedPreview = try loadCodexGhostRepairBulkPreview(
                    requestID: savedPreviewRequestID,
                    database: database
                ) else {
                    throw PersistentStateError.invalidRecord(
                        "Saved bulk Preview is missing."
                    )
                }
                guard generatedAtMilliseconds
                        >= storedPreview.preview.generatedAtMilliseconds,
                      generatedAtMilliseconds
                        < storedPreview.preview.expiresAtMilliseconds else {
                    throw PersistentStateError.invalidRecord(
                        "Saved bulk Preview is expired or not yet valid."
                    )
                }
                if let existing = try loadCodexGhostRepairBulkChallenge(
                    savedPreviewRequestID: savedPreviewRequestID,
                    database: database
                ) {
                    try existing.validate(
                        requestID: savedPreviewRequestID,
                        preview: storedPreview.preview,
                        payloadHash: storedPreview.payloadHash
                    )
                    return existing
                }
                let challenge = try CodexGhostRepairBulkConfirmationChallenge(
                    operationID: UUID(),
                    savedPreviewRequestID: savedPreviewRequestID,
                    preview: storedPreview.preview,
                    previewPayloadHash: storedPreview.payloadHash,
                    generatedAtMilliseconds: generatedAtMilliseconds
                )
                let payload = CodexGhostRepairBulkStoredChallengePayload(
                    challenge: challenge
                )
                let encoded = try Self.encodeBulkPreviewPayload(payload)
                let payloadHash = Self.hashBulkPreviewPayload(encoded)
                try execute(
                    """
                    INSERT INTO codex_ghost_repair_bulk_confirmation_challenges (
                        operation_id, saved_preview_request_id, preview_id,
                        manifest_digest, preview_payload_hash, selected_count,
                        ordinary_count, automation_count,
                        blocked_outside_batch_count, generated_at_ms,
                        expires_at_ms, challenge_digest, confirmation_phrase,
                        payload_json, payload_hash, confirmation_authority,
                        repair_claim_created, repair_mutation_authority
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0)
                    """,
                    values: [
                        .text(challenge.operationID.uuidString.lowercased()),
                        .text(savedPreviewRequestID.uuidString.lowercased()),
                        .text(challenge.previewID.uuidString.lowercased()),
                        .text(challenge.manifestDigest),
                        .text(challenge.previewPayloadHash),
                        .int64(Int64(challenge.selectedCount)),
                        .int64(Int64(challenge.ordinaryCount)),
                        .int64(Int64(challenge.automationCount)),
                        .int64(Int64(challenge.blockedOutsideBatchCount)),
                        .int64(challenge.generatedAtMilliseconds),
                        .int64(challenge.expiresAtMilliseconds),
                        .text(challenge.challengeDigest),
                        .text(challenge.confirmationPhrase),
                        .text(encoded),
                        .text(payloadHash),
                    ],
                    database: database
                )
                guard let readback = try loadCodexGhostRepairBulkChallenge(
                    savedPreviewRequestID: savedPreviewRequestID,
                    database: database
                ), readback == challenge else {
                    throw PersistentStateError.invalidRecord(
                        "Whole-batch challenge readback did not match."
                    )
                }
                return readback
            }
        }
    }

    func codexGhostRepairBulkChallenge(
        savedPreviewRequestID: UUID
    ) throws -> CodexGhostRepairBulkConfirmationChallenge? {
        try withLockedDatabase { database in
            try loadCodexGhostRepairBulkChallenge(
                savedPreviewRequestID: savedPreviewRequestID,
                database: database
            )
        }
    }

    func loadCodexGhostRepairBulkChallenge(
        savedPreviewRequestID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairBulkConfirmationChallenge? {
        let rows = try query(
            """
            SELECT operation_id, preview_id, manifest_digest,
                   preview_payload_hash, selected_count, ordinary_count,
                   automation_count, blocked_outside_batch_count,
                   generated_at_ms, expires_at_ms, challenge_digest,
                   confirmation_phrase, payload_json, payload_hash,
                   confirmation_authority, repair_claim_created,
                   repair_mutation_authority
            FROM codex_ghost_repair_bulk_confirmation_challenges
            WHERE saved_preview_request_id = ?
            """,
            values: [.text(savedPreviewRequestID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairBulkConfirmationChallenge in
            try CodexGhostRepairBulkConfirmationChallengePersistedRow(
                operationID: Self.bulkCanonicalUUID(
                    requiredText(statement, 0)
                ),
                previewID: Self.bulkCanonicalUUID(
                    requiredText(statement, 1)
                ),
                manifestDigest: requiredText(statement, 2),
                previewPayloadHash: requiredText(statement, 3),
                selectedCount: Int(sqlite3_column_int64(statement, 4)),
                ordinaryCount: Int(sqlite3_column_int64(statement, 5)),
                automationCount: Int(sqlite3_column_int64(statement, 6)),
                blockedOutsideBatchCount:
                    Int(sqlite3_column_int64(statement, 7)),
                generatedAtMilliseconds:
                    sqlite3_column_int64(statement, 8),
                expiresAtMilliseconds:
                    sqlite3_column_int64(statement, 9),
                challengeDigest: requiredText(statement, 10),
                confirmationPhrase: requiredText(statement, 11),
                encodedPayload: requiredText(statement, 12),
                payloadHash: requiredText(statement, 13),
                confirmationAuthority:
                    sqlite3_column_int64(statement, 14),
                repairClaimCreated:
                    sqlite3_column_int64(statement, 15),
                repairMutationAuthority:
                    sqlite3_column_int64(statement, 16)
            ).decodeValidated(
                savedPreviewRequestID: savedPreviewRequestID
            )
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord(
                "Duplicate whole-batch challenges."
            )
        }
        guard let challenge = rows.first else { return nil }
        guard let preview = try loadCodexGhostRepairBulkPreview(
            requestID: savedPreviewRequestID,
            database: database
        ) else {
            throw PersistentStateError.invalidRecord(
                "Whole-batch challenge lost its saved Preview."
            )
        }
        try challenge.validate(
            requestID: savedPreviewRequestID,
            preview: preview.preview,
            payloadHash: preview.payloadHash
        )
        return challenge
    }
}
