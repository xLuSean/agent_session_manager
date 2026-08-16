import Foundation
import Darwin

public enum CodexAppServerError: Error, LocalizedError, Equatable, Sendable {
    case executableNotFound
    case launchFailed(String)
    case processExited(Int32, String)
    case responseTimeout
    case exactReadUnavailable
    case malformedResponse(String)
    case rpcError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex CLI was not found in PATH, /opt/homebrew/bin, or /usr/local/bin."
        case .launchFailed(let message):
            "Could not launch Codex App Server: \(message)"
        case .processExited(let status, let message):
            "Codex App Server exited with status \(status): \(message)"
        case .responseTimeout:
            "Codex App Server did not respond before the read-only request timeout."
        case .exactReadUnavailable:
            "This Codex inventory source does not provide exact-ID readback."
        case .malformedResponse(let message):
            "Codex App Server returned an invalid response: \(message)"
        case .rpcError(let code, let message):
            "Codex App Server error \(code): \(message)"
        }
    }
}

struct CodexServerInfo: Codable, Hashable, Sendable {
    let userAgent: String
    let codexHome: String
    let platformFamily: String
    let platformOs: String
}

struct CodexThreadStatus: Codable, Hashable, Sendable {
    let type: String
    let activeFlags: [String]?
}

struct CodexGitInfo: Codable, Hashable, Sendable {
    let branch: String?
    let originUrl: String?
    let sha: String?
}

struct CodexThreadRecord: Codable, Hashable, Sendable {
    let id: String
    let sessionId: String
    let parentThreadId: String?
    let preview: String
    let ephemeral: Bool
    let modelProvider: String
    let createdAt: Int64
    let updatedAt: Int64
    let status: CodexThreadStatus
    let cwd: String
    let cliVersion: String
    let name: String?
    let isPinned: Bool?
    let gitInfo: CodexGitInfo?
}

struct CodexThreadPage: Codable, Hashable, Sendable {
    let data: [CodexThreadRecord]
    let nextCursor: String?
}

struct CodexThreadReadResponse: Codable, Hashable, Sendable {
    let thread: CodexThreadRecord
}

private struct CodexThreadLifecycleResponse: Decodable {}

struct CodexExactReadSnapshot: Hashable, Sendable {
    let serverInfo: CodexServerInfo
    let runtimeVersion: String?
    let thread: CodexThreadRecord
    let observedAt: Date
}

struct CodexPaginationAccumulator: Sendable {
    private(set) var records: [CodexThreadRecord] = []
    private(set) var nextCursor: String?
    private(set) var pageCount = 0
    private(set) var isTruncated = false

    private let maximumPages: Int
    private var seenCursors: Set<String> = []
    private var seenRecordIDs: Set<String> = []

    init(maximumPages: Int) {
        self.maximumPages = max(1, maximumPages)
    }

    /// Returns true when another page should be requested.
    mutating func append(_ page: CodexThreadPage) -> Bool {
        pageCount += 1
        for record in page.data where seenRecordIDs.insert(record.id).inserted {
            records.append(record)
        }

        guard let cursor = page.nextCursor else {
            nextCursor = nil
            return false
        }
        guard pageCount < maximumPages else {
            nextCursor = cursor
            isTruncated = true
            return false
        }
        guard seenCursors.insert(cursor).inserted else {
            nextCursor = cursor
            isTruncated = true
            return false
        }

        nextCursor = cursor
        return true
    }
}

struct CodexInventorySnapshot: Hashable, Sendable {
    let serverInfo: CodexServerInfo
    let runtimeVersion: String?
    let active: [CodexThreadRecord]
    let archived: [CodexThreadRecord]
    let descendantRecords: [CodexThreadRecord]
    let descendantNativeStates: [String: NativeSessionState]
    let descendantGraphComplete: Bool
    let descendantGraphError: String?
    let refreshedAt: Date
    let isTruncated: Bool
    let projects: [CodexDesktopProject]
    let projectCatalogAvailable: Bool
    let projectCatalogError: String?
    let desktopPinnedThreadIDs: Set<String>
    let desktopPinStateAvailable: Bool
    let desktopPinStateError: String?
    let trustFolders: [String: FolderTrustState]
    let trustConfigurationAvailable: Bool
    let trustConfigurationError: String?
}

struct CodexDesktopProject: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let rootPaths: [String]
    let order: Int?
}

struct CodexDesktopState: Decodable {
    let localProjects: [String: CodexDesktopProjectEntry]?
    let projectOrder: [String]?
    let pinnedThreadIDs: [String]?

    private enum CodingKeys: String, CodingKey {
        case localProjects = "local-projects"
        case projectOrder = "project-order"
        case pinnedThreadIDs = "pinned-thread-ids"
    }

    func validatedPinnedThreadIDSet() throws -> Set<String> {
        guard let pinnedThreadIDs else {
            throw CodexDesktopStateError.missingPinnedThreadIDs
        }
        var result: Set<String> = []
        for id in pinnedThreadIDs {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodexDesktopStateError.emptyPinnedThreadID
            }
            guard result.insert(id).inserted else {
                throw CodexDesktopStateError.duplicatePinnedThreadID(id)
            }
        }
        return result
    }

    static func stablePinnedThreadIDSet(
        start: CodexDesktopState,
        end: CodexDesktopState
    ) throws -> Set<String> {
        let startIDs = try start.validatedPinnedThreadIDSet()
        let endIDs = try end.validatedPinnedThreadIDSet()
        guard startIDs == endIDs else {
            throw CodexDesktopStateError.pinnedThreadIDsChangedDuringInventory
        }
        return endIDs
    }

    func projectCatalog() -> [CodexDesktopProject] {
        let orderByID = Dictionary(
            uniqueKeysWithValues: (projectOrder ?? []).enumerated().map { ($1, $0) }
        )
        return (localProjects ?? [:]).compactMap { id, entry in
            let roots = (entry.rootPaths ?? [])
                .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardized.path }
                .filter { !$0.isEmpty }
            guard !roots.isEmpty else { return nil }
            let fallbackName = URL(fileURLWithPath: roots[0]).lastPathComponent
            let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexDesktopProject(
                id: id,
                name: name?.isEmpty == false ? name! : fallbackName,
                rootPaths: roots,
                order: orderByID[id]
            )
        }.sorted { left, right in
            switch (left.order, right.order) {
            case let (.some(lhs), .some(rhs)) where lhs != rhs:
                return lhs < rhs
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
        }
    }
}

enum CodexDesktopStateError: Error, Equatable, LocalizedError {
    case stateReadFailed(String)
    case missingPinnedThreadIDs
    case emptyPinnedThreadID
    case duplicatePinnedThreadID(String)
    case pinnedThreadIDsChangedDuringInventory

    var errorDescription: String? {
        switch self {
        case .stateReadFailed(let message):
            "Codex Desktop state could not be read: \(message)"
        case .missingPinnedThreadIDs:
            "Codex Desktop state does not contain pinned-thread-ids."
        case .emptyPinnedThreadID:
            "Codex Desktop pinned-thread-ids contains an empty ID."
        case .duplicatePinnedThreadID(let id):
            "Codex Desktop pinned-thread-ids contains duplicate ID \(id)."
        case .pinnedThreadIDsChangedDuringInventory:
            "Codex Desktop pin membership changed while the inventory was being read."
        }
    }
}

struct CodexDesktopProjectEntry: Decodable {
    let name: String?
    let rootPaths: [String]?
}

struct CodexProjectTrustEntry: Decodable {
    let trustLevel: String?

    private enum CodingKeys: String, CodingKey {
        case trustLevel = "trust_level"
    }
}

struct CodexRuntimeConfig: Decodable {
    let projects: [String: CodexProjectTrustEntry]?
}

struct CodexConfigReadResponse: Decodable {
    let config: CodexRuntimeConfig
}

protocol CodexInventorySource: Sendable {
    func inventory() async throws -> CodexInventorySnapshot
    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot
}

extension CodexInventorySource {
    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot {
        throw CodexAppServerError.exactReadUnavailable
    }

}

/// Mutation capability is intentionally separate from the read-only inventory
/// source. Only the native Archive facade's internal transport owns this protocol.
protocol CodexArchiveSource: Sendable {
    func inventory() async throws -> CodexInventorySnapshot
    func archive(threadID: String) async throws
}

/// Restore mutation capability is kept separate from read-only inventory and
/// Archive so production call sites must opt into the exact lifecycle method.
protocol CodexRestoreSource: Sendable {
    func inventory() async throws -> CodexInventorySnapshot
    func unarchive(threadID: String) async throws
}

/// Permanent Delete mutation capability remains separate from inventory,
/// Archive, and Restore so only the guarded Delete facade can construct it.
protocol CodexDeleteSource: CodexInventorySource {
    func delete(threadID: String) async throws
}

public struct CodexAppServerConfiguration: Hashable, Sendable {
    public var executableURL: URL?
    public var pageSize: Int
    public var maximumPagesPerCollection: Int
    public var timeout: TimeInterval

    public init(
        executableURL: URL? = nil,
        pageSize: Int = 50,
        maximumPagesPerCollection: Int = 200,
        timeout: TimeInterval = 45
    ) {
        self.executableURL = executableURL
        // The current App Server accepts at most 50 list items per request.
        self.pageSize = min(max(1, pageSize), 50)
        // Keep corrupted or version-drifted cursors bounded while allowing 10,000
        // active and 10,000 archived threads under the default configuration.
        self.maximumPagesPerCollection = min(max(1, maximumPagesPerCollection), 200)
        self.timeout = timeout
    }
}

public actor CodexAppServerClient: CodexInventorySource, CodexArchiveSource, CodexRestoreSource, CodexDeleteSource {
    private static let interactiveSourceKinds = ["cli", "vscode"]
    // This is the complete stable ThreadSourceKind enum in the local 0.147.0 schema.
    // The second bounded inventory is used only to build the read-only descendant graph;
    // sub-agent records are not added to the main session table.
    private static let allSourceKinds = [
        "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
        "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown",
    ]

    private let configuration: CodexAppServerConfiguration

    public init(configuration: CodexAppServerConfiguration = CodexAppServerConfiguration()) {
        self.configuration = configuration
    }

    func inventory() async throws -> CodexInventorySnapshot {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        return try runInventory(executableURL: executableURL)
    }

    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        return try runExactRead(threadID: threadID, executableURL: executableURL)
    }

    func archive(threadID: String) async throws {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        try runLifecycleMutation(
            threadID: threadID,
            method: "thread/archive",
            executableURL: executableURL
        )
    }

    func unarchive(threadID: String) async throws {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        try runLifecycleMutation(
            threadID: threadID,
            method: "thread/unarchive",
            executableURL: executableURL
        )
    }

    func delete(threadID: String) async throws {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        try runLifecycleMutation(
            threadID: threadID,
            method: "thread/delete",
            executableURL: executableURL
        )
    }

    private func runLifecycleMutation(
        threadID: String,
        method: String,
        executableURL: URL
    ) throws {
        let runtimeVersion = probeRuntimeVersion(executableURL: executableURL)
        let contractSupported = method == "thread/delete"
            ? CodexAppServerProvider.supportsVerifiedDeleteContract(runtimeVersion)
            : CodexAppServerProvider.supportsVerifiedLifecycleContract(runtimeVersion)
        guard contractSupported else {
            throw CodexAppServerError.launchFailed(
                "Codex runtime \(runtimeVersion ?? "unavailable") is outside the verified lifecycle contract."
            )
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer { stopProcess(process, closing: input.fileHandleForWriting) }

        let reader = JSONLineReader(fileHandle: output.fileHandleForReading)
        let _: CodexServerInfo = try request(
            process: process,
            input: input.fileHandleForWriting,
            reader: reader,
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "agent_session_manager",
                    "title": "Agent Session Manager",
                    "version": "0.1.0",
                ],
            ]
        )
        try send(
            ["method": "initialized", "params": [:] as [String: Any]],
            to: input.fileHandleForWriting
        )
        let _: CodexThreadLifecycleResponse = try request(
            process: process,
            input: input.fileHandleForWriting,
            reader: reader,
            id: 2,
            method: method,
            params: ["threadId": threadID]
        )
    }

    private func runExactRead(
        threadID: String,
        executableURL: URL
    ) throws -> CodexExactReadSnapshot {
        let runtimeVersion = probeRuntimeVersion(executableURL: executableURL)
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer { stopProcess(process, closing: input.fileHandleForWriting) }

        let reader = JSONLineReader(fileHandle: output.fileHandleForReading)
        let serverInfo: CodexServerInfo = try request(
            process: process,
            input: input.fileHandleForWriting,
            reader: reader,
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "agent_session_manager",
                    "title": "Agent Session Manager",
                    "version": "0.1.0",
                ],
            ]
        )
        try send(
            ["method": "initialized", "params": [:] as [String: Any]],
            to: input.fileHandleForWriting
        )
        let response: CodexThreadReadResponse = try request(
            process: process,
            input: input.fileHandleForWriting,
            reader: reader,
            id: 2,
            method: "thread/read",
            params: ["threadId": threadID, "includeTurns": false]
        )
        return CodexExactReadSnapshot(
            serverInfo: serverInfo,
            runtimeVersion: runtimeVersion,
            thread: response.thread,
            observedAt: Date()
        )
    }

    private func runInventory(executableURL: URL) throws -> CodexInventorySnapshot {
        let runtimeVersion = probeRuntimeVersion(executableURL: executableURL)
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        // Never leave stderr on an undrained pipe; a full child pipe deadlocks JSON-RPC stdout.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        // Convert a closed child stdin into a thrown write error instead of terminating this app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        defer {
            stopProcess(process, closing: input.fileHandleForWriting)
        }

        let reader = JSONLineReader(fileHandle: output.fileHandleForReading)
        var requestID = 1

        let initializeResult: CodexServerInfo = try request(
            process: process,
            input: input.fileHandleForWriting,
            reader: reader,
            id: requestID,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "agent_session_manager",
                    "title": "Agent Session Manager",
                    "version": "0.1.0",
                ],
            ]
        )
        requestID += 1

        try send(
            ["method": "initialized", "params": [:] as [String: Any]],
            to: input.fileHandleForWriting
        )

        let desktopStateURL = URL(fileURLWithPath: initializeResult.codexHome)
            .appendingPathComponent(".codex-global-state.json")
        var desktopStateAtStart: CodexDesktopState?
        var desktopStateAtStartError: String?
        var projects: [CodexDesktopProject] = []
        var projectCatalogAvailable = false
        var projectCatalogError: String?
        do {
            let data = try Data(contentsOf: desktopStateURL)
            let state = try JSONDecoder().decode(CodexDesktopState.self, from: data)
            desktopStateAtStart = state
            projects = state.projectCatalog()
            projectCatalogAvailable = true
        } catch {
            projectCatalogError = error.localizedDescription
            desktopStateAtStartError = error.localizedDescription
        }

        var trustFolders: [String: FolderTrustState] = [:]
        var trustConfigurationAvailable = false
        var trustConfigurationError: String?
        do {
            let configResult: CodexConfigReadResponse = try request(
                process: process,
                input: input.fileHandleForWriting,
                reader: reader,
                id: requestID,
                method: "config/read",
                params: ["includeLayers": false]
            )
            trustConfigurationAvailable = true
            trustFolders = Dictionary(uniqueKeysWithValues:
                (configResult.config.projects ?? [:]).map { path, entry in
                    let state: FolderTrustState
                    switch entry.trustLevel {
                    case "trusted": state = .trusted
                    case "untrusted": state = .untrusted
                    default: state = .unavailable
                    }
                    return (path, state)
                }
            )
        } catch {
            trustConfigurationError = error.localizedDescription
        }
        requestID += 1

        let activeResult = try listAllThreads(
            archived: false,
            sourceKinds: Self.interactiveSourceKinds,
            process: process,
            input: input.fileHandleForWriting,
            reader: reader,
            requestID: &requestID
        )
        let archivedResult = try listAllThreads(
            archived: true,
            sourceKinds: Self.interactiveSourceKinds,
            process: process,
            input: input.fileHandleForWriting,
            reader: reader,
            requestID: &requestID
        )

        var descendantRecords: [CodexThreadRecord] = []
        var descendantNativeStates: [String: NativeSessionState] = [:]
        var descendantGraphComplete = false
        var descendantGraphError: String?
        do {
            let descendantActive = try listAllThreads(
                archived: false,
                sourceKinds: Self.allSourceKinds,
                process: process,
                input: input.fileHandleForWriting,
                reader: reader,
                requestID: &requestID
            )
            let descendantArchived = try listAllThreads(
                archived: true,
                sourceKinds: Self.allSourceKinds,
                process: process,
                input: input.fileHandleForWriting,
                reader: reader,
                requestID: &requestID
            )
            descendantRecords = descendantActive.records + descendantArchived.records
            for record in descendantActive.records {
                descendantNativeStates[record.id] = .active
            }
            let stateOverlap = Set(descendantActive.records.map(\.id))
                .intersection(descendantArchived.records.map(\.id))
            for record in descendantArchived.records {
                descendantNativeStates[record.id] = .archived
            }
            descendantGraphComplete = !descendantActive.isTruncated && !descendantArchived.isTruncated
                && stateOverlap.isEmpty
            if !stateOverlap.isEmpty {
                descendantGraphError = "All-source inventory returned the same ID as both Active and Archived."
            } else if !descendantGraphComplete {
                descendantGraphError = "All-source inventory reached its pagination safety bound."
            }
        } catch {
            descendantGraphError = error.localizedDescription
        }

        var desktopPinnedThreadIDs: Set<String> = []
        var desktopPinStateAvailable = false
        var desktopPinStateError: String?
        do {
            guard let desktopStateAtStart else {
                throw CodexDesktopStateError.stateReadFailed(
                    desktopStateAtStartError ?? "unknown read failure"
                )
            }
            let finalData = try Data(contentsOf: desktopStateURL)
            let finalState = try JSONDecoder().decode(CodexDesktopState.self, from: finalData)
            let finalIDs = try CodexDesktopState.stablePinnedThreadIDSet(
                start: desktopStateAtStart,
                end: finalState
            )
            desktopPinnedThreadIDs = finalIDs
            desktopPinStateAvailable = true
        } catch {
            desktopPinStateError = error.localizedDescription
        }

        return CodexInventorySnapshot(
            serverInfo: initializeResult,
            runtimeVersion: runtimeVersion,
            active: activeResult.records,
            archived: archivedResult.records,
            descendantRecords: descendantRecords,
            descendantNativeStates: descendantNativeStates,
            descendantGraphComplete: descendantGraphComplete,
            descendantGraphError: descendantGraphError,
            refreshedAt: Date(),
            isTruncated: activeResult.isTruncated || archivedResult.isTruncated,
            projects: projects,
            projectCatalogAvailable: projectCatalogAvailable,
            projectCatalogError: projectCatalogError,
            desktopPinnedThreadIDs: desktopPinnedThreadIDs,
            desktopPinStateAvailable: desktopPinStateAvailable,
            desktopPinStateError: desktopPinStateError,
            trustFolders: trustFolders,
            trustConfigurationAvailable: trustConfigurationAvailable,
            trustConfigurationError: trustConfigurationError
        )
    }

    private func listAllThreads(
        archived: Bool,
        sourceKinds: [String],
        process: Process,
        input: FileHandle,
        reader: JSONLineReader,
        requestID: inout Int
    ) throws -> (records: [CodexThreadRecord], isTruncated: Bool) {
        var pagination = CodexPaginationAccumulator(
            maximumPages: configuration.maximumPagesPerCollection
        )

        repeat {
            try Task.checkCancellation()
            var params: [String: Any] = [
                "archived": archived,
                "limit": configuration.pageSize,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "sourceKinds": sourceKinds,
                // Avoid the default scan-and-repair path. Phase 1 is intentionally read-only.
                "useStateDbOnly": true,
            ]
            if let cursor = pagination.nextCursor {
                params["cursor"] = cursor
            }

            let page: CodexThreadPage = try request(
                process: process,
                input: input,
                reader: reader,
                id: requestID,
                method: "thread/list",
                params: params
            )
            requestID += 1
            if !pagination.append(page) {
                break
            }
        } while true

        return (pagination.records, pagination.isTruncated)
    }

    private func request<Response: Decodable>(
        process: Process,
        input: FileHandle,
        reader: JSONLineReader,
        id: Int,
        method: String,
        params: [String: Any]
    ) throws -> Response {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        do {
            try send(["method": method, "id": id, "params": params], to: input)
        } catch {
            throw CodexAppServerError.malformedResponse(
                "could not write \(method) request: \(error.localizedDescription)"
            )
        }

        while let line = try reader.nextLine(deadline: deadline) {
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            guard let responseID = object["id"] as? NSNumber, responseID.intValue == id else {
                continue
            }
            if let error = object["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.intValue ?? -1
                let message = error["message"] as? String ?? "Unknown JSON-RPC error"
                throw CodexAppServerError.rpcError(code, message)
            }
            guard let result = object["result"] else {
                throw CodexAppServerError.malformedResponse("missing result for \(method)")
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: result)
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw CodexAppServerError.malformedResponse(
                    "could not decode \(method): \(error.localizedDescription)"
                )
            }
        }

        stopProcess(process, closing: nil)
        throw CodexAppServerError.processExited(
            process.terminationStatus,
            "The process ended before returning a JSON-RPC response. Child stderr is suppressed to prevent pipe deadlock."
        )
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.malformedResponse(
                "could not write request: \(error.localizedDescription)"
            )
        }
    }

    private func stopProcess(_ process: Process, closing input: FileHandle?) {
        try? input?.close()
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }

        process.interrupt()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func resolveExecutableURL() throws -> URL {
        if let explicit = configuration.executableURL {
            guard FileManager.default.isExecutableFile(atPath: explicit.path) else {
                throw CodexAppServerError.executableNotFound
            }
            return explicit
        }

        let candidates = Self.executableCandidates(
            path: ProcessInfo.processInfo.environment["PATH"]
        )
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw CodexAppServerError.executableNotFound
        }
        return executable
    }

    /// GUI apps inherit PATH from their launcher, which can unexpectedly put a
    /// bundled Desktop alpha runtime ahead of the user's normal Codex install.
    /// Prefer conventional standalone install locations, then fall back to PATH.
    static func executableCandidates(path: String?) -> [URL] {
        let conventional = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        let inherited = path?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") } ?? []
        var seenPaths: Set<String> = []
        return (conventional + inherited).filter {
            seenPaths.insert($0.standardizedFileURL.path).inserted
        }
    }

    private func probeRuntimeVersion(executableURL: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let versionOutput = String(data: data, encoding: .utf8) else {
            return nil
        }
        return CodexAppServerProvider.runtimeVersion(fromVersionOutput: versionOutput)
    }
}

public actor CodexAppServerProvider: SessionProvider, ExactSessionReadbackProviding, ArchiveScopeSnapshotProviding {
    public nonisolated let system: AgentSystem = .codex
    public nonisolated let capabilities: SessionCapabilities = .codexLiveReadOnly

    private let source: any CodexInventorySource
    private var latestDiagnostics: ProviderDiagnostics
    private var latestProjects: [SessionProject] = []
    private var latestArchiveScope = ArchiveScopeSnapshot(nodes: [], isComplete: false)

    public init(configuration: CodexAppServerConfiguration = CodexAppServerConfiguration()) {
        self.source = CodexAppServerClient(configuration: configuration)
        self.latestDiagnostics = ProviderDiagnostics(
            system: .codex,
            connectionState: .degraded,
            inventoryComplete: false,
            protectionComplete: false,
            capabilities: .codexLiveReadOnly,
            messages: ["Live inventory has not been refreshed yet."]
        )
    }

    init(source: any CodexInventorySource) {
        self.source = source
        self.latestDiagnostics = ProviderDiagnostics(
            system: .codex,
            connectionState: .degraded,
            inventoryComplete: false,
            protectionComplete: false,
            capabilities: .codexLiveReadOnly,
            messages: ["Live inventory has not been refreshed yet."]
        )
    }

    public func sessions() async throws -> [AgentSession] {
        do {
            let snapshot = try await source.inventory()
            let mapped = Self.map(snapshot: snapshot)
            latestArchiveScope = Self.archiveScope(snapshot: snapshot)
            latestProjects = snapshot.projects.compactMap { project in
                guard let rootPath = project.rootPaths.first else { return nil }
                return SessionProject(id: project.id, name: project.name, rootPath: rootPath)
            }
            latestDiagnostics = Self.makeDiagnostics(snapshot: snapshot)
            return mapped
        } catch {
            latestProjects = []
            latestArchiveScope = ArchiveScopeSnapshot(nodes: [], isComplete: false)
            latestDiagnostics = ProviderDiagnostics(
                system: .codex,
                connectionState: .unavailable,
                inventoryComplete: false,
                protectionComplete: false,
                capabilities: .codexLiveReadOnly,
                messages: [error.localizedDescription]
            )
            throw error
        }
    }

    public func projects() -> [SessionProject] {
        latestProjects
    }

    public func diagnostics() -> ProviderDiagnostics {
        latestDiagnostics
    }

    public func archiveScopeSnapshot() -> ArchiveScopeSnapshot {
        latestArchiveScope
    }

    public func exactReadback(nativeSessionID: String) async -> ExactSessionReadbackEvidence {
        let trimmedID = nativeSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            return ExactSessionReadbackEvidence(
                provider: .codex,
                nativeSessionID: nativeSessionID,
                status: .unavailable,
                observedAt: Date(),
                runtimeVersion: latestDiagnostics.runtimeVersion,
                evidenceKind: .invalidRequest,
                message: "Exact-ID readback requires a non-empty native session ID."
            )
        }

        do {
            let snapshot = try await source.exactRead(threadID: trimmedID)
            guard snapshot.thread.id == trimmedID else {
                return ExactSessionReadbackEvidence(
                    provider: .codex,
                    nativeSessionID: trimmedID,
                    status: .unavailable,
                    observedAt: snapshot.observedAt,
                    runtimeVersion: snapshot.thread.cliVersion,
                    evidenceKind: .identityMismatch,
                    message: "thread/read returned a different native session ID."
                )
            }
            return ExactSessionReadbackEvidence(
                provider: .codex,
                nativeSessionID: trimmedID,
                status: .present,
                observedAt: snapshot.observedAt,
                runtimeVersion: snapshot.runtimeVersion,
                evidenceKind: .exactMatch,
                message: "Official thread/read returned this exact persisted thread without resuming it."
            )
        } catch {
            // The official protocol does not currently document a stable
            // not-found code. Never convert a generic RPC failure into absence.
            let failure = Self.exactReadbackFailure(error)
            return ExactSessionReadbackEvidence(
                provider: .codex,
                nativeSessionID: trimmedID,
                status: .unavailable,
                observedAt: Date(),
                runtimeVersion: latestDiagnostics.runtimeVersion,
                evidenceKind: failure.kind,
                rpcCode: failure.rpcCode,
                message: error.localizedDescription
            )
        }
    }

    private static func exactReadbackFailure(
        _ error: Error
    ) -> (kind: ExactSessionReadbackEvidenceKind, rpcCode: Int?) {
        guard let appServerError = error as? CodexAppServerError else {
            return (.unknownFailure, nil)
        }
        switch appServerError {
        case let .rpcError(code, _):
            // No Codex App Server release currently has a documented stable
            // thread/read not-found code, so every RPC error stays unavailable.
            return (.rpcError, code)
        case .responseTimeout:
            return (.timeout, nil)
        case .exactReadUnavailable:
            return (.sourceUnavailable, nil)
        case .malformedResponse:
            return (.malformedResponse, nil)
        case .executableNotFound, .launchFailed, .processExited:
            return (.processFailure, nil)
        }
    }

    public func preview(
        operation: SessionOperation,
        managerKeys: [String]
    ) throws -> OperationPreview {
        throw SessionManagerError.unsupportedOperation(
            "The Codex Live inventory adapter does not support \(operation.label); native lifecycle operations require a dedicated gated facade."
        )
    }

    public func execute(
        preview: OperationPreview,
        confirmationToken: String
    ) throws -> OperationReport {
        throw SessionManagerError.unsupportedOperation(
            "The Codex Live inventory adapter cannot execute lifecycle mutations."
        )
    }

    static func map(snapshot: CodexInventorySnapshot) -> [AgentSession] {
        var uniqueRecords: [String: (CodexThreadRecord, NativeSessionState)] = [:]
        for record in snapshot.active {
            uniqueRecords[record.id] = (record, .active)
        }
        // If external state drifts between the two list calls, the later archived
        // observation wins instead of crashing on a duplicate native ID.
        for record in snapshot.archived {
            uniqueRecords[record.id] = (record, .archived)
        }
        let records = Array(uniqueRecords.values)
        var graphByID: [String: CodexThreadRecord] = [:]
        for record in snapshot.descendantRecords {
            graphByID[record.id] = record
        }
        let graphRecords = Array(graphByID.values)
        let children = Dictionary(grouping: graphRecords.compactMap { record in
            record.parentThreadId.map { ($0, record.id) }
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        let allGraphPinStatesKnown = snapshot.descendantGraphComplete
            && graphRecords.allSatisfy { effectivePinState(for: $0, snapshot: snapshot) != nil }

        return records.map { record, nativeState in
            let descendantIDs = descendants(of: record.id, children: children)
            let hasPinnedDescendant = descendantIDs.contains {
                guard let descendant = graphByID[$0] else { return false }
                return effectivePinState(for: descendant, snapshot: snapshot) == true
            }
            let observedRunning = record.status.type == "active"
            let trustFolder = matchingTrustFolder(
                for: record.cwd,
                trustFolders: snapshot.trustFolders
            )
            let project = matchingProject(for: record.cwd, projects: snapshot.projects)
            let protection = (try? ProtectionAuthorityPolicy.resolve(
                system: .codex,
                observations: protectionObservations(
                    record: record,
                    pinObservation: pinObservation(for: record, snapshot: snapshot),
                    observedRunning: observedRunning,
                    hasPinnedDescendant: hasPinnedDescendant,
                    allGraphPinStatesKnown: allGraphPinStatesKnown
                )
            )) ?? unavailableProtection
            return AgentSession(
                system: .codex,
                nativeID: record.id,
                title: displayTitle(for: record),
                project: project,
                workingDirectory: record.cwd,
                trustFolderPath: trustFolder?.path,
                folderTrustState: trustFolder?.state
                    ?? (snapshot.trustConfigurationAvailable ? .unconfigured : .unavailable),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(record.updatedAt)),
                sizeBytes: nil,
                nativeState: nativeState,
                isTrashMember: false,
                protection: protection,
                descendantCount: snapshot.descendantGraphComplete ? descendantIDs.count : 0,
                descendantCountKnown: snapshot.descendantGraphComplete
            )
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    static func archiveScope(snapshot: CodexInventorySnapshot) -> ArchiveScopeSnapshot {
        var recordsByID: [String: CodexThreadRecord] = [:]
        for record in snapshot.descendantRecords {
            recordsByID[record.id] = record
        }
        let children = Dictionary(grouping: recordsByID.values.compactMap { record in
            record.parentThreadId.map { ($0, record.id) }
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        let allGraphPinStatesKnown = snapshot.descendantGraphComplete
            && recordsByID.values.allSatisfy {
                effectivePinState(for: $0, snapshot: snapshot) != nil
            }
        let nodes = recordsByID.values.compactMap { record -> ArchiveScopeNode? in
            guard let nativeState = snapshot.descendantNativeStates[record.id] else { return nil }
            let descendantIDs = descendants(of: record.id, children: children)
            let observedRunning = record.status.type == "active"
            let protection = (try? ProtectionAuthorityPolicy.resolve(
                system: .codex,
                observations: protectionObservations(
                    record: record,
                    pinObservation: pinObservation(for: record, snapshot: snapshot),
                    observedRunning: observedRunning,
                    hasPinnedDescendant: descendantIDs.contains {
                        guard let descendant = recordsByID[$0] else { return false }
                        return effectivePinState(for: descendant, snapshot: snapshot) == true
                    },
                    allGraphPinStatesKnown: allGraphPinStatesKnown
                )
            )) ?? unavailableProtection
            return ArchiveScopeNode(
                managerKey: "\(AgentSystem.codex.rawValue):\(record.id)",
                nativeSessionID: record.id,
                parentNativeSessionID: record.parentThreadId,
                title: displayTitle(for: record),
                nativeState: nativeState,
                protection: protection,
                descendantCount: snapshot.descendantGraphComplete ? descendantIDs.count : 0,
                descendantCountKnown: snapshot.descendantGraphComplete,
                projectID: matchingProject(
                    for: record.cwd,
                    projects: snapshot.projects
                )?.id,
                workingDirectory: record.cwd
            )
        }
        return ArchiveScopeSnapshot(
            nodes: nodes.sorted { $0.managerKey < $1.managerKey },
            isComplete: snapshot.descendantGraphComplete
                && nodes.count == recordsByID.count
        )
    }

    private static func makeDiagnostics(snapshot: CodexInventorySnapshot) -> ProviderDiagnostics {
        let records = snapshot.active + snapshot.archived
        let historicalThreadVersions = Set(records.map(\.cliVersion))
        let runtimeVersion = snapshot.runtimeVersion
        let pinStateAvailable = records.allSatisfy {
            effectivePinState(for: $0, snapshot: snapshot) != nil
        }
        let pinConflictIDs: [String] = (records + snapshot.descendantRecords).compactMap { record in
            guard let serverValue = record.isPinned,
                  snapshot.desktopPinStateAvailable else { return nil }
            let desktopValue = snapshot.desktopPinnedThreadIDs.contains(record.id)
            return serverValue == desktopValue ? nil : record.id
        }
        let observedRunningCount = records.filter { $0.status.type == "active" }.count
        let descendantRecordsByID = Dictionary(
            snapshot.descendantRecords.map { ($0.id, $0) },
            uniquingKeysWith: { _, later in later }
        )
        let parentRelationshipCount = descendantRecordsByID.values.filter {
            $0.parentThreadId != nil
        }.count
        var observedCapabilities = SessionCapabilities.codexLiveReadOnly
        let lifecycleContractKnown = supportsVerifiedLifecycleContract(runtimeVersion)
        observedCapabilities.hasNativeArchiveInterface = lifecycleContractKnown
        observedCapabilities.hasNativeUnarchiveInterface = lifecycleContractKnown
        observedCapabilities.hasNativeDeleteInterface = supportsVerifiedDeleteContract(
            runtimeVersion
        )
        observedCapabilities.canReadPinnedState = pinStateAvailable
        observedCapabilities.canReadRunningState = !records.isEmpty
            && records.allSatisfy { $0.status.type == "active" }
        observedCapabilities.canReadDescendants = snapshot.descendantGraphComplete
        observedCapabilities.canReadFolderTrust = snapshot.trustConfigurationAvailable
        var messages = [
            "Inventory uses thread/list with useStateDbOnly=true; JSONL scan-and-repair is disabled.",
            "Loaded \(snapshot.active.count) active and \(snapshot.archived.count) archived threads through cursor pagination.",
            snapshot.descendantGraphComplete
                ? "All-source descendant inventory loaded \(descendantRecordsByID.count) threads with \(parentRelationshipCount) parent relationships and reached the final cursor."
                : "Descendant graph is unavailable; partial all-source results are not treated as complete.",
            snapshot.trustConfigurationAvailable
                ? "Folder trust is read separately from config/read and matched by the longest configured ancestor path."
                : "Folder trust is unavailable; thread cwd is shown only as a working folder.",
            snapshot.projectCatalogAvailable
                ? "Projects come from Codex Desktop local-projects and are matched to thread cwd by the longest project root path."
                : "Codex Desktop project catalog is unavailable; sessions are not assigned to projects.",
            runtimeVersion.map {
                "Runtime contract is bound to `\($0)` reported by `--version` from the exact selected Codex executable; initialize userAgent identifies this client and is diagnostic only."
            } ?? "Runtime contract could not be bound to the selected Codex executable.",
            "Observed \(observedRunningCount) active threads in this manager-owned App Server process; non-active status cannot rule out activity in another host.",
            "Inventory and exact readback use separate stdio App Server processes; they do not provide target writer ownership or release authority.",
            "Current-task identity is unavailable because App Server exposes no authoritative cross-host current field.",
            lifecycleContractKnown
                ? "The verified 0.147.0 runtime contract includes thread/archive, thread/unarchive, and thread/delete. The inventory provider remains read-only; guarded lifecycle facades authorize execution separately."
                : "This runtime is outside the verified lifecycle contract; native mutation interfaces are treated as unavailable.",
        ]
        if let trustConfigurationError = snapshot.trustConfigurationError {
            messages.append("config/read failed: \(trustConfigurationError)")
        }
        if let projectCatalogError = snapshot.projectCatalogError {
            messages.append("Codex Desktop project catalog read failed: \(projectCatalogError)")
        }
        if snapshot.desktopPinStateAvailable {
            messages.append(
                "Pin state uses matching start/end reads of Codex Desktop pinned-thread-ids (\(snapshot.desktopPinnedThreadIDs.count) pinned Codex sessions)."
            )
        } else if let desktopPinStateError = snapshot.desktopPinStateError {
            messages.append("Codex Desktop pin-state read failed closed: \(desktopPinStateError)")
        }
        if let descendantGraphError = snapshot.descendantGraphError {
            messages.append("Descendant graph probe failed closed: \(descendantGraphError)")
        }
        if !pinStateAvailable {
            messages.append(
                "Pin protection is unavailable because neither a consistent Codex Desktop pinned-thread-ids snapshot nor thread/list isPinned supplied a non-conflicting value for every listed session."
            )
        }
        if !pinConflictIDs.isEmpty {
            messages.append(
                "Pin sources disagree for exact session IDs: \(Set(pinConflictIDs).sorted().joined(separator: ", "))."
            )
        }
        if snapshot.isTruncated {
            messages.append(
                "Inventory reached the 10,000-item-per-collection safety limit or received a repeated cursor; the UI shows a bounded subset."
            )
        }
        if historicalThreadVersions.count > 1 {
            messages.append(
                "Inventory contains threads created by multiple CLI versions; lifecycle contract binding uses `--version` from the selected executable rather than historical thread metadata."
            )
        }
        if runtimeVersion == nil {
            messages.append(
                "The selected Codex executable did not return a parseable `codex-cli <version>` result from `--version`; lifecycle interfaces remain unavailable."
            )
        }
        let isDegraded = snapshot.isTruncated
            || !snapshot.projectCatalogAvailable
            || !snapshot.descendantGraphComplete
            || !pinStateAvailable
        return ProviderDiagnostics(
            system: .codex,
            connectionState: isDegraded ? .degraded : .ready,
            runtimeVersion: runtimeVersion,
            userAgent: snapshot.serverInfo.userAgent,
            lastRefreshedAt: snapshot.refreshedAt,
            inventoryComplete: !snapshot.isTruncated,
            protectionComplete: pinStateAvailable
                && observedCapabilities.canReadRunningState
                && observedCapabilities.canReadCurrentState
                && allGraphPinStatesKnown(snapshot: snapshot),
            capabilities: observedCapabilities,
            messages: messages
        )
    }

    /// Compatibility is intentionally allow-listed. A future or older runtime
    /// must be audited against its generated schema before lifecycle execution
    /// can rely on the same method and readback semantics.
    public static func supportsVerifiedLifecycleContract(_ runtimeVersion: String?) -> Bool {
        guard let runtimeVersion else { return false }
        return runtimeVersion == "0.147.0" || runtimeVersion.hasPrefix("0.147.0-")
    }

    public static func supportsVerifiedDeleteContract(_ runtimeVersion: String?) -> Bool {
        supportsVerifiedLifecycleContract(runtimeVersion)
    }

    /// The initialize `userAgent` identifies the client (for this app it begins
    /// with `agent_session_manager/`) and is not runtime authority. Bind the
    /// lifecycle contract to `--version` from the exact selected executable.
    static func runtimeVersion(fromVersionOutput output: String) -> String? {
        let tokens = output.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 2, tokens[0] == "codex-cli" else { return nil }
        let version = String(tokens[1])
        guard version.first?.isNumber == true,
              version.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter }) else {
            return nil
        }
        return version
    }

    private static func allGraphPinStatesKnown(snapshot: CodexInventorySnapshot) -> Bool {
        snapshot.descendantGraphComplete
            && snapshot.descendantRecords.allSatisfy {
                effectivePinState(for: $0, snapshot: snapshot) != nil
            }
    }

    private static func protectionObservations(
        record: CodexThreadRecord,
        pinObservation: ProtectionAuthorityObservation?,
        observedRunning: Bool,
        hasPinnedDescendant: Bool,
        allGraphPinStatesKnown: Bool
    ) -> [ProtectionAuthorityObservation] {
        var observations = [
            ProtectionAuthorityObservation(
                kind: .running,
                isProtected: observedRunning,
                source: .codexThreadListStatus,
                scope: .managerProcess
            ),
        ]
        if let pinObservation {
            observations.append(pinObservation)
        }
        if allGraphPinStatesKnown {
            observations.append(ProtectionAuthorityObservation(
                kind: .pinnedDescendant,
                isProtected: hasPinnedDescendant,
                source: .codexCompleteDescendantGraph,
                scope: .completeProviderGraph
            ))
        }
        return observations
    }

    private static func effectivePinState(
        for record: CodexThreadRecord,
        snapshot: CodexInventorySnapshot
    ) -> Bool? {
        let desktopValue = snapshot.desktopPinStateAvailable
            ? snapshot.desktopPinnedThreadIDs.contains(record.id)
            : nil
        switch (record.isPinned, desktopValue) {
        case let (.some(serverValue), .some(desktopValue)):
            return serverValue == desktopValue ? serverValue : nil
        case let (.some(serverValue), .none):
            return serverValue
        case let (.none, .some(desktopValue)):
            return desktopValue
        case (.none, .none):
            return nil
        }
    }

    private static func pinObservation(
        for record: CodexThreadRecord,
        snapshot: CodexInventorySnapshot
    ) -> ProtectionAuthorityObservation? {
        guard let value = effectivePinState(for: record, snapshot: snapshot) else {
            return nil
        }
        return ProtectionAuthorityObservation(
            kind: .pinned,
            isProtected: value,
            source: record.isPinned == nil
                ? .codexDesktopPinnedThreadIDs
                : .codexThreadListPin,
            scope: .providerPersistentState
        )
    }

    private static var unavailableProtection: SessionProtection {
        SessionProtection(
            isPinnedKnown: false,
            isRunningKnown: false,
            isCurrentKnown: false,
            hasPinnedDescendantKnown: false
        )
    }

    private static func descendants(
        of rootID: String,
        children: [String: [String]]
    ) -> Set<String> {
        var result: Set<String> = []
        var stack = children[rootID] ?? []
        while let candidate = stack.popLast() {
            guard candidate != rootID, result.insert(candidate).inserted else { continue }
            stack.append(contentsOf: children[candidate] ?? [])
        }
        return result
    }

    private static func displayTitle(for record: CodexThreadRecord) -> String {
        if let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let firstLine = record.preview
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return "Untitled session" }
        return String(firstLine.prefix(120))
    }

    private static func matchingProject(
        for workingDirectory: String,
        projects: [CodexDesktopProject]
    ) -> SessionProject? {
        let cwd = URL(fileURLWithPath: workingDirectory).standardized.path
        return projects.flatMap { project in
            project.rootPaths.compactMap { rawRoot -> (SessionProject, Int)? in
                let root = URL(fileURLWithPath: rawRoot).standardized.path
                guard cwd == root || cwd.hasPrefix(root + "/") else { return nil }
                return (
                    SessionProject(id: project.id, name: project.name, rootPath: root),
                    root.count
                )
            }
        }.max { $0.1 < $1.1 }?.0
    }

    private static func matchingTrustFolder(
        for workingDirectory: String,
        trustFolders: [String: FolderTrustState]
    ) -> (path: String, state: FolderTrustState)? {
        let cwd = URL(fileURLWithPath: workingDirectory).standardized.path
        return trustFolders.compactMap { path, state in
            let folder = URL(fileURLWithPath: path).standardized.path
            guard cwd == folder || cwd.hasPrefix(folder + "/") else { return nil }
            return (folder, state)
        }.max { $0.0.count < $1.0.count }
    }
}

private final class JSONLineReader {
    private let fileHandle: FileHandle
    private var buffer = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func nextLine(deadline: Date) throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                return line
            }

            let remainingMilliseconds = Int(deadline.timeIntervalSinceNow * 1_000)
            guard remainingMilliseconds > 0 else {
                throw CodexAppServerError.responseTimeout
            }
            var descriptor = pollfd(
                fd: fileHandle.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                Int32(min(remainingMilliseconds, Int(Int32.max)))
            )
            if pollResult == 0 {
                throw CodexAppServerError.responseTimeout
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CodexAppServerError.malformedResponse(
                    "stdout poll failed with errno \(errno)"
                )
            }
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let bytesRead = Darwin.read(fileHandle.fileDescriptor, &bytes, bytes.count)
            if bytesRead < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CodexAppServerError.malformedResponse(
                    "stdout read failed with errno \(errno)"
                )
            }
            guard bytesRead > 0 else {
                if buffer.isEmpty { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(contentsOf: bytes.prefix(bytesRead))
        }
    }
}
