import Foundation
import HerdrKit
@testable import Mudi

/// Compatibility names for the phase-2 contract. The tests exercise the
/// production coordinator and production lifecycle/error types directly.
typealias Phase2ConnectionState = ConnectionState
typealias Phase2HostKeyDecision = HostKeyDecision
typealias Phase2ConnectionError = ConnectionError

/// Contract used by the phase-2 tests. The implementation is the same
/// coordinator used by the app, with test doubles injected at its boundaries.
protocol Phase2Application: Sendable {
    func loadHosts() async throws -> [Host]
    func save(_ host: Host) async throws
    func save(_ credentials: SSHCredentials, for host: Host) async throws
    func credentials(for host: Host) async throws -> SSHCredentials?
    func delete(_ host: Host) async throws

    func connect(
        to host: Host,
        credentials: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> Phase2HostKeyDecision
    ) async throws -> Phase2ConnectionState
    func connectionState() async -> Phase2ConnectionState
    func connectionStateStream() async -> AsyncStream<Phase2ConnectionState>
    func disconnect() async
    func reconnect() async throws -> Phase2ConnectionState
}

extension ApplicationCoordinator: Phase2Application {}

actor Phase2HostFile {
    private var contents: Data?

    func write(hosts: [Host]) throws {
        contents = try JSONEncoder().encode(hosts)
    }

    func data() -> Data? {
        contents
    }

    func hosts() throws -> [Host] {
        guard let contents else { return [] }
        return try JSONDecoder().decode([Host].self, from: contents)
    }
}

actor Phase2Keychain {
    private var values: [Host.ID: SSHCredentials] = [:]

    func put(_ credentials: SSHCredentials, for host: Host) {
        values[host.id] = credentials
    }

    func credentials(for host: Host) -> SSHCredentials? {
        values[host.id]
    }

    func remove(for host: Host) {
        values[host.id] = nil
    }
}

actor Phase2KnownHostKeys {
    private var values: [Host.ID: String] = [:]

    func remember(_ fingerprint: String, for host: Host) {
        values[host.id] = fingerprint
    }

    func fingerprint(for host: Host) -> String? {
        values[host.id]
    }

    func remove(for host: Host) {
        values[host.id] = nil
    }
}

actor Phase2ConnectionGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            if started {
                continuation.resume()
            } else {
                startWaiters.append(continuation)
            }
        }
    }

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

struct Phase2ConnectionRecord: Sendable {
    let host: Host
    let credentials: SSHCredentials
}

/// A deterministic SSH transport double injected into the production
/// coordinator by the test factory below.
actor Phase2SSHClient: HostKeyAwareSSHClient {
    let presentedFingerprint: String
    private var outcomes: [Bool]
    private var attempts = 0
    private var records: [Phase2ConnectionRecord] = []
    private let firstConnectionGate: Phase2ConnectionGate?
    private let callbackStartedGate: Phase2ConnectionGate?
    private let failureGate: Phase2ConnectionGate?
    private let failAfterStartingHostKeyDecision: Bool

    init(
        presentedFingerprint: String,
        outcomes: [Bool] = [],
        firstConnectionGate: Phase2ConnectionGate? = nil,
        callbackStartedGate: Phase2ConnectionGate? = nil,
        failureGate: Phase2ConnectionGate? = nil,
        failAfterStartingHostKeyDecision: Bool = false
    ) {
        self.presentedFingerprint = presentedFingerprint
        self.outcomes = outcomes
        self.firstConnectionGate = firstConnectionGate
        self.callbackStartedGate = callbackStartedGate
        self.failureGate = failureGate
        self.failAfterStartingHostKeyDecision = failAfterStartingHostKeyDecision
    }

    func connect(
        to host: Host,
        credentials: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> Phase2HostKeyDecision
    ) async throws -> any PTYChannel {
        attempts += 1
        let attempt = attempts
        records.append(Phase2ConnectionRecord(host: host, credentials: credentials))

        if attempt == 1, let firstConnectionGate {
            await firstConnectionGate.markStarted()
            await firstConnectionGate.waitUntilReleased()
        }

        if attempt == 1, failAfterStartingHostKeyDecision {
            let fingerprint = presentedFingerprint
            Task {
                if let callbackStartedGate {
                    await callbackStartedGate.markStarted()
                }
                _ = await hostKeyDecision(fingerprint)
            }
            if let callbackStartedGate {
                await callbackStartedGate.waitUntilStarted()
            }
            if let failureGate {
                await failureGate.waitUntilReleased()
            }
            throw Phase2ConnectionError.connectionFailed
        }

        let decision = await hostKeyDecision(presentedFingerprint)
        guard decision == .accept else {
            throw Phase2ConnectionError.hostKeyRejected
        }

        let shouldFail = outcomes.isEmpty ? false : outcomes.removeFirst()
        if shouldFail {
            throw Phase2ConnectionError.connectionFailed
        }
        return Phase2PTY()
    }

    func connectionAttempts() -> Int {
        attempts
    }

    func connectionRecords() -> [Phase2ConnectionRecord] {
        records
    }
}

actor Phase2HostKeyPrompt {
    let decision: Phase2HostKeyDecision
    private var presentedFingerprints: [String] = []

    init(decision: Phase2HostKeyDecision) {
        self.decision = decision
    }

    func decide(for fingerprint: String) -> Phase2HostKeyDecision {
        presentedFingerprints.append(fingerprint)
        return decision
    }

    func fingerprints() -> [String] {
        presentedFingerprints
    }
}

private struct Phase2PTY: PTYChannel {
    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {}
}

private struct Phase2HostStore: HostStore {
    let file: Phase2HostFile

    func loadHosts() async throws -> [Host] {
        try await file.hosts()
    }

    func save(_ host: Host) async throws {
        var hosts = try await file.hosts()
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        try await file.write(hosts: hosts)
    }

    func delete(_ host: Host) async throws {
        let hosts = try await file.hosts().filter { $0.id != host.id }
        try await file.write(hosts: hosts)
    }
}

private struct Phase2CredentialStore: CredentialStore {
    let keychain: Phase2Keychain

    func save(_ credentials: SSHCredentials, for host: Host) async throws {
        await keychain.put(credentials, for: host)
    }

    func credentials(for host: Host) async throws -> SSHCredentials? {
        await keychain.credentials(for: host)
    }

    func delete(for host: Host) async throws {
        await keychain.remove(for: host)
    }
}

private struct Phase2KnownHostKeyStore: KnownHostKeyStore {
    let knownHostKeys: Phase2KnownHostKeys

    func remember(_ fingerprint: String, for host: Host) async throws {
        await knownHostKeys.remember(fingerprint, for: host)
    }

    func fingerprint(for host: Host) async throws -> String? {
        await knownHostKeys.fingerprint(for: host)
    }

    func delete(for host: Host) async throws {
        await knownHostKeys.remove(for: host)
    }
}

func makeMissingPhase2Application(
    hostFile: Phase2HostFile = Phase2HostFile(),
    keychain: Phase2Keychain = Phase2Keychain(),
    knownHostKeys: Phase2KnownHostKeys = Phase2KnownHostKeys(),
    client: Phase2SSHClient = Phase2SSHClient(presentedFingerprint: "SHA256:test")
) -> ApplicationCoordinator {
    ApplicationCoordinator(
        hostStore: Phase2HostStore(file: hostFile),
        credentialStore: Phase2CredentialStore(keychain: keychain),
        knownHostKeyStore: Phase2KnownHostKeyStore(knownHostKeys: knownHostKeys),
        client: client
    )
}

func phase2Host(id: UUID = UUID()) -> Host {
    Host(
        id: id,
        displayName: "Development Mac",
        hostname: "mac.example.test",
        port: 2222,
        username: "developer",
        preferredTransport: .ssh
    )
}

func phase2Credentials() -> SSHCredentials {
    let pemPrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    phase2-\(UUID().uuidString)
    -----END OPENSSH PRIVATE KEY-----
    """
    return SSHCredentials(
        password: "phase2-password-\(UUID().uuidString)",
        pemPrivateKey: pemPrivateKey
    )
}

func firstPhase2States(
    from stream: AsyncStream<Phase2ConnectionState>,
    count: Int
) async -> [Phase2ConnectionState] {
    var iterator = stream.makeAsyncIterator()
    var states: [Phase2ConnectionState] = []
    while states.count < count, let state = await iterator.next() {
        states.append(state)
    }
    return states
}

func dataContainsAny(_ data: Data?, markers: [String]) -> Bool {
    guard let data else { return false }
    return markers.contains { data.range(of: Data($0.utf8)) != nil }
}
