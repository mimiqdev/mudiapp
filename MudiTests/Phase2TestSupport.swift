import Foundation
import HerdrKit

/// The connection states required by the phase-2 contract.
///
/// This is test-only scaffolding until the app's connection coordinator has a
/// production state model.
enum Phase2ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed
    case disconnected
}

enum Phase2HostKeyDecision: Sendable {
    case accept
    case reject
}

enum Phase2ConnectionError: Error, Equatable, LocalizedError, Sendable {
    case notImplemented
    case connectionFailed
    case hostKeyRejected
    case hostKeyMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            "The phase-2 SSH connection is not implemented."
        case .connectionFailed:
            "Unable to connect to the SSH host."
        case .hostKeyRejected:
            "The SSH host key was rejected."
        case let .hostKeyMismatch(expected, actual):
            "The SSH host key does not match the remembered fingerprint (expected \(expected), received \(actual))."
        }
    }
}

/// Contract used by the phase-2 tests. The implementation phase will replace
/// `MissingPhase2Application` with the real app coordinator.
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
    func stateHistory() async -> [Phase2ConnectionState]
    func disconnect() async
    func reconnect() async throws -> Phase2ConnectionState
}

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

/// A deterministic SSH transport double. It is intentionally not wired into
/// `MissingPhase2Application`; the failing assertions identify the missing
/// production coordinator rather than making the test double pass the tests.
actor Phase2SSHClient {
    let presentedFingerprint: String
    private var outcomes: [Bool]
    private var attempts = 0

    init(presentedFingerprint: String, outcomes: [Bool] = []) {
        self.presentedFingerprint = presentedFingerprint
        self.outcomes = outcomes
    }

    func connect() throws {
        attempts += 1
        let shouldFail = outcomes.isEmpty ? false : outcomes.removeFirst()
        if shouldFail {
            throw Phase2ConnectionError.connectionFailed
        }
    }

    func connectionAttempts() -> Int {
        attempts
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

/// Compile-only scaffold for the tests-first step. It has no product behavior
/// by design: phase-2 tests should be red until the real slices are added.
actor MissingPhase2Application: Phase2Application {
    let hostFile: Phase2HostFile
    let keychain: Phase2Keychain
    let knownHostKeys: Phase2KnownHostKeys
    let client: Phase2SSHClient

    init(
        hostFile: Phase2HostFile,
        keychain: Phase2Keychain,
        knownHostKeys: Phase2KnownHostKeys,
        client: Phase2SSHClient
    ) {
        self.hostFile = hostFile
        self.keychain = keychain
        self.knownHostKeys = knownHostKeys
        self.client = client
    }

    func loadHosts() async throws -> [Host] {
        []
    }

    func save(_: Host) async throws {}

    func save(_: SSHCredentials, for _: Host) async throws {}

    func credentials(for _: Host) async throws -> SSHCredentials? {
        nil
    }

    func delete(_: Host) async throws {}

    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        hostKeyDecision _: @escaping @Sendable (String) async -> Phase2HostKeyDecision
    ) async throws -> Phase2ConnectionState {
        throw Phase2ConnectionError.notImplemented
    }

    func connectionState() async -> Phase2ConnectionState {
        .idle
    }

    func stateHistory() async -> [Phase2ConnectionState] {
        []
    }

    func disconnect() async {}

    func reconnect() async throws -> Phase2ConnectionState {
        throw Phase2ConnectionError.notImplemented
    }
}

func makeMissingPhase2Application(
    hostFile: Phase2HostFile = Phase2HostFile(),
    keychain: Phase2Keychain = Phase2Keychain(),
    knownHostKeys: Phase2KnownHostKeys = Phase2KnownHostKeys(),
    client: Phase2SSHClient = Phase2SSHClient(presentedFingerprint: "SHA256:test")
) -> MissingPhase2Application {
    MissingPhase2Application(
        hostFile: hostFile,
        keychain: keychain,
        knownHostKeys: knownHostKeys,
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
    SSHCredentials(
        password: "phase2-password-\(UUID().uuidString)",
        pemPrivateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nphase2-\(UUID().uuidString)\n-----END OPENSSH PRIVATE KEY-----"
    )
}

func dataContainsAny(_ data: Data?, markers: [String]) -> Bool {
    guard let data else { return false }
    return markers.contains { data.range(of: Data($0.utf8)) != nil }
}
