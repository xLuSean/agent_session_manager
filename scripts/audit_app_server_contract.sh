#!/bin/zsh

set -eu

schema_directory="$(mktemp -d "${TMPDIR:-/tmp}/agent-session-manager-app-server-schema.XXXXXX")"

cleanup() {
  if command -v trash >/dev/null 2>&1; then
    trash "$schema_directory" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

codex_version="$(codex --version 2>/dev/null)"
codex app-server generate-json-schema --out "$schema_directory" >/dev/null

thread_list_params="$schema_directory/v2/ThreadListParams.json"
thread_list_response="$schema_directory/v2/ThreadListResponse.json"

if [[ ! -f "$thread_list_params" || ! -f "$thread_list_response" ]]; then
  print -u2 "App Server schema bundle does not contain the expected stable v2 thread/list files."
  exit 1
fi

has_json_path() {
  /usr/bin/plutil -extract "$1" raw "$2" >/dev/null 2>&1
}

print_result() {
  printf '%-34s %s\n' "$1" "$2"
}

if has_json_path "definitions.Thread.properties.isPinned" "$thread_list_response"; then
  pin_result="available"
else
  pin_result="unavailable"
fi

if has_json_path "properties.isPinned" "$thread_list_params"; then
  pin_filter_result="available"
else
  pin_filter_result="unavailable"
fi

if has_json_path "definitions.Thread.properties.status" "$thread_list_response"; then
  runtime_status_result="available_process_scoped"
else
  runtime_status_result="unavailable"
fi

if [[ -f "$schema_directory/v2/ThreadLoadedListResponse.json" ]]; then
  loaded_list_result="available_process_scoped"
else
  loaded_list_result="unavailable"
fi

if has_json_path "definitions.Thread.properties.parentThreadId" "$thread_list_response"; then
  parent_result="available"
else
  parent_result="unavailable"
fi

if has_json_path "definitions.Thread.properties.current" "$thread_list_response"; then
  current_result="candidate_requires_manual_authority_review"
else
  current_result="unavailable"
fi

if [[ -f "$schema_directory/v2/ThreadArchiveParams.json" \
      && -f "$schema_directory/v2/ThreadArchiveResponse.json" ]]; then
  archive_result="available"
else
  archive_result="unavailable"
fi

print_result "codex_version" "$codex_version"
print_result "thread_list_is_pinned" "$pin_result"
print_result "thread_list_pin_filter" "$pin_filter_result"
print_result "thread_runtime_status" "$runtime_status_result"
print_result "thread_loaded_list" "$loaded_list_result"
print_result "thread_parent_id" "$parent_result"
print_result "current_task_identity" "$current_result"
print_result "thread_archive_interface" "$archive_result"
print_result "cross_host_idle_clearance" "not_proven_by_schema"
if [[ "$pin_result" == "available" && "$parent_result" == "available" ]]; then
  print_result "archive_pin_authority" "candidate_requires_runtime_review"
else
  print_result "archive_pin_authority" "incomplete"
fi

print
print "This audit is read-only. It generates schema in a temporary directory and does not inspect session storage."
print "Schema presence is compatibility evidence, not mutation authorization."
print "Pin and pinned-descendant evidence remain mandatory. Running/current unknown may only use the audited one-shot Busy-risk contract."
