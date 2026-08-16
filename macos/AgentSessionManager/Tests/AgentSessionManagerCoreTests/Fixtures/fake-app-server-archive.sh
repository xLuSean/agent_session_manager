#!/bin/zsh

if [[ "$1" == "--version" ]]; then
    print -r -- 'codex-cli 0.147.0'
    exit 0
fi

expected_id="01900000-0000-7000-8000-000000000001"

while IFS= read -r request; do
    if [[ "$request" == *'initialize'* && "$request" != *'initialized'* ]]; then
        print -r -- '{"id":1,"result":{"userAgent":"Codex Desktop/0.147.0 fixture","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}'
    elif [[ "$request" == *'thread/archive'* || "$request" == *'thread\/archive'* ]]; then
        if [[ "$request" == *'threadId'* && "$request" == *"$expected_id"* ]]; then
            print -r -- '{"id":2,"result":{}}'
            exit 0
        fi
        print -r -- '{"id":2,"error":{"code":-32602,"message":"wrong archive payload"}}'
        exit 1
    elif [[ "$request" == *'thread/unarchive'* || "$request" == *'thread\/unarchive'* ]]; then
        if [[ "$request" == *'threadId'* && "$request" == *"$expected_id"* ]]; then
            print -r -- '{"id":2,"result":{}}'
            exit 0
        fi
        print -r -- '{"id":2,"error":{"code":-32602,"message":"wrong restore payload"}}'
        exit 1
    fi
done
