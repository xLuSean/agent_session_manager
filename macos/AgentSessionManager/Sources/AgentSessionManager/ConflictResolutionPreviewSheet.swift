import AgentSessionManagerCore
import SwiftUI

struct ConflictResolutionPreviewSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss

    let preview: ConflictResolutionExecutionPreview
    @State private var isSubmitting = false

    private var proposal: ConflictResolutionPreview { preview.proposal }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(
                        preview.operationPreview == nil
                            ? "Read-only resolution preview"
                            : "Conflict resolution preview",
                        systemImage: "eye.trianglebadge.exclamationmark"
                    )
                        .font(.headline)
                        .foregroundStyle(.orange)

                    Text(
                        preview.operationPreview == nil
                            ? "No native session or SQLite membership will be changed."
                            : "Accepting the native restore removes only this app's Trash marker. Codex is already Active and will not receive a lifecycle request."
                    )
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    GroupBox("Frozen evidence") {
                        VStack(alignment: .leading, spacing: 10) {
                            evidenceRow("Provider", proposal.provider.label)
                            evidenceRow("Session ID", proposal.nativeSessionID, monospaced: true)
                            evidenceRow("Observed conflict", proposal.observedStatus.label)
                            evidenceRow(
                                "Native state",
                                proposal.observedNativeState?.rawValue.capitalized ?? "Not observed"
                            )
                            evidenceRow(
                                "Reconciled",
                                proposal.reconciledAt.formatted(date: .abbreviated, time: .standard)
                            )
                            evidenceRow("Inventory hash", proposal.inventoryHash, monospaced: true)
                            if let runtimeVersion = proposal.runtimeVersion {
                                evidenceRow("Runtime", runtimeVersion, monospaced: true)
                            }
                            if let exactReadback = proposal.exactReadback {
                                Divider()
                                evidenceRow("Exact-ID readback", exactReadback.status.label)
                                evidenceRow(
                                    "Exact read observed",
                                    exactReadback.observedAt.formatted(
                                        date: .abbreviated,
                                        time: .standard
                                    )
                                )
                                evidenceRow("Evidence kind", exactReadback.evidenceKind.label)
                                if let rpcCode = exactReadback.rpcCode {
                                    evidenceRow("RPC code", "\(rpcCode)", monospaced: true)
                                }
                                evidenceRow(
                                    "Absence proof",
                                    exactReadback.provesAbsence ? "Contract verified" : "Not established"
                                )
                                if let contract = exactReadback.absenceContract {
                                    evidenceRow("Absence contract", contract.identifier, monospaced: true)
                                    evidenceRow("Official source", contract.officialSourceURL.absoluteString)
                                }
                                evidenceRow("Exact read detail", exactReadback.message)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }

                    Text("Resolution options")
                        .font(.headline)

                    ForEach(proposal.options) { option in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(option.action.label)
                                        .font(.headline)
                                    Spacer()
                                    Text(option.readiness.label)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(
                                            readinessColor(option.readiness)
                                        )
                                }
                                Text(option.action.summary)
                                Text(option.reason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text("Required evidence")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(option.requiredEvidence, id: \.self) { evidence in
                                    Label(evidence, systemImage: "checklist.unchecked")
                                        .font(.callout)
                                }
                                if option.action.changesNativeState {
                                    Label("Would require a native lifecycle mutation", systemImage: "server.rack")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                if option.action.changesManagerState {
                                    Label(
                                        "Would require an atomic SQLite membership change",
                                        systemImage: "cylinder"
                                    )
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }

                    if preview.operationPreview != nil {
                        confirmationPanel
                    }

                    if isSubmitting {
                        ProgressView("Applying manager state and verifying readback…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(proposal.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(22)
            }
            .navigationTitle("Conflict Resolution")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(preview.operationPreview == nil ? "Done" : "Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                }
                if preview.operationPreview != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Confirm Accept Native Restore") {
                            guard !isSubmitting else { return }
                            isSubmitting = true
                            Task {
                                await model.executeConflictResolution(preview)
                                if model.pendingConflictResolutionPreview?.id == preview.id {
                                    isSubmitting = false
                                }
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSubmitting)
                        .immediateHelp("Confirm removal of only the manager Trash marker; Codex remains Active.")
                    }
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 640, idealHeight: 760)
    }

    @ViewBuilder
    private var confirmationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Ready to confirm",
                systemImage: "checkmark.shield"
            )
            .font(.title3.weight(.bold))
            .foregroundStyle(.blue)
            Text(
                "This removes the session from this app's Trash Bin and presents it as Active. It does not archive, restore, or delete anything in Codex."
            )
            .font(.callout.weight(.semibold))
        }
        .padding(16)
        .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.4), lineWidth: 1)
        }
    }

    private func readinessColor(_ readiness: ConflictResolutionReadiness) -> Color {
        switch readiness {
        case .readyToApply: .green
        case .previewOnly: .orange
        case .blocked: .red
        }
    }

    private func evidenceRow(
        _ label: String,
        _ value: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .textSelection(.enabled)
        }
    }
}

private extension ReconciliationStatus {
    var label: String {
        switch self {
        case .active: "Active"
        case .archive: "Archive"
        case .trash: "Trash Bin"
        case .nativeActiveTrashConflict: "Native Active + Manager Trash"
        case .externallyMissing: "Externally Missing"
        case .unavailable: "Unavailable"
        }
    }
}
