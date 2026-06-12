# Roadmap

## Near term

- macOS Share Extension proper (`.appex` bundle) so MacConnect appears in the modern Share sheet alongside Mail / Messages — not just in Finder's Services menu. Needs an app-extension build path that SwiftPM doesn't natively support; the existing Services-menu integration is the working substitute in the meantime.
- Live-update the Bonjour service name when the user renames the device (currently set once at listener creation).
- Two-provider in-process pairing smoke test as a regression gate. Requires injecting `Settings` / `CertificateService` / `PluginRegistry` / `DeviceManager` into `LanLinkProvider` (singletons today). Partial coverage from the `ChannelHandlerTests` EmbeddedChannel tests and the `PeerVerifierTests` cert-store round-trip.

## Medium term

- Mac App Store submission pipeline (sandbox entitlements, provisioning profile, `productbuild` package, App Store Connect upload). The Sparkle-free default build is already the App Store channel; only the submission tooling is missing.
- App About window in addition to the Settings section.
- Non-English localizations (catalog wiring is in place; `Localizable.xcstrings` only ships `en` today).
- Volume + seek bar on the MPRIS now-playing tile.

## Open questions

- Whether to support KDE Connect protocol v8 (re-keying via post-TLS identity exchange). Not required for v7 peers but provides forward compatibility.
- Whether to replace `/usr/bin/openssl` shell-out with `swift-certificates` for cert generation. Adds a dependency but removes the openssl dependency. Needs Mac↔Android round-trip verification under each variant before merging.

## Done

- App icon (0.1.0).
- Pair / unpair flow with Accept/Reject prompts (0.1.0).
- File transfer over a second TLS payload connection (0.1.0).
- Code signing with Apple Developer ID, Hardened Runtime, and notarization in CI (0.1.1).
- Pin-mismatch recovery: "Certificate changed" UI with Reset Trust button (0.1.1).
- Launch at Login via `SMAppService` (0.1.1).
- SHA-256 fingerprint display (local + per pinned peer) for out-of-band verification (0.1.1).
- Per-plugin enable/disable toggles in Settings (0.1.1).
- Notification reply via `UNTextInputNotificationAction` → `kdeconnect.notification.reply` (0.1.1).
- mDNS announce + browse via `NWListener` / `NWBrowser` (`_kdeconnect._udp`) alongside UDP broadcast (0.1.4).
- "Send via MacConnect" Services menu entry for right-click → Send file from Finder (0.1.4).
- TCP `SO_KEEPALIVE` + Darwin `TCP_KEEPALIVE`/`KEEPINTVL`/`KEEPCNT` and a 300 s `IdleStateHandler` so dead links are detected in ~60 s instead of the macOS default ~2 h (0.2.0).
- ~~30 s app-layer `_keepalive` ping on every secured link (0.2.0).~~ Reverted in 0.2.1: KDE Connect Android shows a Ping notification for each, because peers that don't know the `_keepalive` flag treat the packet as an ordinary ping. OS-level TCP keepalive (above) is enough on its own.
- Strong `Device.link` reference + lifecycle fixes; `applicationWillTerminate` tears down channels cleanly (0.2.0).
- `KDEConnectChannelHandler` readBuffer caps (64 KiB pre-handshake, 4 MiB post) (0.2.0).
- Pair packet timestamp in milliseconds (was seconds — some Android builds rejected the seconds-scale value) (0.2.0).
- File-transfer progress UI: per-device row progress bar + persisted last-20 Recent Transfers in Settings (0.2.0).
- Drag-and-drop file send onto paired-and-online device rows; directory drops filtered (0.2.0).
- MPRIS parser + per-device now-playing tile (title/artist, Play-Pause, Next, Previous) with per-player nowPlaying fan-out and prefer-playing on multi-player races (0.2.0).
- Battery plugin: percent + charging indicator on the status line (0.2.0).
- Per-device plugin overrides layered on top of the global toggles (0.2.0).
- Clipboard image fallback: pasteboard image → `clipboard-<uuid>.png` via the Share file payload path (0.2.0).
- About section in Settings (version + build + GitHub link); empty-state troubleshooting checklist; ⌘R / ⌘, / ⌘Q keyboard shortcuts (0.2.0).
- PayloadReceiver writes off the event loop with autoRead backpressure; PluginRegistry capability cache; long-lived UDP broadcast socket; strict-concurrency complete (0.2.0).
- `Localizable.xcstrings` scaffolding via SwiftPM resources; `.swiftlint.yml` / `.swiftformat` and a CI Lint job (0.2.0).
- Sleep/wake + Wi-Fi-change recovery: discovery rebuilds and stale links drop on `NSWorkspace.didWake` and `NWPathMonitor` interface changes, so peers reconnect without an app restart; the popover refresh button now does a full re-discover (0.4.0).
- In-app updates via Sparkle on the direct (GitHub Releases) build: "Check for Updates…" + automatic-check toggle in Settings, EdDSA-verified downloads, inside-out-signed `Sparkle.framework`, and an appcast published to GitHub Pages. The default build stays Sparkle-free as the Mac App Store channel (`MACCONNECT_SPARKLE` / `#if SPARKLE`) (0.4.0).
