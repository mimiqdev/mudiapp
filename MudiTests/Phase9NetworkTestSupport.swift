import Darwin
import Foundation
import HerdrKit
@preconcurrency import NIOCore
@testable import Mudi

// MARK: - Address-family connection policy

/// The address-family values a resolver can hand to the SSH connector.
enum Phase9AddressFamily: String, Equatable, Hashable, Sendable {
    case ipv6
    case ipv4
}

struct Phase9ResolvedAddress: Equatable, Hashable, Sendable {
    let value: String
    let family: Phase9AddressFamily

    init(_ value: String, family: Phase9AddressFamily) {
        self.value = value
        self.family = family
    }
}

/// The phase-9 assertions exercise the production policy directly. The
/// address wrapper remains local to the tests, while timing and scheduling
/// live in the app target.
typealias Phase9ConnectionAttempt =
    NetworkConnectionAttempt<Phase9ResolvedAddress>
typealias Phase9ConnectionPolicy = NetworkConnectionPolicy

enum Phase9AddressConnectFailure: Error, Equatable, Sendable {
    case timedOut
    case unreachable
    case refused
}

enum Phase9AddressConnectResult: Equatable, Sendable {
    case success
    case failure(Phase9AddressConnectFailure)
}

struct Phase9ConnectionAttemptRecord: Equatable, Sendable {
    let address: Phase9ResolvedAddress
    let startAfter: Duration
    let timeout: Duration
    let startedAt: ContinuousClock.Instant
}

protocol Phase9AddressConnector: Sendable {
    func connect(
        to address: Phase9ResolvedAddress,
        startAfter: Duration,
        timeout: Duration
    ) async throws
}

/// Records the plan a strategy gives to its connector. It does not sleep: the
/// policy contract is tested as data, so a dead IPv6 attempt cannot make the
/// simulator suite wait for a real socket timeout.
actor Phase9RecordingAddressConnector: Phase9AddressConnector {
    private let outcomes: [String: Phase9AddressConnectResult]
    private var records: [Phase9ConnectionAttemptRecord] = []

    init(outcomes: [String: Phase9AddressConnectResult] = [:]) {
        self.outcomes = outcomes
    }

    func connect(
        to address: Phase9ResolvedAddress,
        startAfter: Duration,
        timeout: Duration
    ) async throws {
        records.append(
            Phase9ConnectionAttemptRecord(
                address: address,
                startAfter: startAfter,
                timeout: timeout,
                startedAt: ContinuousClock.now
            )
        )
        if case let .failure(failure) = outcomes[address.value] {
            throw failure
        }
    }

    func attemptRecords() -> [Phase9ConnectionAttemptRecord] {
        records
    }
}

/// Blocks the first family until the test releases it. A serial strategy
/// therefore cannot manufacture a passing startAfter value: the recorder must
/// observe the alternate family begin while this first connect is suspended.
actor Phase9BlockingAddressConnector: Phase9AddressConnector {
    private let blockingAddress: Phase9ResolvedAddress
    private let outcomes: [String: Phase9AddressConnectResult]
    private var records: [Phase9ConnectionAttemptRecord] = []
    private var blockingAttemptReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [Phase9ResolvedAddress: [CheckedContinuation<Void, Never>]] = [:]

    init(
        blockingAddress: Phase9ResolvedAddress,
        outcomes: [String: Phase9AddressConnectResult] = [:]
    ) {
        self.blockingAddress = blockingAddress
        self.outcomes = outcomes
    }

    func connect(
        to address: Phase9ResolvedAddress,
        startAfter: Duration,
        timeout: Duration
    ) async throws {
        records.append(
            Phase9ConnectionAttemptRecord(
                address: address,
                startAfter: startAfter,
                timeout: timeout,
                startedAt: ContinuousClock.now
            )
        )
        let waiters = startWaiters.removeValue(forKey: address) ?? []
        for waiter in waiters {
            waiter.resume()
        }

        if address == blockingAddress {
            await waitForBlockingRelease()
        }
        if case let .failure(failure) = outcomes[address.value] {
            throw failure
        }
    }

    func waitUntilStarted(_ address: Phase9ResolvedAddress) async {
        guard !records.contains(where: { $0.address == address }) else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters[address, default: []].append(continuation)
        }
    }

    func hasStarted(_ address: Phase9ResolvedAddress) -> Bool {
        records.contains(where: { $0.address == address })
    }

    func releaseBlockingAttempt() {
        blockingAttemptReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func attemptRecords() -> [Phase9ConnectionAttemptRecord] {
        records
    }

    private func waitForBlockingRelease() async {
        guard !blockingAttemptReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}

/// A virtual slow connector used to prove that policy timeout values, rather
/// than wall-clock sleeps, govern cancellation.
struct Phase9SlowAddressConnector: Phase9AddressConnector {
    let successfulAfter: Duration

    func connect(
        to _: Phase9ResolvedAddress,
        startAfter _: Duration,
        timeout: Duration
    ) async throws {
        guard successfulAfter <= timeout else {
            throw Phase9AddressConnectFailure.timedOut
        }
    }
}

enum Phase9ConnectionStrategyError: Error, Equatable, Sendable {
    case allAttemptsFailed
}

/// Keeps the original test call site while routing every attempt through
/// the production Happy Eyeballs strategy.
enum MissingPhase9ConnectionStrategy {
    static func connect(
        to addresses: [Phase9ResolvedAddress],
        policy: Phase9ConnectionPolicy,
        using connector: any Phase9AddressConnector
    ) async throws -> Phase9ResolvedAddress {
        try await NetworkConnectionStrategy.connect(
            to: addresses,
            policy: policy,
            using: { address, startAfter, timeout in
                try await connector.connect(
                    to: address,
                    startAfter: startAfter,
                    timeout: timeout
                )
            }
        )
    }
}

// MARK: - Network path monitoring

final class Phase9NetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private var handler: (@Sendable (NetworkPathSnapshot) -> Void)?

    func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        self.handler = handler
    }

    func cancel() {
        handler = nil
    }

    func emit(_ path: NetworkPathSnapshot) {
        handler?(path)
    }
}

// MARK: - Mosh Auto fallback

typealias Phase9MoshFailureClass = MoshFailureClass

actor Phase9MoshAttemptRecorder {
    private var failures: [Phase9MoshFailureClass] = []
    private var disconnectCountValue = 0

    func record(_ failure: Phase9MoshFailureClass) {
        failures.append(failure)
    }

    func recordDisconnect() {
        disconnectCountValue += 1
    }

    func recordedFailures() -> [Phase9MoshFailureClass] {
        failures
    }

    func disconnectCount() -> Int {
        disconnectCountValue
    }
}

struct Phase9MoshFailureTransport: MoshTransportBootstrapping {
    let failure: Phase9MoshFailureClass
    let recorder: Phase9MoshAttemptRecorder

    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession
    ) async throws -> SSHShellSession {
        await recorder.record(failure)
        throw failure
    }

    func disconnect() async {
        await recorder.recordDisconnect()
    }
}

actor Phase9MoshSuccessTransport: MoshTransportBootstrapping {
    private let session: SSHShellSession
    private var connectCountValue = 0
    private var disconnectCountValue = 0

    init(session: SSHShellSession = SSHShellSession(
        connectedChannel: Phase9MoshPTY()
    )) {
        self.session = session
    }

    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession
    ) async throws -> SSHShellSession {
        connectCountValue += 1
        return session
    }

    func disconnect() async {
        disconnectCountValue += 1
    }

    func connectCount() -> Int {
        connectCountValue
    }

    func disconnectCount() -> Int {
        disconnectCountValue
    }
}

private struct Phase9MoshPTY: PTYChannel {
    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {}
}

/// Throws a concrete SwiftMosh/NIO adapter error so classification cannot
/// pass by special-casing ``MoshFailureClass``.
struct Phase9ThrowingMoshTransport: MoshTransportBootstrapping {
    let error: any Error

    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession
    ) async throws -> SSHShellSession {
        throw error
    }

    func disconnect() async {}
}

func phase9Host(
    id: UUID = UUID(),
    preferredTransport: TransportPreference = .automatic
) -> Host {
    Host(
        id: id,
        displayName: "Phase 9 Network Host",
        hostname: "phase9.example.test",
        port: 2222,
        username: "developer",
        preferredTransport: preferredTransport
    )
}

// MARK: - Presentable network failures

enum Phase9RawNetworkFailure: Equatable, Hashable, LocalizedError, Sendable {
    case timedOut
    case unreachable
    case refused

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "NIOSSH.ChannelError.connectTimeout(60s)"
        case .unreachable:
            "NIO.IOError(EHOSTUNREACH)"
        case .refused:
            "NIO.IOError(ECONNREFUSED)"
        }
    }

    /// Use the actual NIO error shapes so the production mapper cannot pass
    /// by special-casing this test enum.
    func makeError() -> any Error {
        switch self {
        case .timedOut:
            ChannelError.connectTimeout(.seconds(60))
        case .unreachable:
            IOError(errnoCode: EHOSTUNREACH, reason: "host unreachable")
        case .refused:
            IOError(errnoCode: ECONNREFUSED, reason: "connection refused")
        }
    }
}

/// Emits the kinds of low-level failures the current coordinator collapses
/// into one generic ConnectionError. The production mapping tests use this
/// boundary without opening a real socket on the simulator.
struct Phase9FailingSSHClient: HostKeyAwareSSHClient {
    let failure: Phase9RawNetworkFailure

    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        hostKeyDecision _: @escaping @Sendable (String) async -> HostKeyDecision
    ) async throws -> any PTYChannel {
        throw failure.makeError()
    }
}

private struct Phase9EmptyHostStore: HostStore {
    func loadHosts() async throws -> [Host] { [] }

    func save(_: Host) async throws {}

    func delete(_: Host) async throws {}
}

private struct Phase9EmptyCredentialStore: CredentialStore {
    func save(_: SSHCredentials, for _: Host) async throws {}

    func credentials(for _: Host) async throws -> SSHCredentials? { nil }

    func delete(for _: Host) async throws {}
}

private struct Phase9EmptyKnownHostKeyStore: KnownHostKeyStore {
    func remember(_: String, for _: Host) async throws {}

    func fingerprint(for _: Host) async throws -> String? { nil }

    func delete(for _: Host) async throws {}
}

func makePhase9NetworkApplication(
    client: any HostKeyAwareSSHClient
) -> ApplicationCoordinator {
    ApplicationCoordinator(
        hostStore: Phase9EmptyHostStore(),
        credentialStore: Phase9EmptyCredentialStore(),
        knownHostKeyStore: Phase9EmptyKnownHostKeyStore(),
        client: client,
        moshTransport: Phase9NoopMoshTransport()
    )
}

private struct Phase9NoopMoshTransport: MoshTransportBootstrapping {
    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession
    ) async throws -> SSHShellSession {
        throw Phase9MoshFailureClass.moshServerUnavailable
    }

    func disconnect() async {}
}
