#!/usr/bin/env bash
# Build a MacConnect.app bundle from the Swift Package executable.
#
# Usage:
#   ./scripts/build-app.sh                                   # release, host arch, App Store channel
#   ./scripts/build-app.sh release                           # release, host arch
#   ./scripts/build-app.sh release-universal                 # release, arm64+x86_64
#   ./scripts/build-app.sh release-universal 0.1.0           # also stamp version
#   ./scripts/build-app.sh release-universal 0.1.0 direct    # link Sparkle (in-app updates)
#
# Channels (third argument):
#   appstore (default) — Sparkle-free. The future Mac App Store build; the
#                        store delivers updates, and Apple rejects bundled
#                        Sparkle. No update UI is shown.
#   direct             — links Sparkle, embeds Sparkle.framework, and writes
#                        the SUFeedURL / SUPublicEDKey Info.plist keys. For
#                        GitHub Releases. See README "Distribution channels".
set -euo pipefail

CONFIG="${1:-release}"
VERSION="${2:-0.1.0-dev}"
CHANNEL="${3:-appstore}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Sparkle's appcast feed and the EdDSA public key that verifies updates. The
# public key is NOT secret (the matching private key is the GitHub Actions
# secret SPARKLE_ED_PRIVATE_KEY). Generate the pair once with Sparkle's
# `generate_keys` and replace the placeholder — see the README. Both can
# be overridden from the environment for local update testing.
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://alanhuang99.github.io/MacConnect/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-REPLACE_WITH_ED25519_PUBLIC_KEY}"

case "$CHANNEL" in
  direct)
    echo ">> Channel: direct (Sparkle in-app updates)"
    export MACCONNECT_SPARKLE=1
    ;;
  appstore)
    echo ">> Channel: appstore (Sparkle-free)"
    unset MACCONNECT_SPARKLE || true
    ;;
  *)
    echo "Unknown channel: $CHANNEL" >&2
    echo "Valid: appstore | direct" >&2
    exit 1
    ;;
esac

case "$CONFIG" in
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
    echo "Valid: debug | release | release-universal" >&2
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
FRAMEWORKS="$CONTENTS/Frameworks"

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

# Direct channel: embed Sparkle.framework next to the binary and teach the
# binary to find it at @executable_path/../Frameworks. SwiftPM links
# @rpath/Sparkle.framework but only adds an @loader_path rpath (valid in the
# build dir, where binary and framework sit together); once relocated into the
# .app the loader needs the Frameworks rpath. Inside-out codesigning of the
# framework's nested XPC services / helpers happens later, in scripts/sign-app.sh.
SPARKLE_PLIST_KEYS=""
if [[ "$CHANNEL" == "direct" ]]; then
  SPARKLE_FW="$BIN_DIR/Sparkle.framework"
  if [[ ! -d "$SPARKLE_FW" ]]; then
    echo "ERROR: Sparkle.framework not found at $SPARKLE_FW." >&2
    echo "       The direct channel must build with MACCONNECT_SPARKLE=1 so SwiftPM" >&2
    echo "       resolves and copies the Sparkle binary framework." >&2
    exit 1
  fi
  mkdir -p "$FRAMEWORKS"
  # -R preserves the Versions/Current symlink farm Sparkle ships; cp without it
  # would dereference symlinks and break the framework layout / signature.
  cp -R "$SPARKLE_FW" "$FRAMEWORKS/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/MacConnect"
  echo ">> Embedded Sparkle.framework and added Frameworks rpath"
  if [[ "$SPARKLE_PUBLIC_ED_KEY" == "REPLACE_WITH_ED25519_PUBLIC_KEY" ]]; then
    echo "::warning:: SUPublicEDKey is the placeholder. Generate a key pair (see" >&2
    echo "            the README) before shipping — updates won't verify otherwise." >&2
  fi
  SPARKLE_PLIST_KEYS="
    <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key><false/>"
fi

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
    <array><string>_kdeconnect._udp</string></array>${SPARKLE_PLIST_KEYS}
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
