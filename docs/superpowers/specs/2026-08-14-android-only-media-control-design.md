# Android-Only Media Control Design

Date: 2026-08-14
Release target: v0.4.2

## Goal

Make media control strictly Android to Mac, keep the Android play/pause button synchronized with the Mac's actual playback state, show the current Mac track artwork in Android's multimedia screen when macOS provides it, and make the same controls reliable on both the Redmi K60 and Note12.

## Confirmed runtime evidence

- MacConnect v0.4.1 is connected to the K60 (`23013RK75C`, KDE Connect 1.35.11) and Note12 (`23049RAD8C`, KDE Connect 1.35.13) on the same LAN.
- Both phones receive the same elected Mac player, track, volume, and `isPlaying` state.
- A K60 play/pause tap reaches MacConnect as `kdeconnect.mpris.request` and changes the elected Mac session.
- The Note12 displays an enabled play/pause control, but repeated touch and keyboard activation produced no MPRIS request at the Mac.
- MacConnect v0.4.1 replaces the channel before the candidate TLS handshake finishes approximately every five seconds when a phone responds to the repeated identity broadcast.
- The Note12 UI starts changing between the play triangle and pause bars when a K60 command changes the Mac state, proving its rendering path is driven correctly by incoming `isPlaying` packets.
- Hardware testing of the first v0.4.2 candidate proved that rejecting every duplicate before TLS is also incorrect: Android logs a failed handshake every five seconds, both controllers become silent, and the preserved Mac socket is eventually dropped by liveness reconciliation.
- KDE Connect Android completes TLS before resetting its existing `LanLink`. MacConnect must match that lifecycle by keeping the current secure link available during the candidate handshake, then promoting only the latest successfully secured candidate.
- The first v0.4.2 candidate also delivered no artwork URL even though a separate MediaRemote probe returned valid JPEG/PNG bytes. Artwork acquisition and metadata must be merged atomically inside the branch process before state fan-out.
- Hardware testing after the atomic merge proved that MediaRemote can omit the artwork callback entirely. An unbounded wait then prevents even valid metadata from becoming available, so Android reports `No players found` and cannot emit transport actions. Artwork acquisition must have a short cancellation-safe deadline; metadata remains authoritative and publishes with a placeholder when that deadline expires.

The evidence rules out both pre-TLS replacement and pre-TLS rejection. The corrected design is post-TLS promotion: never interrupt the active channel for an unverified candidate, never fail Android's candidate handshake merely because an active channel exists, and switch only after the candidate is secure.

## Scope

- Advertise only the MPRIS directions needed for Android to control the Mac:
  - incoming: `kdeconnect.mpris.request`
  - outgoing: `kdeconnect.mpris`
- Remove the remote phone player tile, playback buttons, and media-volume slider from the Mac popover.
- Remove Mac-initiated phone player-list, now-playing, transport, and media-volume requests.
- Remove the remote MPRIS cache because no Mac UI consumes phone media state.
- Remove MPRIS as a liveness probe. Battery remains the silent probe for Android phones that advertise it; peers without battery use the existing announcement and hard-TTL path.
- Keep an active secure same-device channel while the newest duplicate candidate completes TLS. Promote the candidate only after a successful handshake, then close the superseded channel outside provider locks.
- Continue sending the elected Mac player list and state when Android connects or requests it.
- Continue broadcasting each real Mac playback-state change to every paired, reachable, MPRIS-enabled Android controller.
- Advertise native MPRIS album-art payload support, include a stable `kdeconnect://` artwork URL in Mac state, and transfer only the matching current artwork when Android requests it.
- Verify play, pause, previous, next, system volume, and button-state changes on both phones.
- Verify the Android music-note placeholder changes to the current Mac track cover on both phones when artwork is available, and falls back cleanly when it is not.
- Publish the result as v0.4.2 after local, hardware, pull-request, main-branch, signing, notarization, release-asset, and appcast verification.

## Non-goals

- Changing or rebuilding KDE Connect Android.
- Adding a Mac media-app picker or enumerating simultaneous Mac media sessions.
- Optimistically changing Android playback state before the Mac reports the actual state.
- Adding seek, queue, playlist, or track-selection features.
- Adding an HTTP server, external artwork lookup, artwork scraping, or Android application changes.
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

### Mac artwork to Android

1. `MediaRemoteBridge` obtains the current artwork bytes using MediaRemote's artwork callback in addition to the existing metadata read.
2. `SystemLocalMediaController` exposes the optional bytes with the local snapshot.
3. `LocalMprisService` derives a stable content-addressed `kdeconnect://macconnect/album-art/...` URL, advertises `supportAlbumArtPayload: true`, and includes `albumArtUrl` only when valid artwork is available.
4. KDE Connect Android displays its existing placeholder immediately, then requests the advertised URL through `kdeconnect.mpris.request` if it is not cached.
5. `MprisPlugin` accepts an artwork request only when its player and URL exactly match the current snapshot.
6. The existing TLS payload transport sends a temporary, bounded artwork file in a `kdeconnect.mpris` packet marked `transferringAlbumArt: true`.
7. Android caches and renders the image. The temporary Mac file is removed after success, failure, or a failed control-packet send.

Artwork remains strictly Mac to Android state. It does not restore phone-media state or controls on the Mac. Payloads are capped at 5 MiB to match KDE Connect's cache boundary, empty or oversized images are omitted, and a track without artwork continues using Android's music-note placeholder.

### Duplicate channel policy

`LanLinkProvider` stages at most one pending candidate per device while the existing `LanLink` remains active:

- The newest identity-bearing candidate replaces only an older pending candidate, never the active secure channel.
- A pending close or failed handshake removes only that pending candidate and cannot detach the active device.
- A handshake completion promotes the channel only if it is still the newest pending candidate.
- Promotion atomically swaps the active channel with `isSecure: true`, updates provider maps, and returns the superseded channel for deferred closure.
- A late handshake from an older candidate is stale and is closed without changing the active link.

Pending-candidate and active-channel maps are changed under the provider lock. Older pending candidates, stale secured candidates, and superseded active channels are always closed after releasing the lock, preserving the existing deadlock protection. This mirrors KDE Connect Android's own order: handshake first, link reset second.

The existing host-change, transport-close, TCP keepalive, liveness, and rediscovery mechanisms remain responsible for replacing genuinely dead or moved links.

## User interface

The Mac device row retains pairing, status, battery, file, clipboard, ping, Find My Phone, transfer progress, and trust controls. It no longer shows any phone now-playing title, phone transport buttons, or phone media-volume slider.

The Android UI is unchanged. Its existing central control renders:

- a play triangle when MacConnect reports `isPlaying: false`, including paused or stopped state;
- pause bars when MacConnect reports `isPlaying: true`.

Its existing cover surface renders the current Mac track artwork after the native KDE Connect payload arrives. Until then, or when macOS supplies no valid artwork, it keeps the existing music-note placeholder.

## Error handling and recovery

- Requests for an unknown player continue returning the current player list without executing a command.
- Malformed actions and volume values remain no-ops or are clamped by the existing service behavior.
- A phone that does not advertise the controller capabilities receives no local media state.
- An artwork request for a stale player or URL is ignored, preventing a previous track's cover from being sent after the song changes.
- Empty, unreadable, or larger-than-5-MiB artwork is omitted and never opens a payload listener.
- An artwork callback that misses its deadline is treated as no artwork for that refresh. Its late result is ignored, metadata still publishes, and the next polling iteration continues.
- A failed artwork control-packet send aborts the one-shot payload listener and removes its temporary file.
- A failed or superseded pending channel cannot detach the active device.
- Only the latest successfully secured candidate can replace the active channel.
- Battery-capable Android phones remain probed after quiet periods. Peers without battery use the established announcement and hard-TTL recovery path.

## Testing

Test-first changes will cover:

- exact one-way MPRIS capability arrays;
- Android requests still receive the Mac player list and state;
- incoming phone-player state produces no cache or follow-up request;
- a Mac state change is sent to two eligible phones and contains the new `isPlaying` value;
- artwork data produces a stable allowed-scheme `albumArtUrl`, while absent or oversized data produces no URL;
- only a request matching the current player and artwork URL creates a bounded native album-art transfer packet;
- artwork acquisition failures leave media transport and metadata available;
- a missing artwork callback times out without blocking metadata, late completion, cancellation, or the next refresh;
- MPRIS is no longer selected or sent as a liveness probe;
- a secure active `LanLink` remains sendable while a duplicate candidate handshakes;
- only the latest secured candidate is promoted, with the previous channel closed after the provider lock is released;
- a failed, closed, or stale pending candidate leaves the active channel and reachability untouched;
- provider closures remain outside the provider lock.

Hardware verification will use both authorized Wi-Fi ADB devices. Each phone must independently issue play, pause, previous, next, and volume operations. After each playback transition, both phones must show the same player and the correct central play/pause icon. With a track that exposes artwork, both phones must replace the music-note placeholder with the same cover. Mac logs must show commands from both device names without five-second secure-link replacement churn.

## Release

The changelog will receive a v0.4.2 entry dated 2026-08-14. After the implementation pull request and exact merge-commit CI pass, tag v0.4.2 on the verified `main` commit. The existing release workflow will build, sign, notarize, staple, package, publish, and add the signed Sparkle appcast entry.
