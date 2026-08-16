import AgentSessionManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct AgentSessionManagerSettingsView: View {
    @EnvironmentObject private var model: SessionManagerModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .environmentObject(model)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            DiagnosticLogsSettingsView()
                .environmentObject(model)
                .tabItem {
                    Label("Logs", systemImage: "list.bullet.rectangle")
                }
        }
        .frame(width: 940, height: 640)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: SessionManagerModel

    private var logPolicy: DiagnosticLogRetentionPolicy {
        model.diagnosticLogSnapshot.retentionPolicy
    }

    var body: some View {
        Form {
            if let warning = model.diagnosticLogPersistenceWarning {
                Section("Warning") {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            Section("Retention") {
                LabeledContent("Report History") {
                    Text("Latest \(OperationHistoryRetentionPolicy.production.maximumReportsPerProvider) reports per provider")
                }
                Text(
                    "Reports are authoritative lifecycle audit bundles. Pruning never changes Trash, Deleted tombstones, checkpoints, pending operations, or Codex sessions."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("Diagnostic Logs") {
                    Text(
                        "\(logPolicy.maximumEvents.formatted()) events · \(days(logPolicy.maximumAge)) days · \(bytes(logPolicy.maximumBytes))"
                    )
                }
                Text(
                    "The oldest events are removed when any limit is reached. Logs are diagnostic and are not lifecycle outcome authority."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Label(
                    "Logs exclude conversation content, confirmation tokens, prompts, request payloads, and message bodies.",
                    systemImage: "hand.raised"
                )
                Text("Full native session IDs, operation IDs, outcomes, and bounded error descriptions may be retained for diagnosis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Diagnostic Log file") {
                    Text(model.diagnosticLogFileURL?.path ?? "In-memory fallback")
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }

    private func days(_ interval: TimeInterval) -> Int {
        Int(interval / (24 * 60 * 60))
    }

    private func bytes(_ count: Int) -> String {
        if count.isMultiple(of: 1_024 * 1_024) {
            return "\(count / (1_024 * 1_024)) MB"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

private struct DiagnosticLogsSettingsView: View {
    @EnvironmentObject private var model: SessionManagerModel

    @State private var selectedLevel: DiagnosticLogLevel?
    @State private var selectedCategory: DiagnosticLogCategory?
    @State private var searchText = ""
    @State private var selectedEventID: UUID?
    @State private var exportDocument: DiagnosticLogFileDocument?
    @State private var isExporting = false
    @State private var localError: String?

    private var filteredEvents: [DiagnosticEvent] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.diagnosticLogSnapshot.events.filter { event in
            let levelMatches = selectedLevel == nil || event.level == selectedLevel
            let categoryMatches = selectedCategory == nil || event.category == selectedCategory
            let searchMatches = needle.isEmpty
                || event.message.localizedCaseInsensitiveContains(needle)
                || event.id.uuidString.localizedCaseInsensitiveContains(needle)
                || event.metadata.contains { key, value in
                    key.localizedCaseInsensitiveContains(needle)
                        || value.localizedCaseInsensitiveContains(needle)
                }
            return levelMatches && categoryMatches && searchMatches
        }
    }

    private var selectedEvent: DiagnosticEvent? {
        guard let selectedEventID else { return nil }
        return model.diagnosticLogSnapshot.events.first { $0.id == selectedEventID }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            Table(filteredEvents, selection: $selectedEventID) {
                TableColumn("Time") { event in
                    Text(event.timestamp, format: .dateTime.month().day().hour().minute().second())
                        .monospacedDigit()
                }
                .width(min: 145, ideal: 165)

                TableColumn("Level") { event in
                    Label(event.level.label, systemImage: levelSymbol(event.level))
                        .foregroundStyle(levelColor(event.level))
                }
                .width(min: 90, ideal: 105)

                TableColumn("Category") { event in
                    Text(event.category.label)
                }
                .width(min: 90, ideal: 110)

                TableColumn("Event") { event in
                    Text(event.message)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 280)

            Divider()
            eventDetail
                .frame(height: 190)
        }
        .task {
            await model.refreshDiagnosticLogs()
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: DiagnosticLogFileDocument.contentType,
            defaultFilename: "agent-session-manager-diagnostics-\(Self.filenameDate.string(from: Date())).jsonl"
        ) { result in
            if case let .failure(error) = result {
                localError = error.localizedDescription
            }
        }
        .alert(
            "Diagnostic Logs",
            isPresented: Binding(
                get: { localError != nil },
                set: { if !$0 { localError = nil } }
            )
        ) {
            Button("OK") { localError = nil }
        } message: {
            Text(localError ?? "Unknown error")
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let warning = model.diagnosticLogPersistenceWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 12) {
                Picker("Level", selection: $selectedLevel) {
                    Text("All Levels").tag(nil as DiagnosticLogLevel?)
                    ForEach(DiagnosticLogLevel.allCases) { level in
                        Text(level.label).tag(Optional(level))
                    }
                }
                .frame(width: 160)

                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories").tag(nil as DiagnosticLogCategory?)
                    ForEach(DiagnosticLogCategory.allCases) { category in
                        Text(category.label).tag(Optional(category))
                    }
                }
                .frame(width: 180)

                TextField("Search events, IDs, or details", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await model.refreshDiagnosticLogs() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .immediateHelp("Reload retained diagnostic events")

                Button {
                    Task { await prepareExport() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.diagnosticLogSnapshot.events.isEmpty)
                .immediateHelp("Export all retained diagnostic events as JSONL")
            }

            HStack {
                Text("\(filteredEvents.count.formatted()) shown")
                Text("·")
                Text("\(model.diagnosticLogSnapshot.events.count.formatted()) retained")
                Text("·")
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(model.diagnosticLogSnapshot.fileByteCount),
                    countStyle: .file
                ))
                Spacer()
                Text(retentionSummary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = model.diagnosticLogErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var eventDetail: some View {
        if let event = selectedEvent {
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.message)
                            .font(.headline)
                            .textSelection(.enabled)
                        detailRow("Event ID", event.id.uuidString)
                        detailRow("Timestamp", event.timestamp.formatted(.iso8601))
                        detailRow("Level", event.level.label)
                        detailRow("Category", event.category.label)
                        ForEach(event.metadata.keys.sorted(), id: \.self) { key in
                            detailRow(key, event.metadata[key] ?? "")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                PasteboardCopyButton(
                    text: formatted(event),
                    help: "Copy this diagnostic event"
                )
            }
            .padding(14)
        } else {
            ContentUnavailableView(
                "Select a Log Event",
                systemImage: "list.bullet.rectangle",
                description: Text("The event ID and bounded diagnostic details will appear here.")
            )
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    private func formatted(_ event: DiagnosticEvent) -> String {
        var lines = [
            "Timestamp: \(event.timestamp.formatted(.iso8601))",
            "Level: \(event.level.label)",
            "Category: \(event.category.label)",
            "Event ID: \(event.id.uuidString)",
            "Message: \(event.message)",
        ]
        for key in event.metadata.keys.sorted() {
            lines.append("\(key): \(event.metadata[key] ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    private var retentionSummary: String {
        let policy = model.diagnosticLogSnapshot.retentionPolicy
        let days = Int(policy.maximumAge / (24 * 60 * 60))
        let maximumBytes = policy.maximumBytes.isMultiple(of: 1_024 * 1_024)
            ? "\(policy.maximumBytes / (1_024 * 1_024)) MB"
            : ByteCountFormatter.string(
                fromByteCount: Int64(policy.maximumBytes),
                countStyle: .file
            )
        return "\(days) days · \(policy.maximumEvents.formatted()) events · \(maximumBytes) maximum"
    }

    @MainActor
    private func prepareExport() async {
        do {
            exportDocument = DiagnosticLogFileDocument(
                data: try await model.exportDiagnosticLogs()
            )
            isExporting = true
        } catch {
            localError = error.localizedDescription
        }
    }

    private func levelSymbol(_ level: DiagnosticLogLevel) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func levelColor(_ level: DiagnosticLogLevel) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
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

private struct DiagnosticLogFileDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "jsonl") ?? .plainText
    static var readableContentTypes: [UTType] { [contentType] }

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
