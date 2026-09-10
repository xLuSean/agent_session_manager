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
    var isPinned: Bool?
    let gitInfo: CodexGitInfo?
    /// In-memory provenance, never supplied by an official JSON response.
    var localSupplement: CodexLocalInventorySupplement? = nil

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, parentThreadId, preview, ephemeral, modelProvider,
             createdAt, updatedAt, status, cwd, cliVersion, name, isPinned, gitInfo
    }
}

struct CodexThreadPage: Codable, Hashable, Sendable {
    let data: [CodexThreadRecord]
    let nextCursor: String?
}

struct CodexThreadReadResponse: Codable, Hashable, Sendable {
    let thread: CodexThreadRecord
}

private struct CodexThreadLifecycleResponse: Decodable {}

#if ASM_ISOLATED_DELETE_ACCEPTANCE
private struct CodexThreadStartResponse: Decodable {
    let thread: CodexThreadRecord
}

struct CodexIsolatedDeleteAcceptanceCreatedThread: Sendable {
    let thread: CodexThreadRecord
    let turnStatus: String
    let interruptRequestCount: Int
}
#endif

struct CodexExactReadSnapshot: Hashable, Sendable {
    let serverInfo: CodexServerInfo
    let runtimeVersion: String?
    let thread: CodexThreadRecord
    let observedAt: Date
}

/// Absence observed by the selected runtime, not a version supplied by a caller.
/// Ordinary exactRead keeps its existing RPC error contract for non-Delete consumers.
struct CodexDeleteAbsenceEvidence: Error, Sendable {
    let nativeSessionID: String
    let runtimeVersion: String
    let observedAt: Date
    let compatibilityAdmission: CodexCompatibilityAdmission?

    init(nativeSessionID: String, runtimeVersion: String, observedAt: Date,
         compatibilityAdmission: CodexCompatibilityAdmission? = nil) {
        self.nativeSessionID = nativeSessionID
        self.runtimeVersion = runtimeVersion
        self.observedAt = observedAt
        self.compatibilityAdmission = compatibilityAdmission
    }
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
    var compatibilityBinding: CodexCompatibilityBinding? = nil
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
    /// Fresh complete lifecycle collections only; never use for mutation preflight.
    func lifecycleReadback() async throws -> CodexInventorySnapshot
    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot
    /// Read-only external-deletion acknowledgement; never supplies Delete authority.
    func exactReadForExternalDeletion(threadID: String) async throws -> CodexExactReadSnapshot
    func exactReadForDeletion(threadID: String) async throws -> CodexExactReadSnapshot
    func exactReadForDeletion(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws -> CodexExactReadSnapshot
}

extension CodexInventorySource {
    func exactReadForExternalDeletion(threadID: String) async throws -> CodexExactReadSnapshot {
        // Alternate sources cannot turn a raw RPC error into verified absence.
        try await exactRead(threadID: threadID)
    }

    func exactReadForDeletion(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws -> CodexExactReadSnapshot {
        guard expectedCompatibility == nil else { throw CodexCompatibilityInspector.CheckError.admissionRequired }
        return try await exactReadForDeletion(threadID: threadID)
    }

    func exactReadForDeletion(threadID: String) async throws -> CodexExactReadSnapshot {
        // A raw error from an alternate source is not verified absence.
        try await exactRead(threadID: threadID)
    }
    func lifecycleReadback() async throws -> CodexInventorySnapshot {
        try await inventory()
    }

    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot {
        throw CodexAppServerError.exactReadUnavailable
    }

}

/// Mutation capability is intentionally separate from the read-only inventory
/// source. Only the native Archive facade's internal transport owns this protocol.
protocol CodexArchiveSource: Sendable {
    func archive(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws
    func inventory() async throws -> CodexInventorySnapshot
    func archive(threadID: String) async throws
}

/// Restore mutation capability is kept separate from read-only inventory and
/// Archive so production call sites must opt into the exact lifecycle method.
protocol CodexRestoreSource: Sendable {
    func unarchive(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws
    func inventory() async throws -> CodexInventorySnapshot
    func unarchive(threadID: String) async throws
}

/// Permanent Delete mutation capability remains separate from inventory,
/// Archive, and Restore so only the guarded Delete facade can construct it.
protocol CodexDeleteSource: CodexInventorySource {
    func delete(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws
    func delete(threadID: String) async throws
}

extension CodexArchiveSource {
    func archive(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        guard expectedCompatibility == nil else { throw CodexCompatibilityInspector.CheckError.admissionRequired }
        try await archive(threadID: threadID)
    }
}

extension CodexRestoreSource {
    func unarchive(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        guard expectedCompatibility == nil else { throw CodexCompatibilityInspector.CheckError.admissionRequired }
        try await unarchive(threadID: threadID)
    }
}

extension CodexDeleteSource {
    func delete(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        guard expectedCompatibility == nil else { throw CodexCompatibilityInspector.CheckError.admissionRequired }
        try await delete(threadID: threadID)
    }
}

public struct CodexAppServerConfiguration: Hashable, Sendable {
    public var executableURL: URL?
    public var pageSize: Int
    public var maximumPagesPerCollection: Int
    public var timeout: TimeInterval
#if ASM_ISOLATED_DELETE_ACCEPTANCE
    fileprivate var isolatedDeleteAcceptanceCodexHomeURL: URL?
#endif

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
#if ASM_ISOLATED_DELETE_ACCEPTANCE
        self.isolatedDeleteAcceptanceCodexHomeURL = nil
#endif
    }

#if ASM_ISOLATED_DELETE_ACCEPTANCE
    static func isolatedDeleteAcceptance(
        executableURL: URL,
        codexHomeURL: URL,
        timeout: TimeInterval = 45
    ) -> Self {
        var configuration = Self(executableURL: executableURL, timeout: timeout)
        configuration.isolatedDeleteAcceptanceCodexHomeURL = codexHomeURL
        return configuration
    }
#endif
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
    private let compatibilityInspector: CodexCompatibilityInspector
    private let expectedCodexHome: URL?

    public init(configuration: CodexAppServerConfiguration = CodexAppServerConfiguration()) {
        self.configuration = configuration
        self.compatibilityInspector = CodexCompatibilityInspector()
        self.expectedCodexHome = nil
    }

    init(configuration: CodexAppServerConfiguration, compatibilityInspector: CodexCompatibilityInspector) {
        self.configuration = configuration
        self.compatibilityInspector = compatibilityInspector
        self.expectedCodexHome = nil
    }

    init(configuration: CodexAppServerConfiguration = .init(), expectedCodexHome: URL) {
        self.configuration = configuration
        self.compatibilityInspector = CodexCompatibilityInspector()
        self.expectedCodexHome = expectedCodexHome
    }

    /// Ghost's canonical readers and mutators use this fixed production root.
    /// Ordinary providers deliberately keep their server-selected custom home.
    static func ghostRepairProduction(configuration: CodexAppServerConfiguration = .init()) -> CodexAppServerClient {
        CodexAppServerClient(configuration: configuration, expectedCodexHome:
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
    }

    func inventory() async throws -> CodexInventorySnapshot {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        return try await boundInventory(executableURL: executableURL)
    }

    private func boundInventory(executableURL: URL, lifecycleOnly: Bool = false) async throws -> CodexInventorySnapshot {
        let beforeSHA = try CodexCompatibilityInspector.executableSHA256(executableURL)
        var snapshot = try runInventory(executableURL: executableURL, lifecycleOnly: lifecycleOnly)
        if let version = snapshot.runtimeVersion,
           snapshot.serverInfo.codexHome.hasPrefix("/") {
            snapshot.compatibilityBinding = try? await compatibilityInspector.lifecycleBinding(
                .init(providerExecutable: executableURL, codexHome: URL(fileURLWithPath: snapshot.serverInfo.codexHome)),
                runtimeVersion: version)
        }
        guard try CodexCompatibilityInspector.executableSHA256(executableURL) == beforeSHA else {
            throw CodexCompatibilityInspector.CheckError.changed
        }
        return snapshot
    }

    func compatibilityExecutableURL() throws -> URL { try resolveExecutableURL() }

    func lifecycleReadback() async throws -> CodexInventorySnapshot {
        try Task.checkCancellation()
        return try await boundInventory(executableURL: resolveExecutableURL(), lifecycleOnly: true)
    }

    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        return try await runExactRead(threadID: threadID, executableURL: executableURL)
    }

    func exactReadForExternalDeletion(threadID: String) async throws -> CodexExactReadSnapshot {
        try Task.checkCancellation()
        return try await runExactRead(threadID: threadID, executableURL: resolveExecutableURL(),
                                      captureExternalDeletionAbsence: true)
    }

    func archive(threadID: String) async throws {
        try await archive(threadID: threadID, expectedCompatibility: nil)
    }

    func archive(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        try await runLifecycleMutation(
            threadID: threadID,
            method: "thread/archive",
            executableURL: executableURL,
            expectedCompatibility: expectedCompatibility
        )
    }

    func exactReadForDeletion(threadID: String) async throws -> CodexExactReadSnapshot {
        try await exactReadForDeletion(threadID: threadID, expectedCompatibility: nil)
    }

    func exactReadForDeletion(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws -> CodexExactReadSnapshot {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        return try await runExactRead(
            threadID: threadID,
            executableURL: executableURL,
            captureDeleteAbsence: true,
            expectedCompatibility: expectedCompatibility
        )
    }

    func unarchive(threadID: String) async throws {
        try await unarchive(threadID: threadID, expectedCompatibility: nil)
    }

    func unarchive(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        try await runLifecycleMutation(
            threadID: threadID,
            method: "thread/unarchive",
            executableURL: executableURL,
            expectedCompatibility: expectedCompatibility
        )
    }

    func delete(threadID: String) async throws {
        try await delete(threadID: threadID, expectedCompatibility: nil)
    }

    func delete(threadID: String, expectedCompatibility: CodexCompatibilityBinding?) async throws {
        try Task.checkCancellation()
        let executableURL = try resolveExecutableURL()
        try await runLifecycleMutation(
            threadID: threadID,
            method: "thread/delete",
            executableURL: executableURL,
            expectedCompatibility: expectedCompatibility
        )
    }

#if ASM_ISOLATED_DELETE_ACCEPTANCE
    /// Creates the sole disposable session for the sandboxed Delete acceptance
    /// through public thread/start + one turn/start in the credential-free,
    /// network-denied acceptance sandbox. Stop the sole test turn if it has
    /// not failed naturally, then require fresh cross-process exact/list reads.
    /// A history append alone persists a thread but does not make it listable.
    func startIsolatedDeleteAcceptanceThread(
        workingDirectoryURL: URL,
        didCreate: @Sendable (String) throws -> Void
    ) async throws -> CodexIsolatedDeleteAcceptanceCreatedThread {
        try Task.checkCancellation()
        guard configuration.isolatedDeleteAcceptanceCodexHomeURL != nil else {
            throw CodexAppServerError.launchFailed(
                "Isolated Delete acceptance requires an expected codexHome."
            )
        }
        let executableURL = try resolveExecutableURL()
        guard probeRuntimeVersion(executableURL: executableURL) == "0.153.4" else {
            throw CodexAppServerError.launchFailed(
                "Isolated Delete acceptance requires exact Codex runtime 0.153.4."
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
        let serverInfo: CodexServerInfo = try request(
            process: process,
            input: input.fileHandleForWriting,
            reader: reader,
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "agent_session_manager_isolated_delete_acceptance",
                    "title": "Agent Session Manager Isolated Delete Acceptance",
                    "version": "0.1.0",
                ],
            ]
        )
        try verifyExpectedCodexHome(serverInfo.codexHome)
        try verifyIsolatedDeleteAcceptanceCodexHome(serverInfo.codexHome)
        try send(
            ["method": "initialized", "params": [:] as [String: Any]],
            to: input.fileHandleForWriting
        )
        let response: CodexThreadStartResponse = try request(
            process: process,
            input: input.fileHandleForWriting,
            reader: reader,
            id: 2,
            method: "thread/start",
            params: [
                "approvalPolicy": "never",
                "cwd": workingDirectoryURL.path,
                "ephemeral": false,
                "sandbox": "read-only",
                "sessionStartSource": "startup",
                "threadSource": "cli",
            ]
        )
        guard response.thread.cwd == workingDirectoryURL.path,
              !response.thread.ephemeral,
              response.thread.parentThreadId == nil,
              let uuid = UUID(uuidString: response.thread.id),
              uuid.uuidString.lowercased() == response.thread.id.lowercased() else {
            throw CodexAppServerError.malformedResponse(
                "Isolated thread/start returned an unexpected disposable session identity."
            )
        }
        try didCreate(response.thread.id)
        let stopped = try finishIsolatedDeleteAcceptanceCreationTurn(
            threadID: response.thread.id, workingDirectoryURL: workingDirectoryURL,
            input: input.fileHandleForWriting, reader: reader
        )
        return .init(
            thread: response.thread,
            turnStatus: stopped.status,
            interruptRequestCount: stopped.interruptCount
        )
    }

    private func finishIsolatedDeleteAcceptanceCreationTurn(
        threadID: String, workingDirectoryURL: URL,
        input: FileHandle, reader: JSONLineReader
    ) throws -> (status: String, interruptCount: Int) {
        // Observe notifications even while waiting for an RPC response: the
        // terminal event may arrive before the interrupt acknowledgement.
        var terminals: [String: String] = [:]
        func nextObject(deadline: Date) throws -> [String: Any] {
            try Task.checkCancellation()
            guard let line = try reader.nextLine(deadline: deadline),
                  let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexAppServerError.malformedResponse("Isolated creation stream ended.")
            }
            if object["method"] as? String == "turn/completed",
               let params = object["params"] as? [String: Any],
               params["threadId"] as? String == threadID,
               let turn = params["turn"] as? [String: Any],
               let id = turn["id"] as? String,
               let status = turn["status"] as? String {
                terminals[id] = status
            }
            return object
        }
        func exchange(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
            guard ["turn/start", "turn/interrupt"].contains(method),
                  params["threadId"] as? String == threadID else {
                throw CodexAppServerError.malformedResponse("Isolated creation request changed scope.")
            }
            try send(["id": id, "method": method, "params": params], to: input)
            let deadline = Date().addingTimeInterval(configuration.timeout)
            while true {
                let object = try nextObject(deadline: deadline)
                guard (object["id"] as? NSNumber)?.intValue == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw CodexAppServerError.rpcError(
                        (error["code"] as? NSNumber)?.intValue ?? -1,
                        "Isolated creation RPC failed; no retry is permitted."
                    )
                }
                guard let result = object["result"] as? [String: Any] else {
                    throw CodexAppServerError.malformedResponse("Isolated creation result is missing.")
                }
                return result
            }
        }
        let start = try exchange(id: 3, method: "turn/start", params: [
            "threadId": threadID, "cwd": workingDirectoryURL.path,
            "approvalPolicy": "never",
            "input": [["type": "text", "text": "Agent Session Manager isolated creation visibility test. No tools are needed."]],
        ])
        guard let turn = start["turn"] as? [String: Any],
              let turnID = turn["id"] as? String, !turnID.isEmpty else {
            throw CodexAppServerError.malformedResponse("Isolated creation turn identity is missing.")
        }
        let naturalDeadline = Date().addingTimeInterval(4)
        while terminals[turnID] == nil {
            do { _ = try nextObject(deadline: naturalDeadline) }
            catch CodexAppServerError.responseTimeout { break }
        }
        var interruptCount = 0
        if terminals[turnID] == nil {
            interruptCount = 1
            _ = try exchange(id: 4, method: "turn/interrupt", params: [
                "threadId": threadID, "turnId": turnID,
            ])
            let terminalDeadline = Date().addingTimeInterval(3)
            while terminals[turnID] == nil { _ = try nextObject(deadline: terminalDeadline) }
        }
        guard let status = terminals[turnID], ["failed", "interrupted"].contains(status) else {
            throw CodexAppServerError.malformedResponse("Isolated creation turn did not stop as expected.")
        }
        return (status, interruptCount)
    }
#endif

    private func runLifecycleMutation(
        threadID: String,
        method: String,
        executableURL: URL,
        expectedCompatibility: CodexCompatibilityBinding? = nil
    ) async throws {
        let feature: CodexCompatibilityFeature = method == "thread/delete" ? .officialDelete : .archiveRestore
        let runtimeVersion = probeRuntimeVersion(executableURL: executableURL)
        let contractSupported = method == "thread/delete"
            ? CodexAppServerProvider.supportsVerifiedDeleteContract(runtimeVersion)
            : CodexAppServerProvider.supportsVerifiedLifecycleContract(runtimeVersion)
        // Only a matching cached test can admit an unknown runtime as far as
        // initialize. The actual initialized home is checked before mutation.
        let candidate: Bool
        if contractSupported && expectedCompatibility == nil { candidate = false }
        else {
            candidate = try await compatibilityInspector.hasLifecycleCandidate(
                executable: executableURL, runtimeVersion: runtimeVersion ?? "", feature: feature)
        }
        guard (contractSupported && expectedCompatibility == nil) || candidate else {
            throw CodexAppServerError.launchFailed(
                "Codex runtime \(runtimeVersion ?? "unavailable") is outside the verified lifecycle contract."
            )
        }
        let launchPath = executableURL.resolvingSymlinksInPath()
        let launchSHA = candidate ? try CodexCompatibilityInspector.executableSHA256(launchPath) : nil
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = launchPath
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
        try verifyExpectedCodexHome(serverInfo.codexHome)
#if ASM_ISOLATED_DELETE_ACCEPTANCE
        try verifyIsolatedDeleteAcceptanceCodexHome(serverInfo.codexHome)
#endif
        if candidate {
            guard serverInfo.codexHome.hasPrefix("/") else { throw CodexCompatibilityInspector.CheckError.changed }
            let compatibilityRequest = CodexCompatibilityRequest(providerExecutable: executableURL,
                codexHome: URL(fileURLWithPath: serverInfo.codexHome))
            let admission = try await compatibilityInspector.lifecycleAdmission(compatibilityRequest,
                runtimeVersion: runtimeVersion ?? "", feature: feature)
            guard (expectedCompatibility == nil || (expectedCompatibility?.environmentFingerprint == admission.environmentFingerprint
                    && expectedCompatibility?.supports(feature == .officialDelete ? .permanentDelete : .archive, runtimeVersion: runtimeVersion) == true)),
                  admission.runtime.sha256 == launchSHA,
                  executableURL.resolvingSymlinksInPath() == launchPath else {
                throw CodexCompatibilityInspector.CheckError.changed
            }
            try await compatibilityInspector.requireCurrent(admission, request: compatibilityRequest)
        }
        try Task.checkCancellation()
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
        executableURL: URL,
        captureDeleteAbsence: Bool = false,
        captureExternalDeletionAbsence: Bool = false,
        expectedCompatibility: CodexCompatibilityBinding? = nil
    ) async throws -> CodexExactReadSnapshot {
        let launchPath = executableURL.resolvingSymlinksInPath()
        let externalLaunchSHA = captureExternalDeletionAbsence
            ? try CodexCompatibilityInspector.executableSHA256(launchPath) : nil
        let runtimeVersion = probeRuntimeVersion(executableURL: launchPath)
        let dynamicDelete = captureDeleteAbsence && (expectedCompatibility != nil || !CodexAppServerProvider.supportsVerifiedDeleteContract(runtimeVersion))
        let launchSHA = dynamicDelete ? try CodexCompatibilityInspector.executableSHA256(launchPath) : nil
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = launchPath
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
        try verifyExpectedCodexHome(serverInfo.codexHome)
#if ASM_ISOLATED_DELETE_ACCEPTANCE
        try verifyIsolatedDeleteAcceptanceCodexHome(serverInfo.codexHome)
#endif
        try send(
            ["method": "initialized", "params": [:] as [String: Any]],
            to: input.fileHandleForWriting
        )
        let response: CodexThreadReadResponse
        do {
            response = try request(
                process: process, input: input.fileHandleForWriting, reader: reader,
                id: 2, method: "thread/read", params: ["threadId": threadID, "includeTurns": false]
            )
        } catch let error as CodexAppServerError {
            if captureExternalDeletionAbsence,
               let runtimeVersion,
               CodexAppServerProvider.supportsVerifiedExternalDeletionReadbackContract(runtimeVersion),
               case let .rpcError(code, message) = error,
               code == -32600, message == "thread not loaded: \(threadID)" {
                guard executableURL.resolvingSymlinksInPath() == launchPath,
                      try CodexCompatibilityInspector.executableSHA256(launchPath) == externalLaunchSHA else {
                    throw CodexCompatibilityInspector.CheckError.changed
                }
                throw CodexExternalDeletionAbsenceEvidence(nativeSessionID: threadID,
                    runtimeVersion: runtimeVersion, observedAt: Date())
            }
            // External acknowledgement never enters Delete admission or its
            // version-specific local absence contract.
            if captureExternalDeletionAbsence { throw error }
            var admission: CodexCompatibilityAdmission?
            if dynamicDelete, let runtimeVersion,
               case let .rpcError(code, message) = error,
               code == -32600, message == "thread not loaded: \(threadID)" {
                guard serverInfo.codexHome.hasPrefix("/") else { throw error }
                let compatibilityRequest = CodexCompatibilityRequest(providerExecutable: executableURL,
                    codexHome: URL(fileURLWithPath: serverInfo.codexHome))
                let verified = try await compatibilityInspector.lifecycleAdmission(compatibilityRequest,
                    runtimeVersion: runtimeVersion, feature: .officialDelete)
                guard (expectedCompatibility == nil || (expectedCompatibility?.environmentFingerprint == verified.environmentFingerprint
                        && expectedCompatibility?.supports(.permanentDelete, runtimeVersion: runtimeVersion) == true)),
                      verified.runtime.sha256 == launchSHA,
                      executableURL.resolvingSymlinksInPath() == launchPath else { throw error }
                try CodexUnlistedSessionInventory.verifyLocalAbsence(home: verified.codexHome, threadID: threadID)
                try await compatibilityInspector.requireCurrent(verified, request: compatibilityRequest)
                admission = verified
            }
            if runtimeVersion == "0.153.4",
               case let .rpcError(code, message) = error,
               code == -32600, message == "thread not loaded: \(threadID)" {
                try CodexUnlistedSessionInventory.verifyLocalAbsence(
                    home: URL(fileURLWithPath: serverInfo.codexHome), threadID: threadID
                )
            }
            if captureDeleteAbsence,
               let runtimeVersion,
               (CodexAppServerProvider.supportsVerifiedDeleteContract(runtimeVersion) || admission != nil),
               case let .rpcError(code, message) = error,
               code == -32600, message == "thread not loaded: \(threadID)" {
                throw CodexDeleteAbsenceEvidence(nativeSessionID: threadID,
                    runtimeVersion: runtimeVersion, observedAt: Date(), compatibilityAdmission: admission)
            }
            throw error
        }
        return CodexExactReadSnapshot(
            serverInfo: serverInfo,
            runtimeVersion: runtimeVersion,
            thread: response.thread,
            observedAt: Date()
        )
    }

    private func runInventory(executableURL: URL, lifecycleOnly: Bool = false) throws -> CodexInventorySnapshot {
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

        try verifyExpectedCodexHome(initializeResult.codexHome)
#if ASM_ISOLATED_DELETE_ACCEPTANCE
        try verifyIsolatedDeleteAcceptanceCodexHome(initializeResult.codexHome)
#endif

        try send(
            ["method": "initialized", "params": [:] as [String: Any]],
            to: input.fileHandleForWriting
        )

        if lifecycleOnly {
            // No cached collections or reused mutation process. Every item still gets
            // fresh, fully paginated official Active + Archive reads. Missing protection
            // metadata is explicitly unavailable, so this cannot authorize a new mutation.
            let active = try listAllThreads(
                archived: false, sourceKinds: Self.interactiveSourceKinds,
                process: process, input: input.fileHandleForWriting,
                reader: reader, requestID: &requestID
            )
            let archived = try listAllThreads(
                archived: true, sourceKinds: Self.interactiveSourceKinds,
                process: process, input: input.fileHandleForWriting,
                reader: reader, requestID: &requestID
            )
            let supplement = try collectUnlistedSessions(
                home: initializeResult.codexHome, runtimeVersion: runtimeVersion,
                active: active.records, archived: archived.records,
                process: process, input: input.fileHandleForWriting,
                reader: reader, requestID: &requestID
            )
            let overlap = !Set(active.records.map(\.id)).isDisjoint(with: archived.records.map(\.id))
            let omitted = "Not collected by lifecycle-only readback; full preflight required."
            return CodexInventorySnapshot(
                serverInfo: initializeResult, runtimeVersion: runtimeVersion,
                active: active.records + supplement.active, archived: archived.records + supplement.archived,
                descendantRecords: [], descendantNativeStates: [:],
                descendantGraphComplete: false, descendantGraphError: omitted,
                refreshedAt: Date(), isTruncated: active.isTruncated || archived.isTruncated || overlap,
                projects: [], projectCatalogAvailable: false, projectCatalogError: omitted,
                desktopPinnedThreadIDs: [], desktopPinStateAvailable: false, desktopPinStateError: omitted,
                trustFolders: [:], trustConfigurationAvailable: false, trustConfigurationError: omitted
            )
        }

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

        let supplement = try collectUnlistedSessions(
            home: initializeResult.codexHome, runtimeVersion: runtimeVersion,
            active: activeResult.records, archived: archivedResult.records,
            process: process, input: input.fileHandleForWriting,
            reader: reader, requestID: &requestID
        )
        let graphIDs = Set(descendantRecords.map(\.id))
        for record in supplement.active where !graphIDs.contains(record.id) {
            descendantRecords.append(record)
            descendantNativeStates[record.id] = .active
        }
        for record in supplement.archived where !graphIDs.contains(record.id) {
            descendantRecords.append(record)
            descendantNativeStates[record.id] = .archived
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
            active: activeResult.records + supplement.active,
            archived: archivedResult.records + supplement.archived,
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

    private func collectUnlistedSessions(
        home: String, runtimeVersion: String?,
        active: [CodexThreadRecord], archived: [CodexThreadRecord],
        process: Process, input: FileHandle, reader: JSONLineReader, requestID: inout Int
    ) throws -> CodexUnlistedSessionInventory.Result {
        try CodexUnlistedSessionInventory.collect(
            home: URL(fileURLWithPath: home), runtimeVersion: runtimeVersion,
            active: active, archived: archived
        ) { id in
            defer { requestID += 1 }
            let response: CodexThreadReadResponse = try request(
                process: process, input: input, reader: reader, id: requestID,
                method: "thread/read", params: ["threadId": id, "includeTurns": false]
            )
            return response.thread
        }
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
                // Inventory inspection must not invoke the default scan-and-repair path.
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

    private func verifyExpectedCodexHome(_ observedPath: String) throws {
        guard let expectedCodexHome else { return }
        guard observedPath.hasPrefix("/"), !observedPath.contains("\0"),
              expectedCodexHome.isFileURL,
              URL(fileURLWithPath: observedPath).standardizedFileURL.resolvingSymlinksInPath().path
                == expectedCodexHome.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw CodexAppServerError.launchFailed("App Server codexHome does not match the required Ghost Repair root.")
        }
    }

#if ASM_ISOLATED_DELETE_ACCEPTANCE
    private func verifyIsolatedDeleteAcceptanceCodexHome(
        _ observedPath: String
    ) throws {
        guard let expectedURL = configuration.isolatedDeleteAcceptanceCodexHomeURL else {
            return
        }
        let expected = expectedURL.standardizedFileURL.resolvingSymlinksInPath().path
        let observed = URL(fileURLWithPath: observedPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard observed == expected else {
            throw CodexAppServerError.launchFailed(
                "Isolated Delete acceptance rejected App Server codexHome mismatch."
            )
        }
    }
#endif

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

/// The exact provider mutation whose generated App Server contract must be
/// audited before Agent Session Manager may even create a Preview.
public enum CodexLifecycleMutationKind: String, CaseIterable, Sendable {
    case archive
    case moveToTrash
    case restore
    case permanentDelete

    public init?(operation: SessionOperation) {
        switch operation {
        case .archive:
            self = .archive
        case .moveToTrash:
            self = .moveToTrash
        case .restore:
            self = .restore
        case .emptyTrash:
            self = .permanentDelete
        case .moveToArchive:
            return nil
        }
    }

    public var operationLabel: String {
        switch self {
        case .archive:
            "Archive"
        case .moveToTrash:
            "Move to Trash"
        case .restore:
            "Restore"
        case .permanentDelete:
            "Permanent Delete"
        }
    }

    public func supports(runtimeVersion: String?, binding: CodexCompatibilityBinding? = nil) -> Bool {
        if binding?.supports(self, runtimeVersion: runtimeVersion) == true { return true }
        return switch self {
        case .archive, .moveToTrash, .restore:
            CodexAppServerProvider.supportsVerifiedLifecycleContract(runtimeVersion)
        case .permanentDelete:
            CodexAppServerProvider.supportsVerifiedDeleteContract(runtimeVersion)
        }
    }

    /// Returns a user-facing, operation-specific reason before any Preview is
    /// persisted or provider lifecycle request is sent.
    public func compatibilityBlockedReason(runtimeVersion: String?, binding: CodexCompatibilityBinding? = nil) -> String? {
        guard let runtimeVersion, !runtimeVersion.isEmpty else {
            return "\(operationLabel) is unavailable because the current Codex runtime version could not be verified. No \(operationLabel) request was sent. Refresh Codex Live and try again."
        }
        guard supports(runtimeVersion: runtimeVersion, binding: binding) else {
            let allowList = self == .permanentDelete
                ? "Permanent Delete allow-list"
                : "lifecycle allow-list"
            return "\(operationLabel) is unavailable because Codex runtime \(runtimeVersion) is outside this version of Agent Session Manager's audited \(allowList). Open Settings → Compatibility and run the isolated tests to verify this installation. No \(operationLabel) request was sent."
        }
        return nil
    }
}

public actor CodexAppServerProvider: SessionProvider, ExactSessionReadbackProviding, ArchiveScopeSnapshotProviding {
    public nonisolated let system: AgentSystem = .codex
    public nonisolated let capabilities: SessionCapabilities = .codexLiveReadOnly

    private let source: any CodexInventorySource
    private var latestDiagnostics: ProviderDiagnostics
    private var latestProjects: [SessionProject] = []
    private var latestSessionFilesHome: URL?
    private var latestCompatibilityBinding: CodexCompatibilityBinding?
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
            latestCompatibilityBinding = snapshot.compatibilityBinding
            latestSessionFilesHome = snapshot.serverInfo.codexHome.hasPrefix("/")
                ? URL(fileURLWithPath: snapshot.serverInfo.codexHome) : nil
            latestArchiveScope = Self.archiveScope(snapshot: snapshot)
            latestProjects = snapshot.projects.compactMap { project in
                guard let rootPath = project.rootPaths.first else { return nil }
                return SessionProject(id: project.id, name: project.name, rootPath: rootPath)
            }
            latestDiagnostics = Self.makeDiagnostics(snapshot: snapshot)
            return mapped
        } catch {
            latestSessionFilesHome = nil
            latestCompatibilityBinding = nil
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

    /// The home reported by the successful runtime inventory, not an assumed ~/.codex.
    public func sessionFilesHomeURL() -> URL? { latestSessionFilesHome }
    public func compatibilityBinding() -> CodexCompatibilityBinding? { latestCompatibilityBinding }

    public func compatibilityRequest() async throws -> CodexCompatibilityRequest {
        guard let client = source as? CodexAppServerClient else {
            throw SessionManagerError.unsupportedOperation("Compatibility inspection requires a local runtime.")
        }
        return try await .init(providerExecutable: client.compatibilityExecutableURL(), codexHome: latestSessionFilesHome)
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
            var protection = (try? ProtectionAuthorityPolicy.resolve(
                system: .codex,
                observations: protectionObservations(
                    record: record,
                    pinObservation: pinObservation(for: record, snapshot: snapshot),
                    observedRunning: observedRunning,
                    hasPinnedDescendant: hasPinnedDescendant,
                    allGraphPinStatesKnown: allGraphPinStatesKnown
                )
            )) ?? unavailableProtection
            if record.localSupplement?.hasCanonicalChildren == true {
                protection.hasPinnedDescendantKnown = false
            }
            var session = AgentSession(
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
                    && record.localSupplement?.hasCanonicalChildren != true
            )
            session.supplementalSourceLabel = record.localSupplement?.label
            return session
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
            var protection = (try? ProtectionAuthorityPolicy.resolve(
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
            if record.localSupplement?.hasCanonicalChildren == true {
                protection.hasPinnedDescendantKnown = false
            }
            return ArchiveScopeNode(
                managerKey: "\(AgentSystem.codex.rawValue):\(record.id)",
                nativeSessionID: record.id,
                parentNativeSessionID: record.parentThreadId,
                title: displayTitle(for: record),
                nativeState: nativeState,
                protection: protection,
                descendantCount: snapshot.descendantGraphComplete ? descendantIDs.count : 0,
                descendantCountKnown: snapshot.descendantGraphComplete
                    && record.localSupplement?.hasCanonicalChildren != true,
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
        let lifecycleContractKnown = CodexLifecycleMutationKind.archive.supports(runtimeVersion: runtimeVersion, binding: snapshot.compatibilityBinding)
        observedCapabilities.hasNativeArchiveInterface = lifecycleContractKnown
        observedCapabilities.hasNativeUnarchiveInterface = lifecycleContractKnown
        observedCapabilities.hasNativeDeleteInterface = CodexLifecycleMutationKind.permanentDelete.supports(runtimeVersion: runtimeVersion, binding: snapshot.compatibilityBinding)
        observedCapabilities.canReadPinnedState = pinStateAvailable
        observedCapabilities.canReadRunningState = !records.isEmpty
            && records.allSatisfy { $0.status.type == "active" }
        observedCapabilities.canReadDescendants = snapshot.descendantGraphComplete
        observedCapabilities.canReadFolderTrust = snapshot.trustConfigurationAvailable
        let deleteContractKnown = CodexLifecycleMutationKind.permanentDelete.supports(runtimeVersion: runtimeVersion, binding: snapshot.compatibilityBinding)
        var messages = [
            "Inventory uses thread/list with useStateDbOnly=true; JSONL scan-and-repair is disabled.",
            "Loaded \(snapshot.active.count) active and \(snapshot.archived.count) archived threads through official pagination and \(records.filter { $0.localSupplement != nil }.count) verified local supplements.",
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
                ? "The verified runtime contract for `\(runtimeVersion ?? "unavailable")` includes thread/archive and thread/unarchive. The inventory provider remains read-only; guarded lifecycle facades authorize execution separately."
                : "This runtime is outside the verified Archive/Restore contract; those native mutation interfaces are treated as unavailable.",
            deleteContractKnown
                ? "The verified runtime contract for `\(runtimeVersion ?? "unavailable")` includes the separately gated thread/delete interface."
                : "Permanent Delete is unavailable because this runtime is outside the separately audited Delete contract.",
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
    /// must be audited against its generated schema before Archive/Restore
    /// execution can rely on the same method and readback semantics.
    public static func supportsVerifiedLifecycleContract(_ runtimeVersion: String?) -> Bool {
        guard let runtimeVersion else { return false }
        return versionBelongsToAuditedSeries(runtimeVersion, release: "0.147.0")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.148.0")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.149.0")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.152.1")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.153.1")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.153.2")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.153.4")
    }

    public static func supportsVerifiedDeleteContract(_ runtimeVersion: String?) -> Bool {
        guard let runtimeVersion else { return false }
        if versionBelongsToAuditedSeries(runtimeVersion, release: "0.147.0") {
            return true
        }
        // Exact 0.153.4 passed the isolated production-coordinator acceptance
        // on 2026-09-07, including dual absence and manager finalization.
        // Adjacent/prerelease versions and external-deletion acknowledgement
        // retain their separate gates. See docs/VALIDATION.md.
        return runtimeVersion == "0.153.4"
    }

    /// Read-only external-deletion acknowledgement has its own compatibility
    /// boundary. It does not authorize `thread/delete`; it only recognizes the
    /// exact not-loaded discriminator when a complete inventory also omits the ID.
    public static func supportsVerifiedExternalDeletionReadbackContract(
        _ runtimeVersion: String?
    ) -> Bool {
        guard let runtimeVersion else { return false }
        return versionBelongsToAuditedSeries(runtimeVersion, release: "0.147.0")
            || versionBelongsToAuditedSeries(runtimeVersion, release: "0.148.0")
    }

    private static func versionBelongsToAuditedSeries(
        _ runtimeVersion: String,
        release: String
    ) -> Bool {
        runtimeVersion == release || runtimeVersion.hasPrefix("\(release)-")
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
