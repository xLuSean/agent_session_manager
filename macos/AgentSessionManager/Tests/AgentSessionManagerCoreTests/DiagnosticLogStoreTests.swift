@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class DiagnosticLogStoreTests: XCTestCase {
    private struct ExpectedBootstrapFailure: LocalizedError {
        var errorDescription: String? { "simulated disk failure" }
    }

    func testBootstrapUsesPersistentStoreWhenInitializationSucceeds() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-diagnostic-bootstrap-\(UUID().uuidString).jsonl")
        let result = DiagnosticLogBootstrap.make(fileURL: fileURL)

        XCTAssertEqual(result.persistenceStatus, .persistent(fileURL: fileURL))
        XCTAssertEqual(result.store.fileURL, fileURL)
        XCTAssertNil(result.persistenceStatus.warningMessage)
    }

    func testBootstrapFailureUsesMemoryAndReturnsPersistentWarning() async throws {
        let fileURL = URL(fileURLWithPath: "/unavailable/diagnostic-events.jsonl")
        let result = DiagnosticLogBootstrap.make(fileURL: fileURL) { _ in
            throw ExpectedBootstrapFailure()
        }

        XCTAssertNil(result.store.fileURL)
        guard case let .inMemoryFallback(intendedFileURL, failureDescription) = result.persistenceStatus else {
            return XCTFail("Expected an in-memory fallback status")
        }
        XCTAssertEqual(intendedFileURL, fileURL)
        XCTAssertEqual(failureDescription, "simulated disk failure")
        XCTAssertTrue(result.persistenceStatus.warningMessage?.contains("lost when the app quits") == true)
        XCTAssertTrue(result.persistenceStatus.warningMessage?.contains("Existing on-disk logs were not changed") == true)

        let snapshot = try await result.store.record(
            level: .warning,
            category: .storage,
            message: "in-memory fallback remains operational"
        )
        XCTAssertEqual(snapshot.events.map(\.message), ["in-memory fallback remains operational"])
    }

    func testBootstrapLocationFailureUsesMemoryAndWarnsWithoutClaimingAPath() {
        let result = DiagnosticLogBootstrap.make(fileURLProvider: {
            throw ExpectedBootstrapFailure()
        })

        XCTAssertNil(result.store.fileURL)
        guard case let .inMemoryFallback(intendedFileURL, failureDescription) = result.persistenceStatus else {
            return XCTFail("Expected an in-memory fallback status")
        }
        XCTAssertNil(intendedFileURL)
        XCTAssertEqual(failureDescription, "simulated disk failure")
        XCTAssertTrue(result.persistenceStatus.warningMessage?.contains("Application Support location") == true)
    }

    func testCountRetentionKeepsNewestEvents() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = try DiagnosticLogStore(
            retentionPolicy: DiagnosticLogRetentionPolicy(
                maximumEvents: 2,
                maximumAge: 100,
                maximumBytes: 10_000
            ),
            now: { now }
        )

        try await store.record(
            level: .info,
            category: .app,
            message: "oldest",
            timestamp: now.addingTimeInterval(-3)
        )
        try await store.record(
            level: .warning,
            category: .inventory,
            message: "middle",
            timestamp: now.addingTimeInterval(-2)
        )
        let snapshot = try await store.record(
            level: .error,
            category: .lifecycle,
            message: "newest",
            timestamp: now.addingTimeInterval(-1)
        )

        XCTAssertEqual(snapshot.events.map(\.message), ["newest", "middle"])
    }

    func testAgeRetentionDropsExpiredEvents() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let store = try DiagnosticLogStore(
            retentionPolicy: DiagnosticLogRetentionPolicy(
                maximumEvents: 10,
                maximumAge: 10,
                maximumBytes: 10_000
            ),
            now: { now }
        )

        try await store.record(
            level: .info,
            category: .inventory,
            message: "expired",
            timestamp: now.addingTimeInterval(-11)
        )
        let snapshot = try await store.record(
            level: .info,
            category: .inventory,
            message: "retained",
            timestamp: now.addingTimeInterval(-9)
        )

        XCTAssertEqual(snapshot.events.map(\.message), ["retained"])
    }

    func testByteRetentionNeverExceedsLimitAndKeepsNewest() async throws {
        let now = Date(timeIntervalSince1970: 3_000)
        let policy = DiagnosticLogRetentionPolicy(
            maximumEvents: 10,
            maximumAge: 100,
            maximumBytes: 2_000
        )
        let store = try DiagnosticLogStore(retentionPolicy: policy, now: { now })

        try await store.record(
            level: .info,
            category: .storage,
            message: "first-" + String(repeating: "a", count: 1_100),
            timestamp: now.addingTimeInterval(-2)
        )
        let snapshot = try await store.record(
            level: .info,
            category: .storage,
            message: "second-" + String(repeating: "b", count: 1_100),
            timestamp: now.addingTimeInterval(-1)
        )

        XCTAssertLessThanOrEqual(snapshot.fileByteCount, policy.maximumBytes)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertTrue(snapshot.events[0].message.hasPrefix("second-"))
    }

    func testPersistentJSONLReloadDropsCorruptLinesAndUsesPrivatePermissions() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-diagnostic-log-\(UUID().uuidString)")
            .appendingPathComponent("diagnostic-events.jsonl")
        let now = Date(timeIntervalSince1970: 4_000)
        let store = try DiagnosticLogStore(fileURL: fileURL, now: { now })
        try await store.record(
            level: .warning,
            category: .recovery,
            message: "readback-only recovery started"
        )

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()

        let reloaded = try DiagnosticLogStore(fileURL: fileURL, now: { now })
        let snapshot = try await reloaded.snapshot()
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

        XCTAssertEqual(snapshot.events.map(\.message), ["readback-only recovery started"])
        XCTAssertEqual(snapshot.discardedCorruptLineCount, 1)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains("not-json"))
    }

    func testMetadataDropsSensitiveKeysAndBoundsValues() async throws {
        let store = try DiagnosticLogStore()
        let snapshot = try await store.record(
            level: .info,
            category: .lifecycle,
            message: "Preview created",
            metadata: [
                "preview_id": "preview-1",
                "confirmation_token": "must-not-be-stored",
                "request_payload": "must-not-be-stored",
                "detail": String(repeating: "x", count: 2_000),
            ]
        )

        let metadata = try XCTUnwrap(snapshot.events.first?.metadata)
        XCTAssertEqual(metadata["preview_id"], "preview-1")
        XCTAssertNil(metadata["confirmation_token"])
        XCTAssertNil(metadata["request_payload"])
        XCTAssertEqual(metadata["detail"]?.count, 1_024)
    }

    func testRejectsInvalidRetentionAndEmptyMessages() async throws {
        XCTAssertThrowsError(
            try DiagnosticLogStore(
                retentionPolicy: DiagnosticLogRetentionPolicy(
                    maximumEvents: 0,
                    maximumAge: 1,
                    maximumBytes: 1
                )
            )
        )
        let store = try DiagnosticLogStore()
        do {
            try await store.record(level: .info, category: .app, message: "   ")
            XCTFail("Expected an empty-message error")
        } catch {
            XCTAssertEqual(error as? DiagnosticLogStoreError, .emptyMessage)
        }
    }
}
