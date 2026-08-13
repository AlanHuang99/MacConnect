# Previous and Next Media Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Let KDE Connect Android send Previous and Next to the Mac's elected system media session and publish the verified change as v0.4.1.

**Architecture:** Extend the existing `LocalMediaControlling` and `MediaRemoteControlling` command path instead of adding a second transport. `LocalMprisService` will advertise navigation while a local transport exists and translate KDE Connect's existing `Previous` and `Next` actions into the MediaRemote bridge commands for the elected system player.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, KDE Connect MPRIS packets, private macOS MediaRemote framework, SwiftLint, SwiftFormat, ADB Wi-Fi debugging, GitHub Actions, Developer ID/notarization, Sparkle appcast.

## Global Constraints

- Preserve the single elected Mac media session introduced in v0.4.0. Do not add an app picker or enumerate multiple local players.
- Do not synthesize keyboard media keys or introduce another permission.
- Keep Android protocol compatibility by using the existing `Previous` and `Next` MPRIS action names and capability fields.
- Add the smallest behavior-focused tests before production changes.
- Never claim a hardware or release result without fresh command output.

---

### Task 1: Forward navigation through the system media controller

**Files:**

- Modify: `Tests/MacConnectCoreTests/SystemMediaBridgeTests.swift`
- Modify: `Sources/MacConnectCore/Plugin/LocalMediaController.swift`
- Modify: `Sources/MacConnectCore/Plugin/MediaRemoteBridge.swift`

- [x] **Step 1: Write the failing forwarding test**

Extend `FakeMediaRemoteController.Command` with `.previous` and `.next`, invoke both operations from `testSystemControllerCombinesStateAndForwardsCommands`, and expect this complete ordered sequence:

```swift
controller.play()
controller.pause()
controller.togglePlayPause()
controller.previous()
controller.next()

XCTAssertEqual(transport.commands, [.play, .pause, .toggle, .previous, .next])
```

Add fake methods that record those calls. The test must initially fail to compile because `SystemLocalMediaController` has no navigation methods.

- [x] **Step 2: Run the focused test and confirm RED**

Run:

```bash
swift test --filter SystemMediaBridgeTests.testSystemControllerCombinesStateAndForwardsCommands
```

Expected: compiler errors for the absent `previous()` and `next()` methods.

- [x] **Step 3: Implement the minimal command path**

Add `previous()` and `next()` to both control protocols and the unavailable/system controller implementations. Forward the system controller methods directly to its transport.

Extend `MediaRemoteBridge.Command` with the established MediaRemote transport values:

```swift
case next = 4
case previous = 5
```

Expose bridge methods that call `send(.previous)` and `send(.next)`. Keep the existing rejection log and post-command refresh path unchanged.

- [x] **Step 4: Run the focused test and confirm GREEN**

Run:

```bash
swift test --filter SystemMediaBridgeTests.testSystemControllerCombinesStateAndForwardsCommands
```

Expected: pass.

---

### Task 2: Route Android MPRIS actions and enable the buttons

**Files:**

- Modify: `Tests/MacConnectCoreTests/LocalMprisServiceTests.swift`
- Modify: `Sources/MacConnectCore/Plugin/LocalMprisService.swift`

- [x] **Step 1: Write failing service behavior tests**

Rename the state serialization test to reflect available navigation and change these assertions:

```swift
XCTAssertEqual(response?.body["canGoNext"]?.boolValue, true)
XCTAssertEqual(response?.body["canGoPrevious"]?.boolValue, true)
```

Extend the action-routing test to send both operations and expect:

```swift
_ = service.handle(.action("Previous"))
_ = service.handle(.action("Next"))

XCTAssertEqual(fake.commands, [.play, .pause, .toggle, .previous, .next])
```

Make the fake controller conform to the extended protocol and record the new cases.

- [x] **Step 2: Run the service tests and confirm RED**

Run:

```bash
swift test --filter LocalMprisServiceTests
```

Expected: the navigation capability assertions and action sequence fail.

- [x] **Step 3: Implement the minimal request mapping**

In `LocalMprisService.handle`, map `Previous` and `Next` to the matching controller methods after the existing elected-player identity check. In `currentStatePacket`, set both navigation flags from `snapshot.transportAvailable`:

```swift
"canGoNext": .bool(snapshot.transportAvailable),
"canGoPrevious": .bool(snapshot.transportAvailable),
```

- [x] **Step 4: Run focused and complete tests**

Run:

```bash
swift test --filter LocalMprisServiceTests
swift test
```

Expected: all pass.

---

### Task 3: Document v0.4.1 and validate the source tree

**Files:**

- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [x] **Step 1: Update user-facing documentation**

Clarify in the README that Android can invoke Play, Pause, Previous, and Next on the elected Mac session. Add a v0.4.1 changelog entry dated 2026-08-13 and advance the comparison links from v0.4.0 to v0.4.1.

- [x] **Step 2: Run all local static and build checks**

Run the repository's exact CI-equivalent checks:

```bash
swift test
swift build -c release
./scripts/build-app.sh release
./scripts/build-app.sh release "0.4.1" direct
swiftlint --strict
swiftformat --lint .
```

Also build the universal direct app with version 0.4.1, confirm arm64 and x86_64 slices, confirm its direct-update framework/rpath configuration, and inspect the resulting bundle metadata.

- [x] **Step 3: Review the complete branch diff**

Confirm every changed line is required for Previous/Next or v0.4.1 release documentation, and that existing Play/Pause/volume behavior is untouched.

---

### Task 4: Verify end-to-end on the K60

**Files:**

- No source changes expected.

- [x] **Step 1: Launch the fresh v0.4.1 build**

Quit any older MacConnect process, launch the newly built app, and confirm it connects to the paired K60. Use `ADB_LIBUSB=1` for Wi-Fi ADB and confirm the authorized K60 serial before interacting with it.

- [x] **Step 2: Verify Android control availability**

Open KDE Connect's Multimedia control for MacConnect on the K60, select the active Mac player, and inspect the UI hierarchy to confirm Previous and Next are present and enabled.

- [x] **Step 3: Verify both operations against real media**

Use a deterministic multi-track Music queue. Record the Mac's current track, invoke Next on the K60, confirm the track changes forward, then invoke Previous and confirm it returns. Reconfirm Play/Pause and volume still work. Check IINA when its current media has navigable playlist items.

- [x] **Step 4: Capture concise evidence**

Retain the device serial/state, before/after track names, UI enabled state, and relevant MacConnect logs for the release handoff.

---

### Task 5: Publish the implementation through GitHub

**Files:**

- No additional source changes expected unless CI exposes a defect.

- [ ] **Step 1: Commit and push the reviewed implementation**

Commit the implementation and release notes intentionally on `codex/previous-next-media-controls`, push the branch, and create a ready pull request targeting `main`.

- [ ] **Step 2: Wait for pull-request CI**

Require every GitHub Actions check to pass. If a check fails, inspect its log, reproduce where possible, apply the smallest fix test-first, and rerun all affected validation.

- [ ] **Step 3: Merge and verify main**

Squash-merge the pull request. Fetch the resulting `origin/main` commit and require the main-branch CI run for that exact commit to pass before tagging.

---

### Task 6: Tag and verify v0.4.1

**Files:**

- No source changes expected.

- [ ] **Step 1: Create the release tag**

Create an annotated `v0.4.1` tag on the verified `origin/main` merge commit and push only that tag.

- [ ] **Step 2: Monitor the release workflow**

Require the existing release workflow to finish successfully, including universal build, Developer ID signing, notarization, stapling, DMG/ZIP publication, GitHub Release creation, and Sparkle appcast update.

- [ ] **Step 3: Independently verify published artifacts**

Download the public v0.4.1 DMG and ZIP into a fresh temporary directory. Record SHA-256 hashes, verify expected archive contents, inspect code signatures, run Gatekeeper assessment, validate notarization tickets, and confirm both binary architectures.

- [ ] **Step 4: Verify release metadata and update feed**

Confirm v0.4.1 is GitHub's latest non-draft release, both assets are publicly downloadable, the `latest` URL resolves to v0.4.1, the Pages deployment succeeded, and the published signed Sparkle appcast references the v0.4.1 ZIP with the correct version, length, and signature.

- [ ] **Step 5: Report the released outcome**

Provide the pull request and release links, verification summary, asset hashes, and any narrowly scoped compatibility note discovered during K60 testing.
