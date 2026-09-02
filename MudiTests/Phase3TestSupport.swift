import Foundation
import HerdrKit
@testable import Mudi

/// The phase-3 contracts exercise the production browser state and
/// coordinator. These aliases keep the contract names short without defining
/// a second test-only workflow model.
typealias Phase3BrowserState = HerdrBrowserState
typealias Phase3SessionSummary = HerdrSessionSummary

typealias Phase3TestApplication = HerdrWorkflowCoordinator<
    Phase3HerdrDiscovery,
    Phase3TerminalTransport
>

protocol Phase3Application: Sendable {
    func discover(on host: Host) async throws -> Phase3BrowserState
    func selectSession(_ sessionID: HerdrSession.ID) async -> Phase3BrowserState
    func selectPane(_ paneID: Pane.ID) async -> Phase3BrowserState
    func openOrdinaryTerminal() async throws -> Phase3BrowserState
    func restoreLastPane() async -> Phase3BrowserState
}

extension HerdrWorkflowCoordinator: Phase3Application
where Discovery == Phase3HerdrDiscovery, Transport == Phase3TerminalTransport {}

/// A fake discovery boundary fed by decoded command transcripts. It keeps the
/// coordinator tests independent of SSH while preserving real Herdr IDs.
actor Phase3HerdrDiscovery: HerdrDiscovering, HerdrWorkspaceCreating {
    private let fixture: Phase3HerdrFixture
    private let workspaceCreation: HerdrWorkspaceCreation?
    private let snapshotAfterWorkspaceCreation: HerdrSnapshot?
    private let workspaceCreationShouldFail: Bool
    private let workspaceCreationGate: Phase2ConnectionGate?
    private let workspaceCreationRecorder: Phase6WorkspaceCreationRecorder?
    private var requestedHosts: [Host] = []
    private var didCreateWorkspace = false

    init(
        fixture: Phase3HerdrFixture,
        workspaceCreation: HerdrWorkspaceCreation? = nil,
        snapshotAfterWorkspaceCreation: HerdrSnapshot? = nil,
        workspaceCreationShouldFail: Bool = false,
        workspaceCreationGate: Phase2ConnectionGate? = nil,
        workspaceCreationRecorder: Phase6WorkspaceCreationRecorder? = nil
    ) {
        self.fixture = fixture
        self.workspaceCreation = workspaceCreation
        self.snapshotAfterWorkspaceCreation = snapshotAfterWorkspaceCreation
        self.workspaceCreationShouldFail = workspaceCreationShouldFail
        self.workspaceCreationGate = workspaceCreationGate
        self.workspaceCreationRecorder = workspaceCreationRecorder
    }

    func snapshot(for host: Host) async throws -> HerdrSnapshot {
        requestedHosts.append(host)
        if didCreateWorkspace, let snapshotAfterWorkspaceCreation {
            return snapshotAfterWorkspaceCreation
        }
        return HerdrSnapshot(sessions: fixture.sessions)
    }

    func createWorkspace() async throws -> HerdrWorkspaceCreation {
        await workspaceCreationRecorder?.record()
        if let workspaceCreationGate {
            await workspaceCreationGate.markStarted()
            await workspaceCreationGate.waitUntilReleased()
        }
        if workspaceCreationShouldFail {
            throw Phase6WorkspaceCreationError.failed
        }
        guard let workspaceCreation else {
            throw Phase6WorkspaceCreationError.unavailable
        }
        didCreateWorkspace = true
        return workspaceCreation
    }

    func requests() -> [Host] {
        requestedHosts
    }
}

enum Phase3TransportError: Error, Equatable, LocalizedError, Sendable {
    case paneUnavailable

    var errorDescription: String? {
        switch self {
        case .paneUnavailable:
            "The selected Herdr pane is no longer available."
        }
    }
}

actor Phase3TerminalTransport: TerminalTransport {
    nonisolated let kind: ActiveTransport = .ssh
    private let missingPaneIDs: Set<Pane.ID>
    private var connectedHosts: [Host] = []
    private var attachedPanes: [Pane] = []
    private var attachedPaneIDs: [Pane.ID] = []

    init(missingPaneIDs: Set<Pane.ID> = []) {
        self.missingPaneIDs = missingPaneIDs
    }

    func connect(to host: Host) async throws {
        connectedHosts.append(host)
    }

    func attach(to pane: Pane) async throws {
        attachedPanes.append(pane)
        attachedPaneIDs.append(pane.id)
        if missingPaneIDs.contains(pane.id) {
            throw Phase3TransportError.paneUnavailable
        }
    }

    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func disconnect() async {}

    func connections() -> [Host] {
        connectedHosts
    }

    func attachments() -> [Pane] {
        attachedPanes
    }

    func attachmentTargets() -> [Pane.ID] {
        attachedPaneIDs
    }
}

func makePhase3Application(
    fixture: Phase3HerdrFixture,
    transport: Phase3TerminalTransport = Phase3TerminalTransport(),
    lastPaneID: Pane.ID? = nil
) -> Phase3TestApplication {
    HerdrWorkflowCoordinator(
        discovery: Phase3HerdrDiscovery(fixture: fixture),
        transport: transport,
        lastPaneID: lastPaneID
    )
}

func phase3Host(id: UUID = UUID()) -> Host {
    Host(
        id: id,
        displayName: "Phase 3 Host",
        hostname: "phase3.example.test",
        port: 2222,
        username: "developer",
        preferredTransport: .ssh
    )
}

func phase3Panes(in session: HerdrSession) -> [Pane] {
    session.workspaces.flatMap { workspace in
        workspace.tabs.flatMap(\.panes)
    }
}
