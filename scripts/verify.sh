#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
PACKAGE_ROOT="$REPOSITORY_ROOT/macos/AgentSessionManager"
APP_PROJECT_ROOT="$PACKAGE_ROOT/App/AgentSessionManager"
APP_PROJECT="$APP_PROJECT_ROOT/AgentSessionManager.xcodeproj"
SHIPPING_BOUNDARY_CHECK="$SCRIPT_DIR/verify_shipping_boundary.sh"

TEMPORARY_BASE=${TMPDIR:-/tmp}
TEMPORARY_BASE=${TEMPORARY_BASE%/}
VERIFY_CACHE_ROOT=${AGENT_SESSION_MANAGER_VERIFY_CACHE_ROOT:-"$TEMPORARY_BASE/agent-session-manager-verify"}
SWIFT_BUILD_ROOT="$VERIFY_CACHE_ROOT/swift-build"
CLANG_CACHE_ROOT="$VERIFY_CACHE_ROOT/clang-module-cache"
SWIFTPM_CACHE_ROOT="$VERIFY_CACHE_ROOT/swiftpm-module-cache"
DERIVED_DATA_ROOT="$VERIFY_CACHE_ROOT/DerivedData"
LOG_ROOT="$VERIFY_CACHE_ROOT/logs"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print -u2 "Required tool is unavailable: $1"
        exit 1
    fi
}

print_failure_log() {
    local label=$1
    local log_path=$2
    print -u2 "FAILED: $label"
    print -u2 "Log: $log_path"
    tail -n 80 "$log_path" >&2
}

for tool in git swift xcodebuild tail; do
    require_tool "$tool"
done

mkdir -p \
    "$SWIFT_BUILD_ROOT" \
    "$CLANG_CACHE_ROOT" \
    "$SWIFTPM_CACHE_ROOT" \
    "$DERIVED_DATA_ROOT" \
    "$LOG_ROOT"

print "==> Checking staged and unstaged diffs"
git -C "$REPOSITORY_ROOT" diff --check
git -C "$REPOSITORY_ROOT" diff --cached --check
print "    Passed"

print "==> Checking shipping Fixture source boundary"
"$SHIPPING_BOUNDARY_CHECK"

SWIFT_LOG="$LOG_ROOT/swift-test.log"
print "==> Running deterministic Swift tests"
if ! (
    cd "$PACKAGE_ROOT"
    env \
        -u AGENT_SESSION_MANAGER_LIVE_TEST \
        -u AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE \
        CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_ROOT" \
        SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE_ROOT" \
        swift test \
            --disable-sandbox \
            --scratch-path "$SWIFT_BUILD_ROOT"
) >"$SWIFT_LOG" 2>&1; then
    print_failure_log "swift test" "$SWIFT_LOG"
    exit 1
fi
SWIFT_SUMMARY=$(grep -E 'Executed [0-9]+ tests?, with' "$SWIFT_LOG" | tail -1 || true)
print "    ${SWIFT_SUMMARY:-Passed}"

XCODE_LOG="$LOG_ROOT/xcodebuild-test.log"
print "==> Building the formal Xcode App target and running App-layer tests"
if ! env \
    -u AGENT_SESSION_MANAGER_LIVE_TEST \
    -u AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE \
    CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_ROOT" \
    SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE_ROOT" \
    xcodebuild \
    -quiet \
    -project "$APP_PROJECT" \
    -scheme AgentSessionManager \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_ROOT" \
    CODE_SIGNING_ALLOWED=NO \
    test >"$XCODE_LOG" 2>&1; then
    print_failure_log "xcodebuild test" "$XCODE_LOG"
    exit 1
fi
XCODE_SUMMARY=$(grep -E 'Executed [0-9]+ tests?, with' "$XCODE_LOG" | tail -1 || true)
print "    ${XCODE_SUMMARY:-Passed}"

BUILT_APP="$DERIVED_DATA_ROOT/Build/Products/Debug/AgentSessionManager.app"
print "==> Checking the built App binary boundary"
"$SHIPPING_BOUNDARY_CHECK" "$BUILT_APP"

print ""
print "Verification passed."
print "Logs: $LOG_ROOT"
