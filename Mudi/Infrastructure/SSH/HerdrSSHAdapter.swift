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

enum HerdrTerminalControlCodecError: Error, Equatable, Sendable {
    case invalidFrame
    case invalidFrameBytes
    case invalidScrollLines
}

/// A screen snapshot emitted by the real `terminal.frame` control protocol.
/// `full` is retained because full frames replace the visible remote screen;
/// the ANSI bytes are still fed through SwiftTerm for rendering.
struct HerdrTerminalFrame: Decodable, Equatable, Sendable {
    let bytes: [UInt8]
    let encoding: String
    let full: Bool
    let height: Int
    let sequence: UInt64
    let width: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == "terminal.frame" else {
            throw HerdrTerminalControlCodecError.invalidFrame
        }

        let encodedBytes = try container.decode(String.self, forKey: .bytes)
        guard let decodedBytes = Data(base64Encoded: encodedBytes) else {
            throw HerdrTerminalControlCodecError.invalidFrameBytes
        }

        bytes = Array(decodedBytes)
        encoding = try container.decode(String.self, forKey: .encoding)
        full = try container.decode(Bool.self, forKey: .full)
        height = try container.decode(Int.self, forKey: .height)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        width = try container.decode(Int.self, forKey: .width)
    }

    private enum CodingKeys: String, CodingKey {
        case bytes
        case encoding
        case full
        case height
        case sequence = "seq"
        case type
        case width
    }
}

enum HerdrTerminalControlCodec {
    static func encodeScroll(
        direction: TerminalScrollDirection,
        lines: Int
    ) throws -> Data {
        guard lines > 0 else {
            throw HerdrTerminalControlCodecError.invalidScrollLines
        }

        var data = try JSONEncoder().encode(ScrollFrame(direction: direction, lines: lines))
        data.append(0x0a)
        return data
    }

    static func decodeFrame(_ data: Data) throws -> HerdrTerminalFrame {
        do {
            return try JSONDecoder().decode(HerdrTerminalFrame.self, from: data)
        } catch let error as HerdrTerminalControlCodecError {
            throw error
        } catch {
            throw HerdrTerminalControlCodecError.invalidFrame
        }
    }

    private struct ScrollFrame: Encodable {
        let type = "terminal.scroll"
        let direction: TerminalScrollDirection
        let lines: Int
    }
}

/// Adapts a dedicated Herdr control exec channel to the phase-3 terminal boundary.
///
/// Wire format is the published CLI contract:
/// `herdr terminal session control <target> [--takeover] [--cols N] [--rows N]`
/// stdin: `terminal.input` / `terminal.resize` / `terminal.scroll` /
/// `terminal.release`
/// `terminal.scroll` was captured from Herdr 0.8.2 as
/// `{\"type\":\"terminal.scroll\",\"direction\":\"up\",\"lines\":1}`;
/// direction is `up` or `down`, and lines must be positive.
/// stdout: `terminal.frame` / `terminal.closed`
/// The last terminal geometry the app actually used. Takeover starts the
/// control session at this size instead of a hardcoded default so the
/// remote TUI is never laid out twice (default size, then real size).
struct HerdrTerminalSize: Equatable, Sendable {
    let columns: Int
    let rows: Int

    static let fallback = HerdrTerminalSize(columns: 80, rows: 24)
}

actor SSHHerdrTerminalTransport: TerminalTransport, HerdrTerminalSessionProviding,
    HerdrSessionAwareTerminalTransport, HerdrPaneControlReleasing {
    nonisolated let kind: ActiveTransport = .ssh
    private let session: SSHShellSession
    private var attachedSession: SSHShellSession?
    private var lastTerminalSize: HerdrTerminalSize?

    init(session: SSHShellSession) {
        self.session = session
    }

    /// The size a takeover would start with right now. Exposed for tests.
    var currentTakeoverSize: HerdrTerminalSize {
        lastTerminalSize ?? .fallback
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
        let size = currentTakeoverSize
        let inner = Self.takeoverInnerCommand(
            target: target,
            sessionOption: sessionOption,
            size: size
        )
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

        let controlChannel = HerdrControlChannel(
            underlying: channel,
            initialSize: size
        )
        await controlChannel.setResizeObserver { [weak self] columns, rows in
            Task {
                await self?.recordTerminalSize(columns: columns, rows: rows)
            }
        }
        await controlChannel.start()
        let newSession = SSHShellSession(connectedChannel: controlChannel)
        if let previousSession = attachedSession {
            await previousSession.disconnect()
        }
        attachedSession = newSession
    }

    static func takeoverInnerCommand(
        target: String,
        sessionOption: String,
        size: HerdrTerminalSize
    ) -> String {
        "exec herdr \(sessionOption)terminal session control \(target) --takeover --cols \(size.columns) --rows \(size.rows)"
    }

    func recordTerminalSize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        lastTerminalSize = HerdrTerminalSize(columns: columns, rows: rows)
    }

    func terminalSession() async -> SSHShellSession? {
        attachedSession
    }

    func releaseControl(for _: Pane.ID) async {
        await releaseTerminalSession()
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
actor HerdrControlChannel: PTYOutputChannel, PTYScrollChannel {
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
    private var lastSentSize: HerdrTerminalSize?
    private var onResize: (@Sendable (Int, Int) -> Void)?

    init(
        underlying: any PTYOutputChannel,
        initialSize: HerdrTerminalSize? = nil
    ) {
        self.underlying = underlying
        lastSentSize = initialSize
        var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        output = AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation = $0 }
        outputContinuation = continuation
    }

    func setResizeObserver(
        _ observer: @escaping @Sendable (Int, Int) -> Void
    ) {
        onResize = observer
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
        let size = HerdrTerminalSize(columns: columns, rows: rows)
        // A takeover already started this control session at the recorded
        // size; forwarding an identical resize would make the remote TUI
        // lay itself out again for no reason.
        guard size != lastSentSize else { return }
        var frame = Array(try JSONEncoder().encode(
            ResizeFrame(cols: columns, rows: rows)
        ))
        frame.append(0x0a)
        try await underlying.send(frame)
        lastSentSize = size
        onResize?(columns, rows)
    }

    func scroll(
        direction: TerminalScrollDirection,
        lines: Int
    ) async throws {
        guard !didFinish else { throw SSHInteractiveCommandError.channelClosed }
        let frame = try HerdrTerminalControlCodec.encodeScroll(
            direction: direction,
            lines: lines
        )
        try await underlying.send(Array(frame))
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
            guard let frame = try? HerdrTerminalControlCodec.decodeFrame(Data(line)),
                  !frame.bytes.isEmpty
            else { return }
            outputContinuation.yield(frame.bytes)
        default:
            break
        }
    }
}
