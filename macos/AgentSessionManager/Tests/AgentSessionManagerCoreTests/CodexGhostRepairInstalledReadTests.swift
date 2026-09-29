@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairInstalledReadTests: XCTestCase {
    func testInstalledExactCleanupScan() async throws {
        guard ProcessInfo.processInfo.environment["ASM_INSTALLED_CLEANUP_SCAN"] == "1",
              let target = ProcessInfo.processInfo.environment["ASM_INSTALLED_CLEANUP_THREAD_ID"] else {
            throw XCTSkip("Explicit opt-in and exact scope required for the read-only App Server scan.")
        }
        let handoff = try CodexDesktopCleanupHandoff(canonicalDeleteReportID: UUID(), items: [
            try .init(managerKey: "codex:\(target)", nativeSessionID: target, deletedAtMilliseconds: 1)
        ])
        let coordinator = CodexGhostRepairBulkInventoryCoordinatorFactory.packagedExplicitReadOnly()
        let outcome = await coordinator.observeCleanup(request: .init(
            requestID: UUID(), snapshotReference: UUID().uuidString.lowercased()), handoff: handoff)
        switch outcome {
        case let .inventory(_, inventory):
            XCTAssertEqual(inventory.items.map(\.threadID), [target])
            XCTAssertEqual(inventory.eligibleThreadIDs, [target])
            print("ASM_INSTALLED_CLEANUP_SCAN=complete:eligible=\(inventory.eligibleThreadIDs.count)")
        case let .unavailable(_, failure):
            // Opt-in diagnostics only. Keep titles, IDs, paths and RPC text out
            // of test output; this independent read cannot retry cleanup.
            do {
                let value = try await CodexAppServerClient.ghostRepairProduction().inventory()
                let active = value.active.map(\.id), archived = value.archived.map(\.id)
                let descendants = value.descendantRecords.map(\.id)
                print("ASM_OFFICIAL_DIAGNOSTIC=runtime:\(value.runtimeVersion ?? "unknown"):truncated:\(value.isTruncated):pins:\(value.desktopPinStateAvailable):graph:\(value.descendantGraphComplete):active:\(active.count):activeUnique:\(Set(active).count):archived:\(archived.count):archivedUnique:\(Set(archived).count):overlap:\(Set(active).intersection(archived).count):descendants:\(descendants.count):descendantsUnique:\(Set(descendants).count)")
            } catch {
                print("ASM_OFFICIAL_DIAGNOSTIC_ERROR_TYPE=\(type(of: error))")
                if let error = error as? CodexAppServerError {
                    let code: String = switch error {
                    case .executableNotFound: "executable-not-found"
                    case .launchFailed: "launch-failed"
                    case .processExited: "process-exited"
                    case .responseTimeout: "timeout"
                    case .exactReadUnavailable: "exact-read-unavailable"
                    case .malformedResponse: "malformed-response"
                    case .rpcError: "rpc-error"
                    }
                    print("ASM_OFFICIAL_DIAGNOSTIC_ERROR=\(code)")
                }
            }
            XCTFail("ASM_INSTALLED_CLEANUP_SCAN=\(failure.stage.rawValue):\(failure.readerReason?.rawValue ?? "not-applicable")")
        }
    }

    func testInstalledExactCleanupReader() throws {
        guard ProcessInfo.processInfo.environment["ASM_INSTALLED_CLEANUP_READ"] == "1" else {
            throw XCTSkip("Explicit opt-in required for a read-only canonical copy probe.")
        }
        let source = CodexGhostRepairSnapshotCanonicalSource.production(profile: .v156DesktopV34Extended)
        let target = ProcessInfo.processInfo.environment["ASM_INSTALLED_CLEANUP_THREAD_ID"] ?? UUID().uuidString.lowercased()
        do {
            let result = try CodexGhostRepairBulkCanonicalQueryOnlyReader.readExactCleanupScope(
                source: source,
                targetThreadIDs: [target],
                workspaceFactory: .production()
            )
            XCTAssertEqual(result.databases.count, 4)
            XCTAssertEqual(result.targets.count, 1)
            print("ASM_INSTALLED_CLEANUP_READ=passed")
            for target in result.targets {
                print("ASM_INSTALLED_CLEANUP_SCOPE=\(target.rowContract):catalog=\(target.catalogRowDigests.count):automation=\(target.automationRunRowDigests.count):references=\(target.references.total)")
            }
        } catch {
            XCTFail("ASM_INSTALLED_CLEANUP_READ=\(CodexGhostRepairBulkCanonicalQueryOnlyReader.failureReason(for: error).rawValue)")
        }
    }
}
