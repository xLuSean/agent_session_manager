import AgentSessionManagerCore
import SwiftUI

struct SessionInspectorView: View {
    @EnvironmentObject private var model: SessionManagerModel
    @State private var forkHistoryTarget: ForkHistoryTarget?

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
                                .help(model.conversationFileSizeHelp(for: session))
                            if let issue = model.sessionFileSizeIssues[session.nativeID] {
                                Text(issue.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            detailRow(
                                "Descendants",
                                session.descendantCountKnown ? "\(session.descendantCount)" : "Unavailable"
                            )
                        }

                        detailSection("Fork history") {
                            if let source = model.forkHistoryNodes.first(where: {
                                $0.nativeSessionID == session.nativeID
                            })?.forkedFromNativeSessionID {
                                detailRow("Forked from", model.conversationTitle(for: source))
                                detailRow("Source ID", source, monospaced: true)
                            }
                            Text("Find the source conversation and related forks, including archived conversations.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Review Fork History…") {
                                forkHistoryTarget = .init(id: session.nativeID, title: session.title)
                            }
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
        .sheet(item: $forkHistoryTarget) { target in
            ForkHistorySheet(target: target).environmentObject(model)
        }
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

struct ForkHistoryTarget: Identifiable {
    let id: String
    let title: String
}

struct ForkHistorySheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss
    let target: ForkHistoryTarget
    var onSelection: (() -> Void)? = nil
    @State private var selectedIDs: Set<String> = []

    private var dependentIDs: Set<String> { model.dependentForkHistoryIDs(for: target.id) }

    private var orderedIDs: [String] {
        [target.id] + dependentIDs.sorted()
            + model.forkHistoryIDs(for: target.id).filter { $0 != target.id && !dependentIDs.contains($0) }
    }

    private func relationshipLabel(for id: String) -> String {
        if id == target.id { return "Conversation you are reviewing" }
        if dependentIDs.contains(id) { return "Fork of this conversation — may still reference its history" }
        return "Other related history — not a dependent fork in this inventory"
    }

    private var availableIDs: Set<String> {
        Set(model.sessionRows.filter {
            $0.system == .codex && $0.nativeState != .absent && $0.nativeState != .unavailable
                && $0.liveSession != nil
        }.map(\.nativeID))
    }

    var body: some View {
        let size = NativeDeletePreviewSheetLayout.size(
            visibleScreenSize: (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.size
                ?? CGSize(width: 1_280, height: 800))
        VStack(alignment: .leading, spacing: 14) {
            Label("Fork History", systemImage: "arrow.triangle.branch")
                .font(.title2.bold())
            Text(target.title).font(.headline).textSelection(.enabled)
            Text(target.id).font(.caption.monospaced()).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How to delete this conversation").font(.headline)
                        Text("1. Review the forks below. A fork you keep may still prevent deleting this source.")
                        Text("2. Check the conversations you choose, then select Show Checked in Sessions. Move the ones outside Trash to Trash first.")
                        Text("3. In Trash, select this conversation and those forks, then Delete Permanently. ASM deletes the selected forks first.")
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(dependentIDs.count) forks to review before deleting this conversation")
                            .font(.callout.weight(.semibold))
                        Button("Check this conversation and its forks") {
                            selectedIDs = dependentIDs.union([target.id]).intersection(availableIDs)
                        }
                        .disabled(dependentIDs.union([target.id]).intersection(availableIDs).isEmpty)
                    }
                    if !model.forkHistoryComplete {
                        Label("The relationship inventory is incomplete. Missing rows do not prove there are no forks.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if dependentIDs.isEmpty {
                            Text("No dependent forks were returned. If Codex rejected deletion because of fork history, refresh this inventory. If the fork is still missing, the blocker remains unresolved; deleting a source or an unrelated conversation is not a substitute.")
                                .font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(orderedIDs, id: \.self) { id in
                            let node = model.forkHistoryNodes.first { $0.nativeSessionID == id }
                            HStack(alignment: .top) {
                                Toggle("Select conversation", isOn: Binding(
                                    get: { selectedIDs.contains(id) },
                                    set: { if $0 { selectedIDs.insert(id) } else { selectedIDs.remove(id) } }
                                ))
                                .labelsHidden().toggleStyle(.checkbox)
                                .disabled(!availableIDs.contains(id))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(id == target.id ? target.title : model.conversationTitle(for: id))
                                        .font(.headline).textSelection(.enabled)
                                    Text(id).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(relationshipLabel(for: id))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let source = node?.forkedFromNativeSessionID {
                                        Text("Forked from: \(model.conversationTitle(for: source))")
                                            .font(.callout).textSelection(.enabled)
                                        Text(source).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                    Text(model.sessionRows.first { $0.nativeID == id && $0.system == .codex }?.displayState.label
                                         ?? node?.nativeState.rawValue.capitalized ?? "Not in the loaded inventory")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !availableIDs.contains(id) {
                                        Text("This conversation is not available for selection in the loaded session list.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Show in Sessions") {
                                    reveal([id])
                                }.disabled(!availableIDs.contains(id))
                            }
                            Divider()
                        }
                    }
                    Text("These are relationships reported by Codex, not message contents or a complete historical transcript. If an expected fork is missing, refresh; a missing relationship does not override a Delete rejection.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Refresh Fork History") { Task { await model.reload() } }
                    .disabled(model.isLoading || model.nativeDeleteSubmissionProgress != nil || model.ghostRepairCleanupState.isBusy)
                Spacer()
                Button("Show Checked in Sessions") { reveal(selectedIDs.intersection(availableIDs)) }
                    .disabled(selectedIDs.intersection(availableIDs).isEmpty)
            }
        }
        .padding(22)
        .frame(width: size.width, height: min(680, size.height))
    }

    private func reveal(_ ids: Set<String>) {
        model.selectForkHistoryConversations(ids)
        onSelection?()
        dismiss()
    }
}

private extension ByteCountFormatter {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
