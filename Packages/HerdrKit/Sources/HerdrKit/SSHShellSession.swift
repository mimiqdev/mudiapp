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

/// The byte-level PTY operations needed by an interactive shell.
public protocol PTYChannel: Sendable {
    func send(_ bytes: [UInt8]) async throws
    func resize(columns: Int, rows: Int) async throws
    func close() async
}

/// A PTY channel that exposes bytes received from the remote shell.
///
/// `PTYChannel` remains the small command boundary used by shell callers; this
/// refinement is only needed by a renderer that consumes the remote output.
public protocol PTYOutputChannel: PTYChannel {
    func outputStream() async -> AsyncThrowingStream<[UInt8], Error>
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
    case notConnected
    case alreadyConnected

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "SSH authentication failed."
        case .connectionFailed:
            "Unable to connect to the SSH host."
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

    private let client: any SSHClient
    private var channel: (any PTYChannel)?
    private var state = State.idle
    private var disconnectRequested = false

    public init(client: any SSHClient) {
        self.client = client
    }

    public func connect(to host: Host, credentials: SSHCredentials) async throws {
        guard state == .idle else {
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
