import assert from "node:assert/strict";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { artifactNames, formatVersion, nextVersion, parseVersion, readVersion, rejectOverrides, releaseVersion, versionFile } from "../lib/release_version.mjs";

const repo = resolve(import.meta.dirname, "../..");
const baseline = { marketingVersion: "0.1.3", buildNumber: "18", releaseSuffix: "alpha.1" };
test("candidate numbering starts at 100 and build is independent", () => {
  const first = nextVersion(baseline);
  assert.deepEqual(first, { marketingVersion: "0.1.100", buildNumber: "19", releaseSuffix: "alpha.1" });
  assert.equal(releaseVersion(nextVersion(first)), "0.1.101-alpha.1");
  assert.deepEqual(nextVersion(first, { nextMinor: true, final: true }),
    { marketingVersion: "0.2.100", buildNumber: "20", releaseSuffix: "" });
  assert.equal(nextVersion({ ...first, releaseSuffix: "" }).releaseSuffix, "");
  assert.equal(artifactNames(first).dmg, "Agent-Session-Manager-0.1.100-alpha.1-arm64.dmg");
});
test("invalid versions and overrides stop without rollover", () => {
  for (const value of [
    { ...baseline, marketingVersion: "0.01.100" }, { ...baseline, marketingVersion: "0.1.1000" },
    { ...baseline, buildNumber: "0" }, { ...baseline, buildNumber: "019" },
    { ...baseline, releaseSuffix: "alpha.01" }, { ...baseline, releaseSuffix: "../unsafe" },
  ]) assert.throws(() => parseVersion(formatVersion(value)));
  assert.throws(() => nextVersion({ ...baseline, marketingVersion: "0.1.999" }));
  assert.throws(() => nextVersion({ ...baseline, buildNumber: "9999" }));
  assert.throws(() => parseVersion(formatVersion(baseline) + "MARKETING_VERSION = 0.1.100\n"));
  for (const key of ["VERSION_OVERRIDE", "BUILD_NUMBER_OVERRIDE", "RELEASE_SUFFIX_OVERRIDE", "ARCHITECTURE_OVERRIDE"]) {
    assert.throws(() => rejectOverrides({ [key]: "" }));
  }
});
test("Debug and Release use the same committed version source", () => {
  readVersion(repo);
  const project = readFileSync(join(repo, "macos/AgentSessionManager/App/AgentSessionManager/AgentSessionManager.xcodeproj/project.pbxproj"), "utf8");
  assert.equal((project.match(/baseConfigurationReference = .*Version.xcconfig/g) ?? []).length, 2);
  assert.doesNotMatch(project, /(?:MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=/);
  const worker = readFileSync(join(repo, "scripts/lib/package_candidate.sh"), "utf8");
  assert.match(worker, /ASMSourceCommit/); assert.match(worker, /ASMReleaseSuffix/);
  assert.match(worker, /cmp .*BUILT_APP.*MOUNTED_APP/);
  assert.doesNotMatch(worker, /trash "\$DMG_PATH"/);
});

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "asm-release-test-"));
  t.after(() => {
    const result = spawnSync("trash", [root]);
    assert.equal(result.status, 0, "fixture cleanup needs macOS Trash access");
    assert.equal(existsSync(root), false);
  });
  for (const file of ["scripts/release.mjs", "scripts/lib/release_version.mjs"]) {
    mkdirSync(dirname(join(root, file)), { recursive: true }); copyFileSync(join(repo, file), join(root, file));
  }
  mkdirSync(dirname(join(root, versionFile)), { recursive: true });
  writeFileSync(join(root, versionFile), formatVersion(baseline));
  writeFileSync(join(root, ".gitignore"), "dist/\n");
  writeFileSync(join(root, "scripts/verify.sh"), "#!/bin/zsh\nexit 0\n");
  // Fake packaging is confined to this synthetic repository, never a production override.
  writeFileSync(join(root, "scripts/lib/package_candidate.sh"), '#!/bin/zsh\nnode "${0:A:h}/fake-worker.mjs" "$@"\n');
  writeFileSync(join(root, "scripts/lib/fake-worker.mjs"), `import {writeFileSync} from 'node:fs';
const [v,b,s,c,t,out]=process.argv.slice(2);
writeFileSync(out+'/Agent-Session-Manager-'+v+(s?'-'+s:'')+'-arm64.dmg',JSON.stringify({v,b,s,c,t}));\n`);
  const git = (...args) => {
    const r = spawnSync("git", args, { cwd: root, encoding: "utf8" });
    assert.equal(r.status, 0, r.stderr); return r.stdout.trim();
  };
  git("init", "-b", "main"); git("config", "user.name", "Fixture"); git("config", "user.email", "fixture@example.invalid");
  git("config", "core.hooksPath", "/dev/null"); git("config", "commit.gpgsign", "false"); git("config", "tag.gpgsign", "false");
  git("add", "."); git("commit", "-m", "fixture");
  const run = (...args) => spawnSync(process.execPath, [join(root, "scripts/release.mjs"), ...args], {
    cwd: root, encoding: "utf8", env: Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.endsWith("_OVERRIDE"))), timeout: 30000 });
  return { root, git, run };
}
test("plan is read-only; prepare exports exact source and emits three matching artifacts; finalize is idempotent", t => {
  const { root, git, run } = fixture(t);
  const head = git("rev-parse", "HEAD");
  const plan = run("plan"); assert.equal(plan.status, 0, plan.stderr);
  assert.equal(JSON.parse(plan.stdout).next.marketingVersion, "0.1.100");
  assert.equal(existsSync(join(root, "dist")), false); assert.equal(git("rev-parse", "HEAD"), head);
  const prepared = run("prepare"); assert.equal(prepared.status, 0, prepared.stderr);
  const names = artifactNames(nextVersion(baseline));
  for (const name of Object.values(names)) assert.ok(existsSync(join(root, "dist", name)));
  assert.equal(git("tag"), "");
  const manifest = JSON.parse(readFileSync(join(root, "dist", names.manifest)));
  assert.equal(manifest.sourceCommit, git("rev-parse", "HEAD"));
  assert.equal(manifest.sourceTree, git("rev-parse", "HEAD^{tree}"));
  assert.equal(manifest.buildNumber, "19");
  assert.equal(run("package").status, 1, "Never replace a delivered candidate");
  assert.equal(run("finalize", `dist/${names.manifest}`).status, 1, "Manual acceptance must be explicit");
  for (let i=0;i<2;i++) { const r=run("finalize", `dist/${names.manifest}`, "--tested"); assert.equal(r.status, 0, r.stderr); }
  assert.equal(git("cat-file", "-t", manifest.tagName), "tag");
});
test("local candidates require opt-in and cannot be finalized as public", t => {
  const { root, git, run } = fixture(t);
  git("switch", "-c", "codex/fixture");
  assert.equal(run("prepare").status, 1);
  const prepared=run("prepare", "--local"); assert.equal(prepared.status, 0, prepared.stderr);
  const name=artifactNames(nextVersion(baseline)).manifest;
  assert.equal(JSON.parse(readFileSync(join(root,"dist",name))).localOnly, true);
  git("branch", "-m", "main", "old-main"); git("branch", "-m", "main");
  assert.equal(run("finalize", `dist/${name}`, "--tested").status, 1);
  assert.equal(git("tag"), "");
});
test("failed verification preserves version changes and blocks automatic replay", t => {
  const { root, git, run }=fixture(t);
  writeFileSync(join(root,"scripts/verify.sh"), "#!/bin/zsh\nexit 1\n"); git("add", "."); git("commit", "-m", "failing fixture");
  const head=git("rev-parse","HEAD");
  assert.equal(run("prepare").status, 1);
  assert.equal(readVersion(root).marketingVersion, "0.1.100"); assert.equal(git("rev-parse","HEAD"),head);
  assert.equal(JSON.parse(readFileSync(join(root,"dist/.release-lock/transaction.json"))).status,"needsReview");
  assert.equal(run("prepare").status, 1); assert.equal(git("tag"), "");
});
test("tampered candidate cannot be finalized", t => {
  const { root, git, run }=fixture(t);
  const prepared=run("prepare"); assert.equal(prepared.status,0,prepared.stderr);
  const names=artifactNames(nextVersion(baseline));
  writeFileSync(join(root,"dist",names.dmg),"tampered");
  const result=run("finalize",`dist/${names.manifest}`,"--tested");
  assert.equal(result.status,1); assert.match(result.stderr,/checksum or size mismatch/); assert.equal(git("tag"),"");
});
test("unrecognized manifest fields cannot be copied into a publication tag", t => {
  const { root, git, run }=fixture(t);
  const prepared=run("prepare"); assert.equal(prepared.status,0,prepared.stderr);
  const name=artifactNames(nextVersion(baseline)).manifest;
  const path=join(root,"dist",name);
  const data=JSON.parse(readFileSync(path)); data.privateNotes="fixture-only";
  writeFileSync(path,JSON.stringify(data));
  const result=run("finalize",`dist/${name}`,"--tested");
  assert.equal(result.status,1); assert.match(result.stderr,/Unexpected manifest fields/); assert.equal(git("tag"),"");
});
