import XCTest
@testable import AgentSessionManagerCore

final class CodexLifecycleExecutionGateTests: XCTestCase {
    func testCodexApplicationBlocksLifecycleExecution() async throws {
        let gate = gate(for: [
            "101 1 /Applications/Codex.app/Contents/MacOS/Codex",
        ])

        do {
            try await gate.requireCodexDesktopExited()
            XCTFail("Codex main application must block lifecycle execution.")
        } catch let error as CodexLifecycleExecutionGateError {
            XCTAssertEqual(
                error,
                .codexDesktopRunning(processKinds: [.codexApplication])
            )
        }
    }

    func testCodexHelperBlocksLifecycleExecution() async throws {
        let gate = gate(for: [
            "102 1 /Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper",
        ])

        do {
            try await gate.requireCodexDesktopExited()
            XCTFail("Codex helper must block lifecycle execution.")
        } catch let error as CodexLifecycleExecutionGateError {
            XCTAssertEqual(
                error,
                .codexDesktopRunning(processKinds: [.codexHelper])
            )
        }
    }

    func testCrashReporterAndChatGPTProcessesDoNotBlockLifecycleExecution() async throws {
        let gate = gate(for: [
            "103 1 /Applications/Codex.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler",
            "104 1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
            "105 1 /Applications/ChatGPT.app/Contents/Frameworks/ChatGPT Helper.app/Contents/MacOS/ChatGPT Helper",
            "106 1 /Applications/ChatGPT.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler",
        ])

        try await gate.requireCodexDesktopExited()
    }

    func testManagerOwnedAppServerAndDescendantsDoNotBlockExecution() async throws {
        let gate = gate(for: [
            "901 900 /Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://",
            "902 901 /Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper",
        ])

        try await gate.requireCodexDesktopExited()
    }

    func testFailedProcessInspectionBlocksLifecycleExecution() async throws {
        let gate = CodexDesktopLifecycleExecutionGate(managerProcessID: 900) {
            CodexGhostRepairCommandResult(
                terminationStatus: 1,
                standardOutput: ""
            )
        }

        do {
            try await gate.requireCodexDesktopExited()
            XCTFail("Incomplete process inspection must block lifecycle execution.")
        } catch let error as CodexLifecycleExecutionGateError {
            XCTAssertEqual(error, .inspectionUnavailable)
        }
    }

    private func gate(for lines: [String]) -> CodexDesktopLifecycleExecutionGate {
        CodexDesktopLifecycleExecutionGate(managerProcessID: 900) {
            CodexGhostRepairCommandResult(
                terminationStatus: 0,
                standardOutput: (["900 1 /Applications/Agent Session Manager.app/Contents/MacOS/Agent Session Manager"] + lines)
                    .joined(separator: "\n")
            )
        }
    }
}

actor LifecycleExecutionGateStub: CodexLifecycleExecutionChecking {
    private var error: CodexLifecycleExecutionGateError?
    private var callCount = 0

    init(error: CodexLifecycleExecutionGateError? = nil) {
        self.error = error
    }

    func requireCodexDesktopExited() async throws {
        callCount += 1
        if let error { throw error }
    }

    func observedCallCount() -> Int {
        callCount
    }

    func simulateDesktopExit() {
        error = nil
    }
}
