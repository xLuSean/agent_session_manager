#if AGENT_SESSION_MANAGER_RESEARCH
@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairProductionPolicyTests: XCTestCase {
    func testInitialPolicyHasExactVersionedAdmissionLimits() {
        let policy = CodexGhostRepairProductionPolicy.initial

        XCTAssertEqual(policy.identifier, "ghost-repair-retention-v1")
        XCTAssertEqual(policy.version, 1)
        XCTAssertEqual(policy.maximumSnapshotCount, 3)
        XCTAssertEqual(policy.maximumTotalBytes, 4_294_967_296)
        XCTAssertEqual(policy.maximumAgeMilliseconds, 2_592_000_000)
    }

    func testInitialPolicyConvertsExactlyAndDeterministicallyToE39() throws {
        let policy = CodexGhostRepairProductionPolicy.initial

        let first = try policy.publishedSnapshotRetentionPolicy()
        let second = try policy.publishedSnapshotRetentionPolicy()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.maximumSnapshotCount, 3)
        XCTAssertEqual(first.maximumTotalBytes, 4_294_967_296)
        XCTAssertEqual(first.maximumAgeMilliseconds, 2_592_000_000)
    }

    func testPolicyGrantsNoCleanupSnapshotOrRepairAuthority() {
        let policy = CodexGhostRepairProductionPolicy.initial

        XCTAssertTrue(policy.destinationCapacityGateStillRequired)
        XCTAssertTrue(policy.overQuotaBlocksNewAcquisitionOnly)
        XCTAssertFalse(policy.automaticDeletionAllowed)
        XCTAssertFalse(policy.policyChangeDeletesExistingSnapshots)
        XCTAssertFalse(policy.snapshotAcquisitionAuthority)
        XCTAssertFalse(policy.repairMutationAuthority)
    }

    func testProductionFactoryHasTypedPolicySurfaceWithoutCallingIt() {
        let factory: (CodexGhostRepairProductionPolicy) throws
            -> CodexGhostRepairProductionDestinationCapability =
            CodexGhostRepairProductionDestinationCapability.production(policy:)

        _ = factory
    }

    func testTestOwnedInspectCarriesExactProductionPolicyWithZeroEffect() throws {
        let fixture = try makeE43Fixture(label: #function)
        let capability = try makeE43Capability(fixture: fixture)

        let report = try capability.inspect()

        XCTAssertEqual(report.status, .requiresPreparation)
        XCTAssertEqual(
            report.productionPolicy,
            CodexGhostRepairProductionPolicy.initial
        )
        XCTAssertEqual(
            report.retentionPolicy,
            try CodexGhostRepairProductionPolicy.initial
                .publishedSnapshotRetentionPolicy()
        )
        XCTAssertEqual(report.createdDirectories, [])
        XCTAssertTrue(report.directories.allSatisfy { !$0.exists })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.bundleRoot.path)
        )
        XCTAssertFalse(report.snapshotAcquisitionAuthority)
        XCTAssertFalse(report.repairMutationAuthority)
    }

    func testTestOwnedPreparePreservesPolicyInExactDirectoryReadback() throws {
        let fixture = try makeE43Fixture(label: #function)
        let capability = try makeE43Capability(fixture: fixture)

        let report = try capability.prepare()

        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(
            report.productionPolicy,
            CodexGhostRepairProductionPolicy.initial
        )
        XCTAssertEqual(
            report.createdDirectories,
            CodexGhostRepairDestinationDirectory.allCases
        )
        XCTAssertTrue(report.directories.allSatisfy(\.exists))
        XCTAssertTrue(report.directories.allSatisfy(\.permissionContractSatisfied))
        XCTAssertTrue(report.directories.allSatisfy { $0.mode == 0o700 })
    }

    private func makeE43Capability(fixture: E43PolicyFixture) throws
        -> CodexGhostRepairProductionDestinationCapability
    {
        try CodexGhostRepairProductionDestinationCapability(
            testOwnedApplicationSupportDirectory: fixture.applicationSupport,
            testOwnedAllowedParentURL: fixture.allowedParent,
            productionPolicy: .initial
        )
    }

    private func makeE43Fixture(label: String) throws -> E43PolicyFixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let allowedParent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e43-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: allowedParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(allowedParent.path, 0o700), 0)
        let markerURL = allowedParent.appendingPathComponent(
            CodexGhostRepairProductionDestinationCapability.testRootMarkerFileName,
            isDirectory: false
        )
        try Data(
            CodexGhostRepairProductionDestinationCapability.testRootMarkerContents.utf8
        ).write(to: markerURL)
        XCTAssertEqual(chmod(markerURL.path, 0o600), 0)
        let applicationSupport = allowedParent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(applicationSupport.path, 0o700), 0)
        return E43PolicyFixture(
            allowedParent: allowedParent,
            applicationSupport: applicationSupport,
            bundleRoot: applicationSupport.appendingPathComponent(
                StateStoreLocation.defaultBundleIdentifier,
                isDirectory: true
            )
        )
    }
}

private struct E43PolicyFixture: Sendable {
    let allowedParent: URL
    let applicationSupport: URL
    let bundleRoot: URL
}
#endif
