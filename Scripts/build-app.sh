#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

"$PROJECT_DIR/Scripts/swift.sh" build -c release --product WebTime
"$PROJECT_DIR/Scripts/swift.sh" build -c release --product webtimed
BIN_DIR="$("$PROJECT_DIR/Scripts/swift.sh" build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/.build/Web Time.app"
STAGE_DIR="$PROJECT_DIR/.build/installer"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$STAGE_DIR"
cp "$BIN_DIR/WebTime" "$APP_DIR/Contents/MacOS/WebTime"
cp "$BIN_DIR/webtimed" "$STAGE_DIR/webtimed"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/README.md" "$APP_DIR/Contents/Resources/README.md"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE.txt"
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
echo "Helper: $STAGE_DIR/webtimed"
