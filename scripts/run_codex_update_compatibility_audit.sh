#!/bin/zsh

set -uo pipefail

SCRIPT_DIR=${0:A:h}

print "MUST: keep the installed Codex Desktop and standalone Codex CLI unchanged while this runs."
print "DO NOT: close Codex, mount a DMG, select a task, or confirm any mutation."
print "This audit does not send lifecycle requests or read session rows."
print ""

node "$SCRIPT_DIR/audit_codex_update_compatibility.mjs"
AUDIT_STATUS=$?

print ""
print "==> Running deterministic compatibility tests"
node --test \
  "$SCRIPT_DIR/tests/codex_update_compatibility.test.mjs" \
  "$SCRIPT_DIR/tests/codex_lifecycle_update_audit.test.mjs" \
  "$SCRIPT_DIR/tests/lifecycle_runtime_packaging_preflight.test.mjs"
TEST_STATUS=$?

print ""
if (( TEST_STATUS != 0 )); then
  print -u2 "BLOCKED: deterministic compatibility tests failed."
  exit "$TEST_STATUS"
fi
if (( AUDIT_STATUS != 0 )); then
  print -u2 "BLOCKED: the installed Codex combination is not admitted by the current build."
  print -u2 "No allow-list, database, task, or App state was changed."
  exit "$AUDIT_STATUS"
fi

print "READY: read-only Ghost preparation and reversible lifecycle compatibility are admitted; Permanent Delete remains subject to its separate verdict."
