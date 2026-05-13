import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// File-payload TLS transport for KDE Connect's `share.request` flow.
///
/// Sender opens a TLS server on a free port (1739…1764), advertises that
/// port in the `payloadTransferInfo.port` of `kdeconnect.share.request`,
/// then streams file bytes once the receiver connects + handshakes. The
/// receiver does the inverse: TLS-client connect to host:port, write all
/// bytes to a target file. Both sides use the existing per-device cert pin.
public enum PayloadTransport {

    public static let portRange: ClosedRange<UInt16> = 1739...1764
    public static let chunkBytes: Int = 64 * 1024

    // MARK: - Sender

    /// Bind a one-shot TLS listener on a free port in the payload range and
    /// return the bound port immediately (the future server resolves when
    /// the file has been streamed and the connection closed).
    public static func startSender(
        fileURL: URL,
        peerDeviceId: String,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) -> (port: UInt16, finished: EventLoopFuture<Void>) {
        let group = NIOTransport.shared.group
        let context = NIOTransport.shared.sslContext
        let donePromise = group.next().makePromise(of: Void.self)
        // Guard the three potentially-racing fulfilment sites (handler
        // complete, handler error, defensive timeout). NIO promises crash
        // hard on double-fulfil, so the bool is the safety boundary.
        let doneFlag = NIOLockedValueBox(false)
        @Sendable func trySucceed() {
            let already = doneFlag.withLockedValue { val -> Bool in
                let was = val
                val = true
                return was
            }
            if !already { donePromise.succeed(()) }
        }
        @Sendable func tryFail(_ err: Error) {
            let already = doneFlag.withLockedValue { val -> Bool in
                let was = val
                val = true
                return was
            }
            if !already { donePromise.fail(err) }
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let sslHandler = NIOSSLServerHandler(
                    context: context,
                    customVerificationCallback: TLSContextBuilder.verifier(forKnownDeviceId: peerDeviceId)
                )
                let payload = PayloadSenderHandler(
                    fileURL: fileURL,
                    onComplete: {
                        onComplete()
                        trySucceed()
                    },
                    onError: { err in
                        onError(err)
                        tryFail(err)
                    }
                )
                do {
                    try channel.pipeline.syncOperations.addHandler(sslHandler)
                    try channel.pipeline.syncOperations.addHandler(payload)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        var boundPort: UInt16?
        var serverChannel: Channel?
        for port in portRange {
            do {
                let ch = try bootstrap.bind(host: "0.0.0.0", port: Int(port)).wait()
                serverChannel = ch
                boundPort = port
                break
            } catch {
                continue
            }
        }
        guard let port = boundPort, let serverChannel else {
            let err = NSError(domain: "MacConnect.Payload", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No free payload port"])
            onError(err)
            tryFail(err)
            return (0, donePromise.futureResult)
        }

        // After completion, close the server channel.
        donePromise.futureResult.whenComplete { _ in
            serverChannel.close(promise: nil)
        }
        // Defensive timeout: if the receiver never connects within 60s, give up.
        group.next().scheduleTask(in: .seconds(60)) {
            if serverChannel.isActive {
                Log.net.warning("Payload listener on \(port, privacy: .public) timed out")
                serverChannel.close(promise: nil)
                let err = NSError(domain: "MacConnect.Payload", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Receiver never connected"])
                tryFail(err)
            }
        }

        Log.net.info("Payload listener bound on port \(port, privacy: .public) for \(fileURL.lastPathComponent, privacy: .public)")
        return (port, donePromise.futureResult)
    }

    // MARK: - Receiver

    public static func startReceiver(
        host: String,
        port: UInt16,
        fileURL: URL,
        expectedSize: Int64,
        peerDeviceId: String,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        let group = NIOTransport.shared.group
        let context = NIOTransport.shared.sslContext

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                do {
                    let ssl = try NIOSSLClientHandler(
                        context: context,
                        serverHostname: nil,
                        customVerificationCallback: TLSContextBuilder.verifier(forKnownDeviceId: peerDeviceId)
                    )
                    let receiver = PayloadReceiverHandler(
                        fileURL: fileURL,
                        expectedSize: expectedSize,
                        onComplete: onComplete,
                        onError: onError
                    )
                    try channel.pipeline.syncOperations.addHandler(ssl)
                    try channel.pipeline.syncOperations.addHandler(receiver)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connectTimeout(.seconds(10))

        bootstrap.connect(host: host, port: Int(port)).whenComplete { result in
            switch result {
            case .success:
                Log.net.info("Payload receiver connected to \(host, privacy: .public):\(port, privacy: .public)")
            case .failure(let err):
                onError(err)
            }
        }
    }
}

// MARK: - Sender pipeline handler

final class PayloadSenderHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let fileURL: URL
    private let onComplete: @Sendable () -> Void
    private let onError: @Sendable (Error) -> Void
    private var streaming = false
    private let queue = DispatchQueue(label: "macconnect.payload.send", qos: .userInitiated)

    init(
        fileURL: URL,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.fileURL = fileURL
        self.onComplete = onComplete
        self.onError = onError
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls {
            streamFile(context: context)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Log.net.error("Payload sender error: \(error.localizedDescription, privacy: .public)")
        onError(error)
        context.close(promise: nil)
    }

    private func streamFile(context: ChannelHandlerContext) {
        guard !streaming else { return }
        streaming = true
        let url = fileURL
        let allocator = context.channel.allocator
        let channel = context.channel

        queue.async { [self] in
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while true {
                    let chunk = handle.readData(ofLength: PayloadTransport.chunkBytes)
                    if chunk.isEmpty { break }
                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    channel.eventLoop.execute {
                        var buf = allocator.buffer(capacity: chunk.count)
                        buf.writeBytes(chunk)
                        channel.writeAndFlush(buf, promise: promise)
                    }
                    do {
                        try promise.futureResult.wait()
                    } catch {
                        self.onError(error)
                        channel.eventLoop.execute { channel.close(promise: nil) }
                        return
                    }
                }
                channel.eventLoop.execute {
                    self.onComplete()
                    channel.close(promise: nil)
                }
            } catch {
                Log.net.error("Payload read error: \(error.localizedDescription, privacy: .public)")
                self.onError(error)
                channel.eventLoop.execute { channel.close(promise: nil) }
            }
        }
    }
}

// MARK: - Receiver pipeline handler

final class PayloadReceiverHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let fileURL: URL
    private let expectedSize: Int64
    private let onComplete: @Sendable () -> Void
    private let onError: @Sendable (Error) -> Void

    /// Serial queue for disk writes. The previous implementation wrote on
    /// the event loop, blocking every other channel that shared the loop
    /// for the duration of each FileHandle.write — a multi-GB receive
    /// could starve clipboard pings and identity broadcasts.
    private let writeQueue = DispatchQueue(label: "macconnect.payload.receive.write", qos: .utility)
    /// Last in-flight write's completion future. New chunks chain off this
    /// so disk writes stay strictly ordered.
    private var writeChain: EventLoopFuture<Void>?
    private var bytesReceived: Int64 = 0
    private var fileHandle: FileHandle?
    /// Pending writes (chunks copied off ByteBuffer but not yet flushed to
    /// disk). When this exceeds `maxPendingWrites` we turn NIO's autoRead
    /// off so a fast sender + slow disk doesn't accumulate unbounded
    /// `Data` copies in memory; we re-enable autoRead when the count drops
    /// back below the threshold.
    private var pendingWrites: Int = 0
    private var autoReadDisabled: Bool = false
    /// Chosen to keep ≤ ~ chunkBytes × maxPendingWrites bytes (4 MB) in
    /// flight at any one time — enough to keep the disk busy without
    /// letting the network completely outrun it on a slow SSD.
    private static let maxPendingWrites = 64

    init(
        fileURL: URL,
        expectedSize: Int64,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.fileURL = fileURL
        self.expectedSize = expectedSize
        self.onComplete = onComplete
        self.onError = onError
    }

    func handlerAdded(context: ChannelHandlerContext) {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        if fileHandle == nil {
            onError(NSError(domain: "MacConnect.Payload", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Could not open output file"]))
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        let len = buf.readableBytes
        guard len > 0 else { return }
        // Copy bytes off the ByteBuffer on the event loop (cheap, ~64 KiB).
        // The Data is then handed to the write queue; the original buffer
        // is free to be reused by NIO as soon as channelRead returns.
        var data = Data(count: len)
        buf.withUnsafeReadableBytes { src in
            data.withUnsafeMutableBytes { dst in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                dstBase.copyMemory(from: srcBase, byteCount: len)
            }
        }

        let channel = context.channel
        let eventLoop = context.eventLoop
        let promise = eventLoop.makePromise(of: Void.self)

        // Chain this write after the previous one so the file stream stays
        // ordered. If the queue depth is climbing past the threshold,
        // disable autoRead so NIO stops handing us more bytes than the
        // disk can absorb. We re-enable in the per-write completion below.
        pendingWrites += 1
        if pendingWrites >= Self.maxPendingWrites, !autoReadDisabled {
            autoReadDisabled = true
            _ = channel.setOption(ChannelOptions.autoRead, value: false)
        }

        let previous = writeChain ?? eventLoop.makeSucceededVoidFuture()
        writeChain = promise.futureResult
        let handle = fileHandle
        let byteCount = len
        let dataToWrite = data
        previous.whenComplete { _ in
            self.writeQueue.async {
                do {
                    try handle?.write(contentsOf: dataToWrite)
                    eventLoop.execute {
                        self.bytesReceived += Int64(byteCount)
                        self.completeOneWrite(channel: channel)
                        if self.expectedSize > 0, self.bytesReceived >= self.expectedSize {
                            self.finish(on: channel, success: true)
                        }
                        promise.succeed(())
                    }
                } catch {
                    eventLoop.execute {
                        self.completeOneWrite(channel: channel)
                        self.finish(on: channel, success: false, error: error)
                        promise.succeed(()) // Chain continues so other queued writes don't deadlock.
                    }
                }
            }
        }
    }

    /// Called on the event loop after each disk write resolves. Drops the
    /// in-flight counter and lifts the autoRead lock if the queue has
    /// drained enough — under a small hysteresis (half of the cap) so we
    /// don't toggle autoRead on every chunk.
    private func completeOneWrite(channel: Channel) {
        pendingWrites = max(0, pendingWrites - 1)
        if autoReadDisabled, pendingWrites < Self.maxPendingWrites / 2 {
            autoReadDisabled = false
            _ = channel.setOption(ChannelOptions.autoRead, value: true)
            // Kick a read explicitly; setOption alone doesn't request the
            // next read.
            channel.read()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let channel = context.channel
        // Drain any pending writes before deciding success — channelInactive
        // can fire while bytes are still being copied to disk.
        let pending = writeChain ?? context.eventLoop.makeSucceededVoidFuture()
        pending.whenComplete { [self] _ in
            if expectedSize == 0 || bytesReceived > 0 {
                finish(on: channel, success: bytesReceived >= max(expectedSize, 0))
            } else {
                finish(on: channel, success: false)
            }
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(on: context.channel, success: false, error: error)
        context.close(promise: nil)
    }

    private var finished = false
    private func finish(on channel: Channel, success: Bool, error: Error? = nil) {
        guard !finished else { return }
        finished = true
        try? fileHandle?.close()
        fileHandle = nil
        if success {
            Log.net.info("Payload received \(self.bytesReceived, privacy: .public) bytes -> \(self.fileURL.lastPathComponent, privacy: .public)")
            onComplete()
        } else {
            try? FileManager.default.removeItem(at: fileURL)
            let err = error ?? NSError(domain: "MacConnect.Payload", code: 4,
                                       userInfo: [NSLocalizedDescriptionKey: "Connection closed before file complete"])
            Log.net.error("Payload receive failed: \(err.localizedDescription, privacy: .public)")
            onError(err)
        }
    }
}
