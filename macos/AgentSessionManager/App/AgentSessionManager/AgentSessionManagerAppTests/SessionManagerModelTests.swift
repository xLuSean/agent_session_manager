import AgentSessionManagerCore
import XCTest

@MainActor
final class SessionManagerModelTests: XCTestCase {
    func testStartsOnCodexActiveInsteadOfAllSessions() {
        let active = makeSession(nativeID: "active", state: .active)
        let archived = makeSession(nativeID: "archived", state: .archived)
        let model = makeModel(sessions: [active, archived])

        XCTAssertEqual(model.selectedSystem, .codex)
        XCTAssertEqual(model.selectedFilter, .active)
        XCTAssertEqual(model.filteredSessions.map(\.nativeID), ["active"])
        XCTAssertEqual(model.navigationTitle, "Active")
    }

    func testProjectScopeAndStatusRemainIndependentFilters() {
        let projectA = SessionProject(id: "project-a", name: "Project A", rootPath: "/projects/a")
        let projectB = SessionProject(id: "project-b", name: "Project B", rootPath: "/projects/b")
        let activeA = makeSession(nativeID: "active-a", state: .active, project: projectA)
        let archivedA = makeSession(nativeID: "archive-a", state: .archived, project: projectA)
        let activeB = makeSession(nativeID: "active-b", state: .active, project: projectB)
        let model = makeModel(sessions: [activeA, archivedA, activeB])
        model.projectCatalog = [projectA, projectB]

        model.selectProject(projectA.id)
        XCTAssertEqual(model.filteredSessions.map(\.nativeID), ["active-a"])
        XCTAssertEqual(model.navigationTitle, "Project A · Active")

        model.selectStatusFilter(.archive)
        XCTAssertEqual(model.filteredSessions.map(\.nativeID), ["archive-a"])
        XCTAssertEqual(model.navigationTitle, "Project A · Archive")
    }

    func testChangingStatusOrSearchRemovesInvisibleCheckboxSelection() {
        let first = makeSession(nativeID: "first", title: "First", state: .active)
        let second = makeSession(nativeID: "second", title: "Second", state: .active)
        let archived = makeSession(nativeID: "archived", state: .archived)
        let model = makeModel(sessions: [first, second, archived])

        model.setSelected(first.id, isSelected: true)
        model.setSelected(second.id, isSelected: true)
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertEqual(model.focusedSessionID, second.id)

        model.searchText = "First"
        XCTAssertEqual(model.selection, [first.id])
        XCTAssertNil(model.focusedSessionID)

        model.selectStatusFilter(.archive)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.focusedSessionID)
    }

    func testSelectAllIsAvailableOnlyForCurrentlyFilteredTrash() {
        let active = makeSession(nativeID: "active", state: .active)
        let firstTrash = makeSession(nativeID: "trash-1", title: "Keep", state: .archived, isTrash: true)
        let secondTrash = makeSession(nativeID: "trash-2", title: "Hide", state: .archived, isTrash: true)
        let model = makeModel(sessions: [active, firstTrash, secondTrash])

        model.toggleFilteredTrashSelection()
        XCTAssertTrue(model.selection.isEmpty)

        model.selectStatusFilter(.trash)
        model.searchText = "Keep"
        model.toggleFilteredTrashSelection()
        XCTAssertEqual(model.selection, [firstTrash.id])
        XCTAssertEqual(model.filteredSelectionState, .all)

        model.toggleFilteredTrashSelection()
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.filteredSelectionState, .none)
    }

    private func makeModel(sessions: [AgentSession]) -> SessionManagerModel {
        let model = SessionManagerModel(
            diagnosticLogStore: DiagnosticLogStore.productionInMemory()
        )
        model.sessions = sessions
        model.sessionRows = sessions.map(SessionPresentation.init(session:))
        return model
    }

    private func makeSession(
        nativeID: String,
        title: String? = nil,
        state: NativeSessionState,
        project: SessionProject? = nil,
        isTrash: Bool = false
    ) -> AgentSession {
        AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: title ?? nativeID,
            project: project,
            workingDirectory: project?.rootPath ?? "/projects/default",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            sizeBytes: nil,
            nativeState: state,
            isTrashMember: isTrash
        )
    }
}
