#!/usr/bin/env node
import { constants, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { artifactNames, formatVersion, nextVersion, parseVersion, readVersion, rejectOverrides, releaseVersion, versionFile } from "./lib/release_version.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: root, encoding: "utf8", maxBuffer: 128 * 1024 * 1024, ...options });
  if (result.error || result.status !== 0) throw Error(`${command} failed (${result.status ?? "unavailable"}): ${result.stderr ?? ""}`);
  return typeof result.stdout === "string" ? result.stdout.trim() : result.stdout;
}
const git = (...args) => run("git", args);
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const present = path => { try { lstatSync(path); return true; } catch (e) { if (e.code === "ENOENT") return false; throw e; } };
function regular(path) {
  if (!lstatSync(path).isFile() || lstatSync(path).isSymbolicLink()) throw Error(`Not a regular file: ${basename(path)}`);
}
function clean() {
  if (git("status", "--porcelain", "--untracked-files=all")) throw Error("Commit reviewed changes before preparing or packaging a candidate");
}
function scope(local) {
  const branch = git("symbolic-ref", "--quiet", "--short", "HEAD");
  if (!local && branch !== "main") throw Error("Public candidates require clean main. Use --local explicitly for a local-only candidate");
}
function identity() { return { sourceCommit: git("rev-parse", "HEAD"), sourceTree: git("rev-parse", "HEAD^{tree}") }; }
function tagExists(tag) { return spawnSync("git", ["show-ref", "--verify", "--quiet", `refs/tags/${tag}`], { cwd: root }).status === 0; }
function collision(value) {
  for (const name of Object.values(artifactNames(value))) {
    if (present(join(root, "dist", name))) throw Error(`Candidate already exists; never overwrite: ${name}`);
  }
  if (tagExists(`v${releaseVersion(value)}`)) throw Error("Candidate tag already exists; prepare a new version");
}
function trash(path) {
  run("trash", [path]);
  if (present(path)) throw Error(`Temporary data remains at ${path}`);
}
function transaction(action, body) {
  const output = join(root, "dist");
  if (present(output) && (!lstatSync(output).isDirectory() || lstatSync(output).isSymbolicLink())) throw Error("dist must be a real directory");
  mkdirSync(output, { recursive: true });
  const lock = join(output, ".release-lock");
  mkdirSync(lock, { mode: 0o700 }); // Atomic: interruptions/concurrent runs fail closed.
  const state = { action, status: "running", ...identity() };
  const journal = join(lock, "transaction.json");
  writeFileSync(journal, JSON.stringify(state, null, 2), { flag: "wx", mode: 0o600 });
  try {
    body();
    writeFileSync(journal, JSON.stringify({ ...state, status: "completed", ...identity() }, null, 2));
    trash(lock);
  } catch (error) {
    writeFileSync(journal, JSON.stringify({ ...state, status: "needsReview", ...identity() }, null, 2));
    throw Error(`${error.message}\nTransaction retained at ${lock}. Inspect before moving it to Trash; do not blindly rerun.`);
  }
}
function packageCandidate(value, localOnly) {
  clean(); scope(localOnly); collision(value);
  if (Number(value.marketingVersion.split(".")[2]) < 100) throw Error("Legacy version: use prepare to start patch numbering at 100");
  const source = identity();
  const names = artifactNames(value);
  const work = mkdtempSync(join(tmpdir(), "asm-candidate-"));
  try {
    const exported = join(work, "source");
    const staged = join(work, "artifacts");
    mkdirSync(exported); mkdirSync(staged);
    const archive = run("git", ["archive", "--format=tar", source.sourceCommit], { encoding: null });
    run("tar", ["-xf", "-", "-C", exported], { input: archive });
    if (JSON.stringify(readVersion(exported)) !== JSON.stringify(value)) throw Error("Exported version differs from requested candidate");
    run("/bin/zsh", [join(exported, "scripts/lib/package_candidate.sh"), value.marketingVersion,
      value.buildNumber, value.releaseSuffix, source.sourceCommit, source.sourceTree, staged], { cwd: exported, stdio: "inherit" });
    const dmg = join(staged, names.dmg);
    regular(dmg);
    const bytes = readFileSync(dmg);
    const checksum = `${sha(bytes)}  ${names.dmg}\n`;
    const manifest = { schemaVersion: 1, ...value, releaseVersion: releaseVersion(value),
      tagName: `v${releaseVersion(value)}`, ...source, architecture: "arm64", localOnly,
      artifact: { name: names.dmg, bytes: bytes.length, sha256: sha(bytes) }, checksumFile: names.checksum };
    writeFileSync(join(staged, names.checksum), checksum, { flag: "wx" });
    writeFileSync(join(staged, names.manifest), JSON.stringify(manifest, null, 2) + "\n", { flag: "wx" });
    clean(); scope(localOnly);
    if (identity().sourceCommit !== source.sourceCommit) throw Error("HEAD changed while packaging");
    collision(value);
    // Publish without replacement. A partial publication retains the transaction.
    for (const name of Object.values(names)) copyFileSync(join(staged, name), join(root, "dist", name), constants.COPYFILE_EXCL);
    console.log(JSON.stringify(manifest, null, 2));
    console.log(`Candidate ready: dist/${names.manifest}\nInstall and test this exact DMG. No tag or remote operation was performed.`);
  } finally {
    try { trash(work); } catch { console.error(`Temporary candidate files retained at ${work}`); }
  }
}
function finalize(path) {
  clean(); scope(false);
  const file = resolve(root, path);
  if (dirname(file) !== join(root, "dist")) throw Error("Select an exact manifest directly in dist");
  regular(file);
  if (lstatSync(file).size > 64 * 1024) throw Error("Manifest exceeds size limit");
  const manifest = JSON.parse(readFileSync(file, "utf8"));
  const keys = ["schemaVersion", "marketingVersion", "buildNumber", "releaseSuffix", "releaseVersion", "tagName",
    "sourceCommit", "sourceTree", "architecture", "localOnly", "artifact", "checksumFile"].sort();
  if (JSON.stringify(Object.keys(manifest).sort()) !== JSON.stringify(keys) ||
      JSON.stringify(Object.keys(manifest.artifact ?? {}).sort()) !== JSON.stringify(["bytes", "name", "sha256"])) {
    throw Error("Unexpected manifest fields; only release evidence may enter a tag");
  }
  const value = parseVersion(formatVersion(manifest));
  const names = artifactNames(value, manifest.architecture);
  const source = identity();
  if (manifest.schemaVersion !== 1 || manifest.architecture !== "arm64" || manifest.localOnly !== false || basename(file) !== names.manifest ||
      JSON.stringify(value) !== JSON.stringify(readVersion(root)) || manifest.releaseVersion !== releaseVersion(value) ||
      manifest.tagName !== `v${releaseVersion(value)}` || manifest.checksumFile !== names.checksum ||
      manifest.sourceCommit !== source.sourceCommit || manifest.sourceTree !== source.sourceTree ||
      manifest.artifact?.name !== names.dmg) throw Error("Manifest does not match the current public candidate source");
  const dmg = join(root, "dist", names.dmg), checksum = join(root, "dist", names.checksum);
  regular(dmg); regular(checksum);
  const bytes = readFileSync(dmg);
  if (bytes.length !== manifest.artifact.bytes || sha(bytes) !== manifest.artifact.sha256 ||
      readFileSync(checksum, "utf8") !== `${sha(bytes)}  ${names.dmg}\n`) throw Error("Candidate checksum or size mismatch");
  const annotation = `ASM candidate\n${JSON.stringify(manifest)}`;
  if (tagExists(manifest.tagName)) {
    if (git("cat-file", "-t", `refs/tags/${manifest.tagName}`) !== "tag" ||
        git("rev-parse", `${manifest.tagName}^{commit}`) !== source.sourceCommit ||
        git("for-each-ref", "--format=%(contents)", `refs/tags/${manifest.tagName}`) !== annotation) throw Error("Existing tag has different evidence; it will not be moved");
    console.log("Already finalized; matching tag and artifacts verified.");
    return;
  }
  git("tag", "-a", manifest.tagName, source.sourceCommit, "-m", annotation);
  console.log(`Local tag created: ${manifest.tagName}\nNo push or GitHub operation was performed. Public-history/privacy review is still required before pushing.`);
}
function main(args) {
  rejectOverrides(process.env);
  const [action, ...rest] = args;
  if (!["plan", "prepare", "package", "finalize"].includes(action)) throw Error("Usage: release.sh plan|prepare [--local] [--next-minor] [--final]; package [--local]; finalize dist/<exact>.candidate.json --tested");
  if (action === "finalize") {
    if (rest.length !== 2 || rest[1] !== "--tested") throw Error("After manually testing the exact DMG: finalize dist/<exact>.candidate.json --tested");
    transaction(action, () => finalize(rest[0])); return;
  }
  if (new Set(rest).size !== rest.length || rest.some(a => !(action === "package" ? ["--local"] : ["--local", "--next-minor", "--final"]).includes(a))) throw Error("Unknown or duplicate option");
  const local = rest.includes("--local");
  const current = readVersion(root);
  const next = action === "package" ? current : nextVersion(current, { nextMinor: rest.includes("--next-minor"), final: rest.includes("--final") });
  if (action === "plan") {
    console.log(JSON.stringify({ current, next, releaseVersion: releaseVersion(next), tagName: `v${releaseVersion(next)}`,
      localOnly: local, artifacts: artifactNames(next), dirty: Boolean(git("status", "--porcelain")),
      requiredBranch: local ? "current named branch" : "main" }, null, 2)); return;
  }
  clean(); scope(local); collision(next);
  transaction(action, () => {
    clean(); scope(local); collision(next);
    const plannedSource = identity();
    if (action === "prepare") {
      writeFileSync(join(root, versionFile), formatVersion(next));
      run("/bin/zsh", [join(root, "scripts/verify.sh")], { stdio: "inherit" });
      if (identity().sourceCommit !== plannedSource.sourceCommit) throw Error("HEAD changed during verification");
      scope(local);
      if (JSON.stringify(readVersion(root)) !== JSON.stringify(next)) throw Error("Version changed during verification");
      const changed = git("diff", "--name-only", "HEAD").split("\n");
      if (changed.length !== 1 || changed[0] !== versionFile || git("ls-files", "--others", "--exclude-standard")) throw Error("Verification changed files outside the version source");
      git("add", "--", versionFile);
      git("commit", "-m", `release: prepare v${releaseVersion(next)}`, "--", versionFile);
    }
    packageCandidate(next, local);
  });
}
try { main(process.argv.slice(2)); } catch (error) { console.error(error.message); process.exitCode = 1; }
