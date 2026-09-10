import AgentSessionManagerCore
import SwiftUI

/// Deliberately separate from the one-shot database repair confirmation.
/// Reviewing, cancelling, or applying this diff never resends official Delete.
private struct GlobalStateCleanupReviewSection: View {
    @EnvironmentObject private var model: SessionManagerModel
    let report: CodexGhostRepairBulkRepairReport
    @State private var engine: CodexGlobalStateCleanup?
    @State private var preview: CodexGlobalStateCleanupPreview?
    @State private var busy = false
    @State private var message = "Not reviewed. No global-state changes have been applied."

    var body: some View {
        GroupBox("Optional: review remaining session settings") {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.caption).textSelection(.enabled)
                Text("Keep Codex closed. Review an exact diff before removing session-specific settings. Automation definitions, other conversations, and working folders are kept. Backups contain the old private data and are kept separately; this is not secure erasure.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Review Global-State Diff…") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let service = try CodexGlobalStateCleanup.production()
                            engine = service
                            preview = try await service.preview(report: report)
                        } catch { message = error.localizedDescription }
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("reviewGlobalStateDiff")
                if busy { ProgressView("Checking the exact session scope…") }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $preview, onDismiss: {
            if let engine { Task { await engine.cancel() } }
        }) { value in
            GlobalStateDiffSheet(preview: value, engine: engine,
                title: { model.ghostRepairBulkDisplayTitle(for: $0) ?? "Title unavailable" },
                completion: { message = $0 })
        }
    }
}

private struct GlobalStateDiffSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: CodexGlobalStateCleanupPreview
    let engine: CodexGlobalStateCleanup?
    let title: (String) -> String
    let completion: (String) -> Void
    @State private var applying = false
    @State private var outcome: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Global-State Cleanup").font(.title2.bold())
            Text("Red − lines show the exact entries to remove. Unchanged data is omitted. This is a semantic diff, not a whole-file formatting diff. Review both the main file and .bak; this confirmation applies the whole displayed batch.")
                .font(.callout).foregroundStyle(.secondary)
            Text("\(preview.threadIDs.count) sessions · \(preview.changes.count) entries · expires at \(preview.expiresAt.formatted(date: .omitted, time: .standard))")
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 16) {
                    if preview.changes.isEmpty {
                        Text("No supported session-specific entries remain. Nothing to apply.")
                    }
                    ForEach(preview.threadIDs, id: \.self) { id in
                        Text(title(id)).font(.headline)
                        Text(id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        ForEach(preview.changes.filter { $0.threadID == id }) { change in
                            Text(change.diff)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let outcome { Text(outcome).font(.caption).textSelection(.enabled) }
            Divider()
            HStack {
                Text("Cancelling keeps these entries; it does not restore the deleted conversation.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(outcome == nil ? "Cancel" : "Close") {
                    if let engine { Task { await engine.cancel() } }
                    dismiss()
                }.disabled(applying)
                Button("Apply This Diff", role: .destructive) {
                    guard let engine else { return }
                    applying = true
                    Task {
                        defer { applying = false }
                        do {
                            let result = try await engine.apply(preview: preview)
                            let text = "Global-state cleanup verified: \(result.removedEntryCount) entries removed. Backup: \(result.backupURL?.path ?? "not needed")."
                            outcome = text; completion(text)
                        } catch {
                            let text = error.localizedDescription
                            outcome = text; completion(text)
                        }
                    }
                }
                .disabled(applying || outcome != nil || preview.changes.isEmpty || engine == nil)
                .accessibilityIdentifier("applyGlobalStateDiff")
            }
        }
        .padding(20)
        .frame(width: min(960, (NSScreen.main?.visibleFrame.width ?? 1080) - 100),
               height: min(720, (NSScreen.main?.visibleFrame.height ?? 820) - 100))
        .interactiveDismissDisabled(applying)
    }
}

enum GhostRepairBulkInventorySheetLayout {
    static let minimumWidth: CGFloat = 980
    static let idealWidth: CGFloat = 1_180
    static let maximumWidth: CGFloat = 1_400
    static let minimumHeight: CGFloat = 640
    static let idealHeight: CGFloat = 780
    static let maximumHeight: CGFloat = 900
    static let inventoryMinimumHeight: CGFloat = 240
    static let inventoryIdealHeight: CGFloat = 360
    static let inventoryMaximumHeight: CGFloat = 480
}

struct GhostRepairBulkInventorySheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @State private var cleanupSelection: Set<String> = []
    @State private var cleanupInventoryDigest = ""
    @State private var isCleanupConfirmationPresented = false
    @State private var isPreviousOperationsRequestInFlight = false
    @State private var isRecoveryReadbackRequestInFlight = false
    @State private var isConfirmationRecoveryRequestInFlight = false
    @State private var isFreshRecoveryRequestInFlight = false
    @State private var isPreparedClosureReviewInFlight = false
    @State private var isPreparedClosureCommitInFlight = false
    @State private var isPreparedClosureRecoveryInFlight = false
    @State private var isPreparedClosureConfirmationPresented = false
    @State private var isDesktopCleanupStatusRequestInFlight = false
    @State private var isLinkedDesktopCleanupPrepareInFlight = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    snapshotInput
                    linkedDesktopCleanup
                    cleanupProgress
                    if showsFinalRepairStage {
                        finalRepairReview
                    }
                    stateContent
                    DisclosureGroup("Recovery tools — normally not needed") {
                        VStack(alignment: .leading, spacing: 12) {
                            previousBulkOperations
                            savedPreviewReadback
                            bulkPreviewContent
                        }
                        .padding(.top, 8)
                    }
                    .font(.caption)
                    .disabled(model.ghostRepairCleanupState.isBusy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .padding(20)
        .frame(
            minWidth: GhostRepairBulkInventorySheetLayout.minimumWidth,
            idealWidth: GhostRepairBulkInventorySheetLayout.idealWidth,
            maxWidth: GhostRepairBulkInventorySheetLayout.maximumWidth,
            minHeight: GhostRepairBulkInventorySheetLayout.minimumHeight,
            idealHeight: GhostRepairBulkInventorySheetLayout.idealHeight,
            maxHeight: GhostRepairBulkInventorySheetLayout.maximumHeight
        )
        .interactiveDismissDisabled(isBusy)
        .onExitCommand {
            guard !isBusy else { return }
            _ = model.setGhostRepairBulkInventoryPresented(false)
        }
        .alert(
            "Clear \(cleanupSelection.count) Ghosts?",
            isPresented: $isCleanupConfirmationPresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Confirm Cleanup", role: .destructive) {
                Task {
                    await model.confirmGhostCleanup(
                        selectedIDs: cleanupSelection,
                        inventoryDigest: cleanupInventoryDigest
                    )
                }
            }
        } message: {
            Text(
                "Only these \(cleanupSelection.count) selected Ghosts will be cleared. Other items will be kept. After you close Codex and continue, the App will check the data, verify a backup, and clear this batch automatically. Automation settings and their enabled/paused status are kept."
                + manualCleanupScope
            )
        }
        .alert(
            "Close this exact unstarted plan?",
            isPresented: $isPreparedClosureConfirmationPresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Close Unstarted Plan") {
                guard !isPreparedClosureCommitInFlight else { return }
                isPreparedClosureCommitInFlight = true
                Task {
                    defer { isPreparedClosureCommitInFlight = false }
                    await model.closeGhostRepairBulkPreparedOperation()
                }
            }
            .disabled(
                isPreparedClosureCommitInFlight
                    || model.ghostRepairBulkPreparedClosureCommitBlockedReason
                        != nil
            )
        } message: {
            Text(
                "This closes only the exact manager-owned prepared plan before any claim or attempt. It does not delete sessions, create a Report, retry, or restore anything."
            )
        }
    }

    private var previousBulkOperations: some View {
        GroupBox("Previous Bulk Operations") {
            VStack(alignment: .leading, spacing: 10) {
                confirmationReceiptRecovery

                HStack {
                    Text(
                        "Load a bounded list of manager-owned operation records only when you explicitly request it."
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Read Previous Operations") {
                        guard !isPreviousOperationsRequestInFlight else {
                            return
                        }
                        isPreviousOperationsRequestInFlight = true
                        Task {
                            defer {
                                isPreviousOperationsRequestInFlight = false
                            }
                            await model.loadGhostRepairBulkPreviousOperations()
                        }
                    }
                    .disabled(
                        isPreviousOperationsRequestInFlight
                            || isRecoveryActionInFlight
                            || model.ghostRepairBulkPreviousOperationsBlockedReason
                                != nil
                    )
                    .accessibilityIdentifier("readPreviousBulkGhostOperations")
                }

                previousBulkOperationsState

                if !model.ghostRepairBulkPreviousOperations.isEmpty {
                    HStack {
                        Button("Read Selected Operation") {
                            guard !isRecoveryReadbackRequestInFlight else {
                                return
                            }
                            isRecoveryReadbackRequestInFlight = true
                            Task {
                                defer {
                                    isRecoveryReadbackRequestInFlight = false
                                }
                                await model
                                    .readSelectedGhostRepairBulkRecoveryOperation()
                            }
                        }
                        .disabled(
                            isRecoveryReadbackRequestInFlight
                                || isConfirmationRecoveryRequestInFlight
                                || isFreshRecoveryRequestInFlight
                                || isPreparedClosureReviewInFlight
                                || isPreparedClosureCommitInFlight
                                || isPreparedClosureRecoveryInFlight
                                || model.ghostRepairBulkRecoveryReadbackBlockedReason
                                    != nil
                        )
                        .accessibilityIdentifier("readSelectedBulkGhostOperation")

                        Button("Check Current Outcome — No Delete") {
                            guard !isFreshRecoveryRequestInFlight else {
                                return
                            }
                            isFreshRecoveryRequestInFlight = true
                            Task {
                                defer {
                                    isFreshRecoveryRequestInFlight = false
                                }
                                await model
                                    .recoverSelectedGhostRepairBulkOperationFreshly()
                            }
                        }
                        .disabled(
                            isFreshRecoveryRequestInFlight
                                || isPreviousOperationsRequestInFlight
                                || isRecoveryReadbackRequestInFlight
                                || isConfirmationRecoveryRequestInFlight
                                || isPreparedClosureReviewInFlight
                                || isPreparedClosureCommitInFlight
                                || isPreparedClosureRecoveryInFlight
                                || model.ghostRepairBulkFreshRecoveryBlockedReason
                                    != nil
                        )
                        .help(
                            model.ghostRepairBulkFreshRecoveryBlockedReason
                                ?? "With Codex closed, freshly read the private Codex after-state and, only when exact, save the original operation's manager Report. No delete, claim, retry, or restore is performed."
                        )
                        .accessibilityIdentifier("checkCurrentBulkGhostOutcome")

                        Button("Review Plan Closure") {
                            guard !isPreparedClosureReviewInFlight else {
                                return
                            }
                            isPreparedClosureReviewInFlight = true
                            Task {
                                defer {
                                    isPreparedClosureReviewInFlight = false
                                }
                                await model
                                    .reviewSelectedGhostRepairBulkPreparedClosure()
                            }
                        }
                        .disabled(
                            isPreparedClosureReviewInFlight
                                || isRecoveryActionInFlight
                                || model
                                    .ghostRepairBulkPreparedClosureReviewBlockedReason
                                    != nil
                        )
                        .help(
                            model
                                .ghostRepairBulkPreparedClosureReviewBlockedReason
                                ?? "Review the exact selected manager-owned prepared plan before choosing whether to close it."
                        )
                        .accessibilityIdentifier(
                            "reviewSelectedBulkGhostPlanClosure"
                        )
                    }
                }

                recoveryReadbackState
                freshRecoveryState
                preparedClosureState

                Text(
                    "Read Previous Operations, Read Selected Operation, and Check Original Confirmation read only Agent Session Manager records; they do not recheck Codex data. Plan Closure reviews and closes only an exact unstarted manager plan; it uses no token and performs no session deletion, claim, attempt, retry, or restore. Check Current Outcome requires Codex to be closed and reads the private Codex after-state; it may only save a newly verified Report for the original operation. An unresolved or not-found result is not success."
                )
                .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private var confirmationReceiptRecovery: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Check Original Confirmation") {
                    guard !isConfirmationRecoveryRequestInFlight else {
                        return
                    }
                    isConfirmationRecoveryRequestInFlight = true
                    Task {
                        defer {
                            isConfirmationRecoveryRequestInFlight = false
                        }
                        await model
                            .recoverUnknownGhostRepairBulkConfirmationReceipt()
                    }
                }
                .disabled(
                    isConfirmationRecoveryRequestInFlight
                        || isPreviousOperationsRequestInFlight
                        || isRecoveryReadbackRequestInFlight
                        || isFreshRecoveryRequestInFlight
                        || isPreparedClosureReviewInFlight
                        || isPreparedClosureCommitInFlight
                        || isPreparedClosureRecoveryInFlight
                        || model
                            .ghostRepairBulkConfirmationReceiptRecoveryBlockedReason
                            != nil
                )
                .help(
                    model.ghostRepairBulkConfirmationReceiptRecoveryBlockedReason
                        ?? "Read only the original manager-owned confirmation record for the current unknown outcome. No phrase or token is displayed."
                )
                .accessibilityIdentifier("checkOriginalBulkGhostConfirmation")
                Spacer()
            }
            confirmationReceiptRecoveryState
        }
    }

    @ViewBuilder
    private var confirmationReceiptRecoveryState: some View {
        switch model.ghostRepairBulkConfirmationReceiptRecoveryState {
        case .idle:
            EmptyView()
        case let .reading(_, request):
            Label {
                Text(
                    "Checking original confirmation for operation \(request.operationID.uuidString.lowercased())…"
                )
            } icon: {
                ProgressView().controlSize(.small)
            }
            .textSelection(.enabled)
        case let .confirmed(request, _):
            Label(
                "Original confirmation is recorded for operation \(request.operationID.uuidString.lowercased()).",
                systemImage: "checkmark.seal.fill"
            )
            .foregroundStyle(.green)
            .textSelection(.enabled)
        case let .recoveryRequired(request, _, message):
            Label(
                "Operation \(request.operationID.uuidString.lowercased()) still requires recovery. \(message)",
                systemImage: "exclamationmark.octagon.fill"
            )
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var previousBulkOperationsState: some View {
        switch model.ghostRepairBulkPreviousOperationsState {
        case .idle:
            Text("No previous-operation read has been requested.")
                .foregroundStyle(.secondary)
        case .loading:
            Label {
                Text("Reading previous manager-owned operations…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case .observed:
            List(selection: recoveryOperationSelection) {
                ForEach(
                    model.ghostRepairBulkPreviousOperations,
                    id: \.identity
                ) { operation in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(operation.identity.operationID.uuidString.lowercased())
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 12) {
                            Text("Phase: \(operation.phase.rawValue)")
                            Text("Selected: \(operation.selectedCount)")
                            Text("Attempts: \(operation.mutationAttemptCount)")
                            Text(recoveryRecordedDate(operation.recordedAtMilliseconds))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .tag(operation.identity)
                }
            }
            .frame(minHeight: 150, idealHeight: 190, maxHeight: 240)
            .disabled(
                isRecoveryReadbackRequestInFlight
                    || isConfirmationRecoveryRequestInFlight
                    || isFreshRecoveryRequestInFlight
                    || isPreparedClosureReviewInFlight
                    || isPreparedClosureCommitInFlight
            )
            .accessibilityIdentifier("previousBulkGhostOperationsList")
        case .empty:
            ContentUnavailableView(
                "No previous operations",
                systemImage: "tray",
                description: Text("No manager-owned Bulk Ghost Delete operation records were found.")
            )
        case let .limitExceeded(limit, foundAtLeast, message):
            Label(
                "Limit exceeded: found at least \(foundAtLeast) records; the bounded limit is \(limit). No partial first-\(limit) list is shown. \(message)",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        case let .unavailable(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var freshRecoveryState: some View {
        switch model.ghostRepairBulkFreshRecoveryState {
        case .idle:
            EmptyView()
        case let .recovering(_, identity):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Freshly checking the current private Codex after-state…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                recoveryIdentity(identity)
            }
        case let .terminal(summary, report, source):
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    source == .existingJournal
                        ? "Recorded terminal Report"
                        : "New readback saved for original operation"
                )
                .fontWeight(.semibold)
                recoveryIdentity(summary.identity)
                terminalRowsView(report)
            }
        case let .closedBeforeAttempt(summary, closure):
            closedPreparedPlanView(summary: summary, closure: closure)
        case let .recoveryRequired(summary, message):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Current outcome remains unresolved. \(message)",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .foregroundStyle(.orange)
                recoveryIdentity(summary.identity)
            }
        case let .notFound(identity):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "The original operation was not found. This is not a successful outcome.",
                    systemImage: "questionmark.folder.fill"
                )
                .foregroundStyle(.orange)
                recoveryIdentity(identity)
            }
        case let .unavailable(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var recoveryOperationSelection:
        Binding<CodexGhostRepairBulkRecoveryOperationIdentity?>
    {
        Binding(
            get: { model.ghostRepairBulkSelectedRecoveryOperationIdentity },
            set: { model.setGhostRepairBulkRecoveryOperationSelected($0) }
        )
    }

    @ViewBuilder
    private var recoveryReadbackState: some View {
        switch model.ghostRepairBulkRecoveryReadbackState {
        case .idle:
            EmptyView()
        case let .reading(_, identity):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Reading selected manager-owned operation…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                recoveryIdentity(identity)
            }
        case let .terminal(summary, report):
            VStack(alignment: .leading, spacing: 6) {
                Text("Recorded terminal Report").fontWeight(.semibold)
                recoveryIdentity(summary.identity)
                terminalRowsView(report)
            }
        case let .closedBeforeAttempt(summary, closure):
            closedPreparedPlanView(summary: summary, closure: closure)
        case let .recoveryRequired(summary, message):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Unresolved operation — exact recovery is still required. \(message)",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .foregroundStyle(.orange)
                recoveryIdentity(summary.identity)
            }
        case let .notFound(identity):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "The exact selected operation was not found. This is not a successful outcome.",
                    systemImage: "questionmark.folder.fill"
                )
                .foregroundStyle(.orange)
                recoveryIdentity(identity)
            }
        case let .unavailable(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func recoveryIdentity(
        _ identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Request ID: \(identity.requestID.uuidString.lowercased())")
            Text("Operation ID: \(identity.operationID.uuidString.lowercased())")
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var preparedClosureState: some View {
        switch model.ghostRepairBulkPreparedClosureState {
        case .idle:
            EmptyView()
        case let .reviewing(_, identity):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Reviewing the exact unstarted prepared plan…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                recoveryIdentity(identity)
            }
        case let .reviewReady(preview):
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan Closure Review").fontWeight(.semibold)
                recoveryIdentity(preview.identity)
                closureReceiptIdentity(preview.confirmationReceiptID)
                closureRowsView(preview.selectedItems)
                Text(
                    "Closing affects only this manager-owned prepared plan. It does not delete sessions and does not create a terminal Repair Report."
                )
                .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel Closure Review", role: .cancel) {
                        model.cancelGhostRepairBulkPreparedClosureReview()
                    }
                    .disabled(
                        isPreparedClosureReviewInFlight
                            || isPreparedClosureCommitInFlight
                            || isPreparedClosureRecoveryInFlight
                    )
                    Spacer()
                    Button("Close Unstarted Plan") {
                        isPreparedClosureConfirmationPresented = true
                    }
                    .disabled(
                        isPreparedClosureCommitInFlight
                            || model
                                .ghostRepairBulkPreparedClosureCommitBlockedReason
                                != nil
                    )
                    .help(
                        model
                            .ghostRepairBulkPreparedClosureCommitBlockedReason
                            ?? "Confirm closure of this exact unstarted manager-owned plan."
                    )
                    .accessibilityIdentifier("closeUnstartedBulkGhostPlan")
                }
            }
        case let .closing(_, preview):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Closing the exact unstarted prepared plan…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                recoveryIdentity(preview.identity)
                closureReceiptIdentity(preview.confirmationReceiptID)
            }
        case let .closedBeforeAttempt(summary, closure, newlyClosed):
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    newlyClosed
                        ? "Unstarted plan closed"
                        : "Previously closed unstarted plan"
                )
                .fontWeight(.semibold)
                closedPreparedPlanView(summary: summary, closure: closure)
            }
        case let .persistenceUncertain(preview, message):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Closure outcome is unresolved. \(message)",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .foregroundStyle(.orange)
                recoveryIdentity(preview.identity)
                closureReceiptIdentity(preview.confirmationReceiptID)
                exactClosureOutcomeReadButton
            }
        case let .recoveryRequired(summary, message):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Closure requires exact readback. \(message)",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .foregroundStyle(.orange)
                recoveryIdentity(summary.identity)
                exactClosureOutcomeReadButton
            }
        case let .notFound(identity):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "The exact prepared plan was not found. It was not closed.",
                    systemImage: "questionmark.folder.fill"
                )
                .foregroundStyle(.orange)
                recoveryIdentity(identity)
            }
        case let .unavailable(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var exactClosureOutcomeReadButton: some View {
        Button("Read Exact Closure Outcome") {
            guard !isPreparedClosureRecoveryInFlight else { return }
            isPreparedClosureRecoveryInFlight = true
            Task {
                defer { isPreparedClosureRecoveryInFlight = false }
                await model.readUncertainGhostRepairBulkPreparedClosure()
            }
        }
        .disabled(
            isPreparedClosureRecoveryInFlight
                || model.ghostRepairBulkPreparedClosureRecoveryBlockedReason
                    != nil
        )
        .help(
            model.ghostRepairBulkPreparedClosureRecoveryBlockedReason
                ?? "Read the exact manager-owned closure record without accessing or changing Codex sessions."
        )
        .accessibilityIdentifier("readUncertainBulkGhostPlanClosure")
    }

    private func closedPreparedPlanView(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        closure: CodexGhostRepairBulkPreparedClosureRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Closed before claim or attempt",
                systemImage: "xmark.seal.fill"
            )
            .foregroundStyle(.secondary)
            recoveryIdentity(summary.identity)
            closureReceiptIdentity(closure.confirmationReceiptID)
            closureRowsView(closure.selectedItems)
            Text(
                "This is a manager-owned plan closure, not a successful Repair Report. No sessions were deleted."
            )
            .foregroundStyle(.secondary)
        }
    }

    private func closureReceiptIdentity(_ receiptID: UUID) -> some View {
        Text("Receipt ID: \(receiptID.uuidString.lowercased())")
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
    }

    private func desktopCleanupSymbol(
        _ state: NativeDeleteDesktopCleanupTargetState
    ) -> String {
        switch state {
        case .pending: "clock"
        case .eligible: "checkmark.circle.fill"
        case .blocked: "xmark.octagon.fill"
        case .outcomeUnknown: "questionmark.diamond.fill"
        case .verified: "checkmark.seal.fill"
        }
    }

    private func desktopCleanupColor(
        _ state: NativeDeleteDesktopCleanupTargetState
    ) -> Color {
        switch state {
        case .pending: .secondary
        case .eligible: .blue
        case .blocked, .outcomeUnknown: .orange
        case .verified: .green
        }
    }

    private func closureRowsView(
        _ items: [CodexGhostRepairBulkPreparedClosureItem]
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.threadID) { item in
                    HStack {
                        sessionIdentity(threadID: item.threadID)
                        Spacer()
                        Text(categoryLabel(item.category))
                    }
                }
            }
        }
        .frame(maxHeight: 150)
    }

    private func recoveryRecordedDate(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .standard)
    }

    private var savedPreviewReadback: some View {
        GroupBox("Cold-start saved Preview readback") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(
                        "Exact Request ID from Saved Preview",
                        text: $model.ghostRepairBulkSavedPreviewRequestIDDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(workflowMutationBlockedReason != nil)
                    .accessibilityIdentifier("bulkGhostSavedPreviewRequestID")
                    Button {
                        Task { await model.readSavedGhostRepairBulkPreview() }
                    } label: {
                        if case .reading =
                            model.ghostRepairBulkPreviewReadbackState {
                            Label {
                                Text("Reading…")
                            } icon: {
                                ProgressView().controlSize(.small)
                            }
                        } else {
                            Label("Read Saved Preview", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .disabled(
                        isReadingSavedPreview
                            || workflowMutationBlockedReason != nil
                    )
                    .accessibilityIdentifier("readSavedBulkGhostPreview")
                }
                switch model.ghostRepairBulkPreviewReadbackState {
                case .idle:
                    Text(
                        "Reads only Agent Session Manager's saved Preview record. It does not reopen the snapshot or contact Codex."
                    )
                    .foregroundStyle(.secondary)
                case .reading:
                    Text("Reading one exact manager-owned record…")
                        .foregroundStyle(.secondary)
                case let .unavailable(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case let .observed(evidence):
                    HStack {
                        Label(
                            "Saved Preview readback matched",
                            systemImage: "checkmark.shield.fill"
                        )
                        .foregroundStyle(.green)
                        Spacer()
                        Text("\(evidence.preview.selectedItems.count) selected")
                        Text("\(evidence.preview.blockedItems.count) blocked")
                        PasteboardCopyButton(
                            text: evidence.requestID.uuidString.lowercased(),
                            help: "Copy exact saved Preview Request ID",
                            minimumWidth: 120,
                            buttonTitle: "Copy Request ID",
                            copiedButtonTitle: "Request ID Copied"
                        )
                    }
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var cleanupProgress: some View {
        switch model.ghostRepairCleanupState {
        case .idle, .finished:
            EmptyView()
        case .preparing:
            ProgressView("Saving your confirmed cleanup…")
        case .awaitingShutdown:
            GroupBox("Close Codex to continue") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quit Codex and stop Codex sessions in terminals or editor extensions. Keep Agent Session Manager open. The App will verify that no writer remains before backing up and clearing your confirmed batch.")
                    Button(shutdownContinuationTitle, role: .destructive) {
                        Task { await model.continueGhostCleanupAfterShutdown() }
                    }
                    .disabled(isBusy || isRecoveryActionInFlight)
                    .accessibilityIdentifier("continueGhostCleanupAfterShutdown")
                }
            }
        case .running:
            ProgressView("Checking, backing up, and clearing the confirmed Ghosts…")
        case let .stopped(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var finalRepairReview: some View {
        GroupBox("Cleanup result") {
            VStack(alignment: .leading, spacing: 10) {
                if model.ghostRepairCleanupState == .running {
                    Text("Keep Codex closed and Agent Session Manager open until the result appears.")
                        .foregroundStyle(.secondary)
                }

                switch model.ghostRepairBulkRepairState {
                case .idle:
                    EmptyView()
                case .preparingReview:
                    ProgressView("Checking the confirmed data and verifying a backup…")
                case .reviewReady:
                    Text(model.ghostRepairCleanupState == .running
                        ? "Backup verified. Continuing with the confirmed cleanup…"
                        : "Cleanup is paused. Check the reason above and the saved operation in recovery tools."
                    )
                        .foregroundStyle(.secondary)
                case .executing:
                    Label {
                        Text(
                            "Executing once and writing the itemized terminal Report. Do not reopen Codex or close this App."
                        )
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .foregroundStyle(.orange)
                case let .completed(report):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Terminal outcome: \(report.outcome.rawValue)",
                            systemImage: report.outcome == .success
                                ? "checkmark.seal.fill"
                                : "exclamationmark.octagon.fill"
                        )
                        .foregroundStyle(
                            report.outcome == .success ? .green : .orange
                        )
                        terminalRowsView(report)
                        if report.outcome == .success {
                            GlobalStateCleanupReviewSection(report: report)
                        }
                        Text(report.outcome == .success
                            ? "Conversation cleanup is verified. Global-state cleanup is a separate optional review below; it has not been included in this Report. After any additional cleanup, reopen Codex once and verify the processed IDs stay absent from the sidebar, Search, and Archived. If any item returns, do not run Ghost Delete again."
                            : "This Report is terminal. Do not retry or restore from this screen."
                        )
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    }
                case let .closedBeforeAttempt(closure):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Unstarted plan closed",
                            systemImage: "xmark.seal.fill"
                        )
                        .foregroundStyle(.secondary)
                        recoveryIdentity(closure.identity)
                        closureReceiptIdentity(closure.confirmationReceiptID)
                        closureRowsView(closure.selectedItems)
                        Text(
                            "This is a manager-owned plan closure, not a Ghost Delete Report. No claim or mutation attempt was made."
                        )
                        .foregroundStyle(.secondary)
                    }
                case let .recoveryRequired(_, message):
                    Label(
                        "Exact readback required — do not retry: \(message)",
                        systemImage: "exclamationmark.octagon.fill"
                    )
                    .foregroundStyle(.orange)
                case let .unavailable(message):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            message,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    }
                }
            }
            .font(.caption)
        }
    }

    private func terminalRowsView(
        _ report: CodexGhostRepairBulkRepairReport
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(report.itemReports, id: \.threadID) { item in
                    HStack {
                        sessionIdentity(threadID: item.threadID)
                        Spacer()
                        Text(categoryLabel(item.category))
                        Text(item.outcome.rawValue)
                            .foregroundStyle(
                                item.outcome == .unknown ? .orange : .primary
                            )
                    }
                }
            }
        }
        .frame(maxHeight: 150)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Bulk Ghost Delete", systemImage: "list.bullet.clipboard")
                .font(.title.bold())
            Text(
                "Scan for Ghosts, review the items to keep or clear, and confirm once. After you close Codex, the App checks the data, verifies a backup, clears the confirmed batch, and shows the results."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var snapshotInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let inventory = model.ghostRepairBulkInventory {
                GroupBox(model.ghostRepairBulkCompletedScanReport == nil
                    ? "Verified current scan" : "Scan reconciled with cleanup result") {
                    HStack {
                        Label(
                            model.ghostRepairBulkCompletedScanReport?.outcome == .success
                                ? "Cleanup complete" : "Scan complete",
                            systemImage: "checkmark.shield.fill"
                        )
                        .foregroundStyle(.green)
                        Spacer()
                        Text("\(model.ghostRepairBulkRemainingItems.filter(\.selectable).count) eligible remaining")
                    }
                }
                if model.ghostRepairBulkCompletedScanReport == nil {
                    Toggle("Manual confirmation / force cleanup of known session residue", isOn: Binding(
                        get: { model.ghostRepairBulkInventory?.manualReviewEnabled == true },
                        set: { model.setGhostRepairManualReviewEnabled($0) }
                    ))
                    .disabled(model.ghostRepairCleanupState != .idle || isBusy
                        || model.ghostRepairBulkWorkflowMutationBlockedReason != nil
                        || model.nativeDeleteDesktopCleanupSelectionBlockedReason != nil)
                    .accessibilityIdentifier("manualGhostResidueReview")
                    if inventory.manualReviewEnabled {
                        Text("Selected session summaries will also be deleted. Automation settings and schedules stay unchanged. Readable, unconfirmed, pinned and parent sessions remain protected. Review the selected IDs before confirming.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            } else {
                GroupBox("Find Ghosts") {
                    HStack(spacing: 12) {
                        preparationStatus
                        Spacer()
                        Button {
                            guard !isLinkedDesktopCleanupPrepareInFlight else {
                                return
                            }
                            isLinkedDesktopCleanupPrepareInFlight = true
                            Task {
                                defer {
                                    isLinkedDesktopCleanupPrepareInFlight = false
                                }
                                await model.prepareGhostRepairBulkInventory()
                            }
                        } label: {
                            if isPreparing {
                                Label {
                                    Text("Preparing…")
                                } icon: {
                                    ProgressView().controlSize(.small)
                                }
                            } else {
                                Label(
                                    "Scan for Ghosts",
                                    systemImage: "wand.and.stars"
                                )
                            }
                        }
                        .disabled(
                            isLinkedDesktopCleanupPrepareInFlight
                                || isRecoveryActionInFlight
                                || bulkInventoryPreparationBlockedReason
                                    != nil
                        )
                        .help(
                            bulkInventoryPreparationBlockedReason
                                ?? "Scan the current local catalog and verify each candidate."
                        )
                        .accessibilityIdentifier(
                            "prepareBulkGhostInventory"
                        )
                    }
                }
            }
        }
    }

    private var manualCleanupScope: String {
        let items = model.ghostRepairBulkInventory?.items.filter {
            cleanupSelection.contains($0.threadID) && $0.reviewedResidue != nil
        } ?? []
        guard !items.isEmpty else { return "" }
        let summaries = items.reduce(0) { $0 + ($1.reviewedResidue?.summaryRowDigests.count ?? 0) }
        return " MANUAL REVIEW: This also deletes \(summaries) summary record(s) belonging only to \(items.count) selected session(s). Automation definitions are NOT deleted or changed."
    }

    private var shutdownContinuationTitle: String {
        if case .unavailable = model.ghostRepairBulkRepairState {
            return "Codex Is Closed — Recheck and Continue"
        }
        return "Codex Is Closed — Start Cleanup"
    }

    @ViewBuilder
    private var linkedDesktopCleanup: some View {
        if let title = model.nativeDeleteDesktopCleanupTitle {
            GroupBox(title) {
                VStack(alignment: .leading, spacing: 8) {
                    if let summary = model.nativeDeleteDesktopCleanupSummary {
                        Text(summary)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(model.nativeDeleteDesktopCleanupTargets) { target in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(
                                        systemName: desktopCleanupSymbol(
                                            target.state
                                        )
                                    )
                                    .foregroundStyle(
                                        desktopCleanupColor(target.state)
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.nativeSessionID)
                                            .font(
                                                .system(
                                                    .caption,
                                                    design: .monospaced
                                                )
                                            )
                                            .textSelection(.enabled)
                                        HStack(spacing: 8) {
                                            if let category = target.category {
                                                Text(categoryLabel(category))
                                            }
                                            Text(target.message)
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                    HStack {
                        Button("Cancel Desktop Cleanup Handoff", role: .cancel) {
                            model.cancelNativeDeleteDesktopCleanupHandoff()
                        }
                        .disabled(
                            isDesktopCleanupStatusRequestInFlight
                                || isLinkedDesktopCleanupPrepareInFlight
                                || model
                                    .nativeDeleteDesktopCleanupCancelBlockedReason
                                    != nil
                        )
                        .help(
                            model.nativeDeleteDesktopCleanupCancelBlockedReason
                                ?? "Cancel this exact manager-owned handoff without changing Codex sessions."
                        )
                        Spacer()
                        Button("Read Cleanup Status") {
                            guard !isDesktopCleanupStatusRequestInFlight else {
                                return
                            }
                            isDesktopCleanupStatusRequestInFlight = true
                            Task {
                                defer {
                                    isDesktopCleanupStatusRequestInFlight = false
                                }
                                await model.readNativeDeleteDesktopCleanupStatus()
                            }
                        }
                        .disabled(
                            isDesktopCleanupStatusRequestInFlight
                                || model
                                    .nativeDeleteDesktopCleanupStatusBlockedReason
                                    != nil
                        )
                        .help(
                            model.nativeDeleteDesktopCleanupStatusBlockedReason
                                ?? "Read only the exact manager-owned status for the linked cleanup operation."
                        )
                    }
                }
                .font(.caption)
            }
        }
    }

    private var bulkInventoryPreparationBlockedReason: String? {
        model.nativeDeleteDesktopCleanupTitle == nil
            ? model.ghostRepairBulkPreparationBlockedReason
            : model.nativeDeleteDesktopCleanupPrepareBlockedReason
    }

    @ViewBuilder
    private var preparationStatus: some View {
        switch model.ghostRepairBulkPreparationState {
        case .idle:
            Text(
                "One click reads the current local catalog, confirms local-state absence, verifies every candidate with an exact Codex read, and classifies the complete catalog."
            )
            .foregroundStyle(.secondary)
        case let .preparing(stage):
            Label(stage.rawValue, systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .ready:
            Label("Ghost inventory is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .blocked(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.ghostRepairBulkInventoryState {
        case .disabled:
            unavailable(
                title: "Bulk inventory is disabled",
                detail: "Enable it in Settings before running a scan."
            )
        case .idle:
            ContentUnavailableView(
                "Ready to prepare the complete inventory",
                systemImage: "list.bullet.clipboard",
                description: Text(
                    "Press Prepare Ghost Inventory once. The App performs the two-signal check and complete classification automatically."
                )
            )
        case .observing:
            ContentUnavailableView {
                Label("Reading complete evidence…", systemImage: "hourglass")
            } description: {
                Text(
                    "The result appears only if the complete local catalog, official inventory, pin, descendant, and exact-read evidence agrees."
                )
            }
        case let .ready(inventory):
            inventoryContent(inventory)
        case let .unavailable(_, stage):
            unavailable(
                title: "No inventory was shown",
                detail: failureExplanation(stage)
            )
        }
    }

    private func inventoryContent(
        _ inventory: CodexGhostRepairBulkInventory
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                metric(model.ghostRepairBulkCompletedScanReport == nil ? "Observed" : "Remaining from scan", model.ghostRepairBulkRemainingItems.count)
                metric("Confirmed ghosts", model.ghostRepairBulkRemainingItems.filter(\.confirmedGhost).count)
                metric("Eligible", model.ghostRepairBulkRemainingItems.filter(\.selectable).count, color: .green)
                metric("Kept / unresolved", inventory.blockedItemCount, color: .orange)
                metric("Not ghosts", inventory.notGhostItemCount)
                Spacer()
            }

            Picker("Show", selection: $model.ghostRepairBulkFilter) {
                ForEach(CodexGhostRepairInventoryFilter.allCases, id: \.self) { filter in
                    Text("\(filter.rawValue) (\(model.ghostRepairBulkFilterCount(filter)))")
                        .tag(filter)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("bulkGhostCategoryFilter")

            if model.ghostRepairBulkFilter == .localData {
                Text("These sessions still have local conversation data. They are not confirmed ghosts and cannot be selected for cleanup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Search this list", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("Title, session ID or status — e.g. eligible, blocked, unconfirmed",
                                  text: $model.ghostRepairBulkSearchText)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .accessibilityLabel("Search this list by title, session ID, status, category, or blocker")
                            .accessibilityIdentifier("bulkGhostSearch")
                        if !model.ghostRepairBulkSearchText.isEmpty {
                            Button {
                                model.ghostRepairBulkSearchText = ""
                                isSearchFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                            .help("Clear the search without changing the selection")
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                        isSearchFocused ? Color.accentColor : Color.primary.opacity(0.4),
                        lineWidth: isSearchFocused ? 2 : 1
                    ))
                }

                Toggle(
                    "Selected only",
                    isOn: Binding(
                        get: { model.isShowingSelectedGhostRepairBulkItemsOnly
                            && !model.ghostRepairBulkDisplayedSelection.isEmpty },
                        set: { model.isShowingSelectedGhostRepairBulkItemsOnly = $0 }
                    )
                )
                .toggleStyle(.button)
                .disabled(model.ghostRepairBulkDisplayedSelection.isEmpty)
                .accessibilityIdentifier("bulkGhostSelectedOnly")

                Button("Select All Eligible") {
                    model.selectAllEligibleGhostRepairBulkItems()
                }
                .disabled(
                    model.ghostRepairBulkRemainingItems.allSatisfy({ !$0.selectable })
                        || workflowMutationBlockedReason != nil
                )
                .accessibilityIdentifier("bulkGhostSelectAllEligible")

                Button("Clear Selection") {
                    model.clearGhostRepairBulkSelection()
                }
                .disabled(
                    model.ghostRepairBulkDisplayedSelection.isEmpty
                        || workflowMutationBlockedReason != nil
                )
                .accessibilityIdentifier("bulkGhostClearSelection")
            }

            HStack {
                Text("\(model.ghostRepairBulkVisibleItems.count) shown")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.ghostRepairBulkDisplayedSelection.count) eligible selected")
                    .fontWeight(.semibold)
                Button("Clear Selected Ghosts…", role: .destructive) {
                    cleanupSelection = model.ghostRepairBulkSelection
                    cleanupInventoryDigest = inventory.inventoryDigest
                    isCleanupConfirmationPresented = true
                }
                .disabled(
                    model.ghostRepairBulkDisplayedSelection.isEmpty
                        || isSavingPreview
                        || workflowMutationBlockedReason != nil
                )
                .accessibilityIdentifier("confirmGhostCleanup")
            }
            .font(.caption)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.ghostRepairBulkVisibleItems.isEmpty {
                        Text(model.ghostRepairBulkClearedThreadIDs.isEmpty
                            ? "No items match this search."
                            : "No remaining items match this search. Cleared sessions are listed in the result above.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(
                        model.ghostRepairBulkVisibleItems,
                        id: \.threadID
                    ) { item in
                        inventoryRow(item)
                        Divider()
                    }
                }
            }
            .frame(
                minHeight:
                    GhostRepairBulkInventorySheetLayout.inventoryMinimumHeight,
                idealHeight:
                    GhostRepairBulkInventorySheetLayout.inventoryIdealHeight,
                maxHeight:
                    GhostRepairBulkInventorySheetLayout.inventoryMaximumHeight
            )
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(
                "Search and category filters keep your selection. Only selected eligible items will be cleared. To review the whole selection, choose All scanned items and clear the search."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bulkPreviewContent: some View {
        switch model.ghostRepairBulkPreviewState {
        case .idle:
            EmptyView()
        case let .unavailable(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case let .saving(_, preview):
            previewGroup(
                preview: preview,
                receipt: nil
            )
        case let .saved(preview, receipt):
            previewGroup(
                preview: preview,
                receipt: receipt
            )
        }
    }

    private func previewGroup(
        preview: CodexGhostRepairBulkPreview,
        receipt: CodexGhostRepairBulkPreviewPersistenceReceipt?
    ) -> some View {
        GroupBox("Frozen whole-batch Preview") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        metric("Selected", preview.selectedItems.count)
                        metric("Ordinary", preview.ordinarySelectedCount)
                        metric("Automation", preview.automationSelectedCount)
                        metric("Blocked outside batch", preview.blockedItems.count)
                        metric(
                            "Eligible not selected",
                            preview.unselectedEligibleThreadIDs.count
                        )
                        Spacer()
                        PasteboardCopyButton(
                            text: bulkPreviewSummary(preview),
                            help: "Copy the complete frozen batch summary",
                            minimumWidth: 190,
                            buttonTitle: "Copy Preview Summary",
                            copiedButtonTitle: "Preview Summary Copied"
                        )
                        .accessibilityIdentifier("copyBulkGhostPreviewSummary")
                    }
                    Label(
                        "All-or-nothing batch; one exact whole-batch confirmation is required before final Ghost Delete review.",
                        systemImage: "checkmark.shield"
                    )
                    .foregroundStyle(.green)
                    if receipt != nil {
                        HStack {
                            Label(
                                "Saved and read back exactly",
                                systemImage: "externaldrive.badge.checkmark"
                            )
                            .foregroundStyle(.green)
                            Spacer()
                            Text(
                                "Recovery details are available in the collapsed section below."
                            )
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Saving to Agent Session Manager and reading it back…")
                        }
                    }
                    Text(
                        "No confirmation authority · no deletion authority · changing the selection invalidates this Preview"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
    }

    private func bulkPreviewSummary(
        _ preview: CodexGhostRepairBulkPreview
    ) -> String {
        let selected = preview.selectedItems.map { item in
            "\(item.threadID)\t\(categoryLabel(item.category))\t\(item.evidenceDigest)"
        }.joined(separator: "\n")
        let blocked = preview.blockedItems.map { item in
            let reasons = item.blockers.map(blockerLabel).joined(separator: ", ")
            return "\(item.threadID)\t\(reasons)\t\(item.evidenceDigest)"
        }.joined(separator: "\n")
        return """
        BULK GHOST FROZEN PREVIEW
        Scan: \(preview.snapshotReference)
        Inventory digest: \(preview.inventoryDigest)
        Preview ID: \(preview.previewID.uuidString.lowercased())
        Manifest digest: \(preview.manifestDigest)
        Selected: \(preview.selectedItems.count)
        Ordinary: \(preview.ordinarySelectedCount)
        Automation: \(preview.automationSelectedCount)
        Blocked outside batch: \(preview.blockedItems.count)
        Eligible not selected: \(preview.unselectedEligibleThreadIDs.count)
        All or nothing: Yes
        Single whole-batch confirmation: Required later
        Confirmation authority: None
        Repair mutation authority: None

        SELECTED ITEMS
        \(selected)

        BLOCKED ITEMS
        \(blocked)
        """
    }

    private func inventoryRow(
        _ item: CodexGhostRepairBulkInventoryItem
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: {
                        model.isGhostRepairBulkItemSelected(item.threadID)
                    },
                    set: {
                        model.setGhostRepairBulkItemSelected(
                            item.threadID,
                            isSelected: $0
                        )
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(
                !item.selectable || workflowMutationBlockedReason != nil
            )
            .accessibilityLabel("Select \(model.ghostRepairBulkDisplayTitle(for: item.threadID) ?? "session"), \(item.threadID)")

            VStack(alignment: .leading, spacing: 4) {
                sessionIdentity(threadID: item.threadID)
                HStack(spacing: 8) {
                    Label(
                        item.initiallyAbsent == true ? "Already clear"
                            : item.retentionExplanation ?? dispositionLabel(item.disposition),
                        systemImage: dispositionSymbol(item.disposition)
                    )
                    .foregroundStyle(dispositionColor(item.disposition))
                    if let category = item.category {
                        Text(categoryLabel(category))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                if let scope = item.reviewedResidue {
                    Text("Manual review: delete \(scope.summaryRowDigests.count) session summary record(s); preserve automation settings.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !item.blockers.isEmpty {
                    Text(item.blockers.map(blockerLabel).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func sessionIdentity(threadID: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            let title = model.ghostRepairBulkDisplayTitle(for: threadID)
            Text(title ?? "Title unavailable")
                .font(.body.weight(.medium))
                .foregroundStyle(title == nil ? .secondary : .primary)
                .lineLimit(2)
                .help(title ?? "No session title is available; use the exact ID below.")
                .textSelection(.enabled)
            Text(threadID)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = footerBlockedReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Label(
                    model.ghostRepairBulkCompletedScanReport == nil
                        ? "Confirm the selected batch once, close Codex, then continue. Checks and a verified backup complete before cleanup."
                        : model.ghostRepairBulkCompletedScanReport?.outcome == .success
                            ? "Cleanup complete. Results are kept above. Start a new scan before another cleanup."
                            : "Cleanup has ended. Review the result above; do not retry or restore from this screen.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                Spacer()
                Button("New Scan") {
                    _ = model.startNewGhostRepairBulkPreparation()
                }
                .disabled(
                    isBusy
                        || !model.canStartNewGhostRepairBulkPreparation
                )
                .accessibilityIdentifier("startNewBulkGhostPreparation")
                Button("Close") {
                    _ = model.setGhostRepairBulkInventoryPresented(false)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
                .fixedSize()
            }
        }
    }

    private var isPreparing: Bool {
        if case .preparing = model.ghostRepairBulkPreparationState {
            return true
        }
        return false
    }

    private var showsFinalRepairStage: Bool {
        switch model.ghostRepairBulkRepairState {
        case .idle:
            return model.ghostRepairBulkConfirmationReceipt != nil
        case .preparingReview, .reviewReady, .executing, .completed,
             .closedBeforeAttempt, .recoveryRequired, .unavailable:
            return true
        }
    }

    private var isSavingPreview: Bool {
        if case .saving = model.ghostRepairBulkPreviewState { return true }
        return false
    }

    private var isReadingSavedPreview: Bool {
        if case .reading = model.ghostRepairBulkPreviewReadbackState {
            return true
        }
        return false
    }

    private var isBusy: Bool {
        model.ghostRepairCleanupState.isBusy
            || model.ghostRepairBulkDismissBlockedReason != nil
            || isPreviousOperationsRequestInFlight
            || isRecoveryReadbackRequestInFlight
            || isConfirmationRecoveryRequestInFlight
            || isFreshRecoveryRequestInFlight
            || isPreparedClosureReviewInFlight
            || isPreparedClosureCommitInFlight
            || isPreparedClosureRecoveryInFlight
            || isDesktopCleanupStatusRequestInFlight
            || isLinkedDesktopCleanupPrepareInFlight
    }

    private var workflowMutationBlockedReason: String? {
        if model.ghostRepairCleanupState != .idle {
            return "Finish the current cleanup before changing its selection."
        }
        if isConfirmationRecoveryRequestInFlight
            || isFreshRecoveryRequestInFlight
            || isPreparedClosureReviewInFlight
            || isPreparedClosureCommitInFlight
            || isPreparedClosureRecoveryInFlight {
            return "Wait for the explicit recovery read to finish."
        }
        return model.ghostRepairBulkWorkflowMutationBlockedReason
    }

    private var isRecoveryActionInFlight: Bool {
        isRecoveryReadbackRequestInFlight
            || isConfirmationRecoveryRequestInFlight
            || isFreshRecoveryRequestInFlight
            || isPreparedClosureReviewInFlight
            || isPreparedClosureCommitInFlight
            || isPreparedClosureRecoveryInFlight
            || isDesktopCleanupStatusRequestInFlight
            || isLinkedDesktopCleanupPrepareInFlight
    }

    private var footerBlockedReason: String? {
        guard model.ghostRepairCleanupState == .idle else { return nil }
        return model.ghostRepairBulkDismissBlockedReason
            ?? model.ghostRepairBulkWorkflowMutationBlockedReason
    }

    private func metric(
        _ title: String,
        _ value: Int,
        color: Color = .secondary
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func unavailable(title: String, detail: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "exclamationmark.triangle",
            description: Text(detail)
        )
    }

    private func failureExplanation(
        _ stage: CodexGhostRepairBulkInventoryFailureStage
    ) -> String {
        switch stage {
        case .requestValidation:
            "The internal scan identity was invalid. No read was started."
        case .snapshotRead:
            "The exact published snapshot could not be read safely."
        case .canonicalSourceRead:
            "The current local Codex databases could not be copied and read safely."
        case .officialInventory:
            "Codex did not return one complete, compatible inventory."
        case .snapshotProfile:
            "The current Codex runtime and local database profile are not an admitted pair."
        case .presentControl:
            "The safety control read did not match the current Codex inventory."
        case .candidateExactRead:
            "At least one candidate could not be checked exactly. No partial list was shown."
        case .composition:
            "The collected evidence did not form one internally consistent inventory."
        case .busy:
            "Another inventory scan is already running."
        case .unavailable:
            "This build does not provide the packaged read-only inventory scanner yet."
        }
    }

    private func dispositionLabel(
        _ disposition: CodexGhostRepairBulkInventoryDisposition
    ) -> String {
        switch disposition {
        case .eligible: "Eligible"
        case .blocked: "Blocked"
        case .unconfirmed: "Needs more evidence"
        case .notGhost: "Not a ghost"
        }
    }

    private func dispositionSymbol(
        _ disposition: CodexGhostRepairBulkInventoryDisposition
    ) -> String {
        switch disposition {
        case .eligible: "checkmark.circle.fill"
        case .blocked: "nosign"
        case .unconfirmed: "questionmark.circle.fill"
        case .notGhost: "person.crop.circle"
        }
    }

    private func dispositionColor(
        _ disposition: CodexGhostRepairBulkInventoryDisposition
    ) -> Color {
        switch disposition {
        case .eligible: .green
        case .blocked, .unconfirmed: .orange
        case .notGhost: .secondary
        }
    }

    private func categoryLabel(_ category: CodexGhostRepairCategory) -> String {
        switch category {
        case .ordinary: "Ordinary session"
        case .automation: "Automation session"
        }
    }

    private func blockerLabel(
        _ blocker: CodexGhostRepairBulkInventoryBlocker
    ) -> String {
        switch blocker {
        case .incompleteOfficialInventory: "Official inventory incomplete"
        case .canonicalStatePresent: "Current local session state still exists"
        case .exactReadNotPerformed: "Exact read skipped because local session data exists"
        case .exactReadPresent: "Exact read succeeded; this session will not be cleared"
        case .exactReadUnavailable: "Exact-read absence could not be verified"
        case .exactReadContractMismatch: "Exact read format changed"
        case .pinned: "Pinned"
        case .descendantsPresent: "Has child sessions"
        case .unsupportedRowShape: "Automation or catalog state is outside the supported cleanup policy"
        case .sideReferencesPresent: "Related records still exist"
        case .summaryRecordsPresent: "Conversation summaries still exist — kept"
        }
    }
}
