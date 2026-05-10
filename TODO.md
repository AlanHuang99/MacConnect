# MacConnect — Roadmap

## Milestone 1: TLS upgrade + pairing (current blocker)

Without TLS, paired devices and unpaired devices cannot complete the handshake, so plugins cannot fire. This is the single highest-value next step.

**The problem:** KDE Connect's protocol sends an identity packet over plain TCP, then both sides upgrade the same socket to TLS via `startTLS`. Apple's `NWConnection` does **not** support adding TLS to an existing connection — TLS is configured at construction time.

**Options considered:**

| Option | Pros | Cons |
|---|---|---|
| Pull in CocoaAsyncSocket via SwiftPM | Mirrors iOS app exactly | Brings back the Obj-C dep we're trying to escape |
| Use `Network.framework`'s `NWProtocolFramer` to switch in-band | Pure Apple, no new deps | Undocumented gymnastics, fragile |
| **`swift-nio` + `swift-nio-ssl`** | Clean upgrade story (`channel.pipeline.addHandler(SslHandler)`), modern, Apple-supported | Adds BoringSSL via SwiftPM; adds a second async runtime |
| `SecureTransport` over BSD sockets | No new deps | `SecureTransport` is deprecated as of macOS 13 |

**Decision:** swift-nio path. Estimated 1–2 sessions to wire up.

Sub-tasks:
- [ ] Replace `LanLinkProvider`'s TCP listener with `NIOAsyncChannel<ByteBuffer, ByteBuffer>`
- [ ] Implement custom `ChannelHandler` that reads plain identity then triggers `addHandler(NIOSSLServerHandler)`
- [ ] Mirror on the client side (read identity, then `NIOSSLClientHandler`)
- [ ] Wire `CertificateService.loadIdentity()` into `NIOSSLContext` configuration (PEM in-memory)
- [ ] Implement custom verify callback for first-pairing (TUFU) and pinning (after pair)
- [ ] Wire pair-accept to call `markTrusted` + persist remote cert via `CertificateService.storeRemoteCert`

## Milestone 2: mDNS / Bonjour announcement

Modern KDE Connect uses mDNS in addition to UDP broadcast. The iOS app has `MdnsDiscovery.swift`. Use `NWBrowser` for discovery + `NWListener` with `service:` parameter for announcement.

## Milestone 3: File transfer

KDE Connect file transfer opens a *second* TLS connection on a port advertised in `payloadTransferInfo.port`. Once Milestone 1 lands, this is straightforward: handle `kdeconnect.share.request` with `payloadSize`, open a second TLS client connection, read N bytes, write to `~/Downloads/`.

## Milestone 4: MPRIS state in menu bar

Parse `kdeconnect.mpris` packets into a `MprisStore`, render a now-playing tile in the popover with PlayPause / Next / Prev / volume slider.

## Milestone 5: Notification reply

`kdeconnect.notification.reply` lets us reply to phone notifications inline. Surface as a NSUserNotification action button.

## Polish

- [ ] Code-sign and notarize the .app for distribution
- [ ] Add a Login Item registration helper (`SMAppService`)
- [ ] App icon
- [ ] Settings window (rename device, manage trusted devices, show fingerprints)
- [ ] Localization
