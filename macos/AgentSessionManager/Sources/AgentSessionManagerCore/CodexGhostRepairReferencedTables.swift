import Foundation

/// Required-column contracts shared by snapshot analysis and compatibility
/// inspection. These are not full DDL or new-runtime mutation acceptance.
enum CodexGhostRepairReferencedTables {
    struct Table {
        let table: String
        let columns: [String]
        let exact: Bool
    }

    static let byDatabase: [
        CodexGhostRepairSnapshotAnalysisDatabase: [Table]
    ] = [
        .summaries: [
            .init(
                table: "thread_turn_summaries",
                columns: [
                    "principal_key", "host_key", "thread_id", "summary",
                    "compact_summary", "compact_summary_turn_key",
                    "revision", "updated_at",
                ],
                exact: true
            ),
        ],
        // Read-only state checks require the referenced identity column, not
        // every column managed by Codex's independent SQLx migrations.
        .state: [
            .init(table: "threads", columns: ["id"], exact: false),
        ],
        .threadHistory: [
            .init(
                table: "thread_turns",
                columns: [
                    "thread_id", "turn_id", "rollout_ordinal", "status",
                    "error_json", "started_at", "completed_at",
                    "duration_ms", "first_user_item_id",
                    "final_agent_item_id", "rollout_byte_offset",
                    "rollout_end_ordinal", "rollout_end_byte_offset",
                ],
                exact: true
            ),
            .init(
                table: "thread_items",
                columns: [
                    "thread_id", "turn_id", "item_id", "rollout_ordinal",
                    "created_at_ms", "item_json", "item_type",
                    "updated_at_ordinal",
                ],
                exact: true
            ),
            .init(
                table: "thread_history_projection_state",
                columns: [
                    "thread_id", "next_rollout_byte_offset",
                    "next_rollout_ordinal",
                ],
                exact: true
            ),
        ],
    ]
}
