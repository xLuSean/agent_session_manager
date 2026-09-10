import Darwin
import Foundation

/// Shipping-compiled fixed-directory Prepare coordinator. The concrete type
/// remains Core-internal; the App can obtain it only through the path-free
/// public factory. Tests exercise effects only inside an E49 plus E58
/// marker-protected temporary mirror.
actor CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator:
    CodexGhostRepairDestinationCanaryCoordinator
{
    static let testEffectMarkerFileName =
        ".agent-session-manager-e58-fixed-directory-effect-root-v1"
    static let testEffectMarkerContents =
        "Agent Session Manager E58 test-owned fixed-directory effect root v1\n"

    typealias RootResolver = @Sendable () throws -> URL
    typealias DirectoryCreator = @Sendable (URL) throws -> Void
    typealias Clock = @Sendable () -> Date

    nonisolated let capabilities =
        CodexGhostRepairDestinationCanaryCapabilities
            .fixedManagerPrivateDirectoryPrepare

    private let inspector:
        CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
    private let rootResolver: RootResolver
    private let effectBoundary: EffectBoundary?
    private let directoryCreator: DirectoryCreator
    private var consumedRequestIDs: Set<UUID> = []
    private var consumedEvidenceTokens: Set<String> = []

    /// Production construction is lazy, path-free, and performs zero I/O.
    /// Calling the public facade still performs no I/O. Only a later explicit
    /// Inspect or Prepare intent resolves the fixed production location.
    static func production(
        clock: @escaping Clock = { Date() }
    ) -> Self {
        Self(
            inspector: .production(clock: clock),
            rootResolver: {
                guard let root = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    throw PrepareError.applicationSupportUnavailable
                }
                return root
            },
            effectBoundary: nil,
            directoryCreator: { try Self.createPrivateDirectory($0) }
        )
    }

    /// Deterministic acceptance seam. Construction is zero-I/O. Explicit
    /// Inspect and Prepare calls must independently pass the E49 read marker;
    /// Prepare additionally requires the E58 effect marker.
    init(
        testOwnedApplicationSupportDirectory: URL,
        testOwnedAllowedParentURL: URL,
        clock: @escaping Clock = { Date() },
        directoryCreator: @escaping DirectoryCreator = {
            try CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator
                .createPrivateDirectory($0)
        }
    ) {
        inspector = CodexGhostRepairDestinationCanaryInspectOnlyCoordinator(
            testOwnedApplicationSupportDirectory:
                testOwnedApplicationSupportDirectory,
            testOwnedAllowedParentURL: testOwnedAllowedParentURL,
            clock: clock
        )
        rootResolver = { testOwnedApplicationSupportDirectory }
        effectBoundary = EffectBoundary(
            allowedParentURL: testOwnedAllowedParentURL,
            applicationSupportURL: testOwnedApplicationSupportDirectory
        )
        self.directoryCreator = directoryCreator
    }

    private init(
        inspector: CodexGhostRepairDestinationCanaryInspectOnlyCoordinator,
        rootResolver: @escaping RootResolver,
        effectBoundary: EffectBoundary?,
        directoryCreator: @escaping DirectoryCreator
    ) {
        self.inspector = inspector
        self.rootResolver = rootResolver
        self.effectBoundary = effectBoundary
        self.directoryCreator = directoryCreator
    }

    func inspect(
        requestID: UUID
    ) async -> CodexGhostRepairDestinationCanaryInspectionOutcome {
        let outcome = await inspector.inspect(requestID: requestID)
        switch outcome {
        case let .needsPreparation(evidence):
            guard Self.isEligible(evidence) else {
                return .blocked(
                    evidence: evidence,
                    message: Self.message("fixed-private-subset-required")
                )
            }
            return .needsPreparation(evidence)
        case .ready, .unavailable, .blocked, .failed:
            return outcome
        }
    }

    func prepare(
        request: CodexGhostRepairDestinationCanaryPreparationRequest
    ) async -> CodexGhostRepairDestinationCanaryPreparationOutcome {
        guard !consumedRequestIDs.contains(request.id) else {
            return .blocked(
                evidence: nil,
                message: Self.message("frozen-request-consumed")
            )
        }
        guard !consumedEvidenceTokens.contains(request.evidenceToken) else {
            consumedRequestIDs.insert(request.id)
            return .blocked(
                evidence: nil,
                message: Self.message("frozen-evidence-consumed")
            )
        }
        consumedRequestIDs.insert(request.id)
        consumedEvidenceTokens.insert(request.evidenceToken)

        let fresh = await inspector.inspect(requestID: UUID())
        guard case let .needsPreparation(frozenEvidence) = fresh,
              Self.isEligible(frozenEvidence),
              Self.matches(request: request, evidence: frozenEvidence) else {
            return .blocked(
                evidence: fresh.evidence,
                message: Self.message("fresh-frozen-evidence-drift")
            )
        }

        do {
            let applicationSupport = try rootResolver().standardizedFileURL
            try validateEffectBoundary(
                resolvedApplicationSupport: applicationSupport
            )
            let entries = Dictionary(uniqueKeysWithValues:
                CodexGhostRepairDestinationCanaryFixedLayout.entries(
                    applicationSupport: applicationSupport
                ).map { ($0.directory, $0) }
            )
            var expected = frozenEvidence
            var completedEffects = 0

            for directory in CodexGhostRepairDestinationCanaryFixedLayout
                .preparationOrder where request.missingDirectories.contains(directory)
            {
                let before = await inspector.inspect(requestID: UUID())
                guard case let .needsPreparation(beforeEvidence) = before,
                      Self.sameStableEvidence(beforeEvidence, expected),
                      Self.isEligible(beforeEvidence),
                      let entry = entries[directory] else {
                    return .partialOrBlocked(
                        completedEffects: completedEffects,
                        evidence: before.evidence,
                        code: "pre-effect-drift"
                    )
                }
                do {
                    try validateEffectBoundary(
                        resolvedApplicationSupport: applicationSupport
                    )
                } catch {
                    return .partialOrBlocked(
                        completedEffects: completedEffects,
                        evidence: before.evidence,
                        code: Self.errorCode(error)
                    )
                }

                do {
                    try directoryCreator(entry.url)
                    try Self.validateCreatedDirectory(entry.url)
                    try Self.synchronizeDirectory(
                        entry.url.deletingLastPathComponent()
                    )
                } catch {
                    let afterFailure = await inspector.inspect(requestID: UUID())
                    return .partial(
                        evidence: afterFailure.evidence,
                        message: Self.message("directory-effect-failed")
                    )
                }

                completedEffects += 1
                let after = await inspector.inspect(requestID: UUID())
                guard let afterEvidence = after.evidence,
                      Self.isExactTransition(
                          from: expected,
                          to: afterEvidence,
                          created: directory
                      ) else {
                    return .partial(
                        evidence: after.evidence,
                        message: Self.message("post-effect-readback-drift")
                    )
                }
                expected = afterEvidence
            }

            let final = await inspector.inspect(requestID: UUID())
            guard case let .ready(evidence) = final,
                  evidence.isReady,
                  Self.sameStableEvidence(evidence, expected) else {
                return .partial(
                    evidence: final.evidence,
                    message: Self.message("incomplete-final-readback")
                )
            }
            return .ready(evidence)
        } catch {
            return .blocked(
                evidence: nil,
                message: Self.message(Self.errorCode(error))
            )
        }
    }

    private func validateEffectBoundary(
        resolvedApplicationSupport: URL
    ) throws {
        guard let effectBoundary else { return }
        let expected = effectBoundary.applicationSupportURL.standardizedFileURL
        let parent = effectBoundary.allowedParentURL.standardizedFileURL
        guard resolvedApplicationSupport == expected,
              expected != parent,
              Self.isDescendant(expected, of: parent) else {
            throw PrepareError.invalidTestBoundary
        }
        try Self.validateEffectMarker(in: parent)
    }

    private static func validateEffectMarker(in parent: URL) throws {
        let marker = parent.appendingPathComponent(
            testEffectMarkerFileName,
            isDirectory: false
        )
        let descriptor = Darwin.open(
            marker.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw PrepareError.invalidEffectMarker }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o7777 == 0o600,
              status.st_size == testEffectMarkerContents.utf8.count else {
            throw PrepareError.invalidEffectMarker
        }
        var bytes = [UInt8](
            repeating: 0,
            count: testEffectMarkerContents.utf8.count
        )
        guard read(descriptor, &bytes, bytes.count) == bytes.count,
              String(decoding: bytes, as: UTF8.self)
                == testEffectMarkerContents else {
            throw PrepareError.invalidEffectMarker
        }
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        guard mkdir(url.path, S_IRWXU) == 0 else {
            throw PrepareError.directoryCreationFailed
        }
    }

    private static func validateCreatedDirectory(_ url: URL) throws {
        var before = stat()
        guard lstat(url.path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFDIR,
              before.st_uid == getuid(),
              before.st_mode & 0o7777 == 0o700 else {
            throw PrepareError.createdDirectoryInvalid
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PrepareError.createdDirectoryInvalid
        }
        defer { Darwin.close(descriptor) }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              after.st_uid == getuid(),
              after.st_mode & 0o7777 == 0o700 else {
            throw PrepareError.createdDirectoryInvalid
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw PrepareError.parentSyncFailed }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw PrepareError.parentSyncFailed
        }
    }

    private static func isEligible(
        _ evidence: CodexGhostRepairDestinationCanaryEvidence
    ) -> Bool {
        let missing = Set(evidence.missingDirectories)
        let allowed = Set(
            CodexGhostRepairDestinationCanaryFixedLayout.preparationOrder
        )
        guard !missing.isEmpty,
              missing.isSubset(of: allowed),
              evidence.directories.first(where: {
                  $0.directory == .applicationBundleRoot
              })?.status == .ready else {
            return false
        }
        return evidence.directories.allSatisfy {
            if $0.directory == .applicationBundleRoot {
                return $0.status == .ready
            }
            return missing.contains($0.directory)
                ? $0.status == .missing
                : $0.status == .ready
        }
    }

    private static func matches(
        request: CodexGhostRepairDestinationCanaryPreparationRequest,
        evidence: CodexGhostRepairDestinationCanaryEvidence
    ) -> Bool {
        request.evidenceToken == evidence.evidenceToken
            && request.policy == evidence.policy
            && request.missingDirectories == evidence.missingDirectories.sorted {
                $0.rawValue < $1.rawValue
            }
    }

    private static func sameStableEvidence(
        _ lhs: CodexGhostRepairDestinationCanaryEvidence,
        _ rhs: CodexGhostRepairDestinationCanaryEvidence
    ) -> Bool {
        lhs.evidenceToken == rhs.evidenceToken
            && lhs.policy == rhs.policy
            && lhs.directories == rhs.directories
    }

    private static func isExactTransition(
        from before: CodexGhostRepairDestinationCanaryEvidence,
        to after: CodexGhostRepairDestinationCanaryEvidence,
        created: CodexGhostRepairDestinationCanaryDirectory
    ) -> Bool {
        guard before.policy == after.policy,
              before.directories.count == after.directories.count else {
            return false
        }
        let beforeByDirectory = Dictionary(uniqueKeysWithValues:
            before.directories.map { ($0.directory, $0) }
        )
        let afterByDirectory = Dictionary(uniqueKeysWithValues:
            after.directories.map { ($0.directory, $0) }
        )
        for directory in CodexGhostRepairDestinationCanaryDirectory.allCases {
            guard let old = beforeByDirectory[directory],
                  let new = afterByDirectory[directory] else { return false }
            if directory == created {
                guard old.status == .missing,
                      new.status == .ready,
                      new.permissionRequirement == .ownerPrivate0700,
                      new.observedMode == 0o700 else { return false }
            } else if old != new {
                return false
            }
        }
        return true
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && Array(childComponents.prefix(parentComponents.count))
                == parentComponents
    }

    private static func message(_ code: String) -> String {
        "Snapshot Storage preparation stopped before further effects (\(code)). Clear filesystem paths are unavailable."
    }

    private static func errorCode(_ error: Error) -> String {
        (error as? PrepareError)?.rawValue ?? "unexpected-effect-error"
    }
}

private extension CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator {
    struct EffectBoundary: Sendable {
        let allowedParentURL: URL
        let applicationSupportURL: URL
    }

    enum PrepareError: String, Error {
        case applicationSupportUnavailable = "application-support-unavailable"
        case invalidTestBoundary = "invalid-test-boundary"
        case invalidEffectMarker = "invalid-effect-marker"
        case directoryCreationFailed = "directory-creation-failed"
        case createdDirectoryInvalid = "created-directory-invalid"
        case parentSyncFailed = "parent-sync-failed"
    }
}

private extension CodexGhostRepairDestinationCanaryInspectionOutcome {
    var evidence: CodexGhostRepairDestinationCanaryEvidence? {
        switch self {
        case let .needsPreparation(evidence), let .ready(evidence): evidence
        case let .blocked(evidence, _): evidence
        case .unavailable, .failed: nil
        }
    }
}

private extension CodexGhostRepairDestinationCanaryPreparationOutcome {
    static func partialOrBlocked(
        completedEffects: Int,
        evidence: CodexGhostRepairDestinationCanaryEvidence?,
        code: String
    ) -> Self {
        let message =
            "Snapshot Storage preparation stopped before further effects (\(code)). Clear filesystem paths are unavailable."
        return completedEffects > 0
            ? .partial(evidence: evidence, message: message)
            : .blocked(evidence: evidence, message: message)
    }
}
