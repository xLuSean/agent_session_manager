import AgentSessionManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct ReportHistoryView: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [OperationHistoryEntry] = []
    @State private var nextCursor: OperationHistoryCursor?
    @State private var selectedReportID: UUID?
    @State private var selectedProvider: AgentSystem?
    @State private var selectedOperation: PersistentOperation?
    @State private var selectedOutcome: PersistentReportOutcome?
    @State private var searchText = ""
    @State private var usesStartDate = false
    @State private var usesEndDate = false
    @State private var startDate = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    @State private var endDate = Date()
    @State private var isWorking = false
    @State private var localError: String?
    @State private var statusMessage: String?
    @State private var exportDocument: ReportHistoryFileDocument?
    @State private var exportType: UTType = .json
    @State private var exportFilename = "agent-session-manager-reports"
    @State private var isFileExporterPresented = false
    @State private var clearPreview: ReportHistoryClearPreview?

    private let pageSize = 50

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let reason = model.reportHistoryUnavailableReason {
                ContentUnavailableView(
                    "Report History Unavailable",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(reason)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                filters
                Divider()
                historyContent
                Divider()
                footer
            }
        }
        .frame(minWidth: 980, idealWidth: 1_100, minHeight: 650, idealHeight: 720)
        .task {
            guard model.reportHistoryUnavailableReason == nil else { return }
            await loadFirstPage()
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case let .success(url):
                statusMessage = "Exported \(url.lastPathComponent) with private-default redaction."
            case let .failure(error):
                localError = error.localizedDescription
            }
        }
        .sheet(item: $clearPreview) { preview in
            ReportHistoryClearConfirmationSheet(preview: preview) { token in
                Task { await clearConfirmed(preview, confirmationToken: token) }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Report History")
                    .font(.title2.weight(.semibold))
                Text(model.reportHistorySourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear Filtered Reports…", role: .destructive) {
                Task { await prepareClear() }
            }
            .disabled(entries.isEmpty || isWorking)
            .immediateHelp(
                entries.isEmpty
                    ? "No reports are currently displayed."
                    : "Delete reports matching the filter settings below. You’ll review the exact number before anything is deleted."
            )
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .immediateHelp("Close Report History")
        }
        .padding(16)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Provider", selection: $selectedProvider) {
                    Text("All Providers").tag(nil as AgentSystem?)
                    ForEach(AgentSystem.allCases) { provider in
                        Text(provider.label).tag(Optional(provider))
                    }
                }
                .frame(width: 190)

                Picker("Operation", selection: $selectedOperation) {
                    Text("All Operations").tag(nil as PersistentOperation?)
                    ForEach(PersistentOperation.allCases, id: \.rawValue) { operation in
                        Text(operation.historyLabel).tag(Optional(operation))
                    }
                }
                .frame(width: 200)

                Picker("Outcome", selection: $selectedOutcome) {
                    Text("All Outcomes").tag(nil as PersistentReportOutcome?)
                    ForEach(PersistentReportOutcome.allCases, id: \.rawValue) { outcome in
                        Text(outcome.historyLabel).tag(Optional(outcome))
                    }
                }
                .frame(width: 180)

                TextField("Report ID, session ID, title, project, or error code", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await loadFirstPage() } }

                Button("Apply") {
                    Task { await loadFirstPage() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
                .immediateHelp("Apply the current Report History filters")
            }

            HStack(spacing: 12) {
                Toggle("From", isOn: $usesStartDate)
                DatePicker(
                    "",
                    selection: $startDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .disabled(!usesStartDate)

                Toggle("Through", isOn: $usesEndDate)
                DatePicker(
                    "",
                    selection: $endDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .disabled(!usesEndDate)

                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading manager SQLite…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private var historyContent: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedReportID) {
                    ForEach(entries, id: \.reportID) { entry in
                        reportRow(entry)
                            .tag(entry.reportID)
                    }
                }
                .overlay {
                    if entries.isEmpty && !isWorking {
                        ContentUnavailableView(
                            "No Reports",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("No committed manager reports match these filters.")
                        )
                    }
                }

                if nextCursor != nil {
                    Divider()
                    Button("Load More") {
                        Task { await loadNextPage() }
                    }
                    .disabled(isWorking)
                    .immediateHelp("Load the next page of matching Reports")
                    .padding(8)
                }
            }
            .frame(minWidth: 350, idealWidth: 420)

            reportDetail
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reportRow(_ entry: OperationHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(entry.operation.historyLabel, systemImage: entry.operation.historySymbol)
                    .fontWeight(.medium)
                Spacer()
                Text(entry.outcome.historyLabel)
                    .foregroundStyle(entry.outcome.historyColor)
            }
            Text(entry.reportID.uuidString.lowercased())
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(entry.itemCount) items · \(entry.completedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var reportDetail: some View {
        if let report = selectedReport {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detailSection("Report") {
                        detailRow("Report ID", report.reportID.uuidString.lowercased(), monospaced: true)
                        detailRow("Preview ID", report.previewID.uuidString.lowercased(), monospaced: true)
                        detailRow("Provider", report.provider.label)
                        detailRow("Operation", report.operation.historyLabel)
                        detailRow("Outcome", report.outcome.historyLabel)
                        detailRow("Started", report.startedAt.formatted(date: .abbreviated, time: .standard))
                        detailRow("Completed", report.completedAt.formatted(date: .abbreviated, time: .standard))
                    }

                    detailSection("Summary") {
                        detailRow("Items", "\(report.itemCount)")
                        detailRow("Success / Failure / Unknown", "\(report.successCount) / \(report.failureCount) / \(report.unknownCount)")
                        detailRow(
                            "Verified released bytes",
                            ByteCountFormatter.string(fromByteCount: report.verifiedReleasedBytes, countStyle: .file)
                        )
                        detailRow("Released bytes complete", report.releasedBytesComplete ? "Yes" : "No")
                        if let errorCode = report.errorCode {
                            detailRow("Error code", errorCode, monospaced: true)
                        }
                        if let errorMessage = report.errorMessage {
                            detailRow("Error message", errorMessage)
                        }
                    }

                    detailSection("Items") {
                        ForEach(report.items, id: \.managerKey) { item in
                            itemCard(item)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Select a Report",
                systemImage: "doc.text",
                description: Text("Full native session IDs and itemized readback evidence appear here.")
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label(
                "Exports keep full native IDs but omit titles, project IDs, free-text errors, paths, hashes, and conversation content.",
                systemImage: "hand.raised.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            if let localError {
                Text(localError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Export JSON") {
                Task { await prepareExport(.json) }
            }
            .disabled(entries.isEmpty || isWorking)
            .immediateHelp("Export all Reports matching the current filters as private-default JSON")
            Button("Export CSV") {
                Task { await prepareExport(.csv) }
            }
            .disabled(entries.isEmpty || isWorking)
            .immediateHelp("Export all Reports matching the current filters as private-default CSV")
        }
        .padding(12)
    }

    private var selectedReport: OperationHistoryEntry? {
        guard let selectedReportID else { return nil }
        return entries.first { $0.reportID == selectedReportID }
    }

    private func itemCard(_ item: OperationHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.sessionTitle)
                .fontWeight(.medium)
                .textSelection(.enabled)
            detailRow("Native session ID", item.nativeSessionID, monospaced: true)
            if let projectID = item.projectID {
                detailRow("Project ID", projectID, monospaced: true)
            }
            detailRow("Expected → observed", "\(item.expectedNativeState.rawValue) → \(item.observedNativeState.rawValue)")
            detailRow("Outcome", item.outcome.rawValue.capitalized)
            detailRow("Evidence", item.evidenceAt.formatted(date: .abbreviated, time: .standard))
            if let errorCode = item.errorCode {
                detailRow("Error code", errorCode, monospaced: true)
            }
            if let errorMessage = item.errorMessage {
                detailRow("Error message", errorMessage)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .textSelection(.enabled)
        }
    }

    private func query(
        cursor: OperationHistoryCursor? = nil,
        limit: Int
    ) -> OperationHistoryQuery {
        OperationHistoryQuery(
            provider: selectedProvider,
            operation: selectedOperation,
            outcome: selectedOutcome,
            searchText: searchText,
            completedFrom: usesStartDate ? startDate : nil,
            completedThrough: usesEndDate ? endDate : nil,
            cursor: cursor,
            limit: limit
        )
    }

    @MainActor
    private func loadFirstPage() async {
        isWorking = true
        localError = nil
        statusMessage = nil
        defer { isWorking = false }
        await Task.yield()
        do {
            let page = try model.operationHistoryPage(query(limit: pageSize))
            entries = page.entries
            nextCursor = page.nextCursor
            selectedReportID = entries.first?.reportID
        } catch {
            entries = []
            nextCursor = nil
            selectedReportID = nil
            localError = error.localizedDescription
        }
    }

    @MainActor
    private func loadNextPage() async {
        guard let nextCursor else { return }
        isWorking = true
        localError = nil
        defer { isWorking = false }
        await Task.yield()
        do {
            let page = try model.operationHistoryPage(
                query(cursor: nextCursor, limit: pageSize)
            )
            let existingIDs = Set(entries.map(\.reportID))
            entries.append(contentsOf: page.entries.filter { !existingIDs.contains($0.reportID) })
            self.nextCursor = page.nextCursor
        } catch {
            localError = error.localizedDescription
        }
    }

    @MainActor
    private func prepareExport(_ kind: ReportHistoryExportKind) async {
        isWorking = true
        localError = nil
        statusMessage = nil
        defer { isWorking = false }
        await Task.yield()
        do {
            let matchingEntries = try model.allOperationHistoryEntries(
                matching: query(limit: OperationHistoryQuery.maximumLimit)
            )
            let data: Data
            switch kind {
            case .json:
                data = try OperationHistoryExporter.json(entries: matchingEntries)
            case .csv:
                data = Data(OperationHistoryExporter.csv(entries: matchingEntries).utf8)
            }
            exportDocument = ReportHistoryFileDocument(data: data)
            exportType = kind.contentType
            exportFilename = "agent-session-manager-reports-\(Self.filenameDate.string(from: Date()))"
            isFileExporterPresented = true
        } catch {
            localError = error.localizedDescription
        }
    }

    @MainActor
    private func prepareClear() async {
        isWorking = true
        localError = nil
        statusMessage = nil
        defer { isWorking = false }
        await Task.yield()
        do {
            let matchingEntries = try model.allOperationHistoryEntries(
                matching: query(limit: OperationHistoryQuery.maximumLimit)
            )
            guard !matchingEntries.isEmpty else {
                statusMessage = "No Reports match the current filters."
                return
            }
            let providers = Set(matchingEntries.map(\.provider))
            guard providers.count == 1 else {
                localError = "Narrow the filters to one Provider before clearing Live Report history."
                return
            }
            clearPreview = ReportHistoryClearPreview(
                reportIDs: Set(matchingEntries.map(\.reportID)),
                provider: providers.first,
                confirmationToken: "CLEAR-REPORTS-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
            )
        } catch {
            localError = error.localizedDescription
        }
    }

    @MainActor
    private func clearConfirmed(
        _ preview: ReportHistoryClearPreview,
        confirmationToken: String
    ) async {
        isWorking = true
        localError = nil
        statusMessage = nil
        defer { isWorking = false }
        await Task.yield()
        do {
            let deleted = try model.clearOperationHistory(
                reportIDs: preview.reportIDs,
                provider: preview.provider,
                confirmationToken: confirmationToken,
                expectedConfirmationToken: preview.confirmationToken
            )
            let page = try model.operationHistoryPage(query(limit: pageSize))
            entries = page.entries
            nextCursor = page.nextCursor
            selectedReportID = entries.first?.reportID
            statusMessage = "Cleared \(deleted) Reports; manager state and Codex sessions were unchanged."
        } catch {
            localError = error.localizedDescription
        }
    }

    private static let filenameDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct ReportHistoryClearPreview: Identifiable {
    let id = UUID()
    let reportIDs: Set<UUID>
    let provider: AgentSystem?
    let confirmationToken: String
}

private struct ReportHistoryClearConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: ReportHistoryClearPreview
    let onConfirm: (String) -> Void
    @State private var typedToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Clear Report History", systemImage: "trash.slash.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)

            Text(
                "This permanently removes exactly \(preview.reportIDs.count) Reports matched when this Preview was created, plus their consumed Previews."
            )

            Label(
                "Trash membership, checkpoints, pending operations, and Codex sessions are not changed.",
                systemImage: "checkmark.shield"
            )
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "Action required: enter the confirmation token",
                    systemImage: "keyboard.badge.ellipsis"
                )
                .font(.title3.weight(.bold))
                .foregroundStyle(.red)

                ConfirmationTokenDisplay(token: preview.confirmationToken)

                TextField("Paste or type the token here", text: $typedToken)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.red.opacity(0.45), lineWidth: 1)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .immediateHelp("Cancel without clearing Report history")
                Spacer()
                Button("Clear \(preview.reportIDs.count) Reports", role: .destructive) {
                    onConfirm(typedToken)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(typedToken != preview.confirmationToken)
                .immediateHelp(
                    typedToken == preview.confirmationToken
                        ? "Clear the exact frozen Report set"
                        : "Enter the exact confirmation token above to enable clearing"
                )
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 390)
    }
}

private enum ReportHistoryExportKind {
    case json
    case csv

    var contentType: UTType {
        switch self {
        case .json: .json
        case .csv: .commaSeparatedText
        }
    }
}

private struct ReportHistoryFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension PersistentOperation {
    var historyLabel: String {
        switch self {
        case .archive: "Archive"
        case .moveToTrash: "Move to Trash"
        case .restore: "Restore"
        case .moveToArchive: "Move to Archive"
        case .permanentlyDelete: "Delete Permanently"
        }
    }

    var historySymbol: String {
        switch self {
        case .archive: "archivebox"
        case .moveToTrash: "trash"
        case .restore: "arrow.uturn.backward"
        case .moveToArchive: "archivebox.fill"
        case .permanentlyDelete: "trash.slash"
        }
    }
}

private extension PersistentReportOutcome {
    var historyLabel: String { rawValue.capitalized }

    var historyColor: Color {
        switch self {
        case .success: .green
        case .warning, .partial: .orange
        case .failure: .red
        case .unknown: .secondary
        }
    }
}
