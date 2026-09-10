import CSQLite3
import Foundation

public struct CodexGhostRepairStoredPreview: Hashable, Sendable {
    public let status: CodexGhostRepairPersistentStatus
    public let plan: CodexGhostRepairPlan

    public init(status: CodexGhostRepairPersistentStatus, plan: CodexGhostRepairPlan) {
        self.status = status
        self.plan = plan
    }
}

public extension SQLiteStateStore {
    /// Saves one frozen Preview in the manager-owned journal. Re-saving the
    /// exact same payload is an idempotent readback; the same ID with different
    /// contents is rejected.
    func saveCodexGhostRepairPreview(_ plan: CodexGhostRepairPlan) throws {
        try validateGhostRepairPlanForPersistence(plan)
        let encoded = try encodeGhostRepairPayload(plan)
        let payloadHash = try CodexGhostRepairHasher.hash(plan)

        try withLockedDatabase { database in
            try transaction(database) {
                if let existing = try loadGhostRepairPreview(id: plan.id, database: database) {
                    guard existing.status == .prepared,
                          existing.plan == plan else {
                        throw PersistentStateError.invalidRecord(
                            "Ghost Repair Preview ID already belongs to different or consumed evidence."
                        )
                    }
                    return
                }
                try execute(
                    """
                    INSERT INTO codex_ghost_repair_previews (
                        id, status, category, manifest_hash, created_at_ms,
                        expires_at_ms, target_count, payload_json, payload_hash
                    ) VALUES (?, 'prepared', ?, ?, ?, ?, ?, ?, ?)
                    """,
                    values: [
                        .text(plan.id.uuidString.lowercased()),
                        .text(plan.category.rawValue),
                        .text(plan.manifestHash),
                        .int64(plan.createdAtMilliseconds),
                        .int64(plan.expiresAtMilliseconds),
                        .int64(Int64(plan.targetIDs.count)),
                        .text(encoded),
                        .text(payloadHash),
                    ],
                    database: database
                )
            }
        }

        guard try codexGhostRepairPreview(id: plan.id) == CodexGhostRepairStoredPreview(
            status: .prepared,
            plan: plan
        ) else {
            throw PersistentStateError.invalidRecord(
                "Ghost Repair Preview durable readback did not match exactly."
            )
        }
    }

    func codexGhostRepairPreview(id: UUID) throws -> CodexGhostRepairStoredPreview? {
        try withLockedDatabase { database in
            try loadGhostRepairPreview(id: id, database: database)
        }
    }

    func codexGhostRepairClaim(planID: UUID) throws -> CodexGhostRepairExecutionClaim? {
        try withLockedDatabase { database in
            try loadGhostRepairClaim(planID: planID, database: database)
        }
    }

    func codexGhostRepairReport(planID: UUID) throws -> CodexGhostRepairReport? {
        try withLockedDatabase { database in
            try loadGhostRepairReport(planID: planID, database: database)
        }
    }

    /// Atomically claims a prepared Preview. Any later invocation receives the
    /// existing Report or a recovery-only result and therefore cannot replay.
    func beginCodexGhostRepair(
        plan: CodexGhostRepairPlan,
        confirmationToken: String,
        claim: CodexGhostRepairExecutionClaim
    ) throws -> CodexGhostRepairBeginResult {
        try validateGhostRepairPlanForPersistence(plan)
        try claim.validateHash()
        guard claim.freshAuthority.metadataRow.satisfiesPrivacyContract(
            cleartextFields: CodexGhostRepairPrivacyContract.metadata
        ), claim.freshAuthority.localSyncRow.satisfiesPrivacyContract(
            cleartextFields: CodexGhostRepairPrivacyContract.localSync
        ) else {
            throw PersistentStateError.invalidRecord(
                "Ghost Repair claim contains non-redacted private fields."
            )
        }
        guard confirmationToken == plan.confirmationToken else {
            throw PersistentStateError.confirmationMismatch
        }
        guard claim.planID == plan.id,
              claim.planManifestHash == plan.manifestHash,
              claim.claimedAtMilliseconds < plan.expiresAtMilliseconds else {
            throw PersistentStateError.invalidRecord(
                "Ghost Repair claim does not match the unexpired frozen Preview."
            )
        }

        return try withLockedDatabase { database in
            try transaction(database) {
                if let report = try loadGhostRepairReport(planID: plan.id, database: database) {
                    return .existingReport(report)
                }
                if let existingClaim = try loadGhostRepairClaim(planID: plan.id, database: database) {
                    return .recoveryRequired(existingClaim)
                }
                guard let stored = try loadGhostRepairPreview(id: plan.id, database: database),
                      stored.status == .prepared,
                      stored.plan == plan else {
                    throw PersistentStateError.invalidRecord(
                        "Ghost Repair Preview is missing, changed, or no longer prepared."
                    )
                }

                let encodedClaim = try encodeGhostRepairPayload(claim)
                try execute(
                    """
                    INSERT INTO codex_ghost_repair_claims (
                        plan_id, claim_hash, claimed_at_ms, payload_json, payload_hash
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    values: [
                        .text(plan.id.uuidString.lowercased()),
                        .text(claim.claimHash),
                        .int64(claim.claimedAtMilliseconds),
                        .text(encodedClaim),
                        .text(try CodexGhostRepairHasher.hash(claim)),
                    ],
                    database: database
                )
                try execute(
                    """
                    UPDATE codex_ghost_repair_previews
                    SET status = 'executing'
                    WHERE id = ? AND status = 'prepared' AND manifest_hash = ?
                    """,
                    values: [
                        .text(plan.id.uuidString.lowercased()),
                        .text(plan.manifestHash),
                    ],
                    database: database
                )
                guard sqlite3_changes(database) == 1 else {
                    throw PersistentStateError.invalidRecord(
                        "Ghost Repair Preview claim lost its atomic prepared state."
                    )
                }
                return .claimed(claim)
            }
        }
    }

    /// Atomically records the observed itemized outcome and consumes the
    /// claimed Preview. This method persists manager state only.
    func finalizeCodexGhostRepair(
        report: CodexGhostRepairReport,
        expectedClaimHash: String
    ) throws {
        guard !report.mutationRetryAllowed,
              Set(report.items.map(\.threadID)).count == report.items.count,
              reportOutcomeIsConsistent(report) else {
            throw PersistentStateError.invalidRecord(
                "Ghost Repair Report must be non-retryable with unique exact items."
            )
        }
        let encodedReport = try encodeGhostRepairPayload(report)
        let reportHash = try CodexGhostRepairHasher.hash(report)

        try withLockedDatabase { database in
            try transaction(database) {
                if let existing = try loadGhostRepairReport(
                    planID: report.planID,
                    database: database
                ) {
                    guard existing == report else {
                        throw PersistentStateError.invalidRecord(
                            "Ghost Repair Report already exists with different evidence."
                        )
                    }
                    return
                }
                guard let stored = try loadGhostRepairPreview(
                    id: report.planID,
                    database: database
                ), stored.status == .executing,
                      stored.plan.manifestHash == report.planManifestHash,
                      stored.plan.targetIDs == report.items.map(\.threadID) else {
                    throw PersistentStateError.previewItemSetMismatch
                }
                guard let claim = try loadGhostRepairClaim(
                    planID: report.planID,
                    database: database
                ), claim.claimHash == expectedClaimHash,
                      claim.planManifestHash == report.planManifestHash,
                      claim.backupManifestHash == report.backupManifestHash else {
                    throw PersistentStateError.invalidRecord(
                        "Ghost Repair Report does not match the durable execution claim."
                    )
                }

                try execute(
                    """
                    INSERT INTO codex_ghost_repair_reports (
                        plan_id, report_hash, completed_at_ms, outcome,
                        payload_json, payload_hash
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    values: [
                        .text(report.planID.uuidString.lowercased()),
                        .text(reportHash),
                        .int64(report.completedAtMilliseconds),
                        .text(report.outcome.rawValue),
                        .text(encodedReport),
                        .text(reportHash),
                    ],
                    database: database
                )
                try execute(
                    """
                    UPDATE codex_ghost_repair_previews
                    SET status = 'consumed'
                    WHERE id = ? AND status = 'executing'
                    """,
                    values: [.text(report.planID.uuidString.lowercased())],
                    database: database
                )
                guard sqlite3_changes(database) == 1 else {
                    throw PersistentStateError.invalidRecord(
                        "Ghost Repair Report could not atomically consume its Preview."
                    )
                }
            }
        }

        guard try codexGhostRepairReport(planID: report.planID) == report,
              try codexGhostRepairPreview(id: report.planID)?.status == .consumed else {
            throw PersistentStateError.invalidRecord(
                "Ghost Repair Report durable readback did not match exactly."
            )
        }
    }
}

private extension SQLiteStateStore {
    func validateGhostRepairPlanForPersistence(_ plan: CodexGhostRepairPlan) throws {
        try plan.validateManifest()
        guard (1 ... 10).contains(plan.targetIDs.count),
              plan.targetIDs == plan.targetIDs.sorted(),
              Set(plan.targetIDs).count == plan.targetIDs.count,
              plan.expiresAtMilliseconds > plan.createdAtMilliseconds,
              plan.frozenTargets.map(\.threadID) == plan.targetIDs,
              plan.frozenTargets.allSatisfy({ target in
                  target.catalogRow.satisfiesPrivacyContract(
                      cleartextFields: CodexGhostRepairPrivacyContract.catalog
                  ) && (target.automationRow?.satisfiesPrivacyContract(
                      cleartextFields: CodexGhostRepairPrivacyContract.automationRun
                  ) ?? true) && (target.automationDefinitionRow?.satisfiesPrivacyContract(
                      cleartextFields: CodexGhostRepairPrivacyContract.automationDefinition
                  ) ?? true)
              }),
              plan.previewAuthorityAudit.metadataRow.satisfiesPrivacyContract(
                  cleartextFields: CodexGhostRepairPrivacyContract.metadata
              ),
              plan.previewAuthorityAudit.localSyncRow.satisfiesPrivacyContract(
                  cleartextFields: CodexGhostRepairPrivacyContract.localSync
              ) else {
            throw CodexGhostRepairError.invalidPlan(
                "Persisted Preview scope, expiry, or private-field digest contract is invalid."
            )
        }
    }

    func reportOutcomeIsConsistent(_ report: CodexGhostRepairReport) -> Bool {
        let expectedItemOutcome: CodexGhostRepairItemOutcome
        switch report.outcome {
        case .success: expectedItemOutcome = .repaired
        case .notApplied: expectedItemOutcome = .notApplied
        case .unknown: expectedItemOutcome = .unknown
        }
        return !report.items.isEmpty
            && report.items.allSatisfy { $0.outcome == expectedItemOutcome }
    }

    func loadGhostRepairPreview(
        id: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairStoredPreview? {
        let rows = try query(
            """
            SELECT status, category, manifest_hash, created_at_ms, expires_at_ms,
                   target_count, payload_json, payload_hash
            FROM codex_ghost_repair_previews WHERE id = ?
            """,
            values: [.text(id.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairStoredPreview in
            guard let status = CodexGhostRepairPersistentStatus(
                rawValue: try requiredText(statement, 0)
            ), let category = CodexGhostRepairCategory(
                rawValue: try requiredText(statement, 1)
            ) else {
                throw PersistentStateError.invalidRecord(
                    "Unknown Ghost Repair Preview status or category."
                )
            }
            let manifestHash = try requiredText(statement, 2)
            let createdAt = sqlite3_column_int64(statement, 3)
            let expiresAt = sqlite3_column_int64(statement, 4)
            let targetCount = Int(sqlite3_column_int64(statement, 5))
            let payload = try requiredText(statement, 6)
            let payloadHash = try requiredText(statement, 7)
            let plan: CodexGhostRepairPlan = try decodeGhostRepairPayload(payload)
            try validateGhostRepairPlanForPersistence(plan)
            guard plan.id == id,
                  plan.category == category,
                  plan.manifestHash == manifestHash,
                  plan.createdAtMilliseconds == createdAt,
                  plan.expiresAtMilliseconds == expiresAt,
                  plan.targetIDs.count == targetCount,
                  try CodexGhostRepairHasher.hash(plan) == payloadHash else {
                throw PersistentStateError.invalidRecord(
                    "Ghost Repair Preview columns and payload disagree."
                )
            }
            return CodexGhostRepairStoredPreview(status: status, plan: plan)
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord("Duplicate Ghost Repair Preview rows.")
        }
        return rows.first
    }

    func loadGhostRepairClaim(
        planID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairExecutionClaim? {
        let rows = try query(
            """
            SELECT claim_hash, claimed_at_ms, payload_json, payload_hash
            FROM codex_ghost_repair_claims WHERE plan_id = ?
            """,
            values: [.text(planID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairExecutionClaim in
            let claimHash = try requiredText(statement, 0)
            let claimedAt = sqlite3_column_int64(statement, 1)
            let payload = try requiredText(statement, 2)
            let payloadHash = try requiredText(statement, 3)
            let claim: CodexGhostRepairExecutionClaim = try decodeGhostRepairPayload(payload)
            try claim.validateHash()
            guard claim.planID == planID,
                  claim.claimHash == claimHash,
                  claim.claimedAtMilliseconds == claimedAt,
                  try CodexGhostRepairHasher.hash(claim) == payloadHash else {
                throw PersistentStateError.invalidRecord(
                    "Ghost Repair claim columns and payload disagree."
                )
            }
            return claim
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord("Duplicate Ghost Repair claim rows.")
        }
        return rows.first
    }

    func loadGhostRepairReport(
        planID: UUID,
        database: OpaquePointer
    ) throws -> CodexGhostRepairReport? {
        let rows = try query(
            """
            SELECT report_hash, completed_at_ms, outcome, payload_json, payload_hash
            FROM codex_ghost_repair_reports WHERE plan_id = ?
            """,
            values: [.text(planID.uuidString.lowercased())],
            database: database
        ) { statement -> CodexGhostRepairReport in
            let reportHash = try requiredText(statement, 0)
            let completedAt = sqlite3_column_int64(statement, 1)
            let outcome = try requiredText(statement, 2)
            let payload = try requiredText(statement, 3)
            let payloadHash = try requiredText(statement, 4)
            let report: CodexGhostRepairReport = try decodeGhostRepairPayload(payload)
            let expectedHash = try CodexGhostRepairHasher.hash(report)
            guard report.planID == planID,
                  report.completedAtMilliseconds == completedAt,
                  report.outcome.rawValue == outcome,
                  reportHash == expectedHash,
                  payloadHash == expectedHash else {
                throw PersistentStateError.invalidRecord(
                    "Ghost Repair Report columns and payload disagree."
                )
            }
            return report
        }
        guard rows.count <= 1 else {
            throw PersistentStateError.invalidRecord("Duplicate Ghost Repair Report rows.")
        }
        return rows.first
    }

    func encodeGhostRepairPayload<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PersistentStateError.invalidRecord(
                "Ghost Repair payload is not valid UTF-8."
            )
        }
        return text
    }

    func decodeGhostRepairPayload<T: Decodable>(_ text: String) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw PersistentStateError.invalidRecord(
                "Ghost Repair payload is not valid UTF-8."
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
