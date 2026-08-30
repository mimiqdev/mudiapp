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

actor Phase3HerdrDiscovery: HerdrDiscovering {
    private let snapshotValue: HerdrSnapshot
    private var requestedHosts: [Host] = []

    init(snapshot: HerdrSnapshot) {
        snapshotValue = snapshot
    }

    func snapshot(for host: Host) async throws -> HerdrSnapshot {
        requestedHosts.append(host)
        return snapshotValue
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

    init(missingPaneIDs: Set<Pane.ID> = []) {
        self.missingPaneIDs = missingPaneIDs
    }

    func connect(to host: Host) async throws {
        connectedHosts.append(host)
    }

    func attach(to pane: Pane) async throws {
        attachedPanes.append(pane)
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
}

func makeMissingPhase3Application(
    snapshot: HerdrSnapshot,
    transport: Phase3TerminalTransport = Phase3TerminalTransport(),
    lastPaneID: Pane.ID? = nil
) -> Phase3TestApplication {
    HerdrWorkflowCoordinator(
        discovery: Phase3HerdrDiscovery(snapshot: snapshot),
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

func phase3Session(
    id: String,
    name: String,
    panes: [Pane],
    isDefault: Bool = false
) -> HerdrSession {
    let tab = Tab(
        id: "\(id)-tab",
        name: "main",
        panes: panes
    )
    let workspace = Workspace(
        id: "\(id)-workspace",
        name: "workspace",
        tabs: [tab]
    )
    return HerdrSession(
        id: id,
        name: name,
        isDefault: isDefault,
        workspaces: [workspace]
    )
}

func phase3Pane(
    id: String,
    title: String,
    agentName: String? = nil,
    agentState: AgentState = .unknown
) -> Pane {
    let agent = agentName.map { Agent(name: $0, state: agentState) }
    return Pane(id: id, title: title, agent: agent)
}

func phase3Panes(in session: HerdrSession) -> [Pane] {
    session.workspaces.flatMap { workspace in
        workspace.tabs.flatMap(\.panes)
    }
}
