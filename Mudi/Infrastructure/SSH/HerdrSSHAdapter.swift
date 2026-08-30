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

/// Adapts dedicated Herdr control channels to the phase-3 terminal boundary.
///
/// The ordinary SSH shell is never used for Herdr discovery or pane attach.
/// Each successful attach owns a separate interactive exec channel whose
/// framed output is decoded before it reaches SwiftTerm.
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
        let command = SSHLoginShellCommand.wrap(
            "herdr \(sessionOption)terminal session control \(target) --cols 80 --rows 24"
        )
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

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Decodes Herdr's newline-delimited terminal frames and encodes input frames.
/// Unknown JSON control frames are intentionally consumed rather than rendered
/// as terminal text; non-JSON lines are forwarded as a compatibility fallback.
private actor HerdrControlChannel: PTYOutputChannel {
    private enum OutputFrame {
        case bytes([UInt8])
        case control
    }

    private struct InputFrame: Encodable {
        let type = "input"
        let data: String
    }

    private struct ResizeFrame: Encodable {
        let type = "resize"
        let columns: Int
        let rows: Int
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
            InputFrame(data: Data(bytes).base64EncodedString())
        ))
        frame.append(0x0a)
        try await underlying.send(frame)
    }

    func resize(columns: Int, rows: Int) async throws {
        guard !didFinish else { throw SSHInteractiveCommandError.channelClosed }
        guard columns > 0, rows > 0 else { return }
        var frame = Array(try JSONEncoder().encode(
            ResizeFrame(columns: columns, rows: rows)
        ))
        frame.append(0x0a)
        try await underlying.send(frame)
    }

    func close() async {
        guard !didFinish else { return }
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
        if !pendingOutput.isEmpty {
            outputContinuation.yield(pendingOutput)
            pendingOutput.removeAll(keepingCapacity: false)
        }
        if let error {
            outputContinuation.finish(throwing: error)
        } else {
            outputContinuation.finish()
        }
        forwardingTask = nil
    }

    private func forward(_ line: [UInt8]) {
        guard !didFinish else { return }
        guard let frame = Self.decodeOutputFrame(line) else {
            outputContinuation.yield(line + [0x0a])
            return
        }
        if case let .bytes(bytes) = frame, !bytes.isEmpty {
            outputContinuation.yield(bytes)
        }
    }

    private static func decodeOutputFrame(_ line: [UInt8]) -> OutputFrame? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        else {
            return nil
        }

        let payload = object["data"] ?? object["bytes"] ?? object["output"] ?? object["payload"]
        if let string = payload as? String {
            if let decoded = Data(base64Encoded: string) {
                return .bytes(Array(decoded))
            }
            return .bytes(Array(string.utf8))
        }
        if let numbers = payload as? [Int] {
            return .bytes(numbers.compactMap(UInt8.init(exactly:)))
        }
        return .control
    }
}
