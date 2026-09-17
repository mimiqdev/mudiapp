import Foundation
import HerdrKit
@preconcurrency import TraversioMoshBootstrap
@preconcurrency import TraversioMoshCore

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
        connectMosh: @escaping @Sendable () async throws -> MoshConnection,
        onMoshFailure: (@Sendable (MoshFailureClass) async -> Void)? = nil
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
                let failureClass = Self.classifyMoshFailure(error)
                if let onMoshFailure {
                    await onMoshFailure(failureClass)
                }
                // The SSH bootstrap remains the active connection.
                return (transport: .ssh, moshConnection: nil)
            }
        }
    }

    /// Production classification hook for Auto fallback. Adapters may throw
    /// ``MoshFailureClass`` directly, while the concrete TraversioMosh errors
    /// are normalized here before Auto keeps the SSH bootstrap.
    static func classifyMoshFailure(_ error: Error) -> MoshFailureClass {
        if let failure = error as? MoshFailureClass {
            return failure
        }

        if let error = error as? MoshFirstContactError {
            switch error {
            case .timedOut:
                return .udpTimedOut
            }
        }

        if let error = error as? MoshBootstrapParseError {
            switch error {
            case .connectLineNotFound, .multipleConnectLines, .malformedConnectLine,
                 .invalidPort, .portOutOfRange:
                return .moshServerUnavailable
            case .invalidSessionKey:
                return .unknown
            }
        }

        if let error = error as? MoshSessionError {
            switch error {
            case .linkRebuildAttemptsExhausted:
                return .udpTimedOut
            case .alreadyStarted, .notStarted, .stopped, .shutdownTimedOut:
                return .unknown
            }
        }

        if let error = error as? SSHInteractiveCommandError {
            switch error {
            case let .commandFailed(_, message):
                return classifyMoshMessage(message ?? error.localizedDescription)
            case .noInitialResponse, .channelClosed, .invalidData, .outputTooLarge:
                return classifyMoshMessage(error.localizedDescription)
            }
        }

        return classifyMoshMessage(
            "\(error.localizedDescription) \(String(describing: error))"
        )
    }

    private static func classifyMoshMessage(_ message: String) -> MoshFailureClass {
        let lowercased = message.lowercased()
        if lowercased.contains("mosh-server")
            && (lowercased.contains("not found")
                || lowercased.contains("command not found")
                || lowercased.contains("no such file"))
        {
            return .moshServerUnavailable
        }
        if lowercased.contains("timed out")
            || lowercased.contains("timeout")
            || lowercased.contains("etimedout")
        {
            return .udpTimedOut
        }
        if lowercased.contains("blocked")
            || lowercased.contains("not permitted")
            || lowercased.contains("permission denied")
            || lowercased.contains("unreachable")
            || lowercased.contains("no route")
            || lowercased.contains("network is down")
            || lowercased.contains("connection refused")
        {
            return .udpBlockedOnTailnetOrCarrier
        }
        return .unknown
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

enum MoshFailureClass: Error, Equatable, Hashable, LocalizedError, Sendable {
    case udpTimedOut
    case udpBlockedOnTailnetOrCarrier
    case moshServerUnavailable
    case unknown

    var errorDescription: String? {
        switch self {
        case .udpTimedOut:
            "The Mosh UDP handshake timed out."
        case .udpBlockedOnTailnetOrCarrier:
            "Mosh UDP appears blocked by the carrier or tailnet."
        case .moshServerUnavailable:
            "The host does not provide mosh-server."
        case .unknown:
            "Mosh failed to establish a session."
        }
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
