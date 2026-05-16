#!/usr/bin/env bash
# Build a MacConnect.app bundle from the Swift Package executable.
#
# Usage:
#   ./scripts/build-app.sh                                # debug, host arch
#   ./scripts/build-app.sh release                        # release, host arch
#   ./scripts/build-app.sh release-arm64                  # release, Apple Silicon only
#   ./scripts/build-app.sh release-universal              # release, arm64+x86_64
#   ./scripts/build-app.sh release-universal 0.1.0        # also stamp version
set -euo pipefail

CONFIG="${1:-release}"
VERSION="${2:-0.1.0-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

case "$CONFIG" in
  release-arm64)
    echo ">> Building macconnect (release, arm64)"
    swift build -c release --arch arm64
    BIN_DIR="$(swift build --show-bin-path -c release --arch arm64)"
    ;;
  release-universal)
    echo ">> Building macconnect (release, universal arm64+x86_64)"
    swift build -c release --arch arm64 --arch x86_64
    BIN_DIR="$(swift build --show-bin-path -c release --arch arm64 --arch x86_64)"
    ;;
  release|debug)
    echo ">> Building macconnect ($CONFIG, host arch)"
    swift build -c "$CONFIG"
    BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
    ;;
  *)
    echo "Unknown config: $CONFIG" >&2
    echo "Valid: debug | release | release-arm64 | release-universal" >&2
    exit 1
    ;;
esac

BIN_PATH="$BIN_DIR/macconnect"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Binary not found at $BIN_PATH" >&2
  exit 1
fi

APP="$ROOT/build/MacConnect.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo ">> Assembling $APP (version $VERSION)"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN_PATH" "$MACOS/MacConnect"

ICON_SRC="$ROOT/resources/AppIcon.icns"
if [[ ! -f "$ICON_SRC" ]]; then
  echo ">> Icon not found; generating via scripts/make-icon.swift"
  (cd "$ROOT" && ./scripts/make-icon.swift)
fi
cp "$ICON_SRC" "$RES/AppIcon.icns"

YEAR="$(date +%Y)"
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacConnect</string>
    <key>CFBundleDisplayName</key><string>MacConnect</string>
    <key>CFBundleIdentifier</key><string>org.macconnect.MacConnect</string>
    <key>CFBundleExecutable</key><string>MacConnect</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>© ${YEAR} MacConnect contributors. GPL-3.0-or-later.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MacConnect discovers KDE Connect devices on your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_kdeconnect._udp</string></array>
</dict>
</plist>
EOF

echo ">> Done: $APP"
echo "Open with: open '$APP'"
