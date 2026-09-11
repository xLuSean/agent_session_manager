import AgentSessionManagerCore
import AppKit
import SwiftUI

struct NativeDeletePreviewSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss
    let preview: OperationPreview
    @State private var typedToken = ""
    @State private var isSubmitting = false
    @State private var submissionFailure: NativeDeleteSubmissionFailure?

    var body: some View {
        let size = NativeDeletePreviewSheetLayout.size(
            visibleScreenSize: (NSApp.keyWindow?.screen ?? NSScreen.main)?
                .visibleFrame.size ?? CGSize(width: 1_280, height: 800)
        )
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Permanent Delete Preview", systemImage: "trash.slash.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
                Spacer()
                Text("\(preview.items.count) Trash session\(preview.items.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                previewContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            submissionStatus
            footer
        }
        .padding(24)
        .frame(width: size.width, height: size.height)
        .interactiveDismissDisabled(isSubmitting)
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            CodexDesktopQuitRequirementBanner()
            Text("Permanently deletes these conversations and cleans their Desktop residue. This cannot be undone. Automation settings are kept; remaining global settings require a separate diff review.")
                .font(.callout)

            NativePreviewItemList(items: preview.items)

            NativeOperationDetails(warnings: preview.warnings)

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
            .disabled(isSubmitting)
        }
    }

    @ViewBuilder
    private var submissionStatus: some View {
        if isSubmitting {
            ProgressView(model.nativeDeleteSubmissionProgress ?? "Checking deletion requirements…")
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(model.nativeDeleteSubmissionProgress ?? "Checking deletion requirements")
        } else if let failure = submissionFailure {
            VStack(alignment: .leading, spacing: 8) {
                Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ScrollView {
                    Text(failure.message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                if failure.reviewCleanup && model.isGhostRepairBulkWorkflowEnabled {
                    Button("Review Previous Cleanup") {
                        model.queueCleanupReviewAfterDeletePreview()
                        dismiss()
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var footer: some View {
        HStack {
            Button(submissionFailure == nil ? "Cancel" : "Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)
                .immediateHelp("Close this preview without sending another Delete request")
            Spacer()
            Button(submissionFailure?.canRetry == true ? "Check Again and Delete" : "Delete Permanently", role: .destructive) {
                guard !isSubmitting else { return }
                submissionFailure = nil
                isSubmitting = true
                Task {
                    submissionFailure = await model.executeNativeDelete(
                        preview,
                        confirmationToken: typedToken
                    )
                    isSubmitting = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSubmitting || typedToken != preview.confirmationToken
                      || submissionFailure?.canRetry == false)
            .immediateHelp(
                typedToken == preview.confirmationToken
                    ? "Delete officially, then clean and verify the same IDs in Desktop"
                    : "Enter the exact confirmation token to enable permanent deletion"
            )
        }
        .disabled(isSubmitting)
    }
}

struct NativeDeleteReportSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss
    let report: NativeDeleteReport

    var body: some View {
        let size = NativeDeleteReportSheetLayout.size(
            visibleScreenSize: (NSApp.keyWindow?.screen ?? NSScreen.main)?
                .visibleFrame.size ?? CGSize(width: 1_280, height: 800)
        )
        VStack(alignment: .leading, spacing: 18) {
            Label(summaryTitle, systemImage: summarySymbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(summaryColor)

            Divider()
            ScrollView {
                reportContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: size.width, height: size.height)
    }

    private var reportContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if report.recoveredAfterInterruption {
                Label(
                    "Recovered after interruption using readback only. No Delete request was resent.",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.blue)
            }

            HStack(spacing: 24) {
                metric("Verified absent", report.successCount)
                metric("Failed", report.failureCount)
                metric("Unknown", report.unknownCount)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Conversation space cleared")
                    .font(.headline)
                if model.nativeDeleteSpaceReportID == report.id,
                   let summary = model.nativeDeleteSpaceSummary {
                    Text(summary.measuredBytes.map {
                        $0 == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "Not measured")
                        .font(.title2.monospacedDigit())
                    if !summary.isComplete {
                        Text("Partial measurement: \(summary.measuredSessionCount) of \(summary.deletedSessionCount) successfully deleted sessions. Unmeasured files are not counted as zero.")
                            .font(.callout)
                    }
                } else if model.nativeDeleteSubmissionProgress != nil,
                          model.latestNativeDeleteReport?.id == report.id {
                    ProgressView("Measurement will appear when this operation finishes…")
                } else {
                    Text("Not measured for this operation")
                        .foregroundStyle(.secondary)
                }
                Text("Logical size measured before deletion, counted only when deletion succeeded and no matching conversation files remain. Excludes shared databases and backups; not the change in available disk space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)

            Table(report.items) {
                TableColumn("Result") { item in
                    Text(item.outcome.rawValue.capitalized)
                        .foregroundStyle(color(for: item.outcome))
                }
                TableColumn("Title") { Text($0.title).lineLimit(1).help($0.title) }
                TableColumn("Session ID") {
                    Text($0.nativeSessionID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                TableColumn("Native state") {
                    Text($0.observedNativeState.rawValue.capitalized)
                }
                TableColumn("Detail") { item in
                    Text(item.errorCode ?? "—")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .help(item.message ?? item.errorCode ?? "Official absence verified")
                }
            }
            .frame(height: NativeDeleteReportSheetLayout.tableHeight(itemCount: report.items.count))

            if let item = report.items.first, let message = item.message {
                VStack(alignment: .leading, spacing: 5) {
                    if let errorCode = item.errorCode {
                        Text(errorCode).font(.caption.monospaced().weight(.semibold))
                    }
                    Text(message).font(.callout).textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }

            Text(
                successfulItems.isEmpty
                    ? "Success verifies canonical deletion only: both official readbacks proved the exact session absent. Codex Desktop residue is not verified here. Unknown is never retried automatically."
                    : model.nativeDeleteDesktopCleanupDetail(reportID: report.id)
            )
                .font(.callout)
                .foregroundStyle(.secondary)

            if !successfulItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        report.outcome == .partial
                            ? "Desktop cleanup can continue only for these exact canonically successful session IDs:"
                            : "Desktop cleanup scope is limited to these exact canonically successful session IDs:"
                    )
                    .font(.callout.weight(.semibold))
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(successfulItems, id: \.nativeSessionID) { item in
                            Text(item.nativeSessionID)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.nativeDeleteAutomaticCleanupReportID == report.id {
                Button("Review Desktop Cleanup Result") {
                    model.reviewNativeDeleteCleanupResult(reportID: report.id)
                    dismiss()
                }
                .help("Inspect the retained cleanup result or perform exact read-only recovery. This does not resend Delete.")
            } else {
                Button("Continue Desktop Cleanup") {
                    model.queueNativeDeleteDesktopCleanup(report: report)
                    dismiss()
                }
                .disabled(
                    model.nativeDeleteDesktopCleanupBlockedReason(
                        report: report
                    ) != nil
                )
                .help(
                    model.nativeDeleteDesktopCleanupBlockedReason(
                        report: report
                    )
                        ?? "Queue only the exact canonically successful IDs, then continue in the existing Bulk Ghost Delete sheet."
                )
                .accessibilityIdentifier("continueNativeDeleteDesktopCleanup")
            }
            Spacer()
            Button("Done") {
                model.finishNativeDeleteReport(reportID: report.id)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("nativeDeleteReportDone")
        }
    }

    private var successfulItems: [NativeDeleteReportItem] {
        report.items.filter {
            $0.outcome == .success && $0.observedNativeState == .absent
        }
    }

    private var summaryTitle: String {
        if report.outcome == .success {
            return model.nativeDeleteDesktopCleanupVerified(reportID: report.id)
                ? "Deletion and Desktop cleanup verified"
                : "Official deletion verified · Desktop cleanup not verified"
        }
        return switch report.outcome {
        case .success: "Canonical deletion verified"
        case .failure: "Canonical deletion failed"
        case .unknown: "Canonical deletion outcome unknown"
        case .warning, .partial: "Canonical deletion completed with warnings"
        }
    }

    private var summarySymbol: String {
        if report.outcome == .success,
           !model.nativeDeleteDesktopCleanupVerified(reportID: report.id) {
            return "exclamationmark.triangle.fill"
        }
        return switch report.outcome {
        case .success: "checkmark.seal.fill"
        case .failure: "xmark.octagon.fill"
        case .unknown: "questionmark.diamond.fill"
        case .warning, .partial: "exclamationmark.triangle.fill"
        }
    }

    private var summaryColor: Color {
        if report.outcome == .success,
           !model.nativeDeleteDesktopCleanupVerified(reportID: report.id) {
            return .orange
        }
        return switch report.outcome {
        case .success: .green
        case .failure: .red
        case .unknown, .warning, .partial: .orange
        }
    }

    private func color(for outcome: PersistentItemOutcome) -> Color {
        switch outcome {
        case .success: .green
        case .failure: .red
        case .unknown: .orange
        }
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.title3.monospacedDigit().weight(.semibold))
        }
    }
}
