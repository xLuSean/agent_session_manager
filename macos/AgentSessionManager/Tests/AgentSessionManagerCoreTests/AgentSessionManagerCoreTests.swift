import XCTest
@testable import AgentSessionManagerCore
import AgentSessionManagerFixtures

final class AgentSessionManagerCoreTests: XCTestCase {
    func testOnlyIrreversibleSessionDeletionRequiresTypedConfirmation() {
        XCTAssertTrue(SessionOperation.emptyTrash.requiresTypedConfirmation)
        XCTAssertFalse(SessionOperation.archive.requiresTypedConfirmation)
        XCTAssertFalse(SessionOperation.moveToTrash.requiresTypedConfirmation)
        XCTAssertFalse(SessionOperation.restore.requiresTypedConfirmation)
        XCTAssertFalse(SessionOperation.moveToArchive.requiresTypedConfirmation)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testArchiveMovesActiveSessionToArchive() async throws {
        let (provider, session) = makeProvider(collection: .active)
        let preview = try await provider.preview(operation: .archive, managerKeys: [session.id])
        let report = try await provider.execute(preview: preview, confirmationToken: preview.confirmationToken)

        XCTAssertEqual(report.successCount, 1)
        let sessions = await provider.sessions()
        XCTAssertEqual(sessions.first?.collection, .archive)
    }

    func testArchiveCanMoveDirectlyToTrashWithoutRestore() async throws {
        let (provider, session) = makeProvider(collection: .archive)
        let preview = try await provider.preview(operation: .moveToTrash, managerKeys: [session.id])
        _ = try await provider.execute(preview: preview, confirmationToken: preview.confirmationToken)

        let sessions = await provider.sessions()
        XCTAssertEqual(sessions.first?.collection, .trash)
    }

    func testTrashCanReturnToArchiveWithoutUnarchive() async throws {
        let (provider, session) = makeProvider(collection: .trash)
        let preview = try await provider.preview(operation: .moveToArchive, managerKeys: [session.id])
        _ = try await provider.execute(preview: preview, confirmationToken: preview.confirmationToken)

        let result = await provider.sessions().first
        XCTAssertEqual(result?.collection, .archive)
        XCTAssertEqual(result?.nativeState, .archived)
    }

    func testOperationPlanSeparatesManagerIntentFromNativeLifecycle() throws {
        XCTAssertEqual(
            try SessionOperation.moveToTrash.plan(from: .active).nativeMutation,
            .archive
        )
        XCTAssertTrue(
            try SessionOperation.moveToTrash.plan(from: .active)
                .membershipMutationRequiresNativeReadback
        )
        XCTAssertEqual(
            try SessionOperation.moveToTrash.plan(from: .archive).nativeMutation,
            nil
        )
        XCTAssertFalse(
            try SessionOperation.moveToTrash.plan(from: .archive)
                .membershipMutationRequiresNativeReadback
        )
        XCTAssertEqual(
            try SessionOperation.moveToArchive.plan(from: .trash).nativeMutation,
            nil
        )
        XCTAssertEqual(
            try SessionOperation.restore.plan(from: .trash).nativeMutation,
            .unarchive
        )
        XCTAssertEqual(
            try SessionOperation.emptyTrash.plan(from: .trash).nativeMutation,
            .delete
        )
    }

    func testArchiveToTrashDoesNotRequireNativeArchiveCapability() async throws {
        let (_, session) = makeProvider(collection: .archive)
        let managerOnlyCapabilities = SessionCapabilities(
            canArchive: false,
            canUnarchive: false,
            canDelete: false,
            canReadPinnedState: true,
            canReadRunningState: true,
            canReadCurrentState: true,
            canReadDescendants: true,
            canWriteManagerTrashMembership: true
        )
        let provider = FixtureSessionProvider(
            system: .codex,
            capabilities: managerOnlyCapabilities,
            sessions: [session]
        )

        let preview = try await provider.preview(
            operation: .moveToTrash,
            managerKeys: [session.id]
        )
        _ = try await provider.execute(
            preview: preview,
            confirmationToken: preview.confirmationToken
        )

        let sessions = await provider.sessions()
        XCTAssertEqual(sessions.first?.collection, .trash)
    }

    func testPermanentDeleteOnlyAcceptsTrash() async throws {
        let (trashProvider, trashSession) = makeProvider(collection: .trash)
        let preview = try await trashProvider.preview(operation: .emptyTrash, managerKeys: [trashSession.id])
        _ = try await trashProvider.execute(preview: preview, confirmationToken: preview.confirmationToken)
        let trashedSessions = await trashProvider.sessions()
        XCTAssertEqual(trashedSessions.first?.collection, .deleted)

        let (archiveProvider, archiveSession) = makeProvider(collection: .archive)
        await XCTAssertThrowsErrorAsync(
            try await archiveProvider.preview(operation: .emptyTrash, managerKeys: [archiveSession.id])
        ) { error in
            guard case SessionManagerError.invalidTransition = error else {
                return XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    func testPinnedSessionCannotArchiveTrashOrDelete() async throws {
        let protection = SessionProtection(isPinned: true)
        let (provider, session) = makeProvider(collection: .active, protection: protection)

        await XCTAssertThrowsErrorAsync(
            try await provider.preview(operation: .moveToTrash, managerKeys: [session.id])
        ) { error in
            guard case SessionManagerError.protectedSession = error else {
                return XCTFail("Expected protectedSession, got \(error)")
            }
        }
    }

    func testWrongConfirmationDoesNotMutate() async throws {
        let (provider, session) = makeProvider(collection: .active)
        let preview = try await provider.preview(operation: .archive, managerKeys: [session.id])

        await XCTAssertThrowsErrorAsync(
            try await provider.execute(preview: preview, confirmationToken: "WRONG-TOKEN")
        ) { error in
            XCTAssertEqual(error as? SessionManagerError, .confirmationMismatch)
        }
        let sessions = await provider.sessions()
        XCTAssertEqual(sessions.first?.collection, .active)
    }

    func testStalePreviewIsRejectedAfterStateDrift() async throws {
        let (provider, session) = makeProvider(collection: .active)
        let stalePreview = try await provider.preview(operation: .moveToTrash, managerKeys: [session.id])
        let archivePreview = try await provider.preview(operation: .archive, managerKeys: [session.id])
        _ = try await provider.execute(preview: archivePreview, confirmationToken: archivePreview.confirmationToken)

        await XCTAssertThrowsErrorAsync(
            try await provider.execute(preview: stalePreview, confirmationToken: stalePreview.confirmationToken)
        ) { error in
            guard case SessionManagerError.previewDrift = error else {
                return XCTFail("Expected previewDrift, got \(error)")
            }
        }
        let sessions = await provider.sessions()
        XCTAssertEqual(sessions.first?.collection, .archive)
    }

    func testServiceRejectsMixedAgentSystems() async throws {
        let (codex, codexSession) = makeProvider(collection: .active, system: .codex)
        let (claude, claudeSession) = makeProvider(collection: .active, system: .claudeCode)
        let service = AgentSessionManagerService(providers: [codex, claude])

        await XCTAssertThrowsErrorAsync(
            try await service.preview(
                operation: .archive,
                managerKeys: [codexSession.id, claudeSession.id]
            )
        ) { error in
            XCTAssertEqual(error as? SessionManagerError, .mixedProviders)
        }
    }

    func testCodexProtocolCapturesDecodeWithUnknownFields() throws {
        let initializeURL = try XCTUnwrap(
            Bundle.module.url(forResource: "initialize-response", withExtension: "json")
        )
        let listURL = try XCTUnwrap(
            Bundle.module.url(forResource: "thread-list-response", withExtension: "json")
        )

        let serverInfo = try JSONDecoder().decode(
            CodexServerInfo.self,
            from: Data(contentsOf: initializeURL)
        )
        let page = try JSONDecoder().decode(
            CodexThreadPage.self,
            from: Data(contentsOf: listURL)
        )

        XCTAssertEqual(serverInfo.platformOs, "macos")
        XCTAssertEqual(page.data.count, 1)
        XCTAssertEqual(page.data[0].name, "Captured session")
        XCTAssertNil(page.data[0].isPinned)

        let allSourcesURL = try XCTUnwrap(
            Bundle.module.url(forResource: "thread-list-all-sources-response", withExtension: "json")
        )
        let allSourcesPage = try JSONDecoder().decode(
            CodexThreadPage.self,
            from: Data(contentsOf: allSourcesURL)
        )
        XCTAssertEqual(allSourcesPage.data.count, 2)
        XCTAssertEqual(allSourcesPage.data[1].parentThreadId, allSourcesPage.data[0].id)
    }

    func testCodexConfigReadCaptureDecodesFolderTrustSeparately() throws {
        let configURL = try XCTUnwrap(
            Bundle.module.url(forResource: "config-read-response", withExtension: "json")
        )

        let response = try JSONDecoder().decode(
            CodexConfigReadResponse.self,
            from: Data(contentsOf: configURL)
        )

        XCTAssertEqual(
            response.config.projects?["/Users/example/Trusted"]?.trustLevel,
            "trusted"
        )
    }

    func testCodexDesktopStateDecodesProjectCatalogAndOrder() throws {
        let stateURL = try XCTUnwrap(
            Bundle.module.url(forResource: "desktop-project-state", withExtension: "json")
        )

        let state = try JSONDecoder().decode(
            CodexDesktopState.self,
            from: Data(contentsOf: stateURL)
        )
        let projects = state.projectCatalog()

        XCTAssertEqual(projects.map(\.id), ["project-nested", "project-root"])
        XCTAssertEqual(projects[0].name, "Nested App")
        XCTAssertEqual(projects[0].rootPaths, ["/Users/example/Projects/sample/packages/app"])
        XCTAssertEqual(
            try state.validatedPinnedThreadIDSet(),
            Set(["pinned-root", "pinned-child"])
        )
    }

    func testCodexDesktopPinStateValidationFailsClosed() throws {
        let missing = try JSONDecoder().decode(
            CodexDesktopState.self,
            from: Data("{}".utf8)
        )
        XCTAssertThrowsError(try missing.validatedPinnedThreadIDSet()) { error in
            XCTAssertEqual(error as? CodexDesktopStateError, .missingPinnedThreadIDs)
        }

        let duplicate = try JSONDecoder().decode(
            CodexDesktopState.self,
            from: Data(#"{"pinned-thread-ids":["same","same"]}"#.utf8)
        )
        XCTAssertThrowsError(try duplicate.validatedPinnedThreadIDSet()) { error in
            XCTAssertEqual(
                error as? CodexDesktopStateError,
                .duplicatePinnedThreadID("same")
            )
        }

        let changed = try JSONDecoder().decode(
            CodexDesktopState.self,
            from: Data(#"{"pinned-thread-ids":["different"]}"#.utf8)
        )
        XCTAssertThrowsError(
            try CodexDesktopState.stablePinnedThreadIDSet(start: duplicate, end: changed)
        )
        let original = try JSONDecoder().decode(
            CodexDesktopState.self,
            from: Data(#"{"pinned-thread-ids":["same"]}"#.utf8)
        )
        XCTAssertThrowsError(
            try CodexDesktopState.stablePinnedThreadIDSet(start: original, end: changed)
        ) { error in
            XCTAssertEqual(
                error as? CodexDesktopStateError,
                .pinnedThreadIDsChangedDuringInventory
            )
        }
    }

    func testDesktopPinSnapshotSuppliesPinAndPinnedDescendantEvidence() throws {
        let parent = makeCodexRecord(
            id: "parent",
            parentThreadID: nil,
            name: "Parent",
            isPinned: nil
        )
        let child = makeCodexRecord(
            id: "child",
            parentThreadID: "parent",
            name: "Child",
            isPinned: nil
        )
        let sessions = CodexAppServerProvider.map(snapshot: makeSnapshot(
            active: [parent],
            descendantRecords: [parent, child],
            descendantGraphComplete: true,
            desktopPinnedThreadIDs: ["child"],
            desktopPinStateAvailable: true
        ))

        let session = try XCTUnwrap(sessions.first)
        XCTAssertTrue(session.protection.isPinnedKnown)
        XCTAssertFalse(session.protection.isPinned)
        XCTAssertTrue(session.protection.hasPinnedDescendantKnown)
        XCTAssertTrue(session.protection.hasPinnedDescendant)
    }

    func testDesktopAndThreadListPinConflictRemainsUnavailable() throws {
        let record = makeCodexRecord(
            id: "conflict",
            parentThreadID: nil,
            name: "Conflict",
            isPinned: false
        )
        let sessions = CodexAppServerProvider.map(snapshot: makeSnapshot(
            active: [record],
            descendantRecords: [record],
            descendantGraphComplete: true,
            desktopPinnedThreadIDs: ["conflict"],
            desktopPinStateAvailable: true
        ))

        let session = try XCTUnwrap(sessions.first)
        XCTAssertFalse(session.protection.isPinnedKnown)
        XCTAssertFalse(session.protection.hasPinnedDescendantKnown)
    }

    func testDesktopAndThreadListPinConflictDegradesDiagnostics() async throws {
        let record = makeCodexRecord(
            id: "diagnostic-conflict",
            parentThreadID: nil,
            name: "Diagnostic conflict",
            isPinned: false
        )
        let provider = CodexAppServerProvider(source: StubCodexInventorySource(
            snapshot: makeSnapshot(
                active: [record],
                descendantRecords: [record],
                descendantGraphComplete: true,
                projects: [CodexDesktopProject(
                    id: "project",
                    name: "Project",
                    rootPaths: [record.cwd],
                    order: 0
                )],
                projectCatalogAvailable: true,
                desktopPinnedThreadIDs: [record.id],
                desktopPinStateAvailable: true
            )
        ))

        let initialFilesHome = await provider.sessionFilesHomeURL()
        XCTAssertNil(initialFilesHome)
        _ = try await provider.sessions()
        let reportedFilesHome = await provider.sessionFilesHomeURL()
        XCTAssertEqual(reportedFilesHome?.path, "/Users/example/.codex")
        let diagnostics = await provider.diagnostics()
        XCTAssertEqual(diagnostics.connectionState, .degraded)
        XCTAssertFalse(diagnostics.capabilities.canReadPinnedState)
        XCTAssertTrue(diagnostics.messages.contains { $0.contains(record.id) })
    }

    func testDesktopPinMembershipChangesCanonicalInventoryHash() throws {
        let record = makeCodexRecord(
            id: "hash-target",
            parentThreadID: nil,
            name: "Hash target",
            isPinned: nil
        )
        let clear = try CodexProviderInventorySnapshotBuilder.make(from: makeSnapshot(
            active: [record],
            descendantRecords: [record],
            descendantGraphComplete: true,
            desktopPinStateAvailable: true
        ))
        let pinned = try CodexProviderInventorySnapshotBuilder.make(from: makeSnapshot(
            active: [record],
            descendantRecords: [record],
            descendantGraphComplete: true,
            desktopPinnedThreadIDs: [record.id],
            desktopPinStateAvailable: true
        ))

        XCTAssertNotEqual(clear.inventoryHash, pinned.inventoryHash)
    }

    func testCodexPaginationFollowsCursorUntilExhausted() {
        var pagination = CodexPaginationAccumulator(maximumPages: 10)
        let first = makeCodexRecord(id: "first", parentThreadID: nil, name: "First", isPinned: nil)
        let second = makeCodexRecord(id: "second", parentThreadID: nil, name: "Second", isPinned: nil)
        let third = makeCodexRecord(id: "third", parentThreadID: nil, name: "Third", isPinned: nil)

        XCTAssertTrue(pagination.append(CodexThreadPage(data: [first], nextCursor: "cursor-2")))
        XCTAssertEqual(pagination.nextCursor, "cursor-2")
        XCTAssertTrue(pagination.append(CodexThreadPage(data: [second], nextCursor: "cursor-3")))
        XCTAssertFalse(pagination.append(CodexThreadPage(data: [third], nextCursor: nil)))

        XCTAssertEqual(pagination.records.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(pagination.pageCount, 3)
        XCTAssertFalse(pagination.isTruncated)
    }

    func testCodexPaginationFailsClosedOnRepeatedCursorAndDeduplicatesRecords() {
        var pagination = CodexPaginationAccumulator(maximumPages: 10)
        let record = makeCodexRecord(id: "same", parentThreadID: nil, name: "Same", isPinned: nil)

        XCTAssertTrue(pagination.append(CodexThreadPage(data: [record], nextCursor: "repeat")))
        XCTAssertFalse(pagination.append(CodexThreadPage(data: [record], nextCursor: "repeat")))

        XCTAssertEqual(pagination.records.map(\.id), ["same"])
        XCTAssertEqual(pagination.pageCount, 2)
        XCTAssertTrue(pagination.isTruncated)
    }

    func testCodexPaginationMarksConfiguredPageLimitAsTruncated() {
        var pagination = CodexPaginationAccumulator(maximumPages: 2)
        let first = makeCodexRecord(id: "first", parentThreadID: nil, name: "First", isPinned: nil)
        let second = makeCodexRecord(id: "second", parentThreadID: nil, name: "Second", isPinned: nil)

        XCTAssertTrue(pagination.append(CodexThreadPage(data: [first], nextCursor: "cursor-2")))
        XCTAssertFalse(pagination.append(CodexThreadPage(data: [second], nextCursor: "cursor-3")))

        XCTAssertEqual(pagination.records.count, 2)
        XCTAssertTrue(pagination.isTruncated)
    }

    func testLifecycleReadbackCollectsBothCollectionsWithoutPreflightMetadata() async throws {
        let executable = try XCTUnwrap(Bundle.module.url(forResource: "fake-app-server-readback", withExtension: "sh"))
        let client = CodexAppServerClient(configuration: .init(executableURL: executable, timeout: 2))
        let snapshot = try await client.lifecycleReadback()
        XCTAssertEqual(snapshot.active.map(\.id), ["fixture-session"])
        XCTAssertTrue(snapshot.archived.isEmpty)
        XCTAssertFalse(snapshot.isTruncated)
        XCTAssertEqual(snapshot.runtimeVersion, "0.149.0")
        XCTAssertFalse(snapshot.descendantGraphComplete)
        XCTAssertFalse(snapshot.desktopPinStateAvailable)
        XCTAssertFalse(snapshot.projectCatalogAvailable)
        XCTAssertFalse(snapshot.trustConfigurationAvailable)
        let mapped = try CodexProviderInventorySnapshotBuilder.make(from: snapshot)
        XCTAssertTrue(mapped.inventoryComplete)
        XCTAssertFalse(mapped.protectionComplete)
        XCTAssertFalse(mapped.archiveScopeComplete)
    }

    func testLifecycleReadbackPreservesPaginationSafetyBound() async throws {
        let executable = try XCTUnwrap(Bundle.module.url(forResource: "fake-app-server-readback", withExtension: "sh"))
        let client = CodexAppServerClient(configuration: .init(
            executableURL: executable, maximumPagesPerCollection: 1, timeout: 2
        ))
        let snapshot = try await client.lifecycleReadback()
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertFalse(try CodexProviderInventorySnapshotBuilder.make(from: snapshot).inventoryComplete)
    }

    func testCodexConfigurationClampsPaginationToRuntimeSafetyBounds() {
        let configuration = CodexAppServerConfiguration(
            pageSize: 500,
            maximumPagesPerCollection: 500,
            timeout: 45
        )

        XCTAssertEqual(configuration.pageSize, 50)
        XCTAssertEqual(configuration.maximumPagesPerCollection, 200)
    }

#if ASM_ISOLATED_DELETE_ACCEPTANCE
    func testIsolatedDeleteConfigurationRejectsInitializeCodexHomeMismatch() async throws {
        let executable = try XCTUnwrap(
            Bundle.module.url(forResource: "fake-app-server-archive", withExtension: "sh")
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o100 != 0 else {
            throw XCTSkip("App Server fixture executable bit is unavailable.")
        }
        let expectedHome = URL(fileURLWithPath: "/tmp/asm-isolated-delete-home-mismatch")
        let source = CodexAppServerClient(
            configuration: .isolatedDeleteAcceptance(
                executableURL: executable,
                codexHomeURL: expectedHome,
                timeout: 2
            )
        )

        do {
            _ = try await source.inventory()
            XCTFail("A mismatched initialize.codexHome must stop before inventory reads.")
        } catch {
            XCTAssertEqual(
                error as? CodexAppServerError,
                .launchFailed(
                    "Isolated Delete acceptance rejected App Server codexHome mismatch."
                )
            )
        }
    }
#endif

    func testCodexMappingKeepsUnavailableProtectionUnknown() throws {
        let record = makeCodexRecord(
            id: "root",
            parentThreadID: nil,
            name: nil,
            preview: "First line\nprivate body is not used as a title",
            isPinned: nil
        )
        let snapshot = makeSnapshot(active: [record])

        let session = try XCTUnwrap(CodexAppServerProvider.map(snapshot: snapshot).first)

        XCTAssertEqual(session.title, "First line")
        XCTAssertFalse(session.protection.isPinnedKnown)
        XCTAssertFalse(session.protection.isRunningKnown)
        XCTAssertFalse(session.protection.isCurrentKnown)
        XCTAssertFalse(session.protection.hasPinnedDescendantKnown)
        XCTAssertFalse(session.descendantCountKnown)
        XCTAssertTrue(session.protection.blocksLifecycleMutation)
        XCTAssertNil(session.project)
        XCTAssertEqual(session.workingDirectory, "/Users/example/Projects/sample")
        XCTAssertNil(session.trustFolderPath)
        XCTAssertEqual(session.folderTrustState, .unavailable)
    }

    func testCodexMappingSeparatesDesktopProjectWorkingDirectoryAndTrustFolder() throws {
        let record = makeCodexRecord(
            id: "separated",
            parentThreadID: nil,
            name: "Separated",
            isPinned: nil,
            originURL: "git@github.com:example/sample-project.git",
            cwd: "/Users/example/Trusted/sample-project/packages/app"
        )
        let snapshot = makeSnapshot(
            active: [record],
            projects: [
                CodexDesktopProject(
                    id: "desktop-sample",
                    name: "Sample Desktop Project",
                    rootPaths: ["/Users/example/Trusted/sample-project"],
                    order: 0
                ),
            ],
            projectCatalogAvailable: true,
            trustFolders: ["/Users/example/Trusted": .trusted],
            trustConfigurationAvailable: true
        )

        let session = try XCTUnwrap(CodexAppServerProvider.map(snapshot: snapshot).first)

        XCTAssertEqual(session.project?.name, "Sample Desktop Project")
        XCTAssertEqual(session.project?.id, "desktop-sample")
        XCTAssertEqual(session.project?.rootPath, "/Users/example/Trusted/sample-project")
        XCTAssertEqual(session.workingDirectory, "/Users/example/Trusted/sample-project/packages/app")
        XCTAssertEqual(session.trustFolderPath, "/Users/example/Trusted")
        XCTAssertEqual(session.folderTrustState, .trusted)
    }

    func testCodexMappingUsesLongestDesktopProjectRootAndNeverGitOrigin() throws {
        let record = makeCodexRecord(
            id: "nested",
            parentThreadID: nil,
            name: "Nested",
            isPinned: nil,
            originURL: "git@github.com:example/wrong-project.git",
            cwd: "/Users/example/Projects/sample/packages/app/Sources"
        )
        let snapshot = makeSnapshot(
            active: [record],
            projects: [
                CodexDesktopProject(
                    id: "root",
                    name: "Root",
                    rootPaths: ["/Users/example/Projects/sample"],
                    order: 1
                ),
                CodexDesktopProject(
                    id: "nested",
                    name: "Nested App",
                    rootPaths: ["/Users/example/Projects/sample/packages/app"],
                    order: 0
                ),
            ],
            projectCatalogAvailable: true
        )

        let session = try XCTUnwrap(CodexAppServerProvider.map(snapshot: snapshot).first)

        XCTAssertEqual(session.project?.id, "nested")
        XCTAssertEqual(session.project?.name, "Nested App")
    }

    func testCodexMappingBuildsDescendantProtectionWhenPinStateIsAvailable() throws {
        let parent = makeCodexRecord(
            id: "parent",
            parentThreadID: nil,
            name: "Parent",
            isPinned: false
        )
        let child = makeCodexRecord(
            id: "child",
            parentThreadID: "parent",
            name: "Child",
            isPinned: true
        )
        let sessions = CodexAppServerProvider.map(
            snapshot: makeSnapshot(
                active: [parent],
                descendantRecords: [parent, child],
                descendantGraphComplete: true
            )
        )
        let mappedParent = try XCTUnwrap(sessions.first { $0.nativeID == "parent" })

        XCTAssertEqual(mappedParent.descendantCount, 1)
        XCTAssertTrue(mappedParent.descendantCountKnown)
        XCTAssertTrue(mappedParent.protection.hasPinnedDescendant)
        XCTAssertTrue(mappedParent.protection.hasPinnedDescendantKnown)
    }

    func testCodexArchiveScopePreservesExactParentAndNativeState() {
        let parent = makeCodexRecord(
            id: "01900000-0000-7000-8000-000000000010",
            parentThreadID: nil,
            name: "Parent",
            isPinned: false
        )
        let child = makeCodexRecord(
            id: "01900000-0000-7000-8000-000000000011",
            parentThreadID: parent.id,
            name: "Child",
            isPinned: false
        )
        let snapshot = makeSnapshot(
            active: [parent],
            archived: [],
            descendantRecords: [parent, child],
            descendantNativeStates: [parent.id: .active, child.id: .archived],
            descendantGraphComplete: true
        )

        let scope = CodexAppServerProvider.archiveScope(snapshot: snapshot)

        XCTAssertTrue(scope.isComplete)
        XCTAssertEqual(scope.nodes.map(\.nativeSessionID), [parent.id, child.id])
        XCTAssertEqual(scope.nodes.map(\.nativeState), [.active, .archived])
        XCTAssertEqual(scope.nodes.map(\.parentNativeSessionID), [nil, parent.id])
        XCTAssertEqual(scope.nodes.map(\.descendantCount), [1, 0])
    }

    func testCodexMappingTreatsActiveStatusAsPositiveRunningEvidenceOnly() throws {
        let active = makeCodexRecord(
            id: "active-runtime",
            parentThreadID: nil,
            name: "Active",
            isPinned: nil,
            statusType: "active"
        )
        let notLoaded = makeCodexRecord(
            id: "other-host-unknown",
            parentThreadID: nil,
            name: "Unknown",
            isPinned: nil
        )

        let sessions = CodexAppServerProvider.map(
            snapshot: makeSnapshot(active: [active, notLoaded])
        )
        let activeSession = try XCTUnwrap(sessions.first { $0.nativeID == active.id })
        let unknownSession = try XCTUnwrap(sessions.first { $0.nativeID == notLoaded.id })

        XCTAssertTrue(activeSession.protection.isRunning)
        XCTAssertTrue(activeSession.protection.isRunningKnown)
        XCTAssertFalse(unknownSession.protection.isRunning)
        XCTAssertFalse(unknownSession.protection.isRunningKnown)
    }

    func testCodexMappingPrefersLaterArchivedObservationForDuplicateNativeID() throws {
        let record = makeCodexRecord(
            id: "drifted",
            parentThreadID: nil,
            name: "Drifted",
            isPinned: nil
        )

        let sessions = CodexAppServerProvider.map(
            snapshot: makeSnapshot(active: [record], archived: [record])
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].collection, .archive)
    }

    func testCodexProviderIsReadOnlyAndReportsObservedCapabilities() async throws {
        let record = makeCodexRecord(
            id: "live",
            parentThreadID: nil,
            name: "Live",
            isPinned: true
        )
        let provider = CodexAppServerProvider(
            source: StubCodexInventorySource(snapshot: makeSnapshot(
                active: [record],
                descendantRecords: [record],
                descendantGraphComplete: true,
                projects: [
                    CodexDesktopProject(
                        id: "live-project",
                        name: "Live Project",
                        rootPaths: ["/Users/example/Projects/sample"],
                        order: 0
                    ),
                    CodexDesktopProject(
                        id: "empty-project",
                        name: "Empty Project",
                        rootPaths: ["/Users/example/Projects/empty"],
                        order: 1
                    ),
                ],
                projectCatalogAvailable: true
            ))
        )

        let sessions = try await provider.sessions()
        let projects = await provider.projects()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(projects.map(\.id), ["live-project", "empty-project"])
        XCTAssertEqual(sessions.compactMap { $0.project?.id }, ["live-project"])
        let diagnostics = await provider.diagnostics()
        XCTAssertEqual(diagnostics.connectionState, .ready)
        XCTAssertTrue(diagnostics.inventoryComplete)
        XCTAssertFalse(diagnostics.protectionComplete)
        XCTAssertTrue(diagnostics.capabilities.canReadPinnedState)
        XCTAssertTrue(diagnostics.capabilities.canReadExactSession)
        XCTAssertFalse(diagnostics.capabilities.canReadRunningState)
        XCTAssertFalse(diagnostics.capabilities.canArchive)
        XCTAssertFalse(diagnostics.capabilities.canDelete)

        let exactReadback = await provider.exactReadback(nativeSessionID: record.id)
        XCTAssertEqual(exactReadback.status, .present)
        XCTAssertEqual(exactReadback.evidenceKind, .exactMatch)
        XCTAssertNil(exactReadback.rpcCode)
        XCTAssertTrue(exactReadback.provesExistence)
        XCTAssertFalse(exactReadback.provesAbsence)

        let missingReadback = await provider.exactReadback(nativeSessionID: "missing")
        XCTAssertEqual(missingReadback.status, .unavailable)
        XCTAssertEqual(missingReadback.evidenceKind, .rpcError)
        XCTAssertEqual(missingReadback.rpcCode, -32600)
        XCTAssertNil(missingReadback.absenceContract)
        XCTAssertFalse(missingReadback.provesAbsence)

        await XCTAssertThrowsErrorAsync(
            try await provider.preview(operation: .archive, managerKeys: [sessions[0].id])
        ) { error in
            guard case SessionManagerError.unsupportedOperation = error else {
                return XCTFail("Expected unsupportedOperation, got \(error)")
            }
        }
    }

    func testCodexDiagnosticsBindLifecycleRuntimeToSelectedExecutableVersion() async throws {
        let current = makeCodexRecord(
            id: "current-version",
            parentThreadID: nil,
            name: "Current",
            isPinned: false
        )
        let historical = CodexThreadRecord(
            id: "historical-version",
            sessionId: "historical-version",
            parentThreadId: nil,
            preview: "Historical",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            status: CodexThreadStatus(type: "notLoaded", activeFlags: nil),
            cwd: "/Users/example/Projects/sample",
            cliVersion: "0.146.0",
            name: "Historical",
            isPinned: false,
            gitInfo: nil
        )
        let snapshot = makeSnapshot(
            active: [current, historical],
            descendantRecords: [current, historical],
            descendantGraphComplete: true,
            projectCatalogAvailable: true
        )
        let provider = CodexAppServerProvider(
            source: StubCodexInventorySource(snapshot: snapshot)
        )

        _ = try await provider.sessions()
        let diagnostics = await provider.diagnostics()
        let mutationSnapshot = try CodexProviderInventorySnapshotBuilder.make(from: snapshot)

        XCTAssertEqual(diagnostics.runtimeVersion, "0.147.0")
        XCTAssertEqual(diagnostics.capabilities.hasNativeArchiveInterface, true)
        XCTAssertTrue(diagnostics.messages.contains { $0.contains("multiple CLI versions") })
        XCTAssertEqual(mutationSnapshot.runtimeVersion, "0.147.0")
    }

    func testCodexRuntimeVersionUsesExactCLIOutputAndNotInitializeUserAgent() {
        XCTAssertEqual(
            CodexAppServerProvider.runtimeVersion(
                fromVersionOutput: "codex-cli 0.147.0\n"
            ),
            "0.147.0"
        )
        XCTAssertEqual(
            CodexAppServerProvider.runtimeVersion(
                fromVersionOutput: "codex-cli 0.147.0-alpha.6.5\n"
            ),
            "0.147.0-alpha.6.5"
        )
        XCTAssertNil(
            CodexAppServerProvider.runtimeVersion(
                fromVersionOutput: "agent_session_manager/0.1.0"
            )
        )
        XCTAssertNil(
            CodexAppServerProvider.runtimeVersion(
                fromVersionOutput: "Codex Desktop/0.147.0"
            )
        )
    }

    func testCodexExecutableResolutionPrefersStandaloneInstallLocationsOverLauncherPATH() {
        let candidates = CodexAppServerClient.executableCandidates(
            path: "/Applications/ChatGPT.app/Contents/Resources:/opt/homebrew/bin:/usr/bin"
        )

        XCTAssertEqual(candidates[0].path, "/opt/homebrew/bin/codex")
        XCTAssertEqual(candidates[1].path, "/usr/local/bin/codex")
        XCTAssertEqual(
            candidates.filter { $0.path == "/opt/homebrew/bin/codex" }.count,
            1
        )
        XCTAssertTrue(
            candidates.contains {
                $0.path == "/Applications/ChatGPT.app/Contents/Resources/codex"
            }
        )
    }

    func testCodexExactReadbackClassifiesTimeoutWithoutPromotingAbsence() async {
        let provider = CodexAppServerProvider(
            source: StubCodexInventorySource(
                snapshot: makeSnapshot(),
                exactReadError: .responseTimeout
            )
        )

        let evidence = await provider.exactReadback(nativeSessionID: "timed-out")

        XCTAssertEqual(evidence.status, .unavailable)
        XCTAssertEqual(evidence.evidenceKind, .timeout)
        XCTAssertNil(evidence.rpcCode)
        XCTAssertFalse(evidence.provesAbsence)
    }

    func testCodexProviderReportsTruncatedPaginationAsDegraded() async throws {
        let record = makeCodexRecord(
            id: "truncated",
            parentThreadID: nil,
            name: "Truncated",
            isPinned: nil
        )
        let provider = CodexAppServerProvider(
            source: StubCodexInventorySource(
                snapshot: makeSnapshot(active: [record], isTruncated: true)
            )
        )

        _ = try await provider.sessions()
        let diagnostics = await provider.diagnostics()

        XCTAssertEqual(diagnostics.connectionState, .degraded)
        XCTAssertFalse(diagnostics.inventoryComplete)
        XCTAssertFalse(diagnostics.protectionComplete)
        XCTAssertTrue(diagnostics.messages.contains { $0.contains("safety limit") })
    }

    func testLiveCodexReadOnlyInventoryWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENT_SESSION_MANAGER_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set AGENT_SESSION_MANAGER_LIVE_TEST=1 for the explicit live read-only smoke test.")
        }
        let limitedProvider = CodexAppServerProvider(
            configuration: CodexAppServerConfiguration(
                pageSize: 20,
                maximumPagesPerCollection: 1,
                timeout: 45
            )
        )
        let limitedSessions = try await limitedProvider.sessions()
        let limitedDiagnostics = await limitedProvider.diagnostics()

        let provider = CodexAppServerProvider()

        let sessions = try await provider.sessions()
        let catalogProjects = await provider.projects()
        let diagnostics = await provider.diagnostics()

        XCTAssertNotEqual(diagnostics.connectionState, .unavailable)
        XCTAssertEqual(diagnostics.runtimeVersion, "0.147.0")
        XCTAssertFalse(diagnostics.capabilities.canArchive)
        XCTAssertFalse(diagnostics.capabilities.canUnarchive)
        XCTAssertFalse(diagnostics.capabilities.canDelete)
        XCTAssertTrue(diagnostics.capabilities.canReadFolderTrust)
        XCTAssertTrue(diagnostics.capabilities.canReadDescendants)
        XCTAssertTrue(diagnostics.capabilities.canReadExactSession)
        XCTAssertTrue(diagnostics.capabilities.canReadPinnedState)
        XCTAssertTrue(sessions.allSatisfy { $0.system == .codex })
        XCTAssertTrue(sessions.allSatisfy { !$0.isTrashMember })
        XCTAssertTrue(sessions.allSatisfy { $0.protection.isPinnedKnown })
        XCTAssertTrue(sessions.allSatisfy { $0.protection.hasPinnedDescendantKnown })
        XCTAssertTrue(sessions.allSatisfy(\.descendantCountKnown))
        XCTAssertTrue(sessions.allSatisfy {
            $0.folderTrustState != .trusted || $0.trustFolderPath != nil
        })
        XCTAssertGreaterThanOrEqual(sessions.count, limitedSessions.count)
        if limitedDiagnostics.connectionState == .degraded {
            XCTAssertGreaterThan(sessions.count, limitedSessions.count)
        }
        let projectCount = Set(sessions.compactMap { $0.project?.id }).count
        XCTAssertGreaterThanOrEqual(catalogProjects.count, projectCount)
        if let firstSession = sessions.first {
            let presentReadback = await provider.exactReadback(
                nativeSessionID: firstSession.nativeID
            )
            XCTAssertEqual(presentReadback.status, .present)
            XCTAssertEqual(presentReadback.nativeSessionID, firstSession.nativeID)
        }
        let missingReadback = await provider.exactReadback(
            nativeSessionID: "00000000-0000-0000-0000-000000000000"
        )
        XCTAssertEqual(missingReadback.status, .unavailable)
        XCTAssertFalse(missingReadback.provesAbsence)
        let trustFolderCount = Set(sessions.compactMap(\.trustFolderPath)).count
        let workingFolderCount = Set(sessions.map(\.workingDirectory)).count
        let rootsWithDescendants = sessions.filter { $0.descendantCount > 0 }.count
        let descendantReferences = sessions.reduce(0) { $0 + $1.descendantCount }
        let pinnedCount = sessions.filter { $0.protection.isPinned }.count
        let descendantDiagnostic = diagnostics.messages.first {
            $0.contains("All-source descendant inventory")
        } ?? "descendant diagnostic unavailable"
        print(
            "Live inventory verification: limited=\(limitedSessions.count), "
                + "paginated=\(sessions.count), projects=\(projectCount), "
                + "catalogProjects=\(catalogProjects.count), "
                + "trustFolders=\(trustFolderCount), workingFolders=\(workingFolderCount), "
                + "pinned=\(pinnedCount), "
                + "rootsWithDescendants=\(rootsWithDescendants), "
                + "descendantReferences=\(descendantReferences), "
                + "graph=\(descendantDiagnostic)"
        )
    }

    private func makeProvider(
        collection: SessionCollection,
        system: AgentSystem = .codex,
        protection: SessionProtection = SessionProtection()
    ) -> (FixtureSessionProvider, AgentSession) {
        let nativeState: NativeSessionState
        let isTrashMember: Bool
        switch collection {
        case .active:
            nativeState = .active
            isTrashMember = false
        case .archive:
            nativeState = .archived
            isTrashMember = false
        case .trash:
            nativeState = .archived
            isTrashMember = true
        case .deleted:
            nativeState = .absent
            isTrashMember = false
        case .unavailable:
            nativeState = .unavailable
            isTrashMember = false
        }

        let session = AgentSession(
            system: system,
            nativeID: "test-\(system.rawValue)-\(collection.rawValue)",
            title: "Test session",
            project: SessionProject(id: "test-project", name: "Test Project", rootPath: "/tmp/test-project"),
            workingDirectory: "/tmp/test-project",
            trustFolderPath: "/tmp",
            folderTrustState: .trusted,
            updatedAt: fixedDate,
            sizeBytes: 1_024,
            nativeState: nativeState,
            isTrashMember: isTrashMember,
            protection: protection
        )
        let capabilities: SessionCapabilities = system == .codex ? .codexFixture : .codexFixture
        return (
            FixtureSessionProvider(
                system: system,
                capabilities: capabilities,
                sessions: [session],
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            session
        )
    }

    private func makeCodexRecord(
        id: String,
        parentThreadID: String?,
        name: String?,
        preview: String = "Preview",
        isPinned: Bool?,
        originURL: String? = nil,
        cwd: String = "/Users/example/Projects/sample",
        statusType: String = "notLoaded"
    ) -> CodexThreadRecord {
        CodexThreadRecord(
            id: id,
            sessionId: id,
            parentThreadId: parentThreadID,
            preview: preview,
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_800_000_000,
            updatedAt: 1_800_000_100,
            status: CodexThreadStatus(
                type: statusType,
                activeFlags: statusType == "active" ? [] : nil
            ),
            cwd: cwd,
            cliVersion: "0.147.0-test",
            name: name,
            isPinned: isPinned,
            gitInfo: originURL.map {
                CodexGitInfo(branch: "main", originUrl: $0, sha: "0123456789")
            }
        )
    }

    private func makeSnapshot(
        runtimeVersion: String? = "0.147.0",
        active: [CodexThreadRecord] = [],
        archived: [CodexThreadRecord] = [],
        descendantRecords: [CodexThreadRecord] = [],
        descendantNativeStates: [String: NativeSessionState]? = nil,
        descendantGraphComplete: Bool = false,
        descendantGraphError: String? = nil,
        isTruncated: Bool = false,
        projects: [CodexDesktopProject] = [],
        projectCatalogAvailable: Bool = false,
        projectCatalogError: String? = nil,
        desktopPinnedThreadIDs: Set<String> = [],
        desktopPinStateAvailable: Bool = false,
        desktopPinStateError: String? = nil,
        trustFolders: [String: FolderTrustState] = [:],
        trustConfigurationAvailable: Bool = false,
        trustConfigurationError: String? = nil
    ) -> CodexInventorySnapshot {
        CodexInventorySnapshot(
            serverInfo: CodexServerInfo(
                userAgent: "agent_session_manager/0.1.0 test",
                codexHome: "/Users/example/.codex",
                platformFamily: "unix",
                platformOs: "macos"
            ),
            runtimeVersion: runtimeVersion,
            active: active,
            archived: archived,
            descendantRecords: descendantRecords,
            descendantNativeStates: descendantNativeStates ?? Dictionary(
                uniqueKeysWithValues: descendantRecords.map { ($0.id, NativeSessionState.active) }
            ),
            descendantGraphComplete: descendantGraphComplete,
            descendantGraphError: descendantGraphError,
            refreshedAt: fixedDate,
            isTruncated: isTruncated,
            projects: projects,
            projectCatalogAvailable: projectCatalogAvailable,
            projectCatalogError: projectCatalogError,
            desktopPinnedThreadIDs: desktopPinnedThreadIDs,
            desktopPinStateAvailable: desktopPinStateAvailable,
            desktopPinStateError: desktopPinStateError,
            trustFolders: trustFolders,
            trustConfigurationAvailable: trustConfigurationAvailable,
            trustConfigurationError: trustConfigurationError
        )
    }
}

private struct StubCodexInventorySource: CodexInventorySource {
    let snapshot: CodexInventorySnapshot
    let exactReadError: CodexAppServerError?

    init(
        snapshot: CodexInventorySnapshot,
        exactReadError: CodexAppServerError? = nil
    ) {
        self.snapshot = snapshot
        self.exactReadError = exactReadError
    }

    func inventory() async throws -> CodexInventorySnapshot {
        snapshot
    }

    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot {
        if let exactReadError { throw exactReadError }
        let records = snapshot.active + snapshot.archived + snapshot.descendantRecords
        guard let record = records.first(where: { $0.id == threadID }) else {
            throw CodexAppServerError.rpcError(-32600, "thread not loaded: \(threadID)")
        }
        return CodexExactReadSnapshot(
            serverInfo: snapshot.serverInfo,
            runtimeVersion: snapshot.runtimeVersion,
            thread: record,
            observedAt: snapshot.refreshedAt
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
