#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
MANAGED_HOOKS_PATH=.githooks

usage() {
    print -u2 "Usage: $0 <enable|disable|status>"
}

current_hooks_path() {
    git config --local --get core.hooksPath 2>/dev/null || true
}

if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

cd "$REPOSITORY_ROOT"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    print -u2 "Not inside a Git repository: $REPOSITORY_ROOT"
    exit 1
fi

ACTION=$1
CURRENT_PATH=$(current_hooks_path)

case "$ACTION" in
    enable)
        if [[ ! -x "$REPOSITORY_ROOT/$MANAGED_HOOKS_PATH/pre-commit" ]]; then
            print -u2 "Managed pre-commit hook is missing or not executable."
            exit 1
        fi

        if [[ -n "$CURRENT_PATH" && "$CURRENT_PATH" != "$MANAGED_HOOKS_PATH" ]]; then
            print -u2 "Refusing to replace existing core.hooksPath: $CURRENT_PATH"
            print -u2 "Disable or migrate that hook configuration manually before enabling this one."
            exit 1
        fi

        git config --local core.hooksPath "$MANAGED_HOOKS_PATH"
        READBACK=$(current_hooks_path)
        if [[ "$READBACK" != "$MANAGED_HOOKS_PATH" ]]; then
            print -u2 "Failed to verify core.hooksPath after enabling."
            exit 1
        fi

        print "Enabled repository pre-commit verification via $MANAGED_HOOKS_PATH."
        ;;
    disable)
        if [[ -z "$CURRENT_PATH" ]]; then
            print "Repository-managed Git hooks are already disabled."
            exit 0
        fi

        if [[ "$CURRENT_PATH" != "$MANAGED_HOOKS_PATH" ]]; then
            print -u2 "Refusing to remove unrecognized core.hooksPath: $CURRENT_PATH"
            exit 1
        fi

        git config --local --unset core.hooksPath
        READBACK=$(current_hooks_path)
        if [[ -n "$READBACK" ]]; then
            print -u2 "Failed to verify core.hooksPath after disabling."
            exit 1
        fi

        print "Disabled repository pre-commit verification."
        ;;
    status)
        if [[ "$CURRENT_PATH" == "$MANAGED_HOOKS_PATH" ]]; then
            print "Repository pre-commit verification is enabled via $MANAGED_HOOKS_PATH."
        elif [[ -z "$CURRENT_PATH" ]]; then
            print "Repository pre-commit verification is disabled."
        else
            print "Repository uses a different core.hooksPath: $CURRENT_PATH"
        fi
        ;;
    *)
        usage
        exit 2
        ;;
esac
