import Foundation
import HerdrKit
import MoshBootstrap
import MoshCore

/// Connects the Mosh data session after an authenticated SSH bootstrap.
///
/// The SSH session is deliberately supplied by the application coordinator:
/// it has already applied the host-key decision and authenticated with the
/// credentials from the Keychain. The adapter only keeps the resulting Mosh
/// client in memory; its endpoint key is never part of Host or a persistence
/// boundary.
protocol MoshTransportBootstrapping: Sendable {
    func connect(
        to host: Host,
        credentials: SSHCredentials,
        using bootstrapSession: SSHShellSession
    ) async throws -> SSHShellSession
    func disconnect() async
}

actor SwiftMoshAdapter: MoshTransportBootstrapping {
    static let transportKind = ActiveTransport.mosh

    private var client: MoshClientSession?
    private var terminalSession: SSHShellSession?

    func connect(
        to host: Host,
        credentials _: SSHCredentials,
        using bootstrapSession: SSHShellSession
    ) async throws -> SSHShellSession {
        await disconnect()

        let output = try await bootstrapSession.execute(Self.serverCommand)
        let connection = try MoshServerOutputParser.parse(
            String(decoding: output, as: UTF8.self)
        )
        let client = MoshClientSession(
            endpoint: MoshEndpoint(
                host: host.hostname,
                port: connection.port,
                keyBase64_22: connection.key
            )
        )

        do {
            try await client.start()
            let channel = MoshPTYChannel(client: client)
            let session = SSHShellSession(connectedChannel: channel)
            self.client = client
            terminalSession = session
            return session
        } catch {
            await client.stop()
            throw error
        }
    }

    func disconnect() async {
        if let terminalSession {
            await terminalSession.disconnect()
        } else if let client {
            await client.stop()
        }
        terminalSession = nil
        client = nil
    }

    private static let serverCommand = SSHLoginShellCommand.wrap(
        "mosh-server new -s",
        environment: TerminalPTYCapabilities.environment
    )
}

/// Presents a MoshClientSession through the existing terminal session
/// boundary. Keystrokes and resize requests become Mosh client operations;
/// host byte operations are forwarded to SwiftTerm as an async byte stream.
private actor MoshPTYChannel: PTYOutputChannel {
    private let client: MoshClientSession
    private let output: AsyncThrowingStream<[UInt8], Error>
    private let outputContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private var outputTask: Task<Void, Never>?
    private var isClosed = false

    init(client: MoshClientSession) {
        self.client = client
        var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        output = AsyncThrowingStream(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        outputContinuation = continuation
    }

    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> {
        startOutputForwarding()
        return output
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw MoshSessionChannelError.closed }
        guard !bytes.isEmpty else { return }
        try await client.enqueue(.keystrokes(Data(bytes)))
    }

    func resize(columns: Int, rows: Int) async throws {
        guard !isClosed else { throw MoshSessionChannelError.closed }
        guard columns > 0, rows > 0 else { return }
        guard let columns = Int32(exactly: columns),
              let rows = Int32(exactly: rows)
        else {
            throw MoshSessionChannelError.invalidSize
        }
        try await client.enqueue(.resize(cols: columns, rows: rows))
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        outputTask?.cancel()
        outputTask = nil
        outputContinuation.finish()
        await client.stop()
    }

    private func startOutputForwarding() {
        guard outputTask == nil, !isClosed else { return }
        let client = self.client
        outputTask = Task { [weak self, client] in
            let stream = await client.hostOpStream()
            for await operation in stream {
                guard !Task.isCancelled else { return }
                guard case let .hostBytes(bytes) = operation, !bytes.isEmpty else {
                    continue
                }
                await self?.yield(Array(bytes))
            }
            await self?.finishOutput()
        }
    }

    private func yield(_ bytes: [UInt8]) {
        guard !isClosed else { return }
        outputContinuation.yield(bytes)
    }

    private func finishOutput() {
        guard !isClosed else { return }
        isClosed = true
        outputTask = nil
        outputContinuation.finish()
    }
}

enum MoshSessionChannelError: Error, LocalizedError, Sendable {
    case closed
    case invalidSize

    var errorDescription: String? {
        switch self {
        case .closed:
            "The Mosh terminal connection is closed."
        case .invalidSize:
            "The Mosh terminal size is invalid."
        }
    }
}
