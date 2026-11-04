#!/bin/bash
# Builds build/Parachute.app (ad-hoc signed, menu-bar only).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product Parachute
BIN="$(swift build -c release --show-bin-path)/Parachute"
APP=build/Parachute.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Parachute"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Parachute</string>
  <key>CFBundleDisplayName</key><string>Parachute</string>
  <key>CFBundleIdentifier</key><string>dev.parachute.app</string>
  <key>CFBundleExecutable</key><string>Parachute</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
codesign --verify --verbose "$APP"
echo "Built $APP"
