import XCTest
@testable import AgentSessionManagerCore

final class ArchiveBatchAtomicityTests: XCTestCase {
    func testPlanUsesDeterministicRootOrderAndRequiresGlobalPreflight() throws {
        let plan = try ArchiveBatchAtomicityPolicy.plan(affectedSets: [
            affectedSet(root: "z-root", descendants: ["z-child"]),
            affectedSet(root: "a-root", descendants: []),
        ])

        XCTAssertEqual(
            plan.units.map(\.selectedRootManagerKey),
            ["codex:a-root", "codex:z-root"]
        )
        XCTAssertEqual(plan.affectedItemCount, 3)
        XCTAssertEqual(plan.providerAtomicity, .perRootSequential)
        XCTAssertTrue(plan.requiresAllUnitsPreflightBeforeFirstRequest)
        XCTAssertTrue(plan.stopsAfterFirstNonSuccess)
    }

    func testPlanRejectsOverlappingAffectedSets() throws {
        let root = affectedSet(root: "root", descendants: ["child"])
        let child = affectedSet(root: "child", descendants: [])

        XCTAssertThrowsError(try ArchiveBatchAtomicityPolicy.plan(
            affectedSets: [root, child]
        )) { error in
            XCTAssertEqual(
                error as? ArchiveBatchAtomicityError,
                .overlappingAffectedItem("codex:child")
            )
        }
    }

    func testAllSuccessFinalizesSuccessWithNoOmittedUnits() throws {
        let plan = try threeUnitPlan()
        let result = try ArchiveBatchAtomicityPolicy.finalize(
            plan: plan,
            attempts: plan.units.map { attempt(for: $0, outcome: .success) }
        )

        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(result.attemptedUnitCount, 3)
        XCTAssertEqual(result.notAttemptedUnitCount, 0)
        XCTAssertTrue(result.units.allSatisfy { $0.disposition == .success })
    }

    func testFirstFailureStopsBatchAndMarksRemainderNotAttempted() throws {
        let plan = try threeUnitPlan()
        let result = try ArchiveBatchAtomicityPolicy.finalize(
            plan: plan,
            attempts: [
                attempt(
                    for: plan.units[0],
                    outcome: .failure,
                    errorCode: "archive_rejected"
                ),
            ]
        )

        XCTAssertEqual(result.outcome, .failure)
        XCTAssertEqual(
            result.units.map(\.disposition),
            [.failure, .notAttempted, .notAttempted]
        )
        XCTAssertEqual(result.notAttemptedUnitCount, 2)
    }

    func testFailureAfterSuccessIsPartialAndStopsRemainingUnit() throws {
        let plan = try threeUnitPlan()
        let result = try ArchiveBatchAtomicityPolicy.finalize(
            plan: plan,
            attempts: [
                attempt(for: plan.units[0], outcome: .success),
                attempt(for: plan.units[1], outcome: .failure),
            ]
        )

        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(
            result.units.map(\.disposition),
            [.success, .failure, .notAttempted]
        )
    }

    func testUnknownDominatesBatchAndStopsRemainingUnits() throws {
        let plan = try threeUnitPlan()
        let result = try ArchiveBatchAtomicityPolicy.finalize(
            plan: plan,
            attempts: [
                attempt(for: plan.units[0], outcome: .success),
                attempt(
                    for: plan.units[1],
                    outcome: .unknown,
                    errorCode: "archive_readback_unknown"
                ),
            ]
        )

        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertEqual(
            result.units.map(\.disposition),
            [.success, .unknown, .notAttempted]
        )
    }

    func testProviderAffectedSetPartialIsReportedItemByItemAndStopsBatch() throws {
        let plan = try threeUnitPlan()
        let result = try ArchiveBatchAtomicityPolicy.finalize(
            plan: plan,
            attempts: [attempt(for: plan.units[0], outcome: .partial)]
        )

        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(
            result.units.map(\.disposition),
            [.partial, .notAttempted, .notAttempted]
        )
        XCTAssertEqual(
            result.units[0].items.map(\.disposition),
            [.success, .failure]
        )
    }

    func testItemizedReadbackIsCanonicalizedToFrozenOrder() throws {
        let plan = try threeUnitPlan()
        let unit = plan.units[0]
        let attempt = ArchiveBatchAttempt(
            selectedRootManagerKey: unit.selectedRootManagerKey,
            outcome: .success,
            items: unit.affectedItems.reversed().map {
                ArchiveBatchAttemptItem(
                    managerKey: $0.managerKey,
                    outcome: .success,
                    observedNativeState: .archived,
                    evidenceAt: Date(timeIntervalSince1970: 50)
                )
            }
        )
        let result = try ArchiveBatchAtomicityPolicy.finalize(
            plan: ArchiveBatchExecutionPlan(
                units: [unit],
                providerAtomicity: .perRootSequential,
                requiresAllUnitsPreflightBeforeFirstRequest: true,
                stopsAfterFirstNonSuccess: true
            ),
            attempts: [attempt]
        )

        XCTAssertEqual(
            result.units[0].items.map(\.managerKey),
            unit.affectedManagerKeys
        )
    }

    func testPreflightFailureAttemptsNothing() throws {
        let plan = try threeUnitPlan()
        let result = ArchiveBatchAtomicityPolicy.preflightRejected(
            plan: plan,
            errorCode: "batch_preflight_drift",
            message: "Frozen checkpoint changed."
        )

        XCTAssertEqual(result.outcome, .failure)
        XCTAssertEqual(result.attemptedUnitCount, 0)
        XCTAssertEqual(result.notAttemptedUnitCount, 3)
        XCTAssertTrue(result.units.allSatisfy {
            $0.errorCode == "batch_preflight_drift"
        })
    }

    func testInvalidExecutionSequenceFailsClosed() throws {
        let plan = try threeUnitPlan()

        XCTAssertThrowsError(try ArchiveBatchAtomicityPolicy.finalize(
            plan: plan,
            attempts: [
                attempt(for: plan.units[1], outcome: .success),
            ]
        ))
        XCTAssertThrowsError(try ArchiveBatchAtomicityPolicy.finalize(
            plan: plan,
            attempts: [
                attempt(for: plan.units[0], outcome: .success),
            ]
        )) { error in
            XCTAssertEqual(
                error as? ArchiveBatchAtomicityError,
                .executionStoppedWithoutTerminalOutcome
            )
        }
        XCTAssertThrowsError(try ArchiveBatchAtomicityPolicy.finalize(
            plan: plan,
            attempts: [
                attempt(for: plan.units[0], outcome: .failure),
                attempt(for: plan.units[1], outcome: .success),
            ]
        )) { error in
            XCTAssertEqual(
                error as? ArchiveBatchAtomicityError,
                .attemptAfterTerminalOutcome(plan.units[1].selectedRootManagerKey)
            )
        }

        let incompleteReadback = ArchiveBatchAttempt(
            selectedRootManagerKey: plan.units[0].selectedRootManagerKey,
            outcome: .success,
            items: [
                ArchiveBatchAttemptItem(
                    managerKey: plan.units[0].affectedManagerKeys[0],
                    outcome: .success,
                    observedNativeState: .archived,
                    evidenceAt: Date(timeIntervalSince1970: 50)
                ),
            ]
        )
        XCTAssertThrowsError(try ArchiveBatchAtomicityPolicy.finalize(
            plan: plan,
            attempts: [incompleteReadback]
        ))
    }

    private func threeUnitPlan() throws -> ArchiveBatchExecutionPlan {
        try ArchiveBatchAtomicityPolicy.plan(affectedSets: [
            affectedSet(root: "a", descendants: ["a-child"]),
            affectedSet(root: "b", descendants: []),
            affectedSet(root: "c", descendants: []),
        ])
    }

    private func attempt(
        for unit: ArchiveBatchExecutionUnit,
        outcome: ArchiveBatchAttemptOutcome,
        errorCode: String? = nil
    ) -> ArchiveBatchAttempt {
        let itemOutcome: ArchiveBatchAttemptItemOutcome = switch outcome {
        case .success: .success
        case .failure: .failure
        case .partial: .failure
        case .unknown: .unknown
        }
        return ArchiveBatchAttempt(
            selectedRootManagerKey: unit.selectedRootManagerKey,
            outcome: outcome,
            errorCode: errorCode,
            items: unit.affectedItems.enumerated().map { index, item in
                ArchiveBatchAttemptItem(
                    managerKey: item.managerKey,
                    outcome: outcome == .partial && index == 0 ? .success : itemOutcome,
                    observedNativeState: outcome == .success ? .archived : .unavailable,
                    errorCode: errorCode,
                    evidenceAt: Date(timeIntervalSince1970: 50)
                )
            }
        )
    }

    private func affectedSet(
        root: String,
        descendants: [String]
    ) -> ArchiveAffectedSet {
        let rootItem = affectedItem(
            nativeID: root,
            parent: nil,
            role: .selectedRoot,
            depth: 0
        )
        let children = descendants.map {
            affectedItem(
                nativeID: $0,
                parent: root,
                role: .descendant,
                depth: 1
            )
        }
        return ArchiveAffectedSet(
            selectedRootNativeSessionID: root,
            items: [rootItem] + children
        )
    }

    private func affectedItem(
        nativeID: String,
        parent: String?,
        role: ArchiveAffectedRole,
        depth: Int
    ) -> ArchiveAffectedItem {
        ArchiveAffectedItem(
            managerKey: "codex:\(nativeID)",
            nativeSessionID: nativeID,
            parentNativeSessionID: parent,
            title: nativeID,
            role: role,
            depth: depth,
            nativeState: .active,
            protection: SessionProtection(),
            descendantCount: 0,
            descendantCountKnown: true,
            projectID: nil,
            knownSizeBytes: nil
        )
    }
}
