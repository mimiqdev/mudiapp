import Foundation
import HerdrKit
import os

/// The application-level coordinator for saved hosts and one active shell.
///
/// Host configuration is delegated to the host store, while credentials and
/// accepted host keys use separate secure stores. The coordinator keeps the
/// SSH bootstrap session for Herdr discovery and exposes the selected terminal
/// session separately when Mosh is available.
actor ApplicationCoordinator: Sendable {  // pi-lens-ignore: type_body_length
    let hostStore: any HostStore
    let credentialStore: any CredentialStore
    let knownHostKeyStore: any KnownHostKeyStore
    let client: any HostKeyAwareSSHClient
    let moshTransport: any MoshTransportBootstrapping
    let networkConnector: (any HostAddressNetworkConnecting)?
    let addressRacePolicy: HostAddressRacePolicy
    let addressRaceClock: any HostAddressRaceClock
    let reconnectTimeout: Duration

    var state: ConnectionState = .idle
    var session: SSHShellSession?
    var terminalSession: SSHShellSession?
    var activeTransportValue: ActiveTransport?
    var lastAutomaticMoshFailure: MoshFailureClass?
    private var activeHostID: Host.ID?
    var activeHostValue: Host?
    private var addressPromotionEnabled = false
    private var lastSuccessfulAddressByHostID: [Host.ID: HostAddress] = [:]
    private var lastAddressRaceError: HostAddressConnectionRaceError?
    private var hostKeyError: (attemptID: UUID, error: ConnectionError)?
    private var inFlightConnectID: UUID?
    private var preserveTerminalSessionForAttempt = false
    private var disconnectRequestedFor: UUID?
    private var attemptWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    init(
        hostStore: any HostStore = JSONHostStore(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        knownHostKeyStore: any KnownHostKeyStore = KeychainKnownHostKeyStore(),
        client: any HostKeyAwareSSHClient = CitadelSSHAdapter(),
        moshTransport: any MoshTransportBootstrapping = TraversioMoshAdapter(),
        reconnectTimeout: Duration = NetworkConnectionPolicy
            .documentedDefault.perAttemptTimeout,
        networkConnector: (any HostAddressNetworkConnecting)? = nil,
        addressRacePolicy: HostAddressRacePolicy = .default,
        addressRaceClock: any HostAddressRaceClock = ContinuousHostAddressRaceClock()
    ) {
        self.hostStore = hostStore
        self.credentialStore = credentialStore
        self.knownHostKeyStore = knownHostKeyStore
        self.client = client
        self.moshTransport = moshTransport
        self.networkConnector = networkConnector ?? (client as? any HostAddressNetworkConnecting)
        self.addressRacePolicy = addressRacePolicy
        self.addressRaceClock = addressRaceClock
        self.reconnectTimeout = reconnectTimeout
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
            activeHostValue = nil
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
        try await connect(
            to: host,
            credentials: credentials,
            hostKeyDecision: hostKeyDecision,
            progress: nil
        )
    }

    func connect(
        to host: Host,
        credentials: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision,
        progress: (@Sendable (HostAddressRaceProgress) async -> Void)?
    ) async throws -> ConnectionState { // pi-lens-ignore: function_body_length
        guard inFlightConnectID == nil,
              state != .connecting,
              state != .connected
        else {
            throw ConnectionError.connectionFailed
        }

        let attemptID = UUID()
        activeHostID = host.id
        activeHostValue = nil
        activeTransportValue = nil
        lastAutomaticMoshFailure = nil
        lastAddressRaceError = nil
        hostKeyError = nil
        preserveTerminalSessionForAttempt = false
        disconnectRequestedFor = nil
        inFlightConnectID = attemptID
        setState(.connecting)

        do {
            return try await establishConnection(
                to: host,
                credentials: credentials,
                hostKeyDecision: hostKeyDecision,
                progress: progress,
                attemptID: attemptID
            )
        } catch {
            if let raceError = error as? HostAddressConnectionRaceError {
                lastAddressRaceError = raceError
            }
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

    private func establishConnection(
        to host: Host,
        credentials: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision,
        progress: (@Sendable (HostAddressRaceProgress) async -> Void)?,
        attemptID: UUID
    ) async throws -> ConnectionState {
        let connectionHost = try await resolveConnectionHost(
            for: host,
            progress: progress
        )
        guard inFlightConnectID == attemptID,
              activeHostID == host.id,
              !Task.isCancelled
        else {
            throw CancellationError()
        }
        activeHostValue = connectionHost
        let channel = try await client.connect(
            to: connectionHost,
            credentials: credentials,
            hostKeyDecision: { [weak self] fingerprint in
                guard let self else { return .reject }
                return await self.evaluateHostKey(
                    fingerprint,
                    for: attemptID,
                    host: connectionHost,
                    userDecision: hostKeyDecision
                )
            }
        )
        let bootstrapSession = SSHShellSession(connectedChannel: channel)
        let selection: (transport: ActiveTransport, moshConnection: SSHShellSession?)
        do {
            selection = try await TransportSelectionStrategy.select(
                preference: connectionHost.preferredTransport,
                bootstrapSSH: {},
                connectMosh: { [moshTransport, bootstrapSession] in
                    try await moshTransport.connect(
                        to: connectionHost,
                        credentials: credentials,
                        using: bootstrapSession
                    )
                },
                onMoshFailure: { [weak self] failureClass in
                    await self?.recordAutomaticMoshFailure(failureClass)
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
        if let selectedTarget = connectionHost.selectedTarget {
            lastSuccessfulAddressByHostID[host.id] = selectedTarget
        }
        inFlightConnectID = nil
        disconnectRequestedFor = nil
        setState(.connected)
        return .connected
    }

    private func resolveConnectionHost(
        for host: Host,
        progress: (@Sendable (HostAddressRaceProgress) async -> Void)?
    ) async throws -> Host {
        let orderedAddresses = orderedAddresses(for: host)
        guard let firstAddress = orderedAddresses.first else {
            throw HostAddressConnectionRaceError.invalidAddressList
        }

        // A legacy/test client without the pre-auth network seam keeps the
        // single-address behavior. Production Citadel supplies the seam, so
        // multi-address racing never starts authentication on a loser.
        guard orderedAddresses.count > 1,
              let networkConnector
        else {
            return host.targeting(firstAddress)
        }

        do {
            let result = try await HostAddressConnectionRace.connect(
                addresses: orderedAddresses,
                policy: addressRacePolicy,
                clock: addressRaceClock,
                using: { [networkConnector] address in
                    try await networkConnector.connectNetwork(
                        to: host.targeting(address)
                    )
                },
                onProgress: progress
            )
            await result.connection.close()
            return host.targeting(result.target)
        } catch let error as HostAddressConnectionRaceError {
            lastAddressRaceError = error
            throw error
        }
    }

    private func orderedAddresses(for host: Host) -> [HostAddress] {
        if let selectedTarget = host.selectedTarget,
           let index = host.addresses.firstIndex(of: selectedTarget) {
            return [selectedTarget] + host.addresses.enumerated().compactMap {
                $0.offset == index ? nil : $0.element
            }
        }
        guard addressPromotionEnabled,
              let lastSuccessful = lastSuccessfulAddressByHostID[host.id],
              let index = host.addresses.firstIndex(of: lastSuccessful)
        else {
            return host.addresses
        }
        return [lastSuccessful] + host.addresses.enumerated().compactMap {
            $0.offset == index ? nil : $0.element
        }
    }

    private func reconnectTarget(for savedHost: Host) -> Host {
        guard let selectedTarget = activeHostValue?.selectedTarget,
              savedHost.addresses.contains(selectedTarget)
        else {
            return savedHost
        }
        return savedHost.targeting(selectedTarget)
    }

    func setAddressPromotionEnabled(_ enabled: Bool) {
        addressPromotionEnabled = enabled
    }

    func isAddressPromotionEnabled() -> Bool {
        addressPromotionEnabled
    }

    func lastAddressRaceFailure() -> HostAddressConnectionRaceError? {
        lastAddressRaceError
    }

    /// Retires a pending bootstrap immediately. The underlying client may
    /// still deliver a late channel, which connect() rejects by attempt ID.
    func cancelPendingConnection() {
        guard let attemptID = inFlightConnectID else { return }
        disconnectRequestedFor = attemptID
        finishAttempt(attemptID, state: .failed)
    }

    /// Disconnects the coordinator's current connection.
    ///
    /// Ownership contract: this retires an in-flight attempt because the
    /// caller owns it (the user disconnected while connecting, or the active
    /// host is being deleted). A superseded task must NOT call this - the
    /// attempt it belonged to may already be gone and the coordinator may now
    /// be serving a newer attempt, whose attempt/session this would then
    /// retire. Superseded tasks leave cleanup to their invalidator (cancel,
    /// teardown, delete, transparent reconnect).
    func disconnect() async {
        if let attemptID = inFlightConnectID {
            disconnectRequestedFor = attemptID
            return
        }
        // A call with nothing to retire is a no-op. That keeps a late
        // stale-attempt cleanup from turning a user-cancelled, idle Host
        // list back into a failure surface.
        guard hasSessionToDisconnect else { return }
        await disconnectCurrentSession()
        activeTransportValue = nil
        if state != .disconnected {
            setState(.disconnected)
        }
    }

    private var hasSessionToDisconnect: Bool {
        session != nil
            || terminalSession != nil
            || activeTransportValue != nil
            || state == .connecting
            || state == .connected
    }

    /// User-initiated cancel of the in-flight connect attempt.
    ///
    /// The attempt is retired by attempt ID first, so a channel delivered by
    /// a cancellation-ignoring client is rejected and closed instead of being
    /// mounted. Anything the attempt already opened is then closed with the
    /// same bounded budget as a navigation teardown, and the coordinator
    /// converges to idle so the Host list keeps no failure residue.
    func cancelConnectionAttempt() async {
        if let attemptID = inFlightConnectID {
            disconnectRequestedFor = attemptID
            finishAttempt(
                attemptID,
                state: .idle,
                preservingTerminalSession: false
            )
        }
        await disconnectCurrentSession()
        activeTransportValue = nil
        lastAutomaticMoshFailure = nil
        preserveTerminalSessionForAttempt = false
        if state != .idle {
            setState(.idle)
        }
    }

    /// Requests a disconnect and does not return until a pending handshake or
    /// connected shell has fully torn down. UI callers use this boundary when
    /// another connection may be started immediately afterwards.
    func disconnectAndWait() async {
        if let attemptID = inFlightConnectID {
            let preservesTerminalSession = preserveTerminalSessionForAttempt
            disconnectRequestedFor = attemptID
            await waitForAttemptCompletion(attemptID)
            if preservesTerminalSession {
                await disconnectCurrentSession()
                activeTransportValue = nil
                if state != .disconnected {
                    setState(.disconnected)
                }
            }
            return
        }
        await disconnectCurrentSession()
        activeTransportValue = nil
        if state != .disconnected {
            setState(.disconnected)
        }
    }

    /// Disconnects only the SSH bootstrap while retaining a live Mosh data
    /// session. Transparent recovery uses this to rebuild Herdr control over
    /// SSH without interrupting the terminal's Mosh transport.
    func disconnectBootstrapAndWait(
        preservingTerminalSession: Bool = false
    ) async {
        // The caller must opt in before the bounded close starts. This is the
        // only intent forceDisconnectedAfterCloseTimeout may use to retain a
        // Mosh session during transparent control-plane recovery.
        preserveTerminalSessionForAttempt = preservingTerminalSession
            && activeTransportValue == .mosh
            && terminalSession != nil
        if let attemptID = inFlightConnectID {
            let preservesTerminalSession = preserveTerminalSessionForAttempt
            disconnectRequestedFor = attemptID
            await waitForAttemptCompletion(attemptID)
            if preservesTerminalSession {
                await disconnectCurrentSession()
                activeTransportValue = nil
                if state != .disconnected {
                    setState(.disconnected)
                }
            }
            return
        }
        await disconnectBootstrapSession()
        if state != .disconnected {
            setState(.disconnected)
        }
    }

    /// Clears a preservation request after the bounded bootstrap close
    /// completed without needing the timeout abort path. The reconnect
    /// attempt sets its own intent again before it opens the replacement SSH
    /// control channel.
    func clearTerminalSessionPreservationForAttempt() {
        preserveTerminalSessionForAttempt = false
    }

    func reconnect(
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision
    ) async throws -> ConnectionState {
        try await reconnect(
            hostKeyDecision: hostKeyDecision,
            preservingMoshSession: false,
            progress: nil
        )
    }

    /// Reconnects only the SSH control plane when Mosh owns the live terminal.
    /// The existing Mosh session remains in memory and is not handed to the
    /// Mosh adapter again, which would otherwise tear it down.
    func reconnect(
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision,
        preservingMoshSession: Bool = false,
        progress: (@Sendable (HostAddressRaceProgress) async -> Void)? = nil
    ) async throws -> ConnectionState {
        try await runWithTimeout(
            reconnectTimeout,
            operation: { [weak self] in
                guard let self else {
                    throw ConnectionError.connectionFailed
                }
                return try await self.performReconnect(
                    hostKeyDecision: hostKeyDecision,
                    preservingMoshSession: preservingMoshSession,
                    progress: progress
                )
            },
            onAbort: { [weak self] in
                await self?.cancelPendingConnection()
            }
        )
    }

    private func performReconnect(
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision,
        preservingMoshSession: Bool = false,
        progress: (@Sendable (HostAddressRaceProgress) async -> Void)? = nil
    ) async throws -> ConnectionState {
        try Task.checkCancellation()
        guard inFlightConnectID == nil else {
            throw ConnectionError.connectionFailed
        }
        guard let activeHostID else {
            setState(.failed)
            throw ConnectionError.connectionFailed
        }
        guard !preservingMoshSession
                || (activeTransportValue == .mosh && terminalSession != nil)
        else {
            setState(.failed)
            throw ConnectionError.connectionFailed
        }

        let host: Host
        do {
            guard let savedHost = try await hostStore.loadHosts().first(where: { $0.id == activeHostID }) else {
                setState(.failed)
                throw ConnectionError.connectionFailed
            }
            host = reconnectTarget(for: savedHost)
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
        try Task.checkCancellation()

        if preservingMoshSession {
            return try await connectSSHBootstrapPreservingMosh(
                to: host,
                credentials: credentials,
                hostKeyDecision: hostKeyDecision
            )
        }
        return try await connect(
            to: host,
            credentials: credentials,
            hostKeyDecision: hostKeyDecision,
            progress: progress
        )
    }

    private func connectSSHBootstrapPreservingMosh(
        to host: Host,
        credentials: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision
    ) async throws -> ConnectionState {
        guard activeTransportValue == .mosh,
              terminalSession != nil,
              inFlightConnectID == nil
        else {
            throw ConnectionError.connectionFailed
        }

        let attemptID = UUID()
        activeHostID = host.id
        hostKeyError = nil
        preserveTerminalSessionForAttempt = true
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
            guard inFlightConnectID == attemptID,
                  activeHostID == host.id,
                  disconnectRequestedFor != attemptID,
                  !Task.isCancelled
            else {
                await bootstrapSession.disconnect()
                finishAttempt(
                    attemptID,
                    state: .disconnected,
                    preservingTerminalSession: true
                )
                throw ConnectionError.connectionFailed
            }

            session = bootstrapSession
            inFlightConnectID = nil
            preserveTerminalSessionForAttempt = false
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

            await disconnectBootstrapSession()
            let wasDisconnectRequested = disconnectRequestedFor == attemptID
                || state == .disconnected
                || Task.isCancelled
            finishAttempt(
                attemptID,
                state: wasDisconnectRequested ? .disconnected : .failed,
                preservingTerminalSession: true
            )
            throw connectionError
        }
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

    /// Maximum budget to wait for channel/socket closure before abandoning it.
    static let channelCloseTimeout = Duration.seconds(1)

    func forceDisconnectedAfterCloseTimeout() async {
        let preservesTerminalSession = preserveTerminalSessionForAttempt
        let shouldDisconnectMosh = activeTransportValue == .mosh
            && !preservesTerminalSession
        session = nil
        if !preservesTerminalSession {
            terminalSession = nil
            activeTransportValue = nil
        }
        // The timeout caller has abandoned the normal disconnect operation.
        // Retire the Mosh adapter here as well, except for the explicit
        // transparent-recovery handoff that is preserving its data plane.
        preserveTerminalSessionForAttempt = false
        if state != .disconnected {
            setState(.disconnected)
        }
        if shouldDisconnectMosh {
            let moshTransport = self.moshTransport
            _ = try? await runWithTimeout(
                Self.channelCloseTimeout,
                operation: { await moshTransport.disconnect() },
                onAbort: {}
            )
        }
    }

    private func disconnectBootstrapSession() async {
        let bootstrapSession = session
        session = nil
        guard let bootstrapSession else { return }
        if let terminalSession,
           ObjectIdentifier(bootstrapSession) == ObjectIdentifier(terminalSession) {
            return
        }
        _ = try? await runWithTimeout(
            Self.channelCloseTimeout,
            operation: {
                await bootstrapSession.disconnect()
            },
            onAbort: {}
        )
    }

    private func disconnectCurrentSession() async {
        let bootstrapSession = session
        let terminalSession = self.terminalSession
        session = nil
        self.terminalSession = nil

        _ = try? await runWithTimeout(
            Self.channelCloseTimeout,
            operation: {
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
                await self.moshTransport.disconnect()
            },
            onAbort: {}
        )
    }

    private func finishAttempt(
        _ attemptID: UUID,
        state: ConnectionState,
        preservingTerminalSession: Bool? = nil
    ) {
        guard inFlightConnectID == attemptID else { return }
        let preservesTerminalSession = preservingTerminalSession
            ?? preserveTerminalSessionForAttempt
        inFlightConnectID = nil
        disconnectRequestedFor = nil
        hostKeyError = nil
        session = nil
        if !preservesTerminalSession {
            terminalSession = nil
            activeTransportValue = nil
        }
        preserveTerminalSessionForAttempt = false
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

    /// Records the classified Auto fallback reason for diagnostics. Successful
    /// SSH fallback must not surface this as a connection error.
    func recordAutomaticMoshFailure(_ failure: MoshFailureClass) {
        lastAutomaticMoshFailure = failure
        Self.transportLog.info(
            "Automatic transport fell back to SSH: \(String(describing: failure), privacy: .public)"
        )
    }

    private static let transportLog = Logger(
        subsystem: "dev.mudi.mobile",
        category: "transport-selection"
    )
}
