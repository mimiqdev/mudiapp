import Foundation

public protocol HerdrDiscovering: Sendable {
    func snapshot(for host: Host) async throws -> HerdrSnapshot
}

public protocol TerminalTransport: Sendable {
    var kind: ActiveTransport { get }

    func connect(to host: Host) async throws
    func attach(to pane: Pane) async throws
    func send(_ bytes: [UInt8]) async throws
    func resize(columns: Int, rows: Int) async throws
    func disconnect() async
}

/// The lifecycle states exposed by the app's connection coordinator.
public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed
    case disconnected
}

/// The result of asking a user whether an unknown SSH host key is trusted.
public enum HostKeyDecision: Equatable, Sendable {
    case accept
    case reject
}

/// Errors that can be shown by the connection UI.
public enum ConnectionError: Error, Equatable, LocalizedError, Sendable {
    case connectionFailed
    case hostKeyRejected
    case hostKeyMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            "Unable to connect to the SSH host."
        case .hostKeyRejected:
            "The SSH host key was rejected."
        case let .hostKeyMismatch(expected, actual):
            "The SSH host key does not match the remembered fingerprint (expected \(expected), received \(actual))."
        }
    }
}

/// A persistence boundary for the non-secret host configuration.
public protocol HostStore: Sendable {
    func loadHosts() async throws -> [Host]
    func save(_ host: Host) async throws
    func delete(_ host: Host) async throws
}

/// A persistence boundary for credentials. Implementations must use a secure
/// credential store rather than the host configuration file.
public protocol CredentialStore: Sendable {
    func save(_ credentials: SSHCredentials, for host: Host) async throws
    func credentials(for host: Host) async throws -> SSHCredentials?
    func delete(for host: Host) async throws
}

/// A persistence boundary for the host key accepted during TOFU.
public protocol KnownHostKeyStore: Sendable {
    func remember(_ fingerprint: String, for host: Host) async throws
    func fingerprint(for host: Host) async throws -> String?
    func delete(for host: Host) async throws
}

/// An SSH client that exposes the server fingerprint before it accepts the
/// connection. The returned channel is already connected and can be handed to
/// ``SSHShellSession`` without opening a second SSH connection.
public protocol HostKeyAwareSSHClient: Sendable {
    func connect(
        to host: Host,
        credentials: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision
    ) async throws -> any PTYChannel
}
