import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexCompatibilityDesktopProbeTests: XCTestCase {
    func testEveryKnownProfilePassesMixedCleanupAndRollbackScenarios() throws {
        for profile in CodexGhostRepairDatabaseSchemaProfile.admittedProfiles {
            for scenario in CodexCompatibilityDesktopProbe.Scenario.allCases {
                XCTAssertNoThrow(try CodexCompatibilityDesktopProbe.verify(profile: profile, scenario: scenario),
                                 "\(profile.identifier): \(scenario)")
            }
            XCTAssertEqual(try CodexCompatibilityDesktopProbe.run(profileIdentifier: profile.identifier).status, .passed)
        }
    }

    func testMissingOrUnknownProfileIsNotTested() throws {
        for profile in [nil, "desktop-v999", ""] as [String?] {
            let result = try CodexCompatibilityDesktopProbe.run(profileIdentifier: profile)
            XCTAssertEqual(result.feature, .desktopCleanup)
            XCTAssertEqual(result.status, .notTested)
        }
    }

    func testEveryKnownProfilePassesDiskBackupColdReadAndRollback() throws {
        for profile in CodexGhostRepairDatabaseSchemaProfile.admittedProfiles {
            for scenario in CodexCompatibilityDesktopProbe.Scenario.allCases {
                XCTAssertNoThrow(try CodexCompatibilityDesktopProbe.verify(profile: profile, scenario: scenario, onDisk: true))
            }
        }
    }

    func testCorruptedDiskBackupStopsBeforeCleanup() throws {
        for profile in CodexGhostRepairDatabaseSchemaProfile.admittedProfiles {
            XCTAssertThrowsError(try CodexCompatibilityDesktopProbe.verify(
                profile: profile, scenario: .mixedSuccess, onDisk: true, corruptBackup: true)) { error in
                guard case CodexCompatibilityDesktopProbe.Failure.backupMismatch = error else {
                    return XCTFail("Expected rejection of corrupted backup, got \(error)")
                }
            }
        }
    }

    func testSQLPassCannotBecomeDesktopAdmissionOrCLIBehaviorEvidence() throws {
        let result = try CodexCompatibilityDesktopProbe.run(profileIdentifier: "desktop-v34")
        var report = CodexCompatibilityReport(revision: CodexCompatibilityReport.policyRevision, checkedAt: Date(),
            provider: .init(path: "/synthetic/codex", version: "0.999.0", sha256: String(repeating: "a", count: 64)),
            desktop: nil, environmentFingerprint: String(repeating: "b", count: 64), desktopSchemaProfile: "desktop-v34",
            results: CodexCompatibilityEvaluator.results(version: "0.999.0", browsing: true, archive: true, restore: true,
                delete: true, desktopVersion: "0.999.0", desktopSchemaProfile: "desktop-v34", desktopMetadataAvailable: true), notes: [])
        report.behavior = .init(revision: CodexCompatibilityBehaviorReport.policyRevision, checkedAt: Date(), results: [result])
        let restored = try JSONDecoder().decode(CodexCompatibilityReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(restored, report)
        for feature in CodexCompatibilityFeature.allCases { XCTAssertFalse(restored.hasVerifiedBehavior(for: feature)) }
        XCTAssertEqual(restored.results.last?.status, .needsBehaviorVerification)
        XCTAssertTrue(result.detail.contains("does not unlock new Desktop versions"))
        XCTAssertFalse(result.detail.contains("asm-probe-"))
    }
}
