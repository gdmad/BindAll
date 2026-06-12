#!/bin/bash
# Build and package BindAll as a distributable .dmg.
#
# Modes:
#   ./scripts/release.sh            local build (default): signed with the dev certificate,
#                                   NOT notarized. Other Macs must allow it once via
#                                   System Settings > Privacy & Security > "Open Anyway".
#   ./scripts/release.sh --notarize Developer ID + notarization (requires a paid Apple
#                                   Developer account and a notarytool profile, see below).
#
# One-time setup for --notarize:
#   - A "Developer ID Application" certificate in the login keychain.
#   - xcrun notarytool store-credentials BindAllNotary \
#       --apple-id "you@example.com" --team-id "RR8844N29J" --password "<app-specific-password>"
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="local"
[[ "${1:-}" == "--notarize" ]] && MODE="notarize"

SCHEME="BindAll"
APP_NAME="BindAll"
TEAM_ID="RR8844N29J"
NOTARY_PROFILE="BindAllNotary"
BUILD_DIR="$(pwd)/.release"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
DMG_DIR="$BUILD_DIR/dmg"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$DMG_DIR"

echo "==> Archiving $APP_NAME $VERSION ($MODE)"
xcodebuild -scheme "$SCHEME" -configuration Release -archivePath "$ARCHIVE" archive | tail -2

if [[ "$MODE" == "notarize" ]]; then
    EXPORT_DIR="$BUILD_DIR/export"
    mkdir -p "$EXPORT_DIR"
    echo "==> Exporting (Developer ID)"
    cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
      -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -exportPath "$EXPORT_DIR" | tail -2
    APP_PATH="$EXPORT_DIR/$APP_NAME.app"
else
    # Local mode: the archived app is already signed with the development certificate.
    APP_PATH="$ARCHIVE/Products/Applications/$APP_NAME.app"
fi

echo "==> Packaging .dmg"
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

if [[ "$MODE" == "notarize" ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
fi

echo "==> Done: $DMG_PATH"