#!/bin/bash

set -e

echo "=> Building native-device-core (Release)..."
cd native-device-core
cargo build --release
cd ..

echo "=> Building GeoTeleportMac (Release)..."
xcodebuild -project GeoTeleportMac.xcodeproj -scheme GeoTeleportMac -configuration Release build -quiet

# Find the built .app
APP_EXECUTABLE=$(find ~/Library/Developer/Xcode/DerivedData -name "GeoTeleportMacV3" -path "*/Build/Products/Release/GeoTeleportMacV3.app/Contents/MacOS/GeoTeleportMacV3" | head -1)

if [ -z "$APP_EXECUTABLE" ]; then
    echo "Error: Release build of GeoTeleportMacV3.app not found."
    exit 1
fi

APP_PATH=$(dirname "$(dirname "$(dirname "$APP_EXECUTABLE")")")
echo "=> Found App: $APP_PATH"

echo "=> Preparing DMG staging directory..."
DMG_STAGING="build/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy the app to the staging directory
cp -R "$APP_PATH" "$DMG_STAGING/"

# Add a shortcut to the Applications folder
ln -s /Applications "$DMG_STAGING/Applications"

echo "=> Creating GeoTeleportMacV3.dmg..."
DMG_NAME="GeoTeleportMacV3.dmg"
rm -f "$DMG_NAME"
hdiutil create -volname "GeoTeleportMacV3" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_NAME" > /dev/null

echo "=> Done! $DMG_NAME has been created in the project root."
echo "   This is an unsigned distribution build. Users must open it through System Settings -> Privacy & Security on first launch."
