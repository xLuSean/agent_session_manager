@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class StateStoreLocationTests: XCTestCase {
    func testDatabasePathUsesStableBundleIdentifierDirectory() throws {
        let base = URL(fileURLWithPath: "/Users/example/Library/Application Support", isDirectory: true)

        let result = try StateStoreLocation.databaseURL(applicationSupportDirectory: base)

        XCTAssertEqual(
            result.path,
            "/Users/example/Library/Application Support/com.sean.AgentSessionManager/state.sqlite"
        )
    }

    func testDatabasePathRejectsEmptyOrPathLikeIdentifier() {
        let base = URL(fileURLWithPath: "/tmp/application-support", isDirectory: true)

        XCTAssertThrowsError(
            try StateStoreLocation.databaseURL(
                applicationSupportDirectory: base,
                bundleIdentifier: " "
            )
        )
        XCTAssertThrowsError(
            try StateStoreLocation.databaseURL(
                applicationSupportDirectory: base,
                bundleIdentifier: "../unsafe"
            )
        )
    }

    func testDiagnosticLogPathUsesSameStableApplicationSupportDirectory() throws {
        let base = URL(fileURLWithPath: "/Users/example/Library/Application Support", isDirectory: true)

        let result = try StateStoreLocation.diagnosticLogURL(applicationSupportDirectory: base)

        XCTAssertEqual(
            result.path,
            "/Users/example/Library/Application Support/com.sean.AgentSessionManager/diagnostic-events.jsonl"
        )
    }
}
