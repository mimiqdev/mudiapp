import Foundation
import HerdrKit
@testable import Mudi

/// Navigation contract for the phase-4 tests. The implementation step can
/// replace this test-only seam with the root model and its real coordinators.
enum Phase4NavigationState: Equatable, Sendable {
    case hosts([Host])
    case herdr(HerdrBrowserState)
    case terminal(Phase4AttachedTerminal)
}

struct Phase4AttachedTerminal: Equatable, Sendable {
    let host: Host
    let pane: Pane
    let title: String
}

protocol Phase4NavigationApplication: Sendable {
    func coldStart() async -> Phase4NavigationState
    func loadHosts() async throws -> [Host]
    func save(_ host: Host) async throws
    func connect(to host: Host) async throws -> Phase4NavigationState
    func selectPane(_ paneID: Pane.ID) async -> Phase4NavigationState
    func returnToHosts() async -> Phase4NavigationState
    func restoreLastPane() async -> Phase4NavigationState
    func isConnected() async -> Bool
}

/// A file-shaped host store used to exercise a second application instance.
/// It stores only the same Codable Host values as the production host store.
actor Phase4HostFile {
    private var contents: Data?

    func write(hosts: [Host]) throws {
        contents = try JSONEncoder().encode(hosts)
    }

    func hosts() throws -> [Host] {
        guard let contents else { return [] }
        return try JSONDecoder().decode([Host].self, from: contents)
    }
}

actor Phase4TerminalTransport {
    private var connected = false
    private var attachedPanes: [Pane] = []
    private var disconnectCount = 0

    func connect(to _: Host) {
        connected = true
    }

    func attach(to pane: Pane) {
        attachedPanes.append(pane)
    }

    func disconnect() {
        connected = false
        disconnectCount += 1
    }

    func isConnected() -> Bool {
        connected
    }

    func attachments() -> [Pane] {
        attachedPanes
    }

    func disconnections() -> Int {
        disconnectCount
    }
}

/// Compile-only scaffold for the tests-first step. It deliberately leaves the
/// phase-4 navigation behavior incomplete so the new tests are red until the
/// production root/navigation model is implemented.
actor MissingPhase4NavigationApplication: Phase4NavigationApplication {
    let hostFile: Phase4HostFile
    let transport: Phase4TerminalTransport
    let fixture: Phase3HerdrFixture
    private let rememberedPaneID: Pane.ID?
    private var currentHost: Host?
    private var currentState: Phase4NavigationState = .hosts([])

    init(
        hostFile: Phase4HostFile,
        transport: Phase4TerminalTransport,
        fixture: Phase3HerdrFixture,
        rememberedPaneID: Pane.ID? = nil
    ) {
        self.hostFile = hostFile
        self.transport = transport
        self.fixture = fixture
        self.rememberedPaneID = rememberedPaneID
    }

    func coldStart() async -> Phase4NavigationState {
        // Hosts can be read, but there is no production launch/navigation
        // state here yet. In particular, this does not restore a pane.
        currentState = .herdr(.empty)
        return currentState
    }

    func loadHosts() async throws -> [Host] {
        try await hostFile.hosts()
    }

    func save(_ host: Host) async throws {
        var hosts = try await hostFile.hosts()
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        try await hostFile.write(hosts: hosts)
    }

    func connect(to host: Host) async throws -> Phase4NavigationState {
        currentHost = host
        await transport.connect(to: host)
        guard let session = fixture.sessions.first else {
            currentState = .herdr(.empty)
            return currentState
        }
        currentState = .herdr(.panes(session: session, message: nil))
        return currentState
    }

    func selectPane(_ paneID: Pane.ID) async -> Phase4NavigationState {
        guard let host = currentHost,
              let pane = allPanes().first(where: { $0.id == paneID })
        else {
            return currentState
        }

        await transport.attach(to: pane)
        // This is the intentionally incomplete behavior under test: the
        // host/IP is used until the terminal title contract is implemented.
        currentState = .terminal(
            Phase4AttachedTerminal(host: host, pane: pane, title: host.hostname)
        )
        return currentState
    }

    func returnToHosts() async -> Phase4NavigationState {
        // Deliberately does not disconnect or clear the Herdr browser yet.
        return currentState
    }

    func restoreLastPane() async -> Phase4NavigationState {
        guard let rememberedPaneID,
              let pane = allPanes().first(where: { $0.id == rememberedPaneID }),
              let host = currentHost
        else {
            return currentState
        }

        await transport.attach(to: pane)
        currentState = .terminal(
            Phase4AttachedTerminal(host: host, pane: pane, title: host.hostname)
        )
        return currentState
    }

    func isConnected() async -> Bool {
        await transport.isConnected()
    }

    private func allPanes() -> [Pane] {
        fixture.sessions.flatMap { session in
            session.workspaces.flatMap { workspace in
                workspace.tabs.flatMap(\.panes)
            }
        }
    }
}

func makeMissingPhase4NavigationApplication(
    hostFile: Phase4HostFile = Phase4HostFile(),
    transport: Phase4TerminalTransport = Phase4TerminalTransport(),
    fixture: Phase3HerdrFixture,
    rememberedPaneID: Pane.ID? = nil
) -> MissingPhase4NavigationApplication {
    MissingPhase4NavigationApplication(
        hostFile: hostFile,
        transport: transport,
        fixture: fixture,
        rememberedPaneID: rememberedPaneID
    )
}

func phase4Host(id: UUID = UUID(), hostname: String = "192.0.2.44") -> Host {
    Host(
        id: id,
        displayName: "Phase 4 Host",
        hostname: hostname,
        port: 2222,
        username: "developer",
        preferredTransport: .ssh
    )
}

enum Phase4Appearance: String, CaseIterable, Codable, Equatable, Sendable {
    case system
    case light
    case dark
}

struct Phase4TerminalPreferences: Codable, Equatable, Sendable {
    var appearance: Phase4Appearance
    var fontSize: Double

    init(
        appearance: Phase4Appearance = .system,
        fontSize: Double = 14
    ) {
        self.appearance = appearance
        self.fontSize = fontSize
    }
}

protocol Phase4PreferencesStore: Sendable {
    func load() async throws -> Phase4TerminalPreferences
    func save(_ preferences: Phase4TerminalPreferences) async throws
}

/// Compile-only settings seam. It returns an incorrect non-default value
/// and saving is a no-op so the tests identify the missing product
/// implementation.
actor MissingPhase4PreferencesStore: Phase4PreferencesStore {
    func load() async throws -> Phase4TerminalPreferences {
        Phase4TerminalPreferences(appearance: .light, fontSize: 12)
    }

    func save(_: Phase4TerminalPreferences) async throws {}
}

func phase4Panes(in fixture: Phase3HerdrFixture) -> [Pane] {
    fixture.sessions.flatMap { session in
        session.workspaces.flatMap { workspace in
            workspace.tabs.flatMap(\.panes)
        }
    }
}
