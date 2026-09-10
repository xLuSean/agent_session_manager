import Foundation

struct CodexGhostRepairBulkProductionExecutionCapabilities:
    Equatable,
    Sendable
{
    let contractOnly = true
    let maximumTargetCount = CodexGhostRepairBulkPreview.maximumSelectedItems
    let requiresFiveDatabaseHandleCounts = true
    let requiresFreshProcessEvidence = true
    let requiresOperationBoundVerifiedBackup = true
    let requiresWholeBatchConfirmationReceipt = true
    let managerClaimAvailable = false
    let filesystemMutationAuthority = false
    let repairMutationAuthority = false
    let appWiringAvailable = false
    let acceptsLiveCodexRoot = false
}

private struct CodexGhostRepairBulkMaintenancePayload:
    Codable,
    Hashable
{
    let runtimeVersion: String
    let executionGate: CodexGhostRepairExecutionGate
    let sourceFingerprintHash: String
    let authorityDigest: String
    let observedAtMilliseconds: Int64
}

struct CodexGhostRepairBulkMaintenanceEvidence:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let runtimeVersion: String
    let executionGate: CodexGhostRepairExecutionGate
    let sourceFingerprintHash: String
    let authorityDigest: String
    let observedAtMilliseconds: Int64
    let evidenceDigest: String

    var allFiveDatabaseHandleCountsAreZero: Bool {
        executionGate.desktopOpenHandleCount == 0
            && executionGate.summariesOpenHandleCount == 0
            && executionGate.historyOpenHandleCount == 0
            && executionGate.stateOpenHandleCount == 0
            && executionGate.threadHistoryOpenHandleCount == 0
    }

    var pathRedacted: Bool { true }
    var processInspectionComplete: Bool {
        executionGate.desktopProcessEvidence != nil
    }
    var handleOwnerInspectionComplete: Bool {
        executionGate.openHandleOwnerEvidence != nil
    }
    var repairMutationAuthority: Bool { false }

    init(
        runtimeVersion: String,
        executionGate: CodexGhostRepairExecutionGate,
        sourceFingerprintHash: String,
        authorityDigest: String,
        observedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairBulkMaintenancePayload(
            runtimeVersion: runtimeVersion,
            executionGate: executionGate,
            sourceFingerprintHash: sourceFingerprintHash,
            authorityDigest: authorityDigest,
            observedAtMilliseconds: observedAtMilliseconds
        )
        self.runtimeVersion = runtimeVersion
        self.executionGate = executionGate
        self.sourceFingerprintHash = sourceFingerprintHash
        self.authorityDigest = authorityDigest
        self.observedAtMilliseconds = observedAtMilliseconds
        evidenceDigest = try CodexGhostRepairHasher.hash(payload)
        try validate()
    }

    func validate() throws {
        let payload = CodexGhostRepairBulkMaintenancePayload(
            runtimeVersion: runtimeVersion,
            executionGate: executionGate,
            sourceFingerprintHash: sourceFingerprintHash,
            authorityDigest: authorityDigest,
            observedAtMilliseconds: observedAtMilliseconds
        )
        guard CodexGhostRepairSnapshotSourceLayout.supports(
                  runtimeVersion: runtimeVersion
              ),
              executionGate.codexFullyExited,
              executionGate.capacitySufficient,
              allFiveDatabaseHandleCountsAreZero,
              processInspectionComplete,
              handleOwnerInspectionComplete,
              executionGate.openHandleOwnerEvidence?.isEmpty == true,
              Self.isSHA256(sourceFingerprintHash),
              Self.isSHA256(authorityDigest),
              observedAtMilliseconds >= 0,
              try CodexGhostRepairHasher.hash(payload) == evidenceDigest,
              pathRedacted,
              !repairMutationAuthority else {
            throw CodexGhostRepairError.executionGateBlocked
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

struct CodexGhostRepairBulkExecutionBackupFile:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let fileName: String
    let present: Bool
    let byteCount: UInt64?
    let contentHash: String?
}

private struct CodexGhostRepairBulkExecutionBackupPayload:
    Codable,
    Hashable
{
    let operationID: UUID
    let planDigest: String
    let selectedThreadIDs: [String]
    let sourceFingerprintHash: String
    let files: [CodexGhostRepairBulkExecutionBackupFile]
    let capturedAtMilliseconds: Int64
}

struct CodexGhostRepairBulkExecutionBackupReceipt:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let planDigest: String
    let selectedThreadIDs: [String]
    let sourceFingerprintHash: String
    let files: [CodexGhostRepairBulkExecutionBackupFile]
    let capturedAtMilliseconds: Int64
    let receiptDigest: String

    var readbackVerified: Bool { true }
    var operationBound: Bool { true }
    var restoreAuthority: Bool { false }
    var cleanupAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }

    init(
        operationID: UUID,
        planDigest: String,
        selectedThreadIDs: [String],
        sourceFingerprintHash: String,
        files: [CodexGhostRepairBulkExecutionBackupFile],
        capturedAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairBulkExecutionBackupPayload(
            operationID: operationID,
            planDigest: planDigest,
            selectedThreadIDs: selectedThreadIDs,
            sourceFingerprintHash: sourceFingerprintHash,
            files: files,
            capturedAtMilliseconds: capturedAtMilliseconds
        )
        self.operationID = operationID
        self.planDigest = planDigest
        self.selectedThreadIDs = selectedThreadIDs
        self.sourceFingerprintHash = sourceFingerprintHash
        self.files = files
        self.capturedAtMilliseconds = capturedAtMilliseconds
        receiptDigest = try CodexGhostRepairHasher.hash(payload)
        try validate()
    }

    func validate() throws {
        let payload = CodexGhostRepairBulkExecutionBackupPayload(
            operationID: operationID,
            planDigest: planDigest,
            selectedThreadIDs: selectedThreadIDs,
            sourceFingerprintHash: sourceFingerprintHash,
            files: files,
            capturedAtMilliseconds: capturedAtMilliseconds
        )
        let expectedNames = CodexGhostRepairSnapshotCanonicalFile.allCases
            .map(\.rawValue)
        let requiredNames = Set(
            CodexGhostRepairSnapshotCanonicalFile.allCases
                .filter(\.isRequiredDatabase)
                .map(\.rawValue)
        )
        guard Self.isSHA256(planDigest),
              (1...CodexGhostRepairBulkPreview.maximumSelectedItems)
                .contains(selectedThreadIDs.count),
              selectedThreadIDs == selectedThreadIDs.sorted(),
              Set(selectedThreadIDs).count == selectedThreadIDs.count,
              Self.isSHA256(sourceFingerprintHash),
              files.map(\.fileName) == expectedNames,
              files.allSatisfy({ file in
                  if file.present {
                      return (file.byteCount ?? 0) > 0
                          && file.contentHash.map(Self.isSHA256) == true
                  }
                  return file.byteCount == nil && file.contentHash == nil
              }),
              requiredNames.isSubset(of: Set(
                  files.filter(\.present).map(\.fileName)
              )),
              capturedAtMilliseconds >= 0,
              try CodexGhostRepairHasher.hash(payload) == receiptDigest,
              readbackVerified,
              operationBound,
              !restoreAuthority,
              !cleanupAuthority,
              !repairMutationAuthority else {
            throw CodexGhostRepairError.backupFailed(
                "Bulk execution backup receipt is incomplete or drifted."
            )
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}

private struct CodexGhostRepairBulkProductionExecutionDraftPayload:
    Codable,
    Hashable
{
    let plan: CodexGhostRepairBulkExecutionPlan
    let operationID: UUID
    let planDigest: String
    let confirmationReceiptID: UUID
    let confirmationReceiptDigest: String
    let selectedItems: [CodexGhostRepairBulkProductionSelectedItem]
    let blockedOutsideBatchCount: Int
    let preBackupMaintenanceDigest: String
    let postBackupMaintenanceDigest: String
    let backup: CodexGhostRepairBulkExecutionBackupReceipt
    let backupReceiptDigest: String
    let preparedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
}

struct CodexGhostRepairBulkProductionSelectedItem:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let threadID: String
    let category: CodexGhostRepairCategory
}

struct CodexGhostRepairBulkProductionExecutionDraft:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let plan: CodexGhostRepairBulkExecutionPlan
    let operationID: UUID
    let planDigest: String
    let confirmationReceiptID: UUID
    let confirmationReceiptDigest: String
    let selectedItems: [CodexGhostRepairBulkProductionSelectedItem]
    let blockedOutsideBatchCount: Int
    let preBackupMaintenanceDigest: String
    let postBackupMaintenanceDigest: String
    let backup: CodexGhostRepairBulkExecutionBackupReceipt
    let backupReceiptDigest: String
    let preparedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let draftDigest: String

    var selectedThreadIDs: [String] { selectedItems.map(\.threadID) }
    var ordinaryCount: Int {
        selectedItems.count { $0.category == .ordinary }
    }
    var automationCount: Int {
        selectedItems.count { $0.category == .automation }
    }

    var allOrNothing: Bool { true }
    var silentSelectionShrinkAllowed: Bool { false }
    var managerClaimCreated: Bool { false }
    var executionAvailable: Bool { false }
    var repairMutationAuthority: Bool { false }
    var automaticRetryAllowed: Bool { false }

    static func prepare(
        plan: CodexGhostRepairBulkExecutionPlan,
        preBackupMaintenance: CodexGhostRepairBulkMaintenanceEvidence,
        backup: CodexGhostRepairBulkExecutionBackupReceipt,
        postBackupMaintenance: CodexGhostRepairBulkMaintenanceEvidence,
        preparedAtMilliseconds: Int64
    ) throws -> Self {
        try plan.validateDigest()
        try preBackupMaintenance.validate()
        try backup.validate()
        try postBackupMaintenance.validate()
        guard preBackupMaintenance.observedAtMilliseconds
                <= backup.capturedAtMilliseconds,
              backup.capturedAtMilliseconds
                <= postBackupMaintenance.observedAtMilliseconds,
              preparedAtMilliseconds
                >= postBackupMaintenance.observedAtMilliseconds,
              preparedAtMilliseconds < plan.expiresAtMilliseconds,
              preBackupMaintenance.sourceFingerprintHash
                == postBackupMaintenance.sourceFingerprintHash,
              preBackupMaintenance.authorityDigest
                == postBackupMaintenance.authorityDigest,
              backup.operationID == plan.operationID,
              backup.planDigest == plan.planDigest,
              backup.selectedThreadIDs == plan.selectedThreadIDs,
              backup.sourceFingerprintHash
                == postBackupMaintenance.sourceFingerprintHash else {
            throw CodexGhostRepairError.authorityDrift
        }
        let payload = CodexGhostRepairBulkProductionExecutionDraftPayload(
            plan: plan,
            operationID: plan.operationID,
            planDigest: plan.planDigest,
            confirmationReceiptID: plan.confirmationReceiptID,
            confirmationReceiptDigest: plan.confirmationReceiptDigest,
            selectedItems: plan.selectedItems.map {
                CodexGhostRepairBulkProductionSelectedItem(
                    threadID: $0.threadID,
                    category: $0.category
                )
            },
            blockedOutsideBatchCount: plan.blockedOutsideBatchCount,
            preBackupMaintenanceDigest: preBackupMaintenance.evidenceDigest,
            postBackupMaintenanceDigest: postBackupMaintenance.evidenceDigest,
            backup: backup,
            backupReceiptDigest: backup.receiptDigest,
            preparedAtMilliseconds: preparedAtMilliseconds,
            expiresAtMilliseconds: plan.expiresAtMilliseconds
        )
        return try Self(payload: payload)
    }

    private init(
        payload: CodexGhostRepairBulkProductionExecutionDraftPayload
    ) throws {
        plan = payload.plan
        operationID = payload.operationID
        planDigest = payload.planDigest
        confirmationReceiptID = payload.confirmationReceiptID
        confirmationReceiptDigest = payload.confirmationReceiptDigest
        selectedItems = payload.selectedItems
        blockedOutsideBatchCount = payload.blockedOutsideBatchCount
        preBackupMaintenanceDigest = payload.preBackupMaintenanceDigest
        postBackupMaintenanceDigest = payload.postBackupMaintenanceDigest
        backup = payload.backup
        backupReceiptDigest = payload.backupReceiptDigest
        preparedAtMilliseconds = payload.preparedAtMilliseconds
        expiresAtMilliseconds = payload.expiresAtMilliseconds
        draftDigest = try CodexGhostRepairHasher.hash(payload)
        try validate()
    }

    func validate() throws {
        let payload = CodexGhostRepairBulkProductionExecutionDraftPayload(
            plan: plan,
            operationID: operationID,
            planDigest: planDigest,
            confirmationReceiptID: confirmationReceiptID,
            confirmationReceiptDigest: confirmationReceiptDigest,
            selectedItems: selectedItems,
            blockedOutsideBatchCount: blockedOutsideBatchCount,
            preBackupMaintenanceDigest: preBackupMaintenanceDigest,
            postBackupMaintenanceDigest: postBackupMaintenanceDigest,
            backup: backup,
            backupReceiptDigest: backupReceiptDigest,
            preparedAtMilliseconds: preparedAtMilliseconds,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
        try plan.validateDigest()
        try backup.validate()
        guard plan.operationID == operationID,
              plan.planDigest == planDigest,
              plan.confirmationReceiptID == confirmationReceiptID,
              plan.confirmationReceiptDigest == confirmationReceiptDigest,
              plan.selectedItems.map({
                  CodexGhostRepairBulkProductionSelectedItem(
                      threadID: $0.threadID,
                      category: $0.category
                  )
              }) == selectedItems,
              plan.blockedOutsideBatchCount == blockedOutsideBatchCount,
              backup.operationID == operationID,
              backup.planDigest == planDigest,
              backup.selectedThreadIDs == selectedThreadIDs,
              backup.receiptDigest == backupReceiptDigest,
              (1...CodexGhostRepairBulkPreview.maximumSelectedItems)
                .contains(selectedThreadIDs.count),
              selectedThreadIDs == selectedThreadIDs.sorted(),
              Set(selectedThreadIDs).count == selectedThreadIDs.count,
              ordinaryCount + automationCount == selectedItems.count,
              blockedOutsideBatchCount >= 0,
              preparedAtMilliseconds < expiresAtMilliseconds,
              try CodexGhostRepairHasher.hash(payload) == draftDigest,
              allOrNothing,
              !silentSelectionShrinkAllowed,
              !managerClaimCreated,
              !executionAvailable,
              !repairMutationAuthority,
              !automaticRetryAllowed else {
            throw CodexGhostRepairError.invalidPlan(
                "Bulk production execution draft integrity is invalid."
            )
        }
    }
}
