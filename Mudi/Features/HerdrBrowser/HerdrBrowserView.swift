import HerdrKit
import SwiftUI

struct HerdrBrowserView: View {
    let snapshot: HerdrSnapshot
    @Binding var selection: Pane.ID?
    @State private var selectedSessionID: HerdrSession.ID?

    @ViewBuilder
    var body: some View {
        if let session = displayedSession {
            PaneList(session: session, selection: $selection)
                .toolbar {
                    if snapshot.sessions.count > 1 {
                        Button("Sessions", systemImage: "chevron.backward") {
                            selectedSessionID = nil
                        }
                    }
                }
        } else {
            List(snapshot.sessions) { session in
                Button {
                    selectedSessionID = session.id
                } label: {
                    HStack {
                        Text(session.name)
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Herdr Sessions")
        }
    }

    private var displayedSession: HerdrSession? {
        if snapshot.sessions.count == 1 {
            return snapshot.sessions.first
        }
        return snapshot.sessions.first { $0.id == selectedSessionID }
    }
}

private struct PaneList: View {
    let session: HerdrSession
    @Binding var selection: Pane.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(session.workspaces) { workspace in
                Section(workspace.name) {
                    ForEach(workspace.tabs) { tab in
                        ForEach(tab.panes) { pane in
                            PaneRow(pane: pane)
                                .tag(pane.id)
                        }
                    }
                }
            }
        }
        .navigationTitle(session.isDefault ? "Herdr" : session.name)
    }
}

private struct PaneRow: View {
    let pane: Pane

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.agent?.name ?? pane.title)
                Text(pane.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let state = pane.agent?.state {
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(state.color)
            }
        }
    }
}

private extension AgentState {
    var label: String {
        switch self {
        case .working: "Working"
        case .waitingForInput: "Needs input"
        case .idle: "Idle"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .working: .blue
        case .waitingForInput: .orange
        case .idle, .unknown: .gray
        case .done: .green
        }
    }
}
