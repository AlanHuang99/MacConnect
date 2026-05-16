# MacConnect

A KDE Connect client for macOS, written in Swift, AppKit, and SwiftUI. It speaks the KDE Connect LAN protocol and interoperates with KDE Connect on Android, Linux, and Windows.

## Status

Working features:

- UDP discovery on port 1716, with subnet-directed broadcasts on every active IPv4 interface.
- Plain-TCP identity exchange followed by mutual TLS (TOFU on first pair, per-device certificate pinning afterwards).
- Pair / unpair flow with explicit Accept/Reject prompts in both directions.
- In-app recovery when a pinned peer's certificate changes (e.g. peer was reinstalled): the popover shows a "Certificate changed" warning with a Reset Trust button instead of failing silently.
- Plugins:
  - Ping (send + receive, banner notification on receive).
  - Clipboard (manual push on outbound; auto-apply on inbound; image fallback sends the pasteboard image as a `clipboard-<uuid>.png` file payload when no text is present).
  - Share (URL, text, and file payload — send and receive over a second TLS connection).
  - Battery (peer's percent + charging indicator shown on the device row when paired and online).
- Menu-bar UI: popover lists discovered devices with pair status, last-seen age for offline peers, paired-first ordering, and per-device actions. Active file transfers render an inline progress bar; the Settings panel keeps the last 20 completed transfers. Devices accept file drops directly when paired and online.
- Connection lifecycle: TCP `SO_KEEPALIVE` plus Darwin `TCP_KEEPALIVE`/`KEEPINTVL`/`KEEPCNT` (30 / 10 / 3) so dead sockets are detected in ~60 s; a NIO `IdleStateHandler` (300 s) is the wedged-socket safety net. No app-layer heartbeat — KDE Connect peers treat unknown `kdeconnect.ping` flags as ordinary pings and would show a notification for each one.
- Settings panel: editable broadcast name, SHA-256 fingerprint display (local + per pinned peer, with Copy buttons), per-plugin enable/disable toggles, per-device plugin overrides on each trusted-device row, Launch-at-Login toggle, pinned-device list with Forget action, Recent Transfers, and an About section with version + GitHub link.
- mDNS / Bonjour discovery (`_kdeconnect._udp`) alongside legacy UDP broadcast — finds peers across access points and on networks where broadcast is filtered.
- Distribution: Release workflow builds an Apple Silicon binary, signs with Apple Developer ID + Hardened Runtime, notarizes via App Store Connect API key, staples the ticket, and publishes a `.dmg` + `.zip` to a GitHub Release.

Not implemented yet:

- macOS Share Extension proper (the modern Share sheet entry). File transfer currently lives in the menu-bar UI via the Send button and file drop.
- KDE Connect protocol v8 (post-TLS identity re-keying). The v7 implementation here interoperates with v7 peers; v8 is forward-compatibility only.
- Notification mirroring, Find My Phone, and media controls. These were intentionally removed from the active app surface while stabilizing the core clipboard and file-transfer workflows.
- Non-English localizations.

See [`ROADMAP.md`](ROADMAP.md) for upcoming work.

## Install

Download the latest release from [Releases](../../releases). Both a `.dmg` and a `.zip` of the `.app` bundle are published. The DMG is the friendlier option:

1. Open the DMG.
2. Drag `MacConnect.app` to `Applications`.
3. Launch normally — the app is signed with Apple Developer ID and notarized, so Gatekeeper will not warn.

The binary is built for Apple Silicon Macs and requires macOS 13 or later.

## Requirements (development)

- macOS 13 or later.
- Xcode 15+ (or Command Line Tools, in which case `swift test` is unavailable because XCTest ships with Xcode).
- `/usr/bin/openssl` (present on stock macOS) — used once on first launch to generate the local TLS identity.

## Build and run

```bash
# Apple Silicon release build
./scripts/build-app.sh release-arm64 0.1.0

# Assemble a debug .app bundle for local UI work
./scripts/build-app.sh debug

# Launch
open build/MacConnect.app
```

For development:

```bash
swift build              # debug build
swift run macconnect     # runs without bundle (no menu-bar item)
swift test               # unit tests
xed Package.swift        # open in Xcode
```

The first launch generates an RSA-2048 self-signed certificate under `~/Library/Application Support/MacConnect/` and seeds a stable device ID. Trusted-peer certificates are stored alongside as DER files keyed by remote `deviceId`.

## Project layout

```
Sources/
  MacConnectCore/
    Logging.swift              # os.Logger subsystems
    Settings/                  # device id, name, trusted-device store, per-plugin + per-device overrides
    Packet/                    # NetworkPacket, IdentityPayload, PairPacketBuilder, PacketType
    Network/
      LanLinkProvider.swift    # UDP discovery + TCP listener + outbound dial
      LanLink.swift            # per-device link + 30 s keepalive ping
      KDEConnectChannelHandler.swift
                               # plain-TCP identity then mTLS upgrade, idle-state close, readBuffer caps
      NIOTransport.swift       # event-loop group + bootstraps + SO_KEEPALIVE/TCP_KEEPALIVE family
      PayloadTransport.swift   # second-channel file transfer; receive-side serial queue + autoRead backpressure
      TLSContextBuilder.swift  # NIOSSL config + per-deviceId pinning verifier
      CertificateService.swift # local cert + pinned-peer store
      NetworkInterfaces.swift  # getifaddrs broadcast enumeration
    Device/                    # Device, DeviceManager
    Plugin/                    # Plugin protocol, registry, clipboard/share/ping/battery plugins, TransferStore, BatteryStore
  MacConnectApp/
    *.swift                          # menu-bar executable (AppKit + SwiftUI popover)
Tests/MacConnectCoreTests/     # XCTest: packet round-trips, pair timestamp, PeerVerifier, EmbeddedChannel handler
scripts/build-app.sh           # assembles MacConnect.app from the executable
.github/workflows/             # CI (build+test, lint)
```

## Protocol

Implemented against KDE Connect protocol version 7. References used:

- [KDE Connect iOS](https://invent.kde.org/network/kdeconnect-ios) — protocol reference.
- [KDE Connect Android](https://invent.kde.org/network/kdeconnect-android) — canonical implementation.
- [Valent protocol reference](https://valent.andyholmes.ca/documentation/protocol.html) — packet specification.

Notes specific to this implementation:

- Discovery uses subnet-directed UDP broadcasts (e.g. `192.168.1.255`) on every active IPv4 interface in addition to limited broadcast (`255.255.255.255`). Limited broadcast alone is filtered by many Wi-Fi access points and bridges.
- Per the protocol, the TCP-connect initiator becomes the TLS server and the TCP-accept side becomes the TLS client. The same channel is used for plain identity then upgraded to TLS via dynamic `ChannelPipeline` reconfiguration in `KDEConnectChannelHandler`.
- File transfer opens a second TLS connection on a port advertised in `payloadTransferInfo.port`. The receiver writes the payload to `~/Downloads/`, with `(1)`, `(2)` suffixes on filename collisions.

## Releases

Releases are tagged `vX.Y.Z`. Pushing a tag triggers `.github/workflows/release.yml`, which builds an Apple Silicon binary, signs and notarizes it, packages it as a `.zip` and a drag-to-`/Applications` `.dmg`, and publishes a GitHub Release with both assets.

To cut a release locally:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## License

GPL-3.0-or-later. The KDE Connect upstream is licensed GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL; this project chooses GPL-3.0-or-later for compatibility with the iOS port. See [`LICENSE`](LICENSE).
