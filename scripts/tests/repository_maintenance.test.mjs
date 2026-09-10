import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const scripts = join(root, "scripts");
function files(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry =>
    entry.isDirectory() ? files(join(directory, entry.name)) : [join(directory, entry.name)]);
}

test("verification discovers every maintained script test", () => {
  const verify = readFileSync(join(scripts, "verify.sh"), "utf8");
  assert.ok(verify.includes('node --test "$SCRIPT_DIR"/tests/*.test.mjs'));
  assert.ok(verify.includes('"$SCRIPT_DIR/verify_documentation.mjs"'));
  assert.ok(verify.includes('"$SHIPPING_BOUNDARY_CHECK"'));
  assert.ok(verify.includes("xcodebuild"));
  for (const key of ["AGENT_SESSION_MANAGER_LIVE_TEST", "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE", "ASM_ISOLATED_DELETE_ACCEPTANCE"]) {
    assert.equal(verify.split("-u " + key).length - 1, 3, "every Swift/App stage must drop " + key);
  }
});

test("retired experimental entrypoints and authorization fixtures stay out of scripts", () => {
  const retired = files(scripts).map(file => file.slice(scripts.length + 1)).filter(file =>
    /codex_desktop_(?:e\d|m4f\d)/.test(file) ||
    /(?:^|\/)live_.*_authorization\./.test(file) ||
    /(?:prepare_ghost_repair_.*canary|ghost_repair_.*canary_contracts)/.test(file) ||
    file.startsWith("tests/fixtures/ghost-contracts/") ||
    ["codex_ghost_delete.py", "compare_sqlite_logical.mjs", "verify_experiment_progressive_disclosure.mjs"].includes(file));
  assert.deepEqual(retired, [], "restore durable checks by function, not retired operator recipes");
});

test("all maintained relative JavaScript imports resolve", () => {
  for (const file of files(scripts).filter(file => file.endsWith(".mjs"))) {
    const content = readFileSync(file, "utf8");
    for (const match of content.matchAll(/(?:from\s*|import\s*)["'](\.\.?\/[^"']+)["']/g)) {
      assert.ok(existsSync(resolve(dirname(file), match[1])), file + " -> " + match[1]);
    }
  }
});

test("public build and audit entrypoints remain available", () => {
  for (const name of [
    "verify.sh", "verify_documentation.mjs", "verify_shipping_boundary.sh",
    "package_dmg.sh", "package_lifecycle_canary_dmg.sh",
    "run_codex_update_compatibility_audit.sh", "run_codex_lifecycle_update_audit.sh",
    "verify_lifecycle_runtime_compatibility.sh", "audit_app_server_contract.sh",
    "audit_codex_update_compatibility.mjs", "configure_git_hooks.sh",
    "run_codex_01534_isolated_delete_acceptance.mjs",
  ]) assert.ok(existsSync(join(scripts, name)), name);
});
