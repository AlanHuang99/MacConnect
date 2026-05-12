# MacConnect — Engineering Work Brief

This file is the playbook for the next AI/engineer working on MacConnect. It contains:
1. **The audit** — what is actually wrong with the codebase, with file:line citations.
2. **The plan** — three milestones with concrete tasks, point values, and strict acceptance criteria.
3. **The scoring rubric** — how to grade the work and how to keep the executor honest.
4. **The anti-laziness protocol** — exact procedures the executor must follow so partial work is caught.

Hand this file to Claude with the prompt at the bottom. Do not let the executor skip the protocol.

---

## 1. Audit findings

### Severity legend
- **P0** — known or near-certain cause of user-visible failure (e.g. "stops working after 2 days").
- **P1** — real bug, intermittent or non-fatal, but degrades reliability.
- **P2** — performance / quality issue, no functional impact today.
- **UX** — user experience.
- **DX** — developer experience / test gap.

### P0 — Stability bugs that likely cause the "stops working after a couple of days" symptom

**P0-1. Stale "secure" link blocks reconnect forever.** [Sources/MacConnectCore/Network/LanLinkProvider.swift:308-313](Sources/MacConnectCore/Network/LanLinkProvider.swift#L308-L313)
```swift
let existing = linksByDeviceId[identity.deviceId]
…
if let existing, existing.isSecure { return }
```
If the peer disappears without a clean TCP close (Wi-Fi flap, phone sleep, AP roam), the `Channel` stays "active" until the TCP stack times out — which on macOS can be hours. Until then UDP broadcasts from the peer are ignored. There is no application-layer heartbeat, no `SO_KEEPALIVE`, no read-idle timeout. **This is the most likely culprit for the "stops working after two days" report.**

**P0-2. No TCP keepalive on any socket.** [Sources/MacConnectCore/Network/NIOTransport.swift:46-48, 81-83](Sources/MacConnectCore/Network/NIOTransport.swift#L46-L83)
Only `tcp_nodelay` + `so_reuseaddr` are set. Without `SO_KEEPALIVE` (plus `TCP_KEEPALIVE`/`TCP_KEEPINTVL`/`TCP_KEEPCNT`), idle dead connections persist for the macOS default of ~2h.

**P0-3. No clean shutdown on `Quit`.** [Sources/MacConnectApp/StatusView.swift:88](Sources/MacConnectApp/StatusView.swift#L88), [Sources/MacConnectCore/Network/LanLinkProvider.swift:54-61](Sources/MacConnectCore/Network/LanLinkProvider.swift#L54-L61)
`NSApp.terminate(nil)` is called directly; `LanLinkProvider.stop()` exists but is never invoked. Channels/handlers leak on quit. Not the "2 days" cause but worth fixing.

**P0-4. `readBuffer` is unbounded in `KDEConnectChannelHandler`.** [Sources/MacConnectCore/Network/KDEConnectChannelHandler.swift:78-93](Sources/MacConnectCore/Network/KDEConnectChannelHandler.swift#L78-L93)
A malformed peer (or attacker) that never sends `\n` will make us buffer indefinitely. OOM at worst, garbage-collection thrash at best. Cap at e.g. 64 KiB for identity / 1 MiB post-handshake.

**P0-5. `PayloadReceiverHandler` writes to disk on the event loop.** [Sources/MacConnectCore/Network/PayloadTransport.swift:258-271](Sources/MacConnectCore/Network/PayloadTransport.swift#L258-L271)
`fileHandle?.write(contentsOf: bytes)` runs synchronously on the event-loop thread. For a multi-GB file this stalls every other channel sharing that event loop (we only have 2 EL threads). User-visible symptom: clipboard pushes, pings, broadcasts all freeze during a large file receive.

### P1 — Reliability / correctness bugs

**P1-1. Pair timestamp is in seconds; protocol uses milliseconds.** [Sources/MacConnectCore/Packet/PairPacket.swift:9](Sources/MacConnectCore/Packet/PairPacket.swift#L9)
`Int64(Date().timeIntervalSince1970)` → use `Int64(Date().timeIntervalSince1970 * 1000)`. Verify against KDE Connect Android source.

**P1-2. `pinnedMismatch` fails silently.** [Sources/MacConnectCore/Network/KDEConnectChannelHandler.swift:175-176](Sources/MacConnectCore/Network/KDEConnectChannelHandler.swift#L175-L176)
Log line only. Should surface a banner / popover notice so the user knows their previously-trusted peer's identity changed — this is the only signal of MITM-style impersonation. Currently the user sees the device just stop working.

**P1-3. TOFU writes cert pre-pair.** [Sources/MacConnectCore/Network/TLSContextBuilder.swift:73-75](Sources/MacConnectCore/Network/TLSContextBuilder.swift#L73-L75)
`storeRemoteCertDER` runs before user pair-accept. If two devices race or a peer reconnects with a new cert before pair-accept, the cert on disk changes. Should buffer the candidate cert in memory and only persist on pair-accept.

**P1-4. `Settings.deviceId` getter races on first access.** [Sources/MacConnectCore/Settings/Settings.swift:17-22](Sources/MacConnectCore/Settings/Settings.swift#L17-L22)
Two concurrent reads before `UserDefaults.set` lands can generate two different IDs. Wrap in a lock + cache the value in memory.

**P1-5. `Settings.deviceName` `objectWillChange.send()` is `DispatchQueue.main.async` from a setter that may already be on main.** [Sources/MacConnectCore/Settings/Settings.swift:33-35](Sources/MacConnectCore/Settings/Settings.swift#L33-L35) Delayed UI refresh and tear.

**P1-6. `Device.link` is `weak`, but is only kept alive by `LanLinkProvider.linksByDeviceId`.** [Sources/MacConnectCore/Device/Device.swift:21](Sources/MacConnectCore/Device/Device.swift#L21)
Fine in steady state, but `LanLinkProvider.handleClosed` removes it from the dict while a UI handler may still be holding a weak reference. The next `device.send` silently drops. This is masking the staleness symptom: the device shows "paired and online" but sends do nothing. Make `link` strong with explicit clear on detach.

**P1-7. UDP broadcast opens a new socket every 5 s.** [Sources/MacConnectCore/Network/LanLinkProvider.swift:353-358](Sources/MacConnectCore/Network/LanLinkProvider.swift#L353-L358)
Should be one long-lived socket. Reduces syscall pressure and matches what kdeconnect-kde does.

**P1-8. UDP listener is created with NWListener but the rest of the stack is NIO.** [Sources/MacConnectCore/Network/LanLinkProvider.swift:257-279](Sources/MacConnectCore/Network/LanLinkProvider.swift#L257-L279)
Two different network frameworks doing the same job. Source of subtle thread/queue confusion. Either move to NIO `DatagramBootstrap` everywhere or move discovery to `NWBrowser` (which also unlocks Bonjour for free).

**P1-9. `LanLinkProvider.handleIdentity` calls `Task { @MainActor in DeviceManager.shared.upsert(identity:) }` twice in some paths.** [Sources/MacConnectCore/Network/LanLinkProvider.swift:149-181](Sources/MacConnectCore/Network/LanLinkProvider.swift#L149-L181)
Once in the replace-channel branch, once in the new-link branch. Both branches dispatch — but the replace branch additionally re-dispatches at the bottom of the function. Easy to leave a duplicate.

**P1-10. `payloadTransport` server-channel double-close race.** [Sources/MacConnectCore/Network/PayloadTransport.swift:82-94](Sources/MacConnectCore/Network/PayloadTransport.swift#L82-L94)
The 60-second timeout fires `donePromise.fail(...)`. If completion succeeded already, NIO promises throw fatal when fulfilled twice. Use `donePromise.succeed(())` / `donePromise.fail(...)` with a `guard !done.isFulfilled` (or a flag) and prefer `EventLoopPromise.completeWithTask` patterns.

**P1-11. `PluginRegistry.dispatch` `await`s plugins sequentially.** [Sources/MacConnectCore/Plugin/PluginRegistry.swift:27-32](Sources/MacConnectCore/Plugin/PluginRegistry.swift#L27-L32)
Each `await p.handle` blocks the next plugin. Fine today because plugins are mostly synchronous, but a slow handler (notification system call) blocks others. Use a `TaskGroup` or dispatch them independently.

**P1-12. Notifications use random UUID identifiers.** [Sources/MacConnectCore/Plugin/Notifier.swift:9](Sources/MacConnectCore/Plugin/Notifier.swift#L9)
Each ping/clipboard/share adds a fresh banner to Notification Center. They never coalesce or replace. Use `"\(category).\(deviceId)"`-style stable IDs and update existing requests instead.

### P2 — Performance / quality

- **P2-1.** `KDEConnectChannelHandler.firstLF` re-scans entire `readBuffer` each call. [Sources/MacConnectCore/Network/KDEConnectChannelHandler.swift:246-252](Sources/MacConnectCore/Network/KDEConnectChannelHandler.swift#L246-L252) Use `readableBytesView.firstIndex(of: 0x0A)`; remember last search position across reads.
- **P2-2.** `PayloadReceiverHandler.channelRead` allocates `Array(buf.readableBytesView)` per read. [Sources/MacConnectCore/Network/PayloadTransport.swift:259-260](Sources/MacConnectCore/Network/PayloadTransport.swift#L259-L260) Stream the ByteBuffer's view directly via `withUnsafeReadableBytes`.
- **P2-3.** `PluginRegistry.allIncomingCapabilities/allOutgoingCapabilities` recompute (alloc + sort) on every identity broadcast (every 5 s). [Sources/MacConnectCore/Plugin/PluginRegistry.swift:19-25](Sources/MacConnectCore/Plugin/PluginRegistry.swift#L19-L25) Cache after registration.
- **P2-4.** Two-thread event loop group. [Sources/MacConnectCore/Network/NIOTransport.swift:13](Sources/MacConnectCore/Network/NIOTransport.swift#L13) Reasonable, but file payload + control plane on the same loop competes. Consider a separate ELG for payload transfers.
- **P2-5.** No backpressure on the payload receiver — buffered writes can blow memory on slow disk + fast network.
- **P2-6.** `Logger` calls everywhere include `String(reflecting:)` of errors that we then format. Cheap but `os.Logger` is best used with public-vs-private interpolation handled per call — already done correctly, just confirm no PII leaks past `.public`.

### UX gaps

- **UX-1.** No fingerprint shown on pair-accept. The user has no way to verify the device is who they think it is (security-critical).
- **UX-2.** No file-transfer progress UI. A 200 MB file send just sits silently until the "Sent" toast appears.
- **UX-3.** No drag-and-drop file send onto the menu-bar popover or a tray icon.
- **UX-4.** No multi-file send.
- **UX-5.** Settings is barebones: no per-plugin toggles, no per-device toggles, no fingerprint display once paired, no "Launch at login".
- **UX-6.** No MPRIS / Now Playing tile (packet handler is a `TODO`). [Sources/MacConnectCore/Plugin/MprisPlugin.swift:13-14](Sources/MacConnectCore/Plugin/MprisPlugin.swift#L13-L14)
- **UX-7.** No notification reply (Android notif → reply text → send back). Roadmap item.
- **UX-8.** No mDNS / Bonjour announcement (only legacy UDP broadcast). Many corporate / mesh Wi-Fi networks filter broadcast. Roadmap item.
- **UX-9.** No login-item registration (`SMAppService`). Roadmap item.
- **UX-10.** No "About" / version display in Settings.
- **UX-11.** Empty state copy is fine but no troubleshooting tips ("can your phone see the Mac?", "are you on the same SSID?").
- **UX-12.** Animation between `StatusView` and `SettingsView` is a fade-only; consider a horizontal slide for hierarchy. Minor.
- **UX-13.** No keyboard shortcuts on the popover (e.g. ⌘, for settings, ⌘W to close, ⌘R to refresh).
- **UX-14.** "Find" button on a paired phone rings immediately with no confirmation; could be misclicked.
- **UX-15.** Status indicator is a green/gray dot; no distinction between "discovered, unpaired" and "discovered, paired-but-offline".
- **UX-16.** No history / log view from the popover ("Recent transfers", "Last clipboard pulled").

### DX / test gaps

- **DX-1.** Three unit tests total, all packet round-trip. [Tests/MacConnectCoreTests/PacketTests.swift](Tests/MacConnectCoreTests/PacketTests.swift) Nothing for: pair state machine, peer verifier, settings sanitization, channel-handler state machine, payload transport, network-interface enumeration.
- **DX-2.** No SwiftLint / SwiftFormat.
- **DX-3.** No strict-concurrency mode in the Package — would catch latent data races.
- **DX-4.** No integration smoke test (e.g. spin up two `LanLinkProvider`s in-process and verify they pair + exchange ping).
- **DX-5.** No CLAUDE.md in the repo for future AI work.

---

## 2. The plan — three milestones

Each task carries a point value and a strict definition-of-done. Total: **100 points** core + **20 points** bonus.

The executor MUST tackle Milestone A before Milestone B, and B before C. Stability first, performance second, polish third. Do not skip ahead.

### Milestone A — Stability foundation (40 pts)

Focus: kill the "stops working after a few days" symptom and harden network lifecycle. After this milestone the app must survive an overnight Wi-Fi flap and reconnect without manual intervention.

**A1. Add TCP keepalive and read-idle timeout on every link channel. (8 pts)**
- Set `SO_KEEPALIVE=1` on inbound and outbound channels in `NIOTransport.swift`. Also set `TCP_KEEPALIVE` (macOS-specific `TCP_KEEPIDLE`) to 30 s, `TCP_KEEPINTVL` to 10 s, `TCP_KEEPCNT` to 3. Use `ChannelOptions.socketOption(.init(SOL_SOCKET, SO_KEEPALIVE))` then raw `setsockopt` on the fd for the TCP_* options inside `channelInitializer` via `channel.getOption(ChannelOptions.fileHandle)` (or pull the fd from the `SocketAddress` if possible).
- Add an `IdleStateHandler` (NIO) to the pipeline so a `readerIdle` event of 60 s closes the channel.
- **DOD:** `tcpdump -i any -n 'host <peer> and tcp[tcpflags] & tcp-syn != 0'` shows a reconnect within ~90 s after pulling the peer's Wi-Fi cable. Update the audit log in `WORK_LOG.md` with the timestamped tcpdump output and the duration measured.

**A2. Add a 30-second app-layer ping heartbeat to every secured link, and treat 3 missed pongs as link-dead. (8 pts)**
- Reuse `PacketType.ping` with a `"_keepalive": true` flag (so the peer doesn't show a notification — handle this exception in `PingPlugin`).
- In `LanLink` schedule a timer that sends a keepalive ping every 30 s. Track `lastPacketReceived`. If no packet of any kind has arrived in 90 s, call `disconnect()` and let the normal close handler kick reconnect.
- **DOD:** Manually verify with two Macs (or one Mac + Android KDE Connect): kill peer Wi-Fi, observe disconnect within 90 s in the popover (green dot → gray). Log timing in `WORK_LOG.md`.

**A3. Replace `weak link` in `Device` with a strong reference + explicit clear. (3 pts)**
- Change `Device.link` to `strong` and ensure `DeviceManager.detach` sets it to `nil`. Verify no retain cycle by adding a deinit log on `LanLink` (only in DEBUG) and exercising connect/disconnect.

**A4. Cap `KDEConnectChannelHandler.readBuffer` and fail closed. (3 pts)**
- 64 KiB cap during `awaitingPlainIdentity`. 4 MiB cap during `ready` (newline-framed JSON packets shouldn't exceed this; KDE Connect itself caps similar). On overflow, log + close the channel cleanly.

**A5. Surface `pinnedMismatch` in the UI. (4 pts)**
- Add an `@Published` `pendingSecurityAlerts: [SecurityAlert]` on `DeviceManager`. When `PeerVerifier` returns `.pinnedMismatch`, push an alert with the deviceId and fingerprint diff.
- Add a UI banner in `StatusView` that shows pending alerts with "Forget device" / "Dismiss" actions.

**A6. Clean shutdown. (3 pts)**
- Make `AppDelegate.applicationWillTerminate` call `LanLinkProvider.shared.stop()`. Wire `NSApp.terminate` through a properly awaited shutdown so the dispatch timer + channels close.

**A7. Fix `PayloadTransport.startSender` double-fulfill race. (3 pts)**
- Guard `donePromise.succeed` / `donePromise.fail` with a `Bool` `done` flag or use NIO's `completeWith` pattern. Wrap the 60 s timer in `if !done {...}`.

**A8. Add a smoke test for two in-process `LanLinkProvider`s. (8 pts)**
- New test target / test that boots two providers, swaps identities on a private port range, simulates pair-request, completes pair, exchanges a ping, exchanges a 1 MiB share payload, asserts both sides see success.
- This test is the regression gate for everything in Milestone A.
- **DOD:** `swift test` passes locally and in CI, including this new test, in < 30 s.

### Milestone B — Performance pass (20 pts)

Focus: eliminate hot-path waste and unblock the event loop during file transfers.

**B1. Move `PayloadReceiverHandler` file writes off the event loop. (6 pts)**
- Use a serial `DispatchQueue(label: "macconnect.payload.write", qos: .utility)` and dispatch `FileHandle.write` there. Coordinate via a NIO promise chain so we don't enable autoread until the disk catches up (true backpressure). Or wrap with `NonBlockingFileIO` from `swift-nio`.

**B2. Cache `PluginRegistry` capability lists. (2 pts)**
- Compute once on first read after registration; invalidate on `register`. Avoids per-broadcast sort/alloc.

**B3. Long-lived UDP broadcast socket. (3 pts)**
- One `socket()` at start of broadcast loop, close on `stop()`. Update broadcast destinations each tick.

**B4. `firstLF` incremental search. (2 pts)**
- Track `searchedTo` index; only scan new bytes.

**B5. Replace `Array(buf.readableBytesView)` allocation in `PayloadReceiverHandler.channelRead`. (2 pts)**
- Use `buf.withUnsafeReadableBytes` and `write(_ bytes: UnsafeRawBufferPointer)` on `FileHandle` (or `Data(bytesNoCopy:count:deallocator:)` carefully).

**B6. Strict concurrency mode in Package.swift. (5 pts)**
- Add `swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]` for both targets, fix warnings. Some will be legitimate races worth fixing; mark only the irreducible ones with `@unchecked Sendable` and a one-line comment.

### Milestone C — UX overhaul (40 pts)

Focus: make the popover feel like a real macOS menubar app and close the experience gaps.

**C1. Fingerprint display + verify-on-pair flow. (5 pts)**
- Show the peer's SHA-256 fingerprint of its leaf cert in both the incoming pair prompt and once-paired view. Format as colon-separated hex pairs, monospaced, with a "Copy" button.
- For incoming pair requests: show "Verify this matches the fingerprint shown on the other device" with the fingerprint above the Accept/Reject buttons. Critical for security UX.

**C2. File transfer progress UI. (5 pts)**
- `TransferStore` (`ObservableObject`) tracking active in/out transfers: filename, total bytes, bytes-transferred, eta, state.
- Inline progress bar in the device row during transfer.
- A "Recent transfers" section in Settings (last 20, persisted to UserDefaults).

**C3. Drag-and-drop file send. (4 pts)**
- Accept `NSItemProvider` on the device row (and on the menu-bar icon if feasible). Multi-file drop sends each file sequentially.

**C4. Per-plugin toggles in Settings. (3 pts)**
- `Settings.disabledPlugins: Set<String>` keyed by plugin identifier. `PluginRegistry.dispatch` checks this. UI: a list with toggles in Settings.

**C5. Launch at login via SMAppService. (3 pts)**
- macOS 13 API: `SMAppService.mainApp.register()` / `unregister()`. Settings toggle "Launch at login" with current state shown.

**C6. MPRIS now-playing tile. (5 pts)**
- Parse `kdeconnect.mpris` packets into a struct (player, title, artist, album, isPlaying, position, length, volume). Store keyed by deviceId.
- A tile above the device-action buttons with play/pause, next, prev, and the title/artist.
- Send `kdeconnect.mpris.request` on action.

**C7. Notification reply. (4 pts)**
- Register a `UNNotificationCategory` with a `UNTextInputNotificationAction`. When the user replies in a banner, send `kdeconnect.notification.reply` to the originating device. Track notification → deviceId / replyId mapping in `NotificationPlugin`.

**C8. mDNS / Bonjour discovery via `NWBrowser` for `_kdeconnect._udp`. (5 pts)**
- In parallel with existing UDP broadcast (don't remove it). Helps reach peers on networks that filter broadcast.

**C9. Refreshed popover visual design. (4 pts)**
- Device rows: device-type icon in a tinted circle (SF Symbol with `.foregroundStyle(.tint)`), name in title-2, status line in caption-2.
- Group paired devices above unpaired.
- Subtle hover state on row, primary action moved to a single right-side button when paired (Send), with overflow menu (`…`) for Ping/Clipboard/Find/Unpair.
- Match macOS Sonoma+ menubar aesthetic (Material backgrounds, smoother corners).

**C10. Keyboard shortcuts + empty state + about. (2 pts)**
- ⌘, opens Settings; ⌘W closes the popover; ⌘R refreshes; ⌘Q quits.
- Empty state: include a checklist (Wi-Fi same SSID, KDE Connect on phone, firewall off).
- About: app version, build, GitHub link.

### Bonus tasks (20 pts)

- **Bonus-1. Battery plugin (5 pts).** Parse `kdeconnect.battery`, show battery % and charging state on the phone row. Subscribe to updates.
- **Bonus-2. SwiftLint + SwiftFormat (3 pts).** Add `.swiftlint.yml`, run in CI, fix everything. Use the rules from `research/kdeconnect-ios/.swiftlint.yml` as a starting point.
- **Bonus-3. Replace openssl shell-out with `swift-certificates` (5 pts).** Per the open question in ROADMAP. Drops a dependency on system openssl; enables ECDSA keys if KDE Connect peers support them.
- **Bonus-4. Localization scaffolding (3 pts).** Move user-facing strings to `Localizable.xcstrings`; provide an en.lproj baseline.
- **Bonus-5. Per-device plugin overrides (2 pts).** UI sugar over C4.
- **Bonus-6. Clipboard image / non-text type support (2 pts).** Detect `NSImage` on the pasteboard, send as a file payload labelled `clipboard.png`.

---

## 3. Scoring rubric

The executor must self-grade at the end of each milestone using the rubric below and produce a `WORK_LOG.md` entry. The user will spot-check.

For each task:
- **Full points** if all acceptance criteria pass AND verification log is present AND tests/CI green AND manually verified on a real peer (Mac↔Android, or Mac↔Mac for Mac-only features).
- **Half points** if code is correct but one of: verification log missing, tests added but skipped, manual verification not performed.
- **Zero** otherwise. No "I implemented the code, it should work" credit.

### Per-milestone gating
- A milestone is not "complete" until *all* of its required tasks score ≥ 80% of available points AND `swift test` is green AND the app builds + launches with `./scripts/build-app.sh release` AND a paired Android device can complete a round-trip ping after the changes.
- The executor MUST not start Milestone B until A is complete. Same for B → C.

### Code-quality penalties (subtract from total)
- **-3 pts** for any net-new `@unchecked Sendable` without a one-line justification comment.
- **-3 pts** for any new `Task { @MainActor in ... }` whose body isn't trivially a UI update (these hide concurrency intent; prefer `MainActor.run` or annotate properly).
- **-5 pts** for any `// TODO` / `// FIXME` added without an open GitHub issue or roadmap entry.
- **-5 pts** for adding a dependency without justifying it in `WORK_LOG.md`.
- **-10 pts** for any milestone declared "done" where `swift test` fails or the app crashes on launch.
- **-10 pts** for breaking Mac↔Android round-trip ping. This is the immovable invariant.

### Quality bonuses (add to total)
- **+2 pts** for each new test that catches a real regression introduced and self-reverted during development (proven by a commit that adds the test failing, then a commit that fixes the bug).
- **+5 pts** if every public symbol in `MacConnectCore` has a one-line doc comment.

---

## 4. Anti-laziness protocol

The previous attempt fizzled, the user says. To prevent the same here, the executor MUST follow this loop for each task:

1. **Restate the task** in 2 sentences in `WORK_LOG.md` before writing any code, including the acceptance criteria.
2. **Plan in writing** — list the files you'll touch, the functions you'll add/change, the test you'll add. If the plan is wrong, the user can intercept early.
3. **Implement.** Small commits per logical change. No mega-commits.
4. **Verify.** Run all of:
   - `swift build`
   - `swift test`
   - `./scripts/build-app.sh release && open build/MacConnect.app`
   - Manual: do whatever the acceptance criteria demand (e.g. pull the peer's Wi-Fi cable, watch logs).
5. **Log.** Append to `WORK_LOG.md` a section:
   ```
   ### Task A1 — Add TCP keepalive (8 pts)
   - Files changed: NIOTransport.swift, LanLink.swift, …
   - Tests added: <list>
   - Verification:
     - swift test: PASS (37 tests, 0 failures)
     - build-app.sh release: PASS
     - Manual: <tcpdump output, screenshot, or notes>
   - Self-score: 8 / 8
   - Notes / leftover: <any caveats>
   ```
6. **Score honestly.** If you didn't complete the manual verification, score 4/8 not 8/8 and say why. Half-credit is fine; lying is not.
7. **Never skip a milestone gate.** Do not start B until A scores ≥ 32/40 AND Android round-trip ping verified.

### Hard rules
- **Never** add `// TODO` to skip a sub-step. Either implement it or open a follow-up issue and link it.
- **Never** disable a test to make CI green. If a test breaks because of legitimate behavior change, update it, but the change must be called out in `WORK_LOG.md`.
- **Never** remove a feature to "simplify" without the user signing off.
- **Never** declare a milestone complete without a hand-run of the app against a real peer.
- **Always** run `swift build` after every non-trivial edit, not just at the end. Catch compile errors early.
- **Always** prefer editing existing files; do not introduce new architectural layers unless the task explicitly says so.

### Stop conditions
- If a task's acceptance criteria turn out to be impossible or wrong, STOP, write a 5-sentence summary of why in `WORK_LOG.md`, and ask the user. Do not silently change the goal.
- If you find an unrelated bug while working, file a one-line entry under "Incidental findings" in `WORK_LOG.md` and keep going. Do not yak-shave.

---

## 5. Hand-off prompt (copy-paste this to Claude)

```
You are taking over MacConnect, a macOS KDE Connect client (Swift Package, ~2.6k LOC).
Read WORK_BRIEF.md from the repo root before doing anything.

Your job: execute Milestones A, B, C in order, following the anti-laziness protocol
strictly. After each task, update WORK_LOG.md with the format from section 4.

Hard constraints:
- Mac ↔ Mac and Mac ↔ Android must remain functional throughout. Test with a real
  peer at the end of every milestone. If you don't have a peer available, say so
  explicitly in WORK_LOG.md and pause for the user instead of skipping verification.
- Stability before performance before UX. Do not start B until A scores ≥ 32/40.
- No silent scope changes. If you disagree with a task, write a 5-sentence rationale
  in WORK_LOG.md under "Proposed deviations" and wait.

Start by reading WORK_BRIEF.md end-to-end, then run `swift build && swift test` to
establish a baseline, then begin Task A1. Self-score honestly.
```

---

## Appendix — quick file map for orientation

| Area | File | Note |
|---|---|---|
| Discovery + listener | `Sources/MacConnectCore/Network/LanLinkProvider.swift` | Owns UDP + TCP. Stale-link bug lives here. |
| Per-link state | `Sources/MacConnectCore/Network/LanLink.swift` | Heartbeat will live here (Milestone A2). |
| Channel handshake | `Sources/MacConnectCore/Network/KDEConnectChannelHandler.swift` | Plain-TCP-then-TLS. Buffer caps go here (A4). |
| TLS context | `Sources/MacConnectCore/Network/TLSContextBuilder.swift` | TOFU + pinning. Cert-store sharpening goes here (P1-3). |
| Payload | `Sources/MacConnectCore/Network/PayloadTransport.swift` | File transfer; receiver writes on EL (P0-5, B1). |
| Cert store | `Sources/MacConnectCore/Network/CertificateService.swift` | openssl shell-out (Bonus-3). |
| Settings | `Sources/MacConnectCore/Settings/Settings.swift` | deviceId race (P1-4). |
| Device model | `Sources/MacConnectCore/Device/Device.swift` | weak link bug (P1-6 / A3). |
| Device collection | `Sources/MacConnectCore/Device/DeviceManager.swift` | Pair state machine. |
| Plugins | `Sources/MacConnectCore/Plugin/*.swift` | One file per plugin. MPRIS is stubbed. |
| Notifier | `Sources/MacConnectCore/Plugin/Notifier.swift` | Stable IDs missing (P1-12). |
| App entry | `Sources/MacConnectApp/AppDelegate.swift` | Status item + popover. |
| Popover UI | `Sources/MacConnectApp/StatusView.swift` | UX milestone target. |
| Settings UI | `Sources/MacConnectApp/SettingsView.swift` | UX milestone target. |
| Tests | `Tests/MacConnectCoreTests/PacketTests.swift` | Three tests today. |
