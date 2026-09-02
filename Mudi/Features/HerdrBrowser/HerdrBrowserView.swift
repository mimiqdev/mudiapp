import HerdrKit
import SwiftUI

struct HerdrBrowserView: View {
    let state: HerdrBrowserState
    let hasLastPane: Bool
    let canSwitchSessions: Bool
    let onReturnToHosts: () -> Void
    let onSelectSession: (HerdrSession.ID) -> Void
    let onSelectPane: (Pane.ID) -> Void
    let onShowSessions: () -> Void
    let onOpenOrdinaryTerminal: () -> Void
    let onRestoreLastPane: () -> Void

    init(
        state: HerdrBrowserState,
        hasLastPane: Bool = false,
        canSwitchSessions: Bool = false,
        onReturnToHosts: @escaping () -> Void = {},
        onSelectSession: @escaping (HerdrSession.ID) -> Void,
        onSelectPane: @escaping (Pane.ID) -> Void,
        onShowSessions: @escaping () -> Void = {},
        onOpenOrdinaryTerminal: @escaping () -> Void,
        onRestoreLastPane: @escaping () -> Void
    ) {
        self.state = state
        self.hasLastPane = hasLastPane
        self.canSwitchSessions = canSwitchSessions
        self.onReturnToHosts = onReturnToHosts
        self.onSelectSession = onSelectSession
        self.onSelectPane = onSelectPane
        self.onShowSessions = onShowSessions
        self.onOpenOrdinaryTerminal = onOpenOrdinaryTerminal
        self.onRestoreLastPane = onRestoreLastPane
    }

    /// Compatibility initializer for previews that only have a snapshot. The
    /// coordinator-backed initializer above is used by the connected app.
    init(snapshot: HerdrSnapshot, selection _: Binding<Pane.ID?>) {
        self.init(
            state: Self.initialState(for: snapshot),
            onReturnToHosts: {},
            onSelectSession: { _ in },
            onSelectPane: { _ in },
            onShowSessions: {},
            onOpenOrdinaryTerminal: {},
            onRestoreLastPane: {}
        )
    }

    var body: some View {
        Group {
            switch state {
        case .empty:
            ContentUnavailableView {
                Label("No Herdr Sessions", systemImage: "rectangle.stack")
            } description: {
                Text("No active Herdr session was found on this host.")
            } actions: {
                Button("Open SSH Terminal", systemImage: "terminal", action: onOpenOrdinaryTerminal)
            }
            .navigationTitle("Herdr")

        case let .sessions(summaries):
            List(summaries, id: \.id) { summary in
                Button {
                    onSelectSession(summary.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(summary.name)
                            if summary.isDefault {
                                Text("Default session")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("herdr-session-\(summary.id)")
            }
            .navigationTitle("Herdr Sessions")

        case let .panes(session, message):
            PaneList(
                session: session,
                message: message,
                onSelectPane: onSelectPane
            )
            .safeAreaInset(edge: .bottom) {
                if hasLastPane {
                    Button("Restore Last Pane", systemImage: "arrow.counterclockwise", action: onRestoreLastPane)
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial)
                }
            }

            case .ordinaryTerminal, .attached:
                EmptyView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(
                    "Hosts",
                    systemImage: "chevron.backward",
                    action: onReturnToHosts
                )
                .accessibilityIdentifier("return-to-hosts")

                if canSwitchSessions {
                    Button(
                        "Sessions",
                        systemImage: "rectangle.stack",
                        action: onShowSessions
                    )
                }
            }
        }
    }

    private static func initialState(for snapshot: HerdrSnapshot) -> HerdrBrowserState {
        switch snapshot.sessions.count {
        case 0:
            return .empty
        case 1:
            return .panes(session: snapshot.sessions[0], message: nil)
        default:
            return .sessions(snapshot.sessions.map(HerdrSessionSummary.init(session:)))
        }
    }
}

private struct PaneList: View {
    let session: HerdrSession
    let message: String?
    let onSelectPane: (Pane.ID) -> Void

    var body: some View {
        List {
            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            ForEach(session.workspaces) { workspace in
                ForEach(workspace.tabs) { tab in
                    Section {
                        ForEach(tab.panes) { pane in
                            Button {
                                onSelectPane(pane.id)
                            } label: {
                                HerdrPaneRow(pane: pane)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("herdr-pane-\(pane.id)")
                        }
                    } header: {
                        Text("\(workspace.name) / \(tab.name)")
                    }
                }
            }
        }
        .navigationTitle(session.isDefault ? "Herdr" : session.name)
    }
}
