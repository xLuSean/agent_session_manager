import CSQLite3
import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexCompatibilityAdmissionTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var executable: URL!
    private var inspector: CodexCompatibilityInspector!
    private var request: CodexCompatibilityRequest { .init(providerExecutable: executable, codexHome: home) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("asm-admission-test-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("runtime")
        let script = #"""
        #!/usr/bin/perl
        use strict; use warnings; use JSON::PP;
        $| = 1;
        if ($ARGV[0] eq '--version') { print "codex-cli 0.999.0\n"; exit 0; }
        if ($ARGV[1] eq 'generate-json-schema') { mkdir $ARGV[3]; mkdir "$ARGV[3]/v2"; exit 0; }
        while (<STDIN>) {
            my $r = decode_json($_); my $method = $r->{method}; next if $method eq 'initialized';
            my $result = {};
            if ($method eq 'initialize') {
                my $home = '\#(home.path)';
                if (-f '\#(root.path)/wrong-home') { $home .= '/different'; }
                if (-f '\#(root.path)/replace-runtime') {
                    open(my $exe, '>>', '\#(executable.path)') or die; print $exe "\n# replacement\n"; close $exe;
                }
                $result = {userAgent=>'fixture',codexHome=>$home,platformFamily=>'unix',platformOs=>'macos'};
            } elsif ($method eq 'thread/read') {
                print encode_json({id=>$r->{id},error=>{code=>-32600,message=>'thread not loaded: '.$r->{params}->{threadId}}}), "\n";
                next;
            } elsif ($method =~ /^thread\/(archive|unarchive|delete)$/) {
                open(my $log, '>>', '\#(root.path)/mutations') or die; print $log "$method\n"; close $log;
            } else { die 'unexpected method'; }
            print encode_json({id=>$r->{id},result=>$result}), "\n";
        }
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        inspector = CodexCompatibilityInspector(reportURL: root.appendingPathComponent("cache.json"), desktopCandidates: [])
    }

    override func tearDownWithError() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["trash", root.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    // Synthetic observations test admission, not official runtime behavior.
    private func savedFixture(archive: CodexCompatibilityBehaviorStatus = .passed,
                              delete: CodexCompatibilityBehaviorStatus = .passed) async throws -> CodexCompatibilityReport {
        let inspected = try await inspector.inspect(request)
        var report = CodexCompatibilityReport(revision: inspected.revision, checkedAt: inspected.checkedAt,
            provider: inspected.provider, desktop: nil, environmentFingerprint: inspected.environmentFingerprint,
            desktopSchemaProfile: nil,
            results: CodexCompatibilityEvaluator.results(version: "0.999.0", browsing: true, archive: true,
                restore: true, delete: true, desktopVersion: nil, desktopSchemaProfile: nil, desktopMetadataAvailable: false), notes: [])
        report.behavior = .init(revision: 1, checkedAt: Date(), results: [
            .init(feature: .archiveRestore, status: archive, detail: "fixture"),
            .init(feature: .officialDelete, status: delete, detail: "fixture")])
        try await inspector.saveInspection(report)
        return report
    }

    private func client() -> CodexAppServerClient {
        .init(configuration: .init(executableURL: executable, timeout: 3), compatibilityInspector: inspector)
    }

    func testFrozenBindingReachesClientAndRejectsDifferentEnvironment() async throws {
        _ = try await savedFixture()
        let value = try await inspector.lifecycleBinding(request, runtimeVersion: "0.999.0")
        let binding = try XCTUnwrap(value)
        let source = client()
        let id = "00000000-0000-4000-8000-000000000001"
        let wrong = CodexCompatibilityBinding(revision: 1, runtimeVersion: "0.999.0",
            environmentFingerprint: "another-environment", features: binding.features)
        do {
            try await source.archive(threadID: id, expectedCompatibility: wrong)
            XCTFail("A different tested environment cannot replace the frozen selection's environment")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mutations").path))
        try await source.archive(threadID: id, expectedCompatibility: binding)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("mutations")), "thread/archive\n")
        _ = try await inspector.inspect(request)
        do {
            try await source.delete(threadID: id, expectedCompatibility: binding)
            XCTFail("Revoked acceptance must not authorize a frozen preview")
        } catch {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("mutations")), "thread/archive\n")
    }

    func testFrozenDeleteAbsenceCannotBeBorrowedFromAnotherEnvironment() async throws {
        let report = try await savedFixture()
        let admission = try await inspector.lifecycleAdmission(request, runtimeVersion: "0.999.0", feature: .officialDelete)
        let id = "00000000-0000-4000-8000-000000000001"
        let proof = CodexDeleteAbsenceEvidence(nativeSessionID: id, runtimeVersion: "0.999.0",
            observedAt: Date(), compatibilityAdmission: admission)
        let binding = CodexCompatibilityBinding(revision: 1, runtimeVersion: "0.999.0",
            environmentFingerprint: report.environmentFingerprint, features: [.officialDelete])
        guard case .absent = DeleteExactReadObservation.verifiedAbsence(proof, nativeSessionID: id,
            auditedRuntimeVersion: "0.999.0", expectedCompatibility: binding) else { return XCTFail("Matching proof rejected") }
        let wrong = CodexCompatibilityBinding(revision: 1, runtimeVersion: "0.999.0",
            environmentFingerprint: "changed", features: [.officialDelete])
        guard case .unavailable = DeleteExactReadObservation.verifiedAbsence(proof, nativeSessionID: id,
            auditedRuntimeVersion: "0.999.0", expectedCompatibility: wrong) else { return XCTFail("Foreign proof accepted") }
        XCTAssertTrue(report.hasVerifiedBehavior(for: .officialDelete))
        XCTAssertFalse(report.hasVerifiedBehavior(for: .desktopCleanup))
    }

    func testFreshEvidenceAdmitsOnlyTheIndependentlyPassedFeature() async throws {
        _ = try await savedFixture(archive: .failed)
        let permitted = try await inspector.lifecycleAdmission(request, runtimeVersion: "0.999.0", feature: .officialDelete)
        try await inspector.requireCurrent(permitted, request: request)
        do {
            _ = try await inspector.lifecycleAdmission(request, runtimeVersion: "0.999.0", feature: .archiveRestore)
            XCTFail("Failed archive test must not inherit Delete success")
        } catch {}
        do {
            _ = try await inspector.lifecycleAdmission(request, runtimeVersion: "0.999.0", feature: .desktopCleanup)
            XCTFail("CLI observations cannot permit private database cleanup")
        } catch {}
        let source = client()
        do { try await source.archive(threadID: "00000000-0000-4000-8000-000000000001"); XCTFail("Failed feature must not send") } catch {}
        try await source.delete(threadID: "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("mutations"), encoding: .utf8), "thread/delete\n")
    }

    func testReportCannotAdmitDifferentVersionFingerprintOrMissingHome() async throws {
        let report = try await savedFixture()
        XCTAssertNil(CodexCompatibilityAdmission.evaluate(report: report, request: request,
            currentFingerprint: "different", runtimeVersion: "0.999.0", feature: .officialDelete))
        XCTAssertNil(CodexCompatibilityAdmission.evaluate(report: report, request: request,
            currentFingerprint: report.environmentFingerprint, runtimeVersion: "0.999.1", feature: .officialDelete))
        XCTAssertNil(CodexCompatibilityAdmission.evaluate(report: report,
            request: .init(providerExecutable: executable, codexHome: nil),
            currentFingerprint: report.environmentFingerprint, runtimeVersion: "0.999.0", feature: .officialDelete))
    }

    func testDuplicateFailedOrObsoleteObservationsAreRejected() async throws {
        var report = try await savedFixture()
        let passed = report.behavior!.results[0]
        for behavior in [
            CodexCompatibilityBehaviorReport(revision: 1, checkedAt: Date(), results: []),
            .init(revision: 1, checkedAt: Date(), results: [passed, passed]),
            .init(revision: 99, checkedAt: Date(), results: [passed]),
            .init(revision: 1, checkedAt: Date().addingTimeInterval(600), results: [passed])
        ] {
            report.behavior = behavior
            XCTAssertNil(CodexCompatibilityAdmission.evaluate(report: report, request: request,
                currentFingerprint: report.environmentFingerprint, runtimeVersion: "0.999.0", feature: .archiveRestore))
        }
    }

    func testRevokedReportAndChangedExecutableInvalidateIssuedAdmission() async throws {
        _ = try await savedFixture()
        let admitted = try await inspector.lifecycleAdmission(request, runtimeVersion: "0.999.0", feature: .archiveRestore)
        _ = try await savedFixture(archive: .failed)
        do { try await inspector.requireCurrent(admitted, request: request); XCTFail("Revoked test must not pass") } catch {}
        _ = try await savedFixture()
        let current = try await inspector.lifecycleAdmission(request, runtimeVersion: "0.999.0", feature: .archiveRestore)
        let handle = try FileHandle(forWritingTo: executable)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("\n# changed\n".utf8)); try handle.close()
        do { try await inspector.requireCurrent(current, request: request); XCTFail("Same version with changed bytes must fail") } catch {}
    }

    func testExpiredInMemoryAdmissionCannotBeReused() async throws {
        let report = try await savedFixture()
        let old = Date().addingTimeInterval(-120)
        var historical = CodexCompatibilityReport(revision: report.revision, checkedAt: old,
            provider: report.provider, desktop: nil, environmentFingerprint: report.environmentFingerprint,
            desktopSchemaProfile: nil, results: report.results, notes: [])
        historical.behavior = .init(revision: 1, checkedAt: old, results: report.behavior!.results)
        let expired = try XCTUnwrap(CodexCompatibilityAdmission.evaluate(report: historical, request: request,
            currentFingerprint: report.environmentFingerprint, runtimeVersion: "0.999.0",
            feature: .archiveRestore, now: old))
        do { try await inspector.requireCurrent(expired, request: request); XCTFail("Expired permit must fail without a request") } catch {}
    }

    func testClientSendsOnlyAfterActualHomeMatchesTheSavedEnvironment() async throws {
        _ = try await savedFixture()
        let source = client()
        try await source.archive(threadID: "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("mutations"), encoding: .utf8), "thread/archive\n")
        try Data().write(to: root.appendingPathComponent("wrong-home"))
        do { try await source.archive(threadID: "00000000-0000-4000-8000-000000000001"); XCTFail("Changed home must fail") } catch {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("mutations"), encoding: .utf8), "thread/archive\n")
    }

    func testClientRejectsMissingAcceptanceAndReplacementDuringInitialization() async throws {
        let source = client()
        do { try await source.delete(threadID: "00000000-0000-4000-8000-000000000001"); XCTFail("No report must fail") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mutations").path))
        _ = try await savedFixture()
        try Data().write(to: root.appendingPathComponent("replace-runtime"))
        do { try await source.delete(threadID: "00000000-0000-4000-8000-000000000001"); XCTFail("Replaced runtime must fail") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mutations").path))
    }

    func testSchemaDriftInvalidatesButConversationChangesDoNot() async throws {
        try sql("CREATE TABLE threads (id TEXT PRIMARY KEY)")
        _ = try await savedFixture()
        let admitted = try await inspector.lifecycleAdmission(request, runtimeVersion: "0.999.0", feature: .archiveRestore)
        try sql("INSERT INTO threads VALUES ('fixture')")
        try await inspector.requireCurrent(admitted, request: request)
        try sql("ALTER TABLE threads ADD COLUMN new_format TEXT")
        do { try await inspector.requireCurrent(admitted, request: request); XCTFail("Schema changes must invalidate admission") } catch {}
    }

    func testDynamicDeleteAbsenceRequiresLocalAbsenceAndPreservesOrdinaryReadError() async throws {
        try sql("CREATE TABLE threads (id TEXT PRIMARY KEY)")
        _ = try await savedFixture()
        let source = client()
        let id = "00000000-0000-4000-8000-000000000001"
        do { _ = try await source.exactRead(threadID: id); XCTFail("Read fixture is absent") }
        catch let error as CodexAppServerError { XCTAssertEqual(error, .rpcError(-32600, "thread not loaded: \(id)")) }
        do { _ = try await source.exactReadForDeletion(threadID: id); XCTFail("Typed absence expected") }
        catch let evidence as CodexDeleteAbsenceEvidence {
            guard case .absent = DeleteExactReadObservation.verifiedAbsence(evidence, nativeSessionID: id, auditedRuntimeVersion: "0.999.0") else {
                return XCTFail("Current admitted runtime must produce usable exact absence")
            }
            guard case .unavailable = DeleteExactReadObservation.verifiedAbsence(evidence, nativeSessionID: id, auditedRuntimeVersion: "0.999.1") else {
                return XCTFail("Wrong runtime must not inherit absence")
            }
        }
        try sql("INSERT INTO threads VALUES ('\(id)')")
        do { _ = try await source.exactReadForDeletion(threadID: id); XCTFail("Leftover row must fail") }
        catch is CodexDeleteAbsenceEvidence { XCTFail("A leftover row is not verified absence") }
        catch {}
        try sql("DELETE FROM threads WHERE id='\(id)'")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        try Data("fixture".utf8).write(to: sessions.appendingPathComponent("rollout-\(id).jsonl"))
        do { _ = try await source.exactReadForDeletion(threadID: id); XCTFail("Leftover rollout must fail") }
        catch is CodexDeleteAbsenceEvidence { XCTFail("A leftover file is not verified absence") }
        catch {}
    }

    private func sql(_ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else {
            throw CodexAppServerError.exactReadUnavailable
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw CodexAppServerError.exactReadUnavailable
        }
    }
}
