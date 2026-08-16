import CSQLite3
import Foundation

public extension SQLiteStateStore {
    func saveArchiveBatchPlan(_ plan: PersistentArchiveBatchPlan) throws {
        try validateArchiveBatchPlanShape(plan)
        try withLockedDatabase { database in
            try transaction(database) {
                try validateArchiveBatchPlanReferences(plan, database: database)
                try execute(
                    """
                    INSERT INTO archive_batch_plans (
                        id, provider, status, provider_inventory_hash,
                        confirmation_token_hash, manifest_hash,
                        created_at, expires_at, unit_count, item_count
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    values: [
                        .text(plan.id.uuidString.lowercased()),
                        .text(plan.provider.rawValue),
                        .text(plan.status.rawValue),
                        .text(plan.providerInventoryHash),
                        .text(plan.confirmationTokenHash),
                        .text(plan.manifestHash),
                        .text(encode(plan.createdAt)),
                        .text(encode(plan.expiresAt)),
                        .int64(Int64(plan.units.count)),
                        .int64(Int64(plan.itemCount)),
                    ],
                    database: database
                )

                for unit in plan.units {
                    try execute(
                        """
                        INSERT INTO archive_batch_units (
                            batch_id, unit_ordinal, preview_id,
                            selected_root_manager_key, selected_root_native_session_id,
                            affected_set_hash
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        values: [
                            .text(plan.id.uuidString.lowercased()),
                            .int64(Int64(unit.ordinal)),
                            .text(unit.previewID.uuidString.lowercased()),
                            .text(unit.selectedRootManagerKey),
                            .text(unit.selectedRootNativeSessionID),
                            .text(unit.affectedSetHash),
                        ],
                        database: database
                    )
                    for (itemOrdinal, item) in unit.items.enumerated() {
                        try execute(
                            """
                            INSERT INTO archive_batch_items (
                                batch_id, unit_ordinal, item_ordinal, preview_id,
                                manager_key, native_session_id
                            ) VALUES (?, ?, ?, ?, ?, ?)
                            """,
                            values: [
                                .text(plan.id.uuidString.lowercased()),
                                .int64(Int64(unit.ordinal)),
                                .int64(Int64(itemOrdinal)),
                                .text(unit.previewID.uuidString.lowercased()),
                                .text(item.managerKey),
                                .text(item.nativeSessionID),
                            ],
                            database: database
                        )
                    }
                }
            }
        }
    }

    func archiveBatchPlan(id: UUID) throws -> PersistentArchiveBatchPlan? {
        try withLockedDatabase { database in
            try loadArchiveBatchPlan(id: id, database: database)
        }
    }

    internal func claimArchiveBatchPlanForExecution(
        id: UUID,
        now: Date,
        confirmationTokenHash: String
    ) throws -> (
        plan: PersistentArchiveBatchPlan,
        checkpoint: ProviderCheckpointRecord
    ) {
        try withLockedDatabase { database in
            try transaction(database) {
                guard let plan = try loadArchiveBatchPlan(id: id, database: database) else {
                    throw PersistentStateError.recordNotFound(id.uuidString)
                }
                guard plan.status == .prepared,
                      plan.expiresAt > now,
                      plan.confirmationTokenHash == confirmationTokenHash else {
                    throw PersistentStateError.invalidRecord(
                        "Archive batch is not prepared, is expired, or confirmation mismatched."
                    )
                }
                try validateArchiveBatchPlanShape(plan)
                try validateArchiveBatchPlanReferences(plan, database: database)
                guard let checkpoint = try loadCheckpoint(
                    provider: plan.provider,
                    database: database
                ) else {
                    throw PersistentStateError.recordNotFound(
                        "checkpoint:\(plan.provider.rawValue)"
                    )
                }

                try execute(
                    """
                    UPDATE archive_batch_plans SET status = 'executing'
                    WHERE id = ? AND status = 'prepared' AND expires_at > ?
                    """,
                    values: [
                        .text(id.uuidString.lowercased()),
                        .text(encode(now)),
                    ],
                    database: database
                )
                guard sqlite3_changes(database) == 1 else {
                    throw PersistentStateError.invalidRecord(
                        "Archive batch claim lost a status or expiry race."
                    )
                }
                for unit in plan.units {
                    try execute(
                        """
                        UPDATE operation_previews SET status = 'executing'
                        WHERE id = ? AND status = 'prepared' AND expires_at > ?
                        """,
                        values: [
                            .text(unit.previewID.uuidString.lowercased()),
                            .text(encode(now)),
                        ],
                        database: database
                    )
                    guard sqlite3_changes(database) == 1 else {
                        throw PersistentStateError.invalidRecord(
                            "Archive batch member Preview claim drifted."
                        )
                    }
                }
                return (copy(plan, status: .executing), checkpoint)
            }
        }
    }

    func saveArchiveBatchReport(_ report: PersistentArchiveBatchReport) throws {
        guard report.completedAt >= report.startedAt else {
            throw PersistentStateError.invalidRecord(
                "Archive batch Report completion precedes start."
            )
        }
        try withLockedDatabase { database in
            try transaction(database) {
                guard let plan = try loadArchiveBatchPlan(
                    id: report.batchID,
                    database: database
                ) else {
                    throw PersistentStateError.recordNotFound(report.batchID.uuidString)
                }
                guard plan.status == .prepared || plan.status == .executing else {
                    throw PersistentStateError.invalidRecord(
                        "Archive batch plan is not reportable."
                    )
                }
                try validateArchiveBatchFinalization(
                    report.finalization,
                    plan: plan
                )
                if report.finalization.attemptedUnitCount > 0,
                   plan.status != .executing {
                    throw PersistentStateError.invalidRecord(
                        "Attempted Archive batch Report requires an executing claim."
                    )
                }

                try execute(
                    """
                    INSERT INTO archive_batch_reports (
                        id, batch_id, outcome, started_at, completed_at,
                        attempted_unit_count, not_attempted_unit_count,
                        error_code, error_message
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    values: [
                        .text(report.id.uuidString.lowercased()),
                        .text(report.batchID.uuidString.lowercased()),
                        .text(report.finalization.outcome.rawValue),
                        .text(encode(report.startedAt)),
                        .text(encode(report.completedAt)),
                        .int64(Int64(report.finalization.attemptedUnitCount)),
                        .int64(Int64(report.finalization.notAttemptedUnitCount)),
                        .optionalText(report.errorCode),
                        .optionalText(report.errorMessage),
                    ],
                    database: database
                )

                for unit in report.finalization.units {
                    let unitOrdinal = try ordinal(
                        for: unit.selectedRootManagerKey,
                        in: plan
                    )
                    try execute(
                        """
                        UPDATE archive_batch_units
                        SET disposition = ?, error_code = ?, error_message = ?
                        WHERE batch_id = ? AND unit_ordinal = ? AND disposition IS NULL
                        """,
                        values: [
                            .text(unit.disposition.rawValue),
                            .optionalText(unit.errorCode),
                            .optionalText(unit.message),
                            .text(report.batchID.uuidString.lowercased()),
                            .int64(Int64(unitOrdinal)),
                        ],
                        database: database
                    )
                    guard sqlite3_changes(database) == 1 else {
                        throw PersistentStateError.invalidRecord(
                            "Archive batch unit was already consumed or changed."
                        )
                    }

                    for item in unit.items {
                        try execute(
                            """
                            UPDATE archive_batch_items
                            SET disposition = ?, observed_native_state = ?,
                                evidence_at = ?, error_code = ?, error_message = ?
                            WHERE batch_id = ? AND unit_ordinal = ?
                              AND manager_key = ? AND disposition IS NULL
                            """,
                            values: [
                                .text(item.disposition.rawValue),
                                .text(item.observedNativeState.rawValue),
                                .optionalText(item.evidenceAt.map(encode)),
                                .optionalText(item.errorCode),
                                .optionalText(item.message),
                                .text(report.batchID.uuidString.lowercased()),
                                .int64(Int64(unitOrdinal)),
                                .text(item.managerKey),
                            ],
                            database: database
                        )
                        guard sqlite3_changes(database) == 1 else {
                            throw PersistentStateError.invalidRecord(
                                "Archive batch item was already consumed or changed: \(item.managerKey)"
                            )
                        }
                    }
                }

                let requiredPreviewStatus = plan.status == .executing
                    ? PersistentPreviewStatus.executing
                    : .prepared
                for unit in plan.units {
                    try execute(
                        """
                        UPDATE operation_previews SET status = 'consumed'
                        WHERE id = ? AND status = ?
                        """,
                        values: [
                            .text(unit.previewID.uuidString.lowercased()),
                            .text(requiredPreviewStatus.rawValue),
                        ],
                        database: database
                    )
                    guard sqlite3_changes(database) == 1 else {
                        throw PersistentStateError.invalidRecord(
                            "Archive batch member Preview consume drifted."
                        )
                    }
                }

                try execute(
                    """
                    UPDATE archive_batch_plans SET status = 'consumed'
                    WHERE id = ? AND status IN ('prepared', 'executing')
                    """,
                    values: [.text(report.batchID.uuidString.lowercased())],
                    database: database
                )
                guard sqlite3_changes(database) == 1 else {
                    throw PersistentStateError.invalidRecord(
                        "Archive batch plan is not consumable."
                    )
                }
            }
        }
    }

    func archiveBatchReport(id: UUID) throws -> PersistentArchiveBatchReport? {
        try withLockedDatabase { database in
            try loadArchiveBatchReport(id: id, database: database)
        }
    }
}

extension SQLiteStateStore {
    func validateArchiveBatchPlanShape(_ plan: PersistentArchiveBatchPlan) throws {
        guard plan.provider == .codex,
              plan.status == .prepared,
              !plan.providerInventoryHash.isEmpty,
              !plan.confirmationTokenHash.isEmpty,
              !plan.manifestHash.isEmpty,
              plan.expiresAt > plan.createdAt,
              !plan.units.isEmpty else {
            throw PersistentStateError.invalidRecord(
                "Archive batch plan header is incomplete."
            )
        }
        guard plan.units.map(\.ordinal) == Array(plan.units.indices) else {
            throw PersistentStateError.invalidRecord(
                "Archive batch unit ordinals are not contiguous."
            )
        }
        let expectedManifest = try ArchiveBatchPersistenceHasher.manifestHash(
            id: plan.id,
            provider: plan.provider,
            providerInventoryHash: plan.providerInventoryHash,
            confirmationTokenHash: plan.confirmationTokenHash,
            createdAt: plan.createdAt,
            expiresAt: plan.expiresAt,
            units: plan.units
        )
        guard expectedManifest == plan.manifestHash else {
            throw PersistentStateError.invalidRecord(
                "Archive batch canonical manifest hash mismatch."
            )
        }
        var previewIDs: Set<UUID> = []
        var rootKeys: Set<String> = []
        var itemKeys: Set<String> = []
        for unit in plan.units {
            guard previewIDs.insert(unit.previewID).inserted,
                  rootKeys.insert(unit.selectedRootManagerKey).inserted,
                  !unit.affectedSetHash.isEmpty,
                  !unit.items.isEmpty else {
                throw PersistentStateError.invalidRecord(
                    "Archive batch units are duplicated or incomplete."
                )
            }
            for item in unit.items {
                guard item.managerKey == "\(plan.provider.rawValue):\(item.nativeSessionID)",
                      itemKeys.insert(item.managerKey).inserted else {
                    throw PersistentStateError.invalidRecord(
                        "Archive batch item identity is duplicated or invalid."
                    )
                }
            }
            guard unit.items.contains(where: {
                $0.managerKey == unit.selectedRootManagerKey
                    && $0.nativeSessionID == unit.selectedRootNativeSessionID
            }) else {
                throw PersistentStateError.invalidRecord(
                    "Archive batch selected root is absent from its frozen items."
                )
            }
        }
    }

    func validateArchiveBatchPlanReferences(
        _ plan: PersistentArchiveBatchPlan,
        database: OpaquePointer
    ) throws {
        guard let checkpoint = try loadCheckpoint(
            provider: plan.provider,
            database: database
        ), checkpoint.inventoryComplete, checkpoint.protectionComplete,
              checkpoint.inventoryHash == plan.providerInventoryHash else {
            throw PersistentStateError.invalidRecord(
                "Archive batch plan requires its exact complete provider checkpoint."
            )
        }
        for unit in plan.units {
            guard let preview = try loadPreview(id: unit.previewID, database: database),
                  preview.provider == plan.provider,
                  preview.operation == .archive,
                  preview.status == .prepared,
                  preview.providerInventoryHash == plan.providerInventoryHash,
                  preview.affectedSetHash == unit.affectedSetHash,
                  preview.items.map(\.managerKey) == unit.items.map(\.managerKey),
                  preview.items.map(\.nativeSessionID) == unit.items.map(\.nativeSessionID) else {
                throw PersistentStateError.invalidRecord(
                    "Archive batch unit does not exactly match its persisted Preview."
                )
            }
        }
    }

    func validateArchiveBatchFinalization(
        _ finalization: ArchiveBatchFinalization,
        plan: PersistentArchiveBatchPlan
    ) throws {
        guard finalization.units.count == plan.units.count else {
            throw PersistentStateError.previewItemSetMismatch
        }
        var terminalDispositionSeen = false
        for (stored, finalized) in zip(plan.units, finalization.units) {
            guard stored.selectedRootManagerKey == finalized.selectedRootManagerKey,
                  stored.items.map(\.managerKey) == finalized.affectedManagerKeys,
                  finalized.items.map(\.managerKey) == finalized.affectedManagerKeys else {
                throw PersistentStateError.previewItemSetMismatch
            }
            if finalized.disposition == .notAttempted {
                guard terminalDispositionSeen || finalization.attemptedUnitCount == 0 else {
                    throw PersistentStateError.invalidRecord(
                        "Archive batch cannot skip a unit before a terminal outcome."
                    )
                }
                guard finalized.items.allSatisfy({
                    $0.disposition == .notAttempted
                        && $0.observedNativeState == .unavailable
                        && $0.evidenceAt == nil
                }) else {
                    throw PersistentStateError.invalidRecord(
                        "Not-attempted Archive batch items cannot claim readback evidence."
                    )
                }
            } else {
                guard !terminalDispositionSeen else {
                    throw PersistentStateError.invalidRecord(
                        "Archive batch cannot attempt a unit after a terminal outcome."
                    )
                }
                guard finalized.items.allSatisfy({
                    [.success, .failure, .unknown].contains($0.disposition)
                        && $0.evidenceAt != nil
                }) else {
                    throw PersistentStateError.invalidRecord(
                        "Attempted Archive batch items require exact readback evidence."
                    )
                }
                let itemDispositions = finalized.items.map(\.disposition)
                let expectedUnitDisposition: ArchiveBatchUnitDisposition
                if itemDispositions.contains(.unknown) {
                    expectedUnitDisposition = .unknown
                } else if itemDispositions.allSatisfy({ $0 == .success }) {
                    expectedUnitDisposition = .success
                } else if itemDispositions.allSatisfy({ $0 == .failure }) {
                    expectedUnitDisposition = .failure
                } else {
                    expectedUnitDisposition = .partial
                }
                guard finalized.disposition == expectedUnitDisposition else {
                    throw PersistentStateError.invalidRecord(
                        "Archive batch unit disposition does not match itemized evidence."
                    )
                }
                if finalized.disposition != .success {
                    terminalDispositionSeen = true
                }
            }
        }
        let expectedOutcome: PersistentReportOutcome
        if finalization.attemptedUnitCount == 0 {
            expectedOutcome = .failure
        } else if finalization.units.contains(where: { $0.disposition == .unknown }) {
            expectedOutcome = .unknown
        } else if finalization.units.allSatisfy({ $0.disposition == .success }) {
            expectedOutcome = .success
        } else if finalization.units.first?.disposition == .failure,
                  finalization.attemptedUnitCount == 1 {
            expectedOutcome = .failure
        } else {
            expectedOutcome = .partial
        }
        guard finalization.outcome == expectedOutcome else {
            throw PersistentStateError.invalidRecord(
                "Archive batch Report outcome does not match its units."
            )
        }
    }

    func loadArchiveBatchPlan(
        id: UUID,
        database: OpaquePointer
    ) throws -> PersistentArchiveBatchPlan? {
        let headers = try query(
            """
            SELECT provider, status, provider_inventory_hash,
                   confirmation_token_hash, manifest_hash,
                   created_at, expires_at, unit_count, item_count
            FROM archive_batch_plans WHERE id = ?
            """,
            values: [.text(id.uuidString.lowercased())],
            database: database
        ) { statement -> (
            AgentSystem, PersistentArchiveBatchStatus, String, String, String,
            Date, Date, Int, Int
        ) in
            guard let provider = AgentSystem(rawValue: try requiredText(statement, 0)),
                  let status = PersistentArchiveBatchStatus(
                    rawValue: try requiredText(statement, 1)
                  ) else {
                throw PersistentStateError.invalidRecord(
                    "Unknown Archive batch plan enum value."
                )
            }
            return (
                provider,
                status,
                try requiredText(statement, 2),
                try requiredText(statement, 3),
                try requiredText(statement, 4),
                try decodeDate(requiredText(statement, 5)),
                try decodeDate(requiredText(statement, 6)),
                Int(sqlite3_column_int64(statement, 7)),
                Int(sqlite3_column_int64(statement, 8))
            )
        }
        guard let header = headers.first else { return nil }
        let units = try loadArchiveBatchUnits(batchID: id, database: database)
        guard units.count == header.7,
              units.reduce(0, { $0 + $1.items.count }) == header.8 else {
            throw PersistentStateError.invalidRecord(
                "Archive batch plan summary does not match its units/items."
            )
        }
        return PersistentArchiveBatchPlan(
            id: id,
            provider: header.0,
            status: header.1,
            providerInventoryHash: header.2,
            confirmationTokenHash: header.3,
            manifestHash: header.4,
            createdAt: header.5,
            expiresAt: header.6,
            units: units
        )
    }

    func loadArchiveBatchUnits(
        batchID: UUID,
        database: OpaquePointer
    ) throws -> [PersistentArchiveBatchUnit] {
        let unitRows = try query(
            """
            SELECT unit_ordinal, preview_id, selected_root_manager_key,
                   selected_root_native_session_id, affected_set_hash
            FROM archive_batch_units WHERE batch_id = ? ORDER BY unit_ordinal
            """,
            values: [.text(batchID.uuidString.lowercased())],
            database: database
        ) { statement -> (Int, UUID, String, String, String) in
            guard let previewID = UUID(uuidString: try requiredText(statement, 1)) else {
                throw PersistentStateError.invalidRecord(
                    "Invalid Archive batch unit Preview ID."
                )
            }
            return (
                Int(sqlite3_column_int64(statement, 0)),
                previewID,
                try requiredText(statement, 2),
                try requiredText(statement, 3),
                try requiredText(statement, 4)
            )
        }
        return try unitRows.map { row in
            let items = try query(
                """
                SELECT manager_key, native_session_id
                FROM archive_batch_items
                WHERE batch_id = ? AND unit_ordinal = ? ORDER BY item_ordinal
                """,
                values: [
                    .text(batchID.uuidString.lowercased()),
                    .int64(Int64(row.0)),
                ],
                database: database
            ) { statement in
                PersistentArchiveBatchItemIdentity(
                    managerKey: try requiredText(statement, 0),
                    nativeSessionID: try requiredText(statement, 1)
                )
            }
            return PersistentArchiveBatchUnit(
                ordinal: row.0,
                previewID: row.1,
                selectedRootManagerKey: row.2,
                selectedRootNativeSessionID: row.3,
                affectedSetHash: row.4,
                items: items
            )
        }
    }

    func loadArchiveBatchReport(
        id: UUID,
        database: OpaquePointer
    ) throws -> PersistentArchiveBatchReport? {
        let headers = try query(
            """
            SELECT batch_id, outcome, started_at, completed_at,
                   attempted_unit_count, not_attempted_unit_count,
                   error_code, error_message
            FROM archive_batch_reports WHERE id = ?
            """,
            values: [.text(id.uuidString.lowercased())],
            database: database
        ) { statement -> (
            UUID, PersistentReportOutcome, Date, Date, Int, Int, String?, String?
        ) in
            guard let batchID = UUID(uuidString: try requiredText(statement, 0)),
                  let outcome = PersistentReportOutcome(
                    rawValue: try requiredText(statement, 1)
                  ) else {
                throw PersistentStateError.invalidRecord(
                    "Unknown Archive batch Report identity or outcome."
                )
            }
            return (
                batchID,
                outcome,
                try decodeDate(requiredText(statement, 2)),
                try decodeDate(requiredText(statement, 3)),
                Int(sqlite3_column_int64(statement, 4)),
                Int(sqlite3_column_int64(statement, 5)),
                optionalText(statement, 6),
                optionalText(statement, 7)
            )
        }
        guard let header = headers.first else { return nil }
        guard let plan = try loadArchiveBatchPlan(id: header.0, database: database) else {
            throw PersistentStateError.recordNotFound(header.0.uuidString)
        }
        let finalizedUnits = try query(
            """
            SELECT unit_ordinal, selected_root_manager_key, disposition,
                   error_code, error_message
            FROM archive_batch_units WHERE batch_id = ? ORDER BY unit_ordinal
            """,
            values: [.text(header.0.uuidString.lowercased())],
            database: database
        ) { statement -> (Int, String, ArchiveBatchUnitDisposition, String?, String?) in
            guard let disposition = ArchiveBatchUnitDisposition(
                rawValue: try requiredText(statement, 2)
            ) else {
                throw PersistentStateError.invalidRecord(
                    "Unknown Archive batch unit disposition."
                )
            }
            return (
                Int(sqlite3_column_int64(statement, 0)),
                try requiredText(statement, 1),
                disposition,
                optionalText(statement, 3),
                optionalText(statement, 4)
            )
        }.map { row in
            let storedUnit = plan.units[row.0]
            let items = try query(
                """
                SELECT manager_key, disposition, observed_native_state,
                       evidence_at, error_code, error_message
                FROM archive_batch_items
                WHERE batch_id = ? AND unit_ordinal = ? ORDER BY item_ordinal
                """,
                values: [
                    .text(header.0.uuidString.lowercased()),
                    .int64(Int64(row.0)),
                ],
                database: database
            ) { statement in
                guard let disposition = ArchiveBatchUnitDisposition(
                    rawValue: try requiredText(statement, 1)
                ), let state = NativeSessionState(
                    rawValue: try requiredText(statement, 2)
                ) else {
                    throw PersistentStateError.invalidRecord(
                        "Unknown Archive batch item disposition or state."
                    )
                }
                return ArchiveBatchFinalizedItem(
                    managerKey: try requiredText(statement, 0),
                    disposition: disposition,
                    observedNativeState: state,
                    errorCode: optionalText(statement, 4),
                    message: optionalText(statement, 5),
                    evidenceAt: try optionalText(statement, 3).map(decodeDate)
                )
            }
            return ArchiveBatchFinalizedUnit(
                selectedRootManagerKey: row.1,
                affectedManagerKeys: storedUnit.items.map(\.managerKey),
                disposition: row.2,
                errorCode: row.3,
                message: row.4,
                items: items
            )
        }
        let finalization = ArchiveBatchFinalization(
            outcome: header.1,
            units: finalizedUnits
        )
        guard finalization.attemptedUnitCount == header.4,
              finalization.notAttemptedUnitCount == header.5 else {
            throw PersistentStateError.invalidRecord(
                "Archive batch Report summary does not match its units."
            )
        }
        return PersistentArchiveBatchReport(
            id: id,
            batchID: header.0,
            startedAt: header.2,
            completedAt: header.3,
            errorCode: header.6,
            errorMessage: header.7,
            finalization: finalization
        )
    }

    func ordinal(
        for selectedRootManagerKey: String,
        in plan: PersistentArchiveBatchPlan
    ) throws -> Int {
        guard let ordinal = plan.units.first(where: {
            $0.selectedRootManagerKey == selectedRootManagerKey
        })?.ordinal else {
            throw PersistentStateError.previewItemSetMismatch
        }
        return ordinal
    }

    func copy(
        _ plan: PersistentArchiveBatchPlan,
        status: PersistentArchiveBatchStatus
    ) -> PersistentArchiveBatchPlan {
        PersistentArchiveBatchPlan(
            id: plan.id,
            provider: plan.provider,
            status: status,
            providerInventoryHash: plan.providerInventoryHash,
            confirmationTokenHash: plan.confirmationTokenHash,
            manifestHash: plan.manifestHash,
            createdAt: plan.createdAt,
            expiresAt: plan.expiresAt,
            units: plan.units
        )
    }
}
