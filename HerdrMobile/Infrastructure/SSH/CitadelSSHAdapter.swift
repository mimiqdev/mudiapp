@preconcurrency import Citadel
import Foundation
import HerdrKit
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

/// A Citadel-backed implementation of the HerdrKit SSH shell boundary.
///
/// The Citadel client and its authentication method are retained only by the
/// active PTY channel. Closing that channel closes the SSH client as well.
struct CitadelSSHAdapter: HerdrKit.SSHClient {
    static let transportKind = ActiveTransport.ssh

    func connect(
        to host: HerdrKit.Host,
        credentials: HerdrKit.SSHCredentials
    ) async throws -> any PTYChannel {
        guard let password = credentials.password, !password.isEmpty else {
            throw HerdrKit.SSHClientError.authenticationFailed
        }

        let client: Citadel.SSHClient
        do {
            client = try await Citadel.SSHClient.connect(
                host: host.hostname,
                port: Int(host.port),
                authenticationMethod: .passwordBased(
                    username: host.username,
                    password: password
                ),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        } catch let error as Citadel.SSHClientError {
            switch error {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                throw HerdrKit.SSHClientError.authenticationFailed
            case .channelCreationFailed:
                throw error
            }
        } catch is Citadel.AuthenticationFailed {
            throw HerdrKit.SSHClientError.authenticationFailed
        }

        let channel = CitadelPTYChannel(client: client)
        do {
            try await channel.start()
            return channel
        } catch {
            await channel.close()
            throw error
        }
    }
}

private enum CitadelPTYChannelError: Error {
    case closed
    case notReady
    case alreadyStarted
}

/// Bridges Citadel's scoped `withPTY` API to the long-lived PTYChannel used by
/// the app. The scoped closure stays alive until `close()` is requested, while
/// its input and output are exposed through the HerdrKit shell seam.
private actor CitadelPTYChannel: PTYOutputChannel {
    private let output: AsyncThrowingStream<[UInt8], Error>
    private let outputContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private var client: Citadel.SSHClient?
    private var writer: TTYStdinWriter?
    private var runTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyResult: Result<Void, Error>?
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeRequested = false
    private var finished = false
    private var outputFinished = false

    init(client: Citadel.SSHClient) {
        self.client = client
        var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        self.output = AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.outputContinuation = continuation
    }

    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> {
        output
    }

    func start() async throws {
        guard runTask == nil else {
            throw CitadelPTYChannelError.alreadyStarted
        }
        guard let client else {
            throw CitadelPTYChannelError.closed
        }

        runTask = Task { [weak self, client] in
            await self?.run(client: client)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let readyResult {
                continuation.resume(with: readyResult)
            } else {
                readyContinuation = continuation
            }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !closeRequested else {
            throw CitadelPTYChannelError.closed
        }
        guard let writer else {
            throw CitadelPTYChannelError.notReady
        }

        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await writer.write(buffer)
    }

    func resize(columns: Int, rows: Int) async throws {
        guard columns > 0, rows > 0 else {
            return
        }
        guard !closeRequested else {
            throw CitadelPTYChannelError.closed
        }
        guard let writer else {
            throw CitadelPTYChannelError.notReady
        }

        try await writer.changeSize(
            cols: columns,
            rows: rows,
            pixelWidth: 0,
            pixelHeight: 0
        )
    }

    func close() async {
        if !closeRequested {
            closeRequested = true
            writer = nil
            finishOutput()
            signalClose()
        }

        guard !finished else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            terminationWaiters.append(continuation)
        }
    }

    private func run(client: Citadel.SSHClient) async {
        var runError: Error?

        do {
            try await client.withPTY(Self.ptyRequest) { [weak self] inbound, outbound in
                guard let self else { return }

                await self.markReady(with: outbound)
                let outputTask = Task { [weak self] in
                    do {
                        for try await value in inbound {
                            switch value {
                            case .stdout(var buffer), .stderr(var buffer):
                                guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
                                    continue
                                }
                                await self?.yield(bytes)
                            }
                        }
                    } catch {
                        await self?.finishOutput(with: error)
                    }
                    await self?.remoteOutputFinished()
                }

                await self.waitUntilClosed()
                outputTask.cancel()
                _ = await outputTask.result
            }
        } catch {
            runError = error
        }

        try? await client.close()
        finishRun(with: runError)
    }

    private func markReady(with writer: TTYStdinWriter) {
        guard !closeRequested else { return }
        self.writer = writer
        completeReady(with: .success(()))
    }

    private func waitUntilClosed() async {
        guard !closeRequested else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            closeContinuation = continuation
        }
    }

    private func signalClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }

    private func yield(_ bytes: [UInt8]) {
        guard !outputFinished else { return }
        outputContinuation.yield(bytes)
    }

    private func finishOutput(with error: Error? = nil) {
        guard !outputFinished else { return }
        outputFinished = true
        if let error {
            outputContinuation.finish(throwing: error)
        } else {
            outputContinuation.finish()
        }
    }

    private func remoteOutputFinished() {
        closeRequested = true
        writer = nil
        signalClose()
    }

    private func completeReady(with result: Result<Void, Error>) {
        guard readyResult == nil else {
            return
        }
        readyResult = result
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(with: result)
        }
    }

    private func finishRun(with error: Error?) {
        guard !finished else { return }
        finished = true
        client = nil
        writer = nil

        if readyResult == nil {
            completeReady(with: .failure(error ?? CitadelPTYChannelError.notReady))
        }
        finishOutput(with: error)
        signalClose()

        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
