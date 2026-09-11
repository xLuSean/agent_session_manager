import AgentSessionManagerCore
import AppKit
import SwiftUI

struct SessionTableView: View {
    @EnvironmentObject private var model: SessionManagerModel
    @State private var historyClearPreview: CompletedHistoryClearPreview?
    @State private var deletedListClearPreview: DeletedListClearPreview?
    @State private var historyClearError: String?

    var body: some View {
        VStack(spacing: 0) {
            liveBanner
            deletedHistoryBar
            filteredSelectionBar
            HStack {
                if model.isCalculatingSessionFileSizes {
                    ProgressView().controlSize(.small)
                    Text("Updating conversation sizes…").font(.caption).foregroundStyle(.secondary)
                } else if model.unavailableConversationSizeCount > 0 {
                    Text("\(model.unavailableConversationSizeCount) sizes unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Hover over a — in the Size column for the reason. Unmeasured sessions appear after measured sizes, not as zero.")
                }
                Spacer()
                Picker("Sort", selection: $model.sessionListSort) {
                    ForEach(SessionListSort.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Table(model.filteredSessions, selection: $model.focusedSessionID) {
                TableColumn("Session") { session in
                    SessionIdentityCell(model: model, session: session)
                }
                .width(min: 298, ideal: 378)

                TableColumn("Project") { session in
                    Text(session.project?.name ?? "—")
                        .help(session.project.map { "\($0.rootPath) · Desktop project ID: \($0.id)" } ?? "No matching Codex Desktop project")
                        .lineLimit(1)
                }
                .width(min: 110, ideal: 150)

                TableColumn("Working Folder") { session in
                    Text(
                        session.workingDirectory.map {
                            URL(fileURLWithPath: $0).lastPathComponent
                        } ?? "—"
                    )
                        .help(session.workingDirectory ?? "Working folder unavailable")
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 160)

                TableColumn("State") { session in
                    Label(session.displayState.label, systemImage: session.displayState.symbol)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(color(for: session.displayState))
                        .help(session.stateExplanation)
                }
                .width(min: 100, ideal: 110)

                TableColumn("Size") { session in
                    Text(model.conversationFileSizeLabel(for: session))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(model.conversationFileSizeHelp(for: session))
                        .accessibilityHint(model.conversationFileSizeHelp(for: session))
                }
                .width(min: 70, ideal: 85, max: 110)

                TableColumn("Updated") { session in
                    Text(session.updatedAt, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .help(session.updatedAt.formatted(date: .complete, time: .standard))
                }
                .width(min: 90, ideal: 110)
            }
            .background {
                TableColumnWidthPersistence(
                    storageKey: "layout.sessionTable.columnWidths.v2",
                    expectedColumnCount: 6
                )
            }
            .contextMenu(forSelectionType: String.self) { managerKeys in
                sessionContextMenu(managerKeys: managerKeys)
            }
            selectionSummary
        }
        .navigationTitle(model.navigationTitle)
        .searchable(text: $model.searchText, prompt: "Title, ID, source, project, or folder")
        .toolbar { toolbarContent }
        .alert("Remove Deleted list records?", isPresented: Binding(
            get: { deletedListClearPreview != nil }, set: { if !$0 { deletedListClearPreview = nil } }
        ), presenting: deletedListClearPreview) { preview in
            Button("Remove from List", role: .destructive) {
                do { try model.clearDeletedList(preview) }
                catch { historyClearError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { preview in
            Text("Remove \(preview.recordCount) records from the ASM Deleted list, including older records without completion reports. No Codex conversations or backup files will be changed. Operation reports and recovery evidence remain stored separately; this is not erasure of all ASM data. Removed records stay out of this list after refresh or restart.")
        }
        .alert("Clear completed history?", isPresented: Binding(
            get: { historyClearPreview != nil }, set: { if !$0 { historyClearPreview = nil } }
        ), presenting: historyClearPreview) { preview in
            Button("Clear Records", role: .destructive) {
                do { try model.clearCompletedHistory(preview) }
                catch { historyClearError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { preview in
            Text("This removes \(preview.deletedRecordCount) Deleted records, \(preview.reportCount) reports and \(preview.ghostOperationCount) completed cleanup operations from ASM only. \(preview.keptRecordCount) Deleted records are kept because completion cannot be verified or the full batch is not selected. No Codex conversations or backup files are changed. Minimal replay-prevention markers are retained. This cannot be undone from this list.")
        }
        .alert("History was kept", isPresented: Binding(
            get: { historyClearError != nil }, set: { if !$0 { historyClearError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(historyClearError ?? "") }
        .overlay {
            if model.filteredSessions.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    Label(model.hasSessionSearch ? "No Matching Records" : "No Sessions",
                          systemImage: model.hasSessionSearch ? "magnifyingglass" : "tray")
                } description: {
                    Text(model.hasSessionSearch
                         ? "No records match your search in this view. Clear the search or adjust the filters."
                         : "No records are shown with the current filters.")
                } actions: {
                    if model.hasSessionSearch {
                        Button("Clear Search") { model.clearSessionSearch() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deletedHistoryBar: some View {
        if model.selectedFilter == .deleted {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("List removal does not change Codex data. Completed operation history is cleaned after 30 days; recovery evidence is kept.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Selected Records…") { prepareDeletedListClear(selectedOnly: true) }
                        .disabled(model.selection.isEmpty || model.isLoading)
                    Button("Clear All List Records") { prepareDeletedListClear(selectedOnly: false) }
                        .disabled(model.isLoading)
                }
                Button("Clear Completed Operation History…") { prepareHistoryClear(selectedOnly: false) }
                    .disabled(model.isLoading)
                if let notice = model.completedHistoryNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func prepareDeletedListClear(selectedOnly: Bool) {
        do {
            let preview = try model.prepareDeletedListClear(selectedOnly: selectedOnly)
            if preview.isEmpty {
                historyClearError = "No Deleted list records match. Refresh the list or select records again."
            } else { deletedListClearPreview = preview }
        } catch { historyClearError = error.localizedDescription }
    }

    private func prepareHistoryClear(selectedOnly: Bool) {
        do {
            let preview = try model.prepareCompletedHistoryClear(selectedOnly: selectedOnly)
            if preview.isEmpty {
                historyClearError = "No safely completed records can be cleared. Pending, unknown, legacy/unverified records and partially selected batches are kept."
            } else { historyClearPreview = preview }
        } catch { historyClearError = error.localizedDescription }
    }

    @ViewBuilder
    private var filteredSelectionBar: some View {
        if model.showsFilteredSelectionControls {
            HStack(spacing: 10) {
                TriStateCheckbox(
                    state: model.filteredSelectionState,
                    label: model.hasSessionSearch ? "Select all search results" : "Select all filtered",
                    isEnabled: model.canToggleFilteredSelection
                ) {
                    model.toggleFilteredSelection()
                }
                .fixedSize(horizontal: true, vertical: true)
                .help("Select or deselect only the currently shown results. Selections outside this view are kept.")
                Text("\(model.filteredSessions.count) shown")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.selection.count) selected · \(model.visibleSelectionCount) shown")
                    .fontWeight(.medium)
                if !model.selection.isEmpty {
                    selectedOnlyToggle
                    Button("Clear Selection") {
                        model.clearSelection()
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.caption)
            .frame(height: 22)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var selectionSummary: some View {
        if !model.selection.isEmpty, !model.showsFilteredSelectionControls {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.square.fill")
                    .foregroundStyle(Color.accentColor)
                Text("\(model.selection.count) selected · \(model.visibleSelectionCount) shown")
                    .fontWeight(.medium)
                Spacer()
                selectedOnlyToggle
                Button("Clear Selection") {
                    model.clearSelection()
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var selectedOnlyToggle: some View {
        Toggle("Show Selected Only", isOn: $model.isShowingSelectedSessionsOnly)
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Filter the table to sessions that are currently checked")
    }

    private var liveBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
            Text("Codex live — Archive is evidence-gated; Archive Restore is Preview-first")
                .fontWeight(.medium)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(Color.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.09))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            operationToolbarButton(.archive)

            operationToolbarButton(.moveToTrash)
            operationToolbarButton(.restore)
            operationToolbarButton(.moveToArchive)
            operationToolbarButton(.emptyTrash)

            HoverHelpButton(
                label: "Refresh",
                symbol: "arrow.clockwise",
                disabled: model.isLoading,
                helpText: model.isLoading
                    ? "A session refresh is already in progress."
                    : "Refresh the current session data source"
            ) {
                Task { await model.reload() }
            }

            HoverHelpButton(
                label: "Report History",
                symbol: "clock.arrow.circlepath",
                disabled: model.reportHistoryUnavailableReason != nil,
                helpText: model.reportHistoryUnavailableReason
                    ?? "Open manager-owned operation Report history"
            ) {
                model.isReportHistoryPresented = true
            }

            HoverHelpButton(
                label: "Maintenance",
                symbol: "externaldrive.badge.timemachine",
                disabled: model.maintenanceUnavailableReason != nil,
                helpText: model.maintenanceUnavailableReason
                    ?? "Inspect manager-owned SQLite backups and reclaimable pages"
            ) {
                model.isMaintenancePresented = true
            }
        }
    }

    private func operationToolbarButton(_ operation: SessionOperation) -> some View {
        HoverHelpButton(
            label: operation.label,
            symbol: operation.symbol,
            role: operation.isDestructive ? .destructive : nil,
            disabled: !model.canRequestPreview(operation),
            helpText: model.blockedReason(for: operation) ?? "Preview \(operation.label)"
        ) {
            Task { await model.requestPreview(operation) }
        }
    }

    @ViewBuilder
    private func sessionContextMenu(managerKeys: Set<String>) -> some View {
        if managerKeys.isEmpty {
            Text("No session selected")
        } else {
            contextOperationButton(.archive, managerKeys: managerKeys)

            contextOperationButton(.moveToTrash, managerKeys: managerKeys)
            contextOperationButton(.restore, managerKeys: managerKeys)
            contextOperationButton(.moveToArchive, managerKeys: managerKeys)
            Divider()
            contextOperationButton(.emptyTrash, managerKeys: managerKeys)
        }
    }

    private func contextOperationButton(
        _ operation: SessionOperation,
        managerKeys: Set<String>
    ) -> some View {
        Button(role: operation.isDestructive ? .destructive : nil) {
            model.selection = managerKeys
            Task { await model.requestPreview(operation) }
        } label: {
            Label(operation.label, systemImage: operation.symbol)
        }
        .disabled(model.blockedReason(for: operation, managerKeys: managerKeys) != nil)
    }

    private func color(for state: SessionDisplayState) -> Color {
        switch state {
        case .active: .green
        case .archive: .blue
        case .trash: .orange
        case .deleted: .red
        case .conflict, .externallyMissing: .red
        case .unavailable: .secondary
        }
    }
}

private struct SessionIdentityCell: View {
    @ObservedObject var model: SessionManagerModel
    let session: SessionPresentation

    var body: some View {
        HStack(spacing: 10) {
            SessionSelectionCheckbox(model: model, session: session)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if session.protection.isPinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Text(session.nativeID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                if let source = session.liveSession?.supplementalSourceLabel {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Officially readable by ID, but omitted from the official list because its preview is empty.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

private struct SessionSelectionCheckbox: View {
    @ObservedObject var model: SessionManagerModel
    let session: SessionPresentation

    var body: some View {
        Button {
            model.setSelected(
                session.id,
                isSelected: !model.isSelected(session.id)
            )
        } label: {
            Image(systemName: model.isSelected(session.id) ? "checkmark.square.fill" : "square")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(
                    model.isSelected(session.id) ? Color.accentColor : Color.secondary
                )
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .accessibilityLabel("Select \(session.title)")
        .accessibilityValue(model.isSelected(session.id) ? "Selected" : "Not selected")
        .help(
            model.isSelected(session.id)
                ? "Remove this session from the selection"
                : "Add this session to the selection"
        )
    }
}

private struct TriStateCheckbox: NSViewRepresentable {
    let state: FilteredSelectionState
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: label,
            target: context.coordinator,
            action: #selector(Coordinator.activate)
        )
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = label
        button.isEnabled = isEnabled
        switch state {
        case .none: button.state = .off
        case .partial: button.state = .mixed
        case .all: button.state = .on
        }
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func activate() {
            action()
        }
    }
}

/// SwiftUI exposes initial TableColumn widths but no binding for widths after
/// the user drags a header divider. This zero-impact AppKit probe observes the
/// concrete NSTableView and persists its five fixed-order column widths.
private struct TableColumnWidthPersistence: NSViewRepresentable {
    let storageKey: String
    let expectedColumnCount: Int

    func makeNSView(context: Context) -> TableColumnWidthProbe {
        TableColumnWidthProbe(
            storageKey: storageKey,
            expectedColumnCount: expectedColumnCount
        )
    }

    func updateNSView(_ probe: TableColumnWidthProbe, context: Context) {
        probe.update(
            storageKey: storageKey,
            expectedColumnCount: expectedColumnCount
        )
    }
}

private final class TableColumnWidthProbe: NSView {
    private var storageKey: String
    private var expectedColumnCount: Int
    private weak var observedTable: NSTableView?
    private var resizeObserver: NSObjectProtocol?
    private var eventMonitor: Any?
    private var configurationScheduled = false
    private var restoreScheduled = false
    private var initialCaptureScheduled = false
    private var isApplyingWidths = false
    private var isTrackingHeaderInteraction = false
    private var desiredWidths: [CGFloat]?
    private weak var headerInteractionTable: NSTableView?
    private weak var pendingRestoreTable: NSTableView?
    private var headerTrackingTimer: Timer?
    private var headerTrackingStartedAt: Date?
    private var lastTrackedWidths: [CGFloat]?

    init(storageKey: String, expectedColumnCount: Int) {
        self.storageKey = storageKey
        self.expectedColumnCount = expectedColumnCount
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        headerTrackingTimer?.invalidate()
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    override func layout() {
        super.layout()
        scheduleConfiguration()
    }

    func update(storageKey: String, expectedColumnCount: Int) {
        let identityChanged = self.storageKey != storageKey
            || self.expectedColumnCount != expectedColumnCount
        self.storageKey = storageKey
        self.expectedColumnCount = expectedColumnCount
        if identityChanged {
            stopObserving()
        }
        scheduleConfiguration()
    }

    private func scheduleConfiguration() {
        guard window != nil, !configurationScheduled else { return }
        configurationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.configurationScheduled = false
            self.configureNearestTableIfNeeded()
        }
    }

    private func configureNearestTableIfNeeded() {
        if let observedTable,
           observedTable.window === window,
           observedTable.tableColumns.count == expectedColumnCount {
            return
        }
        guard let contentView = window?.contentView else { return }
        let probeFrame = convert(bounds, to: nil)
        let table = tableViews(in: contentView)
            .filter { $0.tableColumns.count == expectedColumnCount }
            .max { lhs, rhs in
                intersectionArea(lhs.convert(lhs.bounds, to: nil), probeFrame)
                    < intersectionArea(rhs.convert(rhs.bounds, to: nil), probeFrame)
            }
        guard let table else { return }
        guard observedTable !== table else { return }

        stopObserving()
        observedTable = table
        desiredWidths = persistedWidths()
        scheduleRestore(on: table)
        scheduleInitialCaptureIfNeeded(on: table)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let resizedTable = notification.object as? NSTableView,
                  self.isCandidateTable(resizedTable),
                  !self.isApplyingWidths else { return }
            self.observedTable = resizedTable
            if self.isUserDrivenResize(of: resizedTable) {
                self.saveWidths(from: resizedTable)
            } else {
                self.scheduleRestore(on: resizedTable)
            }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    private func persistedWidths() -> [CGFloat]? {
        guard let storedValues = UserDefaults.standard.array(forKey: storageKey) else {
            return nil
        }
        // V1 originally stored a dedicated checkbox column. When that column
        // is merged into Session, retain the five user-sized data columns by
        // discarding only the obsolete leading width.
        let values: [Any]
        if storedValues.count == expectedColumnCount {
            values = storedValues
        } else if storedValues.count == expectedColumnCount + 1 {
            values = Array(storedValues.dropFirst())
        } else {
            return nil
        }
        let widths = values.compactMap { value -> CGFloat? in
            if let number = value as? NSNumber {
                return CGFloat(number.doubleValue)
            }
            if let double = value as? Double {
                return CGFloat(double)
            }
            if let integer = value as? Int {
                return CGFloat(integer)
            }
            return nil
        }
        guard widths.count == expectedColumnCount else { return nil }
        if storedValues.count != expectedColumnCount {
            UserDefaults.standard.set(
                widths.map { NSNumber(value: Double($0)) },
                forKey: storageKey
            )
        }
        return widths
    }

    private func scheduleRestore(on table: NSTableView) {
        guard desiredWidths != nil,
              !isApplyingWidths else { return }
        pendingRestoreTable = table
        guard !restoreScheduled else { return }
        restoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreScheduled = false
            guard let table = self.pendingRestoreTable,
                  !self.isTrackingHeaderInteraction else { return }
            self.restoreWidths(on: table)
        }
    }

    private func restoreWidths(on table: NSTableView) {
        guard let desiredWidths,
              desiredWidths.count == expectedColumnCount,
              table.tableColumns.count == expectedColumnCount else { return }
        // Compare against attainable widths so a previously wider Size column
        // does not trigger another restore on every layout pass.
        let targetWidths = zip(table.tableColumns, desiredWidths).map { column, width in
            let maximum = column.maxWidth > 0 ? column.maxWidth : .greatestFiniteMagnitude
            return min(max(width, column.minWidth), maximum)
        }
        let alreadyRestored = zip(table.tableColumns, targetWidths).allSatisfy {
            abs($0.width - $1) < 0.5
        }
        guard !alreadyRestored else { return }

        isApplyingWidths = true
        for (column, width) in zip(table.tableColumns, targetWidths) {
            column.width = width
        }
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingWidths = false
        }
    }

    private func scheduleInitialCaptureIfNeeded(on table: NSTableView) {
        guard desiredWidths == nil, !initialCaptureScheduled else { return }
        initialCaptureScheduled = true
        DispatchQueue.main.async { [weak self, weak table] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.initialCaptureScheduled = false
                guard let table,
                      table === self.observedTable,
                      self.desiredWidths == nil else { return }
                self.saveWidths(from: table)
            }
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard event.window === window,
                  let contentView = event.window?.contentView,
                  let hitView = contentView.hitTest(event.locationInWindow),
                  let headerView = nearestTableHeader(from: hitView),
                  let table = headerView.tableView,
                  isCandidateTable(table) else {
                isTrackingHeaderInteraction = false
                headerInteractionTable = nil
                return
            }
            observedTable = table
            headerInteractionTable = table
            isTrackingHeaderInteraction = true
            beginHeaderWidthTracking(on: table)

        case .leftMouseUp:
            guard isTrackingHeaderInteraction,
                  let table = headerInteractionTable else { return }
            isTrackingHeaderInteraction = false
            headerInteractionTable = nil
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self, let table,
                      self.isCandidateTable(table) else { return }
                self.observedTable = table
                self.saveWidths(from: table)
            }

        default:
            break
        }
    }

    private func isUserDrivenResize(of table: NSTableView) -> Bool {
        if isTrackingHeaderInteraction, headerInteractionTable === table {
            return true
        }
        guard NSApp.currentEvent?.window === table.window else { return false }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return true
        default:
            return false
        }
    }

    private func beginHeaderWidthTracking(on table: NSTableView) {
        headerTrackingTimer?.invalidate()
        headerInteractionTable = table
        headerTrackingStartedAt = Date()
        lastTrackedWidths = table.tableColumns.map(\.width)

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak table] _ in
            guard let self, let table,
                  self.isCandidateTable(table) else {
                self?.finishHeaderWidthTracking()
                return
            }

            let widths = table.tableColumns.map(\.width)
            if let lastTrackedWidths = self.lastTrackedWidths,
               !self.widthsMatch(widths, lastTrackedWidths) {
                self.saveWidths(from: table)
                self.lastTrackedWidths = widths
            }

            let buttonIsDown = CGEventSource.buttonState(
                .combinedSessionState,
                button: .left
            )
            let timedOut = self.headerTrackingStartedAt.map {
                Date().timeIntervalSince($0) > 15
            } ?? true
            if !buttonIsDown || timedOut {
                self.finishHeaderWidthTracking()
            }
        }
        headerTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishHeaderWidthTracking() {
        headerTrackingTimer?.invalidate()
        headerTrackingTimer = nil
        headerTrackingStartedAt = nil
        lastTrackedWidths = nil
        isTrackingHeaderInteraction = false
        headerInteractionTable = nil
    }

    private func widthsMatch(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.5 }
    }

    private func isCandidateTable(_ table: NSTableView) -> Bool {
        guard table.window === window,
              table.tableColumns.count == expectedColumnCount,
              table.bounds.width > 0,
              table.bounds.height > 0 else { return false }
        var view: NSView? = table
        while let current = view {
            if current.isHidden { return false }
            view = current.superview
        }
        return true
    }

    private func nearestTableHeader(from view: NSView) -> NSTableHeaderView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let headerView = current as? NSTableHeaderView {
                return headerView
            }
            candidate = current.superview
        }
        return nil
    }

    private func saveWidths(from table: NSTableView) {
        guard table.tableColumns.count == expectedColumnCount else { return }
        let widths = table.tableColumns.map(\.width)
        desiredWidths = widths
        UserDefaults.standard.set(
            widths.map { NSNumber(value: Double($0)) },
            forKey: storageKey
        )
    }

    private func stopObserving() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        restoreScheduled = false
        initialCaptureScheduled = false
        isApplyingWidths = false
        isTrackingHeaderInteraction = false
        headerTrackingTimer?.invalidate()
        headerTrackingTimer = nil
        headerTrackingStartedAt = nil
        lastTrackedWidths = nil
        headerInteractionTable = nil
        pendingRestoreTable = nil
        observedTable = nil
    }

    private func tableViews(in view: NSView) -> [NSTableView] {
        var result: [NSTableView] = []
        if let table = view as? NSTableView {
            result.append(table)
        }
        for subview in view.subviews {
            result.append(contentsOf: tableViews(in: subview))
        }
        return result
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

private struct HoverHelpButton: View {
    let label: String
    let symbol: String
    var role: ButtonRole?
    let disabled: Bool
    let helpText: String
    let action: () -> Void

    init(
        label: String,
        symbol: String,
        role: ButtonRole? = nil,
        disabled: Bool,
        helpText: String,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.symbol = symbol
        self.role = role
        self.disabled = disabled
        self.helpText = helpText
        self.action = action
    }

    var body: some View {
        ZStack {
            Button(role: role) {
                action()
            } label: {
                Label(label, systemImage: symbol)
            }
            .disabled(disabled)
        }
        .modifier(
            ToolbarHoverHelpModifier(
                text: "\(label) — \(helpText)"
            )
        )
    }
}

/// Native hover help is reserved for compact toolbar controls whose visible
/// symbol does not explain the action. Large labelled controls use an
/// accessibility hint only, avoiding persistent AppKit help tags that can
/// overlap sheets and Settings content.
private struct ToolbarHoverHelpModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .help(text)
            .accessibilityHint(text)
    }
}

private struct ImmediateHelpModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
    }
}

extension View {
    func immediateHelp(_ text: String) -> some View {
        modifier(ImmediateHelpModifier(text: text))
    }
}
