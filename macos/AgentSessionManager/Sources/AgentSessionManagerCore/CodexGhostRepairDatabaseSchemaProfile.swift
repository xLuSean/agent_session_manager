import Foundation

struct CodexGhostRepairSQLiteColumnContract: Equatable, Sendable {
    let name: String
    let declaredType: String
    let notNull: Bool
    let defaultValue: String?
    let primaryKeyPosition: Int
}

struct CodexGhostRepairSQLiteIndexContract: Equatable, Sendable {
    let name: String
    let unique: Bool
    let partial: Bool
    let columns: [String]
}

struct CodexGhostRepairSQLiteTableContract: Equatable, Sendable {
    let table: String
    let columns: [CodexGhostRepairSQLiteColumnContract]
    let exactColumns: Bool
    let customIndexes: [CodexGhostRepairSQLiteIndexContract]
}

struct CodexGhostRepairDatabaseSchemaProfile: Equatable, Sendable {
    let identifier: String
    let databaseVersions: [
        CodexGhostRepairSnapshotAnalysisDatabase: Int32
    ]
    let desktopTables: [CodexGhostRepairSQLiteTableContract]

    static let desktopV32 = makeDesktopProfile(
        identifier: "desktop-v32",
        version: 32,
        automationColumns: automationV32Columns,
        automationIndexes: []
    )

    static let desktopV33 = makeDesktopProfile(
        identifier: "desktop-v33",
        version: 33,
        automationColumns: automationV33AndV34Columns,
        automationIndexes: automationV33AndV34Indexes
    )

    /// Desktop v34 changes the migration identity but preserves the exact
    /// seven-table column/default/primary-key contract and owner index from
    /// v33. It remains a separate profile so version drift cannot be hidden.
    static let desktopV34 = makeDesktopProfile(
        identifier: "desktop-v34",
        version: 34,
        automationColumns: automationV33AndV34Columns,
        automationIndexes: automationV33AndV34Indexes
    )

    static let admittedProfiles = [desktopV32, desktopV33, desktopV34]

    static func admitted(desktopUserVersion: Int32)
        -> CodexGhostRepairDatabaseSchemaProfile?
    {
        admittedProfiles.first {
            $0.databaseVersions[.desktop] == desktopUserVersion
        }
    }

    static func admitted(
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    ) -> CodexGhostRepairDatabaseSchemaProfile? {
        guard databases.map(\.database)
                == CodexGhostRepairSnapshotAnalysisDatabase.allCases,
              let desktop = databases.first(where: { $0.database == .desktop }),
              let profile = admitted(
                  desktopUserVersion: desktop.schemaVersion
              ),
              databases.allSatisfy({ evidence in
                  profile.databaseVersions[evidence.database]
                      == evidence.schemaVersion
                      && evidence.integrityCheckPassed
                      && evidence.foreignKeyViolationCount == 0
              }) else {
            return nil
        }
        return profile
    }

    private static func makeDesktopProfile(
        identifier: String,
        version: Int32,
        automationColumns: [CodexGhostRepairSQLiteColumnContract],
        automationIndexes: [CodexGhostRepairSQLiteIndexContract]
    ) -> CodexGhostRepairDatabaseSchemaProfile {
        .init(
            identifier: identifier,
            databaseVersions: [
                .desktop: version,
                .summaries: 2,
                .state: 0,
                .threadHistory: 0,
            ],
            desktopTables: [
                .init(
                    table: "local_thread_catalog",
                    columns: [
                        column("host_id", "TEXT", notNull: true, primaryKey: 1),
                        column("thread_id", "TEXT", notNull: true, primaryKey: 2),
                        column("display_title", "TEXT", notNull: true),
                        column("source_created_at", "REAL", notNull: true),
                        column("source_updated_at", "REAL", notNull: true),
                        column("cwd", "TEXT"),
                        column("source_kind", "TEXT", notNull: true),
                        column("source_detail", "TEXT"),
                        column("model_provider", "TEXT"),
                        column("git_branch", "TEXT"),
                        column("observation_sequence", "INTEGER", notNull: true),
                        column("missing_candidate", "INTEGER", notNull: true, defaultValue: "0"),
                        column("thread_source", "TEXT"),
                        column("source_recency_at", "REAL", notNull: true, defaultValue: "0"),
                        column("pending_observed_title", "INTEGER", notNull: true, defaultValue: "0"),
                        column("project_id", "TEXT"),
                        column("conversation_origin", "TEXT"),
                    ],
                    exactColumns: true,
                    customIndexes: localThreadCatalogIndexes
                ),
                .init(
                    table: "automation_runs",
                    columns: [
                        column("thread_id", "TEXT", primaryKey: 1),
                        column("automation_id", "TEXT", notNull: true),
                        column("status", "TEXT", notNull: true),
                        column("read_at", "INTEGER"),
                        column("thread_title", "TEXT"),
                        column("source_cwd", "TEXT"),
                        column("inbox_title", "TEXT"),
                        column("inbox_summary", "TEXT"),
                        column("created_at", "INTEGER", notNull: true),
                        column("updated_at", "INTEGER", notNull: true),
                        column("archived_user_message", "TEXT"),
                        column("archived_assistant_message", "TEXT"),
                        column("archived_reason", "TEXT"),
                    ],
                    exactColumns: true,
                    customIndexes: []
                ),
                .init(
                    table: "automations",
                    columns: automationColumns,
                    exactColumns: true,
                    customIndexes: automationIndexes
                ),
                .init(
                    table: "inbox_items",
                    columns: [
                        column("id", "TEXT", primaryKey: 1),
                        column("title", "TEXT"),
                        column("description", "TEXT"),
                        column("thread_id", "TEXT"),
                        column("read_at", "INTEGER"),
                        column("created_at", "INTEGER"),
                    ],
                    exactColumns: true,
                    customIndexes: []
                ),
                .init(
                    table: "thread_timeline_ledger",
                    columns: [
                        column("host_id", "TEXT", notNull: true, primaryKey: 1),
                        column("thread_id", "TEXT", notNull: true, primaryKey: 2),
                        column("sequence", "INTEGER", notNull: true, primaryKey: 3),
                        column("record_id", "TEXT", notNull: true),
                        column("payload_json", "TEXT", notNull: true),
                    ],
                    exactColumns: true,
                    customIndexes: []
                ),
                .init(
                    table: "local_thread_catalog_metadata",
                    columns: [
                        column("id", "INTEGER", primaryKey: 1),
                        column("catalog_revision", "INTEGER", notNull: true, defaultValue: "0"),
                    ],
                    exactColumns: true,
                    customIndexes: []
                ),
                .init(
                    table: "local_thread_catalog_sync_state",
                    columns: [
                        column("host_id", "TEXT", primaryKey: 1),
                        column("watermark_updated_at", "REAL"),
                        column("initial_build_complete", "INTEGER", notNull: true, defaultValue: "0"),
                        column("observation_sequence", "INTEGER", notNull: true, defaultValue: "0"),
                        column("last_full_reconciled_at", "INTEGER"),
                    ],
                    exactColumns: true,
                    customIndexes: []
                ),
            ]
        )
    }

    private static let automationV32Columns: [
        CodexGhostRepairSQLiteColumnContract
    ] = [
        column("id", "TEXT", primaryKey: 1),
        column("name", "TEXT", notNull: true),
        column("prompt", "TEXT", notNull: true),
        column("status", "TEXT", notNull: true, defaultValue: "'ACTIVE'"),
        column("next_run_at", "INTEGER"),
        column("last_run_at", "INTEGER"),
        column("cwds", "TEXT", notNull: true, defaultValue: "'[]'"),
        column(
            "rrule",
            "TEXT",
            notNull: true,
            defaultValue: "'FREQ=HOURLY;INTERVAL=24;BYMINUTE=0'"
        ),
        column("model", "TEXT"),
        column("reasoning_effort", "TEXT"),
        column("created_at", "INTEGER", notNull: true),
        column("updated_at", "INTEGER", notNull: true),
        column("target_type", "TEXT"),
        column("project_id", "TEXT"),
    ]

    /// The Desktop catalog indexes are part of the durable schema contract in
    /// every admitted profile. They predate Desktop v34; the v34 live source
    /// observation exposed that the earlier deterministic fixture had omitted
    /// them and therefore could not detect an outdated empty-index contract.
    private static let localThreadCatalogIndexes = [
        CodexGhostRepairSQLiteIndexContract(
            name: "local_thread_catalog_created_idx",
            unique: false,
            partial: true,
            columns: [
                "host_id", "source_created_at", "source_updated_at",
                "thread_id",
            ]
        ),
        CodexGhostRepairSQLiteIndexContract(
            name: "local_thread_catalog_cwd_created_idx",
            unique: false,
            partial: true,
            columns: [
                "host_id", "cwd", "source_created_at", "source_updated_at",
                "thread_id",
            ]
        ),
        CodexGhostRepairSQLiteIndexContract(
            name: "local_thread_catalog_cwd_updated_idx",
            unique: false,
            partial: true,
            columns: [
                "host_id", "cwd", "source_recency_at", "source_created_at",
                "thread_id",
            ]
        ),
        CodexGhostRepairSQLiteIndexContract(
            name: "local_thread_catalog_origin_updated_idx",
            unique: false,
            partial: true,
            columns: [
                "host_id", "conversation_origin", "source_recency_at",
                "source_created_at", "thread_id",
            ]
        ),
        CodexGhostRepairSQLiteIndexContract(
            name: "local_thread_catalog_project_updated_idx",
            unique: false,
            partial: true,
            columns: [
                "host_id", "project_id", "source_recency_at",
                "source_created_at", "thread_id",
            ]
        ),
        CodexGhostRepairSQLiteIndexContract(
            name: "local_thread_catalog_thread_lookup_idx",
            unique: false,
            partial: true,
            columns: [
                "thread_id", "source_recency_at", "source_created_at",
                "host_id",
            ]
        ),
        CodexGhostRepairSQLiteIndexContract(
            name: "local_thread_catalog_updated_idx",
            unique: false,
            partial: true,
            columns: [
                "host_id", "source_recency_at", "source_created_at",
                "thread_id",
            ]
        ),
    ]

    private static let automationV33AndV34Columns = automationV32Columns + [
        column("kind", "TEXT", notNull: true, defaultValue: "'cron'"),
        column("target_thread_id", "TEXT"),
        column("execution_environment", "TEXT"),
        column("local_environment_config_path", "TEXT"),
        column("plugin_template_id", "TEXT"),
        column("notification_policy", "TEXT"),
        column("account_id", "TEXT"),
        column("user_id", "TEXT"),
        column("installation_id", "TEXT"),
        column("legacy_automation_id", "TEXT"),
    ]

    private static let automationV33AndV34Indexes = [
        CodexGhostRepairSQLiteIndexContract(
            name: "automations_owner_idx",
            unique: false,
            partial: false,
            columns: ["account_id", "user_id", "installation_id"]
        ),
    ]

    private static func column(
        _ name: String,
        _ type: String,
        notNull: Bool = false,
        defaultValue: String? = nil,
        primaryKey: Int = 0
    ) -> CodexGhostRepairSQLiteColumnContract {
        .init(
            name: name,
            declaredType: type,
            notNull: notNull,
            defaultValue: defaultValue,
            primaryKeyPosition: primaryKey
        )
    }
}
