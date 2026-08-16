@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class SessionStateReconcilerTests: XCTestCase {
    func testCompleteInventoryProducesActiveArchiveTrashAndConflictStates() throws {
        let hash = "complete-inventory"
        let memberships = [
            membership("archived-trash", hash: hash),
            membership("active-conflict", hash: hash),
            membership("not-observed", hash: hash),
        ]
        let snapshot = ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: "test-runtime",
            inventoryHash: hash,
            observedAt: date(100),
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [
                session("active", state: .active),
                session("archive", state: .archived),
                session("archived-trash", state: .archived),
                session("active-conflict", state: .active),
            ]
        )

        let result = try SessionStateReconciler.reconcile(
            snapshot: snapshot,
            trashMemberships: memberships
        )
        let entries = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.managerKey, $0) })

        XCTAssertEqual(entries["codex:active"]?.status, .active)
        XCTAssertEqual(entries["codex:archive"]?.status, .archive)
        XCTAssertEqual(entries["codex:archived-trash"]?.status, .trash)
        XCTAssertEqual(entries["codex:archived-trash"]?.liveSession?.collection, .trash)
        XCTAssertEqual(entries["codex:active-conflict"]?.status, .nativeActiveTrashConflict)
        XCTAssertEqual(entries["codex:not-observed"]?.status, .externallyMissing)

        XCTAssertEqual(entries["codex:active"]?.isStableForLifecyclePreview, true)
        XCTAssertEqual(entries["codex:archive"]?.isStableForLifecyclePreview, true)
        XCTAssertEqual(entries["codex:archived-trash"]?.isStableForLifecyclePreview, true)
        XCTAssertEqual(entries["codex:active-conflict"]?.isStableForLifecyclePreview, false)
        XCTAssertEqual(entries["codex:not-observed"]?.isStableForLifecyclePreview, false)
        XCTAssertEqual(result.checkpoint, snapshot.checkpoint)
    }

    func testIncompleteInventoryNeverTreatsUnobservedTrashMembershipAsDeleted() throws {
        let hash = "partial-inventory"
        let snapshot = ProviderInventorySnapshot(
            provider: .codex,
            inventoryHash: hash,
            observedAt: date(100),
            inventoryComplete: false,
            protectionComplete: true,
            sessions: [],
            errorCode: "pagination-truncated"
        )

        let result = try SessionStateReconciler.reconcile(
            snapshot: snapshot,
            trashMemberships: [membership("not-observed", hash: hash)]
        )

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].status, .unavailable)
        XCTAssertFalse(result.entries[0].isStableForLifecyclePreview)
        XCTAssertFalse(result.checkpoint.inventoryComplete)
    }

    func testIncompleteProtectionBlocksOtherwiseNormalPreviewState() throws {
        let snapshot = ProviderInventorySnapshot(
            provider: .codex,
            inventoryHash: "inventory",
            observedAt: date(100),
            inventoryComplete: true,
            protectionComplete: false,
            sessions: [session("active", state: .active)],
            errorCode: "pin-state-unavailable"
        )

        let result = try SessionStateReconciler.reconcile(snapshot: snapshot, trashMemberships: [])

        XCTAssertEqual(result.entries[0].status, .active)
        XCTAssertFalse(result.entries[0].isStableForLifecyclePreview)
    }

    func testProviderTrashFlagCannotInventManagerTrashMembership() throws {
        var untrustedSession = session("archive", state: .archived)
        untrustedSession.isTrashMember = true
        let snapshot = ProviderInventorySnapshot(
            provider: .codex,
            inventoryHash: "inventory",
            observedAt: date(100),
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [untrustedSession]
        )

        let result = try SessionStateReconciler.reconcile(snapshot: snapshot, trashMemberships: [])

        XCTAssertEqual(result.entries[0].status, .archive)
        XCTAssertEqual(result.entries[0].liveSession?.isTrashMember, false)
    }

    func testDuplicateLiveManagerKeyFailsClosed() throws {
        let duplicate = session("duplicate", state: .active)
        let snapshot = ProviderInventorySnapshot(
            provider: .codex,
            inventoryHash: "inventory",
            observedAt: date(100),
            inventoryComplete: true,
            protectionComplete: true,
            sessions: [duplicate, duplicate]
        )

        XCTAssertThrowsError(
            try SessionStateReconciler.reconcile(snapshot: snapshot, trashMemberships: [])
        ) { error in
            XCTAssertEqual(error as? PersistentStateError, .duplicateManagerKey("codex:duplicate"))
        }
    }

    private func session(_ nativeID: String, state: NativeSessionState) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: nativeID,
            workingDirectory: "/tmp/project",
            updatedAt: date(100),
            sizeBytes: nil,
            nativeState: state,
            protection: SessionProtection()
        )
    }

    private func membership(_ nativeID: String, hash: String) -> TrashMembershipRecord {
        TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: nativeID,
            managerKey: "codex:\(nativeID)",
            titleAtEntry: nativeID,
            workingDirectoryAtEntry: "/tmp/project",
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: hash,
            enteredAt: date(90),
            lastReconciledAt: date(100)
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
