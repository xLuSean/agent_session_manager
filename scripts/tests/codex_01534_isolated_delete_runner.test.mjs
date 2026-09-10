import assert from "node:assert/strict";
import test from "node:test";
import {
  EXPECTED_CODEX_SHA256, PREPARED_LIFETIME_MS, SMOKE_TEST_SELECTOR, TEST_SELECTOR,
  exactResultMarker, exactXCTestSuccess, isDirectIsolatedRootPath, parseArguments, sandboxProfile,
  sanitizedEnvironment, sha256,
} from "../run_codex_01534_isolated_delete_acceptance.mjs";
import { readFileSync } from "node:fs";

const root = "/private/tmp/asm-isolated-delete-testfixture";

test("runner has a single narrow four-action interface", () => {
  assert.deepEqual(parseArguments(["--prepare"]), { action: "prepare" });
  assert.deepEqual(parseArguments(["--schema", root]), { action: "schema", root });
  assert.deepEqual(parseArguments(["--build", root]), { action: "build", root });
  assert.deepEqual(parseArguments(["--run", root]), { action: "run", root });
  for (const invalid of [[], ["--run"], ["--prepare", root], ["--delete", root]]) {
    assert.throws(() => parseArguments(invalid), /usage/);
  }
});

test("only a direct disposable root is accepted", () => {
  assert.equal(isDirectIsolatedRootPath("/private/tmp/asm-isolated-delete-abc123"), true);
  assert.equal(isDirectIsolatedRootPath("/private/tmp/asm-isolated-delete-abc123/nested"), false);
  assert.equal(isDirectIsolatedRootPath("/tmp/asm-isolated-delete-abc123"), false);
  assert.equal(isDirectIsolatedRootPath("/private/tmp/not-isolated"), false);
});

test("runtime and XCTest authority are pinned", () => {
  assert.equal(EXPECTED_CODEX_SHA256, "b973d440acac501fd2594a43e7ca9ce41e0a65b9dfb28d0d7a7837c99e1261e3");
  assert.equal(TEST_SELECTOR, "AgentSessionManagerCoreTests.IsolatedDeleteAcceptanceTests/testOfficialIsolatedDeleteWhenExplicitlyEnabled");
  assert.equal(SMOKE_TEST_SELECTOR, "AgentSessionManagerCoreTests.IsolatedDeleteAcceptanceTests/testIsolatedRuntimeEnvironmentBeforeCreation");
  assert.equal(PREPARED_LIFETIME_MS, 1_800_000);
  assert.equal(sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

test("child environment is explicit and contains no inherited authority", () => {
  const env = sanitizedEnvironment(root);
  assert.deepEqual(Object.keys(env).sort(), [
    "ASM_ISOLATED_CODEX_HOME", "ASM_ISOLATED_DELETE_ACCEPTANCE", "ASM_ISOLATED_DELETE_CWD",
    "ASM_ISOLATED_DELETE_EXECUTABLE", "ASM_ISOLATED_DELETE_ROOT", "CODEX_HOME", "HOME", "LANG",
    "LC_ALL", "PATH", "TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
  ]);
  assert.equal(env.HOME, `${root}/home`);
  assert.equal(env.CODEX_HOME, `${root}/codex`);
  assert.equal(env.ASM_ISOLATED_DELETE_ACCEPTANCE, "1");
  assert.ok(!env.PATH.includes("/opt/homebrew/bin"));
});

test("sandbox denies network, non-root reads and writes, and keychain services", () => {
  const profile = sandboxProfile(root);
  assert.match(profile, /^\(version 1\)\n\(allow default\)/);
  assert.match(profile, /\(deny network\*\)/);
  assert.match(profile, /\(deny file-read\*\)/);
  assert.match(profile, /\(allow file-read\* \(literal "\/"\)\)/);
  assert.doesNotMatch(profile, /\(allow file-read\* \(subpath "\/"\)\)/);
  assert.match(profile, /\(allow file-read-metadata \(literal "\/private"\) \(literal "\/private\/tmp"\)\)/);
  assert.doesNotMatch(profile, /\(allow file-read\* \(subpath "\/private(?:\/tmp)?"\)\)/);
  assert.doesNotMatch(profile, /\(allow file-read-data[^\n]*"\/private/);
  assert.match(profile, /\(allow file-read\* \(subpath "\/private\/tmp\/asm-isolated-delete-testfixture"\)\)/);
  assert.match(profile, /\(deny file-write\*\)/);
  assert.match(profile, /\(allow file-write\* \(literal "\/dev\/null"\)\)/);
  assert.match(profile, /com\.apple\.securityd/);
  assert.match(profile, /\(deny appleevent-send\)/);
  assert.doesNotMatch(profile, /^\(deny mach-lookup\)$/m);
  assert.doesNotMatch(profile, /Users\/sean/);
});

test("system requirements probes receive metadata only, never directory contents", () => {
  const profile = sandboxProfile(root);
  assert.match(profile, /\(allow file-read-metadata \(literal "\/etc"\) \(literal "\/private\/etc"\)/);
  assert.match(profile, /\(literal "\/private\/etc\/codex\/requirements\.toml"\)/);
  assert.doesNotMatch(profile, /\(allow file-read(?:\*|-data)[^\n]*"\/(?:private\/)?etc/);
  assert.doesNotMatch(profile, /\(subpath "\/(?:private\/)?etc/);
});

test("listable fixture creation uses one bounded official test turn in the acceptance build", () => {
  const provider = readFileSync(new URL("../../macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexAppServerProvider.swift", import.meta.url), "utf8");
  const start = provider.indexOf("func startIsolatedDeleteAcceptanceThread(");
  const end = provider.indexOf("\n#endif", start);
  const creation = provider.slice(start, end);
  assert.ok(provider.lastIndexOf("#if ASM_ISOLATED_DELETE_ACCEPTANCE", start) > provider.lastIndexOf("#endif", start));
  assert.match(creation, /method: "thread\/start"/);
  assert.match(creation, /method: "turn\/start"/);
  assert.match(creation, /method: "turn\/interrupt"/);
  assert.match(creation, /addingTimeInterval\(4\)/);
  assert.match(creation, /addingTimeInterval\(3\)/);
  assert.match(creation, /\["failed", "interrupted"\]\.contains\(status\)/);
  assert.ok(creation.indexOf("try didCreate(response.thread.id)") < creation.indexOf('try finishIsolatedDeleteAcceptanceCreationTurn('));
  assert.doesNotMatch(creation, /method: "thread\/(?:delete|archive|inject_items)"|Data\(contentsOf:|write\(to:|FileManager/);
});

test("profile drift, replay, and zero-test success cannot pass", () => {
  const profile = sandboxProfile(root);
  assert.notEqual(sha256(`${profile}drift`), sha256(profile));
  assert.equal(exactXCTestSuccess("Executed 1 test, with 0 failures"), true);
  assert.equal(exactXCTestSuccess("Executed 0 tests, with 0 failures"), false);
  assert.equal(exactXCTestSuccess("Executed 1 test, with 0 failures (1 test skipped)"), false);
  const marker = {
    schemaVersion: 1, kind: "asm-isolated-delete-0.153.4-result", status: "success",
    runtimeVersion: "0.153.4", nativeSessionID: "12345678-1234-4123-8123-123456789ABC",
    initialAllSourceCount: 0, createdMainCount: 1, createdAllSourceCount: 1,
    creationMethod: "thread/start+turn/start+bounded-stop",
    creationTurnStatus: "interrupted", creationInterruptRequestCount: 1,
    archiveOutcome: "success", deleteOutcome: "success", archiveRequestCount: 1,
    deleteRequestCount: 1, finalMainCount: 0, finalAllSourceCount: 0,
    previewStatus: "consumed", trashMembershipCount: 0, tombstoneCount: 1,
  };
  assert.equal(exactResultMarker(`ASM_ISOLATED_DELETE_RESULT=${JSON.stringify(marker)}`), true);
  assert.equal(exactResultMarker(""), false);
  assert.equal(exactResultMarker(`ASM_ISOLATED_DELETE_RESULT=${JSON.stringify({ ...marker, deleteRequestCount: 0 })}`), false);
  assert.equal(exactResultMarker(`ASM_ISOLATED_DELETE_RESULT=${JSON.stringify({ ...marker, creationMethod: "thread/start" })}`), false);
  assert.equal(exactResultMarker(`ASM_ISOLATED_DELETE_RESULT=${JSON.stringify({ ...marker, creationTurnStatus: "completed" })}`), false);
  assert.equal(exactResultMarker(`ASM_ISOLATED_DELETE_RESULT=${JSON.stringify({ ...marker, creationInterruptRequestCount: 0 })}`), false);
  assert.equal(exactResultMarker(`ASM_ISOLATED_DELETE_RESULT=${JSON.stringify({ ...marker, creationTurnStatus: "failed", creationInterruptRequestCount: 0 })}`), true);
  const runner = readFileSync(new URL("../run_codex_01534_isolated_delete_acceptance.mjs", import.meta.url), "utf8");
  assert.match(runner, /if \(existsSync\(join\(root, claimName\)\)\) throw new Error\("run_already_claimed"\)/);
  assert.match(runner, /openSync\(path, "wx", 0o600\)/);
});
