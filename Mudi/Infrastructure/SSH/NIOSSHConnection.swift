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
    static let commandTimeout: TimeAmount = .seconds(10)

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

    /// Executes a command on a new SSH session channel. The caller's PTY
    /// channel is left untouched, including its output stream.
    func execute(_ command: String, maxOutputBytes: Int = 1_048_576) async throws -> [UInt8] {
        let eventLoop = channel.eventLoop
        let sshHandler = self.sshHandler
        let promise = eventLoop.makePromise(of: [UInt8].self)
        let responseHandler = NIOExecCommandHandler(
            maxOutputBytes: maxOutputBytes,
            promise: promise
        )

        let execChannel: Channel
        do {
            execChannel = try await eventLoop.flatSubmit {
                let createChannel = eventLoop.makePromise(of: Channel.self)
                sshHandler.value.createChannel(createChannel) { channel, _ in
                    channel.pipeline.addHandler(responseHandler)
                }
                eventLoop.scheduleTask(in: .seconds(15)) {
                    createChannel.fail(CitadelPTYChannelError.channelCreationFailed)
                }
                return createChannel.futureResult
            }.get()
        } catch {
            promise.fail(error)
            throw error
        }

        let timeoutTask = eventLoop.scheduleTask(in: Self.commandTimeout) {
            responseHandler.timeout()
            execChannel.close(promise: nil)
        }

        do {
            defer { timeoutTask.cancel() }
            try await execChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
            return try await promise.futureResult.get()
        } catch {
            try? await execChannel.close()
            throw error
        }
    }

    /// Opens an interactive exec channel on a new SSH session channel. It is
    /// independent from the shell PTY and is ready only after the command has
    /// produced its first control response.
    func openInteractiveCommand(_ command: String) async throws -> any PTYOutputChannel {
        let interactiveChannel = CitadelInteractivePTYChannel(
            connection: self,
            command: command
        )
        try await interactiveChannel.start()
        return interactiveChannel
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

private enum NIOExecCommandError: Error {
    case timeout
}

enum SSHInteractiveCommandError: Error, LocalizedError, Sendable {
    case commandFailed(exitCode: Int, message: String?)
    case noInitialResponse
    case channelClosed
    case invalidData
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case let .commandFailed(exitCode, message):
            if let message, !message.isEmpty {
                return "The remote terminal command failed (status \(exitCode)): \(message)"
            }
            return "The remote terminal command failed with status \(exitCode)."
        case .noInitialResponse:
            return "The remote terminal command did not produce an initial response."
        case .channelClosed:
            return "The remote terminal control channel closed unexpectedly."
        case .invalidData:
            return "The remote terminal returned invalid data."
        case .outputTooLarge:
            return "The remote command returned too much data."
        }
    }
}

private final class NIOExecCommandHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let maxOutputBytes: Int
    private let promise: EventLoopPromise<[UInt8]>
    private var output: [UInt8] = []
    private var stderr: [UInt8] = []
    private var exitStatus: Int?
    private var finished = false

    init(maxOutputBytes: Int, promise: EventLoopPromise<[UInt8]>) {
        self.maxOutputBytes = maxOutputBytes
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel
            .setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { [promise] error in
                promise.fail(error)
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = data.data else {
            fail(SSHInteractiveCommandError.invalidData)
            context.close(promise: nil)
            return
        }

        switch data.type {
        case .channel:
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            guard output.count + bytes.count <= maxOutputBytes else {
                fail(SSHInteractiveCommandError.outputTooLarge)
                context.close(promise: nil)
                return
            }
            output.append(contentsOf: bytes)
        case .stdErr:
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                stderr.append(contentsOf: bytes)
            }
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
            if status.exitStatus != 0 {
                fail(SSHInteractiveCommandError.commandFailed(
                    exitCode: status.exitStatus,
                    message: String(bytes: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
            context.close(promise: nil)
        case is ChannelFailureEvent:
            fail(SSHInteractiveCommandError.channelClosed)
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished {
            if exitStatus == 0 {
                finish(.success(output))
            } else {
                finish(.failure(SSHInteractiveCommandError.channelClosed))
            }
        }
        context.fireChannelInactive()
    }

    func timeout() {
        fail(NIOExecCommandError.timeout)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if !finished {
            if exitStatus == 0 {
                finish(.success(output))
            } else {
                finish(.failure(SSHInteractiveCommandError.channelClosed))
            }
        }
    }

    private func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<[UInt8], Error>) {
        guard !finished else { return }
        finished = true
        switch result {
        case let .success(output):
            promise.succeed(output)
        case let .failure(error):
            promise.fail(error)
        }
    }
}

/// An interactive exec channel used by Herdr's terminal control protocol.
/// Its output is independent from the ordinary shell PTY.
private actor CitadelInteractivePTYChannel: PTYOutputChannel {
    private let connection: NIOSSHConnection
    private let command: String
    private let output: AsyncThrowingStream<[UInt8], Error>
    private let outputContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let readiness: AsyncThrowingStream<Void, Error>
    private let readinessContinuation: AsyncThrowingStream<Void, Error>.Continuation
    private var childChannel: Channel?
    private var closeRequested = false
    private var started = false

    init(connection: NIOSSHConnection, command: String) {
        self.connection = connection
        self.command = command
        var outputContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        output = AsyncThrowingStream(bufferingPolicy: .unbounded) {
            outputContinuation = $0
        }
        self.outputContinuation = outputContinuation
        var readinessContinuation: AsyncThrowingStream<Void, Error>.Continuation!
        readiness = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) {
            readinessContinuation = $0
        }
        self.readinessContinuation = readinessContinuation
    }

    func start() async throws {
        guard !started else { throw CitadelPTYChannelError.alreadyStarted }
        guard !closeRequested else { throw CitadelPTYChannelError.closed }
        started = true

        let handler = NIOInteractiveCommandHandler(
            output: outputContinuation,
            readiness: readinessContinuation
        )
        let eventLoop = connection.channel.eventLoop
        let sshHandler = connection.sshHandler
        let childChannel: Channel
        do {
            childChannel = try await eventLoop.flatSubmit {
                let createChannel = eventLoop.makePromise(of: Channel.self)
                sshHandler.value.createChannel(createChannel) { channel, _ in
                    channel.pipeline.addHandler(handler)
                }
                eventLoop.scheduleTask(in: .seconds(15)) {
                    createChannel.fail(CitadelPTYChannelError.channelCreationFailed)
                }
                return createChannel.futureResult
            }.get()
        } catch {
            outputContinuation.finish(throwing: error)
            readinessContinuation.finish(throwing: error)
            throw error
        }

        self.childChannel = childChannel
        do {
            for (name, value) in TerminalPTYCapabilities.environment.sorted(
                by: { $0.key < $1.key }
            ) {
                try await childChannel.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.EnvironmentRequest(
                        wantReply: false,
                        name: name,
                        value: value
                    )
                )
            }
            try await childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
            try await waitForReadiness()
        } catch {
            await close()
            throw error
        }
    }

    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> {
        output
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !closeRequested else { throw CitadelPTYChannelError.closed }
        guard let childChannel else { throw CitadelPTYChannelError.notReady }
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await childChannel.writeAndFlush(
            SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        )
    }

    func resize(columns: Int, rows: Int) async throws {
        guard columns > 0, rows > 0 else { return }
        guard !closeRequested else { throw CitadelPTYChannelError.closed }
        guard let childChannel else { throw CitadelPTYChannelError.notReady }
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
        readinessContinuation.finish()
        if let childChannel {
            try? await childChannel.close()
        }
    }

    private func waitForReadiness() async throws {
        let readiness = readiness
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = readiness.makeAsyncIterator()
                guard try await iterator.next() != nil else {
                    throw SSHInteractiveCommandError.noInitialResponse
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw SSHInteractiveCommandError.noInitialResponse
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private final class NIOInteractiveCommandHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let output: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let readiness: AsyncThrowingStream<Void, Error>.Continuation
    private var initialOutput: [UInt8] = []
    private var didSignalReadiness = false
    private var didFinish = false

    init(
        output: AsyncThrowingStream<[UInt8], Error>.Continuation,
        readiness: AsyncThrowingStream<Void, Error>.Continuation
    ) {
        self.output = output
        self.readiness = readiness
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel
            .setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { [self] error in
                fail(error)
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = data.data else {
            fail(SSHInteractiveCommandError.invalidData)
            context.close(promise: nil)
            return
        }
        switch data.type {
        case .channel:
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            guard !bytes.isEmpty else { return }
            if !didSignalReadiness {
                initialOutput.append(contentsOf: bytes)
                if let error = Self.initialResponseError(in: initialOutput) {
                    fail(error)
                    context.close(promise: nil)
                    return
                }
            }
            output.yield(bytes)
            signalReadiness()
        case .stdErr:
            // Login shells and herdr may write warnings to stderr. Killing the
            // channel here made pane attach look connected then immediately fail.
            break
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            if status.exitStatus != 0 {
                fail(SSHInteractiveCommandError.commandFailed(exitCode: status.exitStatus, message: nil))
            } else if !didSignalReadiness {
                fail(SSHInteractiveCommandError.noInitialResponse)
            }
            context.close(promise: nil)
        case is ChannelFailureEvent:
            fail(SSHInteractiveCommandError.channelClosed)
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish()
    }

    private func signalReadiness() {
        guard !didSignalReadiness else { return }
        didSignalReadiness = true
        readiness.yield(())
        readiness.finish()
    }

    private static func initialResponseError(in bytes: [UInt8]) -> Error? {
        guard let newline = bytes.firstIndex(of: 0x0a) else { return nil }
        let firstLine = Array(bytes[..<newline])
        guard let object = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any]
        else {
            return nil
        }
        let type = (object["type"] as? String)?.lowercased() ?? ""
        let status = (object["status"] as? String)?.lowercased() ?? ""
        guard type.contains("error") || type.contains("fail")
            || status.contains("error") || status.contains("fail")
        else {
            return nil
        }
        let message = object["message"] as? String
        return SSHInteractiveCommandError.commandFailed(
            exitCode: 1,
            message: message
        )
    }

    private func fail(_ error: Error) {
        guard !didFinish else { return }
        didFinish = true
        readiness.finish(throwing: error)
        output.finish(throwing: error)
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        if !didSignalReadiness {
            readiness.finish(throwing: SSHInteractiveCommandError.channelClosed)
        } else {
            readiness.finish()
        }
        output.finish()
    }
}

/// Bridges an authenticated NIOSSH parent channel to the app's PTY boundary.
actor CitadelPTYChannel: PTYOutputChannel, SSHCommandExecutingChannel, SSHInteractiveCommandChannel {
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

    func execute(_ command: String) async throws -> [UInt8] {
        try await connection.execute(command)
    }

    func openInteractiveCommand(_ command: String) async throws -> any PTYOutputChannel {
        try await connection.openInteractiveCommand(command)
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
        for (name, value) in TerminalPTYCapabilities.environment.sorted(
            by: { $0.key < $1.key }
        ) {
            try await childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.EnvironmentRequest(
                    wantReply: false,
                    name: name,
                    value: value
                )
            )
        }
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
