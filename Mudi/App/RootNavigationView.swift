import HerdrKit
import SwiftUI

struct RootView: View {
    @StateObject private var model: RootViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSettingsPresented = false

    init(coordinator: ApplicationCoordinator = ApplicationCoordinator()) {
        _model = StateObject(wrappedValue: RootViewModel(coordinator: coordinator))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let activeConnection = model.activeConnection,
                   let herdrState = model.herdrState {
                    switch herdrState {
                    case .ordinaryTerminal:
                        TerminalScreen(
                            host: activeConnection.host,
                            session: activeConnection.session,
                            transport: activeConnection.transport,
                            onDisconnect: model.disconnect,
                            onOpenPanePicker: model.openPanePickerFromTerminal,
                            fontSize: model.preferences.fontSize
                        )
                    case let .attached(_, pane):
                        TerminalScreen(
                            host: activeConnection.host,
                            session: activeConnection.session,
                            title: activeConnection.terminalTitle ?? pane.terminalTitle,
                            transport: activeConnection.transport,
                            onDisconnect: model.disconnect,
                            onOpenPanePicker: model.openPanePickerFromTerminal,
                            fontSize: model.preferences.fontSize,
                            suppressConnectionErrors: model.isPaneControlSuspended
                        )
                    case .empty, .sessions, .panes:
                        // The successful Host path is the picker presentation,
                        // not the legacy full-screen browser. Keeping a quiet
                        // connection surface underneath also lets an empty or
                        // failed picker remain the single place for discovery
                        // feedback.
                        ProgressView("Choose a terminal…")
                    }
                } else if model.isTearingDown {
                    ProgressView("Disconnecting…")
                } else if model.activeConnection != nil {
                    ProgressView("Discovering Herdr…")
                } else {
                    HostListView(
                        hosts: model.hosts,
                        connectionState: model.connectionState,
                        errorMessage: model.errorMessage,
                        onConnect: model.connect,
                        onReconnect: model.reconnect,
                        onAdd: model.addHost,
                        onEdit: model.edit,
                        onDelete: model.delete,
                        onSettings: { isSettingsPresented = true }
                    )
                }
            }
        }
        .preferredColorScheme(model.preferences.appearance.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.suspendPaneControl()
            case .active:
                model.resumePaneControl()
            default:
                break
            }
        }
        .task {
            await model.loadHosts()
            await model.loadPreferences()
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsView(model: model)
            }
        }
        .sheet(item: $model.editor) { context in
            NavigationStack {
                SSHConnectionForm(
                    host: context.host,
                    credentials: context.credentials,
                    onSave: model.save,
                    onCancel: model.cancelEditing
                )
            }
        }
        .popover(isPresented: panePickerBinding, arrowEdge: .top) {
            if let state = model.panePicker {
                PanePickerView(
                    state: state,
                    onDismiss: model.dismissPanePicker,
                    onRefresh: { await model.refreshPanePicker() },
                    onSelectPane: model.selectPaneFromPicker,
                    onSelectOrdinaryTerminal: model.selectOrdinaryTerminalFromPicker
                )
                .frame(minWidth: 320, minHeight: 420)
                .presentationCompactAdaptation(.sheet)
            } else {
                ProgressView("Loading panes…")
                    .frame(minWidth: 320, minHeight: 220)
                    .presentationCompactAdaptation(.sheet)
            }
        }
        .alert(item: $model.hostKeyPrompt) { prompt in
            Alert(
                title: Text("Verify SSH host key"),
                message: Text(
                    "The server presented this fingerprint:\n\n\(prompt.fingerprint)\n\nAccept only if it matches a fingerprint you trust."
                ),
                primaryButton: .destructive(Text("Reject")) {
                    model.answerHostKeyPrompt(.reject, for: prompt.id)
                },
                secondaryButton: .default(Text("Accept")) {
                    model.answerHostKeyPrompt(.accept, for: prompt.id)
                }
            )
        }
    }

    private var panePickerBinding: Binding<Bool> {
        Binding(
            get: { model.isPanePickerPresented },
            set: { isPresented in
                if !isPresented {
                    model.dismissPanePicker()
                }
            }
        )
    }
}

private extension AppearancePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}
