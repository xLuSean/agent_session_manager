import AgentSessionManagerCore
import SwiftUI

struct SessionInspectorView: View {
    @EnvironmentObject private var model: SessionManagerModel

    var body: some View {
        Group {
            if let session = model.inspectedSession {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label(session.displayState.label, systemImage: session.displayState.symbol)
                            .font(.headline)

                        Text(session.title)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)

                        if session.displayState == .conflict
                            || session.displayState == .externallyMissing {
                            conflictActionPanel(session)
                        }

                        detailSection("Identity") {
                            detailRow("Agent", session.system.label)
                            detailRow("Session ID", session.nativeID, monospaced: true)
                        }

                        detailSection("Location") {
                            detailRow("Project", session.project?.name ?? "Unavailable")
                            detailRow("Project root", session.project?.rootPath ?? "Unavailable")
                            detailRow("Working folder", session.workingDirectory ?? "Unavailable")
                            detailRow("Trust folder", session.trustFolderPath ?? "Unavailable")
                            detailRow("Folder trust", session.folderTrustState.label)
                        }

                        detailSection("Lifecycle") {
                            detailRow("Native state", session.nativeState?.rawValue.capitalized ?? "Not observed")
                            detailRow("Manager state", session.displayState.label)
                            detailRow("Reconciliation", session.stateExplanation)
                            detailRow(
                                "Lifecycle Preview",
                                session.isStableForLifecyclePreview ? "Stable" : "Blocked"
                            )
                            detailRow("Updated", session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            detailRow("Conversation size", model.conversationFileSizeLabel(for: session))
                                .help(model.conversationFileSizeHelp)
                            detailRow(
                                "Descendants",
                                session.descendantCountKnown ? "\(session.descendantCount)" : "Unavailable"
                            )
                        }

                        detailSection("Protection") {
                            ForEach(session.protectionEvidence) { evidence in
                                protectionEvidenceRow(evidence)
                            }
                        }

                        detailSection("Archive") {
                            Text("Review this conversation before archiving. Archived conversations can be restored.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Archive") {
                                Task { await model.requestPreview(.archive) }
                            }
                            .disabled(!model.canRequestPreview(.archive))
                            .immediateHelp(
                                model.blockedReason(for: .archive)
                                    ?? "Review and confirm Archive"
                            )
                        }

                        if let diagnostic = model.providerDiagnostics.first(where: {
                            $0.system == session.system
                        }) {
                            detailSection("Provider capability") {
                                detailRow("Source", "Codex Live")
                                detailRow("Connection", diagnostic.connectionState.label)
                                detailRow(
                                    "Inventory coverage",
                                    diagnostic.inventoryComplete ? "Complete" : "Incomplete"
                                )
                                detailRow(
                                    "Protection coverage",
                                    diagnostic.protectionComplete ? "Complete" : "Incomplete"
                                )
                                detailRow(
                                    "Pin state",
                                    availability(diagnostic.capabilities.canReadPinnedState)
                                )
                                detailRow(
                                    "Running state",
                                    availability(diagnostic.capabilities.canReadRunningState)
                                )
                                detailRow(
                                    "Current state",
                                    availability(diagnostic.capabilities.canReadCurrentState)
                                )
                                detailRow(
                                    "Descendant graph",
                                    availability(diagnostic.capabilities.canReadDescendants)
                                )
                                detailRow(
                                    "Folder trust",
                                    availability(diagnostic.capabilities.canReadFolderTrust)
                                )
                                detailRow(
                                    "Exact-ID readback",
                                    availability(diagnostic.capabilities.canReadExactSession)
                                )
                                detailRow(
                                    "Writer authority",
                                    "Unavailable (Archive may return Busy)"
                                )
                                detailRow(
                                    "Native Archive API",
                                    optionalAvailability(diagnostic.capabilities.hasNativeArchiveInterface)
                                )
                                detailRow(
                                    "Native Delete API",
                                    optionalAvailability(diagnostic.capabilities.hasNativeDeleteInterface)
                                )
                                detailRow(
                                    "Manager Archive executor",
                                    diagnostic.capabilities.canArchive ? "Enabled" : "Disabled"
                                )
                                detailRow(
                                    "Lifecycle mutation",
                                    diagnostic.capabilities.canArchive
                                        || diagnostic.capabilities.canUnarchive
                                        || diagnostic.capabilities.canDelete
                                        ? "Available" : "Disabled"
                                )
                                if let runtimeVersion = diagnostic.runtimeVersion {
                                    detailRow("Runtime", runtimeVersion, monospaced: true)
                                }
                                if let userAgent = diagnostic.userAgent {
                                    detailRow("Client user agent", userAgent, monospaced: true)
                                }
                                if let stateStoreURL = model.stateStoreURL {
                                    detailRow("SQLite state", stateStoreURL.path, monospaced: true)
                                }
                                ForEach(diagnostic.messages, id: \.self) { message in
                                    Label(message, systemImage: "info.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    model.selection.count > 1 ? "Multiple Sessions" : "Select a Session",
                    systemImage: "sidebar.right",
                    description: Text(
                        model.selection.count > 1
                            ? "Use the toolbar to Preview a batch operation."
                            : "Identity, lifecycle state, and protection flags appear here."
                    )
                )
            }
        }
        .navigationTitle("Inspector")
    }

    private func conflictActionPanel(
        _ session: SessionPresentation
    ) -> some View {
        let blockedReason = model.conflictResolutionBlockedReason(for: session)
        return VStack(alignment: .leading, spacing: 12) {
            Label("Conflict needs review", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(
                session.displayState == .conflict
                    ? "Codex reports this session as Active while Session Manager still marks it as Trash. Review the frozen evidence before accepting either state."
                    : "The provider inventory no longer contains this Trash member. Review the evidence before changing any manager state."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            Button {
                Task { await model.reviewConflictResolution(for: session) }
            } label: {
                Label("Review Resolution Preview", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.orange)
            .disabled(blockedReason != nil)
            .immediateHelp(
                blockedReason
                    ?? (session.displayState == .conflict
                        ? "Review and confirm the manager-only resolution"
                        : "Open the read-only conflict evidence Preview")
            )

            if let blockedReason {
                Label(blockedReason, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .textSelection(.enabled)
        }
    }

    private func availability(_ available: Bool) -> String {
        available ? "Verified" : "Unavailable"
    }

    private func optionalAvailability(_ available: Bool?) -> String {
        available == true ? "Verified contract" : "Unavailable"
    }

    private func protectionEvidenceRow(_ evidence: ProtectionEvidence) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(evidence.kind.label, systemImage: protectionSymbol(evidence.verdict))
                Spacer()
                Text(evidence.verdict.label)
                    .foregroundStyle(protectionColor(evidence.verdict))
            }
            Text(evidence.source.label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(evidence.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func protectionSymbol(_ verdict: ProtectionEvidenceVerdict) -> String {
        switch verdict {
        case .protected: "lock.fill"
        case .clear: "checkmark.shield"
        case .unavailable: "questionmark.circle"
        }
    }

    private func protectionColor(_ verdict: ProtectionEvidenceVerdict) -> Color {
        switch verdict {
        case .protected: .orange
        case .clear: .green
        case .unavailable: .secondary
        }
    }
}

private extension ByteCountFormatter {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
