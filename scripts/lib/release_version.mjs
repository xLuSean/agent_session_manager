import { readFileSync } from "node:fs";

export const versionFile = "macos/AgentSessionManager/App/AgentSessionManager/Config/Version.xcconfig";
export function parseVersion(text) {
  const fields = {};
  for (const line of text.split(/\r?\n/)) {
    const value = line.replace(/\/\/.*$/, "").trim();
    if (!value) continue;
    const match = /^(MARKETING_VERSION|CURRENT_PROJECT_VERSION|ASM_RELEASE_SUFFIX)\s*=\s*(.*?)\s*$/.exec(value);
    if (!match || Object.hasOwn(fields, match[1])) throw Error("Invalid or duplicate version setting");
    fields[match[1]] = match[2];
  }
  const marketingVersion = fields.MARKETING_VERSION;
  const buildNumber = fields.CURRENT_PROJECT_VERSION;
  const releaseSuffix = fields.ASM_RELEASE_SUFFIX;
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(marketingVersion ?? "")) throw Error("Invalid marketing version");
  const numbers = marketingVersion.split(".").map(Number);
  if (numbers.some(n => !Number.isSafeInteger(n)) || numbers[2] > 999) throw Error("Version segment limit reached");
  if (!/^[1-9]\d{0,3}$/.test(buildNumber ?? "")) throw Error("Build must be 1…9999");
  if (releaseSuffix === undefined || (releaseSuffix !== "" &&
      (!/^[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*$/.test(releaseSuffix) ||
       releaseSuffix.split(".").some(s => /^0\d+$/.test(s))))) throw Error("Invalid release suffix");
  return { marketingVersion, buildNumber, releaseSuffix };
}
export function readVersion(root) { return parseVersion(readFileSync(`${root}/${versionFile}`, "utf8")); }
export function releaseVersion(value) { return value.marketingVersion + (value.releaseSuffix ? `-${value.releaseSuffix}` : ""); }
export function nextVersion(value, { nextMinor = false, final = false } = {}) {
  let [major, minor, patch] = value.marketingVersion.split(".").map(Number);
  if (nextMinor) { minor++; patch = 100; }
  else { patch = Math.max(100, patch + 1); }
  return parseVersion(formatVersion({ marketingVersion: `${major}.${minor}.${patch}`,
    buildNumber: String(Number(value.buildNumber) + 1), releaseSuffix: final ? "" : value.releaseSuffix }));
}
export function formatVersion(value) {
  return `// Single version source; changed only when preparing a new candidate.\nMARKETING_VERSION = ${value.marketingVersion}\nCURRENT_PROJECT_VERSION = ${value.buildNumber}\nASM_RELEASE_SUFFIX = ${value.releaseSuffix}\n`;
}
export function artifactNames(value, architecture = "arm64") {
  if (architecture !== "arm64") throw Error("Only arm64 candidates are currently supported");
  const dmg = `Agent-Session-Manager-${releaseVersion(value)}-${architecture}.dmg`;
  return { dmg, checksum: dmg + ".sha256", manifest: dmg + ".candidate.json" };
}
export function rejectOverrides(env) {
  for (const key of ["VERSION_OVERRIDE", "BUILD_NUMBER_OVERRIDE", "RELEASE_SUFFIX_OVERRIDE", "ARCHITECTURE_OVERRIDE"]) {
    if (Object.hasOwn(env, key)) throw Error(`${key} is not supported; use the committed version file`);
  }
}
