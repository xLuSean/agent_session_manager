#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { accessSync, constants, existsSync, lstatSync } from "node:fs";
import { basename, delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  GHOST_REPAIR_DATABASE_CONTRACT_V33,
  evaluateGhostRepairContract,
  overallCompatibilityVerdict,
  parseCodexVersion,
  versionsDiverge,
} from "./lib/codex_update_compatibility.mjs";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const REPOSITORY_ROOT = resolve(dirname(SCRIPT_PATH), "..");
const LIFECYCLE_AUDIT = join(REPOSITORY_ROOT, "scripts/audit_app_server_contract.sh");
const HOME = process.env.HOME ?? "";
const CODEX_HOME = join(HOME, ".codex");

function run(command, arguments_, options = {}) {
  const result = spawnSync(command, arguments_, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    ...options,
  });
  if (result.error) throw result.error;
  return result;
}

function exactVersion(executable) {
  const result = run(executable, ["--version"]);
  if (result.status !== 0) return null;
  return parseCodexVersion(result.stdout);
}

function plistValue(appPath, key) {
  const result = run("/usr/libexec/PlistBuddy", [
    "-c", `Print :${key}`, join(appPath, "Contents/Info.plist"),
  ]);
  return result.status === 0 ? result.stdout.trim() : null;
}

function isExecutable(path) {
  if (!existsSync(path)) return false;
  try {
    const stat = lstatSync(path);
    if (!stat.isFile() && !stat.isSymbolicLink()) return false;
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function resolveDesktopRuntime() {
  const candidates = [
    "/Applications/Codex.app",
    "/Applications/ChatGPT.app",
    join(HOME, "Applications/Codex.app"),
    join(HOME, "Applications/ChatGPT.app"),
  ];
  for (const appPath of candidates) {
    if (!existsSync(join(appPath, "Contents/Info.plist"))) continue;
    if (plistValue(appPath, "CFBundleIdentifier") !== "com.openai.codex") continue;
    const executable = join(appPath, "Contents/Resources/codex");
    if (!isExecutable(executable)) continue;
    const runtimeVersion = exactVersion(executable);
    if (!runtimeVersion) continue;
    return {
      appName: basename(appPath),
      appVersion: plistValue(appPath, "CFBundleShortVersionString"),
      appBuild: plistValue(appPath, "CFBundleVersion"),
      executable,
      runtimeVersion,
    };
  }
  return null;
}

function resolveProviderRuntime() {
  const pathCandidates = (process.env.PATH ?? "")
    .split(delimiter)
    .filter(Boolean)
    .map((entry) => join(entry, "codex"));
  const candidates = [
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    ...pathCandidates,
  ];
  const seen = new Set();
  for (const executable of candidates) {
    const standardized = resolve(executable);
    if (seen.has(standardized)) continue;
    seen.add(standardized);
    if (!isExecutable(executable)) continue;
    const runtimeVersion = exactVersion(executable);
    if (!runtimeVersion) continue;
    return { executable, runtimeVersion };
  }
  return null;
}

function sqliteJSON(databasePath, sql) {
  const result = run("sqlite3", ["-readonly", "-json", databasePath, sql]);
  if (result.status !== 0) return null;
  const output = result.stdout.trim();
  if (!output) return [];
  try {
    return JSON.parse(output);
  } catch {
    return null;
  }
}

function inspectGhostRepairDatabases() {
  const databases = {};
  // The v33 profile contains the superset of fixed table names and the only
  // currently required custom index. The evaluator selects v32 or v33 from
  // the observed Desktop user_version after this metadata-only inspection.
  for (const [role, contract] of Object.entries(
    GHOST_REPAIR_DATABASE_CONTRACT_V33.databases,
  )) {
    const databasePath = join(
      CODEX_HOME,
      contract.relativeDirectory,
      contract.fileName,
    );
    if (!existsSync(databasePath) || !lstatSync(databasePath).isFile()) {
      continue;
    }
    const versionRows = sqliteJSON(databasePath, "PRAGMA user_version;");
    const userVersion = versionRows?.[0]?.user_version;
    if (!Number.isInteger(userVersion)) continue;
    const tables = {};
    const indexes = {};
    let complete = true;
    for (const table of Object.keys(contract.tables)) {
      const rows = sqliteJSON(databasePath, `PRAGMA table_info('${table}');`);
      if (!rows) {
        complete = false;
        break;
      }
      tables[table] = rows.map((row) => row.name);
      const requiredIndexes = contract.tables[table].requiredIndexes ?? {};
      if (Object.keys(requiredIndexes).length > 0) {
        indexes[table] = {};
        for (const index of Object.keys(requiredIndexes)) {
          const indexRows = sqliteJSON(
            databasePath,
            `PRAGMA index_info('${index}');`,
          );
          if (!indexRows) {
            complete = false;
            break;
          }
          indexes[table][index] = indexRows.map((row) => row.name);
        }
      }
      if (!complete) break;
    }
    if (!complete) continue;
    databases[role] = {
      fileName: contract.fileName,
      userVersion,
      tables,
      indexes,
    };
  }
  return databases;
}

function parseLifecycleOutput(stdout) {
  const fields = {};
  for (const line of stdout.split("\n")) {
    const match = /^([a-z][a-z0-9_]*)\s{2,}(.+)$/.exec(line);
    if (match) fields[match[1]] = match[2].trim();
  }
  return fields;
}

function lifecycleAudit(label, runtime) {
  if (!runtime) {
    return {
      label,
      status: "blocked_runtime_unavailable",
      fields: {},
      error: "runtime unavailable",
    };
  }
  const result = run(LIFECYCLE_AUDIT, [], {
    cwd: REPOSITORY_ROOT,
    env: {
      ...process.env,
      CODEX_EXECUTABLE_OVERRIDE: runtime.executable,
    },
  });
  const fields = parseLifecycleOutput(result.stdout);
  return {
    label,
    status: result.status === 0
      ? fields.archive_shipping_verdict ?? "blocked_inspection_unavailable"
      : "blocked_schema_drift",
    fields,
    error: result.status === 0 ? null : result.stderr.trim(),
  };
}

function printField(name, value) {
  process.stdout.write(`${name.padEnd(40)} ${value ?? "unavailable"}\n`);
}

function main() {
  const desktop = resolveDesktopRuntime();
  const provider = resolveProviderRuntime();
  const providerLifecycle = lifecycleAudit("provider", provider);
  const desktopLifecycle = lifecycleAudit("desktop", desktop);
  const ghostRepair = evaluateGhostRepairContract({
    runtimeVersion: desktop?.runtimeVersion ?? null,
    databases: inspectGhostRepairDatabases(),
  });
  const overall = overallCompatibilityVerdict({
    providerLifecycleVerdict: providerLifecycle.status,
    desktopLifecycleVerdict: desktopLifecycle.status,
    ghostRepairVerdict: ghostRepair.verdict,
  });

  console.log("Codex update compatibility — automated read-only audit");
  console.log("This command reads runtime versions, generated public protocol schema,");
  console.log("and fixed SQLite schema metadata only. It never reads session rows.");
  console.log("");
  printField("desktop_app", desktop?.appName);
  printField("desktop_app_version", desktop?.appVersion);
  printField("desktop_app_build", desktop?.appBuild);
  printField("desktop_bundled_runtime", desktop?.runtimeVersion);
  printField("provider_runtime", provider?.runtimeVersion);
  printField(
    "runtime_divergence",
    versionsDiverge(desktop?.runtimeVersion, provider?.runtimeVersion) ? "yes" : "no",
  );
  console.log("");
  printField("provider_archive_verdict", providerLifecycle.status);
  printField("desktop_archive_schema_verdict", desktopLifecycle.status);
  printField(
    "desktop_permanent_delete_verdict",
    desktopLifecycle.fields.permanent_delete_shipping_verdict
      ?? "blocked_inspection_unavailable",
  );
  printField("ghost_repair_verdict", ghostRepair.verdict);
  printField(
    "ghost_repair_schema_profile",
    ghostRepair.schemaProfileIdentifier,
  );
  for (const drift of ghostRepair.drifts) {
    printField("ghost_repair_drift", drift);
  }
  console.log("");
  printField("session_rows_read", ghostRepair.sessionRowsRead);
  printField("sqlite_writes", ghostRepair.sqliteWrites);
  printField("lifecycle_requests_sent", "0");
  printField("mutation_authority", ghostRepair.mutationAuthority);
  printField("overall_verdict", overall);

  if (providerLifecycle.error) {
    console.error(`Provider lifecycle audit: ${providerLifecycle.error}`);
  }
  if (desktopLifecycle.error) {
    console.error(`Desktop lifecycle audit: ${desktopLifecycle.error}`);
  }
  process.exitCode = overall === "ready" ? 0 : 2;
}

try {
  main();
} catch {
  console.error("BLOCKED: compatibility inspection was unavailable.");
  printField("session_rows_read", "0");
  printField("sqlite_writes", "0");
  printField("lifecycle_requests_sent", "0");
  printField("mutation_authority", "none");
  printField("overall_verdict", "blocked");
  process.exitCode = 2;
}
