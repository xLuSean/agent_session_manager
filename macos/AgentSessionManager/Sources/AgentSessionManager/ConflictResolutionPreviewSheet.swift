import AgentSessionManagerCore
import SwiftUI

struct ConflictResolutionPreviewSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss

    let preview: ConflictResolutionExecutionPreview
    @State private var isSubmitting = false

    private var proposal: ConflictResolutionPreview { preview.proposal }
    private var isExternalDeletion: Bool {
        proposal.observedStatus == .externallyMissing
    }

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
                            : isExternalDeletion
                                ? "Acknowledging the external deletion moves only this app's stale Trash marker to Deleted. Codex will not receive a lifecycle request."
                                : "Choose whether to accept Codex's Active state or review one official Archive attempt that keeps this app's existing Trash intent."
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
                            if let evidence = proposal.externalDeletionEvidence {
                                Divider()
                                evidenceRow("External deletion proof", "Verified")
                                evidenceRow("Runtime", evidence.runtimeVersion, monospaced: true)
                                evidenceRow(
                                    "Complete inventory observed",
                                    evidence.inventoryObservedAt.formatted(
                                        date: .abbreviated,
                                        time: .standard
                                    )
                                )
                                evidenceRow(
                                    "Exact read observed",
                                    evidence.exactReadObservedAt.formatted(
                                        date: .abbreviated,
                                        time: .standard
                                    )
                                )
                                evidenceRow("RPC code", "\(evidence.rpcCode)", monospaced: true)
                                evidenceRow("Exact read detail", evidence.message)
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
                                    Label(
                                        option.readiness == .readyToApply
                                            ? "Uses one official Archive request with fresh readback"
                                            : "Native lifecycle mutation is unavailable",
                                        systemImage: "server.rack"
                                    )
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
                                if option.action == .reapplyTrashIntent,
                                   option.readiness == .readyToApply {
                                    Button("Review Archive Again and Keep in Trash…") {
                                        guard !isSubmitting else { return }
                                        isSubmitting = true
                                        Task {
                                            await model.prepareReapplyTrashIntent(from: preview)
                                            if model.pendingConflictResolutionPreview?.id == preview.id {
                                                isSubmitting = false
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(isSubmitting)
                                    .immediateHelp(
                                        "Create a frozen native Archive Preview while preserving the exact Manager Trash intent"
                                    )
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
                        ProgressView("Preparing or applying the selected resolution…")
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
                        Button(
                            isExternalDeletion
                                ? "Confirm External Deletion"
                                : "Confirm Accept Native Restore"
                        ) {
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
                        .immediateHelp(
                            isExternalDeletion
                                ? "Confirm the readback-only Trash to Deleted transition; no Codex request is sent."
                                : "Confirm removal of only the manager Trash marker; Codex remains Active."
                        )
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
                isExternalDeletion
                    ? "This removes the stale session from this app's Trash Bin and records it under Deleted. It does not archive, restore, or delete anything in Codex."
                    : "This removes the session from this app's Trash Bin and presents it as Active. It does not archive, restore, or delete anything in Codex."
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
