import Foundation
import HerdrKit
@testable import Mudi

/// A deterministic credential boundary for a production ApplicationCoordinator
/// while keeping test secrets out of the real Keychain.
actor Phase4CredentialVault {
    private var values: [Host.ID: SSHCredentials] = [:]

    func save(_ credentials: SSHCredentials, for host: Host) {
        values[host.id] = credentials
    }

    func credentials(for host: Host) -> SSHCredentials? {
        values[host.id]
    }

    func delete(for host: Host) {
        values[host.id] = nil
    }
}

struct Phase4CredentialStore: CredentialStore {
    let vault: Phase4CredentialVault

    func save(_ credentials: SSHCredentials, for host: Host) async throws {
        await vault.save(credentials, for: host)
    }

    func credentials(for host: Host) async throws -> SSHCredentials? {
        await vault.credentials(for: host)
    }

    func delete(for host: Host) async throws {
        await vault.delete(for: host)
    }
}

actor Phase4KnownHostKeys {
    private var values: [Host.ID: String] = [:]

    func remember(_ fingerprint: String, for host: Host) {
        values[host.id] = fingerprint
    }

    func fingerprint(for host: Host) -> String? {
        values[host.id]
    }

    func delete(for host: Host) {
        values[host.id] = nil
    }
}

struct Phase4KnownHostKeyStore: KnownHostKeyStore {
    let knownHostKeys: Phase4KnownHostKeys

    func remember(_ fingerprint: String, for host: Host) async throws {
        await knownHostKeys.remember(fingerprint, for: host)
    }

    func fingerprint(for host: Host) async throws -> String? {
        await knownHostKeys.fingerprint(for: host)
    }

    func delete(for host: Host) async throws {
        await knownHostKeys.delete(for: host)
    }
}

/// A terminal transport used by a production HerdrWorkflowCoordinator. The
/// base SSH session is supplied by the RootViewModel's application coordinator
/// and is returned for the attached terminal just like the real transport's
/// dedicated control session.
actor Phase4TerminalTransport: TerminalTransport, HerdrTerminalSessionProviding {
    nonisolated let kind: ActiveTransport = .ssh

    private var missingPaneIDs: Set<Pane.ID>
    private var baseSession: SSHShellSession?
    private var terminalSessionValue: SSHShellSession?
    private var connectedHosts: [Host] = []
    private var attachedPanes: [Pane] = []

    init(missingPaneIDs: Set<Pane.ID> = []) {
        self.missingPaneIDs = missingPaneIDs
    }

    func setMissingPaneIDs(_ paneIDs: Set<Pane.ID>) {
        missingPaneIDs = paneIDs
    }

    func setTerminalSession(_ session: SSHShellSession) {
        baseSession = session
        terminalSessionValue = session
    }

    func connect(to host: Host) async throws {
        connectedHosts.append(host)
    }

    func attach(to pane: Pane) async throws {
        attachedPanes.append(pane)
        guard !missingPaneIDs.contains(pane.id) else {
            throw Phase3TransportError.paneUnavailable
        }
        terminalSessionValue = baseSession
    }

    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func disconnect() async {
        terminalSessionValue = nil
        baseSession = nil
    }

    func terminalSession() async -> SSHShellSession? {
        terminalSessionValue
    }

    func releaseTerminalSession() async {
        terminalSessionValue = nil
    }

    func attachments() -> [Pane] {
        attachedPanes
    }

    func connections() -> [Host] {
        connectedHosts
    }
}

actor Phase4OutputChannel: PTYOutputChannel {
    private let output: AsyncThrowingStream<[UInt8], Error>
    private var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation

    init() {
        var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        output = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> {
        output
    }

    func finish() {
        continuation.finish()
    }

    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {
        continuation.finish()
    }
}

struct Phase4MoshTransport: MoshTransportBootstrapping {
    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession
    ) async throws -> SSHShellSession {
        SSHShellSession(connectedChannel: Phase4MoshPTY())
    }

    func disconnect() async {}
}

private struct Phase4MoshPTY: PTYChannel {
    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {}
}

struct Phase4WorkflowFactory: HerdrWorkflowFactory {
    let fixture: Phase3HerdrFixture
    let transport: Phase4TerminalTransport
    let workspaceCreation: HerdrWorkspaceCreation?
    let workspaceSnapshotAfterCreation: HerdrSnapshot?
    let workspaceCreationShouldFail: Bool
    let workspaceCreationGate: Phase2ConnectionGate?
    let workspaceCreationRecorder: Phase6WorkspaceCreationRecorder?

    init(
        fixture: Phase3HerdrFixture,
        transport: Phase4TerminalTransport,
        workspaceCreation: HerdrWorkspaceCreation? = nil,
        workspaceSnapshotAfterCreation: HerdrSnapshot? = nil,
        workspaceCreationShouldFail: Bool = false,
        workspaceCreationGate: Phase2ConnectionGate? = nil,
        workspaceCreationRecorder: Phase6WorkspaceCreationRecorder? = nil
    ) {
        self.fixture = fixture
        self.transport = transport
        self.workspaceCreation = workspaceCreation
        self.workspaceSnapshotAfterCreation = workspaceSnapshotAfterCreation
        self.workspaceCreationShouldFail = workspaceCreationShouldFail
        self.workspaceCreationGate = workspaceCreationGate
        self.workspaceCreationRecorder = workspaceCreationRecorder
    }

    func makeWorkflow(
        for session: SSHShellSession,
        rememberedPaneID: Pane.ID?
    ) async -> any HerdrWorkflowCoordinating {
        await transport.setTerminalSession(session)
        return HerdrWorkflowCoordinator(
            discovery: Phase3HerdrDiscovery(
                fixture: fixture,
                workspaceCreation: workspaceCreation,
                snapshotAfterWorkspaceCreation: workspaceSnapshotAfterCreation,
                workspaceCreationShouldFail: workspaceCreationShouldFail,
                workspaceCreationGate: workspaceCreationGate,
                workspaceCreationRecorder: workspaceCreationRecorder
            ),
            transport: transport,
            lastPaneID: rememberedPaneID
        )
    }
}

/// A test harness around the production RootViewModel, application
/// coordinator, Herdr workflow coordinator, and JSON host store.
@MainActor
final class Phase4NavigationApplication {
    let model: RootViewModel
    let coordinator: ApplicationCoordinator
    let transport: Phase4TerminalTransport
    let panePickerScheduler: Phase6TestScheduler
    let workspaceCreationRecorder: Phase6WorkspaceCreationRecorder

    private let knownHostKeys: Phase4KnownHostKeys
    private let hostKeyFingerprint = "SHA256:phase4-test-key"

    init(
        hostFileURL: URL,
        fixture: Phase3HerdrFixture,
        transport: Phase4TerminalTransport = Phase4TerminalTransport(),
        credentialVault: Phase4CredentialVault = Phase4CredentialVault(),
        knownHostKeys: Phase4KnownHostKeys = Phase4KnownHostKeys(),
        client: Phase2SSHClient = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key"
        ),
        moshTransport: any MoshTransportBootstrapping = SwiftMoshAdapter(),
        preferencesStore: (any PreferencesStore)? = nil,
        panePickerScheduler: Phase6TestScheduler = Phase6TestScheduler(),
        workspaceCreation: HerdrWorkspaceCreation? = nil,
        workspaceSnapshotAfterCreation: HerdrSnapshot? = nil,
        workspaceCreationShouldFail: Bool = false,
        workspaceCreationGate: Phase2ConnectionGate? = nil,
        workspaceCreationRecorder: Phase6WorkspaceCreationRecorder = Phase6WorkspaceCreationRecorder(),
        rememberedPaneID: Pane.ID? = nil,
        rememberedPaneHostID: Host.ID? = nil
    ) {
        self.transport = transport
        self.panePickerScheduler = panePickerScheduler
        self.workspaceCreationRecorder = workspaceCreationRecorder
        self.knownHostKeys = knownHostKeys
        coordinator = ApplicationCoordinator(
            hostStore: JSONHostStore(fileURL: hostFileURL),
            credentialStore: Phase4CredentialStore(vault: credentialVault),
            knownHostKeyStore: Phase4KnownHostKeyStore(knownHostKeys: knownHostKeys),
            client: client,
            moshTransport: moshTransport
        )
        model = RootViewModel(
            coordinator: coordinator,
            workflowFactory: Phase4WorkflowFactory(
                fixture: fixture,
                transport: transport,
                workspaceCreation: workspaceCreation,
                workspaceSnapshotAfterCreation: workspaceSnapshotAfterCreation,
                workspaceCreationShouldFail: workspaceCreationShouldFail,
                workspaceCreationGate: workspaceCreationGate,
                workspaceCreationRecorder: workspaceCreationRecorder
            ),
            preferencesStore: preferencesStore ?? UserDefaultsPreferencesStore(),
            panePickerScheduler: panePickerScheduler,
            rememberedPaneID: rememberedPaneID,
            rememberedPaneHostID: rememberedPaneHostID
        )
    }

    func coldStart() async {
        await model.loadHosts()
        await model.loadPreferences()
    }

    func save(_ host: Host) async throws {
        try await coordinator.save(host)
        try await coordinator.save(phase2Credentials(), for: host)
        await knownHostKeys.remember(hostKeyFingerprint, for: host)
        await model.loadHosts()
    }
}

@MainActor
func makePhase4NavigationApplication(
    hostFileURL: URL = phase4HostFileURL(),
    fixture: Phase3HerdrFixture,
    transport: Phase4TerminalTransport = Phase4TerminalTransport(),
    credentialVault: Phase4CredentialVault = Phase4CredentialVault(),
    knownHostKeys: Phase4KnownHostKeys = Phase4KnownHostKeys(),
    client: Phase2SSHClient = Phase2SSHClient(
        presentedFingerprint: "SHA256:phase4-test-key"
    ),
    moshTransport: any MoshTransportBootstrapping = SwiftMoshAdapter(),
    preferencesStore: (any PreferencesStore)? = nil,
    panePickerScheduler: Phase6TestScheduler = Phase6TestScheduler(),
    workspaceCreation: HerdrWorkspaceCreation? = nil,
    workspaceSnapshotAfterCreation: HerdrSnapshot? = nil,
    workspaceCreationShouldFail: Bool = false,
    workspaceCreationGate: Phase2ConnectionGate? = nil,
    workspaceCreationRecorder: Phase6WorkspaceCreationRecorder = Phase6WorkspaceCreationRecorder(),
    rememberedPaneID: Pane.ID? = nil,
    rememberedPaneHostID: Host.ID? = nil
) -> Phase4NavigationApplication {
    Phase4NavigationApplication(
        hostFileURL: hostFileURL,
        fixture: fixture,
        transport: transport,
        credentialVault: credentialVault,
        knownHostKeys: knownHostKeys,
        client: client,
        moshTransport: moshTransport,
        preferencesStore: preferencesStore,
        panePickerScheduler: panePickerScheduler,
        workspaceCreation: workspaceCreation,
        workspaceSnapshotAfterCreation: workspaceSnapshotAfterCreation,
        workspaceCreationShouldFail: workspaceCreationShouldFail,
        workspaceCreationGate: workspaceCreationGate,
        workspaceCreationRecorder: workspaceCreationRecorder,
        rememberedPaneID: rememberedPaneID,
        rememberedPaneHostID: rememberedPaneHostID
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

func phase4HostFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mudi-phase4-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("hosts.json")
}

func phase4Panes(in fixture: Phase3HerdrFixture) -> [Pane] {
    fixture.sessions.flatMap { session in
        session.workspaces.flatMap { workspace in
            workspace.tabs.flatMap(\.panes)
        }
    }
}
