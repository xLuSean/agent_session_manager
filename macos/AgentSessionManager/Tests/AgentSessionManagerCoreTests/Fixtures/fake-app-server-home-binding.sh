#!/bin/zsh
# Test-owned protocol fixture: configuration and output remain beside this copy.
fixture_root=${0:A:h}
if [[ "$1" == "--version" ]]; then
    print -r -- "codex-cli $(<"$fixture_root/runtime.txt")"
    exit 0
fi
[[ "$1" == "app-server" ]] || exit 2
ordinal=0
while IFS= read -r request; do
    print -r -- "$request" >> "$fixture_root/requests.jsonl"
    [[ "$request" == *'initialized'* ]] && continue
    (( ordinal += 1 ))
    if [[ "$request" == *'initialize'* ]]; then
        print -r -- "$(<"$fixture_root/initialize.json")"
    elif [[ "$request" == *'thread/read'* || "$request" == *'thread\/read'* ]]; then
        print -r -- "$(<"$fixture_root/exact.json")"
    elif [[ "$request" == *'thread/list'* || "$request" == *'thread\/list'* ]]; then
        print -r -- "{\"id\":$ordinal,\"result\":{\"data\":[],\"nextCursor\":null}}"
    elif [[ "$request" == *'config/read'* || "$request" == *'config\/read'* ]]; then
        print -r -- "{\"id\":$ordinal,\"result\":{\"config\":{\"projects\":{}}}}"
    else
        # This fixture must never mutate anything, even on a regressed caller.
        print -r -- "{\"id\":$ordinal,\"error\":{\"code\":-32601,\"message\":\"fixture rejects mutation\"}}"
    fi
done
