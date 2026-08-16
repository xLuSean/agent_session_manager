#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h}
PROJECT_PATH="$REPOSITORY_ROOT/macos/AgentSessionManager/App/AgentSessionManager/AgentSessionManager.xcodeproj"
PROJECT_FILE="$PROJECT_PATH/project.pbxproj"
SCHEME="AgentSessionManager"
PRODUCT_NAME="AgentSessionManager.app"
DISPLAY_NAME="Agent Session Manager"
BUNDLE_IDENTIFIER="com.sean.AgentSessionManager"
OUTPUT_DIRECTORY="$REPOSITORY_ROOT/dist"
SHIPPING_BOUNDARY_CHECK="$SCRIPT_DIR/verify_shipping_boundary.sh"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print -u2 "Required tool is unavailable: $1"
        exit 1
    fi
}

for tool in xcodebuild codesign hdiutil ditto shasum plutil trash; do
    require_tool "$tool"
done

VERSION=${VERSION_OVERRIDE:-$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$PROJECT_FILE" | head -1)}
BUILD_NUMBER=${BUILD_NUMBER_OVERRIDE:-$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' "$PROJECT_FILE" | head -1)}
ARCHITECTURE=${ARCHITECTURE_OVERRIDE:-$(uname -m)}

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
    print -u2 "Could not resolve MARKETING_VERSION or CURRENT_PROJECT_VERSION."
    exit 1
fi

TEMPORARY_ROOT=$(mktemp -d /tmp/agent-session-manager-dmg.XXXXXX)
DERIVED_DATA="$TEMPORARY_ROOT/DerivedData"
STAGING_DIRECTORY="$TEMPORARY_ROOT/staging"
MOUNT_DIRECTORY="$TEMPORARY_ROOT/mount"
ATTACHED=0

cleanup() {
    if (( ATTACHED )); then
        hdiutil detach "$MOUNT_DIRECTORY" >/dev/null 2>&1 || true
    fi
    if [[ -e "$TEMPORARY_ROOT" ]]; then
        trash "$TEMPORARY_ROOT" >/dev/null 2>&1 || {
            print -u2 "Warning: temporary build directory was retained at $TEMPORARY_ROOT"
        }
    fi
}
trap cleanup EXIT INT TERM

mkdir -p "$STAGING_DIRECTORY" "$MOUNT_DIRECTORY" "$OUTPUT_DIRECTORY"

"$SHIPPING_BOUNDARY_CHECK"

print "Building $DISPLAY_NAME $VERSION ($BUILD_NUMBER) for $ARCHITECTURE…"
xcodebuild \
    -quiet \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=macOS,arch=$ARCHITECTURE" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$PRODUCT_NAME"
if [[ ! -d "$BUILT_APP" ]]; then
    print -u2 "Release app was not produced at $BUILT_APP"
    exit 1
fi

"$SHIPPING_BOUNDARY_CHECK" "$BUILT_APP"

ACTUAL_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_APP/Contents/Info.plist")
ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")
ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")
if [[ "$ACTUAL_IDENTIFIER" != "$BUNDLE_IDENTIFIER" \
    || "$ACTUAL_VERSION" != "$VERSION" \
    || "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]]; then
    print -u2 "Built bundle metadata does not match the packaging request."
    exit 1
fi

plutil -lint "$BUILT_APP/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

ditto "$BUILT_APP" "$STAGING_DIRECTORY/$PRODUCT_NAME"
ln -s /Applications "$STAGING_DIRECTORY/Applications"

DMG_BASENAME="Agent-Session-Manager-$VERSION-local-$ARCHITECTURE.dmg"
DMG_PATH="$OUTPUT_DIRECTORY/$DMG_BASENAME"
TEMPORARY_DMG="$TEMPORARY_ROOT/$DMG_BASENAME"

if [[ -e "$DMG_PATH" ]]; then
    trash "$DMG_PATH"
    if [[ -e "$DMG_PATH" ]]; then
        print -u2 "Existing DMG could not be moved to Trash: $DMG_PATH"
        exit 1
    fi
fi

print "Creating $DMG_BASENAME…"
hdiutil create \
    -volname "$DISPLAY_NAME $VERSION" \
    -srcfolder "$STAGING_DIRECTORY" \
    -format UDZO \
    -ov \
    "$TEMPORARY_DMG"
hdiutil verify "$TEMPORARY_DMG"
mv "$TEMPORARY_DMG" "$DMG_PATH"

hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_DIRECTORY" \
    "$DMG_PATH" >/dev/null
ATTACHED=1

MOUNTED_APP="$MOUNT_DIRECTORY/$PRODUCT_NAME"
if [[ ! -d "$MOUNTED_APP" || ! -L "$MOUNT_DIRECTORY/Applications" ]]; then
    print -u2 "Mounted DMG does not contain the expected app and Applications link."
    exit 1
fi
if [[ "$(readlink "$MOUNT_DIRECTORY/Applications")" != "/Applications" ]]; then
    print -u2 "Applications link has an unexpected destination."
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP"

hdiutil detach "$MOUNT_DIRECTORY" >/dev/null
ATTACHED=0

DMG_SIZE=$(stat -f '%z' "$DMG_PATH")
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

print ""
print "DMG ready: $DMG_PATH"
print "Version: $VERSION ($BUILD_NUMBER)"
print "Architecture: $ARCHITECTURE"
print "Bytes: $DMG_SIZE"
print "SHA-256: $DMG_SHA256"
print "Signing: ad-hoc local build; not notarized for public distribution"
