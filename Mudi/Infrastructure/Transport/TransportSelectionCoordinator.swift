import Foundation
import HerdrKit

/// The credentialed connection boundary used by transport selection.
///
/// A connector owns the connection it establishes. In particular, an SSH
/// connector must keep its bootstrap connection alive when Auto falls back
/// from Mosh so that the caller can continue using SSH without reconnecting.
protocol TransportConnector: Sendable {
    func connect(to host: Host, credentials: SSHCredentials) async throws
}

/// The selection algorithm is shared by the persistence-only coordinator and
/// the live SSH coordinator. The live coordinator has already performed the
/// SSH bootstrap before invoking this helper, so it supplies a no-op bootstrap
/// closure there.
enum TransportSelectionStrategy {
    static func select<MoshConnection>(
        preference: TransportPreference,
        bootstrapSSH: @escaping @Sendable () async throws -> Void,
        connectMosh: @escaping @Sendable () async throws -> MoshConnection
    ) async throws -> (transport: ActiveTransport, moshConnection: MoshConnection?) {
        switch preference {
        case .ssh:
            try await bootstrapSSH()
            return (transport: .ssh, moshConnection: nil)
        case .mosh:
            try await bootstrapSSH()
            do {
                let moshConnection = try await connectMosh()
                return (transport: .mosh, moshConnection: moshConnection)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TransportSelectionError.moshUnavailable
            }
        case .automatic:
            try await bootstrapSSH()
            do {
                let moshConnection = try await connectMosh()
                return (transport: .mosh, moshConnection: moshConnection)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The SSH bootstrap remains the active connection.
                return (transport: .ssh, moshConnection: nil)
            }
        }
    }
}

/// Selects the actual transport for a host while keeping host configuration
/// and credentials in their separate persistence boundaries.
///
/// Mosh always follows a successful SSH bootstrap. Auto keeps that bootstrap
/// alive when the Mosh attempt fails; an explicit Mosh preference reports the
/// failure instead of silently changing the user's requested mode.
actor TransportSelectionCoordinator {
    let hostStore: any HostStore
    let credentialStore: any CredentialStore
    let sshTransport: any TransportConnector
    let moshTransport: any TransportConnector

    private var activeTransportValue: ActiveTransport?

    init(
        hostStore: any HostStore,
        credentialStore: any CredentialStore,
        sshTransport: any TransportConnector,
        moshTransport: any TransportConnector
    ) {
        self.hostStore = hostStore
        self.credentialStore = credentialStore
        self.sshTransport = sshTransport
        self.moshTransport = moshTransport
    }

    func loadHosts() async throws -> [Host] {
        try await hostStore.loadHosts()
    }

    func save(_ host: Host) async throws {
        try await hostStore.save(host)
    }

    func save(_ credentials: SSHCredentials, for host: Host) async throws {
        try await credentialStore.save(credentials, for: host)
    }

    func credentials(for host: Host) async throws -> SSHCredentials? {
        try await credentialStore.credentials(for: host)
    }

    func connect(to host: Host) async throws -> ActiveTransport {
        let credentials = try await credentialStore.credentials(for: host) ?? SSHCredentials()
        return try await connect(to: host, credentials: credentials)
    }

    func connect(
        to host: Host,
        credentials: SSHCredentials
    ) async throws -> ActiveTransport {
        activeTransportValue = nil
        let sshTransport = self.sshTransport
        let moshTransport = self.moshTransport
        let selection = try await TransportSelectionStrategy.select(
            preference: host.preferredTransport,
            bootstrapSSH: {
                try await sshTransport.connect(to: host, credentials: credentials)
            },
            connectMosh: {
                try await moshTransport.connect(to: host, credentials: credentials)
            }
        )
        activeTransportValue = selection.transport
        return selection.transport
    }

    func activeTransport() -> ActiveTransport? {
        activeTransportValue
    }

    func disconnect() async {
        activeTransportValue = nil
    }
}

enum TransportSelectionError: Error, Equatable, LocalizedError, Sendable {
    case moshUnavailable

    var errorDescription: String? {
        switch self {
        case .moshUnavailable:
            "Mosh is unavailable for this host."
        }
    }
}
