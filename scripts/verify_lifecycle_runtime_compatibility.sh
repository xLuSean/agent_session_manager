#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
CONTRACT_SOURCE=${CODEX_LIFECYCLE_CONTRACT_SOURCE_OVERRIDE:-"$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexAppServerProvider.swift"}

fail() {
    print -u2 "BLOCKED: $1"
    print -u2 "No lifecycle canary DMG was built."
    exit 1
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

resolve_codex_executable() {
    if [[ -n ${CODEX_EXECUTABLE_OVERRIDE:-} ]]; then
        [[ -x "$CODEX_EXECUTABLE_OVERRIDE" ]] \
            || fail "CODEX_EXECUTABLE_OVERRIDE is not executable."
        print -r -- "$CODEX_EXECUTABLE_OVERRIDE"
        return
    fi

    local candidate
    for candidate in /opt/homebrew/bin/codex /usr/local/bin/codex; do
        if [[ -x "$candidate" ]]; then
            print -r -- "$candidate"
            return
        fi
    done
    candidate=${commands[codex]:-}
    [[ -n "$candidate" && -x "$candidate" ]] || fail "Codex CLI was not found."
    print -r -- "$candidate"
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

[[ -r "$CONTRACT_SOURCE" ]] || fail "The shipping Core lifecycle contract source is unavailable."
(( $# > 0 )) || fail "Name at least one required operation: archive, move-to-trash, restore, or permanent-delete."

CODEX_EXECUTABLE=$(resolve_codex_executable)
VERSION_OUTPUT=$("$CODEX_EXECUTABLE" --version 2>/dev/null) \
    || fail "The selected Codex executable did not return a version."
VERSION_TOKENS=(${=VERSION_OUTPUT})
(( ${#VERSION_TOKENS} == 2 )) \
    || fail "Expected exact 'codex-cli <version>' output; observed: ${VERSION_OUTPUT:-empty}."
[[ "${VERSION_TOKENS[1]}" == "codex-cli" ]] \
    || fail "Expected exact 'codex-cli <version>' output; observed: $VERSION_OUTPUT."
RUNTIME_VERSION=${VERSION_TOKENS[2]}
[[ "$RUNTIME_VERSION" == [0-9]* && "$RUNTIME_VERSION" != *[^A-Za-z0-9.-]* ]] \
    || fail "The Codex runtime version is malformed: $RUNTIME_VERSION."

LIFECYCLE_RELEASES=(${(f)"$(guarded_admissions supportsVerifiedLifecycleContract)"})
DELETE_RELEASES=(${(f)"$(guarded_admissions supportsVerifiedDeleteContract)"})
(( ${#LIFECYCLE_RELEASES} > 0 )) || fail "The Archive/Restore allow-list is empty."
(( ${#DELETE_RELEASES} > 0 )) || fail "The Permanent Delete allow-list is empty."

print "Codex lifecycle packaging preflight"
print "Runtime executable: $CODEX_EXECUTABLE"
print "Observed runtime: $RUNTIME_VERSION"

FAILED_OPERATIONS=()
for operation in "$@"; do
    case "$operation" in
        archive|move-to-trash|restore)
            if admissions_contain "$RUNTIME_VERSION" "${LIFECYCLE_RELEASES[@]}"; then
                print "Compatible: $operation"
            else
                FAILED_OPERATIONS+=("$operation")
            fi
            ;;
        permanent-delete|delete)
            if admissions_contain "$RUNTIME_VERSION" "${DELETE_RELEASES[@]}"; then
                print "Compatible: permanent-delete"
            else
                FAILED_OPERATIONS+=("permanent-delete")
            fi
            ;;
        *)
            fail "Unknown lifecycle operation: $operation."
            ;;
    esac
done

if (( ${#FAILED_OPERATIONS} > 0 )); then
    fail "Codex runtime $RUNTIME_VERSION is outside the audited allow-list for: ${(j:, :)FAILED_OPERATIONS}."
fi

print "Preflight passed. Packaging may continue for the exact requested operations."
