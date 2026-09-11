import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexCompatibilityInstallationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("asm-installation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.trashItem(at: root, resultingItemURL: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRepeatedProductionHashingHasBoundedMemoryAndIdenticalDigest() throws {
        let file = root.appendingPathComponent("synthetic-binary")
        let expected = try autoreleasepool { () throws -> String in
            let data = Data(repeating: 0x5a, count: 8 * 1_048_576)
            try data.write(to: file)
            return CodexCompatibilityInspector.hash(data)
        }
        // No outer pool is drained between iterations, just as in a long task.
        try autoreleasepool {
            let baseline = try residentBytes()
            for _ in 0..<24 {
                XCTAssertEqual(try CodexCompatibilityInspector.executableSHA256(file), expected)
            }
            let growth = max(try residentBytes(), baseline) - baseline
            XCTAssertLessThan(growth, 48 * 1_048_576,
                "Hashing must release chunks; the original implementation retains about 192 MiB here")
        }
    }

    func testSameSizeReplacementAndRetargetedSymlinkInvalidateMetadata() throws {
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        let link = root.appendingPathComponent("cli")
        try Data("aaaa".utf8).write(to: a)
        try Data("bbbb".utf8).write(to: b)
        let original = try CodexCompatibilityInstallation.FileStamp.read(a)
        try Data("cccc".utf8).write(to: a, options: .atomic)
        XCTAssertNotEqual(try CodexCompatibilityInstallation.FileStamp.read(a), original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let linked = try CodexCompatibilityInstallation.FileStamp.read(link)
        try FileManager.default.trashItem(at: link, resultingItemURL: nil)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
        XCTAssertNotEqual(try CodexCompatibilityInstallation.FileStamp.read(link), linked)
    }

    func testOldReportNeedsOneExplicitSettingsCheckAndNeverGetsSilentlyUpgraded() async throws {
        let executable = root.appendingPathComponent("runtime")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.153.4\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let cache = root.appendingPathComponent("cache.json")
        let inspector = CodexCompatibilityInspector(reportURL: cache, desktopCandidates: [])
        let request = CodexCompatibilityRequest(providerExecutable: executable, codexHome: root)
        let old = CodexCompatibilityReport(revision: CodexCompatibilityReport.policyRevision, checkedAt: Date(),
            provider: .init(path: executable.path, version: "0.153.4", sha256: String(repeating: "a", count: 64)),
            desktop: nil, environmentFingerprint: "old", desktopSchemaProfile: nil, results: [], notes: [])
        try await inspector.saveInspection(old)
        let before = try Data(contentsOf: cache)
        let review = try await inspector.reviewSavedCompatibility(request)
        XCTAssertFalse(review.isCurrent)
        XCTAssertEqual(before, try Data(contentsOf: cache))
    }

    private func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        return info.resident_size
    }
}
