import AgentSessionManagerCore
import SwiftUI

struct MaintenanceView: View {
    @EnvironmentObject private var model: SessionManagerModel
    @Environment(\.dismiss) private var dismiss

    @State private var assessment: SQLiteMaintenanceAssessment?
    @State private var assessedAt: Date?
    @State private var isLoading = false
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let reason = model.maintenanceUnavailableReason {
                ContentUnavailableView(
                    "Maintenance Unavailable",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text(reason)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading, assessment == nil {
                ProgressView("Inspecting manager-owned SQLite…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let localError, assessment == nil {
                ContentUnavailableView(
                    "Assessment Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(localError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let assessment {
                assessmentContent(assessment)
            }
        }
        .frame(minWidth: 920, idealWidth: 1_040, minHeight: 650, idealHeight: 740)
        .task {
            guard model.maintenanceUnavailableReason == nil else { return }
            await loadAssessment()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SQLite Maintenance")
                    .font(.title2.weight(.semibold))
                Text("Manager-owned storage · read-only assessment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let assessedAt {
                Text("Assessed \(assessedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await loadAssessment() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading || model.maintenanceUnavailableReason != nil)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func assessmentContent(_ assessment: SQLiteMaintenanceAssessment) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(
                    "This screen cannot move backups, delete files, compact SQLite, or authorize execution.",
                    systemImage: "eye"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.blue)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                if let localError {
                    Label(localError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                summarySection(assessment)
                compactionSection(assessment.physicalCompaction)
                backupsSection(assessment.backupRetention)
            }
            .padding(18)
        }
    }

    private func summarySection(_ assessment: SQLiteMaintenanceAssessment) -> some View {
        let retention = assessment.backupRetention
        let candidateBytes = retention.trashCandidates.reduce(Int64(0)) { $0 + $1.byteCount }
        return GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                    metric("Recognized backups", "\(retention.recognizedBackups.count)")
                    metric("Protected", "\(retention.protectedBackups.count)")
                    metric("Retention candidates", "\(retention.trashCandidates.count)")
                    metric("Candidate bytes", formatBytes(candidateBytes))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 8)

            detailRow("SQLite path", assessment.physicalCompaction.databaseURL.path, monospaced: true)
            detailRow(
                "Retention policy",
                "Keep at least \(retention.policy.minimumBackupsPerKind) verified 0600 backups per kind; extras need \(days(retention.policy.minimumAge)) days of age."
            )
            detailRow(
                "Candidate safety cap",
                "\(retention.policy.maximumCandidatesPerAssessment) per assessment; overflow fails closed."
            )
        } label: {
            Label("Storage Summary", systemImage: "internaldrive")
        }
    }

    private func compactionSection(_ compaction: SQLitePhysicalCompactionAssessment) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        compaction.recommendation == .eligibleForExplicitPreview
                            ? "Reclaimable space detected"
                            : "Below the compaction threshold",
                        systemImage: compaction.recommendation == .eligibleForExplicitPreview
                            ? "info.circle"
                            : "minus.circle"
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Text(compaction.reclaimableRatio, format: .percent.precision(.fractionLength(1)))
                        .font(.headline.monospacedDigit())
                }

                ProgressView(value: min(max(compaction.reclaimableRatio, 0), 1))

                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow {
                        metric("Logical pages", formatBytes(compaction.logicalDatabaseBytes))
                        metric("Estimated reclaimable", formatBytes(compaction.estimatedReclaimableBytes))
                        metric("Page size", formatBytes(compaction.pageSizeBytes))
                        metric("Free pages", "\(compaction.freeListPageCount) / \(compaction.pageCount)")
                    }
                }

                Divider()
                detailRow(
                    "Production threshold",
                    "At least \(formatBytes(compaction.policy.minimumReclaimableBytes)) and \(formatPercent(compaction.policy.minimumReclaimableRatio))."
                )
                Text("Estimate only. Database compaction is not available in this version; no database files are changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("Physical Compaction Estimate", systemImage: "square.resize.down")
        }
    }

    private func backupsSection(_ retention: SQLiteBackupRetentionAssessment) -> some View {
        GroupBox {
            if retention.decisions.isEmpty {
                ContentUnavailableView(
                    "No Manager Backups",
                    systemImage: "externaldrive",
                    description: Text("No exact migration or pre-restore backup filenames were recognized.")
                )
                .frame(minHeight: 180)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(retention.decisions, id: \.backup.url) { decision in
                        backupCard(decision)
                    }
                }
            }
        } label: {
            Label("Backup Retention Decisions", systemImage: "externaldrive.badge.timemachine")
        }
    }

    private func backupCard(_ decision: SQLiteBackupRetentionDecision) -> some View {
        let backup = decision.backup
        let isCandidate = decision.disposition == .trashCandidate
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    isCandidate ? "Retention Candidate" : "Protected",
                    systemImage: isCandidate ? "exclamationmark.triangle" : "lock.fill"
                )
                .fontWeight(.semibold)
                .foregroundStyle(isCandidate ? Color.orange : Color.secondary)
                Spacer()
                Text(backup.kind.label)
                    .font(.caption.weight(.medium))
                Text(formatBytes(backup.byteCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(backup.url.lastPathComponent)
                .font(.caption.monospaced().weight(.medium))
                .textSelection(.enabled)
            Text(backup.url.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 14) {
                Label(
                    backup.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )
                Label(backup.verification.label, systemImage: backup.verification.symbol)
                Label(
                    backup.hasPrivatePermissions ? "Permissions 0600" : "Permissions not 0600",
                    systemImage: backup.hasPrivatePermissions ? "lock" : "exclamationmark.lock"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(decision.reason.explanation)
                .font(.caption)
                .foregroundStyle(isCandidate ? Color.orange : Color.secondary)
        }
        .padding(12)
        .background(
            (isCandidate ? Color.orange : Color.secondary).opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private func detailRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
        }
    }

    private func loadAssessment() async {
        isLoading = true
        localError = nil
        defer { isLoading = false }
        do {
            assessment = try await model.sqliteMaintenanceAssessment()
            assessedAt = Date()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func days(_ interval: TimeInterval) -> Int {
        Int((interval / (24 * 60 * 60)).rounded())
    }

    private func formatPercent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

private extension SQLiteBackupKind {
    var label: String {
        switch self {
        case .migration: "Migration"
        case .preRestore: "Pre-restore"
        }
    }
}

private extension SQLiteBackupVerification {
    var label: String {
        switch self {
        case .verified: "Verified"
        case .unreadable: "Unreadable"
        case .integrityCheckFailed: "Integrity check failed"
        case .unsupportedSchemaVersion: "Unsupported schema"
        case .schemaVersionMismatch: "Filename/schema mismatch"
        case .unexpectedApplicationID: "Unexpected application ID"
        }
    }

    var symbol: String {
        self == .verified ? "checkmark.shield" : "exclamationmark.shield"
    }
}

private extension SQLiteBackupRetentionReason {
    var explanation: String {
        switch self {
        case .eligibleByCountAndAge:
            "Verified 0600 backup outside the minimum retained count and old enough to be a candidate. No action is available in this build."
        case let .minimumVerifiedCount(position, minimum):
            "Protected as verified backup \(position) within the newest \(minimum) for this kind."
        case let .youngerThanMinimumAge(age, minimum):
            "Protected because it is \(dayCount(age)) days old; the minimum age is \(dayCount(minimum)) days."
        case .futureDated:
            "Protected because its filename timestamp is in the future."
        case let .verificationFailed(verification):
            "Protected because backup verification is \(verification.label.lowercased())."
        case .permissionsNotPrivate:
            "Protected because its file permissions are not the required 0600."
        }
    }

    private func dayCount(_ interval: TimeInterval) -> Int {
        max(0, Int((interval / (24 * 60 * 60)).rounded(.down)))
    }
}
