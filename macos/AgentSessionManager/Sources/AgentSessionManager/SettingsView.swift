import AgentSessionManagerCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct AgentSessionManagerSettingsView: View {
    @EnvironmentObject private var model: SessionManagerModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettingsView()
                .environmentObject(model)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag("general")

            DiagnosticLogsSettingsView()
                .environmentObject(model)
                .tabItem {
                    Label("Logs", systemImage: "list.bullet.rectangle")
                }
                .tag("logs")

            CodexCompatibilitySettingsView()
                .environmentObject(model)
                .tabItem { Label("Compatibility", systemImage: "checkmark.shield") }
                .tag("compatibility")
        }
        .frame(width: 940, height: 640)
        .sheet(isPresented: $model.isGhostRepairSnapshotReadbackPresented) {
            SnapshotReadbackSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isGhostRepairSnapshotCleanupPresented) {
            SnapshotStorageCleanupSheet()
                .environmentObject(model)
        }
    }
}

struct CodexCompatibilitySettingsView: View {
    @EnvironmentObject private var model: SessionManagerModel
    @State private var confirmedFingerprint: String?
    @State private var showsBehaviorConfirmation = false

    private var isUpdating: Bool { model.isCheckingCompatibility || model.isComparingCompatibility }

    private func currentLabel(_ saved: String) -> String {
        CodexCompatibilityPresentation.label(saved: saved, isCurrent: model.compatibilityReportIsCurrent,
            isChecking: model.isCheckingCompatibility, isComparing: model.isComparingCompatibility)
    }

    @ViewBuilder private var checkActivity: some View {
        if model.isCheckingCompatibility {
            HStack {
                ProgressView().controlSize(.small)
                Text(model.compatibilityProgress ?? "Verifying…")
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("compatibilityTestProgress")
        } else if let completion = model.compatibilityCompletionMessage {
            Text(completion).font(.callout).foregroundStyle(.secondary)
        }
        if let error = model.compatibilityCheckError {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
        if model.compatibilityCheckID != nil || model.compatibilityReport?.diagnosticRunID != nil {
            Button("View Diagnostics for This Check") { model.showCompatibilityDiagnostics() }
                .disabled(model.isCheckingCompatibility)
        }
    }

    var body: some View {
        Form {
            Section("Codex compatibility") {
                Text("Check the installed CLI, Desktop runtime and database definitions on this Mac. No network access, upload or session changes.")
                Text("Saved results are reused after restart. Startup only compares the environment; it does not repeat compatibility tests.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Check Compatibility") {
                        Task { await model.checkCodexCompatibility() }
                    }
                    .disabled(model.isCheckingCompatibility || model.isLoading || model.isComparingCompatibility)
                    .accessibilityIdentifier("checkCodexCompatibility")
                    if model.isComparingCompatibility && !model.isCheckingCompatibility {
                        ProgressView().controlSize(.small)
                        Text("Comparing with saved results…").foregroundStyle(.secondary)
                    }
                }
                checkActivity
            }
            if let review = model.compatibilityReview {
                Section("Detected installation") {
                    LabeledContent("ASM's CLI", value: review.providerVersion ?? "Unavailable")
                    LabeledContent("Desktop runtime", value: review.desktopVersion ?? "Unavailable")
                    Text(isUpdating ? "Verification is in progress. This section shows the previously detected installation." : review.isCurrent ? "The environment matches a saved inspection. No tests were rerun at startup."
                         : "This environment does not match a saved inspection. Run Check Compatibility to see which features are supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let report = model.compatibilityReport {
                Section("Last local inspection") {
                    LabeledContent("Interface check", value: report.checkedAt.formatted())
                    LabeledContent("ASM's CLI", value: report.provider.version)
                    LabeledContent("Desktop runtime", value: report.desktop?.version ?? "Unavailable")
                    LabeledContent("Desktop schema", value: report.desktopSchemaProfile ?? "Unknown or changed")
                    if isUpdating {
                        Text("Verification is in progress. Saved results below are for reference until the check finishes.")
                            .foregroundStyle(.secondary)
                    } else if !model.compatibilityReportIsCurrent {
                        Label("This result is not current. Run a new check after Codex finishes updating.", systemImage: "arrow.clockwise")
                            .foregroundStyle(.orange)
                    }
                }
                Section("Desktop application") {
                    if let application = report.desktopApplication {
                        LabeledContent("App version", value: "\(application.version) (\(application.build))")
                        Text(isUpdating ? "Comparing the installation with the saved App identity…" : model.compatibilityReportIsCurrent
                             ? "App executable, sealed resources and embedded code were checked locally. This identifies the installation; it is not behavioral acceptance."
                             : "The saved App identity is no longer current. Run Check Compatibility.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(report.desktop != nil
                             ? "Desktop was found, but its App signature could not be verified. Built-in runtime support is assessed separately; this does not authorize unknown Desktop versions."
                             : "No Desktop runtime was found. ASM checks registered Codex applications as well as Applications. Run Check Compatibility after installation finishes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Feature compatibility") {
                    ForEach(report.results) { result in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(result.feature.label).fontWeight(.medium)
                                Spacer()
                                Text(currentLabel(report.hasVerifiedBehavior(for: result.feature) ? "Verified on this device" : result.status.label))
                                    .foregroundStyle(isUpdating ? Color.secondary : model.compatibilityReportIsCurrent
                                        && (result.status == .supportedByBuild || report.hasVerifiedBehavior(for: result.feature))
                                        ? Color.green : Color.orange)
                            }
                            Text(report.hasVerifiedBehavior(for: result.feature)
                                 ? "Isolated tests passed for this installation. Each operation still checks the current environment and selected sessions."
                                 : result.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Complete Delete requires both official deletion and Desktop cleanup support. An issue with one feature does not disable browsing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let checks = report.databaseChecks {
                    Section("Desktop database checks") {
                        ForEach(checks) { check in
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledContent {
                                    let isCurrentResult = !isUpdating && model.compatibilityReportIsCurrent
                                    Label(currentLabel(check.label), systemImage: isCurrentResult
                                          ? (check.issue == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                          : "clock")
                                        .foregroundStyle(isUpdating ? Color.secondary : isCurrentResult && check.issue == nil
                                                         ? Color.green : Color.orange)
                                } label: {
                                    Text(check.fileName)
                                }
                                if let issue = check.issue {
                                    Text(check.readFailure?.detail ?? issue.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("These results show database structure checks, not isolated behavior tests. A passed structure check stays passed after isolated tests; those results appear separately below. No conversation contents are read. This is not full Desktop runtime or restart verification.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Interface check evidence") {
                    ForEach(report.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Isolated behavior tests") {
                    Text("Test archive, restore and deletion using temporary conversations, plus Desktop cleanup and disk backups using synthetic files. No real conversations are changed.")
                    Button("Run Isolated Compatibility Tests…") {
                        confirmedFingerprint = report.environmentFingerprint
                        showsBehaviorConfirmation = true
                    }
                    .disabled(!model.compatibilityReportIsCurrent || model.isCheckingCompatibility || model.isComparingCompatibility || model.isLoading)
                    .accessibilityIdentifier("testCodexCompatibilityBehavior")
                    checkActivity
                    if let behavior = report.behavior {
                        Text("\(isUpdating ? "Previous isolated test" : "Isolated test") \(behavior.checkedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                        ForEach(behavior.results) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(result.feature == .desktopCleanup ? "Desktop cleanup SQL self-test" : result.feature.label): \(currentLabel(result.status.label))")
                                    .foregroundStyle(isUpdating ? Color.secondary : model.compatibilityReportIsCurrent && result.status == .passed ? Color.green : Color.orange)
                                Text(result.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Results are remembered. Passed CLI tests allow the matching environment to use those features. The Desktop self-test checks synthetic disk backups and cleanup, not the Desktop application or crash recovery; it does not unlock new Desktop versions. Temporary test files are moved to macOS Trash when possible.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("No saved inspection. Refresh Codex Live first so ASM can identify the active data directory, then run Check Compatibility.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .onAppear { model.refreshCompatibilityReport() }
        .confirmationDialog("Run isolated compatibility tests?", isPresented: $showsBehaviorConfirmation, titleVisibility: .visible) {
            Button("Run Tests") {
                guard let fingerprint = confirmedFingerprint else { return }
                Task { await model.checkCodexCompatibility(confirmedBehaviorFingerprint: fingerprint) }
            }
            Button("Cancel", role: .cancel) { confirmedFingerprint = nil }
        } message: {
            Text("ASM will create temporary test conversations, archive and restore them, and delete a test conversation. Desktop cleanup, disk backup readback and rollback are also checked using synthetic files. Your real conversations are not changed. This may take a few minutes; results are saved locally.")
        }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: SessionManagerModel
    @State private var isSnapshotRecoveryExpanded = false

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
                Text("Compatibility events use check IDs, stages, durations and numeric error codes. They exclude session IDs, titles, private paths, SQL and raw error descriptions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Diagnostic Log file") {
                    Text(model.diagnosticLogFileURL?.path ?? "In-memory fallback")
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }

                Divider()

                Button {
                    Task {
                        await model.presentGhostRepairSnapshotCleanup()
                    }
                } label: {
                    Label(
                        "Manage Published Snapshot Storage…",
                        systemImage: "externaldrive.badge.minus"
                    )
                }
                .accessibilityIdentifier(
                    "managePublishedGhostRepairSnapshotStorage"
                )
                .immediateHelp(
                    "List published snapshots and review moving one exact eligible snapshot to Agent Session Manager Trash"
                )

                Text(
                    "Independent of session selection and Safety Review. Opening this screen only reads app-owned snapshot metadata. A snapshot moves only after you choose one exact UUID and approve the final macOS confirmation; it is not permanently deleted and Codex is not changed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Ghost Delete") {
                Toggle(
                    "Enable Bulk Ghost Delete",
                    isOn: Binding(
                        get: {
                            model.isGhostRepairBulkReconciliationEnabled
                        },
                        set: {
                            model.setGhostRepairBulkReconciliationEnabled($0)
                        }
                    )
                )
                .disabled(model.ghostRepairBulkDisableBlockedReason != nil)
                .accessibilityIdentifier("bulkGhostCleanupToggle")
                .immediateHelp(
                    "Enable the version-bound bulk deletion of confirmed Codex Desktop residue"
                )

                if let reason = model.ghostRepairBulkDisableBlockedReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(
                    "Default off. Permanent Delete first uses Codex App Server to delete the canonical session and verifies official absence. This screen then classifies any Codex Desktop residue, freezes the complete batch, and requires one whole-batch confirmation before one atomic Ghost Delete. It never asks you to repair sessions one by one."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let reference = model.ghostRepairSnapshotRecoveryReference {
                    Label(
                        "Snapshot \(reference) requires exact readback. Ghost Delete remains locked to prevent retry or identity loss.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                }

                Divider()

                Button {
                    model.presentGhostRepairBulkInventory()
                } label: {
                    Label(
                        "Open Bulk Ghost Delete…",
                        systemImage: "list.bullet.clipboard"
                    )
                }
                .disabled(!model.isGhostRepairBulkReconciliationEnabled)
                .accessibilityIdentifier("openBulkGhostInventory")
                .immediateHelp(
                    model.isGhostRepairBulkReconciliationEnabled
                        ? "Open bulk residue inventory, classification, confirmation, and readback"
                        : "Enable Bulk Ghost Delete first"
                )

                DisclosureGroup(
                    "Snapshot recovery",
                    isExpanded: $isSnapshotRecoveryExpanded
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Use this only when a previous Snapshot operation requires exact recovery readback. It is not a second Ghost Delete workflow."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Toggle(
                            "Enable explicit Snapshot Readback",
                            isOn: $model.isGhostRepairSnapshotReadbackEnabled
                        )
                        .accessibilityIdentifier("ghostRepairSnapshotReadbackToggle")

                        Button {
                            model.presentGhostRepairSnapshotReadback()
                        } label: {
                            Label(
                                "Open Snapshot Readback",
                                systemImage: "doc.text.magnifyingglass"
                            )
                        }
                        .disabled(
                            !model.isGhostRepairSnapshotReadbackEnabled
                                || !model.ghostRepairSnapshotReadbackCapabilities
                                    .readbackAvailable
                        )
                        .accessibilityIdentifier("openGhostRepairSnapshotReadback")
                        .immediateHelp(
                            model.isGhostRepairSnapshotReadbackEnabled
                                && model.ghostRepairSnapshotReadbackCapabilities
                                    .readbackAvailable
                                ? "Open explicit, path-redacted snapshot readback"
                                : "Enable Snapshot Readback with an available packaged readback capability first"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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

private struct SnapshotReadbackSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @State private var isReadbackSubmissionLatched = false

    private var isReading: Bool {
        if case .reading = model.ghostRepairSnapshotReadbackState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "Snapshot Readback",
                    systemImage: "doc.text.magnifyingglass"
                )
                .font(.title2.bold())
                Text(
                    "Inspect saved snapshot status for recovery. Reading status does not change Codex data or create a new snapshot."
                )
                .foregroundStyle(.secondary)
            }

            Divider()
            content
            Spacer(minLength: 0)
            Divider()

            HStack {
                Label(
                    "No clear paths or raw database contents are shown. Readback cannot retry acquisition, clean up storage, create a snapshot, or authorize repair.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                if model.ghostRepairSnapshotReadbackCapabilities.readbackAvailable {
                    Button(readbackButtonTitle) {
                        guard !isReadbackSubmissionLatched else { return }
                        isReadbackSubmissionLatched = true
                        Task {
                            await model.readGhostRepairSnapshotInventory()
                            if !isReading {
                                isReadbackSubmissionLatched = false
                            }
                        }
                    }
                    .disabled(isReading || isReadbackSubmissionLatched)
                    .accessibilityIdentifier("readGhostRepairSnapshotStatus")
                }
                Button("Close") {
                    model.isGhostRepairSnapshotReadbackPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isReading)
            }
        }
        .padding(20)
        .frame(width: 780, height: 640)
        .interactiveDismissDisabled(isReading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.ghostRepairSnapshotReadbackState {
        case .disabled:
            ContentUnavailableView(
                "Snapshot Readback Disabled",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Enable explicit Snapshot Readback in Settings first.")
            )
        case .idle:
            if model.ghostRepairSnapshotReadbackCapabilities.readbackAvailable {
                ContentUnavailableView(
                    "Not Read",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        "No storage metadata is read until you press Read Snapshot Status."
                    )
                )
            } else {
                ContentUnavailableView(
                    "Snapshot Readback Unavailable",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(
                        "The packaged readback capability is unavailable in this build."
                    )
                )
            }
        case .reading:
            VStack(alignment: .leading, spacing: 12) {
                ProgressView()
                Text("Reading bounded, path-redacted snapshot evidence…")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .observed(inventory):
            inventoryContent(inventory)
        case let .unavailable(message):
            ContentUnavailableView(
                "Snapshot Readback Unavailable",
                systemImage: "exclamationmark.triangle.fill",
                description: Text(message)
            )
        }
    }

    private var readbackButtonTitle: String {
        switch model.ghostRepairSnapshotReadbackState {
        case .idle, .disabled: "Read Snapshot Status"
        case .reading: "Reading…"
        case .observed, .unavailable: "Read Again"
        }
    }

    private func inventoryContent(
        _ inventory: CodexGhostRepairSnapshotReadbackInventory
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Fresh inventory") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(
                            "Durable acquisition records",
                            value: inventory.snapshots.count.formatted()
                        )
                        LabeledContent(
                            "Published bytes",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(clamping: inventory.totalPublishedBytes),
                                countStyle: .file
                            )
                        )
                        LabeledContent("Raw database contents opened", value: "0")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                if inventory.snapshots.isEmpty {
                    Label(
                        "No durable snapshot acquisition records were observed.",
                        systemImage: "tray"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(inventory.snapshots, id: \.reference) { item in
                        snapshotItem(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func snapshotItem(
        _ item: CodexGhostRepairSnapshotReadbackItem
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.reference)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                LabeledContent("State", value: stateLabel(item.state))
                LabeledContent("Reviewed targets", value: item.targetCount.formatted())
                LabeledContent(
                    "Observed regular files",
                    value: item.observedRegularFileCount.formatted()
                )
                if let bytes = item.actualPublishedBytes {
                    LabeledContent(
                        "Published bytes",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: bytes),
                            countStyle: .file
                        )
                    )
                }
                LabeledContent("Acquisition record hash") {
                    Text(item.acquisitionRecordHash)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let manifestHash = item.manifestHash {
                    LabeledContent("Manifest hash") {
                        Text(manifestHash)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let receiptHash = item.publicationReceiptHash {
                    LabeledContent("Publication receipt hash") {
                        Text(receiptHash)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Label(stateLabel(item.state), systemImage: stateSymbol(item.state))
        }
    }

    private func stateLabel(
        _ state: CodexGhostRepairSnapshotReadbackState
    ) -> String {
        switch state {
        case .preparedOnly: "Prepared only"
        case .unpublishedPartial: "Unpublished partial"
        case .publicationInterrupted: "Publication interrupted"
        case .published: "Published"
        case .movedToTrash: "Moved to Trash"
        }
    }

    private func stateSymbol(
        _ state: CodexGhostRepairSnapshotReadbackState
    ) -> String {
        switch state {
        case .preparedOnly: "doc.badge.clock"
        case .unpublishedPartial: "exclamationmark.triangle.fill"
        case .publicationInterrupted: "pause.circle.fill"
        case .published: "checkmark.shield.fill"
        case .movedToTrash: "trash.fill"
        }
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
            let runMatches = model.diagnosticLogRunFilter == nil
                || event.metadata["check_id"] == model.diagnosticLogRunFilter?.uuidString
            return levelMatches && categoryMatches && searchMatches && runMatches
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
            if model.diagnosticLogRunFilter != nil {
                selectedLevel = nil; selectedCategory = .compatibility; searchText = ""
            }
            await model.refreshDiagnosticLogs()
        }
        .onChange(of: model.diagnosticLogRunFilter) { _, runID in
            if runID != nil { selectedLevel = nil; selectedCategory = .compatibility; searchText = "" }
            selectedEventID = nil
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
            if let runID = model.diagnosticLogRunFilter {
                HStack {
                    Text("Compatibility check: \(runID.uuidString)").font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Show All Checks") { model.diagnosticLogRunFilter = nil; selectedEventID = nil }
                }
            }
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
                    Label(model.diagnosticLogRunFilter == nil ? "Export" : "Export This Check", systemImage: "square.and.arrow.up")
                }
                .disabled(model.diagnosticLogSnapshot.events.isEmpty)
                .immediateHelp(model.diagnosticLogRunFilter == nil ? "Export all retained diagnostic events as JSONL" : "Export only this compatibility check, regardless of text or level filters")
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
