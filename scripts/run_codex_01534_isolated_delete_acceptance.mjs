#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { createServer } from "node:net";
import {
  chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync,
  closeSync, fsyncSync, openSync, readFileSync, readdirSync, realpathSync, writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const EXPECTED_CODEX_SHA256 = "b973d440acac501fd2594a43e7ca9ce41e0a65b9dfb28d0d7a7837c99e1261e3";
export const TEST_SELECTOR = "AgentSessionManagerCoreTests.IsolatedDeleteAcceptanceTests/testOfficialIsolatedDeleteWhenExplicitlyEnabled";
export const SMOKE_TEST_SELECTOR = "AgentSessionManagerCoreTests.IsolatedDeleteAcceptanceTests/testIsolatedRuntimeEnvironmentBeforeCreation";
export const PREPARED_LIFETIME_MS = 30 * 60 * 1_000;
const repositoryRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const runnerPath = fileURLToPath(import.meta.url);
const acceptanceSource = join(repositoryRoot, "macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/IsolatedDeleteAcceptanceTests.swift");
const packageRoot = join(repositoryRoot, "macos/AgentSessionManager");
const sourceRuntime = "/opt/homebrew/bin/codex";
const xctestTool = "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest";
const manifestName = "prepared.json";
const isolationProofName = "isolation-proof.json";
const builtManifestName = "built.json";
const claimName = "run-claim.json";

export function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function sameArray(actual, expected) {
  return Array.isArray(actual) && actual.length === expected.length
    && actual.every((value, index) => value === expected[index]);
}

function digest(path) {
  return sha256(readFileSync(path));
}

function assertMacOS() {
  if (process.platform !== "darwin") throw new Error("macos_required");
}

function assertEmpty(path) {
  if (readdirSync(path).length !== 0) throw new Error("initial_directory_not_empty");
}

function writeExclusiveJSON(path, value) {
  const fd = openSync(path, "wx", 0o600);
  try {
    writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  chmodSync(path, 0o600);
}

function safeReadJSON(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

export function sanitizedEnvironment(root) {
  const developerBin = "/Applications/Xcode.app/Contents/Developer/usr/bin";
  const toolchainBin = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin";
  return Object.freeze({
    HOME: join(root, "home"),
    CODEX_HOME: join(root, "codex"),
    XDG_CONFIG_HOME: join(root, "home", ".config"),
    XDG_DATA_HOME: join(root, "home", ".local", "share"),
    XDG_CACHE_HOME: join(root, "cache"),
    TMPDIR: join(root, "tmp"),
    PATH: `/usr/bin:/bin:/usr/sbin:/sbin:${developerBin}:${toolchainBin}`,
    LANG: "C.UTF-8",
    LC_ALL: "C.UTF-8",
    ASM_ISOLATED_DELETE_ROOT: root,
    ASM_ISOLATED_CODEX_HOME: join(root, "codex"),
    ASM_ISOLATED_DELETE_EXECUTABLE: join(root, "codex-runtime"),
    ASM_ISOLATED_DELETE_CWD: join(root, "project"),
    ASM_ISOLATED_DELETE_ACCEPTANCE: "1",
  });
}

function quoteSeatbelt(value) {
  return value.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}

export function sandboxProfile(root) {
  const allowedReads = [
    root, "/System", "/usr", "/bin", "/sbin", "/Library/Developer",
    "/Library/Apple", "/Applications/Xcode.app", "/private/var/db/dyld", "/dev",
  ];
  const reads = allowedReads.map((path) => `(allow file-read* (subpath "${quoteSeatbelt(path)}"))`).join("\n");
  return `(version 1)
(allow default)
(deny network*)
(deny file-read*)
; macOS process bootstrap reads the root directory entry, not its descendants.
(allow file-read* (literal "/"))
; Canonicalizing the isolated root needs ancestor metadata, never ancestor contents.
(allow file-read-metadata (literal "/private") (literal "/private/tmp"))
; Codex probes the optional system requirements file even with an isolated home.
; Metadata only allows ENOENT; a real file's contents remain inaccessible.
(allow file-read-metadata (literal "/etc") (literal "/private/etc")
  (literal "/private/etc/codex") (literal "/private/etc/codex/requirements.toml")
  (literal "/etc/codex") (literal "/etc/codex/requirements.toml"))
${reads}
(deny file-write*)
(allow file-write* (subpath "${quoteSeatbelt(root)}"))
(allow file-write* (literal "/dev/null"))
(deny appleevent-send)
(deny mach-lookup (global-name "com.apple.securityd"))
(deny mach-lookup (global-name "com.apple.securityd.system"))
(deny mach-lookup (global-name "com.apple.security.agent"))
`;
}

export function isDirectIsolatedRootPath(value) {
  return resolve(value, "..") === "/private/tmp"
    && /^asm-isolated-delete-[A-Za-z0-9_-]+$/.test(value.slice("/private/tmp/".length));
}

function exactRoot(value) {
  const root = realpathSync(value);
  if (!isDirectIsolatedRootPath(root)) throw new Error("invalid_root");
  if (!lstatSync(root).isDirectory()) throw new Error("invalid_root");
  return root;
}

function confinedExisting(root, relativePath) {
  if (typeof relativePath !== "string" || relativePath.startsWith("/") || relativePath.split("/").includes("..")) {
    throw new Error("manifest_path_escape");
  }
  const path = join(root, relativePath);
  const real = realpathSync(path);
  if (!real.startsWith(`${root}/`)) throw new Error("manifest_path_escape");
  return real;
}

function findTestBundle(buildRoot) {
  const found = [];
  const visit = (directory) => {
    for (const name of readdirSync(directory)) {
      const path = join(directory, name);
      const stat = lstatSync(path);
      if (stat.isSymbolicLink()) continue;
      if (stat.isDirectory() && name === "AgentSessionManagerPackageTests.xctest") found.push(path);
      else if (stat.isDirectory()) visit(path);
    }
  };
  visit(buildRoot);
  if (found.length !== 1) throw new Error("xctest_bundle_count");
  return found[0];
}

function sourceClosureSha256() {
  const files = [join(packageRoot, "Package.swift"), acceptanceSource];
  for (const relative of ["Sources/AgentSessionManagerCore", "Sources/CSQLite3"]) {
    const visit = (directory) => {
      for (const name of readdirSync(directory).sort()) {
        const path = join(directory, name);
        const stat = lstatSync(path);
        if (stat.isSymbolicLink()) throw new Error("source_closure_symlink");
        if (stat.isDirectory()) visit(path);
        else if (stat.isFile()) files.push(path);
      }
    };
    visit(join(packageRoot, relative));
  }
  return sha256(`${files.sort().map((path) => `${path.slice(packageRoot.length + 1)}\0${digest(path)}`).join("\n")}\n`);
}

function checkedSpawn(command, args, options, errorCode, logRoot, logStem, timeoutMs = 60_000) {
  const result = spawnSync(command, args, {
    ...options,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    timeout: timeoutMs,
    killSignal: "SIGTERM",
  });
  if (logRoot) {
    writeFileSync(join(logRoot, `${logStem}.stdout.log`), result.stdout ?? "", { flag: "wx", mode: 0o600 });
    writeFileSync(join(logRoot, `${logStem}.stderr.log`), result.stderr ?? "", { flag: "wx", mode: 0o600 });
    writeFileSync(join(logRoot, `${logStem}.process.json`), `${JSON.stringify({
      status: result.status ?? null,
      signal: result.signal ?? null,
      errorCode: typeof result.error?.code === "string" ? result.error.code : null,
    })}\n`, { flag: "wx", mode: 0o600 });
  }
  if (result.error || result.status !== 0) throw new Error(errorCode);
  return result;
}

export function validatePreparedManifest(root, manifest, now = Date.now()) {
  if (manifest?.schemaVersion !== 1 || manifest?.kind !== "asm-isolated-delete-0.153.4-prepared") throw new Error("manifest_shape");
  if (manifest.root !== root || manifest.expiresAtMs < now || manifest.preparedAtMs > now) throw new Error("manifest_expired_or_root");
  const runtime = join(root, "codex-runtime");
  const profile = join(root, "isolation.sb");
  if (
    lstatSync(runtime).isSymbolicLink() || realpathSync(runtime) !== runtime
    || lstatSync(profile).isSymbolicLink() || realpathSync(profile) !== profile
    || digest(runtime) !== EXPECTED_CODEX_SHA256
    || manifest.sandboxProfileSha256 !== sha256(sandboxProfile(root))
    || digest(profile) !== manifest.sandboxProfileSha256
  ) throw new Error("prepared_hash_drift");
}

function prepare() {
  assertMacOS();
  if (digest(sourceRuntime) !== EXPECTED_CODEX_SHA256) throw new Error("source_runtime_hash");
  const root = mkdtempSync("/private/tmp/asm-isolated-delete-");
  chmodSync(root, 0o700);
  for (const name of ["home", "codex", "project", "tmp", "cache"]) {
    const path = join(root, name);
    mkdirSync(path, { mode: 0o700 });
    assertEmpty(path);
  }
  copyFileSync(sourceRuntime, join(root, "codex-runtime"), 1);
  chmodSync(join(root, "codex-runtime"), 0o700);
  if (digest(join(root, "codex-runtime")) !== EXPECTED_CODEX_SHA256) throw new Error("copied_runtime_hash");
  const profilePath = join(root, "isolation.sb");
  writeFileSync(profilePath, sandboxProfile(root), { encoding: "utf8", flag: "wx", mode: 0o600 });
  const now = Date.now();
  const manifest = {
    schemaVersion: 1,
    kind: "asm-isolated-delete-0.153.4-prepared",
    root,
    preparedAtMs: now,
    expiresAtMs: now + PREPARED_LIFETIME_MS,
    sandboxProfileSha256: digest(profilePath),
    codexRuntimeSha256: EXPECTED_CODEX_SHA256,
  };
  writeExclusiveJSON(join(root, manifestName), manifest);
  return { status: "prepared", root, expiresAt: new Date(manifest.expiresAtMs).toISOString() };
}

function loadPrepared(value) {
  assertMacOS();
  const root = exactRoot(value);
  const manifest = safeReadJSON(join(root, manifestName));
  validatePreparedManifest(root, manifest);
  return { root, manifest, env: sanitizedEnvironment(root) };
}

function runSandbox(root, env, command, args, errorCode, logStem, timeoutMs = 60_000) {
  return checkedSpawn("/usr/bin/sandbox-exec", ["-f", join(root, "isolation.sb"), command, ...args], {
    cwd: join(root, "project"), env,
  }, errorCode, root, logStem, timeoutMs);
}

async function schema(value) {
  const { root, env } = loadPrepared(value);
  if (existsSync(join(root, claimName)) || existsSync(join(root, "public-schema"))) throw new Error("schema_order_or_replay");
  await isolationSelfChecks(root, env);
  validatePreparedManifest(root, safeReadJSON(join(root, manifestName)));
  runSandbox(root, env, join(root, "codex-runtime"), [
    "app-server", "generate-json-schema", "--out", join(root, "public-schema"),
  ], "schema_generation", "schema");
  writeExclusiveJSON(join(root, isolationProofName), {
    schemaVersion: 1,
    kind: "asm-isolated-delete-isolation-proof",
    sandboxProfileSha256: digest(join(root, "isolation.sb")),
    selfcheckStdoutSha256: digest(join(root, "selfcheck.stdout.log")),
    schemaDirectoryRelativePath: "public-schema",
  });
  return { status: "schema_generated", root };
}

async function isolationSelfChecks(root, env) {
  const sibling = mkdtempSync("/private/tmp/asm-isolated-delete-sibling-");
  chmodSync(sibling, 0o700);
  writeFileSync(join(sibling, "marker"), "blocked\n", { flag: "wx", mode: 0o600 });
  const listener = createServer((socket) => socket.destroy());
  await new Promise((resolve, reject) => {
    listener.once("error", reject);
    listener.listen(0, "127.0.0.1", resolve);
  });
  const port = listener.address().port;
  const check = `set -eu
mkdir "$ASM_ISOLATED_DELETE_ROOT/selfcheck"
printf permitted > "$ASM_ISOLATED_DELETE_ROOT/selfcheck/permitted"
test "$(cat "$ASM_ISOLATED_DELETE_ROOT/selfcheck/permitted")" = permitted
test "$(/usr/bin/perl -MCwd=realpath -e 'print realpath($ARGV[0])' "$ASM_ISOLATED_DELETE_ROOT")" = "$ASM_ISOLATED_DELETE_ROOT"
test "$(/usr/bin/perl -MCwd=realpath -e 'print realpath($ARGV[0])' "$ASM_ISOLATED_CODEX_HOME")" = "$ASM_ISOLATED_CODEX_HOME"
if cat "$ASM_ISOLATED_SIBLING/marker" >/dev/null 2>&1; then exit 41; fi
if printf blocked > "$ASM_ISOLATED_SIBLING/write" 2>/dev/null; then exit 42; fi
if /usr/bin/nc -z -w 1 127.0.0.1 "$ASM_ISOLATED_SELF_CHECK_PORT" >/dev/null 2>&1; then exit 43; fi
/usr/bin/env
`;
  try {
    const result = runSandbox(root, {
      ...env,
      ASM_ISOLATED_SIBLING: sibling,
      ASM_ISOLATED_SELF_CHECK_PORT: String(port),
    }, "/bin/sh", ["-c", check], "isolation_selfcheck", "selfcheck");
    const keys = result.stdout.trim().split("\n").filter(Boolean).map((line) => line.split("=", 1)[0]);
    if (keys.some((key) => /(SECRET|TOKEN|PASSWORD|CREDENTIAL|API_KEY)/i.test(key))) {
      throw new Error("secret_environment_present");
    }
  } finally {
    await new Promise((resolve) => listener.close(resolve));
  }
}

function validateIsolationProof(root) {
  const proof = safeReadJSON(join(root, isolationProofName));
  if (
    proof?.kind !== "asm-isolated-delete-isolation-proof"
    || proof?.sandboxProfileSha256 !== digest(join(root, "isolation.sb"))
    || proof?.selfcheckStdoutSha256 !== digest(join(root, "selfcheck.stdout.log"))
    || confinedExisting(root, proof?.schemaDirectoryRelativePath) !== join(root, "public-schema")
  ) throw new Error("isolation_proof_drift");
}

function build(value) {
  const { root, env } = loadPrepared(value);
  if (!existsSync(acceptanceSource)) throw new Error("acceptance_source_missing");
  if (existsSync(join(root, builtManifestName)) || existsSync(join(root, claimName))) throw new Error("build_order_or_replay");
  validateIsolationProof(root);
  const closureBefore = sourceClosureSha256();
  checkedSpawn("/usr/bin/swift", [
    "build", "--package-path", packageRoot, "--scratch-path", join(root, "build"),
    "--build-tests", "-Xswiftc", "-DASM_ISOLATED_DELETE_ACCEPTANCE",
  ], { cwd: packageRoot, env }, "test_build", root, "build", 600_000);
  const closureAfter = sourceClosureSha256();
  if (closureBefore !== closureAfter) throw new Error("source_drift_during_build");
  const bundle = findTestBundle(join(root, "build"));
  const executable = join(bundle, "Contents/MacOS/AgentSessionManagerPackageTests");
  if (!existsSync(executable) || !lstatSync(executable).isFile()) throw new Error("xctest_executable_missing");
  const smoke = runSandbox(root, env, xctestTool, ["-XCTest", SMOKE_TEST_SELECTOR, bundle], "smoke_test_failed", "smoke", 300_000);
  if (!exactXCTestSuccess(`${smoke.stdout}\n${smoke.stderr}`)) throw new Error("smoke_test_not_exact_one");
  const built = {
    schemaVersion: 1,
    kind: "asm-isolated-delete-0.153.4-built",
    testSelector: TEST_SELECTOR,
    smokeTestSelector: SMOKE_TEST_SELECTOR,
    xctestBundleRelativePath: bundle.slice(root.length + 1),
    xctestExecutableRelativePath: executable.slice(root.length + 1),
    runnerSha256: digest(runnerPath),
    acceptanceSourceSha256: digest(acceptanceSource),
    sourceClosureSha256: closureAfter,
    sandboxProfileSha256: digest(join(root, "isolation.sb")),
    codexRuntimeSha256: digest(join(root, "codex-runtime")),
    xctestExecutableSha256: digest(executable),
  };
  writeExclusiveJSON(join(root, builtManifestName), built);
  return { status: "built", root, testSelector: TEST_SELECTOR };
}

function validateBuilt(root) {
  const built = safeReadJSON(join(root, builtManifestName));
  if (
    built?.kind !== "asm-isolated-delete-0.153.4-built"
    || built?.testSelector !== TEST_SELECTOR
    || built?.smokeTestSelector !== SMOKE_TEST_SELECTOR
  ) throw new Error("built_manifest_shape");
  const executable = confinedExisting(root, built.xctestExecutableRelativePath);
  confinedExisting(root, built.xctestBundleRelativePath);
  if (
    built.runnerSha256 !== digest(runnerPath)
    || built.acceptanceSourceSha256 !== digest(acceptanceSource)
    || built.sourceClosureSha256 !== sourceClosureSha256()
    || built.sandboxProfileSha256 !== digest(join(root, "isolation.sb"))
    || built.codexRuntimeSha256 !== digest(join(root, "codex-runtime"))
    || built.xctestExecutableSha256 !== digest(executable)
  ) throw new Error("built_hash_drift");
  return built;
}

async function run(value) {
  const { root, env } = loadPrepared(value);
  if (existsSync(join(root, claimName))) throw new Error("run_already_claimed");
  validateIsolationProof(root);
  const built = validateBuilt(root);
  writeExclusiveJSON(join(root, claimName), {
    schemaVersion: 1,
    kind: "asm-isolated-delete-0.153.4-run-claim",
    claimedAt: new Date().toISOString(),
    preparedManifestSha256: digest(join(root, manifestName)),
    runnerSha256: built.runnerSha256,
    acceptanceSourceSha256: built.acceptanceSourceSha256,
    codexRuntimeSha256: built.codexRuntimeSha256,
    xctestExecutableSha256: built.xctestExecutableSha256,
  });
  const bundle = confinedExisting(root, built.xctestBundleRelativePath);
  const result = runSandbox(root, env, xctestTool, ["-XCTest", TEST_SELECTOR, bundle], "isolated_acceptance_failed", "run", 300_000);
  const combined = `${result.stdout}\n${result.stderr}`;
  if (!exactXCTestSuccess(combined) || !exactResultMarker(combined)) {
    throw new Error("xctest_result_not_exact_one");
  }
  return { status: "completed", root, testSelector: TEST_SELECTOR, xctestExitStatus: result.status };
}

export function exactXCTestSuccess(output) {
  return /Executed 1 test, with 0 failures/.test(output) && !/skipped/i.test(output);
}

export function exactResultMarker(output) {
  const prefix = "ASM_ISOLATED_DELETE_RESULT=";
  const lines = output.split("\n").filter((line) => line.startsWith(prefix));
  if (lines.length !== 1) return false;
  let value;
  try { value = JSON.parse(lines[0].slice(prefix.length)); } catch { return false; }
  const expectedKeys = [
    "archiveOutcome", "archiveRequestCount", "createdAllSourceCount", "createdMainCount",
    "creationInterruptRequestCount", "creationMethod", "creationTurnStatus",
    "deleteOutcome", "deleteRequestCount", "finalAllSourceCount", "finalMainCount",
    "initialAllSourceCount", "kind", "nativeSessionID", "previewStatus", "runtimeVersion",
    "schemaVersion", "status", "tombstoneCount", "trashMembershipCount",
  ];
  if (!sameArray(Object.keys(value).sort(), expectedKeys)) return false;
  return value.schemaVersion === 1
    && value.kind === "asm-isolated-delete-0.153.4-result"
    && value.status === "success" && value.runtimeVersion === "0.153.4"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value.nativeSessionID)
    && value.initialAllSourceCount === 0 && value.createdMainCount === 1
    && value.creationMethod === "thread/start+turn/start+bounded-stop"
    && ["failed", "interrupted"].includes(value.creationTurnStatus)
    && [0, 1].includes(value.creationInterruptRequestCount)
    && (value.creationTurnStatus !== "interrupted" || value.creationInterruptRequestCount === 1)
    && value.createdAllSourceCount === 1 && value.archiveOutcome === "success"
    && value.deleteOutcome === "success" && value.archiveRequestCount === 1
    && value.deleteRequestCount === 1 && value.finalMainCount === 0
    && value.finalAllSourceCount === 0 && value.previewStatus === "consumed"
    && value.trashMembershipCount === 0 && value.tombstoneCount === 1;
}

export function parseArguments(argv) {
  if (argv.length === 1 && argv[0] === "--prepare") return { action: "prepare" };
  if (argv.length === 2 && ["--schema", "--build", "--run"].includes(argv[0])) return { action: argv[0].slice(2), root: argv[1] };
  throw new Error("usage");
}

async function main() {
  const args = parseArguments(process.argv.slice(2));
  const report = args.action === "prepare"
    ? prepare()
    : args.action === "schema"
      ? await schema(args.root)
      : args.action === "build"
        ? build(args.root)
        : await run(args.root);
  process.stdout.write(`${JSON.stringify(report)}\n`);
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(runnerPath)) {
  main().catch((error) => {
    const safe = new Set([
      "acceptance_source_missing", "copied_runtime_hash", "initial_directory_not_empty", "invalid_root",
      "build_order_or_replay", "built_hash_drift", "built_manifest_shape", "isolated_acceptance_failed",
      "isolation_proof_drift", "isolation_selfcheck", "macos_required", "manifest_expired_or_root",
      "manifest_path_escape", "manifest_shape", "prepared_hash_drift", "run_already_claimed",
      "schema_generation", "schema_order_or_replay", "secret_environment_present", "source_runtime_hash",
      "smoke_test_failed", "smoke_test_not_exact_one", "source_closure_symlink",
      "source_drift_during_build", "test_build", "usage",
      "xctest_bundle_count", "xctest_executable_missing",
      "xctest_result_not_exact_one",
    ]);
    process.stdout.write(`${JSON.stringify({ status: "failed", error: safe.has(error?.message) ? error.message : "runner_failure" })}\n`);
    process.exitCode = 1;
  });
}
