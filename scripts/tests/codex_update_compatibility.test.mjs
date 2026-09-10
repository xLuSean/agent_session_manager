import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import {
  AUDITED_GHOST_REPAIR_RUNTIME,
  GHOST_REPAIR_DATABASE_CONTRACT,
  GHOST_REPAIR_DATABASE_CONTRACTS,
  GHOST_REPAIR_DATABASE_CONTRACT_V33,
  GHOST_REPAIR_DATABASE_CONTRACT_V34,
  UNADMITTED_GHOST_REPAIR_V33_CANDIDATE,
  evaluateGhostRepairContract,
  overallCompatibilityVerdict,
  parseCodexVersion,
  versionsDiverge,
} from "../lib/codex_update_compatibility.mjs";

const repositoryRoot = resolve(import.meta.dirname, "../..");

function compatibleDatabases(contract = GHOST_REPAIR_DATABASE_CONTRACT) {
  return Object.fromEntries(
    Object.entries(contract).map(([role, databaseContract]) => [
      role,
      {
        fileName: databaseContract.fileName,
        userVersion: databaseContract.userVersion,
        tables: Object.fromEntries(
          Object.entries(databaseContract.tables).map(([table, tableContract]) => [
            table,
            [...tableContract.columns],
          ]),
        ),
        indexes: Object.fromEntries(
          Object.entries(databaseContract.tables)
            .filter(([, tableContract]) => tableContract.requiredIndexes)
            .map(([table, tableContract]) => [
              table,
              Object.fromEntries(
                Object.entries(tableContract.requiredIndexes).map(
                  ([index, columns]) => [index, [...columns]],
                ),
              ),
            ]),
        ),
      },
    ]),
  );
}

test("parses exact Codex version output only", () => {
  assert.equal(parseCodexVersion("codex-cli 0.151.0-alpha.7.2\n"), "0.151.0-alpha.7.2");
  assert.equal(parseCodexVersion("Codex Desktop 0.151.0"), null);
  assert.equal(parseCodexVersion("codex-cli 0.151.0 extra"), null);
});

test("reports Desktop and provider runtime divergence", () => {
  assert.equal(versionsDiverge("0.151.0-alpha.7.2", "0.149.0"), true);
  assert.equal(versionsDiverge("0.149.0", "0.149.0"), false);
  assert.equal(versionsDiverge(null, "0.149.0"), false);
});

test("audited runtime and exact schema are ready", () => {
  const result = evaluateGhostRepairContract({
    runtimeVersion: AUDITED_GHOST_REPAIR_RUNTIME,
    databases: compatibleDatabases(),
  });
  assert.equal(result.verdict, "ready_current_build");
  assert.equal(result.schemaCompatible, true);
  assert.deepEqual(result.drifts, []);
  assert.equal(result.sessionRowsRead, 0);
  assert.equal(result.sqliteWrites, 0);
  assert.equal(result.mutationAuthority, "none");
});

test("compatible schema on a new runtime requires review and never self-admits", () => {
  const result = evaluateGhostRepairContract({
    runtimeVersion: "0.151.0-alpha.7.2",
    databases: compatibleDatabases(),
  });
  assert.equal(result.verdict, "candidate_requires_runtime_admission");
  assert.equal(result.schemaCompatible, true);
});

test("an unknown Desktop user_version blocks Ghost Repair", () => {
  const databases = compatibleDatabases();
  databases.desktop.userVersion = 35;
  const result = evaluateGhostRepairContract({
    runtimeVersion: "0.151.0-alpha.7.2",
    databases,
  });
  assert.equal(result.verdict, "blocked_schema_drift");
  assert.deepEqual(result.drifts, [
    "desktop: unsupported user_version 35",
  ]);
});

test("the exact v34 schema and 0.152.1 runtime are admitted together", () => {
  const databases = compatibleDatabases(
    GHOST_REPAIR_DATABASE_CONTRACT_V34.databases,
  );
  const result = evaluateGhostRepairContract({
    runtimeVersion: "0.152.1",
    databases,
  });
  assert.equal(result.verdict, "ready_current_build");
  assert.equal(result.schemaProfileIdentifier, "desktop-v34");
  assert.deepEqual(result.drifts, []);
  assert.equal(result.sessionRowsRead, 0);
  assert.equal(result.sqliteWrites, 0);
  assert.equal(result.mutationAuthority, "none");
});

test("the exact v34 schema and current 0.153 runtime pair are admitted", () => {
  for (const runtimeVersion of ["0.153.1", "0.153.2"]) {
    const result = evaluateGhostRepairContract({
      runtimeVersion,
      databases: compatibleDatabases(
        GHOST_REPAIR_DATABASE_CONTRACT_V34.databases,
      ),
    });
    assert.equal(result.verdict, "ready_current_build");
    assert.equal(result.schemaProfileIdentifier, "desktop-v34");
    assert.deepEqual(result.drifts, []);
    assert.equal(result.sessionRowsRead, 0);
    assert.equal(result.sqliteWrites, 0);
    assert.equal(result.mutationAuthority, "none");
  }
});

test("only exact 0.153.4 with the v34 schema is newly admitted", () => {
  const databases = compatibleDatabases(
    GHOST_REPAIR_DATABASE_CONTRACT_V34.databases,
  );
  const admitted = evaluateGhostRepairContract({
    runtimeVersion: "0.153.4",
    databases,
  });
  assert.equal(admitted.verdict, "ready_current_build");
  assert.equal(admitted.schemaProfileIdentifier, "desktop-v34");
  assert.equal(admitted.mutationAuthority, "none");

  for (const runtimeVersion of ["0.153.3", "0.153.5"]) {
    const rejected = evaluateGhostRepairContract({
      runtimeVersion,
      databases,
    });
    assert.equal(rejected.verdict, "candidate_requires_runtime_admission");
  }
});

test("0.153.4 fails closed when its Desktop schema is not exact v34", () => {
  const databases = compatibleDatabases(
    GHOST_REPAIR_DATABASE_CONTRACT_V34.databases,
  );
  databases.desktop.userVersion = 35;
  const result = evaluateGhostRepairContract({
    runtimeVersion: "0.153.4",
    databases,
  });
  assert.equal(result.verdict, "blocked_schema_drift");
  assert.deepEqual(result.drifts, ["desktop: unsupported user_version 35"]);
});

test("v34 structure on a different runtime cannot self-admit", () => {
  const result = evaluateGhostRepairContract({
    runtimeVersion: "0.152.2",
    databases: compatibleDatabases(
      GHOST_REPAIR_DATABASE_CONTRACT_V34.databases,
    ),
  });
  assert.equal(result.verdict, "candidate_requires_runtime_admission");
});

test("checked-in v0.152.1 read-only evidence is exact path-free and authority-free", () => {
  const raw = readFileSync(
    resolve(
      repositoryRoot,
      "scripts/fixtures/current-v152-read-only-evidence.json",
    ),
    "utf8",
  );
  const fixture = JSON.parse(raw);
  assert.equal(
    createHash("sha256").update(raw).digest("hex"),
    "6021fab9b9bfcff8431f9142f9031faa8e5da07675a70404c6ce6bec6bbbaf94",
  );
  assert.deepEqual(
    fixture.runtimeProfiles.map((profile) => profile.runtimeVersion),
    ["0.152.1", "0.152.1"],
  );
  assert.notEqual(
    fixture.runtimeProfiles[0].executableSha256,
    fixture.runtimeProfiles[1].executableSha256,
  );
  assert.equal(
    fixture.runtimeProfiles[0].generatedProtocol.schemaBundleSha256,
    fixture.runtimeProfiles[1].generatedProtocol.schemaBundleSha256,
  );
  assert.ok(fixture.runtimeProfiles.every((profile) =>
    profile.missingThreadRead.rpcCode === -32600
      && profile.missingThreadRead.messageTemplate
        === "thread not loaded: {thread_id}"
      && profile.requestBoundary.existingThreadIDsRead === 0
      && profile.requestBoundary.lifecycleMutationRequests === 0));
  assert.equal(fixture.sourceLayout.desktopSchemaProfile, "desktop-v34");
  assert.equal(fixture.databaseMetadata.desktopUserVersion, 34);
  assert.equal(fixture.databaseMetadata.exactV34ContractMatched, true);
  assert.equal(fixture.safetyContract.mutationAuthorityGranted, false);
  assert.doesNotMatch(raw, /\/Users\//);
  assert.doesNotMatch(
    raw,
    /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,
  );
});

test("checked-in current v0.153 pair evidence is exact path-free and authority-free", () => {
  const raw = readFileSync(
    resolve(
      repositoryRoot,
      "scripts/fixtures/current-v153-read-only-evidence.json",
    ),
    "utf8",
  );
  const fixture = JSON.parse(raw);
  assert.equal(
    createHash("sha256").update(raw).digest("hex"),
    "1fb8f8ca65485fa82e668aa9f986e1f178aa5d9d27da12ed8be0957d06a5503f",
  );
  assert.deepEqual(
    fixture.runtimeProfiles.map((profile) => profile.runtimeVersion),
    ["0.153.1", "0.153.2"],
  );
  assert.notEqual(
    fixture.runtimeProfiles[0].executableSha256,
    fixture.runtimeProfiles[1].executableSha256,
  );
  assert.equal(
    fixture.runtimeProfiles[0].generatedProtocol.schemaBundleSha256,
    fixture.runtimeProfiles[1].generatedProtocol.schemaBundleSha256,
  );
  assert.ok(fixture.runtimeProfiles.every((profile) =>
    profile.missingThreadRead.rpcCode === -32600
      && profile.missingThreadRead.messageTemplate
        === "thread not loaded: {thread_id}"
      && profile.requestBoundary.existingThreadIDsRead === 0
      && profile.requestBoundary.lifecycleMutationRequests === 0));
  assert.equal(fixture.sourceLayout.desktopSchemaProfile, "desktop-v34");
  assert.equal(fixture.databaseMetadata.desktopUserVersion, 34);
  assert.equal(fixture.databaseMetadata.exactV34ContractMatched, true);
  assert.equal(fixture.safetyContract.mutationAuthorityGranted, false);
  assert.doesNotMatch(raw, /\/Users\//);
  assert.doesNotMatch(
    raw,
    /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,
  );
});

test("checked-in v0.153.4 dual-runtime evidence is exact path-free and authority-free", () => {
  const raw = readFileSync(
    resolve(
      repositoryRoot,
      "scripts/fixtures/current-v1534-read-only-evidence.json",
    ),
    "utf8",
  );
  const fixture = JSON.parse(raw);
  assert.equal(
    createHash("sha256").update(raw).digest("hex"),
    "7d26dc10bca3d2063727cae204c90ea84d86ca2ba1470cf62dc6ecd5ba0fc353",
  );
  assert.deepEqual(
    fixture.runtimeProfiles.map((profile) => ({
      profileIdentifier: profile.profileIdentifier,
      role: profile.role,
      runtimeVersion: profile.runtimeVersion,
      executableSha256: profile.executableSha256,
    })),
    [
      {
        profileIdentifier: "desktop-bundled-0.153.4",
        role: "desktop_bundled",
        runtimeVersion: "0.153.4",
        executableSha256:
          "a30ec314bbd0e3721632234d07db7c99855db3b9f1e32dbe8c791947f07e7629",
      },
      {
        profileIdentifier: "provider-0.153.4",
        role: "provider_stable",
        runtimeVersion: "0.153.4",
        executableSha256:
          "b973d440acac501fd2594a43e7ca9ce41e0a65b9dfb28d0d7a7837c99e1261e3",
      },
    ],
  );
  assert.ok(fixture.runtimeProfiles.every((profile) =>
    profile.generatedProtocol.schemaBundleSha256
        === "251c80d7742dca39c0013f2b0ad11641df6582989c602fbbde6895207bd84692"
      && profile.generatedProtocol.lifecycleShapesCompatible === true
      && profile.missingThreadRead.rpcCode === -32600
      && profile.missingThreadRead.messageTemplate
        === "thread not loaded: {thread_id}"
      && profile.missingThreadRead.syntheticThreadIDStoredInEvidence === false
      && profile.requestBoundary.existingThreadIDsRead === 0
      && profile.requestBoundary.lifecycleMutationRequests === 0));
  assert.deepEqual(
    {
      identifier: fixture.sourceLayout.identifier,
      sourceOwner: fixture.sourceLayout.sourceOwner,
      runtimeProfileIdentifier: fixture.sourceLayout.runtimeProfileIdentifier,
      desktopSchemaProfile: fixture.sourceLayout.desktopSchemaProfile,
      memberCount: fixture.sourceLayout.memberCount,
      layoutDigest: fixture.sourceLayout.layoutDigest,
    },
    {
      identifier: "codex-cli-0.153.4-desktop-v34-20-member-v1",
      sourceOwner: "desktop-bundled-0.153.4",
      runtimeProfileIdentifier: "desktop-bundled-0.153.4",
      desktopSchemaProfile: "desktop-v34",
      memberCount: 20,
      layoutDigest:
        "75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85",
    },
  );
  assert.equal(fixture.sourceLayout.members.length, 20);
  assert.equal(fixture.sourceLayout.clearSourcePathPersisted, false);
  assert.equal(fixture.sourceLayout.rawDatabaseContentsRead, false);
  assert.equal(fixture.databaseMetadata.desktopUserVersion, 34);
  assert.equal(fixture.databaseMetadata.exactV34ContractMatched, true);
  assert.equal(
    fixture.databaseMetadata.observationScope,
    "fixed user_version, table column names and order, required index columns",
  );
  assert.equal(fixture.safetyContract.syntheticMissingThreadReads, 2);
  assert.equal(fixture.safetyContract.existingThreadReads, 0);
  assert.equal(fixture.safetyContract.lifecycleMutationRequestsSent, 0);
  assert.equal(fixture.safetyContract.mutationAuthorityGranted, false);
  assert.equal(
    fixture.safetyContract.appServerInternalDatabaseWritesMeasured,
    false,
  );
  assert.doesNotMatch(raw, /\/Users\//);
  assert.doesNotMatch(
    raw,
    /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,
  );
});

test("an added exact automation column blocks Ghost Repair", () => {
  const databases = compatibleDatabases();
  databases.desktop.tables.automations.push("kind");
  const result = evaluateGhostRepairContract({
    runtimeVersion: "0.151.0-alpha.7.2",
    databases,
  });
  assert.equal(result.verdict, "blocked_schema_drift");
  assert.deepEqual(result.drifts, [
    "desktop.automations: exact columns changed",
  ]);
});

test("the deterministic v33 schema remains admitted only for exact v0.151 pairs", () => {
  const databases = compatibleDatabases(
    GHOST_REPAIR_DATABASE_CONTRACT_V33.databases,
  );
  const result = evaluateGhostRepairContract({
    runtimeVersion:
      UNADMITTED_GHOST_REPAIR_V33_CANDIDATE.desktopRuntimeVersion,
    databases,
  });
  assert.equal(result.verdict, "ready_current_build");
  assert.equal(result.schemaProfileIdentifier, "desktop-v33");
  assert.deepEqual(result.drifts, []);
  assert.deepEqual(
    UNADMITTED_GHOST_REPAIR_V33_CANDIDATE.addedAutomationColumns,
    [
      "kind", "target_thread_id", "execution_environment",
      "local_environment_config_path", "plugin_template_id",
      "notification_policy", "account_id", "user_id", "installation_id",
      "legacy_automation_id",
    ],
  );
  assert.deepEqual(
    UNADMITTED_GHOST_REPAIR_V33_CANDIDATE.addedAutomationIndex,
    {
      name: "automations_owner_idx",
      columns: ["account_id", "user_id", "installation_id"],
    },
  );
  assert.equal(
    UNADMITTED_GHOST_REPAIR_V33_CANDIDATE
      .deterministicSchemaContractAccepted,
    false,
  );
  assert.equal(
    UNADMITTED_GHOST_REPAIR_V33_CANDIDATE
      .deterministic148ItemAcceptancePassed,
    false,
  );
  assert.equal(
    UNADMITTED_GHOST_REPAIR_V33_CANDIDATE.packagedAppWiringAllowed,
    false,
  );
  assert.equal(
    UNADMITTED_GHOST_REPAIR_V33_CANDIDATE.mutationAuthority,
    "none",
  );
  assert.equal(
    GHOST_REPAIR_DATABASE_CONTRACT_V33.deterministicSchemaContractAccepted,
    true,
  );
  assert.equal(
    GHOST_REPAIR_DATABASE_CONTRACT_V33.deterministic148ItemAcceptancePassed,
    true,
  );
  assert.equal(GHOST_REPAIR_DATABASE_CONTRACT_V33.runtimeAdmissionGranted, true);
});

test("v33 requires the exact owner index", () => {
  const databases = compatibleDatabases(
    GHOST_REPAIR_DATABASE_CONTRACT_V33.databases,
  );
  delete databases.desktop.indexes.automations.automations_owner_idx;
  const result = evaluateGhostRepairContract({
    runtimeVersion: "0.151.0-alpha.7.2",
    databases,
  });
  assert.equal(result.verdict, "blocked_schema_drift");
  assert.deepEqual(result.drifts, [
    "desktop.automations: required index automations_owner_idx changed",
  ]);
});

test("state contract permits extra columns but still requires id", () => {
  const databases = compatibleDatabases();
  databases.state.tables.threads.push("rollout_path", "title");
  assert.equal(
    evaluateGhostRepairContract({
      runtimeVersion: AUDITED_GHOST_REPAIR_RUNTIME,
      databases,
    }).verdict,
    "ready_current_build",
  );
  databases.state.tables.threads = ["rollout_path"];
  assert.equal(
    evaluateGhostRepairContract({
      runtimeVersion: AUDITED_GHOST_REPAIR_RUNTIME,
      databases,
    }).verdict,
    "blocked_schema_drift",
  );
});

test("missing metadata blocks without inferring compatibility", () => {
  const databases = compatibleDatabases();
  delete databases.threadHistory;
  const result = evaluateGhostRepairContract({
    runtimeVersion: AUDITED_GHOST_REPAIR_RUNTIME,
    databases,
  });
  assert.equal(result.verdict, "blocked_inspection_unavailable");
  assert.deepEqual(result.drifts, [
    "threadHistory: database metadata unavailable",
  ]);
});

test("overall verdict is blocked if any independent contract is blocked", () => {
  assert.equal(
    overallCompatibilityVerdict({
      providerLifecycleVerdict: "ready_current_build",
      desktopLifecycleVerdict: "candidate_requires_allowlist_update",
      ghostRepairVerdict: "blocked_schema_drift",
    }),
    "blocked",
  );
  assert.equal(
    overallCompatibilityVerdict({
      providerLifecycleVerdict: "ready_current_build",
      desktopLifecycleVerdict: "candidate_requires_allowlist_update",
      ghostRepairVerdict: "candidate_requires_runtime_admission",
    }),
    "review_required",
  );
});

test("diagnostic v32 through v34 schema profiles stay synchronized with the shipping reader", () => {
  const reader = readFileSync(
    resolve(
      repositoryRoot,
      "macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairSnapshotAnalysisReader.swift",
    ),
    "utf8",
  );
  const profiles = readFileSync(
    resolve(
      repositoryRoot,
      "macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairDatabaseSchemaProfile.swift",
    ),
    "utf8",
  );
  const referencedTables = readFileSync(
    resolve(repositoryRoot,
      "macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGhostRepairReferencedTables.swift"),
    "utf8",
  );
  assert.ok(reader.includes("CodexGhostRepairReferencedTables.byDatabase[database]"));
  const source = `${reader}\n${profiles}\n${referencedTables}`.replaceAll(/\s/g, "")
    .replaceAll(",]", "]");

  assert.equal(GHOST_REPAIR_DATABASE_CONTRACTS.length, 3);
  assert.ok(source.includes('identifier:"desktop-v32"'));
  assert.ok(source.includes('identifier:"desktop-v33"'));
  assert.ok(source.includes('identifier:"desktop-v34"'));
  assert.ok(source.includes('name:"automations_owner_idx"'));
  assert.ok(source.includes('columns:["account_id","user_id","installation_id"]'));

  for (const [role, database] of Object.entries(
    GHOST_REPAIR_DATABASE_CONTRACT_V34.databases,
  )) {
    if (role === "desktop") {
      assert.ok(
        source.includes('identifier:"desktop-v34"') &&
          source.includes(`version:${database.userVersion}`),
        `${role} user_version drifted from the diagnostic contract`,
      );
    } else {
      assert.match(
        source,
        new RegExp(`\\.${role}:${database.userVersion}(?:,|])`),
        `${role} user_version drifted from the diagnostic contract`,
      );
    }
    for (const [table, contract] of Object.entries(database.tables)) {
      assert.ok(source.includes(`table:"${table}"`));
      for (const column of contract.columns) {
        assert.ok(
          source.includes(`"${column}"`),
          `${role}.${table}.${column} drifted from the diagnostic contract`,
        );
      }
    }
  }
});
