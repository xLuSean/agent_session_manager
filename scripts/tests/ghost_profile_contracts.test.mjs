import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import {
  analyzeAbsenceProfiles,
  analyzeSnapshotProfiles,
  analyzeRequestProfileSelection,
  analyzeSourceAdmission,
} from "./support/ghost_profile_contracts.mjs";
import { repositorySources } from "./support/repository_sources.mjs";

const baseline = repositorySources();
test("v166 runtime admission remains bound to captured isolated evidence", () => {
  const bytes = readFileSync(new URL("../fixtures/current-v166-read-only-evidence.json", import.meta.url));
  const digest = createHash("sha256").update(bytes).digest("hex");
  assert.ok(baseline.profiles.includes('compatibilityFixtureSHA256: "' + digest + '"'));
  const evidence = JSON.parse(bytes);
  assert.deepEqual(evidence.runtimeProfiles.map(value => value.runtimeVersion), ["0.164.0", "0.166.0-alpha.5.1"]);
  for (const runtime of evidence.runtimeProfiles) {
    assert.ok(baseline.profiles.includes(runtime.executableSha256));
    assert.ok(baseline.profiles.includes(runtime.generatedProtocol.schemaBundleSha256));
    assert.equal(runtime.missingThreadRead.rpcCode, -32600);
    assert.equal(runtime.requestBoundary.existingThreadIDsRead, 0);
    assert.equal(runtime.requestBoundary.lifecycleMutationRequests, 0);
  }
  assert.equal(evidence.sourceLayout.desktopSchemaProfile, "desktop-v34-realtime");
  assert.equal(evidence.safetyContract.sourceDatabaseWrites, 0);
  assert.equal(evidence.safetyContract.networkAllowed, false);
  assert.equal(evidence.safetyContract.credentialsAvailable, false);
});
test("production evidence binds the exact release catalog, optional summaries and original runtime observations", () => {
  const bytes = readFileSync(new URL("../fixtures/current-v166-production-read-only-evidence.json", import.meta.url));
  const data = JSON.parse(bytes);
  const digest = value => createHash("sha256").update(value).digest("hex");
  assert.ok(baseline.profiles.includes(digest(bytes)));
  assert.equal(data.runtimeEvidenceSHA256, digest(readFileSync(new URL("../fixtures/" + data.runtimeEvidenceFile, import.meta.url))));
  const members = data.sourceLayout.members.map(({ fileName, logicalRoot, requiredDatabase }) => ({ fileName, logicalRoot, requiredDatabase }));
  assert.equal(data.sourceLayout.layoutDigest, digest(JSON.stringify(members)));
  assert.equal(members.length, 20);
  assert.deepEqual(members.filter(member => member.requiredDatabase).map(member => member.fileName), ["codex.db", "state_5.sqlite", "thread_history_1.sqlite"]);
  assert.ok(members.every(member => !member.fileName.includes("-dev.db")));
});
const checks = { analyzeAbsenceProfiles, analyzeSnapshotProfiles, analyzeRequestProfileSelection, analyzeSourceAdmission };
for (const [name, analyze] of Object.entries(checks)) {
  test(name + " validates current sources without historical source rewrites", () => {
    assert.deepEqual(Object.entries(analyze(baseline)).filter(([, value]) => value !== true), []);
  });
}

// Change actual source copies, not fabricated "next milestone" booleans.
const cases = [
  ["absence needs a matching present control", analyzeAbsenceProfiles, "coordinator", "returnedThreadID == presentControlID", "true", "freshPresentControlRequired"],
  ["absence requires the exact RPC code", analyzeAbsenceProfiles, "profiles", "observation.rpcCode == -32600", "true", "exactResponseContract"],
  ["older admitted profiles remain independently covered", analyzeAbsenceProfiles, "profiles", 'runtimeVersion: "0.149.0"', 'runtimeVersion: "0.151.0"', "v149RegressionRetained"],
  ["runtime and source must be paired", analyzeAbsenceProfiles, "inventory", "CodexGhostRepairPackagedReadOnlyProfileCatalog.supportsPair(", "uncheckedPair(", "runtimeSourceSchemaPairing"],
  ["inventory regression cannot shrink the mixed batch", analyzeAbsenceProfiles, "inventoryTests", "(1...148).map(canonicalID)", "(1...2).map(canonicalID)", "deterministicAcceptance"],
  ["profiles cannot be caller constructed", analyzeSnapshotProfiles, "canonicalSource", "private init(", "public init(", "exactTypedProfiles"],
  ["source fingerprints bind the exact profile", analyzeSnapshotProfiles, "canonicalSource", "profile.validates(files: files)", "true", "fingerprintAdmitsExactProfile"],
  ["publisher must compare before and after source", analyzeSnapshotProfiles, "publisher", "sourceAfter == sourceBefore", "true", "publisherPreservesBoundProfile"],
  ["analysis keeps the manifest profile", analyzeSnapshotProfiles, "analysisReader", "before.manifest.sourceLayoutIdentifier", '"unbound"', "analysisPreservesManifestProfile"],
  ["snapshot regression cannot shrink 148 targets", analyzeSnapshotProfiles, "analysisTests", "evidence.readback.targets.count, 148", "evidence.readback.targets.count, 147", "exactV151Acceptance"],
  ["snapshot acquisition may not retry", analyzeSnapshotProfiles, "publisher", "let retriesAcquisition = false", "let retriesAcquisition = true", "noLiveOrMutationAuthority"],
  ["selection remains internal", analyzeRequestProfileSelection, "selection", "struct CodexGhostRepairSnapshotRequestBoundProfileSelection", "public struct CodexGhostRepairSnapshotRequestBoundProfileSelection", "requestBoundSelectionRemainsInternal"],
  ["selection binds the whole request", analyzeRequestProfileSelection, "selection", "guard request == selection.request", "guard true", "frozenRequestAndTypedProfile"],
  ["profile mismatch stops before acquisition", analyzeRequestProfileSelection, "publisher", "source.profile == selection.sourceProfile", "true", "profileMismatchStopsBeforeAcquisition"],
  ["schema check must exist before publication", analyzeRequestProfileSelection, "publisher", "try prepublicationSchemaVerification?(", "try uncheckedSchema?(", "schemaVerificationPrecedesPublication"],
  ["schema verification uses an owned workspace", analyzeRequestProfileSelection, "analysisReader", "workspaceFactory.create()", "unownedWorkspace()", "schemaVerificationUsesOwnedQueryOnlyCopy"],
  ["schema failure cannot lose no-replay coverage", analyzeRequestProfileSelection, "analysisTests", ".claimAlreadyExists", ".otherError", "failureAndNoReplayAcceptance"],
  ["runtime alone cannot admit a schema", analyzeRequestProfileSelection, "selection", "var runtimeAloneAdmitsSchema: Bool { false }", "var runtimeAloneAdmitsSchema: Bool { true }", "noNewAuthority"],
  ["exact runtime mapping cannot drift to a neighbor", analyzeSourceAdmission, "selection", 'case "0.153.4", "codex-cli 0.153.4":', 'case "0.153.3":', "exactTypedRuntimeMappings"],
  ["unknown runtime remains rejected", analyzeSourceAdmission, "selection", "default:\n            nil", "default:\n            .v1534DesktopV34", "exactTypedRuntimeMappings"],
  ["profile identifiers cannot become arbitrary strings", analyzeSourceAdmission, "canonicalSource", "struct CodexGhostRepairSnapshotSourceProfile", "struct CodexGhostRepairSnapshotSourceProfile /* profileIdentifier: String */", "productionConstructionUsesTypedProfileOnly"],
  ["shipping App cannot enable research code", analyzeSourceAdmission, "xcodeProject", "archiveVersion", "AGENT_SESSION_MANAGER_RESEARCH archiveVersion", "publicAppBoundaryUnchanged"],
];
for (const [name, analyze, key, before, after, reason] of cases) {
  test(name, () => {
    assert.ok(baseline[key].includes(before), "mutation must match a current source fragment");
    const source = { ...baseline, [key]: baseline[key].replaceAll(before, after) };
    assert.equal(analyze(source)[reason], false, reason);
  });
}

test("moving schema verification after the publication marker is rejected", () => {
  const publisher = baseline.publisher.replaceAll("try prepublicationSchemaVerification?(", "try uncheckedSchema?(")
    + "\ntry prepublicationSchemaVerification?(";
  assert.equal(analyzeRequestProfileSelection({ ...baseline, publisher }).schemaVerificationPrecedesPublication, false);
});
