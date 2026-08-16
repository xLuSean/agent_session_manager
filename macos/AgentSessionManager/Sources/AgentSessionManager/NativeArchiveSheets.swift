import AgentSessionManagerCore
import SwiftUI

struct NativeArchivePreviewSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss
    let preview: OperationPreview
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(previewTitle, systemImage: preview.operation.symbol)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(preview.items.count) session\(preview.items.count == 1 ? "" : "s")")
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

            Label(
                preview.items.count == 1
                    ? "Confirm sends exactly one official thread/archive request, then performs one fresh readback. It never retries automatically."
                    : "Confirm preflights the whole frozen selection, then sends requests in order and stops after the first non-success. It never retries automatically.",
                systemImage: "checkmark.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                    .immediateHelp("Keep the persisted Preview unused and send no request")
                Spacer()
                Button("Confirm \(preview.operation.label)") {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    Task {
                        await model.executeNativeArchive(preview)
                        if model.pendingNativeArchivePreview?.id == preview.id {
                            isSubmitting = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
                .immediateHelp("Confirm, send the official Archive request, and verify \(preview.operation.label)")
            }
            .disabled(isSubmitting)

            if isSubmitting {
                ProgressView("Archiving and verifying exact-ID readback…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 740, minHeight: 480)
    }

    private var previewTitle: String {
        preview.operation == .moveToTrash
            ? "Active to Trash Preview"
            : "Native Archive Preview"
    }
}

struct NativePreviewItemList: View {
    let items: [OperationPreviewItem]

    var body: some View {
        if items.count == 1, let item = items.first {
            itemRow(item)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        itemRow(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if item.id != items.last?.id { Divider() }
                    }
                }
                .padding(12)
            }
            .frame(minHeight: 110, maxHeight: 190)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func itemRow(_ item: OperationPreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.headline).lineLimit(1)
            Text(item.nativeID)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("\(item.beforeCollection.label) → \(item.targetCollection.label)")
                .font(.callout.weight(.medium))
                .foregroundStyle(.blue)
        }
    }
}

struct NativeArchiveReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: NativeArchiveReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(summaryTitle, systemImage: summarySymbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(summaryColor)

            if report.recoveredAfterInterruption {
                Label(
                    "Recovered after an interrupted execution using readback only. No Archive request was resent.",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.blue)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
                TableColumn("Native state") { Text($0.observedNativeState.rawValue.capitalized) }
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

            Text("Success requires Archived readback. Busy/rejection is a normal failure result. Unknown means the app could not authoritatively prove the final state. No automatic retry is ever sent, including during recovery.")
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
        case .success: "\(operationLabel) succeeded"
        case .failure: "\(operationLabel) failed"
        case .unknown: "\(operationLabel) outcome unknown"
        case .warning, .partial: "\(operationLabel) completed with warnings"
        }
    }

    private var operationLabel: String {
        report.operation == .moveToTrash ? "Move to Trash" : "Archive"
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
