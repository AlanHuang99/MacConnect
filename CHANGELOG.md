# Changelog

All notable changes to MacConnect are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Releases before 0.3.5 are catalogued in the [GitHub Releases](https://github.com/AlanHuang99/MacConnect/releases) and the "Done" section of [`ROADMAP.md`](ROADMAP.md).

## [Unreleased]

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

[Unreleased]: https://github.com/AlanHuang99/MacConnect/compare/v0.3.5...HEAD
[0.3.5]: https://github.com/AlanHuang99/MacConnect/releases/tag/v0.3.5
