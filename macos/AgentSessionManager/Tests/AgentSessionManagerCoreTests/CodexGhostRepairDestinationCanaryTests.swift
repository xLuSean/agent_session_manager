import XCTest
@testable import AgentSessionManagerCore

final class CodexGhostRepairDestinationCanaryTests: XCTestCase {
    func testCapabilitiesAreOperationSpecificAndNeverGrantAuthority() {
        XCTAssertEqual(
            CodexGhostRepairDestinationCanaryCapabilities.unavailable,
            .unavailable
        )
        XCTAssertFalse(
            CodexGhostRepairDestinationCanaryCapabilities.unavailable
                .inspectionAvailable
        )
        XCTAssertFalse(
            CodexGhostRepairDestinationCanaryCapabilities.unavailable
                .preparationAvailable
        )
        XCTAssertTrue(
            CodexGhostRepairDestinationCanaryCapabilities.inspectOnly
                .inspectionAvailable
        )
        XCTAssertFalse(
            CodexGhostRepairDestinationCanaryCapabilities.inspectOnly
                .preparationAvailable
        )
        XCTAssertTrue(
            CodexGhostRepairDestinationCanaryCapabilities.inspectAndPrepare
                .inspectionAvailable
        )
        XCTAssertTrue(
            CodexGhostRepairDestinationCanaryCapabilities.inspectAndPrepare
                .preparationAvailable
        )
        XCTAssertEqual(
            CodexGhostRepairDestinationCanaryCapabilities.unavailable
                .preparationEffect,
            .unavailable
        )
        XCTAssertEqual(
            CodexGhostRepairDestinationCanaryCapabilities.inspectAndPrepare
                .preparationEffect,
            .testOwnedPrototype
        )
        XCTAssertEqual(
            CodexGhostRepairDestinationCanaryCapabilities
                .fixedManagerPrivateDirectoryPrepare.preparationEffect,
            .fixedManagerPrivateDirectories
        )
        XCTAssertTrue(
            CodexGhostRepairDestinationCanaryCapabilities
                .fixedManagerPrivateDirectoryPrepare.preparationEffect
                .writesFilesystem
        )
        for capabilities in [
            CodexGhostRepairDestinationCanaryCapabilities.unavailable,
            .inspectOnly,
            .inspectAndPrepare,
            .fixedManagerPrivateDirectoryPrepare,
        ] {
            XCTAssertFalse(capabilities.filesystemAuthority)
            XCTAssertFalse(capabilities.snapshotAuthority)
            XCTAssertFalse(capabilities.officialAbsenceAuthority)
            XCTAssertFalse(capabilities.repairMutationAuthority)
        }
    }

    func testPackagedInspectOnlyFactoryConstructsWithoutInspecting() {
        let coordinator = CodexGhostRepairDestinationCanaryCoordinatorFactory
            .packagedInspectOnly()

        XCTAssertEqual(coordinator.capabilities, .inspectOnly)
    }

    func testPackagedFixedDirectoryPrepareFactoryConstructsWithoutEffect() {
        let coordinator = CodexGhostRepairDestinationCanaryCoordinatorFactory
            .packagedFixedDirectoryPrepare()

        XCTAssertEqual(
            coordinator.capabilities,
            .fixedManagerPrivateDirectoryPrepare
        )
        XCTAssertEqual(
            coordinator.capabilities.preparationEffect,
            .fixedManagerPrivateDirectories
        )
        XCTAssertFalse(coordinator.capabilities.filesystemAuthority)
        XCTAssertFalse(coordinator.capabilities.snapshotAuthority)
        XCTAssertFalse(coordinator.capabilities.repairMutationAuthority)
    }

    func testEvidenceIsPathRedactedCompleteAndCarriesNoAuthority() throws {
        let evidence = try makeEvidence(missing: [.snapshots, .journal])

        XCTAssertTrue(evidence.pathRedacted)
        XCTAssertEqual(evidence.directories.count, 6)
        XCTAssertEqual(evidence.missingDirectories, [.journal, .snapshots])
        XCTAssertTrue(evidence.isPreparationEligible)
        XCTAssertFalse(evidence.isReady)
        XCTAssertFalse(evidence.filesystemAuthority)
        XCTAssertFalse(evidence.snapshotAuthority)
        XCTAssertFalse(evidence.officialAbsenceAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)
    }

    func testPreparationRequestFreezesExactEvidenceTokenPolicyAndMissingSet() throws {
        let evidence = try makeEvidence(missing: [.trash, .quarantine])
        let requestID = UUID(uuidString: "B11595ED-6E4B-4E46-A120-E7FC7E608E45")!

        let request = try CodexGhostRepairDestinationCanaryPreparationRequest(
            id: requestID,
            evidence: evidence
        )

        XCTAssertEqual(request.id, requestID)
        XCTAssertEqual(request.evidenceToken, evidence.evidenceToken)
        XCTAssertEqual(request.policy, evidence.policy)
        XCTAssertEqual(request.missingDirectories, [.quarantine, .trash])
        XCTAssertFalse(request.filesystemAuthority)
        XCTAssertFalse(request.snapshotAuthority)
        XCTAssertFalse(request.repairMutationAuthority)
    }

    func testPreparationRejectsReadyCollisionAndUnsafeEvidence() throws {
        XCTAssertThrowsError(try CodexGhostRepairDestinationCanaryPreparationRequest(
            evidence: makeEvidence(missing: [])
        ))
        XCTAssertThrowsError(try CodexGhostRepairDestinationCanaryPreparationRequest(
            evidence: makeEvidence(missing: [], overriddenStatus: [.journal: .collision])
        ))
        XCTAssertThrowsError(try CodexGhostRepairDestinationCanaryPreparationRequest(
            evidence: makeEvidence(missing: [], overriddenStatus: [.trash: .unsafe])
        ))
    }

    func testEvidenceRejectsIncompleteDuplicateAndNonDigestSets() throws {
        let policy = try makePolicy()
        let complete = try makeDirectories(missing: [])

        XCTAssertThrowsError(try CodexGhostRepairDestinationCanaryEvidence(
            policy: policy,
            directories: Array(complete.dropLast()),
            evidenceToken: digest("a"),
            observedAt: Date(timeIntervalSince1970: 1_000)
        ))
        XCTAssertThrowsError(try CodexGhostRepairDestinationCanaryEvidence(
            policy: policy,
            directories: complete + [complete[0]],
            evidenceToken: digest("a"),
            observedAt: Date(timeIntervalSince1970: 1_000)
        ))
        XCTAssertThrowsError(try CodexGhostRepairDestinationCanaryEvidence(
            policy: policy,
            directories: complete,
            evidenceToken: "/Users/example/Application Support",
            observedAt: Date(timeIntervalSince1970: 1_000)
        ))
    }

    func testReadyDirectoryRequiresTypedPermissionContractAndDigest() throws {
        XCTAssertThrowsError(try CodexGhostRepairDestinationCanaryDirectoryEvidence(
            directory: .snapshots,
            status: .ready,
            permissionRequirement: .ownerPrivate0700,
            identityDigest: nil,
            observedMode: 0o700
        ))
        XCTAssertThrowsError(try CodexGhostRepairDestinationCanaryDirectoryEvidence(
            directory: .snapshots,
            status: .ready,
            permissionRequirement: .ownerPrivate0700,
            identityDigest: digest("b"),
            observedMode: 0o755
        ))
        XCTAssertThrowsError(try CodexGhostRepairDestinationCanaryDirectoryEvidence(
            directory: .applicationBundleRoot,
            status: .ready,
            permissionRequirement: .ownerPrivate0700,
            identityDigest: digest("b"),
            observedMode: 0o700
        ))

        let ownerControlled = try CodexGhostRepairDestinationCanaryDirectoryEvidence(
            directory: .applicationBundleRoot,
            status: .ready,
            permissionRequirement: .ownerControlled,
            identityDigest: digest("b"),
            observedMode: 0o755
        )
        XCTAssertEqual(ownerControlled.observedMode, 0o755)
    }

    func testShippingUnavailableCoordinatorPerformsNoSuccessOrPreparation() async throws {
        let coordinator = CodexGhostRepairDestinationCanaryUnavailableCoordinator()
        XCTAssertEqual(coordinator.capabilities, .unavailable)
        let inspect = await coordinator.inspect(requestID: UUID())
        guard case .unavailable = inspect else {
            return XCTFail("Shipping inspect must remain unavailable")
        }

        let request = try CodexGhostRepairDestinationCanaryPreparationRequest(
            evidence: makeEvidence(missing: [.snapshots])
        )
        let prepare = await coordinator.prepare(request: request)
        guard case .unavailable = prepare else {
            return XCTFail("Shipping prepare must remain unavailable")
        }
    }

    private func makeEvidence(
        missing: Set<CodexGhostRepairDestinationCanaryDirectory>,
        overriddenStatus: [
            CodexGhostRepairDestinationCanaryDirectory:
                CodexGhostRepairDestinationCanaryEntryStatus
        ] = [:]
    ) throws -> CodexGhostRepairDestinationCanaryEvidence {
        try CodexGhostRepairDestinationCanaryEvidence(
            policy: makePolicy(),
            directories: makeDirectories(
                missing: missing,
                overriddenStatus: overriddenStatus
            ),
            evidenceToken: digest("e"),
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makePolicy()
        throws -> CodexGhostRepairDestinationCanaryPolicyEvidence
    {
        try CodexGhostRepairDestinationCanaryPolicyEvidence(
            identifier: "ghost-repair-retention-v1",
            version: 1,
            maximumSnapshotCount: 3,
            maximumTotalBytes: 4_294_967_296,
            maximumAgeMilliseconds: 2_592_000_000,
            policyDigest: digest("c")
        )
    }

    private func makeDirectories(
        missing: Set<CodexGhostRepairDestinationCanaryDirectory>,
        overriddenStatus: [
            CodexGhostRepairDestinationCanaryDirectory:
                CodexGhostRepairDestinationCanaryEntryStatus
        ] = [:]
    ) throws -> [CodexGhostRepairDestinationCanaryDirectoryEvidence] {
        try CodexGhostRepairDestinationCanaryDirectory.allCases.map { directory in
            let status = overriddenStatus[directory]
                ?? (missing.contains(directory) ? .missing : .ready)
            return try CodexGhostRepairDestinationCanaryDirectoryEvidence(
                directory: directory,
                status: status,
                permissionRequirement: directory == .applicationBundleRoot
                    ? .ownerControlled
                    : .ownerPrivate0700,
                identityDigest: status == .missing ? nil : digest("d"),
                observedMode: status == .missing ? nil : 0o700
            )
        }
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }
}
