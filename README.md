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
  - Clipboard (manual push on outbound; auto-apply on inbound).
  - Notifications (receive Android notifications as macOS banners, with inline Reply for notifications that carry a `requestReplyId`).
  - Find My Phone (ring outbound).
  - Share (URL, text, and file payload — send and receive over a second TLS connection).
- Menu-bar UI with a popover that lists discovered devices, their pair status, last-seen age for offline peers, and per-device actions.
- Settings panel: editable broadcast name, SHA-256 fingerprint display (local + per pinned peer), per-plugin enable/disable toggles, Launch-at-Login toggle, pinned-device list with Forget action.
- "Send via MacConnect" Finder Services entry (right-click any file → Services → Send via MacConnect → pick a paired device).
- mDNS / Bonjour discovery (`_kdeconnect._udp`) alongside legacy UDP broadcast — finds peers across access points and on networks where broadcast is filtered.
- Distribution: Release workflow builds a universal binary, signs with Apple Developer ID + Hardened Runtime, notarizes via App Store Connect API key, staples the ticket, and publishes a `.dmg` + `.zip` to a GitHub Release.

Not implemented yet:

- macOS Share Extension proper (the modern Share sheet entry). The current Services menu integration is the practical equivalent; a real `.appex` Share Extension requires app-extension build tooling that SwiftPM doesn't support natively.
- MPRIS state parsing (packets are received but no media UI).
- Clipboard image transfer (pending KDE Connect protocol alignment across implementations).

See [`ROADMAP.md`](ROADMAP.md) for upcoming work.

## Install

Download the latest release from [Releases](../../releases). Both a `.dmg` and a `.zip` of the `.app` bundle are published. The DMG is the friendlier option:

1. Open the DMG.
2. Drag `MacConnect.app` to `Applications`.
3. Launch normally — the app is signed with Apple Developer ID and notarized, so Gatekeeper will not warn.

The binary is universal (Apple Silicon + Intel) and requires macOS 13 or later.

## Requirements (development)

- macOS 13 or later.
- Xcode 15+ (or Command Line Tools, in which case `swift test` is unavailable because XCTest ships with Xcode).
- `/usr/bin/openssl` (present on stock macOS) — used once on first launch to generate the local TLS identity.

## Build and run

```bash
# Assemble a .app bundle
./scripts/build-app.sh release

# Universal (arm64 + x86_64) build
./scripts/build-app.sh release-universal 0.1.0

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
    Settings/                  # device id, name, trusted-device store
    Packet/                    # NetworkPacket, IdentityPayload, PairPacketBuilder, PacketType
    Network/
      LanLinkProvider.swift    # UDP discovery + TCP listener + outbound dial
      LanLink.swift            # per-device link wrapping a NIO Channel
      KDEConnectChannelHandler.swift
                               # plain-TCP identity then mTLS upgrade
      NIOTransport.swift       # event-loop group + bootstraps
      PayloadTransport.swift   # second-channel file transfer
      TLSContextBuilder.swift  # NIOSSL config + per-deviceId pinning verifier
      CertificateService.swift # local cert + pinned-peer store
      NetworkInterfaces.swift  # getifaddrs broadcast enumeration
    Device/                    # Device, DeviceManager
    Plugin/                    # Plugin protocol, registry, plugin implementations
  MacConnectApp/               # menu-bar executable (AppKit + SwiftUI popover)
Tests/MacConnectCoreTests/     # XCTest packet round-trip tests
scripts/build-app.sh           # assembles MacConnect.app from the executable
.github/workflows/             # CI
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

Releases are tagged `vX.Y.Z`. Pushing a tag triggers `.github/workflows/release.yml`, which builds a universal binary, ad-hoc codesigns it, packages it as a `.zip` and a drag-to-`/Applications` `.dmg`, and publishes a GitHub Release with both assets.

To cut a release locally:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## License

GPL-3.0-or-later. The KDE Connect upstream is licensed GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL; this project chooses GPL-3.0-or-later for compatibility with the iOS port. See [`LICENSE`](LICENSE).
