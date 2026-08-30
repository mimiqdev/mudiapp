import Foundation
import HerdrKit

/// The application-level coordinator for saved hosts and one active SSH shell.
///
/// Host configuration is delegated to the host store, while credentials and
/// accepted host keys use separate secure stores. The coordinator owns only
/// the in-memory values needed for the current connection and a manual
/// reconnect.
actor ApplicationCoordinator: Sendable {
    let hostStore: any HostStore
    let credentialStore: any CredentialStore
    let knownHostKeyStore: any KnownHostKeyStore
    let client: any HostKeyAwareSSHClient

    private var state: ConnectionState = .idle
    private var session: SSHShellSession?
    private var activeHost: Host?
    private var activeCredentials: SSHCredentials?
    private var activeHostKeyDecision: (@Sendable (String) async -> HostKeyDecision)?
    private var hostKeyError: ConnectionError?
    private var disconnectRequested = false
    private var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    init(
        hostStore: any HostStore = JSONHostStore(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        knownHostKeyStore: any KnownHostKeyStore = KeychainKnownHostKeyStore(),
        client: any HostKeyAwareSSHClient = CitadelSSHAdapter()
    ) {
        self.hostStore = hostStore
        self.credentialStore = credentialStore
        self.knownHostKeyStore = knownHostKeyStore
        self.client = client
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

    func delete(_ host: Host) async throws {
        if activeHost?.id == host.id {
            await disconnect()
        }

        var firstError: Error?
        do {
            try await hostStore.delete(host)
        } catch {
            firstError = error
        }
        do {
            try await credentialStore.delete(for: host)
        } catch {
            firstError = firstError ?? error
        }
        do {
            try await knownHostKeyStore.delete(for: host)
        } catch {
            firstError = firstError ?? error
        }

        if activeHost?.id == host.id {
            activeHost = nil
            activeCredentials = nil
            activeHostKeyDecision = nil
        }
        if let firstError {
            throw firstError
        }
    }

    func connect(
        to host: Host,
        credentials: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision
    ) async throws -> ConnectionState {
        guard state != .connecting, state != .connected else {
            throw ConnectionError.connectionFailed
        }

        activeHost = host
        activeCredentials = credentials
        activeHostKeyDecision = hostKeyDecision
        disconnectRequested = false
        hostKeyError = nil
        setState(.connecting)

        do {
            let channel = try await client.connect(
                to: host,
                credentials: credentials,
                hostKeyDecision: { [weak self] fingerprint in
                    guard let self else { return .reject }
                    return await self.evaluateHostKey(
                        fingerprint,
                        userDecision: hostKeyDecision
                    )
                }
            )

            if disconnectRequested {
                await channel.close()
                disconnectRequested = false
                setState(.disconnected)
                throw ConnectionError.connectionFailed
            }

            session = SSHShellSession(connectedChannel: channel)
            setState(.connected)
            return .connected
        } catch {
            let connectionError = hostKeyError ?? mapConnectionError(error)
            hostKeyError = nil
            session = nil
            if state != .disconnected {
                setState(.failed)
            }
            disconnectRequested = false
            throw connectionError
        }
    }

    func connectionState() -> ConnectionState {
        state
    }

    /// Returns lifecycle events after subscription. The stream intentionally
    /// does not replay the initial idle state, so a connection reports the
    /// meaningful `connecting` → `connected` transition to new observers.
    func connectionStateStream() -> AsyncStream<ConnectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            stateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeStateContinuation(id)
                }
            }
        }
    }

    /// The active session is already connected and can be passed to the
    /// SwiftTerm container without another SSH handshake.
    func activeShellSession() -> SSHShellSession? {
        session
    }

    func disconnect() async {
        if state == .connecting {
            disconnectRequested = true
            setState(.disconnected)
            return
        }
        await disconnectCurrentSession()
        if state != .disconnected {
            setState(.disconnected)
        }
    }

    func reconnect() async throws -> ConnectionState {
        guard let activeHost,
              let activeCredentials,
              let activeHostKeyDecision
        else {
            setState(.failed)
            throw ConnectionError.connectionFailed
        }

        let reconnectCredentials = (try? await credentialStore.credentials(for: activeHost))
            ?? activeCredentials
        return try await connect(
            to: activeHost,
            credentials: reconnectCredentials,
            hostKeyDecision: activeHostKeyDecision
        )
    }

    private func evaluateHostKey(
        _ fingerprint: String,
        userDecision: @escaping @Sendable (String) async -> HostKeyDecision
    ) async -> HostKeyDecision {
        guard let activeHost else {
            hostKeyError = .connectionFailed
            return .reject
        }

        do {
            if let remembered = try await knownHostKeyStore.fingerprint(for: activeHost) {
                guard remembered == fingerprint else {
                    hostKeyError = .hostKeyMismatch(
                        expected: remembered,
                        actual: fingerprint
                    )
                    return .reject
                }
                // A remembered key is trusted without showing the prompt.
                return .accept
            }

            let decision = await userDecision(fingerprint)
            guard decision == .accept else {
                return .reject
            }
            try await knownHostKeyStore.remember(fingerprint, for: activeHost)
            return .accept
        } catch {
            hostKeyError = .connectionFailed
            return .reject
        }
    }

    private func disconnectCurrentSession() async {
        guard let session else {
            return
        }
        self.session = nil
        await session.disconnect()
    }

    private func setState(_ newState: ConnectionState) {
        state = newState
        stateContinuations.values.forEach { continuation in
            continuation.yield(newState)
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private func mapConnectionError(_ error: Error) -> ConnectionError {
        if let error = error as? ConnectionError {
            return error
        }
        if let error = error as? SSHShellError {
            switch error {
            case .authenticationFailed, .connectionFailed, .notConnected:
                return .connectionFailed
            case .alreadyConnected:
                return .connectionFailed
            }
        }
        return .connectionFailed
    }
}
