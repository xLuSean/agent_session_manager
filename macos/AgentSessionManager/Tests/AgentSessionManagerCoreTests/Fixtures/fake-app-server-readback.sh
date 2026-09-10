#!/bin/zsh
# Synthetic read-only protocol fixture. Unexpected requests fail immediately.
if [[ "$1" == "--version" ]]; then
    print -r -- 'codex-cli 0.149.0'
    exit 0
fi
ordinal=0
while IFS= read -r request; do
    if [[ "$request" == *'initialized'* ]]; then
        continue
    fi
    (( ordinal += 1 ))
    if (( ordinal == 1 )); then
        [[ "$request" == *'initialize'* ]] || exit 2
        print -r -- '{"id":1,"result":{"userAgent":"fixture","codexHome":"/tmp/asm-readback-fixture","platformFamily":"unix","platformOs":"macos"}}'
    else
        [[ "$request" == *'thread/list'* || "$request" == *'thread\/list'* ]] || exit 3
        [[ "$request" == *'"useStateDbOnly":true'* ]] || exit 4
        [[ "$request" == *'"cli"'* && "$request" == *'"vscode"'* ]] || exit 5
        if [[ "$request" == *'"archived":true'* ]]; then
            print -r -- "{\"id\":$ordinal,\"result\":{\"data\":[],\"nextCursor\":null}}"
        elif [[ "$request" == *'"cursor":"page-2"'* ]]; then
            print -r -- "{\"id\":$ordinal,\"result\":{\"data\":[],\"nextCursor\":null}}"
        else
            print -r -- "{\"id\":$ordinal,\"result\":{\"data\":[{\"id\":\"fixture-session\",\"sessionId\":\"fixture-session\",\"preview\":\"Fixture\",\"ephemeral\":false,\"modelProvider\":\"openai\",\"createdAt\":0,\"updatedAt\":1,\"status\":{\"type\":\"idle\"},\"cwd\":\"/tmp\",\"cliVersion\":\"0.153.4\"}],\"nextCursor\":\"page-2\"}}"
        fi
    fi
done
