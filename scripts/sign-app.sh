#!/usr/bin/env bash
# Codesign MacConnect.app with Developer ID + Hardened Runtime, signing any
# embedded Sparkle.framework inside-out first so the nested XPC services and
# helpers seal correctly before the framework wrapper and then the app.
#
# Works for both channels: with no Sparkle.framework present (App Store build)
# it just signs the app with the given entitlements — same result as a plain
# codesign of the bundle.
#
# Usage:
#   ./scripts/sign-app.sh /path/to/MacConnect.app 'Developer ID Application: …' [keychain] [entitlements]
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 /path/to/MacConnect.app 'Developer ID Application: …' [keychain] [entitlements]" >&2
  exit 1
fi

APP_PATH="$1"
IDENTITY="$2"
KEYCHAIN_ARG=()
if [[ $# -ge 3 && -n "${3:-}" ]]; then
  KEYCHAIN_ARG=(--keychain "$3")
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# MacConnect is not sandboxed; the entitlements only declare network
# client/server for the LAN protocol. Sparkle needs no extra entitlements in a
# non-sandboxed app (unlike the sandboxed case, which would also need
# mach-lookup temporary exceptions + SUEnableInstallerLauncherService).
ENTITLEMENTS_ARG="${4:-resources/MacConnect.entitlements}"
case "$ENTITLEMENTS_ARG" in
  /*) ENTITLEMENTS="$ENTITLEMENTS_ARG" ;;
  *)  ENTITLEMENTS="$ROOT/$ENTITLEMENTS_ARG" ;;
esac

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Entitlements not found: $ENTITLEMENTS" >&2
  exit 1
fi

sign() {
  codesign --force --options runtime --timestamp \
    "${KEYCHAIN_ARG[@]}" \
    --sign "$IDENTITY" \
    "$@"
}

FRAMEWORKS="$APP_PATH/Contents/Frameworks"
SPARKLE="$FRAMEWORKS/Sparkle.framework"

# Sparkle (direct build) carries nested code bundles and helper executables.
# They must be re-signed inside-out, BEFORE the framework wrapper that seals
# them — a plain `find -type f` over the framework would sign bundle internals
# as loose files and break the signature / notarization.
if [[ -d "$SPARKLE" ]]; then
  V="$SPARKLE/Versions/B"
  for nested in \
    "$V/XPCServices/Downloader.xpc" \
    "$V/XPCServices/Installer.xpc" \
    "$V/Updater.app" \
    "$V/Autoupdate"; do
    [[ -e "$nested" ]] && sign "$nested"
  done
  sign "$SPARKLE"
fi

# Any other embedded frameworks / loose dylibs (none today; defensive for the
# future). Each .framework is signed as a bundle; loose dylibs individually.
if [[ -d "$FRAMEWORKS" ]]; then
  for fw in "$FRAMEWORKS"/*.framework; do
    [[ -d "$fw" && "$fw" != "$SPARKLE" ]] || continue
    sign "$fw"
  done
  while IFS= read -r -d '' dylib; do
    sign "$dylib"
  done < <(find "$FRAMEWORKS" -maxdepth 1 -type f -name '*.dylib' -print0)
fi

# The app last, with the channel entitlements. This also re-seals the main
# executable, healing the signature install_name_tool invalidated when it
# added the Frameworks rpath in build-app.sh.
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "${KEYCHAIN_ARG[@]}" \
  --sign "$IDENTITY" \
  "$APP_PATH"

# Deep verification catches a mis-ordered nested signature before notarization does.
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=4 "$APP_PATH"
