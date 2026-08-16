@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class SessionPresentationTests: XCTestCase {
    func testNativeActiveTrashConflictIsNotPresentedAsActive() {
        let live = session("conflict", state: .active)
        let membership = membership("conflict")
        let presentation = SessionPresentation(
            reconciled: ReconciledSessionState(
                managerKey: live.id,
                liveSession: live,
                trashMembership: membership,
                status: .nativeActiveTrashConflict,
                isStableForLifecyclePreview: false
            )
        )

        XCTAssertEqual(presentation.displayState, .conflict)
        XCTAssertEqual(presentation.displayState.filterCollection, .unavailable)
        XCTAssertFalse(presentation.isStableForLifecyclePreview)
        XCTAssertTrue(presentation.stateExplanation.contains("Trash intent"))
    }

    func testMembershipOnlyMissingRowPreservesFullIdentityAndIsNotDeleted() {
        let membership = membership("missing")
        let presentation = SessionPresentation(
            reconciled: ReconciledSessionState(
                managerKey: membership.managerKey,
                liveSession: nil,
                trashMembership: membership,
                status: .externallyMissing,
                isStableForLifecyclePreview: false
            )
        )

        XCTAssertEqual(presentation.managerKey, "codex:missing")
        XCTAssertEqual(presentation.nativeID, "missing")
        XCTAssertEqual(presentation.title, "Stored missing")
        XCTAssertEqual(presentation.workingDirectory, "/stored/project")
        XCTAssertEqual(presentation.displayState, .externallyMissing)
        XCTAssertNotEqual(presentation.displayState, .deleted)
        XCTAssertNil(presentation.nativeState)
        XCTAssertTrue(presentation.protection.hasUnavailableState)
    }

    func testNormalTrashPresentationUsesReconciledManagerIntent() {
        let live = session("trash", state: .archived)
        let presentation = SessionPresentation(
            reconciled: ReconciledSessionState(
                managerKey: live.id,
                liveSession: live,
                trashMembership: membership("trash"),
                status: .trash,
                isStableForLifecyclePreview: true
            )
        )

        XCTAssertEqual(presentation.displayState, .trash)
        XCTAssertEqual(presentation.displayState.filterCollection, .trash)
        XCTAssertTrue(presentation.isStableForLifecyclePreview)
    }

    func testTrashPresentationResolvesMovedProjectFromUniqueWorkingDirectoryName() {
        let live = AgentSession(
            system: .codex,
            nativeID: "moved-project",
            title: "Moved project",
            workingDirectory: "/Users/example/Documents/sample_mail_project",
            updatedAt: Date(timeIntervalSince1970: 100),
            sizeBytes: nil,
            nativeState: .archived,
            protection: SessionProtection()
        )
        let membership = TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: live.nativeID,
            managerKey: live.id,
            titleAtEntry: live.title,
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: "inventory",
            enteredAt: Date(timeIntervalSince1970: 80),
            lastReconciledAt: Date(timeIntervalSince1970: 90)
        )
        let project = SessionProject(
            id: "project-email",
            name: "sample_mail_project",
            rootPath: "/Users/example/Projects/sample_mail_project"
        )

        let presentation = SessionPresentation(
            reconciled: ReconciledSessionState(
                managerKey: live.id,
                liveSession: live,
                trashMembership: membership,
                status: .trash,
                isStableForLifecyclePreview: true
            ),
            projectCatalog: [project]
        )

        XCTAssertEqual(presentation.project, project)
    }

    func testTrashPresentationDoesNotGuessAnAmbiguousMovedProject() {
        let live = AgentSession(
            system: .codex,
            nativeID: "ambiguous-project",
            title: "Ambiguous project",
            workingDirectory: "/Users/example/Documents/shared",
            updatedAt: Date(timeIntervalSince1970: 100),
            sizeBytes: nil,
            nativeState: .archived,
            protection: SessionProtection()
        )
        let membership = TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: live.nativeID,
            managerKey: live.id,
            titleAtEntry: live.title,
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: "inventory",
            enteredAt: Date(timeIntervalSince1970: 80),
            lastReconciledAt: Date(timeIntervalSince1970: 90)
        )
        let projects = [
            SessionProject(id: "one", name: "shared", rootPath: "/Projects/one"),
            SessionProject(id: "two", name: "two", rootPath: "/Projects/shared"),
        ]

        let presentation = SessionPresentation(
            reconciled: ReconciledSessionState(
                managerKey: live.id,
                liveSession: live,
                trashMembership: membership,
                status: .trash,
                isStableForLifecyclePreview: true
            ),
            projectCatalog: projects
        )

        XCTAssertNil(presentation.project)
    }

    func testFixtureDeletedStateRemainsDeleted() {
        let presentation = SessionPresentation(session: session("deleted", state: .absent))

        XCTAssertEqual(presentation.displayState, .deleted)
        XCTAssertEqual(presentation.displayState.filterCollection, .deleted)
    }

    private func session(_ nativeID: String, state: NativeSessionState) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: "Live \(nativeID)",
            workingDirectory: "/live/project",
            updatedAt: Date(timeIntervalSince1970: 100),
            sizeBytes: nil,
            nativeState: state,
            protection: SessionProtection()
        )
    }

    private func membership(_ nativeID: String) -> TrashMembershipRecord {
        TrashMembershipRecord(
            provider: .codex,
            nativeSessionID: nativeID,
            managerKey: "codex:\(nativeID)",
            titleAtEntry: "Stored \(nativeID)",
            workingDirectoryAtEntry: "/stored/project",
            nativeStateAtEntry: .archived,
            providerInventoryHashAtEntry: "inventory",
            enteredAt: Date(timeIntervalSince1970: 80),
            lastReconciledAt: Date(timeIntervalSince1970: 90)
        )
    }
}
