import assert from "node:assert/strict";
import test from "node:test";
import {
  analyzeAbsenceProfiles,
  analyzeSnapshotProfiles,
  analyzeRequestProfileSelection,
  analyzeSourceAdmission,
} from "./support/ghost_profile_contracts.mjs";
import { repositorySources } from "./support/repository_sources.mjs";

const baseline = repositorySources();
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
