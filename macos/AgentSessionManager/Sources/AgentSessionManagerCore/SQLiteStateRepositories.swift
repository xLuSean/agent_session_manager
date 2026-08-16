import CSQLite3
import Foundation

private let repositorySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public extension SQLiteStateStore {
    func upsertProviderCheckpoint(_ checkpoint: ProviderCheckpointRecord) throws {
        try validate(checkpoint)
        try withLockedDatabase { database in
            try transaction(database) {
                let existing = try loadCheckpoint(provider: checkpoint.provider, database: database)
                if existing != checkpoint {
                    let executingRows = try query(
                        "SELECT 1 FROM operation_previews WHERE provider = ? AND status = 'executing' LIMIT 1",
                        values: [.text(checkpoint.provider.rawValue)],
                        database: database
                    ) { _ in true }
                    guard executingRows.isEmpty else {
                        throw PersistentStateError.invalidRecord(
                            "Provider checkpoint cannot change while execution recovery is unresolved."
                        )
                    }
                }
                try upsert(checkpoint, database: database)
            }
        }
    }

    func providerCheckpoint(for provider: AgentSystem) throws -> ProviderCheckpointRecord? {
        try withLockedDatabase { database in
            try loadCheckpoint(provider: provider, database: database)
        }
    }

    /// Atomically advances an authoritative complete inventory checkpoint and
    /// marks exactly the frozen Trash membership set as reconciled. Any local
    /// membership drift aborts the whole transaction.
    func commitReconciliationCheckpoint(
        _ checkpoint: ProviderCheckpointRecord,
        expectedTrashManagerKeys: Set<String>
    ) throws {
        try validate(checkpoint)
        guard checkpoint.inventoryComplete else {
            throw PersistentStateError.invalidRecord(
                "Authoritative reconciliation requires a complete inventory checkpoint."
            )
        }
        try withLockedDatabase { database in
            try transaction(database) {
                let executingRows = try query(
                    "SELECT 1 FROM operation_previews WHERE provider = ? AND status = 'executing' LIMIT 1",
                    values: [.text(checkpoint.provider.rawValue)],
                    database: database
                ) { _ in true }
                guard executingRows.isEmpty else {
                    throw PersistentStateError.invalidRecord(
                        "Provider checkpoint cannot advance while execution recovery is unresolved."
                    )
                }
                let rows = try query(
                    "SELECT manager_key FROM trash_memberships WHERE provider = ? ORDER BY manager_key",
                    values: [.text(checkpoint.provider.rawValue)],
                    database: database
                ) { statement in
                    try requiredText(statement, 0)
                }
                guard Set(rows) == expectedTrashManagerKeys,
                      rows.count == expectedTrashManagerKeys.count else {
                    throw PersistentStateError.invalidRecord(
                        "Trash membership set drifted during reconciliation."
                    )
                }

                try upsert(checkpoint, database: database)
                for managerKey in expectedTrashManagerKeys.sorted() {
                    try execute(
                        "UPDATE trash_memberships SET last_reconciled_at = ? WHERE provider = ? AND manager_key = ?",
                        values: [
                            .text(encode(checkpoint.refreshedAt)),
                            .text(checkpoint.provider.rawValue),
                            .text(managerKey),
                        ],
                        database: database
                    )
                    guard sqlite3_changes(database) == 1 else {
                        throw PersistentStateError.invalidRecord(
                            "Trash membership disappeared during reconciliation: \(managerKey)"
                        )
                    }
                }
            }
        }
    }

    /// Persists manager Trash intent and its authoritative provider checkpoint
    /// in one transaction. This does not call or mutate the provider.
    func saveTrashMembership(
        _ membership: TrashMembershipRecord,
        checkpoint: ProviderCheckpointRecord
    ) throws {
        try validate(checkpoint)
        try validate(membership, checkpoint: checkpoint)
        try withLockedDatabase { database in
            try transaction(database) {
                try upsert(checkpoint, database: database)
                let sql = """
                INSERT INTO trash_memberships (
                    provider, native_session_id, manager_key, title_at_entry,
                    project_id_at_entry, working_directory_at_entry,
                    native_state_at_entry, provider_inventory_hash_at_entry,
                    entered_at, last_reconciled_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider, native_session_id) DO UPDATE SET
                    last_reconciled_at = excluded.last_reconciled_at
                """
                try execute(
                    sql,
                    values: [
                        .text(membership.provider.rawValue),
                        .text(membership.nativeSessionID),
                        .text(membership.managerKey),
                        .text(membership.titleAtEntry),
                        .optionalText(membership.projectIDAtEntry),
                        .optionalText(membership.workingDirectoryAtEntry),
                        .text(membership.nativeStateAtEntry.rawValue),
                        .text(membership.providerInventoryHashAtEntry),
                        .text(encode(membership.enteredAt)),
                        .text(encode(membership.lastReconciledAt)),
                    ],
                    database: database
                )
            }
        }
    }

    func trashMemberships(for provider: AgentSystem) throws -> [TrashMembershipRecord] {
        try withLockedDatabase { database in
            let sql = """
            SELECT provider, native_session_id, manager_key, title_at_entry,
                   project_id_at_entry, working_directory_at_entry,
                   native_state_at_entry, provider_inventory_hash_at_entry,
                   entered_at, last_reconciled_at
            FROM trash_memberships
            WHERE provider = ?
            ORDER BY manager_key
            """
            return try query(sql, values: [.text(provider.rawValue)], database: database) { statement in
                guard let storedProvider = AgentSystem(rawValue: try requiredText(statement, 0)),
                      let nativeState = NativeSessionState(rawValue: try requiredText(statement, 6)) else {
                    throw PersistentStateError.invalidRecord("Unknown provider or native state in Trash membership.")
                }
                return TrashMembershipRecord(
                    provider: storedProvider,
                    nativeSessionID: try requiredText(statement, 1),
                    managerKey: try requiredText(statement, 2),
                    titleAtEntry: try requiredText(statement, 3),
                    projectIDAtEntry: optionalText(statement, 4),
                    workingDirectoryAtEntry: optionalText(statement, 5),
                    nativeStateAtEntry: nativeState,
                    providerInventoryHashAtEntry: try requiredText(statement, 7),
                    enteredAt: try decodeDate(requiredText(statement, 8)),
                    lastReconciledAt: try decodeDate(requiredText(statement, 9))
                )
            }
        }
    }

    func deletedSessions(for provider: AgentSystem) throws -> [DeletedSessionRecord] {
        try withLockedDatabase { database in
            try loadDeletedSessions(provider: provider, database: database)
        }
    }

    /// Atomically applies one frozen manager-only Archive/Trash classification,
    /// writes its itemized success Report, and consumes the Preview. No provider
    /// lifecycle method is available anywhere in this transaction boundary.
    func commitManagerOnlyOperation(
        previewID: UUID,
        confirmationTokenHash: String,
        validatedCheckpoint: ProviderCheckpointRecord,
        completedAt: Date,
        reportID: UUID
    ) throws -> PersistentOperationReport {
        // SQLite's ISO-8601 representation round-trips at millisecond
        // precision. Freeze the execution timestamp to that durable precision
        // before it is used by memberships, Report items, and exact readback.
        let canonicalCompletedAt = PersistentTimestamp.canonical(completedAt)
        let committed = try withLockedDatabase { database in
            try transaction(database) {
                guard let preview = try loadPreview(id: previewID, database: database) else {
                    throw PersistentStateError.recordNotFound(previewID.uuidString)
                }
                guard preview.status == .prepared,
                      preview.operation == .moveToTrash || preview.operation == .moveToArchive else {
                    throw PersistentStateError.invalidRecord(
                        "Preview is not a prepared manager-only Archive/Trash operation."
                    )
                }
                guard preview.expiresAt > canonicalCompletedAt else {
                    throw PersistentStateError.invalidRecord(
                        "Manager-only Preview expired before confirmation."
                    )
                }
                guard preview.confirmationTokenHash == confirmationTokenHash else {
                    throw PersistentStateError.confirmationMismatch
                }
                guard let checkpoint = try loadCheckpoint(
                    provider: preview.provider,
                    database: database
                ) else {
                    throw PersistentStateError.recordNotFound(
                        "checkpoint:\(preview.provider.rawValue)"
                    )
                }
                guard checkpoint == validatedCheckpoint,
                      checkpoint.inventoryComplete else {
                    throw PersistentStateError.invalidRecord(
                        "Validated manager-only checkpoint changed before commit."
                    )
                }
                if preview.operation == .moveToTrash, !checkpoint.protectionComplete {
                    throw PersistentStateError.invalidRecord(
                        "Move to Trash requires complete protection evidence."
                    )
                }
                guard let runtimeVersion = checkpoint.runtimeVersion,
                      !runtimeVersion.isEmpty,
                      preview.manifestHash == (try ManagerOnlyOperationHasher.manifestHash(
                          operation: preview.operation,
                          providerInventoryHash: preview.providerInventoryHash,
                          runtimeVersion: runtimeVersion,
                          createdAt: preview.createdAt,
                          expiresAt: preview.expiresAt,
                          items: preview.items
                      )) else {
                    throw PersistentStateError.invalidRecord(
                        "Manager-only Preview manifest no longer matches its frozen contents."
                    )
                }
                let existingMemberships = try query(
                    "SELECT manager_key FROM trash_memberships WHERE provider = ? ORDER BY manager_key",
                    values: [.text(preview.provider.rawValue)],
                    database: database
                ) { statement in
                    try requiredText(statement, 0)
                }
                let existingKeys = Set(existingMemberships)
                let previewKeys = Set(preview.items.map(\.managerKey))
                for managerKey in previewKeys {
                    let executingNativeLifecycle = try query(
                        """
                        SELECT 1
                        FROM operation_previews p
                        JOIN operation_items i ON i.preview_id = p.id
                        WHERE p.provider = ?
                          AND p.manager_intent IN ('archive', 'move_to_trash', 'restore')
                          AND p.status = 'executing'
                          AND i.manager_key = ?
                        LIMIT 1
                        """,
                        values: [
                            .text(preview.provider.rawValue),
                            .text(managerKey),
                        ],
                        database: database
                    ) { _ in true }
                    guard executingNativeLifecycle.isEmpty else {
                        throw PersistentStateError.invalidRecord(
                            "Manager classification cannot change while the exact session has an executing native lifecycle operation."
                        )
                    }
                }
                if preview.operation == .moveToTrash {
                    guard existingKeys.isDisjoint(with: previewKeys) else {
                        throw PersistentStateError.invalidRecord(
                            "Trash membership changed after Preview."
                        )
                    }
                    for item in preview.items {
                        guard item.expectedNativeState == .archived else {
                            throw PersistentStateError.invalidRecord(
                                "Manager-only Move to Trash requires native Archived state."
                            )
                        }
                        try execute(
                            """
                            INSERT INTO trash_memberships (
                                provider, native_session_id, manager_key,
                                title_at_entry, project_id_at_entry,
                                working_directory_at_entry, native_state_at_entry,
                                provider_inventory_hash_at_entry, entered_at,
                                last_reconciled_at
                            ) VALUES (?, ?, ?, ?, ?, ?, 'archived', ?, ?, ?)
                            """,
                            values: [
                                .text(preview.provider.rawValue),
                                .text(item.nativeSessionID),
                                .text(item.managerKey),
                                .text(item.expectedTitle),
                                .optionalText(item.expectedProjectID),
                                .optionalText(item.expectedWorkingDirectory),
                                .text(preview.providerInventoryHash),
                                .text(encode(canonicalCompletedAt)),
                                .text(encode(canonicalCompletedAt)),
                            ],
                            database: database
                        )
                        guard sqlite3_changes(database) == 1 else {
                            throw PersistentStateError.invalidRecord(
                                "Trash membership was not inserted: \(item.managerKey)"
                            )
                        }
                    }
                } else {
                    guard previewKeys.isSubset(of: existingKeys) else {
                        throw PersistentStateError.invalidRecord(
                            "Trash membership changed after Preview."
                        )
                    }
                    for item in preview.items {
                        guard item.expectedNativeState == .archived else {
                            throw PersistentStateError.invalidRecord(
                                "Manager-only Move to Archive requires native Archived state."
                            )
                        }
                        try execute(
                            "DELETE FROM trash_memberships WHERE provider = ? AND manager_key = ?",
                            values: [
                                .text(preview.provider.rawValue),
                                .text(item.managerKey),
                            ],
                            database: database
                        )
                        guard sqlite3_changes(database) == 1 else {
                            throw PersistentStateError.invalidRecord(
                                "Trash membership was not removed: \(item.managerKey)"
                            )
                        }
                    }
                }

                let report = PersistentOperationReport(
                    id: reportID,
                    previewID: preview.id,
                    provider: preview.provider,
                    operation: preview.operation,
                    outcome: .success,
                    startedAt: canonicalCompletedAt,
                    completedAt: canonicalCompletedAt,
                    releasedBytesComplete: true,
                    items: preview.items.map { item in
                        PersistentReportItem(
                            managerKey: item.managerKey,
                            outcome: .success,
                            observedNativeState: .archived,
                            verifiedReleasedBytes: 0,
                            evidenceAt: canonicalCompletedAt
                        )
                    }
                )
                try validate(report)
                try insertOperationReportAndConsumePreview(
                    report,
                    expectedPreview: preview,
                    database: database
                )
                _ = try pruneOperationHistory(
                    for: report.provider,
                    database: database
                )
                return report
            }
        }

        // Commit success is not inferred from an empty SQLite response. Read
        // back every manager-owned artifact after the transaction has closed.
        guard let reportReadback = try operationReport(id: committed.id),
              reportReadback == committed else {
            throw PersistentStateError.invalidRecord(
                "Manager-only commit completed, but exact Report readback failed. Do not retry this consumed Preview; refresh to reconcile."
            )
        }
        guard try operationPreview(id: previewID)?.status == .consumed else {
            throw PersistentStateError.invalidRecord(
                "Manager-only commit completed, but consumed Preview readback failed. Do not retry; refresh to reconcile."
            )
        }
        let membershipKeys = Set(
            try trashMemberships(for: committed.provider).map(\.managerKey)
        )
        let committedKeys = Set(committed.items.map(\.managerKey))
        let membershipReadbackMatches = switch committed.operation {
        case .moveToTrash:
            committedKeys.isSubset(of: membershipKeys)
        case .moveToArchive:
            committedKeys.isDisjoint(with: membershipKeys)
        default:
            false
        }
        guard membershipReadbackMatches else {
            throw PersistentStateError.invalidRecord(
                "Manager-only commit completed, but exact Trash membership readback failed. Do not retry; refresh to reconcile."
            )
        }
        return reportReadback
    }

    /// Accepts a provider-native restore that has already happened outside this
    /// app. The transaction removes exactly one frozen manager Trash membership,
    /// writes its Report, and consumes the Preview. It cannot mutate Codex.
    func commitAcceptNativeRestore(
        previewID: UUID,
        confirmationTokenHash: String,
        completedAt: Date,
        reportID: UUID
    ) throws -> PersistentOperationReport {
        let canonicalCompletedAt = PersistentTimestamp.canonical(completedAt)
        let committed = try withLockedDatabase { database in
            try transaction(database) {
                guard let preview = try loadPreview(id: previewID, database: database) else {
                    throw PersistentStateError.recordNotFound(previewID.uuidString)
                }
                guard preview.status == .prepared,
                      preview.provider == .codex,
                      preview.operation == .restore,
                      preview.items.count == 1,
                      let item = preview.items.first,
                      item.expectedNativeState == .active else {
                    throw PersistentStateError.invalidRecord(
                        "Preview is not a prepared Accept Native Restore operation."
                    )
                }
                guard preview.expiresAt > canonicalCompletedAt else {
                    throw PersistentStateError.invalidRecord(
                        "Conflict resolution Preview expired before confirmation."
                    )
                }
                guard preview.confirmationTokenHash == confirmationTokenHash else {
                    throw PersistentStateError.confirmationMismatch
                }
                guard let checkpoint = try loadCheckpoint(
                    provider: preview.provider,
                    database: database
                ) else {
                    throw PersistentStateError.recordNotFound(
                        "checkpoint:\(preview.provider.rawValue)"
                    )
                }
                guard checkpoint.inventoryComplete,
                      checkpoint.inventoryHash == preview.providerInventoryHash else {
                    throw PersistentStateError.invalidRecord(
                        "Provider inventory drifted after conflict resolution Preview."
                    )
                }
                guard let runtimeVersion = checkpoint.runtimeVersion,
                      !runtimeVersion.isEmpty,
                      preview.manifestHash == (try ConflictResolutionHasher.manifestHash(
                          providerInventoryHash: preview.providerInventoryHash,
                          runtimeVersion: runtimeVersion,
                          createdAt: preview.createdAt,
                          expiresAt: preview.expiresAt,
                          items: preview.items
                      )) else {
                    throw PersistentStateError.invalidRecord(
                        "Conflict resolution Preview manifest no longer matches its frozen contents."
                    )
                }
                try validate(
                    preview,
                    checkpoint: checkpoint,
                    requiresCompleteProtection: false
                )

                let memberships = try query(
                    """
                    SELECT provider, native_session_id, manager_key,
                           title_at_entry, project_id_at_entry,
                           working_directory_at_entry, native_state_at_entry,
                           provider_inventory_hash_at_entry, entered_at,
                           last_reconciled_at
                    FROM trash_memberships
                    WHERE provider = ?
                    ORDER BY manager_key
                    """,
                    values: [
                        .text(preview.provider.rawValue),
                    ],
                    database: database
                ) { statement in
                    guard let provider = AgentSystem(rawValue: try requiredText(statement, 0)),
                          let nativeState = NativeSessionState(
                              rawValue: try requiredText(statement, 6)
                          ) else {
                        throw PersistentStateError.invalidRecord(
                            "Unknown provider or native state in Trash membership."
                        )
                    }
                    return TrashMembershipRecord(
                        provider: provider,
                        nativeSessionID: try requiredText(statement, 1),
                        managerKey: try requiredText(statement, 2),
                        titleAtEntry: try requiredText(statement, 3),
                        projectIDAtEntry: optionalText(statement, 4),
                        workingDirectoryAtEntry: optionalText(statement, 5),
                        nativeStateAtEntry: nativeState,
                        providerInventoryHashAtEntry: try requiredText(statement, 7),
                        enteredAt: try decodeDate(requiredText(statement, 8)),
                        lastReconciledAt: try decodeDate(requiredText(statement, 9))
                    )
                }
                guard let membership = memberships.first(where: {
                          $0.managerKey == item.managerKey
                      }),
                      membership.nativeSessionID == item.nativeSessionID,
                      try ConflictResolutionHasher.membershipSetHash(memberships)
                        == item.expectedProtectionHash else {
                    throw PersistentStateError.invalidRecord(
                        "Trash membership drifted after conflict resolution Preview."
                    )
                }

                try execute(
                    "DELETE FROM trash_memberships WHERE provider = ? AND native_session_id = ? AND manager_key = ?",
                    values: [
                        .text(preview.provider.rawValue),
                        .text(item.nativeSessionID),
                        .text(item.managerKey),
                    ],
                    database: database
                )
                guard sqlite3_changes(database) == 1 else {
                    throw PersistentStateError.invalidRecord(
                        "Trash membership was not removed: \(item.managerKey)"
                    )
                }

                let report = PersistentOperationReport(
                    id: reportID,
                    previewID: preview.id,
                    provider: preview.provider,
                    operation: .restore,
                    outcome: .success,
                    startedAt: canonicalCompletedAt,
                    completedAt: canonicalCompletedAt,
                    releasedBytesComplete: true,
                    items: [
                        PersistentReportItem(
                            managerKey: item.managerKey,
                            outcome: .success,
                            observedNativeState: .active,
                            verifiedReleasedBytes: 0,
                            evidenceAt: canonicalCompletedAt
                        )
                    ]
                )
                try validate(report)
                try insertOperationReportAndConsumePreview(
                    report,
                    expectedPreview: preview,
                    database: database
                )
                _ = try pruneOperationHistory(for: report.provider, database: database)
                return report
            }
        }

        guard let reportReadback = try operationReport(id: committed.id),
              reportReadback == committed else {
            throw PersistentStateError.invalidRecord(
                "Conflict resolution committed, but exact Report readback failed. Do not retry this consumed Preview; refresh to reconcile."
            )
        }
        guard try operationPreview(id: previewID)?.status == .consumed else {
            throw PersistentStateError.invalidRecord(
                "Conflict resolution committed, but consumed Preview readback failed. Do not retry; refresh to reconcile."
            )
        }
        let membershipKeys = Set(
            try trashMemberships(for: committed.provider).map(\.managerKey)
        )
        guard Set(committed.items.map(\.managerKey)).isDisjoint(with: membershipKeys) else {
            throw PersistentStateError.invalidRecord(
                "Conflict resolution committed, but exact Trash membership readback failed. Do not retry; refresh to reconcile."
            )
        }
        return reportReadback
    }

    /// Removes manager-owned Trash intent only. It has no native lifecycle side
    /// effect. Production UI operations use the frozen transactional coordinator
    /// above instead of this lower-level reconciliation primitive.
    @discardableResult
    func removeTrashMembership(managerKey: String) throws -> Bool {
        try withLockedDatabase { database in
            try execute(
                "DELETE FROM trash_memberships WHERE manager_key = ?",
                values: [.text(managerKey)],
                database: database
            )
            return sqlite3_changes(database) == 1
        }
    }

    /// Saves an immutable frozen Preview header and all items atomically. The
    /// API accepts only a token hash; there is no plaintext-token column.
    func saveOperationPreview(
        _ preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord
    ) throws {
        try persistOperationPreview(
            preview,
            checkpoint: checkpoint,
            requiresCompleteProtection: preview.requiresCompleteProtectionCheckpoint
        )
    }

    /// Narrow persistence entrypoint for Accept Native Restore. This operation
    /// exits manager Trash and cannot perform a protected native mutation.
    func saveConflictResolutionPreview(
        _ preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord
    ) throws {
        guard preview.operation == .restore,
              preview.items.count == 1,
              preview.items.first?.expectedNativeState == .active else {
            throw PersistentStateError.invalidRecord(
                "Conflict resolution persistence accepts only one Active Restore item."
            )
        }
        try persistOperationPreview(
            preview,
            checkpoint: checkpoint,
            requiresCompleteProtection: false
        )
    }

    private func persistOperationPreview(
        _ preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        requiresCompleteProtection: Bool
    ) throws {
        try validate(checkpoint)
        try validate(
            preview,
            checkpoint: checkpoint,
            requiresCompleteProtection: requiresCompleteProtection
        )
        try withLockedDatabase { database in
            try transaction(database) {
                try upsert(checkpoint, database: database)
                try execute(
                    """
                    INSERT INTO operation_previews (
                        id, provider, operation, status, confirmation_token_hash,
                        manifest_hash, provider_inventory_hash, created_at,
                        expires_at, item_count, known_size_bytes, unknown_size_count,
                        affected_set_hash, manager_intent, trash_membership_mutation
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    values: [
                        .text(preview.id.uuidString.lowercased()),
                        .text(preview.provider.rawValue),
                        .text(preview.operation.legacyOperationRawValue),
                        .text(preview.status.rawValue),
                        .text(preview.confirmationTokenHash),
                        .text(preview.manifestHash),
                        .text(preview.providerInventoryHash),
                        .text(encode(preview.createdAt)),
                        .text(encode(preview.expiresAt)),
                        .int64(Int64(preview.items.count)),
                        .int64(try checkedKnownSize(preview.items)),
                        .int64(Int64(preview.unknownSizeCount)),
                        .optionalText(preview.affectedSetHash),
                        .text(preview.operation.rawValue),
                        .optionalText(preview.trashMembershipMutation?.rawValue),
                    ],
                    database: database
                )

                let itemSQL = """
                INSERT INTO operation_items (
                    preview_id, manager_key, native_session_id,
                    expected_native_state, expected_protection_hash,
                    expected_title, expected_project_id,
                    expected_working_directory, known_size_bytes,
                    archive_affected_role, parent_native_session_id,
                    archive_affected_depth
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                for item in preview.items {
                    try execute(
                        itemSQL,
                        values: [
                            .text(preview.id.uuidString.lowercased()),
                            .text(item.managerKey),
                            .text(item.nativeSessionID),
                            .text(item.expectedNativeState.rawValue),
                            .text(item.expectedProtectionHash),
                            .text(item.expectedTitle),
                            .optionalText(item.expectedProjectID),
                            .optionalText(item.expectedWorkingDirectory),
                            .optionalInt64(item.knownSizeBytes),
                            .optionalText(item.archiveAffectedRole?.rawValue),
                            .optionalText(item.parentNativeSessionID),
                            .optionalInt64(item.archiveAffectedDepth.map(Int64.init)),
                        ],
                        database: database
                    )
                }
                guard let persisted = try loadPreview(
                    id: preview.id,
                    database: database
                ), persisted == preview else {
                    throw PersistentStateError.invalidRecord(
                        "Preview persistence readback differs from its frozen input."
                    )
                }
            }
        }
    }

    func operationPreview(id: UUID) throws -> PersistentOperationPreview? {
        try withLockedDatabase { database in
            try loadPreview(id: id, database: database)
        }
    }

    /// Recovery must resolve executing work against its original persisted
    /// checkpoint before ordinary inventory refresh is allowed to replace it.
    func hasExecutingOperationPreview(for provider: AgentSystem) throws -> Bool {
        try withLockedDatabase { database in
            let rows = try query(
                "SELECT 1 FROM operation_previews WHERE provider = ? AND status = 'executing' LIMIT 1",
                values: [.text(provider.rawValue)],
                database: database
            ) { _ in true }
            return !rows.isEmpty
        }
    }

    /// Returns the exact durable work that must be resolved before the
    /// provider checkpoint may advance. The bounded query fails closed rather
    /// than silently omitting recovery work from an unexpectedly large set.
    func executingOperationPreviews(
        for provider: AgentSystem,
        limit: Int = 100
    ) throws -> [PersistentOperationPreview] {
        guard (1 ... 100).contains(limit) else {
            throw PersistentStateError.invalidRecord(
                "Executing Preview recovery limit must be between 1 and 100."
            )
        }
        return try withLockedDatabase { database in
            let identifiers = try query(
                """
                SELECT id
                FROM operation_previews
                WHERE provider = ? AND status = 'executing'
                ORDER BY created_at, id
                LIMIT ?
                """,
                values: [
                    .text(provider.rawValue),
                    .int64(Int64(limit + 1)),
                ],
                database: database
            ) { statement -> UUID in
                let rawID = try requiredText(statement, 0)
                guard let id = UUID(uuidString: rawID) else {
                    throw PersistentStateError.invalidRecord(
                        "Executing Preview has an invalid identifier."
                    )
                }
                return id
            }
            guard identifiers.count <= limit else {
                throw PersistentStateError.invalidRecord(
                    "Executing Preview recovery exceeds the bounded limit of \(limit)."
                )
            }
            return try identifiers.map { id in
                guard let preview = try loadPreview(id: id, database: database) else {
                    throw PersistentStateError.recordNotFound(id.uuidString)
                }
                return preview
            }
        }
    }

    /// Atomically claims one exact prepared Preview for execution together
    /// with the current provider checkpoint. A claimed Preview cannot be
    /// claimed again after a crash, preventing blind mutation replay.
    internal func claimOperationPreviewForExecution(
        id: UUID,
        now: Date,
        confirmationTokenHash: String
    ) throws -> (
        preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord
    ) {
        try withLockedDatabase { database in
            try transaction(database) {
                guard let preview = try loadPreview(id: id, database: database) else {
                    throw PersistentStateError.recordNotFound(id.uuidString)
                }
                guard preview.status == .prepared else {
                    throw PersistentStateError.invalidRecord(
                        "Preview is not prepared and cannot be claimed."
                    )
                }
                let batchRows = try query(
                    """
                    SELECT 1
                    FROM archive_batch_units u
                    JOIN archive_batch_plans b ON b.id = u.batch_id
                    WHERE u.preview_id = ? AND b.status IN ('prepared', 'executing')
                    LIMIT 1
                    """,
                    values: [.text(id.uuidString.lowercased())],
                    database: database
                ) { _ in true }
                guard batchRows.isEmpty else {
                    throw PersistentStateError.invalidRecord(
                        "Preview belongs to an unresolved Archive batch and cannot be claimed alone."
                    )
                }
                guard preview.expiresAt > now else {
                    throw PersistentStateError.invalidRecord(
                        "Preview expired before it could be claimed."
                    )
                }
                guard preview.confirmationTokenHash == confirmationTokenHash else {
                    throw PersistentStateError.confirmationMismatch
                }
                guard let checkpoint = try loadCheckpoint(
                    provider: preview.provider,
                    database: database
                ) else {
                    throw PersistentStateError.recordNotFound(
                        "checkpoint:\(preview.provider.rawValue)"
                    )
                }
                let requiresCompleteProtection = preview.requiresCompleteProtectionCheckpoint
                guard checkpoint.inventoryComplete,
                      !requiresCompleteProtection || checkpoint.protectionComplete else {
                    throw PersistentStateError.invalidRecord(
                        requiresCompleteProtection
                            ? "Execution claim requires complete inventory and protection checkpoints."
                            : "Archive execution claim requires a complete inventory checkpoint."
                    )
                }
                guard checkpoint.inventoryHash == preview.providerInventoryHash else {
                    throw PersistentStateError.invalidRecord(
                        "Provider checkpoint drifted after Preview persistence."
                    )
                }
                if (preview.operation == .restore || preview.operation == .permanentlyDelete),
                   preview.items.allSatisfy({ $0.expectedNativeState == .archived }) {
                    let memberships = try loadTrashMemberships(
                        provider: preview.provider,
                        database: database
                    )
                    for item in preview.items {
                        let membership = memberships.first {
                            $0.managerKey == item.managerKey
                        }
                        if preview.trashMembershipMutation == .remove {
                            guard membership?.nativeSessionID == item.nativeSessionID,
                                  try ConflictResolutionHasher.membershipSetHash(memberships)
                                    == item.expectedProtectionHash else {
                                throw PersistentStateError.invalidRecord(
                                    "Native lifecycle claim detected frozen Manager Trash membership drift."
                                )
                            }
                        } else {
                            guard membership == nil else {
                                throw PersistentStateError.invalidRecord(
                                    "Native Restore claim detected Manager Trash membership drift."
                                )
                            }
                        }
                    }
                }
                if preview.operation == .moveToTrash,
                   preview.trashMembershipMutation == .add {
                    let membershipKeys = Set(try loadTrashMemberships(
                        provider: preview.provider,
                        database: database
                    ).map(\.managerKey))
                    guard membershipKeys.isDisjoint(with: preview.items.map(\.managerKey)) else {
                        throw PersistentStateError.invalidRecord(
                            "Move to Trash claim detected existing Manager Trash membership."
                        )
                    }
                }
                // Re-validate the exact SQLite record inside the claim
                // transaction so corrupt or incomplete item rows fail before
                // any status change or provider call.
                try validate(
                    preview,
                    checkpoint: checkpoint,
                    requiresCompleteProtection: requiresCompleteProtection
                )

                try execute(
                    "UPDATE operation_previews SET status = 'executing' WHERE id = ? AND status = 'prepared' AND expires_at > ?",
                    values: [
                        .text(id.uuidString.lowercased()),
                        .text(encode(now)),
                    ],
                    database: database
                )
                guard sqlite3_changes(database) == 1 else {
                    throw PersistentStateError.invalidRecord(
                        "Preview claim lost a concurrent status or expiry race."
                    )
                }

                return (
                    PersistentOperationPreview(
                        id: preview.id,
                        provider: preview.provider,
                        operation: preview.operation,
                        status: .executing,
                        confirmationTokenHash: preview.confirmationTokenHash,
                        manifestHash: preview.manifestHash,
                        providerInventoryHash: preview.providerInventoryHash,
                        affectedSetHash: preview.affectedSetHash,
                        trashMembershipMutation: preview.trashMembershipMutation,
                        createdAt: preview.createdAt,
                        expiresAt: preview.expiresAt,
                        items: preview.items
                    ),
                    checkpoint
                )
            }
        }
    }

    /// Persists the report, fills every frozen item result, and consumes the
    /// Preview in one transaction. A partial item set is rejected before writes.
    @discardableResult
    func saveOperationReport(
        _ report: PersistentOperationReport,
        requiringPreviewStatus requiredPreviewStatus: PersistentPreviewStatus? = nil
    ) throws -> OperationHistoryPruneResult {
        try validate(report)
        return try withLockedDatabase { database in
            try transaction(database) {
                guard let preview = try loadPreview(id: report.previewID, database: database) else {
                    throw PersistentStateError.recordNotFound(report.previewID.uuidString)
                }
                guard preview.provider == report.provider else {
                    throw PersistentStateError.providerMismatch(
                        expected: preview.provider,
                        found: report.provider
                    )
                }
                guard preview.operation == report.operation else {
                    throw PersistentStateError.invalidRecord("Report operation does not match Preview.")
                }
                let batchRows = try query(
                    """
                    SELECT 1
                    FROM archive_batch_units u
                    JOIN archive_batch_plans b ON b.id = u.batch_id
                    WHERE u.preview_id = ? AND b.status IN ('prepared', 'executing')
                    LIMIT 1
                    """,
                    values: [.text(report.previewID.uuidString.lowercased())],
                    database: database
                ) { _ in true }
                guard batchRows.isEmpty else {
                    throw PersistentStateError.invalidRecord(
                        "Archive batch member Preview cannot be reported through the single-item repository."
                    )
                }
                if let requiredPreviewStatus,
                   preview.status != requiredPreviewStatus {
                    throw PersistentStateError.invalidRecord(
                        "Preview status is \(preview.status.rawValue), expected \(requiredPreviewStatus.rawValue)."
                    )
                }
                if report.items.contains(where: { $0.outcome == .success }),
                   let membershipMutation = preview.trashMembershipMutation {
                    try applySuccessfulNativeTrashMembershipMutation(
                        membershipMutation,
                        preview: preview,
                        report: report,
                        database: database
                    )
                }
                try insertOperationReportAndConsumePreview(
                    report,
                    expectedPreview: preview,
                    database: database
                )

                return try pruneOperationHistory(
                    for: report.provider,
                    database: database
                )
            }
        }
    }

    func applySuccessfulNativeTrashMembershipMutation(
        _ mutation: TrashMembershipMutation,
        preview: PersistentOperationPreview,
        report: PersistentOperationReport,
        database: OpaquePointer
    ) throws {
        guard preview.items.count == report.items.count,
              Set(preview.items.map(\.managerKey)) == Set(report.items.map(\.managerKey)) else {
            throw PersistentStateError.previewItemSetMismatch
        }
        let reportItemsByKey = Dictionary(uniqueKeysWithValues: report.items.map {
            ($0.managerKey, $0)
        })
        let successfulPairs = preview.items.compactMap { item -> (
            PersistentPreviewItem, PersistentReportItem
        )? in
            guard let reportItem = reportItemsByKey[item.managerKey],
                  reportItem.outcome == .success else { return nil }
            return (item, reportItem)
        }
        guard !successfulPairs.isEmpty else { return }
        let memberships = try loadTrashMemberships(
            provider: preview.provider,
            database: database
        )
        switch mutation {
        case .add:
            guard preview.operation == .moveToTrash,
                  successfulPairs.allSatisfy({ item, reportItem in
                      item.expectedNativeState == .active
                          && reportItem.observedNativeState == .archived
                          && !memberships.contains(where: {
                              $0.managerKey == item.managerKey
                          })
                  }) else {
                throw PersistentStateError.invalidRecord(
                    "Successful Active to Trash finalization found lifecycle or membership drift."
                )
            }
            for (item, reportItem) in successfulPairs {
                try execute(
                    """
                    INSERT INTO trash_memberships (
                        provider, native_session_id, manager_key,
                        title_at_entry, project_id_at_entry,
                        working_directory_at_entry, native_state_at_entry,
                        provider_inventory_hash_at_entry, entered_at,
                        last_reconciled_at
                    ) VALUES (?, ?, ?, ?, ?, ?, 'archived', ?, ?, ?)
                    """,
                    values: [
                        .text(preview.provider.rawValue),
                        .text(item.nativeSessionID),
                        .text(item.managerKey),
                        .text(item.expectedTitle),
                        .optionalText(item.expectedProjectID),
                        .optionalText(item.expectedWorkingDirectory),
                        .text(preview.providerInventoryHash),
                        .text(encode(reportItem.evidenceAt)),
                        .text(encode(reportItem.evidenceAt)),
                    ],
                    database: database
                )
                guard sqlite3_changes(database) == 1 else {
                    throw PersistentStateError.invalidRecord(
                        "Active to Trash did not insert the frozen membership."
                    )
                }
            }
        case .remove:
            let membershipHash = try ConflictResolutionHasher.membershipSetHash(memberships)
            guard successfulPairs.allSatisfy({ item, reportItem in
                let finalStateMatches = switch preview.operation {
                case .restore: reportItem.observedNativeState == .active
                case .permanentlyDelete: reportItem.observedNativeState == .absent
                default: false
                }
                return item.expectedNativeState == .archived
                    && finalStateMatches
                    && memberships.contains(where: {
                        $0.managerKey == item.managerKey
                            && $0.nativeSessionID == item.nativeSessionID
                    })
                    && membershipHash == item.expectedProtectionHash
            }) else {
                throw PersistentStateError.invalidRecord(
                    "Successful Trash exit finalization found frozen membership drift."
                )
            }
            for (item, reportItem) in successfulPairs {
                try execute(
                    "DELETE FROM trash_memberships WHERE provider = ? AND native_session_id = ? AND manager_key = ?",
                    values: [
                        .text(preview.provider.rawValue),
                        .text(item.nativeSessionID),
                        .text(item.managerKey),
                    ],
                    database: database
                )
                guard sqlite3_changes(database) == 1 else {
                    throw PersistentStateError.invalidRecord(
                        "Successful native lifecycle operation did not remove the frozen Trash membership."
                    )
                }
                if preview.operation == .permanentlyDelete {
                    try execute(
                        """
                        INSERT INTO deleted_sessions (
                            provider, native_session_id, manager_key,
                            title_at_deletion, project_id_at_deletion,
                            working_directory_at_deletion, known_size_bytes,
                            provider_inventory_hash_at_deletion, deleted_at,
                            delete_report_id
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        values: [
                            .text(preview.provider.rawValue),
                            .text(item.nativeSessionID),
                            .text(item.managerKey),
                            .text(item.expectedTitle),
                            .optionalText(item.expectedProjectID),
                            .optionalText(item.expectedWorkingDirectory),
                            .optionalInt64(item.knownSizeBytes),
                            .text(preview.providerInventoryHash),
                            .text(encode(reportItem.evidenceAt)),
                            .text(report.id.uuidString.lowercased()),
                        ],
                        database: database
                    )
                    guard sqlite3_changes(database) == 1 else {
                        throw PersistentStateError.invalidRecord(
                            "Permanent Delete did not create the durable Deleted tombstone."
                        )
                    }
                }
            }
        }
    }

    func operationReport(id: UUID) throws -> PersistentOperationReport? {
        try withLockedDatabase { database in
            try loadReport(id: id, database: database)
        }
    }

    /// Returns immutable operation history in deterministic reverse chronology.
    /// The cursor is a keyset boundary, so rows inserted ahead of an in-flight
    /// traversal cannot create duplicates or offset drift.
    func operationHistory(
        _ historyQuery: OperationHistoryQuery = OperationHistoryQuery()
    ) throws -> OperationHistoryPage {
        guard (1 ... OperationHistoryQuery.maximumLimit).contains(historyQuery.limit) else {
            throw PersistentStateError.invalidRecord(
                "Operation history query limit must be between 1 and \(OperationHistoryQuery.maximumLimit)."
            )
        }
        if let from = historyQuery.completedFrom,
           let through = historyQuery.completedThrough,
           from > through {
            throw PersistentStateError.invalidRecord(
                "Operation history completedFrom must not follow completedThrough."
            )
        }

        return try withLockedDatabase { database in
            var predicates: [String] = []
            var values: [RepositorySQLiteValue] = []

            if let provider = historyQuery.provider {
                predicates.append("provider = ?")
                values.append(.text(provider.rawValue))
            }
            if let operation = historyQuery.operation {
                predicates.append("manager_intent = ?")
                values.append(.text(operation.rawValue))
            }
            if let outcome = historyQuery.outcome {
                predicates.append("outcome = ?")
                values.append(.text(outcome.rawValue))
            }
            let searchText = historyQuery.searchText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !searchText.isEmpty {
                let pattern = sqlLikeContainsPattern(searchText)
                predicates.append(
                    """
                    (
                        operation_reports.id LIKE ? ESCAPE '\\' COLLATE NOCASE
                        OR operation_reports.preview_id LIKE ? ESCAPE '\\' COLLATE NOCASE
                        OR operation_reports.error_code LIKE ? ESCAPE '\\' COLLATE NOCASE
                        OR EXISTS (
                            SELECT 1 FROM operation_items AS history_item
                            WHERE history_item.report_id = operation_reports.id
                              AND (
                                  history_item.manager_key LIKE ? ESCAPE '\\' COLLATE NOCASE
                                  OR history_item.native_session_id LIKE ? ESCAPE '\\' COLLATE NOCASE
                                  OR history_item.expected_title LIKE ? ESCAPE '\\' COLLATE NOCASE
                                  OR history_item.expected_project_id LIKE ? ESCAPE '\\' COLLATE NOCASE
                                  OR history_item.error_code LIKE ? ESCAPE '\\' COLLATE NOCASE
                              )
                        )
                    )
                    """
                )
                values.append(contentsOf: Array(repeating: .text(pattern), count: 8))
            }
            if let from = historyQuery.completedFrom {
                predicates.append("completed_at >= ?")
                values.append(.text(encode(from)))
            }
            if let through = historyQuery.completedThrough {
                predicates.append("completed_at <= ?")
                values.append(.text(encode(through)))
            }
            if let cursor = historyQuery.cursor {
                predicates.append("(completed_at < ? OR (completed_at = ? AND id < ?))")
                values.append(.text(encode(cursor.completedAt)))
                values.append(.text(encode(cursor.completedAt)))
                values.append(.text(cursor.reportID.uuidString.lowercased()))
            }

            let whereClause = predicates.isEmpty
                ? ""
                : "WHERE " + predicates.joined(separator: " AND ")
            values.append(.int64(Int64(historyQuery.limit + 1)))
            let reportIDs = try query(
                """
                SELECT id
                FROM operation_reports
                \(whereClause)
                ORDER BY completed_at DESC, id DESC
                LIMIT ?
                """,
                values: values,
                database: database
            ) { statement in
                guard let id = UUID(uuidString: try requiredText(statement, 0)) else {
                    throw PersistentStateError.invalidRecord(
                        "Operation history contains an invalid Report ID."
                    )
                }
                return id
            }

            let hasMore = reportIDs.count > historyQuery.limit
            let pageIDs = Array(reportIDs.prefix(historyQuery.limit))
            let entries = try pageIDs.map { id in
                guard let entry = try loadHistoryEntry(id: id, database: database) else {
                    throw PersistentStateError.invalidRecord(
                        "Operation history Report disappeared during query: \(id.uuidString)."
                    )
                }
                return entry
            }
            let nextCursor = hasMore ? entries.last.map {
                OperationHistoryCursor(completedAt: $0.completedAt, reportID: $0.reportID)
            } : nil
            return OperationHistoryPage(entries: entries, nextCursor: nextCursor)
        }
    }

    /// Atomically removes complete operation-history bundles older than the
    /// newest provider-scoped retention window. It never touches checkpoints,
    /// Trash memberships, or Previews without a committed Report.
    @discardableResult
    func pruneOperationHistory(
        for provider: AgentSystem
    ) throws -> OperationHistoryPruneResult {
        try withLockedDatabase { database in
            try transaction(database) {
                try pruneOperationHistory(for: provider, database: database)
            }
        }
    }

    /// Explicitly clears complete consumed operation-history bundles. This is
    /// audit-history deletion only: checkpoints, Trash memberships, prepared or
    /// executing Previews, and native provider state are outside the target set.
    @discardableResult
    func clearOperationHistory(
        reportIDs: Set<UUID>,
        provider: AgentSystem,
        confirmationToken: String,
        expectedConfirmationToken: String
    ) throws -> OperationHistoryClearResult {
        guard !expectedConfirmationToken.isEmpty,
              confirmationToken == expectedConfirmationToken else {
            throw PersistentStateError.confirmationMismatch
        }
        guard !reportIDs.isEmpty else {
            return OperationHistoryClearResult(
                provider: provider,
                deletedReportIDs: [],
                deletedPreviewIDs: [],
                deletedItemCount: 0
            )
        }
        let orderedIDs = reportIDs.sorted { $0.uuidString < $1.uuidString }
        let result = try withLockedDatabase { database in
            try transaction(database) {
                let placeholders = Array(repeating: "?", count: orderedIDs.count)
                    .joined(separator: ", ")
                let candidates = try historyDeletionCandidates(
                    whereClause: "WHERE provider = ? AND id IN (\(placeholders))",
                    values: [.text(provider.rawValue)] + orderedIDs.map {
                        .text($0.uuidString.lowercased())
                    },
                    database: database
                )
                guard Set(candidates.map(\.reportID)) == reportIDs else {
                    throw PersistentStateError.invalidRecord(
                        "Operation history changed after clear confirmation. Refresh and confirm again."
                    )
                }
                let deletedItemCount = try deleteHistoryBundles(
                    candidates,
                    database: database
                )
                return OperationHistoryClearResult(
                    provider: provider,
                    deletedReportIDs: candidates.map(\.reportID),
                    deletedPreviewIDs: candidates.map(\.previewID),
                    deletedItemCount: deletedItemCount
                )
            }
        }

        let remaining = try reportIDs.compactMap { try operationReport(id: $0) }
        guard remaining.isEmpty else {
            throw PersistentStateError.invalidRecord(
                "Operation history clear committed, but exact Report readback failed. Refresh before retrying."
            )
        }
        return result
    }
}

private struct OperationHistoryDeletionCandidate {
    let reportID: UUID
    let previewID: UUID
    let itemCount: Int
}

enum RepositorySQLiteValue {
    case text(String)
    case int64(Int64)
    case null

    static func optionalText(_ value: String?) -> Self {
        value.map(Self.text) ?? .null
    }

    static func optionalInt64(_ value: Int64?) -> Self {
        value.map(Self.int64) ?? .null
    }
}

extension SQLiteStateStore {
    func pruneOperationHistory(
        for provider: AgentSystem,
        database: OpaquePointer
    ) throws -> OperationHistoryPruneResult {
        let candidates = try historyDeletionCandidates(
            whereClause: "WHERE provider = ?",
            values: [
                .text(provider.rawValue),
            ],
            suffix: "LIMIT -1 OFFSET ?",
            suffixValues: [.int64(Int64(historyRetentionPolicy.maximumReportsPerProvider))],
            database: database
        )
        let deletedItemCount = try deleteHistoryBundles(candidates, database: database)

        let retainedCounts = try query(
            "SELECT COUNT(*) FROM operation_reports WHERE provider = ?",
            values: [.text(provider.rawValue)],
            database: database
        ) { statement in
            Int(sqlite3_column_int64(statement, 0))
        }
        guard let retainedReportCount = retainedCounts.first,
              retainedReportCount <= historyRetentionPolicy.maximumReportsPerProvider else {
            throw PersistentStateError.invalidRecord(
                "Operation history still exceeds the configured provider retention limit."
            )
        }

        return OperationHistoryPruneResult(
            provider: provider,
            retainedReportCount: retainedReportCount,
            deletedReportIDs: candidates.map(\.reportID),
            deletedPreviewIDs: candidates.map(\.previewID),
            deletedItemCount: deletedItemCount
        )
    }

    fileprivate func historyDeletionCandidates(
        whereClause: String,
        values: [RepositorySQLiteValue],
        suffix: String = "",
        suffixValues: [RepositorySQLiteValue] = [],
        database: OpaquePointer
    ) throws -> [OperationHistoryDeletionCandidate] {
        try query(
            """
            SELECT id, preview_id, item_count
            FROM operation_reports
            \(whereClause)
            ORDER BY completed_at DESC, id DESC
            \(suffix)
            """,
            values: values + suffixValues,
            database: database
        ) { statement in
            guard let reportID = UUID(uuidString: try requiredText(statement, 0)),
                  let previewID = UUID(uuidString: try requiredText(statement, 1)) else {
                throw PersistentStateError.invalidRecord(
                    "Operation history contains an invalid Report or Preview ID."
                )
            }
            return OperationHistoryDeletionCandidate(
                reportID: reportID,
                previewID: previewID,
                itemCount: Int(sqlite3_column_int64(statement, 2))
            )
        }
    }

    fileprivate func deleteHistoryBundles(
        _ candidates: [OperationHistoryDeletionCandidate],
        database: OpaquePointer
    ) throws -> Int {
        var deletedItemCount = 0
        for candidate in candidates {
            try execute(
                "DELETE FROM operation_items WHERE preview_id = ? AND report_id = ?",
                values: [
                    .text(candidate.previewID.uuidString.lowercased()),
                    .text(candidate.reportID.uuidString.lowercased()),
                ],
                database: database
            )
            let itemChanges = Int(sqlite3_changes(database))
            guard itemChanges == candidate.itemCount else {
                throw PersistentStateError.invalidRecord(
                    "Report item count changed during history deletion: \(candidate.reportID.uuidString)."
                )
            }
            deletedItemCount += itemChanges

            try execute(
                "DELETE FROM operation_reports WHERE id = ? AND preview_id = ?",
                values: [
                    .text(candidate.reportID.uuidString.lowercased()),
                    .text(candidate.previewID.uuidString.lowercased()),
                ],
                database: database
            )
            guard sqlite3_changes(database) == 1 else {
                throw PersistentStateError.invalidRecord(
                    "Report changed during history deletion: \(candidate.reportID.uuidString)."
                )
            }

            try execute(
                "DELETE FROM operation_previews WHERE id = ? AND status = 'consumed'",
                values: [.text(candidate.previewID.uuidString.lowercased())],
                database: database
            )
            guard sqlite3_changes(database) == 1 else {
                throw PersistentStateError.invalidRecord(
                    "Only a consumed Preview can be deleted with its Report: \(candidate.previewID.uuidString)."
                )
            }
        }
        return deletedItemCount
    }

    func validate(_ checkpoint: ProviderCheckpointRecord) throws {
        guard !checkpoint.inventoryHash.isEmpty else {
            throw PersistentStateError.invalidRecord("Inventory hash is empty.")
        }
    }

    func validate(
        _ membership: TrashMembershipRecord,
        checkpoint: ProviderCheckpointRecord
    ) throws {
        guard membership.provider == checkpoint.provider else {
            throw PersistentStateError.providerMismatch(
                expected: checkpoint.provider,
                found: membership.provider
            )
        }
        let expectedKey = "\(membership.provider.rawValue):\(membership.nativeSessionID)"
        guard membership.managerKey == expectedKey else {
            throw PersistentStateError.invalidRecord("Trash membership manager key is inconsistent.")
        }
        guard membership.nativeStateAtEntry == .active || membership.nativeStateAtEntry == .archived else {
            throw PersistentStateError.invalidRecord("Trash entry native state must be active or archived.")
        }
        guard checkpoint.inventoryComplete else {
            throw PersistentStateError.invalidRecord("Trash membership requires a complete inventory checkpoint.")
        }
        guard membership.providerInventoryHashAtEntry == checkpoint.inventoryHash else {
            throw PersistentStateError.invalidRecord("Trash membership inventory hash does not match checkpoint.")
        }
        guard !membership.nativeSessionID.isEmpty, !membership.titleAtEntry.isEmpty else {
            throw PersistentStateError.invalidRecord("Trash membership identity is empty.")
        }
    }

    func validate(
        _ preview: PersistentOperationPreview,
        checkpoint: ProviderCheckpointRecord,
        requiresCompleteProtection: Bool = true
    ) throws {
        guard preview.provider == checkpoint.provider else {
            throw PersistentStateError.providerMismatch(expected: checkpoint.provider, found: preview.provider)
        }
        guard checkpoint.inventoryComplete else {
            throw PersistentStateError.invalidRecord("Preview requires a complete inventory checkpoint.")
        }
        if requiresCompleteProtection, !checkpoint.protectionComplete {
            throw PersistentStateError.invalidRecord(
                "This Preview requires a complete protection checkpoint."
            )
        }
        guard preview.providerInventoryHash == checkpoint.inventoryHash else {
            throw PersistentStateError.invalidRecord("Preview inventory hash does not match checkpoint.")
        }
        guard preview.status == .prepared else {
            throw PersistentStateError.invalidRecord("A new Preview must be prepared.")
        }
        guard preview.expiresAt > preview.createdAt else {
            throw PersistentStateError.invalidRecord("Preview expiry must be after creation.")
        }
        guard preview.createdAt == PersistentTimestamp.canonical(preview.createdAt),
              preview.expiresAt == PersistentTimestamp.canonical(preview.expiresAt) else {
            throw PersistentStateError.invalidRecord(
                "Preview timestamps must use SQLite millisecond precision before manifest hashing."
            )
        }
        guard !preview.confirmationTokenHash.isEmpty, !preview.manifestHash.isEmpty else {
            throw PersistentStateError.invalidRecord("Preview hashes must not be empty.")
        }
        guard !preview.items.isEmpty else {
            throw PersistentStateError.invalidRecord("Preview item set is empty.")
        }
        var keys: Set<String> = []
        let hasAffectedSetMetadata = preview.items.contains {
            $0.archiveAffectedRole != nil
                || $0.parentNativeSessionID != nil
                || $0.archiveAffectedDepth != nil
        }
        if preview.affectedSetHash != nil || hasAffectedSetMetadata {
            guard preview.operation == .archive || preview.operation == .moveToTrash,
                  let affectedSetHash = preview.affectedSetHash,
                  !affectedSetHash.isEmpty else {
                throw PersistentStateError.invalidRecord(
                    "Affected-set metadata is accepted only on an Archive native transition with a non-empty hash."
                )
            }
            guard try ArchiveAffectedSetPersistence.hash(items: preview.items) == affectedSetHash else {
                throw PersistentStateError.invalidRecord("Archive affected-set hash mismatch.")
            }
            let roots = preview.items.filter { $0.archiveAffectedRole == .selectedRoot }
            guard roots.count == 1,
                  roots[0].parentNativeSessionID == nil,
                  roots[0].archiveAffectedDepth == 0 else {
                throw PersistentStateError.invalidRecord(
                    "Archive affected set requires exactly one depth-zero selected root."
                )
            }
        }
        switch preview.trashMembershipMutation {
        case .add:
            guard preview.operation == .moveToTrash else {
                throw PersistentStateError.invalidRecord(
                    "Trash membership add intent requires Move to Trash."
                )
            }
        case .remove:
            guard preview.operation == .restore
                    || preview.operation == .moveToArchive
                    || preview.operation == .permanentlyDelete else {
                throw PersistentStateError.invalidRecord(
                    "Trash membership remove intent requires Restore, Move to Archive, or Permanent Delete."
                )
            }
        case nil:
            break
        }
        for item in preview.items {
            guard keys.insert(item.managerKey).inserted else {
                throw PersistentStateError.duplicateManagerKey(item.managerKey)
            }
            let expectedKey = "\(preview.provider.rawValue):\(item.nativeSessionID)"
            guard item.managerKey == expectedKey else {
                throw PersistentStateError.invalidRecord("Preview item manager key is inconsistent.")
            }
            guard item.expectedNativeState != .unavailable else {
                throw PersistentStateError.invalidRecord("Preview cannot freeze an unavailable native state.")
            }
            guard !item.expectedProtectionHash.isEmpty, !item.expectedTitle.isEmpty else {
                throw PersistentStateError.invalidRecord("Preview item evidence is incomplete.")
            }
            if let size = item.knownSizeBytes, size < 0 {
                throw PersistentStateError.invalidRecord("Preview item size is negative.")
            }
            if preview.affectedSetHash != nil {
                guard let role = item.archiveAffectedRole,
                      let depth = item.archiveAffectedDepth,
                      depth >= 0 else {
                    throw PersistentStateError.invalidRecord(
                        "Every Archive affected item requires role and non-negative depth."
                    )
                }
                if role == .selectedRoot {
                    guard depth == 0, item.parentNativeSessionID == nil else {
                        throw PersistentStateError.invalidRecord(
                            "Selected Archive root must have depth zero and no parent."
                        )
                    }
                } else {
                    guard depth > 0,
                          let parentID = item.parentNativeSessionID,
                          keys.contains("\(preview.provider.rawValue):\(parentID)") else {
                        throw PersistentStateError.invalidRecord(
                            "Archive descendant parent must precede it in the frozen set."
                        )
                    }
                }
            }
        }
        _ = try checkedKnownSize(preview.items)
    }

    func validate(_ report: PersistentOperationReport) throws {
        guard report.completedAt >= report.startedAt else {
            throw PersistentStateError.invalidRecord("Report completion precedes start.")
        }
        guard !report.items.isEmpty else {
            throw PersistentStateError.invalidRecord("Report item set is empty.")
        }
        var keys: Set<String> = []
        for item in report.items {
            guard keys.insert(item.managerKey).inserted else {
                throw PersistentStateError.duplicateManagerKey(item.managerKey)
            }
            if let bytes = item.verifiedReleasedBytes, bytes < 0 {
                throw PersistentStateError.invalidRecord("Verified released bytes are negative.")
            }
        }
        _ = try checkedReleasedBytes(report.items)
    }

    func upsert(_ checkpoint: ProviderCheckpointRecord, database: OpaquePointer) throws {
        if let existing = try loadCheckpoint(provider: checkpoint.provider, database: database) {
            guard checkpoint.refreshedAt >= existing.refreshedAt else {
                throw PersistentStateError.invalidRecord("Checkpoint would move backward in time.")
            }
            guard checkpoint.refreshedAt != existing.refreshedAt || checkpoint == existing else {
                throw PersistentStateError.invalidRecord(
                    "Different checkpoints share the same refresh timestamp."
                )
            }
        }
        try execute(
            """
            INSERT INTO provider_checkpoints (
                provider, runtime_version, inventory_hash, refreshed_at,
                inventory_complete, protection_complete,
                last_error_code, last_error_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider) DO UPDATE SET
                runtime_version = excluded.runtime_version,
                inventory_hash = excluded.inventory_hash,
                refreshed_at = excluded.refreshed_at,
                inventory_complete = excluded.inventory_complete,
                protection_complete = excluded.protection_complete,
                last_error_code = excluded.last_error_code,
                last_error_message = excluded.last_error_message
            """,
            values: [
                .text(checkpoint.provider.rawValue),
                .optionalText(checkpoint.runtimeVersion),
                .text(checkpoint.inventoryHash),
                .text(encode(checkpoint.refreshedAt)),
                .int64(checkpoint.inventoryComplete ? 1 : 0),
                .int64(checkpoint.protectionComplete ? 1 : 0),
                .optionalText(checkpoint.lastErrorCode),
                .optionalText(checkpoint.lastErrorMessage),
            ],
            database: database
        )
    }

    func loadCheckpoint(
        provider: AgentSystem,
        database: OpaquePointer
    ) throws -> ProviderCheckpointRecord? {
        let rows = try query(
            """
            SELECT provider, runtime_version, inventory_hash, refreshed_at,
                   inventory_complete, protection_complete,
                   last_error_code, last_error_message
            FROM provider_checkpoints WHERE provider = ?
            """,
            values: [.text(provider.rawValue)],
            database: database
        ) { statement in
            guard let storedProvider = AgentSystem(rawValue: try requiredText(statement, 0)) else {
                throw PersistentStateError.invalidRecord("Unknown provider in checkpoint.")
            }
            return ProviderCheckpointRecord(
                provider: storedProvider,
                runtimeVersion: optionalText(statement, 1),
                inventoryHash: try requiredText(statement, 2),
                refreshedAt: try decodeDate(requiredText(statement, 3)),
                inventoryComplete: sqlite3_column_int64(statement, 4) == 1,
                protectionComplete: sqlite3_column_int64(statement, 5) == 1,
                lastErrorCode: optionalText(statement, 6),
                lastErrorMessage: optionalText(statement, 7)
            )
        }
        return rows.first
    }

    func loadTrashMemberships(
        provider: AgentSystem,
        database: OpaquePointer
    ) throws -> [TrashMembershipRecord] {
        try query(
            """
            SELECT provider, native_session_id, manager_key,
                   title_at_entry, project_id_at_entry,
                   working_directory_at_entry, native_state_at_entry,
                   provider_inventory_hash_at_entry, entered_at,
                   last_reconciled_at
            FROM trash_memberships
            WHERE provider = ?
            ORDER BY manager_key
            """,
            values: [.text(provider.rawValue)],
            database: database
        ) { statement in
            guard let storedProvider = AgentSystem(rawValue: try requiredText(statement, 0)),
                  let nativeState = NativeSessionState(rawValue: try requiredText(statement, 6)) else {
                throw PersistentStateError.invalidRecord(
                    "Unknown provider or native state in Trash membership."
                )
            }
            return TrashMembershipRecord(
                provider: storedProvider,
                nativeSessionID: try requiredText(statement, 1),
                managerKey: try requiredText(statement, 2),
                titleAtEntry: try requiredText(statement, 3),
                projectIDAtEntry: optionalText(statement, 4),
                workingDirectoryAtEntry: optionalText(statement, 5),
                nativeStateAtEntry: nativeState,
                providerInventoryHashAtEntry: try requiredText(statement, 7),
                enteredAt: try decodeDate(requiredText(statement, 8)),
                lastReconciledAt: try decodeDate(requiredText(statement, 9))
            )
        }
    }

    func loadDeletedSessions(
        provider: AgentSystem,
        database: OpaquePointer
    ) throws -> [DeletedSessionRecord] {
        try query(
            """
            SELECT provider, native_session_id, manager_key,
                   title_at_deletion, project_id_at_deletion,
                   working_directory_at_deletion, known_size_bytes,
                   provider_inventory_hash_at_deletion, deleted_at,
                   delete_report_id
            FROM deleted_sessions
            WHERE provider = ?
            ORDER BY deleted_at DESC, manager_key
            """,
            values: [.text(provider.rawValue)],
            database: database
        ) { statement in
            guard let storedProvider = AgentSystem(
                rawValue: try requiredText(statement, 0)
            ) else {
                throw PersistentStateError.invalidRecord(
                    "Unknown provider in Deleted session tombstone."
                )
            }
            let reportID: UUID?
            if let rawReportID = optionalText(statement, 9) {
                guard let decoded = UUID(uuidString: rawReportID) else {
                    throw PersistentStateError.invalidRecord(
                        "Deleted session tombstone has an invalid Report ID."
                    )
                }
                reportID = decoded
            } else {
                reportID = nil
            }
            return DeletedSessionRecord(
                provider: storedProvider,
                nativeSessionID: try requiredText(statement, 1),
                managerKey: try requiredText(statement, 2),
                titleAtDeletion: try requiredText(statement, 3),
                projectIDAtDeletion: optionalText(statement, 4),
                workingDirectoryAtDeletion: optionalText(statement, 5),
                knownSizeBytes: optionalInt64(statement, 6),
                providerInventoryHashAtDeletion: try requiredText(statement, 7),
                deletedAt: try decodeDate(requiredText(statement, 8)),
                deleteReportID: reportID
            )
        }
    }

    func loadPreview(id: UUID, database: OpaquePointer) throws -> PersistentOperationPreview? {
        let rows = try query(
            """
            SELECT provider, manager_intent, status, confirmation_token_hash,
                   manifest_hash, provider_inventory_hash, affected_set_hash,
                   trash_membership_mutation, created_at, expires_at
            FROM operation_previews WHERE id = ?
            """,
            values: [.text(id.uuidString.lowercased())],
            database: database
        ) { statement -> (
            AgentSystem, PersistentOperation, PersistentPreviewStatus,
            String, String, String, String?, TrashMembershipMutation?, Date, Date
        ) in
            guard let provider = AgentSystem(rawValue: try requiredText(statement, 0)),
                  let operation = PersistentOperation(rawValue: try requiredText(statement, 1)),
                  let status = PersistentPreviewStatus(rawValue: try requiredText(statement, 2)) else {
                throw PersistentStateError.invalidRecord("Unknown Preview enum value.")
            }
            let membershipMutation: TrashMembershipMutation?
            if let rawMutation = optionalText(statement, 7) {
                guard let decoded = TrashMembershipMutation(rawValue: rawMutation) else {
                    throw PersistentStateError.invalidRecord("Unknown Trash membership mutation.")
                }
                membershipMutation = decoded
            } else {
                membershipMutation = nil
            }
            return (
                provider,
                operation,
                status,
                try requiredText(statement, 3),
                try requiredText(statement, 4),
                try requiredText(statement, 5),
                optionalText(statement, 6),
                membershipMutation,
                try decodeDate(requiredText(statement, 8)),
                try decodeDate(requiredText(statement, 9))
            )
        }
        guard let header = rows.first else { return nil }

        let items = try query(
            """
            SELECT manager_key, native_session_id, expected_native_state,
                   expected_protection_hash, expected_title,
                   expected_project_id, expected_working_directory,
                   known_size_bytes,
                   archive_affected_role, parent_native_session_id,
                   archive_affected_depth
            FROM operation_items WHERE preview_id = ?
            ORDER BY COALESCE(archive_affected_depth, 0), manager_key
            """,
            values: [.text(id.uuidString.lowercased())],
            database: database
        ) { statement in
            guard let state = NativeSessionState(rawValue: try requiredText(statement, 2)) else {
                throw PersistentStateError.invalidRecord("Unknown expected native state.")
            }
            let affectedRole: ArchiveAffectedRole?
            if let rawRole = optionalText(statement, 8) {
                guard let decodedRole = ArchiveAffectedRole(rawValue: rawRole) else {
                    throw PersistentStateError.invalidRecord("Unknown Archive affected role.")
                }
                affectedRole = decodedRole
            } else {
                affectedRole = nil
            }
            return PersistentPreviewItem(
                managerKey: try requiredText(statement, 0),
                nativeSessionID: try requiredText(statement, 1),
                expectedNativeState: state,
                expectedProtectionHash: try requiredText(statement, 3),
                expectedTitle: try requiredText(statement, 4),
                expectedProjectID: optionalText(statement, 5),
                expectedWorkingDirectory: optionalText(statement, 6),
                knownSizeBytes: optionalInt64(statement, 7),
                archiveAffectedRole: affectedRole,
                parentNativeSessionID: optionalText(statement, 9),
                archiveAffectedDepth: optionalInt64(statement, 10).map(Int.init)
            )
        }
        return PersistentOperationPreview(
            id: id,
            provider: header.0,
            operation: header.1,
            status: header.2,
            confirmationTokenHash: header.3,
            manifestHash: header.4,
            providerInventoryHash: header.5,
            affectedSetHash: header.6,
            trashMembershipMutation: header.7,
            createdAt: header.8,
            expiresAt: header.9,
            items: items
        )
    }

    func loadReport(id: UUID, database: OpaquePointer) throws -> PersistentOperationReport? {
        let rows = try query(
            """
            SELECT preview_id, provider, manager_intent, outcome, started_at,
                   completed_at, released_bytes_complete, error_code, error_message
            FROM operation_reports WHERE id = ?
            """,
            values: [.text(id.uuidString.lowercased())],
            database: database
        ) { statement -> (
            UUID, AgentSystem, PersistentOperation, PersistentReportOutcome,
            Date, Date, Bool, String?, String?
        ) in
            guard let previewID = UUID(uuidString: try requiredText(statement, 0)),
                  let provider = AgentSystem(rawValue: try requiredText(statement, 1)),
                  let operation = PersistentOperation(rawValue: try requiredText(statement, 2)),
                  let outcome = PersistentReportOutcome(rawValue: try requiredText(statement, 3)) else {
                throw PersistentStateError.invalidRecord("Unknown Report identity or enum value.")
            }
            return (
                previewID,
                provider,
                operation,
                outcome,
                try decodeDate(requiredText(statement, 4)),
                try decodeDate(requiredText(statement, 5)),
                sqlite3_column_int64(statement, 6) == 1,
                optionalText(statement, 7),
                optionalText(statement, 8)
            )
        }
        guard let header = rows.first else { return nil }

        let items = try query(
            """
            SELECT manager_key, result_outcome, observed_native_state,
                   verified_released_bytes, evidence_at, error_code, error_message
            FROM operation_items WHERE report_id = ? ORDER BY manager_key
            """,
            values: [.text(id.uuidString.lowercased())],
            database: database
        ) { statement in
            guard let outcome = PersistentItemOutcome(rawValue: try requiredText(statement, 1)),
                  let state = NativeSessionState(rawValue: try requiredText(statement, 2)) else {
                throw PersistentStateError.invalidRecord("Unknown report item enum value.")
            }
            return PersistentReportItem(
                managerKey: try requiredText(statement, 0),
                outcome: outcome,
                observedNativeState: state,
                verifiedReleasedBytes: optionalInt64(statement, 3),
                evidenceAt: try decodeDate(requiredText(statement, 4)),
                errorCode: optionalText(statement, 5),
                errorMessage: optionalText(statement, 6)
            )
        }
        return PersistentOperationReport(
            id: id,
            previewID: header.0,
            provider: header.1,
            operation: header.2,
            outcome: header.3,
            startedAt: header.4,
            completedAt: header.5,
            releasedBytesComplete: header.6,
            errorCode: header.7,
            errorMessage: header.8,
            items: items
        )
    }

    func loadHistoryEntry(
        id: UUID,
        database: OpaquePointer
    ) throws -> OperationHistoryEntry? {
        let headers = try query(
            """
            SELECT preview_id, provider, manager_intent, outcome, started_at,
                   completed_at, item_count, succeeded_count, failed_count,
                   unknown_count, verified_released_bytes,
                   released_bytes_complete, error_code, error_message
            FROM operation_reports WHERE id = ?
            """,
            values: [.text(id.uuidString.lowercased())],
            database: database
        ) { statement -> (
            UUID, AgentSystem, PersistentOperation, PersistentReportOutcome,
            Date, Date, Int, Int, Int, Int, Int64, Bool, String?, String?
        ) in
            guard let previewID = UUID(uuidString: try requiredText(statement, 0)),
                  let provider = AgentSystem(rawValue: try requiredText(statement, 1)),
                  let operation = PersistentOperation(rawValue: try requiredText(statement, 2)),
                  let outcome = PersistentReportOutcome(rawValue: try requiredText(statement, 3)) else {
                throw PersistentStateError.invalidRecord(
                    "Unknown operation history Report identity or enum value."
                )
            }
            return (
                previewID,
                provider,
                operation,
                outcome,
                try decodeDate(requiredText(statement, 4)),
                try decodeDate(requiredText(statement, 5)),
                Int(sqlite3_column_int64(statement, 6)),
                Int(sqlite3_column_int64(statement, 7)),
                Int(sqlite3_column_int64(statement, 8)),
                Int(sqlite3_column_int64(statement, 9)),
                sqlite3_column_int64(statement, 10),
                sqlite3_column_int64(statement, 11) == 1,
                optionalText(statement, 12),
                optionalText(statement, 13)
            )
        }
        guard let header = headers.first else { return nil }

        let items = try query(
            """
            SELECT manager_key, native_session_id, expected_native_state,
                   expected_title, expected_project_id, known_size_bytes,
                   result_outcome, observed_native_state,
                   verified_released_bytes, evidence_at, error_code, error_message
            FROM operation_items
            WHERE report_id = ? AND preview_id = ?
            ORDER BY manager_key
            """,
            values: [
                .text(id.uuidString.lowercased()),
                .text(header.0.uuidString.lowercased()),
            ],
            database: database
        ) { statement in
            guard let expectedState = NativeSessionState(rawValue: try requiredText(statement, 2)),
                  let outcome = PersistentItemOutcome(rawValue: try requiredText(statement, 6)),
                  let observedState = NativeSessionState(rawValue: try requiredText(statement, 7)) else {
                throw PersistentStateError.invalidRecord(
                    "Unknown operation history Item enum value."
                )
            }
            return OperationHistoryItem(
                managerKey: try requiredText(statement, 0),
                nativeSessionID: try requiredText(statement, 1),
                expectedNativeState: expectedState,
                sessionTitle: try requiredText(statement, 3),
                projectID: optionalText(statement, 4),
                knownSizeBytes: optionalInt64(statement, 5),
                outcome: outcome,
                observedNativeState: observedState,
                verifiedReleasedBytes: optionalInt64(statement, 8),
                evidenceAt: try decodeDate(requiredText(statement, 9)),
                errorCode: optionalText(statement, 10),
                errorMessage: optionalText(statement, 11)
            )
        }
        let releasedBytes = try items.compactMap(\.verifiedReleasedBytes).reduce(Int64(0)) { total, value in
            let result = total.addingReportingOverflow(value)
            guard value >= 0, !result.overflow else {
                throw PersistentStateError.invalidRecord(
                    "Operation history Item released bytes are invalid: \(id.uuidString)."
                )
            }
            return result.partialValue
        }
        guard items.count == header.6,
              items.filter({ $0.outcome == .success }).count == header.7,
              items.filter({ $0.outcome == .failure }).count == header.8,
              items.filter({ $0.outcome == .unknown }).count == header.9,
              releasedBytes == header.10 else {
            throw PersistentStateError.invalidRecord(
                "Operation history Report summary does not match its Items: \(id.uuidString)."
            )
        }
        return OperationHistoryEntry(
            reportID: id,
            previewID: header.0,
            provider: header.1,
            operation: header.2,
            outcome: header.3,
            startedAt: header.4,
            completedAt: header.5,
            itemCount: header.6,
            successCount: header.7,
            failureCount: header.8,
            unknownCount: header.9,
            verifiedReleasedBytes: header.10,
            releasedBytesComplete: header.11,
            errorCode: header.12,
            errorMessage: header.13,
            items: items
        )
    }

    func transaction<T>(_ database: OpaquePointer, body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE", values: [], database: database)
        do {
            let result = try body()
            try execute("COMMIT", values: [], database: database)
            return result
        } catch {
            try? execute("ROLLBACK", values: [], database: database)
            throw error
        }
    }

    func execute(
        _ sql: String,
        values: [RepositorySQLiteValue],
        database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            throw repositoryError("prepare", prepareResult, database)
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, database: database)
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE else {
            throw repositoryError("execute", stepResult, database)
        }
    }

    func query<T>(
        _ sql: String,
        values: [RepositorySQLiteValue],
        database: OpaquePointer,
        decode: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw repositoryError("prepare", prepareResult, database)
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, database: database)

        var rows: [T] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { return rows }
            guard stepResult == SQLITE_ROW else {
                throw repositoryError("query", stepResult, database)
            }
            rows.append(try decode(statement))
        }
    }

    func bind(
        _ values: [RepositorySQLiteValue],
        to statement: OpaquePointer?,
        database: OpaquePointer
    ) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text):
                result = text.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, repositorySQLiteTransient)
                }
            case let .int64(number):
                result = sqlite3_bind_int64(statement, index, number)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw repositoryError("bind", result, database)
            }
        }
    }

    func requiredText(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            throw PersistentStateError.invalidRecord("Required SQLite text column is null.")
        }
        return String(cString: text)
    }

    func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    func repositoryError(
        _ operation: String,
        _ code: Int32,
        _ database: OpaquePointer
    ) -> SQLiteStateStoreError {
        SQLiteStateStoreError.sqlite(
            operation: "repository \(operation)",
            code: code,
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func decodeDate(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = standard.date(from: value) else {
            throw PersistentStateError.invalidRecord("Invalid SQLite timestamp: \(value)")
        }
        return date
    }

    func sqlLikeContainsPattern(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    func checkedKnownSize(_ items: [PersistentPreviewItem]) throws -> Int64 {
        try items.compactMap(\.knownSizeBytes).reduce(0) { total, value in
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else {
                throw PersistentStateError.invalidRecord("Known size total overflowed Int64.")
            }
            return result.partialValue
        }
    }

    func checkedReleasedBytes(_ items: [PersistentReportItem]) throws -> Int64 {
        try items.compactMap(\.verifiedReleasedBytes).reduce(0) { total, value in
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else {
                throw PersistentStateError.invalidRecord("Released byte total overflowed Int64.")
            }
            return result.partialValue
        }
    }

    func insertOperationReportAndConsumePreview(
        _ report: PersistentOperationReport,
        expectedPreview preview: PersistentOperationPreview,
        database: OpaquePointer
    ) throws {
        guard preview.provider == report.provider,
              preview.operation == report.operation else {
            throw PersistentStateError.invalidRecord(
                "Report identity does not match the frozen Preview."
            )
        }
        let previewKeys = Set(preview.items.map(\.managerKey))
        let reportKeys = Set(report.items.map(\.managerKey))
        guard previewKeys == reportKeys,
              reportKeys.count == report.items.count else {
            throw PersistentStateError.previewItemSetMismatch
        }

        try execute(
            """
            INSERT INTO operation_reports (
                id, preview_id, provider, operation, outcome,
                started_at, completed_at, item_count, succeeded_count,
                failed_count, unknown_count, verified_released_bytes,
                released_bytes_complete, error_code, error_message,
                manager_intent
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .text(report.id.uuidString.lowercased()),
                .text(report.previewID.uuidString.lowercased()),
                .text(report.provider.rawValue),
                .text(report.operation.legacyOperationRawValue),
                .text(report.outcome.rawValue),
                .text(encode(report.startedAt)),
                .text(encode(report.completedAt)),
                .int64(Int64(report.items.count)),
                .int64(Int64(report.successCount)),
                .int64(Int64(report.failureCount)),
                .int64(Int64(report.unknownCount)),
                .int64(try checkedReleasedBytes(report.items)),
                .int64(report.releasedBytesComplete ? 1 : 0),
                .optionalText(report.errorCode),
                .optionalText(report.errorMessage),
                .text(report.operation.rawValue),
            ],
            database: database
        )

        for item in report.items {
            try execute(
                """
                UPDATE operation_items
                SET report_id = ?, result_outcome = ?, observed_native_state = ?,
                    verified_released_bytes = ?, evidence_at = ?,
                    error_code = ?, error_message = ?
                WHERE preview_id = ? AND manager_key = ? AND report_id IS NULL
                """,
                values: [
                    .text(report.id.uuidString.lowercased()),
                    .text(item.outcome.rawValue),
                    .text(item.observedNativeState.rawValue),
                    .optionalInt64(item.verifiedReleasedBytes),
                    .text(encode(item.evidenceAt)),
                    .optionalText(item.errorCode),
                    .optionalText(item.errorMessage),
                    .text(report.previewID.uuidString.lowercased()),
                    .text(item.managerKey),
                ],
                database: database
            )
            guard sqlite3_changes(database) == 1 else {
                throw PersistentStateError.invalidRecord(
                    "Frozen Preview item was already consumed or changed: \(item.managerKey)"
                )
            }
        }

        try execute(
            "UPDATE operation_previews SET status = 'consumed' WHERE id = ? AND status IN ('prepared', 'executing')",
            values: [.text(report.previewID.uuidString.lowercased())],
            database: database
        )
        guard sqlite3_changes(database) == 1 else {
            throw PersistentStateError.invalidRecord("Preview is not executable.")
        }
    }
}
