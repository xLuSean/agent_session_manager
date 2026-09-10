import CryptoKit
import Darwin
import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH

enum CodexGhostRepairCategoryAProductionRecipeFault: Sendable {
    case none
    case afterAuthorization
    case afterSnapshot
    case afterManagerClaim
    case disposableBusy
    case disposableAfterClaim
    case disposableAfterCommit
    case afterDisposableReport
}

struct CodexGhostRepairCategoryAProductionRecipeCapabilities:
    Equatable,
    Sendable
{
    let markerProtectedTestMirrorsOnly = true
    let operationBoundExecutionSnapshot = true
    let freshAuthorityReplacesPreviewCounters = true
    let managerClaimBeforeMutation = true
    let desktopOnlyWriteDatabaseCount = 1
    let readbackOnlyDatabaseCount = 4
    let recoveryReplaysMutation = false
    let acceptsLiveCodexRoot = false
    let appWiringAvailable = false
    let packagedRepairAuthority = false
}

struct CodexGhostRepairCategoryAExecutionSnapshotFile:
    Codable,
    Hashable,
    Sendable
{
    let fileName: String
    let present: Bool
    let device: UInt64?
    let inode: UInt64?
    let mode: UInt16?
    let byteCount: UInt64?
    let modifiedAtNanoseconds: Int64?
    let contentHash: String?
}

private struct CodexGhostRepairCategoryAExecutionSnapshotPayload:
    Codable,
    Hashable
{
    let operationID: UUID
    let draftDigest: String
    let targetThreadIDs: [String]
    let freshEvidenceDigest: String
    let beforeState: CodexGhostRepairCategoryADisposableState
    let files: [CodexGhostRepairCategoryAExecutionSnapshotFile]
    let createdAtMilliseconds: Int64
}

struct CodexGhostRepairCategoryAOperationBoundExecutionSnapshot:
    Codable,
    Hashable,
    Sendable
{
    let operationID: UUID
    let draftDigest: String
    let targetThreadIDs: [String]
    let freshEvidenceDigest: String
    let beforeState: CodexGhostRepairCategoryADisposableState
    let files: [CodexGhostRepairCategoryAExecutionSnapshotFile]
    let createdAtMilliseconds: Int64
    let manifestHash: String

    var restoreAuthority: Bool { false }
    var cleanupAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }

    fileprivate init(
        operationID: UUID,
        draftDigest: String,
        targetThreadIDs: [String],
        freshEvidenceDigest: String,
        beforeState: CodexGhostRepairCategoryADisposableState,
        files: [CodexGhostRepairCategoryAExecutionSnapshotFile],
        createdAtMilliseconds: Int64
    ) throws {
        let payload = CodexGhostRepairCategoryAExecutionSnapshotPayload(
            operationID: operationID,
            draftDigest: draftDigest,
            targetThreadIDs: targetThreadIDs,
            freshEvidenceDigest: freshEvidenceDigest,
            beforeState: beforeState,
            files: files,
            createdAtMilliseconds: createdAtMilliseconds
        )
        self.operationID = operationID
        self.draftDigest = draftDigest
        self.targetThreadIDs = targetThreadIDs
        self.freshEvidenceDigest = freshEvidenceDigest
        self.beforeState = beforeState
        self.files = files
        self.createdAtMilliseconds = createdAtMilliseconds
        manifestHash = try CodexGhostRepairHasher.hash(payload)
    }

    func validateDigest() throws {
        let payload = CodexGhostRepairCategoryAExecutionSnapshotPayload(
            operationID: operationID,
            draftDigest: draftDigest,
            targetThreadIDs: targetThreadIDs,
            freshEvidenceDigest: freshEvidenceDigest,
            beforeState: beforeState,
            files: files,
            createdAtMilliseconds: createdAtMilliseconds
        )
        guard try CodexGhostRepairHasher.hash(payload) == manifestHash,
              (1...2).contains(targetThreadIDs.count),
              targetThreadIDs == targetThreadIDs.sorted(),
              Set(targetThreadIDs).count == targetThreadIDs.count,
              files.count == CodexGhostRepairSnapshotCanonicalFile.allCases.count,
              files.map(\.fileName)
                == CodexGhostRepairSnapshotCanonicalFile.allCases.map(\.rawValue),
              !restoreAuthority,
              !cleanupAuthority,
              !repairMutationAuthority else {
            throw CodexGhostRepairError.invalidPlan(
                "M3f execution snapshot manifest is invalid."
            )
        }
    }
}

struct CodexGhostRepairCategoryAProductionRecipeBundle: Sendable {
    static let markerFileName =
        ".agent-session-manager-m3f-production-recipe-v1"
    static let markerContents =
        "Agent Session Manager M3f production recipe mirror v1\n"
    static let snapshotDirectoryName = "m3f-execution-snapshots"
    static let manifestFileName = "manifest.json"

    let disposableBundle: CodexGhostRepairCategoryADisposableBundle
    private let snapshotRootURL: URL

    init(
        disposableBundle: CodexGhostRepairCategoryADisposableBundle,
        testOwnedManagerRootURL: URL,
        testOwnedAllowedParentURL: URL
    ) throws {
        let managerRoot = testOwnedManagerRootURL.standardizedFileURL
        let allowedParent = testOwnedAllowedParentURL.standardizedFileURL
        let liveCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
        guard managerRoot.path != allowedParent.path,
              Self.isDescendant(managerRoot, of: allowedParent),
              managerRoot.path != liveCodexHome.path,
              !Self.isDescendant(managerRoot, of: liveCodexHome),
              !Self.isDescendant(
                  managerRoot,
                  of: disposableBundle.resolution.codexHomeURL
              ),
              !Self.isDescendant(
                  disposableBundle.resolution.codexHomeURL,
                  of: managerRoot
              ) else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M3f manager root escaped or overlapped its test boundary."
            )
        }
        let marker = managerRoot.appendingPathComponent(Self.markerFileName)
        guard try String(contentsOf: marker, encoding: .utf8)
                == Self.markerContents else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M3f manager root marker is missing or invalid."
            )
        }
        let snapshots = managerRoot.appendingPathComponent(
            Self.snapshotDirectoryName,
            isDirectory: true
        )
        try Self.requireOwnerPrivateDirectory(managerRoot)
        try Self.requireOwnerPrivateDirectory(snapshots)
        self.disposableBundle = disposableBundle
        snapshotRootURL = snapshots
    }

    func capture(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        freshEvidence: CodexGhostRepairCategoryAFreshExecutionEvidence,
        beforeState: CodexGhostRepairCategoryADisposableState,
        createdAtMilliseconds: Int64
    ) throws -> CodexGhostRepairCategoryAOperationBoundExecutionSnapshot {
        try draft.validateDigest()
        try freshEvidence.validateDigest()
        try disposableBundle.validateFreshLayout()
        try Self.requireOwnerPrivateDirectory(snapshotRootURL)
        guard freshEvidence.items.map(\.threadID) == draft.targetThreadIDs,
              beforeState.items.map(\.threadID) == draft.targetThreadIDs,
              beforeState.authority == freshEvidence.freshAuthority else {
            throw CodexGhostRepairError.authorityDrift
        }

        let destination = snapshotURL(operationID: draft.operationID)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CodexGhostRepairError.claimAlreadyExists
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(destination.path, S_IRWXU) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f could not protect the execution snapshot directory."
            )
        }

        let beforeFiles = try sourceEvidence()
        for evidence in beforeFiles where evidence.present {
            let source = sourceURL(fileName: evidence.fileName)
            let copied = destination.appendingPathComponent(evidence.fileName)
            try Self.copyVerifiedFile(
                from: source,
                to: copied,
                evidence: evidence
            )
            guard try Self.rawHash(copied) == evidence.contentHash else {
                throw CodexGhostRepairError.backupFailed(
                    "M3f execution snapshot copy readback did not match."
                )
            }
        }
        guard try sourceEvidence() == beforeFiles else {
            throw CodexGhostRepairError.backupFailed(
                "M3f source drifted while the execution snapshot was copied."
            )
        }

        let snapshot = try CodexGhostRepairCategoryAOperationBoundExecutionSnapshot(
            operationID: draft.operationID,
            draftDigest: draft.draftDigest,
            targetThreadIDs: draft.targetThreadIDs,
            freshEvidenceDigest: freshEvidence.evidenceDigest,
            beforeState: beforeState,
            files: beforeFiles,
            createdAtMilliseconds: createdAtMilliseconds
        )
        try snapshot.validateDigest()
        try writeManifest(snapshot, at: destination)
        try Self.synchronizeDirectory(destination)
        try Self.synchronizeDirectory(snapshotRootURL)
        return try load(operationID: draft.operationID)
    }

    func load(
        operationID: UUID
    ) throws -> CodexGhostRepairCategoryAOperationBoundExecutionSnapshot {
        let directory = snapshotURL(operationID: operationID)
        try Self.requireOwnerPrivateDirectory(directory)
        let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
        try Self.requireOwnerPrivateRegularFile(manifestURL)
        let data = try Data(contentsOf: manifestURL)
        let snapshot = try JSONDecoder().decode(
            CodexGhostRepairCategoryAOperationBoundExecutionSnapshot.self,
            from: data
        )
        try snapshot.validateDigest()
        guard snapshot.operationID == operationID else {
            throw CodexGhostRepairError.invalidPlan(
                "M3f execution snapshot operation ID mismatch."
            )
        }
        for evidence in snapshot.files where evidence.present {
            let copied = directory.appendingPathComponent(evidence.fileName)
            try Self.requireOwnerPrivateRegularFile(copied)
            guard try Self.rawHash(copied) == evidence.contentHash else {
                throw CodexGhostRepairError.backupFailed(
                    "M3f execution snapshot durable readback drifted."
                )
            }
        }
        for evidence in snapshot.files where !evidence.present {
            guard !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(evidence.fileName).path
            ) else {
                throw CodexGhostRepairError.backupFailed(
                    "M3f absent source appeared in the durable snapshot."
                )
            }
        }
        return snapshot
    }

    private func snapshotURL(operationID: UUID) -> URL {
        snapshotRootURL.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func sourceEvidence()
        throws -> [CodexGhostRepairCategoryAExecutionSnapshotFile]
    {
        try CodexGhostRepairSnapshotCanonicalFile.allCases.map { file in
            let url = file.sourceURL(
                codexHomeURL: disposableBundle.resolution.codexHomeURL,
                sqliteRootURL: disposableBundle.resolution.sqliteRootURL
            )
            var status = stat()
            if lstat(url.path, &status) != 0 {
                guard errno == ENOENT, !file.isRequiredDatabase else {
                    throw CodexGhostRepairError.backupFailed(
                        "M3f required source file is unavailable."
                    )
                }
                return .init(
                    fileName: file.rawValue,
                    present: false,
                    device: nil,
                    inode: nil,
                    mode: nil,
                    byteCount: nil,
                    modifiedAtNanoseconds: nil,
                    contentHash: nil
                )
            }
            try Self.requireOwnerPrivateRegularFile(url)
            return try .init(
                fileName: file.rawValue,
                present: true,
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                mode: UInt16(status.st_mode & 0o7777),
                byteCount: UInt64(status.st_size),
                modifiedAtNanoseconds:
                    Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int64(status.st_mtimespec.tv_nsec),
                contentHash: Self.rawHash(
                    url,
                    expectedDevice: UInt64(status.st_dev),
                    expectedInode: UInt64(status.st_ino),
                    expectedByteCount: UInt64(status.st_size),
                    expectedModifiedAtNanoseconds:
                        Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
                        + Int64(status.st_mtimespec.tv_nsec)
                )
            )
        }
    }

    private func sourceURL(fileName: String) -> URL {
        let file = CodexGhostRepairSnapshotCanonicalFile(rawValue: fileName)!
        return file.sourceURL(
            codexHomeURL: disposableBundle.resolution.codexHomeURL,
            sqliteRootURL: disposableBundle.resolution.sqliteRootURL
        )
    }

    private func writeManifest(
        _ snapshot: CodexGhostRepairCategoryAOperationBoundExecutionSnapshot,
        at directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        let url = directory.appendingPathComponent(Self.manifestFileName)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CodexGhostRepairError.backupFailed(
                "M3f execution snapshot manifest already exists."
            )
        }
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f execution snapshot manifest is not private."
            )
        }
        try Self.synchronizeFile(url)
    }

    private static func rawHash(
        _ url: URL,
        expectedDevice: UInt64? = nil,
        expectedInode: UInt64? = nil,
        expectedByteCount: UInt64? = nil,
        expectedModifiedAtNanoseconds: Int64? = nil
    ) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f could not open a fixed snapshot file read-only."
            )
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0,
              expectedDevice.map({ $0 == UInt64(status.st_dev) }) ?? true,
              expectedInode.map({ $0 == UInt64(status.st_ino) }) ?? true,
              expectedByteCount.map({ $0 == UInt64(status.st_size) }) ?? true,
              expectedModifiedAtNanoseconds.map({
                  $0 == Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int64(status.st_mtimespec.tv_nsec)
              }) ?? true else {
            throw CodexGhostRepairError.backupFailed(
                "M3f fixed snapshot file identity drifted before read."
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw CodexGhostRepairError.backupFailed(
                    "M3f fixed snapshot file read failed."
                )
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        let digest = hasher.finalize()
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func copyVerifiedFile(
        from source: URL,
        to destination: URL,
        evidence: CodexGhostRepairCategoryAExecutionSnapshotFile
    ) throws {
        let sourceDescriptor = open(
            source.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f could not open a fixed source file for copy."
            )
        }
        defer { close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              evidence.device == UInt64(sourceStatus.st_dev),
              evidence.inode == UInt64(sourceStatus.st_ino),
              evidence.mode == UInt16(sourceStatus.st_mode & 0o7777),
              evidence.byteCount == UInt64(sourceStatus.st_size),
              evidence.modifiedAtNanoseconds
                == Int64(sourceStatus.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int64(sourceStatus.st_mtimespec.tv_nsec) else {
            throw CodexGhostRepairError.backupFailed(
                "M3f source identity drifted before copy."
            )
        }

        let destinationDescriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f could not create the exact destination file."
            )
        }
        defer { close(destinationDescriptor) }
        guard fchmod(destinationDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f could not protect the copied destination file."
            )
        }

        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let readCount = read(sourceDescriptor, &buffer, buffer.count)
            guard readCount >= 0 else {
                throw CodexGhostRepairError.backupFailed(
                    "M3f source read failed during copy."
                )
            }
            if readCount == 0 { break }
            var written = 0
            while written < readCount {
                let writeCount = buffer.withUnsafeBytes { bytes in
                    write(
                        destinationDescriptor,
                        bytes.baseAddress!.advanced(by: written),
                        readCount - written
                    )
                }
                guard writeCount > 0 else {
                    throw CodexGhostRepairError.backupFailed(
                        "M3f destination write failed during copy."
                    )
                }
                written += writeCount
            }
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f could not fsync the copied destination file."
            )
        }
    }

    private static func synchronizeFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f could not open a destination file for fsync."
            )
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f could not fsync a destination file."
            )
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f could not open a destination directory for fsync."
            )
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CodexGhostRepairError.backupFailed(
                "M3f could not fsync a destination directory."
            )
        }
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parent = parent.standardizedFileURL.pathComponents
        let child = child.standardizedFileURL.pathComponents
        return child.count > parent.count
            && child.prefix(parent.count) == parent[...]
    }

    private static func requireOwnerPrivateDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M3f required directory is not owner-private."
            )
        }
    }

    private static func requireOwnerPrivateRegularFile(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw CodexGhostRepairError.invalidDisposablePath(
                "M3f required file is not owner-private."
            )
        }
    }
}

actor CodexGhostRepairCategoryAProductionRecipeCoordinator {
    static let capabilities =
        CodexGhostRepairCategoryAProductionRecipeCapabilities()

    private let bundle: CodexGhostRepairCategoryAProductionRecipeBundle
    private let journal: SQLiteStateStore
    private let executor: CodexGhostRepairCategoryADisposableExecutor

    init(
        bundle: CodexGhostRepairCategoryAProductionRecipeBundle,
        journal: SQLiteStateStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.bundle = bundle
        self.journal = journal
        executor = CodexGhostRepairCategoryADisposableExecutor(
            bundle: bundle.disposableBundle,
            now: now
        )
    }

    func confirmAndExecute(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        review: CodexGhostRepairCategoryAExecutionReviewEvidence,
        confirmationToken: String,
        freshEvidence: CodexGhostRepairCategoryAFreshExecutionEvidence,
        confirmedAtMilliseconds: Int64,
        snapshotAtMilliseconds: Int64,
        executionAtMilliseconds: Int64,
        fault: CodexGhostRepairCategoryAProductionRecipeFault = .none
    ) async throws -> CodexGhostRepairCategoryAExecutionTerminalReport {
        let consumed = try journal
            .consumeCodexGhostRepairCategoryAAuthorization(
                operationID: draft.operationID,
                confirmationToken: confirmationToken,
                confirmedAtMilliseconds: confirmedAtMilliseconds
            )
        switch consumed {
        case let .existingReport(report):
            return report
        case let .existingReceipt(receipt):
            return try await recoverOrStop(
                draft: draft,
                receipt: receipt,
                completedAtMilliseconds: executionAtMilliseconds
            )
        case let .consumed(receipt):
            if fault == .afterAuthorization {
                throw CodexGhostRepairError.injectedInterruption
            }
            return try await executeNewAuthorization(
                draft: draft,
                review: review,
                receipt: receipt,
                freshEvidence: freshEvidence,
                snapshotAtMilliseconds: snapshotAtMilliseconds,
                executionAtMilliseconds: executionAtMilliseconds,
                fault: fault
            )
        }
    }

    private func executeNewAuthorization(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        review: CodexGhostRepairCategoryAExecutionReviewEvidence,
        receipt: CodexGhostRepairCategoryAAuthorizationReceipt,
        freshEvidence: CodexGhostRepairCategoryAFreshExecutionEvidence,
        snapshotAtMilliseconds: Int64,
        executionAtMilliseconds: Int64,
        fault: CodexGhostRepairCategoryAProductionRecipeFault
    ) async throws -> CodexGhostRepairCategoryAExecutionTerminalReport {
        let state = try journal.codexGhostRepairCategoryAOperation(
            operationID: draft.operationID
        )
        guard let state, state.status == .authorized,
              state.receipt == receipt else {
            throw CodexGhostRepairError.recoveryRequired
        }
        let before: CodexGhostRepairCategoryADisposableState
        do {
            before = try await executor.inspectForProductionRecipe(
                draft: draft,
                freshEvidence: freshEvidence
            )
        } catch {
            return try terminal(
                state: state,
                claim: nil,
                outcome: .notAttempted,
                attempted: false,
                completedAtMilliseconds: executionAtMilliseconds
            )
        }

        let snapshot: CodexGhostRepairCategoryAOperationBoundExecutionSnapshot
        do {
            snapshot = try bundle.capture(
                draft: draft,
                freshEvidence: freshEvidence,
                beforeState: before,
                createdAtMilliseconds: snapshotAtMilliseconds
            )
            let afterSnapshot = try await executor.inspectForProductionRecipe(
                draft: draft,
                freshEvidence: freshEvidence
            )
            guard afterSnapshot == before else {
                throw CodexGhostRepairError.authorityDrift
            }
        } catch {
            return try terminal(
                state: state,
                claim: nil,
                outcome: .notAttempted,
                attempted: false,
                completedAtMilliseconds: executionAtMilliseconds
            )
        }
        if fault == .afterSnapshot {
            throw CodexGhostRepairError.injectedInterruption
        }

        let claim = try CodexGhostRepairCategoryAExecutionPreparation
            .prepareClaimEvidence(
                draft: draft,
                review: review,
                challenge: state.challenge,
                receipt: receipt,
                executionSnapshotManifestHash: snapshot.manifestHash,
                freshEvidence: freshEvidence,
                executionAtMilliseconds: executionAtMilliseconds,
                claimedAtMilliseconds: snapshotAtMilliseconds
            )
        let claimResult = try journal.claimCodexGhostRepairCategoryAExecution(
            claim
        )
        guard case .claimed = claimResult else {
            return try await recoverOrStop(
                draft: draft,
                receipt: receipt,
                completedAtMilliseconds: executionAtMilliseconds
            )
        }
        if fault == .afterManagerClaim {
            throw CodexGhostRepairError.injectedInterruption
        }

        let disposableFault: CodexGhostRepairCategoryADisposableFault
        switch fault {
        case .disposableBusy: disposableFault = .explicitBusyBeforeTransaction
        case .disposableAfterClaim: disposableFault = .afterClaim
        case .disposableAfterCommit: disposableFault = .afterCommitBeforeReport
        default: disposableFault = .none
        }
        let disposable = try await executor.execute(
            draft: draft,
            executionAuthority: freshEvidence.freshAuthority,
            observedAtMilliseconds: executionAtMilliseconds,
            fault: disposableFault
        )
        if fault == .afterDisposableReport {
            throw CodexGhostRepairError.injectedInterruption
        }
        return try terminal(
            state: try requiredState(draft.operationID),
            claim: claim,
            outcome: disposable.outcome,
            attempted: disposable.mutationAttemptedOnce,
            completedAtMilliseconds: executionAtMilliseconds
        )
    }

    private func recoverOrStop(
        draft: CodexGhostRepairCategoryAExecutionDraft,
        receipt: CodexGhostRepairCategoryAAuthorizationReceipt,
        completedAtMilliseconds: Int64
    ) async throws -> CodexGhostRepairCategoryAExecutionTerminalReport {
        let state = try requiredState(draft.operationID)
        if let report = state.report { return report }
        guard state.receipt == receipt else {
            throw CodexGhostRepairError.recoveryRequired
        }
        guard let claim = state.claim else {
            return try terminal(
                state: state,
                claim: nil,
                outcome: .notAttempted,
                attempted: false,
                completedAtMilliseconds: completedAtMilliseconds
            )
        }
        let snapshot = try bundle.load(operationID: draft.operationID)
        guard snapshot.manifestHash == claim.executionSnapshotManifestHash,
              snapshot.draftDigest == draft.draftDigest,
              snapshot.freshEvidenceDigest
                == claim.freshEvidence.evidenceDigest else {
            throw CodexGhostRepairError.recoveryRequired
        }

        let outcome: CodexGhostRepairCategoryABatchOutcome
        let attempted: Bool
        if await executor.hasDurableExecutionEvidence(
            operationID: draft.operationID
        ) {
            let disposable = try await executor.recoverByReadback(draft: draft)
            outcome = disposable.outcome
            attempted = disposable.mutationAttemptedOnce
        } else {
            let observed = try? await executor.inspectForProductionRecipe(
                draft: draft,
                freshEvidence: claim.freshEvidence
            )
            outcome = observed == snapshot.beforeState
                ? .notAttempted : .unknown
            attempted = false
        }
        return try terminal(
            state: state,
            claim: claim,
            outcome: outcome,
            attempted: attempted,
            completedAtMilliseconds: completedAtMilliseconds
        )
    }

    private func terminal(
        state: CodexGhostRepairCategoryAExecutionOperationState,
        claim: CodexGhostRepairCategoryAExecutionClaimEvidence?,
        outcome: CodexGhostRepairCategoryABatchOutcome,
        attempted: Bool,
        completedAtMilliseconds: Int64
    ) throws -> CodexGhostRepairCategoryAExecutionTerminalReport {
        guard let receipt = state.receipt else {
            throw CodexGhostRepairError.recoveryRequired
        }
        let report = try CodexGhostRepairCategoryAExecutionPreparation
            .terminalReport(
                challenge: state.challenge,
                receipt: receipt,
                claim: claim,
                outcome: outcome,
                mutationAttemptedOnce: attempted,
                completedAtMilliseconds: completedAtMilliseconds
        )
        try journal.finalizeCodexGhostRepairCategoryAExecution(report)
        guard let persisted = try requiredState(report.operationID).report else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return persisted
    }

    private func requiredState(
        _ operationID: UUID
    ) throws -> CodexGhostRepairCategoryAExecutionOperationState {
        guard let state = try journal.codexGhostRepairCategoryAOperation(
            operationID: operationID
        ) else {
            throw CodexGhostRepairError.recoveryRequired
        }
        return state
    }
}

#endif
