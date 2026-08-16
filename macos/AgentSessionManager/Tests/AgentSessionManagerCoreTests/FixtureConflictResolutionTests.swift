@testable import AgentSessionManagerCore
import AgentSessionManagerFixtures
import Foundation
import XCTest

final class FixtureConflictResolutionTests: XCTestCase {
    func testFixtureIncludesClearlyLabeledActiveTrashConflict() async throws {
        let service = FixtureData.service(
            referenceDate: Date(timeIntervalSince1970: 1_000)
        )

        let sessions = try await service.sessions()
        let conflict = try XCTUnwrap(sessions.first {
            $0.nativeID == "00000000-0000-0000-0000-00000000c0de"
        })

        XCTAssertTrue(conflict.title.hasPrefix("[Demo Conflict]"))
        XCTAssertEqual(conflict.nativeState, .active)
        XCTAssertTrue(conflict.isTrashMember)
    }

    func testFixtureAcceptNativeRestoreUsesTokenAndChangesOnlyMemory() async throws {
        let referenceDate = Date(timeIntervalSince1970: 1_000)
        let provider = FixtureSessionProvider(
            system: .codex,
            capabilities: .codexFixture,
            sessions: [
                AgentSession(
                    system: .codex,
                    nativeID: "00000000-0000-0000-0000-00000000c0de",
                    title: "[Demo Conflict] Restored outside Session Manager",
                    workingDirectory: "/tmp/agent-session-manager-fixture",
                    updatedAt: referenceDate,
                    sizeBytes: 64_000,
                    nativeState: .active,
                    isTrashMember: true
                )
            ],
            now: { referenceDate }
        )
        let managerKey = "codex:00000000-0000-0000-0000-00000000c0de"
        let preview = try await provider.previewAcceptNativeRestore(
            managerKey: managerKey
        )

        do {
            _ = try await provider.executeAcceptNativeRestore(
                preview: preview,
                confirmationToken: "wrong-token"
            )
            XCTFail("Expected the wrong token to fail.")
        } catch {
            XCTAssertEqual(error as? SessionManagerError, .confirmationMismatch)
        }
        let afterWrongToken = await provider.sessions()
        XCTAssertTrue(
            afterWrongToken.first { $0.id == managerKey }?.isTrashMember == true
        )

        let report = try await provider.executeAcceptNativeRestore(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )
        let afterExecution = await provider.sessions()
        let resolved = try XCTUnwrap(afterExecution.first { $0.id == managerKey })

        XCTAssertFalse(resolved.isTrashMember)
        XCTAssertEqual(resolved.nativeState, .active)
        XCTAssertEqual(report.operation, .restore)
        XCTAssertEqual(report.items.first?.beforeCollection, .trash)
        XCTAssertEqual(report.items.first?.observedFinalCollection, .active)
        XCTAssertTrue(report.items.first?.note.contains("process-local memory") == true)
    }
}
