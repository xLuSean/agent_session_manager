#!/bin/zsh
# Synthetic read-only server; copied beside a test-owned state database.
if [[ "$1" == "--version" ]]; then
    print -r -- 'codex-cli 0.153.4'
    exit 0
fi
fixture_root=${0:A:h}
ordinal=0
while IFS= read -r request; do
    [[ "$request" == *'initialized'* ]] && continue
    (( ordinal += 1 ))
    if (( ordinal == 1 )); then
        [[ "$request" == *'initialize'* ]] || exit 2
        print -r -- "{\"id\":1,\"result\":{\"userAgent\":\"fixture\",\"codexHome\":\"$fixture_root\",\"platformFamily\":\"unix\",\"platformOs\":\"macos\"}}"
    elif [[ "$request" == *'config/read'* || "$request" == *'config\/read'* ]]; then
        print -r -- "{\"id\":$ordinal,\"result\":{\"config\":{\"projects\":{}}}}"
    elif [[ "$request" == *'thread/list'* || "$request" == *'thread\/list'* ]]; then
        [[ "$request" == *'"useStateDbOnly":true'* ]] || exit 3
        print -r -- "{\"id\":$ordinal,\"result\":{\"data\":[],\"nextCursor\":null}}"
    elif [[ "$request" == *'thread/read'* || "$request" == *'thread\/read'* ]]; then
        [[ "$request" == *'"includeTurns":false'* ]] || exit 4
        [[ "$request" =~ '00000000-0000-4000-8000-[0-9]{12}' ]] || exit 5
        fixture_id=$MATCH
        payload=$(/usr/bin/sqlite3 -readonly "$fixture_root/state_5.sqlite" "SELECT json_object('id',id,'sessionId',id,'preview','','ephemeral',json('false'),'modelProvider','openai','createdAt',0,'updatedAt',1,'status',json('{\"type\":\"notLoaded\"}'),'cwd',cwd,'cliVersion','0.153.4','name','Automation fixture') FROM threads WHERE id='$fixture_id';") || exit 6
        if [[ -n "$payload" ]]; then
            print -r -- "{\"id\":$ordinal,\"result\":{\"thread\":$payload}}"
        else
            print -r -- "{\"id\":$ordinal,\"error\":{\"code\":-32600,\"message\":\"thread not loaded: $fixture_id\"}}"
        fi
    else
        # No lifecycle mutation, resume, or repair is supported by this fixture.
        exit 7
    fi
done
