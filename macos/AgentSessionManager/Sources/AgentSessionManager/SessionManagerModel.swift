import AgentSessionManagerCore
import Foundation
import OSLog
import SwiftUI

struct TrustFolderSummary: Identifiable, Hashable {
    let path: String
    let state: FolderTrustState

    var id: String { path }
}

struct SidebarMetrics: Sendable {
    var statusCounts: [CollectionFilter: Int] = [:]
    var systemCounts: [AgentSystem: Int] = [:]
    var projectCounts: [String: Int] = [:]
    var trustFolderCounts: [String: Int] = [:]
    var workingFolderCounts: [String: Int] = [:]
    var allCurrentStatusCount = 0
    var trustFolderCurrentStatusCount = 0
}

enum SidebarBrowsingScope: String, Sendable {
    case all
    case project
    case trustFolder
    case workingFolder
}

enum FilteredSelectionState: Equatable, Sendable {
    case none
    case partial
    case all
}

enum SessionListSort: String, CaseIterable {
    case updated = "Recently updated"
    case largest = "Conversation size: largest first"
    case smallest = "Conversation size: smallest first"
}

enum GhostRepairReadOnlyReviewState: Equatable, Sendable {
    case idle
    case loading(targetThreadIDs: [String])
    case ready(CodexGhostRepairReadOnlyReview)
    case unavailable(targetThreadIDs: [String], message: String)
}

enum GhostRepairOperatingPreflightState: Equatable, Sendable {
    case idle
    case inspecting(requestID: UUID)
    case observed(
        gate: CodexGhostRepairExecutionGate,
        observedAt: Date
    )
    case unavailable(message: String)
}

enum GhostRepairSnapshotAdmissionState: Equatable, Sendable {
    case idle
    case inspecting(CodexGhostRepairSnapshotActionRequest)
    case allowed(
        CodexGhostRepairSnapshotActionRequest,
        CodexGhostRepairSnapshotAdmissionEvidence
    )
    case blocked(
        CodexGhostRepairSnapshotActionRequest,
        evidence: CodexGhostRepairSnapshotAdmissionEvidence?,
        message: String
    )
    case unavailable(
        CodexGhostRepairSnapshotActionRequest,
        message: String
    )
}

enum GhostRepairSnapshotAdmissionOperatorDecisionKind:
    String,
    Equatable,
    Sendable
{
    case checking = "CHECKING"
    case ready = "READY"
    case passed = "PASSED"
    case stop = "STOP"
}

struct GhostRepairSnapshotAdmissionOperatorDecision:
    Equatable,
    Sendable
{
    let kind: GhostRepairSnapshotAdmissionOperatorDecisionKind
    let title: String
    let detail: String
}

enum GhostRepairSnapshotActionState: Equatable, Sendable {
    case unavailable(message: String)
    case reviewRequired
    case blocked(targetThreadIDs: [String], message: String)
    case ready(CodexGhostRepairSnapshotActionRequest)
    case acquiring(CodexGhostRepairSnapshotActionRequest)
    case succeeded(CodexGhostRepairSnapshotActionRequest, reference: String)
    case recoveryRequired(
        CodexGhostRepairSnapshotActionRequest,
        reference: String,
        message: String
    )
    case failed(CodexGhostRepairSnapshotActionRequest, message: String)
}

enum GhostRepairBulkInventoryState: Equatable, Sendable {
    case disabled
    case idle
    case observing(requestID: UUID, snapshotReference: String)
    case ready(CodexGhostRepairBulkInventory)
    case unavailable(
        snapshotReference: String?,
        stage: CodexGhostRepairBulkInventoryFailureStage
    )
}

enum GhostRepairCleanupState: Equatable {
    case idle
    case preparing
    case awaitingShutdown
    case running
    case stopped(String)
    case finished

    var isBusy: Bool {
        self == .preparing || self == .running
    }
}

enum GhostRepairBulkPreparationStage: String, Equatable, Sendable {
    case discoveringWitnesses = "Finding initial Snapshot witnesses"
    case reviewing = "Checking current evidence"
    case publishingSnapshot = "Creating one verified Snapshot"
    case scanningInventory = "Checking current local and exact Ghost evidence"
}

private enum GhostRepairAutomaticSnapshotWitness: Equatable, Sendable {
    case managerTombstones(managerKeys: Set<String>, threadIDs: [String])
    case initialDiscovery(CodexGhostRepairInitialWitnessEvidence)

    var threadIDs: [String] {
        switch self {
        case let .managerTombstones(_, threadIDs):
            threadIDs
        case let .initialDiscovery(evidence):
            evidence.threadIDs
        }
    }
}

enum GhostRepairBulkPreparationState: Equatable, Sendable {
    case idle
    case preparing(GhostRepairBulkPreparationStage)
    case ready(snapshotReference: String)
    case blocked(message: String)
}

enum GhostRepairBulkPreviewState: Equatable, Sendable {
    case idle
    case saving(requestID: UUID, preview: CodexGhostRepairBulkPreview)
    case saved(
        preview: CodexGhostRepairBulkPreview,
        receipt: CodexGhostRepairBulkPreviewPersistenceReceipt
    )
    case unavailable(message: String)
}

enum GhostRepairBulkPreviewReadbackState: Equatable, Sendable {
    case idle
    case reading(requestID: UUID)
    case observed(CodexGhostRepairBulkPreviewReadbackEvidence)
    case unavailable(message: String)
}

enum GhostRepairBulkConfirmationChallengeState: Equatable, Sendable {
    case idle
    case preparing(requestID: UUID)
    case ready(CodexGhostRepairBulkConfirmationChallenge)
    case unavailable(message: String)
}

enum GhostRepairBulkConfirmationReceiptState: Equatable, Sendable {
    case idle
    case confirming(requestID: UUID)
    case confirmed(CodexGhostRepairBulkConfirmationReceipt)
    case alreadyConfirmed(CodexGhostRepairBulkConfirmationReceipt)
    case unavailable(message: String)
}

enum GhostRepairBulkRepairState: Equatable, Sendable {
    case idle
    case preparingReview(requestID: UUID)
    case reviewReady(CodexGhostRepairBulkFinalReview)
    case executing(operationID: UUID)
    case completed(CodexGhostRepairBulkRepairReport)
    case closedBeforeAttempt(CodexGhostRepairBulkPreparedClosureRecord)
    case recoveryRequired(operationID: UUID, message: String)
    case unavailable(message: String)
}

enum GhostRepairBulkPreviousOperationsState: Equatable, Sendable {
    case idle
    case loading(requestID: UUID)
    case observed([CodexGhostRepairBulkRecoveryOperationSummary])
    case empty
    case limitExceeded(limit: Int, foundAtLeast: Int, message: String)
    case unavailable(message: String)
}

enum GhostRepairBulkRecoveryReadbackState: Equatable, Sendable {
    case idle
    case reading(
        requestID: UUID,
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    )
    case terminal(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        report: CodexGhostRepairBulkRepairReport
    )
    case closedBeforeAttempt(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        closure: CodexGhostRepairBulkPreparedClosureRecord
    )
    case recoveryRequired(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        message: String
    )
    case notFound(identity: CodexGhostRepairBulkRecoveryOperationIdentity)
    case unavailable(message: String)
}

enum GhostRepairBulkConfirmationReceiptRecoveryState: Equatable, Sendable {
    case idle
    case reading(
        requestID: UUID,
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest
    )
    case confirmed(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest,
        receipt: CodexGhostRepairBulkConfirmationReceipt
    )
    case recoveryRequired(
        request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest,
        reason: CodexGhostRepairBulkConfirmationReceiptRecoveryReason,
        message: String
    )
}

enum GhostRepairBulkFreshRecoveryState: Equatable, Sendable {
    case idle
    case recovering(
        requestID: UUID,
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    )
    case terminal(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        report: CodexGhostRepairBulkRepairReport,
        source: CodexGhostRepairBulkFreshRecoveryReportSource
    )
    case closedBeforeAttempt(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        closure: CodexGhostRepairBulkPreparedClosureRecord
    )
    case recoveryRequired(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        message: String
    )
    case notFound(identity: CodexGhostRepairBulkRecoveryOperationIdentity)
    case unavailable(message: String)
}

enum GhostRepairBulkPreparedClosureState: Equatable, Sendable {
    case idle
    case reviewing(
        requestID: UUID,
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    )
    case reviewReady(CodexGhostRepairBulkPreparedClosurePreview)
    case closing(
        requestID: UUID,
        preview: CodexGhostRepairBulkPreparedClosurePreview
    )
    case closedBeforeAttempt(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        closure: CodexGhostRepairBulkPreparedClosureRecord,
        newlyClosed: Bool
    )
    case persistenceUncertain(
        preview: CodexGhostRepairBulkPreparedClosurePreview,
        message: String
    )
    case recoveryRequired(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        message: String
    )
    case notFound(identity: CodexGhostRepairBulkRecoveryOperationIdentity)
    case unavailable(message: String)
}

enum NativeDeleteDesktopCleanupTargetState: Equatable, Sendable {
    case pending
    case eligible
    case blocked
    case outcomeUnknown
    case verified
}

struct NativeDeleteDesktopCleanupTarget: Identifiable, Equatable, Sendable {
    let nativeSessionID: String
    let state: NativeDeleteDesktopCleanupTargetState
    let category: CodexGhostRepairCategory?
    let message: String

    var id: String { nativeSessionID }
}

struct NativeDeleteDesktopCleanupContext: Equatable, Sendable {
    let canonicalDeleteReportID: UUID
    let expectedNativeSessionIDs: [String]
    let nativeDeleteItemCount: Int

    var isPartialNativeDeleteSuccess: Bool {
        expectedNativeSessionIDs.count != nativeDeleteItemCount
    }
}

enum NativeDeleteDesktopCleanupState: Equatable, Sendable {
    case idle
    case queued(NativeDeleteDesktopCleanupContext)
    case reviewing(requestID: UUID, NativeDeleteDesktopCleanupContext)
    case pending(
        NativeDeleteDesktopCleanupContext,
        CodexDesktopCleanupHandoff
    )
    case inventoryReady(
        NativeDeleteDesktopCleanupContext,
        CodexDesktopCleanupHandoff
    )
    case inventoryBlocked(
        NativeDeleteDesktopCleanupContext,
        CodexDesktopCleanupHandoff,
        targets: [NativeDeleteDesktopCleanupTarget],
        message: String
    )
    case binding(
        requestID: UUID,
        NativeDeleteDesktopCleanupContext,
        CodexDesktopCleanupHandoff,
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    )
    case bindingRecoveryRequired(
        NativeDeleteDesktopCleanupContext,
        CodexDesktopCleanupHandoff,
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        message: String
    )
    case status(
        NativeDeleteDesktopCleanupContext,
        CodexDesktopCleanupStatus
    )
    case unavailable(
        NativeDeleteDesktopCleanupContext,
        message: String
    )
}

private enum GhostRepairBulkPreparedClosureOrigin: Equatable, Sendable {
    case current(
        receipt: CodexGhostRepairBulkConfirmationReceipt,
        review: CodexGhostRepairBulkFinalReview
    )
    case previousOperation(
        summary: CodexGhostRepairBulkRecoveryOperationSummary
    )
}

private struct GhostRepairBulkProtectedItem: Equatable, Sendable {
    let threadID: String
    let category: CodexGhostRepairCategory
}

private struct GhostRepairBulkProtectedOperation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case confirming(CodexGhostRepairBulkConfirmationChallenge)
        case confirmationOutcomeUnknown(
            challenge: CodexGhostRepairBulkConfirmationChallenge,
            message: String
        )
        case confirmed(CodexGhostRepairBulkConfirmationReceipt)
        case preparingFinalReview(
            receipt: CodexGhostRepairBulkConfirmationReceipt,
            requestID: UUID
        )
        case reviewReady(
            receipt: CodexGhostRepairBulkConfirmationReceipt,
            review: CodexGhostRepairBulkFinalReview
        )
        case executing(
            receipt: CodexGhostRepairBulkConfirmationReceipt,
            review: CodexGhostRepairBulkFinalReview,
            requestID: UUID
        )
        case completed(
            receipt: CodexGhostRepairBulkConfirmationReceipt,
            report: CodexGhostRepairBulkRepairReport
        )
        case completedUnresolved(
            receipt: CodexGhostRepairBulkConfirmationReceipt,
            report: CodexGhostRepairBulkRepairReport
        )
        case recoveryRequired(
            receipt: CodexGhostRepairBulkConfirmationReceipt,
            message: String
        )
        case preparedClosureReviewReady(
            origin: GhostRepairBulkPreparedClosureOrigin,
            preview: CodexGhostRepairBulkPreparedClosurePreview
        )
        case closingPreparedClosure(
            origin: GhostRepairBulkPreparedClosureOrigin,
            preview: CodexGhostRepairBulkPreparedClosurePreview,
            requestID: UUID
        )
        case preparedClosureOutcomeUnknown(
            origin: GhostRepairBulkPreparedClosureOrigin,
            preview: CodexGhostRepairBulkPreparedClosurePreview,
            message: String
        )
        case preparedClosureRecoveryRequired(
            origin: GhostRepairBulkPreparedClosureOrigin,
            preview: CodexGhostRepairBulkPreparedClosurePreview,
            summary: CodexGhostRepairBulkRecoveryOperationSummary?,
            message: String
        )
        case closedBeforeAttempt(
            CodexGhostRepairBulkPreparedClosureRecord
        )
    }

    let savedPreviewRequestID: UUID
    let operationID: UUID
    let expectedItems: [GhostRepairBulkProtectedItem]
    var phase: Phase
}

enum GhostRepairSnapshotReadbackState: Equatable, Sendable {
    case disabled
    case idle
    case reading(requestID: UUID)
    case observed(CodexGhostRepairSnapshotReadbackInventory)
    case unavailable(message: String)
}

enum GhostRepairSnapshotCleanupState: Equatable, Sendable {
    case idle
    case inspecting(requestID: UUID)
    case observed(CodexGhostRepairSnapshotCleanupInventory)
    case preparing(reference: String)
    case reviewReady(CodexGhostRepairSnapshotCleanupReview)
    case executing(CodexGhostRepairSnapshotCleanupReview)
    case completed(CodexGhostRepairSnapshotCleanupReport)
    case recoveryRequired(operationID: UUID, message: String)
    case unavailable(message: String)
}

@MainActor
final class SessionManagerModel: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var sessionRows: [SessionPresentation] = []
    @Published var sessionListSort: SessionListSort = .updated
    @Published private(set) var sessionFileSizes: [String: Int64] = [:]
    @Published private(set) var isCalculatingSessionFileSizes = false
    @Published private(set) var compatibilityReport: CodexCompatibilityReport?
    @Published private(set) var isCheckingCompatibility = false
    @Published private(set) var compatibilityReportIsCurrent = false
    @Published var settingsTab = "general"
    @Published var diagnosticLogRunFilter: UUID?
    @Published private(set) var compatibilityCheckID: UUID?
    @Published private(set) var compatibilityCompletionMessage: String?
    @Published private(set) var compatibilityCheckError: String?
    @Published private(set) var compatibilityProgress: String?
    @Published private(set) var compatibilityReview: CodexCompatibilityReview?
    @Published private(set) var isComparingCompatibility = false
    @Published private var deferredCompatibilityNoticeID: String?
    @Published var isCompatibilityUpdateAlertPresented = false
    private var alertedCompatibilityEnvironment: String?
    private let compatibilityInspector: any CodexCompatibilityInspecting
    private var compatibilityRefreshTask: Task<Void, Never>?
    private var compatibilityRequestGeneration = UUID()
    private let sessionFileSizeReader: any SessionFileSizeReading
    private var sessionFileSizeTask: Task<Void, Never>?
    private var sessionFileSizeRequestID: UUID?
    private var sessionFileSizeHomeURL: URL?
    @Published var projectCatalog: [SessionProject] = []
    private(set) var selectedFilter: CollectionFilter = .active
    private(set) var browsingScope: SidebarBrowsingScope = .all
    private(set) var selectedSystem: AgentSystem = .codex
    private(set) var selectedProjectID: String?
    private(set) var selectedTrustFolderPath: String?
    private(set) var selectedWorkingDirectory: String?
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            clearFocusedSessionWhenHidden()
        }
    }
    @Published var isShowingSelectedSessionsOnly = false {
        didSet {
            guard isShowingSelectedSessionsOnly != oldValue else { return }
            clearFocusedSessionWhenHidden()
        }
    }
    @Published var selection: Set<String> = [] {
        didSet {
            if selection.isEmpty, isShowingSelectedSessionsOnly {
                isShowingSelectedSessionsOnly = false
            }
        }
    }
    /// Single row used by the Inspector. Batch lifecycle selection is owned by
    /// `selection` and changes only through the explicit row checkboxes.
    @Published var focusedSessionID: String?
    @Published var pendingPreview: OperationPreview?
    @Published var pendingNativeArchivePreview: OperationPreview?
    @Published var pendingNativeRestorePreview: OperationPreview?
    @Published var pendingNativeDeletePreview: OperationPreview?
    @Published var pendingConflictResolutionPreview: ConflictResolutionExecutionPreview?
    @Published var latestReport: OperationReport?
    @Published var latestNativeArchiveReport: NativeArchiveReport?
    @Published var latestNativeRestoreReport: NativeRestoreReport?
    @Published var latestNativeDeleteReport: NativeDeleteReport?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var completedHistoryNotice: String?
    private var lastCompletedHistoryPruneAt: Date?
    @Published var providerDiagnostics: [ProviderDiagnostics] = []
    @Published var checkpointDisposition: CheckpointCommitDisposition?
    @Published var stateStoreURL: URL?
    @Published var isReportHistoryPresented = false
    @Published var isMaintenancePresented = false
    @Published var isGhostRepairSnapshotReadbackPresented = false
    @Published var isGhostRepairSnapshotCleanupPresented = false
    @Published private(set) var isGhostRepairBulkInventoryPresented = false
    @Published var ghostRepairBulkSnapshotReferenceDraft = ""
    @Published var ghostRepairBulkSavedPreviewRequestIDDraft = "" {
        didSet {
            guard ghostRepairBulkSavedPreviewRequestIDDraft != oldValue else {
                return
            }
            if let protectedOperation = ghostRepairBulkProtectedOperation {
                ghostRepairBulkSavedPreviewRequestIDDraft =
                    protectedOperation.savedPreviewRequestID.uuidString
                        .lowercased()
                return
            }
            invalidateGhostRepairBulkPreparedEvidence()
        }
    }
    @Published var ghostRepairBulkConfirmationPhraseDraft = ""
    @Published var ghostRepairBulkSearchText = ""
    @Published var ghostRepairBulkFilter: CodexGhostRepairInventoryFilter = .needsAttention
    @Published var isShowingSelectedGhostRepairBulkItemsOnly = false
    @Published private(set) var ghostRepairBulkSelection: Set<String> = []
    @Published private(set) var ghostRepairCleanupState: GhostRepairCleanupState = .idle
    @Published private(set) var ghostRepairReadOnlyReviewState:
        GhostRepairReadOnlyReviewState = .idle
    @Published private(set) var ghostRepairOperatingPreflightState:
        GhostRepairOperatingPreflightState = .idle
    @Published private(set) var ghostRepairSnapshotAdmissionState:
        GhostRepairSnapshotAdmissionState = .idle
    @Published private(set) var ghostRepairSnapshotReadbackState:
        GhostRepairSnapshotReadbackState
    @Published private(set) var ghostRepairSnapshotCleanupState:
        GhostRepairSnapshotCleanupState = .idle
    @Published private(set) var ghostRepairBulkInventoryState:
        GhostRepairBulkInventoryState = .disabled
    @Published private(set) var ghostRepairBulkPreparationState:
        GhostRepairBulkPreparationState = .idle
    @Published private(set) var ghostRepairBulkPreviewState:
        GhostRepairBulkPreviewState = .idle
    @Published private(set) var ghostRepairBulkPreviewReadbackState:
        GhostRepairBulkPreviewReadbackState = .idle
    @Published private(set) var ghostRepairBulkConfirmationChallengeState:
        GhostRepairBulkConfirmationChallengeState = .idle
    @Published private(set) var ghostRepairBulkConfirmationReceiptState:
        GhostRepairBulkConfirmationReceiptState = .idle
    @Published private(set) var ghostRepairBulkRepairState:
        GhostRepairBulkRepairState = .idle
    @Published private(set) var ghostRepairBulkPreviousOperationsState:
        GhostRepairBulkPreviousOperationsState = .idle
    @Published private(set) var ghostRepairBulkRecoveryReadbackState:
        GhostRepairBulkRecoveryReadbackState = .idle
    @Published private(set)
        var ghostRepairBulkConfirmationReceiptRecoveryState:
            GhostRepairBulkConfirmationReceiptRecoveryState = .idle
    @Published private(set) var ghostRepairBulkFreshRecoveryState:
        GhostRepairBulkFreshRecoveryState = .idle
    @Published private(set) var ghostRepairBulkPreparedClosureState:
        GhostRepairBulkPreparedClosureState = .idle
    @Published private(set) var nativeDeleteDesktopCleanupState:
        NativeDeleteDesktopCleanupState = .idle
    @Published private(set) var nativeDeleteAutomaticCleanupReportID: UUID?
    @Published private(set) var nativeDeleteDesktopAbsenceVerifiedReportID: UUID?
    private var consumedNativeDeleteCleanupReports = Set<UUID>()
    private var shouldPresentNativeDeleteCleanupReview = false

    /// Delete authorizes its own cleanup, not a persistent Settings change.
    var isGhostRepairBulkWorkflowEnabled: Bool {
        isGhostRepairBulkReconciliationEnabled
            || nativeDeleteAutomaticCleanupReportID != nil
    }
    @Published private(set) var ghostRepairBulkSelectedRecoveryOperationIdentity:
        CodexGhostRepairBulkRecoveryOperationIdentity?
    @Published private(set) var isGhostRepairBulkReconciliationEnabled: Bool {
        didSet {
            guard isGhostRepairBulkReconciliationEnabled != oldValue else { return }
            ghostRepairBulkReconciliationPreferenceWriter(
                isGhostRepairBulkReconciliationEnabled
            )
            resetGhostRepairBulkWorkflowState(
                enabled: isGhostRepairBulkReconciliationEnabled
            )
        }
    }
    @Published var isGhostRepairSnapshotReadbackEnabled: Bool {
        didSet {
            guard isGhostRepairSnapshotReadbackEnabled != oldValue else { return }
            ghostRepairSnapshotReadbackPreferenceWriter(
                isGhostRepairSnapshotReadbackEnabled
            )
            ghostRepairSnapshotReadbackRequestID = nil
            if isGhostRepairSnapshotReadbackEnabled {
                ghostRepairSnapshotReadbackState = .idle
            } else {
                ghostRepairSnapshotReadbackState = .disabled
                isGhostRepairSnapshotReadbackPresented = false
            }
        }
    }
    @Published private(set) var diagnosticLogSnapshot = DiagnosticLogSnapshot.empty
    @Published private(set) var diagnosticLogErrorMessage: String?
    @Published private(set) var diagnosticLogPersistenceWarning: String?
    @Published var isDiagnosticLogPersistenceWarningPresented = false
    @Published private(set) var sidebarMetrics = SidebarMetrics()

    private let liveProvider: CodexAppServerProvider
    private let stateStoreFactory: () throws -> SQLiteStateStore
    private let diagnosticLogStore: DiagnosticLogStore
    private let ghostRepairReadOnlySafetySource:
        any CodexGhostRepairReadOnlySafetySource
    private let ghostRepairOperationalGateSource:
        any CodexGhostRepairExecutionGateSource
    private let ghostRepairSnapshotActionCoordinator:
        any CodexGhostRepairSnapshotActionCoordinator
    private let ghostRepairSnapshotAdmissionInspector:
        any CodexGhostRepairSnapshotAdmissionInspecting
    private let ghostRepairSnapshotReadbackCoordinator:
        any CodexGhostRepairSnapshotReadbackCoordinator
    private let ghostRepairSnapshotCleanupCoordinator:
        any CodexGhostRepairSnapshotCleanupCoordinating
    private let ghostRepairInitialWitnessDiscovery:
        any CodexGhostRepairInitialWitnessDiscovering
    private let ghostRepairBulkInventoryCoordinator:
        any CodexGhostRepairBulkInventoryCoordinating
    private let ghostRepairBulkPreviewPersister:
        any CodexGhostRepairBulkPreviewPersisting
    private let ghostRepairBulkPreviewReadbackCoordinator:
        any CodexGhostRepairBulkPreviewReadbackCoordinating
    private let ghostRepairBulkConfirmationChallengeCoordinator:
        any CodexGhostRepairBulkConfirmationChallengeCoordinating
    private let ghostRepairBulkConfirmationReceiptCoordinator:
        any CodexGhostRepairBulkConfirmationReceiptCoordinating
    private let ghostRepairBulkRepairCoordinator:
        any CodexGhostRepairBulkRepairCoordinating
    private let ghostRepairBulkRecoveryCoordinator:
        any CodexGhostRepairBulkRecoveryCoordinating
    private let ghostRepairBulkConfirmationReceiptRecoveryCoordinator:
        any CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinating
    private let ghostRepairBulkFreshRecoveryCoordinator:
        any CodexGhostRepairBulkFreshRecoveryCoordinating
    private let ghostRepairBulkPreparedClosureCoordinator:
        any CodexGhostRepairBulkPreparedClosureCoordinating
    private let nativeDeleteDesktopCleanupCoordinator:
        any CodexDesktopCleanupLinkageCoordinating
    private let ghostRepairSnapshotReadbackPreferenceWriter: (Bool) -> Void
    private let ghostRepairBulkReconciliationPreferenceWriter: (Bool) -> Void
    private var liveStateStore: SQLiteStateStore?
    private var liveSnapshotCoordinator: SessionSnapshotCoordinator?
    private var liveManagerOnlyCoordinator: ManagerOnlyOperationCoordinator?
    private var liveNativeArchiveCoordinator: CodexNativeArchiveCoordinator?
    private var liveNativeArchiveRecoveryCoordinator: CodexNativeArchiveRecoveryCoordinator?
    private var liveNativeRestoreCoordinator: CodexNativeRestoreCoordinator?
    private var liveNativeRestoreRecoveryCoordinator: CodexNativeRestoreRecoveryCoordinator?
    private var liveNativeDeleteCoordinator: CodexNativeDeleteCoordinator?
    private var liveNativeDeleteRecoveryCoordinator: CodexNativeDeleteRecoveryCoordinator?
    private var liveNativeBatchCoordinator: CodexNativeBatchCoordinator?
    private var liveConflictResolutionCoordinator: ConflictResolutionCoordinator?
    private var executingNativeArchivePreviewID: UUID?
    private var executingNativeRestorePreviewID: UUID?
    private var executingNativeDeletePreviewID: UUID?
    private var executingOperationPreviewID: UUID?
    private var executingConflictResolutionPreviewID: UUID?
    private var queuedOperationReport: OperationReport?
    private var queuedNativeArchivePreview: OperationPreview?
    private var reconciledStatesByKey: [String: ReconciledSessionState] = [:]
    private var reconciliationCheckpoint: ProviderCheckpointRecord?
    private var latestCoordinatedSnapshot: ProviderInventorySnapshot?
    private var ghostRepairReviewRequestID: UUID?
    private var ghostRepairOperatingPreflightRequestID: UUID?
    private var ghostRepairSnapshotActionRequestID: UUID?
    private var ghostRepairSnapshotAdmissionRequestID: UUID?
    private var ghostRepairSnapshotReadbackRequestID: UUID?
    private var ghostRepairSnapshotCleanupRequestID: UUID?
    private var ghostRepairInitialWitnessDiscoveryRequestID: UUID?
    private var ghostRepairBulkInventoryRequestID: UUID?
    private var ghostRepairBulkPreviewRequestID: UUID?
    private var ghostRepairBulkPreviewReadbackRequestID: UUID?
    private var ghostRepairBulkConfirmationChallengeRequestID: UUID?
    private var ghostRepairBulkConfirmationReceiptRequestID: UUID?
    private var ghostRepairBulkRepairRequestID: UUID?
    private var ghostRepairBulkPreviousOperationsRequestID: UUID?
    private var ghostRepairBulkRecoveryReadbackRequestID: UUID?
    private var ghostRepairBulkConfirmationReceiptRecoveryRequestID: UUID?
    private var ghostRepairBulkFreshRecoveryRequestID: UUID?
    private var ghostRepairBulkPreparedClosureRequestID: UUID?
    private var nativeDeleteDesktopCleanupStatusRequestID: UUID?
    private var ghostRepairBulkProtectedOperation:
        GhostRepairBulkProtectedOperation?
    @Published private var ghostRepairSnapshotExecutionState:
        GhostRepairSnapshotActionState? = nil

    private static let ghostRepairSnapshotReadbackPreferenceKey =
        "feature.ghostRepairSnapshotReadback.v1"
    // Keep the existing storage key so upgrades preserve the user's setting.
    private static let ghostRepairBulkReconciliationPreferenceKey =
        "feature.ghostRepairBulkInventory.v1"

    init(
        liveProvider: CodexAppServerProvider = CodexAppServerProvider(),
        sessionFileSizeReader: any SessionFileSizeReading = CodexSessionFileSizeReader(),
        compatibilityInspector: any CodexCompatibilityInspecting = CodexCompatibilityInspector(),
        diagnosticLogStore: DiagnosticLogStore? = nil,
        ghostRepairReadOnlySafetySource: (any CodexGhostRepairReadOnlySafetySource)? = nil,
        ghostRepairOperationalGateSource:
            (any CodexGhostRepairExecutionGateSource)? = nil,
        ghostRepairSnapshotActionCoordinator:
            (any CodexGhostRepairSnapshotActionCoordinator)? = nil,
        ghostRepairSnapshotAdmissionInspector:
            (any CodexGhostRepairSnapshotAdmissionInspecting)? = nil,
        ghostRepairSnapshotReadbackCoordinator:
            (any CodexGhostRepairSnapshotReadbackCoordinator)? = nil,
        ghostRepairSnapshotCleanupCoordinator:
            (any CodexGhostRepairSnapshotCleanupCoordinating)? = nil,
        ghostRepairInitialWitnessDiscovery:
            (any CodexGhostRepairInitialWitnessDiscovering)? = nil,
        ghostRepairSnapshotReadbackEnabled: Bool? = nil,
        ghostRepairSnapshotReadbackPreferenceWriter: ((Bool) -> Void)? = nil,
        ghostRepairBulkInventoryCoordinator:
            (any CodexGhostRepairBulkInventoryCoordinating)? = nil,
        ghostRepairBulkPreviewPersister:
            (any CodexGhostRepairBulkPreviewPersisting)? = nil,
        ghostRepairBulkPreviewReadbackCoordinator:
            (any CodexGhostRepairBulkPreviewReadbackCoordinating)? = nil,
        ghostRepairBulkConfirmationChallengeCoordinator:
            (any CodexGhostRepairBulkConfirmationChallengeCoordinating)? = nil,
        ghostRepairBulkConfirmationReceiptCoordinator:
            (any CodexGhostRepairBulkConfirmationReceiptCoordinating)? = nil,
        ghostRepairBulkRepairCoordinator:
            (any CodexGhostRepairBulkRepairCoordinating)? = nil,
        ghostRepairBulkRecoveryCoordinator:
            (any CodexGhostRepairBulkRecoveryCoordinating)? = nil,
        ghostRepairBulkConfirmationReceiptRecoveryCoordinator:
            (any CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinating)? = nil,
        ghostRepairBulkFreshRecoveryCoordinator:
            (any CodexGhostRepairBulkFreshRecoveryCoordinating)? = nil,
        ghostRepairBulkPreparedClosureCoordinator:
            (any CodexGhostRepairBulkPreparedClosureCoordinating)? = nil,
        nativeDeleteDesktopCleanupCoordinator:
            (any CodexDesktopCleanupLinkageCoordinating)? = nil,
        ghostRepairBulkReconciliationEnabled: Bool? = nil,
        ghostRepairBulkReconciliationPreferenceWriter: ((Bool) -> Void)? = nil,
        stateStoreFactory: @escaping () throws -> SQLiteStateStore = {
            let databaseURL = try StateStoreLocation.applicationSupportDatabaseURL()
            return try SQLiteStateStore(databaseURL: databaseURL)
        }
    ) {
        self.liveProvider = liveProvider
        self.sessionFileSizeReader = sessionFileSizeReader
        self.compatibilityInspector = compatibilityInspector
        self.stateStoreFactory = stateStoreFactory
        let operatingGateSource = ghostRepairOperationalGateSource
            ?? Self.makeDefaultGhostRepairOperationalGateSource()
        self.ghostRepairOperationalGateSource = operatingGateSource
        self.ghostRepairReadOnlySafetySource = ghostRepairReadOnlySafetySource
            ?? Self.makeDefaultGhostRepairReadOnlySafetySource(
                executionGateSource: operatingGateSource
            )
        self.ghostRepairSnapshotActionCoordinator =
            ghostRepairSnapshotActionCoordinator
            ?? CodexGhostRepairSnapshotActionCoordinatorFactory
                .packagedExplicitAction()
        self.ghostRepairSnapshotAdmissionInspector =
            ghostRepairSnapshotAdmissionInspector
            ?? CodexGhostRepairSnapshotAdmissionInspectorFactory
                .packagedExplicitReadOnly()
        self.ghostRepairSnapshotReadbackCoordinator =
            ghostRepairSnapshotReadbackCoordinator
            ?? CodexGhostRepairSnapshotReadbackCoordinatorFactory
                .packagedReadOnly()
        self.ghostRepairSnapshotCleanupCoordinator =
            ghostRepairSnapshotCleanupCoordinator
            ?? CodexGhostRepairSnapshotCleanupCoordinatorFactory.packaged()
        self.ghostRepairInitialWitnessDiscovery =
            ghostRepairInitialWitnessDiscovery
            ?? CodexGhostRepairInitialWitnessDiscoveryFactory
                .packagedExplicitReadOnly()
        let snapshotReadbackEnabled = ghostRepairSnapshotReadbackEnabled
            ?? UserDefaults.standard.bool(
                forKey: Self.ghostRepairSnapshotReadbackPreferenceKey
            )
        self.isGhostRepairSnapshotReadbackEnabled = snapshotReadbackEnabled
        self.ghostRepairSnapshotReadbackState = snapshotReadbackEnabled
            ? .idle
            : .disabled
        self.ghostRepairSnapshotReadbackPreferenceWriter =
            ghostRepairSnapshotReadbackPreferenceWriter
            ?? { enabled in
                UserDefaults.standard.set(
                    enabled,
                    forKey: Self.ghostRepairSnapshotReadbackPreferenceKey
                )
            }
        self.ghostRepairBulkInventoryCoordinator =
            ghostRepairBulkInventoryCoordinator
            ?? CodexGhostRepairBulkInventoryCoordinatorFactory
                .packagedExplicitReadOnly()
        self.ghostRepairBulkPreviewPersister = ghostRepairBulkPreviewPersister
            ?? CodexGhostRepairBulkPreviewPersistenceFactory.packaged()
        self.ghostRepairBulkPreviewReadbackCoordinator =
            ghostRepairBulkPreviewReadbackCoordinator
            ?? CodexGhostRepairBulkPreviewReadbackCoordinatorFactory
                .packagedReadOnly()
        self.ghostRepairBulkConfirmationChallengeCoordinator =
            ghostRepairBulkConfirmationChallengeCoordinator
            ?? CodexGhostRepairBulkConfirmationChallengeCoordinatorFactory
                .packagedEvidenceOnly()
        self.ghostRepairBulkConfirmationReceiptCoordinator =
            ghostRepairBulkConfirmationReceiptCoordinator
            ?? CodexGhostRepairBulkConfirmationReceiptCoordinatorFactory
                .packagedReceiptOnly()
        self.ghostRepairBulkRepairCoordinator =
            ghostRepairBulkRepairCoordinator
            ?? CodexGhostRepairBulkRepairCoordinatorFactory
                .packagedProduction()
        self.ghostRepairBulkRecoveryCoordinator =
            ghostRepairBulkRecoveryCoordinator
            ?? CodexGhostRepairBulkRecoveryCoordinatorFactory
                .packagedReadOnly()
        self.ghostRepairBulkConfirmationReceiptRecoveryCoordinator =
            ghostRepairBulkConfirmationReceiptRecoveryCoordinator
            ?? CodexGhostRepairBulkConfirmationReceiptRecoveryCoordinatorFactory
                .packagedReadOnly()
        self.ghostRepairBulkFreshRecoveryCoordinator =
            ghostRepairBulkFreshRecoveryCoordinator
            ?? CodexGhostRepairBulkFreshRecoveryCoordinatorFactory
                .packagedExplicit()
        self.ghostRepairBulkPreparedClosureCoordinator =
            ghostRepairBulkPreparedClosureCoordinator
            ?? CodexGhostRepairBulkPreparedClosureCoordinatorFactory
                .packagedExplicit()
        self.nativeDeleteDesktopCleanupCoordinator =
            nativeDeleteDesktopCleanupCoordinator
            ?? CodexDesktopCleanupLinkageCoordinatorFactory.packaged()
        let bulkReconciliationEnabled = ghostRepairBulkReconciliationEnabled
            ?? UserDefaults.standard.bool(
                forKey: Self.ghostRepairBulkReconciliationPreferenceKey
            )
        self.isGhostRepairBulkReconciliationEnabled = bulkReconciliationEnabled
        self.ghostRepairBulkInventoryState = bulkReconciliationEnabled
            ? .idle
            : .disabled
        self.ghostRepairBulkReconciliationPreferenceWriter =
            ghostRepairBulkReconciliationPreferenceWriter
            ?? { enabled in
                UserDefaults.standard.set(
                    enabled,
                    forKey: Self.ghostRepairBulkReconciliationPreferenceKey
                )
            }
        if let diagnosticLogStore {
            self.diagnosticLogStore = diagnosticLogStore
        } else {
            let bootstrap = DiagnosticLogBootstrap.make(
                fileURLProvider: {
                    try StateStoreLocation.applicationSupportDiagnosticLogURL()
                }
            )
            self.diagnosticLogStore = bootstrap.store
            if let warning = bootstrap.persistenceStatus.warningMessage {
                // Persistence failure is a durable state for this launch, not
                // a transient snapshot error. Refresh must never clear it.
                self.diagnosticLogPersistenceWarning = warning
                self.isDiagnosticLogPersistenceWarningPresented = true
            }
        }
        logDiagnostic(
            level: .info,
            category: .app,
            message: "App launched",
            metadata: [
                "data_source": "codex_live",
            ]
        )
    }

    private static func canonicalSnapshotReference(
        _ rawValue: String
    ) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString.lowercased()
    }

    var diagnosticLogFileURL: URL? { diagnosticLogStore.fileURL }

    func refreshDiagnosticLogs() async {
        do {
            diagnosticLogSnapshot = try await diagnosticLogStore.snapshot()
            diagnosticLogErrorMessage = nil
        } catch {
            diagnosticLogErrorMessage = error.localizedDescription
        }
    }

    func exportDiagnosticLogs() async throws -> Data {
        try await diagnosticLogStore.exportJSONL(compatibilityRunID: diagnosticLogRunFilter)
    }

    private func logDiagnostic(
        level: DiagnosticLogLevel,
        category: DiagnosticLogCategory,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let timestamp = Date()
        let logger = Logger(
            subsystem: StateStoreLocation.defaultBundleIdentifier,
            category: category.rawValue
        )
        switch level {
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
        Task { [weak self, diagnosticLogStore] in
            do {
                let snapshot = try await diagnosticLogStore.record(
                    level: level,
                    category: category,
                    message: message,
                    metadata: metadata,
                    timestamp: timestamp
                )
                self?.diagnosticLogSnapshot = snapshot
                self?.diagnosticLogErrorMessage = nil
            } catch {
                self?.diagnosticLogErrorMessage = error.localizedDescription
            }
        }
    }

    private func logPreviewPrepared(_ preview: OperationPreview) {
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation Preview created",
            metadata: [
                "operation": preview.operation.rawValue,
                "preview_id": preview.id.uuidString,
                "provider": preview.provider.rawValue,
                "selection_count": String(preview.items.count),
                "native_session_ids": preview.items.map(\.nativeID).joined(separator: ","),
            ]
        )
    }

    private func logOperationCompleted(
        operation: SessionOperation,
        reportID: UUID,
        outcome: String,
        itemCount: Int
    ) {
        logDiagnostic(
            level: outcome == "success" ? .info : .warning,
            category: .lifecycle,
            message: "Operation completed",
            metadata: [
                "operation": operation.rawValue,
                "report_id": reportID.uuidString,
                "outcome": outcome,
                "item_count": String(itemCount),
            ]
        )
    }

    private var sessionsMatchingNavigationAndSearch: [SessionPresentation] {
        sessionRows.filter { session in
            let matchesSystem = session.system == selectedSystem
            let matchesProject = browsingScope != .project
                || selectedProjectID == nil
                || session.project?.id == selectedProjectID
            let matchesTrustFolder = browsingScope != .trustFolder
                || selectedTrustFolderPath == nil
                || session.trustFolderPath == selectedTrustFolderPath
            let matchesWorkingDirectory = browsingScope != .workingFolder
                || selectedWorkingDirectory == nil
                || session.workingDirectory == selectedWorkingDirectory
            let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = needle.isEmpty
                || session.title.localizedCaseInsensitiveContains(needle)
                || session.nativeID.localizedCaseInsensitiveContains(needle)
                || session.liveSession?.supplementalSourceLabel?.localizedCaseInsensitiveContains(needle) == true
                || session.project?.name.localizedCaseInsensitiveContains(needle) == true
                || session.workingDirectory?.localizedCaseInsensitiveContains(needle) == true
                || session.trustFolderPath?.localizedCaseInsensitiveContains(needle) == true
            return matches(session, filter: selectedFilter)
                && matchesSystem
                && matchesProject
                && matchesTrustFolder
                && matchesWorkingDirectory
                && matchesSearch
        }
    }

    var filteredSessions: [SessionPresentation] {
        let rows = sessionsMatchingNavigationAndSearch.filter { session in
            !isShowingSelectedSessionsOnly || selection.contains(session.id)
        }
        guard sessionListSort != .updated else { return rows }
        return rows.sorted { lhs, rhs in
            let left = conversationFileSize(for: lhs)
            let right = conversationFileSize(for: rhs)
            if let left, let right, left != right {
                return sessionListSort == .largest ? left > right : left < right
            }
            if (left == nil) != (right == nil) { return left != nil }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    func conversationFileSize(for session: SessionPresentation) -> Int64? {
        // Never fall back to historical tombstone sizes or use these totals to
        // authorize lifecycle operations. Missing metadata stays unknown.
        session.system == .codex ? sessionFileSizes[session.nativeID] : nil
    }

    func conversationFileSizeLabel(for session: SessionPresentation) -> String {
        conversationFileSize(for: session).map {
            $0 == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "—"
    }

    var conversationFileSizeHelp: String {
        "Current logical size of all matching conversation files in sessions and archived_sessions, including old files. Excludes projects, shared databases and ASM backups/reports; not space guaranteed to be freed. Cached until refresh. — means not calculated or unavailable."
    }

    @discardableResult
    func refreshSessionFileSizes(homeURL: URL?) -> Task<Void, Never>? {
        sessionFileSizeTask?.cancel()
        let requestID = UUID()
        sessionFileSizeRequestID = requestID
        if homeURL != sessionFileSizeHomeURL { sessionFileSizes = [:] }
        sessionFileSizeHomeURL = homeURL
        guard let homeURL else {
            isCalculatingSessionFileSizes = false
            return nil
        }
        let ids = Set(sessionRows.filter { $0.system == .codex }.map(\.nativeID))
        sessionFileSizes = sessionFileSizes.filter { ids.contains($0.key) }
        isCalculatingSessionFileSizes = true
        let reader = sessionFileSizeReader
        sessionFileSizeTask = Task(priority: .utility) { [weak self] in
            let sizes = await reader.sizes(homeURL: homeURL, sessionIDs: ids)
            guard !Task.isCancelled, let self,
                  self.sessionFileSizeRequestID == requestID else { return }
            self.sessionFileSizes = sizes
            self.isCalculatingSessionFileSizes = false
        }
        return sessionFileSizeTask
    }

    var selectedSessions: [AgentSession] {
        sessions.filter { selection.contains($0.id) }
    }

    var selectedRows: [SessionPresentation] {
        sessionRows.filter { selection.contains($0.id) }
    }

    var visibleSelectionCount: Int {
        let visibleIDs = Set(filteredSessions.map(\.id))
        return selection.intersection(visibleIDs).count
    }

    var filteredSelectionState: FilteredSelectionState {
        let visibleIDs = Set(filteredSessions.map(\.id))
        guard !visibleIDs.isEmpty else { return .none }
        let selectedVisibleCount = selection.intersection(visibleIDs).count
        if selectedVisibleCount == 0 { return .none }
        return selectedVisibleCount == visibleIDs.count ? .all : .partial
    }

    func isSelected(_ managerKey: String) -> Bool {
        selection.contains(managerKey)
    }

    func setSelected(_ managerKey: String, isSelected: Bool) {
        guard filteredSessions.contains(where: { $0.id == managerKey }) else { return }
        if isSelected {
            selection.insert(managerKey)
            focusedSessionID = managerKey
        } else {
            selection.remove(managerKey)
        }
    }

    func clearSelection() {
        selection.removeAll()
        focusedSessionID = nil
    }

    var hasSessionSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearSessionSearch() {
        searchText = ""
    }

    var showsFilteredSelectionControls: Bool {
        selectedFilter == .trash || hasSessionSearch
    }

    var canToggleFilteredSelection: Bool {
        showsFilteredSelectionControls && !isLoading && !filteredSessions.isEmpty
    }

    func toggleFilteredSelection() {
        guard canToggleFilteredSelection else { return }
        let visibleIDs = Set(filteredSessions.map(\.id))
        guard !visibleIDs.isEmpty else { return }
        if visibleIDs.isSubset(of: selection) {
            selection.subtract(visibleIDs)
        } else {
            selection.formUnion(visibleIDs)
        }
    }

    var navigationTitle: String {
        let browsingTitle: String?
        switch browsingScope {
        case .all:
            browsingTitle = nil
        case .project:
            browsingTitle = projects.first(where: { $0.id == selectedProjectID })?.name
                ?? "All Projects"
        case .trustFolder:
            browsingTitle = selectedTrustFolderPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "All Trust Folders"
        case .workingFolder:
            browsingTitle = selectedWorkingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "All Working Folders"
        }
        return browsingTitle.map { "\($0) · \(selectedFilter.label)" }
            ?? selectedFilter.label
    }

    func selectStatusFilter(_ filter: CollectionFilter) {
        guard selectedFilter != filter else { return }
        selectedFilter = filter
        clearSessionSearch()
        isShowingSelectedSessionsOnly = false
        if !selection.isEmpty { selection.removeAll() }
        focusedSessionID = nil
        rebuildSidebarMetrics()
    }

    func selectAgentSystem(_ system: AgentSystem) {
        guard selectedSystem != system else { return }
        selectedSystem = system
        if !selection.isEmpty { selection.removeAll() }
        focusedSessionID = nil
        rebuildSidebarMetrics()
    }

    func selectProject(_ projectID: String?) {
        guard browsingScope != .project || selectedProjectID != projectID else { return }
        resetSidebarSelection(to: .project)
        selectedProjectID = projectID
        rebuildSidebarMetrics()
    }

    func selectTrustFolder(_ path: String?) {
        guard browsingScope != .trustFolder || selectedTrustFolderPath != path else { return }
        resetSidebarSelection(to: .trustFolder)
        selectedTrustFolderPath = path
        rebuildSidebarMetrics()
    }

    func selectWorkingFolder(_ path: String?) {
        guard browsingScope != .workingFolder || selectedWorkingDirectory != path else { return }
        resetSidebarSelection(to: .workingFolder)
        selectedWorkingDirectory = path
        rebuildSidebarMetrics()
    }

    private func resetSidebarSelection(to scope: SidebarBrowsingScope) {
        browsingScope = scope
        selectedProjectID = nil
        selectedTrustFolderPath = nil
        selectedWorkingDirectory = nil
        if !selection.isEmpty { selection.removeAll() }
        focusedSessionID = nil
    }

    private func retainOnlyExistingSelection() {
        let existingIDs = Set(sessionRows.map(\.id))
        if !selection.isEmpty {
            selection.formIntersection(existingIDs)
        }
        clearFocusedSessionWhenHidden()
    }

    private func clearFocusedSessionWhenHidden() {
        let visibleIDs = Set(filteredSessions.map(\.id))
        if let focusedSessionID, !visibleIDs.contains(focusedSessionID) {
            self.focusedSessionID = nil
        }
    }

    var inspectedSession: SessionPresentation? {
        if let focusedSessionID,
           let focused = sessionRows.first(where: { $0.id == focusedSessionID }) {
            return focused
        }
        return selectedRows.count == 1 ? selectedRows.first : nil
    }

    var projects: [SessionProject] {
        projectCatalog
    }

    var availableSystems: [AgentSystem] {
        AgentSystem.allCases.filter { system in
            system == .codex
                || providerDiagnostics.contains { $0.system == system }
                || sessionRows.contains { $0.system == system }
        }
    }

    var trustFolders: [TrustFolderSummary] {
        let grouped = Dictionary(grouping: sessionRows.compactMap { session in
            session.trustFolderPath.map { ($0, session.folderTrustState) }
        }, by: \.0)
        return grouped.map { path, entries in
            let states = Set(entries.map(\.1))
            let state = states.count == 1 ? entries[0].1 : .unavailable
            return TrustFolderSummary(path: path, state: state)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var workingDirectories: [String] {
        Array(Set(sessionRows.compactMap(\.workingDirectory))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var currentModeDiagnostic: ProviderDiagnostics? {
        providerDiagnostics.first
    }

    var reportHistoryUnavailableReason: String? {
        guard liveStateStore != nil else {
            return "The manager SQLite store is unavailable. Refresh Codex Live first."
        }
        return nil
    }

    var ghostRepairReadOnlyReviewBlockedReason: String? {
        ghostRepairReadOnlyReviewBlockedReason(for: selection)
    }

    var ghostRepairBulkInventoryCapabilities:
        CodexGhostRepairBulkInventoryCapabilities
    {
        ghostRepairBulkInventoryCoordinator.capabilities
    }

    var ghostRepairBulkInventory: CodexGhostRepairBulkInventory? {
        guard case let .ready(inventory) = ghostRepairBulkInventoryState else {
            return nil
        }
        return inventory
    }

    var ghostRepairBulkPreview: CodexGhostRepairBulkPreview? {
        switch ghostRepairBulkPreviewState {
        case let .saving(_, preview), let .saved(preview, _):
            return preview
        case .idle, .unavailable:
            return nil
        }
    }

    var ghostRepairBulkRecoveryCapabilities:
        CodexGhostRepairBulkRecoveryCapabilities
    {
        ghostRepairBulkRecoveryCoordinator.capabilities
    }

    var ghostRepairBulkConfirmationReceiptRecoveryCapabilities:
        CodexGhostRepairBulkConfirmationReceiptRecoveryCapabilities
    {
        ghostRepairBulkConfirmationReceiptRecoveryCoordinator.capabilities
    }

    var ghostRepairBulkFreshRecoveryCapabilities:
        CodexGhostRepairBulkFreshRecoveryCapabilities
    {
        ghostRepairBulkFreshRecoveryCoordinator.capabilities
    }

    var ghostRepairBulkPreparedClosureCapabilities:
        CodexGhostRepairBulkPreparedClosureCapabilities
    {
        ghostRepairBulkPreparedClosureCoordinator.capabilities
    }

    var ghostRepairBulkPreparedClosureReviewBlockedReason: String? {
        guard ghostRepairBulkPreparedClosureCapabilities
                .explicitClosureAvailable else {
            return "Closing an unstarted Bulk Ghost Delete plan is unavailable in this build."
        }
        guard ghostRepairBulkPreparedClosureRequestID == nil,
              ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil else {
            return "Another Bulk Ghost Delete review or recovery request is already running."
        }
        guard !isGhostRepairBulkPreparationInFlight,
              !isGhostRepairBulkOperationInFlight else {
            return "Wait for the current Bulk Ghost Delete step to finish before reviewing closure."
        }
        if let protectedOperation = ghostRepairBulkProtectedOperation {
            guard case .reviewReady = protectedOperation.phase else {
                return "Only an exact prepared plan that has not been claimed or attempted can be closed."
            }
            return nil
        }
        guard let identity =
                ghostRepairBulkSelectedRecoveryOperationIdentity,
              let summary = ghostRepairBulkPreviousOperations.first(where: {
                  $0.identity == identity
              }) else {
            return "Select one exact previous prepared operation first."
        }
        guard summary.phase == .prepared,
              summary.mutationAttemptCount == 0,
              !summary.hasTerminalReport else {
            return "Only an exact prepared plan that has not been claimed or attempted can be closed."
        }
        return nil
    }

    var ghostRepairBulkPreparedClosureCommitBlockedReason: String? {
        guard ghostRepairBulkPreparedClosureRequestID == nil else {
            return "A prepared-plan closure request is already running."
        }
        guard case let .reviewReady(preview) =
                ghostRepairBulkPreparedClosureState,
              case let .preparedClosureReviewReady(_, protectedPreview)? =
                ghostRepairBulkProtectedOperation?.phase,
              protectedPreview == preview else {
            return "Review the exact frozen prepared plan before closing it."
        }
        return nil
    }

    var ghostRepairBulkPreparedClosureRecoveryBlockedReason: String? {
        guard ghostRepairBulkRecoveryCapabilities.explicitReadbackAvailable
        else {
            return "Exact closure readback is unavailable in this build."
        }
        guard ghostRepairBulkPreparedClosureRequestID == nil,
              ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil else {
            return "Another Bulk Ghost Delete review or recovery request is already running."
        }
        guard !isGhostRepairBulkPreparationInFlight,
              !isGhostRepairBulkOperationInFlight else {
            return "Wait for the current Bulk Ghost Delete step to finish before exact closure readback."
        }
        guard let phase = ghostRepairBulkProtectedOperation?.phase else {
            return "Exact closure readback requires this app's unresolved closure context."
        }
        switch phase {
        case .preparedClosureOutcomeUnknown,
             .preparedClosureRecoveryRequired:
            return nil
        case .confirming, .confirmationOutcomeUnknown, .confirmed,
             .preparingFinalReview, .reviewReady, .executing, .completed,
             .completedUnresolved, .recoveryRequired,
             .preparedClosureReviewReady, .closingPreparedClosure,
             .closedBeforeAttempt:
            return "Exact closure readback requires this app's unresolved closure context."
        }
    }

    var ghostRepairBulkPreviousOperations:
        [CodexGhostRepairBulkRecoveryOperationSummary]
    {
        guard case let .observed(operations) =
                ghostRepairBulkPreviousOperationsState else { return [] }
        return operations
    }

    var ghostRepairBulkPreviousOperationsBlockedReason: String? {
        guard ghostRepairBulkRecoveryCapabilities.explicitReadbackAvailable
        else {
            return "Previous Bulk Ghost Delete operations are unavailable in this build."
        }
        guard !isGhostRepairBulkOperationInFlight,
              !isGhostRepairBulkPreparationInFlight else {
            return "Wait for the current Bulk Ghost Delete operation to stop before reading previous operations."
        }
        if let phase = ghostRepairBulkProtectedOperation?.phase {
            switch phase {
            case .preparedClosureReviewReady,
                 .preparedClosureOutcomeUnknown,
                 .preparedClosureRecoveryRequired:
                return "Finish or resolve the exact prepared-plan closure before replacing the previous-operation list."
            case .confirming, .confirmationOutcomeUnknown, .confirmed,
                 .preparingFinalReview, .reviewReady, .executing, .completed,
                 .completedUnresolved, .recoveryRequired,
                 .closingPreparedClosure, .closedBeforeAttempt:
                break
            }
        }
        guard ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil,
              ghostRepairBulkPreparedClosureRequestID == nil else {
            return "A previous-operation readback is already running."
        }
        return nil
    }

    var ghostRepairBulkConfirmationReceiptRecoveryBlockedReason: String? {
        guard ghostRepairBulkConfirmationReceiptRecoveryCapabilities
                .explicitExactReadbackAvailable else {
            return "Exact confirmation receipt recovery is unavailable in this build."
        }
        guard ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil,
              ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkPreparedClosureRequestID == nil else {
            return "Another Bulk Ghost Delete recovery request is already running."
        }
        guard !isGhostRepairBulkPreparationInFlight else {
            return "Wait for the current Bulk Ghost Delete preparation step to finish."
        }
        guard case .confirmationOutcomeUnknown =
                ghostRepairBulkProtectedOperation?.phase else {
            return "Receipt recovery requires this app's exact unresolved confirmation context."
        }
        return nil
    }

    var ghostRepairBulkFreshRecoveryBlockedReason: String? {
        guard ghostRepairBulkFreshRecoveryCapabilities
                .explicitRecoveryAvailable else {
            return "Fresh recovery is unavailable in this build."
        }
        guard ghostRepairBulkFreshRecoveryRequestID == nil,
              ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkPreparedClosureRequestID == nil else {
            return "Another Bulk Ghost Delete recovery request is already running."
        }
        guard !isGhostRepairBulkPreparationInFlight,
              !isGhostRepairBulkOperationInFlight else {
            return "Wait for the current Bulk Ghost Delete step to finish before fresh recovery."
        }
        guard let identity =
                ghostRepairBulkSelectedRecoveryOperationIdentity else {
            return "Select one exact previous operation first."
        }
        if case .confirmationOutcomeUnknown =
                ghostRepairBulkProtectedOperation?.phase {
            return "Check the original confirmation receipt before fresh operation recovery."
        }
        if let phase = ghostRepairBulkProtectedOperation?.phase {
            switch phase {
            case .preparedClosureReviewReady, .closingPreparedClosure,
                 .preparedClosureOutcomeUnknown,
                 .preparedClosureRecoveryRequired:
                return "Finish or resolve the exact prepared-plan closure before fresh recovery."
            case .confirming, .confirmationOutcomeUnknown, .confirmed,
                 .preparingFinalReview, .reviewReady, .executing, .completed,
                 .completedUnresolved, .recoveryRequired,
                 .closedBeforeAttempt:
                break
            }
        }
        guard ghostRepairBulkPreviousOperations.contains(where: {
            $0.identity == identity
        }) else {
            return "The selected operation is not in the exact previous-operation list."
        }
        return nil
    }

    var ghostRepairBulkRecoveryReadbackBlockedReason: String? {
        if let reason = ghostRepairBulkPreviousOperationsBlockedReason {
            return reason
        }
        guard let identity =
                ghostRepairBulkSelectedRecoveryOperationIdentity else {
            return "Select one exact previous operation first."
        }
        guard ghostRepairBulkPreviousOperations.contains(where: {
            $0.identity == identity
        }) else {
            return "The selected operation is not in the exact previous-operation list."
        }
        return nil
    }

    func loadGhostRepairBulkPreviousOperations() async {
        guard ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil,
              ghostRepairBulkPreparedClosureRequestID == nil else {
            return
        }
        guard ghostRepairBulkPreviousOperationsBlockedReason == nil else {
            ghostRepairBulkPreviousOperationsState = .unavailable(
                message: ghostRepairBulkPreviousOperationsBlockedReason
                    ?? "Previous operations are unavailable."
            )
            return
        }
        let requestID = UUID()
        ghostRepairBulkPreviousOperationsRequestID = requestID
        ghostRepairBulkRecoveryReadbackState = .idle
        ghostRepairBulkFreshRecoveryState = .idle
        ghostRepairBulkPreviousOperationsState = .loading(
            requestID: requestID
        )
        let outcome = await ghostRepairBulkRecoveryCoordinator
            .readPreviousOperations()
        guard ghostRepairBulkPreviousOperationsRequestID == requestID else {
            return
        }
        ghostRepairBulkPreviousOperationsRequestID = nil
        ghostRepairBulkSelectedRecoveryOperationIdentity = nil
        ghostRepairBulkRecoveryReadbackState = .idle
        ghostRepairBulkFreshRecoveryState = .idle
        switch outcome {
        case let .observed(operations):
            let identities = operations.map(\.identity)
            guard !operations.isEmpty,
                  Set(identities).count == identities.count else {
                ghostRepairBulkPreviousOperationsState = .unavailable(
                    message: "Previous-operation readback returned an invalid exact identity list."
                )
                return
            }
            ghostRepairBulkPreviousOperationsState = .observed(operations)
        case .empty:
            ghostRepairBulkPreviousOperationsState = .empty
        case let .limitExceeded(limit, foundAtLeast, message):
            ghostRepairBulkPreviousOperationsState = .limitExceeded(
                limit: limit,
                foundAtLeast: foundAtLeast,
                message: message
            )
        case let .unavailable(message):
            ghostRepairBulkPreviousOperationsState = .unavailable(
                message: message
            )
        }
    }

    func setGhostRepairBulkRecoveryOperationSelected(
        _ identity: CodexGhostRepairBulkRecoveryOperationIdentity?
    ) {
        guard ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil,
              ghostRepairBulkPreparedClosureRequestID == nil else {
            errorMessage = "Wait for the exact operation readback to finish before changing selection."
            return
        }
        if let phase = ghostRepairBulkProtectedOperation?.phase {
            switch phase {
            case .preparedClosureReviewReady, .closingPreparedClosure,
                 .preparedClosureOutcomeUnknown,
                 .preparedClosureRecoveryRequired:
                errorMessage =
                    "Finish or resolve the exact prepared-plan closure before changing previous-operation selection."
                return
            case .confirming, .confirmationOutcomeUnknown, .confirmed,
                 .preparingFinalReview, .reviewReady, .executing, .completed,
                 .completedUnresolved, .recoveryRequired,
                 .closedBeforeAttempt:
                break
            }
        }
        if let identity {
            guard ghostRepairBulkPreviousOperations.contains(where: {
                $0.identity == identity
            }) else {
                errorMessage =
                    "The requested recovery operation is not in the exact previous-operation list."
                return
            }
        }
        guard ghostRepairBulkSelectedRecoveryOperationIdentity != identity
        else { return }
        ghostRepairBulkSelectedRecoveryOperationIdentity = identity
        ghostRepairBulkRecoveryReadbackState = .idle
        ghostRepairBulkFreshRecoveryState = .idle
    }

    func reviewCurrentGhostRepairBulkPreparedClosure() async {
        guard ghostRepairBulkPreparedClosureReviewBlockedReason == nil,
              let protectedOperation = ghostRepairBulkProtectedOperation,
              case let .reviewReady(receipt, review) =
                protectedOperation.phase else {
            errorMessage = ghostRepairBulkPreparedClosureReviewBlockedReason
            return
        }
        await reviewGhostRepairBulkPreparedClosure(
            identity: .init(
                requestID: protectedOperation.savedPreviewRequestID,
                operationID: protectedOperation.operationID
            ),
            origin: .current(receipt: receipt, review: review),
            expectedItems: protectedOperation.expectedItems
        )
    }

    func reviewSelectedGhostRepairBulkPreparedClosure() async {
        guard ghostRepairBulkPreparedClosureReviewBlockedReason == nil,
              ghostRepairBulkProtectedOperation == nil,
              let identity =
                ghostRepairBulkSelectedRecoveryOperationIdentity,
              let summary = ghostRepairBulkPreviousOperations.first(where: {
                  $0.identity == identity
              }) else {
            errorMessage = ghostRepairBulkPreparedClosureReviewBlockedReason
            return
        }
        await reviewGhostRepairBulkPreparedClosure(
            identity: identity,
            origin: .previousOperation(summary: summary),
            expectedItems: nil
        )
    }

    private func reviewGhostRepairBulkPreparedClosure(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        origin: GhostRepairBulkPreparedClosureOrigin,
        expectedItems: [GhostRepairBulkProtectedItem]?
    ) async {
        guard ghostRepairBulkPreparedClosureRequestID == nil else { return }
        let requestID = UUID()
        ghostRepairBulkPreparedClosureRequestID = requestID
        ghostRepairBulkPreparedClosureState = .reviewing(
            requestID: requestID,
            identity: identity
        )
        let outcome = await ghostRepairBulkPreparedClosureCoordinator
            .reviewClosure(identity: identity)
        guard ghostRepairBulkPreparedClosureRequestID == requestID else {
            return
        }
        ghostRepairBulkPreparedClosureRequestID = nil

        switch outcome {
        case let .ready(preview):
            guard preparedClosurePreview(
                preview,
                matches: identity,
                origin: origin,
                expectedItems: expectedItems
            ) else {
                retainInvalidGhostRepairBulkPreparedClosureReview(
                    identity: identity,
                    origin: origin,
                    message: "Prepared-plan closure review did not match the exact operation."
                )
                return
            }
            ghostRepairBulkProtectedOperation = .init(
                savedPreviewRequestID: identity.requestID,
                operationID: identity.operationID,
                expectedItems: preview.selectedItems.map {
                    .init(threadID: $0.threadID, category: $0.category)
                },
                phase: .preparedClosureReviewReady(
                    origin: origin,
                    preview: preview
                )
            )
            ghostRepairBulkPreparedClosureState = .reviewReady(preview)
        case let .alreadyClosed(summary, closure):
            guard preparedClosureResult(
                summary: summary,
                closure: closure,
                matches: identity,
                preview: nil,
                expectedItems: expectedItems
            ), preparedClosureRecord(closure, matches: origin) else {
                retainInvalidGhostRepairBulkPreparedClosureReview(
                    identity: identity,
                    origin: origin,
                    message: "Closed-plan evidence did not match the exact operation."
                )
                return
            }
            acceptGhostRepairBulkPreparedClosure(
                summary: summary,
                closure: closure,
                newlyClosed: false,
                expectedIdentity: identity
            )
        case let .notClosable(summary, message):
            guard summary.identity == identity else {
                retainInvalidGhostRepairBulkPreparedClosureReview(
                    identity: identity,
                    origin: origin,
                    message: "Closure eligibility returned a different exact operation."
                )
                return
            }
            retainGhostRepairBulkPreparedClosureRecovery(
                identity: identity,
                origin: origin,
                expectedItems: expectedItems,
                summary: summary,
                message: message
            )
        case let .notFound(returnedIdentity):
            guard returnedIdentity == identity else {
                retainInvalidGhostRepairBulkPreparedClosureReview(
                    identity: identity,
                    origin: origin,
                    message: "Closure review returned a different operation identity."
                )
                return
            }
            if case let .current(receipt, _) = origin {
                let message =
                    "The exact durable prepared operation was not found. Keep this operation reference and use exact readback."
                ghostRepairBulkProtectedOperation?.phase = .recoveryRequired(
                    receipt: receipt,
                    message: message
                )
                ghostRepairBulkRepairState = .recoveryRequired(
                    operationID: identity.operationID,
                    message: message
                )
            }
            ghostRepairBulkPreparedClosureState = .notFound(
                identity: identity
            )
        case let .unavailable(message):
            ghostRepairBulkPreparedClosureState = .unavailable(
                message: message
            )
        }
    }

    func cancelGhostRepairBulkPreparedClosureReview() {
        guard ghostRepairBulkPreparedClosureRequestID == nil,
              case let .preparedClosureReviewReady(origin, _) =
                ghostRepairBulkProtectedOperation?.phase else { return }
        switch origin {
        case let .current(receipt, review):
            ghostRepairBulkProtectedOperation?.phase = .reviewReady(
                receipt: receipt,
                review: review
            )
            ghostRepairBulkRepairState = .reviewReady(review)
        case .previousOperation:
            ghostRepairBulkProtectedOperation = nil
            ghostRepairBulkRepairState = .idle
        }
        ghostRepairBulkPreparedClosureState = .idle
    }

    func closeGhostRepairBulkPreparedOperation() async {
        guard ghostRepairBulkPreparedClosureRequestID == nil else { return }
        guard ghostRepairBulkPreparedClosureCommitBlockedReason == nil,
              case let .reviewReady(preview) =
                ghostRepairBulkPreparedClosureState,
              case let .preparedClosureReviewReady(origin, currentPreview)? =
                ghostRepairBulkProtectedOperation?.phase,
              currentPreview == preview else {
            errorMessage = ghostRepairBulkPreparedClosureCommitBlockedReason
            return
        }
        let requestID = UUID()
        ghostRepairBulkPreparedClosureRequestID = requestID
        ghostRepairBulkPreparedClosureState = .closing(
            requestID: requestID,
            preview: preview
        )
        ghostRepairBulkProtectedOperation?.phase = .closingPreparedClosure(
            origin: origin,
            preview: preview,
            requestID: requestID
        )
        let outcome = await ghostRepairBulkPreparedClosureCoordinator
            .closePreparedOperation(preview)
        guard ghostRepairBulkPreparedClosureRequestID == requestID,
              ghostRepairBulkProtectedOperation?.savedPreviewRequestID
                == preview.identity.requestID,
              ghostRepairBulkProtectedOperation?.operationID
                == preview.identity.operationID,
              case let .closingPreparedClosure(
                  currentOrigin,
                  currentPreview,
                  currentRequestID
              )? = ghostRepairBulkProtectedOperation?.phase,
              currentOrigin == origin,
              currentPreview == preview,
              currentRequestID == requestID else { return }
        ghostRepairBulkPreparedClosureRequestID = nil

        switch outcome {
        case let .closed(summary, closure, newlyClosed):
            guard preparedClosureResult(
                summary: summary,
                closure: closure,
                matches: preview.identity,
                preview: preview,
                expectedItems: ghostRepairBulkProtectedOperation?
                    .expectedItems
            ) else {
                retainUnknownGhostRepairBulkPreparedClosure(
                    origin: origin,
                    preview: preview,
                    message: "Closure commit returned evidence for a different exact operation. Keep this operation reference and resolve it by exact readback."
                )
                return
            }
            acceptGhostRepairBulkPreparedClosure(
                summary: summary,
                closure: closure,
                newlyClosed: newlyClosed,
                expectedIdentity: preview.identity
            )
        case let .persistenceUncertain(identity, message):
            guard identity == preview.identity else {
                retainUnknownGhostRepairBulkPreparedClosure(
                    origin: origin,
                    preview: preview,
                    message: "Closure persistence returned a different operation identity. Keep the original operation reference and resolve it by exact readback."
                )
                return
            }
            retainUnknownGhostRepairBulkPreparedClosure(
                origin: origin,
                preview: preview,
                message: message
            )
        case let .notClosable(summary, message):
            guard summary.identity == preview.identity else {
                retainUnknownGhostRepairBulkPreparedClosure(
                    origin: origin,
                    preview: preview,
                    message: "Closure commit returned a different operation identity. Keep the original operation reference and resolve it by exact readback."
                )
                return
            }
            retainGhostRepairBulkPreparedClosureRecovery(
                identity: preview.identity,
                origin: origin,
                expectedItems: ghostRepairBulkProtectedOperation?
                    .expectedItems,
                preview: preview,
                summary: summary,
                message: message
            )
        case let .notFound(identity):
            let message = identity == preview.identity
                ? "The exact prepared operation was not found after the closure intent. Keep its identity and resolve it by exact readback."
                : "Closure commit returned a different operation identity. Keep the original operation reference and resolve it by exact readback."
            retainUnknownGhostRepairBulkPreparedClosure(
                origin: origin,
                preview: preview,
                message: message
            )
        case let .unavailable(message):
            retainUnknownGhostRepairBulkPreparedClosure(
                origin: origin,
                preview: preview,
                message: "Closure outcome is unavailable: \(message) Keep this operation reference and resolve it by exact readback."
            )
        }
    }

    func readUncertainGhostRepairBulkPreparedClosure() async {
        guard ghostRepairBulkPreparedClosureRequestID == nil else { return }
        guard ghostRepairBulkPreparedClosureRecoveryBlockedReason == nil,
              let protectedOperation = ghostRepairBulkProtectedOperation else {
            errorMessage = ghostRepairBulkPreparedClosureRecoveryBlockedReason
            return
        }
        let protectedPhase = protectedOperation.phase
        switch protectedPhase {
        case .preparedClosureOutcomeUnknown,
             .preparedClosureRecoveryRequired:
            break
        case .confirming, .confirmationOutcomeUnknown, .confirmed,
             .preparingFinalReview, .reviewReady, .executing, .completed,
             .completedUnresolved, .recoveryRequired,
             .preparedClosureReviewReady, .closingPreparedClosure,
             .closedBeforeAttempt:
            errorMessage =
                "Exact closure readback requires this app's unresolved closure context."
            return
        }
        let identity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: protectedOperation.savedPreviewRequestID,
            operationID: protectedOperation.operationID
        )
        guard let evidence = protectedPreparedClosureEvidence(
            matching: identity
        ) else {
            errorMessage =
                "Exact closure readback requires this app's unresolved closure context."
            return
        }
        let origin = evidence.origin
        let preview = evidence.preview
        let acceptsEquivalentReviewedClosure =
            evidence.acceptsEquivalentReviewedClosure
        let requestID = UUID()
        ghostRepairBulkPreparedClosureRequestID = requestID
        ghostRepairBulkPreparedClosureState = .reviewing(
            requestID: requestID,
            identity: preview.identity
        )
        let outcome = await ghostRepairBulkRecoveryCoordinator.readOperation(
            identity: preview.identity
        )
        guard ghostRepairBulkPreparedClosureRequestID == requestID,
              ghostRepairBulkProtectedOperation?.savedPreviewRequestID
                == preview.identity.requestID,
              ghostRepairBulkProtectedOperation?.operationID
                == preview.identity.operationID,
              ghostRepairBulkProtectedOperation?.phase == protectedPhase else {
            return
        }
        ghostRepairBulkPreparedClosureRequestID = nil

        switch outcome {
        case let .closedBeforeAttempt(summary, closure):
            guard preparedClosureResult(
                summary: summary,
                closure: closure,
                matches: preview.identity,
                preview: preview,
                acceptsEquivalentReviewedClosure:
                    acceptsEquivalentReviewedClosure,
                expectedItems: ghostRepairBulkProtectedOperation?
                    .expectedItems
            ) else {
                retainGhostRepairBulkPreparedClosureReadFailure(
                    protectedPhase: protectedPhase,
                    origin: origin,
                    preview: preview,
                    message: "Exact closure readback did not match the original frozen closure intent."
                )
                return
            }
            acceptGhostRepairBulkPreparedClosure(
                summary: summary,
                closure: closure,
                newlyClosed: false,
                expectedIdentity: preview.identity
            )
        case let .recoveryRequired(summary, message):
            guard !acceptsEquivalentReviewedClosure else {
                retainGhostRepairBulkPreparedClosureReadFailure(
                    protectedPhase: protectedPhase,
                    origin: origin,
                    preview: preview,
                    message: "Exact readback did not return the already-recorded closed-before-attempt evidence."
                )
                return
            }
            guard summary.identity == preview.identity,
                  !summary.hasTerminalReport else {
                retainGhostRepairBulkPreparedClosureReadFailure(
                    protectedPhase: protectedPhase,
                    origin: origin,
                    preview: preview,
                    message: "Exact closure readback returned mismatched recovery evidence."
                )
                return
            }
            if summary.phase == .prepared,
               summary.mutationAttemptCount == 0,
               summary.confirmationReceiptID
                == preview.confirmationReceiptID,
               summary.selectedCount == preview.selectedItems.count {
                ghostRepairBulkProtectedOperation?.phase =
                    .preparedClosureReviewReady(
                        origin: origin,
                        preview: preview
                    )
                ghostRepairBulkPreparedClosureState = .reviewReady(preview)
                return
            }
            retainGhostRepairBulkPreparedClosureRecovery(
                identity: preview.identity,
                origin: origin,
                expectedItems: ghostRepairBulkProtectedOperation?
                    .expectedItems,
                preview: preview,
                summary: summary,
                message: message
            )
        case let .terminal(summary, report):
            guard !acceptsEquivalentReviewedClosure else {
                retainGhostRepairBulkPreparedClosureReadFailure(
                    protectedPhase: protectedPhase,
                    origin: origin,
                    preview: preview,
                    message: "Exact readback contradicted the already-recorded closed-before-attempt phase."
                )
                return
            }
            guard summary.identity == preview.identity,
                  summary.confirmationReceiptID
                    == preview.confirmationReceiptID,
                  summary.selectedCount == preview.selectedItems.count,
                  summary.phase == .terminal,
                  summary.hasTerminalReport,
                  report.operationID == preview.identity.operationID,
                  report.itemReports.count == preview.selectedItems.count,
                  recoveredReportMatchesProtectedOperation(
                    identity: preview.identity,
                    report: report
                  ) else {
                retainGhostRepairBulkPreparedClosureReadFailure(
                    protectedPhase: protectedPhase,
                    origin: origin,
                    preview: preview,
                    message: "Exact closure readback returned a terminal result for a different operation."
                )
                return
            }
            ghostRepairBulkRecoveryReadbackState = .terminal(
                summary: summary,
                report: report
            )
            reconcileProtectedGhostRepairBulkOperation(
                identity: preview.identity,
                report: report
            )
            switch ghostRepairBulkProtectedOperation?.phase {
            case .preparedClosureReviewReady,
                 .closingPreparedClosure,
                 .preparedClosureOutcomeUnknown,
                 .preparedClosureRecoveryRequired:
                retainGhostRepairBulkPreparedClosureRecovery(
                    identity: preview.identity,
                    origin: origin,
                    expectedItems: ghostRepairBulkProtectedOperation?
                        .expectedItems,
                    preview: preview,
                    summary: summary,
                    message: "The operation has terminal execution evidence, not an unstarted-plan closure. Use its terminal Report."
                )
            case .confirming, .confirmationOutcomeUnknown, .confirmed,
                 .preparingFinalReview, .reviewReady, .executing,
                 .completed, .completedUnresolved, .recoveryRequired,
                 .closedBeforeAttempt, nil:
                ghostRepairBulkPreparedClosureState = .idle
            }
        case let .notFound(identity):
            let message = identity == preview.identity
                ? "The exact operation was not found. Keep this closure identity; the prior commit outcome remains unknown."
                : "Closure readback returned a different operation identity. Keep the original closure identity."
            retainGhostRepairBulkPreparedClosureReadFailure(
                protectedPhase: protectedPhase,
                origin: origin,
                preview: preview,
                message: message
            )
        case let .unavailable(message):
            retainGhostRepairBulkPreparedClosureReadFailure(
                protectedPhase: protectedPhase,
                origin: origin,
                preview: preview,
                message: "Exact closure readback is unavailable: \(message)"
            )
        }
    }

    private func protectedPreparedClosureEvidence(
        matching identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) -> (
        origin: GhostRepairBulkPreparedClosureOrigin,
        preview: CodexGhostRepairBulkPreparedClosurePreview,
        acceptsEquivalentReviewedClosure: Bool
    )? {
        guard ghostRepairBulkProtectedOperation?.savedPreviewRequestID
                == identity.requestID,
              ghostRepairBulkProtectedOperation?.operationID
                == identity.operationID,
              let phase = ghostRepairBulkProtectedOperation?.phase else {
            return nil
        }
        switch phase {
        case let .preparedClosureReviewReady(origin, preview),
             let .closingPreparedClosure(origin, preview, _),
             let .preparedClosureOutcomeUnknown(origin, preview, _):
            return (origin, preview, false)
        case let .preparedClosureRecoveryRequired(
            origin,
            preview,
            summary,
            _
        ):
            return (
                origin,
                preview,
                summary.map {
                    preparedClosureSummaryProvesClosedOriginal(
                        $0,
                        preview: preview
                    )
                } ?? false
            )
        case .confirming, .confirmationOutcomeUnknown, .confirmed,
             .preparingFinalReview, .reviewReady, .executing, .completed,
             .completedUnresolved, .recoveryRequired,
             .closedBeforeAttempt:
            return nil
        }
    }

    private func preparedClosurePreview(
        _ preview: CodexGhostRepairBulkPreparedClosurePreview,
        matches identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        origin: GhostRepairBulkPreparedClosureOrigin,
        expectedItems: [GhostRepairBulkProtectedItem]?
    ) -> Bool {
        guard (try? preview.validate()) != nil,
              preview.identity == identity else { return false }
        let observedItems = preview.selectedItems.map {
            GhostRepairBulkProtectedItem(
                threadID: $0.threadID,
                category: $0.category
            )
        }
        if let expectedItems, observedItems != expectedItems {
            return false
        }
        switch origin {
        case let .current(receipt, review):
            return preview.confirmationReceiptID == receipt.receiptID
                && preview.identity.requestID
                    == receipt.savedPreviewRequestID
                && preview.identity.operationID == receipt.operationID
                && preview.planDigest == review.reviewDigest
                && preview.confirmationReceiptDigest == receipt.receiptDigest
                && preview.selectedItems.count == review.selectedCount
        case let .previousOperation(summary):
            return summary.identity == identity
                && summary.phase == .prepared
                && summary.mutationAttemptCount == 0
                && !summary.hasTerminalReport
                && summary.confirmationReceiptID
                    == preview.confirmationReceiptID
                && summary.selectedCount == preview.selectedItems.count
        }
    }

    private func preparedClosureResult(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        closure: CodexGhostRepairBulkPreparedClosureRecord,
        matches identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        preview: CodexGhostRepairBulkPreparedClosurePreview?,
        acceptsEquivalentReviewedClosure: Bool = false,
        expectedItems: [GhostRepairBulkProtectedItem]?
    ) -> Bool {
        guard (try? closure.validate()) != nil,
              summary.identity == identity,
              closure.identity == identity,
              summary.phase == .closedBeforeAttempt,
              summary.mutationAttemptCount == 0,
              !summary.hasTerminalReport,
              summary.confirmationReceiptID == closure.confirmationReceiptID,
              summary.selectedCount == closure.selectedItems.count,
              closure.reason == .userClosedUnstartedPlan else {
            return false
        }
        let observedItems = closure.selectedItems.map {
            GhostRepairBulkProtectedItem(
                threadID: $0.threadID,
                category: $0.category
            )
        }
        if let expectedItems, observedItems != expectedItems {
            return false
        }
        guard let preview else { return true }
        return preparedClosureRecord(
            closure,
            matches: preview,
            acceptsEquivalentReviewedClosure:
                acceptsEquivalentReviewedClosure
        )
    }

    private func preparedClosureSummaryProvesClosedOriginal(
        _ summary: CodexGhostRepairBulkRecoveryOperationSummary,
        preview: CodexGhostRepairBulkPreparedClosurePreview
    ) -> Bool {
        summary.identity == preview.identity
            && summary.phase == .closedBeforeAttempt
            && summary.mutationAttemptCount == 0
            && !summary.hasTerminalReport
            && summary.confirmationReceiptID == preview.confirmationReceiptID
            && summary.selectedCount == preview.selectedItems.count
    }

    private func preparedClosureRecord(
        _ closure: CodexGhostRepairBulkPreparedClosureRecord,
        matches preview: CodexGhostRepairBulkPreparedClosurePreview,
        acceptsEquivalentReviewedClosure: Bool
    ) -> Bool {
        (acceptsEquivalentReviewedClosure
            || (closure.closureReviewID == preview.closureReviewID
                && closure.reviewDigest == preview.reviewDigest
                && closure.reviewedAtMilliseconds
                    == preview.reviewedAtMilliseconds))
            && closure.expectedPreparedJournalPayloadHash
                == preview.expectedJournalPayloadHash
            && closure.confirmationReceiptID == preview.confirmationReceiptID
            && closure.selectedItems == preview.selectedItems
            && closure.planDigest == preview.planDigest
            && closure.confirmationReceiptDigest
                == preview.confirmationReceiptDigest
            && closure.backupReceiptDigest == preview.backupReceiptDigest
            && closure.preparedAtMilliseconds
                == preview.preparedAtMilliseconds
    }

    private func preparedClosureRecord(
        _ closure: CodexGhostRepairBulkPreparedClosureRecord,
        matches origin: GhostRepairBulkPreparedClosureOrigin
    ) -> Bool {
        switch origin {
        case let .current(receipt, review):
            return closure.identity.requestID
                    == receipt.savedPreviewRequestID
                && closure.identity.operationID == receipt.operationID
                && closure.confirmationReceiptID == receipt.receiptID
                && closure.confirmationReceiptDigest == receipt.receiptDigest
                && closure.planDigest == review.reviewDigest
        case let .previousOperation(summary):
            return closure.identity == summary.identity
                && closure.confirmationReceiptID
                    == summary.confirmationReceiptID
                && closure.selectedItems.count == summary.selectedCount
        }
    }

    private func preparedClosureRecordMatchesProtectedOperation(
        _ closure: CodexGhostRepairBulkPreparedClosureRecord,
        identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) -> Bool {
        guard let protectedOperation = ghostRepairBulkProtectedOperation else {
            return true
        }
        guard protectedOperation.savedPreviewRequestID == identity.requestID,
              protectedOperation.operationID == identity.operationID,
              closure.identity == identity else { return false }

        func matches(
            receipt: CodexGhostRepairBulkConfirmationReceipt
        ) -> Bool {
            closure.identity.requestID == receipt.savedPreviewRequestID
                && closure.identity.operationID == receipt.operationID
                && closure.confirmationReceiptID == receipt.receiptID
                && closure.confirmationReceiptDigest == receipt.receiptDigest
        }

        switch protectedOperation.phase {
        case .confirming, .confirmationOutcomeUnknown:
            return false
        case let .confirmed(receipt),
             let .recoveryRequired(receipt, _):
            return matches(receipt: receipt)
        case let .reviewReady(receipt, review):
            return matches(receipt: receipt)
                && closure.planDigest == review.reviewDigest
        case .preparingFinalReview, .executing, .completed,
             .completedUnresolved:
            return false
        case let .preparedClosureReviewReady(origin, preview),
             let .closingPreparedClosure(origin, preview, _),
             let .preparedClosureOutcomeUnknown(origin, preview, _):
            return preparedClosureRecord(closure, matches: origin)
                && closure.closureReviewID == preview.closureReviewID
                && closure.reviewDigest == preview.reviewDigest
                && closure.expectedPreparedJournalPayloadHash
                    == preview.expectedJournalPayloadHash
                && closure.confirmationReceiptID
                    == preview.confirmationReceiptID
                && closure.selectedItems == preview.selectedItems
                && closure.planDigest == preview.planDigest
                && closure.confirmationReceiptDigest
                    == preview.confirmationReceiptDigest
                && closure.backupReceiptDigest
                    == preview.backupReceiptDigest
        case let .preparedClosureRecoveryRequired(
            origin,
            preview,
            summary,
            _
        ):
            let acceptsEquivalentReviewedClosure = summary.map {
                preparedClosureSummaryProvesClosedOriginal(
                    $0,
                    preview: preview
                )
            } ?? false
            return preparedClosureRecord(closure, matches: origin)
                && preparedClosureRecord(
                    closure,
                    matches: preview,
                    acceptsEquivalentReviewedClosure:
                        acceptsEquivalentReviewedClosure
                )
        case let .closedBeforeAttempt(existingClosure):
            return existingClosure == closure
        }
    }

    private func retainInvalidGhostRepairBulkPreparedClosureReview(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        origin: GhostRepairBulkPreparedClosureOrigin,
        message: String
    ) {
        if case let .current(receipt, review) = origin,
           ghostRepairBulkProtectedOperation?.savedPreviewRequestID
            == identity.requestID,
           ghostRepairBulkProtectedOperation?.operationID
            == identity.operationID {
            ghostRepairBulkProtectedOperation?.phase = .reviewReady(
                receipt: receipt,
                review: review
            )
        }
        ghostRepairBulkPreparedClosureState = .unavailable(message: message)
    }

    private func retainUnknownGhostRepairBulkPreparedClosure(
        origin: GhostRepairBulkPreparedClosureOrigin,
        preview: CodexGhostRepairBulkPreparedClosurePreview,
        message: String
    ) {
        ghostRepairBulkProtectedOperation?.phase =
            .preparedClosureOutcomeUnknown(
                origin: origin,
                preview: preview,
                message: message
            )
        ghostRepairBulkPreparedClosureState = .persistenceUncertain(
            preview: preview,
            message: message
        )
        ghostRepairBulkRepairState = .recoveryRequired(
            operationID: preview.identity.operationID,
            message: message
        )
    }

    private func retainGhostRepairBulkPreparedClosureReadFailure(
        protectedPhase: GhostRepairBulkProtectedOperation.Phase,
        origin: GhostRepairBulkPreparedClosureOrigin,
        preview: CodexGhostRepairBulkPreparedClosurePreview,
        message: String
    ) {
        guard case let .preparedClosureRecoveryRequired(
            currentOrigin,
            currentPreview,
            summary,
            _
        ) = protectedPhase,
        currentOrigin == origin,
        currentPreview == preview else {
            retainUnknownGhostRepairBulkPreparedClosure(
                origin: origin,
                preview: preview,
                message: message
            )
            return
        }
        ghostRepairBulkProtectedOperation?.phase =
            .preparedClosureRecoveryRequired(
                origin: origin,
                preview: preview,
                summary: summary,
                message: message
            )
        if let summary {
            ghostRepairBulkPreparedClosureState = .recoveryRequired(
                summary: summary,
                message: message
            )
        } else {
            ghostRepairBulkPreparedClosureState = .unavailable(
                message: message
            )
        }
        ghostRepairBulkRepairState = .recoveryRequired(
            operationID: preview.identity.operationID,
            message: message
        )
    }

    private func retainGhostRepairBulkPreparedClosureRecovery(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        origin: GhostRepairBulkPreparedClosureOrigin,
        expectedItems: [GhostRepairBulkProtectedItem]?,
        preview: CodexGhostRepairBulkPreparedClosurePreview? = nil,
        summary: CodexGhostRepairBulkRecoveryOperationSummary?,
        message: String
    ) {
        if let preview {
            if ghostRepairBulkProtectedOperation == nil,
               let expectedItems {
                ghostRepairBulkProtectedOperation = .init(
                    savedPreviewRequestID: identity.requestID,
                    operationID: identity.operationID,
                    expectedItems: expectedItems,
                    phase: .preparedClosureRecoveryRequired(
                        origin: origin,
                        preview: preview,
                        summary: summary,
                        message: message
                    )
                )
            } else {
                ghostRepairBulkProtectedOperation?.phase =
                    .preparedClosureRecoveryRequired(
                        origin: origin,
                        preview: preview,
                        summary: summary,
                        message: message
                    )
            }
        } else if case let .current(receipt, _) = origin {
            ghostRepairBulkProtectedOperation?.phase = .recoveryRequired(
                receipt: receipt,
                message: message
            )
        }
        if let summary {
            ghostRepairBulkPreparedClosureState = .recoveryRequired(
                summary: summary,
                message: message
            )
        } else {
            ghostRepairBulkPreparedClosureState = .unavailable(
                message: message
            )
        }
        ghostRepairBulkRepairState = .recoveryRequired(
            operationID: identity.operationID,
            message: message
        )
    }

    private func acceptGhostRepairBulkPreparedClosure(
        summary: CodexGhostRepairBulkRecoveryOperationSummary,
        closure: CodexGhostRepairBulkPreparedClosureRecord,
        newlyClosed: Bool,
        expectedIdentity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) {
        guard summary.identity == expectedIdentity,
              closure.identity == expectedIdentity,
              preparedClosureRecordMatchesProtectedOperation(
                  closure,
                  identity: expectedIdentity
              ) else { return }
        if let protectedOperation = ghostRepairBulkProtectedOperation {
            guard protectedOperation.savedPreviewRequestID
                    == expectedIdentity.requestID,
                  protectedOperation.operationID
                    == expectedIdentity.operationID else { return }
            ghostRepairBulkProtectedOperation?.phase =
                .closedBeforeAttempt(closure)
        } else {
            ghostRepairBulkProtectedOperation = .init(
                savedPreviewRequestID: expectedIdentity.requestID,
                operationID: expectedIdentity.operationID,
                expectedItems: closure.selectedItems.map {
                    .init(threadID: $0.threadID, category: $0.category)
                },
                phase: .closedBeforeAttempt(closure)
            )
        }
        ghostRepairBulkRepairState = .closedBeforeAttempt(closure)
        ghostRepairBulkPreparedClosureState = .closedBeforeAttempt(
            summary: summary,
            closure: closure,
            newlyClosed: newlyClosed
        )
        updateGhostRepairBulkPreviousOperationSummary(summary)
        clearGhostRepairBulkRecoveryProjection(for: expectedIdentity)
    }

    private func updateGhostRepairBulkPreviousOperationSummary(
        _ summary: CodexGhostRepairBulkRecoveryOperationSummary
    ) {
        guard case let .observed(operations) =
                ghostRepairBulkPreviousOperationsState,
              let index = operations.firstIndex(where: {
                  $0.identity == summary.identity
              }) else { return }
        var updated = operations
        updated[index] = summary
        ghostRepairBulkPreviousOperationsState = .observed(updated)
    }

    private func clearGhostRepairBulkRecoveryProjection(
        for identity: CodexGhostRepairBulkRecoveryOperationIdentity
    ) {
        switch ghostRepairBulkRecoveryReadbackState {
        case let .reading(_, currentIdentity),
             let .notFound(currentIdentity):
            if currentIdentity == identity {
                ghostRepairBulkRecoveryReadbackState = .idle
            }
        case let .terminal(summary, _),
             let .closedBeforeAttempt(summary, _),
             let .recoveryRequired(summary, _):
            if summary.identity == identity {
                ghostRepairBulkRecoveryReadbackState = .idle
            }
        case .idle, .unavailable:
            break
        }
        switch ghostRepairBulkFreshRecoveryState {
        case let .recovering(_, currentIdentity),
             let .notFound(currentIdentity):
            if currentIdentity == identity {
                ghostRepairBulkFreshRecoveryState = .idle
            }
        case let .terminal(summary, _, _),
             let .closedBeforeAttempt(summary, _),
             let .recoveryRequired(summary, _):
            if summary.identity == identity {
                ghostRepairBulkFreshRecoveryState = .idle
            }
        case .idle, .unavailable:
            break
        }
    }

    func readSelectedGhostRepairBulkRecoveryOperation() async {
        guard ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil,
              ghostRepairBulkPreparedClosureRequestID == nil else {
            return
        }
        guard ghostRepairBulkRecoveryReadbackBlockedReason == nil,
              let identity =
                ghostRepairBulkSelectedRecoveryOperationIdentity,
              let expectedSummary =
                ghostRepairBulkPreviousOperations.first(where: {
                    $0.identity == identity
                }) else {
            ghostRepairBulkRecoveryReadbackState = .unavailable(
                message: ghostRepairBulkRecoveryReadbackBlockedReason
                    ?? "Exact operation readback is unavailable."
            )
            return
        }
        let requestID = UUID()
        ghostRepairBulkRecoveryReadbackRequestID = requestID
        ghostRepairBulkFreshRecoveryState = .idle
        ghostRepairBulkRecoveryReadbackState = .reading(
            requestID: requestID,
            identity: identity
        )
        let outcome = await ghostRepairBulkRecoveryCoordinator.readOperation(
            identity: identity
        )
        guard ghostRepairBulkRecoveryReadbackRequestID == requestID,
              ghostRepairBulkSelectedRecoveryOperationIdentity == identity
        else { return }
        ghostRepairBulkRecoveryReadbackRequestID = nil
        switch outcome {
        case let .terminal(summary, report):
            guard summary.identity == identity,
                  summary.confirmationReceiptID
                    == expectedSummary.confirmationReceiptID,
                  summary.selectedCount == expectedSummary.selectedCount,
                  summary.hasTerminalReport,
                  report.operationID == identity.operationID,
                  report.itemReports.count == summary.selectedCount else {
                ghostRepairBulkRecoveryReadbackState = .unavailable(
                    message: "The terminal Report did not match the exact selected operation."
                )
                return
            }
            ghostRepairBulkRecoveryReadbackState = .terminal(
                summary: summary,
                report: report
            )
            reconcileProtectedGhostRepairBulkOperation(
                identity: identity,
                report: report
            )
        case let .closedBeforeAttempt(summary, closure):
            let protectedClosureEvidence =
                protectedPreparedClosureEvidence(matching: identity)
            guard preparedClosureResult(
                summary: summary,
                closure: closure,
                matches: identity,
                preview: protectedClosureEvidence?.preview,
                acceptsEquivalentReviewedClosure:
                    protectedClosureEvidence?
                        .acceptsEquivalentReviewedClosure ?? false,
                expectedItems: ghostRepairBulkProtectedOperation?
                    .expectedItems
            ), summary.confirmationReceiptID
                == expectedSummary.confirmationReceiptID,
               summary.selectedCount == expectedSummary.selectedCount,
               preparedClosureRecordMatchesProtectedOperation(
                   closure,
                   identity: identity
               ) else {
                ghostRepairBulkRecoveryReadbackState = .unavailable(
                    message: "Closed-plan evidence did not match the exact selected operation."
                )
                return
            }
            acceptGhostRepairBulkPreparedClosure(
                summary: summary,
                closure: closure,
                newlyClosed: false,
                expectedIdentity: identity
            )
            ghostRepairBulkRecoveryReadbackState = .closedBeforeAttempt(
                summary: summary,
                closure: closure
            )
        case let .recoveryRequired(summary, message):
            guard summary.identity == identity,
                  summary.confirmationReceiptID
                    == expectedSummary.confirmationReceiptID,
                  summary.selectedCount == expectedSummary.selectedCount,
                  !summary.hasTerminalReport else {
                ghostRepairBulkRecoveryReadbackState = .unavailable(
                    message: "Recovery evidence did not match the exact selected operation."
                )
                return
            }
            ghostRepairBulkRecoveryReadbackState = .recoveryRequired(
                summary: summary,
                message: message
            )
            if ghostRepairBulkProtectedOperation?.savedPreviewRequestID
                    == identity.requestID,
               ghostRepairBulkProtectedOperation?.operationID
                    == identity.operationID,
               let receipt = protectedGhostRepairBulkReceipt {
                ghostRepairBulkProtectedOperation?.phase = .recoveryRequired(
                    receipt: receipt,
                    message: message
                )
                ghostRepairBulkRepairState = .recoveryRequired(
                    operationID: identity.operationID,
                    message: message
                )
            }
        case let .notFound(returnedIdentity):
            guard returnedIdentity == identity else {
                ghostRepairBulkRecoveryReadbackState = .unavailable(
                    message: "The not-found result did not match the exact selected operation."
                )
                return
            }
            ghostRepairBulkRecoveryReadbackState = .notFound(
                identity: identity
            )
        case let .unavailable(message):
            ghostRepairBulkRecoveryReadbackState = .unavailable(
                message: message
            )
        }
    }

    func recoverUnknownGhostRepairBulkConfirmationReceipt() async {
        guard ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil else {
            return
        }
        guard ghostRepairBulkConfirmationReceiptRecoveryBlockedReason == nil,
              case let .confirmationOutcomeUnknown(challenge, _) =
                ghostRepairBulkProtectedOperation?.phase else {
            errorMessage = ghostRepairBulkConfirmationReceiptRecoveryBlockedReason
            return
        }
        let request = CodexGhostRepairBulkConfirmationReceiptRecoveryRequest(
            challenge: challenge
        )
        let requestID = UUID()
        ghostRepairBulkConfirmationReceiptRecoveryRequestID = requestID
        ghostRepairBulkConfirmationReceiptRecoveryState = .reading(
            requestID: requestID,
            request: request
        )
        let outcome = await ghostRepairBulkConfirmationReceiptRecoveryCoordinator
            .recoverReceipt(request: request)
        guard ghostRepairBulkConfirmationReceiptRecoveryRequestID == requestID,
              ghostRepairBulkProtectedOperation?.savedPreviewRequestID
                == request.savedPreviewRequestID,
              ghostRepairBulkProtectedOperation?.operationID
                == request.operationID,
              case let .confirmationOutcomeUnknown(currentChallenge, _) =
                ghostRepairBulkProtectedOperation?.phase,
              currentChallenge == challenge else { return }
        ghostRepairBulkConfirmationReceiptRecoveryRequestID = nil
        guard outcome.request == request else {
            let message =
                "Receipt recovery returned a different exact operation. Keep the original operation reference and do not retry confirmation."
            retainUnknownGhostRepairBulkConfirmation(
                challenge: challenge,
                message: message
            )
            ghostRepairBulkConfirmationReceiptRecoveryState =
                .recoveryRequired(
                    request: request,
                    reason: .evidenceInvalid,
                    message: message
                )
            return
        }
        switch outcome {
        case let .confirmed(_, receipt):
            guard recoveredReceipt(receipt, matches: request) else {
                retainUnknownGhostRepairBulkConfirmation(
                    challenge: challenge,
                    message: "Recovered receipt evidence did not match the exact unresolved confirmation."
                )
                ghostRepairBulkConfirmationReceiptRecoveryState =
                    .recoveryRequired(
                        request: request,
                        reason: .evidenceInvalid,
                        message: "Recovered receipt evidence did not match the exact unresolved confirmation. Keep the operation reference and do not retry confirmation."
                    )
                return
            }
            ghostRepairBulkProtectedOperation?.phase = .confirmed(receipt)
            ghostRepairBulkConfirmationReceiptState =
                .alreadyConfirmed(receipt)
            ghostRepairBulkConfirmationReceiptRecoveryState = .confirmed(
                request: request,
                receipt: receipt
            )
        case let .executionRecoveryRequired(_, receipt, phase, message):
            guard recoveredReceipt(receipt, matches: request) else {
                let mismatchMessage =
                    "Execution-owned receipt evidence did not match the exact unresolved confirmation. Keep the operation reference and do not retry confirmation."
                retainUnknownGhostRepairBulkConfirmation(
                    challenge: challenge,
                    message: mismatchMessage
                )
                ghostRepairBulkConfirmationReceiptRecoveryState =
                    .recoveryRequired(
                        request: request,
                        reason: .evidenceInvalid,
                        message: mismatchMessage
                    )
                return
            }
            ghostRepairBulkProtectedOperation?.phase = .recoveryRequired(
                receipt: receipt,
                message: message
            )
            ghostRepairBulkConfirmationReceiptState =
                .alreadyConfirmed(receipt)
            ghostRepairBulkRepairState = .recoveryRequired(
                operationID: request.operationID,
                message: message
            )
            ghostRepairBulkConfirmationReceiptRecoveryState =
                .recoveryRequired(
                    request: request,
                    reason: .executionJournalPresent(phase: phase),
                    message: message
                )
        case let .recoveryRequired(_, reason, message):
            ghostRepairBulkConfirmationReceiptRecoveryState =
                .recoveryRequired(
                    request: request,
                    reason: reason,
                    message: message
                )
        }
    }

    func recoverSelectedGhostRepairBulkOperationFreshly() async {
        guard ghostRepairBulkFreshRecoveryRequestID == nil else { return }
        guard ghostRepairBulkFreshRecoveryBlockedReason == nil,
              let identity =
                ghostRepairBulkSelectedRecoveryOperationIdentity,
              let expectedSummary =
                ghostRepairBulkPreviousOperations.first(where: {
                    $0.identity == identity
                }) else {
            ghostRepairBulkFreshRecoveryState = .unavailable(
                message: ghostRepairBulkFreshRecoveryBlockedReason
                    ?? "Fresh recovery is unavailable."
            )
            return
        }
        let requestID = UUID()
        ghostRepairBulkFreshRecoveryRequestID = requestID
        ghostRepairBulkRecoveryReadbackState = .idle
        ghostRepairBulkFreshRecoveryState = .recovering(
            requestID: requestID,
            identity: identity
        )
        let outcome = await ghostRepairBulkFreshRecoveryCoordinator
            .recoverOperation(identity: identity)
        guard ghostRepairBulkFreshRecoveryRequestID == requestID,
              ghostRepairBulkSelectedRecoveryOperationIdentity == identity
        else { return }
        ghostRepairBulkFreshRecoveryRequestID = nil
        switch outcome {
        case let .terminal(summary, report, source):
            guard summary.identity == identity,
                  summary.confirmationReceiptID
                    == expectedSummary.confirmationReceiptID,
                  summary.selectedCount == expectedSummary.selectedCount,
                  summary.hasTerminalReport,
                  report.operationID == identity.operationID,
                  report.itemReports.count == summary.selectedCount,
                  recoveredReportMatchesProtectedOperation(
                    identity: identity,
                    report: report
                  ) else {
                ghostRepairBulkFreshRecoveryState = .unavailable(
                    message: "Fresh recovery returned a terminal Report for a different exact operation."
                )
                return
            }
            ghostRepairBulkFreshRecoveryState = .terminal(
                summary: summary,
                report: report,
                source: source
            )
            if case let .observed(operations) =
                    ghostRepairBulkPreviousOperationsState,
               let index = operations.firstIndex(where: {
                   $0.identity == identity
               }) {
                var updated = operations
                updated[index] = summary
                ghostRepairBulkPreviousOperationsState = .observed(updated)
            }
            reconcileProtectedGhostRepairBulkOperation(
                identity: identity,
                report: report
            )
        case let .closedBeforeAttempt(summary, closure):
            let protectedClosureEvidence =
                protectedPreparedClosureEvidence(matching: identity)
            guard preparedClosureResult(
                summary: summary,
                closure: closure,
                matches: identity,
                preview: protectedClosureEvidence?.preview,
                acceptsEquivalentReviewedClosure:
                    protectedClosureEvidence?
                        .acceptsEquivalentReviewedClosure ?? false,
                expectedItems: ghostRepairBulkProtectedOperation?
                    .expectedItems
            ), summary.confirmationReceiptID
                == expectedSummary.confirmationReceiptID,
               summary.selectedCount == expectedSummary.selectedCount,
               preparedClosureRecordMatchesProtectedOperation(
                   closure,
                   identity: identity
               ) else {
                ghostRepairBulkFreshRecoveryState = .unavailable(
                    message: "Fresh recovery returned closed-plan evidence for a different exact operation."
                )
                return
            }
            acceptGhostRepairBulkPreparedClosure(
                summary: summary,
                closure: closure,
                newlyClosed: false,
                expectedIdentity: identity
            )
            ghostRepairBulkFreshRecoveryState = .closedBeforeAttempt(
                summary: summary,
                closure: closure
            )
        case let .recoveryRequired(summary, message):
            guard summary.identity == identity,
                  summary.confirmationReceiptID
                    == expectedSummary.confirmationReceiptID,
                  summary.selectedCount == expectedSummary.selectedCount,
                  !summary.hasTerminalReport else {
                ghostRepairBulkFreshRecoveryState = .unavailable(
                    message: "Fresh recovery evidence did not match the exact selected operation."
                )
                return
            }
            ghostRepairBulkFreshRecoveryState = .recoveryRequired(
                summary: summary,
                message: message
            )
            if ghostRepairBulkProtectedOperation?.savedPreviewRequestID
                    == identity.requestID,
               ghostRepairBulkProtectedOperation?.operationID
                    == identity.operationID,
               let receipt = protectedGhostRepairBulkReceipt {
                ghostRepairBulkProtectedOperation?.phase = .recoveryRequired(
                    receipt: receipt,
                    message: message
                )
                ghostRepairBulkRepairState = .recoveryRequired(
                    operationID: identity.operationID,
                    message: message
                )
            }
        case let .notFound(returnedIdentity):
            guard returnedIdentity == identity else {
                ghostRepairBulkFreshRecoveryState = .unavailable(
                    message: "Fresh recovery returned a different operation identity."
                )
                return
            }
            ghostRepairBulkFreshRecoveryState = .notFound(identity: identity)
        case let .unavailable(message):
            ghostRepairBulkFreshRecoveryState = .unavailable(message: message)
        }
    }

    private func recoveredReceipt(
        _ receipt: CodexGhostRepairBulkConfirmationReceipt,
        matches request: CodexGhostRepairBulkConfirmationReceiptRecoveryRequest
    ) -> Bool {
        (try? receipt.validate(challenge: request.challenge)) != nil
            && receipt.savedPreviewRequestID == request.savedPreviewRequestID
            && receipt.operationID == request.operationID
            && receipt.challengeDigest == request.challengeDigest
            && receipt.selectedCount == request.selectedCount
            && receipt.wholeBatchConfirmationRecorded
            && !receipt.createsRepairClaim
            && !receipt.repairClaimCreated
            && !receipt.repairMutationAuthority
            && !receipt.automaticRetryAllowed
    }

    private func recoveredReportMatchesProtectedOperation(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        report: CodexGhostRepairBulkRepairReport
    ) -> Bool {
        guard let protectedOperation = ghostRepairBulkProtectedOperation,
              protectedOperation.savedPreviewRequestID == identity.requestID,
              protectedOperation.operationID == identity.operationID else {
            return true
        }
        let expected = protectedOperation.expectedItems.map {
            ($0.threadID, $0.category)
        }.sorted { $0.0 < $1.0 }
        let observed = report.itemReports.map {
            ($0.threadID, $0.category)
        }.sorted { $0.0 < $1.0 }
        return expected.elementsEqual(
            observed,
            by: { $0.0 == $1.0 && $0.1 == $1.1 }
        )
    }

    private var protectedGhostRepairBulkReceipt:
        CodexGhostRepairBulkConfirmationReceipt?
    {
        guard let phase = ghostRepairBulkProtectedOperation?.phase else {
            return nil
        }
        switch phase {
        case let .confirmed(receipt),
             let .preparingFinalReview(receipt, _),
             let .reviewReady(receipt, _),
             let .executing(receipt, _, _),
             let .completed(receipt, _),
             let .completedUnresolved(receipt, _),
             let .recoveryRequired(receipt, _):
            return receipt
        case let .preparedClosureReviewReady(origin, _),
             let .closingPreparedClosure(origin, _, _),
             let .preparedClosureOutcomeUnknown(origin, _, _),
             let .preparedClosureRecoveryRequired(origin, _, _, _):
            guard case let .current(receipt, _) = origin else {
                return nil
            }
            return receipt
        case .confirming, .confirmationOutcomeUnknown,
             .closedBeforeAttempt:
            return nil
        }
    }

    private func reconcileProtectedGhostRepairBulkOperation(
        identity: CodexGhostRepairBulkRecoveryOperationIdentity,
        report: CodexGhostRepairBulkRepairReport
    ) {
        guard let protectedOperation = ghostRepairBulkProtectedOperation,
              protectedOperation.savedPreviewRequestID == identity.requestID,
              protectedOperation.operationID == identity.operationID else {
            return
        }
        let expectedIdentity = protectedOperation.expectedItems
            .map { ($0.threadID, $0.category) }
            .sorted { $0.0 < $1.0 }
        let reportedIdentity = report.itemReports
            .map { ($0.threadID, $0.category) }
            .sorted { $0.0 < $1.0 }
        guard expectedIdentity.elementsEqual(
            reportedIdentity,
            by: { $0.0 == $1.0 && $0.1 == $1.1 }
        ) else { return }

        let unresolved = report.outcome == .unknown
            || report.itemReports.contains(where: { $0.outcome == .unknown })
        guard let receipt = protectedGhostRepairBulkReceipt else {
            if !unresolved {
                switch protectedOperation.phase {
                case .confirmationOutcomeUnknown,
                     .preparedClosureReviewReady,
                     .closingPreparedClosure,
                     .preparedClosureOutcomeUnknown,
                     .preparedClosureRecoveryRequired:
                    // The independent readback remains the presentation owner;
                    // without the receipt we only retire the matching lock.
                    ghostRepairBulkProtectedOperation = nil
                    ghostRepairBulkPreparedClosureState = .idle
                case .confirming, .confirmed, .preparingFinalReview,
                     .reviewReady, .executing, .completed,
                     .completedUnresolved, .recoveryRequired,
                     .closedBeforeAttempt:
                    break
                }
            }
            return
        }
        if unresolved {
            ghostRepairBulkProtectedOperation?.phase = .completedUnresolved(
                receipt: receipt,
                report: report
            )
        } else {
            ghostRepairBulkProtectedOperation?.phase = .completed(
                receipt: receipt,
                report: report
            )
        }
        ghostRepairBulkRepairState = .completed(report)
    }

    var isGhostRepairBulkProtectedOperationActive: Bool {
        ghostRepairBulkProtectedOperation != nil
    }

    func nativeDeleteDesktopCleanupBlockedReason(
        report: NativeDeleteReport
    ) -> String? {
        guard isGhostRepairBulkWorkflowEnabled else {
            return "Enable Bulk Ghost Delete in Settings before continuing."
        }
        guard nativeDeleteDesktopCleanupCoordinator.capabilities.available else {
            return "Desktop cleanup linkage is unavailable in this build."
        }
        guard report.id == latestNativeDeleteReport?.id else {
            return "This is not the current canonical Delete report."
        }
        let successfulIDs = report.items
            .filter {
                $0.outcome == .success
                    && $0.observedNativeState == .absent
            }
            .map(\.nativeSessionID)
            .sorted()
        guard !successfulIDs.isEmpty else {
            return "No canonically deleted session is available for Desktop cleanup."
        }
        guard Set(successfulIDs).count == successfulIDs.count,
              successfulIDs.allSatisfy({ !$0.isEmpty }) else {
            return "The canonical Delete report does not contain a unique exact cleanup scope."
        }
        guard successfulIDs.count
                <= CodexGhostRepairBulkPreview.maximumSelectedItems else {
            return "This canonical Delete report exceeds the supported Bulk Ghost Delete limit."
        }
        guard case .idle = nativeDeleteDesktopCleanupState else {
            return "Finish or cancel the current Desktop cleanup handoff first."
        }
        if let reason = ghostRepairBulkWorkflowMutationBlockedReason {
            return reason
        }
        if isGhostRepairBulkPreparationInFlight {
            return "Wait for the current Bulk Ghost Delete preparation step to finish."
        }
        return nil
    }

    func queueNativeDeleteDesktopCleanup(report: NativeDeleteReport) {
        guard let blockedReason = nativeDeleteDesktopCleanupBlockedReason(
            report: report
        ) else {
            let successfulIDs = report.items
                .filter {
                    $0.outcome == .success
                        && $0.observedNativeState == .absent
                }
                .map(\.nativeSessionID)
                .sorted()
            nativeDeleteDesktopCleanupState = .queued(
                NativeDeleteDesktopCleanupContext(
                    canonicalDeleteReportID: report.id,
                    expectedNativeSessionIDs: successfulIDs,
                    nativeDeleteItemCount: report.items.count
                )
            )
            return
        }
        errorMessage = blockedReason
    }

    func presentQueuedNativeDeleteDesktopCleanup() {
        if shouldPresentNativeDeleteCleanupReview {
            shouldPresentNativeDeleteCleanupReview = false
            presentGhostRepairBulkInventory()
            return
        }
        if let reportID = nativeDeleteDesktopCleanupContext?.canonicalDeleteReportID,
           nativeDeleteDesktopCleanupVerified(reportID: reportID) {
            finishNativeDeleteReport(reportID: reportID)
            return
        }
        guard case .queued = nativeDeleteDesktopCleanupState else { return }
        presentGhostRepairBulkInventory()
    }

    func reviewNativeDeleteCleanupResult(reportID: UUID) {
        guard nativeDeleteDesktopCleanupContext?.canonicalDeleteReportID == reportID else { return }
        shouldPresentNativeDeleteCleanupReview = true
    }

    func finishNativeDeleteReport(reportID: UUID) {
        guard nativeDeleteDesktopCleanupVerified(reportID: reportID) else { return }
        if nativeDeleteDesktopAbsenceVerifiedReportID == reportID {
            cancelNativeDeleteDesktopCleanupHandoff()
        } else {
            _ = startNewGhostRepairBulkPreparation()
        }
    }

    var nativeDeleteDesktopCleanupTitle: String? {
        if nativeDeleteDesktopAbsenceVerifiedReportID != nil,
           nativeDeleteDesktopAbsenceVerifiedReportID
                == nativeDeleteDesktopCleanupContext?.canonicalDeleteReportID {
            return "No Desktop residue found"
        }
        switch nativeDeleteDesktopCleanupState {
        case .idle:
            return nil
        case .queued, .reviewing, .pending:
            return "Desktop cleanup pending"
        case .inventoryReady:
            return "Exact Desktop cleanup scope ready"
        case .inventoryBlocked:
            return "Desktop cleanup scope blocked"
        case .binding:
            return "Recording exact cleanup linkage"
        case .bindingRecoveryRequired:
            return "Cleanup linkage requires readback"
        case let .status(_, status):
            switch status {
            case .pending:
                return "Desktop cleanup pending"
            case .prepared:
                return "Desktop cleanup plan prepared"
            case .recoveryRequired:
                return "Desktop cleanup recovery required"
            case .closedBeforeAttempt:
                return "Desktop cleanup plan closed"
            case .terminalNotVerified:
                return "Desktop cleanup not verified"
            case .outcomeUnknown:
                return "Desktop cleanup outcome unknown"
            case .verified:
                return "Desktop cleanup verified"
            }
        case .unavailable:
            return "Desktop cleanup unavailable"
        }
    }

    var nativeDeleteDesktopCleanupSummary: String? {
        let prefix: String
        guard let context = nativeDeleteDesktopCleanupContext else { return nil }
        if nativeDeleteDesktopAbsenceVerifiedReportID == context.canonicalDeleteReportID {
            return "The exact \(context.expectedNativeSessionIDs.count) canonically deleted IDs had no Desktop catalog, automation, or side-reference residue at the post-Delete check. No Desktop mutation was needed."
        }
        if context.isPartialNativeDeleteSuccess {
            prefix = "The native Delete report recorded \(context.expectedNativeSessionIDs.count) successful items out of \(context.nativeDeleteItemCount). This follow-up keeps only that exact successful scope; the other report outcomes remain unchanged. "
        } else {
            prefix = "This follow-up keeps all \(context.expectedNativeSessionIDs.count) canonically deleted session IDs as one exact scope. "
        }
        switch nativeDeleteDesktopCleanupState {
        case .idle:
            return nil
        case .queued:
            return prefix + "Desktop cleanup is queued. The official Delete request will not be resent."
        case .reviewing:
            return prefix + "Manager-owned Delete evidence is being checked."
        case .pending:
            return prefix + "Checking Desktop residue for the exact successful IDs."
        case .inventoryReady:
            return prefix + "Every requested ID is either already clear or an eligible classified ghost. Preparing the complete cleanup plan."
        case let .inventoryBlocked(_, _, _, message),
             let .bindingRecoveryRequired(_, _, _, message),
             let .unavailable(_, message):
            return prefix + message
        case .binding:
            return prefix + "The prepared operation is being bound before Execute can be exposed."
        case let .status(_, status):
            switch status {
            case .pending:
                return prefix + "No prepared Bulk operation is bound yet."
            case .prepared:
                return prefix + "The exact prepared operation is durably linked and may use its existing Execute step."
            case let .recoveryRequired(_, _, _, message):
                return prefix + message
            case .closedBeforeAttempt:
                return prefix + "The bound plan was closed before any cleanup attempt. Desktop absence was not verified."
            case let .terminalNotVerified(_, _, outcome):
                return prefix + "The bound operation ended as \(String(describing: outcome)); Desktop cleanup was not verified."
            case .outcomeUnknown:
                return prefix + "The bound cleanup outcome is unknown. Do not retry or replace it."
            case let .verified(_, _, completedAtMilliseconds):
                let date = Date(
                    timeIntervalSince1970:
                        TimeInterval(completedAtMilliseconds) / 1_000
                )
                return prefix + "The exact bound terminal record verified cleanup at \(date.formatted()). This is historical operation evidence, not a current global absence check."
            }
        }
    }

    var nativeDeleteDesktopCleanupTargets:
        [NativeDeleteDesktopCleanupTarget]
    {
        if let context = nativeDeleteDesktopCleanupContext,
           nativeDeleteDesktopAbsenceVerifiedReportID == context.canonicalDeleteReportID {
            return context.expectedNativeSessionIDs.map {
                .init(nativeSessionID: $0, state: .verified, category: nil,
                      message: "No Desktop residue was found at the post-Delete check.")
            }
        }
        switch nativeDeleteDesktopCleanupState {
        case .idle:
            return []
        case let .queued(context), let .reviewing(_, context),
             let .unavailable(context, _):
            return context.expectedNativeSessionIDs.map {
                NativeDeleteDesktopCleanupTarget(
                    nativeSessionID: $0,
                    state: .pending,
                    category: nil,
                    message: "Awaiting exact manager-owned cleanup evidence."
                )
            }
        case let .pending(_, handoff):
            return handoff.items.map {
                NativeDeleteDesktopCleanupTarget(
                    nativeSessionID: $0.nativeSessionID,
                    state: .pending,
                    category: nil,
                    message: "Awaiting Bulk inventory classification."
                )
            }
        case let .inventoryReady(_, handoff):
            let inventoryByID = Dictionary(
                uniqueKeysWithValues:
                    (ghostRepairBulkInventory?.items ?? []).map {
                        ($0.threadID, $0)
                    }
            )
            return handoff.nativeSessionIDs.map { id in
                NativeDeleteDesktopCleanupTarget(
                    nativeSessionID: id,
                    state: .eligible,
                    category: inventoryByID[id]?.category,
                    message: "Eligible in the exact frozen cleanup scope."
                )
            }
        case let .inventoryBlocked(_, _, targets, _):
            return targets
        case let .binding(_, _, handoff, _):
            return handoff.nativeSessionIDs.map {
                NativeDeleteDesktopCleanupTarget(
                    nativeSessionID: $0,
                    state: .pending,
                    category: nil,
                    message: "Awaiting durable prepared-operation linkage."
                )
            }
        case let .bindingRecoveryRequired(_, handoff, _, message):
            return handoff.nativeSessionIDs.map {
                NativeDeleteDesktopCleanupTarget(
                    nativeSessionID: $0,
                    state: .outcomeUnknown,
                    category: nil,
                    message: message
                )
            }
        case let .status(_, status):
            return nativeDeleteDesktopCleanupTargets(for: status)
        }
    }

    var nativeDeleteDesktopCleanupPrepareBlockedReason: String? {
        switch nativeDeleteDesktopCleanupState {
        case .queued:
            return ghostRepairBulkPreparationBlockedReason
        case .reviewing:
            return "The canonical Delete handoff is already being checked."
        case .pending:
            return ghostRepairBulkPreparationBlockedReason
        case .inventoryReady:
            return "The exact cleanup inventory is already ready."
        case .inventoryBlocked:
            return "The exact cleanup scope is blocked. No smaller Preview may be created."
        case .binding, .bindingRecoveryRequired, .status:
            return "This cleanup handoff already owns a durable operation or recovery state."
        case .unavailable:
            return "The canonical Delete handoff is unavailable."
        case .idle:
            return "No canonical Delete handoff is queued."
        }
    }

    var nativeDeleteDesktopCleanupStatusBlockedReason: String? {
        switch nativeDeleteDesktopCleanupState {
        case .bindingRecoveryRequired:
            return nil
        case let .status(_, status):
            return nativeDeleteDesktopCleanupStatusEvidence(status).binding == nil
                ? "No bound Desktop cleanup operation is available for exact status readback."
                : nil
        case .reviewing, .binding:
            return "Wait for the current Desktop cleanup request to finish."
        case .queued, .pending, .inventoryReady, .inventoryBlocked,
             .unavailable, .idle:
            return "No bound Desktop cleanup operation is available for exact status readback."
        }
    }

    var nativeDeleteDesktopCleanupCancelBlockedReason: String? {
        switch nativeDeleteDesktopCleanupState {
        case .idle:
            return "No Desktop cleanup handoff is active."
        case .reviewing, .binding:
            return "Wait for the current Desktop cleanup request to finish."
        case .bindingRecoveryRequired, .status:
            return "This handoff owns durable operation evidence and cannot be discarded."
        case .queued, .pending, .inventoryReady, .inventoryBlocked,
             .unavailable:
            return ghostRepairBulkProtectedOperation == nil
                ? nil
                : "This handoff is attached to a protected Bulk operation."
        }
    }

    var nativeDeleteDesktopCleanupSelectionBlockedReason: String? {
        switch nativeDeleteDesktopCleanupState {
        case .inventoryReady:
            return "The canonical Delete handoff owns this exact selection. Cancel the handoff to choose a different scope."
        case .idle:
            return nil
        case .queued, .reviewing, .pending, .inventoryBlocked, .binding,
             .bindingRecoveryRequired, .status, .unavailable:
            return "The canonical Delete handoff does not permit manual selection changes."
        }
    }

    var nativeDeleteDesktopCleanupExecutionBlockedReason: String? {
        guard case let .status(_, status) = nativeDeleteDesktopCleanupState else {
            if case .idle = nativeDeleteDesktopCleanupState { return nil }
            return "The exact canonical Delete scope is not durably bound to this prepared operation."
        }
        guard case let .prepared(handoff, binding) = status,
              nativeDeleteDesktopCleanupBindingMatchesProtectedOperation(
                handoff: handoff,
                binding: binding
              ) else {
            return "The bound cleanup operation is not in the exact prepared state. Do not execute or replace it."
        }
        return nil
    }

    func cancelNativeDeleteDesktopCleanupHandoff() {
        guard nativeDeleteDesktopCleanupCancelBlockedReason == nil else {
            errorMessage = nativeDeleteDesktopCleanupCancelBlockedReason
            return
        }
        nativeDeleteDesktopCleanupState = .idle
        nativeDeleteAutomaticCleanupReportID = nil
        nativeDeleteDesktopAbsenceVerifiedReportID = nil
        resetGhostRepairBulkWorkflowState(
            enabled: isGhostRepairBulkReconciliationEnabled
        )
    }

    private var nativeDeleteDesktopCleanupContext:
        NativeDeleteDesktopCleanupContext?
    {
        switch nativeDeleteDesktopCleanupState {
        case .idle:
            return nil
        case let .queued(context), let .reviewing(_, context),
             let .pending(context, _), let .inventoryReady(context, _),
             let .inventoryBlocked(context, _, _, _),
             let .binding(_, context, _, _),
             let .bindingRecoveryRequired(context, _, _, _),
             let .status(context, _), let .unavailable(context, _):
            return context
        }
    }

    private var isNativeDeleteDesktopCleanupRequestInFlight: Bool {
        switch nativeDeleteDesktopCleanupState {
        case .reviewing, .binding:
            return true
        case .idle, .queued, .pending, .inventoryReady, .inventoryBlocked,
             .bindingRecoveryRequired, .status, .unavailable:
            return false
        }
    }

    private func nativeDeleteDesktopCleanupTargets(
        for status: CodexDesktopCleanupStatus
    ) -> [NativeDeleteDesktopCleanupTarget] {
        let handoff: CodexDesktopCleanupHandoff
        let binding: CodexDesktopCleanupBinding?
        let state: NativeDeleteDesktopCleanupTargetState
        let message: String
        switch status {
        case let .pending(value):
            handoff = value
            binding = nil
            state = .pending
            message = "No prepared Bulk operation is bound yet."
        case let .prepared(value, valueBinding):
            handoff = value
            binding = valueBinding
            state = .eligible
            message = "Durably bound to the exact prepared Bulk operation."
        case let .recoveryRequired(value, valueBinding, _, valueMessage):
            handoff = value
            binding = valueBinding
            state = .outcomeUnknown
            message = valueMessage
        case let .closedBeforeAttempt(value, valueBinding):
            handoff = value
            binding = valueBinding
            state = .blocked
            message = "The plan was closed before any cleanup attempt."
        case let .terminalNotVerified(value, valueBinding, outcome):
            handoff = value
            binding = valueBinding
            state = .blocked
            message = "The terminal operation ended as \(String(describing: outcome)); cleanup was not verified."
        case let .outcomeUnknown(value, valueBinding):
            handoff = value
            binding = valueBinding
            state = .outcomeUnknown
            message = "The exact cleanup outcome is unknown. Do not retry."
        case let .verified(value, valueBinding, _):
            handoff = value
            binding = valueBinding
            state = .verified
            message = "The bound terminal record verified this exact cleanup item."
        }
        let categories = Dictionary(
            uniqueKeysWithValues: (binding?.items ?? []).map {
                ($0.nativeSessionID, $0.category)
            }
        )
        return handoff.nativeSessionIDs.map {
            NativeDeleteDesktopCleanupTarget(
                nativeSessionID: $0,
                state: state,
                category: categories[$0],
                message: message
            )
        }
    }

    private func nativeDeleteDesktopCleanupStatusEvidence(
        _ status: CodexDesktopCleanupStatus
    ) -> (
        handoff: CodexDesktopCleanupHandoff,
        binding: CodexDesktopCleanupBinding?
    ) {
        switch status {
        case let .pending(handoff):
            return (handoff, nil)
        case let .prepared(handoff, binding),
             let .recoveryRequired(handoff, binding, _, _),
             let .closedBeforeAttempt(handoff, binding),
             let .terminalNotVerified(handoff, binding, _),
             let .outcomeUnknown(handoff, binding),
             let .verified(handoff, binding, _):
            return (handoff, binding)
        }
    }

    private func nativeDeleteDesktopCleanupHandoffMatches(
        _ handoff: CodexDesktopCleanupHandoff,
        context: NativeDeleteDesktopCleanupContext
    ) -> Bool {
        handoff.canonicalDeleteReportID == context.canonicalDeleteReportID
            && handoff.nativeSessionIDs == context.expectedNativeSessionIDs
    }

    private func nativeDeleteDesktopCleanupBindingMatchesProtectedOperation(
        handoff: CodexDesktopCleanupHandoff,
        binding: CodexDesktopCleanupBinding
    ) -> Bool {
        guard binding.canonicalDeleteReportID
                == handoff.canonicalDeleteReportID,
              binding.handoffDigest == handoff.handoffDigest,
              binding.items.map(\.nativeSessionID)
                == handoff.nativeSessionIDs,
              let protectedOperation = ghostRepairBulkProtectedOperation,
              binding.bulkIdentity.requestID
                == protectedOperation.savedPreviewRequestID,
              binding.bulkIdentity.operationID
                == protectedOperation.operationID else {
            return false
        }
        let receipt: CodexGhostRepairBulkConfirmationReceipt
        let review: CodexGhostRepairBulkFinalReview
        let itemsMatch = binding.items.map {
            GhostRepairBulkProtectedItem(
                threadID: $0.nativeSessionID,
                category: $0.category
            )
        } == protectedOperation.expectedItems
        switch protectedOperation.phase {
        case let .confirmed(valueReceipt),
             let .preparingFinalReview(valueReceipt, _),
             let .completed(valueReceipt, _),
             let .completedUnresolved(valueReceipt, _),
             let .recoveryRequired(valueReceipt, _):
            receipt = valueReceipt
            let receiptMatches = binding.confirmationReceiptID
                == receipt.receiptID
                && binding.confirmationReceiptDigest == receipt.receiptDigest
            return receiptMatches && itemsMatch
        case let .reviewReady(valueReceipt, valueReview),
             let .executing(valueReceipt, valueReview, _):
            receipt = valueReceipt
            review = valueReview
        default:
            return false
        }
        let receiptMatches = binding.confirmationReceiptID == receipt.receiptID
            && binding.confirmationReceiptDigest == receipt.receiptDigest
        let planMatches = binding.planDigest == review.reviewDigest
        return receiptMatches && planMatches && itemsMatch
    }

    var isGhostRepairBulkOperationInFlight: Bool {
        guard let phase = ghostRepairBulkProtectedOperation?.phase else {
            return false
        }
        switch phase {
        case .confirming, .preparingFinalReview, .executing,
             .closingPreparedClosure:
            return true
        case .confirmationOutcomeUnknown, .confirmed, .reviewReady,
             .completed, .completedUnresolved, .recoveryRequired,
             .preparedClosureReviewReady,
             .preparedClosureOutcomeUnknown,
             .preparedClosureRecoveryRequired, .closedBeforeAttempt:
            return false
        }
    }

    var ghostRepairBulkWorkflowMutationBlockedReason: String? {
        if isNativeDeleteDesktopCleanupRequestInFlight
            || nativeDeleteDesktopCleanupStatusRequestID != nil {
            return "Wait for the current Desktop cleanup linkage request to finish before changing the Bulk Ghost Delete workflow."
        }
        if ghostRepairBulkPreviousOperationsRequestID != nil
            || ghostRepairBulkRecoveryReadbackRequestID != nil
            || ghostRepairBulkConfirmationReceiptRecoveryRequestID != nil
            || ghostRepairBulkFreshRecoveryRequestID != nil
            || ghostRepairBulkPreparedClosureRequestID != nil {
            return "Wait for the previous-operation readback to finish before changing the current Bulk Ghost Delete workflow."
        }
        guard let phase = ghostRepairBulkProtectedOperation?.phase else {
            return nil
        }
        switch phase {
        case .confirming:
            return "Whole-batch confirmation is running. Keep this exact operation open until its receipt is known."
        case .confirmationOutcomeUnknown:
            return "The confirmation outcome is unresolved. Keep this operation reference; do not retry or replace it."
        case .confirmed, .preparingFinalReview, .reviewReady:
            return "A confirmed whole-batch operation owns this frozen selection. Finish it or explicitly start a new preparation first."
        case .executing:
            return "The one-shot bulk operation is running. Its frozen identity cannot be changed."
        case .completed:
            return "This operation has a terminal Report. Explicitly start a new preparation before changing its frozen inputs."
        case .completedUnresolved:
            return "The terminal Report contains an unknown outcome. Keep this operation for exact read-only recovery; do not retry or replace it."
        case .recoveryRequired:
            return "This operation requires exact read-only recovery. Do not replace its identity or retry it."
        case .preparedClosureReviewReady:
            return "A frozen manager-only closure review owns this exact unstarted plan. Confirm or cancel that review first."
        case .closingPreparedClosure:
            return "The manager-only prepared-plan closure is being recorded. Keep this exact operation open."
        case .preparedClosureOutcomeUnknown:
            return "The prepared-plan closure outcome is unknown. Keep this exact operation reference and use durable readback; do not execute or replace it."
        case .preparedClosureRecoveryRequired:
            return "This prepared plan has changed or requires exact recovery. Do not execute, close again, or replace its identity."
        case .closedBeforeAttempt:
            return "This unstarted plan is durably closed. Explicitly start a new preparation before changing its frozen inputs."
        }
    }

    var ghostRepairBulkDismissBlockedReason: String? {
        if ghostRepairCleanupState.isBusy {
            return "Wait for Ghost cleanup to finish its current step."
        }
        if ghostRepairBulkPreparedClosureRequestID != nil {
            return "Wait for the current prepared-plan closure step to finish before closing this sheet."
        }
        guard let phase = ghostRepairBulkProtectedOperation?.phase else {
            return nil
        }
        switch phase {
        case .confirming, .preparingFinalReview, .executing,
             .closingPreparedClosure:
            return "Wait for the current Bulk Ghost Delete step to finish before closing this sheet."
        case .confirmationOutcomeUnknown, .confirmed, .reviewReady,
             .completed, .completedUnresolved, .recoveryRequired,
             .preparedClosureReviewReady,
             .preparedClosureOutcomeUnknown,
             .preparedClosureRecoveryRequired, .closedBeforeAttempt:
            return nil
        }
    }

    var ghostRepairBulkExecutionBlockedReason: String? {
        guard isGhostRepairBulkWorkflowEnabled else {
            return "Enable Bulk Ghost Delete in Settings first."
        }
        if let reason = nativeDeleteDesktopCleanupExecutionBlockedReason {
            return reason
        }
        guard ghostRepairBulkRepairCoordinator.capabilities.executionAvailable
        else {
            return "Bulk one-shot execution is not available in this build."
        }
        guard let phase = ghostRepairBulkProtectedOperation?.phase else {
            return "Prepare the exact final review first."
        }
        switch phase {
        case .reviewReady:
            return nil
        case .executing:
            return "The one-shot bulk operation is already running."
        case .recoveryRequired:
            return "This operation requires exact read-only recovery. Do not retry it."
        case .completed:
            return "This operation already has a terminal Report."
        case .completedUnresolved:
            return "The terminal Report requires exact read-only recovery. Do not retry it."
        case .confirmationOutcomeUnknown:
            return "The confirmation outcome is unresolved. Do not retry it."
        case .confirming, .confirmed, .preparingFinalReview:
            return "Prepare the exact final review first."
        case .preparedClosureReviewReady, .closingPreparedClosure,
             .preparedClosureOutcomeUnknown,
             .preparedClosureRecoveryRequired:
            return "This exact prepared plan is in the manager-only closure workflow and cannot be executed."
        case .closedBeforeAttempt:
            return "This unstarted plan was closed without a repair attempt."
        }
    }

    var canStartNewGhostRepairBulkPreparation: Bool {
        guard !isGhostRepairBulkPreparationInFlight else { return false }
        guard nativeDeleteDesktopCleanupAllowsStartingNew else { return false }
        guard ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil,
              ghostRepairBulkPreparedClosureRequestID == nil else {
            return false
        }
        guard let phase = ghostRepairBulkProtectedOperation?.phase else {
            return true
        }
        switch phase {
        case .confirmed, .completed, .closedBeforeAttempt:
            return true
        case .confirming, .confirmationOutcomeUnknown,
             .preparingFinalReview, .reviewReady, .executing,
             .completedUnresolved, .recoveryRequired,
             .preparedClosureReviewReady, .closingPreparedClosure,
             .preparedClosureOutcomeUnknown,
             .preparedClosureRecoveryRequired:
            return false
        }
    }

    var ghostRepairBulkDisableBlockedReason: String? {
        if ghostRepairCleanupState.isBusy {
            return "Wait for Ghost cleanup to finish its current step."
        }
        if let reference = ghostRepairSnapshotRecoveryReference {
            return "Complete exact Snapshot recovery for \(reference) before disabling Bulk Ghost Delete."
        }
        if ghostRepairBulkPreviousOperationsRequestID != nil
            || ghostRepairBulkRecoveryReadbackRequestID != nil
            || ghostRepairBulkConfirmationReceiptRecoveryRequestID != nil
            || ghostRepairBulkFreshRecoveryRequestID != nil
            || ghostRepairBulkPreparedClosureRequestID != nil {
            return "Wait for the current Bulk Ghost Delete recovery request to finish before disabling it."
        }
        if !nativeDeleteDesktopCleanupAllowsStartingNew {
            return "Finish, resolve, or explicitly cancel the current canonical Delete cleanup handoff before disabling Bulk Ghost Delete."
        }
        guard let phase = ghostRepairBulkProtectedOperation?.phase else {
            return nil
        }
        switch phase {
        case .confirming, .preparingFinalReview, .executing,
             .closingPreparedClosure:
            return ghostRepairBulkDismissBlockedReason
        case .confirmationOutcomeUnknown:
            return "The whole-batch confirmation outcome is unresolved. Keep this operation available and do not retry it."
        case .completedUnresolved:
            return "The terminal Report contains an unknown outcome and requires exact read-only recovery."
        case .recoveryRequired:
            return "This operation requires exact read-only recovery before Bulk Ghost Delete can be disabled."
        case .reviewReady, .preparedClosureReviewReady:
            return "Close this durable unstarted plan before disabling Bulk Ghost Delete."
        case .preparedClosureOutcomeUnknown:
            return "The prepared-plan closure outcome is unknown. Resolve it by exact durable readback before disabling Bulk Ghost Delete."
        case .preparedClosureRecoveryRequired:
            return "This prepared plan requires exact recovery before Bulk Ghost Delete can be disabled."
        case .confirmed, .completed, .closedBeforeAttempt:
            return nil
        }
    }

    var ghostRepairBulkStartNewPreparationBlockedReason: String? {
        if isGhostRepairBulkPreparationInFlight {
            return "Wait for the current preparation step to stop before starting a new preparation."
        }
        if ghostRepairBulkPreviousOperationsRequestID != nil
            || ghostRepairBulkRecoveryReadbackRequestID != nil
            || ghostRepairBulkConfirmationReceiptRecoveryRequestID != nil
            || ghostRepairBulkFreshRecoveryRequestID != nil
            || ghostRepairBulkPreparedClosureRequestID != nil {
            return "Wait for the current read-only recovery request to finish before starting a new preparation."
        }
        guard !canStartNewGhostRepairBulkPreparation else { return nil }
        if !nativeDeleteDesktopCleanupAllowsStartingNew {
            return "The canonical Delete cleanup handoff is still pending or unresolved. Resolve it without creating a replacement operation."
        }
        return ghostRepairBulkWorkflowMutationBlockedReason
    }

    private var isGhostRepairBulkPreparationInFlight: Bool {
        let reviewIsLoading: Bool
        if case .loading = ghostRepairReadOnlyReviewState {
            reviewIsLoading = true
        } else {
            reviewIsLoading = false
        }
        return ghostRepairCleanupState.isBusy
            || ghostRepairInitialWitnessDiscoveryRequestID != nil
            || reviewIsLoading
            || ghostRepairSnapshotAdmissionRequestID != nil
            || ghostRepairSnapshotActionRequestID != nil
            || ghostRepairBulkInventoryRequestID != nil
            || ghostRepairBulkPreviewRequestID != nil
            || ghostRepairBulkPreviewReadbackRequestID != nil
            || ghostRepairBulkConfirmationChallengeRequestID != nil
    }

    private var nativeDeleteDesktopCleanupAllowsStartingNew: Bool {
        switch nativeDeleteDesktopCleanupState {
        case .idle:
            return true
        case let .status(_, status):
            switch status {
            case .verified, .closedBeforeAttempt, .terminalNotVerified:
                return true
            case .pending, .prepared, .recoveryRequired, .outcomeUnknown:
                return false
            }
        case .queued, .reviewing, .pending, .inventoryReady,
             .inventoryBlocked, .binding, .bindingRecoveryRequired,
             .unavailable:
            return false
        }
    }

    /// Presentation only: never rewrite the frozen scan, selection or receipt.
    /// An unrelated recovered report must not hide rows in the current scan.
    var ghostRepairBulkCompletedScanReport: CodexGhostRepairBulkRepairReport? {
        guard let inventory = ghostRepairBulkInventory,
              let preview = ghostRepairBulkPreview,
              preview.inventoryDigest == inventory.inventoryDigest,
              case let .completed(report) = ghostRepairBulkRepairState,
              report.operationID == ghostRepairBulkConfirmationReceipt?.operationID,
              Set(report.itemReports.map(\.threadID)) == Set(preview.selectedThreadIDs) else { return nil }
        return report
    }

    var ghostRepairBulkClearedThreadIDs: Set<String> {
        guard let report = ghostRepairBulkCompletedScanReport,
              report.outcome == .success else { return [] }
        return Set(report.itemReports.filter {
            $0.outcome == .success || $0.outcome == .alreadyAbsent
        }.map(\.threadID))
    }

    var ghostRepairBulkRemainingItems: [CodexGhostRepairBulkInventoryItem] {
        let cleared = ghostRepairBulkClearedThreadIDs
        return (ghostRepairBulkInventory?.items ?? []).filter { !cleared.contains($0.threadID) }
    }

    var ghostRepairBulkDisplayedSelection: Set<String> {
        ghostRepairBulkSelection.subtracting(ghostRepairBulkClearedThreadIDs)
    }

    func ghostRepairBulkDisplayTitle(for threadID: String) -> String? {
        let title = ghostRepairBulkInventory?.displayTitle(for: threadID)
            ?? sessionRows.first(where: { $0.system == .codex && $0.nativeID == threadID })?.title
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(512))
    }

    func ghostRepairBulkFilterCount(_ filter: CodexGhostRepairInventoryFilter) -> Int {
        (ghostRepairBulkInventory?.threadIDs(matching: filter) ?? [])
            .subtracting(ghostRepairBulkClearedThreadIDs).count
    }

    var ghostRepairBulkVisibleItems: [CodexGhostRepairBulkInventoryItem] {
        let matchingIDs = ghostRepairBulkInventory?.threadIDs(matching: ghostRepairBulkFilter) ?? []
        let displayedSelection = ghostRepairBulkDisplayedSelection
        let completedScan = ghostRepairBulkCompletedScanReport != nil
        let needle = ghostRepairBulkSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ghostRepairBulkRemainingItems.filter { item in
            let matchesSelection = !isShowingSelectedGhostRepairBulkItemsOnly
                || (completedScan && displayedSelection.isEmpty)
                || displayedSelection.contains(item.threadID)
            let matchesSearch = needle.isEmpty
                || ghostRepairBulkDisplayTitle(for: item.threadID)?
                    .localizedCaseInsensitiveContains(needle) == true
                || item.threadID.localizedCaseInsensitiveContains(needle)
                || item.disposition.rawValue
                    .localizedCaseInsensitiveContains(needle)
                || item.category.map { String(describing: $0) }
                    .map { $0.localizedCaseInsensitiveContains(needle) }
                    == true
                || item.blockers.contains {
                    $0.rawValue.localizedCaseInsensitiveContains(needle)
                }
            return matchesSelection && matchesSearch
                && matchingIDs.contains(item.threadID)
        }
    }

    var ghostRepairBulkInventoryBlockedReason: String? {
        guard isGhostRepairBulkWorkflowEnabled else {
            return "Enable Bulk Ghost Delete in Settings first."
        }
        guard ghostRepairBulkInventoryCapabilities.observationAvailable else {
            return "Bulk Ghost Inventory is not available in this build."
        }
        if case .observing = ghostRepairBulkInventoryState {
            return "A Bulk Ghost Inventory observation is already running."
        }
        if let reason = ghostRepairBulkWorkflowMutationBlockedReason {
            return reason
        }
        guard Self.canonicalSnapshotReference(
            ghostRepairBulkSnapshotReferenceDraft
        ) != nil else {
            return "Paste one exact published snapshot UUID."
        }
        return nil
    }

    var ghostRepairBulkPreparationBlockedReason: String? {
        guard isGhostRepairBulkWorkflowEnabled else {
            return "Enable Bulk Ghost Delete in Settings first."
        }
        guard ghostRepairBulkInventoryCapabilities.observationAvailable else {
            return "This build does not contain the complete automatic preparation flow."
        }
        if !ghostRepairBulkInventoryCapabilities
            .canonicalSourceQueryAvailable
        {
            guard ghostRepairSnapshotAdmissionInspectorCapabilities
                    .inspectionAvailable,
                  ghostRepairSnapshotActionCapabilities
                    .acquisitionAvailable else {
                return "This build does not contain the complete automatic preparation flow."
            }
        }
        guard ghostRepairSnapshotRecoveryReference == nil else {
            return "Complete exact Snapshot recovery before preparing another inventory."
        }
        if let reason = ghostRepairBulkWorkflowMutationBlockedReason {
            return reason
        }
        if case .preparing = ghostRepairBulkPreparationState {
            return "Ghost inventory preparation is already running."
        }
        if !ghostRepairBulkInventoryCapabilities
            .canonicalSourceQueryAvailable,
           automaticGhostRepairSnapshotWitnessManagerKeys.isEmpty,
           !ghostRepairInitialWitnessDiscoveryCapabilitiesAreReadOnly {
            return "No manager Deleted Codex sessions are available, and initial Snapshot witness discovery is unavailable in this build."
        }
        return nil
    }

    @discardableResult
    func setGhostRepairBulkReconciliationEnabled(_ enabled: Bool) -> Bool {
        guard nativeDeleteAutomaticCleanupReportID == nil else {
            errorMessage = "Finish or resolve the current Delete cleanup before changing the separate Ghost Delete preference."
            return false
        }
        if !enabled, let reason = ghostRepairBulkDisableBlockedReason {
            errorMessage = reason
            return false
        }
        if enabled {
            guard ghostRepairBulkInventoryCapabilities.observationAvailable else {
                errorMessage =
                    "This build does not contain the complete automatic preparation flow."
                return false
            }
            if !ghostRepairBulkInventoryCapabilities
                .canonicalSourceQueryAvailable
            {
                guard ghostRepairSnapshotAdmissionInspectorCapabilities
                        .inspectionAvailable,
                      ghostRepairSnapshotActionCapabilities
                        .acquisitionAvailable else {
                    errorMessage =
                        "This build does not contain the complete automatic preparation flow."
                    return false
                }
            }
        }
        guard isGhostRepairBulkReconciliationEnabled != enabled else {
            return true
        }
        ghostRepairInitialWitnessDiscoveryRequestID = nil
        ghostRepairReviewRequestID = nil
        ghostRepairReadOnlyReviewState = .idle
        ghostRepairSnapshotActionRequestID = nil
        ghostRepairSnapshotExecutionState = nil
        ghostRepairSnapshotAdmissionRequestID = nil
        ghostRepairSnapshotAdmissionState = .idle
        isGhostRepairBulkReconciliationEnabled = enabled
        return true
    }

    func presentGhostRepairBulkInventory() {
        guard isGhostRepairBulkWorkflowEnabled else {
            errorMessage = ghostRepairBulkInventoryBlockedReason
            return
        }
        isGhostRepairBulkInventoryPresented = true
    }

    @discardableResult
    func setGhostRepairBulkInventoryPresented(_ presented: Bool) -> Bool {
        if presented {
            presentGhostRepairBulkInventory()
            return isGhostRepairBulkInventoryPresented
        }
        guard ghostRepairBulkDismissBlockedReason == nil else {
            errorMessage = ghostRepairBulkDismissBlockedReason
            return false
        }
        isGhostRepairBulkInventoryPresented = false
        return true
    }

    @discardableResult
    func startNewGhostRepairBulkPreparation() -> Bool {
        guard canStartNewGhostRepairBulkPreparation else {
            errorMessage = ghostRepairBulkStartNewPreparationBlockedReason
            return false
        }
        ghostRepairBulkProtectedOperation = nil
        nativeDeleteDesktopCleanupState = .idle
        nativeDeleteAutomaticCleanupReportID = nil
        nativeDeleteDesktopAbsenceVerifiedReportID = nil
        nativeDeleteDesktopCleanupStatusRequestID = nil
        ghostRepairBulkSavedPreviewRequestIDDraft = ""
        resetGhostRepairBulkWorkflowState(
            enabled: isGhostRepairBulkReconciliationEnabled
        )
        return true
    }

    private func resetGhostRepairBulkWorkflowState(enabled: Bool) {
        if ghostRepairBulkProtectedOperation != nil {
            if !enabled {
                isGhostRepairBulkInventoryPresented = false
            }
            return
        }
        ghostRepairReviewRequestID = nil
        ghostRepairReadOnlyReviewState = .idle
        ghostRepairInitialWitnessDiscoveryRequestID = nil
        ghostRepairBulkInventoryRequestID = nil
        ghostRepairBulkPreviewRequestID = nil
        ghostRepairBulkPreviewReadbackRequestID = nil
        ghostRepairBulkConfirmationChallengeRequestID = nil
        ghostRepairBulkConfirmationReceiptRequestID = nil
        ghostRepairBulkRepairRequestID = nil
        ghostRepairBulkConfirmationReceiptRecoveryRequestID = nil
        ghostRepairBulkFreshRecoveryRequestID = nil
        ghostRepairBulkPreparedClosureRequestID = nil
        ghostRepairBulkSelection.removeAll()
        isShowingSelectedGhostRepairBulkItemsOnly = false
        ghostRepairBulkPreviewState = .idle
        ghostRepairCleanupState = .idle
        ghostRepairBulkPreviewReadbackState = .idle
        ghostRepairBulkConfirmationChallengeState = .idle
        ghostRepairBulkConfirmationReceiptState = .idle
        ghostRepairBulkConfirmationReceiptRecoveryState = .idle
        ghostRepairBulkFreshRecoveryState = .idle
        ghostRepairBulkPreparedClosureState = .idle
        ghostRepairBulkRepairState = .idle
        ghostRepairBulkConfirmationPhraseDraft = ""
        ghostRepairBulkInventoryState = enabled ? .idle : .disabled
        ghostRepairBulkPreparationState = .idle
        if !enabled {
            isGhostRepairBulkInventoryPresented = false
        }
    }

    private func invalidateGhostRepairBulkPreparedEvidence() {
        guard ghostRepairBulkProtectedOperation == nil else { return }
        ghostRepairBulkPreviewRequestID = nil
        ghostRepairBulkPreviewReadbackRequestID = nil
        ghostRepairBulkConfirmationChallengeRequestID = nil
        ghostRepairBulkConfirmationReceiptRequestID = nil
        ghostRepairBulkPreviewState = .idle
        ghostRepairBulkPreviewReadbackState = .idle
        ghostRepairBulkConfirmationChallengeState = .idle
        ghostRepairBulkConfirmationReceiptState = .idle
        ghostRepairBulkRepairRequestID = nil
        ghostRepairBulkRepairState = .idle
        ghostRepairBulkConfirmationPhraseDraft = ""
    }

    /// Shipping preparation scans current local evidence directly and requires
    /// no witness selection, published Snapshot, UUID copy/paste, or sheet
    /// handoff. The legacy injected coordinator path remains only so existing
    /// Snapshot journals and deterministic compatibility tests can be read.
    func prepareGhostRepairBulkInventory() async {
        guard ghostRepairBulkPreparationBlockedReason == nil else {
            ghostRepairBulkPreparationState = .blocked(
                message: ghostRepairBulkPreparationBlockedReason
                    ?? "Ghost inventory preparation is unavailable."
            )
            return
        }
        switch nativeDeleteDesktopCleanupState {
        case let .queued(context):
            guard let handoff = await reviewNativeDeleteDesktopCleanup(
                context: context
            ) else { return }
            nativeDeleteDesktopCleanupState = .pending(context, handoff)
            if await ghostRepairBulkInventoryCoordinator.verifyNoDesktopResidue(handoff: handoff) {
                guard nativeDeleteDesktopCleanupState == .pending(context, handoff) else { return }
                nativeDeleteDesktopAbsenceVerifiedReportID = context.canonicalDeleteReportID
                return
            }
            guard nativeDeleteDesktopCleanupState == .pending(context, handoff) else { return }
            await prepareGhostRepairBulkInventory(
                cleanupContext: context,
                handoff: handoff
            )
            return
        case let .pending(context, handoff):
            await prepareGhostRepairBulkInventory(
                cleanupContext: context,
                handoff: handoff
            )
            return
        case .idle:
            break
        case .reviewing, .inventoryReady, .inventoryBlocked, .binding,
             .bindingRecoveryRequired, .status, .unavailable:
            return
        }
        await prepareGhostRepairBulkInventory(
            cleanupContext: nil,
            handoff: nil
        )
    }

    private func reviewNativeDeleteDesktopCleanup(
        context: NativeDeleteDesktopCleanupContext
    ) async -> CodexDesktopCleanupHandoff? {
        let requestID = UUID()
        nativeDeleteDesktopCleanupState = .reviewing(
            requestID: requestID,
            context
        )
        let currentStatus = await nativeDeleteDesktopCleanupCoordinator
            .readStatus(reportID: context.canonicalDeleteReportID)
        guard nativeDeleteDesktopCleanupState == .reviewing(
            requestID: requestID,
            context
        ) else { return nil }
        switch currentStatus {
        case let .status(status):
            let evidence = nativeDeleteDesktopCleanupStatusEvidence(status)
            guard nativeDeleteDesktopCleanupHandoffMatches(
                evidence.handoff,
                context: context
            ) else {
                nativeDeleteDesktopCleanupState = .unavailable(
                    context,
                    message: "Durable Desktop cleanup evidence did not match the exact successful native Delete items."
                )
                return nil
            }
            guard evidence.binding == nil else {
                nativeDeleteDesktopCleanupState = .status(context, status)
                return nil
            }
            return evidence.handoff
        case .notFound:
            break
        case let .unavailable(message):
            nativeDeleteDesktopCleanupState = .unavailable(
                context,
                message: message
            )
            return nil
        }
        let outcome = await nativeDeleteDesktopCleanupCoordinator
            .reviewCanonicalDelete(
                reportID: context.canonicalDeleteReportID,
                expectedNativeSessionIDs: context.expectedNativeSessionIDs
            )
        guard nativeDeleteDesktopCleanupState == .reviewing(
            requestID: requestID,
            context
        ) else { return nil }
        switch outcome {
        case let .ready(handoff):
            guard nativeDeleteDesktopCleanupHandoffMatches(
                handoff,
                context: context
            ) else {
                nativeDeleteDesktopCleanupState = .unavailable(
                    context,
                    message: "The reviewed Desktop cleanup handoff changed the exact native Delete scope."
                )
                return nil
            }
            return handoff
        case .notFound:
            nativeDeleteDesktopCleanupState = .unavailable(
                context,
                message: "The exact canonical Delete report was not found."
            )
        case let .rejected(message), let .unavailable(message):
            nativeDeleteDesktopCleanupState = .unavailable(
                context,
                message: message
            )
        }
        return nil
    }

    private func prepareGhostRepairBulkInventory(
        cleanupContext: NativeDeleteDesktopCleanupContext?,
        handoff: CodexDesktopCleanupHandoff?
    ) async {
        if ghostRepairBulkInventoryCapabilities
            .canonicalSourceQueryAvailable
        {
            await prepareGhostRepairBulkInventoryFromCurrentEvidence(
                cleanupContext: cleanupContext,
                handoff: handoff
            )
            return
        }

        let witnessManagerKeys = automaticGhostRepairSnapshotWitnessManagerKeys
        let witness: GhostRepairAutomaticSnapshotWitness
        if witnessManagerKeys.isEmpty {
            guard let evidence = await discoverInitialGhostRepairSnapshotWitnesses()
            else { return }
            witness = .initialDiscovery(evidence)
        } else {
            guard let managerWitness = ghostRepairManagerSnapshotWitness(
                managerKeys: witnessManagerKeys
            ) else {
                ghostRepairBulkPreparationState = .blocked(
                    message: "Current manager Deleted Snapshot witnesses changed before preparation."
                )
                return
            }
            witness = managerWitness
        }
        await prepareGhostRepairBulkInventory(
            witness: witness,
            cleanupContext: cleanupContext,
            handoff: handoff
        )
    }

    private func prepareGhostRepairBulkInventoryFromCurrentEvidence(
        cleanupContext: NativeDeleteDesktopCleanupContext?,
        handoff: CodexDesktopCleanupHandoff?
    ) async {
        let scanReference = UUID().uuidString.lowercased()
        ghostRepairBulkSnapshotReferenceDraft = scanReference
        ghostRepairBulkPreparationState = .preparing(.scanningInventory)
        await observeGhostRepairBulkInventory()
        guard case let .ready(inventory) = ghostRepairBulkInventoryState,
              inventory.snapshotReference == scanReference else {
            ghostRepairBulkPreparationState = .blocked(
                message: "Current local state and exact Codex reads did not form one complete, consistent Ghost inventory."
            )
            return
        }
        ghostRepairBulkPreparationState = .ready(
            snapshotReference: scanReference
        )
        if let cleanupContext, let handoff {
            applyNativeDeleteDesktopCleanupInventory(
                context: cleanupContext,
                handoff: handoff,
                inventory: inventory
            )
        }
    }

    private func discoverInitialGhostRepairSnapshotWitnesses() async
        -> CodexGhostRepairInitialWitnessEvidence?
    {
        guard ghostRepairInitialWitnessDiscoveryRequestID == nil,
              ghostRepairInitialWitnessDiscoveryCapabilitiesAreReadOnly else {
            ghostRepairBulkPreparationState = .blocked(
                message: "Initial Snapshot witness discovery is unavailable. No Snapshot or inventory was created."
            )
            return nil
        }
        let requestID = UUID()
        ghostRepairInitialWitnessDiscoveryRequestID = requestID
        ghostRepairBulkPreparationState = .preparing(.discoveringWitnesses)
        let outcome = await ghostRepairInitialWitnessDiscovery.discover()
        guard ghostRepairInitialWitnessDiscoveryRequestID == requestID,
              isGhostRepairBulkWorkflowEnabled else { return nil }
        ghostRepairInitialWitnessDiscoveryRequestID = nil

        switch outcome {
        case let .discovered(evidence):
            guard initialGhostRepairSnapshotWitnessEvidenceIsValid(evidence),
                  initialGhostRepairSnapshotWitnessHasNoPositiveManagerState(
                    evidence
                  ) else {
                ghostRepairBulkPreparationState = .blocked(
                    message: "Initial Snapshot witness evidence was invalid or stale. No Snapshot or inventory was created."
                )
                return nil
            }
            return evidence
        case .empty:
            ghostRepairBulkPreparationState = .blocked(
                message: "Initial discovery found no eligible Snapshot witness. No Snapshot or inventory was created."
            )
        case let .unavailable(message):
            ghostRepairBulkPreparationState = .blocked(
                message: "\(message) No Snapshot or inventory was created."
            )
        }
        return nil
    }

    private func prepareGhostRepairBulkInventory(
        witness: GhostRepairAutomaticSnapshotWitness,
        cleanupContext: NativeDeleteDesktopCleanupContext?,
        handoff: CodexDesktopCleanupHandoff?
    ) async {
        let witnessThreadIDs = witness.threadIDs
        guard ghostRepairAutomaticSnapshotWitnessIsCurrent(witness) else {
            ghostRepairBulkPreparationState = .blocked(
                message: "Initial Snapshot witness evidence changed before Safety Review. No Snapshot or inventory was created."
            )
            return
        }

        ghostRepairBulkPreparationState = .preparing(.reviewing)
        await requestGhostRepairReadOnlyReview(witness: witness)
        guard case let .ready(review) = ghostRepairReadOnlyReviewState,
              ghostRepairReview(review, matches: witness),
              ghostRepairAutomaticSnapshotWitnessIsCurrent(witness) else {
            ghostRepairBulkPreparationState = .blocked(
                message: "Current Snapshot evidence did not match the frozen initial witness IDs and provenance. No Snapshot or inventory was created."
            )
            return
        }

        do {
            if let snapshotReference = try await
                ghostRepairBulkInventoryCoordinator
                    .resumablePublishedSnapshotReference(
                        targetThreadIDs: witnessThreadIDs
                    )
            {
                guard ghostRepairAutomaticSnapshotWitnessIsCurrent(witness)
                else {
                    ghostRepairBulkPreparationState = .blocked(
                        message: "Initial Snapshot witness state changed while resolving existing evidence. No inventory was scanned."
                    )
                    return
                }
                await finishGhostRepairBulkPreparation(
                    snapshotReference: snapshotReference,
                    cleanupContext: cleanupContext,
                    handoff: handoff
                )
                return
            }
        } catch {
            ghostRepairBulkPreparationState = .blocked(
                message: "Existing verified Snapshot evidence could not be resolved safely. No new Snapshot was created."
            )
            return
        }

        ghostRepairBulkPreparationState = .preparing(.publishingSnapshot)
        await requestGhostRepairSnapshotWithAutomaticAdmission(
            witness: witness
        )
        guard case let .succeeded(request, rawReference) =
                ghostRepairSnapshotExecutionState,
              request.targetThreadIDs == witnessThreadIDs,
              ghostRepairAutomaticSnapshotWitnessIsCurrent(witness),
              let snapshotReference = Self.canonicalSnapshotReference(
                rawReference
              ) else {
            ghostRepairBulkPreparationState = .blocked(
                message: "Verified Snapshot creation did not complete for the frozen initial witness evidence. No inventory was scanned."
            )
            return
        }

        await finishGhostRepairBulkPreparation(
            snapshotReference: snapshotReference,
            cleanupContext: cleanupContext,
            handoff: handoff
        )
    }

    private func finishGhostRepairBulkPreparation(
        snapshotReference: String,
        cleanupContext: NativeDeleteDesktopCleanupContext?,
        handoff: CodexDesktopCleanupHandoff?
    ) async {
        ghostRepairBulkSnapshotReferenceDraft = snapshotReference
        ghostRepairBulkPreparationState = .preparing(.scanningInventory)
        await observeGhostRepairBulkInventory()
        guard case let .ready(inventory) = ghostRepairBulkInventoryState,
              inventory.snapshotReference == snapshotReference else {
            ghostRepairBulkPreparationState = .blocked(
                message: "Verified Snapshot evidence is available, but complete ghost classification was unavailable."
            )
            return
        }
        ghostRepairBulkPreparationState = .ready(
            snapshotReference: snapshotReference
        )
        if let cleanupContext, let handoff {
            applyNativeDeleteDesktopCleanupInventory(
                context: cleanupContext,
                handoff: handoff,
                inventory: inventory
            )
        }
    }

    private func applyNativeDeleteDesktopCleanupInventory(
        context: NativeDeleteDesktopCleanupContext,
        handoff: CodexDesktopCleanupHandoff,
        inventory: CodexGhostRepairBulkInventory
    ) {
        guard nativeDeleteDesktopCleanupState == .pending(context, handoff),
              nativeDeleteDesktopCleanupHandoffMatches(
                handoff,
                context: context
              ) else { return }
        let inventoryByID = Dictionary(
            uniqueKeysWithValues: inventory.items.map { ($0.threadID, $0) }
        )
        let targets = handoff.nativeSessionIDs.map { id in
            guard let item = inventoryByID[id] else {
                return NativeDeleteDesktopCleanupTarget(
                    nativeSessionID: id,
                    state: .blocked,
                    category: nil,
                    message: "This requested ID is missing from the complete Bulk inventory."
                )
            }
            guard item.disposition == .eligible, let category = item.category
            else {
                return NativeDeleteDesktopCleanupTarget(
                    nativeSessionID: id,
                    state: .blocked,
                    category: item.category,
                    message: "This requested ID is \(item.disposition.rawValue), so the exact scope cannot proceed."
                )
            }
            return NativeDeleteDesktopCleanupTarget(
                nativeSessionID: id,
                state: .eligible,
                category: category,
                message: item.initiallyAbsent == true
                    ? "Already clear; retained in the exact batch for final absence verification."
                    : "Eligible in the exact canonical Delete cleanup scope."
            )
        }
        guard targets.allSatisfy({ $0.state == .eligible }) else {
            ghostRepairBulkSelection.removeAll()
            isShowingSelectedGhostRepairBulkItemsOnly = false
            nativeDeleteDesktopCleanupState = .inventoryBlocked(
                context,
                handoff,
                targets: targets,
                message: "Every requested native session ID must be verified already clear or an eligible classified ghost. Nothing was selected and no smaller Preview may be built."
            )
            return
        }
        ghostRepairBulkSelection = Set(handoff.nativeSessionIDs)
        nativeDeleteDesktopCleanupState = .inventoryReady(context, handoff)
    }

    private var automaticGhostRepairSnapshotWitnessManagerKeys: Set<String> {
        var observedThreadIDs = Set<String>()
        let witnesses = sessionRows
            .filter {
                $0.system == .codex && $0.displayState == .deleted
            }
            .sorted { lhs, rhs in
                if lhs.nativeID != rhs.nativeID {
                    return lhs.nativeID < rhs.nativeID
                }
                return lhs.id < rhs.id
            }
            .filter { observedThreadIDs.insert($0.nativeID).inserted }
            .prefix(10)
        return Set(witnesses.map(\.id))
    }

    private var ghostRepairInitialWitnessDiscoveryCapabilitiesAreReadOnly: Bool {
        let capabilities = ghostRepairInitialWitnessDiscovery.capabilities
        return capabilities.discoveryAvailable
            && capabilities.readsFixedRawDatabaseFiles
            && capabilities.officialInventoryAvailable
            && !capabilities.acceptsCallerPath
            && !capabilities.acceptsCallerThreadIDs
            && !capabilities.writesCodexDatabaseFiles
            && !capabilities.writesManagerFilesystem
            && !capabilities.publishesSnapshot
            && !capabilities.persistsPreview
            && !capabilities.confirmationAuthority
            && !capabilities.repairMutationAuthority
    }

    private func initialGhostRepairSnapshotWitnessEvidenceIsValid(
        _ evidence: CodexGhostRepairInitialWitnessEvidence
    ) -> Bool {
        let threadIDs = evidence.threadIDs
        guard (1...10).contains(threadIDs.count),
              threadIDs == threadIDs.sorted(),
              Set(threadIDs).count == threadIDs.count,
              threadIDs.allSatisfy({
                  UUID(uuidString: $0)?.uuidString.lowercased() == $0
              }),
              !evidence.runtimeVersion.isEmpty,
              !evidence.sourceLayoutIdentifier.isEmpty,
              evidence.sourceFingerprintHash.hasPrefix("sha256:"),
              evidence.sourceFingerprintHash.count == 71,
              !evidence.confirmedGhostEvidence,
              !evidence.snapshotAuthority,
              !evidence.repairMutationAuthority else {
            return false
        }
        return evidence.sourceFingerprintHash
            .dropFirst("sha256:".count)
            .allSatisfy {
                $0.isNumber || ("a"..."f").contains(String($0))
            }
    }

    private func initialGhostRepairSnapshotWitnessHasNoPositiveManagerState(
        _ evidence: CodexGhostRepairInitialWitnessEvidence
    ) -> Bool {
        let targetIDs = Set(evidence.threadIDs)
        return !sessionRows.contains {
            $0.system == .codex
                && targetIDs.contains($0.nativeID)
                && $0.displayState != .deleted
        }
    }

    private func initialGhostRepairSnapshotWitnessIsCurrent(
        _ witness: GhostRepairAutomaticSnapshotWitness
    ) -> Bool {
        guard case let .initialDiscovery(evidence) = witness else {
            return false
        }
        return initialGhostRepairSnapshotWitnessEvidenceIsValid(evidence)
            && initialGhostRepairSnapshotWitnessHasNoPositiveManagerState(
                evidence
            )
    }

    private func ghostRepairManagerSnapshotWitness(
        managerKeys: Set<String>
    ) -> GhostRepairAutomaticSnapshotWitness? {
        let rows = sessionRows.filter { managerKeys.contains($0.id) }
        let threadIDs = rows.map(\.nativeID).sorted()
        guard rows.count == managerKeys.count,
              (1...10).contains(rows.count),
              rows.allSatisfy({
                  $0.system == .codex && $0.displayState == .deleted
              }) else {
            return nil
        }
        return .managerTombstones(
            managerKeys: managerKeys,
            threadIDs: threadIDs
        )
    }

    private func ghostRepairAutomaticSnapshotWitnessIsCurrent(
        _ witness: GhostRepairAutomaticSnapshotWitness
    ) -> Bool {
        switch witness {
        case let .managerTombstones(managerKeys, threadIDs):
            return ghostRepairManagerSnapshotWitness(managerKeys: managerKeys)?
                .threadIDs == threadIDs
        case .initialDiscovery:
            return initialGhostRepairSnapshotWitnessIsCurrent(witness)
        }
    }

    private func ghostRepairReview(
        _ review: CodexGhostRepairReadOnlyReview,
        matches witness: GhostRepairAutomaticSnapshotWitness
    ) -> Bool {
        guard review.targetThreadIDs == witness.threadIDs else { return false }
        switch witness {
        case .managerTombstones:
            return true
        case let .initialDiscovery(evidence):
            return review.runtimeVersion == evidence.runtimeVersion
        }
    }

    func observeGhostRepairBulkInventory() async {
        guard ghostRepairBulkInventoryBlockedReason == nil,
              let snapshotReference = Self.canonicalSnapshotReference(
                ghostRepairBulkSnapshotReferenceDraft
              ) else {
            errorMessage = ghostRepairBulkInventoryBlockedReason
            return
        }

        let request = CodexGhostRepairBulkInventoryRequest(
            requestID: UUID(),
            snapshotReference: snapshotReference
        )
        ghostRepairBulkInventoryRequestID = request.requestID
        ghostRepairBulkInventoryState = .observing(
            requestID: request.requestID,
            snapshotReference: snapshotReference
        )

        guard isGhostRepairBulkWorkflowEnabled,
              ghostRepairBulkInventoryRequestID == request.requestID,
              ghostRepairBulkInventoryState == .observing(
                requestID: request.requestID,
                snapshotReference: snapshotReference
              ) else { return }

        let outcome: CodexGhostRepairBulkInventoryOutcome
        if case let .pending(_, handoff) = nativeDeleteDesktopCleanupState {
            outcome = await ghostRepairBulkInventoryCoordinator.observeCleanup(request: request, handoff: handoff)
        } else {
            outcome = await ghostRepairBulkInventoryCoordinator.observe(request: request)
        }
        guard isGhostRepairBulkWorkflowEnabled,
              ghostRepairBulkInventoryRequestID == request.requestID,
              outcome.requestID == request.requestID else { return }
        ghostRepairBulkInventoryRequestID = nil

        switch outcome {
        case let .inventory(_, inventory):
            guard inventory.snapshotReference == snapshotReference else {
                ghostRepairBulkInventoryState = .unavailable(
                    snapshotReference: snapshotReference,
                    stage: .composition
                )
                return
            }
            ghostRepairBulkSnapshotReferenceDraft = snapshotReference
            if ghostRepairBulkInventoryCapabilities
                .canonicalSourceQueryAvailable
            {
                ghostRepairBulkSelection = Set(inventory.eligibleThreadIDs)
            } else {
                ghostRepairBulkSelection.removeAll()
            }
            isShowingSelectedGhostRepairBulkItemsOnly = false
            invalidateGhostRepairBulkPreparedEvidence()
            ghostRepairBulkInventoryState = .ready(inventory)
        case let .unavailable(_, failure):
            ghostRepairBulkSelection.removeAll()
            isShowingSelectedGhostRepairBulkItemsOnly = false
            invalidateGhostRepairBulkPreparedEvidence()
            ghostRepairBulkInventoryState = .unavailable(
                snapshotReference: snapshotReference,
                stage: failure.stage
            )
        }
    }

    func isGhostRepairBulkItemSelected(_ threadID: String) -> Bool {
        ghostRepairBulkSelection.contains(threadID)
    }

    func setGhostRepairManualReviewEnabled(_ enabled: Bool) {
        guard ghostRepairCleanupState == .idle,
              ghostRepairBulkWorkflowMutationBlockedReason == nil,
              nativeDeleteDesktopCleanupSelectionBlockedReason == nil,
              let inventory = ghostRepairBulkInventory else { return }
        do {
            let reviewed = try inventory.reviewingKnownResidue(enabled)
            ghostRepairBulkSelection.removeAll()
            isShowingSelectedGhostRepairBulkItemsOnly = false
            invalidateGhostRepairBulkPreparedEvidence()
            ghostRepairBulkInventoryState = .ready(reviewed)
        } catch {
            errorMessage = "Manual review requires a fresh, verified scan."
        }
    }

    func setGhostRepairBulkItemSelected(
        _ threadID: String,
        isSelected: Bool
    ) {
        guard !ghostRepairCleanupState.isBusy else { return }
        guard nativeDeleteDesktopCleanupSelectionBlockedReason == nil else {
            errorMessage = nativeDeleteDesktopCleanupSelectionBlockedReason
            return
        }
        guard ghostRepairBulkWorkflowMutationBlockedReason == nil else {
            errorMessage = ghostRepairBulkWorkflowMutationBlockedReason
            return
        }
        guard let item = ghostRepairBulkInventory?.items.first(where: {
            $0.threadID == threadID
        }), item.selectable else { return }
        if isSelected {
            ghostRepairBulkSelection.insert(threadID)
        } else {
            ghostRepairBulkSelection.remove(threadID)
        }
        invalidateGhostRepairBulkPreparedEvidence()
        if ghostRepairBulkSelection.isEmpty {
            isShowingSelectedGhostRepairBulkItemsOnly = false
        }
    }

    func selectAllEligibleGhostRepairBulkItems() {
        guard !ghostRepairCleanupState.isBusy else { return }
        guard nativeDeleteDesktopCleanupSelectionBlockedReason == nil else {
            errorMessage = nativeDeleteDesktopCleanupSelectionBlockedReason
            return
        }
        guard ghostRepairBulkWorkflowMutationBlockedReason == nil else {
            errorMessage = ghostRepairBulkWorkflowMutationBlockedReason
            return
        }
        guard let inventory = ghostRepairBulkInventory else { return }
        ghostRepairBulkSelection = Set(inventory.eligibleThreadIDs)
        invalidateGhostRepairBulkPreparedEvidence()
    }

    func clearGhostRepairBulkSelection() {
        guard !ghostRepairCleanupState.isBusy else { return }
        guard nativeDeleteDesktopCleanupSelectionBlockedReason == nil else {
            errorMessage = nativeDeleteDesktopCleanupSelectionBlockedReason
            return
        }
        guard ghostRepairBulkWorkflowMutationBlockedReason == nil else {
            errorMessage = ghostRepairBulkWorkflowMutationBlockedReason
            return
        }
        ghostRepairBulkSelection.removeAll()
        isShowingSelectedGhostRepairBulkItemsOnly = false
        invalidateGhostRepairBulkPreparedEvidence()
    }

    /// Consent comes from the cleanup summary or the current official Delete's
    /// confirmed exact scope. Selection and scan must match before a receipt.
    func confirmGhostCleanup(
        selectedIDs: Set<String>,
        inventoryDigest: String
    ) async {
        guard ghostRepairCleanupState == .idle,
              isGhostRepairBulkWorkflowEnabled,
              ghostRepairBulkWorkflowMutationBlockedReason == nil,
              !selectedIDs.isEmpty,
              selectedIDs == ghostRepairBulkSelection,
              inventoryDigest == ghostRepairBulkInventory?.inventoryDigest else {
            return
        }
        ghostRepairCleanupState = .preparing
        await buildGhostRepairBulkPreview()
        guard isGhostRepairBulkWorkflowEnabled,
              ghostRepairCleanupState == .preparing,
              selectedIDs == ghostRepairBulkSelection,
              inventoryDigest == ghostRepairBulkInventory?.inventoryDigest,
              case let .saved(preview, savedReceipt) = ghostRepairBulkPreviewState,
              preview.inventoryDigest == inventoryDigest,
              case let .ready(challenge) = ghostRepairBulkConfirmationChallengeState,
              case let .observed(evidence) = ghostRepairBulkPreviewReadbackState,
              preview == evidence.preview,
              savedReceipt.requestID == evidence.requestID,
              Set(evidence.preview.selectedItems.map(\.threadID)) == selectedIDs,
              challenge.savedPreviewRequestID == evidence.requestID else {
            ghostRepairCleanupState = .stopped(ghostCleanupPreparationFailure)
            return
        }
        // The button confirmation owns this exact batch. Keep the existing
        // durable receipt contract internal; no phrase needs to be transcribed.
        ghostRepairBulkConfirmationPhraseDraft = challenge.confirmationPhrase
        await confirmGhostRepairBulkBatch()
        guard case .confirmed? = ghostRepairBulkProtectedOperation?.phase else {
            ghostRepairCleanupState = .stopped(ghostCleanupPreparationFailure)
            return
        }
        ghostRepairCleanupState = .awaitingShutdown
    }

    /// Shutdown acknowledgement, including the original quit-first Delete
    /// confirmation, continues the batch. The coordinator checks shutdown and backup before
    /// returning a review; only that same review may execute, once.
    func continueGhostCleanupAfterShutdown() async {
        guard ghostRepairCleanupState == .awaitingShutdown,
              let receipt = ghostRepairBulkConfirmationReceipt,
              ghostRepairBulkFinalReviewBlockedReason == nil else { return }
        ghostRepairCleanupState = .running
        await prepareGhostRepairBulkFinalReview()
        // A typed pre-runner shutdown stop retains the original receipt and
        // selection. Do not loop: another explicit user acknowledgement is required.
        if ghostRepairCleanupState == .awaitingShutdown { return }
        guard ghostRepairCleanupState == .running,
              case let .reviewReady(review) = ghostRepairBulkRepairState,
              review.confirmationReceiptID == receipt.receiptID,
              review.operationID == receipt.operationID,
              ghostRepairBulkExecutionBlockedReason == nil else {
            if case let .unavailable(message) = ghostRepairBulkRepairState {
                ghostRepairCleanupState = .stopped(message)
            } else {
                ghostRepairCleanupState = .stopped(
                    ghostRepairBulkExecutionBlockedReason
                        ?? "Cleanup checks did not complete. Nothing was deleted."
                )
            }
            return
        }
        await executeGhostRepairBulkOneShot()
        if case .completed = ghostRepairBulkRepairState {
            ghostRepairCleanupState = .finished
        } else {
            ghostRepairCleanupState = .stopped(
                "Cleanup stopped. Read the operation result before starting anything else."
            )
        }
    }

    private var ghostCleanupPreparationFailure: String {
        if case let .unavailable(message) = ghostRepairBulkConfirmationReceiptState {
            return message
        }
        if case let .unavailable(message) = ghostRepairBulkConfirmationChallengeState {
            return message
        }
        if case let .unavailable(message) = ghostRepairBulkPreviewReadbackState {
            return message
        }
        if case let .unavailable(message) = ghostRepairBulkPreviewState {
            return message
        }
        return "The selected cleanup could not be verified and saved. Nothing was deleted."
    }

    func buildGhostRepairBulkPreview() async {
        if case let .inventoryReady(_, handoff) =
            nativeDeleteDesktopCleanupState {
            guard ghostRepairBulkSelection.sorted()
                    == handoff.nativeSessionIDs else {
                ghostRepairBulkPreviewState = .unavailable(
                    message: "The canonical Delete cleanup selection changed. No Preview was built."
                )
                return
            }
        } else if case .idle = nativeDeleteDesktopCleanupState {
            // The existing general Bulk Ghost Delete path is unchanged.
        } else {
            ghostRepairBulkPreviewState = .unavailable(
                message: "The exact canonical Delete cleanup scope is not ready. No Preview was built."
            )
            return
        }
        guard ghostRepairBulkWorkflowMutationBlockedReason == nil else {
            errorMessage = ghostRepairBulkWorkflowMutationBlockedReason
            return
        }
        guard ghostRepairBulkPreviewRequestID == nil else { return }
        guard let inventory = ghostRepairBulkInventory,
              !ghostRepairBulkSelection.isEmpty else {
            ghostRepairBulkPreviewState = .unavailable(
                message: "Select at least one eligible item first."
            )
            return
        }
        let selectedIDs = ghostRepairBulkSelection.sorted()
        guard selectedIDs.count
                <= CodexGhostRepairBulkPreview.maximumSelectedItems else {
            ghostRepairBulkPreviewState = .unavailable(
                message: "This Preview supports at most \(CodexGhostRepairBulkPreview.maximumSelectedItems) selected items."
            )
            return
        }
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let preview: CodexGhostRepairBulkPreview
        do {
            preview = try CodexGhostRepairBulkPreviewFactory
                .buildAuthorityFree(
                    inventory: inventory,
                    selectedThreadIDs: selectedIDs,
                    generatedAtMilliseconds: now
                )
        } catch {
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Bulk Ghost Preview build failed",
                metadata: [
                    "error": error.localizedDescription,
                    "selected_count": String(selectedIDs.count),
                    "source_layout": inventory.sourceLayoutIdentifier,
                    "observed_count": String(
                        inventory.observedCatalogItemCount
                    ),
                    "eligible_count": String(inventory.eligibleItemCount),
                    "confirmed_blocked_count": String(
                        inventory.items.count { $0.disposition == .blocked }
                    ),
                    "unconfirmed_count": String(
                        inventory.items.count { $0.disposition == .unconfirmed }
                    ),
                    "not_ghost_count": String(inventory.notGhostItemCount),
                ]
            )
            ghostRepairBulkPreviewState = .unavailable(
                message: "The frozen Preview could not be built from the verified inventory. Nothing was saved, confirmed, or changed."
            )
            return
        }
        let requestID = UUID()
        ghostRepairBulkPreviewRequestID = requestID
        ghostRepairBulkPreviewState = .saving(
            requestID: requestID,
            preview: preview
        )
        do {
            let receipt = try await ghostRepairBulkPreviewPersister.persist(
                requestID: requestID,
                preview: preview,
                inventory: inventory
            )
            guard isGhostRepairBulkWorkflowEnabled,
                  ghostRepairBulkPreviewRequestID == requestID,
                  ghostRepairBulkSelection.sorted() == selectedIDs,
                  ghostRepairBulkInventory?.inventoryDigest
                    == inventory.inventoryDigest,
                  receipt.requestID == requestID,
                  receipt.previewID == preview.previewID,
                  receipt.frozenSourceDigest != nil,
                  receipt.durableReadbackMatched,
                  !receipt.confirmationAuthority,
                  !receipt.repairMutationAuthority else { return }
            ghostRepairBulkPreviewRequestID = nil
            ghostRepairBulkSavedPreviewRequestIDDraft =
                requestID.uuidString.lowercased()
            ghostRepairBulkPreviewState = .saved(
                preview: preview,
                receipt: receipt
            )
            // The same explicit Build Preview intent owns the manager-only
            // durable readback and challenge preparation. Neither step reads
            // live Codex data or creates repair authority.
            await readSavedGhostRepairBulkPreview()
        } catch {
            logDiagnostic(
                level: .error,
                category: .storage,
                message: "Bulk Ghost Preview persistence failed",
                metadata: [
                    "error": error.localizedDescription,
                    "request_id": requestID.uuidString.lowercased(),
                    "selected_count": String(selectedIDs.count),
                    "source_layout": inventory.sourceLayoutIdentifier,
                ]
            )
            ghostRepairBulkPreviewRequestID = nil
            ghostRepairBulkPreviewState = .unavailable(
                message: "The frozen Preview was built, but its manager-owned save and exact readback failed. No confirmation or repair authority was created."
            )
        }
    }

    func readSavedGhostRepairBulkPreview() async {
        guard ghostRepairBulkWorkflowMutationBlockedReason == nil else {
            errorMessage = ghostRepairBulkWorkflowMutationBlockedReason
            return
        }
        guard ghostRepairBulkPreviewReadbackRequestID == nil else { return }
        guard let canonical = Self.canonicalSnapshotReference(
            ghostRepairBulkSavedPreviewRequestIDDraft
        ), let requestID = UUID(uuidString: canonical) else {
            ghostRepairBulkPreviewReadbackState = .unavailable(
                message: "Paste one exact saved Preview Request ID."
            )
            return
        }
        ghostRepairBulkPreviewReadbackRequestID = requestID
        ghostRepairBulkPreviewReadbackState = .reading(requestID: requestID)
        let outcome = await ghostRepairBulkPreviewReadbackCoordinator.readback(
            requestID: requestID
        )
        guard ghostRepairBulkPreviewReadbackRequestID == requestID,
              outcome.requestID == requestID else { return }
        ghostRepairBulkPreviewReadbackRequestID = nil
        switch outcome {
        case let .observed(evidence):
            guard evidence.requestID == requestID,
                  evidence.durableReadbackMatched,
                  !evidence.confirmationAuthority,
                  !evidence.repairMutationAuthority else {
                ghostRepairBulkPreviewReadbackState = .unavailable(
                    message: "Saved bulk Preview readback did not match exactly."
                )
                return
            }
            ghostRepairBulkPreviewReadbackState = .observed(evidence)
            await prepareGhostRepairBulkConfirmationChallenge()
        case .notFound:
            ghostRepairBulkPreviewReadbackState = .unavailable(
                message: "No saved bulk Preview exists for that exact Request ID."
            )
        case let .unavailable(_, message):
            ghostRepairBulkPreviewReadbackState = .unavailable(message: message)
        }
    }

    func prepareGhostRepairBulkConfirmationChallenge() async {
        guard ghostRepairBulkWorkflowMutationBlockedReason == nil else {
            errorMessage = ghostRepairBulkWorkflowMutationBlockedReason
            return
        }
        guard ghostRepairBulkProtectedOperation == nil else { return }
        guard ghostRepairBulkConfirmationChallengeRequestID == nil else {
            return
        }
        guard isGhostRepairBulkWorkflowEnabled else {
            ghostRepairBulkConfirmationChallengeState = .unavailable(
                message: "Enable Bulk Ghost Delete in Settings first."
            )
            return
        }
        guard let canonical = Self.canonicalSnapshotReference(
            ghostRepairBulkSavedPreviewRequestIDDraft
        ), let requestID = UUID(uuidString: canonical) else {
            ghostRepairBulkConfirmationChallengeState = .unavailable(
                message: "Read one exact saved Preview before preparing confirmation."
            )
            return
        }
        guard case let .observed(evidence) =
                ghostRepairBulkPreviewReadbackState,
              evidence.requestID == requestID,
              evidence.durableReadbackMatched,
              !evidence.confirmationAuthority,
              !evidence.repairMutationAuthority else {
            ghostRepairBulkConfirmationChallengeState = .unavailable(
                message: "Press Read Saved Preview for this exact Request ID first."
            )
            return
        }
        ghostRepairBulkConfirmationChallengeRequestID = requestID
        ghostRepairBulkConfirmationChallengeState = .preparing(
            requestID: requestID
        )
        let outcome = await ghostRepairBulkConfirmationChallengeCoordinator
            .prepareChallenge(savedPreviewRequestID: requestID)
        guard ghostRepairBulkConfirmationChallengeRequestID == requestID,
              outcome.requestID == requestID else { return }
        ghostRepairBulkConfirmationChallengeRequestID = nil
        switch outcome {
        case let .ready(challenge):
            guard challenge.savedPreviewRequestID == requestID,
                  challenge.singleWholeBatchConfirmation,
                  !challenge.perItemConfirmation,
                  !challenge.confirmationAuthority,
                  !challenge.repairClaimCreated,
                  !challenge.repairMutationAuthority else {
                ghostRepairBulkConfirmationChallengeState = .unavailable(
                    message: "Whole-batch challenge exceeded its evidence-only boundary."
                )
                return
            }
            ghostRepairBulkConfirmationChallengeState = .ready(challenge)
            ghostRepairBulkConfirmationReceiptState = .idle
            ghostRepairBulkRepairRequestID = nil
            ghostRepairBulkRepairState = .idle
            ghostRepairBulkConfirmationPhraseDraft = ""
        case .notFound:
            ghostRepairBulkConfirmationChallengeState = .unavailable(
                message: "The exact saved Preview no longer exists."
            )
        case let .unavailable(_, message):
            ghostRepairBulkConfirmationChallengeState = .unavailable(
                message: message
            )
        }
    }

    func confirmGhostRepairBulkBatch() async {
        // A confirmation may already have been durably recorded while this
        // MainActor was suspended. Never replace that operation's identity or
        // issue a second confirmation request.
        guard ghostRepairBulkProtectedOperation == nil else { return }
        guard ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil else {
            errorMessage = ghostRepairBulkWorkflowMutationBlockedReason
            return
        }
        guard isGhostRepairBulkWorkflowEnabled else {
            ghostRepairBulkConfirmationReceiptState = .unavailable(
                message: "Enable Bulk Ghost Delete in Settings first."
            )
            return
        }
        guard case let .ready(challenge) =
                ghostRepairBulkConfirmationChallengeState else {
            ghostRepairBulkConfirmationReceiptState = .unavailable(
                message: "Prepare the exact whole-batch challenge first."
            )
            return
        }
        let exactPhrase = ghostRepairBulkConfirmationPhraseDraft
        guard !exactPhrase.isEmpty else {
            ghostRepairBulkConfirmationReceiptState = .unavailable(
                message: "Paste the exact whole-batch confirmation phrase."
            )
            return
        }
        let requestID = challenge.savedPreviewRequestID
        guard case let .observed(previewEvidence) =
                ghostRepairBulkPreviewReadbackState,
              previewEvidence.requestID == requestID,
              previewEvidence.durableReadbackMatched,
              previewEvidence.preview.selectedItems.count
                == challenge.selectedCount,
              previewEvidence.preview.ordinarySelectedCount
                == challenge.ordinaryCount,
              previewEvidence.preview.automationSelectedCount
                == challenge.automationCount else {
            ghostRepairBulkConfirmationReceiptState = .unavailable(
                message: "The exact saved Preview no longer matches this whole-batch challenge."
            )
            return
        }
        ghostRepairBulkProtectedOperation = .init(
            savedPreviewRequestID: requestID,
            operationID: challenge.operationID,
            expectedItems: previewEvidence.preview.selectedItems.map {
                .init(threadID: $0.threadID, category: $0.category)
            },
            phase: .confirming(challenge)
        )
        ghostRepairBulkConfirmationReceiptRequestID = requestID
        ghostRepairBulkConfirmationReceiptState = .confirming(
            requestID: requestID
        )
        let outcome = await ghostRepairBulkConfirmationReceiptCoordinator
            .confirm(
                savedPreviewRequestID: requestID,
                exactConfirmationPhrase: exactPhrase
            )
        guard ghostRepairBulkConfirmationReceiptRequestID == requestID,
              case let .confirming(currentChallenge)? =
                ghostRepairBulkProtectedOperation?.phase,
              currentChallenge == challenge else { return }
        ghostRepairBulkConfirmationReceiptRequestID = nil
        guard outcome.requestID == requestID else {
            retainUnknownGhostRepairBulkConfirmation(
                challenge: challenge,
                message: "The confirmation result did not match the exact operation. Do not retry it."
            )
            return
        }
        switch outcome {
        case let .confirmed(receipt), let .alreadyConfirmed(receipt):
            guard receipt.savedPreviewRequestID == requestID,
                  receipt.operationID == challenge.operationID,
                  receipt.challengeDigest == challenge.challengeDigest,
                  receipt.selectedCount == challenge.selectedCount,
                  receipt.wholeBatchConfirmationRecorded,
                  !receipt.createsRepairClaim,
                  !receipt.repairClaimCreated,
                  !receipt.repairMutationAuthority,
                  !receipt.automaticRetryAllowed else {
                retainUnknownGhostRepairBulkConfirmation(
                    challenge: challenge,
                    message: "The returned whole-batch receipt did not match the exact confirmed operation. Do not retry it."
                )
                return
            }
            ghostRepairBulkConfirmationPhraseDraft = ""
            ghostRepairBulkRepairRequestID = nil
            ghostRepairBulkRepairState = .idle
            ghostRepairBulkProtectedOperation?.phase = .confirmed(receipt)
            if case .confirmed = outcome {
                ghostRepairBulkConfirmationReceiptState = .confirmed(receipt)
            } else {
                ghostRepairBulkConfirmationReceiptState =
                    .alreadyConfirmed(receipt)
            }
            // Confirmation remains manager-owned evidence only. Final Review
            // is a separate explicit action so the operator can first exit
            // Codex and every app-server owner without losing this receipt.
        case .notFound:
            ghostRepairBulkProtectedOperation = nil
            ghostRepairBulkConfirmationReceiptState = .unavailable(
                message: "The exact whole-batch challenge no longer exists."
            )
        case let .rejected(_, message):
            ghostRepairBulkProtectedOperation = nil
            ghostRepairBulkConfirmationReceiptState = .unavailable(
                message: message
            )
        case let .outcomeUnknown(_, message):
            retainUnknownGhostRepairBulkConfirmation(
                challenge: challenge,
                message: message
            )
        }
    }

    private func retainUnknownGhostRepairBulkConfirmation(
        challenge: CodexGhostRepairBulkConfirmationChallenge,
        message: String
    ) {
        ghostRepairBulkProtectedOperation?.phase =
            .confirmationOutcomeUnknown(
                challenge: challenge,
                message: message
            )
        ghostRepairBulkConfirmationReceiptState = .unavailable(
            message: message
        )
        ghostRepairBulkRepairState = .idle
    }

    var ghostRepairBulkFinalReviewBlockedReason: String? {
        guard isGhostRepairBulkWorkflowEnabled else {
            return "Enable Bulk Ghost Delete in Settings first."
        }
        guard ghostRepairBulkRepairCoordinator.capabilities.reviewAvailable else {
            return "Bulk final repair review is not available in this build."
        }
        guard let phase = ghostRepairBulkProtectedOperation?.phase else {
            return "Record the one whole-batch confirmation first."
        }
        switch phase {
        case .confirmed:
            return nil
        case .confirming:
            return "Whole-batch confirmation is still running."
        case .confirmationOutcomeUnknown:
            return "The confirmation outcome is unresolved. Do not retry it."
        case .preparingFinalReview, .executing:
            return "A bulk repair operation is already running."
        case .reviewReady:
            return "The exact final review is already ready."
        case .completed:
            return "This operation already has a terminal Report."
        case .completedUnresolved:
            return "The terminal Report requires exact read-only recovery. Do not retry it."
        case .recoveryRequired:
            return "This operation requires exact read-only recovery. Do not retry it."
        case .preparedClosureReviewReady, .closingPreparedClosure,
             .preparedClosureOutcomeUnknown,
             .preparedClosureRecoveryRequired:
            return "This exact prepared plan is in the manager-only closure workflow."
        case .closedBeforeAttempt:
            return "This unstarted plan was closed without a repair attempt."
        }
    }

    var ghostRepairBulkRepairCapabilities:
        CodexGhostRepairBulkRepairCapabilities
    {
        ghostRepairBulkRepairCoordinator.capabilities
    }

    var ghostRepairBulkConfirmationReceipt:
        CodexGhostRepairBulkConfirmationReceipt?
    {
        if let phase = ghostRepairBulkProtectedOperation?.phase {
            switch phase {
            case let .confirmed(receipt),
                 let .preparingFinalReview(receipt, _),
                 let .reviewReady(receipt, _),
                 let .executing(receipt, _, _),
                 let .completed(receipt, _),
                 let .completedUnresolved(receipt, _),
                 let .recoveryRequired(receipt, _):
                return receipt
            case let .preparedClosureReviewReady(origin, _),
                 let .closingPreparedClosure(origin, _, _),
                 let .preparedClosureOutcomeUnknown(origin, _, _),
                 let .preparedClosureRecoveryRequired(origin, _, _, _):
                guard case let .current(receipt, _) = origin else {
                    return nil
                }
                return receipt
            case .confirming, .confirmationOutcomeUnknown,
                 .closedBeforeAttempt:
                break
            }
        }
        switch ghostRepairBulkConfirmationReceiptState {
        case let .confirmed(receipt), let .alreadyConfirmed(receipt):
            return receipt
        case .idle, .confirming, .unavailable:
            return nil
        }
    }

    func prepareGhostRepairBulkFinalReview() async {
        guard ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil,
              ghostRepairBulkPreparedClosureRequestID == nil else {
            errorMessage = ghostRepairBulkWorkflowMutationBlockedReason
            return
        }
        if let protectedOperation = ghostRepairBulkProtectedOperation {
            guard case let .confirmed(receipt) = protectedOperation.phase else {
                return
            }
            guard ghostRepairBulkFinalReviewBlockedReason == nil else {
                ghostRepairBulkRepairState = .unavailable(
                    message: ghostRepairBulkFinalReviewBlockedReason
                        ?? "Bulk final repair review is unavailable."
                )
                return
            }
            await prepareGhostRepairBulkFinalReview(
                protectedOperation: protectedOperation,
                receipt: receipt
            )
            return
        }
        guard ghostRepairBulkFinalReviewBlockedReason == nil else {
            ghostRepairBulkRepairState = .unavailable(
                message: ghostRepairBulkFinalReviewBlockedReason
                    ?? "Whole-batch confirmation is unavailable."
            )
            return
        }
    }

    private func prepareGhostRepairBulkFinalReview(
        protectedOperation: GhostRepairBulkProtectedOperation,
        receipt: CodexGhostRepairBulkConfirmationReceipt
    ) async {
        let requestID = UUID()
        ghostRepairBulkRepairRequestID = requestID
        ghostRepairBulkRepairState = .preparingReview(requestID: requestID)
        ghostRepairBulkProtectedOperation?.phase = .preparingFinalReview(
            receipt: receipt,
            requestID: requestID
        )
        let outcome = await ghostRepairBulkRepairCoordinator.prepareFinalReview(
            request: CodexGhostRepairBulkRepairReviewRequest(
                requestID: requestID,
                confirmationReceiptID: receipt.receiptID
            )
        )
        guard ghostRepairBulkRepairRequestID == requestID,
              ghostRepairBulkProtectedOperation?.savedPreviewRequestID
                == protectedOperation.savedPreviewRequestID,
              ghostRepairBulkProtectedOperation?.operationID
                == protectedOperation.operationID,
              case let .preparingFinalReview(currentReceipt, currentRequestID)?
                = ghostRepairBulkProtectedOperation?.phase,
              currentReceipt == receipt,
              currentRequestID == requestID else { return }
        ghostRepairBulkRepairRequestID = nil
        switch outcome {
        case let .ready(review):
            guard review.operationID == receipt.operationID,
                  review.confirmationReceiptID == receipt.receiptID,
                  review.selectedCount == receipt.selectedCount,
                  review.selectedCount
                    == protectedOperation.expectedItems.count,
                  review.ordinaryCount
                    == protectedOperation.expectedItems.count(where: {
                        $0.category == .ordinary
                    }),
                  review.automationCount
                    == protectedOperation.expectedItems.count(where: {
                        $0.category == .automation
                    }),
                  review.allOrNothing,
                  review.codexMustRemainExited,
                  review.managerMustRemainOpen,
                  !review.automaticRetryAllowed,
                  !review.automaticRestoreAllowed,
                  !review.silentSelectionShrinkAllowed else {
                ghostRepairBulkRepairState = .unavailable(
                    message: "Final review did not match the exact confirmed batch. Nothing was executed."
                )
                ghostRepairBulkProtectedOperation?.phase = .confirmed(receipt)
                return
            }
            let bindingReady = await bindNativeDeleteDesktopCleanupIfNeeded(
                protectedOperation: protectedOperation,
                receipt: receipt,
                review: review
            )
            guard bindingReady else {
                ghostRepairBulkProtectedOperation?.phase = .reviewReady(
                    receipt: receipt,
                    review: review
                )
                ghostRepairBulkRepairState = .reviewReady(review)
                return
            }
            ghostRepairBulkProtectedOperation?.phase = .reviewReady(
                receipt: receipt,
                review: review
            )
            ghostRepairBulkRepairState = .reviewReady(review)
        case let .awaitingShutdown(message):
            logDiagnostic(
                level: .warning, category: .lifecycle,
                message: "Bulk Ghost Final Review awaiting shutdown before runner preparation",
                metadata: ["selected_count": String(receipt.selectedCount),
                           "repair_claim_created": "false", "mutation_attempted": "false"]
            )
            ghostRepairBulkProtectedOperation?.phase = .confirmed(receipt)
            ghostRepairBulkRepairState = .unavailable(message: message)
            ghostRepairCleanupState = .awaitingShutdown
        case let .blocked(message), let .unavailable(message):
            logDiagnostic(
                level: .warning,
                category: .lifecycle,
                message: "Bulk Ghost Final Review stopped before claim",
                metadata: [
                    "reason": message,
                    "selected_count": String(receipt.selectedCount),
                    "repair_claim_created": "false",
                    "mutation_attempted": "false",
                ]
            )
            ghostRepairBulkProtectedOperation?.phase = .confirmed(receipt)
            ghostRepairBulkRepairState = .unavailable(message: message)
        }
    }

    private func bindNativeDeleteDesktopCleanupIfNeeded(
        protectedOperation: GhostRepairBulkProtectedOperation,
        receipt: CodexGhostRepairBulkConfirmationReceipt,
        review: CodexGhostRepairBulkFinalReview
    ) async -> Bool {
        guard case let .inventoryReady(context, handoff) =
            nativeDeleteDesktopCleanupState else {
            return true
        }
        let identity = CodexGhostRepairBulkRecoveryOperationIdentity(
            requestID: protectedOperation.savedPreviewRequestID,
            operationID: protectedOperation.operationID
        )
        let requestID = UUID()
        ghostRepairBulkRepairRequestID = requestID
        ghostRepairBulkProtectedOperation?.phase = .preparingFinalReview(
            receipt: receipt,
            requestID: requestID
        )
        nativeDeleteDesktopCleanupState = .binding(
            requestID: requestID,
            context,
            handoff,
            identity: identity
        )
        let outcome = await nativeDeleteDesktopCleanupCoordinator
            .bindPreparedOperation(
                handoff: handoff,
                bulkIdentity: identity
            )
        guard ghostRepairBulkRepairRequestID == requestID,
              nativeDeleteDesktopCleanupState == .binding(
                requestID: requestID,
                context,
                handoff,
                identity: identity
              ),
              ghostRepairBulkProtectedOperation?.savedPreviewRequestID
                == protectedOperation.savedPreviewRequestID,
              ghostRepairBulkProtectedOperation?.operationID
                == protectedOperation.operationID,
              case let .preparingFinalReview(currentReceipt, currentRequestID)?
                = ghostRepairBulkProtectedOperation?.phase,
              currentReceipt == receipt,
              currentRequestID == requestID else {
            return false
        }
        ghostRepairBulkRepairRequestID = nil
        switch outcome {
        case let .bound(binding), let .alreadyBound(binding):
            guard binding.bulkIdentity == identity,
                  binding.planDigest == review.reviewDigest,
                  nativeDeleteDesktopCleanupBindingMatchesProtectedOperation(
                    handoff: handoff,
                    binding: binding
                  ) else {
                nativeDeleteDesktopCleanupState = .bindingRecoveryRequired(
                    context,
                    handoff,
                    identity: identity,
                    message: "The durable cleanup binding did not match the exact prepared operation. Do not execute or create a replacement."
                )
                return false
            }
            nativeDeleteDesktopCleanupState = .status(
                context,
                .prepared(handoff, binding)
            )
            return true
        case .notFound:
            nativeDeleteDesktopCleanupState = .bindingRecoveryRequired(
                context,
                handoff,
                identity: identity,
                message: "The exact canonical Delete evidence was not found while binding. The prepared operation was retained and cannot execute."
            )
        case let .rejected(message):
            nativeDeleteDesktopCleanupState = .bindingRecoveryRequired(
                context,
                handoff,
                identity: identity,
                message: "Cleanup binding was rejected: \(message) The prepared operation was retained and cannot execute."
            )
        case let .finalizationOutcomeUnknown(reportID, message):
            let outcomeMessage = reportID == context.canonicalDeleteReportID
                ? message
                : "Cleanup binding returned a different report identity."
            nativeDeleteDesktopCleanupState = .bindingRecoveryRequired(
                context,
                handoff,
                identity: identity,
                message: "The cleanup binding outcome is unknown: \(outcomeMessage) Use exact status readback; do not execute or create a replacement."
            )
        }
        return false
    }

    func readNativeDeleteDesktopCleanupStatus() async {
        guard nativeDeleteDesktopCleanupStatusBlockedReason == nil,
              nativeDeleteDesktopCleanupStatusRequestID == nil,
              let context = nativeDeleteDesktopCleanupContext,
              let expectedIdentity =
                nativeDeleteDesktopCleanupExpectedIdentity else {
            return
        }
        let expectedHandoff: CodexDesktopCleanupHandoff
        let previouslyAcceptedBinding: CodexDesktopCleanupBinding?
        switch nativeDeleteDesktopCleanupState {
        case let .bindingRecoveryRequired(_, handoff, _, _):
            expectedHandoff = handoff
            previouslyAcceptedBinding = nil
        case let .status(_, status):
            let evidence = nativeDeleteDesktopCleanupStatusEvidence(status)
            expectedHandoff = evidence.handoff
            previouslyAcceptedBinding = evidence.binding
        case .idle, .queued, .reviewing, .pending, .inventoryReady,
             .inventoryBlocked, .binding, .unavailable:
            return
        }
        let requestID = UUID()
        nativeDeleteDesktopCleanupStatusRequestID = requestID
        let outcome = await nativeDeleteDesktopCleanupCoordinator.readStatus(
            reportID: context.canonicalDeleteReportID
        )
        guard nativeDeleteDesktopCleanupStatusRequestID == requestID,
              nativeDeleteDesktopCleanupContext == context else {
            return
        }
        nativeDeleteDesktopCleanupStatusRequestID = nil
        switch outcome {
        case let .status(status):
            let evidence = nativeDeleteDesktopCleanupStatusEvidence(status)
            guard evidence.handoff == expectedHandoff,
                  nativeDeleteDesktopCleanupHandoffMatches(
                    evidence.handoff,
                    context: context
                  ) else {
                nativeDeleteDesktopCleanupState = .bindingRecoveryRequired(
                    context,
                    expectedHandoff,
                    identity: expectedIdentity,
                    message: "Desktop cleanup status did not match the exact handoff. The original operation remains protected."
                )
                return
            }
            guard let binding = evidence.binding,
                  binding.bulkIdentity == expectedIdentity else {
                nativeDeleteDesktopCleanupState = .bindingRecoveryRequired(
                    context,
                    expectedHandoff,
                    identity: expectedIdentity,
                    message: "No exact binding for the original prepared operation was found. Do not execute or create a replacement."
                )
                return
            }
            if let previouslyAcceptedBinding {
                guard binding == previouslyAcceptedBinding else {
                    nativeDeleteDesktopCleanupState =
                        .bindingRecoveryRequired(
                            context,
                            expectedHandoff,
                            identity: expectedIdentity,
                            message: "Desktop cleanup status changed the previously accepted immutable binding. The original operation remains protected."
                        )
                    return
                }
            } else if ghostRepairBulkProtectedOperation != nil,
               !nativeDeleteDesktopCleanupBindingMatchesProtectedOperation(
                    handoff: evidence.handoff,
                    binding: binding
               ) {
                nativeDeleteDesktopCleanupState = .bindingRecoveryRequired(
                    context,
                    expectedHandoff,
                    identity: expectedIdentity,
                    message: "Desktop cleanup status belongs to a different prepared operation. The original operation remains protected."
                )
                return
            }
            nativeDeleteDesktopCleanupState = .status(context, status)
        case .notFound:
            nativeDeleteDesktopCleanupState = .bindingRecoveryRequired(
                context,
                expectedHandoff,
                identity: expectedIdentity,
                message: "The exact Desktop cleanup linkage was not found. The original operation remains protected."
            )
        case let .unavailable(message):
            nativeDeleteDesktopCleanupState = .bindingRecoveryRequired(
                context,
                expectedHandoff,
                identity: expectedIdentity,
                message: "Exact Desktop cleanup status is unavailable: \(message)"
            )
        }
    }

    private var nativeDeleteDesktopCleanupExpectedIdentity:
        CodexGhostRepairBulkRecoveryOperationIdentity?
    {
        switch nativeDeleteDesktopCleanupState {
        case let .binding(_, _, _, identity),
             let .bindingRecoveryRequired(_, _, identity, _):
            return identity
        case let .status(_, status):
            return nativeDeleteDesktopCleanupStatusEvidence(status)
                .binding?.bulkIdentity
        case .idle, .queued, .reviewing, .pending, .inventoryReady,
             .inventoryBlocked, .unavailable:
            return nil
        }
    }

    func executeGhostRepairBulkOneShot() async {
        guard ghostRepairBulkPreviousOperationsRequestID == nil,
              ghostRepairBulkRecoveryReadbackRequestID == nil,
              ghostRepairBulkConfirmationReceiptRecoveryRequestID == nil,
              ghostRepairBulkFreshRecoveryRequestID == nil,
              ghostRepairBulkPreparedClosureRequestID == nil else {
            errorMessage = ghostRepairBulkWorkflowMutationBlockedReason
            return
        }
        if let protectedOperation = ghostRepairBulkProtectedOperation {
            guard isGhostRepairBulkWorkflowEnabled,
                  nativeDeleteDesktopCleanupExecutionBlockedReason == nil,
                  ghostRepairBulkRepairCoordinator.capabilities
                    .executionAvailable,
                  case let .reviewReady(receipt, review) =
                    protectedOperation.phase,
                  case let .reviewReady(presentedReview) =
                    ghostRepairBulkRepairState,
                  presentedReview == review,
                  review.operationID == receipt.operationID,
                  review.confirmationReceiptID == receipt.receiptID else {
                return
            }
            await executeGhostRepairBulkOneShot(
                protectedOperation: protectedOperation,
                receipt: receipt,
                review: review
            )
            return
        }
        ghostRepairBulkRepairState = .unavailable(
            message: "The exact final review is unavailable. Nothing was executed."
        )
    }

    private func executeGhostRepairBulkOneShot(
        protectedOperation: GhostRepairBulkProtectedOperation,
        receipt: CodexGhostRepairBulkConfirmationReceipt,
        review: CodexGhostRepairBulkFinalReview
    ) async {
        let requestID = UUID()
        ghostRepairBulkRepairRequestID = requestID
        ghostRepairBulkRepairState = .executing(operationID: review.operationID)
        ghostRepairBulkProtectedOperation?.phase = .executing(
            receipt: receipt,
            review: review,
            requestID: requestID
        )
        let outcome = await ghostRepairBulkRepairCoordinator.execute(
            request: CodexGhostRepairBulkRepairExecutionRequest(
                requestID: requestID,
                review: review
            )
        )
        guard ghostRepairBulkRepairRequestID == requestID,
              ghostRepairBulkProtectedOperation?.savedPreviewRequestID
                == protectedOperation.savedPreviewRequestID,
              ghostRepairBulkProtectedOperation?.operationID
                == protectedOperation.operationID,
              case let .executing(currentReceipt, currentReview, currentRequestID)?
                = ghostRepairBulkProtectedOperation?.phase,
              currentReceipt == receipt,
              currentReview == review,
              currentRequestID == requestID else { return }
        ghostRepairBulkRepairRequestID = nil
        switch outcome {
        case let .completed(report):
            let expectedIdentity = protectedOperation.expectedItems
                .map { ($0.threadID, $0.category) }
                .sorted { $0.0 < $1.0 }
            let reportedIdentity = report.itemReports
                .map { ($0.threadID, $0.category) }
                .sorted { $0.0 < $1.0 }
            guard report.operationID == review.operationID,
                  report.itemReports.count == review.selectedCount,
                  expectedIdentity.elementsEqual(
                    reportedIdentity,
                    by: { $0.0 == $1.0 && $0.1 == $1.1 }
                  ),
                  !report.automaticRetryAllowed,
                  !report.automaticRestoreAllowed else {
                ghostRepairBulkRepairState = .recoveryRequired(
                    operationID: review.operationID,
                    message: "Terminal Report did not match the exact batch. Do not retry."
                )
                ghostRepairBulkProtectedOperation?.phase = .recoveryRequired(
                    receipt: receipt,
                    message: "Terminal Report did not match the exact batch. Do not retry."
                )
                return
            }
            if report.outcome == .unknown
                || report.itemReports.contains(where: {
                    $0.outcome == .unknown
                }) {
                ghostRepairBulkProtectedOperation?.phase =
                    .completedUnresolved(
                        receipt: receipt,
                        report: report
                    )
            } else {
                ghostRepairBulkProtectedOperation?.phase = .completed(
                    receipt: receipt,
                    report: report
                )
            }
            ghostRepairBulkRepairState = .completed(report)
        case let .recoveryRequired(operationID, message):
            guard operationID == review.operationID else {
                let mismatchMessage =
                    "Operation identity changed. Do not retry."
                ghostRepairBulkRepairState = .recoveryRequired(
                    operationID: review.operationID,
                    message: mismatchMessage
                )
                ghostRepairBulkProtectedOperation?.phase = .recoveryRequired(
                    receipt: receipt,
                    message: mismatchMessage
                )
                return
            }
            ghostRepairBulkProtectedOperation?.phase = .recoveryRequired(
                receipt: receipt,
                message: message
            )
            ghostRepairBulkRepairState = .recoveryRequired(
                operationID: operationID,
                message: message
            )
        case let .unavailable(message):
            let recoveryMessage =
                "The one-shot outcome is unavailable: \(message) Do not retry."
            ghostRepairBulkProtectedOperation?.phase = .recoveryRequired(
                receipt: receipt,
                message: recoveryMessage
            )
            ghostRepairBulkRepairState = .recoveryRequired(
                operationID: review.operationID,
                message: recoveryMessage
            )
        }
        if case .idle = nativeDeleteDesktopCleanupState {
            return
        }
        await readNativeDeleteDesktopCleanupStatus()
    }

    var ghostRepairSnapshotReadbackCapabilities:
        CodexGhostRepairSnapshotReadbackCapabilities
    {
        ghostRepairSnapshotReadbackCoordinator.capabilities
    }

    var ghostRepairSnapshotReadbackBlockedReason: String? {
        guard isGhostRepairSnapshotReadbackEnabled else {
            return "Enable the experimental Snapshot Readback in Settings first."
        }
        guard ghostRepairSnapshotReadbackCapabilities.readbackAvailable else {
            return "Snapshot readback is not available in this build."
        }
        if case .reading = ghostRepairSnapshotReadbackState {
            return "A snapshot readback is already running."
        }
        return nil
    }

    func presentGhostRepairSnapshotReadback() {
        guard isGhostRepairSnapshotReadbackEnabled else {
            errorMessage = ghostRepairSnapshotReadbackBlockedReason
            return
        }
        isGhostRepairSnapshotReadbackPresented = true
    }

    func readGhostRepairSnapshotInventory() async {
        guard ghostRepairSnapshotReadbackBlockedReason == nil else {
            errorMessage = ghostRepairSnapshotReadbackBlockedReason
            return
        }

        let requestID = UUID()
        ghostRepairSnapshotReadbackRequestID = requestID
        ghostRepairSnapshotReadbackState = .reading(requestID: requestID)

        // Readback is explicit and read-only. Revalidate the UI exposure and
        // exact request identity before the first suspension point so startup,
        // sheet presentation, and duplicate actions cannot trigger work.
        guard isGhostRepairSnapshotReadbackEnabled,
              ghostRepairSnapshotReadbackRequestID == requestID,
              ghostRepairSnapshotReadbackState == .reading(
                  requestID: requestID
              ) else { return }

        let outcome = await ghostRepairSnapshotReadbackCoordinator.readback()
        guard isGhostRepairSnapshotReadbackEnabled,
              ghostRepairSnapshotReadbackRequestID == requestID else { return }
        ghostRepairSnapshotReadbackRequestID = nil
        switch outcome {
        case let .observed(inventory):
            ghostRepairSnapshotReadbackState = .observed(inventory)
        case let .unavailable(message):
            ghostRepairSnapshotReadbackState = .unavailable(message: message)
        }
    }

    var ghostRepairSnapshotCleanupCapabilities:
        CodexGhostRepairSnapshotCleanupCapabilities
    {
        ghostRepairSnapshotCleanupCoordinator.capabilities
    }

    var isGhostRepairSnapshotCleanupRunning: Bool {
        switch ghostRepairSnapshotCleanupState {
        case .inspecting, .preparing, .executing:
            true
        case .idle, .observed, .reviewReady, .completed,
             .recoveryRequired, .unavailable:
            false
        }
    }

    func presentGhostRepairSnapshotCleanup() async {
        guard ghostRepairSnapshotCleanupCapabilities.inspectionAvailable else {
            errorMessage = "Published Snapshot cleanup is unavailable in this build."
            return
        }
        isGhostRepairSnapshotCleanupPresented = true
        await inspectGhostRepairSnapshotCleanup()
    }

    func inspectGhostRepairSnapshotCleanup() async {
        guard !isGhostRepairSnapshotCleanupRunning else { return }
        let requestID = UUID()
        ghostRepairSnapshotCleanupRequestID = requestID
        ghostRepairSnapshotCleanupState = .inspecting(requestID: requestID)
        let outcome = await ghostRepairSnapshotCleanupCoordinator.inspect()
        guard ghostRepairSnapshotCleanupRequestID == requestID,
              isGhostRepairSnapshotCleanupPresented else { return }
        ghostRepairSnapshotCleanupRequestID = nil
        switch outcome {
        case let .observed(inventory):
            ghostRepairSnapshotCleanupState = .observed(inventory)
        case let .unavailable(message):
            ghostRepairSnapshotCleanupState = .unavailable(message: message)
        }
    }

    func prepareGhostRepairSnapshotCleanup(reference: String) async {
        guard !isGhostRepairSnapshotCleanupRunning,
              ghostRepairSnapshotCleanupCapabilities
                .moveToManagerTrashAvailable else { return }
        let requestID = UUID()
        ghostRepairSnapshotCleanupRequestID = requestID
        ghostRepairSnapshotCleanupState = .preparing(reference: reference)
        let outcome = await ghostRepairSnapshotCleanupCoordinator.prepare(
            snapshotReference: reference
        )
        guard ghostRepairSnapshotCleanupRequestID == requestID,
              isGhostRepairSnapshotCleanupPresented else { return }
        ghostRepairSnapshotCleanupRequestID = nil
        switch outcome {
        case let .ready(review):
            ghostRepairSnapshotCleanupState = .reviewReady(review)
        case let .blocked(message), let .unavailable(message):
            ghostRepairSnapshotCleanupState = .unavailable(message: message)
        }
    }

    func executeGhostRepairSnapshotCleanup(
        review: CodexGhostRepairSnapshotCleanupReview
    ) async {
        guard !isGhostRepairSnapshotCleanupRunning,
              ghostRepairSnapshotCleanupState == .reviewReady(review) else {
            return
        }
        ghostRepairSnapshotCleanupState = .executing(review)
        let outcome = await ghostRepairSnapshotCleanupCoordinator.execute(
            operationID: review.operationID
        )
        guard case .executing(review) = ghostRepairSnapshotCleanupState else {
            return
        }
        switch outcome {
        case let .completed(report):
            ghostRepairSnapshotCleanupState = .completed(report)
        case let .rejected(message):
            ghostRepairSnapshotCleanupState = .unavailable(message: message)
        case let .recoveryRequired(operationID, message):
            ghostRepairSnapshotCleanupState = .recoveryRequired(
                operationID: operationID,
                message: message
            )
        }
    }

    func returnFromGhostRepairSnapshotCleanupReview() async {
        guard case .reviewReady = ghostRepairSnapshotCleanupState else { return }
        await inspectGhostRepairSnapshotCleanup()
    }

    var ghostRepairSnapshotActionState: GhostRepairSnapshotActionState {
        ghostRepairSnapshotActionState(for: selection)
    }

    func ghostRepairSnapshotActionState(
        for managerKeys: Set<String>
    ) -> GhostRepairSnapshotActionState {
        if let ghostRepairSnapshotExecutionState {
            return ghostRepairSnapshotExecutionState
        }
        return ghostRepairSnapshotReadinessState(managerKeys: managerKeys)
    }

    var ghostRepairSnapshotActionCapabilities:
        CodexGhostRepairSnapshotActionCapabilities
    {
        ghostRepairSnapshotActionCoordinator.capabilities
    }

    var ghostRepairSnapshotAdmissionInspectorCapabilities:
        CodexGhostRepairSnapshotAdmissionInspectorCapabilities
    {
        ghostRepairSnapshotAdmissionInspector.capabilities
    }

    var ghostRepairSnapshotAdmissionOperatorDecision:
        GhostRepairSnapshotAdmissionOperatorDecision
    {
        switch ghostRepairReadOnlyReviewState {
        case .idle:
            return .init(
                kind: .stop,
                title: "STOP — complete the read-only Safety Review first",
                detail: "No Snapshot Admission inspection is allowed yet."
            )
        case .loading:
            return .init(
                kind: .checking,
                title: "CHECKING — collecting the exact Safety Review",
                detail: "Wait for the read-only review to finish."
            )
        case let .unavailable(_, message):
            return .init(
                kind: .stop,
                title: "STOP — Safety Review evidence is unavailable",
                detail: "Do not retry from this screen. \(message)"
            )
        case let .ready(review):
            guard review.snapshotEvidenceEligible else {
                return .init(
                    kind: .stop,
                    title: "STOP — Snapshot protection is incomplete",
                    detail: review.snapshotEvidenceUnavailableReason
                        ?? "The exact inventory, pin, or descendant evidence is not complete."
                )
            }
            guard review.operationalGateClear else {
                let gate = review.executionGate
                let blockers = gate
                    .userFacingBlockerDescriptions
                    .joined(separator: "; ")
                let ownerDetail: String
                if let owners = gate.openHandleOwnerEvidence {
                    let descriptions = Self.sortedOpenHandleOwners(owners)
                        .map(\.userFacingDescription)
                    ownerDetail = descriptions.isEmpty
                        ? ""
                        : " Exact open-handle owners: \(descriptions.joined(separator: "; "))"
                } else {
                    ownerDetail = " Exact open-handle owner evidence is unavailable."
                }
                return .init(
                    kind: .stop,
                    title: "STOP — operating conditions are blocked",
                    detail: blockers.isEmpty
                        ? "A required operating condition is not clear.\(ownerDetail)"
                        : "\(blockers)\(ownerDetail)"
                )
            }
            guard let currentRequest =
                    currentGhostRepairSnapshotAdmissionRequest(
                        managerKeys: selection
                    ) else {
                return .init(
                    kind: .stop,
                    title: "STOP — the selected sessions changed",
                    detail: "Select the same exact sessions from this completed review."
                )
            }

            switch ghostRepairSnapshotAdmissionState {
            case .idle:
                if let blockedReason =
                    ghostRepairSnapshotAdmissionInspectionBlockedReason {
                    return .init(
                        kind: .stop,
                        title: "STOP — read-only Admission cannot start",
                        detail: blockedReason
                    )
                }
                return .init(
                    kind: .ready,
                    title: "READY — run the read-only Admission check once",
                    detail: "The orange repair-only limitations are expected and do not block this check."
                )
            case let .inspecting(request):
                guard request == currentRequest else {
                    return .init(
                        kind: .stop,
                        title: "STOP — the Admission request changed",
                        detail: "Do not retry from this screen."
                    )
                }
                return .init(
                    kind: .checking,
                    title: "CHECKING — read-only Admission is running",
                    detail: "Wait for the result; do not close this sheet."
                )
            case let .allowed(request, _):
                guard request == currentRequest else {
                    return .init(
                        kind: .stop,
                        title: "STOP — the Admission result is stale",
                        detail: "The exact reviewed selection no longer matches."
                    )
                }
                return .init(
                    kind: .passed,
                    title: "PASSED — read-only Admission is clear",
                    detail: "Copy the complete report and close this sheet. No Snapshot or repair was created."
                )
            case let .blocked(request, _, message):
                return .init(
                    kind: .stop,
                    title: request == currentRequest
                        ? "STOP — Snapshot Admission is blocked"
                        : "STOP — the Admission result is stale",
                    detail: "Do not retry from this screen. \(message)"
                )
            case let .unavailable(request, message):
                return .init(
                    kind: .stop,
                    title: request == currentRequest
                        ? "STOP — Snapshot Admission is unavailable"
                        : "STOP — the Admission result is stale",
                    detail: "Do not retry from this screen. \(message)"
                )
            }
        }
    }

    var ghostRepairSnapshotAdmissionReadOnlyReport: String? {
        guard case let .ready(review) = ghostRepairReadOnlyReviewState else {
            return nil
        }
        let decision = ghostRepairSnapshotAdmissionOperatorDecision
        let repairEvidence = review.officialEvidenceEligible
            ? "expected_non_blocking_available"
            : "expected_non_blocking_unavailable"
        let snapshotProtection = review.snapshotEvidenceEligible
            ? "ready"
            : "stop"
        let operatingConditions = review.operationalGateClear
            ? "ready"
            : "stop"
        let gate = review.executionGate
        let admission: String
        switch ghostRepairSnapshotAdmissionState {
        case .idle:
            admission = "not_run"
        case .inspecting:
            admission = "checking"
        case let .allowed(_, evidence):
            admission =
                "allowed_retained_\(evidence.publishedSnapshotCount)_of_\(evidence.maximumSnapshotCount)"
        case let .blocked(_, _, message):
            admission = "blocked_\(Self.singleLineReportValue(message))"
        case let .unavailable(_, message):
            admission = "unavailable_\(Self.singleLineReportValue(message))"
        }

        var lines = [
            "Agent Session Manager — Ghost Repair Read-only Report",
            "operator_decision=\(decision.kind.rawValue)",
            "operator_title=\(Self.singleLineReportValue(decision.title))",
            "operator_detail=\(Self.singleLineReportValue(decision.detail))",
            "targets=\(review.targetThreadIDs.joined(separator: ","))",
            "runtime=\(Self.singleLineReportValue(review.runtimeVersion))",
            "review_observed_at=\(ISO8601DateFormatter().string(from: review.observedAt))",
            "repair_only_evidence=\(repairEvidence)",
            "live_repair=expected_unavailable_non_blocking",
            "snapshot_protection=\(snapshotProtection)",
            "operating_conditions=\(operatingConditions)",
            "desktop_open_handle_count=\(gate.desktopOpenHandleCount)",
            "summaries_open_handle_count=\(gate.summariesOpenHandleCount)",
            "legacy_history_open_handle_count=\(gate.historyOpenHandleCount)",
            "state_open_handle_count=\(gate.stateOpenHandleCount.map(String.init) ?? "unavailable")",
            "thread_history_open_handle_count=\(gate.threadHistoryOpenHandleCount.map(String.init) ?? "unavailable")",
            "snapshot_admission=\(admission)",
            "snapshot_created=false",
            "preview_created=false",
            "repair_mutation_authority=false",
            "automatic_retry=false",
        ]

        if let owners = gate.openHandleOwnerEvidence {
            let sortedOwners = Self.sortedOpenHandleOwners(owners)
            lines.append(
                "open_handle_owner_evidence=\(sortedOwners.isEmpty ? "none" : "collected")"
            )
            lines.append("open_handle_owner_count=\(sortedOwners.count)")
            lines.append(
                "open_handle_owner_process_count=\(Set(sortedOwners.map(\.processIdentifier)).count)"
            )
            for (index, owner) in sortedOwners.enumerated() {
                lines.append(
                    "open_handle_owner_\(index + 1)=\(Self.singleLineReportValue(owner.userFacingDescription))"
                )
            }
        } else {
            lines.append("open_handle_owner_evidence=unavailable")
            lines.append("open_handle_owner_count=unavailable")
            lines.append("open_handle_owner_process_count=unavailable")
        }

        return lines.joined(separator: "\n")
    }

    private static func sortedOpenHandleOwners(
        _ owners: [CodexGhostRepairOpenHandleOwnerEvidence]
    ) -> [CodexGhostRepairOpenHandleOwnerEvidence] {
        owners.sorted { lhs, rhs in
            if lhs.databaseRole.rawValue != rhs.databaseRole.rawValue {
                return lhs.databaseRole.rawValue < rhs.databaseRole.rawValue
            }
            return lhs.processIdentifier < rhs.processIdentifier
        }
    }

    private static func singleLineReportValue(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var ghostRepairSnapshotAdmissionInspectionBlockedReason: String? {
        ghostRepairSnapshotAdmissionInspectionBlockedReason(
            managerKeys: selection
        )
    }

    private func ghostRepairSnapshotAdmissionInspectionBlockedReason(
        managerKeys: Set<String>
    ) -> String? {
        guard isGhostRepairBulkWorkflowEnabled else {
            return "Enable Bulk Ghost Delete in Settings first."
        }
        guard ghostRepairSnapshotAdmissionInspectorCapabilities
            .inspectionAvailable else {
            return "Packaged Snapshot admission inspection is unavailable in this build."
        }
        guard ghostRepairSnapshotAdmissionRequestID == nil else {
            return "Snapshot admission inspection is already running."
        }
        guard case .ready = ghostRepairReadOnlyReviewState else {
            return "Complete an exact Ghost Repair Safety Review first."
        }
        guard currentGhostRepairSnapshotAdmissionRequest(
            managerKeys: managerKeys
        ) != nil else {
            return "The frozen Bulk Ghost Delete witness set changed after Safety Review. Prepare the inventory again."
        }
        guard case let .ready(review) = ghostRepairReadOnlyReviewState else {
            return "Complete an exact Ghost Repair Safety Review first."
        }
        guard review.snapshotEvidenceEligible else {
            return "Complete inventory-omission, pin, and descendant evidence before inspecting Snapshot admission."
        }
        guard review.operationalGateClear else {
            return "Snapshot operating conditions are blocked."
        }
        return nil
    }

    private func currentGhostRepairSnapshotAdmissionRequest(
        managerKeys: Set<String>
    )
        -> CodexGhostRepairSnapshotActionRequest?
    {
        guard let witness = ghostRepairManagerSnapshotWitness(
            managerKeys: managerKeys
        ) else { return nil }
        return currentGhostRepairSnapshotAdmissionRequest(witness: witness)
    }

    var ghostRepairSnapshotActionBlockedReason: String? {
        ghostRepairSnapshotActionBlockedReason(for: selection)
    }

    func ghostRepairSnapshotActionBlockedReason(
        for managerKeys: Set<String>
    ) -> String? {
        switch ghostRepairSnapshotActionState(for: managerKeys) {
        case .ready:
            nil
        case let .unavailable(message),
             let .blocked(_, message),
             let .recoveryRequired(_, _, message),
             let .failed(_, message):
            message
        case .reviewRequired:
            "Complete an exact Ghost Repair Safety Review first."
        case .acquiring:
            "A Ghost Repair snapshot action is already running."
        case .succeeded:
            "The completed snapshot action must be reset before another request."
        }
    }

    var ghostRepairSnapshotRecoveryReference: String? {
        guard case let .recoveryRequired(_, reference, _) =
            ghostRepairSnapshotExecutionState else { return nil }
        return reference
    }

    func requestGhostRepairSnapshotAction(
        managerKeys: Set<String>
    ) async {
        let frozenManagerKeys = managerKeys
        guard case let .ready(request) = ghostRepairSnapshotActionState(
            for: frozenManagerKeys
        ) else {
            errorMessage = ghostRepairSnapshotActionBlockedReason(
                for: frozenManagerKeys
            )
            return
        }

        guard request.targetThreadIDs.isEmpty == false,
              let witness = ghostRepairManagerSnapshotWitness(
                managerKeys: frozenManagerKeys
              ) else { return }
        await requestGhostRepairSnapshotAction(witness: witness)
    }

    /// One explicit user intent owns both the read-only admission check and,
    /// only when that exact check passes, the snapshot effect. Keeping the
    /// two coordinators separate preserves their authority boundaries without
    /// forcing the operator to shuttle between two buttons.
    func requestGhostRepairSnapshotWithAutomaticAdmission(
        managerKeys: Set<String>
    ) async {
        let frozenManagerKeys = managerKeys
        guard let witness = ghostRepairManagerSnapshotWitness(
            managerKeys: frozenManagerKeys
        ) else {
            errorMessage = ghostRepairSnapshotCombinedActionBlockedReason(
                managerKeys: frozenManagerKeys
            )
            return
        }
        await requestGhostRepairSnapshotWithAutomaticAdmission(
            witness: witness
        )
    }

    func ghostRepairSnapshotCombinedActionBlockedReason(
        managerKeys: Set<String>
    ) -> String? {
        let frozenManagerKeys = managerKeys
        switch ghostRepairSnapshotActionState(for: frozenManagerKeys) {
        case .ready:
            return nil
        case .acquiring:
            return "A Ghost Repair snapshot action is already running."
        case .succeeded:
            return "The exact Snapshot has already been published."
        case let .recoveryRequired(_, _, message),
             let .failed(_, message),
             let .unavailable(message):
            return message
        case let .blocked(_, message):
            switch ghostRepairSnapshotAdmissionState {
            case .idle:
                return ghostRepairSnapshotAdmissionInspectionBlockedReason(
                    managerKeys: frozenManagerKeys
                )
            case .inspecting:
                return "Snapshot admission is already being checked."
            case .allowed:
                return message
            case let .blocked(_, _, admissionMessage),
                 let .unavailable(_, admissionMessage):
                return admissionMessage
            }
        case .reviewRequired:
            return "Complete an exact Ghost Repair Safety Review first."
        }
    }

    func resetGhostRepairSnapshotAction() {
        guard ghostRepairSnapshotActionRequestID == nil else { return }
        if case .recoveryRequired = ghostRepairSnapshotExecutionState { return }
        ghostRepairSnapshotExecutionState = nil
    }

    private func ghostRepairSnapshotReadinessState(
        managerKeys: Set<String>
    )
        -> GhostRepairSnapshotActionState
    {
        guard isGhostRepairBulkWorkflowEnabled else {
            return .unavailable(
                message: "The experimental Ghost Repair snapshot action is disabled."
            )
        }
        guard ghostRepairSnapshotActionCapabilities.acquisitionAvailable else {
            return .unavailable(
                message: "Packaged raw database snapshot acquisition is not available in this build."
            )
        }
        guard case let .ready(review) = ghostRepairReadOnlyReviewState else {
            return .reviewRequired
        }
        guard let witness = ghostRepairManagerSnapshotWitness(
            managerKeys: managerKeys
        ) else {
            return .blocked(
                targetThreadIDs: review.targetThreadIDs,
                message: "The frozen Bulk Ghost Delete witness set changed after Safety Review. Prepare the inventory again."
            )
        }
        return ghostRepairSnapshotReadinessState(witness: witness)
    }

    func ghostRepairReadOnlyReviewBlockedReason(
        for managerKeys: Set<String>
    ) -> String? {
        if let reference = ghostRepairSnapshotRecoveryReference {
            return "Snapshot \(reference) requires exact readback before another Safety Review."
        }
        guard isGhostRepairBulkWorkflowEnabled else {
            return "Enable Bulk Ghost Delete in Settings first."
        }
        if case .loading = ghostRepairReadOnlyReviewState {
            return "A read-only Ghost Repair safety review is already running."
        }
        guard (1...10).contains(managerKeys.count) else {
            return "Select 1–10 exact Deleted Codex sessions."
        }
        let rows = sessionRows.filter { managerKeys.contains($0.id) }
        guard rows.count == managerKeys.count,
              rows.allSatisfy({ $0.system == .codex && $0.displayState == .deleted }) else {
            return "Ghost Repair Safety Review accepts only manager Deleted tombstones from Codex."
        }
        return nil
    }

    var isGhostRepairOperatingPreflightInspecting: Bool {
        if case .inspecting = ghostRepairOperatingPreflightState { return true }
        return false
    }

    func inspectGhostRepairOperatingConditions() async {
        guard ghostRepairOperatingPreflightRequestID == nil else { return }
        let requestID = UUID()
        ghostRepairOperatingPreflightRequestID = requestID
        ghostRepairOperatingPreflightState = .inspecting(requestID: requestID)
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Maintenance readiness inspection started",
            metadata: ["authority": "read_only_preflight"]
        )
        do {
            let gate = try await ghostRepairOperationalGateSource
                .ghostRepairExecutionGate()
            guard ghostRepairOperatingPreflightRequestID == requestID else {
                return
            }
            ghostRepairOperatingPreflightRequestID = nil
            ghostRepairOperatingPreflightState = .observed(
                gate: gate,
                observedAt: Date()
            )
            var metadata = Self.ghostRepairOperatingGateDiagnosticMetadata(gate)
            metadata["authority"] = "read_only_preflight"
            logDiagnostic(
                level: gate.isClear ? .info : .warning,
                category: .lifecycle,
                message: "Maintenance readiness inspection completed",
                metadata: metadata
            )
        } catch {
            guard ghostRepairOperatingPreflightRequestID == requestID else {
                return
            }
            ghostRepairOperatingPreflightRequestID = nil
            ghostRepairOperatingPreflightState = .unavailable(
                message: error.localizedDescription
            )
            logDiagnostic(
                level: .warning,
                category: .lifecycle,
                message: "Maintenance readiness inspection unavailable",
                metadata: [
                    "authority": "read_only_preflight",
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func requestGhostRepairReadOnlyReview(
        witness: GhostRepairAutomaticSnapshotWitness
    ) async {
        if case .loading = ghostRepairReadOnlyReviewState { return }
        guard ghostRepairSnapshotRecoveryReference == nil,
              isGhostRepairBulkWorkflowEnabled,
              ghostRepairAutomaticSnapshotWitnessIsCurrent(witness) else {
            return
        }
        let targetThreadIDs = witness.threadIDs
        let requestID = UUID()
        ghostRepairSnapshotActionRequestID = nil
        ghostRepairSnapshotAdmissionRequestID = nil
        ghostRepairSnapshotAdmissionState = .idle
        if ghostRepairSnapshotRecoveryReference == nil {
            ghostRepairSnapshotExecutionState = nil
        }
        ghostRepairReviewRequestID = requestID
        ghostRepairReadOnlyReviewState = .loading(
            targetThreadIDs: targetThreadIDs
        )
        do {
            let snapshot = try await ghostRepairReadOnlySafetySource
                .ghostRepairSafetySnapshot(targetThreadIDs: targetThreadIDs)
            guard ghostRepairReviewRequestID == requestID,
                  isGhostRepairBulkWorkflowEnabled else {
                return
            }
            guard ghostRepairAutomaticSnapshotWitnessIsCurrent(witness) else {
                ghostRepairReviewRequestID = nil
                ghostRepairReadOnlyReviewState = .unavailable(
                    targetThreadIDs: targetThreadIDs,
                    message: "The frozen Snapshot witness state changed during Safety Review."
                )
                return
            }
            let review = try CodexGhostRepairReadOnlyReviewBuilder.build(
                targetThreadIDs: targetThreadIDs,
                snapshot: snapshot
            )
            guard ghostRepairReview(review, matches: witness) else {
                ghostRepairReviewRequestID = nil
                ghostRepairReadOnlyReviewState = .unavailable(
                    targetThreadIDs: targetThreadIDs,
                    message: "Safety Review did not match the frozen initial witness runtime and identities."
                )
                return
            }
            ghostRepairReadOnlyReviewState = .ready(review)
        } catch {
            guard ghostRepairReviewRequestID == requestID,
                  isGhostRepairBulkWorkflowEnabled else { return }
            ghostRepairReviewRequestID = nil
            ghostRepairReadOnlyReviewState = .unavailable(
                targetThreadIDs: targetThreadIDs,
                message: error.localizedDescription
            )
        }
    }

    func requestGhostRepairReadOnlyReview(
        managerKeys: Set<String>
    ) async {
        let frozenManagerKeys = managerKeys
        guard ghostRepairReadOnlyReviewBlockedReason(
            for: frozenManagerKeys
        ) == nil else {
            errorMessage = ghostRepairReadOnlyReviewBlockedReason(
                for: frozenManagerKeys
            )
            return
        }

        guard let witness = ghostRepairManagerSnapshotWitness(
            managerKeys: frozenManagerKeys
        ) else { return }
        await requestGhostRepairReadOnlyReview(witness: witness)
    }

    private func currentGhostRepairSnapshotAdmissionRequest(
        witness: GhostRepairAutomaticSnapshotWitness
    ) -> CodexGhostRepairSnapshotActionRequest? {
        guard ghostRepairAutomaticSnapshotWitnessIsCurrent(witness),
              case let .ready(review) = ghostRepairReadOnlyReviewState,
              ghostRepairReview(review, matches: witness) else {
            return nil
        }
        switch witness {
        case .managerTombstones:
            return try? CodexGhostRepairSnapshotActionRequest(review: review)
        case let .initialDiscovery(evidence):
            return try? CodexGhostRepairSnapshotActionRequest(
                review: review,
                initialWitnessEvidence: evidence
            )
        }
    }

    private func requestGhostRepairSnapshotAdmissionInspection(
        witness: GhostRepairAutomaticSnapshotWitness
    ) async {
        guard ghostRepairSnapshotAdmissionInspectorCapabilities
                .inspectionAvailable,
              ghostRepairSnapshotAdmissionRequestID == nil,
              case let .ready(review) = ghostRepairReadOnlyReviewState,
              review.snapshotEvidenceEligible,
              review.operationalGateClear,
              let reviewRequestID = ghostRepairReviewRequestID,
              let request = currentGhostRepairSnapshotAdmissionRequest(
                witness: witness
              ) else {
            return
        }
        let admissionRequestID = UUID()
        ghostRepairSnapshotAdmissionRequestID = admissionRequestID
        ghostRepairSnapshotAdmissionState = .inspecting(request)

        guard case let .ready(freshReview) = ghostRepairReadOnlyReviewState,
              freshReview == review,
              currentGhostRepairSnapshotAdmissionRequest(
                witness: witness
              ) == request else {
            ghostRepairSnapshotAdmissionRequestID = nil
            ghostRepairSnapshotAdmissionState = .idle
            return
        }

        let outcome = await ghostRepairSnapshotAdmissionInspector.inspect(
            request: request
        )
        guard ghostRepairSnapshotAdmissionRequestID == admissionRequestID else {
            return
        }
        guard ghostRepairReviewRequestID == reviewRequestID,
              isGhostRepairBulkWorkflowEnabled,
              case let .ready(currentReview) = ghostRepairReadOnlyReviewState,
              currentReview == review,
              currentGhostRepairSnapshotAdmissionRequest(
                witness: witness
              ) == request else {
            ghostRepairSnapshotAdmissionRequestID = nil
            ghostRepairSnapshotAdmissionState = .idle
            return
        }
        ghostRepairSnapshotAdmissionRequestID = nil
        switch outcome {
        case let .allowed(evidence):
            guard evidence.isAllowed else {
                ghostRepairSnapshotAdmissionState = .unavailable(
                    request,
                    message: "Snapshot storage returned contradictory readiness evidence. No snapshot was started."
                )
                return
            }
            ghostRepairSnapshotAdmissionState = .allowed(request, evidence)
        case let .blocked(evidence, message):
            ghostRepairSnapshotAdmissionState = .blocked(
                request,
                evidence: evidence,
                message: message
            )
        case let .unavailable(message):
            ghostRepairSnapshotAdmissionState = .unavailable(
                request,
                message: message
            )
        }
    }

    private func ghostRepairSnapshotReadinessState(
        witness: GhostRepairAutomaticSnapshotWitness
    ) -> GhostRepairSnapshotActionState {
        guard isGhostRepairBulkWorkflowEnabled else {
            return .unavailable(
                message: "The experimental Ghost Repair snapshot action is disabled."
            )
        }
        guard ghostRepairSnapshotActionCapabilities.acquisitionAvailable else {
            return .unavailable(
                message: "Packaged raw database snapshot acquisition is not available in this build."
            )
        }
        guard ghostRepairAutomaticSnapshotWitnessIsCurrent(witness) else {
            return .blocked(
                targetThreadIDs: witness.threadIDs,
                message: "The frozen Bulk Ghost Delete witness set changed after Safety Review. Prepare the inventory again."
            )
        }
        guard case let .ready(review) = ghostRepairReadOnlyReviewState else {
            return .reviewRequired
        }
        guard ghostRepairReview(review, matches: witness) else {
            return .blocked(
                targetThreadIDs: review.targetThreadIDs,
                message: "The frozen Bulk Ghost Delete witness set changed after Safety Review. Prepare the inventory again."
            )
        }
        guard review.snapshotEvidenceEligible else {
            return .blocked(
                targetThreadIDs: review.targetThreadIDs,
                message: "Complete inventory-omission, pin, and descendant evidence is required before snapshot acquisition."
            )
        }
        guard review.operationalGateClear else {
            let blockers = review.executionGate.userFacingBlockerDescriptions
                .joined(separator: "; ")
            return .blocked(
                targetThreadIDs: review.targetThreadIDs,
                message: "Snapshot operating conditions are blocked: \(blockers)."
            )
        }
        guard let request = currentGhostRepairSnapshotAdmissionRequest(
            witness: witness
        ) else {
            return .blocked(
                targetThreadIDs: review.targetThreadIDs,
                message: "The frozen initial Snapshot witness evidence changed."
            )
        }
        switch ghostRepairSnapshotAdmissionState {
        case let .allowed(admittedRequest, _) where admittedRequest == request:
            return .ready(request)
        case let .blocked(admittedRequest, _, message)
            where admittedRequest == request:
            return .blocked(
                targetThreadIDs: request.targetThreadIDs,
                message: message
            )
        case let .unavailable(admittedRequest, message)
            where admittedRequest == request:
            return .blocked(
                targetThreadIDs: request.targetThreadIDs,
                message: message
            )
        case let .inspecting(admittedRequest) where admittedRequest == request:
            return .blocked(
                targetThreadIDs: request.targetThreadIDs,
                message: "Checking snapshot storage quota and free space…"
            )
        case .idle, .inspecting, .allowed, .blocked, .unavailable:
            return .blocked(
                targetThreadIDs: request.targetThreadIDs,
                message: "Snapshot storage readiness has not been verified for this exact review."
            )
        }
    }

    private func requestGhostRepairSnapshotAction(
        witness: GhostRepairAutomaticSnapshotWitness
    ) async {
        guard ghostRepairSnapshotExecutionState == nil else { return }
        guard case let .ready(request) = ghostRepairSnapshotReadinessState(
            witness: witness
        ) else { return }
        let requestID = UUID()
        ghostRepairSnapshotActionRequestID = requestID
        ghostRepairSnapshotExecutionState = .acquiring(request)
        guard case let .ready(freshRequest) =
                ghostRepairSnapshotReadinessState(witness: witness),
              freshRequest == request else {
            ghostRepairSnapshotActionRequestID = nil
            ghostRepairSnapshotExecutionState = .blocked(
                targetThreadIDs: request.targetThreadIDs,
                message: "The frozen initial witness or safety evidence changed before the snapshot action."
            )
            return
        }
        let outcome = await ghostRepairSnapshotActionCoordinator.perform(
            request: request
        )
        guard ghostRepairSnapshotActionRequestID == requestID,
              isGhostRepairBulkWorkflowEnabled else {
            return
        }
        ghostRepairSnapshotActionRequestID = nil
        switch outcome {
        case let .unavailable(message):
            ghostRepairSnapshotExecutionState = .unavailable(message: message)
        case let .blocked(message):
            ghostRepairSnapshotExecutionState = .blocked(
                targetThreadIDs: request.targetThreadIDs,
                message: message
            )
        case let .succeeded(reference):
            ghostRepairSnapshotExecutionState = .succeeded(
                request,
                reference: reference
            )
        case let .recoveryRequired(reference, message):
            ghostRepairSnapshotExecutionState = .recoveryRequired(
                request,
                reference: reference,
                message: message
            )
        case let .failed(message):
            ghostRepairSnapshotExecutionState = .failed(
                request,
                message: message
            )
        }
    }

    private func requestGhostRepairSnapshotWithAutomaticAdmission(
        witness: GhostRepairAutomaticSnapshotWitness
    ) async {
        guard ghostRepairSnapshotExecutionState == nil else { return }
        if case .ready = ghostRepairSnapshotReadinessState(
            witness: witness
        ) {
            await requestGhostRepairSnapshotAction(witness: witness)
            return
        }
        guard case .idle = ghostRepairSnapshotAdmissionState,
              ghostRepairAutomaticSnapshotWitnessIsCurrent(witness) else {
            return
        }
        await requestGhostRepairSnapshotAdmissionInspection(
            witness: witness
        )
        guard case let .allowed(request, _) =
                ghostRepairSnapshotAdmissionState,
              currentGhostRepairSnapshotAdmissionRequest(
                witness: witness
              ) == request,
              case .ready = ghostRepairSnapshotReadinessState(
                witness: witness
              ) else {
            return
        }
        await requestGhostRepairSnapshotAction(witness: witness)
    }

    func requestGhostRepairSnapshotAdmissionInspection(
        managerKeys: Set<String>
    ) async {
        let frozenManagerKeys = managerKeys
        let blockedReason =
            ghostRepairSnapshotAdmissionInspectionBlockedReason(
                managerKeys: frozenManagerKeys
            )
        guard blockedReason == nil,
              let witness = ghostRepairManagerSnapshotWitness(
                managerKeys: frozenManagerKeys
              ) else {
            errorMessage = blockedReason
            return
        }
        await requestGhostRepairSnapshotAdmissionInspection(witness: witness)
    }

    static func ghostRepairReviewDiagnosticMetadata(
        targetThreadIDs: [String],
        review: CodexGhostRepairReadOnlyReview
    ) -> [String: String] {
        let gate = review.executionGate
        var metadata = ghostRepairOperatingGateDiagnosticMetadata(gate)
        metadata["selection_count"] = String(targetThreadIDs.count)
        metadata["official_evidence_eligible"] = String(
            review.officialEvidenceEligible
        )
        metadata["snapshot_evidence_eligible"] = String(
            review.snapshotEvidenceEligible
        )
        metadata["live_repair_available"] = String(review.liveRepairAvailable)
        return metadata
    }

    static func ghostRepairOperatingGateDiagnosticMetadata(
        _ gate: CodexGhostRepairExecutionGate
    ) -> [String: String] {
        let blockers = gate.blockers.map(\.rawValue)
        let processEvidenceDescription: String
        if let evidence = gate.desktopProcessEvidence {
            processEvidenceDescription = evidence.isEmpty
                ? "none"
                : evidence.map {
                    "\($0.kind.rawValue):\($0.processCount)"
                }.joined(separator: ",")
        } else {
            processEvidenceDescription = "unavailable"
        }
        func evidenceDescription(
            _ evidence: [CodexGhostRepairDesktopProcessEvidence]
        ) -> String {
            evidence.isEmpty
                ? "none"
                : evidence.map {
                    "\($0.kind.rawValue):\($0.processCount)"
                }.joined(separator: ",")
        }
        func processCount(
            _ kind: CodexGhostRepairDesktopProcessKind
        ) -> String {
            guard let evidence = gate.desktopProcessEvidence else {
                return "unavailable"
            }
            return String(
                evidence.first(where: { $0.kind == kind })?.processCount ?? 0
            )
        }
        let openHandleOwnerEvidenceDescription: String
        let uniqueOpenHandleOwnerCount: String
        if let owners = gate.openHandleOwnerEvidence {
            openHandleOwnerEvidenceDescription = owners.isEmpty
                ? "none"
                : owners.map { owner in
                    let parent = owner.parentProcessIdentifier.map(String.init)
                        ?? "unavailable"
                    let parentName = owner.parentProcessName ?? "unavailable"
                    let executable = owner.executableName ?? "unavailable"
                    let kind = owner.processKind?.rawValue ?? "unclassified"
                    return "\(owner.databaseRole.rawValue):pid=\(owner.processIdentifier):ppid=\(parent):name=\(owner.processName):executable=\(executable):parent_name=\(parentName):kind=\(kind):fd=\(owner.fileDescriptorCount)"
                }.joined(separator: ";")
            uniqueOpenHandleOwnerCount = String(
                Set(owners.map(\.processIdentifier)).count
            )
        } else {
            openHandleOwnerEvidenceDescription = "unavailable"
            uniqueOpenHandleOwnerCount = "unavailable"
        }
        return [
            "operational_gate_clear": String(gate.isClear),
            "operational_blockers": blockers.isEmpty
                ? "none"
                : blockers.joined(separator: ","),
            "codex_fully_exited": String(gate.codexFullyExited),
            "desktop_process_evidence": processEvidenceDescription,
            "blocking_desktop_process_evidence": evidenceDescription(
                gate.blockingDesktopProcessEvidence
            ),
            "non_blocking_desktop_process_evidence": evidenceDescription(
                gate.nonBlockingDesktopProcessEvidence
            ),
            "codex_application_process_count": processCount(
                .codexApplication
            ),
            "codex_helper_process_count": processCount(.codexHelper),
            "codex_crash_reporter_process_count": processCount(
                .codexCrashReporter
            ),
            "chatgpt_application_process_count": processCount(
                .chatGPTApplication
            ),
            "chatgpt_helper_process_count": processCount(.chatGPTHelper),
            "chatgpt_crash_reporter_process_count": processCount(
                .chatGPTCrashReporter
            ),
            "desktop_open_handle_count": String(gate.desktopOpenHandleCount),
            "summaries_open_handle_count": String(gate.summariesOpenHandleCount),
            "history_open_handle_count": String(gate.historyOpenHandleCount),
            "state_open_handle_count": gate.stateOpenHandleCount.map(String.init)
                ?? "unavailable",
            "thread_history_open_handle_count": gate.threadHistoryOpenHandleCount
                .map(String.init) ?? "unavailable",
            "open_handle_owner_evidence":
                openHandleOwnerEvidenceDescription,
            "unique_open_handle_owner_process_count":
                uniqueOpenHandleOwnerCount,
            "snapshot_capacity_sufficient": String(gate.capacitySufficient),
        ]
    }

    private static func makeDefaultGhostRepairOperationalGateSource()
        -> any CodexGhostRepairExecutionGateSource
    {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return CodexGhostRepairMacOSOperationalGateSource(
            configuration: CodexGhostRepairOperationalGateConfiguration(
                codexHomeURL: homeURL.appendingPathComponent(
                    ".codex",
                    isDirectory: true
                ),
                backupVolumeProbeURL: homeURL
            )
        )
    }

    private static func makeDefaultGhostRepairReadOnlySafetySource(
        executionGateSource: any CodexGhostRepairExecutionGateSource
    )
        -> any CodexGhostRepairReadOnlySafetySource
    {
        return CodexGhostRepairLiveReadOnlySafetySource(
            absenceContracts: CodexGhostRepairAbsenceContractRegistry(),
            executionGateSource: executionGateSource
        )
    }

    var reportHistorySourceDescription: String {
        "Manager-owned SQLite lifecycle audit reports · read-only"
    }

    func prepareDeletedListClear(selectedOnly: Bool) throws -> DeletedListClearPreview {
        guard !isLoading, !ghostRepairCleanupState.isBusy, let store = liveStateStore else {
            throw SessionManagerError.unsupportedOperation("Wait for the current operation to finish and refresh first.")
        }
        let keys: Set<String>? = selectedOnly ? Set(sessionRows.filter {
            selection.contains($0.managerKey) && $0.displayState == .deleted
        }.map(\.managerKey)) : nil
        return try store.prepareDeletedListClear(selectedManagerKeys: keys)
    }

    func clearDeletedList(_ preview: DeletedListClearPreview) throws {
        guard !isLoading, !ghostRepairCleanupState.isBusy, let store = liveStateStore else {
            throw SessionManagerError.unsupportedOperation("Wait for the current operation to finish.")
        }
        try store.clearDeletedList(preview)
        reconcileClearedHistory(using: store)
        completedHistoryNotice = "Removed \(preview.recordCount) records from the Deleted list. Operation reports and recovery evidence are kept separately. No Codex data or backups were changed."
    }

    func prepareCompletedHistoryClear(selectedOnly: Bool) throws -> CompletedHistoryClearPreview {
        guard !isLoading, !ghostRepairCleanupState.isBusy, let store = liveStateStore else {
            throw SessionManagerError.unsupportedOperation("Wait for the current operation to finish and refresh first.")
        }
        let keys: Set<String>? = selectedOnly ? Set(sessionRows.filter {
            selection.contains($0.managerKey) && $0.displayState == .deleted
        }.map(\.managerKey)) : nil
        return try store.prepareCompletedHistoryClear(selectedManagerKeys: keys)
    }

    func clearCompletedHistory(_ preview: CompletedHistoryClearPreview) throws {
        guard !isLoading, !ghostRepairCleanupState.isBusy, let store = liveStateStore else {
            throw SessionManagerError.unsupportedOperation("Wait for the current operation to finish.")
        }
        let result = try store.clearCompletedHistory(preview)
        reconcileClearedHistory(using: store)
        completedHistoryNotice = "Cleared \(result.deletedRecordCount) Deleted records, \(result.reportCount) reports and \(result.ghostOperationCount) cleanup operations. \(result.keptRecordCount) Deleted records kept."
        logDiagnostic(level: .info, category: .storage, message: "Completed manager history cleared",
            metadata: ["deleted_count": String(result.deletedRecordCount), "report_count": String(result.reportCount),
                       "ghost_operation_count": String(result.ghostOperationCount)])
    }

    private func reconcileClearedHistory(using store: SQLiteStateStore) {
        guard let remaining = try? store.visibleDeletedSessions(for: .codex) else { return }
        let keys = Set(remaining.map(\.managerKey))
        sessionRows.removeAll { $0.displayState == .deleted && !keys.contains($0.managerKey) }
        retainOnlyExistingSelection()
        rebuildSidebarMetrics()
    }

    private func pruneCompletedHistoryIfDue() {
        let now = Date()
        guard !ghostRepairCleanupState.isBusy, let store = liveStateStore,
              lastCompletedHistoryPruneAt.map({ now.timeIntervalSince($0) >= 24 * 60 * 60 }) ?? true else { return }
        do {
            let result = try store.pruneCompletedHistory(now: now)
            lastCompletedHistoryPruneAt = now
            reconcileClearedHistory(using: store)
            if !result.isEmpty {
                completedHistoryNotice = "Automatically cleared completed history older than 30 days. Unresolved records were kept."
                logDiagnostic(level: .info, category: .storage, message: "30-day manager history retention completed",
                    metadata: ["deleted_count": String(result.deletedRecordCount), "report_count": String(result.reportCount),
                               "ghost_operation_count": String(result.ghostOperationCount)])
            }
        } catch {
            // Retention must never turn a successful session refresh into a failure.
            completedHistoryNotice = "History was kept: \(error.localizedDescription)"
        }
    }

    func clearOperationHistory(
        reportIDs: Set<UUID>,
        provider: AgentSystem?,
        confirmationToken: String,
        expectedConfirmationToken: String
    ) throws -> Int {
        guard !reportIDs.isEmpty else { return 0 }
        guard !expectedConfirmationToken.isEmpty,
              confirmationToken == expectedConfirmationToken else {
            throw PersistentStateError.confirmationMismatch
        }
        guard let store = liveStateStore else {
            throw SessionManagerError.unsupportedOperation(
                "The manager SQLite store is unavailable."
            )
        }
        guard let provider else {
            throw SessionManagerError.unsupportedOperation(
                "Select one provider before clearing Live Report history."
            )
        }
        let result = try store.clearOperationHistory(
            reportIDs: reportIDs,
            provider: provider,
            confirmationToken: confirmationToken,
            expectedConfirmationToken: expectedConfirmationToken
        )
        guard Set(result.deletedReportIDs) == reportIDs else {
            throw PersistentStateError.invalidRecord(
                "Cleared Report IDs did not match the frozen selection."
            )
        }
        logDiagnostic(
            level: .warning,
            category: .storage,
            message: "Report History cleared",
            metadata: [
                "data_source": "codex_live",
                "provider": provider.rawValue,
                "report_count": String(result.deletedReportIDs.count),
            ]
        )
        return result.deletedReportIDs.count
    }

    func clearableOperationReportIDs(provider: AgentSystem) throws -> Set<UUID> {
        guard let store = liveStateStore else { return [] }
        return try store.clearableOperationReportIDs(provider: provider)
    }

    var maintenanceUnavailableReason: String? {
        guard liveStateStore != nil else {
            return "The manager SQLite store is unavailable. Refresh Codex Live first."
        }
        return nil
    }

    func count(for filter: CollectionFilter) -> Int {
        sidebarMetrics.statusCounts[filter, default: 0]
    }

    func count(for system: AgentSystem) -> Int {
        sidebarMetrics.systemCounts[system, default: 0]
    }

    func count(forProjectID projectID: String) -> Int {
        sidebarMetrics.projectCounts[projectID, default: 0]
    }

    func count(forTrustFolderPath path: String) -> Int {
        sidebarMetrics.trustFolderCounts[path, default: 0]
    }

    func count(forWorkingFolderPath path: String) -> Int {
        sidebarMetrics.workingFolderCounts[path, default: 0]
    }

    private func rebuildSidebarMetrics() {
        var metrics = SidebarMetrics()
        for session in sessionRows {
            for filter in CollectionFilter.allCases
            where session.system == selectedSystem
                && matches(session, filter: filter)
                && matchesCurrentBrowsingScope(session) {
                metrics.statusCounts[filter, default: 0] += 1
            }
            guard matches(session, filter: selectedFilter) else { continue }
            if matchesCurrentBrowsingScope(session) {
                metrics.systemCounts[session.system, default: 0] += 1
            }
            guard session.system == selectedSystem else { continue }
            metrics.allCurrentStatusCount += 1
            if let projectID = session.project?.id {
                metrics.projectCounts[projectID, default: 0] += 1
            }
            if let trustFolderPath = session.trustFolderPath {
                metrics.trustFolderCounts[trustFolderPath, default: 0] += 1
                metrics.trustFolderCurrentStatusCount += 1
            }
            if let workingDirectory = session.workingDirectory {
                metrics.workingFolderCounts[workingDirectory, default: 0] += 1
            }
        }
        sidebarMetrics = metrics
    }

    private func matches(_ session: SessionPresentation, filter: CollectionFilter) -> Bool {
        switch filter {
        case .all: session.displayState != .deleted
        case .active: session.displayState == .active
        case .archive: session.displayState == .archive
        case .trash: session.displayState == .trash
        case .pinned: session.protection.isPinned
        case .deleted: session.displayState == .deleted
        }
    }

    private func matchesCurrentBrowsingScope(_ session: SessionPresentation) -> Bool {
        switch browsingScope {
        case .all:
            true
        case .project:
            selectedProjectID == nil || session.project?.id == selectedProjectID
        case .trustFolder:
            selectedTrustFolderPath == nil
                || session.trustFolderPath == selectedTrustFolderPath
        case .workingFolder:
            selectedWorkingDirectory == nil
                || session.workingDirectory == selectedWorkingDirectory
        }
    }

    func reload() async {
        guard !isLoading else { return }
        logDiagnostic(
            level: .info,
            category: .inventory,
            message: "Session refresh started",
            metadata: ["data_source": "codex_live"]
        )
        isLoading = true
        defer {
            isLoading = false
            refreshCompatibilityReport(force: true)
        }
        do {
            let coordinator = try liveCoordinator()
            var coordinated = try await coordinator.refresh()
            try await applyLiveSnapshot(coordinated)
            if coordinated.checkpointDisposition == .skippedExecutingRecovery {
                logDiagnostic(
                    level: .warning,
                    category: .recovery,
                    message: "Interrupted operation recovery started",
                    metadata: ["provider": AgentSystem.codex.rawValue]
                )
                guard let recovery = liveNativeArchiveRecoveryCoordinator else {
                    throw SessionManagerError.unsupportedOperation(
                        "An executing Archive Preview blocks checkpoint advancement, but the readback-only recovery facade is unavailable."
                    )
                }
                if let recoveredBatch = try await liveNativeBatchCoordinator?
                    .recoverPending(using: coordinated.snapshot) {
                    logOperationCompleted(
                        operation: recoveredBatch.operation,
                        reportID: recoveredBatch.id,
                        outcome: recoveredBatch.outcome.rawValue,
                        itemCount: recoveredBatch.items.count
                    )
                    presentNativeBatchReport(recoveredBatch)
                } else if let recoveredReport = try await recovery.recoverPending(
                    using: coordinated.snapshot
                ) {
                    logOperationCompleted(
                        operation: recoveredReport.operation,
                        reportID: recoveredReport.id,
                        outcome: recoveredReport.outcome.rawValue,
                        itemCount: recoveredReport.items.count
                    )
                    latestNativeArchiveReport = recoveredReport
                } else if let recoveredReport = try await liveNativeRestoreRecoveryCoordinator?
                    .recoverPending(using: coordinated.snapshot) {
                    logOperationCompleted(
                        operation: .restore,
                        reportID: recoveredReport.id,
                        outcome: recoveredReport.outcome.rawValue,
                        itemCount: recoveredReport.items.count
                    )
                    latestNativeRestoreReport = recoveredReport
                } else if let recoveredReport = try await liveNativeDeleteRecoveryCoordinator?
                    .recoverPending(using: coordinated.snapshot) {
                    logOperationCompleted(
                        operation: .emptyTrash,
                        reportID: recoveredReport.id,
                        outcome: recoveredReport.outcome.rawValue,
                        itemCount: recoveredReport.items.count
                    )
                    latestNativeDeleteReport = recoveredReport
                }
                // Recovery consumed the executing Preview. A second normal
                // refresh may now advance the authoritative checkpoint. A
                // zero-result recovery is also rechecked to handle a safe
                // concurrent completion without inventing an error.
                coordinated = try await coordinator.refresh()
                try await applyLiveSnapshot(coordinated)
            }
            pruneCompletedHistoryIfDue()
            retainOnlyExistingSelection()
            rebuildSidebarMetrics()
            logDiagnostic(
                level: .info,
                category: .inventory,
                message: "Session refresh completed",
                metadata: [
                    "data_source": "codex_live",
                    "session_count": String(sessions.count),
                    "displayed_row_count": String(sessionRows.count),
                    "project_count": String(projectCatalog.count),
                    "checkpoint_disposition": checkpointDisposition.map(String.init(describing:)) ?? "unavailable",
                ]
            )
        } catch {
            errorMessage = error.localizedDescription
            providerDiagnostics = [await liveProvider.diagnostics()]
            logDiagnostic(
                level: .error,
                category: .inventory,
                message: "Session refresh failed",
                metadata: [
                    "data_source": "codex_live",
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func checkCodexCompatibility(confirmedBehaviorFingerprint: String? = nil) async {
        guard !isCheckingCompatibility else { return }
        isCheckingCompatibility = true
        compatibilityProgress = confirmedBehaviorFingerprint == nil ? "Checking local interfaces…" : "Preparing isolated tests…"
        compatibilityCheckError = nil
        compatibilityCompletionMessage = nil
        compatibilityReportIsCurrent = false
        compatibilityRefreshTask?.cancel()
        isComparingCompatibility = false
        let generation = UUID()
        compatibilityCheckID = generation
        let started = Date()
        compatibilityRequestGeneration = generation
        defer { isCheckingCompatibility = false; compatibilityProgress = nil }
        await recordCompatibilityEvent(.init(level: .info, category: .compatibility,
            message: "Compatibility check started", metadata: ["check_id": generation.uuidString,
                "kind": confirmedBehaviorFingerprint == nil ? "inspection" : "isolatedTests"]))
        do {
            let source = try await liveProvider.compatibilityRequest()
            let request = CodexCompatibilityRequest(providerExecutable: source.providerExecutable,
                codexHome: source.codexHome, diagnosticRunID: generation)
            if let fingerprint = confirmedBehaviorFingerprint {
                _ = try await compatibilityInspector.verifyBehavior(request, confirmedFingerprint: fingerprint) { [weak self] stage in
                    guard let self else { return }
                    await MainActor.run {
                        guard self.compatibilityRequestGeneration == generation else { return }
                        self.compatibilityProgress = stage
                        self.logDiagnostic(level: .info, category: .compatibility,
                            message: "Compatibility check stage", metadata: ["check_id": generation.uuidString, "stage": stage])
                    }
                }
            } else {
                _ = try await compatibilityInspector.inspect(request)
            }
            compatibilityProgress = "Comparing results with the current installation…"
            let review = try await compatibilityInspector.reviewSavedCompatibility(request)
            guard compatibilityRequestGeneration == generation else { return }
            applyCompatibilityReview(review)
            compatibilityProgress = "Refreshing the session list…"
            // Rebuild capabilities from the newly saved evidence without another test run.
            await reload()
            compatibilityCompletionMessage = compatibilityReportIsCurrent
                ? compatibilityReport.map { CodexCompatibilityPresentation.completion($0, behaviorRun: confirmedBehaviorFingerprint != nil) }
                : "Check finished, but the current environment could not be matched. Review diagnostics before checking again."
            let incomplete = compatibilityReport.map {
                confirmedBehaviorFingerprint != nil
                    ? $0.behavior?.results.contains { $0.status != .passed } ?? true
                    : $0.results.contains { $0.status != .supportedByBuild }
            } ?? true
            await recordCompatibilityEvent(.init(level: compatibilityReportIsCurrent ? .info : .warning,
                category: .compatibility, message: "Compatibility check finished",
                metadata: ["check_id": generation.uuidString,
                    "outcome": compatibilityReportIsCurrent ? (incomplete ? "completedWithIssues" : "completed") : "recheckRequired",
                    "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1_000))]))
        } catch {
            compatibilityCheckError = error.localizedDescription
            compatibilityCompletionMessage = "Check stopped. Open diagnostics for this check."
            await recordCompatibilityEvent(.init(level: .error, category: .compatibility,
                message: "Compatibility check stopped", metadata: ["check_id": generation.uuidString,
                    "outcome": "stopped", "stage": compatibilityProgress ?? "starting",
                    "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1_000))]
                    .merging(CodexCompatibilityDiagnosticError.metadata(error)) { _, value in value }))
        }
        for event in await compatibilityInspector.takeDiagnostics(runID: generation) {
            await recordCompatibilityEvent(event)
        }
    }

    private func recordCompatibilityEvent(_ event: DiagnosticEvent) async {
        do {
            diagnosticLogSnapshot = try await diagnosticLogStore.record(level: event.level, category: .compatibility,
                message: event.message, metadata: event.metadata, timestamp: event.timestamp)
        } catch {
            diagnosticLogErrorMessage = "Compatibility diagnostics could not be saved. Test results are stored separately."
        }
    }

    func showCompatibilityDiagnostics() {
        diagnosticLogRunFilter = compatibilityCheckID ?? compatibilityReport?.diagnosticRunID
        settingsTab = "logs"
    }

    @discardableResult
    func refreshCompatibilityReport(force: Bool = false) -> Task<Void, Never>? {
        guard !isCheckingCompatibility, !isLoading else { return nil }
        if isComparingCompatibility && !force { return compatibilityRefreshTask }
        compatibilityRefreshTask?.cancel()
        let generation = UUID()
        compatibilityRequestGeneration = generation
        isComparingCompatibility = true
        compatibilityRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if compatibilityRequestGeneration == generation { isComparingCompatibility = false }
            }
            do {
                let request = try await liveProvider.compatibilityRequest()
                let review = try await compatibilityInspector.reviewSavedCompatibility(request)
                guard !Task.isCancelled, compatibilityRequestGeneration == generation else { return }
                applyCompatibilityReview(review)
            } catch {
                guard !Task.isCancelled, compatibilityRequestGeneration == generation else { return }
                compatibilityReportIsCurrent = false
                compatibilityCheckError = "Codex compatibility could not be compared with saved results. Open Compatibility to check again."
            }
        }
        return compatibilityRefreshTask
    }

    private func applyCompatibilityReview(_ review: CodexCompatibilityReview) {
        compatibilityReview = review
        compatibilityReport = review.report
        compatibilityReportIsCurrent = review.isCurrent
        compatibilityCheckError = nil
        if review.metadataUnavailable {
            compatibilityCheckError = "Database metadata could not be read. This is not evidence of a Codex update or incompatibility. Open Compatibility and review database diagnostics."
            isCompatibilityUpdateAlertPresented = false
            return
        }
        if !review.isCurrent, review.report != nil,
           alertedCompatibilityEnvironment != review.environmentFingerprint {
            alertedCompatibilityEnvironment = review.environmentFingerprint
            isCompatibilityUpdateAlertPresented = true
        } else if review.isCurrent {
            isCompatibilityUpdateAlertPresented = false
        }
    }

    var compatibilityNotice: (id: String, title: String, message: String)? {
        if let error = compatibilityCheckError {
            return ("error:\(compatibilityReview?.environmentFingerprint ?? "unknown")", "Compatibility check needs attention", error)
        }
        guard let review = compatibilityReview else { return nil }
        let versions = "CLI: \(review.providerVersion ?? "unavailable") · Desktop runtime: \(review.desktopVersion ?? "unavailable")."
        if !review.isCurrent {
            let hasPrevious = review.report != nil
            return (review.environmentFingerprint,
                    hasPrevious ? "Codex changed — compatibility needs checking" : "Check this Codex installation",
                    versions + (hasPrevious
                        ? " The version, executable or database structure differs from the saved result."
                        : " There is no saved check for this environment.")
                    + " Browsing remains available when readable; unverified operations stay protected.")
        }
        let unresolved = review.report?.results.filter {
            $0.status != .supportedByBuild && review.report?.hasVerifiedBehavior(for: $0.feature) != true
        } ?? []
        guard !unresolved.isEmpty else { return nil }
        return (review.environmentFingerprint + ":features", "Some Codex features need attention",
                versions + " " + unresolved.map { "\($0.feature.label): \($0.status.label)" }.joined(separator: "; ")
                + ". Supported features remain available.")
    }

    var isCompatibilityNoticeExpanded: Bool {
        compatibilityNotice.map { $0.id != deferredCompatibilityNoticeID } ?? false
    }

    func deferCompatibilityNotice() {
        deferredCompatibilityNoticeID = compatibilityNotice?.id
    }

    private func applyLiveSnapshot(
        _ coordinated: CoordinatedSessionSnapshot
    ) async throws {
        sessions = coordinated.reconciliation.entries.compactMap(\.liveSession)
        projectCatalog = await liveProvider.projects()
        var rows = coordinated.reconciliation.entries
            .map {
                SessionPresentation(
                    reconciled: $0,
                    projectCatalog: projectCatalog
                )
            }
        if let liveStateStore {
            let liveKeys = Set(rows.map(\.managerKey))
            rows.append(contentsOf: try liveStateStore.visibleDeletedSessions(for: .codex)
                .filter { !liveKeys.contains($0.managerKey) }
                .map {
                    SessionPresentation(
                        deleted: $0,
                        projectCatalog: projectCatalog
                    )
                })
        }
        sessionRows = rows.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        providerDiagnostics = [coordinated.diagnostics]
        checkpointDisposition = coordinated.checkpointDisposition
        latestCoordinatedSnapshot = coordinated.snapshot
        reconciledStatesByKey = Dictionary(
            uniqueKeysWithValues: coordinated.reconciliation.entries.map { ($0.managerKey, $0) }
        )
        reconciliationCheckpoint = coordinated.reconciliation.checkpoint
        refreshSessionFileSizes(homeURL: await liveProvider.sessionFilesHomeURL())
    }

    private func liveCoordinator() throws -> SessionSnapshotCoordinator {
        if let liveSnapshotCoordinator { return liveSnapshotCoordinator }
        let store = try stateStoreFactory()
        let coordinator = SessionSnapshotCoordinator(provider: liveProvider, store: store)
        liveStateStore = store
        liveSnapshotCoordinator = coordinator
        liveManagerOnlyCoordinator = ManagerOnlyOperationCoordinator(store: store)
        liveNativeArchiveCoordinator = CodexNativeArchiveCoordinator(store: store)
        liveNativeArchiveRecoveryCoordinator = CodexNativeArchiveRecoveryCoordinator(store: store)
        liveNativeRestoreCoordinator = CodexNativeRestoreCoordinator(store: store)
        liveNativeRestoreRecoveryCoordinator = CodexNativeRestoreRecoveryCoordinator(store: store)
        liveNativeDeleteCoordinator = CodexNativeDeleteCoordinator(store: store)
        liveNativeDeleteRecoveryCoordinator = CodexNativeDeleteRecoveryCoordinator(store: store)
        liveNativeBatchCoordinator = CodexNativeBatchCoordinator(store: store)
        liveConflictResolutionCoordinator = ConflictResolutionCoordinator(store: store)
        stateStoreURL = store.databaseURL
        logDiagnostic(
            level: .info,
            category: .storage,
            message: "Manager SQLite store opened",
            metadata: ["path": store.databaseURL.path]
        )
        return coordinator
    }

    func operationHistoryPage(
        _ query: OperationHistoryQuery
    ) throws -> OperationHistoryPage {
        if let reason = reportHistoryUnavailableReason {
            throw SessionManagerError.unsupportedOperation(reason)
        }
        guard let store = liveStateStore else {
            throw SessionManagerError.unsupportedOperation(
                "The manager SQLite store is unavailable."
            )
        }
        return try store.operationHistory(query)
    }

    func allOperationHistoryEntries(
        matching query: OperationHistoryQuery
    ) throws -> [OperationHistoryEntry] {
        var entries: [OperationHistoryEntry] = []
        var cursor: OperationHistoryCursor?
        var seenCursors: Set<String> = []

        for _ in 0 ..< 100 {
            let pageQuery = OperationHistoryQuery(
                provider: query.provider,
                operation: query.operation,
                outcome: query.outcome,
                searchText: query.searchText,
                completedFrom: query.completedFrom,
                completedThrough: query.completedThrough,
                cursor: cursor,
                limit: OperationHistoryQuery.maximumLimit
            )
            let page = try operationHistoryPage(pageQuery)
            entries.append(contentsOf: page.entries)
            guard let nextCursor = page.nextCursor else { return entries }
            let key = "\(nextCursor.completedAt.timeIntervalSinceReferenceDate):\(nextCursor.reportID.uuidString)"
            guard seenCursors.insert(key).inserted else {
                throw SessionManagerError.unsupportedOperation(
                    "Report history pagination repeated a cursor and stopped."
                )
            }
            cursor = nextCursor
        }
        throw SessionManagerError.unsupportedOperation(
            "Report history export exceeded its 100-page safety limit."
        )
    }

    func sqliteMaintenanceAssessment() async throws -> SQLiteMaintenanceAssessment {
        if let reason = maintenanceUnavailableReason {
            throw SessionManagerError.unsupportedOperation(reason)
        }
        guard let store = liveStateStore else {
            throw SessionManagerError.unsupportedOperation(
                "The manager SQLite store is unavailable."
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try store.maintenanceAssessment()
        }.value
    }

    func requestPreview(_ operation: SessionOperation) async {
        if let mutationKind = nativeLifecycleMutationKind(
            for: operation,
            managerKeys: selection
        ), let reason = mutationKind.compatibilityBlockedReason(
            runtimeVersion: observedCodexRuntimeVersion, binding: latestCoordinatedSnapshot?.compatibilityBinding
        ) {
            errorMessage = reason
            logDiagnostic(
                level: .warning,
                category: .lifecycle,
                message: "Operation Preview blocked before request",
                metadata: [
                    "operation": operation.rawValue,
                    "reason": "runtime_outside_audited_allow_list",
                    "runtime_version": observedCodexRuntimeVersion ?? "unavailable",
                    "selection_count": String(selection.count),
                    "preview_persisted": "false",
                    "lifecycle_request_sent": "false",
                    "mutation_attempted": "false",
                ]
            )
            return
        }
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation Preview requested",
            metadata: [
                "operation": operation.rawValue,
                "selection_count": String(selection.count),
                "native_session_ids": selectedSessions.map(\.nativeID).joined(separator: ","),
            ]
        )
        do {
            let usesNativeBatch = selection.count > 1
                    && (
                        operation == .archive
                            || operation == .restore
                            || operation == .emptyTrash
                            || (
                                operation == .moveToTrash
                                    && selection.allSatisfy {
                                        reconciledStatesByKey[$0]?.status == .active
                                    }
                            )
                    )
                if usesNativeBatch {
                    guard let snapshot = latestCoordinatedSnapshot,
                          let checkpoint = reconciliationCheckpoint,
                          let coordinator = liveNativeBatchCoordinator else {
                        throw SessionManagerError.unsupportedOperation(
                            "Native batch Preview is unavailable for the current selection."
                        )
                    }
                    let preview = try await coordinator.prepare(
                        managerKeys: selection,
                        operation: operation,
                        snapshot: snapshot,
                        checkpoint: checkpoint
                    )
                    switch operation {
                    case .archive, .moveToTrash:
                        pendingNativeArchivePreview = preview
                    case .restore:
                        pendingNativeRestorePreview = preview
                    case .emptyTrash:
                        pendingNativeDeletePreview = preview
                    case .moveToArchive:
                        break
                    }
                    logPreviewPrepared(preview)
                    return
                }
                if operation == .archive {
                    await prepareNativeArchive()
                    return
                }
                if operation == .emptyTrash {
                    guard selection.count == 1,
                          let managerKey = selection.first,
                          let snapshot = latestCoordinatedSnapshot,
                          let checkpoint = reconciliationCheckpoint,
                          let coordinator = liveNativeDeleteCoordinator else {
                        throw SessionManagerError.unsupportedOperation(
                            "Permanent Delete Preview is unavailable for the current selection."
                        )
                    }
                    pendingNativeDeletePreview = try await coordinator.prepare(
                        managerKey: managerKey,
                        snapshot: snapshot,
                        checkpoint: checkpoint
                    )
                    if let pendingNativeDeletePreview {
                        logPreviewPrepared(pendingNativeDeletePreview)
                    }
                    return
                }
                if operation == .restore {
                    guard selection.count == 1,
                          let managerKey = selection.first,
                          let snapshot = latestCoordinatedSnapshot,
                          let checkpoint = reconciliationCheckpoint,
                          let coordinator = liveNativeRestoreCoordinator else {
                        throw SessionManagerError.unsupportedOperation(
                            "Native Restore Preview is unavailable for the current selection."
                        )
                    }
                    pendingNativeRestorePreview = try await coordinator.prepare(
                        managerKey: managerKey,
                        snapshot: snapshot,
                        checkpoint: checkpoint
                    )
                    if let pendingNativeRestorePreview {
                        logPreviewPrepared(pendingNativeRestorePreview)
                    }
                    return
                }
                if operation == .moveToTrash,
                   selection.count == 1,
                   let managerKey = selection.first,
                   reconciledStatesByKey[managerKey]?.status == .active {
                    guard let snapshot = latestCoordinatedSnapshot,
                          let checkpoint = reconciliationCheckpoint,
                          let coordinator = liveNativeArchiveCoordinator else {
                        throw SessionManagerError.unsupportedOperation(
                            "Active to Trash Preview is unavailable for the current selection."
                        )
                    }
                    pendingNativeArchivePreview = try await coordinator.prepare(
                        managerKey: managerKey,
                        snapshot: snapshot,
                        checkpoint: checkpoint,
                        operation: .moveToTrash
                    )
                    if let pendingNativeArchivePreview {
                        logPreviewPrepared(pendingNativeArchivePreview)
                    }
                    return
                }
                guard operation == .moveToTrash || operation == .moveToArchive,
                      let coordinator = liveManagerOnlyCoordinator,
                      let checkpoint = reconciliationCheckpoint else {
                    throw SessionManagerError.unsupportedOperation(
                        "This Codex Live operation is not available."
                    )
                }
                pendingPreview = try await coordinator.prepare(
                    operation: operation,
                    sessions: selectedSessions,
                    checkpoint: checkpoint
                )
                if let pendingPreview { logPreviewPrepared(pendingPreview) }
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Operation Preview failed",
                metadata: [
                    "operation": operation.rawValue,
                    "selection_count": String(selection.count),
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private var observedCodexRuntimeVersion: String? {
        reconciliationCheckpoint?.runtimeVersion
            ?? providerDiagnostics.first { $0.system == .codex }?.runtimeVersion
    }

    private func nativeLifecycleMutationKind(
        for operation: SessionOperation,
        managerKeys: Set<String>
    ) -> CodexLifecycleMutationKind? {
        guard !managerKeys.isEmpty else { return nil }
        switch operation {
        case .archive:
            return .archive
        case .restore:
            return .restore
        case .emptyTrash:
            return .permanentDelete
        case .moveToTrash:
            let rows = sessionRows.filter { managerKeys.contains($0.managerKey) }
            guard rows.count == managerKeys.count,
                  rows.allSatisfy({
                      reconciledStatesByKey[$0.managerKey]?.status == .active
                  }) else {
                return nil
            }
            return .moveToTrash
        case .moveToArchive:
            return nil
        }
    }

    private func prepareNativeArchive() async {
        do {
            guard selection.count == 1,
                  let managerKey = selection.first,
                  let state = reconciledStatesByKey[managerKey],
                  let snapshot = latestCoordinatedSnapshot,
                  let checkpoint = reconciliationCheckpoint,
                  let coordinator = liveNativeArchiveCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "Native Archive Preview is unavailable for the current selection."
                )
            }
            let diagnostic = providerDiagnostics.first { $0.system == .codex }
            let readiness = ArchiveMutationReadinessAssessor.assess(
                session: state.liveSession,
                selectionCount: selection.count,
                diagnostics: diagnostic,
                checkpoint: checkpoint,
                reconciliationStable: state.status == .active,
                executorAvailable: true
            )
            guard readiness.isExecutionEnabled else {
                throw SessionManagerError.unsupportedOperation(
                    readiness.primaryBlockedReason
                        ?? "Native Archive evidence is incomplete."
                )
            }

            let preview = try await coordinator.prepare(
                managerKey: managerKey,
                snapshot: snapshot,
                checkpoint: checkpoint
            )
            logPreviewPrepared(preview)
            pendingNativeArchivePreview = preview
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Archive Preview failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func executeNativeArchive(_ preview: OperationPreview) async {
        guard executingNativeArchivePreviewID == nil else { return }
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation execution started",
            metadata: [
                "operation": preview.operation.rawValue,
                "preview_id": preview.id.uuidString,
                "item_count": String(preview.items.count),
            ]
        )
        executingNativeArchivePreviewID = preview.id
        defer {
            if executingNativeArchivePreviewID == preview.id {
                executingNativeArchivePreviewID = nil
            }
        }
        do {
            guard let coordinator = liveNativeArchiveCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "Native Archive execution is unavailable."
                )
            }
            if preview.items.count > 1 {
                guard let batchCoordinator = liveNativeBatchCoordinator else {
                    throw SessionManagerError.unsupportedOperation(
                        "Native Archive batch execution is unavailable."
                    )
                }
                let batchReport = try await batchCoordinator.execute(
                    preview: preview,
                    confirmationToken: preview.confirmationToken
                )
                logOperationCompleted(
                    operation: batchReport.operation,
                    reportID: batchReport.id,
                    outcome: batchReport.outcome.rawValue,
                    itemCount: batchReport.items.count
                )
                pendingNativeArchivePreview = nil
                presentNativeBatchReport(batchReport)
            } else {
                let report = try await coordinator.execute(
                    preview: preview,
                    confirmationToken: preview.confirmationToken
                )
                logOperationCompleted(
                    operation: report.operation,
                    reportID: report.id,
                    outcome: report.outcome.rawValue,
                    itemCount: report.items.count
                )
                latestNativeArchiveReport = report
            }
            pendingNativeArchivePreview = nil
            selection.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Operation execution failed",
                metadata: [
                    "operation": preview.operation.rawValue,
                    "preview_id": preview.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func executeNativeRestore(_ preview: OperationPreview) async {
        guard executingNativeRestorePreviewID == nil else { return }
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation execution started",
            metadata: [
                "operation": preview.operation.rawValue,
                "preview_id": preview.id.uuidString,
                "item_count": String(preview.items.count),
            ]
        )
        executingNativeRestorePreviewID = preview.id
        defer {
            if executingNativeRestorePreviewID == preview.id {
                executingNativeRestorePreviewID = nil
            }
        }
        do {
            guard let coordinator = liveNativeRestoreCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "Native Restore execution is unavailable."
                )
            }
            if preview.items.count > 1 {
                guard let batchCoordinator = liveNativeBatchCoordinator else {
                    throw SessionManagerError.unsupportedOperation(
                        "Native Restore batch execution is unavailable."
                    )
                }
                let batchReport = try await batchCoordinator.execute(
                    preview: preview,
                    confirmationToken: preview.confirmationToken
                )
                logOperationCompleted(
                    operation: batchReport.operation,
                    reportID: batchReport.id,
                    outcome: batchReport.outcome.rawValue,
                    itemCount: batchReport.items.count
                )
                pendingNativeRestorePreview = nil
                presentNativeBatchReport(batchReport)
            } else {
                let report = try await coordinator.execute(
                    preview: preview,
                    confirmationToken: preview.confirmationToken
                )
                logOperationCompleted(
                    operation: .restore,
                    reportID: report.id,
                    outcome: report.outcome.rawValue,
                    itemCount: report.items.count
                )
                latestNativeRestoreReport = report
            }
            pendingNativeRestorePreview = nil
            selection.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Operation execution failed",
                metadata: [
                    "operation": preview.operation.rawValue,
                    "preview_id": preview.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func executeNativeDelete(
        _ preview: OperationPreview,
        confirmationToken: String
    ) async {
        guard executingNativeDeletePreviewID == nil else { return }
        guard case .idle = nativeDeleteDesktopCleanupState,
              ghostRepairBulkWorkflowMutationBlockedReason == nil,
              !isGhostRepairBulkPreparationInFlight,
              ghostRepairCleanupState == .idle else {
            errorMessage = "Finish or resolve the previous Desktop cleanup before starting another Delete. No new Delete request was sent."
            return
        }
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation execution started",
            metadata: [
                "operation": preview.operation.rawValue,
                "preview_id": preview.id.uuidString,
                "item_count": String(preview.items.count),
            ]
        )
        executingNativeDeletePreviewID = preview.id
        defer {
            if executingNativeDeletePreviewID == preview.id {
                executingNativeDeletePreviewID = nil
            }
        }
        do {
            guard let coordinator = liveNativeDeleteCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "Permanent Delete execution is unavailable."
                )
            }
            if preview.items.count > 1 {
                guard let batchCoordinator = liveNativeBatchCoordinator else {
                    throw SessionManagerError.unsupportedOperation(
                        "Permanent Delete batch execution is unavailable."
                    )
                }
                let batchReport = try await batchCoordinator.execute(
                    preview: preview,
                    confirmationToken: confirmationToken
                )
                logOperationCompleted(
                    operation: batchReport.operation,
                    reportID: batchReport.id,
                    outcome: batchReport.outcome.rawValue,
                    itemCount: batchReport.items.count
                )
                presentNativeBatchReport(batchReport)
            } else {
                let report = try await coordinator.execute(
                    preview: preview,
                    confirmationToken: confirmationToken
                )
                logOperationCompleted(
                    operation: .emptyTrash,
                    reportID: report.id,
                    outcome: report.outcome.rawValue,
                    itemCount: report.items.count
                )
                latestNativeDeleteReport = report
            }
            if let report = latestNativeDeleteReport {
                await continueFreshNativeDeleteCleanup(
                    report: report,
                    confirmedPreviewID: preview.id,
                    confirmedNativeSessionIDs: preview.items.map(\.nativeID)
                )
            }
            pendingNativeDeletePreview = nil
            selection.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Operation execution failed",
                metadata: [
                    "operation": preview.operation.rawValue,
                    "preview_id": preview.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    /// The successful return from the current official Delete owns consent.
    /// Reload/recovery never calls this method. Consumed reports cannot create
    /// another receipt or resend either destructive stage.
    func continueFreshNativeDeleteCleanup(
        report: NativeDeleteReport,
        confirmedPreviewID: UUID,
        confirmedNativeSessionIDs: [String]
    ) async {
        guard !report.recoveredAfterInterruption,
              report.id == latestNativeDeleteReport?.id,
              report.previewID == confirmedPreviewID,
              !confirmedNativeSessionIDs.isEmpty,
              Set(confirmedNativeSessionIDs).count == confirmedNativeSessionIDs.count,
              report.items.map(\.nativeSessionID).sorted()
                == confirmedNativeSessionIDs.sorted(),
              case .idle = nativeDeleteDesktopCleanupState,
              ghostRepairCleanupState == .idle,
              ghostRepairBulkWorkflowMutationBlockedReason == nil,
              !isGhostRepairBulkPreparationInFlight,
              report.items.contains(where: {
                $0.outcome == .success && $0.observedNativeState == .absent
              }),
              consumedNativeDeleteCleanupReports.insert(report.id).inserted else { return }

        nativeDeleteAutomaticCleanupReportID = report.id
        queueNativeDeleteDesktopCleanup(report: report)
        guard case .queued = nativeDeleteDesktopCleanupState else {
            nativeDeleteDesktopCleanupState = .unavailable(
                .init(canonicalDeleteReportID: report.id,
                      expectedNativeSessionIDs: report.items.filter {
                        $0.outcome == .success && $0.observedNativeState == .absent
                      }.map(\.nativeSessionID).sorted(),
                      nativeDeleteItemCount: report.items.count),
                message: errorMessage ?? "Desktop cleanup could not start. The official Delete result is retained."
            )
            return
        }
        await prepareGhostRepairBulkInventory()
        if nativeDeleteDesktopAbsenceVerifiedReportID == report.id { return }
        guard case let .inventoryReady(context, handoff) = nativeDeleteDesktopCleanupState,
              context.canonicalDeleteReportID == report.id,
              let inventory = ghostRepairBulkInventory,
              ghostRepairBulkSelection == Set(handoff.nativeSessionIDs) else { return }

        // The original Delete confirmation includes Desktop cleanup. Shutdown
        // was required there and is independently checked again by Final Review.
        await confirmGhostCleanup(
            selectedIDs: Set(handoff.nativeSessionIDs),
            inventoryDigest: inventory.inventoryDigest
        )
        await continueGhostCleanupAfterShutdown()
    }

    func nativeDeleteDesktopCleanupVerified(reportID: UUID) -> Bool {
        if nativeDeleteDesktopAbsenceVerifiedReportID == reportID { return true }
        guard case let .status(context, .verified(_, _, _)) = nativeDeleteDesktopCleanupState
        else { return false }
        return context.canonicalDeleteReportID == reportID
    }

    func nativeDeleteDesktopCleanupDetail(reportID: UUID) -> String {
        guard nativeDeleteDesktopCleanupContext?.canonicalDeleteReportID == reportID else {
            return "Desktop cleanup is not verified. The canonical Delete result is retained; no Delete request will be resent."
        }
        let stopped: String
        if case let .stopped(message) = ghostRepairCleanupState {
            stopped = " " + message
        } else {
            stopped = ""
        }
        return (nativeDeleteDesktopCleanupSummary ?? "Desktop cleanup is not verified.") + stopped
    }

    private func presentNativeBatchReport(_ report: NativeBatchReport) {
        switch report.operation {
        case .archive, .moveToTrash:
            latestNativeArchiveReport = NativeArchiveReport(
                id: report.id,
                previewID: report.previewID,
                operation: report.operation,
                outcome: report.outcome,
                completedAt: report.completedAt,
                items: report.items,
                recoveredAfterInterruption: report.recoveredAfterInterruption
            )
        case .restore:
            latestNativeRestoreReport = NativeRestoreReport(
                id: report.id,
                previewID: report.previewID,
                outcome: report.outcome,
                completedAt: report.completedAt,
                items: report.items,
                recoveredAfterInterruption: report.recoveredAfterInterruption
            )
        case .emptyTrash:
            latestNativeDeleteReport = NativeDeleteReport(
                id: report.id,
                previewID: report.previewID,
                outcome: report.outcome,
                completedAt: report.completedAt,
                items: report.items,
                recoveredAfterInterruption: report.recoveredAfterInterruption
            )
        case .moveToArchive:
            break
        }
    }

    func conflictResolutionBlockedReason(for session: SessionPresentation) -> String? {
        guard session.displayState == .conflict || session.displayState == .externallyMissing else {
            return "This session does not have a reviewable reconciliation conflict."
        }
        guard let checkpoint = reconciliationCheckpoint, checkpoint.inventoryComplete else {
            return "A complete provider inventory is required."
        }
        guard let state = reconciledStatesByKey[session.managerKey] else {
            return "The frozen reconciliation evidence is unavailable."
        }
        guard state.trashMembership != nil else {
            return "No manager Trash membership exists to resolve."
        }
        return nil
    }

    func reviewConflictResolution(for session: SessionPresentation) async {
        do {
            if let reason = conflictResolutionBlockedReason(for: session) {
                throw SessionManagerError.unsupportedOperation(reason)
            }
            guard let state = reconciledStatesByKey[session.managerKey],
                  let checkpoint = reconciliationCheckpoint else {
                throw SessionManagerError.sessionNotFound(session.managerKey)
            }
            guard let conflictCoordinator = liveConflictResolutionCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "The conflict resolution coordinator is unavailable."
                )
            }
            let proposal: ConflictResolutionPreview
            let operationPreview: OperationPreview?
            if state.status == .nativeActiveTrashConflict {
                let exactReadback = await liveProvider.exactReadback(
                    nativeSessionID: session.nativeID
                )
                proposal = try ConflictResolutionPlanner.preview(
                    for: state,
                    checkpoint: checkpoint,
                    exactReadback: exactReadback
                )
                operationPreview = try await conflictCoordinator.prepareAcceptNativeRestore(
                    state: state,
                    checkpoint: checkpoint
                )
            } else {
                let prepared = try await conflictCoordinator
                    .prepareAcknowledgeExternalDeletion(
                        state: state,
                        checkpoint: checkpoint
                    )
                proposal = try ConflictResolutionPlanner.preview(
                    for: state,
                    checkpoint: checkpoint,
                    externalDeletionEvidence: prepared.evidence
                )
                operationPreview = prepared.operationPreview
            }
            pendingConflictResolutionPreview = ConflictResolutionExecutionPreview(
                proposal: proposal,
                operationPreview: operationPreview
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func executeConflictResolution(
        _ preview: ConflictResolutionExecutionPreview
    ) async {
        guard executingConflictResolutionPreviewID == nil else { return }
        guard let operationPreview = preview.operationPreview else {
            errorMessage = SessionManagerError.unsupportedOperation(
                "This conflict resolution option is not executable."
            ).localizedDescription
            return
        }
        executingConflictResolutionPreviewID = operationPreview.id
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Conflict resolution started",
            metadata: [
                "preview_id": operationPreview.id.uuidString,
                "item_count": String(operationPreview.items.count),
            ]
        )
        defer {
            if executingConflictResolutionPreviewID == operationPreview.id {
                executingConflictResolutionPreviewID = nil
            }
        }
        do {
            guard let coordinator = liveConflictResolutionCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "The Live conflict resolution coordinator is unavailable."
                )
            }
            let isExternalDeletion = preview.proposal.observedStatus == .externallyMissing
            let persisted: PersistentOperationReport
            if isExternalDeletion {
                persisted = try await coordinator.executeAcknowledgeExternalDeletion(
                    previewID: operationPreview.id,
                    confirmationToken: operationPreview.confirmationToken
                )
            } else {
                guard let snapshotCoordinator = liveSnapshotCoordinator else {
                    throw SessionManagerError.unsupportedOperation(
                        "The Live snapshot coordinator is unavailable."
                    )
                }
                // Re-observe the complete official inventory immediately before
                // the SQLite transaction. A changed native state changes the hash;
                // the frozen Preview is then rejected without removing membership.
                let freshSnapshot = try await snapshotCoordinator.refresh()
                guard freshSnapshot.diagnostics.inventoryComplete,
                      freshSnapshot.diagnostics.connectionState != .unavailable,
                      freshSnapshot.checkpointDisposition != .skippedIncompleteInventory,
                      freshSnapshot.checkpointDisposition != .skippedExecutingRecovery else {
                    throw SessionManagerError.unsupportedOperation(
                        "Fresh official inventory readback was incomplete. Trash membership was not changed."
                    )
                }
                persisted = try await coordinator.executeAcceptNativeRestore(
                    previewID: operationPreview.id,
                    confirmationToken: operationPreview.confirmationToken
                )
            }
            let report = OperationReport(
                id: persisted.id,
                previewID: persisted.previewID,
                provider: persisted.provider,
                operation: isExternalDeletion ? .emptyTrash : .restore,
                completedAt: persisted.completedAt,
                items: operationPreview.items.map { item in
                    OperationResultItem(
                        managerKey: item.managerKey,
                        nativeID: item.nativeID,
                        title: item.title,
                        projectName: item.projectName,
                        workingDirectory: item.workingDirectory,
                        beforeCollection: .trash,
                        observedFinalCollection: isExternalDeletion ? .deleted : .active,
                        success: true,
                        note: isExternalDeletion
                            ? "Acknowledged verified external deletion, removed the manager Trash membership, and created a Deleted record. No Codex lifecycle request was sent."
                            : "Accepted Codex Active state and removed only the manager Trash membership. No Codex lifecycle request was sent."
                    )
                }
            )
            logOperationCompleted(
                operation: isExternalDeletion ? .emptyTrash : .restore,
                reportID: report.id,
                outcome: report.failureCount == 0 ? "success" : "failure",
                itemCount: report.items.count
            )
            queuedOperationReport = report
            pendingConflictResolutionPreview = nil
            selection.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Conflict resolution failed",
                metadata: [
                    "preview_id": operationPreview.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func prepareReapplyTrashIntent(
        from preview: ConflictResolutionExecutionPreview
    ) async {
        do {
            guard pendingConflictResolutionPreview?.id == preview.id,
                  preview.proposal.observedStatus == .nativeActiveTrashConflict,
                  preview.proposal.options.contains(where: {
                      $0.action == .reapplyTrashIntent
                          && $0.readiness == .readyToApply
                  }),
                  let state = reconciledStatesByKey[preview.proposal.managerKey],
                  let snapshot = latestCoordinatedSnapshot,
                  let checkpoint = reconciliationCheckpoint,
                  let coordinator = liveNativeArchiveCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "Reapply Trash Intent is unavailable for the current conflict evidence."
                )
            }
            let archivePreview = try await coordinator.prepareReapplyTrashIntent(
                state: state,
                snapshot: snapshot,
                checkpoint: checkpoint
            )
            logPreviewPrepared(archivePreview)
            // Let the conflict sheet finish dismissing before presenting the
            // native Archive confirmation sheet. Publishing both bindings in
            // one render pass can leave the first sheet visibly stuck.
            queuedNativeArchivePreview = archivePreview
            pendingConflictResolutionPreview = nil
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Reapply Trash Intent Preview failed",
                metadata: [
                    "manager_key": preview.proposal.managerKey,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func canRequestPreview(_ operation: SessionOperation) -> Bool {
        blockedReason(for: operation) == nil
    }

    func blockedReason(
        for operation: SessionOperation,
        managerKeys: Set<String>? = nil
    ) -> String? {
        let keys = managerKeys ?? selection
        let operationRows = sessionRows.filter { keys.contains($0.id) }
        guard !operationRows.isEmpty else { return "Select at least one session." }
        guard !operationRows.contains(where: { $0.displayState == .deleted }) else {
            return "Deleted records cannot be archived, restored or deleted again. Only list removal is available."
        }
        if operation == .emptyTrash {
            guard let checkpoint = reconciliationCheckpoint,
                  checkpoint.inventoryComplete else {
                return "Refresh a complete Codex inventory before Permanent Delete."
            }
            if let reason = CodexLifecycleMutationKind.permanentDelete
                .compatibilityBlockedReason(runtimeVersion: checkpoint.runtimeVersion, binding: checkpoint.compatibilityBinding) {
                return reason
            }
            guard liveNativeDeleteCoordinator != nil,
                  keys.count == 1 || liveNativeBatchCoordinator != nil else {
                return "The guarded Permanent Delete executor is unavailable in this App build."
            }
            for row in operationRows {
                guard let state = reconciledStatesByKey[row.managerKey],
                      let session = state.liveSession,
                      state.status == .trash,
                      session.nativeState == .archived else {
                    return "Permanent Delete is available only for stable manager Trash sessions. Move Archive to Trash first."
                }
                guard session.descendantCountKnown, session.descendantCount == 0 else {
                    return "Permanent Delete requires verified zero descendants for every selected session."
                }
                guard !session.protection.blocksDeleteAttempt else {
                    return "Permanent Delete is blocked by positive pinned/running/current protection or unavailable pin/descendant evidence."
                }
            }
            return nil
        }
        if operation == .restore {
            guard liveStateStore != nil else {
                return "The manager SQLite store is unavailable. Refresh Codex Live."
            }
            guard liveNativeRestoreCoordinator != nil,
                  keys.count == 1 || liveNativeBatchCoordinator != nil else {
                return "The guarded Native Restore executor is unavailable in this App build."
            }
            guard let checkpoint = reconciliationCheckpoint else {
                return "No authoritative Codex inventory checkpoint exists yet. Refresh Codex Live."
            }
            guard checkpoint.inventoryComplete else {
                return "The latest Codex inventory is incomplete. Refresh and inspect provider diagnostics."
            }
            if let reason = CodexLifecycleMutationKind.restore
                .compatibilityBlockedReason(runtimeVersion: checkpoint.runtimeVersion, binding: checkpoint.compatibilityBinding) {
                return reason
            }
            let statuses = Set(operationRows.compactMap {
                reconciledStatesByKey[$0.managerKey]?.status
            })
            guard statuses.count == 1,
                  let status = statuses.first,
                  status == .archive || status == .trash else {
                return "Select only Archive sessions or only Trash sessions for one Restore batch; do not mix them."
            }
            for row in operationRows {
                guard let state = reconciledStatesByKey[row.managerKey],
                      let session = state.liveSession,
                      session.nativeState == .archived else {
                    return "Native Restore is available only for stable Archive or Trash sessions."
                }
            }
            return nil
        }
        if operation == .archive {
            guard let checkpoint = reconciliationCheckpoint,
                  checkpoint.inventoryComplete,
                  liveNativeArchiveCoordinator != nil,
                  keys.count == 1 || liveNativeBatchCoordinator != nil else {
                return "Refresh a complete Codex inventory before native Archive."
            }
            if let reason = CodexLifecycleMutationKind.archive
                .compatibilityBlockedReason(runtimeVersion: checkpoint.runtimeVersion, binding: checkpoint.compatibilityBinding) {
                return reason
            }
            for row in operationRows {
                guard let state = reconciledStatesByKey[row.managerKey],
                      let session = state.liveSession,
                      state.status == .active,
                      session.nativeState == .active,
                      session.descendantCountKnown,
                      session.descendantCount == 0,
                      !session.protection.blocksArchiveAttempt else {
                    return "Archive requires stable Active sessions with verified clear protection and zero descendants."
                }
            }
            return nil
        }
        guard operation == .moveToTrash || operation == .moveToArchive else {
            return "This Codex Live operation does not have an enabled execution path."
        }
        guard liveStateStore != nil,
              liveManagerOnlyCoordinator != nil,
              let checkpoint = reconciliationCheckpoint,
              checkpoint.inventoryComplete else {
            return "Refresh a complete Codex inventory before changing manager classification."
        }
        if operation == .moveToTrash,
           operationRows.allSatisfy({ reconciledStatesByKey[$0.managerKey]?.status == .active }) {
            if let reason = CodexLifecycleMutationKind.moveToTrash
                .compatibilityBlockedReason(runtimeVersion: checkpoint.runtimeVersion, binding: checkpoint.compatibilityBinding) {
                return reason
            }
            guard keys.count == 1 || liveNativeBatchCoordinator != nil else {
                return "The guarded native batch executor is unavailable."
            }
            for row in operationRows {
                guard let state = reconciledStatesByKey[row.managerKey],
                      let session = state.liveSession,
                      session.nativeState == .active,
                      session.descendantCountKnown,
                      session.descendantCount == 0,
                      !session.protection.blocksArchiveAttempt else {
                    return "Active to Trash requires stable Active sessions with verified clear Archive protection and zero descendants."
                }
            }
            return nil
        }
        let requiredState: ReconciliationStatus = operation == .moveToTrash ? .archive : .trash
        for row in operationRows {
            guard let state = reconciledStatesByKey[row.managerKey],
                  let session = state.liveSession,
                  state.status == requiredState,
                  session.nativeState == .archived else {
                return "\(operation.label) is available only for stable \(requiredState.rawValue) sessions."
            }
            if operation == .moveToTrash {
                guard checkpoint.protectionComplete,
                      !session.protection.blocksLifecycleMutation else {
                    return "Session \(session.nativeID) lacks complete, clear lifecycle protection."
                }
            }
        }
        return nil
    }

    func execute(
        _ preview: OperationPreview,
        typedConfirmationToken: String? = nil
    ) async {
        guard executingOperationPreviewID == nil else { return }
        logDiagnostic(
            level: .info,
            category: .lifecycle,
            message: "Operation execution started",
            metadata: [
                "operation": preview.operation.rawValue,
                "preview_id": preview.id.uuidString,
                "item_count": String(preview.items.count),
            ]
        )
        executingOperationPreviewID = preview.id
        defer {
            if executingOperationPreviewID == preview.id {
                executingOperationPreviewID = nil
            }
        }

        do {
            let executionToken = preview.operation.requiresTypedConfirmation
                ? typedConfirmationToken ?? ""
                : preview.confirmationToken
            guard preview.operation == .moveToTrash
                    || preview.operation == .moveToArchive,
                  let coordinator = liveManagerOnlyCoordinator,
                  let snapshotCoordinator = liveSnapshotCoordinator else {
                throw SessionManagerError.unsupportedOperation(
                    "This Codex Live operation is not available."
                )
            }
            // A fresh official inventory read is the pre-commit readback.
            // If native state changed, it advances to a different hash and
            // the SQLite transaction below rejects the frozen Preview.
            let freshSnapshot = try await snapshotCoordinator.refresh()
            guard freshSnapshot.diagnostics.inventoryComplete,
                  freshSnapshot.diagnostics.connectionState != .unavailable,
                  freshSnapshot.checkpointDisposition != .skippedIncompleteInventory,
                  freshSnapshot.checkpointDisposition != .skippedExecutingRecovery else {
                throw SessionManagerError.unsupportedOperation(
                    "Fresh official inventory readback was incomplete. No manager classification was changed."
                )
            }
            let persisted = try await coordinator.execute(
                previewID: preview.id,
                confirmationToken: executionToken,
                freshSnapshot: freshSnapshot.snapshot
            )
            let report = OperationReport(
                id: persisted.id,
                previewID: persisted.previewID,
                provider: persisted.provider,
                operation: preview.operation,
                completedAt: persisted.completedAt,
                items: preview.items.map { item in
                    OperationResultItem(
                        managerKey: item.managerKey,
                        nativeID: item.nativeID,
                        title: item.title,
                        projectName: item.projectName,
                        workingDirectory: item.workingDirectory,
                        beforeCollection: item.beforeCollection,
                        observedFinalCollection: preview.operation.targetCollection(
                            from: item.beforeCollection
                        ),
                        success: true,
                        note: "Manager SQLite classification committed atomically; Codex remains Archived."
                    )
                }
            )
            logOperationCompleted(
                operation: preview.operation,
                reportID: report.id,
                outcome: report.failureCount == 0 ? "success" : "failure",
                itemCount: report.items.count
            )
            // Wait until SwiftUI has fully dismissed the Preview sheet before
            // presenting the Report. Publishing both sheet bindings together
            // can leave the consumed Preview visibly stuck on screen.
            queuedOperationReport = report
            pendingPreview = nil
            selection.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            logDiagnostic(
                level: .error,
                category: .lifecycle,
                message: "Operation execution failed",
                metadata: [
                    "operation": preview.operation.rawValue,
                    "preview_id": preview.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func presentQueuedOperationReport() {
        guard let report = queuedOperationReport else { return }
        queuedOperationReport = nil
        latestReport = report
    }

    func presentQueuedConflictFollowUp() {
        if let archivePreview = queuedNativeArchivePreview {
            queuedNativeArchivePreview = nil
            pendingNativeArchivePreview = archivePreview
            return
        }
        presentQueuedOperationReport()
    }
}
