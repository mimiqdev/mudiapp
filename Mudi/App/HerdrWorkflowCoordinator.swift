import Foundation
import HerdrKit

/// The browser state exposed while a connected host is being explored.
///
/// A session list contains summaries only. Panes are exposed after a session
/// has been selected (or when the snapshot contains exactly one session), so a
/// caller cannot accidentally render panes from an unselected session.
enum HerdrBrowserState: Equatable, Sendable {
    case empty
    case sessions([HerdrSessionSummary])
    case panes(session: HerdrSession, message: String?)
    case ordinaryTerminal
    case attached(session: HerdrSession, pane: Pane)
}

struct HerdrSessionSummary: Equatable, Sendable {
    let id: HerdrSession.ID
    let name: String
    let isDefault: Bool

    init(session: HerdrSession) {
        id = session.id
        name = session.name
        isDefault = session.isDefault
    }
}

/// Provides the terminal session created by a successful pane attach.
protocol HerdrTerminalSessionProviding: Sendable {
    func terminalSession() async -> SSHShellSession?
    func releaseTerminalSession() async
}

/// Lets a Herdr transport select the named server that owns a pane. Legacy
/// transports can continue to use the pane-only TerminalTransport method.
protocol HerdrSessionAwareTerminalTransport: Sendable {
    func attach(to pane: Pane, in session: HerdrSession) async throws
}

/// The narrow application boundary used by the root UI and by workflow tests.
protocol HerdrWorkflowCoordinating: AnyObject, Sendable {
    func discover(on host: Host) async throws -> HerdrBrowserState
    func selectSession(_ sessionID: HerdrSession.ID) async -> HerdrBrowserState
    func selectPane(_ paneID: Pane.ID) async -> HerdrBrowserState
    func showSessions() async -> HerdrBrowserState
    func returnToBrowser() async -> HerdrBrowserState
    func openOrdinaryTerminal() async throws -> HerdrBrowserState
    func restoreLastPane() async -> HerdrBrowserState
    func suspendAttachedControl() async
    func resumeAttachedControl() async -> HerdrBrowserState
    func hasRememberedPane() async -> Bool
    func hasMultipleSessions() async -> Bool
    func terminalSession() async -> SSHShellSession?
}

/// Builds the workflow for a connected shell. Keeping this factory at the
/// root-model boundary lets the app use the SSH adapters while tests can feed
/// recorded Herdr responses into the same production coordinator.
protocol HerdrWorkflowFactory: Sendable {
    func makeWorkflow(
        for session: SSHShellSession,
        rememberedPaneID: Pane.ID?
    ) async -> any HerdrWorkflowCoordinating
}

struct SSHHerdrWorkflowFactory: HerdrWorkflowFactory, Sendable {
    func makeWorkflow(
        for session: SSHShellSession,
        rememberedPaneID: Pane.ID?
    ) async -> any HerdrWorkflowCoordinating {
        HerdrWorkflowCoordinator(
            discovery: SSHHerdrDiscovery(session: session),
            transport: SSHHerdrTerminalTransport(session: session),
            lastPaneID: rememberedPaneID
        )
    }
}

extension Pane {
    /// The title shown by an attached terminal. Agent names are more useful
    /// when available; a pane title (and finally its ID) keeps shell panes
    /// identifiable without exposing the host address as the terminal title.
    var terminalTitle: String {
        if let agentName = agent?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !agentName.isEmpty {
            return agentName
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? id : trimmedTitle
    }
}

enum HerdrWorkflowError: Error, Equatable, LocalizedError, Sendable {
    case noConnectedHost

    var errorDescription: String? {
        switch self {
        case .noConnectedHost:
            "Connect to an SSH host before opening a terminal."
        }
    }
}

/// Coordinates read-only Herdr browsing and explicit pane attachment.
///
/// Discovery and terminal transport are injected independently. The host
/// connection remains owned by the existing SSH coordinator; attaching a pane
/// does not implicitly connect, select, or observe another pane.
actor HerdrWorkflowCoordinator<Discovery: HerdrDiscovering, Transport: TerminalTransport>:
    HerdrWorkflowCoordinating
{
    let discovery: Discovery
    let transport: Transport

    private var snapshot: HerdrSnapshot?
    private var connectedHost: Host?
    private var selectedSessionID: HerdrSession.ID?
    private var lastPaneID: Pane.ID?
    private var browserState: HerdrBrowserState = .empty

    init(
        discovery: Discovery,
        transport: Transport,
        lastPaneID: Pane.ID? = nil
    ) {
        self.discovery = discovery
        self.transport = transport
        self.lastPaneID = lastPaneID
    }

    func discover(on host: Host) async throws -> HerdrBrowserState {
        connectedHost = host
        snapshot = nil
        selectedSessionID = nil
        browserState = .empty
        let discoveredSnapshot = try await discovery.snapshot(for: host)
        snapshot = discoveredSnapshot
        selectedSessionID = discoveredSnapshot.sessions.count == 1
            ? discoveredSnapshot.sessions.first?.id
            : nil
        browserState = makeBrowserState()
        return browserState
    }

    func selectSession(_ sessionID: HerdrSession.ID) -> HerdrBrowserState {
        guard let snapshot else {
            browserState = .empty
            return browserState
        }

        guard snapshot.sessions.count > 1,
              snapshot.sessions.contains(where: { $0.id == sessionID })
        else {
            browserState = makeBrowserState()
            return browserState
        }

        selectedSessionID = sessionID
        browserState = makeBrowserState()
        return browserState
    }

    func selectPane(_ paneID: Pane.ID) async -> HerdrBrowserState {
        guard let session = selectedSession() else {
            browserState = makeBrowserState()
            return browserState
        }
        guard let pane = panes(in: session).first(where: { $0.id == paneID }) else {
            browserState = .panes(
                session: session,
                message: Self.missingPaneMessage
            )
            return browserState
        }

        return await attach(pane, in: session)
    }

    func showSessions() -> HerdrBrowserState {
        guard let snapshot, snapshot.sessions.count > 1 else {
            browserState = makeBrowserState()
            return browserState
        }
        selectedSessionID = nil
        browserState = makeBrowserState()
        return browserState
    }

    func returnToBrowser() async -> HerdrBrowserState {
        if let provider = transport as? any HerdrTerminalSessionProviding {
            await provider.releaseTerminalSession()
        }
        browserState = makeBrowserState()
        return browserState
    }

    func openOrdinaryTerminal() async throws -> HerdrBrowserState {
        guard let connectedHost else {
            throw HerdrWorkflowError.noConnectedHost
        }

        try await transport.connect(to: connectedHost)
        browserState = .ordinaryTerminal
        return browserState
    }

    func suspendAttachedControl() async {
        guard case .attached = browserState else { return }
        if let provider = transport as? any HerdrTerminalSessionProviding {
            await provider.releaseTerminalSession()
        }
    }

    func resumeAttachedControl() async -> HerdrBrowserState {
        guard case let .attached(session, pane) = browserState else {
            return browserState
        }
        return await attach(pane, in: session)
    }

    func restoreLastPane() async -> HerdrBrowserState {
        guard let lastPaneID,
              let snapshot
        else {
            browserState = makeBrowserState()
            return browserState
        }

        guard let match = snapshot.sessions.lazy
            .map({ session in
                (session: session, pane: self.panes(in: session).first { $0.id == lastPaneID })
            })
            .first(where: { $0.pane != nil }),
            let pane = match.pane
        else {
            browserState = makeBrowserState(message: Self.missingPaneMessage)
            return browserState
        }

        selectedSessionID = match.session.id
        return await attach(pane, in: match.session)
    }

    /// Updates the remembered target after the caller explicitly chooses a
    /// pane. Persistence is deliberately outside this phase's scope.
    func rememberLastPane(_ paneID: Pane.ID?) {
        lastPaneID = paneID
    }

    func currentState() -> HerdrBrowserState {
        browserState
    }

    func hasRememberedPane() async -> Bool {
        lastPaneID != nil
    }

    func hasMultipleSessions() async -> Bool {
        (snapshot?.sessions.count ?? 0) > 1
    }

    func terminalSession() async -> SSHShellSession? {
        guard let provider = transport as? any HerdrTerminalSessionProviding else {
            return nil
        }
        return await provider.terminalSession()
    }

    private func attach(_ pane: Pane, in session: HerdrSession) async -> HerdrBrowserState {
        do {
            if let sessionAwareTransport = transport as? any HerdrSessionAwareTerminalTransport {
                try await sessionAwareTransport.attach(to: pane, in: session)
            } else {
                try await transport.attach(to: pane)
            }
            lastPaneID = pane.id
            browserState = .attached(session: session, pane: pane)
        } catch {
            browserState = .panes(
                session: session,
                message: Self.presentableMessage(for: error)
            )
        }
        return browserState
    }

    private func selectedSession() -> HerdrSession? {
        guard let snapshot else { return nil }
        if snapshot.sessions.count == 1 {
            return snapshot.sessions.first
        }
        guard let selectedSessionID else { return nil }
        return snapshot.sessions.first { $0.id == selectedSessionID }
    }

    private func makeBrowserState(message: String? = nil) -> HerdrBrowserState {
        guard let snapshot else { return .empty }
        switch snapshot.sessions.count {
        case 0:
            return .empty
        case 1:
            guard let session = snapshot.sessions.first else { return .empty }
            return .panes(session: session, message: message)
        default:
            guard let session = selectedSession() else {
                return .sessions(snapshot.sessions.map(HerdrSessionSummary.init(session:)))
            }
            return .panes(session: session, message: message)
        }
    }

    private func panes(in session: HerdrSession) -> [Pane] {
        session.workspaces.flatMap { workspace in
            workspace.tabs.flatMap(\.panes)
        }
    }

    private static func presentableMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        let description = error.localizedDescription
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return missingPaneMessage
        }
        return description
    }

    private static var missingPaneMessage: String {
        "The selected Herdr pane is no longer available."
    }
}
