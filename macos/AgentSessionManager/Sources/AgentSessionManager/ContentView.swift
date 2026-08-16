import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: SessionManagerModel

    var body: some View {
        mainSplitView
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
        .task { await model.reload() }
        .sheet(item: $model.pendingPreview, onDismiss: {
            model.presentQueuedOperationReport()
        }) { preview in
            OperationPreviewSheet(preview: preview)
                .environmentObject(model)
        }
        .sheet(item: $model.pendingArchiveReadiness) { readiness in
            ArchiveReadinessSheet(readiness: readiness)
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
        .sheet(item: $model.pendingNativeDeletePreview) { preview in
            NativeDeletePreviewSheet(preview: preview)
                .environmentObject(model)
        }
        .sheet(item: $model.latestNativeDeleteReport) { report in
            NativeDeleteReportSheet(report: report)
        }
        .sheet(item: $model.latestReport) { report in
            OperationReportSheet(report: report)
                .environmentObject(model)
        }
        .sheet(item: $model.pendingConflictResolutionPreview, onDismiss: {
            model.presentQueuedOperationReport()
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
