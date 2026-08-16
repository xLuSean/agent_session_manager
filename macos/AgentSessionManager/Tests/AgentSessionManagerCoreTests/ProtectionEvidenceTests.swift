@testable import AgentSessionManagerCore
import XCTest

final class ProtectionEvidenceTests: XCTestCase {
    func testUnknownFalseNeverBecomesVerifiedClear() throws {
        let protection = SessionProtection(
            isPinned: false,
            isRunning: false,
            isCurrent: false,
            hasPinnedDescendant: false,
            isPinnedKnown: false,
            isRunningKnown: false,
            isCurrentKnown: false,
            hasPinnedDescendantKnown: false
        )

        let evidence = ProtectionEvidenceBuilder.evidence(for: protection, system: .codex)

        XCTAssertEqual(evidence.count, ProtectionEvidenceKind.allCases.count)
        XCTAssertTrue(evidence.allSatisfy { $0.verdict == .unavailable })
        XCTAssertTrue(evidence.allSatisfy(\.verdict.blocksLifecycleMutation))
    }

    func testCodexUsesSeparateSourcesForPinRunningAndDescendantEvidence() throws {
        let protection = SessionProtection(
            isPinned: false,
            isRunning: true,
            isCurrent: false,
            hasPinnedDescendant: true,
            isPinnedKnown: true,
            isRunningKnown: true,
            isCurrentKnown: false,
            hasPinnedDescendantKnown: true
        )

        let evidence = Dictionary(
            uniqueKeysWithValues: ProtectionEvidenceBuilder
                .evidence(for: protection, system: .codex)
                .map { ($0.kind, $0) }
        )

        XCTAssertEqual(evidence[.pinned]?.verdict, .clear)
        XCTAssertEqual(evidence[.pinned]?.source, .codexDesktopPinnedThreadIDs)
        XCTAssertEqual(evidence[.running]?.verdict, .protected)
        XCTAssertEqual(evidence[.running]?.source, .codexThreadListStatus)
        XCTAssertEqual(evidence[.current]?.verdict, .unavailable)
        XCTAssertEqual(evidence[.current]?.source, .unavailable)
        XCTAssertEqual(evidence[.pinnedDescendant]?.verdict, .protected)
        XCTAssertEqual(evidence[.pinnedDescendant]?.source, .codexCompleteDescendantGraph)
    }

    func testCodexRunningStatusIsPositiveOnlyAndCannotVerifyClear() throws {
        let protection = SessionProtection(
            isRunning: false,
            isRunningKnown: true,
            isCurrentKnown: false
        )

        let running = try XCTUnwrap(
            ProtectionEvidenceBuilder
                .evidence(for: protection, system: .codex)
                .first { $0.kind == .running }
        )

        XCTAssertEqual(running.verdict, .unavailable)
        XCTAssertEqual(running.source, .unavailable)
        XCTAssertTrue(running.verdict.blocksLifecycleMutation)
    }

    func testFixtureKnownFalseValuesAreVerifiedClear() {
        let evidence = ProtectionEvidenceBuilder.evidence(
            for: SessionProtection(),
            system: .claudeCode
        )

        XCTAssertTrue(evidence.allSatisfy { $0.verdict == .clear })
        XCTAssertTrue(evidence.allSatisfy { $0.source == .fixtureProvider })
        XCTAssertTrue(evidence.allSatisfy { !$0.verdict.blocksLifecycleMutation })
    }
}
