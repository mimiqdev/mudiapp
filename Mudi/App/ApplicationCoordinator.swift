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
    private var activeHostID: Host.ID?
    private var hostKeyError: (attemptID: UUID, error: ConnectionError)?
    private var inFlightConnectID: UUID?
    private var disconnectRequestedFor: UUID?
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
        let deletesActiveHost = activeHostID == host.id
        if deletesActiveHost {
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

        if deletesActiveHost {
            activeHostID = nil
            hostKeyError = nil
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
        guard inFlightConnectID == nil,
              state != .connecting,
              state != .connected
        else {
            throw ConnectionError.connectionFailed
        }

        let attemptID = UUID()
        activeHostID = host.id
        hostKeyError = nil
        disconnectRequestedFor = nil
        inFlightConnectID = attemptID
        setState(.connecting)

        do {
            let channel = try await client.connect(
                to: host,
                credentials: credentials,
                hostKeyDecision: { [weak self] fingerprint in
                    guard let self else { return .reject }
                    return await self.evaluateHostKey(
                        fingerprint,
                        for: attemptID,
                        host: host,
                        userDecision: hostKeyDecision
                    )
                }
            )

            guard inFlightConnectID == attemptID,
                  activeHostID == host.id,
                  disconnectRequestedFor != attemptID,
                  !Task.isCancelled
            else {
                await channel.close()
                finishAttempt(attemptID, state: .disconnected)
                throw ConnectionError.connectionFailed
            }

            session = SSHShellSession(connectedChannel: channel)
            inFlightConnectID = nil
            disconnectRequestedFor = nil
            setState(.connected)
            return .connected
        } catch {
            let connectionError: ConnectionError
            if hostKeyError?.attemptID == attemptID {
                connectionError = hostKeyError?.error ?? mapConnectionError(error)
            } else {
                connectionError = mapConnectionError(error)
            }

            guard inFlightConnectID == attemptID else {
                throw connectionError
            }

            let wasDisconnectRequested = disconnectRequestedFor == attemptID
                || state == .disconnected
                || Task.isCancelled
            finishAttempt(
                attemptID,
                state: wasDisconnectRequested ? .disconnected : .failed
            )
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
        if let attemptID = inFlightConnectID {
            disconnectRequestedFor = attemptID
            setState(.disconnected)
            return
        }
        await disconnectCurrentSession()
        if state != .disconnected {
            setState(.disconnected)
        }
    }

    func reconnect(
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision
    ) async throws -> ConnectionState {
        guard inFlightConnectID == nil else {
            throw ConnectionError.connectionFailed
        }
        guard let activeHostID else {
            setState(.failed)
            throw ConnectionError.connectionFailed
        }

        let host: Host
        do {
            guard let savedHost = try await hostStore.loadHosts().first(where: { $0.id == activeHostID }) else {
                setState(.failed)
                throw ConnectionError.connectionFailed
            }
            host = savedHost
        } catch let error as ConnectionError {
            throw error
        } catch {
            setState(.failed)
            throw ConnectionError.connectionFailed
        }

        guard inFlightConnectID == nil, self.activeHostID == activeHostID else {
            throw ConnectionError.connectionFailed
        }

        let credentials: SSHCredentials
        do {
            guard let savedCredentials = try await credentialStore.credentials(for: host) else {
                setState(.failed)
                throw ConnectionError.connectionFailed
            }
            credentials = savedCredentials
        } catch let error as ConnectionError {
            throw error
        } catch {
            setState(.failed)
            throw ConnectionError.connectionFailed
        }

        guard inFlightConnectID == nil, self.activeHostID == activeHostID else {
            throw ConnectionError.connectionFailed
        }

        return try await connect(
            to: host,
            credentials: credentials,
            hostKeyDecision: hostKeyDecision
        )
    }

    private func evaluateHostKey(
        _ fingerprint: String,
        for attemptID: UUID,
        host: Host,
        userDecision: @escaping @Sendable (String) async -> HostKeyDecision
    ) async -> HostKeyDecision {
        guard inFlightConnectID == attemptID,
              activeHostID == host.id,
              disconnectRequestedFor != attemptID
        else {
            return .reject
        }

        do {
            if let remembered = try await knownHostKeyStore.fingerprint(for: host) {
                guard inFlightConnectID == attemptID,
                      activeHostID == host.id,
                      disconnectRequestedFor != attemptID
                else {
                    return .reject
                }
                guard remembered == fingerprint else {
                    hostKeyError = (
                        attemptID,
                        .hostKeyMismatch(expected: remembered, actual: fingerprint)
                    )
                    return .reject
                }
                // A remembered key is trusted without showing the prompt.
                return .accept
            }

            let decision = await userDecision(fingerprint)
            guard decision == .accept,
                  inFlightConnectID == attemptID,
                  activeHostID == host.id,
                  disconnectRequestedFor != attemptID
            else {
                return .reject
            }
            try await knownHostKeyStore.remember(fingerprint, for: host)
            guard inFlightConnectID == attemptID,
                  activeHostID == host.id,
                  disconnectRequestedFor != attemptID
            else {
                try? await knownHostKeyStore.delete(for: host)
                return .reject
            }
            return .accept
        } catch {
            if inFlightConnectID == attemptID {
                hostKeyError = (attemptID, .connectionFailed)
            }
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

    private func finishAttempt(_ attemptID: UUID, state: ConnectionState) {
        guard inFlightConnectID == attemptID else { return }
        inFlightConnectID = nil
        disconnectRequestedFor = nil
        hostKeyError = nil
        session = nil
        setState(state)
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
            case .authenticationFailed, .connectionFailed, .commandExecutionUnavailable, .notConnected:
                return .connectionFailed
            case .alreadyConnected:
                return .connectionFailed
            }
        }
        return .connectionFailed
    }
}
