# Android-Only Media Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make media control strictly Android to Mac, restore reliable Note12 commands, synchronize the play/pause icon on both phones, and publish v0.4.2.

**Architecture:** Reduce `MprisPlugin` to the controlled side of the KDE Connect protocol: receive Android requests and send Mac state. Remove the reverse Mac controller UI, cache, requests, and liveness probe. Stabilize Android controller instances by rejecting duplicate candidate channels while an active secure channel already exists, while retaining replacement for insecure or inactive links.

**Tech Stack:** Swift 5.9, Swift Package Manager, SwiftUI, XCTest, SwiftNIO EmbeddedChannel, KDE Connect MPRIS protocol, macOS MediaRemote and Core Audio, ADB Wi-Fi debugging, GitHub Actions, Developer ID/notarization, Sparkle appcast.

## Global Constraints

- Media control is Android to Mac only.
- Do not add a Mac media-app picker or enumerate simultaneous Mac media sessions.
- The Android central button must show play for `isPlaying: false` and pause for `isPlaying: true` based on actual Mac state.
- Keep Play, Pause, PlayPause, Previous, Next, Mac output volume, and mute behavior.
- Do not change the Android application or introduce a new packet type, process, dependency, or permission.
- Preserve unrelated Mac-to-phone functions such as file sending, clipboard push, ping, and Find My Phone.
- Add focused failing tests before each production change.
- Never claim a hardware, CI, signing, notarization, or release result without fresh evidence.

---

### Task 1: Reduce MPRIS to Android-controlled Mac state

**Files:**

- Modify: `Tests/MacConnectCoreTests/MprisPluginTests.swift`
- Modify: `Sources/MacConnectCore/Plugin/MprisPlugin.swift`
- Delete: `Sources/MacConnectCore/Plugin/MprisStore.swift`

**Interfaces:**

- Consumes: `LocalMprisService.handle(_:)`, `LocalMprisService.playerListPacket()`, and `LocalMprisService.currentStatePacket()`.
- Produces: `MprisPlugin.incomingCapabilities == [PacketType.mprisRequest]`, `MprisPlugin.outgoingCapabilities == [PacketType.mpris]`, request responses to Android, and local-state fan-out to all eligible phones.

- [ ] **Step 1: Write failing one-way capability and no-reverse-state tests**

Replace the symmetric capability expectation with:

```swift
XCTAssertEqual(plugin.incomingCapabilities, [PacketType.mprisRequest])
XCTAssertEqual(plugin.outgoingCapabilities, [PacketType.mpris])
```

Keep the local player-list request assertion, then send an incoming phone `PacketType.mpris` player-list packet and assert the recorder count does not change:

```swift
let sentBeforeRemoteState = recorder.packets.count
await plugin.handle(
    packet: NetworkPacket(
        type: PacketType.mpris,
        body: ["playerList": .array([.string("Phone Player")])]
    ),
    from: device
)
XCTAssertEqual(recorder.packets.count, sentBeforeRemoteState)
```

Remove all `MprisStore` setup, assertions, remote fan-out tests, and remote volume packet tests.

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
swift test --filter MprisPluginTests
```

Expected: capability assertions fail because both directions are still advertised, and the no-reverse-state assertion fails because the plugin sends a phone-player follow-up request.

- [ ] **Step 3: Implement the minimal one-way plugin**

Set the exact capability arrays, keep only `PacketType.mprisRequest` handling, and delete these Mac-controller APIs and helpers:

```swift
requestNowPlaying(from:)
playPause(_:)
previous(_:)
next(_:)
setVolume(_:for:)
volumePacket(player:percent:)
sendAction(_:_:)
```

Delete `MprisStore.swift`. Keep `attach(to:)`, `broadcastLocalState()`, and eligibility checks unchanged except for comments that describe the Android-controlled direction.

- [ ] **Step 4: Add and pass a two-phone state fan-out test**

Create two paired, reachable devices that accept `PacketType.mpris`, emit a fake local state change, and assert both IDs receive a state packet with the expected playback flag:

```swift
XCTAssertEqual(Set(recorder.deviceIds), ["k60", "note12"])
XCTAssertTrue(recorder.packets.allSatisfy {
    $0.body["isPlaying"]?.boolValue == true
})
```

Run:

```bash
swift test --filter MprisPluginTests
```

Expected: pass.

---

### Task 2: Remove Mac-side phone media UI and probes

**Files:**

- Modify: `Sources/MacConnectApp/StatusView.swift`
- Modify: `Sources/MacConnectCore/Device/DeviceManager.swift`
- Modify: `Sources/MacConnectCore/Plugin/BatteryPlugin.swift`
- Modify: `Tests/MacConnectCoreTests/LivenessReconcileTests.swift`

**Interfaces:**

- Consumes: `BatteryPlugin.requestUpdate(from:)` and the existing announcement-based unprobeable liveness path.
- Produces: battery-only `DeviceManager.ProbeKind`, battery-only `supportedProbes(...)`, and a device row with no phone media controls.

- [ ] **Step 1: Write failing battery-only liveness tests**

Change every `supportedProbes` call to omit `mprisEnabled`. Replace the MacConnect MPRIS probe test with:

```swift
func testMprisCapabilitiesDoNotCreateAProbe() {
    let probes = DeviceManager.supportedProbes(
        batteryEnabled: false,
        peerIncoming: [PacketType.mprisRequest],
        peerOutgoing: [PacketType.mpris]
    )
    XCTAssertTrue(probes.isEmpty)
}
```

Change the locally disabled plugin test so a disabled battery plugin yields no probes even if MPRIS is advertised.

- [ ] **Step 2: Run focused liveness tests and confirm RED**

Run:

```bash
swift test --filter LivenessReconcileTests
```

Expected: compile failures until the production signature and probe enum are reduced.

- [ ] **Step 3: Implement battery-only probing and remove remote cache cleanup**

Remove `.mpris` from `ProbeKind`, the `mprisEnabled` parameter and branch from `supportedProbes`, and the MPRIS send from `sendLivenessProbe`. Remove every `MprisStore.shared.clear` call. Update liveness comments to state that Android media is intentionally controlled-only and battery is the available silent probe.

Update the BatteryStore disconnect comment so it no longer refers to `MprisStore`.

- [ ] **Step 4: Remove the Mac phone-media surface**

In `StatusView`:

- rename `requestNowPlayingFromPeers` to `requestBatteryFromPeers` and leave only the enabled battery request;
- remove the `MprisStore` observation from `DeviceRow`;
- remove the conditional MPRIS tile;
- remove `mprisTile(_:)`;
- remove `RemoteVolumeSlider`.

- [ ] **Step 5: Run focused and complete tests**

Run:

```bash
swift test --filter LivenessReconcileTests
swift test
```

Expected: all pass.

---

### Task 3: Preserve an active secure channel

**Files:**

- Modify: `Tests/MacConnectCoreTests/LanLinkReplaceChannelTests.swift`
- Modify: `Sources/MacConnectCore/Network/LanLink.swift`
- Modify: `Sources/MacConnectCore/Network/LanLinkProvider.swift`

**Interfaces:**

- Produces: `LanLink.ChannelAdoption`, with `.unchanged`, `.rejected`, and `.replaced(previous: Channel)`, plus `LanLink.adoptChannel(_:) -> ChannelAdoption`.
- Consumes: `Channel.isActive`, the existing secure flag, provider channel maps, and deferred channel closure outside `linkLock`.

- [ ] **Step 1: Write failing secure-channel adoption tests**

Replace direct `replaceChannel` expectations with three tests:

```swift
func testSecureActiveLinkRejectsDuplicateCandidate() throws {
    let current = try makeActiveChannel()
    let candidate = try makeActiveChannel()
    let link = makeLink(channel: current)
    link.isSecure = true

    guard case .rejected = link.adoptChannel(candidate) else {
        return XCTFail("secure active link must reject the candidate")
    }
    XCTAssertTrue(link.activeChannel === current)
    XCTAssertTrue(link.isSecure)
}
```

Add an insecure-link test that expects `.replaced(previous:)`, adoption of the candidate, and `isSecure == false`. Add an inactive-current-channel test with the same replacement expectation even if the prior secure flag is true.

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
swift test --filter LanLinkReplaceChannelTests
```

Expected: compile failures because `ChannelAdoption` and `adoptChannel(_:)` do not exist.

- [ ] **Step 3: Implement atomic adoption policy in `LanLink`**

Under the existing link lock:

```swift
if old === newChannel { return .unchanged }
if _isSecure, old.isActive { return .rejected }
channel = newChannel
_isSecure = false
return .replaced(previous: old)
```

Do not close either channel inside `LanLink`.

- [ ] **Step 4: Integrate adoption with provider maps and deferred close**

In `LanLinkProvider.handleIdentity`, switch on `existing.adoptChannel(channel)` while holding `linkLock`:

- `.unchanged`: unlock and return;
- `.rejected`: unlock, close the candidate, log the preserved link, and return;
- `.replaced(previous:)`: remove the previous mapping, map the candidate, unlock, close the previous channel, update device identity, and return.

The candidate and previous channel closures must remain outside `linkLock`.

- [ ] **Step 5: Run focused and complete tests**

Run:

```bash
swift test --filter LanLinkReplaceChannelTests
swift test
```

Expected: all pass.

---

### Task 4: Document v0.4.2 and validate the source tree

**Files:**

- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update user-facing documentation**

Replace the two-way media feature wording with Android-to-Mac control. State that Play, Pause, Previous, Next, and synchronized Mac output volume are available from Android, and that play/pause controls track actual Mac playback state. Remove `MprisStore` from the project-layout description.

Add a v0.4.2 changelog entry dated 2026-08-14 with:

- Android-only media direction and removal of the Mac phone-player tile;
- stable duplicate-channel handling that restores Note12 commands;
- synchronized play/pause button state across connected phones.

Advance comparison links from v0.4.1 to v0.4.2.

- [ ] **Step 2: Run CI-equivalent local checks**

Run:

```bash
swift test
swift build -c release
./scripts/build-app.sh release
./scripts/build-app.sh release "0.4.2" direct
swiftlint --strict
swiftformat --lint .
```

Also assemble the universal direct v0.4.2 app, verify arm64 and x86_64 slices, inspect bundle version and direct-update framework/rpath configuration, and review the complete branch diff.

---

### Task 5: Verify both Android phones end to end

**Files:**

- No source changes expected.

- [ ] **Step 1: Launch the fresh v0.4.2 build and reconnect both phones**

Quit the installed v0.4.1 process, launch the fresh branch app, and confirm the authorized Wi-Fi ADB devices:

```text
23013RK75C / Redmi K60 / KDE Connect 1.35.11
23049RAD8C / Note12 / KDE Connect 1.35.13
```

Confirm both are paired with the same MacConnect identity.

- [ ] **Step 2: Verify stable links**

Observe MacConnect logs for at least three identity broadcast intervals. Require no repeating `Replaced channel for existing link` or secure-link reset for either phone while the original secure channels remain active.

- [ ] **Step 3: Verify Note12 and K60 commands independently**

On each phone, open Multimedia control and invoke:

- play, then require the elected Mac session to play;
- pause, then require it to pause;
- next, then require the track to move forward;
- previous, then require it to return;
- volume change, then require the Mac output level to change.

Require Mac logs to show MPRIS requests from both `Redmi K60` and the Note12 peer identity.

- [ ] **Step 4: Verify two-phone button state synchronization**

After play from either phone, dump both UI hierarchies and require `play_button` to describe/render Pause. After pause, require both to describe/render Play. Confirm both still show the same elected Mac player and current track.

- [ ] **Step 5: Restore the installed app state**

After validation, leave the tested v0.4.2 build running or install the public release once it is available. Preserve the existing v0.4.1 app recoverably until the public artifact is verified.

---

### Task 6: Publish and verify v0.4.2

**Files:**

- No source changes expected unless review or CI exposes a defect.

- [ ] **Step 1: Request a fresh code review**

Run the requesting-code-review workflow against the complete branch diff. Fix any validated findings test-first and repeat affected verification.

- [ ] **Step 2: Commit, push, and open a pull request**

Commit focused implementation and release-documentation changes on `codex/android-only-media-control`, push the branch, and create a ready pull request against `main` using the GitHub publication workflow.

- [ ] **Step 3: Require pull-request and main CI**

Wait for all pull-request checks, squash-merge only after they pass, fetch the resulting `origin/main` commit, and require the main-branch CI run for that exact commit to pass.

- [ ] **Step 4: Tag the verified main commit**

Create and push annotated tag `v0.4.2` on the verified merge commit.

- [ ] **Step 5: Monitor and independently verify the release**

Require the release workflow to complete signing, notarization, stapling, DMG/ZIP publication, GitHub Release creation, and Sparkle appcast update. Download public assets into a fresh temporary directory and verify:

- SHA-256 hashes;
- archive contents and version 0.4.2 metadata;
- Developer ID signatures and hardened runtime;
- Gatekeeper assessment and notarization tickets;
- arm64 and x86_64 binary slices;
- latest-release redirect;
- signed appcast version, enclosure length, URL, and EdDSA signature;
- GitHub Pages deployment.

- [ ] **Step 6: Install and smoke-test the public release**

Replace `/Applications/MacConnect.app` recoverably with the verified public v0.4.2 bundle, launch it, and repeat a concise K60 and Note12 play/pause smoke test before reporting completion.
