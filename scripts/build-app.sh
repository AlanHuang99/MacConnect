#!/usr/bin/env bash
# Build MacConnect.app bundle from the Swift Package executable.
# Usage: ./scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo ">> Building macconnect ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/macconnect"
APP="$ROOT/build/MacConnect.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo ">> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN_PATH" "$MACOS/MacConnect"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacConnect</string>
    <key>CFBundleDisplayName</key><string>MacConnect</string>
    <key>CFBundleIdentifier</key><string>org.macconnect.MacConnect</string>
    <key>CFBundleExecutable</key><string>MacConnect</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MacConnect discovers KDE Connect devices on your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_kdeconnect._udp</string></array>
</dict>
</plist>
EOF

echo ">> Done: $APP"
echo "Open with: open '$APP'"
