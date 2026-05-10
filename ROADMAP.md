# Roadmap

## Near term

- mDNS / Bonjour announcement using `NWListener` with a `_kdeconnect._udp` service. UDP broadcast is kept as a fallback. Helps reach peers across access points where broadcast is filtered.
- MPRIS state parsing and a now-playing tile in the popover (PlayPause / Next / Prev / volume).
- Notification reply: hook `kdeconnect.notification.reply` into `UNNotificationAction` so phone notifications can be replied to inline.
- Login-item registration via `SMAppService` so the app can launch at login.

## Medium term

- Code signing and notarization for distribution outside development.
- App icon and About window.
- Localization scaffolding.
- Settings: per-plugin enable/disable toggles, per-device plugin overrides, fingerprint display.
- Clipboard image / non-text type support.

## Open questions

- Whether to support KDE Connect protocol v8 (re-keying via post-TLS identity exchange). Not required for v7 peers but provides forward compatibility.
- Whether to replace `/usr/bin/openssl` shell-out with `swift-certificates` for cert generation. Adds a dependency but removes the openssl dependency.
- How to surface peer-cert mismatch (`pinnedMismatch`) in the UI today the connection fails silently in the log; users should be notified that the peer's identity has changed.
