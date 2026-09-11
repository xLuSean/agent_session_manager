import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.openSettings) private var openSettings
    @State private var hasLoaded = false

    var body: some View {
        mainSplitView
        .safeAreaInset(edge: .top, spacing: 0) {
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
            model.refreshCompatibilityReport()
            await model.reload()
            hasLoaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if hasLoaded { model.refreshCompatibilityReport() }
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
        .sheet(isPresented: $model.isReportHistoryPresented) {
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
            )
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
