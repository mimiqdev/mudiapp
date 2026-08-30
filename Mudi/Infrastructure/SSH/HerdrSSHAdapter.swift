import Foundation
import HerdrKit

enum SSHHerdrTerminalTransportError: Error, LocalizedError, Sendable {
    case paneUnavailable
    case attachFailed

    var errorDescription: String? {
        switch self {
        case .paneUnavailable:
            "The selected Herdr pane is no longer available."
        case .attachFailed:
            "Unable to open the selected Herdr pane."
        }
    }
}

/// Adapts a dedicated Herdr control exec channel to the phase-3 terminal boundary.
///
/// Wire format is the published CLI contract:
/// `herdr terminal session control <target> [--takeover] [--cols N] [--rows N]`
/// stdin: `terminal.input` / `terminal.resize` / `terminal.release`
/// stdout: `terminal.frame` / `terminal.closed`
actor SSHHerdrTerminalTransport: TerminalTransport, HerdrTerminalSessionProviding,
    HerdrSessionAwareTerminalTransport {
    nonisolated let kind: ActiveTransport = .ssh
    private let session: SSHShellSession
    private var attachedSession: SSHShellSession?

    init(session: SSHShellSession) {
        self.session = session
    }

    func connect(to _: Host) async throws {}

    func attach(to pane: Pane) async throws {
        try await attach(to: pane, sessionName: nil)
    }

    func attach(to pane: Pane, in session: HerdrSession) async throws {
        let sessionName = session.isDefault ? nil : session.name
        try await attach(to: pane, sessionName: sessionName)
    }

    private func attach(to pane: Pane, sessionName: String?) async throws {
        let target = SSHLoginShellCommand.shellQuote(pane.id)
        let sessionOption = sessionName.map {
            "--session \(SSHLoginShellCommand.shellQuote($0)) "
        } ?? ""
        let inner =
            "exec herdr \(sessionOption)terminal session control \(target) --takeover --cols 80 --rows 24"
        let command =
            "\"${SHELL:-/bin/sh}\" -lc \(SSHLoginShellCommand.shellQuote(inner))"
        let channel: any PTYOutputChannel
        do {
            channel = try await session.openInteractiveCommand(command)
        } catch is SSHInteractiveCommandError {
            throw SSHHerdrTerminalTransportError.paneUnavailable
        } catch {
            throw SSHHerdrTerminalTransportError.attachFailed
        }

        let controlChannel = HerdrControlChannel(underlying: channel)
        await controlChannel.start()
        let newSession = SSHShellSession(connectedChannel: controlChannel)
        if let previousSession = attachedSession {
            await previousSession.disconnect()
        }
        attachedSession = newSession
    }

    func terminalSession() async -> SSHShellSession? {
        attachedSession
    }

    func releaseTerminalSession() async {
        if let attachedSession {
            await attachedSession.disconnect()
            self.attachedSession = nil
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        if let attachedSession {
            try await attachedSession.send(bytes)
        } else {
            try await session.send(bytes)
        }
    }

    func resize(columns: Int, rows: Int) async throws {
        if let attachedSession {
            try await attachedSession.resize(columns: columns, rows: rows)
        } else {
            try await session.resize(columns: columns, rows: rows)
        }
    }

    func disconnect() async {
        if let attachedSession {
            await attachedSession.disconnect()
            self.attachedSession = nil
        }
        await session.disconnect()
    }
}

/// Encodes and decodes the published `herdr terminal session control` NDJSON stream.
private actor HerdrControlChannel: PTYOutputChannel {
    private struct InputFrame: Encodable {
        let type = "terminal.input"
        let bytes: String
    }

    private struct ResizeFrame: Encodable {
        let type = "terminal.resize"
        let cols: Int
        let rows: Int
    }

    private struct ReleaseFrame: Encodable {
        let type = "terminal.release"
    }

    private let underlying: any PTYOutputChannel
    private let output: AsyncThrowingStream<[UInt8], Error>
    private let outputContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private var forwardingTask: Task<Void, Never>?
    private var pendingOutput: [UInt8] = []
    private var didFinish = false

    init(underlying: any PTYOutputChannel) {
        self.underlying = underlying
        var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        output = AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation = $0 }
        outputContinuation = continuation
    }

    func start() {
        guard forwardingTask == nil else { return }
        let underlying = self.underlying
        forwardingTask = Task { [weak self, underlying] in
            let stream = await underlying.outputStream()
            do {
                for try await bytes in stream {
                    guard !Task.isCancelled else { return }
                    await self?.consume(bytes)
                }
                await self?.finish()
            } catch {
                await self?.finish(throwing: error)
            }
        }
    }

    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> {
        output
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !didFinish else { throw SSHInteractiveCommandError.channelClosed }
        guard !bytes.isEmpty else { return }
        var frame = Array(try JSONEncoder().encode(
            InputFrame(bytes: Data(bytes).base64EncodedString())
        ))
        frame.append(0x0a)
        try await underlying.send(frame)
    }

    func resize(columns: Int, rows: Int) async throws {
        guard !didFinish else { throw SSHInteractiveCommandError.channelClosed }
        guard columns > 0, rows > 0 else { return }
        var frame = Array(try JSONEncoder().encode(
            ResizeFrame(cols: columns, rows: rows)
        ))
        frame.append(0x0a)
        try await underlying.send(frame)
    }

    func close() async {
        guard !didFinish else { return }
        let frame = (try? JSONEncoder().encode(ReleaseFrame())) ?? Data()
        if !frame.isEmpty {
            var bytes = Array(frame)
            bytes.append(0x0a)
            try? await underlying.send(bytes)
        }
        didFinish = true
        forwardingTask?.cancel()
        forwardingTask = nil
        outputContinuation.finish()
        await underlying.close()
    }

    private func consume(_ bytes: [UInt8]) {
        guard !didFinish else { return }
        pendingOutput.append(contentsOf: bytes)
        while let newline = pendingOutput.firstIndex(of: 0x0a) {
            let line = Array(pendingOutput[..<newline])
            pendingOutput.removeFirst(newline + 1)
            forward(line)
        }
    }

    private func finish(throwing error: Error? = nil) {
        guard !didFinish else { return }
        didFinish = true
        if let error {
            outputContinuation.finish(throwing: error)
        } else {
            outputContinuation.finish()
        }
        forwardingTask = nil
    }

    private func forward(_ line: [UInt8]) {
        guard !didFinish else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        switch type {
        case "terminal.closed":
            finish()
        case "terminal.frame":
            guard let encoded = object["bytes"] as? String,
                  let decoded = Data(base64Encoded: encoded),
                  !decoded.isEmpty
            else { return }
            outputContinuation.yield(Array(decoded))
        default:
            break
        }
    }
}
