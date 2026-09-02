import HerdrKit
import SwiftUI

extension AgentState {
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

struct HerdrPaneRow: View {
    let pane: Pane
    let isAttached: Bool
    let workspaceContext: String?

    init(
        pane: Pane,
        isAttached: Bool = false,
        workspaceContext: String? = nil
    ) {
        self.pane = pane
        self.isAttached = isAttached
        self.workspaceContext = workspaceContext
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.agent?.name ?? pane.title)
                Text(pane.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let workspaceContext {
                    Text(workspaceContext)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if isAttached {
                HStack(spacing: 4) {
                    if let agent = pane.agent {
                        Text(agent.state.label)
                            .font(.caption)
                            .foregroundStyle(agent.state.color)
                    }
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Current pane")
                }
            } else if let agent = pane.agent {
                Text(agent.state.label)
                    .font(.caption)
                    .foregroundStyle(agent.state.color)
            }
        }
        .contentShape(Rectangle())
    }
}
