@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairLiveReadOnlySafetySourceTests: XCTestCase {
    private let runtimeVersion = "codex-cli 0.148.0"
    private let targetID = "019f-test-ghost"

    func testOneFreshInventorySuppliesAbsencePinDescendantAndGateEvidence() async throws {
        let child = makeRecord(id: "child", parentThreadID: targetID)
        let inventory = makeInventory(
            descendantRecords: [child],
            pinnedThreadIDs: [targetID]
        )
        let rawSource = RecordingGhostRepairInventorySource(snapshot: inventory)
        let gate = CodexGhostRepairExecutionGate(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: true
        )
        let source = CodexGhostRepairLiveReadOnlySafetySource(
            source: rawSource,
            absenceContracts: try contractRegistry(runtimeVersion: runtimeVersion),
            executionGateSource: FixedGhostRepairExecutionGateSource(gate: gate)
        )

        let snapshot = try await source.ghostRepairSafetySnapshot(
            targetThreadIDs: [targetID]
        )
        let evidence = try CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: [targetID],
            snapshot: snapshot
        )

        XCTAssertTrue(snapshot.inventory.inventoryComplete)
        XCTAssertTrue(snapshot.inventory.protectionComplete)
        XCTAssertTrue(snapshot.inventory.archiveScopeComplete)
        XCTAssertEqual(snapshot.pinnedThreadIDs, [targetID])
        XCTAssertTrue(snapshot.pinnedInventoryComplete)
        XCTAssertTrue(snapshot.exactReadbacks[0].provesAbsence)
        XCTAssertEqual(evidence.protectionEvidence[0].descendantCount, 1)
        XCTAssertTrue(evidence.protectionEvidence[0].pinned)
        XCTAssertFalse(evidence.protectionEvidence[0].isEligible)
        XCTAssertTrue(evidence.executionGate.isClear)
        let inventoryCallCount = await rawSource.inventoryCallCount
        let exactReadThreadIDs = await rawSource.exactReadThreadIDs
        XCTAssertEqual(inventoryCallCount, 1)
        XCTAssertEqual(exactReadThreadIDs, [targetID])
    }

    func testEmptyContractRegistryKeepsMinus32600UnavailableAndFailsClosed() async throws {
        let rawSource = RecordingGhostRepairInventorySource(snapshot: makeInventory())
        let source = CodexGhostRepairLiveReadOnlySafetySource(
            source: rawSource,
            absenceContracts: CodexGhostRepairAbsenceContractRegistry(),
            executionGateSource: FixedGhostRepairExecutionGateSource(gate: clearGate)
        )

        let snapshot = try await source.ghostRepairSafetySnapshot(
            targetThreadIDs: [targetID]
        )

        XCTAssertEqual(snapshot.exactReadbacks[0].status, .unavailable)
        XCTAssertEqual(snapshot.exactReadbacks[0].evidenceKind, .rpcError)
        XCTAssertEqual(snapshot.exactReadbacks[0].rpcCode, -32600)
        XCTAssertNil(snapshot.exactReadbacks[0].absenceContract)
        XCTAssertThrowsError(try CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: [targetID],
            snapshot: snapshot
        ))
    }

    func testVersionDriftCannotReuseAbsenceContract() async throws {
        let rawSource = RecordingGhostRepairInventorySource(
            snapshot: makeInventory(runtimeVersion: "codex-cli 0.149.0")
        )
        let source = CodexGhostRepairLiveReadOnlySafetySource(
            source: rawSource,
            absenceContracts: try contractRegistry(runtimeVersion: runtimeVersion),
            executionGateSource: FixedGhostRepairExecutionGateSource(gate: clearGate)
        )

        let snapshot = try await source.ghostRepairSafetySnapshot(
            targetThreadIDs: [targetID]
        )

        XCTAssertEqual(snapshot.exactReadbacks[0].status, .unavailable)
        XCTAssertNil(snapshot.exactReadbacks[0].absenceContract)
        XCTAssertThrowsError(try CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: [targetID],
            snapshot: snapshot
        ))
    }

    func testIncompletePinOrDescendantEvidenceFailsClosed() async throws {
        for inventory in [
            makeInventory(pinStateAvailable: false),
            makeInventory(descendantGraphComplete: false),
        ] {
            let source = CodexGhostRepairLiveReadOnlySafetySource(
                source: RecordingGhostRepairInventorySource(snapshot: inventory),
                absenceContracts: try contractRegistry(runtimeVersion: runtimeVersion),
                executionGateSource: FixedGhostRepairExecutionGateSource(gate: clearGate)
            )
            let snapshot = try await source.ghostRepairSafetySnapshot(
                targetThreadIDs: [targetID]
            )
            XCTAssertFalse(snapshot.inventory.protectionComplete)
            XCTAssertThrowsError(try CodexGhostRepairSafetyCollector.collect(
                targetThreadIDs: [targetID],
                snapshot: snapshot
            ))
        }
    }

    func testInvalidTargetSetStopsBeforeAnyLiveRead() async throws {
        let rawSource = RecordingGhostRepairInventorySource(snapshot: makeInventory())
        let source = CodexGhostRepairLiveReadOnlySafetySource(
            source: rawSource,
            absenceContracts: try contractRegistry(runtimeVersion: runtimeVersion),
            executionGateSource: FixedGhostRepairExecutionGateSource(gate: clearGate)
        )

        do {
            _ = try await source.ghostRepairSafetySnapshot(
                targetThreadIDs: [targetID, targetID]
            )
            XCTFail("Expected duplicate target IDs to fail before live reads.")
        } catch {
            XCTAssertNotNil(error as? CodexGhostRepairError)
        }

        let inventoryCallCount = await rawSource.inventoryCallCount
        let exactReadThreadIDs = await rawSource.exactReadThreadIDs
        XCTAssertEqual(inventoryCallCount, 0)
        XCTAssertEqual(exactReadThreadIDs, [])
    }

    func testUnavailableOperationalGateCanNeverAuthorizeExecution() async throws {
        let source = CodexGhostRepairLiveReadOnlySafetySource(
            source: RecordingGhostRepairInventorySource(snapshot: makeInventory()),
            absenceContracts: try contractRegistry(runtimeVersion: runtimeVersion),
            executionGateSource: CodexGhostRepairUnavailableExecutionGateSource()
        )

        let snapshot = try await source.ghostRepairSafetySnapshot(
            targetThreadIDs: [targetID]
        )
        let evidence = try CodexGhostRepairSafetyCollector.collect(
            targetThreadIDs: [targetID],
            snapshot: snapshot
        )

        XCTAssertTrue(evidence.protectionEvidence[0].isEligible)
        XCTAssertFalse(evidence.executionGate.isClear)
    }

    func testMacOSOperationalGateCollectsClearReadOnlyEvidence() async throws {
        let configuration = operationalConfiguration()
        let source = CodexGhostRepairMacOSOperationalGateSource(
            configuration: configuration,
            commandRunner: FixedGhostRepairCommandRunner(
                processResult: CodexGhostRepairCommandResult(
                    terminationStatus: 0,
                    standardOutput: """
                    120 1 /Applications/Codex.app/Contents/Frameworks/Electron Framework.framework/Helpers/browser_crashpad_handler
                    121 1 /Applications/Codex.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler
                    122 1 /Applications/ChatGPT.app/Contents/Frameworks/Electron Framework.framework/Helpers/browser_crashpad_handler
                    123 1 /Applications/ChatGPT.app/Contents/Frameworks/Electron Framework.framework/Helpers/browser_crashpad_handler
                    124 1 /Applications/ChatGPT.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler
                    125 1 /Applications/ChatGPT.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler
                    126 1 /usr/bin/unrelated

                    """
                ),
                lsofResults: Dictionary(
                    uniqueKeysWithValues: configuration.databaseURLsForTests.map {
                        ($0.path, CodexGhostRepairCommandResult(
                            terminationStatus: 1,
                            standardOutput: ""
                        ))
                    }
                )
            ),
            fileSystem: FixedGhostRepairFileSystemProbe(
                sizes: Dictionary(
                    uniqueKeysWithValues: configuration.databaseURLsForTests.map {
                        ($0.path, 1_024)
                    }
                ),
                availableBytes: 128 * 1_024 * 1_024
            )
        )

        let gate = try await source.ghostRepairExecutionGate()

        XCTAssertTrue(gate.isClear)
        XCTAssertTrue(gate.codexFullyExited)
        XCTAssertEqual(
            gate.desktopProcessEvidence,
            [
                .init(kind: .codexCrashReporter, processCount: 2),
                .init(kind: .chatGPTCrashReporter, processCount: 4),
            ]
        )
        XCTAssertEqual(gate.blockingDesktopProcessEvidence, [])
        XCTAssertEqual(gate.openHandleOwnerEvidence, [])
        XCTAssertEqual(
            gate.nonBlockingDesktopProcessEvidence,
            gate.desktopProcessEvidence
        )
    }

    func testMacOSOperationalGateReportsProcessesHandlesAndCapacityWithoutClearing() async throws {
        let configuration = operationalConfiguration()
        var lsof = Dictionary(
            uniqueKeysWithValues: configuration.databaseURLsForTests.map {
                ($0.path, CodexGhostRepairCommandResult(
                    terminationStatus: 1,
                    standardOutput: ""
                ))
            }
        )
        lsof[configuration.desktopDatabaseURL.path] = CodexGhostRepairCommandResult(
            terminationStatus: 0,
            standardOutput: "p321\ncCodex\nf4u\nn\(configuration.desktopDatabaseURL.path)\n"
        )
        let source = CodexGhostRepairMacOSOperationalGateSource(
            configuration: configuration,
            commandRunner: FixedGhostRepairCommandRunner(
                processResult: CodexGhostRepairCommandResult(
                    terminationStatus: 0,
                    standardOutput: """
                    321 1 /Applications/Codex.app/Contents/MacOS/Codex
                    322 321 /Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper
                    323 321 /Applications/Codex.app/Contents/Frameworks/Codex Helper (Renderer).app/Contents/MacOS/Codex Helper (Renderer)
                    3231 321 /Applications/Codex.app/Contents/Resources/codex
                    3232 321 /Applications/Codex.app/Contents/Frameworks/Electron Framework.framework/Helpers/browser_crashpad_handler
                    324 1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
                    325 324 /Applications/ChatGPT.app/Contents/Frameworks/ChatGPT Helper.app/Contents/MacOS/ChatGPT Helper
                    3251 324 /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host
                    3252 324 /Applications/ChatGPT.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler
                    326 1 /usr/bin/unrelated

                    """
                ),
                lsofResults: lsof
            ),
            fileSystem: FixedGhostRepairFileSystemProbe(
                sizes: Dictionary(
                    uniqueKeysWithValues: configuration.databaseURLsForTests.map {
                        ($0.path, 10_000_000)
                    }
                ),
                availableBytes: 1
            )
        )

        let gate = try await source.ghostRepairExecutionGate()

        XCTAssertFalse(gate.codexFullyExited)
        XCTAssertEqual(
            gate.desktopProcessEvidence,
            [
                CodexGhostRepairDesktopProcessEvidence(
                    kind: .codexApplication,
                    processCount: 1
                ),
                CodexGhostRepairDesktopProcessEvidence(
                    kind: .codexHelper,
                    processCount: 3
                ),
                CodexGhostRepairDesktopProcessEvidence(
                    kind: .codexCrashReporter,
                    processCount: 1
                ),
                CodexGhostRepairDesktopProcessEvidence(
                    kind: .chatGPTApplication,
                    processCount: 1
                ),
                CodexGhostRepairDesktopProcessEvidence(
                    kind: .chatGPTHelper,
                    processCount: 2
                ),
                CodexGhostRepairDesktopProcessEvidence(
                    kind: .chatGPTCrashReporter,
                    processCount: 1
                ),
            ]
        )
        XCTAssertEqual(gate.desktopOpenHandleCount, 1)
        XCTAssertEqual(
            gate.openHandleOwnerEvidence,
            [
                CodexGhostRepairOpenHandleOwnerEvidence(
                    databaseRole: .desktop,
                    processIdentifier: 321,
                    parentProcessIdentifier: 1,
                    processName: "Codex",
                    executableName: "Codex",
                    processKind: .codexApplication,
                    ownerApplication: .codexDesktop,
                    fileDescriptorCount: 1
                ),
            ]
        )
        XCTAssertFalse(gate.capacitySufficient)
        XCTAssertFalse(gate.isClear)
    }

    func testMacOSOperationalGateGroupsDescriptorsByExactOwnerAndRedactsPaths()
        async throws
    {
        let configuration = operationalConfiguration()
        var lsof = Dictionary(
            uniqueKeysWithValues: configuration.databaseURLsForTests.map {
                ($0.path, CodexGhostRepairCommandResult(
                    terminationStatus: 1,
                    standardOutput: ""
                ))
            }
        )
        lsof[configuration.stateDatabaseURL.path] = .init(
            terminationStatus: 0,
            standardOutput: """
            p801
            ccodex
            f10u
            n\(configuration.stateDatabaseURL.path)
            f11u
            n\(configuration.stateDatabaseURL.path)

            """
        )
        let source = CodexGhostRepairMacOSOperationalGateSource(
            configuration: configuration,
            commandRunner: FixedGhostRepairCommandRunner(
                processResult: .init(
                    terminationStatus: 0,
                    standardOutput: """
                    700 1 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
                    801 700 /Users/test/.vscode/extensions/openai.chatgpt-26.825.51511-darwin-arm64/bin/macos-aarch64/codex app-server

                    """
                ),
                lsofResults: lsof
            ),
            fileSystem: FixedGhostRepairFileSystemProbe(
                sizes: Dictionary(
                    uniqueKeysWithValues: configuration.databaseURLsForTests.map {
                        ($0.path, 1_024)
                    }
                ),
                availableBytes: 128 * 1_024 * 1_024
            )
        )

        let gate = try await source.ghostRepairExecutionGate()

        XCTAssertTrue(gate.codexFullyExited)
        XCTAssertEqual(gate.stateOpenHandleCount, 2)
        XCTAssertFalse(gate.isClear)
        XCTAssertEqual(gate.openHandleOwnerEvidence?.count, 1)
        let owner = try XCTUnwrap(gate.openHandleOwnerEvidence?.first)
        XCTAssertEqual(owner.databaseRole, .state)
        XCTAssertEqual(owner.processIdentifier, 801)
        XCTAssertEqual(owner.parentProcessIdentifier, 700)
        XCTAssertEqual(owner.processName, "codex")
        XCTAssertEqual(owner.executableName, "codex")
        XCTAssertEqual(owner.parentProcessName, "Electron")
        XCTAssertNil(owner.processKind)
        XCTAssertEqual(
            owner.ownerApplication,
            .visualStudioCodeOpenAIExtension
        )
        XCTAssertEqual(owner.fileDescriptorCount, 2)
        XCTAssertFalse(owner.userFacingDescription.contains("/test/.codex"))
        XCTAssertFalse(owner.userFacingDescription.contains("/.vscode/"))
        XCTAssertTrue(
            owner.userFacingDescription.contains(
                "Close Visual Studio Code (OpenAI extension), then check again."
            )
        )
        XCTAssertTrue(owner.userFacingDescription.contains("state_5.sqlite"))
    }

    func testMacOSOperationalGateFailsClosedOnIncompleteInspection() async throws {
        let configuration = operationalConfiguration()
        let source = CodexGhostRepairMacOSOperationalGateSource(
            configuration: configuration,
            commandRunner: FixedGhostRepairCommandRunner(
                processResult: CodexGhostRepairCommandResult(
                    terminationStatus: 0,
                    standardOutput: ""
                ),
                lsofResults: Dictionary(
                    uniqueKeysWithValues: configuration.databaseURLsForTests.map {
                        ($0.path, CodexGhostRepairCommandResult(
                            terminationStatus: 2,
                            standardOutput: ""
                        ))
                    }
                )
            ),
            fileSystem: FixedGhostRepairFileSystemProbe(
                sizes: [:],
                availableBytes: 0
            )
        )

        do {
            _ = try await source.ghostRepairExecutionGate()
            XCTFail("Expected incomplete lsof evidence to fail closed.")
        } catch {
            XCTAssertNotNil(error as? CodexGhostRepairError)
        }
    }

    func testMacOSOperationalGateAllowsMissingLegacyHistoryDatabase() async throws {
        let configuration = operationalConfiguration()
        let requiredURLs = configuration.databaseURLsForTests.filter {
            $0 != configuration.historyDatabaseURL
        }
        let source = CodexGhostRepairMacOSOperationalGateSource(
            configuration: configuration,
            commandRunner: FixedGhostRepairCommandRunner(
                processResult: .init(terminationStatus: 0, standardOutput: ""),
                lsofResults: Dictionary(
                    uniqueKeysWithValues: configuration.databaseURLsForTests.map {
                        ($0.path, .init(terminationStatus: 1, standardOutput: ""))
                    }
                )
            ),
            fileSystem: FixedGhostRepairFileSystemProbe(
                sizes: Dictionary(
                    uniqueKeysWithValues: requiredURLs.map { ($0.path, 1_024) }
                ),
                availableBytes: 128 * 1_024 * 1_024
            )
        )

        let gate = try await source.ghostRepairExecutionGate()

        XCTAssertTrue(gate.isClear)
        XCTAssertEqual(gate.historyOpenHandleCount, 0)
        XCTAssertEqual(gate.stateOpenHandleCount, 0)
        XCTAssertEqual(gate.threadHistoryOpenHandleCount, 0)
    }

    func testMacOSOperationalGateRejectsMissingRequiredThreadHistoryDatabase()
        async throws
    {
        let configuration = operationalConfiguration()
        let presentURLs = configuration.databaseURLsForTests.filter {
            $0 != configuration.threadHistoryDatabaseURL
        }
        let source = CodexGhostRepairMacOSOperationalGateSource(
            configuration: configuration,
            commandRunner: FixedGhostRepairCommandRunner(
                processResult: .init(terminationStatus: 0, standardOutput: ""),
                lsofResults: Dictionary(
                    uniqueKeysWithValues: configuration.databaseURLsForTests.map {
                        ($0.path, .init(terminationStatus: 1, standardOutput: ""))
                    }
                )
            ),
            fileSystem: FixedGhostRepairFileSystemProbe(
                sizes: Dictionary(
                    uniqueKeysWithValues: presentURLs.map { ($0.path, 1_024) }
                ),
                availableBytes: 128 * 1_024 * 1_024
            )
        )

        do {
            _ = try await source.ghostRepairExecutionGate()
            XCTFail("Expected missing thread history metadata to fail closed.")
        } catch let CodexGhostRepairError.invalidProtectionEvidence(message) {
            XCTAssertTrue(message.contains("thread_history_1.sqlite"))
        } catch {
            XCTFail("Expected invalidProtectionEvidence, found \(error)")
        }
    }

    private var clearGate: CodexGhostRepairExecutionGate {
        CodexGhostRepairExecutionGate(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: true
        )
    }

    private func contractRegistry(
        runtimeVersion: String
    ) throws -> CodexGhostRepairAbsenceContractRegistry {
        try CodexGhostRepairAbsenceContractRegistry(contracts: [
            ExactSessionAbsenceContract(
                provider: .codex,
                runtimeVersion: runtimeVersion,
                rpcCode: -32600,
                identifier: "thread_not_loaded",
                officialSourceURL: URL(
                    string: "https://developers.openai.com/codex/app-server"
                )!
            ),
        ])
    }

    private func makeInventory(
        runtimeVersion: String? = nil,
        descendantRecords: [CodexThreadRecord] = [],
        pinnedThreadIDs: Set<String> = [],
        pinStateAvailable: Bool = true,
        descendantGraphComplete: Bool = true
    ) -> CodexInventorySnapshot {
        CodexInventorySnapshot(
            serverInfo: CodexServerInfo(
                userAgent: "ghost-repair-live-read-only-test",
                codexHome: "/Users/example/.codex",
                platformFamily: "unix",
                platformOs: "macos"
            ),
            runtimeVersion: runtimeVersion ?? self.runtimeVersion,
            active: [],
            archived: [],
            descendantRecords: descendantRecords,
            descendantNativeStates: Dictionary(
                uniqueKeysWithValues: descendantRecords.map { ($0.id, .active) }
            ),
            descendantGraphComplete: descendantGraphComplete,
            descendantGraphError: descendantGraphComplete ? nil : "incomplete",
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000),
            isTruncated: false,
            projects: [],
            projectCatalogAvailable: true,
            projectCatalogError: nil,
            desktopPinnedThreadIDs: pinnedThreadIDs,
            desktopPinStateAvailable: pinStateAvailable,
            desktopPinStateError: pinStateAvailable ? nil : "unavailable",
            trustFolders: [:],
            trustConfigurationAvailable: true,
            trustConfigurationError: nil
        )
    }

    private func makeRecord(
        id: String,
        parentThreadID: String?
    ) -> CodexThreadRecord {
        CodexThreadRecord(
            id: id,
            sessionId: id,
            parentThreadId: parentThreadID,
            preview: id,
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_800_000_000,
            updatedAt: 1_800_000_001,
            status: CodexThreadStatus(type: "notLoaded", activeFlags: nil),
            cwd: "/Users/example/Projects/sample",
            cliVersion: runtimeVersion,
            name: id,
            isPinned: false,
            gitInfo: nil
        )
    }

    private func operationalConfiguration()
        -> CodexGhostRepairOperationalGateConfiguration
    {
        CodexGhostRepairOperationalGateConfiguration(
            codexHomeURL: URL(fileURLWithPath: "/test/.codex", isDirectory: true),
            backupVolumeProbeURL: URL(fileURLWithPath: "/test/backups", isDirectory: true)
        )
    }
}

private extension CodexGhostRepairOperationalGateConfiguration {
    var databaseURLsForTests: [URL] {
        [
            desktopDatabaseURL,
            summariesDatabaseURL,
            historyDatabaseURL,
            stateDatabaseURL,
            threadHistoryDatabaseURL,
        ]
    }
}

private actor RecordingGhostRepairInventorySource: CodexInventorySource {
    let snapshot: CodexInventorySnapshot
    private(set) var inventoryCallCount = 0
    private(set) var exactReadThreadIDs: [String] = []

    init(snapshot: CodexInventorySnapshot) {
        self.snapshot = snapshot
    }

    func inventory() async throws -> CodexInventorySnapshot {
        inventoryCallCount += 1
        return snapshot
    }

    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot {
        exactReadThreadIDs.append(threadID)
        throw CodexAppServerError.rpcError(-32600, "thread not loaded: \(threadID)")
    }
}

private struct FixedGhostRepairExecutionGateSource:
    CodexGhostRepairExecutionGateSource,
    Sendable
{
    let gate: CodexGhostRepairExecutionGate

    func ghostRepairExecutionGate() async throws -> CodexGhostRepairExecutionGate {
        gate
    }
}

private struct FixedGhostRepairCommandRunner: CodexGhostRepairCommandRunning, Sendable {
    let processResult: CodexGhostRepairCommandResult
    let lsofResults: [String: CodexGhostRepairCommandResult]

    func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> CodexGhostRepairCommandResult {
        if executableURL.path == "/bin/ps" {
            guard arguments == ["-axo", "pid=,ppid=,comm="] else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Unexpected deterministic process command."
                )
            }
            return processResult
        }
        guard executableURL.path == "/usr/sbin/lsof",
              arguments.prefix(2) == ["-Fpcfn", "--"],
              let path = arguments.last,
              let result = lsofResults[path] else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Unexpected deterministic command."
            )
        }
        return result
    }
}

private struct FixedGhostRepairFileSystemProbe:
    CodexGhostRepairFileSystemProbing,
    Sendable
{
    let sizes: [String: UInt64]
    let availableBytes: UInt64

    func regularFileSizeIfPresent(at url: URL) throws -> UInt64? {
        sizes[url.path]
    }

    func availableCapacity(at url: URL) throws -> UInt64 {
        availableBytes
    }
}
