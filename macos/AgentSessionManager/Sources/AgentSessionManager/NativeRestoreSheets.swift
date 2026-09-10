import AgentSessionManagerCore
import SwiftUI

struct NativeRestorePreviewSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss
    let preview: OperationPreview
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Native Restore Preview", systemImage: "arrow.uturn.backward")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(preview.items.count) session\(preview.items.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }

            CodexDesktopQuitRequirementBanner()

            NativePreviewItemList(items: preview.items)

            NativeOperationDetails(warnings: preview.warnings)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                    .immediateHelp("Keep the persisted Preview unused and send no request")
                Spacer()
                Button("Confirm Restore") {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    Task {
                        await model.executeNativeRestore(preview)
                        if model.pendingNativeRestorePreview?.id == preview.id {
                            isSubmitting = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
                .immediateHelp("Confirm, send the official Restore request, and read back the exact session")
            }
            .disabled(isSubmitting)

            if isSubmitting {
                ProgressView("Checking Codex is exited, then restoring and verifying…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 740, minHeight: 500)
    }
}

struct NativeRestoreReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: NativeRestoreReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(summaryTitle, systemImage: summarySymbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(summaryColor)

            if report.recoveredAfterInterruption {
                Label(
                    "Recovered after an interrupted execution using readback only. No Restore request was resent.",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.blue)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            if report.outcome == .success {
                CodexDesktopColdStartInstruction()
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

            if let item = report.items.first,
               let message = item.message {
                VStack(alignment: .leading, spacing: 5) {
                    if let errorCode = item.errorCode {
                        Text(errorCode)
                            .font(.caption.monospaced().weight(.semibold))
                    }
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }

            Text("Success requires Active readback. Rejection with Archived readback is failure. Unknown means the final state could not be proven. No automatic retry is ever sent, including during recovery.")
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
        case .success: "Restore succeeded"
        case .failure: "Restore failed"
        case .unknown: "Restore outcome unknown"
        case .warning, .partial: "Restore completed with warnings"
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
