// Read-only source-boundary checks against the current Swift implementation.
// These supplement executable Swift tests; they neither grant authority nor prove live acceptance.
// Historical milestone evaluators and operator authorization are deliberately not retained.

export function analyzeAbsenceProfiles(sources) {
  return Object.freeze({
    exactV151RuntimeProfiles:
      sources.profiles.includes('runtimeVersion: "0.151.0-alpha.7.2"')
      && sources.profiles.includes('runtimeVersion: "0.151.0"')
      && sources.profiles.includes(
        'identifier: "desktop-bundled-0.151.0-alpha.7.2"',
      )
      && sources.profiles.includes('identifier: "provider-0.151.0"'),
    exactV151SourceProfile:
      sources.profiles.includes(
        'codex-cli-0.151.0-alpha.7.2-desktop-v33-20-member-v1',
      )
      && sources.profiles.includes('databaseSchemaProfileIdentifier: "desktop-v33"')
      && sources.profiles.includes('static let v151Members')
      && sources.profiles.includes('75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85'),
    reviewedProvenanceFrozen:
      sources.profiles.includes('a6042937174f72112dbd2d554a4af36936422e0c5ac69e353dc68994458996e9')
      && sources.profiles.includes('98491713ffb196061003ee148636e743997cc31d76144ba7c53462269896891d')
      && sources.profiles.includes('c4080cf0cbf540e6e52ca717185a45406ab70252862de70b60985fc0adbfd9f7')
      && sources.profiles.includes('59b4669567f8c52a4dc5751a5e976cd2f28024662a950bf1964f6fc90917e2e3'),
    v149RegressionRetained:
      sources.profiles.includes('static func packagedReviewedV1()')
      && sources.profiles.includes('runtimeVersion: "0.149.0"')
      && sources.sourceLayout.includes(
        'static let identifier = "codex-cli-0.149.0-paginated-v1"',
      ),
    runtimeSourceSchemaPairing:
      sources.inventory.includes(
        'CodexGhostRepairPackagedReadOnlyProfileCatalog.supportsPair(',
      )
      && sources.inventory.includes(
        'CodexGhostRepairPackagedReadOnlyProfileCatalog.supportsSource(',
      )
      && sources.profiles.includes('schema.identifier == "desktop-v32"')
      && sources.profiles.includes('schema.identifier == "desktop-v33"'),
    freshPresentControlRequired:
      sources.profiles.includes('freshPresentControlVerified: Bool')
      && sources.profiles.includes('guard freshPresentControlVerified')
      && sources.coordinator.includes('guard let presentControlID')
      && sources.coordinator.includes('returnedThreadID == presentControlID')
      && sources.coordinator.includes('freshPresentControlVerified: true'),
    exactResponseContract:
      sources.profiles.includes('observation.rpcCode == -32600')
      && sources.profiles.includes('"rpc-error-code-message-v1"')
      && sources.profiles.includes(
        '"thread not loaded: \\(observation.requestedThreadID)"',
      ),
    deterministicAcceptance:
      sources.profileTests.includes(
        'testPackagedV151RegistryAdmitsBothExactRuntimeSourcePairs',
      )
      && sources.profileTests.includes(
        'testV151SourceProfileRejectsMemberOrDigestDrift',
      )
      && sources.inventoryTests.includes(
        'testV151RuntimePairsClassifyExact148ItemsWithoutSilentShrink',
      )
      && sources.inventoryTests.includes('(1...148).map(canonicalID)')
      && sources.inventoryTests.includes(
        'testRuntimeSourceAndSchemaCrossPairDriftFailClosed',
      )
      && sources.inventoryTests.includes(
        'testOfficialInventoryAboveBoundReturnsNoReducedInventory',
      )
      && sources.coordinatorTests.includes(
        'testV151ExactProfilesRequireAndUseFreshPresentControl',
      ),
  });
}

function swiftTestBody(source, functionName) {
  const start = source.indexOf(`func ${functionName}()`);
  if (start < 0) return "";
  const next = source.indexOf("\n    func ", start + functionName.length);
  return source.slice(start, next < 0 ? source.length : next);
}

export function analyzeSnapshotProfiles(sources) {
  const exactV151Body = swiftTestBody(
    sources.analysisTests,
    "testV151PublishedSnapshotBulkReadEnumeratesExactMixed148Catalog",
  );
  return Object.freeze({
    exactTypedProfiles:
      sources.canonicalSource.includes(
        "struct CodexGhostRepairSnapshotSourceProfile",
      )
      && sources.canonicalSource.includes("private init(")
      && sources.canonicalSource.includes("static let v149DesktopV32")
      && sources.canonicalSource.includes("static let v151DesktopV33")
      && sources.canonicalSource.includes(
        'databaseSchemaProfileIdentifier: "desktop-v32"',
      )
      && sources.canonicalSource.includes(
        'databaseSchemaProfileIdentifier: "desktop-v33"',
      ),
    fingerprintAdmitsExactProfile:
      sources.canonicalSource.includes(
        "profile: CodexGhostRepairSnapshotSourceProfile",
      )
      && sources.canonicalSource.includes(
        "sourceLayoutIdentifier: profile.identifier",
      )
      && sources.canonicalSource.includes(
        "CodexGhostRepairSnapshotSourceProfile.admitted(",
      )
      && sources.canonicalSource.includes("profile.validates(files: files)"),
    fixedTwentyMembersPreserved:
      sources.canonicalSource.match(
        /^    case \w+ = /gm,
      )?.length === 20
      && sources.canonicalSource.includes(
        "files = CodexGhostRepairSnapshotCanonicalFile.allCases",
      ),
    publisherPreservesBoundProfile:
      sources.publisher.includes("source.profile.files")
      && sources.publisher.includes("sourceBefore == sourceAfter") === false
      && sources.publisher.includes("sourceAfter == sourceBefore")
      && sources.publisher.includes("journal.prepare(")
      && sources.publisher.includes("createExclusivePrivateDirectory")
      && sources.publisher.includes("atomicPublish("),
    manifestAdmitsExactProfile:
      sources.publishedInventory.includes(
        "CodexGhostRepairSnapshotSourceProfile.admitted(",
      )
      && sources.publishedInventory.includes("profile.files")
      && !sources.publishedInventory.includes(
        "sourceLayoutIdentifier\n                == CodexGhostRepairSnapshotSourceLayout.identifier",
      ),
    analysisPreservesManifestProfile:
      sources.analysisReader.includes(
        "before.manifest.sourceLayoutIdentifier",
      )
      && sources.analysisReader.includes(
        "sourceLayoutIdentifier: profile.identifier",
      )
      && sources.analysisReader.includes(
        "profile.admits(databases: result.databases)",
      ),
    exactV151Acceptance:
      exactV151Body.includes("evidence.readback.targets.count, 148")
      && exactV151Body.includes("$0.rowContract == .categoryAEligible")
      && exactV151Body.includes("$0.rowContract == .categoryBEligible"),
    driftAcceptance:
      sources.analysisTests.includes(
        "testSourceAndDatabaseSchemaCrossPairFailsClosed",
      )
      && sources.canonicalTests.includes(
        "testV151ProfileUsesSameFixedMembersButDistinctFrozenIdentity",
      )
      && sources.publisherTests.includes(
        "testV151ProfilePublishesAndColdReadbackPreservesExactIdentity",
      ),
    noLiveOrMutationAuthority:
      sources.canonicalSource.includes("let writesCodexDatabaseFiles = false")
      && sources.canonicalSource.includes("let repairMutationAuthority = false")
      && sources.publisher.includes("let retriesAcquisition = false")
      && sources.publisher.includes("let repairMutationAuthority = false"),
  });
}

export const EXACT_RUNTIME_PROFILE_SELECTIONS = Object.freeze([
  Object.freeze({ runtime: "0.149.0", profile: "v149-desktop-v32" }),
  Object.freeze({ runtime: "codex-cli 0.149.0", profile: "v149-desktop-v32" }),
  Object.freeze({ runtime: "0.151.0-alpha.7.2", profile: "v151-desktop-v33" }),
  Object.freeze({ runtime: "0.151.0", profile: "v151-desktop-v33" }),
  Object.freeze({ runtime: "0.152.1", profile: "v152-desktop-v34" }),
  Object.freeze({ runtime: "codex-cli 0.152.1", profile: "v152-desktop-v34" }),
  Object.freeze({ runtime: "0.153.1", profile: "v153-desktop-v34" }),
  Object.freeze({ runtime: "codex-cli 0.153.1", profile: "v153-desktop-v34" }),
  Object.freeze({ runtime: "0.153.2", profile: "v153-desktop-v34" }),
  Object.freeze({ runtime: "codex-cli 0.153.2", profile: "v153-desktop-v34" }),
  Object.freeze({ runtime: "0.153.4", profile: "v1534-desktop-v34" }),
  Object.freeze({ runtime: "codex-cli 0.153.4", profile: "v1534-desktop-v34" }),
]);

export function analyzeRequestProfileSelection(sources) {
  const profileCheck = sources.publisher.indexOf(
    "source.profile == selection.sourceProfile",
  );
  const acquireCall = sources.publisher.indexOf(
    "return try await acquire(\n            snapshotID:",
  );
  const schemaCheck = sources.publisher.indexOf(
    "try prepublicationSchemaVerification?(",
  );
  const manifest = sources.publisher.indexOf(
    "let manifest = try CodexGhostRepairSnapshotPublishedManifest(",
  );
  const publish = sources.publisher.indexOf("try Self.atomicPublish(");
  const marker = sources.publisher.indexOf(
    "CodexGhostRepairSnapshotPublishedFormat.markerContents.utf8",
  );

  return Object.freeze({
    requestBoundSelectionRemainsInternal:
      sources.selection.includes(
        "struct CodexGhostRepairSnapshotRequestBoundProfileSelection",
      )
      && !sources.selection.includes(
        "public struct CodexGhostRepairSnapshotRequestBoundProfileSelection",
      ),
    exactRuntimeMappings:
      EXACT_RUNTIME_PROFILE_SELECTIONS.every(({ runtime }) =>
        sources.selection.includes(`\"${runtime}\"`)
      )
      && sources.selection.includes(".v149DesktopV32")
      && sources.selection.includes(".v151DesktopV33")
      && sources.selection.includes(".v152DesktopV34")
      && sources.selection.includes(".v153DesktopV34")
      && sources.selection.includes(".v1534DesktopV34")
      && sources.selection.includes("default:\n            nil"),
    frozenRequestAndTypedProfile:
      sources.selection.includes(
        "let request: CodexGhostRepairSnapshotActionRequest",
      )
      && sources.selection.includes(
        "let sourceProfile: CodexGhostRepairSnapshotSourceProfile",
      )
      && sources.selection.includes("guard request == selection.request")
      && !sources.selection.includes("sourcePath:"),
    profileMismatchStopsBeforeAcquisition:
      profileCheck >= 0
      && acquireCall >= 0
      && profileCheck < acquireCall,
    schemaVerificationPrecedesPublication:
      schemaCheck >= 0
      && manifest >= 0
      && publish >= 0
      && marker >= 0
      && schemaCheck < manifest
      && schemaCheck < publish
      && schemaCheck < marker,
    schemaVerificationUsesOwnedQueryOnlyCopy:
      sources.analysisReader.includes(
        "enum CodexGhostRepairSnapshotPrepublicationSchemaVerifier",
      )
      && sources.analysisReader.includes("verifyPrepublicationCopy(")
      && sources.analysisReader.includes("workspaceFactory.create()")
      && sources.analysisReader.includes(
        "profile.admits(databases: result.databases)",
      )
      && sources.analysisReader.includes("workspace.remove()"),
    exact148MixedAcceptance:
      sources.analysisTests.includes(
        "testM4f28V151RequestBoundPublisherVerifiesBeforeExact148Publication",
      )
      && sources.analysisTests.includes(
        "testCurrentV152RequestBoundPublisherVerifiesV34Exact148Publication",
      )
      && sources.analysisTests.includes(
        "testCurrentV153RequestBoundPublisherVerifiesV34Exact148Publication",
      )
      && sources.analysisTests.includes("XCTAssertEqual(evidence.readback.targets.count, 148)")
      && sources.analysisTests.match(/XCTAssertEqual\([\s\S]*?74[\s\S]*?\)/g)?.length >= 2,
    failureAndNoReplayAcceptance:
      sources.analysisTests.includes(
        "testM4f28SchemaCrossPairStopsBeforeManifestMarkerAndCannotRetry",
      )
      && sources.analysisTests.includes(".claimAlreadyExists")
      && sources.analysisTests.includes(
        "testM4f28PublisherProfileMismatchStopsBeforeSourceOpenOrJournal",
      )
      && sources.analysisTests.includes(
        "testM4f28FrozenRequestDriftAndUnknownRuntimeFailBeforeEffects",
      ),
    noNewAuthority:
      sources.selection.includes("var runtimeAloneAdmitsSchema: Bool { false }")
      && sources.selection.includes("var liveSourceReadAuthority: Bool { false }")
      && sources.selection.includes("var snapshotAuthority: Bool { false }")
      && sources.selection.includes("var repairMutationAuthority: Bool { false }")
      && sources.selection.includes("var retriesAcquisition: Bool { false }"),
  });
}

export function analyzeSourceAdmission(sources) {
  const verifierStart = sources.analysisReader.indexOf(
    "enum CodexGhostRepairSnapshotPrepublicationSchemaVerifier",
  );
  const verifierGuard = sources.analysisReader.lastIndexOf(
    "#if AGENT_SESSION_MANAGER_RESEARCH",
    verifierStart,
  );
  const verifierGuardEnd = sources.analysisReader.indexOf(
    "#endif",
    verifierGuard,
  );

  return Object.freeze({
    requestBoundSelectionIsShippingInternal:
      sources.selection.includes(
        "struct CodexGhostRepairSnapshotRequestBoundProfileSelection",
      )
      && !sources.selection.includes(
        "public struct CodexGhostRepairSnapshotRequestBoundProfileSelection",
      )
      && !sources.selection.startsWith("#if AGENT_SESSION_MANAGER_RESEARCH"),
    exactTypedRuntimeMappings:
      [
        "0.149.0",
        "codex-cli 0.149.0",
        "0.151.0-alpha.7.2",
        "0.151.0",
        "0.152.1",
        "codex-cli 0.152.1",
        "0.153.1",
        "codex-cli 0.153.1",
        "0.153.2",
        "codex-cli 0.153.2",
        "0.153.4",
        "codex-cli 0.153.4",
      ].every((runtime) => sources.selection.includes(`\"${runtime}\"`))
      && sources.selection.includes(".v149DesktopV32")
      && sources.selection.includes(".v151DesktopV33")
      && sources.selection.includes(".v152DesktopV34")
      && sources.selection.includes(".v153DesktopV34")
      && sources.selection.includes(".v1534DesktopV34")
      && sources.selection.includes("default:\n            nil"),
    internalPublisherPreservesWholeSelection:
      sources.actionCoordinator.includes(
        "selection: CodexGhostRepairSnapshotRequestBoundProfileSelection",
      )
      && sources.actionCoordinator.includes(
        "selection: selection",
      )
      && !sources.actionCoordinator.includes(
        "func publish(\n        snapshotID: UUID,\n        targetThreadIDs: [String]",
      ),
    productionConstructionUsesTypedProfileOnly:
      sources.canonicalSource.includes(
        "profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32",
      )
      && sources.publisher.includes(
        "productionOperationalGateCandidate(\n        profile: CodexGhostRepairSnapshotSourceProfile",
      )
      && sources.publisher.includes("source: .production(profile: profile)")
      && !sources.canonicalSource.includes("profileIdentifier: String"),
    profileMismatchStopsBeforeAdmissionOrAcquisition:
      sources.publisher.includes(
        "source.profile == selection.sourceProfile",
      )
      && sources.publisher.includes("inspectAdmissionProfileBound(")
      && sources.publisher.includes("func acquireProfileBound("),
    prepublicationVerifierIsShippingInternal:
      verifierStart >= 0
      && !(verifierGuard >= 0 && verifierGuardEnd > verifierStart)
      && !sources.analysisReader.includes(
        "public enum CodexGhostRepairSnapshotPrepublicationSchemaVerifier",
      ),
    verifierRunsBeforeManifestMoveAndMarker:
      sources.publisher.indexOf("try prepublicationSchemaVerification?(")
        < sources.publisher.indexOf(
          "let manifest = try CodexGhostRepairSnapshotPublishedManifest(",
        )
      && sources.publisher.indexOf("try prepublicationSchemaVerification?(")
        < sources.publisher.indexOf("try Self.atomicPublish("),
    noResearchExact148CurrentAcceptance:
      sources.analysisTests.includes(
        "testM4f28V151RequestBoundPublisherVerifiesBeforeExact148Publication",
      )
      && sources.analysisTests.includes(
        "testCurrentV152RequestBoundPublisherVerifiesV34Exact148Publication",
      )
      && sources.analysisTests.includes(
        "testCurrentV153RequestBoundPublisherVerifiesV34Exact148Publication",
      )
      && sources.analysisTests.includes(
        "XCTAssertEqual(evidence.readback.targets.count, 148)",
      )
      && sources.analysisTests.includes("74")
      && !sources.analysisTests.includes("#if AGENT_SESSION_MANAGER_RESEARCH"),
    coordinatorAcceptsCurrentProfilesAndUnknownFailsPrePublisher:
      sources.actionTests.includes(
        "testV151RequestSelectsExactTypedProfileAndPreservesWholeRequest",
      )
      && sources.actionTests.includes(
        "testV152RequestSelectsExactTypedV34ProfileAndPreservesWholeRequest",
      )
      && sources.actionTests.includes(
        "testV153ProviderRequestSelectsDesktopOwnedV34Profile",
      )
      && sources.actionTests.includes(
        "testUnsupportedRuntimeStopsBeforeGeneratingOrPublishing",
      )
      && sources.actionTests.includes("XCTAssertEqual(requests, [])"),
    publicAppBoundaryUnchanged:
      sources.appModel.match(
        /CodexGhostRepairSnapshotActionCoordinatorFactory/g,
      )?.length === 1
      && !sources.appModel.includes(
        "CodexGhostRepairSnapshotRequestBoundProfileSelection",
      )
      && !sources.xcodeProject.includes("AGENT_SESSION_MANAGER_RESEARCH"),
    noNewRepairAuthority:
      sources.selection.includes("var runtimeAloneAdmitsSchema: Bool { false }")
      && sources.selection.includes("var repairMutationAuthority: Bool { false }")
      && sources.publisher.includes("let repairMutationAuthority = false")
      && sources.actionCoordinator.includes("accepts no path"),
  });
}
