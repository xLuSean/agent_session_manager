#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
CONTRACT_SOURCE=${CODEX_LIFECYCLE_CONTRACT_SOURCE_OVERRIDE:-"$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexAppServerProvider.swift"}
CODEX_COMMAND=${CODEX_EXECUTABLE_OVERRIDE:-${CODEX_EXECUTABLE:-codex}}
OWNS_SCHEMA_DIRECTORY=1

if [[ -n ${CODEX_APP_SERVER_SCHEMA_DIRECTORY_OVERRIDE:-} ]]; then
  schema_directory=$CODEX_APP_SERVER_SCHEMA_DIRECTORY_OVERRIDE
  OWNS_SCHEMA_DIRECTORY=0
else
  schema_directory="$(mktemp -d "${TMPDIR:-/tmp}/agent-session-manager-app-server-schema.XXXXXX")"
fi

cleanup() {
  if (( OWNS_SCHEMA_DIRECTORY )) && [[ -e "$schema_directory" ]]; then
    trash "$schema_directory" >/dev/null 2>&1 || {
      if [[ -e "$schema_directory" ]]; then
        print -u2 "Warning: temporary schema directory was retained."
      fi
    }
  fi
}
trap cleanup EXIT

fail() {
  print -u2 "BLOCKED: $1"
  print -u2 "No lifecycle request was sent."
  exit 1
}

for tool in jq shasum trash; do
  command -v "$tool" >/dev/null 2>&1 || fail "This audit requires $tool."
done
command -v "$CODEX_COMMAND" >/dev/null 2>&1 \
  || fail "The selected Codex executable is unavailable."
[[ -r "$CONTRACT_SOURCE" ]] \
  || fail "The shipping Core lifecycle contract source is unavailable."

VERSION_OUTPUT=$("$CODEX_COMMAND" --version 2>/dev/null) \
  || fail "The selected Codex executable did not return a version."
VERSION_TOKENS=(${=VERSION_OUTPUT})
(( ${#VERSION_TOKENS} == 2 )) \
  || fail "Expected exact 'codex-cli <version>' output; observed: ${VERSION_OUTPUT:-empty}."
[[ "${VERSION_TOKENS[1]}" == "codex-cli" ]] \
  || fail "Expected exact 'codex-cli <version>' output; observed: $VERSION_OUTPUT."
RUNTIME_VERSION=${VERSION_TOKENS[2]}
[[ "$RUNTIME_VERSION" == [0-9]* && "$RUNTIME_VERSION" != *[^A-Za-z0-9.-]* ]] \
  || fail "The Codex runtime version is malformed: $RUNTIME_VERSION."

if (( OWNS_SCHEMA_DIRECTORY )); then
  "$CODEX_COMMAND" app-server generate-json-schema --out "$schema_directory" >/dev/null \
    || fail "Codex App Server schema generation failed."
else
  [[ -d "$schema_directory" ]] \
    || fail "The injected schema directory is unavailable."
fi

thread_list_params="$schema_directory/v2/ThreadListParams.json"
thread_list_response="$schema_directory/v2/ThreadListResponse.json"

if [[ ! -f "$thread_list_params" || ! -f "$thread_list_response" ]]; then
  fail "App Server schema bundle does not contain the expected stable v2 thread/list files."
fi

has_json_path() {
  /usr/bin/plutil -extract "$1" raw "$2" >/dev/null 2>&1
}

print_result() {
  printf '%-36s %s\n' "$1" "$2"
}

schema_matches() {
  jq -e "$2" "$1" >/dev/null 2>&1
}

verify_lifecycle_contract() {
  local prefix="$1"
  local params="$schema_directory/v2/${prefix}Params.json"
  local response="$schema_directory/v2/${prefix}Response.json"
  local notification="$schema_directory/v2/${prefix}dNotification.json"

  [[ -f "$params" && -f "$response" && -f "$notification" ]] || return 1
  schema_matches "$params" \
    '.type == "object" and (.properties | keys) == ["threadId"] and .required == ["threadId"] and .properties.threadId.type == "string"' || return 1
  schema_matches "$notification" \
    '.type == "object" and (.properties | keys) == ["threadId"] and .required == ["threadId"] and .properties.threadId.type == "string"' || return 1

  case "$prefix" in
    ThreadUnarchive)
      schema_matches "$response" \
        '.type == "object" and (.properties | keys) == ["thread"] and .required == ["thread"] and .properties.thread."$ref" == "#/definitions/Thread"'
      ;;
    *)
      schema_matches "$response" \
        '.type == "object" and ((.properties // {}) | length) == 0'
      ;;
  esac
}

verify_thread_decoder_contract() {
  local schema_file="$1"

  schema_matches "$schema_file" '
    . as $document
    | .definitions.Thread as $thread
    | ((([
        "id", "sessionId", "preview", "ephemeral", "modelProvider",
        "createdAt", "updatedAt", "status", "cwd", "cliVersion"
      ] - ($thread.required // [])) | length) == 0)
      and $thread.properties.id.type == "string"
      and $thread.properties.sessionId.type == "string"
      and $thread.properties.preview.type == "string"
      and $thread.properties.ephemeral.type == "boolean"
      and $thread.properties.modelProvider.type == "string"
      and $thread.properties.createdAt.type == "integer"
      and $thread.properties.updatedAt.type == "integer"
      and $thread.properties.status.allOf[0]."$ref" == "#/definitions/ThreadStatus"
      and $thread.properties.cwd.allOf[0]."$ref" == "#/definitions/AbsolutePathBuf"
      and $thread.properties.cliVersion.type == "string"
      and (($thread.properties.parentThreadId.type // ["string", "null"]) | sort) == ["null", "string"]
      and (($thread.properties.name.type // ["string", "null"]) | sort) == ["null", "string"]
      and ([
        $document.definitions.ThreadStatus.oneOf[]
        | ((.required // []) | index("type") != null)
          and .properties.type.type == "string"
      ] | all)
  '
}

guarded_admissions() {
  local function_name=$1
  local body
  body=$(sed -n "/public static func ${function_name}/,/^    }/p" "$CONTRACT_SOURCE")
  [[ -n "$body" ]] || fail "Could not read ${function_name} from the shipping Core contract."
  print -r -- "$body" \
    | awk '
        /^[[:space:]]*#if[[:space:]]+ASM_ISOLATED_DELETE_ACCEPTANCE([[:space:]]|$)/ { ignored = 1; next }
        ignored && /^[[:space:]]*#if([[:space:]]|$)/ { ignored += 1; next }
        ignored && /^[[:space:]]*#endif([[:space:]]|$)/ { ignored -= 1; next }
        !ignored { print }
      ' \
    | sed -n -E \
        -e 's/.*release: "([^"]+)".*/series:\1/p' \
        -e 's/.*runtimeVersion == "([^"]+)".*/exact:\1/p'
}

admissions_contain() {
  local runtime_version=$1
  shift
  local admission release
  for admission in "$@"; do
    case "$admission" in
      series:*)
        release=${admission#series:}
        if [[ "$runtime_version" == "$release" || "$runtime_version" == "$release"-* ]]; then
          return 0
        fi
        ;;
      exact:*)
        [[ "$runtime_version" == "${admission#exact:}" ]] && return 0
        ;;
    esac
  done
  return 1
}

shipping_verdict() {
  local schema_result=$1
  local unsupported_result=$2
  shift 2

  if [[ "$schema_result" != "compatible" ]]; then
    print -r -- "blocked_schema_drift"
  elif admissions_contain "$RUNTIME_VERSION" "$@"; then
    print -r -- "ready_current_build"
  else
    print -r -- "$unsupported_result"
  fi
}

if verify_lifecycle_contract ThreadArchive; then
  archive_contract_result="compatible"
else
  archive_contract_result="incompatible"
fi
if verify_lifecycle_contract ThreadUnarchive; then
  unarchive_contract_result="compatible"
else
  unarchive_contract_result="incompatible"
fi
if verify_lifecycle_contract ThreadDelete; then
  delete_contract_result="compatible_schema_only"
  delete_schema_result="compatible"
else
  delete_contract_result="incompatible"
  delete_schema_result="incompatible"
fi
if verify_thread_decoder_contract "$thread_list_response" \
    && verify_thread_decoder_contract "$schema_directory/v2/ThreadUnarchiveResponse.json"; then
  thread_decoder_result="compatible"
else
  thread_decoder_result="incompatible"
fi

if [[ "$archive_contract_result" == "compatible" && "$thread_decoder_result" == "compatible" ]]; then
  archive_schema_result="compatible"
else
  archive_schema_result="incompatible"
fi
if [[ "$unarchive_contract_result" == "compatible" && "$thread_decoder_result" == "compatible" ]]; then
  restore_schema_result="compatible"
else
  restore_schema_result="incompatible"
fi
if [[ "$delete_schema_result" == "compatible" && "$thread_decoder_result" != "compatible" ]]; then
  delete_schema_result="incompatible"
fi

LIFECYCLE_RELEASES=(${(f)"$(guarded_admissions supportsVerifiedLifecycleContract)"})
DELETE_RELEASES=(${(f)"$(guarded_admissions supportsVerifiedDeleteContract)"})
(( ${#LIFECYCLE_RELEASES} > 0 )) \
  || fail "The Archive/Restore allow-list is empty."
(( ${#DELETE_RELEASES} > 0 )) \
  || fail "The Permanent Delete allow-list is empty."

archive_verdict=$(shipping_verdict \
  "$archive_schema_result" candidate_requires_allowlist_update "${LIFECYCLE_RELEASES[@]}")
restore_verdict=$(shipping_verdict \
  "$restore_schema_result" candidate_requires_allowlist_update "${LIFECYCLE_RELEASES[@]}")
move_to_trash_verdict=$(shipping_verdict \
  "$archive_schema_result" candidate_requires_allowlist_update "${LIFECYCLE_RELEASES[@]}")
permanent_delete_verdict=$(shipping_verdict \
  "$delete_schema_result" blocked_requires_live_acceptance "${DELETE_RELEASES[@]}")

schema_files=(
  "$schema_directory/v2/ThreadListParams.json"
  "$schema_directory/v2/ThreadListResponse.json"
  "$schema_directory/v2/ThreadLoadedListResponse.json"
  "$schema_directory/v2/ThreadArchiveParams.json"
  "$schema_directory/v2/ThreadArchiveResponse.json"
  "$schema_directory/v2/ThreadArchivedNotification.json"
  "$schema_directory/v2/ThreadUnarchiveParams.json"
  "$schema_directory/v2/ThreadUnarchiveResponse.json"
  "$schema_directory/v2/ThreadUnarchivedNotification.json"
  "$schema_directory/v2/ThreadDeleteParams.json"
  "$schema_directory/v2/ThreadDeleteResponse.json"
  "$schema_directory/v2/ThreadDeletedNotification.json"
)
schema_hash_input=""
for schema_file in "${schema_files[@]}"; do
  [[ -f "$schema_file" ]] || fail "The lifecycle schema bundle is incomplete."
  schema_hash_input+="$(shasum -a 256 "$schema_file" | awk '{print $1}')  ${schema_file:t}"$'\n'
done
schema_bundle_hash=$(print -rn -- "$schema_hash_input" | shasum -a 256 | awk '{print $1}')

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

print "Codex lifecycle update audit"
print "IMPORTANT: this command only generates and inspects protocol schema."
print "It does not inspect task storage or send Archive, Restore, Trash, or Delete requests."
print
print_result "codex_version" "$VERSION_OUTPUT"
print_result "lifecycle_schema_bundle_sha256" "$schema_bundle_hash"
print_result "thread_list_is_pinned" "$pin_result"
print_result "thread_list_pin_filter" "$pin_filter_result"
print_result "thread_runtime_status" "$runtime_status_result"
print_result "thread_loaded_list" "$loaded_list_result"
print_result "thread_parent_id" "$parent_result"
print_result "current_task_identity" "$current_result"
print_result "thread_archive_interface" "$archive_result"
print_result "thread_archive_contract" "$archive_contract_result"
print_result "thread_unarchive_contract" "$unarchive_contract_result"
print_result "thread_delete_contract" "$delete_contract_result"
print_result "thread_decoder_contract" "$thread_decoder_result"
print_result "archive_shipping_verdict" "$archive_verdict"
print_result "restore_shipping_verdict" "$restore_verdict"
print_result "move_to_trash_shipping_verdict" "$move_to_trash_verdict"
print_result "permanent_delete_shipping_verdict" "$permanent_delete_verdict"
print_result "cross_host_idle_clearance" "not_proven_by_schema"
if [[ "$pin_result" == "available" && "$parent_result" == "available" ]]; then
  print_result "archive_pin_authority" "candidate_requires_runtime_review"
else
  print_result "archive_pin_authority" "incomplete"
fi
print_result "session_storage_inspected" "no"
print_result "lifecycle_requests_sent" "0"
print_result "mutation_authority" "none"

print
print "Verdict meanings:"
print "  ready_current_build                 already allowed by this App build"
print "  candidate_requires_allowlist_update exact reversible schema matches; code review is still required"
print "  blocked_requires_live_acceptance    irreversible Delete remains separately blocked"
print "  blocked_schema_drift                do not update an allow-list; inspect the contract change"

if [[ "$archive_schema_result" != "compatible" \
      || "$restore_schema_result" != "compatible" \
      || "$delete_schema_result" != "compatible" ]]; then
  fail "The generated lifecycle schema or the App's Thread decoder surface changed."
fi
