import Foundation
import HerdrKit
@testable import Mudi

/// The phase-5 contract is backed by the production transport coordinator;
/// only persistence and connector boundaries are test doubles.
protocol Phase5TransportApplication: Sendable {
    func loadHosts() async throws -> [Host]
    func save(_ host: Host) async throws
    func save(_ credentials: SSHCredentials, for host: Host) async throws
    func credentials(for host: Host) async throws -> SSHCredentials?
    func connect(to host: Host) async throws -> ActiveTransport
    func activeTransport() async -> ActiveTransport?
}

enum Phase5TransportError: Error, Equatable, LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The requested transport is unavailable."
        }
    }
}

struct Phase5MoshFailureTransport: MoshTransportBootstrapping {
    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession
    ) async throws -> SSHShellSession {
        throw Phase5TransportError.unavailable
    }

    func disconnect() async {}
}

struct Phase5ConnectionRecord: Equatable, Sendable {
    let host: Host
    let credentials: SSHCredentials
}

/// A deterministic transport double. It records attempted connections even
/// when unavailable so Auto tests can distinguish fallback from SSH-only
/// behavior.
actor Phase5TransportSpy {
    let kind: ActiveTransport
    private let available: Bool
    private var records: [Phase5ConnectionRecord] = []

    init(kind: ActiveTransport, available: Bool = true) {
        self.kind = kind
        self.available = available
    }

    func connect(to host: Host, credentials: SSHCredentials) throws {
        records.append(Phase5ConnectionRecord(host: host, credentials: credentials))
        guard available else {
            throw Phase5TransportError.unavailable
        }
    }

    func connectionAttempts() -> Int {
        records.count
    }

    func connectionRecords() -> [Phase5ConnectionRecord] {
        records
    }
}

/// File-shaped storage matching the phase-2 persistence double. Only encoded
/// Host values cross this boundary; credentials are held by Phase5Keychain.
actor Phase5HostFile {
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

actor Phase5Keychain {
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

private struct Phase5HostStore: HostStore {
    let file: Phase5HostFile

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

private struct Phase5CredentialStore: CredentialStore {
    let keychain: Phase5Keychain

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

/// Adapt the test double to the production connector boundary. The tests
/// still control availability and inspect the same connection records, but
/// transport selection itself runs in the app target.
private struct Phase5TransportConnector: TransportConnector {
    let spy: Phase5TransportSpy

    func connect(to host: Host, credentials: SSHCredentials) async throws {
        try await spy.connect(to: host, credentials: credentials)
    }
}

/// Keep the factory name used by the phase contract while making it return the
/// production coordinator rather than a test-only implementation.
typealias MissingPhase5Application = TransportSelectionCoordinator

extension TransportSelectionCoordinator: Phase5TransportApplication {}

func makeMissingPhase5Application(
    hostFile: Phase5HostFile = Phase5HostFile(),
    keychain: Phase5Keychain = Phase5Keychain(),
    sshTransport: Phase5TransportSpy = Phase5TransportSpy(kind: .ssh),
    moshTransport: Phase5TransportSpy = Phase5TransportSpy(kind: .mosh)
) -> MissingPhase5Application {
    TransportSelectionCoordinator(
        hostStore: Phase5HostStore(file: hostFile),
        credentialStore: Phase5CredentialStore(keychain: keychain),
        sshTransport: Phase5TransportConnector(spy: sshTransport),
        moshTransport: Phase5TransportConnector(spy: moshTransport)
    )
}

func phase5Host(
    id: UUID = UUID(),
    preferredTransport: TransportPreference = .automatic
) -> Host {
    Host(
        id: id,
        displayName: "Phase 5 Host",
        hostname: "phase5.example.test",
        port: 2222,
        username: "developer",
        preferredTransport: preferredTransport
    )
}

func phase5Credentials() -> SSHCredentials {
    SSHCredentials(
        password: "phase5-password",
        pemPrivateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        phase5-private-key
        -----END OPENSSH PRIVATE KEY-----
        """
    )
}
