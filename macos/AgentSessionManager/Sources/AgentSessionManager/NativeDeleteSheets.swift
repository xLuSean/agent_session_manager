import AgentSessionManagerCore
import SwiftUI

struct NativeDeletePreviewSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss
    let preview: OperationPreview
    @State private var typedToken = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Permanent Delete Preview", systemImage: "trash.slash.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
                Spacer()
                Text("\(preview.items.count) Trash session\(preview.items.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }

            NativePreviewItemList(items: preview.items)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(preview.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                }
            }
            .font(.callout)
            .foregroundStyle(.orange)

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
                    .disabled(isSubmitting)
                    .immediateHelp("Keep the persisted Preview unused and send no Delete request")
                Spacer()
                Button("Delete Permanently", role: .destructive) {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    Task {
                        await model.executeNativeDelete(
                            preview,
                            confirmationToken: typedToken
                        )
                        if model.pendingNativeDeletePreview?.id == preview.id {
                            isSubmitting = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || typedToken != preview.confirmationToken)
                .immediateHelp(
                    typedToken == preview.confirmationToken
                        ? "Send one official Delete request and prove exact-ID absence"
                        : "Enter the exact confirmation token to enable permanent deletion"
                )
            }
            .disabled(isSubmitting)

            if isSubmitting {
                ProgressView("Deleting once and verifying two official readbacks…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 700, idealWidth: 760, minHeight: 520)
    }
}

struct NativeDeleteReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: NativeDeleteReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(summaryTitle, systemImage: summarySymbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(summaryColor)

            if report.recoveredAfterInterruption {
                Label(
                    "Recovered after interruption using readback only. No Delete request was resent.",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.blue)
            }

            HStack(spacing: 24) {
                metric("Succeeded", report.successCount)
                metric("Failed", report.failureCount)
                metric("Unknown", report.unknownCount)
            }

            Table(report.items) {
                TableColumn("Result") { item in
                    Text(item.outcome.rawValue.capitalized)
                        .foregroundStyle(color(for: item.outcome))
                }
                TableColumn("Title") { Text($0.title).lineLimit(1) }
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
                        .help(item.message ?? item.errorCode ?? "Verified success")
                }
            }
            .frame(minHeight: 210)

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

            Text("Success means both official readbacks proved the exact session absent. Unknown is never retried automatically. Released disk space is not claimed or estimated.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 430)
    }

    private var summaryTitle: String {
        switch report.outcome {
        case .success: "Permanent Delete succeeded"
        case .failure: "Permanent Delete failed"
        case .unknown: "Permanent Delete outcome unknown"
        case .warning, .partial: "Permanent Delete completed with warnings"
        }
    }

    private var summarySymbol: String {
        switch report.outcome {
        case .success: "checkmark.seal.fill"
        case .failure: "xmark.octagon.fill"
        case .unknown: "questionmark.diamond.fill"
        case .warning, .partial: "exclamationmark.triangle.fill"
        }
    }

    private var summaryColor: Color {
        switch report.outcome {
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
