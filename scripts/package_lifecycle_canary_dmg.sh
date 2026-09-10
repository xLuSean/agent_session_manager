#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}

# A lifecycle canary is meaningful only when every operation in its runbook is
# supported by the exact Codex executable selected on this Mac. This check runs
# before xcodebuild, signing, staging, or DMG creation.
"$SCRIPT_DIR/verify_lifecycle_runtime_compatibility.sh" \
    archive \
    move-to-trash \
    permanent-delete

"$SCRIPT_DIR/package_dmg.sh" "$@"
