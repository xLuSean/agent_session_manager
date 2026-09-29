#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
PACKAGE_ROOT="$REPOSITORY_ROOT/macos/AgentSessionManager"
BUILD_ROOT="$REPOSITORY_ROOT/tmp/compatibility-build"
OUTPUT_ROOT="$REPOSITORY_ROOT/tmp/compatibility-reports"

for tool in swift git; do
    command -v "$tool" >/dev/null 2>&1 || { print -u2 "Required tool is unavailable: $tool"; exit 1; }
done

# Build caches stay local. Core separately confines every test runtime.
mkdir -p "$BUILD_ROOT/clang-cache" "$BUILD_ROOT/module-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache"
export ASM_COMPATIBILITY_SOURCE_REVISION=$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)
if [[ -n "$(git -C "$REPOSITORY_ROOT" status --porcelain -- macos/AgentSessionManager scripts/check_codex_compatibility.sh)" ]]; then
    ASM_COMPATIBILITY_SOURCE_REVISION="${ASM_COMPATIBILITY_SOURCE_REVISION}-dirty"
fi
export ASM_COMPATIBILITY_SOURCE_VERSION=$(awk -F ' = ' '
    /^MARKETING_VERSION = / { version = $2 }
    /^CURRENT_PROJECT_VERSION = / { build = $2 }
    /^ASM_RELEASE_SUFFIX = / { suffix = $2 }
    END { print version (suffix == "" ? "" : "-" suffix) " (build " build ")" }
    ' \
    "$PACKAGE_ROOT/App/AgentSessionManager/Config/Version.xcconfig")

# Keep explicit output arguments intact; the executable validates all flags.
ARGS=("$@")
if (( ${ARGS[(Ie)--output-root]} == 0 )); then
    ARGS+=(--output-root "$OUTPUT_ROOT")
fi
exec swift run --disable-sandbox --package-path "$PACKAGE_ROOT" \
    --scratch-path "$BUILD_ROOT/swift-build" asm-compatibility "${ARGS[@]}"
