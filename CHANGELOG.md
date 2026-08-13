# Changelog

All notable changes to MacConnect are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Releases before 0.3.5 are catalogued in the [GitHub Releases](https://github.com/AlanHuang99/MacConnect/releases) and the "Done" section of [`ROADMAP.md`](ROADMAP.md).

## [Unreleased]

### Added

- Two-way media controls. KDE Connect Android can control the Mac's active system media session with Play, Pause, Play-Pause, and output-volume controls, while the Mac's existing peer media tile now includes volume. Mac playback uses the private MediaRemote framework, so this system-wide integration is intended for the direct distribution channel rather than Mac App Store review.

## [0.3.8] - 2026-07-11

### Fixed

- Two Macs no longer lose each other until a manual refresh after one goes offline and comes back. Three fixes work together. The discovery listener now retries with backoff when its port bind fails — a refresh or wake rebuild raced the old listener's asynchronous teardown for the port, and losing that race silently left the app deaf to every peer announcement until the next rebuild (caught live: the other Mac announced every 5 seconds into a dead listener while both sides looked idle). The liveness reconciler can now retire a stale link to a peer it has no silent probe for — two MacConnects advertise battery and media-control as receivers on both ends, so neither could probe the other and a stale Mac↔Mac link was kept forever; past a 2-minute ceiling of TCP silence the link is now re-dialed in place while the peer keeps announcing, or dropped once the peer's announcements stop too. And a peer that comes back on a new IP address is reconnected within a few seconds: when a peer announces from a new address and its old one has gone quiet, the stale link is dropped and re-dialed immediately (multi-homed peers announce from every interface, so they are not affected). ([#28](https://github.com/AlanHuang99/MacConnect/pull/28))
- The Send file picker no longer opens with dead, unclickable controls that forced several attempts. The popover (and its click-outside dismiss monitor) now closes before the picker is presented, the app temporarily becomes a regular app so the panel can take real keyboard focus, and the panel runs modally — the same discipline the Services-menu flow already used.

### Changed

- The menu bar now shows the real app icon instead of a generic system symbol, matching the Dock and Finder branding.
- Push Clipboard is now a one-click button on each device row, next to Send. Both are compact icon buttons (paperclip = send file, clipboard = push clipboard) with tooltips, so they fit the row; Ping, Find My Phone, and Unpair stay in the ⋯ menu.

## [0.3.7] - 2026-06-14

### Fixed

- Discovery could silently stop finding and connecting to every device: the menu kept showing stale "online" badges while nothing actually connected, and refreshing did nothing, until the app was quit and relaunched. Closing a superseded connection while the discovery lock was held re-entered that same non-recursive lock on the same thread and deadlocked the discovery queue, halting all broadcasting, dialing, and reconnecting. A reconnect race, such as several devices reconnecting at once after a reboot, would trigger it. ([#26](https://github.com/AlanHuang99/MacConnect/pull/26))
- Update prompts on the direct (Sparkle) build now bring the app to the front when an update is presented, so they are visible for this menu-bar app instead of opening behind other windows. ([#27](https://github.com/AlanHuang99/MacConnect/pull/27))

## [0.3.6] - 2026-06-12

### Fixed

- Device status no longer sticks at "online" with hours-old battery and now-playing data after the Mac sleeps, runs a screen saver, or the phone enters Doze. A periodic reconciler re-derives reachability from the last packet seen on the wall clock and silently probes idle paired links (only for capabilities the peer advertises, so healthy limited clients are not flapped), marking a peer that has gone away offline within about a minute so it reconnects on its own. ([#23](https://github.com/AlanHuang99/MacConnect/pull/23))
- Battery percentage is cleared when a device disconnects, so a reconnecting peer no longer briefly shows its previous charge. ([#23](https://github.com/AlanHuang99/MacConnect/pull/23))

### Changed

- README: added a header with the app icon, status badges, a features overview, and a tech-stack table. ([#24](https://github.com/AlanHuang99/MacConnect/pull/24))

## [0.3.5] - 2026-06-12

### Added

- In-app updates on the direct (GitHub Releases) build via Sparkle: a "Check for Updates…" command and an optional automatic-check toggle, with EdDSA-verified downloads. The default build stays Sparkle-free as the Mac App Store channel. ([#22](https://github.com/AlanHuang99/MacConnect/pull/22))

### Fixed

- Discovery rebuilds on sleep/wake and network changes (Wi-Fi switch, dock/undock) and stale links are dropped, so peers reconnect without an app restart. ([#21](https://github.com/AlanHuang99/MacConnect/pull/21))

[Unreleased]: https://github.com/AlanHuang99/MacConnect/compare/v0.3.8...HEAD
[0.3.8]: https://github.com/AlanHuang99/MacConnect/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/AlanHuang99/MacConnect/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/AlanHuang99/MacConnect/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/AlanHuang99/MacConnect/releases/tag/v0.3.5
