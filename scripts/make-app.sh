#!/bin/bash
# Build Tunnel Vision as a proper .app bundle (LSUIElement menu bar app, non-sandboxed).
# Usage: scripts/make-app.sh [debug|release]   (default release)
#
# Signing. TCC (Accessibility, Automation, Screen Recording) keys every grant
# to the app's designated code requirement. An ad-hoc signature has no
# certificate, so its requirement is a bare cdhash that changes with every
# build: the toggle in System Settings stays on, but AXIsProcessTrusted()
# says no and tccd logs "Failed to match existing code requirement". A
# certificate-backed signature keeps one requirement across builds.
#
# Identity, in order: $CODESIGN_IDENTITY (a name or SHA-1 from
# `security find-identity -v -p codesigning`), else the first "Developer ID
# Application", "Apple Development" or "Mac Developer" certificate in the
# keychain, else ad-hoc. Xcode > Settings > Accounts > Manage Certificates
# creates an Apple Development certificate for any developer account.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="TunnelVision"
BUNDLE_ID="com.tunnelvision.timer"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

IDENTITY="-"
IDENTITY_NAME="ad-hoc"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  IDENTITY="$CODESIGN_IDENTITY"
  IDENTITY_NAME="$CODESIGN_IDENTITY"
else
  IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
  for KIND in "Developer ID Application" "Apple Development" "Mac Developer"; do
    LINE=$(printf '%s\n' "$IDENTITIES" | grep -F "\"$KIND" | head -n1 || true)
    if [ -n "$LINE" ]; then
      IDENTITY=$(printf '%s' "$LINE" | sed -E 's/^[[:space:]]*[0-9]+\) ([0-9A-Fa-f]+) .*$/\1/')
      IDENTITY_NAME=$(printf '%s' "$LINE" | sed -E 's/^[^"]*"(.*)"[[:space:]]*$/\1/')
      break
    fi
  done
fi

echo "==> swift build -c $CONFIG"
swift build --disable-sandbox -c "$CONFIG"

BIN=".build/$CONFIG/TunnelVision"
MCP_BIN=".build/$CONFIG/tunnelvision-mcp"
for B in "$BIN" "$MCP_BIN"; do
  if [ ! -x "$B" ]; then
    echo "error: binary not found at $B" >&2
    exit 1
  fi
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# The MCP server rides along as a helper; register it with
#   claude mcp add tunnelvision -- "$PWD/$APP/Contents/Helpers/tunnelvision-mcp"
cp "$MCP_BIN" "$APP/Contents/Helpers/tunnelvision-mcp"
cp "Support/Info.plist" "$APP/Contents/Info.plist"

if [ "$IDENTITY" = "-" ]; then
  echo "==> ad-hoc codesign: no code-signing certificate found."
  echo "    Accessibility and Automation grants will not survive the next rebuild."
  echo "    Create one in Xcode > Settings > Accounts > Manage Certificates (Apple Development),"
  echo "    or set CODESIGN_IDENTITY to an identity from: security find-identity -v -p codesigning"
else
  echo "==> codesign with identity: $IDENTITY_NAME"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Helpers/tunnelvision-mcp"
codesign --force --sign "$IDENTITY" "$APP"

echo "==> verify"
codesign --verify --strict "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
LSUI=$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$APP/Contents/Info.plist")
echo "LSUIElement=$LSUI"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /designated requirement: /p'

# TCC keeps the requirement it saw when the user granted access. A different
# signature than last build (or any ad-hoc rebuild) means those grants no
# longer match and have to be redone once.
STAMP="$BUILD_DIR/.codesign-identity"
PREVIOUS=$(cat "$STAMP" 2>/dev/null || true)
printf '%s\n' "$IDENTITY" > "$STAMP"
if [ "$IDENTITY" = "-" ] || [ "$PREVIOUS" != "$IDENTITY" ]; then
  echo
  echo "Signature differs from the last build: grants made under the old one no longer match."
  echo "Redo them once after launching: remove Tunnel Vision from System Settings > Privacy & Security >"
  echo "Accessibility and add it back, or run:"
  echo "  tccutil reset Accessibility $BUNDLE_ID && tccutil reset AppleEvents $BUNDLE_ID"
fi

echo
echo "Built: $APP"
echo "Run with: open \"$APP\""
echo "MCP server: $APP/Contents/Helpers/tunnelvision-mcp  (make mcp-register adds it to Claude Code)"
