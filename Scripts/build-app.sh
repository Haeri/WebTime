#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

"$PROJECT_DIR/Scripts/swift.sh" build -c release --product WebTime
"$PROJECT_DIR/Scripts/swift.sh" build -c release --product webtimed
"$PROJECT_DIR/Scripts/swift.sh" build -c release --product WebTimeSetup
BIN_DIR="$("$PROJECT_DIR/Scripts/swift.sh" build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/.build/Web Time.app"
SETUP_APP_DIR="$PROJECT_DIR/.build/Web Time Setup.app"
STAGE_DIR="$PROJECT_DIR/.build/installer"

rm -rf "$APP_DIR" "$SETUP_APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$STAGE_DIR"
cp "$BIN_DIR/WebTime" "$APP_DIR/Contents/MacOS/WebTime"
cp "$BIN_DIR/webtimed" "$STAGE_DIR/webtimed"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/README.md" "$APP_DIR/Contents/Resources/README.md"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE.txt"
codesign --force --deep --sign - "$APP_DIR"

PAYLOAD_DIR="$SETUP_APP_DIR/Contents/Resources/Payload"
mkdir -p \
    "$SETUP_APP_DIR/Contents/MacOS" \
    "$SETUP_APP_DIR/Contents/Resources" \
    "$PAYLOAD_DIR/.build/installer" \
    "$PAYLOAD_DIR/Resources" \
    "$PAYLOAD_DIR/Scripts"
cp "$BIN_DIR/WebTimeSetup" "$SETUP_APP_DIR/Contents/MacOS/WebTimeSetup"
cp "$PROJECT_DIR/Resources/Info.plist" "$SETUP_APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable WebTimeSetup" "$SETUP_APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.web-time.setup" "$SETUP_APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Web Time Setup" "$SETUP_APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$SETUP_APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$SETUP_APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Scripts/authorized-action.sh" "$SETUP_APP_DIR/Contents/Resources/authorized-action.sh"
ditto "$APP_DIR" "$PAYLOAD_DIR/.build/Web Time.app"
cp "$STAGE_DIR/webtimed" "$PAYLOAD_DIR/.build/installer/webtimed"
cp "$PROJECT_DIR/Resources/local.web-time.agent.plist" "$PAYLOAD_DIR/Resources/"
cp "$PROJECT_DIR/Resources/local.web-time.daemon.plist" "$PAYLOAD_DIR/Resources/"
cp "$PROJECT_DIR/Scripts/install.sh" "$PAYLOAD_DIR/Scripts/install.sh"
cp "$PROJECT_DIR/Scripts/uninstall.sh" "$PAYLOAD_DIR/Scripts/uninstall.sh"
chmod 755 \
    "$SETUP_APP_DIR/Contents/Resources/authorized-action.sh" \
    "$PAYLOAD_DIR/Scripts/install.sh" \
    "$PAYLOAD_DIR/Scripts/uninstall.sh"
codesign --force --deep --sign - "$SETUP_APP_DIR"

echo "Built: $APP_DIR"
echo "Helper: $STAGE_DIR/webtimed"
echo "Setup: $SETUP_APP_DIR"
