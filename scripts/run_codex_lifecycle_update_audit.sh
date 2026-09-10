#!/bin/zsh

set -euo pipefail

# This read-only wrapper must never inherit explicit live-acceptance opt-ins.
unset AGENT_SESSION_MANAGER_LIVE_TEST AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE ASM_ISOLATED_DELETE_ACCEPTANCE
unset ASM_COMPATIBILITY_ACCEPTANCE ASM_COMPATIBILITY_ACCEPTANCE_EXECUTABLE ASM_COMPATIBILITY_LOCAL_INSPECTION

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
PACKAGE_ROOT="$REPOSITORY_ROOT/macos/AgentSessionManager"
TEMPORARY_BASE=${TMPDIR:-/tmp}
TEMPORARY_BASE=${TEMPORARY_BASE%/}
AUDIT_CACHE_ROOT=${AGENT_SESSION_MANAGER_LIFECYCLE_AUDIT_CACHE_ROOT:-"$TEMPORARY_BASE/agent-session-manager-lifecycle-audit"}
SWIFT_BUILD_ROOT="$AUDIT_CACHE_ROOT/swift-build"
CLANG_CACHE_ROOT="$AUDIT_CACHE_ROOT/clang-module-cache"
SWIFTPM_CACHE_ROOT="$AUDIT_CACHE_ROOT/swiftpm-module-cache"

mkdir -p "$SWIFT_BUILD_ROOT" "$CLANG_CACHE_ROOT" "$SWIFTPM_CACHE_ROOT"

print "Codex lifecycle update — automated read-only audit"
print ""
print "MUST: keep the selected Codex CLI installed while this command runs."
print "DO NOT: close Codex, mount a DMG, select a task, or confirm any mutation."
print "This command never calls thread/archive, thread/unarchive, or thread/delete."
print ""

"$SCRIPT_DIR/audit_app_server_contract.sh"

print ""
print "==> Running deterministic lifecycle audit and packaging-gate tests"
node --test \
  "$SCRIPT_DIR/tests/codex_lifecycle_update_audit.test.mjs" \
  "$SCRIPT_DIR/tests/lifecycle_runtime_packaging_preflight.test.mjs"

print ""
print "==> Running focused Archive/Restore safety tests"
(
  cd "$PACKAGE_ROOT"
  env \
    CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_ROOT" \
    SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE_ROOT" \
    swift test \
    --disable-sandbox \
    --scratch-path "$SWIFT_BUILD_ROOT" \
    --filter 'LifecycleMutationReadinessTests|CodexNativeArchiveCoordinatorTests|ArchiveMutationExecutorTests|ArchiveIsolatedSessionAcceptanceTests|CodexNativeRestoreCoordinatorTests'
)

print ""
print "Audit complete. No lifecycle request was sent."
print "A reversible-operation candidate still requires a reviewed source allow-list update."
print "Permanent Delete remains blocked until its separate disposable-task live acceptance is explicitly authorized."
