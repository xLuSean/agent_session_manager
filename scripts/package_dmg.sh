#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
exec node "$SCRIPT_DIR/release.mjs" package "$@"
