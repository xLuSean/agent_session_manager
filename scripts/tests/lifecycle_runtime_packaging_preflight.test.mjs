import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const repositoryRoot = resolve(import.meta.dirname, "../..");
const verifier = join(repositoryRoot, "scripts/verify_lifecycle_runtime_compatibility.sh");
const wrapper = join(repositoryRoot, "scripts/package_lifecycle_canary_dmg.sh");

function fakeCodex(versionOutput) {
  const root = mkdtempSync(join(tmpdir(), "asm-lifecycle-preflight-"));
  const executable = join(root, "codex");
  writeFileSync(executable, `#!/bin/zsh\nprint -r -- ${JSON.stringify(versionOutput)}\n`);
  chmodSync(executable, 0o700);
  return executable;
}

function syntheticContract({ lifecycleExact = null, conditionalDeleteExact = null } = {}) {
  const root = mkdtempSync(join(tmpdir(), "asm-lifecycle-preflight-contract-"));
  const source = join(root, "Contract.swift");
  const lifecycleEquality = lifecycleExact
    ? `\n            || runtimeVersion == "${lifecycleExact}"`
    : "";
  const conditionalDeleteEquality = conditionalDeleteExact
    ? `\n#if ASM_ISOLATED_DELETE_ACCEPTANCE\n            || runtimeVersion == "${conditionalDeleteExact}"\n#endif`
    : "";
  writeFileSync(source, `public enum Contract {
    public static func supportsVerifiedLifecycleContract(_ runtimeVersion: String?) -> Bool {
        versionBelongsToAuditedSeries(runtimeVersion, release: "0.147.0")${lifecycleEquality}
    }

    public static func supportsVerifiedDeleteContract(_ runtimeVersion: String?) -> Bool {
        versionBelongsToAuditedSeries(runtimeVersion, release: "0.147.0")${conditionalDeleteEquality}
    }
}
`);
  return source;
}

function run(versionOutput, operations, contractSource = null) {
  return spawnSync(verifier, operations, {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: {
      ...process.env,
      CODEX_EXECUTABLE_OVERRIDE: fakeCodex(versionOutput),
      ...(contractSource
        ? { CODEX_LIFECYCLE_CONTRACT_SOURCE_OVERRIDE: contractSource }
        : {}),
    },
  });
}

test("0.147.0 passes Archive and Permanent Delete packaging preflight", () => {
  const result = run("codex-cli 0.147.0", ["archive", "permanent-delete"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Observed runtime: 0\.147\.0/);
  assert.match(result.stdout, /Compatible: archive/);
  assert.match(result.stdout, /Compatible: permanent-delete/);
});

test("0.148.0 passes Archive but fails Permanent Delete before packaging", () => {
  const result = run("codex-cli 0.148.0", ["archive", "permanent-delete"]);
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Compatible: archive/);
  assert.match(result.stderr, /outside the audited allow-list for: permanent-delete/);
  assert.match(result.stderr, /No lifecycle canary DMG was built/);
});

test("0.149.0 passes Archive Restore and Move to Trash but blocks Permanent Delete", () => {
  const result = run("codex-cli 0.149.0", [
    "archive",
    "restore",
    "move-to-trash",
    "permanent-delete",
  ]);
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Compatible: archive/);
  assert.match(result.stdout, /Compatible: restore/);
  assert.match(result.stdout, /Compatible: move-to-trash/);
  assert.match(result.stderr, /outside the audited allow-list for: permanent-delete/);
  assert.match(result.stderr, /No lifecycle canary DMG was built/);
});

test("verified exact 0.153.4 passes reversible lifecycle and Permanent Delete preflight", () => {
  const result = run("codex-cli 0.153.4", [
    "archive",
    "restore",
    "move-to-trash",
    "permanent-delete",
  ]);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /Compatible: archive/);
  assert.match(result.stdout, /Compatible: restore/);
  assert.match(result.stdout, /Compatible: move-to-trash/);
  assert.match(result.stdout, /Compatible: permanent-delete/);
  assert.equal(result.stderr, "");
});

test("unverified neighboring and prerelease runtimes cannot enable Permanent Delete", () => {
  for (const version of ["0.153.3", "0.153.4-alpha.1", "0.153.5"]) {
    const result = run(`codex-cli ${version}`, ["permanent-delete"]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /outside the audited allow-list for: permanent-delete/);
  }
});

test("neighboring 0.153 runtimes remain blocked before packaging", () => {
  for (const version of ["0.153.3", "0.153.5"]) {
    const result = run(`codex-cli ${version}`, ["archive", "restore", "move-to-trash"]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`Codex runtime ${version.replaceAll(".", "\\.")}`));
    assert.match(result.stderr, /archive, restore, move-to-trash/);
    assert.match(result.stderr, /No lifecycle canary DMG was built/);
  }
});

test("exact equality admits only its runtime and ignores conditional Delete branches", () => {
  const contract = syntheticContract({
    lifecycleExact: "0.153.4",
    conditionalDeleteExact: "0.153.4",
  });
  const exact = run("codex-cli 0.153.4", ["archive", "permanent-delete"], contract);
  assert.equal(exact.status, 1);
  assert.match(exact.stdout, /Compatible: archive/);
  assert.match(
    exact.stderr,
    /outside the audited allow-list for: permanent-delete/,
  );

  for (const version of ["0.153.4-alpha.1", "0.153.3", "0.153.5"]) {
    const rejected = run(`codex-cli ${version}`, ["archive"], contract);
    assert.equal(rejected.status, 1);
    assert.match(rejected.stderr, /outside the audited allow-list for: archive/);
  }
});

test("0.150.0 remains blocked for all lifecycle operations", () => {
  const result = run("codex-cli 0.150.0", ["archive", "move-to-trash", "permanent-delete"]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Codex runtime 0\.150\.0/);
  assert.match(result.stderr, /archive, move-to-trash, permanent-delete/);
  assert.match(result.stderr, /No lifecycle canary DMG was built/);
});

test("malformed version output fails closed", () => {
  const result = run("Codex 0.147.0", ["archive"]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Expected exact 'codex-cli <version>' output/);
});

test("lifecycle canary wrapper runs preflight before generic packaging", () => {
  const source = readFileSync(wrapper, "utf8");
  const preflight = source.indexOf("verify_lifecycle_runtime_compatibility.sh");
  const packaging = source.indexOf('"$SCRIPT_DIR/package_dmg.sh"');
  assert.ok(preflight >= 0);
  assert.ok(packaging > preflight);
  assert.match(source, /archive[\s\\]+move-to-trash[\s\\]+permanent-delete/);
});
