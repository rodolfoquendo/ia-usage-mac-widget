#!/usr/bin/env bash
# Builds ClaudeUsage.app -- a menu bar app showing Claude usage & limits.
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsage"
BUNDLE="$APP.app"

echo "==> Compiling (release)..."
swift build -c release

BIN=".build/release/$APP"

echo "==> Assembling $BUNDLE ..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleIdentifier</key><string>com.rodolfoquendo.claudeusage</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "==> Done: $(pwd)/$BUNDLE"
echo "    Run it:   open $BUNDLE"
echo "    Install:  cp -r $BUNDLE /Applications/"
