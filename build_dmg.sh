#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist/macos}"
XCODE_SWIFT_OPTIMIZATION_LEVEL="${XCODE_SWIFT_OPTIMIZATION_LEVEL:-}"
XCODE_SWIFT_COMPILATION_MODE="${XCODE_SWIFT_COMPILATION_MODE:-}"
XCODE_ENABLE_PREVIEWS="${XCODE_ENABLE_PREVIEWS:-}"

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

# Find the built .app
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/GeoTeleportMacV3.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/GeoTeleportMacV3"

if [ ! -x "$APP_EXECUTABLE" ]; then
    echo "Error: Release build of GeoTeleportMacV3.app not found."
    exit 1
fi

echo "=> Found App: $APP_PATH"

echo "=> Preparing DMG staging directory..."
DMG_STAGING="$ROOT_DIR/build/dmg_staging_macos"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Copy the app to the staging directory
cp -R "$APP_PATH" "$DMG_STAGING/"
cp -R "$APP_PATH" "$DIST_DIR/"

# Add a shortcut to the Applications folder
ln -s /Applications "$DMG_STAGING/Applications"

echo "=> Creating dist/macos/GeoTeleportMacV3.dmg..."
DMG_PATH="$DIST_DIR/GeoTeleportMacV3.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "GeoTeleportMacV3" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" > /dev/null
rm -rf "$DMG_STAGING"
rm -rf "$APP_PATH"
rm -rf "$DERIVED_DATA_PATH/Build/Products/Release/GeoTeleportMacV3.app.dSYM"

echo "=> Done! macOS release artifacts are in:"
echo "   $DIST_DIR"
echo "   This is an unsigned distribution build. Users must open it through System Settings -> Privacy & Security on first launch."
