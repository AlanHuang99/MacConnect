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

# SwiftPM generates one bundle per target with declared resources. The
# MacConnectApp target's bundle holds Localizable.xcstrings; copy it
# inside the .app so Bundle.module lookups work at runtime.
# Hard-fail if the bundle is missing — runtime Text(_:bundle: .module)
# lookups crash without it (Bundle.module accessor calls fatalError on
# absence) and we'd ship a broken .app that CI still marked green.
SPM_BUNDLE="$BIN_DIR/MacConnect_MacConnectApp.bundle"
if [[ ! -d "$SPM_BUNDLE" ]]; then
  echo "ERROR: SwiftPM resource bundle not found at $SPM_BUNDLE." >&2
  echo "       Sources/MacConnectApp/Resources/ must be declared in Package.swift" >&2
  echo "       and at least one resource file present so SwiftPM emits the bundle." >&2
  exit 1
fi
cp -R "$SPM_BUNDLE" "$RES/"

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
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>Send via MacConnect</string></dict>
            <key>NSMessage</key>
            <string>sendFileToDevice</string>
            <key>NSPortName</key>
            <string>MacConnect</string>
            <key>NSSendTypes</key>
            <array><string>public.file-url</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF

echo ">> Done: $APP"
echo "Open with: open '$APP'"
