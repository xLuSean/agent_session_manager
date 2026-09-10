import assert from "node:assert/strict";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const repositoryRoot = resolve(import.meta.dirname, "../..");
const auditScript = join(repositoryRoot, "scripts/audit_app_server_contract.sh");
const updateRunner = join(repositoryRoot, "scripts/run_codex_lifecycle_update_audit.sh");
const compatibilityRunner = join(
  repositoryRoot,
  "scripts/run_codex_update_compatibility_audit.sh",
);
const temporaryRoots = [];

test.after(() => {
  for (const root of temporaryRoots) {
    spawnSync("trash", [root], { encoding: "utf8" });
  }
});

function temporaryRoot(prefix) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  temporaryRoots.push(root);
  return root;
}

function threadDefinition() {
  return {
    type: "object",
    required: [
      "cliVersion",
      "createdAt",
      "cwd",
      "ephemeral",
      "id",
      "modelProvider",
      "preview",
      "sessionId",
      "status",
      "updatedAt",
    ],
    properties: {
      id: { type: "string" },
      sessionId: { type: "string" },
      parentThreadId: { type: ["string", "null"] },
      preview: { type: "string" },
      ephemeral: { type: "boolean" },
      modelProvider: { type: "string" },
      createdAt: { type: "integer", format: "int64" },
      updatedAt: { type: "integer", format: "int64" },
      status: { allOf: [{ $ref: "#/definitions/ThreadStatus" }] },
      cwd: { allOf: [{ $ref: "#/definitions/AbsolutePathBuf" }] },
      cliVersion: { type: "string" },
      name: { type: ["string", "null"] },
      gitInfo: {
        anyOf: [
          { $ref: "#/definitions/GitInfo" },
          { type: "null" },
        ],
      },
    },
  };
}

function threadStatusDefinition() {
  return {
    oneOf: [
      {
        type: "object",
        required: ["type"],
        properties: { type: { type: "string", enum: ["notLoaded"] } },
      },
      {
        type: "object",
        required: ["activeFlags", "type"],
        properties: {
          activeFlags: { type: "array", items: { type: "string" } },
          type: { type: "string", enum: ["active"] },
        },
      },
    ],
  };
}

function lifecycleThreadIDShape() {
  return {
    type: "object",
    required: ["threadId"],
    properties: { threadId: { type: "string" } },
  };
}

function writeJSON(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function schemaFixture({ archiveDrift = false, decoderDrift = false } = {}) {
  const root = temporaryRoot("asm-lifecycle-audit-schema-");
  const v2 = join(root, "v2");
  mkdirSync(v2);

  const listThread = threadDefinition();
  const unarchiveThread = threadDefinition();
  if (decoderDrift) {
    listThread.properties.updatedAt.type = "string";
    unarchiveThread.properties.updatedAt.type = "string";
  }

  writeJSON(join(v2, "ThreadListParams.json"), {
    type: "object",
    properties: {},
  });
  writeJSON(join(v2, "ThreadListResponse.json"), {
    type: "object",
    definitions: {
      Thread: listThread,
      ThreadStatus: threadStatusDefinition(),
    },
  });
  writeJSON(join(v2, "ThreadLoadedListResponse.json"), { type: "object" });

  const archiveParams = lifecycleThreadIDShape();
  if (archiveDrift) {
    archiveParams.properties.unexpected = { type: "boolean" };
  }
  writeJSON(join(v2, "ThreadArchiveParams.json"), archiveParams);
  writeJSON(join(v2, "ThreadArchiveResponse.json"), {
    type: "object",
    properties: {},
  });
  writeJSON(join(v2, "ThreadArchivedNotification.json"), lifecycleThreadIDShape());

  writeJSON(join(v2, "ThreadUnarchiveParams.json"), lifecycleThreadIDShape());
  writeJSON(join(v2, "ThreadUnarchiveResponse.json"), {
    type: "object",
    required: ["thread"],
    properties: { thread: { $ref: "#/definitions/Thread" } },
    definitions: {
      Thread: unarchiveThread,
      ThreadStatus: threadStatusDefinition(),
    },
  });
  writeJSON(join(v2, "ThreadUnarchivedNotification.json"), lifecycleThreadIDShape());

  writeJSON(join(v2, "ThreadDeleteParams.json"), lifecycleThreadIDShape());
  writeJSON(join(v2, "ThreadDeleteResponse.json"), {
    type: "object",
    properties: {},
  });
  writeJSON(join(v2, "ThreadDeletedNotification.json"), lifecycleThreadIDShape());
  return root;
}

function fakeCodex(versionOutput) {
  const root = temporaryRoot("asm-lifecycle-audit-codex-");
  const executable = join(root, "codex");
  const log = join(root, "calls.log");
  writeFileSync(
    executable,
    `#!/bin/zsh\nprint -r -- "$*" >> ${JSON.stringify(log)}\nif [[ "$1" == "--version" ]]; then\n  print -r -- ${JSON.stringify(versionOutput)}\n  exit 0\nfi\nexit 97\n`,
  );
  chmodSync(executable, 0o700);
  return { executable, log };
}

function contractSource({ conditionalOnlyExact = false } = {}) {
  const root = temporaryRoot("asm-lifecycle-audit-contract-");
  const path = join(root, "Contract.swift");
  writeFileSync(
    path,
    `public enum Contract {
    public static func supportsVerifiedLifecycleContract(_ runtimeVersion: String?) -> Bool {
        versionBelongsToAuditedSeries(runtimeVersion, release: "0.147.0")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.148.0")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.149.0")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.152.1")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.153.1")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.153.2")
            || runtimeVersion == "${conditionalOnlyExact ? "0.153.2" : "0.153.4"}"
    }

    public static func supportsVerifiedDeleteContract(_ runtimeVersion: String?) -> Bool {
        versionBelongsToAuditedSeries(runtimeVersion, release: "0.147.0")
#if ASM_ISOLATED_DELETE_ACCEPTANCE
            || runtimeVersion == "0.153.4"
#endif
    }
}
`,
  );
  return path;
}

function runAudit(versionOutput, schemaOptions = {}, contractOptions = {}) {
  const fake = fakeCodex(versionOutput);
  const result = spawnSync(auditScript, [], {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: {
      ...process.env,
      CODEX_EXECUTABLE_OVERRIDE: fake.executable,
      CODEX_APP_SERVER_SCHEMA_DIRECTORY_OVERRIDE: schemaFixture(schemaOptions),
      CODEX_LIFECYCLE_CONTRACT_SOURCE_OVERRIDE: contractSource(contractOptions),
    },
  });
  return { ...result, callLog: readFileSync(fake.log, "utf8") };
}

test("audited 0.149 runtime is ready only for reversible lifecycle operations", () => {
  const result = runAudit("codex-cli 0.149.0");
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /thread_decoder_contract\s+compatible/);
  assert.match(result.stdout, /archive_shipping_verdict\s+ready_current_build/);
  assert.match(result.stdout, /restore_shipping_verdict\s+ready_current_build/);
  assert.match(result.stdout, /move_to_trash_shipping_verdict\s+ready_current_build/);
  assert.match(
    result.stdout,
    /permanent_delete_shipping_verdict\s+blocked_requires_live_acceptance/,
  );
  assert.match(result.stdout, /session_storage_inspected\s+no/);
  assert.match(result.stdout, /lifecycle_requests_sent\s+0/);
  assert.match(result.stdout, /mutation_authority\s+none/);
  assert.equal(result.callLog, "--version\n");
});

test("new compatible runtime becomes a reversible candidate without sending a request", () => {
  const result = runAudit("codex-cli 0.150.0");
  assert.equal(result.status, 0, result.stderr);
  assert.match(
    result.stdout,
    /archive_shipping_verdict\s+candidate_requires_allowlist_update/,
  );
  assert.match(
    result.stdout,
    /restore_shipping_verdict\s+candidate_requires_allowlist_update/,
  );
  assert.match(
    result.stdout,
    /permanent_delete_shipping_verdict\s+blocked_requires_live_acceptance/,
  );
  assert.equal(result.callLog, "--version\n");
});

test("reviewed 0.152.1 runtime is ready for reversible lifecycle only", () => {
  const result = runAudit("codex-cli 0.152.1");
  assert.equal(result.status, 0, result.stderr);
  assert.match(
    result.stdout,
    /archive_shipping_verdict\s+ready_current_build/,
  );
  assert.match(
    result.stdout,
    /restore_shipping_verdict\s+ready_current_build/,
  );
  assert.match(
    result.stdout,
    /move_to_trash_shipping_verdict\s+ready_current_build/,
  );
  assert.match(
    result.stdout,
    /permanent_delete_shipping_verdict\s+blocked_requires_live_acceptance/,
  );
  assert.equal(result.callLog, "--version\n");
});

test("reviewed current 0.153 runtimes are ready for reversible lifecycle only", () => {
  for (const version of ["0.153.1", "0.153.2", "0.153.4"]) {
    const result = runAudit(`codex-cli ${version}`);
    assert.equal(result.status, 0, result.stderr);
    assert.match(
      result.stdout,
      /archive_shipping_verdict\s+ready_current_build/,
    );
    assert.match(
      result.stdout,
      /restore_shipping_verdict\s+ready_current_build/,
    );
    assert.match(
      result.stdout,
      /move_to_trash_shipping_verdict\s+ready_current_build/,
    );
    assert.match(
      result.stdout,
      /permanent_delete_shipping_verdict\s+blocked_requires_live_acceptance/,
    );
    assert.equal(result.callLog, "--version\n");
  }
});

test("neighboring unaudited 0.153 runtimes remain reversible candidates", () => {
  for (const version of ["0.153.3", "0.153.5"]) {
    const result = runAudit(`codex-cli ${version}`);
    assert.equal(result.status, 0, result.stderr);
    assert.match(
      result.stdout,
      /archive_shipping_verdict\s+candidate_requires_allowlist_update/,
    );
    assert.match(
      result.stdout,
      /restore_shipping_verdict\s+candidate_requires_allowlist_update/,
    );
    assert.match(
      result.stdout,
      /move_to_trash_shipping_verdict\s+candidate_requires_allowlist_update/,
    );
    assert.match(
      result.stdout,
      /permanent_delete_shipping_verdict\s+blocked_requires_live_acceptance/,
    );
    assert.equal(result.callLog, "--version\n");
  }
});

test("exact lifecycle equality excludes suffixes and conditional Delete admission", () => {
  for (const version of ["0.153.4-alpha.1", "0.153.3", "0.153.5"]) {
    const result = runAudit(`codex-cli ${version}`);
    assert.equal(result.status, 0, result.stderr);
    assert.match(
      result.stdout,
      /archive_shipping_verdict\s+candidate_requires_allowlist_update/,
    );
  }
  const conditionalOnly = runAudit(
    "codex-cli 0.153.4",
    {},
    { conditionalOnlyExact: true },
  );
  assert.equal(conditionalOnly.status, 0, conditionalOnly.stderr);
  assert.match(
    conditionalOnly.stdout,
    /archive_shipping_verdict\s+candidate_requires_allowlist_update/,
  );
  assert.match(
    conditionalOnly.stdout,
    /permanent_delete_shipping_verdict\s+blocked_requires_live_acceptance/,
  );
});

test("operation schema drift blocks the affected release audit", () => {
  const result = runAudit("codex-cli 0.150.0", { archiveDrift: true });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /thread_archive_contract\s+incompatible/);
  assert.match(result.stdout, /archive_shipping_verdict\s+blocked_schema_drift/);
  assert.match(result.stdout, /move_to_trash_shipping_verdict\s+blocked_schema_drift/);
  assert.match(result.stderr, /generated lifecycle schema or the App's Thread decoder surface changed/);
  assert.match(result.stderr, /No lifecycle request was sent/);
  assert.equal(result.callLog, "--version\n");
});

test("Thread decoder drift blocks every lifecycle verdict", () => {
  const result = runAudit("codex-cli 0.150.0", { decoderDrift: true });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /thread_decoder_contract\s+incompatible/);
  assert.match(result.stdout, /archive_shipping_verdict\s+blocked_schema_drift/);
  assert.match(result.stdout, /restore_shipping_verdict\s+blocked_schema_drift/);
  assert.match(result.stdout, /permanent_delete_shipping_verdict\s+blocked_schema_drift/);
  assert.equal(result.callLog, "--version\n");
});

test("malformed runtime output fails before schema or lifecycle access", () => {
  const result = runAudit("Codex 0.150.0");
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Expected exact 'codex-cli <version>' output/);
  assert.match(result.stderr, /No lifecycle request was sent/);
  assert.equal(result.callLog, "--version\n");
});

test("single-command runner audits before tests and never packages a DMG", () => {
  const source = readFileSync(updateRunner, "utf8");
  const audit = source.indexOf("audit_app_server_contract.sh");
  const nodeTests = source.indexOf("node --test");
  const swiftTests = source.indexOf("swift test");
  assert.ok(audit >= 0);
  assert.ok(nodeTests > audit);
  assert.ok(swiftTests > nodeTests);
  assert.doesNotMatch(source, /package_dmg|package_lifecycle_canary/);
});

test("compatibility runner READY message does not imply Permanent Delete admission", () => {
  const source = readFileSync(compatibilityRunner, "utf8");
  assert.match(
    source,
    /READY: read-only Ghost preparation and reversible lifecycle compatibility are admitted; Permanent Delete remains subject to its separate verdict\./,
  );
  assert.doesNotMatch(
    source,
    /READY: the installed Codex combination is admitted by the current build\./,
  );
});

test("read-only update runner removes inherited live-acceptance opt-ins before any subprocess", () => {
  const source = readFileSync(updateRunner, "utf8");
  const firstSubprocess = source.indexOf('mkdir -p');
  for (const name of [
    "AGENT_SESSION_MANAGER_LIVE_TEST",
    "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE",
    "ASM_ISOLATED_DELETE_ACCEPTANCE",
    "ASM_COMPATIBILITY_ACCEPTANCE",
    "ASM_COMPATIBILITY_ACCEPTANCE_EXECUTABLE",
    "ASM_COMPATIBILITY_LOCAL_INSPECTION",
  ]) {
    const unset = new RegExp(`^unset [^\\n]*\\b${name}\\b`, "m").exec(source);
    assert.ok(unset, `${name} must be explicitly unset`);
    assert.ok(unset.index < firstSubprocess, `${name} must be removed before launching commands`);
  }
});
