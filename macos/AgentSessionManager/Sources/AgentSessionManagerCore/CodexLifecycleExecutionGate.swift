import Foundation

protocol CodexLifecycleExecutionChecking: Sendable {
    /// Verifies the presentation host is no longer running before a lifecycle
    /// Preview is claimed. A rejection must leave the Preview prepared and
    /// must occur before any provider mutation request is sent.
    func requireCodexDesktopExited() async throws
}

enum CodexLifecycleExecutionGateError: Error, Equatable, LocalizedError, Sendable {
    case inspectionUnavailable
    case codexDesktopRunning(processKinds: [CodexGhostRepairDesktopProcessKind])

    var errorDescription: String? {
        switch self {
        case .inspectionUnavailable:
            "Agent Session Manager could not verify that Codex Desktop is fully exited. No lifecycle request was sent, and the Preview remains unused. Quit Codex with Command-Q, then try the same unexpired Preview again."
        case .codexDesktopRunning:
            "Codex Desktop or one of its helper processes is still running. No lifecycle request was sent, and the Preview remains unused. Quit Codex with Command-Q, wait for it to exit completely, then try the same unexpired Preview again."
        }
    }
}

/// Process-only execution gate for official Archive, Restore, and Delete.
///
/// This is intentionally separate from Ghost Repair operating conditions. It
/// does not inspect SQLite handles, filesystem capacity, ChatGPT, or private
/// Codex storage. Its sole purpose is to avoid cross-process lifecycle writes
/// while Codex Desktop still owns a live presentation/writer session.
actor CodexDesktopLifecycleExecutionGate: CodexLifecycleExecutionChecking {
    private let processSnapshot:
        @Sendable () async throws -> CodexGhostRepairCommandResult
    private let managerProcessID: Int32

    init() {
        let runner = FoundationGhostRepairCommandRunner()
        self.managerProcessID = ProcessInfo.processInfo.processIdentifier
        self.processSnapshot = {
            try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,ppid=,command="]
            )
        }
    }

    init(
        managerProcessID: Int32,
        processSnapshot:
            @escaping @Sendable () async throws -> CodexGhostRepairCommandResult
    ) {
        self.managerProcessID = managerProcessID
        self.processSnapshot = processSnapshot
    }

    func requireCodexDesktopExited() async throws {
        let result: CodexGhostRepairCommandResult
        do {
            result = try await processSnapshot()
        } catch {
            throw CodexLifecycleExecutionGateError.inspectionUnavailable
        }
        guard result.terminationStatus == 0 else {
            throw CodexLifecycleExecutionGateError.inspectionUnavailable
        }

        guard let entries = CodexLifecycleProcessTable.parse(result.standardOutput),
              entries.contains(where: { $0.processID == managerProcessID }) else {
            throw CodexLifecycleExecutionGateError.inspectionUnavailable
        }
        let managerOwnedProcessIDs = CodexLifecycleProcessTable.descendants(
            of: managerProcessID,
            in: entries
        )
        let blockingSet: Set<CodexGhostRepairDesktopProcessKind> = Set(
            entries.compactMap { entry in
                guard !managerOwnedProcessIDs.contains(entry.processID),
                      let kind = CodexDesktopProcessClassifier.processKind(
                          "\(entry.processID) \(entry.command)"
                      ),
                      kind == .codexApplication || kind == .codexHelper else {
                    return nil
                }
                return kind
            }
        )
        let blockingKinds = CodexGhostRepairDesktopProcessKind.allCases.filter(
            blockingSet.contains
        )

        guard blockingKinds.isEmpty else {
            throw CodexLifecycleExecutionGateError.codexDesktopRunning(
                processKinds: blockingKinds
            )
        }
    }
}

private struct CodexLifecycleProcessEntry: Sendable {
    let processID: Int32
    let parentProcessID: Int32
    let command: String
}

private enum CodexLifecycleProcessTable {
    static func parse(_ output: String) -> [CodexLifecycleProcessEntry]? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }

        var entries: [CodexLifecycleProcessEntry] = []
        for line in lines {
            let fields = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count == 3,
                  let processID = Int32(fields[0]),
                  let parentProcessID = Int32(fields[1]),
                  !fields[2].isEmpty else {
                return nil
            }
            entries.append(CodexLifecycleProcessEntry(
                processID: processID,
                parentProcessID: parentProcessID,
                command: String(fields[2])
            ))
        }
        return entries
    }

    static func descendants(
        of rootProcessID: Int32,
        in entries: [CodexLifecycleProcessEntry]
    ) -> Set<Int32> {
        let parents = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.processID, $0.parentProcessID) }
        )
        var result: Set<Int32> = [rootProcessID]

        for entry in entries {
            var visited: Set<Int32> = []
            var candidate = entry.processID
            while visited.insert(candidate).inserted,
                  let parent = parents[candidate],
                  parent > 0 {
                if parent == rootProcessID {
                    result.insert(entry.processID)
                    break
                }
                candidate = parent
            }
        }
        return result
    }
}

enum CodexDesktopProcessClassifier {
    static func evidence(
        _ lines: [String]
    ) -> [CodexGhostRepairDesktopProcessEvidence] {
        var counts: [CodexGhostRepairDesktopProcessKind: Int] = [:]
        for line in lines {
            guard let kind = processKind(line) else { continue }
            counts[kind, default: 0] += 1
        }
        return CodexGhostRepairDesktopProcessKind.allCases.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            return CodexGhostRepairDesktopProcessEvidence(
                kind: kind,
                processCount: count
            )
        }
    }

    static func processKind(
        _ line: String
    ) -> CodexGhostRepairDesktopProcessKind? {
        let options: String.CompareOptions = [
            .regularExpression,
            .caseInsensitive,
        ]
        if line.range(
            of: #"^\d+\s+.+\/Codex\.app\/Contents\/MacOS\/Codex(?:\s|$)"#,
            options: options
        ) != nil {
            return .codexApplication
        }
        if line.range(
            of: #"^\d+\s+.+\/Codex\.app\/Contents\/Frameworks\/.+\/Helpers\/(?:browser|chrome)_crashpad_handler(?:\s|$)"#,
            options: options
        ) != nil {
            return .codexCrashReporter
        }
        if line.range(
            of: #"^\d+\s+.+\/Codex\.app\/Contents\/Frameworks\/"#,
            options: options
        ) != nil {
            return .codexHelper
        }
        if line.range(
            of: #"^\d+\s+.+\/Codex\.app\/Contents\/Resources\/(?:codex|codex-code-mode-host)(?:\s|$)"#,
            options: options
        ) != nil {
            return .codexHelper
        }
        if line.range(
            of: #"^\d+\s+.+\/ChatGPT\.app\/Contents\/MacOS\/ChatGPT(?:\s|$)"#,
            options: options
        ) != nil {
            return .chatGPTApplication
        }
        if line.range(
            of: #"^\d+\s+.+\/ChatGPT\.app\/Contents\/Frameworks\/.+\/Helpers\/(?:browser|chrome)_crashpad_handler(?:\s|$)"#,
            options: options
        ) != nil {
            return .chatGPTCrashReporter
        }
        if line.range(
            of: #"^\d+\s+.+\/ChatGPT\.app\/Contents\/Frameworks\/"#,
            options: options
        ) != nil {
            return .chatGPTHelper
        }
        if line.range(
            of: #"^\d+\s+.+\/ChatGPT\.app\/Contents\/Resources\/(?:codex|codex-code-mode-host)(?:\s|$)"#,
            options: options
        ) != nil {
            return .chatGPTHelper
        }
        return nil
    }
}
