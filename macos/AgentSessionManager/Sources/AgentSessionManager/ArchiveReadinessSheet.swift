import AgentSessionManagerCore
import SwiftUI

struct ArchiveReadinessSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss
    let readiness: LifecycleMutationReadiness

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Archive Readiness")
                        .font(.title2.weight(.semibold))
                    Text("Read-only review for the first single-session live Archive slice")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                summaryBadge
            }

            if let nativeSessionID = readiness.nativeSessionID {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Native session ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(nativeSessionID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(readiness.items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(for: item.verdict))
                                .foregroundStyle(color(for: item.verdict))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.requirement.label)
                                    .fontWeight(.medium)
                                Text(item.explanation)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(label(for: item.verdict))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: item.verdict))
                        }
                    }
                }
            }

            Label(
                "No Archive request will be sent from this screen.",
                systemImage: "lock.shield"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)

            HStack {
                if let reason = readiness.primaryBlockedReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(readiness.isExecutionEnabled ? "Create Preview" : "Done") {
                    if readiness.isExecutionEnabled {
                        Task { await model.prepareNativeArchive() }
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .immediateHelp(
                    readiness.isExecutionEnabled
                        ? "Persist a frozen Archive Preview; this still does not send the request."
                        : "Close Archive readiness"
                )
            }
        }
        .padding(24)
        .frame(minWidth: 650, idealWidth: 720, minHeight: 560, idealHeight: 640)
    }

    private var summaryBadge: some View {
        Label(
            summaryLabel,
            systemImage: summarySymbol
        )
        .font(.callout.weight(.semibold))
        .foregroundStyle(summaryColor)
    }

    private var summaryLabel: String {
        if !readiness.isEvidenceReady { return "Blocked" }
        return readiness.hasAttemptRisk ? "Attempt may fail" : "Evidence ready"
    }

    private var summarySymbol: String {
        if !readiness.isEvidenceReady { return "exclamationmark.shield.fill" }
        return readiness.hasAttemptRisk
            ? "exclamationmark.triangle.fill"
            : "checkmark.shield.fill"
    }

    private var summaryColor: Color {
        if !readiness.isEvidenceReady { return .orange }
        return readiness.hasAttemptRisk ? .yellow : .green
    }

    private func symbol(for verdict: LifecycleReadinessVerdict) -> String {
        switch verdict {
        case .satisfied: "checkmark.circle.fill"
        case .attemptMayFail: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    private func color(for verdict: LifecycleReadinessVerdict) -> Color {
        switch verdict {
        case .satisfied: .green
        case .attemptMayFail: .yellow
        case .blocked: .orange
        case .unavailable: .secondary
        }
    }

    private func label(for verdict: LifecycleReadinessVerdict) -> String {
        switch verdict {
        case .satisfied: "Ready"
        case .attemptMayFail: "May fail"
        case .blocked: "Blocked"
        case .unavailable: "Unavailable"
        }
    }
}
