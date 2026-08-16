@testable import AgentSessionManagerCore
import XCTest

final class ProtectionAuthorityTests: XCTestCase {
    func testProcessLocalRunningObservationProtectsButCannotClear() throws {
        let protected = try ProtectionAuthorityPolicy.resolve(
            system: .codex,
            observations: [running(true, scope: .managerProcess)]
        )
        XCTAssertTrue(protected.isRunning)
        XCTAssertTrue(protected.isRunningKnown)

        let idle = try ProtectionAuthorityPolicy.resolve(
            system: .codex,
            observations: [running(false, scope: .managerProcess)]
        )
        XCTAssertFalse(idle.isRunning)
        XCTAssertFalse(idle.isRunningKnown)
        XCTAssertTrue(idle.blocksLifecycleMutation)
    }

    func testCrossHostAuthorityCanClearRunningAndCurrent() throws {
        let protection = try ProtectionAuthorityPolicy.resolve(
            system: .codex,
            observations: [
                running(false, scope: .allRelevantHosts),
                ProtectionAuthorityObservation(
                    kind: .current,
                    isProtected: false,
                    source: .explicitCrossHostAuthority,
                    scope: .allRelevantHosts
                ),
            ]
        )

        XCTAssertTrue(protection.isRunningKnown)
        XCTAssertTrue(protection.isCurrentKnown)
        XCTAssertFalse(protection.isRunning)
        XCTAssertFalse(protection.isCurrent)
    }

    func testProviderPinAndCompleteGraphCanAuthoritativelyClearTheirFields() throws {
        let protection = try ProtectionAuthorityPolicy.resolve(
            system: .codex,
            observations: [
                ProtectionAuthorityObservation(
                    kind: .pinned,
                    isProtected: false,
                    source: .codexThreadListPin,
                    scope: .providerPersistentState
                ),
                ProtectionAuthorityObservation(
                    kind: .pinnedDescendant,
                    isProtected: false,
                    source: .codexCompleteDescendantGraph,
                    scope: .completeProviderGraph
                ),
            ]
        )

        XCTAssertTrue(protection.isPinnedKnown)
        XCTAssertTrue(protection.hasPinnedDescendantKnown)
    }

    func testDesktopPinSnapshotCanAuthoritativelyClearPin() throws {
        let protection = try ProtectionAuthorityPolicy.resolve(
            system: .codex,
            observations: [
                ProtectionAuthorityObservation(
                    kind: .pinned,
                    isProtected: false,
                    source: .codexDesktopPinnedThreadIDs,
                    scope: .providerPersistentState
                ),
            ]
        )

        XCTAssertTrue(protection.isPinnedKnown)
        XCTAssertFalse(protection.isPinned)
    }

    func testSourceScopeMismatchAndDuplicateFactsFailClosed() throws {
        XCTAssertThrowsError(try ProtectionAuthorityPolicy.resolve(
            system: .codex,
            observations: [running(false, scope: .providerPersistentState)]
        ))

        XCTAssertThrowsError(try ProtectionAuthorityPolicy.resolve(
            system: .codex,
            observations: [
                running(true, scope: .managerProcess),
                running(false, scope: .managerProcess),
            ]
        )) { error in
            XCTAssertEqual(
                error as? ProtectionAuthorityError,
                .duplicateObservation(.running)
            )
        }
    }

    private func running(
        _ value: Bool,
        scope: ProtectionAuthorityScope
    ) -> ProtectionAuthorityObservation {
        ProtectionAuthorityObservation(
            kind: .running,
            isProtected: value,
            source: scope == .allRelevantHosts
                ? .explicitCrossHostAuthority
                : .codexThreadListStatus,
            scope: scope
        )
    }
}
