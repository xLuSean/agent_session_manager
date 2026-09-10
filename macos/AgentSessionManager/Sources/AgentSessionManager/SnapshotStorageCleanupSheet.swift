import AgentSessionManagerCore
import Foundation
import SwiftUI

struct SnapshotStorageCleanupSheet: View {
    @EnvironmentObject private var model: SessionManagerModel
    @State private var reviewToConfirm:
        CodexGhostRepairSnapshotCleanupReview?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "Manage Snapshot Storage",
                    systemImage: "externaldrive.badge.minus"
                )
                .font(.title2.bold())
                Text(
                    "Choose one exact published snapshot. Eligible items move to Agent Session Manager Trash; nothing is permanently deleted and Codex is not changed."
                )
                .foregroundStyle(.secondary)
            }
            Divider()
            content
            Spacer(minLength: 0)
            Divider()
            HStack {
                Label(
                    "No automatic cleanup, no silent selection changes, and no retry after a one-shot claim.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Close") {
                    model.isGhostRepairSnapshotCleanupPresented = false
                }
                .disabled(model.isGhostRepairSnapshotCleanupRunning)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .interactiveDismissDisabled(model.isGhostRepairSnapshotCleanupRunning)
        .alert(
            "Move one snapshot to Trash?",
            isPresented: Binding(
                get: { reviewToConfirm != nil },
                set: { if !$0 { reviewToConfirm = nil } }
            ),
            presenting: reviewToConfirm
        ) { review in
            Button("Cancel", role: .cancel) {
                reviewToConfirm = nil
            }
            Button("Move Snapshot to Trash", role: .destructive) {
                reviewToConfirm = nil
                Task {
                    await model.executeGhostRepairSnapshotCleanup(review: review)
                }
            }
        } message: { review in
            Text(
                "Exact snapshot:\n\(review.snapshot.reference)\n\nActive storage changes from \(review.activeSnapshotCountBefore)/3 to \(review.activeSnapshotCountAfter)/3. This moves one app-owned snapshot to Agent Session Manager Trash. It does not permanently delete it or modify Codex."
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.ghostRepairSnapshotCleanupState {
        case .idle, .inspecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading exact snapshot and dependency evidence…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .observed(inventory):
            inventoryView(inventory)

        case let .preparing(reference):
            VStack(spacing: 12) {
                ProgressView()
                Text("Freezing one exact cleanup review…")
                Text(reference)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .reviewReady(review):
            reviewView(review)

        case let .executing(review):
            VStack(spacing: 12) {
                ProgressView()
                Text("Moving exactly one snapshot and reading it back…")
                Text(review.snapshot.reference)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("Keep this window open. Do not retry or move files manually.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .completed(report):
            ContentUnavailableView {
                Label(
                    "Snapshot moved to Trash",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } description: {
                VStack(spacing: 8) {
                    Text(report.snapshotReference).font(.caption.monospaced())
                    Text(
                        "Active Snapshot Storage is now \(report.activeSnapshotCountAfter)/3. The snapshot was not permanently deleted and Codex was not changed."
                    )
                }
                .textSelection(.enabled)
            }

        case let .recoveryRequired(operationID, message):
            ContentUnavailableView {
                Label(
                    "Exact readback required — do not retry",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } description: {
                VStack(spacing: 8) {
                    Text(message)
                    Text("Operation \(operationID.uuidString.lowercased())")
                        .font(.caption.monospaced())
                }
                .textSelection(.enabled)
            }

        case let .unavailable(message):
            ContentUnavailableView(
                "Snapshot cleanup unavailable",
                systemImage: "exclamationmark.triangle.fill",
                description: Text(message)
            )
        }
    }

    private func inventoryView(
        _ inventory: CodexGhostRepairSnapshotCleanupInventory
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    "Active storage: \(inventory.activeSnapshotCount)/\(inventory.maximumSnapshotCount)",
                    systemImage: "externaldrive.fill"
                )
                .font(.headline)
                Spacer()
                Button {
                    Task { await model.inspectGhostRepairSnapshotCleanup() }
                } label: {
                    Label("Read Again", systemImage: "arrow.clockwise")
                }
            }
            Text("Oldest snapshots are shown first. Protected items cannot be moved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(inventory.snapshots, id: \.reference) { snapshot in
                        snapshotRow(snapshot)
                    }
                }
            }
        }
    }

    private func snapshotRow(
        _ snapshot: CodexGhostRepairSnapshotCleanupItem
    ) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.reference)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text(
                        "Created \(date(snapshot.publishedAtMilliseconds)) · \(bytes(snapshot.actualBytes))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    eligibility(snapshot)
                }
                Spacer()
                Button("Review Move to Trash…") {
                    Task {
                        await model.prepareGhostRepairSnapshotCleanup(
                            reference: snapshot.reference
                        )
                        if case let .reviewReady(review) =
                            model.ghostRepairSnapshotCleanupState {
                            reviewToConfirm = review
                        }
                    }
                }
                .disabled(!snapshot.canMoveToTrash)
                .accessibilityIdentifier(
                    "reviewSnapshotCleanup-\(snapshot.reference)"
                )
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func eligibility(
        _ snapshot: CodexGhostRepairSnapshotCleanupItem
    ) -> some View {
        switch snapshot.eligibility {
        case .eligible:
            Label(
                snapshot.historicalReferenceCount > 0
                    ? "Eligible · old expired/finished references are history only"
                    : "Eligible to move",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case let .protectedByActivePreview(count):
            Label(
                "Protected by \(count) unexpired Preview record(s)",
                systemImage: "lock.fill"
            )
            .foregroundStyle(.orange)
        case let .protectedByRepair(count):
            Label(
                "Protected by \(count) unfinished Repair operation(s)",
                systemImage: "lock.fill"
            )
            .foregroundStyle(.orange)
        }
    }

    private func reviewView(
        _ review: CodexGhostRepairSnapshotCleanupReview
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Exact cleanup review is ready", systemImage: "checkmark.shield")
                .font(.headline)
                .foregroundStyle(.green)
            GroupBox("Only effect") {
                VStack(alignment: .leading, spacing: 7) {
                    Text(review.effectDescription)
                    Text(review.snapshot.reference)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Text(
                        "Active storage: \(review.activeSnapshotCountBefore)/3 → \(review.activeSnapshotCountAfter)/3"
                    )
                    Text(
                        "No permanent deletion · no Codex database change · no automatic retry"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            HStack {
                Button("Back") {
                    Task {
                        await model.returnFromGhostRepairSnapshotCleanupReview()
                    }
                }
                Spacer()
                Button("Continue to Final Confirmation…") {
                    reviewToConfirm = review
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func date(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value),
            countStyle: .file
        )
    }
}
