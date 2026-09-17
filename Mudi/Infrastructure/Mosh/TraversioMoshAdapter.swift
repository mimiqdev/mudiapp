import Foundation
import HerdrKit
import TraversioMoshBootstrap
import TraversioMoshCore

/// Connects the TraversioMosh data session after an authenticated SSH
/// bootstrap.
///
/// The adapter's whole job is the handoff: run the `mosh-server new` bootstrap
/// command over SSH, parse the `MOSH CONNECT` line with TraversioMosh's
/// parser, start a Traversio `MoshSession` for the parsed endpoint, wait for
/// the server's first in-sequence datagram, and expose the session to the
/// terminal as a ``MoshPTYChannel``. Everything after that — encryption, SSP,
/// framebuffer, prediction, and transport recovery — belongs to Traversio,
/// which rebuilds the UDP link under the same session when the path changes.
///
/// The bounded first-contact wait exists for transport selection: without it
/// a blocked UDP path mounts a Mosh session that will never paint, and Auto
/// mode would keep a dead Mosh session instead of falling back to SSH. A
/// timeout surfaces as ``MoshFirstContactError/timedOut``, which the selector
/// classifies as `udpTimedOut`.
actor TraversioMoshAdapter: MoshTransportBootstrapping {
    static let transportKind = ActiveTransport.mosh

    /// First-contact budget for the UDP handshake. The SSH bootstrap has
    /// already proven the path to the server, so a working UDP path answers
    /// within a round trip; 10 seconds is generous for cellular/VPN setup
    /// while keeping the Auto fallback to SSH responsive. Tests inject a
    /// shorter bound through ``init``.
    static let defaultFirstContactTimeout = Duration.seconds(10)

    /// Traversio's configuration needs an initial geometry. The terminal view
    /// reports the real size through `resize` as soon as it lays out, so this
    /// is only the pre-layout fallback. 80x24 is always valid for
    /// `MoshTerminalDimensions` (positive and under both caps), so the
    /// throwing initializer cannot fail here.
    static func initialTerminalDimensions() throws -> MoshTerminalDimensions {
        try MoshTerminalDimensions(columns: 80, rows: 24)
    }

    /// Production constructs the real Traversio session; tests inject a
    /// controlled ``MoshTerminalSessionHandling``.
    private let makeSession: @Sendable (MoshEndpoint, MoshTerminalDimensions) -> any MoshTerminalSessionHandling
    private let firstContactTimeout: Duration
    private var session: (any MoshTerminalSessionHandling)?
    private var terminalSession: SSHShellSession?
    private var paneDaemonPid: Int32?

    init(
        makeSession: (@Sendable (MoshEndpoint, MoshTerminalDimensions) -> any MoshTerminalSessionHandling)? = nil,
        firstContactTimeout: Duration = TraversioMoshAdapter.defaultFirstContactTimeout
    ) {
        self.firstContactTimeout = firstContactTimeout
        self.makeSession = makeSession ?? { endpoint, dimensions in
            TraversioMoshTerminalSession(
                session: MoshSession(
                    configuration: MoshSessionConfiguration(
                        endpoint: endpoint,
                        initialTerminalDimensions: dimensions,
                        transportFactory: MoshNWSessionTransportFactory()
                    )
                )
            )
        }
    }

    func connect(
        to host: Host,
        credentials _: SSHCredentials,
        using bootstrapSession: SSHShellSession,
        command: String? = nil
    ) async throws -> SSHShellSession {
        let serverCommand = Self.serverCommand(for: command)
        let output = try await bootstrapSession.execute(serverCommand)
        let outputString = String(bytes: output, encoding: .utf8) ?? ""
        let bootstrap = try MoshBootstrapParser.parse(outputString)
        let capturedPid = MoshServerDaemonPid.parse(from: outputString)
        let client = makeSession(
            MoshEndpoint(
                host: host.hostname,
                port: bootstrap.port,
                sessionKey: bootstrap.sessionKey
            ),
            try Self.initialTerminalDimensions()
        )

        do {
            try await client.start()
            // Bounded first-contact gate: a parsed bootstrap line only proves
            // the TCP SSH path works. Waiting for the server's first
            // in-sequence datagram is what lets Auto choose SSH when the UDP
            // path is blocked. The client is stopped on timeout so no dead
            // session leaks into the adapter's mounted state.
            try await client.waitForFirstContact(timeout: firstContactTimeout)
            // A command session is a raw direct attach: the remote
            // application, not the host, owns its viewport, so vertical pans
            // become wheel input for it. The login-shell session (no command)
            // keeps SwiftTerm's local pan behaviour.
            let channel = MoshPTYChannel(
                session: client,
                acceptsMouseWheelInput: command?.isEmpty == false
            )
            let newSession = SSHShellSession(connectedChannel: channel)

            let previousSession = terminalSession
            let previousClient = session
            self.session = client
            terminalSession = newSession
            if let command, !command.isEmpty {
                paneDaemonPid = capturedPid
            }

            if let previousSession {
                await previousSession.disconnect()
            } else if let previousClient {
                await previousClient.stop()
            }

            return newSession
        } catch {
            await client.stop()
            throw error
        }
    }

    func disconnect() async {
        if let terminalSession {
            await terminalSession.disconnect()
        } else if let session {
            await session.stop()
        }
        terminalSession = nil
        session = nil
    }

    func leavePaneDaemon(using bootstrapSession: SSHShellSession) async {
        guard let pid = paneDaemonPid else { return }
        paneDaemonPid = nil
        _ = try? await bootstrapSession.execute(
            MoshServerDaemonPid.terminateCommand(pid: pid)
        )
    }

    /// Builds the login-shell `mosh-server new` command. `-s` keeps the
    /// server inside the SSH connection's address family (Tailscale included)
    /// and `2>&1` merges the detached-pid stderr line into the captured
    /// output so Leave can TERM the pane daemon.
    static func serverCommand(for command: String? = nil) -> String {
        let baseCommand: String
        if let command, !command.isEmpty {
            baseCommand = "mosh-server new -s -- \(command) 2>&1"
        } else {
            baseCommand = "mosh-server new -s 2>&1"
        }
        return SSHLoginShellCommand.wrap(
            baseCommand,
            environment: TerminalPTYCapabilities.environment
        )
    }
}
