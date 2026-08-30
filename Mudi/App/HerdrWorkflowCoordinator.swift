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

/// The narrow application boundary used by the root UI and by workflow tests.
protocol HerdrWorkflowCoordinating: Sendable {
    func discover(on host: Host) async throws -> HerdrBrowserState
    func selectSession(_ sessionID: HerdrSession.ID) async -> HerdrBrowserState
    func selectPane(_ paneID: Pane.ID) async -> HerdrBrowserState
    func openOrdinaryTerminal() async throws -> HerdrBrowserState
    func restoreLastPane() async -> HerdrBrowserState
    func hasRememberedPane() async -> Bool
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

    func openOrdinaryTerminal() async throws -> HerdrBrowserState {
        guard let connectedHost else {
            throw HerdrWorkflowError.noConnectedHost
        }

        try await transport.connect(to: connectedHost)
        browserState = .ordinaryTerminal
        return browserState
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

    private func attach(_ pane: Pane, in session: HerdrSession) async -> HerdrBrowserState {
        do {
            try await transport.attach(to: pane)
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
