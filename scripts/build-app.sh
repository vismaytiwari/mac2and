#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Mac2And.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp ".build/release/Mac2And" "$MACOS/Mac2And"
cp "Sources/Mac2And/Resources/icon.icns" "$RESOURCES/icon.icns"

RESOURCE_BUNDLE="$(find .build -path '*Mac2And_Mac2And.bundle' -type d | head -1)"
if [[ -n "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES/"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Mac2And</string>
  <key>CFBundleIdentifier</key>
  <string>com.personal.mac2and</string>
  <key>CFBundleName</key>
  <string>Mac2And</string>
  <key>CFBundleDisplayName</key>
  <string>Mac2And</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.0.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>CFBundleIconFile</key>
  <string>icon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Mac2And can type clipboard text into the focused app when you request Slow Type.</string>
</dict>
</plist>
PLIST

echo "Built $APP"
