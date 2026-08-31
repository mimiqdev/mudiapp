import Foundation

/// Credentials are supplied for one connection attempt and are never part of `Host` or persisted by this package.
public struct SSHCredentials: Equatable, Sendable {
    public let password: String?
    public let pemPrivateKey: String?

    public init(password: String? = nil, pemPrivateKey: String? = nil) {
        self.password = password
        self.pemPrivateKey = pemPrivateKey
    }
}

/// The direction of a remote terminal scrollback request.
public enum TerminalScrollDirection: String, Codable, Equatable, Sendable {
    case up
    case down
}

/// The byte-level PTY operations needed by an interactive shell.
public protocol PTYChannel: Sendable {
    func send(_ bytes: [UInt8]) async throws
    func resize(columns: Int, rows: Int) async throws
    func close() async
}

/// A PTY channel whose host can provide scrollback snapshots independently
/// from the local terminal emulator's buffer.
public protocol PTYScrollChannel: PTYChannel {
    func scroll(
        direction: TerminalScrollDirection,
        lines: Int
    ) async throws
}

/// A PTY channel that exposes bytes received from the remote shell.
///
/// `PTYChannel` remains the small command boundary used by shell callers; this
/// refinement is only needed by a renderer that consumes the remote output.
public protocol PTYOutputChannel: PTYChannel {
    func outputStream() async -> AsyncThrowingStream<[UInt8], Error>
}

/// A connected SSH channel that can open a separate non-interactive exec
/// channel on the same authenticated SSH connection.
public protocol SSHCommandExecutingChannel: Sendable {
    func execute(_ command: String) async throws -> [UInt8]
}

/// A connected SSH channel that can open an interactive exec channel without
/// consuming the shell channel's output stream.
public protocol SSHInteractiveCommandChannel: Sendable {
    func openInteractiveCommand(_ command: String) async throws -> any PTYOutputChannel
}

/// Errors that an `SSHClient` reports to the shell session.
public enum SSHClientError: Error, Equatable, Sendable {
    case authenticationFailed
}

/// The small dependency boundary between a shell session and an SSH library.
/// Implementations report authentication failures as `SSHClientError.authenticationFailed`.
/// Credentials must be retained only for the lifetime of the returned channel.
public protocol SSHClient: Sendable {
    func connect(to host: Host, credentials: SSHCredentials) async throws -> any PTYChannel
}

/// A shell session deliberately has no pane or discovery concerns.
public protocol ShellSession: Sendable {
    func connect(to host: Host, credentials: SSHCredentials) async throws
    func send(_ bytes: [UInt8]) async throws
    func resize(columns: Int, rows: Int) async throws
    func disconnect() async
}

public enum SSHShellError: Error, Equatable, LocalizedError, Sendable {
    case authenticationFailed
    case connectionFailed
    case commandExecutionUnavailable
    case notConnected
    case alreadyConnected

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "SSH authentication failed."
        case .connectionFailed:
            "Unable to connect to the SSH host."
        case .commandExecutionUnavailable:
            "The SSH connection cannot execute a remote command."
        case .notConnected:
            "The SSH shell is not connected."
        case .alreadyConnected:
            "The SSH shell is already connected."
        }
    }
}

/// Coordinates one SSH connection with its remote PTY.
public actor SSHShellSession: ShellSession {
    private enum State {
        case idle
        case connecting
        case connected
        case disconnecting
    }

    private let client: (any SSHClient)?
    private var channel: (any PTYChannel)?
    private var state = State.idle
    private var disconnectRequested = false

    public init(client: any SSHClient) {
        self.client = client
    }

    /// Creates a shell session around a channel that has already completed its
    /// SSH handshake. This lets a host-key-aware connection coordinator keep
    /// the accepted connection instead of opening a second connection for the
    /// terminal.
    public init(connectedChannel: any PTYChannel) {
        self.client = nil
        self.channel = connectedChannel
        self.state = .connected
    }

    public func connect(to host: Host, credentials: SSHCredentials) async throws {
        guard state == .idle else {
            throw SSHShellError.alreadyConnected
        }
        guard let client else {
            throw SSHShellError.alreadyConnected
        }
        state = .connecting

        do {
            let newChannel = try await client.connect(to: host, credentials: credentials)
            if disconnectRequested {
                disconnectRequested = false
                state = .disconnecting
                await newChannel.close()
                throw SSHShellError.notConnected
            }
            channel = newChannel
            state = .connected
        } catch let error as SSHClientError {
            resetConnectionAttempt()
            switch error {
            case .authenticationFailed:
                throw SSHShellError.authenticationFailed
            }
        } catch let error as SSHShellError {
            resetConnectionAttempt()
            throw error
        } catch {
            resetConnectionAttempt()
            throw SSHShellError.connectionFailed
        }
    }

    /// Executes a command on a dedicated SSH session channel. The interactive
    /// shell's output stream is never consumed by this operation.
    public func execute(_ command: String) async throws -> [UInt8] {
        guard let channel, state == .connected else {
            throw SSHShellError.notConnected
        }
        guard let commandChannel = channel as? any SSHCommandExecutingChannel else {
            throw SSHShellError.commandExecutionUnavailable
        }
        return try await commandChannel.execute(command)
    }

    /// Opens an interactive exec channel while leaving the connected shell
    /// channel and its output stream untouched.
    public func openInteractiveCommand(_ command: String) async throws -> any PTYOutputChannel {
        guard let channel, state == .connected else {
            throw SSHShellError.notConnected
        }
        guard let commandChannel = channel as? any SSHInteractiveCommandChannel else {
            throw SSHShellError.commandExecutionUnavailable
        }
        return try await commandChannel.openInteractiveCommand(command)
    }

    /// Returns the remote output stream for the connected PTY.
    ///
    /// A channel that does not provide output is represented by a finished
    /// stream. This keeps the original shell command seam usable by tests and
    /// non-rendering clients.
    public func outputStream() async -> AsyncThrowingStream<[UInt8], Error> {
        guard let channel, state == .connected,
              let outputChannel = channel as? any PTYOutputChannel else {
            return Self.finishedOutputStream()
        }
        return await outputChannel.outputStream()
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard let channel, state == .connected else {
            throw SSHShellError.notConnected
        }
        try await channel.send(bytes)
    }

    public func resize(columns: Int, rows: Int) async throws {
        guard let channel, state == .connected else {
            throw SSHShellError.notConnected
        }
        try await channel.resize(columns: columns, rows: rows)
    }

    /// Whether this session's channel can request host-side scrollback.
    public func supportsRemoteScrollback() -> Bool {
        channel is any PTYScrollChannel && state == .connected
    }

    /// Requests a host-side scrollback snapshot when the channel supports it.
    public func scroll(
        direction: TerminalScrollDirection,
        lines: Int
    ) async throws {
        guard let channel, state == .connected else {
            throw SSHShellError.notConnected
        }
        guard let scrollChannel = channel as? any PTYScrollChannel else {
            throw SSHShellError.commandExecutionUnavailable
        }
        try await scrollChannel.scroll(direction: direction, lines: lines)
    }

    public func disconnect() async {
        switch state {
        case .idle, .disconnecting:
            return
        case .connecting:
            disconnectRequested = true
        case .connected:
            guard let channel else {
                state = .idle
                return
            }
            self.channel = nil
            state = .disconnecting
            await channel.close()
            state = .idle
        }
    }

    private func resetConnectionAttempt() {
        state = .idle
        disconnectRequested = false
    }

    private static func finishedOutputStream() -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
