#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist/macos}"
XCODE_SWIFT_OPTIMIZATION_LEVEL="${XCODE_SWIFT_OPTIMIZATION_LEVEL:-}"
XCODE_SWIFT_COMPILATION_MODE="${XCODE_SWIFT_COMPILATION_MODE:-}"
XCODE_ENABLE_PREVIEWS="${XCODE_ENABLE_PREVIEWS:-}"
APP_NAME="GeoTeleportMacV3.app"
DMG_NAME="GeoTeleportMacV3.dmg"
VOLUME_NAME="GeoTeleportMacV3"
DMG_STAGING="$ROOT_DIR/build/dmg_staging_macos"
RW_DMG="$ROOT_DIR/build/${DMG_NAME%.dmg}.rw.dmg"

cd "$ROOT_DIR"

echo "=> Building native-device-core (Release)..."
cd native-device-core
cargo build --release
cd ..

echo "=> Building GeoTeleportMac (Release)..."
XCODEBUILD_ARGS=(
    -project GeoTeleportMac.xcodeproj
    -scheme GeoTeleportMac
    -configuration Release
    -derivedDataPath "$DERIVED_DATA_PATH"
    build
)

if [ -n "$XCODE_SWIFT_OPTIMIZATION_LEVEL" ]; then
    XCODEBUILD_ARGS+=("SWIFT_OPTIMIZATION_LEVEL=$XCODE_SWIFT_OPTIMIZATION_LEVEL")
fi

if [ -n "$XCODE_SWIFT_COMPILATION_MODE" ]; then
    XCODEBUILD_ARGS+=("SWIFT_COMPILATION_MODE=$XCODE_SWIFT_COMPILATION_MODE")
fi

if [ -n "$XCODE_ENABLE_PREVIEWS" ]; then
    XCODEBUILD_ARGS+=("ENABLE_PREVIEWS=$XCODE_ENABLE_PREVIEWS")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}"

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/GeoTeleportMacV3"

if [ ! -x "$APP_EXECUTABLE" ]; then
    echo "Error: Release build of GeoTeleportMacV3.app not found." >&2
    exit 1
fi

echo "=> Found App: $APP_PATH"

echo "=> Preparing DMG staging directory..."
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Defensive: detach any stale mount of the same volume name from a previous run.
if [ -d "/Volumes/$VOLUME_NAME" ]; then
    hdiutil detach "/Volumes/$VOLUME_NAME" -force >/dev/null 2>&1 || true
fi

echo "=> Creating writable DMG for layout staging..."
mkdir -p "$ROOT_DIR/build"
rm -f "$RW_DMG"
hdiutil create \
    -srcfolder "$DMG_STAGING" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -ov \
    "$RW_DMG" >/dev/null

echo "=> Mounting writable DMG..."
MOUNT_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
MOUNT_POINT="$(echo "$MOUNT_OUTPUT" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"

if [ -z "${MOUNT_POINT:-}" ] || [ ! -d "$MOUNT_POINT" ]; then
    echo "Error: failed to determine mount point for $RW_DMG" >&2
    echo "$MOUNT_OUTPUT" >&2
    exit 1
fi

echo "=> Mounted at $MOUNT_POINT — applying Finder layout..."

# Plain icon-view layout: app on the left, Applications alias on the right,
# user just drags between them. No background picture, no custom text.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 160, 740, 540}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set position of item "$APP_NAME" of container window to {135, 200}
        set position of item "Applications" of container window to {405, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
sleep 1

echo "=> Detaching writable DMG..."
hdiutil detach "$MOUNT_POINT" >/dev/null

echo "=> Refreshing dist/macos/..."
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/$APP_NAME"
rm -f "$DIST_DIR/$DMG_NAME"

echo "=> Converting to compressed read-only DMG..."
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DIST_DIR/$DMG_NAME" >/dev/null
rm -f "$RW_DMG"

echo "=> Done! $DIST_DIR/$DMG_NAME has been created."
echo "   Send only this .dmg to recipients — drag-to-Applications layout is baked in."
echo "   This is an unsigned distribution build. Users must open it through System Settings -> Privacy & Security on first launch."
