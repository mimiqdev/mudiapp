@preconcurrency import Citadel
import Foundation
import HerdrKit
@preconcurrency import NIO
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

/// Opens the NIO SSH connection used by the Citadel adapter.
///
/// Citadel's convenience connector fixes its login timeout at ten seconds.
/// Host-key validation is user-interactive, so this small connection seam owns
/// the handshake handler and gives that decision enough time to complete while
/// retaining Citadel's authentication methods and PTY protocol.
final class NIOSSHConnection: @unchecked Sendable {
    static let hostKeyDecisionTimeout: TimeAmount = .seconds(60)

    let channel: Channel
    let sshHandler: NIOLoopBoundBox<NIOSSHHandler>

    private init(channel: Channel, sshHandler: NIOLoopBoundBox<NIOSSHHandler>) {
        self.channel = channel
        self.sshHandler = sshHandler
    }

    static func connect(
        host: Host,
        authenticationMethod: Citadel.SSHAuthenticationMethod,
        hostKeyValidator: Citadel.SSHHostKeyValidator
    ) async throws -> NIOSSHConnection {
        var clientConfiguration = SSHClientConfiguration(
            userAuthDelegate: authenticationMethod,
            serverAuthDelegate: hostKeyValidator
        )
        clientConfiguration.hostname = host.hostname
        let configuredClient = clientConfiguration

        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                let sshHandler = NIOSSHHandler(
                    role: .client(configuredClient),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { childChannel, _ in
                        childChannel.eventLoop.makeSucceededVoidFuture()
                    }
                )
                let handshakeHandler = MudiSSHHandshakeHandler(
                    eventLoop: channel.eventLoop,
                    loginTimeout: Self.hostKeyDecisionTimeout
                )

                do {
                    try channel.pipeline.syncOperations.addHandlers(
                        sshHandler,
                        handshakeHandler
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connectTimeout(.seconds(30))
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: 1
            )
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY),
                value: 1
            )

        let channel = try await bootstrap
            .connect(host: host.hostname, port: Int(host.port))
            .get()

        do {
            let handshakeHandler = try await channel.pipeline
                .handler(type: MudiSSHHandshakeHandler.self)
                .get()
            try await handshakeHandler.authenticated.get()

            let sshHandlerBox = try await channel.eventLoop.submit {
                let sshHandler = try channel.pipeline.syncOperations.handler(
                    type: NIOSSHHandler.self
                )
                return NIOLoopBoundBox(sshHandler, eventLoop: channel.eventLoop)
            }.get()
            return NIOSSHConnection(channel: channel, sshHandler: sshHandlerBox)
        } catch {
            try? await channel.close()
            throw error
        }
    }
}

private final class MudiSSHHandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let promise: EventLoopPromise<Void>

    var authenticated: EventLoopFuture<Void> {
        promise.futureResult
    }

    init(eventLoop: EventLoop, loginTimeout: TimeAmount) {
        promise = eventLoop.makePromise(of: Void.self)
        eventLoop.scheduleTask(in: loginTimeout) { [promise] in
            promise.fail(ChannelError.connectTimeout(loginTimeout))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise.succeed(())
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(ChannelError.eof)
        context.fireChannelInactive()
    }
}

private enum CitadelPTYChannelError: Error {
    case closed
    case notReady
    case alreadyStarted
    case channelCreationFailed
    case channelFailure
}

/// Bridges an authenticated NIOSSH parent channel to the app's PTY boundary.
actor CitadelPTYChannel: PTYOutputChannel {
    private let connection: NIOSSHConnection
    private let output: AsyncThrowingStream<[UInt8], Error>
    private let outputContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private var childChannel: Channel?
    private var closeRequested = false
    private var started = false

    init(connection: NIOSSHConnection) {
        self.connection = connection
        var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        output = AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation = $0 }
        outputContinuation = continuation
    }

    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> {
        output
    }

    func start() async throws {
        guard !started else {
            throw CitadelPTYChannelError.alreadyStarted
        }
        guard !closeRequested else {
            throw CitadelPTYChannelError.closed
        }
        started = true

        let handler = NIOPTYChannelHandler(continuation: outputContinuation)
        let childChannel: Channel
        do {
            childChannel = try await connection.channel.eventLoop.flatSubmit { [connection, handler] in
                let createChannel = connection.channel.eventLoop.makePromise(of: Channel.self)
                connection.sshHandler.value.createChannel(
                    createChannel,
                    channelType: .session
                ) { channel, _ in
                    channel.pipeline.addHandler(handler)
                }
                connection.channel.eventLoop.scheduleTask(in: .seconds(15)) {
                    createChannel.fail(CitadelPTYChannelError.channelCreationFailed)
                }
                return createChannel.futureResult
            }.get()
        } catch {
            throw error
        }

        self.childChannel = childChannel
        guard !closeRequested else {
            try? await childChannel.close()
            throw CitadelPTYChannelError.closed
        }

        try await childChannel.triggerUserOutboundEvent(Self.ptyRequest)
        try await childChannel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ShellRequest(wantReply: true)
        )
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !closeRequested else {
            throw CitadelPTYChannelError.closed
        }
        guard let childChannel else {
            throw CitadelPTYChannelError.notReady
        }

        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await childChannel.writeAndFlush(
            SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        )
    }

    func resize(columns: Int, rows: Int) async throws {
        guard columns > 0, rows > 0 else {
            return
        }
        guard !closeRequested else {
            throw CitadelPTYChannelError.closed
        }
        guard let childChannel else {
            throw CitadelPTYChannelError.notReady
        }

        try await childChannel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: columns,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            )
        )
    }

    func close() async {
        guard !closeRequested else { return }
        closeRequested = true
        outputContinuation.finish()

        if let childChannel {
            try? await childChannel.close()
        }
        try? await connection.channel.close()
    }

    private static let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
        wantReply: true,
        term: "xterm-256color",
        terminalCharacterWidth: 80,
        terminalRowHeight: 24,
        terminalPixelWidth: 0,
        terminalPixelHeight: 0,
        terminalModes: SSHTerminalModes([:])
    )
}

private final class NIOPTYChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation

    init(continuation: AsyncThrowingStream<[UInt8], Error>.Continuation) {
        self.continuation = continuation
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel
            .setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { [continuation] error in
                continuation.finish(throwing: error)
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = data.data else {
            continuation.finish(throwing: CitadelPTYChannelError.channelFailure)
            return
        }
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }
        if !bytes.isEmpty {
            continuation.yield(bytes)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelFailureEvent {
            continuation.finish(throwing: CitadelPTYChannelError.channelFailure)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.fireErrorCaught(error)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        continuation.finish()
    }
}
