import XCTest
@testable import AgentSessionManagerCore

final class ArchiveIsolatedSessionAcceptanceTests: XCTestCase {
    private let nativeID = "01900000-0000-7000-8000-000000000001"
    private let rootPath = "/tmp/asm-isolated-archive-fixture"
    private let title = "[ASM-ISOLATED-ARCHIVE] disposable fixture"

    func testGateAcceptsOnlyExactSacrificialSessionAndCompleteEvidence() throws {
        let snapshot = try ArchiveIsolatedSessionAcceptanceGate.attestedSnapshot(
            environment: readyEnvironment(),
            snapshot: try readySnapshot(protectionComplete: false)
        )
        let authorization = try ArchiveIsolatedSessionAcceptanceGate.authorize(
            environment: readyEnvironment(),
            snapshot: snapshot
        )

        XCTAssertEqual(authorization.session.nativeID, nativeID)
        XCTAssertEqual(authorization.confirmationToken, "ARCHIVE-ISOLATED-\(nativeID.uppercased())")
        XCTAssertEqual(authorization.checkpoint, snapshot.checkpoint)
    }

    func testGateRejectsMissingOptInBeforeSelectingSession() throws {
        var environment = readyEnvironment()
        environment.removeValue(
            forKey: ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.enabled
        )

        XCTAssertThrowsError(
            try ArchiveIsolatedSessionAcceptanceGate.authorize(
                environment: environment,
                snapshot: try readySnapshot()
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveIsolatedSessionAcceptanceError,
                .invalidEnvironment("explicit mutation opt-in is missing")
            )
        }
    }

    func testGateRejectsConfirmationTitleAndRootMismatch() throws {
        let mismatchCases: [(String, String, ArchiveIsolatedSessionAcceptanceError)] = [
            (
                ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.confirmation,
                "ARCHIVE-WRONG",
                .confirmationMismatch
            ),
            (
                ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.expectedTitle,
                "[ASM-ISOLATED-ARCHIVE] another title",
                .sessionMismatch("the exact frozen title does not match")
            ),
            (
                ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.workingDirectory,
                "/tmp/asm-isolated-archive-other",
                .sessionMismatch("the exact frozen working directory does not match")
            ),
        ]

        for (key, value, expectedError) in mismatchCases {
            var environment = readyEnvironment()
            environment[key] = value
            XCTAssertThrowsError(
                try ArchiveIsolatedSessionAcceptanceGate.authorize(
                    environment: environment,
                    snapshot: try readySnapshot()
                )
            ) { error in
                XCTAssertEqual(error as? ArchiveIsolatedSessionAcceptanceError, expectedError)
            }
        }
    }

    func testGateRejectsNonSacrificialNamesBeforeLifecycleExecution() throws {
        var wrongTitleEnvironment = readyEnvironment()
        wrongTitleEnvironment[ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.expectedTitle]
            = "ordinary session"
        XCTAssertThrowsError(
            try ArchiveIsolatedSessionAcceptanceGate.authorize(
                environment: wrongTitleEnvironment,
                snapshot: try readySnapshot(title: "ordinary session")
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveIsolatedSessionAcceptanceError,
                .invalidEnvironment(
                    "expected title must begin with [ASM-ISOLATED-ARCHIVE]"
                )
            )
        }

        var wrongRootEnvironment = readyEnvironment()
        wrongRootEnvironment[ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.workingDirectory]
            = "/tmp/ordinary-project"
        XCTAssertThrowsError(
            try ArchiveIsolatedSessionAcceptanceGate.authorize(
                environment: wrongRootEnvironment,
                snapshot: try readySnapshot(workingDirectory: "/tmp/ordinary-project")
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveIsolatedSessionAcceptanceError,
                .invalidEnvironment(
                    "working directory basename must begin with asm-isolated-archive-"
                )
            )
        }
    }

    func testGateRejectsIncompleteRuntimeProtectionAndDescendantEvidence() throws {
        let cases: [(ProviderInventorySnapshot, ArchiveIsolatedSessionAcceptanceError)] = [
            (
                try readySnapshot(inventoryComplete: false),
                .evidenceUnavailable("official inventory is incomplete")
            ),
            (
                try readySnapshot(runtimeVersion: "0.148.0"),
                .evidenceUnavailable("runtime is outside the verified lifecycle contract")
            ),
            (
                try readySnapshot(descendantCount: 1),
                .protectedSession("the isolated session has 1 descendant(s)")
            ),
        ]

        for (snapshot, expectedError) in cases {
            XCTAssertThrowsError(
                try ArchiveIsolatedSessionAcceptanceGate.authorize(
                    environment: readyEnvironment(),
                    snapshot: snapshot
                )
            ) { error in
                XCTAssertEqual(error as? ArchiveIsolatedSessionAcceptanceError, expectedError)
            }
        }
    }

    func testAttestationIsExactShortLivedAndCannotOverrideProtection() throws {
        let now = Date(timeIntervalSince1970: 1_800_300_000)
        var expired = readyEnvironment(now: now)
        expired[ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.authorityExpiresAt]
            = ISO8601DateFormatter().string(from: now)
        XCTAssertThrowsError(try ArchiveIsolatedSessionAcceptanceGate.attestedSnapshot(
            environment: expired,
            snapshot: try readySnapshot(protectionComplete: false),
            now: now
        ))

        var pinned = readyEnvironment(now: now)
        pinned[ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.completePinnedIDs] = nativeID
        XCTAssertThrowsError(try ArchiveIsolatedSessionAcceptanceGate.attestedSnapshot(
            environment: pinned,
            snapshot: try readySnapshot(protectionComplete: false),
            now: now
        )) { error in
            XCTAssertEqual(
                error as? ArchiveIsolatedSessionAcceptanceError,
                .protectedSession("the complete attested pinned list contains the target")
            )
        }

        var current = readyEnvironment(now: now)
        current["CODEX_THREAD_ID"] = nativeID
        XCTAssertThrowsError(try ArchiveIsolatedSessionAcceptanceGate.attestedSnapshot(
            environment: current,
            snapshot: try readySnapshot(protectionComplete: false),
            now: now
        )) { error in
            XCTAssertEqual(
                error as? ArchiveIsolatedSessionAcceptanceError,
                .protectedSession("the target matches this process CODEX_THREAD_ID")
            )
        }

        let providerProtected = try readySnapshot(
            protectionComplete: false,
            protection: SessionProtection(
                isRunning: true,
                isRunningKnown: true,
                isCurrentKnown: false
            )
        )
        XCTAssertThrowsError(try ArchiveIsolatedSessionAcceptanceGate.attestedSnapshot(
            environment: readyEnvironment(now: now),
            snapshot: providerProtected,
            now: now
        )) { error in
            XCTAssertEqual(
                error as? ArchiveIsolatedSessionAcceptanceError,
                .protectedSession("Running")
            )
        }
    }

    func testLiveArchiveOfExplicitIsolatedSessionWhenSeparatelyAuthorized() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.enabled]
            == ArchiveIsolatedSessionAcceptanceGate.requiredOptIn else {
            throw XCTSkip(
                "Set the dedicated isolated Archive acceptance environment only after creating a disposable session. Ordinary live smoke tests never enable mutation."
            )
        }

        let nativeTransport = CodexArchiveMutationTransport()
        let transport = ArchiveIsolatedAcceptanceTransport(
            base: nativeTransport,
            environment: environment
        )
        let initialSnapshot = try await transport.inventorySnapshot()
        let authorization = try ArchiveIsolatedSessionAcceptanceGate.authorize(
            environment: environment,
            snapshot: initialSnapshot
        )
        let createdAt = canonicalDate(Date())
        let expiresAt = createdAt.addingTimeInterval(120)
        let item = PersistentPreviewItem(
            managerKey: authorization.session.id,
            nativeSessionID: authorization.session.nativeID,
            expectedNativeState: .active,
            expectedProtectionHash: try ArchiveExecutionHasher.protectionHash(
                for: authorization.session
            ),
            expectedTitle: authorization.session.title,
            expectedProjectID: authorization.session.project?.id,
            knownSizeBytes: nil
        )
        let preview = PersistentOperationPreview(
            id: UUID(),
            provider: .codex,
            operation: .archive,
            confirmationTokenHash: ArchiveExecutionHasher.confirmationTokenHash(
                authorization.confirmationToken
            ),
            manifestHash: try ArchiveExecutionHasher.manifestHash(
                provider: .codex,
                operation: .archive,
                providerInventoryHash: authorization.checkpoint.inventoryHash,
                runtimeVersion: try XCTUnwrap(authorization.checkpoint.runtimeVersion),
                reconciliationTimestamp: authorization.checkpoint.refreshedAt,
                createdAt: createdAt,
                expiresAt: expiresAt,
                items: [item]
            ),
            providerInventoryHash: authorization.checkpoint.inventoryHash,
            createdAt: createdAt,
            expiresAt: expiresAt,
            items: [item]
        )

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "asm-isolated-archive-acceptance-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(
            databaseURL: directory.appendingPathComponent("acceptance.sqlite3")
        )
        defer { store.close() }
        let coordinator = ArchiveAuthorizationCoordinator(
            store: store,
            executor: ArchiveMutationExecutor(transport: transport)
        )

        _ = try await coordinator.prepare(preview, checkpoint: authorization.checkpoint)
        let report = try await coordinator.execute(
            previewID: preview.id,
            confirmationToken: authorization.confirmationToken
        )

        print(
            "Isolated Archive acceptance report: id=\(report.id.uuidString) preview=\(report.previewID.uuidString) nativeID=\(authorization.session.nativeID) outcome=\(report.outcome.rawValue) observed=\(report.items[0].observedNativeState.rawValue) errorCode=\(report.items[0].errorCode ?? "none") message=\(report.items[0].errorMessage ?? "none")"
        )
        XCTAssertEqual(report.outcome, .success)
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items[0].managerKey, authorization.session.id)
        XCTAssertEqual(report.items[0].observedNativeState, .archived)
        XCTAssertEqual(try store.operationPreview(id: preview.id)?.status, .consumed)
        XCTAssertEqual(try store.operationReport(id: report.id), report)
    }

    private func readyEnvironment(now: Date = Date()) -> [String: String] {
        [
            ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.enabled:
                ArchiveIsolatedSessionAcceptanceGate.requiredOptIn,
            ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.nativeSessionID: nativeID,
            ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.expectedTitle: title,
            ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.workingDirectory: rootPath,
            ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.confirmation:
                "ARCHIVE-ISOLATED-\(nativeID.uppercased())",
            ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.authorityExpiresAt:
                ISO8601DateFormatter().string(from: now.addingTimeInterval(120)),
            ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.otherHostsStopped:
                "I_ATTEST_ALL_OTHER_CODEX_HOSTS_ARE_STOPPED_FOR_\(nativeID.uppercased())",
            ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.targetNotCurrent:
                "I_ATTEST_TARGET_IS_NOT_CURRENT_\(nativeID.uppercased())",
            ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.completePinnedIDs: "NONE",
            ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.pinCheckComplete:
                "I_ATTEST_PINNED_LIST_IS_COMPLETE_FOR_\(nativeID.uppercased())",
        ]
    }

    private func readySnapshot(
        title: String? = nil,
        workingDirectory: String? = nil,
        runtimeVersion: String = "0.147.0",
        inventoryComplete: Bool = true,
        protectionComplete: Bool = true,
        descendantCount: Int = 0,
        protection: SessionProtection = SessionProtection()
    ) throws -> ProviderInventorySnapshot {
        let session = AgentSession(
            system: .codex,
            nativeID: nativeID,
            title: title ?? self.title,
            workingDirectory: workingDirectory ?? rootPath,
            updatedAt: Date(timeIntervalSince1970: 1_800_300_000),
            sizeBytes: nil,
            nativeState: .active,
            protection: protection,
            descendantCount: descendantCount,
            descendantCountKnown: true
        )
        return ProviderInventorySnapshot(
            provider: .codex,
            runtimeVersion: runtimeVersion,
            inventoryHash: try InventorySnapshotHasher.hash(provider: .codex, sessions: [session]),
            observedAt: Date(timeIntervalSince1970: 1_800_300_000),
            inventoryComplete: inventoryComplete,
            protectionComplete: protectionComplete,
            sessions: [session]
        )
    }

    private func canonicalDate(_ date: Date) -> Date {
        Date(
            timeIntervalSince1970:
                (date.timeIntervalSince1970 * 1_000).rounded() / 1_000
        )
    }
}

private enum ArchiveIsolatedSessionAcceptanceError: Error, Equatable, LocalizedError {
    case invalidEnvironment(String)
    case confirmationMismatch
    case evidenceUnavailable(String)
    case sessionMismatch(String)
    case protectedSession(String)

    var errorDescription: String? {
        switch self {
        case let .invalidEnvironment(message):
            "Invalid isolated Archive acceptance environment: \(message)"
        case .confirmationMismatch:
            "The isolated Archive acceptance confirmation does not match the exact full session ID."
        case let .evidenceUnavailable(message):
            "Isolated Archive acceptance evidence is unavailable: \(message)"
        case let .sessionMismatch(message):
            "The selected isolated Archive session does not match: \(message)"
        case let .protectedSession(message):
            "The isolated Archive session is protected: \(message)"
        }
    }
}

private struct ArchiveIsolatedSessionAcceptanceAuthorization {
    let session: AgentSession
    let checkpoint: ProviderCheckpointRecord
    let confirmationToken: String
}

private enum ArchiveIsolatedSessionAcceptanceGate {
    static let requiredOptIn = "I_UNDERSTAND_THIS_ARCHIVES_ONE_REAL_DISPOSABLE_SESSION"
    static let titlePrefix = "[ASM-ISOLATED-ARCHIVE]"
    static let workingDirectoryPrefix = "asm-isolated-archive-"

    enum EnvironmentKey {
        static let enabled = "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE"
        static let nativeSessionID = "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_SESSION_ID"
        static let expectedTitle = "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_EXPECTED_TITLE"
        static let workingDirectory = "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_WORKING_DIRECTORY"
        static let confirmation = "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_CONFIRMATION"
        static let authorityExpiresAt = "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_AUTHORITY_EXPIRES_AT"
        static let otherHostsStopped = "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_OTHER_HOSTS_STOPPED"
        static let targetNotCurrent = "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_TARGET_NOT_CURRENT"
        static let completePinnedIDs = "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_COMPLETE_PINNED_IDS"
        static let pinCheckComplete = "AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_PIN_CHECK_COMPLETE"
    }

    static func attestedSnapshot(
        environment: [String: String],
        snapshot: ProviderInventorySnapshot,
        now: Date = Date()
    ) throws -> ProviderInventorySnapshot {
        guard let nativeSessionID = environment[EnvironmentKey.nativeSessionID],
              UUID(uuidString: nativeSessionID) != nil else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "a canonical full UUID session ID is required before attestation"
            )
        }
        let upperID = nativeSessionID.uppercased()
        guard environment["CODEX_THREAD_ID"]?.lowercased()
            != nativeSessionID.lowercased() else {
            throw ArchiveIsolatedSessionAcceptanceError.protectedSession(
                "the target matches this process CODEX_THREAD_ID"
            )
        }
        guard environment[EnvironmentKey.otherHostsStopped]
            == "I_ATTEST_ALL_OTHER_CODEX_HOSTS_ARE_STOPPED_FOR_\(upperID)" else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "an exact all-other-hosts-stopped attestation is required"
            )
        }
        guard environment[EnvironmentKey.targetNotCurrent]
            == "I_ATTEST_TARGET_IS_NOT_CURRENT_\(upperID)" else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "an exact target-not-current attestation is required"
            )
        }
        guard environment[EnvironmentKey.pinCheckComplete]
            == "I_ATTEST_PINNED_LIST_IS_COMPLETE_FOR_\(upperID)" else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "a complete pinned-list attestation is required"
            )
        }
        guard let expiresText = environment[EnvironmentKey.authorityExpiresAt],
              let expiresAt = ISO8601DateFormatter().date(from: expiresText),
              expiresAt > now,
              expiresAt.timeIntervalSince(now) <= 300 else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "authority expiry must be a future ISO-8601 instant no more than five minutes away"
            )
        }
        guard let pinnedText = environment[EnvironmentKey.completePinnedIDs] else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "the complete pinned-ID list is required; use NONE for an empty list"
            )
        }
        let pinnedIDs: Set<String>
        if pinnedText == "NONE" {
            pinnedIDs = []
        } else {
            let values = pinnedText.split(separator: ",", omittingEmptySubsequences: false)
            guard !values.isEmpty,
                  values.allSatisfy({ UUID(uuidString: String($0)) != nil }) else {
                throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                    "the complete pinned-ID list must be NONE or comma-separated full UUIDs"
                )
            }
            pinnedIDs = Set(values.map { String($0).lowercased() })
        }
        guard !pinnedIDs.contains(nativeSessionID.lowercased()) else {
            throw ArchiveIsolatedSessionAcceptanceError.protectedSession(
                "the complete attested pinned list contains the target"
            )
        }
        guard snapshot.provider == .codex, snapshot.inventoryComplete else {
            throw ArchiveIsolatedSessionAcceptanceError.evidenceUnavailable(
                "official inventory is incomplete"
            )
        }
        let matches = snapshot.sessions.filter {
            $0.nativeID.lowercased() == nativeSessionID.lowercased()
        }
        guard matches.count == 1 else {
            throw ArchiveIsolatedSessionAcceptanceError.sessionMismatch(
                "complete inventory must contain exactly one matching native ID"
            )
        }
        let providerProtection = matches[0].protection
        let positiveLabels = [
            providerProtection.isPinned ? "Pinned" : nil,
            providerProtection.isRunning ? "Running" : nil,
            providerProtection.isCurrent ? "Current" : nil,
            providerProtection.hasPinnedDescendant ? "Pinned descendant" : nil,
        ].compactMap { $0 }
        guard positiveLabels.isEmpty else {
            throw ArchiveIsolatedSessionAcceptanceError.protectedSession(
                positiveLabels.joined(separator: ", ")
            )
        }

        var attestedSessions: [AgentSession] = []
        for var session in snapshot.sessions {
            guard session.nativeID.lowercased() == nativeSessionID.lowercased() else {
                attestedSessions.append(session)
                continue
            }
            session.protection = try ProtectionAuthorityPolicy.resolve(
                system: .codex,
                observations: [
                    ProtectionAuthorityObservation(
                        kind: .pinned,
                        isProtected: false,
                        source: .explicitCrossHostAuthority,
                        scope: .allRelevantHosts
                    ),
                    ProtectionAuthorityObservation(
                        kind: .running,
                        isProtected: false,
                        source: .explicitCrossHostAuthority,
                        scope: .allRelevantHosts
                    ),
                    ProtectionAuthorityObservation(
                        kind: .current,
                        isProtected: false,
                        source: .explicitCrossHostAuthority,
                        scope: .allRelevantHosts
                    ),
                    ProtectionAuthorityObservation(
                        kind: .pinnedDescendant,
                        isProtected: false,
                        source: .explicitCrossHostAuthority,
                        scope: .allRelevantHosts
                    ),
                ]
            )
            attestedSessions.append(session)
        }
        let attestedHash = try InventorySnapshotHasher.hash(
            provider: snapshot.provider,
            sessions: attestedSessions,
            archiveScopeNodes: snapshot.archiveScopeNodes,
            archiveScopeComplete: snapshot.archiveScopeComplete
        )
        return ProviderInventorySnapshot(
            provider: snapshot.provider,
            runtimeVersion: snapshot.runtimeVersion,
            inventoryHash: attestedHash,
            observedAt: snapshot.observedAt,
            inventoryComplete: snapshot.inventoryComplete,
            protectionComplete: true,
            sessions: attestedSessions,
            archiveScopeNodes: snapshot.archiveScopeNodes,
            archiveScopeComplete: snapshot.archiveScopeComplete,
            errorCode: snapshot.errorCode,
            errorMessage: snapshot.errorMessage
        )
    }

    static func authorize(
        environment: [String: String],
        snapshot: ProviderInventorySnapshot
    ) throws -> ArchiveIsolatedSessionAcceptanceAuthorization {
        guard environment[EnvironmentKey.enabled] == requiredOptIn else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "explicit mutation opt-in is missing"
            )
        }
        guard let nativeSessionID = environment[EnvironmentKey.nativeSessionID],
              let uuid = UUID(uuidString: nativeSessionID),
              uuid.uuidString.lowercased() == nativeSessionID.lowercased() else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "a canonical full UUID session ID is required"
            )
        }
        guard let expectedTitle = environment[EnvironmentKey.expectedTitle],
              expectedTitle.hasPrefix(titlePrefix) else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "expected title must begin with \(titlePrefix)"
            )
        }
        guard let workingDirectory = environment[EnvironmentKey.workingDirectory],
              workingDirectory.hasPrefix("/") else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "an absolute isolated working directory is required"
            )
        }
        let standardizedWorkingDirectory = URL(
            fileURLWithPath: workingDirectory
        ).standardizedFileURL.path
        guard URL(fileURLWithPath: standardizedWorkingDirectory)
            .lastPathComponent.hasPrefix(workingDirectoryPrefix) else {
            throw ArchiveIsolatedSessionAcceptanceError.invalidEnvironment(
                "working directory basename must begin with \(workingDirectoryPrefix)"
            )
        }
        let confirmationToken = "ARCHIVE-ISOLATED-\(nativeSessionID.uppercased())"
        guard environment[EnvironmentKey.confirmation] == confirmationToken else {
            throw ArchiveIsolatedSessionAcceptanceError.confirmationMismatch
        }

        guard snapshot.provider == .codex else {
            throw ArchiveIsolatedSessionAcceptanceError.evidenceUnavailable(
                "provider identity is not Codex"
            )
        }
        guard snapshot.inventoryComplete else {
            throw ArchiveIsolatedSessionAcceptanceError.evidenceUnavailable(
                "official inventory is incomplete"
            )
        }
        guard snapshot.protectionComplete else {
            throw ArchiveIsolatedSessionAcceptanceError.evidenceUnavailable(
                "lifecycle protection evidence is incomplete"
            )
        }
        guard CodexAppServerProvider.supportsVerifiedLifecycleContract(
            snapshot.runtimeVersion
        ) else {
            throw ArchiveIsolatedSessionAcceptanceError.evidenceUnavailable(
                "runtime is outside the verified lifecycle contract"
            )
        }
        let exactMatches = snapshot.sessions.filter {
            $0.system == .codex && $0.nativeID.lowercased() == nativeSessionID.lowercased()
        }
        guard exactMatches.count == 1, let session = exactMatches.first else {
            throw ArchiveIsolatedSessionAcceptanceError.sessionMismatch(
                "complete inventory must contain exactly one matching native ID"
            )
        }
        guard session.id == "\(AgentSystem.codex.rawValue):\(session.nativeID)" else {
            throw ArchiveIsolatedSessionAcceptanceError.sessionMismatch(
                "manager identity does not match the native ID"
            )
        }
        guard session.title == expectedTitle else {
            throw ArchiveIsolatedSessionAcceptanceError.sessionMismatch(
                "the exact frozen title does not match"
            )
        }
        let sessionWorkingDirectory = URL(
            fileURLWithPath: session.workingDirectory
        ).standardizedFileURL.path
        guard sessionWorkingDirectory == standardizedWorkingDirectory else {
            throw ArchiveIsolatedSessionAcceptanceError.sessionMismatch(
                "the exact frozen working directory does not match"
            )
        }
        guard session.nativeState == .active else {
            throw ArchiveIsolatedSessionAcceptanceError.sessionMismatch(
                "native state must be Active"
            )
        }
        guard !session.protection.blocksLifecycleMutation else {
            throw ArchiveIsolatedSessionAcceptanceError.protectedSession(
                session.protection.labels.joined(separator: ", ")
            )
        }
        guard session.descendantCountKnown else {
            throw ArchiveIsolatedSessionAcceptanceError.evidenceUnavailable(
                "descendant scope is unknown"
            )
        }
        guard session.descendantCount == 0 else {
            throw ArchiveIsolatedSessionAcceptanceError.protectedSession(
                "the isolated session has \(session.descendantCount) descendant(s)"
            )
        }

        return ArchiveIsolatedSessionAcceptanceAuthorization(
            session: session,
            checkpoint: snapshot.checkpoint,
            confirmationToken: confirmationToken
        )
    }
}

private actor ArchiveIsolatedAcceptanceTransport: ArchiveMutationTransport {
    private let base: CodexArchiveMutationTransport
    private let environment: [String: String]

    init(base: CodexArchiveMutationTransport, environment: [String: String]) {
        self.base = base
        self.environment = environment
    }

    func inventorySnapshot() async throws -> ProviderInventorySnapshot {
        try ArchiveIsolatedSessionAcceptanceGate.attestedSnapshot(
            environment: environment,
            snapshot: await base.inventorySnapshot()
        )
    }

    func archive(nativeSessionID: String) async throws {
        guard nativeSessionID.lowercased()
            == environment[ArchiveIsolatedSessionAcceptanceGate.EnvironmentKey.nativeSessionID]?
                .lowercased() else {
            throw ArchiveIsolatedSessionAcceptanceError.sessionMismatch(
                "mutation transport received an ID outside the exact attestation"
            )
        }
        try await base.archive(nativeSessionID: nativeSessionID)
    }
}
