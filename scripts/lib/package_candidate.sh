#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h:h}
PROJECT_PATH="$REPOSITORY_ROOT/macos/AgentSessionManager/App/AgentSessionManager/AgentSessionManager.xcodeproj"
PROJECT_FILE="$PROJECT_PATH/project.pbxproj"
SCHEME="AgentSessionManager"
PRODUCT_NAME="AgentSessionManager.app"
DISPLAY_NAME="Agent Session Manager"
BUNDLE_IDENTIFIER="com.sean.AgentSessionManager"
# Internal worker, run from a committed export by release.mjs.
[[ $# == 6 ]] || { print -u2 "Use scripts/release.sh or scripts/package_dmg.sh"; exit 1; }
VERSION=$1
BUILD_NUMBER=$2
RELEASE_SUFFIX=$3
SOURCE_COMMIT=$4
SOURCE_TREE=$5
OUTPUT_DIRECTORY=$6
ARCHITECTURE=arm64
SHIPPING_BOUNDARY_CHECK="$REPOSITORY_ROOT/scripts/verify_shipping_boundary.sh"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print -u2 "Required tool is unavailable: $1"
        exit 1
    fi
}

for tool in xcodebuild codesign hdiutil ditto shasum plutil trash; do
    require_tool "$tool"
done

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
    print -u2 "Could not resolve MARKETING_VERSION or CURRENT_PROJECT_VERSION."
    exit 1
fi

if [[ "$RELEASE_SUFFIX" == *[!A-Za-z0-9.-]* ]]; then
    print -u2 "Invalid release suffix."
    exit 1
fi

RELEASE_VERSION="$VERSION"
if [[ -n "$RELEASE_SUFFIX" ]]; then
    RELEASE_VERSION="$VERSION-$RELEASE_SUFFIX"
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
        [[ ! -e "$TEMPORARY_ROOT" ]] || print -u2 "Temporary directory still exists: $TEMPORARY_ROOT"
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
    ASM_SOURCE_COMMIT="$SOURCE_COMMIT" \
    ASM_SOURCE_TREE="$SOURCE_TREE" \
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
ACTUAL_SUFFIX=$(/usr/libexec/PlistBuddy -c 'Print :ASMReleaseSuffix' "$BUILT_APP/Contents/Info.plist")
ACTUAL_COMMIT=$(/usr/libexec/PlistBuddy -c 'Print :ASMSourceCommit' "$BUILT_APP/Contents/Info.plist")
ACTUAL_TREE=$(/usr/libexec/PlistBuddy -c 'Print :ASMSourceTree' "$BUILT_APP/Contents/Info.plist")
if [[ "$ACTUAL_IDENTIFIER" != "$BUNDLE_IDENTIFIER" \
    || "$ACTUAL_VERSION" != "$VERSION" \
    || "$ACTUAL_BUILD" != "$BUILD_NUMBER" || "$ACTUAL_SUFFIX" != "$RELEASE_SUFFIX" \
    || "$ACTUAL_COMMIT" != "$SOURCE_COMMIT" || "$ACTUAL_TREE" != "$SOURCE_TREE" ]]; then
    print -u2 "Built bundle metadata does not match the packaging request."
    exit 1
fi

plutil -lint "$BUILT_APP/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

ditto "$BUILT_APP" "$STAGING_DIRECTORY/$PRODUCT_NAME"
ln -s /Applications "$STAGING_DIRECTORY/Applications"

DMG_BASENAME="Agent-Session-Manager-$RELEASE_VERSION-$ARCHITECTURE.dmg"
DMG_PATH="$OUTPUT_DIRECTORY/$DMG_BASENAME"
TEMPORARY_DMG="$TEMPORARY_ROOT/$DMG_BASENAME"

if [[ -e "$DMG_PATH" ]]; then
    print -u2 "Refusing to replace existing DMG: $DMG_PATH"
    exit 1
fi

print "Creating $DMG_BASENAME…"
hdiutil create \
    -volname "$DISPLAY_NAME $VERSION" \
    -srcfolder "$STAGING_DIRECTORY" \
    -format UDZO \
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
cmp "$BUILT_APP/Contents/Info.plist" "$MOUNTED_APP/Contents/Info.plist"
"$SHIPPING_BOUNDARY_CHECK" "$MOUNTED_APP"

hdiutil detach "$MOUNT_DIRECTORY" >/dev/null
ATTACHED=0

DMG_SIZE=$(stat -f '%z' "$DMG_PATH")
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

print ""
print "DMG ready: $DMG_PATH"
print "Version: $VERSION ($BUILD_NUMBER)"
print "Release tag: v$RELEASE_VERSION"
print "Architecture: $ARCHITECTURE"
print "Bytes: $DMG_SIZE"
print "SHA-256: $DMG_SHA256"
print "Signing: ad-hoc local build; not notarized for public distribution"
