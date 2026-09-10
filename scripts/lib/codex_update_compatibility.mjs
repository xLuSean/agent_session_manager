export const AUDITED_GHOST_REPAIR_RUNTIME = "0.149.0";
export const AUDITED_GHOST_REPAIR_RUNTIME_PROFILES = Object.freeze({
  "0.149.0": "desktop-v32",
  "0.151.0-alpha.7.2": "desktop-v33",
  "0.151.0": "desktop-v33",
  "0.152.1": "desktop-v34",
  "0.153.1": "desktop-v34",
  "0.153.2": "desktop-v34",
  "0.153.4": "desktop-v34",
});

// Metadata observed by the explicit read-only update audit on 2026-08-31.
// This is deliberately not an admitted schema profile. Recording the exact
// candidate prevents a future update from treating "version 33" as a one-line
// constant change before the reader, planner, mutator, and 148-item acceptance
// have all been rebuilt against the new semantics.
export const UNADMITTED_GHOST_REPAIR_V33_CANDIDATE = Object.freeze({
  desktopUserVersion: 33,
  desktopRuntimeVersion: "0.151.0-alpha.7.2",
  automationColumns: Object.freeze([
    "id", "name", "prompt", "status", "next_run_at", "last_run_at",
    "cwds", "rrule", "model", "reasoning_effort", "created_at",
    "updated_at", "target_type", "project_id", "kind",
    "target_thread_id", "execution_environment",
    "local_environment_config_path", "plugin_template_id",
    "notification_policy", "account_id", "user_id", "installation_id",
    "legacy_automation_id",
  ]),
  addedAutomationColumns: Object.freeze([
    "kind", "target_thread_id", "execution_environment",
    "local_environment_config_path", "plugin_template_id",
    "notification_policy", "account_id", "user_id", "installation_id",
    "legacy_automation_id",
  ]),
  addedAutomationIndex: Object.freeze({
    name: "automations_owner_idx",
    columns: Object.freeze(["account_id", "user_id", "installation_id"]),
  }),
  metadataObservationOnly: true,
  deterministicSchemaContractAccepted: false,
  deterministic148ItemAcceptancePassed: false,
  packagedAppWiringAllowed: false,
  mutationAuthority: "none",
});

export const GHOST_REPAIR_DATABASE_CONTRACT = Object.freeze({
  desktop: Object.freeze({
    fileName: "codex-dev.db",
    relativeDirectory: "sqlite",
    userVersion: 32,
    tables: Object.freeze({
      local_thread_catalog: Object.freeze({
        exact: true,
        columns: Object.freeze([
          "host_id", "thread_id", "display_title", "source_created_at",
          "source_updated_at", "cwd", "source_kind", "source_detail",
          "model_provider", "git_branch", "observation_sequence",
          "missing_candidate", "thread_source", "source_recency_at",
          "pending_observed_title", "project_id", "conversation_origin",
        ]),
      }),
      automation_runs: Object.freeze({
        exact: true,
        columns: Object.freeze([
          "thread_id", "automation_id", "status", "read_at",
          "thread_title", "source_cwd", "inbox_title", "inbox_summary",
          "created_at", "updated_at", "archived_user_message",
          "archived_assistant_message", "archived_reason",
        ]),
      }),
      automations: Object.freeze({
        exact: true,
        columns: Object.freeze([
          "id", "name", "prompt", "status", "next_run_at", "last_run_at",
          "cwds", "rrule", "model", "reasoning_effort", "created_at",
          "updated_at", "target_type", "project_id",
        ]),
      }),
      inbox_items: Object.freeze({
        exact: true,
        columns: Object.freeze([
          "id", "title", "description", "thread_id", "read_at",
          "created_at",
        ]),
      }),
      thread_timeline_ledger: Object.freeze({
        exact: true,
        columns: Object.freeze([
          "host_id", "thread_id", "sequence", "record_id", "payload_json",
        ]),
      }),
      local_thread_catalog_metadata: Object.freeze({
        exact: true,
        columns: Object.freeze(["id", "catalog_revision"]),
      }),
      local_thread_catalog_sync_state: Object.freeze({
        exact: true,
        columns: Object.freeze([
          "host_id", "watermark_updated_at", "initial_build_complete",
          "observation_sequence", "last_full_reconciled_at",
        ]),
      }),
    }),
  }),
  summaries: Object.freeze({
    fileName: "codex-thread-summaries-dev.db",
    relativeDirectory: "sqlite",
    userVersion: 2,
    tables: Object.freeze({
      thread_turn_summaries: Object.freeze({
        exact: true,
        columns: Object.freeze([
          "principal_key", "host_key", "thread_id", "summary",
          "compact_summary", "compact_summary_turn_key", "revision",
          "updated_at",
        ]),
      }),
    }),
  }),
  state: Object.freeze({
    fileName: "state_5.sqlite",
    relativeDirectory: "",
    userVersion: 0,
    tables: Object.freeze({
      threads: Object.freeze({
        exact: false,
        columns: Object.freeze(["id"]),
      }),
    }),
  }),
  threadHistory: Object.freeze({
    fileName: "thread_history_1.sqlite",
    relativeDirectory: "",
    userVersion: 0,
    tables: Object.freeze({
      thread_turns: Object.freeze({
        exact: true,
        columns: Object.freeze([
          "thread_id", "turn_id", "rollout_ordinal", "status", "error_json",
          "started_at", "completed_at", "duration_ms", "first_user_item_id",
          "final_agent_item_id", "rollout_byte_offset", "rollout_end_ordinal",
          "rollout_end_byte_offset",
        ]),
      }),
      thread_items: Object.freeze({
        exact: true,
        columns: Object.freeze([
          "thread_id", "turn_id", "item_id", "rollout_ordinal",
          "created_at_ms", "item_json", "item_type", "updated_at_ordinal",
        ]),
      }),
      thread_history_projection_state: Object.freeze({
        exact: true,
        columns: Object.freeze([
          "thread_id", "next_rollout_byte_offset", "next_rollout_ordinal",
        ]),
      }),
    }),
  }),
});

// M4f-20 completed the deterministic v33 reader, classifier, frozen-plan,
// mixed-mutator and exact 148-item acceptance. Later packaged acceptance
// admitted only the two exact v0.151 runtime/source pairs listed above.
export const GHOST_REPAIR_DATABASE_CONTRACT_V33 = Object.freeze({
  identifier: "desktop-v33",
  databases: Object.freeze({
    ...GHOST_REPAIR_DATABASE_CONTRACT,
    desktop: Object.freeze({
      ...GHOST_REPAIR_DATABASE_CONTRACT.desktop,
      userVersion: 33,
      tables: Object.freeze({
        ...GHOST_REPAIR_DATABASE_CONTRACT.desktop.tables,
        automations: Object.freeze({
          exact: true,
          columns: UNADMITTED_GHOST_REPAIR_V33_CANDIDATE.automationColumns,
          requiredIndexes: Object.freeze({
            automations_owner_idx: Object.freeze([
              "account_id", "user_id", "installation_id",
            ]),
          }),
        }),
      }),
    }),
  }),
  deterministicSchemaContractAccepted: true,
  deterministic148ItemAcceptancePassed: true,
  runtimeAdmissionGranted: true,
  mutationAuthority: "none",
});

// Codex 0.152.1 increments Desktop user_version to 34 while preserving the
// exact v33 table, column/default/primary-key and owner-index contract. It is
// modeled separately so a future v34 drift cannot be hidden by structural
// aliasing or a version range.
export const GHOST_REPAIR_DATABASE_CONTRACT_V34 = Object.freeze({
  identifier: "desktop-v34",
  databases: Object.freeze({
    ...GHOST_REPAIR_DATABASE_CONTRACT_V33.databases,
    desktop: Object.freeze({
      ...GHOST_REPAIR_DATABASE_CONTRACT_V33.databases.desktop,
      userVersion: 34,
    }),
  }),
  deterministicSchemaContractAccepted: true,
  deterministic148ItemAcceptancePassed: true,
  runtimeAdmissionGranted: true,
  mutationAuthority: "none",
});

export const GHOST_REPAIR_DATABASE_CONTRACTS = Object.freeze([
  Object.freeze({
    identifier: "desktop-v32",
    databases: GHOST_REPAIR_DATABASE_CONTRACT,
    deterministicSchemaContractAccepted: true,
    deterministic148ItemAcceptancePassed: true,
    runtimeAdmissionGranted: true,
    mutationAuthority: "none",
  }),
  GHOST_REPAIR_DATABASE_CONTRACT_V33,
  GHOST_REPAIR_DATABASE_CONTRACT_V34,
]);

export function parseCodexVersion(output) {
  const match = /^codex-cli ([0-9][A-Za-z0-9.-]*)\s*$/.exec(output ?? "");
  return match?.[1] ?? null;
}

export function versionsDiverge(left, right) {
  return Boolean(left && right && left !== right);
}

function columnsEqual(actual, expected) {
  return actual.length === expected.length
    && actual.every((column, index) => column === expected[index]);
}

function containsColumns(actual, expected) {
  const actualSet = new Set(actual);
  return expected.every((column) => actualSet.has(column));
}

export function evaluateGhostRepairContract({ runtimeVersion, databases }) {
  const drifts = [];
  let inspectionUnavailable = false;

  const desktopUserVersion = databases?.desktop?.userVersion;
  const schemaProfile = GHOST_REPAIR_DATABASE_CONTRACTS.find(
    (candidate) =>
      candidate.databases.desktop.userVersion === desktopUserVersion,
  );
  if (!databases?.desktop) {
    inspectionUnavailable = true;
  } else if (!schemaProfile) {
    drifts.push(
      `desktop: unsupported user_version ${String(desktopUserVersion)}`,
    );
  }

  const expectedDatabases = schemaProfile?.databases
    ?? GHOST_REPAIR_DATABASE_CONTRACT;

  for (const [role, expected] of Object.entries(expectedDatabases)) {
    const actual = databases?.[role];
    if (!actual) {
      inspectionUnavailable = true;
      drifts.push(`${role}: database metadata unavailable`);
      continue;
    }
    if (role === "desktop" && !schemaProfile) continue;
    if (actual.fileName !== expected.fileName) {
      drifts.push(
        `${role}: expected file ${expected.fileName}, observed ${actual.fileName}`,
      );
    }
    if (actual.userVersion !== expected.userVersion) {
      drifts.push(
        `${role}: expected user_version ${expected.userVersion}, observed ${actual.userVersion}`,
      );
    }
    for (const [table, contract] of Object.entries(expected.tables)) {
      const actualColumns = actual.tables?.[table];
      if (!actualColumns) {
        drifts.push(`${role}.${table}: table metadata unavailable`);
        continue;
      }
      const compatible = contract.exact
        ? columnsEqual(actualColumns, contract.columns)
        : containsColumns(actualColumns, contract.columns);
      if (!compatible) {
        const mode = contract.exact ? "exact columns" : "required columns";
        drifts.push(`${role}.${table}: ${mode} changed`);
      }
      for (const [index, columns] of Object.entries(
        contract.requiredIndexes ?? {},
      )) {
        const actualIndexColumns = actual.indexes?.[table]?.[index];
        if (!actualIndexColumns || !columnsEqual(actualIndexColumns, columns)) {
          drifts.push(`${role}.${table}: required index ${index} changed`);
        }
      }
    }
  }

  let verdict;
  if (inspectionUnavailable) {
    verdict = "blocked_inspection_unavailable";
  } else if (drifts.length > 0) {
    verdict = "blocked_schema_drift";
  } else if (
    AUDITED_GHOST_REPAIR_RUNTIME_PROFILES[runtimeVersion]
      === schemaProfile?.identifier
  ) {
    verdict = "ready_current_build";
  } else {
    verdict = "candidate_requires_runtime_admission";
  }

  return Object.freeze({
    verdict,
    runtimeVersion,
    auditedRuntimeVersion: AUDITED_GHOST_REPAIR_RUNTIME,
    schemaProfileIdentifier: schemaProfile?.identifier ?? null,
    schemaCompatible: drifts.length === 0,
    drifts: Object.freeze([...drifts].sort()),
    sessionRowsRead: 0,
    sqliteWrites: 0,
    mutationAuthority: "none",
  });
}

export function overallCompatibilityVerdict({
  providerLifecycleVerdict,
  desktopLifecycleVerdict,
  ghostRepairVerdict,
}) {
  const blocked = [
    providerLifecycleVerdict,
    desktopLifecycleVerdict,
    ghostRepairVerdict,
  ].some((value) => value?.startsWith("blocked_"));
  if (blocked) return "blocked";

  const reviewRequired = [
    providerLifecycleVerdict,
    desktopLifecycleVerdict,
    ghostRepairVerdict,
  ].some((value) => value !== "ready_current_build");
  return reviewRequired ? "review_required" : "ready";
}
