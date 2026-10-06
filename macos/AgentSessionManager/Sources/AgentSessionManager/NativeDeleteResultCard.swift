import SwiftUI
import AgentSessionManagerCore

/// A report row uses the available width and grows vertically. The reason and
/// next action stay together; reading it never depends on a tooltip or hover.
struct NativeDeleteResultCard: View {
    let item: NativeDeleteReportItem
    let reviewForkHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.deletionResultLabel)
                .font(.callout.weight(.semibold))
                .foregroundStyle(item.outcome == .success ? .green : item.deletionWasNotAttempted ? .secondary : item.outcome == .failure ? .red : .orange)
            Text(item.title).font(.headline)
            Text(item.nativeSessionID).font(.caption.monospaced())
            Text("Current state: \(item.observedNativeState.rawValue.capitalized)")
                .font(.caption).foregroundStyle(.secondary)
            if item.outcome != .success {
                Text(item.deletionExplanation).font(.callout)
                Button("Review Fork History…", action: reviewForkHistory)
                    .buttonStyle(.borderedProminent)
                if !item.deletionHasForkHistoryBlocker {
                    Text("If the refusal mentions fork history, review the dependent forks before trying again. Older reports may have omitted the original refusal reason.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.errorCode ?? "No error code").font(.caption.monospaced())
                        if let message = item.message { Text(message).font(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
