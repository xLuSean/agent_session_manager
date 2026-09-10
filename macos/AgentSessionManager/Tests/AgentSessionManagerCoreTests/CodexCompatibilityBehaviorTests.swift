import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class CodexCompatibilityBehaviorTests: XCTestCase {
    func testInstalledRuntimeOnlyWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ASM_COMPATIBILITY_ACCEPTANCE"] == "1",
              let path = ProcessInfo.processInfo.environment["ASM_COMPATIBILITY_ACCEPTANCE_EXECUTABLE"] else {
            throw XCTSkip("Explicit opt-in is required; only new isolated test conversations are used.")
        }
        let inspector = CodexCompatibilityInspector(reportURL: root.appendingPathComponent("installed-report.json"), desktopCandidates: [])
        let request = CodexCompatibilityRequest(providerExecutable: URL(fileURLWithPath: path), codexHome: nil)
        let inspection = try await inspector.inspect(request)
        print("ASM_COMPATIBILITY_RUNTIME=\(inspection.provider.version)")
        let result = try await inspector.verifyBehavior(request, confirmedFingerprint: inspection.environmentFingerprint) { print($0) }
        for item in result.behavior?.results ?? [] {
            print("ASM_COMPATIBILITY_RESULT=\(item.feature.rawValue):\(item.status.rawValue):\(item.detail)")
        }
        XCTAssertEqual(result.behavior?.results.map(\.status), [.passed, .passed])
    }

    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("asm-behavior-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["trash", root.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRealSandboxedProcessVerifiesLifecycleAndDeniesPrivateAccess() throws {
        let privateFile = root.appendingPathComponent("private.txt")
        try Data("private fixture".utf8).write(to: privateFile)
        let executable = try fixture(mode: "success", privateFile: privateFile)
        for feature in [CodexCompatibilityFeature.archiveRestore, .officialDelete] {
            let result = try run(executable, feature: feature)
            XCTAssertEqual(result.status, .passed, result.detail)
            XCTAssertFalse(result.detail.contains(root.path))
        }
        XCTAssertEqual(try String(contentsOf: privateFile, encoding: .utf8), "private fixture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside-write").path))
        XCTAssertFalse(CodexAppServerProvider.supportsVerifiedDeleteContract("0.999.0"))
    }

    func testWrongHomeIdentityIncompleteListAndBusyFailClosed() throws {
        for mode in ["wrong-home", "wrong-id", "page", "busy", "approval", "eof", "no-persistence"] {
            let result = try run(fixture(mode: mode), feature: .archiveRestore)
            XCTAssertEqual(result.status, .failed, mode)
        }
    }

    func testRolloutMustBeInsideSessionsAndNotASymlink() throws {
        // The successful fixture also exercises existing /private/tmp -> /tmp
        // normalization. It must not turn sibling paths or symlinks into valid evidence.
        for mode in ["sibling-rollout", "symlink-rollout"] {
            let result = try run(fixture(mode: mode), feature: .officialDelete)
            XCTAssertEqual(result.status, .failed, mode)
            XCTAssertTrue(result.detail.contains("file and database persistence"), result.detail)
        }
    }

    func testDeleteCannotPassOnAcknowledgementOrGenericErrorOrLeftoverData() throws {
        for mode in ["delete-noop", "wrong-error", "leftover-file", "leftover-row"] {
            let result = try run(fixture(mode: mode), feature: .officialDelete)
            XCTAssertEqual(result.status, .failed, mode)
            XCTAssertTrue(result.detail.contains("delete and absence"), result.detail)
        }
    }

    func testRestoreFailureDoesNotPreventIndependentDeleteTest() throws {
        let executable = try fixture(mode: "restore-fails")
        XCTAssertEqual(try run(executable, feature: .archiveRestore).status, .failed)
        XCTAssertEqual(try run(executable, feature: .officialDelete).status, .passed)
    }

    func testCopiedExecutableMustMatchConfirmedDigest() throws {
        let executable = try fixture(mode: "success")
        let result = try CodexCompatibilityBehaviorRunner.run(executable: executable, expectedSHA256: "wrong", feature: .officialDelete)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.detail.contains("startup"))
    }

    func testBehaviorRequiresCurrentConfirmedInspectionAndPersistsWithoutRerun() async throws {
        let executable = try fixture(mode: "success")
        let url = root.appendingPathComponent("report.json")
        let inspector = CodexCompatibilityInspector(reportURL: url, desktopCandidates: [])
        let request = CodexCompatibilityRequest(providerExecutable: executable, codexHome: nil)
        let baseline = try await inspector.inspect(request)
        do {
            _ = try await inspector.verifyBehavior(request, confirmedFingerprint: "stale") { _ in }
            XCTFail("Stale confirmation must not start tests")
        } catch {}
        // Supply known matching schema results to isolate runner/cache behavior;
        // schema acceptance itself is covered by CodexCompatibilityTests.
        let report = CodexCompatibilityReport(revision: baseline.revision, checkedAt: baseline.checkedAt,
            provider: baseline.provider, desktop: nil, environmentFingerprint: baseline.environmentFingerprint,
            desktopSchemaProfile: nil, results: CodexCompatibilityEvaluator.results(version: "0.999.0",
                browsing: true, archive: true, restore: true, delete: true, desktopVersion: nil,
                desktopSchemaProfile: nil, desktopMetadataAvailable: false), notes: [])
        try await inspector.saveInspection(report)
        let checked = try await inspector.verifyBehavior(request, confirmedFingerprint: report.environmentFingerprint) { _ in }
        XCTAssertEqual(checked.behavior?.results.map(\.feature), [.archiveRestore, .officialDelete, .desktopCleanup])
        XCTAssertEqual(checked.behavior?.results.map(\.status), [.passed, .passed, .notTested])
        XCTAssertEqual(checked.results[1].status, .needsBehaviorVerification, "Interface status remains separate from behavior evidence")
        let restarted = CodexCompatibilityInspector(reportURL: url, desktopCandidates: [])
        let review = try await restarted.reviewSavedCompatibility(request)
        XCTAssertTrue(review.isCurrent)
        XCTAssertEqual(review.report?.behavior, checked.behavior)
        let inspectedAgain = try await restarted.inspect(request)
        XCTAssertEqual(inspectedAgain.behavior, checked.behavior)
        try Data("\n# changed".utf8).append(to: executable)
        do {
            _ = try await inspector.verifyBehavior(request, confirmedFingerprint: report.environmentFingerprint) { _ in }
            XCTFail("Changed runtime must not reuse confirmation")
        } catch {}
    }

    func testMissingInterfacesAreNotTestedAndObsoleteBehaviorIsDiscarded() async throws {
        let executable = try fixture(mode: "success")
        let inspector = CodexCompatibilityInspector(reportURL: root.appendingPathComponent("report.json"), desktopCandidates: [])
        let request = CodexCompatibilityRequest(providerExecutable: executable, codexHome: nil)
        var report = try await inspector.inspect(request)
        let result = try await inspector.verifyBehavior(request, confirmedFingerprint: report.environmentFingerprint) { _ in }
        XCTAssertEqual(result.behavior?.results.map(\.status), [.notTested, .notTested, .notTested])
        report.behavior = .init(revision: 999, checkedAt: Date(), results: [])
        try await inspector.saveInspection(report)
        let reloaded = try await inspector.savedReport()
        XCTAssertNil(reloaded?.behavior)
    }

    private func run(_ executable: URL, feature: CodexCompatibilityFeature) throws -> CodexCompatibilityBehaviorResult {
        try CodexCompatibilityBehaviorRunner.run(executable: executable,
            expectedSHA256: CodexCompatibilityInspector.hash(Data(contentsOf: executable)), feature: feature)
    }

    private func fixture(mode: String, privateFile: URL? = nil) throws -> URL {
        let executable = root.appendingPathComponent("runtime-\(UUID().uuidString)")
        let script = #"""
        #!/usr/bin/perl
        use strict; use warnings; use JSON::PP; use IO::Socket::INET;
        $| = 1;
        my $mode = '\#(mode)';
        my $home = $ENV{CODEX_HOME};
        my $private = '\#(privateFile?.path ?? root.appendingPathComponent("private.txt").path)';
        # If any confinement probe succeeds, the fixture refuses to cooperate.
        if (open(my $forbidden, '<', $private)) { exit 88; }
        if (open(my $forbidden, '>', '\#(root.appendingPathComponent("outside-write").path)')) { exit 89; }
        if (IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp')) { exit 90; }
        for my $key (keys %ENV) { if ($key =~ /TOKEN|SECRET|API_KEY|AUTH/) { exit 91; } }
        if ($ARGV[0] eq '--version') { print "codex-cli 0.999.0\n"; exit 0; }
        if ($ARGV[1] eq 'generate-json-schema') { mkdir $ARGV[3]; mkdir "$ARGV[3]/v2"; exit 0; }
        my $id = '00000000-0000-4000-8000-000000000001';
        my $state = "$home/fixture-state";
        my $recordPath = "$home/fixture-record";
        sub sql { system('/usr/bin/sqlite3', "$home/state_5.sqlite", $_[0]) == 0 or die 'sqlite'; }
        sub readState { if (open(my $f, '<', $state)) { local $/; return <$f>; } return 'empty'; }
        sub saveState { open(my $f, '>', $state) or die; print $f $_[0]; close $f; }
        sub record { open(my $f, '<', $recordPath) or die; local $/; return decode_json(<$f>); }
        sub emit { print encode_json($_[0]), "\n"; }
        while (<STDIN>) {
            my $request = decode_json($_); my $method = $request->{method}; my $p = $request->{params};
            next if $method eq 'initialized';
            my $result = {}; my $error;
            if ($mode eq 'eof') { exit 0; }
            if ($mode eq 'approval') { emit({id=>999,method=>'item/commandExecution/requestApproval',params=>{}}); next; }
            if ($method eq 'initialize') { $result = {codexHome => $mode eq 'wrong-home' ? '/' : $home}; }
            elsif ($method eq 'thread/list') {
                my $s = readState();
                my @rows = (($s eq 'active' && !$p->{archived}) || ($s eq 'archived' && $p->{archived})) ? (record()) : ();
                $result = {data=>\@rows, nextCursor=> $mode eq 'page' ? 'more' : undef};
            }
            elsif ($method eq 'thread/start') {
                my $r = {id=>$mode eq 'wrong-id' ? 'bad' : $id, sessionId=>$id, preview=>'fixture', ephemeral=>JSON::PP::false,
                    modelProvider=>'fixture', createdAt=>1, updatedAt=>1, status=>{type=>'idle'}, cwd=>$p->{cwd}, cliVersion=>'0.999.0'};
                open(my $f, '>', $recordPath) or die; print $f encode_json($r); close $f;
                mkdir "$home/sessions";
                my $rollout = "$home/sessions/rollout-$id.jsonl";
                if ($mode eq 'sibling-rollout') {
                    mkdir "$home/sessions-other";
                    $rollout = "$home/sessions-other/rollout-$id.jsonl";
                }
                open(my $roll, '>', $rollout) or die; print $roll "fixture\n"; close $roll;
                if ($mode eq 'symlink-rollout') {
                    rename $rollout, "$home/fixture-rollout" or die;
                    symlink "$home/fixture-rollout", $rollout or die;
                }
                sql("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); INSERT INTO threads VALUES ('$id', '$rollout');");
                saveState('active') unless $mode eq 'no-persistence';
                $result = {thread=>$r};
            }
            elsif ($method eq 'turn/start') {
                # Exercise a terminal event arriving BEFORE the start reply.
                emit({method=>'turn/completed',params=>{threadId=>$id,turn=>{id=>'test-turn',status=>'failed'}}});
                $result = {turn=>{id=>'test-turn'}};
            }
            elsif ($method eq 'thread/read') {
                if (readState() eq 'empty') { $error = {code=>-32600, message=>$mode eq 'wrong-error' ? 'not found' : "thread not loaded: $id"}; }
                else { $result = {thread=>record()}; }
            }
            elsif ($method eq 'thread/archive') {
                if ($mode eq 'busy') { $error = {code=>-32600,message=>'Busy'}; }
                else { saveState('archived'); }
            }
            elsif ($method eq 'thread/unarchive') {
                if ($mode eq 'restore-fails') { $error = {code=>-32600,message=>'Busy'}; }
                else { saveState('active'); $result = {thread=>record()}; }
            }
            elsif ($method eq 'thread/delete') {
                if ($mode ne 'delete-noop') {
                    saveState('empty');
                    sql("DELETE FROM threads WHERE id='$id';") unless $mode eq 'leftover-row';
                    # Simulate removal from the known rollout namespace, without
                    # irreversibly deleting a fixture. The whole test root is trashed.
                    rename "$home/sessions/rollout-$id.jsonl", "$home/fixture-removed" unless $mode eq 'leftover-file';
                }
            } else { die 'unexpected request'; }
            emit($error ? {id=>$request->{id},error=>$error} : {id=>$request->{id},result=>$result});
        }
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: self)
    }
}
