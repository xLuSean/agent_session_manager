@testable import AgentSessionManagerCore
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinatorTests:
    XCTestCase
{
    func testConstructionIsZeroIOAndCapabilityDisclosesFixedFilesystemEffect() {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e58-no-io-\(UUID().uuidString)",
            isDirectory: true
        )
        let applicationSupport = parent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )

        let coordinator = CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator(
            testOwnedApplicationSupportDirectory: applicationSupport,
            testOwnedAllowedParentURL: parent
        )

        XCTAssertEqual(
            coordinator.capabilities,
            .fixedManagerPrivateDirectoryPrepare
        )
        XCTAssertEqual(
            coordinator.capabilities.preparationEffect,
            .fixedManagerPrivateDirectories
        )
        XCTAssertTrue(coordinator.capabilities.preparationEffect.writesFilesystem)
        XCTAssertFalse(coordinator.capabilities.filesystemAuthority)
        XCTAssertFalse(coordinator.capabilities.preparationEffect.acceptsCallerPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testFiveMissingCreatesFixedOrderAndPreservesBundleRoot() async throws {
        let fixture = try makeFixture(label: #function, readyPrivatePrefixCount: 0)
        let calls = E58CallCounter()
        let coordinator = makeCoordinator(fixture, calls: calls)
        let rootBefore = try identity(fixture.bundleRoot)
        let preview = try inspectionEvidence(
            await coordinator.inspect(requestID: UUID())
        )

        let outcome = await coordinator.prepare(
            request: try .init(evidence: preview)
        )
        let ready = try preparationEvidence(outcome)

        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(calls.createdURLs, fixture.privateURLs)
        XCTAssertEqual(try identity(fixture.bundleRoot), rootBefore)
        for url in fixture.privateURLs {
            XCTAssertEqual(try identity(url).mode, 0o700)
        }
    }

    func testThreeMissingCreatesOnlyExactRemainingSubset() async throws {
        let fixture = try makeFixture(label: #function, readyPrivatePrefixCount: 2)
        let calls = E58CallCounter()
        let coordinator = makeCoordinator(fixture, calls: calls)
        let preview = try inspectionEvidence(
            await coordinator.inspect(requestID: UUID())
        )

        XCTAssertEqual(preview.missingDirectories, [.journal, .quarantine, .trash])
        _ = try preparationEvidence(await coordinator.prepare(
            request: try .init(evidence: preview)
        ))

        XCTAssertEqual(calls.createdURLs, Array(fixture.privateURLs.dropFirst(2)))
    }

    func testOneMissingCreatesOnlyTrash() async throws {
        let fixture = try makeFixture(label: #function, readyPrivatePrefixCount: 4)
        let calls = E58CallCounter()
        let coordinator = makeCoordinator(fixture, calls: calls)
        let preview = try inspectionEvidence(
            await coordinator.inspect(requestID: UUID())
        )

        XCTAssertEqual(preview.missingDirectories, [.trash])
        _ = try preparationEvidence(await coordinator.prepare(
            request: try .init(evidence: preview)
        ))

        XCTAssertEqual(calls.createdURLs, [fixture.privateURLs[4]])
    }

    func testFreshDriftConsumesRequestAndPerformsNoEffect() async throws {
        let fixture = try makeFixture(label: #function, readyPrivatePrefixCount: 0)
        let calls = E58CallCounter()
        let coordinator = makeCoordinator(fixture, calls: calls)
        let preview = try inspectionEvidence(
            await coordinator.inspect(requestID: UUID())
        )
        let request = try CodexGhostRepairDestinationCanaryPreparationRequest(
            evidence: preview
        )
        try createPrivateDirectory(fixture.privateURLs[0])

        let first = await coordinator.prepare(request: request)
        let replay = await coordinator.prepare(request: request)

        assertBlocked(first, contains: "fresh-frozen-evidence-drift")
        assertBlocked(replay, contains: "frozen-request-consumed")
        XCTAssertEqual(calls.createCalls, 0)
    }

    func testFreshFileCollisionBlocksBeforeEffect() async throws {
        let fixture = try makeFixture(label: #function, readyPrivatePrefixCount: 0)
        let calls = E58CallCounter()
        let coordinator = makeCoordinator(fixture, calls: calls)
        let preview = try inspectionEvidence(
            await coordinator.inspect(requestID: UUID())
        )
        try Data("collision".utf8).write(to: fixture.privateURLs[0])

        let outcome = await coordinator.prepare(request: try .init(evidence: preview))

        assertBlocked(outcome, contains: "fresh-frozen-evidence-drift")
        XCTAssertEqual(calls.createCalls, 0)
    }

    func testFreshSymlinkCollisionIsNotFollowedAndBlocksBeforeEffect() async throws {
        let fixture = try makeFixture(label: #function, readyPrivatePrefixCount: 0)
        let calls = E58CallCounter()
        let coordinator = makeCoordinator(fixture, calls: calls)
        let preview = try inspectionEvidence(
            await coordinator.inspect(requestID: UUID())
        )
        XCTAssertEqual(
            symlink(fixture.allowedParent.path, fixture.privateURLs[0].path),
            0
        )

        let outcome = await coordinator.prepare(request: try .init(evidence: preview))

        assertBlocked(outcome, contains: "fresh-frozen-evidence-drift")
        XCTAssertEqual(calls.createCalls, 0)
    }

    func testConcurrentSameEvidenceRequestsPerformEffectsOnce() async throws {
        let fixture = try makeFixture(label: #function, readyPrivatePrefixCount: 0)
        let calls = E58CallCounter()
        let coordinator = makeCoordinator(fixture, calls: calls)
        let preview = try inspectionEvidence(
            await coordinator.inspect(requestID: UUID())
        )
        let first = try CodexGhostRepairDestinationCanaryPreparationRequest(
            evidence: preview
        )
        let second = try CodexGhostRepairDestinationCanaryPreparationRequest(
            evidence: preview
        )

        async let firstOutcome = coordinator.prepare(request: first)
        async let secondOutcome = coordinator.prepare(request: second)
        let outcomes = await [firstOutcome, secondOutcome]

        XCTAssertEqual(calls.createCalls, 5)
        XCTAssertEqual(outcomes.filter(\.isReady).count, 1)
        XCTAssertEqual(outcomes.filter(\.isEvidenceConsumed).count, 1)
    }

    func testPartialCannotReplayButFreshCoordinatorCanAuthorizeRemainingSubset() async throws {
        let fixture = try makeFixture(label: #function, readyPrivatePrefixCount: 0)
        let firstCalls = E58CallCounter(failAt: 3)
        let firstCoordinator = makeCoordinator(fixture, calls: firstCalls)
        let preview = try inspectionEvidence(
            await firstCoordinator.inspect(requestID: UUID())
        )
        let request = try CodexGhostRepairDestinationCanaryPreparationRequest(
            evidence: preview
        )

        let partial = await firstCoordinator.prepare(request: request)
        guard case let .partial(partialEvidence, message) = partial,
              let partialEvidence else {
            return XCTFail("Injected failure must be reported as partial")
        }
        XCTAssertTrue(message.contains("directory-effect-failed"))
        XCTAssertEqual(
            partialEvidence.missingDirectories,
            [.journal, .quarantine, .trash]
        )
        let prefixBefore = try fixture.privateURLs.prefix(2).map(identity)
        assertBlocked(
            await firstCoordinator.prepare(request: request),
            contains: "frozen-request-consumed"
        )

        let recoveryCalls = E58CallCounter()
        let freshCoordinator = makeCoordinator(fixture, calls: recoveryCalls)
        let freshEvidence = try inspectionEvidence(
            await freshCoordinator.inspect(requestID: UUID())
        )
        XCTAssertNotEqual(freshEvidence.evidenceToken, preview.evidenceToken)
        XCTAssertEqual(
            freshEvidence.missingDirectories,
            [.journal, .quarantine, .trash]
        )
        _ = try preparationEvidence(await freshCoordinator.prepare(
            request: try .init(evidence: freshEvidence)
        ))

        XCTAssertEqual(try fixture.privateURLs.prefix(2).map(identity), prefixBefore)
        XCTAssertEqual(recoveryCalls.createdURLs, Array(fixture.privateURLs.dropFirst(2)))
    }

    func testMissingEffectMarkerBlocksBeforeDirectoryEffect() async throws {
        let fixture = try makeFixture(label: #function, readyPrivatePrefixCount: 0)
        try FileManager.default.removeItem(at: fixture.effectMarker)
        let calls = E58CallCounter()
        let coordinator = makeCoordinator(fixture, calls: calls)
        let preview = try inspectionEvidence(
            await coordinator.inspect(requestID: UUID())
        )

        let outcome = await coordinator.prepare(request: try .init(evidence: preview))

        assertBlocked(outcome, contains: "invalid-effect-marker")
        XCTAssertEqual(calls.createCalls, 0)
    }

    func testUnsafeExistingDirectoryBlocksWithoutChmodOrEffect() async throws {
        let fixture = try makeFixture(label: #function, readyPrivatePrefixCount: 1)
        XCTAssertEqual(chmod(fixture.privateURLs[0].path, 0o755), 0)
        let before = try identity(fixture.privateURLs[0])
        let calls = E58CallCounter()
        let coordinator = makeCoordinator(fixture, calls: calls)

        let outcome = await coordinator.inspect(requestID: UUID())

        guard case let .blocked(_, message) = outcome else {
            return XCTFail("Unsafe existing private directory must block")
        }
        assertPathRedacted(message, fixture: fixture)
        XCTAssertEqual(try identity(fixture.privateURLs[0]), before)
        XCTAssertEqual(calls.createCalls, 0)
    }

    func testProductionFactoryCanBeTypeCheckedWithoutInvocation() {
        let factory: (
            @escaping CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator.Clock
        ) -> CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator =
            CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator
                .production(clock:)
        _ = factory
    }

    private func makeCoordinator(
        _ fixture: E58Fixture,
        calls: E58CallCounter
    ) -> CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator {
        CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator(
            testOwnedApplicationSupportDirectory: fixture.applicationSupport,
            testOwnedAllowedParentURL: fixture.allowedParent,
            clock: { Date(timeIntervalSince1970: 1_000) },
            directoryCreator: { try calls.create($0) }
        )
    }

    private func makeFixture(
        label: String,
        readyPrivatePrefixCount: Int
    ) throws -> E58Fixture {
        let safeLabel = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-e58-\(safeLabel)-\(UUID().uuidString)",
            isDirectory: true
        )
        try createPrivateDirectory(parent)
        let readMarker = parent.appendingPathComponent(
            CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                .testRootMarkerFileName
        )
        try writeMarker(
            CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                .testRootMarkerContents,
            to: readMarker
        )
        let effectMarker = parent.appendingPathComponent(
            CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator
                .testEffectMarkerFileName
        )
        try writeMarker(
            CodexGhostRepairDestinationCanaryFixedDirectoryPrepareCoordinator
                .testEffectMarkerContents,
            to: effectMarker
        )
        let applicationSupport = parent.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try createPrivateDirectory(applicationSupport)
        let entries = CodexGhostRepairDestinationCanaryFixedLayout.entries(
            applicationSupport: applicationSupport
        )
        let bundleRoot = try XCTUnwrap(entries.first {
            $0.directory == .applicationBundleRoot
        }?.url)
        try FileManager.default.createDirectory(
            at: bundleRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertEqual(chmod(bundleRoot.path, 0o755), 0)
        let byDirectory = Dictionary(uniqueKeysWithValues:
            entries.map { ($0.directory, $0.url) }
        )
        let privateURLs = try CodexGhostRepairDestinationCanaryFixedLayout
            .preparationOrder.map { try XCTUnwrap(byDirectory[$0]) }
        for url in privateURLs.prefix(readyPrivatePrefixCount) {
            try createPrivateDirectory(url)
        }
        return E58Fixture(
            allowedParent: parent,
            applicationSupport: applicationSupport,
            bundleRoot: bundleRoot,
            effectMarker: effectMarker,
            privateURLs: privateURLs
        )
    }

    private func createPrivateDirectory(_ url: URL) throws {
        guard mkdir(url.path, S_IRWXU) == 0 else {
            throw E58TestError.mkdirFailed
        }
    }

    private func writeMarker(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    private func identity(_ url: URL) throws -> E58Identity {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw E58TestError.metadataUnavailable
        }
        return E58Identity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode & 0o7777)
        )
    }

    private func inspectionEvidence(
        _ outcome: CodexGhostRepairDestinationCanaryInspectionOutcome
    ) throws -> CodexGhostRepairDestinationCanaryEvidence {
        switch outcome {
        case let .needsPreparation(evidence), let .ready(evidence): evidence
        default: throw E58TestError.unexpectedOutcome
        }
    }

    private func preparationEvidence(
        _ outcome: CodexGhostRepairDestinationCanaryPreparationOutcome
    ) throws -> CodexGhostRepairDestinationCanaryEvidence {
        guard case let .ready(evidence) = outcome else {
            throw E58TestError.unexpectedOutcome
        }
        return evidence
    }

    private func assertBlocked(
        _ outcome: CodexGhostRepairDestinationCanaryPreparationOutcome,
        contains code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .blocked(_, message) = outcome else {
            return XCTFail("Expected blocked outcome", file: file, line: line)
        }
        XCTAssertTrue(message.contains(code), file: file, line: line)
    }

    private func assertPathRedacted(
        _ message: String,
        fixture: E58Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(message.contains(fixture.allowedParent.path), file: file, line: line)
        XCTAssertFalse(message.contains("/Users/"), file: file, line: line)
        XCTAssertTrue(message.contains("Clear filesystem paths are unavailable"), file: file, line: line)
    }
}

private struct E58Fixture: @unchecked Sendable {
    let allowedParent: URL
    let applicationSupport: URL
    let bundleRoot: URL
    let effectMarker: URL
    let privateURLs: [URL]
}

private struct E58Identity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
}

private enum E58TestError: Error {
    case injectedFailure
    case metadataUnavailable
    case mkdirFailed
    case unexpectedOutcome
}

private final class E58CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let failAt: Int?
    private var storedCalls = 0
    private var storedURLs: [URL] = []

    init(failAt: Int? = nil) {
        self.failAt = failAt
    }

    var createCalls: Int { lock.withLock { storedCalls } }
    var createdURLs: [URL] { lock.withLock { storedURLs } }

    func create(_ url: URL) throws {
        let call = lock.withLock { () -> Int in
            storedCalls += 1
            return storedCalls
        }
        if call == failAt { throw E58TestError.injectedFailure }
        guard mkdir(url.path, S_IRWXU) == 0 else {
            throw E58TestError.mkdirFailed
        }
        lock.withLock { storedURLs.append(url) }
    }
}

private extension CodexGhostRepairDestinationCanaryPreparationOutcome {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isEvidenceConsumed: Bool {
        if case let .blocked(_, message) = self {
            return message.contains("frozen-evidence-consumed")
        }
        return false
    }
}
