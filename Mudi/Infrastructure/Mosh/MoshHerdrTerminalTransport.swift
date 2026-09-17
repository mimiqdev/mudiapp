import Foundation
import HerdrKit

/// Connects an attached Herdr pane directly through a dedicated Mosh data session.
///
/// The outer host connection retains its authenticated SSH bootstrap session
/// for Herdr discovery and pane picker queries; attaching an agent pane starts
/// an independent on-screen Mosh session whose child process is the Herdr pane
/// takeover command, rather than opening an interactive SSH exec channel.
actor MoshHerdrTerminalTransport: TerminalTransport,
    HerdrTerminalSessionProviding,
    HerdrSessionAwareTerminalTransport,
    HerdrPaneControlReleasing,
    HerdrAttachedSessionHydrating,
    HerdrOrdinaryTerminalSessionStarting {
    nonisolated let kind: ActiveTransport = .mosh
    private let session: SSHShellSession
    private let host: Host
    private let credentialsProvider: @Sendable () async throws -> SSHCredentials?
    private let moshTransport: any MoshTransportBootstrapping
    private var attachedSession: SSHShellSession?
    private var lastTerminalSize: HerdrTerminalSize?

    init(
        session: SSHShellSession,
        host: Host,
        credentialsProvider: @escaping @Sendable () async throws -> SSHCredentials?,
        moshTransport: any MoshTransportBootstrapping
    ) {
        self.session = session
        self.host = host
        self.credentialsProvider = credentialsProvider
        self.moshTransport = moshTransport
    }

    var currentTakeoverSize: HerdrTerminalSize {
        lastTerminalSize ?? .fallback
    }

    func connect(to _: Host) async throws {}

    func startOrdinaryTerminalSession() async throws {
        guard let credentials = try await credentialsProvider() else {
            throw MissingCredentialsError()
        }
        let newSession = try await moshTransport.connect(
            to: host,
            credentials: credentials,
            using: session
        )
        if let previousSession = attachedSession {
            await previousSession.disconnect()
        }
        attachedSession = newSession
    }

    func attach(to pane: Pane) async throws {
        try await attachMoshTerminal(to: pane)
    }

    func attach(to pane: Pane, in _: HerdrSession) async throws {
        try await attachMoshTerminal(to: pane)
    }

    private func attachMoshTerminal(to pane: Pane) async throws {
        guard let terminalID = pane.terminalID, !terminalID.isEmpty else {
            throw SSHHerdrTerminalTransportError.missingTerminalID
        }
        let target = SSHLoginShellCommand.shellQuote(terminalID)
        let inner = Self.attachInnerCommand(target: target)
        let command =
            "\"${SHELL:-/bin/sh}\" -lc \(SSHLoginShellCommand.shellQuote(inner))"

        guard let credentials = try await credentialsProvider() else {
            throw MissingCredentialsError()
        }

        let moshSession: SSHShellSession
        do {
            moshSession = try await moshTransport.connect(
                to: host,
                credentials: credentials,
                using: session,
                command: command
            )
        } catch is SSHInteractiveCommandError {
            throw SSHHerdrTerminalTransportError.paneUnavailable
        } catch {
            throw SSHHerdrTerminalTransportError.attachFailed
        }

        // mosh-server provides a real PTY. Keep it as the terminal session;
        // HerdrControlChannel is only for SSH exec pipes that speak NDJSON,
        // not for the byte-oriented Mosh data plane.
        if let previousSession = attachedSession {
            await previousSession.disconnect()
        }
        attachedSession = moshSession
    }

    /// Builds the raw terminal-stream command used as the Mosh PTY child.
    /// Unlike SSH takeover, `terminal attach` has no geometry options and
    /// emits terminal bytes directly instead of the session-control protocol.
    static func attachInnerCommand(target: String) -> String {
        let command = "exec herdr terminal attach \(target) --takeover"
        return "\(TerminalPTYCapabilities.shellExportPrefix); \(command)"
    }

    func recordTerminalSize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        lastTerminalSize = HerdrTerminalSize(columns: columns, rows: rows)
    }

    func terminalSession() async -> SSHShellSession? {
        attachedSession
    }

    func hydrate(attachedSession: SSHShellSession) {
        self.attachedSession = attachedSession
    }

    func releaseControl(for _: Pane.ID) async {
        guard attachedSession != nil else { return }
        await moshTransport.leavePaneDaemon(using: session)
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
        recordTerminalSize(columns: columns, rows: rows)
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
        await moshTransport.disconnect()
    }
}
