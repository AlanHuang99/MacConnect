# Previous and Next Media Controls Design

Date: 2026-08-13
Release target: v0.4.1

## Goal

Let KDE Connect Android invoke Previous and Next on the Mac's currently elected system media session, alongside the Play, Pause, and Play-Pause operations released in v0.4.0.

## Scope

- Add Previous and Next commands to the local media-control abstraction.
- Route Android MPRIS `Previous` and `Next` action requests to those commands.
- Send the corresponding MediaRemote commands to the elected Mac player.
- Advertise `canGoPrevious` and `canGoNext` while a Mac media session is active so KDE Connect Android enables the buttons.
- Preserve the existing MacConnect popover controls for remote Android players.
- Validate both operations on the K60 against available Mac media applications, with Music as the primary deterministic target and IINA checked where its current media supports playlist navigation.
- Publish the completed change as v0.4.1 after local verification and GitHub CI pass.

## Non-goals

- Enumerating or selecting among multiple simultaneous Mac media applications.
- Discovering application-specific Previous or Next capability through additional private APIs.
- Synthesizing keyboard media keys as a fallback.
- Adding seek, queue, playlist, or track-selection UI.
- Changing the Android application.

## Architecture and data flow

The existing local MPRIS request pipeline remains unchanged in shape:

1. KDE Connect Android sends an MPRIS request for the elected Mac player.
2. `MprisPlugin` passes the request to `LocalMprisService`.
3. `LocalMprisService` validates the player identity and maps `action: "Previous"` or `action: "Next"` to `LocalMediaControlling`.
4. `SystemLocalMediaController` forwards the operation to `MediaRemoteControlling`.
5. `MediaRemoteBridge` sends the matching system MediaRemote command to the elected session.
6. The existing refresh path republishes updated metadata and playback state to Android.

No new plugin, packet type, process, permission, or UI surface is required.

## Capability behavior

When an elected Mac media session is available, the local MPRIS state packet reports both `canGoPrevious` and `canGoNext` as true. This matches the bridge's current behavior for Play and Pause: availability indicates that MacConnect can dispatch the system command, not that every receiving application guarantees an effect.

When no media session is available, MacConnect advertises no local MPRIS player, so there are no enabled transport controls.

## Error handling

- Requests for an unknown or stale player name remain ignored and return the current player list.
- Missing or malformed actions remain no-ops.
- MediaRemote command rejection is logged through the existing error path.
- A player that does not implement Previous or Next may ignore the system command without affecting connection state or other controls.

## Testing

Unit tests will first fail for the absent behavior, then cover:

- `LocalMprisService` routes Previous and Next for the elected player.
- The local MPRIS state advertises `canGoPrevious` and `canGoNext` when transport is available.
- `SystemLocalMediaController` forwards Previous and Next to its media bridge.
- Existing Play, Pause, Play-Pause, volume, mute, and remote-player behavior remains unchanged.

Verification will include the complete Swift test suite, debug and release builds, strict SwiftLint, SwiftFormat lint, universal direct-channel bundle checks, K60 hardware commands, GitHub pull-request CI, merge-commit CI, Developer ID signing, Apple notarization, release asset publication, and Sparkle appcast verification.

## Release

The changelog will receive a v0.4.1 entry dated 2026-08-13. After the implementation PR and merge-commit CI pass, tag v0.4.1 on the verified `main` commit. The existing release workflow will produce and publish the notarized universal DMG and ZIP and update the signed Sparkle appcast.
