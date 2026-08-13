#!/usr/bin/env bash
# Build a polished, layout-customised MacConnect DMG.
#
# Inputs:
#   $1 — path to a built .app bundle (default: build/MacConnect.app)
#   $2 — output DMG path (default: build/MacConnect.dmg)
#   $3 — volume name (default: MacConnect)
#
# Produces a UDZO-compressed DMG that:
#   - Mounts as a Finder window with the .app on the left and an
#     Applications symlink on the right, a background image showing
#     "Drag MacConnect → Applications", and a fixed window size.
#   - Carries a custom volume icon (resources/AppIcon.icns).
#
# Signing / notarization of the .dmg itself is left to the caller (CI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_PATH="${1:-build/MacConnect.app}"
DMG_PATH="${2:-build/MacConnect.dmg}"
VOLNAME="${3:-MacConnect}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH" >&2
  exit 1
fi

# Ensure assets exist; regenerate if missing.
BG_PATH="resources/dmg-background.png"
BG2X_PATH="resources/dmg-background@2x.png"
ICON_SRC="resources/AppIcon.icns"

if [[ ! -f "$BG_PATH" ]]; then
  echo ">> Generating DMG background via scripts/make-dmg-background.swift"
  ./scripts/make-dmg-background.swift
fi
if [[ ! -f "$ICON_SRC" ]]; then
  echo "ERROR: $ICON_SRC missing; run scripts/make-icon.swift first." >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo ">> Staging contents in $STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Hidden .background folder picked up by the Finder layout AppleScript.
mkdir -p "$STAGE/.background"
cp "$BG_PATH" "$STAGE/.background/background.png"
if [[ -f "$BG2X_PATH" ]]; then
  cp "$BG2X_PATH" "$STAGE/.background/background@2x.png"
fi

# Custom volume icon. Finder picks this up automatically when the file
# is named .VolumeIcon.icns at the root of the volume.
cp "$ICON_SRC" "$STAGE/.VolumeIcon.icns"

# Build a temporary writable DMG large enough for the .app + assets.
APP_KB=$(du -sk "$APP_PATH" | awk '{print $1}')
PAD_KB=$(( APP_KB + 20480 ))   # +20 MB padding for filesystem overhead
RW_DMG="$(mktemp -u)-rw.dmg"
echo ">> Creating writable DMG ($PAD_KB KB)"
# `hdiutil create` is famously flaky on the GitHub macOS runners,
# returning "Resource busy" when Spotlight or some background daemon
# briefly holds a lock on the staging dir. Retry a handful of times
# with backoff before declaring it dead — the underlying issue is
# transient on the order of seconds.
hdiutil_create() {
  hdiutil create \
    -srcfolder "$STAGE" \
    -volname "$VOLNAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${PAD_KB}k" \
    "$RW_DMG" >/dev/null
}
attempt=1
until hdiutil_create; do
  if [[ $attempt -ge 5 ]]; then
    echo "hdiutil create failed after $attempt attempts" >&2
    exit 1
  fi
  echo "hdiutil create attempt $attempt failed; retrying in $((attempt * 2))s..." >&2
  rm -f "$RW_DMG"
  sleep $((attempt * 2))
  attempt=$((attempt + 1))
done

# Attach the writable DMG so we can apply Finder layout via AppleScript.
echo ">> Attaching to apply Finder layout"
MOUNT_POINT="$(mktemp -d)/$VOLNAME"
ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_POINT" -noautoopen -noverify)"
DMG_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk 'NR == 1 { print $1 }')"
if [[ "$DMG_DEVICE" != /dev/disk* ]]; then
  echo "Could not determine attached device from hdiutil output:" >&2
  printf '%s\n' "$ATTACH_OUTPUT" >&2
  exit 1
fi

# Mark the volume to use a custom icon (chflags + Finder reload).
# `SetFile` is part of the Xcode CLT toolchain; fall back silently if absent.
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MOUNT_POINT"
fi

# Position windows + icons via AppleScript. Window size 540×380 matches
# the background image; icon centers are pinned to the arrow's endpoints.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {200, 120, 740, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set background picture of viewOptions to file ".background:background.png"
        set position of item "MacConnect.app" of container window to {160, 200}
        set position of item "Applications" of container window to {380, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Re-block the Finder so changes flush.
sync
sleep 1

echo ">> Detaching writable DMG"
if ! DETACH_ERROR="$(hdiutil detach "$DMG_DEVICE" -quiet 2>&1)"; then
  if [[ "$DETACH_ERROR" == *"No such file or directory"* ]]; then
    echo ">> Writable DMG was already detached"
  else
    printf '%s\n' "$DETACH_ERROR" >&2
    hdiutil detach "$DMG_DEVICE" -force
  fi
fi

# Convert to compressed read-only DMG.
echo ">> Converting to UDZO"
rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG"

# Verify the final image.
hdiutil verify "$DMG_PATH" >/dev/null

echo ">> Done: $DMG_PATH"
ls -lh "$DMG_PATH"
