import Foundation
import HerdrKit

/// The application-level coordinator for saved hosts and one active shell.
///
/// Host configuration is delegated to the host store, while credentials and
/// accepted host keys use separate secure stores. The coordinator keeps the
/// SSH bootstrap session for Herdr discovery and exposes the selected terminal
/// session separately when Mosh is available.
actor ApplicationCoordinator: Sendable {
    let hostStore: any HostStore
    let credentialStore: any CredentialStore
    let knownHostKeyStore: any KnownHostKeyStore
    let client: any HostKeyAwareSSHClient
    let moshTransport: any MoshTransportBootstrapping

    var state: ConnectionState = .idle
    var session: SSHShellSession?
    var terminalSession: SSHShellSession?
    var activeTransportValue: ActiveTransport?
    private var activeHostID: Host.ID?
    private var hostKeyError: (attemptID: UUID, error: ConnectionError)?
    private var inFlightConnectID: UUID?
    private var disconnectRequestedFor: UUID?
    private var attemptWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    init(
        hostStore: any HostStore = JSONHostStore(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        knownHostKeyStore: any KnownHostKeyStore = KeychainKnownHostKeyStore(),
        client: any HostKeyAwareSSHClient = CitadelSSHAdapter(),
        moshTransport: any MoshTransportBootstrapping = SwiftMoshAdapter()
    ) {
        self.hostStore = hostStore
        self.credentialStore = credentialStore
        self.knownHostKeyStore = knownHostKeyStore
        self.client = client
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
        activeTransportValue = nil
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
            let bootstrapSession = SSHShellSession(connectedChannel: channel)
            let selection: (transport: ActiveTransport, moshConnection: SSHShellSession?)
            do {
                selection = try await TransportSelectionStrategy.select(
                    preference: host.preferredTransport,
                    bootstrapSSH: {},
                    connectMosh: { [moshTransport, bootstrapSession] in
                        try await moshTransport.connect(
                            to: host,
                            credentials: credentials,
                            using: bootstrapSession
                        )
                    }
                )
            } catch {
                await moshTransport.disconnect()
                await bootstrapSession.disconnect()
                throw error
            }
            let selectedTerminalSession = selection.moshConnection ?? bootstrapSession

            guard inFlightConnectID == attemptID,
                  activeHostID == host.id,
                  disconnectRequestedFor != attemptID,
                  !Task.isCancelled
            else {
                await selectedTerminalSession.disconnect()
                if ObjectIdentifier(selectedTerminalSession) != ObjectIdentifier(bootstrapSession) {
                    await bootstrapSession.disconnect()
                }
                await moshTransport.disconnect()
                finishAttempt(attemptID, state: .disconnected)
                throw ConnectionError.connectionFailed
            }

            session = bootstrapSession
            terminalSession = selectedTerminalSession
            activeTransportValue = selection.transport
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

            await disconnectCurrentSession()
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

    func disconnect() async {
        if let attemptID = inFlightConnectID {
            disconnectRequestedFor = attemptID
            return
        }
        await disconnectCurrentSession()
        activeTransportValue = nil
        if state != .disconnected {
            setState(.disconnected)
        }
    }

    /// Requests a disconnect and does not return until a pending handshake or
    /// connected shell has fully torn down. UI callers use this boundary when
    /// another connection may be started immediately afterwards.
    func disconnectAndWait() async {
        if let attemptID = inFlightConnectID {
            disconnectRequestedFor = attemptID
            await waitForAttemptCompletion(attemptID)
            return
        }
        await disconnectCurrentSession()
        activeTransportValue = nil
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
        let bootstrapSession = session
        let terminalSession = self.terminalSession
        session = nil
        self.terminalSession = nil

        if let terminalSession {
            await terminalSession.disconnect()
        }
        if let bootstrapSession {
            let isSameSession = terminalSession.map {
                ObjectIdentifier(bootstrapSession) == ObjectIdentifier($0)
            } ?? false
            if !isSameSession {
                await bootstrapSession.disconnect()
            }
        }
        await moshTransport.disconnect()
    }

    private func finishAttempt(_ attemptID: UUID, state: ConnectionState) {
        guard inFlightConnectID == attemptID else { return }
        inFlightConnectID = nil
        disconnectRequestedFor = nil
        hostKeyError = nil
        session = nil
        terminalSession = nil
        activeTransportValue = nil
        setState(state)
        let waiters = attemptWaiters.removeValue(forKey: attemptID) ?? []
        waiters.forEach { $0.resume() }
    }

    private func waitForAttemptCompletion(_ attemptID: UUID) async {
        guard inFlightConnectID == attemptID else { return }
        await withCheckedContinuation { continuation in
            guard inFlightConnectID == attemptID else {
                continuation.resume()
                return
            }
            attemptWaiters[attemptID, default: []].append(continuation)
        }
    }

    private func setState(_ newState: ConnectionState) {
        state = newState
        stateContinuations.values.forEach { continuation in
            continuation.yield(newState)
        }
    }

    func removeStateContinuation(_ id: UUID) {
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
