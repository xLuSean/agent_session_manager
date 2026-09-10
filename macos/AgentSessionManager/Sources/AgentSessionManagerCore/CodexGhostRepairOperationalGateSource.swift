import Darwin
import Foundation

public struct CodexGhostRepairOperationalGateConfiguration: Hashable, Sendable {
    public let desktopDatabaseURL: URL
    public let summariesDatabaseURL: URL
    public let historyDatabaseURL: URL
    public let stateDatabaseURL: URL
    public let threadHistoryDatabaseURL: URL
    public let backupVolumeProbeURL: URL
    public let fixedCapacityHeadroomBytes: UInt64

    public init(
        codexHomeURL: URL,
        backupVolumeProbeURL: URL,
        fixedCapacityHeadroomBytes: UInt64 = 64 * 1_024 * 1_024
    ) {
        let sqliteDirectory = codexHomeURL.appendingPathComponent("sqlite", isDirectory: true)
        self.desktopDatabaseURL = sqliteDirectory.appendingPathComponent(
            "codex-dev.db",
            isDirectory: false
        )
        self.summariesDatabaseURL = sqliteDirectory.appendingPathComponent(
            "codex-thread-summaries-dev.db",
            isDirectory: false
        )
        self.historyDatabaseURL = sqliteDirectory.appendingPathComponent(
            "codex-history-snapshots-dev.db",
            isDirectory: false
        )
        self.stateDatabaseURL = codexHomeURL.appendingPathComponent(
            "state_5.sqlite",
            isDirectory: false
        )
        self.threadHistoryDatabaseURL = codexHomeURL.appendingPathComponent(
            "thread_history_1.sqlite",
            isDirectory: false
        )
        self.backupVolumeProbeURL = backupVolumeProbeURL
        self.fixedCapacityHeadroomBytes = fixedCapacityHeadroomBytes
    }

    fileprivate struct DatabaseEntry: Sendable {
        let role: CodexGhostRepairDatabaseRole
        let url: URL
        let required: Bool
    }

    fileprivate var databaseEntries: [DatabaseEntry] {
        [
            DatabaseEntry(role: .desktop, url: desktopDatabaseURL, required: true),
            DatabaseEntry(role: .summaries, url: summariesDatabaseURL, required: true),
            DatabaseEntry(role: .legacyHistory, url: historyDatabaseURL, required: false),
            DatabaseEntry(role: .state, url: stateDatabaseURL, required: true),
            DatabaseEntry(
                role: .threadHistory,
                url: threadHistoryDatabaseURL,
                required: true
            ),
        ]
    }
}

struct CodexGhostRepairCommandResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: String
}

protocol CodexGhostRepairCommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws
        -> CodexGhostRepairCommandResult
}

struct FoundationGhostRepairCommandRunner: CodexGhostRepairCommandRunning {
    func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> CodexGhostRepairCommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let standardOutput = String(data: outputData, encoding: .utf8) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Operational gate command output was not valid UTF-8."
            )
        }
        return CodexGhostRepairCommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: standardOutput
        )
    }
}

private struct CodexGhostRepairProcessSnapshotEntry: Sendable {
    let processIdentifier: Int32
    let parentProcessIdentifier: Int32
    let executable: String
}

private enum CodexGhostRepairProcessSnapshotParser {
    static func parse(
        _ output: String
    ) throws -> [CodexGhostRepairProcessSnapshotEntry] {
        var result: [CodexGhostRepairProcessSnapshotEntry] = []
        var observedProcessIdentifiers: Set<Int32> = []
        for line in output.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ) {
            let fields = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count == 3,
                  let processIdentifier = Int32(fields[0]),
                  processIdentifier > 0,
                  let parentProcessIdentifier = Int32(fields[1]),
                  parentProcessIdentifier >= 0,
                  !fields[2].isEmpty,
                  observedProcessIdentifiers.insert(processIdentifier).inserted else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Codex process inspection returned an unsupported shape."
                )
            }
            result.append(CodexGhostRepairProcessSnapshotEntry(
                processIdentifier: processIdentifier,
                parentProcessIdentifier: parentProcessIdentifier,
                executable: String(fields[2])
            ))
        }
        return result
    }
}

private enum CodexGhostRepairOpenHandleParser {
    private struct Accumulator {
        var processName: String?
        var fileDescriptorCount = 0
    }

    static func parse(
        _ output: String,
        databaseRole: CodexGhostRepairDatabaseRole,
        processEntries: [Int32: CodexGhostRepairProcessSnapshotEntry]
    ) throws -> [CodexGhostRepairOpenHandleOwnerEvidence] {
        let lines = output.split(
            separator: "\n",
            omittingEmptySubsequences: true
        )
        guard !lines.isEmpty else { return [] }

        var currentProcessIdentifier: Int32?
        var accumulators: [Int32: Accumulator] = [:]
        for line in lines {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                guard let processIdentifier = Int32(value),
                      processIdentifier > 0 else {
                    throw unsupportedOpenHandleShape()
                }
                currentProcessIdentifier = processIdentifier
                if accumulators[processIdentifier] == nil {
                    accumulators[processIdentifier] = Accumulator()
                }
            case "c":
                guard let processIdentifier = currentProcessIdentifier else {
                    throw unsupportedOpenHandleShape()
                }
                let processName = try pathRedactedProcessName(value)
                if let existing = accumulators[processIdentifier]?.processName,
                   existing != processName {
                    throw unsupportedOpenHandleShape()
                }
                accumulators[processIdentifier]?.processName = processName
            case "f":
                guard let processIdentifier = currentProcessIdentifier,
                      !value.isEmpty else {
                    throw unsupportedOpenHandleShape()
                }
                accumulators[processIdentifier]?.fileDescriptorCount += 1
            case "n":
                guard currentProcessIdentifier != nil else {
                    throw unsupportedOpenHandleShape()
                }
                // The clear filesystem path is deliberately ignored.
                continue
            default:
                throw unsupportedOpenHandleShape()
            }
        }

        return try accumulators.keys.sorted().map { processIdentifier in
            guard let accumulator = accumulators[processIdentifier],
                  let processName = accumulator.processName,
                  accumulator.fileDescriptorCount > 0 else {
                throw unsupportedOpenHandleShape()
            }
            let processEntry = processEntries[processIdentifier]
            let parentProcessEntry = processEntry.flatMap {
                processEntries[$0.parentProcessIdentifier]
            }
            let processKind = processEntry.flatMap {
                CodexDesktopProcessClassifier.processKind(
                    "\($0.processIdentifier) \($0.executable)"
                )
            }
            let executableName = processEntry.flatMap {
                try? pathRedactedExecutableName($0.executable)
            }
            let parentProcessName = parentProcessEntry.flatMap {
                try? pathRedactedExecutableName($0.executable)
            }
            let ownerApplication = classifyOwnerApplication(
                processExecutable: processEntry?.executable,
                parentExecutable: parentProcessEntry?.executable
            )
            return CodexGhostRepairOpenHandleOwnerEvidence(
                databaseRole: databaseRole,
                processIdentifier: processIdentifier,
                parentProcessIdentifier:
                    processEntry?.parentProcessIdentifier,
                processName: processName,
                executableName: executableName,
                parentProcessName: parentProcessName,
                processKind: processKind,
                ownerApplication: ownerApplication,
                fileDescriptorCount: accumulator.fileDescriptorCount
            )
        }
    }

    private static func classifyOwnerApplication(
        processExecutable: String?,
        parentExecutable: String?
    ) -> CodexGhostRepairOpenHandleOwnerApplication? {
        let process = processExecutable?.lowercased() ?? ""
        let parent = parentExecutable?.lowercased() ?? ""
        if process.contains("/.vscode/extensions/openai.chatgpt-")
            || (parent.contains("/visual studio code.app/")
                && process.split(separator: "/").last?
                    .hasPrefix("codex") == true) {
            return .visualStudioCodeOpenAIExtension
        }
        if process.contains("/codex.app/") {
            return .codexDesktop
        }
        if process.contains("/chatgpt.app/") {
            return .chatGPTDesktop
        }
        if process.split(separator: "/").last?.hasPrefix("codex") == true {
            return .codexCommandLine
        }
        return nil
    }

    private static func pathRedactedProcessName(
        _ value: String
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastComponent = trimmed.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).last.map(String.init) ?? trimmed
        let safeScalars = lastComponent.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let safeName = String(String.UnicodeScalarView(safeScalars)).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !safeName.isEmpty else { throw unsupportedOpenHandleShape() }
        return String(safeName.prefix(80))
    }

    private static func pathRedactedExecutableName(
        _ command: String
    ) throws -> String {
        let candidate: String
        if let marker = command.range(of: "/Contents/MacOS/") {
            let remainder = String(command[marker.upperBound...])
            candidate = remainder.components(separatedBy: " --").first
                ?? remainder
        } else if let marker = command.range(of: "/Contents/Resources/") {
            let remainder = String(command[marker.upperBound...])
            candidate = remainder.split(
                whereSeparator: { $0 == " " || $0 == "\t" }
            ).first.map(String.init) ?? remainder
        } else {
            candidate = command.split(
                whereSeparator: { $0 == " " || $0 == "\t" }
            ).first.map(String.init) ?? command
        }
        return try pathRedactedProcessName(candidate)
    }

    private static func unsupportedOpenHandleShape()
        -> CodexGhostRepairError
    {
        CodexGhostRepairError.invalidProtectionEvidence(
            "Open-handle inspection returned an unsupported shape."
        )
    }
}

protocol CodexGhostRepairFileSystemProbing: Sendable {
    func regularFileSizeIfPresent(at url: URL) throws -> UInt64?
    func availableCapacity(at url: URL) throws -> UInt64
}

struct DarwinGhostRepairFileSystemProbe: CodexGhostRepairFileSystemProbing {
    func regularFileSizeIfPresent(at url: URL) throws -> UInt64? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Operational gate cannot inspect database metadata: \(url.lastPathComponent)."
            )
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Operational gate requires a regular database file: \(url.lastPathComponent)."
            )
        }
        return UInt64(status.st_size)
    }

    func availableCapacity(at url: URL) throws -> UInt64 {
        var status = statfs()
        guard statfs(url.path, &status) == 0,
              status.f_bavail >= 0,
              status.f_bsize >= 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Operational gate cannot inspect backup-volume capacity."
            )
        }
        let blocks = UInt64(status.f_bavail)
        let blockSize = UInt64(status.f_bsize)
        let (capacity, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
        guard !overflow else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Backup-volume capacity overflowed UInt64."
            )
        }
        return capacity
    }
}

/// Read-only macOS operational gate. It runs `ps` and `lsof`, reads file
/// metadata, and probes filesystem capacity; it never opens SQLite or exposes
/// a database/lifecycle mutation method.
public actor CodexGhostRepairMacOSOperationalGateSource:
    CodexGhostRepairExecutionGateSource
{
    private let configuration: CodexGhostRepairOperationalGateConfiguration
    private let commandRunner: any CodexGhostRepairCommandRunning
    private let fileSystem: any CodexGhostRepairFileSystemProbing

    public init(configuration: CodexGhostRepairOperationalGateConfiguration) {
        self.configuration = configuration
        self.commandRunner = FoundationGhostRepairCommandRunner()
        self.fileSystem = DarwinGhostRepairFileSystemProbe()
    }

    init(
        configuration: CodexGhostRepairOperationalGateConfiguration,
        commandRunner: any CodexGhostRepairCommandRunning,
        fileSystem: any CodexGhostRepairFileSystemProbing
    ) {
        self.configuration = configuration
        self.commandRunner = commandRunner
        self.fileSystem = fileSystem
    }

    public func ghostRepairExecutionGate() async throws -> CodexGhostRepairExecutionGate {
        let processResult = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,ppid=,comm="]
        )
        guard processResult.terminationStatus == 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Codex process inspection was incomplete."
            )
        }
        let processEntries = try CodexGhostRepairProcessSnapshotParser.parse(
            processResult.standardOutput
        )
        let processEvidence = CodexDesktopProcessClassifier.evidence(
            processEntries.map {
                "\($0.processIdentifier) \($0.executable)"
            }
        )
        let processEntriesByIdentifier = Dictionary(
            uniqueKeysWithValues: processEntries.map {
                ($0.processIdentifier, $0)
            }
        )

        var handleCounts: [CodexGhostRepairDatabaseRole: Int] = [:]
        var openHandleOwnerEvidence:
            [CodexGhostRepairOpenHandleOwnerEvidence] = []
        for database in configuration.databaseEntries {
            let result = try await commandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-Fpcfn", "--", database.url.path]
            )
            let trimmed = result.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard result.terminationStatus == 0
                    || (result.terminationStatus == 1 && trimmed.isEmpty) else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Open-handle inspection was incomplete."
                )
            }
            let owners = try CodexGhostRepairOpenHandleParser.parse(
                trimmed,
                databaseRole: database.role,
                processEntries: processEntriesByIdentifier
            )
            openHandleOwnerEvidence.append(contentsOf: owners)
            handleCounts[database.role] = owners.reduce(0) {
                $0 + $1.fileDescriptorCount
            }
        }

        var sourceBytes: UInt64 = 0
        for database in configuration.databaseEntries {
            let observedSize = try fileSystem.regularFileSizeIfPresent(
                at: database.url
            )
            guard let size = observedSize else {
                if database.required {
                    throw CodexGhostRepairError.invalidProtectionEvidence(
                        "Required snapshot source database is unavailable: \(database.url.lastPathComponent)."
                    )
                }
                continue
            }
            let (next, overflow) = sourceBytes.addingReportingOverflow(size)
            guard !overflow else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Database source-size evidence overflowed UInt64."
                )
            }
            sourceBytes = next
        }
        let (twoCopies, copyOverflow) = sourceBytes.multipliedReportingOverflow(by: 2)
        let (requiredBytes, headroomOverflow) = twoCopies.addingReportingOverflow(
            configuration.fixedCapacityHeadroomBytes
        )
        guard !copyOverflow, !headroomOverflow else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Backup capacity requirement overflowed UInt64."
            )
        }
        let availableBytes = try fileSystem.availableCapacity(
            at: configuration.backupVolumeProbeURL
        )

        return CodexGhostRepairExecutionGate(
            codexFullyExited: !processEvidence.contains(
                where: \.blocksSnapshotAcquisition
            ),
            desktopOpenHandleCount: handleCounts[.desktop, default: 0],
            summariesOpenHandleCount: handleCounts[.summaries, default: 0],
            historyOpenHandleCount: handleCounts[.legacyHistory, default: 0],
            stateOpenHandleCount: handleCounts[.state, default: 0],
            threadHistoryOpenHandleCount:
                handleCounts[.threadHistory, default: 0],
            capacitySufficient: availableBytes >= requiredBytes,
            desktopProcessEvidence: processEvidence,
            openHandleOwnerEvidence: openHandleOwnerEvidence
        )
    }

}
