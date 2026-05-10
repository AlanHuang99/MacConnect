# MacConnect

A Mac-native, no-Qt, no-Catalyst KDE Connect client. Built fresh in pure Swift with Apple's Network framework, AppKit, and SwiftUI.

> **Status: v0.1 — early skeleton.** Device discovery and identity exchange work. TLS upgrade and pairing are the next milestone (see [TODO.md](TODO.md)).

## Why?

The official KDE Connect macOS app is a Qt port and feels foreign. [Soduto](https://github.com/sannidhyaroy/Soduto) is a fork-of-a-fork of an old codebase, and its auto-clipboard sync sends every paired device a notification any time you copy text. This project is a clean, Mac-native rewrite that:

- **Does not auto-sync clipboard.** Push and pull are explicit menu actions.
- **Uses Apple's Network framework** instead of CocoaAsyncSocket — no Objective-C dependency.
- **Targets macOS 13+ with SwiftUI / AppKit** for a real menu-bar experience.

## What works today

- ✅ UDP discovery on port 1716 (broadcast send + listen)
- ✅ TCP server + outbound TCP, plain-TCP identity exchange
- ✅ Self-signed RSA-2048 TLS identity generated on first run (via `/usr/bin/openssl`)
- ✅ Device list in a menu-bar popover with reachability + pair status
- ✅ Plugin abstraction (Ping / Clipboard / Notifications / FindMyPhone / MPRIS / Share)
- ✅ Pair-request UI prompt (Accept / Reject)
- ✅ Builds cleanly under Swift 6 strict concurrency

## What does *not* work yet

- ❌ **TLS upgrade.** Plain TCP is exchanged but `startTLS` is not yet wired. KDE Connect requires post-identity TLS upgrade with mutual cert auth and per-device pinning. Apple's `NWConnection` does not support starting plain TCP and upgrading mid-stream — the next iteration switches the transport layer to `swift-nio` + `swift-nio-ssl`. See [TODO.md](TODO.md).
- ❌ Pairing handshake completion — depends on TLS.
- ❌ File transfer (depends on TLS payload-channel).
- ❌ MPRIS state parsing (packets received, not yet decoded).
- ❌ mDNS/Bonjour announcement (only legacy 255.255.255.255 broadcast for now).

## Build

Requirements: macOS 13+, Swift 5.9+ (Command Line Tools is sufficient — full Xcode is only needed for running the test target).

```bash
# Build the .app bundle
./scripts/build-app.sh release

# Launch
open build/MacConnect.app
```

For development:

```bash
swift build       # debug build, fast iteration
swift run macconnect   # runs without bundle (no menu-bar item)
```

## Project layout

```
Sources/
  MacConnectCore/        # library — protocol, network, plugins
    Packet/              # NetworkPacket, IdentityPayload, PairPacketBuilder
    Network/             # LanLinkProvider (UDP+TCP), LanLink, CertificateService
    Device/              # Device, DeviceManager
    Plugin/              # Plugin protocol, registry, plugin implementations
    Settings/            # device id, name, trusted-device store
  MacConnectApp/         # menu-bar executable (AppKit + SwiftUI popover)
scripts/
  build-app.sh           # produce MacConnect.app bundle
Tests/
  MacConnectCoreTests/   # XCTest packet round-trip tests (requires full Xcode)
```

## Protocol references

This project implements the KDE Connect LAN protocol. The reference implementations consulted while writing this:

- [KDE Connect iOS](https://invent.kde.org/network/kdeconnect-ios) (Objective-C network backend, Swift UI) — used as the protocol reference, not as a base for porting. License GPLv3.
- [Valent protocol reference](https://valent.andyholmes.ca/documentation/protocol.html) — packet specification.
- [KDE Connect Android](https://invent.kde.org/network/kdeconnect-android) — canonical implementation.

## License

GPLv3 — matching the upstream KDE Connect projects. See [LICENSE](LICENSE).
