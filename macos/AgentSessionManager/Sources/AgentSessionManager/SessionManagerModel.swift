import AgentSessionManagerCore
import Foundation
import OSLog
import SwiftUI

struct TrustFolderSummary: Identifiable, Hashable {
    let path: String
    let state: FolderTrustState

    var id: String { path }
}

struct SidebarMetrics: Sendable {
    var statusCounts: [CollectionFilter: Int] = [:]
    var systemCounts: [AgentSystem: Int] = [:]
    var projectCounts: [String: Int] = [:]
    var trustFolderCounts: [String: Int] = [:]
    var workingFolderCounts: [String: Int] = [:]
    var allCurrentStatusCount = 0
    var trustFolderCurrentStatusCount = 0
}

enum SidebarBrowsingScope: String, Sendable {
    case all
    case project
    case trustFolder
    case workingFolder
}

enum FilteredSelectionState: Equatable, Sendable {
    case none
    case partial
    case all
}

@MainActor
final class SessionManagerModel: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var sessionRows: [SessionPresentation] = []
    @Published var projectCatalog: [SessionProject] = []
    private(set) var selectedFilter: CollectionFilter = .active
    private(set) var browsingScope: SidebarBrowsingScope = .all
    private(set) var selectedSystem: AgentSystem = .codex
    private(set) var selectedProjectID: String?
    private(set) var selectedTrustFolderPath: String?
    private(set) var selectedWorkingDirectory: String?
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            retainOnlyVisibleSelection()
        }
    }
    @Published var selection: Set<String> = []
    /// Single row used by the Inspector. Batch lifecycle selection is owned by
    /// `selection` and changes only through the explicit row checkboxes.
    @Published var focusedSessionID: String?
    @Published var pendingPreview: OperationPreview?
    @Published var pendingArchiveReadiness: LifecycleMutationReadiness?
    @Published var pendingNativeArchivePreview: OperationPreview?
    @Published var pendingNativeRestorePreview: OperationPreview?
    @Published var pendingNativeDeletePreview: OperationPreview?
    @Published var pendingConflictResolutionPreview: ConflictResolutionExecutionPreview?
    @Published var latestReport: OperationReport?
    @Published var latestNativeArchiveReport: NativeArchiveReport?
    @Published var latestNativeRestoreReport: NativeRestoreReport?
    @Published var latestNativeDeleteReport: NativeDeleteReport?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var providerDiagnostics: [ProviderDiagnostics] = []
    @Published var checkpointDisposition: CheckpointCommitDisposition?
    @Published var stateStoreURL: URL?
    @Published var isReportHistoryPresented = false
    @Published var isMaintenancePresented = false
    @Published private(set) var diagnosticLogSnapshot = DiagnosticLogSnapshot.empty
    @Published private(set) var diagnosticLogErrorMessage: String?
    @Published private(set) var diagnosticLogPersistenceWarning: String?
    @Published var isDiagnosticLogPersistenceWarningPresented = false
    @Published private(set) var sidebarMetrics = SidebarMetrics()

    private let liveProvider: CodexAppServerProvider
    private let stateStoreFactory: () throws -> SQLiteStateStore
    private let diagnosticLogStore: DiagnosticLogStore
    private var liveStateStore: SQLiteStateStore?
    private var liveSnapshotCoordinator: SessionSnapshotCoordinator?
    private var liveManagerOnlyCoordinator: ManagerOnlyOperationCoordinator?
    private var liveNativeArchiveCoordinator: CodexNativeArchiveCoordinator?
    private var liveNativeArchiveRecoveryCoordinator: CodexNativeArchiveRecoveryCoordinator?
    private var liveNativeRestoreCoordinator: CodexNativeRestoreCoordinator?
    private var liveNativeRestoreRecoveryCoordinator: CodexNativeRestoreRecoveryCoordinator?
    private var liveNativeDeleteCoordinator: CodexNativeDeleteCoordinator?
    private var liveNativeDeleteRecoveryCoordinator: CodexNativeDeleteRecoveryCoordinator?
    private var liveNativeBatchCoordinator: CodexNativeBatchCoordinator?
    private var liveConflictResolutionCoordinator: ConflictResolutionCoordinator?
    private var executingNativeArchivePreviewID: UUID?
    private var executingNativeRestorePreviewID: UUID?
    private var executingNativeDeletePreviewID: UUID?
    private var executingOperationPreviewID: UUID?
    private var executingConflictResolutionPreviewID: UUID?
    private var queuedOperationReport: OperationReport?
    private var reconciledStatesByKey: [String: ReconciledSessionState] = [:]
    private var reconciliationCheckpoint: ProviderCheckpointRecord?
    private var latestCoordinatedSnapshot: ProviderInventorySnapshot?

    init(
        liveProvider: CodexAppServerProvider = CodexAppServerProvider(),
        diagnosticLogStore: DiagnosticLogStore? = nil,
        stateStoreFactory: @escaping () throws -> SQLiteStateStore = {
            let databaseURL = try StateStoreLocation.applicationSupportDatabaseURL()
            return try SQLiteStateStore(databaseURL: databaseURL)
        }
    ) {
        self.liveProvider = liveProvider
        self.stateStoreFactory = stateStoreFactory
        if let diagnosticLogStore {
            self.diagnosticLogStore = diagnosticLogStore
        } else {
            let bootstrap = DiagnosticLogBootstrap.make(
                fileURLProvider: {
                    try StateStoreLocation.applicationSupportDiagnosticLogURL()
                }
            )
            self.diagnosticLogStore = bootstrap.store
            if let warning = bootstrap.persistenceStatus.warningMessage {
                // Persistence failure is a durable state for this launch, not
                // a transient snapshot error. Refresh must never clear it.
                self.diagnosticLogPersistenceWarning = warning
                self.isDiagnosticLogPersistenceWarningPresented = true
            }
        }
        logDiagnostic(
            level: .info,
            category: .app,
            message: "App launched",
            metadata: [
                "data_source": "codex_live",
            ]
        )
    }

    var diagnosticLogFileURL: URL? { diagnosticLogStore.fileURL }

    func refreshDiagnosticLogs() async {
        do {
            diagnosticLogSnapshot = try await diagnosticLogStore.snapshot()
            diagnosticLogErrorMessage = nil
        } catch {
            diagnosticLogErrorMessage = error.localizedDescription
        }
    }

    func exportDiagnosticLogs() async throws -> Data {
        try await diagnosticLogStore.exportJSONL()
    }

    private func logDiagnostic(
        level: DiagnosticLogLevel,
        category: DiagnosticLogCategory,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let timestamp = Date()
        let logger = Logger(
            subsystem: StateStoreLocation.defaultBundleIdentifier,
            category: category.rawValue
        )
        switch level {
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
        Task { [weak self, diagnosticLogStore] in
            do {
                let snapshot = try await diagnosticLogStore.record(
                    level: level,
                    category: category,
                    message: message,
                    metadata: metadata,
                    timestamp: timestamp
                )
                self?.diagnosticLogSnapshot = snapshot
                self?.diagnosticLogErrorMessage = nil
            } catch {
                self?.diagnosticLogErrorMessage = error.localizedDescription
            }
        }
    }

    private func logPreviewPrepared(_ preview: OperationPreview) {
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation Preview created",
            metadata: [
                "operation": preview.operation.rawValue,
                "preview_id": preview.id.uuidString,
                "provider": preview.provider.rawValue,
                "selection_count": String(preview.items.count),
                "native_session_ids": preview.items.map(\.nativeID).joined(separator: ","),
            ]
        )
    }

    private func logOperationCompleted(
        operation: SessionOperation,
        reportID: UUID,
        outcome: String,
        itemCount: Int
    ) {
        logDiagnostic(
            level: outcome == "success" ? .info : .warning,
            category: .lifecycle,
            message: "Operation completed",
            metadata: [
                "operation": operation.rawValue,
                "report_id": reportID.uuidString,
                "outcome": outcome,
                "item_count": String(itemCount),
            ]
        )
    }

    var filteredSessions: [SessionPresentation] {
        sessionRows.filter { session in
            let matchesSystem = session.system == selectedSystem
            let matchesProject = browsingScope != .project
                || selectedProjectID == nil
                || session.project?.id == selectedProjectID
            let matchesTrustFolder = browsingScope != .trustFolder
                || selectedTrustFolderPath == nil
                || session.trustFolderPath == selectedTrustFolderPath
            let matchesWorkingDirectory = browsingScope != .workingFolder
                || selectedWorkingDirectory == nil
                || session.workingDirectory == selectedWorkingDirectory
            let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = needle.isEmpty
                || session.title.localizedCaseInsensitiveContains(needle)
                || session.nativeID.localizedCaseInsensitiveContains(needle)
                || session.project?.name.localizedCaseInsensitiveContains(needle) == true
                || session.workingDirectory?.localizedCaseInsensitiveContains(needle) == true
                || session.trustFolderPath?.localizedCaseInsensitiveContains(needle) == true
            return matches(session, filter: selectedFilter)
                && matchesSystem
                && matchesProject
                && matchesTrustFolder
                && matchesWorkingDirectory
                && matchesSearch
        }
    }

    var selectedSessions: [AgentSession] {
        sessions.filter { selection.contains($0.id) }
    }

    var selectedRows: [SessionPresentation] {
        sessionRows.filter { selection.contains($0.id) }
    }

    var visibleSelectionCount: Int {
        let visibleIDs = Set(filteredSessions.map(\.id))
        return selection.intersection(visibleIDs).count
    }

    var filteredSelectionState: FilteredSelectionState {
        let visibleIDs = Set(filteredSessions.map(\.id))
        guard !visibleIDs.isEmpty else { return .none }
        let selectedVisibleCount = selection.intersection(visibleIDs).count
        if selectedVisibleCount == 0 { return .none }
        return selectedVisibleCount == visibleIDs.count ? .all : .partial
    }

    func isSelected(_ managerKey: String) -> Bool {
        selection.contains(managerKey)
    }

    func setSelected(_ managerKey: String, isSelected: Bool) {
        guard filteredSessions.contains(where: { $0.id == managerKey }) else { return }
        if isSelected {
            selection.insert(managerKey)
            focusedSessionID = managerKey
        } else {
            selection.remove(managerKey)
        }
    }

    func toggleFilteredTrashSelection() {
        guard selectedFilter == .trash else { return }
        let visibleIDs = Set(filteredSessions.map(\.id))
        guard !visibleIDs.isEmpty else { return }
        if visibleIDs.isSubset(of: selection) {
            selection.subtract(visibleIDs)
        } else {
            selection.formUnion(visibleIDs)
        }
    }

    var navigationTitle: String {
        let browsingTitle: String?
        switch browsingScope {
        case .all:
            browsingTitle = nil
        case .project:
            browsingTitle = projects.first(where: { $0.id == selectedProjectID })?.name
                ?? "All Projects"
        case .trustFolder:
            browsingTitle = selectedTrustFolderPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "All Trust Folders"
        case .workingFolder:
            browsingTitle = selectedWorkingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "All Working Folders"
        }
        return browsingTitle.map { "\($0) · \(selectedFilter.label)" }
            ?? selectedFilter.label
    }

    func selectStatusFilter(_ filter: CollectionFilter) {
        guard selectedFilter != filter else { return }
        selectedFilter = filter
        if !selection.isEmpty { selection.removeAll() }
        focusedSessionID = nil
        rebuildSidebarMetrics()
    }

    func selectAgentSystem(_ system: AgentSystem) {
        guard selectedSystem != system else { return }
        selectedSystem = system
        if !selection.isEmpty { selection.removeAll() }
        focusedSessionID = nil
        rebuildSidebarMetrics()
    }

    func selectProject(_ projectID: String?) {
        guard browsingScope != .project || selectedProjectID != projectID else { return }
        resetSidebarSelection(to: .project)
        selectedProjectID = projectID
        rebuildSidebarMetrics()
    }

    func selectTrustFolder(_ path: String?) {
        guard browsingScope != .trustFolder || selectedTrustFolderPath != path else { return }
        resetSidebarSelection(to: .trustFolder)
        selectedTrustFolderPath = path
        rebuildSidebarMetrics()
    }

    func selectWorkingFolder(_ path: String?) {
        guard browsingScope != .workingFolder || selectedWorkingDirectory != path else { return }
        resetSidebarSelection(to: .workingFolder)
        selectedWorkingDirectory = path
        rebuildSidebarMetrics()
    }

    private func resetSidebarSelection(to scope: SidebarBrowsingScope) {
        browsingScope = scope
        selectedProjectID = nil
        selectedTrustFolderPath = nil
        selectedWorkingDirectory = nil
        if !selection.isEmpty { selection.removeAll() }
        focusedSessionID = nil
    }

    private func retainOnlyVisibleSelection() {
        let visibleIDs = Set(filteredSessions.map(\.id))
        if !selection.isEmpty {
            selection.formIntersection(visibleIDs)
        }
        if let focusedSessionID, !visibleIDs.contains(focusedSessionID) {
            self.focusedSessionID = nil
        }
    }

    var inspectedSession: SessionPresentation? {
        if let focusedSessionID,
           let focused = sessionRows.first(where: { $0.id == focusedSessionID }) {
            return focused
        }
        return selectedRows.count == 1 ? selectedRows.first : nil
    }

    var projects: [SessionProject] {
        projectCatalog
    }

    var availableSystems: [AgentSystem] {
        AgentSystem.allCases.filter { system in
            system == .codex
                || providerDiagnostics.contains { $0.system == system }
                || sessionRows.contains { $0.system == system }
        }
    }

    var trustFolders: [TrustFolderSummary] {
        let grouped = Dictionary(grouping: sessionRows.compactMap { session in
            session.trustFolderPath.map { ($0, session.folderTrustState) }
        }, by: \.0)
        return grouped.map { path, entries in
            let states = Set(entries.map(\.1))
            let state = states.count == 1 ? entries[0].1 : .unavailable
            return TrustFolderSummary(path: path, state: state)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var workingDirectories: [String] {
        Array(Set(sessionRows.compactMap(\.workingDirectory))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var currentModeDiagnostic: ProviderDiagnostics? {
        providerDiagnostics.first
    }

    var reportHistoryUnavailableReason: String? {
        guard liveStateStore != nil else {
            return "The manager SQLite store is unavailable. Refresh Codex Live first."
        }
        return nil
    }

    var reportHistorySourceDescription: String {
        "Manager-owned SQLite lifecycle audit reports · read-only"
    }

    func clearOperationHistory(
        reportIDs: Set<UUID>,
        provider: AgentSystem?,
        confirmationToken: String,
        expectedConfirmationToken: String
    ) throws -> Int {
        guard !reportIDs.isEmpty else { return 0 }
        guard !expectedConfirmationToken.isEmpty,
              confirmationToken == expectedConfirmationToken else {
            throw PersistentStateError.confirmationMismatch
        }
        guard let store = liveStateStore else {
            throw SessionManagerError.unsupportedOperation(
                "The manager SQLite store is unavailable."
            )
        }
        guard let provider else {
            throw SessionManagerError.unsupportedOperation(
                "Select one provider before clearing Live Report history."
            )
        }
        let result = try store.clearOperationHistory(
            reportIDs: reportIDs,
            provider: provider,
            confirmationToken: confirmationToken,
            expectedConfirmationToken: expectedConfirmationToken
        )
        guard Set(result.deletedReportIDs) == reportIDs else {
            throw PersistentStateError.invalidRecord(
                "Cleared Report IDs did not match the frozen selection."
            )
        }
        logDiagnostic(
            level: .warning,
            category: .storage,
            message: "Report History cleared",
            metadata: [
                "data_source": "codex_live",
                "provider": provider.rawValue,
                "report_count": String(result.deletedReportIDs.count),
            ]
        )
        return result.deletedReportIDs.count
    }

    var maintenanceUnavailableReason: String? {
        guard liveStateStore != nil else {
            return "The manager SQLite store is unavailable. Refresh Codex Live first."
        }
        return nil
    }

    func count(for filter: CollectionFilter) -> Int {
        sidebarMetrics.statusCounts[filter, default: 0]
    }

    func count(for system: AgentSystem) -> Int {
        sidebarMetrics.systemCounts[system, default: 0]
    }

    func count(forProjectID projectID: String) -> Int {
        sidebarMetrics.projectCounts[projectID, default: 0]
    }

    func count(forTrustFolderPath path: String) -> Int {
        sidebarMetrics.trustFolderCounts[path, default: 0]
    }

    func count(forWorkingFolderPath path: String) -> Int {
        sidebarMetrics.workingFolderCounts[path, default: 0]
    }

    private func rebuildSidebarMetrics() {
        var metrics = SidebarMetrics()
        for session in sessionRows {
            for filter in CollectionFilter.allCases
            where session.system == selectedSystem
                && matches(session, filter: filter)
                && matchesCurrentBrowsingScope(session) {
                metrics.statusCounts[filter, default: 0] += 1
            }
            guard matches(session, filter: selectedFilter) else { continue }
            if matchesCurrentBrowsingScope(session) {
                metrics.systemCounts[session.system, default: 0] += 1
            }
            guard session.system == selectedSystem else { continue }
            metrics.allCurrentStatusCount += 1
            if let projectID = session.project?.id {
                metrics.projectCounts[projectID, default: 0] += 1
            }
            if let trustFolderPath = session.trustFolderPath {
                metrics.trustFolderCounts[trustFolderPath, default: 0] += 1
                metrics.trustFolderCurrentStatusCount += 1
            }
            if let workingDirectory = session.workingDirectory {
                metrics.workingFolderCounts[workingDirectory, default: 0] += 1
            }
        }
        sidebarMetrics = metrics
    }

    private func matches(_ session: SessionPresentation, filter: CollectionFilter) -> Bool {
        switch filter {
        case .all: session.displayState != .deleted
        case .active: session.displayState == .active
        case .archive: session.displayState == .archive
        case .trash: session.displayState == .trash
        case .pinned: session.protection.isPinned
        case .deleted: session.displayState == .deleted
        }
    }

    private func matchesCurrentBrowsingScope(_ session: SessionPresentation) -> Bool {
        switch browsingScope {
        case .all:
            true
        case .project:
            selectedProjectID == nil || session.project?.id == selectedProjectID
        case .trustFolder:
            selectedTrustFolderPath == nil
                || session.trustFolderPath == selectedTrustFolderPath
        case .workingFolder:
            selectedWorkingDirectory == nil
                || session.workingDirectory == selectedWorkingDirectory
        }
    }

    func reload() async {
        guard !isLoading else { return }
        logDiagnostic(
            level: .info,
            category: .inventory,
            message: "Session refresh started",
            metadata: ["data_source": "codex_live"]
        )
        pendingArchiveReadiness = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let coordinator = try liveCoordinator()
            var coordinated = try await coordinator.refresh()
            try await applyLiveSnapshot(coordinated)
            if coordinated.checkpointDisposition == .skippedExecutingRecovery {
                logDiagnostic(
                    level: .warning,
                    category: .recovery,
                    message: "Interrupted operation recovery started",
                    metadata: ["provider": AgentSystem.codex.rawValue]
                )
                guard let recovery = liveNativeArchiveRecoveryCoordinator else {
                    throw SessionManagerError.unsupportedOperation(
                        "An executing Archive Preview blocks checkpoint advancement, but the readback-only recovery facade is unavailable."
                    )
                }
                if let recoveredBatch = try await liveNativeBatchCoordinator?
                    .recoverPending(using: coordinated.snapshot) {
                    logOperationCompleted(
                        operation: recoveredBatch.operation,
                        reportID: recoveredBatch.id,
                        outcome: recoveredBatch.outcome.rawValue,
                        itemCount: recoveredBatch.items.count
                    )
                    presentNativeBatchReport(recoveredBatch)
                } else if let recoveredReport = try await recovery.recoverPending(
                    using: coordinated.snapshot
                ) {
                    logOperationCompleted(
                        operation: recoveredReport.operation,
                        reportID: recoveredReport.id,
                        outcome: recoveredReport.outcome.rawValue,
                        itemCount: recoveredReport.items.count
                    )
                    latestNativeArchiveReport = recoveredReport
                } else if let recoveredReport = try await liveNativeRestoreRecoveryCoordinator?
                    .recoverPending(using: coordinated.snapshot) {
                    logOperationCompleted(
                        operation: .restore,
                        reportID: recoveredReport.id,
                        outcome: recoveredReport.outcome.rawValue,
                        itemCount: recoveredReport.items.count
                    )
                    latestNativeRestoreReport = recoveredReport
                } else if let recoveredReport = try await liveNativeDeleteRecoveryCoordinator?
                    .recoverPending(using: coordinated.snapshot) {
                    logOperationCompleted(
                        operation: .emptyTrash,
                        reportID: recoveredReport.id,
                        outcome: recoveredReport.outcome.rawValue,
                        itemCount: recoveredReport.items.count
                    )
                    latestNativeDeleteReport = recoveredReport
                }
                // Recovery consumed the executing Preview. A second normal
                // refresh may now advance the authoritative checkpoint. A
                // zero-result recovery is also rechecked to handle a safe
                // concurrent completion without inventing an error.
                coordinated = try await coordinator.refresh()
                try await applyLiveSnapshot(coordinated)
            }
            retainOnlyVisibleSelection()
            rebuildSidebarMetrics()
            logDiagnostic(
                level: .info,
                category: .inventory,
                message: "Session refresh completed",
                metadata: [
                    "data_source": "codex_live",
                    "session_count": String(sessions.count),
                    "displayed_row_count": String(sessionRows.count),
                    "project_count": String(projectCatalog.count),
                    "checkpoint_disposition": checkpointDisposition.map(String.init(describing:)) ?? "unavailable",
                ]
            )
        } catch {
            errorMessage = error.localizedDescription
            providerDiagnostics = [await liveProvider.diagnostics()]
            logDiagnostic(
                level: .error,
                category: .inventory,
                message: "Session refresh failed",
                metadata: [
                    "data_source": "codex_live",
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func applyLiveSnapshot(
        _ coordinated: CoordinatedSessionSnapshot
    ) async throws {
        sessions = coordinated.reconciliation.entries.compactMap(\.liveSession)
        projectCatalog = await liveProvider.projects()
        var rows = coordinated.reconciliation.entries
            .map {
                SessionPresentation(
                    reconciled: $0,
                    projectCatalog: projectCatalog
                )
            }
        if let liveStateStore {
            let liveKeys = Set(rows.map(\.managerKey))
            rows.append(contentsOf: try liveStateStore.deletedSessions(for: .codex)
                .filter { !liveKeys.contains($0.managerKey) }
                .map {
                    SessionPresentation(
                        deleted: $0,
                        projectCatalog: projectCatalog
                    )
                })
        }
        sessionRows = rows.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        providerDiagnostics = [coordinated.diagnostics]
        checkpointDisposition = coordinated.checkpointDisposition
        latestCoordinatedSnapshot = coordinated.snapshot
        reconciledStatesByKey = Dictionary(
            uniqueKeysWithValues: coordinated.reconciliation.entries.map { ($0.managerKey, $0) }
        )
        reconciliationCheckpoint = coordinated.reconciliation.checkpoint
    }

    private func liveCoordinator() throws -> SessionSnapshotCoordinator {
        if let liveSnapshotCoordinator { return liveSnapshotCoordinator }
        let store = try stateStoreFactory()
        let coordinator = SessionSnapshotCoordinator(provider: liveProvider, store: store)
        liveStateStore = store
        liveSnapshotCoordinator = coordinator
        liveManagerOnlyCoordinator = ManagerOnlyOperationCoordinator(store: store)
        liveNativeArchiveCoordinator = CodexNativeArchiveCoordinator(store: store)
        liveNativeArchiveRecoveryCoordinator = CodexNativeArchiveRecoveryCoordinator(store: store)
        liveNativeRestoreCoordinator = CodexNativeRestoreCoordinator(store: store)
        liveNativeRestoreRecoveryCoordinator = CodexNativeRestoreRecoveryCoordinator(store: store)
        liveNativeDeleteCoordinator = CodexNativeDeleteCoordinator(store: store)
        liveNativeDeleteRecoveryCoordinator = CodexNativeDeleteRecoveryCoordinator(store: store)
        liveNativeBatchCoordinator = CodexNativeBatchCoordinator(store: store)
        liveConflictResolutionCoordinator = ConflictResolutionCoordinator(store: store)
        stateStoreURL = store.databaseURL
        logDiagnostic(
            level: .info,
            category: .storage,
            message: "Manager SQLite store opened",
            metadata: ["path": store.databaseURL.path]
        )
        return coordinator
    }

    func operationHistoryPage(
        _ query: OperationHistoryQuery
    ) throws -> OperationHistoryPage {
        if let reason = reportHistoryUnavailableReason {
            throw SessionManagerError.unsupportedOperation(reason)
        }
        guard let store = liveStateStore else {
            throw SessionManagerError.unsupportedOperation(
                "The manager SQLite store is unavailable."
            )
        }
        return try store.operationHistory(query)
    }

    func allOperationHistoryEntries(
        matching query: OperationHistoryQuery
    ) throws -> [OperationHistoryEntry] {
        var entries: [OperationHistoryEntry] = []
        var cursor: OperationHistoryCursor?
        var seenCursors: Set<String> = []

        for _ in 0 ..< 100 {
            let pageQuery = OperationHistoryQuery(
                provider: query.provider,
                operation: query.operation,
                outcome: query.outcome,
                searchText: query.searchText,
                completedFrom: query.completedFrom,
                completedThrough: query.completedThrough,
                cursor: cursor,
                limit: OperationHistoryQuery.maximumLimit
            )
            let page = try operationHistoryPage(pageQuery)
            entries.append(contentsOf: page.entries)
            guard let nextCursor = page.nextCursor else { return entries }
            let key = "\(nextCursor.completedAt.timeIntervalSinceReferenceDate):\(nextCursor.reportID.uuidString)"
            guard seenCursors.insert(key).inserted else {
                throw SessionManagerError.unsupportedOperation(
                    "Report history pagination repeated a cursor and stopped."
                )
            }
            cursor = nextCursor
        }
        throw SessionManagerError.unsupportedOperation(
            "Report history export exceeded its 100-page safety limit."
        )
    }

    func sqliteMaintenanceAssessment() async throws -> SQLiteMaintenanceAssessment {
        if let reason = maintenanceUnavailableReason {
            throw SessionManagerError.unsupportedOperation(reason)
        }
        guard let store = liveStateStore else {
            throw SessionManagerError.unsupportedOperation(
                "The manager SQLite store is unavailable."
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try store.maintenanceAssessment()
        }.value
    }

    func requestPreview(_ operation: SessionOperation) async {
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation Preview requested",
            metadata: [
                "operation": operation.rawValue,
                "selection_count": String(selection.count),
                "native_session_ids": selectedSessions.map(\.nativeID).joined(separator: ","),
            ]
        )
        do {
            let usesNativeBatch = selection.count > 1
                    && (
                        operation == .archive
                            || operation == .restore
                            || operation == .emptyTrash
                            || (
                                operation == .moveToTrash
                                    && selection.allSatisfy {
                                        reconciledStatesByKey[$0]?.status == .active
                                    }
                            )
                    )
                if usesNativeBatch {
                    guard let snapshot = latestCoordinatedSnapshot,
                          let checkpoint = reconciliationCheckpoint,
                          let coordinator = liveNativeBatchCoordinator else {
                        throw SessionManagerError.unsupportedOperation(
                            "Native batch Preview is unavailable for the current selection."
                        )
                    }
                    let preview = try await coordinator.prepare(
                        managerKeys: selection,
                        operation: operation,
                        snapshot: snapshot,
                        checkpoint: checkpoint
                    )
                    switch operation {
                    case .archive, .moveToTrash:
                        pendingNativeArchivePreview = preview
                    case .restore:
                        pendingNativeRestorePreview = preview
                    case .emptyTrash:
                        pendingNativeDeletePreview = preview
                    case .moveToArchive:
                        break
                    }
                    logPreviewPrepared(preview)
                    return
                }
                if operation == .emptyTrash {
                    guard selection.count == 1,
                          let managerKey = selection.first,
                          let snapshot = latestCoordinatedSnapshot,
                          let checkpoint = reconciliationCheckpoint,
                          let coordinator = liveNativeDeleteCoordinator else {
                        throw SessionManagerError.unsupportedOperation(
                            "Permanent Delete Preview is unavailable for the current selection."
                        )
                    }
                    pendingNativeDeletePreview = try await coordinator.prepare(
                        managerKey: managerKey,
                        snapshot: snapshot,
                        checkpoint: checkpoint
                    )
                    if let pendingNativeDeletePreview {
                        logPreviewPrepared(pendingNativeDeletePreview)
                    }
                    return
                }
                if operation == .restore {
                    guard selection.count == 1,
                          let managerKey = selection.first,
                          let snapshot = latestCoordinatedSnapshot,
                          let checkpoint = reconciliationCheckpoint,
                          let coordinator = liveNativeRestoreCoordinator else {
                        throw SessionManagerError.unsupportedOperation(
                            "Native Restore Preview is unavailable for the current selection."
                        )
                    }
                    pendingNativeRestorePreview = try await coordinator.prepare(
                        managerKey: managerKey,
                        snapshot: snapshot,
                        checkpoint: checkpoint
                    )
                    if let pendingNativeRestorePreview {
                        logPreviewPrepared(pendingNativeRestorePreview)
                    }
                    return
                }
                if operation == .moveToTrash,
                   selection.count == 1,
                   let managerKey = selection.first,
                   reconciledStatesByKey[managerKey]?.status == .active {
                    guard let snapshot = latestCoordinatedSnapshot,
                          let checkpoint = reconciliationCheckpoint,
                          let coordinator = liveNativeArchiveCoordinator else {
                        throw SessionManagerError.unsupportedOperation(
                            "Active to Trash Preview is unavailable for the current selection."
                        )
                    }
                    pendingNativeArchivePreview = try await coordinator.prepare(
                        managerKey: managerKey,
                        snapshot: snapshot,
                        checkpoint: checkpoint,
                        operation: .moveToTrash
                    )
                    if let pendingNativeArchivePreview {
                        logPreviewPrepared(pendingNativeArchivePreview)
                    }
                    return
                }
                guard operation == .moveToTrash || operation == .moveToArchive,
                      let coordinator = liveManagerOnlyCoordinator,
                      let checkpoint = reconciliationCheckpoint else {
                    throw SessionManagerError.unsupportedOperation(
                        "This Codex Live operation is not available."
                    )
                }
                pendingPreview = try await coordinator.prepare(
                    operation: operation,
                    sessions: selectedSessions,
                    checkpoint: checkpoint
                )
                if let pendingPreview { logPreviewPrepared(pendingPreview) }
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Operation Preview failed",
                metadata: [
                    "operation": operation.rawValue,
                    "selection_count": String(selection.count),
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    var canReviewArchiveReadiness: Bool {
        archiveReadinessReviewBlockedReason == nil
    }

    var archiveReadinessReviewBlockedReason: String? {
        archiveReadinessReviewBlockedReason(for: selection)
    }

    func archiveReadinessReviewBlockedReason(
        for managerKeys: Set<String>
    ) -> String? {
        guard managerKeys.count == 1 else {
            return "Select exactly one live session to review Archive readiness."
        }
        return nil
    }

    func reviewArchiveReadiness(managerKeys: Set<String>? = nil) {
        let keys = managerKeys ?? selection
        guard archiveReadinessReviewBlockedReason(for: keys) == nil else { return }
        selection = keys
        let row = sessionRows.first { keys.contains($0.managerKey) }
        let state = row.flatMap { reconciledStatesByKey[$0.managerKey] }
        let diagnostic = providerDiagnostics.first { $0.system == .codex }
        pendingArchiveReadiness = ArchiveMutationReadinessAssessor.assess(
            session: state?.liveSession,
            selectionCount: keys.count,
            diagnostics: diagnostic,
            checkpoint: reconciliationCheckpoint,
            reconciliationStable: state?.status == .active,
            executorAvailable: liveNativeArchiveCoordinator != nil
        )
    }

    func prepareNativeArchive() async {
        do {
            guard selection.count == 1,
                  let managerKey = selection.first,
                  let state = reconciledStatesByKey[managerKey],
                  let snapshot = latestCoordinatedSnapshot,
                  let checkpoint = reconciliationCheckpoint,
                  let coordinator = liveNativeArchiveCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "Native Archive Preview is unavailable for the current selection."
                )
            }
            let diagnostic = providerDiagnostics.first { $0.system == .codex }
            let readiness = ArchiveMutationReadinessAssessor.assess(
                session: state.liveSession,
                selectionCount: selection.count,
                diagnostics: diagnostic,
                checkpoint: checkpoint,
                reconciliationStable: state.status == .active,
                executorAvailable: true
            )
            guard readiness.isExecutionEnabled else {
                pendingArchiveReadiness = readiness
                throw SessionManagerError.unsupportedOperation(
                    readiness.primaryBlockedReason
                        ?? "Native Archive evidence is incomplete."
                )
            }

            let preview = try await coordinator.prepare(
                managerKey: managerKey,
                snapshot: snapshot,
                checkpoint: checkpoint
            )
            logPreviewPrepared(preview)
            pendingArchiveReadiness = nil
            pendingNativeArchivePreview = preview
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Archive Preview failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func executeNativeArchive(_ preview: OperationPreview) async {
        guard executingNativeArchivePreviewID == nil else { return }
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation execution started",
            metadata: [
                "operation": preview.operation.rawValue,
                "preview_id": preview.id.uuidString,
                "item_count": String(preview.items.count),
            ]
        )
        executingNativeArchivePreviewID = preview.id
        defer {
            if executingNativeArchivePreviewID == preview.id {
                executingNativeArchivePreviewID = nil
            }
        }
        do {
            guard let coordinator = liveNativeArchiveCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "Native Archive execution is unavailable."
                )
            }
            if preview.items.count > 1 {
                guard let batchCoordinator = liveNativeBatchCoordinator else {
                    throw SessionManagerError.unsupportedOperation(
                        "Native Archive batch execution is unavailable."
                    )
                }
                let batchReport = try await batchCoordinator.execute(
                    preview: preview,
                    confirmationToken: preview.confirmationToken
                )
                logOperationCompleted(
                    operation: batchReport.operation,
                    reportID: batchReport.id,
                    outcome: batchReport.outcome.rawValue,
                    itemCount: batchReport.items.count
                )
                pendingNativeArchivePreview = nil
                presentNativeBatchReport(batchReport)
            } else {
                let report = try await coordinator.execute(
                    preview: preview,
                    confirmationToken: preview.confirmationToken
                )
                logOperationCompleted(
                    operation: report.operation,
                    reportID: report.id,
                    outcome: report.outcome.rawValue,
                    itemCount: report.items.count
                )
                latestNativeArchiveReport = report
            }
            pendingNativeArchivePreview = nil
            selection.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Operation execution failed",
                metadata: [
                    "operation": preview.operation.rawValue,
                    "preview_id": preview.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func executeNativeRestore(_ preview: OperationPreview) async {
        guard executingNativeRestorePreviewID == nil else { return }
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation execution started",
            metadata: [
                "operation": preview.operation.rawValue,
                "preview_id": preview.id.uuidString,
                "item_count": String(preview.items.count),
            ]
        )
        executingNativeRestorePreviewID = preview.id
        defer {
            if executingNativeRestorePreviewID == preview.id {
                executingNativeRestorePreviewID = nil
            }
        }
        do {
            guard let coordinator = liveNativeRestoreCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "Native Restore execution is unavailable."
                )
            }
            if preview.items.count > 1 {
                guard let batchCoordinator = liveNativeBatchCoordinator else {
                    throw SessionManagerError.unsupportedOperation(
                        "Native Restore batch execution is unavailable."
                    )
                }
                let batchReport = try await batchCoordinator.execute(
                    preview: preview,
                    confirmationToken: preview.confirmationToken
                )
                logOperationCompleted(
                    operation: batchReport.operation,
                    reportID: batchReport.id,
                    outcome: batchReport.outcome.rawValue,
                    itemCount: batchReport.items.count
                )
                pendingNativeRestorePreview = nil
                presentNativeBatchReport(batchReport)
            } else {
                let report = try await coordinator.execute(
                    preview: preview,
                    confirmationToken: preview.confirmationToken
                )
                logOperationCompleted(
                    operation: .restore,
                    reportID: report.id,
                    outcome: report.outcome.rawValue,
                    itemCount: report.items.count
                )
                latestNativeRestoreReport = report
            }
            pendingNativeRestorePreview = nil
            selection.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Operation execution failed",
                metadata: [
                    "operation": preview.operation.rawValue,
                    "preview_id": preview.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func executeNativeDelete(
        _ preview: OperationPreview,
        confirmationToken: String
    ) async {
        guard executingNativeDeletePreviewID == nil else { return }
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation execution started",
            metadata: [
                "operation": preview.operation.rawValue,
                "preview_id": preview.id.uuidString,
                "item_count": String(preview.items.count),
            ]
        )
        executingNativeDeletePreviewID = preview.id
        defer {
            if executingNativeDeletePreviewID == preview.id {
                executingNativeDeletePreviewID = nil
            }
        }
        do {
            guard let coordinator = liveNativeDeleteCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "Permanent Delete execution is unavailable."
                )
            }
            if preview.items.count > 1 {
                guard let batchCoordinator = liveNativeBatchCoordinator else {
                    throw SessionManagerError.unsupportedOperation(
                        "Permanent Delete batch execution is unavailable."
                    )
                }
                let batchReport = try await batchCoordinator.execute(
                    preview: preview,
                    confirmationToken: confirmationToken
                )
                logOperationCompleted(
                    operation: batchReport.operation,
                    reportID: batchReport.id,
                    outcome: batchReport.outcome.rawValue,
                    itemCount: batchReport.items.count
                )
                pendingNativeDeletePreview = nil
                presentNativeBatchReport(batchReport)
            } else {
                let report = try await coordinator.execute(
                    preview: preview,
                    confirmationToken: confirmationToken
                )
                logOperationCompleted(
                    operation: .emptyTrash,
                    reportID: report.id,
                    outcome: report.outcome.rawValue,
                    itemCount: report.items.count
                )
                latestNativeDeleteReport = report
            }
            pendingNativeDeletePreview = nil
            selection.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Operation execution failed",
                metadata: [
                    "operation": preview.operation.rawValue,
                    "preview_id": preview.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func presentNativeBatchReport(_ report: NativeBatchReport) {
        switch report.operation {
        case .archive, .moveToTrash:
            latestNativeArchiveReport = NativeArchiveReport(
                id: report.id,
                previewID: report.previewID,
                operation: report.operation,
                outcome: report.outcome,
                completedAt: report.completedAt,
                items: report.items,
                recoveredAfterInterruption: report.recoveredAfterInterruption
            )
        case .restore:
            latestNativeRestoreReport = NativeRestoreReport(
                id: report.id,
                previewID: report.previewID,
                outcome: report.outcome,
                completedAt: report.completedAt,
                items: report.items,
                recoveredAfterInterruption: report.recoveredAfterInterruption
            )
        case .emptyTrash:
            latestNativeDeleteReport = NativeDeleteReport(
                id: report.id,
                previewID: report.previewID,
                outcome: report.outcome,
                completedAt: report.completedAt,
                items: report.items,
                recoveredAfterInterruption: report.recoveredAfterInterruption
            )
        case .moveToArchive:
            break
        }
    }

    func conflictResolutionBlockedReason(for session: SessionPresentation) -> String? {
        guard session.displayState == .conflict || session.displayState == .externallyMissing else {
            return "This session does not have a reviewable reconciliation conflict."
        }
        guard let checkpoint = reconciliationCheckpoint, checkpoint.inventoryComplete else {
            return "A complete provider inventory is required."
        }
        guard let state = reconciledStatesByKey[session.managerKey] else {
            return "The frozen reconciliation evidence is unavailable."
        }
        guard state.trashMembership != nil else {
            return "No manager Trash membership exists to resolve."
        }
        return nil
    }

    func reviewConflictResolution(for session: SessionPresentation) async {
        do {
            if let reason = conflictResolutionBlockedReason(for: session) {
                throw SessionManagerError.unsupportedOperation(reason)
            }
            guard let state = reconciledStatesByKey[session.managerKey],
                  let checkpoint = reconciliationCheckpoint else {
                throw SessionManagerError.sessionNotFound(session.managerKey)
            }
            let exactReadback = await liveProvider.exactReadback(
                nativeSessionID: session.nativeID
            )
            let proposal = try ConflictResolutionPlanner.preview(
                for: state,
                checkpoint: checkpoint,
                exactReadback: exactReadback
            )
            let operationPreview: OperationPreview?
            if state.status == .nativeActiveTrashConflict {
                guard let conflictCoordinator = liveConflictResolutionCoordinator else {
                    throw SessionManagerError.unsupportedOperation(
                        "The conflict resolution coordinator is unavailable."
                    )
                }
                operationPreview = try await conflictCoordinator.prepareAcceptNativeRestore(
                    state: state,
                    checkpoint: checkpoint
                )
            } else {
                operationPreview = nil
            }
            pendingConflictResolutionPreview = ConflictResolutionExecutionPreview(
                proposal: proposal,
                operationPreview: operationPreview
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func executeConflictResolution(
        _ preview: ConflictResolutionExecutionPreview
    ) async {
        guard executingConflictResolutionPreviewID == nil else { return }
        guard let operationPreview = preview.operationPreview else {
            errorMessage = SessionManagerError.unsupportedOperation(
                "This conflict resolution option is not executable."
            ).localizedDescription
            return
        }
        executingConflictResolutionPreviewID = operationPreview.id
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Conflict resolution started",
            metadata: [
                "preview_id": operationPreview.id.uuidString,
                "item_count": String(operationPreview.items.count),
            ]
        )
        defer {
            if executingConflictResolutionPreviewID == operationPreview.id {
                executingConflictResolutionPreviewID = nil
            }
        }
        do {
            guard let coordinator = liveConflictResolutionCoordinator,
                  let snapshotCoordinator = liveSnapshotCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "The Live conflict resolution coordinator is unavailable."
                )
            }
            // Re-observe the complete official inventory immediately before
            // the SQLite transaction. A changed native state changes the hash;
            // the frozen Preview is then rejected without removing membership.
            let freshSnapshot = try await snapshotCoordinator.refresh()
            guard freshSnapshot.diagnostics.inventoryComplete,
                  freshSnapshot.diagnostics.connectionState != .unavailable,
                  freshSnapshot.checkpointDisposition != .skippedIncompleteInventory,
                  freshSnapshot.checkpointDisposition != .skippedExecutingRecovery else {
                throw SessionManagerError.unsupportedOperation(
                    "Fresh official inventory readback was incomplete. Trash membership was not changed."
                )
            }
            let persisted = try await coordinator.executeAcceptNativeRestore(
                previewID: operationPreview.id,
                confirmationToken: operationPreview.confirmationToken
            )
            let report = OperationReport(
                id: persisted.id,
                previewID: persisted.previewID,
                provider: persisted.provider,
                operation: .restore,
                completedAt: persisted.completedAt,
                items: operationPreview.items.map { item in
                    OperationResultItem(
                        managerKey: item.managerKey,
                        nativeID: item.nativeID,
                        title: item.title,
                        projectName: item.projectName,
                        workingDirectory: item.workingDirectory,
                        beforeCollection: .trash,
                        observedFinalCollection: .active,
                        success: true,
                        note: "Accepted Codex Active state and removed only the manager Trash membership. No Codex lifecycle request was sent."
                    )
                }
            )
            logOperationCompleted(
                operation: .restore,
                reportID: report.id,
                outcome: report.failureCount == 0 ? "success" : "failure",
                itemCount: report.items.count
            )
            queuedOperationReport = report
            pendingConflictResolutionPreview = nil
            selection.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Conflict resolution failed",
                metadata: [
                    "preview_id": operationPreview.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func canRequestPreview(_ operation: SessionOperation) -> Bool {
        blockedReason(for: operation) == nil
    }

    func blockedReason(
        for operation: SessionOperation,
        managerKeys: Set<String>? = nil
    ) -> String? {
        let keys = managerKeys ?? selection
        let operationRows = sessionRows.filter { keys.contains($0.id) }
        guard !operationRows.isEmpty else { return "Select at least one session." }
        if operation == .emptyTrash {
            guard let checkpoint = reconciliationCheckpoint,
                  checkpoint.inventoryComplete else {
                return "Refresh a complete Codex inventory before Permanent Delete."
            }
            guard let runtimeVersion = checkpoint.runtimeVersion,
                  CodexAppServerProvider.supportsVerifiedDeleteContract(runtimeVersion) else {
                return "The current Codex runtime is outside the audited Permanent Delete allow-list."
            }
            guard liveNativeDeleteCoordinator != nil,
                  keys.count == 1 || liveNativeBatchCoordinator != nil else {
                return "The guarded Permanent Delete executor is unavailable in this App build."
            }
            for row in operationRows {
                guard let state = reconciledStatesByKey[row.managerKey],
                      let session = state.liveSession,
                      state.status == .trash,
                      session.nativeState == .archived else {
                    return "Permanent Delete is available only for stable manager Trash sessions. Move Archive to Trash first."
                }
                guard session.descendantCountKnown, session.descendantCount == 0 else {
                    return "Permanent Delete requires verified zero descendants for every selected session."
                }
                guard !session.protection.blocksDeleteAttempt else {
                    return "Permanent Delete is blocked by positive pinned/running/current protection or unavailable pin/descendant evidence."
                }
            }
            return nil
        }
        if operation == .restore {
            guard liveStateStore != nil else {
                return "The manager SQLite store is unavailable. Refresh Codex Live."
            }
            guard liveNativeRestoreCoordinator != nil,
                  keys.count == 1 || liveNativeBatchCoordinator != nil else {
                return "The guarded Native Restore executor is unavailable in this App build."
            }
            guard let checkpoint = reconciliationCheckpoint else {
                return "No authoritative Codex inventory checkpoint exists yet. Refresh Codex Live."
            }
            guard checkpoint.inventoryComplete else {
                return "The latest Codex inventory is incomplete. Refresh and inspect provider diagnostics."
            }
            guard let runtimeVersion = checkpoint.runtimeVersion,
                  !runtimeVersion.isEmpty else {
                let reportedUserAgent = providerDiagnostics
                    .first(where: { $0.system == .codex })?
                    .userAgent ?? "unavailable"
                return "The selected Codex executable did not provide a valid `codex-cli <version>` result. Client user agent: \(reportedUserAgent)"
            }
            guard CodexAppServerProvider.supportsVerifiedLifecycleContract(
                runtimeVersion
            ) else {
                return "Codex runtime \(runtimeVersion) is outside the audited Native Restore allow-list."
            }
            let statuses = Set(operationRows.compactMap {
                reconciledStatesByKey[$0.managerKey]?.status
            })
            guard statuses.count == 1,
                  let status = statuses.first,
                  status == .archive || status == .trash else {
                return "Select only Archive sessions or only Trash sessions for one Restore batch; do not mix them."
            }
            for row in operationRows {
                guard let state = reconciledStatesByKey[row.managerKey],
                      let session = state.liveSession,
                      session.nativeState == .archived else {
                    return "Native Restore is available only for stable Archive or Trash sessions."
                }
            }
            return nil
        }
        if operation == .archive {
            guard let checkpoint = reconciliationCheckpoint,
                  checkpoint.inventoryComplete,
                  liveNativeArchiveCoordinator != nil,
                  keys.count == 1 || liveNativeBatchCoordinator != nil else {
                return "Refresh a complete Codex inventory before native Archive."
            }
            for row in operationRows {
                guard let state = reconciledStatesByKey[row.managerKey],
                      let session = state.liveSession,
                      state.status == .active,
                      session.nativeState == .active,
                      session.descendantCountKnown,
                      session.descendantCount == 0,
                      !session.protection.blocksArchiveAttempt else {
                    return "Archive requires stable Active sessions with verified clear protection and zero descendants."
                }
            }
            return nil
        }
        guard operation == .moveToTrash || operation == .moveToArchive else {
            return "This Codex Live operation does not have an enabled execution path."
        }
        guard liveStateStore != nil,
              liveManagerOnlyCoordinator != nil,
              let checkpoint = reconciliationCheckpoint,
              checkpoint.inventoryComplete else {
            return "Refresh a complete Codex inventory before changing manager classification."
        }
        if operation == .moveToTrash,
           operationRows.allSatisfy({ reconciledStatesByKey[$0.managerKey]?.status == .active }) {
            guard keys.count == 1 || liveNativeBatchCoordinator != nil else {
                return "The guarded native batch executor is unavailable."
            }
            for row in operationRows {
                guard let state = reconciledStatesByKey[row.managerKey],
                      let session = state.liveSession,
                      session.nativeState == .active,
                      session.descendantCountKnown,
                      session.descendantCount == 0,
                      !session.protection.blocksArchiveAttempt else {
                    return "Active to Trash requires stable Active sessions with verified clear Archive protection and zero descendants."
                }
            }
            return nil
        }
        let requiredState: ReconciliationStatus = operation == .moveToTrash ? .archive : .trash
        for row in operationRows {
            guard let state = reconciledStatesByKey[row.managerKey],
                  let session = state.liveSession,
                  state.status == requiredState,
                  session.nativeState == .archived else {
                return "\(operation.label) is available only for stable \(requiredState.rawValue) sessions."
            }
            if operation == .moveToTrash {
                guard checkpoint.protectionComplete,
                      !session.protection.blocksLifecycleMutation else {
                    return "Session \(session.nativeID) lacks complete, clear lifecycle protection."
                }
            }
        }
        return nil
    }

    func execute(
        _ preview: OperationPreview,
        typedConfirmationToken: String? = nil
    ) async {
        guard executingOperationPreviewID == nil else { return }
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation execution started",
            metadata: [
                "operation": preview.operation.rawValue,
                "preview_id": preview.id.uuidString,
                "item_count": String(preview.items.count),
            ]
        )
        executingOperationPreviewID = preview.id
        defer {
            if executingOperationPreviewID == preview.id {
                executingOperationPreviewID = nil
            }
        }

        do {
            let executionToken = preview.operation.requiresTypedConfirmation
                ? typedConfirmationToken ?? ""
                : preview.confirmationToken
            guard preview.operation == .moveToTrash
                    || preview.operation == .moveToArchive,
                  let coordinator = liveManagerOnlyCoordinator,
                  let snapshotCoordinator = liveSnapshotCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "This Codex Live operation is not available."
                )
            }
            // A fresh official inventory read is the pre-commit readback.
            // If native state changed, it advances to a different hash and
            // the SQLite transaction below rejects the frozen Preview.
            let freshSnapshot = try await snapshotCoordinator.refresh()
            guard freshSnapshot.diagnostics.inventoryComplete,
                  freshSnapshot.diagnostics.connectionState != .unavailable,
                  freshSnapshot.checkpointDisposition != .skippedIncompleteInventory,
                  freshSnapshot.checkpointDisposition != .skippedExecutingRecovery else {
                throw SessionManagerError.unsupportedOperation(
                    "Fresh official inventory readback was incomplete. No manager classification was changed."
                )
            }
            let persisted = try await coordinator.execute(
                previewID: preview.id,
                confirmationToken: executionToken,
                freshSnapshot: freshSnapshot.snapshot
            )
            let report = OperationReport(
                id: persisted.id,
                previewID: persisted.previewID,
                provider: persisted.provider,
                operation: preview.operation,
                completedAt: persisted.completedAt,
                items: preview.items.map { item in
                    OperationResultItem(
                        managerKey: item.managerKey,
                        nativeID: item.nativeID,
                        title: item.title,
                        projectName: item.projectName,
                        workingDirectory: item.workingDirectory,
                        beforeCollection: item.beforeCollection,
                        observedFinalCollection: preview.operation.targetCollection(
                            from: item.beforeCollection
                        ),
                        success: true,
                        note: "Manager SQLite classification committed atomically; Codex remains Archived."
                    )
                }
            )
            logOperationCompleted(
                operation: preview.operation,
                reportID: report.id,
                outcome: report.failureCount == 0 ? "success" : "failure",
                itemCount: report.items.count
            )
            // Wait until SwiftUI has fully dismissed the Preview sheet before
            // presenting the Report. Publishing both sheet bindings together
            // can leave the consumed Preview visibly stuck on screen.
            queuedOperationReport = report
            pendingPreview = nil
            selection.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Operation execution failed",
                metadata: [
                    "operation": preview.operation.rawValue,
                    "preview_id": preview.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func presentQueuedOperationReport() {
        guard let report = queuedOperationReport else { return }
        queuedOperationReport = nil
        latestReport = report
    }
}
