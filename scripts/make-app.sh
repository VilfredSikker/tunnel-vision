#!/bin/bash
# Build Anchor as a proper .app bundle (LSUIElement menu bar app, non-sandboxed).
# Usage: scripts/make-app.sh [debug|release]   (default release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="Anchor"
BUNDLE_ID="com.anchor.timer"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build --disable-sandbox -c "$CONFIG"

BIN=".build/$CONFIG/Anchor"
if [ ! -x "$BIN" ]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "Support/Info.plist" "$APP/Contents/Info.plist"

echo "==> ad-hoc codesign (stable identity for TCC later)"
codesign --force --sign - "$APP"

echo "==> verify"
codesign --verify --strict "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
LSUI=$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$APP/Contents/Info.plist")
echo "LSUIElement=$LSUI"
echo
echo "Built: $APP"
echo "Run with: open \"$APP\""
