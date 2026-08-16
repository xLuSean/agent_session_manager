#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
APP_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManager"
PACKAGE_FILE="$REPOSITORY_ROOT/macos/AgentSessionManager/Package.swift"
PROJECT_FILE="$REPOSITORY_ROOT/macos/AgentSessionManager/App/AgentSessionManager/AgentSessionManager.xcodeproj/project.pbxproj"
FIXTURE_SOURCE="$REPOSITORY_ROOT/macos/AgentSessionManager/Sources/AgentSessionManagerFixtures"

if grep -nE \
    'AgentSessionManagerFixtures|FixtureSessionProvider|FixtureOperationHistoryLedger|FixtureData|INITIAL_DATA_SOURCE|InventoryMode|inventoryMode|testtube\.2' \
    "$APP_SOURCE"/*.swift; then
    print -u2 "Shipping App source still references Fixture product-mode code."
    exit 1
fi

if grep -n 'AgentSessionManagerFixtures.*Frameworks' "$PROJECT_FILE"; then
    print -u2 "The shipping App target links AgentSessionManagerFixtures."
    exit 1
fi

if [[ ! -d "$FIXTURE_SOURCE" ]] \
    || ! grep -q 'name: "AgentSessionManagerFixtures"' "$PACKAGE_FILE"; then
    print -u2 "Fixture support is not isolated in its dedicated Swift package target."
    exit 1
fi

if [[ $# -gt 0 ]]; then
    APP_BUNDLE=$1
    APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentSessionManager"
    if [[ ! -x "$APP_BINARY" ]]; then
        print -u2 "Shipping App binary is unavailable: $APP_BINARY"
        exit 1
    fi
    if /usr/bin/strings -a "$APP_BINARY" \
        | grep -E 'AgentSessionManagerFixtures|FixtureSessionProvider|FixtureOperationHistoryLedger|InventoryMode|testtube\.2'; then
        print -u2 "Shipping App binary contains Fixture implementation symbols."
        exit 1
    fi
fi

print "Shipping boundary verified: App is Codex Live-only; Fixture support is test-only."
