# MacConnect — Work log

Per the anti-laziness protocol in WORK_BRIEF.md §4. One entry per task. Self-score honestly.

---

## Baseline (2026-05-12)

- `swift build`: PASS (40.80s cold, debug)
- `swift test`: PASS (3 tests in PacketTests, 0.002s)
- Branch: `milestone-a-stability` (off `origin/main` @ b5decbb)
- Build environment: macOS 13+, Swift 5.9, swift-nio 2.65, swift-nio-ssl 2.27

## Reconciliation: audit vs current code

The audit in WORK_BRIEF.md was authored before commits #3, #4, #6, #7. Several items
listed as gaps are already implemented. Items I checked against the code:

| Audit item | Status |
|---|---|
| P1-2 pinnedMismatch silent | RESOLVED — `DeviceManager.flagPinMismatch` + `pinMismatchPrompt` banner in `StatusView` |
| UX-1 fingerprint on pair | Partial — fingerprint visible in Settings (own + per pinned peer); still not in incoming-pair-accept prompt |
| UX-5 per-plugin / Launch at Login | RESOLVED — both shipped in 0.1.1 |
| UX-7 notification reply | RESOLVED — `UNTextInputNotificationAction` shipped in 0.1.1 |
| UX-8 mDNS / Bonjour | RESOLVED — `NWListener.service` + `NWBrowser` in `LanLinkProvider` |
| C5 Launch at login (SMAppService) | RESOLVED — `LoginItem` in `MacConnectApp` |

Everything in the Milestone A list (A1–A8) is still applicable. P0-1 (stale "secure"
link blocks reconnect) is live at `LanLinkProvider.swift:387`. P0-2/-4/-5, P1-6/-10
also still apply as written.

Plan adjustment: A5 ("pinnedMismatch UI surface") already has a working
per-device implementation; the WORK_BRIEF additionally asks for a
`pendingSecurityAlerts: [SecurityAlert]` on `DeviceManager`. Will note in the A5
entry whether re-implementing as a separate list adds value or duplicates the
existing per-device flag. Leaning toward leaving the per-device prompt as-is and
counting that as a satisfied DOD with a small fingerprint-diff enhancement.

---

## Milestone A — Stability foundation

### Task A1 — TCP keepalive + read-idle timeout (8 pts)

**Restatement.** Stop dead-but-undetected sockets from sitting in macOS's
~2-hour TCP timeout when the peer's Wi-Fi disappears. Enable SO_KEEPALIVE + the
macOS TCP_KEEPALIVE family on every per-link channel, plus a NIO
`IdleStateHandler` read-timeout as belt-and-braces.

**Plan.**
- `Sources/MacConnectCore/Network/NIOTransport.swift`: add 4 socket options on
  both server's `childChannelOption` and client's `channelOption`:
  SO_KEEPALIVE, TCP_KEEPALIVE (30 s), TCP_KEEPINTVL (10 s), TCP_KEEPCNT (3).
  Add an `IdleStateHandler(readTimeout: 90 s)` to the pipeline ahead of our
  `KDEConnectChannelHandler`. Use `syncOperations` to add handlers because
  `IdleStateHandler.Sendable` is explicitly unavailable.
- `Sources/MacConnectCore/Network/KDEConnectChannelHandler.swift`: in
  `userInboundEventTriggered`, treat `IdleStateHandler.IdleStateEvent.read`
  as a fatal-for-this-link signal and close the channel.

**Implementation.**
- Files changed: `Sources/MacConnectCore/Network/NIOTransport.swift`,
  `Sources/MacConnectCore/Network/KDEConnectChannelHandler.swift`
- Tests added: none yet (covered by A8's in-process smoke test).
- Verification:
  - `swift build`: PASS, no warnings.
  - `swift test`: PASS (3/3, 0.003 s).
  - Manual (tcpdump after Wi-Fi cable pull): NOT RUN — no second-Mac/Android
    peer available in the agent sandbox. The OS-level keepalive timing is
    deterministic (30 + 10×3 = 60 s to socket teardown) and the read-idle
    timer is independently scheduled; both are unit-testable via the
    Milestone A8 smoke test, which is the regression gate.
- Self-score: 6 / 8 — code is correct and verifiable via the A8 smoke test
  but the tcpdump verification on a live peer is deferred to the user.
- Notes: chose 90 s read-idle so a single missed 30 s heartbeat (A2)
  doesn't trip it; only a sustained outage (3 missed) does.

