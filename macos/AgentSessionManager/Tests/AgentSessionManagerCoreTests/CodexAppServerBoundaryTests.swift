import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexAppServerBoundaryTests: XCTestCase {
    private let threadID = "01900000-0000-7000-8000-000000000001"

    func testExpectedHomeRejectsEveryReadAndLifecycleEntryBeforeRequests() async throws {
        let fixture = try BoundaryFixture(runtime: "0.147.0")
        defer { fixture.cleanUp() }
        let client = CodexAppServerClient(configuration: fixture.configuration, expectedCodexHome: fixture.root)
        for observed in ["", "relative-home", fixture.root.path + "-other", fixture.root.path + "\0"] {
            try fixture.setHome(observed)
            for operation in 0..<8 {
                try fixture.clearRequests()
                do {
                    switch operation {
                    case 0: _ = try await client.inventory()
                    case 1: _ = try await client.lifecycleReadback()
                    case 2: _ = try await client.exactRead(threadID: threadID)
                    case 3: _ = try await client.exactReadForExternalDeletion(threadID: threadID)
                    case 4: _ = try await client.exactReadForDeletion(threadID: threadID)
                    case 5: try await client.archive(threadID: threadID)
                    case 6: try await client.unarchive(threadID: threadID)
                    default: try await client.delete(threadID: threadID)
                    }
                    XCTFail("Mismatched home admitted operation \(operation)")
                } catch let CodexAppServerError.launchFailed(message) {
                    XCTAssertTrue(message.contains("codexHome"))
                } catch { XCTFail("Unexpected failure for operation \(operation): \(error)") }
                XCTAssertEqual(try fixture.methods(), ["initialize"])
            }
        }
    }

    func testNormalizedHomeAndDefaultCustomHomeRemainSupported() async throws {
        let fixture = try BoundaryFixture(runtime: "0.148.0")
        defer { fixture.cleanUp() }
        try fixture.setHome(fixture.root.path + "/./")
        try fixture.setPresent(threadID: threadID)
        let bound = CodexAppServerClient(configuration: fixture.configuration, expectedCodexHome: fixture.root)
        let exact = try await bound.exactRead(threadID: threadID)
        XCTAssertEqual(exact.thread.id, threadID)
        let inventory = try await bound.inventory()
        XCTAssertEqual(inventory.runtimeVersion, "0.148.0")
        let lean = try await bound.lifecycleReadback()
        XCTAssertEqual(lean.runtimeVersion, "0.148.0")

        // The normal public initializer must not force the operator's ~/.codex.
        let ordinary = CodexAppServerClient(configuration: fixture.configuration)
        let custom = try await ordinary.exactRead(threadID: threadID)
        XCTAssertEqual(custom.serverInfo.codexHome, fixture.root.path + "/./")
    }

    func testGhostProductionClientAndReadOnlyWrapperRejectCustomHome() async throws {
        let fixture = try BoundaryFixture(runtime: "0.148.0")
        defer { fixture.cleanUp() }
        let source = CodexGhostRepairExperimentalReadOnlyAppServerSource(configuration: fixture.configuration)
        do {
            _ = try await source.inventory()
            XCTFail("Ghost wrapper accepted a different home")
        } catch let CodexAppServerError.launchFailed(message) {
            XCTAssertTrue(message.contains("codexHome"))
        }
        XCTAssertEqual(try fixture.methods(), ["initialize"])
        try fixture.clearRequests()
        let client = CodexAppServerClient.ghostRepairProduction(configuration: fixture.configuration)
        do {
            _ = try await client.exactRead(threadID: threadID)
            XCTFail("Ghost exact read accepted a different home")
        } catch let CodexAppServerError.launchFailed(message) {
            XCTAssertTrue(message.contains("codexHome"))
        }
        XCTAssertEqual(try fixture.methods(), ["initialize"])
    }

    func testExternalAbsenceUsesActualRuntimeAndIndependentContract() async throws {
        let fixture = try BoundaryFixture(runtime: "0.148.0")
        defer { fixture.cleanUp() }
        try fixture.setAbsent(threadID: threadID)
        let client = CodexAppServerClient(configuration: fixture.configuration, expectedCodexHome: fixture.root)
        let readback = CodexExternalDeletionReadback(source: client)
        for version in ["0.147.0", "0.148.0", "0.149.0", "0.153.4"] {
            try fixture.setRuntime(version)
            let result = await readback.exactReadObservation(nativeSessionID: threadID, auditedRuntimeVersion: version)
            if ["0.147.0", "0.148.0"].contains(version) {
                guard case let .absent(id, observedAt, actualVersion, code, message) = result else {
                    XCTFail("Read-only contract rejected \(version): \(result)"); continue
                }
                XCTAssertEqual(id, threadID)
                XCTAssertEqual(actualVersion, version)
                XCTAssertLessThan(abs(observedAt.timeIntervalSinceNow), 10)
                XCTAssertEqual(code, -32600)
                XCTAssertEqual(message, "thread not loaded: \(threadID)")
            } else {
                guard case .unavailable = result else { XCTFail("Unaudited external runtime admitted: \(result)"); continue }
            }
        }
        // A fresh subprocess can differ from the previously inventoried runtime.
        try fixture.setRuntime("0.148.0")
        let inventory = try await readback.inventorySnapshot()
        XCTAssertEqual(inventory.runtimeVersion, "0.148.0")
        for actualVersion in ["0.147.0", "0.149.0"] {
            try fixture.setRuntime(actualVersion)
            let result = await readback.exactReadObservation(nativeSessionID: threadID, auditedRuntimeVersion: "0.148.0")
            guard case .unavailable = result else { XCTFail("Caller runtime relabeled actual \(actualVersion)"); continue }
        }
        XCTAssertFalse(try fixture.methods().contains("thread/delete"))
    }

    func testExternalTypedEvidenceCannotBeMistakenForDeleteOrRawErrors() async throws {
        let fixture = try BoundaryFixture(runtime: "0.148.0")
        defer { fixture.cleanUp() }
        try fixture.setAbsent(threadID: threadID)
        let client = CodexAppServerClient(configuration: fixture.configuration)
        do {
            _ = try await client.exactReadForExternalDeletion(threadID: threadID)
            XCTFail("Expected typed absence")
        } catch {
            XCTAssertTrue(error is CodexExternalDeletionAbsenceEvidence)
            XCTAssertFalse(error is CodexDeleteAbsenceEvidence)
        }
        XCTAssertFalse(CodexAppServerProvider.supportsVerifiedDeleteContract("0.148.0"))
        let rawSource = BoundaryErrorSource(error: CodexAppServerError.rpcError(-32600, "thread not loaded: \(threadID)"))
        let rawReadback = CodexExternalDeletionReadback(source: rawSource)
        let raw = await rawReadback.exactReadObservation(nativeSessionID: threadID, auditedRuntimeVersion: "0.148.0")
        guard case .unavailable = raw else { return XCTFail("Raw alternate-source error became absence") }
        let wrongID = BoundaryErrorSource(error: CodexExternalDeletionAbsenceEvidence(nativeSessionID: "other", runtimeVersion: "0.148.0", observedAt: Date()))
        let wrong = await CodexExternalDeletionReadback(source: wrongID).exactReadObservation(nativeSessionID: threadID, auditedRuntimeVersion: "0.148.0")
        guard case .unavailable = wrong else { return XCTFail("Wrong exact ID became absence") }
    }

    func testExternalReadRejectsNearMatchErrorsAndPreservesPresent() async throws {
        let fixture = try BoundaryFixture(runtime: "0.148.0")
        defer { fixture.cleanUp() }
        let client = CodexAppServerClient(configuration: fixture.configuration)
        let readback = CodexExternalDeletionReadback(source: client)
        for (code, message) in [(-32600, "thread not loaded: other"), (-32600, "thread not loaded: \(threadID) "), (-32602, "thread not loaded: \(threadID)")] {
            try fixture.setError(code: code, message: message)
            let result = await readback.exactReadObservation(nativeSessionID: threadID, auditedRuntimeVersion: "0.148.0")
            guard case .unavailable = result else { XCTFail("Near-match RPC became absence"); continue }
        }
        try fixture.setPresent(threadID: threadID)
        let result = await readback.exactReadObservation(nativeSessionID: threadID, auditedRuntimeVersion: "0.148.0")
        guard case let .present(id, _, version) = result else { return XCTFail("Exact present result lost") }
        XCTAssertEqual(id, threadID)
        XCTAssertEqual(version, "0.148.0")
    }
}

private struct BoundaryErrorSource: CodexInventorySource {
    let error: Error
    func inventory() async throws -> CodexInventorySnapshot { throw CodexAppServerError.exactReadUnavailable }
    func exactRead(threadID: String) async throws -> CodexExactReadSnapshot { throw error }
}

private struct BoundaryFixture {
    let root: URL
    let executable: URL
    var configuration: CodexAppServerConfiguration { .init(executableURL: executable, timeout: 2) }

    init(runtime: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("asm-app-server-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        executable = root.appendingPathComponent("server.sh")
        let resource = try XCTUnwrap(Bundle.module.url(forResource: "fake-app-server-home-binding", withExtension: "sh"))
        try FileManager.default.copyItem(at: resource, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try setRuntime(runtime)
        try setHome(root.path)
        try writeJSON(["pinned-thread-ids": []], name: ".codex-global-state.json")
        try clearRequests()
    }

    func setRuntime(_ version: String) throws { try Data(version.utf8).write(to: root.appendingPathComponent("runtime.txt")) }
    func setHome(_ path: String) throws {
        try writeJSON(["id": 1, "result": ["userAgent": "fixture", "codexHome": path, "platformFamily": "unix", "platformOs": "macos"]], name: "initialize.json")
    }
    func setAbsent(threadID: String) throws { try setError(code: -32600, message: "thread not loaded: \(threadID)") }
    func setError(code: Int, message: String) throws { try writeJSON(["id": 2, "error": ["code": code, "message": message]], name: "exact.json") }
    func setPresent(threadID: String) throws {
        try writeJSON(["id": 2, "result": ["thread": ["id": threadID, "sessionId": threadID, "preview": "Synthetic", "ephemeral": false, "modelProvider": "openai", "createdAt": 0, "updatedAt": 1, "status": ["type": "idle"], "cwd": root.path, "cliVersion": "historical-version"]]], name: "exact.json")
    }
    func clearRequests() throws { try Data().write(to: root.appendingPathComponent("requests.jsonl")) }
    func methods() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map {
            let object = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            return try XCTUnwrap(object?["method"] as? String)
        }
    }
    func writeJSON(_ object: [String: Any], name: String) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent(name))
    }
    func cleanUp() {
        // Keep newly created fixtures recoverable under the user's deletion policy.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["trash", root.path]
        do {
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "Could not move the exact fixture root to Trash")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Fixture root remains after Trash cleanup")
        } catch {
            XCTFail("Could not move the fixture root to Trash: \(error)")
        }
    }
}
