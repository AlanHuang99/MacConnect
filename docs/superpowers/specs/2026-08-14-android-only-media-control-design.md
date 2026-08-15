# Android-Only Media Control Design

Date: 2026-08-14
Release target: v0.4.2

## Goal

Make media control strictly Android to Mac, keep the Android play/pause button synchronized with the Mac's actual playback state, and make the same controls reliable on both the Redmi K60 and Note12.

## Confirmed runtime evidence

- MacConnect v0.4.1 is connected to the K60 (`23013RK75C`, KDE Connect 1.35.11) and Note12 (`23049RAD8C`, KDE Connect 1.35.13) on the same LAN.
- Both phones receive the same elected Mac player, track, volume, and `isPlaying` state.
- A K60 play/pause tap reaches MacConnect as `kdeconnect.mpris.request` and changes the elected Mac session.
- The Note12 displays an enabled play/pause control, but repeated touch and keyboard activation produced no MPRIS request at the Mac.
- MacConnect replaces the secure channel for each phone approximately every five seconds when the phone responds to the repeated identity broadcast.
- The Note12 UI starts changing between the play triangle and pause bars when a K60 command changes the Mac state, proving its rendering path is driven correctly by incoming `isPlaying` packets.

The evidence supports a stale Android controller binding caused by repeated link replacement as the Note12 failure mechanism. The implementation will validate that diagnosis by keeping the established secure channel and repeating the same hardware test.

## Scope

- Advertise only the MPRIS directions needed for Android to control the Mac:
  - incoming: `kdeconnect.mpris.request`
  - outgoing: `kdeconnect.mpris`
- Remove the remote phone player tile, playback buttons, and media-volume slider from the Mac popover.
- Remove Mac-initiated phone player-list, now-playing, transport, and media-volume requests.
- Remove the remote MPRIS cache because no Mac UI consumes phone media state.
- Remove MPRIS as a liveness probe. Battery remains the silent probe for Android phones that advertise it; peers without battery use the existing announcement and hard-TTL path.
- Keep an active secure same-device channel when a duplicate candidate arrives. Reject and close the candidate before TLS instead of replacing the active link.
- Continue sending the elected Mac player list and state when Android connects or requests it.
- Continue broadcasting each real Mac playback-state change to every paired, reachable, MPRIS-enabled Android controller.
- Verify play, pause, previous, next, system volume, and button-state changes on both phones.
- Publish the result as v0.4.2 after local, hardware, pull-request, main-branch, signing, notarization, release-asset, and appcast verification.

## Non-goals

- Changing or rebuilding KDE Connect Android.
- Adding a Mac media-app picker or enumerating simultaneous Mac media sessions.
- Optimistically changing Android playback state before the Mac reports the actual state.
- Adding seek, queue, playlist, album-art transfer, or track-selection features.
- Removing unrelated Mac-to-phone functions such as file sending, clipboard push, ping, or Find My Phone.
- Changing the Android system-volume protocol. Android remains able to control the Mac's current output volume and mute state.
- Repairing unrelated discovery-listener diagnostics unless the focused channel-stability change fails to restore Note12 control.

## Architecture and data flow

### Android to Mac media path

1. MacConnect advertises that it accepts `kdeconnect.mpris.request` and produces `kdeconnect.mpris`.
2. KDE Connect Android requests the player list and state.
3. `MprisPlugin` delegates the request to `LocalMprisService` and sends the response to the requesting phone.
4. Android sends Play, Pause, PlayPause, Previous, Next, or volume operations for the elected player.
5. `LocalMprisService` validates the player and forwards the operation to `SystemLocalMediaController`.
6. The macOS media and Core Audio bridges change the elected system session or output volume.
7. The existing controller refresh reports the actual new state.
8. `MprisPlugin` broadcasts that state to every eligible phone, which makes each Android play/pause button render the correct icon.

Incoming `kdeconnect.mpris` phone-player state is no longer advertised, stored, queried, or shown on the Mac.

### Duplicate channel policy

`LanLink` will decide whether a candidate channel may replace its active channel:

- Same channel object: no operation.
- Active and secure current channel: reject the candidate and preserve the current channel and secure flag.
- Insecure or inactive current channel: adopt the candidate, reset the secure flag, and return the old channel for deferred closure.

`LanLinkProvider` will update channel maps only after a candidate is adopted. Both rejected candidates and superseded channels are closed outside the provider lock, preserving the existing deadlock protection.

The existing host-change, transport-close, TCP keepalive, liveness, and rediscovery mechanisms remain responsible for replacing genuinely dead or moved links.

## User interface

The Mac device row retains pairing, status, battery, file, clipboard, ping, Find My Phone, transfer progress, and trust controls. It no longer shows any phone now-playing title, phone transport buttons, or phone media-volume slider.

The Android UI is unchanged. Its existing central control renders:

- a play triangle when MacConnect reports `isPlaying: false`, including paused or stopped state;
- pause bars when MacConnect reports `isPlaying: true`.

## Error handling and recovery

- Requests for an unknown player continue returning the current player list without executing a command.
- Malformed actions and volume values remain no-ops or are clamped by the existing service behavior.
- A phone that does not advertise the controller capabilities receives no local media state.
- A rejected duplicate channel has no provider mapping, so its close callback cannot detach the active device.
- A current channel that is inactive or not yet secure can still be replaced immediately.
- Battery-capable Android phones remain probed after quiet periods. Peers without battery use the established announcement and hard-TTL recovery path.

## Testing

Test-first changes will cover:

- exact one-way MPRIS capability arrays;
- Android requests still receive the Mac player list and state;
- incoming phone-player state produces no cache or follow-up request;
- a Mac state change is sent to two eligible phones and contains the new `isPlaying` value;
- MPRIS is no longer selected or sent as a liveness probe;
- a secure active `LanLink` rejects a duplicate candidate without changing the active channel or secure flag;
- insecure and inactive links still adopt replacement candidates;
- provider closures remain outside the provider lock.

Hardware verification will use both authorized Wi-Fi ADB devices. Each phone must independently issue play, pause, previous, next, and volume operations. After each playback transition, both phones must show the same player and the correct central play/pause icon. Mac logs must show commands from both device names without five-second secure-link replacement churn.

## Release

The changelog will receive a v0.4.2 entry dated 2026-08-14. After the implementation pull request and exact merge-commit CI pass, tag v0.4.2 on the verified `main` commit. The existing release workflow will build, sign, notarize, staple, package, publish, and add the signed Sparkle appcast entry.
