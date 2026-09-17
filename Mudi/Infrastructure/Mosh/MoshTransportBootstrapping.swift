import Foundation
import HerdrKit

/// Connects the Mosh data session after an authenticated SSH bootstrap.
///
/// The SSH session is deliberately supplied by the application coordinator:
/// it has already applied the host-key decision and authenticated with the
/// credentials from the Keychain. The adapter only keeps the resulting Mosh
/// session in memory; its session key never becomes part of Host or a
/// persistence boundary.
///
/// The adapter owns no roaming or restore logic: TraversioMosh rebuilds the
/// UDP link under the same `MoshSession` when the network path changes, so a
/// path change must not create a new session, reconnect SSH, or replay bytes.
protocol MoshTransportBootstrapping: Sendable {
    func connect(
        to host: Host,
        credentials: SSHCredentials,
        using bootstrapSession: SSHShellSession
    ) async throws -> SSHShellSession

    func connect(
        to host: Host,
        credentials: SSHCredentials,
        using bootstrapSession: SSHShellSession,
        command: String?
    ) async throws -> SSHShellSession

    func disconnect() async

    /// Ends exclusive pane display by TERMing the captured `mosh-server` pid.
    /// No-op when this session never recorded a pane daemon pid.
    func leavePaneDaemon(using bootstrapSession: SSHShellSession) async
}

extension MoshTransportBootstrapping {
    func connect(
        to host: Host,
        credentials: SSHCredentials,
        using bootstrapSession: SSHShellSession
    ) async throws -> SSHShellSession {
        try await connect(
            to: host,
            credentials: credentials,
            using: bootstrapSession,
            command: nil
        )
    }

    func connect(
        to host: Host,
        credentials: SSHCredentials,
        using bootstrapSession: SSHShellSession,
        command: String?
    ) async throws -> SSHShellSession {
        try await connect(
            to: host,
            credentials: credentials,
            using: bootstrapSession
        )
    }

    func leavePaneDaemon(using _: SSHShellSession) async {}
}
