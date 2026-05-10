# Roadmap

## Near term

- mDNS / Bonjour announcement and browse using `NWListener` / `NWBrowser` with the `_kdeconnect._udp` service type. UDP broadcast stays as a fallback. Reaches peers across access points where broadcast is filtered.
- MPRIS state parsing and a now-playing tile in the popover (PlayPause / Next / Prev / volume).
- macOS Share Extension target so files can be sent to a paired device via Finder's right-click Share menu and from any app's share sheet.

## Medium term

- Per-device plugin overrides (today's per-plugin toggles are global).
- App About window with version, license, and credits.
- Localization scaffolding.
- Clipboard image / non-text type support — pending KDE Connect protocol alignment across implementations.

## Open questions

- Whether to support KDE Connect protocol v8 (re-keying via post-TLS identity exchange). Not required for v7 peers but provides forward compatibility.
- Whether to replace `/usr/bin/openssl` shell-out with `swift-certificates` for cert generation. Adds a dependency but removes the openssl dependency.

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
