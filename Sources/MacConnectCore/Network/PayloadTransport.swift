import Foundation
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
                        donePromise.succeed(())
                    },
                    onError: { err in
                        onError(err)
                        donePromise.fail(err)
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
            donePromise.fail(err)
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
                donePromise.fail(err)
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

    private var bytesReceived: Int64 = 0
    private var fileHandle: FileHandle?

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
        let bytes = Array(buf.readableBytesView)
        guard !bytes.isEmpty else { return }
        do {
            try fileHandle?.write(contentsOf: bytes)
            bytesReceived += Int64(bytes.count)
            if expectedSize > 0, bytesReceived >= expectedSize {
                finish(context: context, success: true)
            }
        } catch {
            finish(context: context, success: false, error: error)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if expectedSize == 0 || bytesReceived > 0 {
            // Variable-size or got something — treat as complete on close
            finish(context: context, success: bytesReceived >= max(expectedSize, 0))
        } else {
            finish(context: context, success: false)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(context: context, success: false, error: error)
        context.close(promise: nil)
    }

    private var finished = false
    private func finish(context: ChannelHandlerContext, success: Bool, error: Error? = nil) {
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
