import AgentSessionManagerCore
import AppKit
import SwiftUI

struct OperationPreviewSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss
    let preview: OperationPreview
    @State private var typedToken = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("\(preview.operation.label) Preview", systemImage: preview.operation.symbol)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(preview.items.count) session\(preview.items.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 22) {
                metric("Total", "\(preview.items.count)")
                metric("Known size", ByteCountFormatter.string(fromByteCount: preview.measurableBytes, countStyle: .file))
                metric("Agent", preview.provider.label)
            }

            if !preview.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(preview.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                    }
                }
                .font(.callout)
                .foregroundStyle(.orange)
            }

            Table(preview.items) {
                TableColumn("Title") { Text($0.title).lineLimit(1) }
                TableColumn("Session ID") {
                    Text($0.nativeID).font(.caption.monospaced()).textSelection(.enabled)
                }
                TableColumn("Change") {
                    Text("\($0.beforeCollection.label) → \($0.targetCollection.label)")
                }
            }
            .frame(minHeight: 230)

            if !preview.operation.isDestructive {
                Label(
                    "Manager-only change: updates this app's SQLite classification; Codex remains Archived.",
                    systemImage: "externaldrive.badge.checkmark"
                )
                .font(.callout)
                .foregroundStyle(.blue)
            }

            if preview.operation.requiresTypedConfirmation {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        "Action required: enter the confirmation token",
                        systemImage: "keyboard.badge.ellipsis"
                    )
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.red)

                    Text("Permanent deletion cannot be undone. Copy the token below into the text field to enable Delete Permanently.")
                        .font(.callout.weight(.semibold))
                    ConfirmationTokenDisplay(token: preview.confirmationToken)
                    TextField("Paste or type the token here", text: $typedToken)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSubmitting)
                }
                .padding(16)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red.opacity(0.45), lineWidth: 1)
                }
            } else {
                Label(
                    "Review the frozen selection above, then confirm this reversible operation.",
                    systemImage: "checkmark.shield"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                    .immediateHelp("Cancel without applying this operation")
                Spacer()
                Button(preview.operation.label, role: preview.operation.isDestructive ? .destructive : nil) {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    Task {
                        await model.execute(
                            preview,
                            typedConfirmationToken: preview.operation.requiresTypedConfirmation
                                ? typedToken
                                : nil
                        )
                        if model.pendingPreview?.id == preview.id {
                            isSubmitting = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isSubmitting
                        || (
                            preview.operation.requiresTypedConfirmation
                                && typedToken != preview.confirmationToken
                        )
                )
                .immediateHelp(
                    preview.operation.requiresTypedConfirmation
                        && typedToken != preview.confirmationToken
                        ? "Enter the exact confirmation token above to enable \(preview.operation.label)."
                        : "Confirm and execute \(preview.operation.label)"
                )
            }
            .disabled(isSubmitting)

            if isSubmitting {
                ProgressView("Applying manager state and verifying readback…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }

}

struct ConfirmationTokenDisplay: View {
    let token: String

    var body: some View {
        HStack(spacing: 10) {
            Text(token)
                .font(.title3.monospaced().weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            PasteboardCopyButton(
                text: token,
                help: "Copy the exact confirmation token"
            )
            .controlSize(.small)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct OperationReportSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss
    let report: OperationReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Operation Report", systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(report.failureCount == 0 ? .green : .orange)

            HStack(spacing: 24) {
                metric("Total", report.items.count)
                metric("Succeeded", report.successCount)
                metric("Failed", report.failureCount)
            }

            Table(report.items) {
                TableColumn("Result") { item in
                    Label(item.success ? "Success" : "Failed", systemImage: item.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(item.success ? .green : .red)
                }
                TableColumn("Title") { Text($0.title).lineLimit(1) }
                TableColumn("Session ID") {
                    Text($0.nativeID).font(.caption.monospaced()).textSelection(.enabled)
                }
                TableColumn("Final state") { Text($0.observedFinalCollection.label) }
            }
            .frame(minHeight: 240)

            Text(reportSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 440)
    }

    private var reportSummary: String {
        switch report.operation {
        case .restore:
            "Manager Trash membership and itemized report committed atomically. Codex was already Active; no lifecycle request was sent."
        case .emptyTrash where report.items.allSatisfy({
            $0.note.contains("external deletion")
        }):
            "The stale Manager Trash membership, Deleted record, and itemized report committed atomically. Codex was already absent; no lifecycle request was sent."
        default:
            "Manager SQLite classification and itemized report committed atomically. Codex remained natively Archived."
        }
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.title3.monospacedDigit().weight(.semibold))
        }
    }
}
