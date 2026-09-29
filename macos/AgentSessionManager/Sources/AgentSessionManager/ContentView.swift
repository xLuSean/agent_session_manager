import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.openSettings) private var openSettings
    @State private var hasLoaded = false

    var body: some View {
        mainSplitView
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let notice = model.compatibilityNotice {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(notice.title, systemImage: "info.circle")
                                .fontWeight(.medium)
                            Spacer()
                            Button("Review Compatibility") { reviewCompatibility() }
                                .accessibilityIdentifier("reviewCodexCompatibility")
                            if model.isCompatibilityNoticeExpanded {
                                Button("Later") { model.deferCompatibilityNotice() }
                            }
                        }
                        if model.isCompatibilityNoticeExpanded {
                            Text(notice.message).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                }
                ghostOverviewBanner
            }
        }
        .background {
            Color.clear
                .frame(width: 0, height: 0)
                .alert(
                    "Diagnostic Logs Are Not Being Saved",
                    isPresented: $model.isDiagnosticLogPersistenceWarningPresented
                ) {
                    Button("Continue") {
                        model.isDiagnosticLogPersistenceWarningPresented = false
                    }
                } message: {
                    Text(
                        model.diagnosticLogPersistenceWarning
                            ?? "This run is using temporary in-memory diagnostic logs."
                    )
                }
        }
        .toolbar {
            if usesPersistentMainSplit {
                ToolbarItem(placement: .navigation) {
                    Button {
                        NSApp.sendAction(
                            #selector(NSSplitViewController.toggleSidebar(_:)),
                            to: nil,
                            from: nil
                        )
                    } label: {
                        Label("Toggle Sidebar", systemImage: "sidebar.left")
                    }
                    .accessibilityIdentifier("mainSidebarToggle")
                    .help("Show or hide the sidebar")
                }
            }
        }
        .task {
            // reload resolves the actual Codex home, then compares saved
            // compatibility in its completion path. A pre-load comparison
            // would mistake the initially unknown home for an installation change.
            await model.reload()
            model.refreshGhostOverview(force: true)
            hasLoaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if hasLoaded {
                model.refreshCompatibilityReport()
                model.refreshGhostOverview()
            }
        }
        .alert("Codex changed — check compatibility", isPresented: $model.isCompatibilityUpdateAlertPresented) {
            Button("Review Compatibility") { reviewCompatibility() }
            Button("Later", role: .cancel) { model.deferCompatibilityNotice() }
        } message: {
            Text("This Codex installation differs from your saved check. Review compatibility before using unverified operations. Your conversations have not been changed.")
        }
        .sheet(item: $model.pendingPreview, onDismiss: {
            model.presentQueuedOperationReport()
        }) { preview in
            OperationPreviewSheet(preview: preview)
                .environmentObject(model)
        }
        .sheet(item: $model.pendingNativeArchivePreview) { preview in
            NativeArchivePreviewSheet(preview: preview)
                .environmentObject(model)
        }
        .sheet(item: $model.latestNativeArchiveReport) { report in
            NativeArchiveReportSheet(report: report)
        }
        .sheet(item: $model.pendingNativeRestorePreview) { preview in
            NativeRestorePreviewSheet(preview: preview)
                .environmentObject(model)
        }
        .sheet(item: $model.latestNativeRestoreReport) { report in
            NativeRestoreReportSheet(report: report)
        }
        .sheet(item: $model.pendingNativeDeletePreview, onDismiss: {
            model.presentCleanupAfterDeletePreview()
        }) { preview in
            NativeDeletePreviewSheet(preview: preview)
                .environmentObject(model)
        }
        .sheet(item: $model.latestNativeDeleteReport, onDismiss: {
            model.presentQueuedNativeDeleteDesktopCleanup()
        }) { report in
            NativeDeleteReportSheet(report: report)
                .environmentObject(model)
        }
        .sheet(item: $model.latestReport) { report in
            OperationReportSheet(report: report)
                .environmentObject(model)
        }
        .sheet(item: $model.pendingConflictResolutionPreview, onDismiss: {
            model.presentQueuedConflictFollowUp()
        }) { preview in
            ConflictResolutionPreviewSheet(preview: preview)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isDesktopCleanupFollowUpsPresented, onDismiss: {
            model.presentQueuedNativeDeleteDesktopCleanup()
        }) {
            DesktopCleanupFollowUpsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isReportHistoryPresented, onDismiss: {
            model.presentQueuedNativeDeleteDesktopCleanup()
        }) {
            ReportHistoryView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isMaintenancePresented) {
            MaintenanceView()
                .environmentObject(model)
        }
        .sheet(
            isPresented: Binding(
                get: { model.isGhostRepairBulkInventoryPresented },
                set: { _ = model.setGhostRepairBulkInventoryPresented($0) }
            ),
            onDismiss: { model.refreshGhostOverview(force: true) }
        ) {
            GhostRepairBulkInventorySheet()
                .environmentObject(model)
        }
        .alert(
            "Agent Session Manager",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var ghostOverviewBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                if model.ghostOverviewState == .checking {
                    ProgressView().controlSize(.small)
                }
                Label(
                    model.hasPendingGhostCleanup ? "Desktop cleanup needs attention" : model.ghostOverviewState.title,
                    systemImage: model.hasPendingGhostCleanup || model.ghostOverviewState.needsAttention
                        ? "exclamationmark.circle.fill" : "sparkles"
                )
                .fontWeight(.medium)
                .foregroundStyle(model.hasPendingGhostCleanup || model.ghostOverviewState.needsAttention
                    ? Color.orange : Color.secondary)
                Spacer(minLength: 8)
                Button(model.hasPendingGhostCleanup ? "Continue Cleanup…" : "Review Ghosts…") {
                    Task { await model.presentMainGhostCleanup() }
                }
                .disabled(model.ghostOverviewState == .checking)
                .accessibilityIdentifier("mainGhostCleanup")
                Menu {
                    Button("Check Again") { model.refreshGhostOverview(force: true) }
                        .disabled(model.ghostOverviewState == .checking || model.hasPendingGhostCleanup)
                    Button("Previous Deletions…") { model.presentDesktopCleanupFollowUps() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Desktop cleanup options")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Group {
                if model.hasPendingGhostCleanup {
                    Text("Continue the saved batch to review its progress or result.")
                } else {
                    switch model.ghostOverviewState {
                    case let .checked(summary):
                        Text("Last checked \(summary.checkedAt.formatted(date: .abbreviated, time: .shortened)). \(summary.eligibleCount) eligible for cleanup; \(summary.uncertainCount) unconfirmed. Across projects and list filters.")
                    case .unavailable:
                        Text("Residue may still be present. Choose Review Ghosts to check again and see the reason.")
                    case .unchecked, .checking:
                        Text("Checks for records left by deleted Codex conversations. Nothing is deleted automatically.")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mainGhostOverview")
    }

    private func reviewCompatibility() {
        model.settingsTab = "compatibility"
        // Use the real Settings scene; do not present a competing sheet while
        // the startup alert is dismissing.
        DispatchQueue.main.async { openSettings() }
    }

    @ViewBuilder
    private var mainSplitView: some View {
        if usesPersistentMainSplit {
            PersistentMainSplitView(model: model)
        } else {
            navigationSplitView
        }
    }

    private var usesPersistentMainSplit: Bool {
        !ProcessInfo.processInfo.arguments.contains("--legacy-navigation-split")
    }

    private var navigationSplitView: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 235, max: 360)
        } content: {
            SessionTableView()
                .navigationSplitViewColumnWidth(min: 400, ideal: 680)
        } detail: {
            SessionInspectorView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 330, max: 520)
        }
    }
}
