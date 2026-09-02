import HerdrKit
import SwiftUI

struct PanePickerPresentationPolicy: Equatable {
    enum CompactDetent: String, CaseIterable, Equatable {
        case medium
        case large

        var presentationDetent: PresentationDetent {
            switch self {
            case .medium:
                .medium
            case .large:
                .large
            }
        }
    }

    let compactDetents: [CompactDetent]
    let showsDragIndicator: Bool
    /// The system sheet/popover handles outside taps and swipe-down as a
    /// user dismissal natively. Disabling that and re-adding it with custom
    /// gesture bridges breaks detent dragging, so dismissal stays native and
    /// flows through the presentation Binding into `dismissPanePicker()`.
    let usesSystemInteractiveDismissal: Bool

    static let compactSheet = PanePickerPresentationPolicy(
        compactDetents: [.medium, .large],
        showsDragIndicator: true,
        usesSystemInteractiveDismissal: true
    )

    /// iPad popover sizing: a narrow but full-height side panel anchored at
    /// the top-leading corner, rather than a small card floating in the
    /// corner of a landscape screen.
    struct PopoverContentSize: Equatable {
        let width: CGFloat
        let height: CGFloat
    }

    static func popoverContentSize(for container: CGSize) -> PopoverContentSize {
        PopoverContentSize(
            width: min(420, max(320, container.width * 0.36)),
            height: max(420, container.height - 24)
        )
    }

    var detents: Set<PresentationDetent> {
        Set(compactDetents.map(\.presentationDetent))
    }

    var dragIndicator: Visibility {
        showsDragIndicator ? .visible : .automatic
    }
}

/// The one picker surface used after Host connection and from a terminal
/// toolbar. It renders a repository/worktree tree and pane rows derived from
/// the complete official discovery snapshot, while delegating all lifecycle
/// decisions to RootViewModel.
struct PanePickerView: View {
    let state: PanePickerState
    let onDismiss: () -> Void
    let onRefresh: () async -> Void
    let onCreateWorkspace: () -> Void
    let isCreatingWorkspace: Bool
    let onSelectPane: (Pane.ID) -> Void
    let onSelectOrdinaryTerminal: () -> Void
    let onAppear: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if !state.isLoading {
                    Section {
                        Button(action: onSelectOrdinaryTerminal) {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Ordinary SSH Terminal")
                                    Text("Open the host shell without attaching a pane")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "terminal")
                            }
                        }
                        .accessibilityIdentifier("pane-picker-ordinary-terminal")
                    } header: {
                        Text("Terminal")
                    }
                }

                if let message = state.message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if state.isLoading {
                    ProgressView("Discovering Herdr…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if presentationSections.isEmpty
                    || presentationSections.allSatisfy({ $0.roots.isEmpty }) {
                    ContentUnavailableView {
                        Label("No Herdr Sessions", systemImage: "rectangle.stack")
                    } description: {
                        Text("No active Herdr session was found on this host.")
                    }
                } else {
                    ForEach(presentationSections) { session in
                        Section {
                            ForEach(session.roots) { root in
                                PanePickerWorkspaceNodeView(
                                    node: root,
                                    attachedPaneID: state.attachedTerminal?.pane.id,
                                    onSelectPane: onSelectPane
                                )
                            }
                        } header: {
                            HStack {
                                Text(session.title)
                                if presentationSections.count > 1, session.isDefault {
                                    Text("Default")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose Pane")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await onRefresh()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: onDismiss)
                        .accessibilityIdentifier("pane-picker-close")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Create Workspace", systemImage: "plus", action: onCreateWorkspace)
                        .disabled(isCreatingWorkspace)
                        .accessibilityIdentifier("pane-picker-create-workspace")
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await onRefresh() }
                    }
                    .accessibilityIdentifier("pane-picker-refresh")
                }
            }
        }
        .onAppear(perform: onAppear)
        .accessibilityIdentifier("pane-picker")
    }

    private var presentationSections: [PanePickerSessionPresentation] {
        panePickerPresentationSections(in: state.snapshot)
    }
}

private struct PanePickerWorkspaceNodeView: View {
    let node: PanePickerWorkspacePresentation
    let attachedPaneID: Pane.ID?
    let onSelectPane: (Pane.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(node.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(node.rows) { row in
                Button {
                    onSelectPane(row.paneID)
                } label: {
                    HerdrPaneRow(
                        pane: row.pane,
                        isAttached: attachedPaneID == row.paneID,
                        workspaceContext: row.workspaceContext
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pane-picker-pane-\(row.paneID)")
            }

            ForEach(node.children) { child in
                PanePickerWorkspaceNodeView(
                    node: child,
                    attachedPaneID: attachedPaneID,
                    onSelectPane: onSelectPane
                )
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 4)
    }
}
