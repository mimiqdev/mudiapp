import HerdrKit
import SwiftUI

struct RootView: View {
    @StateObject private var model: RootViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSettingsPresented = false
    @State private var containerSize: CGSize = .zero

    init(coordinator: ApplicationCoordinator = ApplicationCoordinator()) {
        _model = StateObject(wrappedValue: RootViewModel(coordinator: coordinator))
    }

    var body: some View {
        NavigationStack {
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
                        onSessionClosed: { sessionIdentity in
                            Task {
                                await model.handleTerminalSessionClosed(
                                    for: sessionIdentity
                                )
                            }
                        },
                        fontSize: model.preferences.fontSize,
                        isInputFocusAllowed: !model.isPanePickerPresented,
                        shouldRestoreInputFocus: model
                            .terminalKeyboardFocusActive,
                        onInputFocusChange: model.terminalInputFocusDidChange
                    )
                    // Identity follows the terminal context, not the session
                    // object: a background retakeover swaps the control
                    // channel in place via updateSession, keeping the view
                    // first responder so UIKit restores the keyboard without
                    // a resize animation.
                    .id("ordinary-\(activeConnection.host.id)")
                case let .attached(_, pane):
                    TerminalScreen(
                        host: activeConnection.host,
                        session: activeConnection.session,
                        title: activeConnection.terminalTitle ?? pane.terminalTitle,
                        transport: activeConnection.transport,
                        onDisconnect: model.disconnect,
                        onOpenPanePicker: model.openPanePickerFromTerminal,
                        onSessionClosed: { sessionIdentity in
                            Task {
                                await model.handleTerminalSessionClosed(
                                    for: sessionIdentity
                                )
                            }
                        },
                        fontSize: model.preferences.fontSize,
                        isInputFocusAllowed: !model.isPanePickerPresented,
                        shouldRestoreInputFocus: model
                            .terminalKeyboardFocusActive,
                        onInputFocusChange: model.terminalInputFocusDidChange,
                        suppressConnectionErrors: model.isPaneControlSuspended
                    )
                    .id("attached-\(pane.id)")
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
        .preferredColorScheme(model.preferences.appearance.colorScheme)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            containerSize = newSize
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                model.sceneWillResignActive()
                Task { await model.sceneDidEnterBackground() }
            case .active:
                Task { await model.sceneDidBecomeActive() }
            default:
                break
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.willResignActiveNotification
            )
        ) { _ in
            // UIKit delivers this before any scene-transition dismissal
            // callback, closing the ordering gap where the presentation
            // Binding could otherwise fire while scenePhase still reads
            // .active and be mistaken for an explicit Close.
            model.sceneWillResignActive()
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
                panePickerPresentation(
                    panePickerContentFrame(
                        PanePickerView(
                            state: state,
                            onDismiss: model.dismissPanePicker,
                            onRefresh: { await model.refreshPanePicker() },
                            onCreateWorkspace: model.createWorkspaceFromPicker,
                            isCreatingWorkspace: model.isCreatingWorkspace,
                            onSelectPane: model.selectPaneFromPicker,
                            onSelectOrdinaryTerminal: model.selectOrdinaryTerminalFromPicker,
                            onAppear: {
                                Task { await model.panePickerDidBecomeVisible() }
                            }
                        )
                    )
                )
            } else {
                panePickerPresentation(
                    panePickerContentFrame(
                        ProgressView("Loading panes…")
                    )
                )
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
            // The system dismisses the sheet on a medium outside tap, a
            // swipe-down, or a popover outside tap. That user dismissal goes
            // through the same explicit semantics as the Close button.
            set: { isPresented in
                model.panePickerPresentationBindingDidChange(
                    isPresented,
                    sceneIsActive: scenePhase == .active
                )
            }
        )
    }

    @ViewBuilder
    private func panePickerContentFrame<Content: View>(
        _ content: Content
    ) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad,
           containerSize != .zero
        {
            let size = PanePickerPresentationPolicy.popoverContentSize(
                for: containerSize
            )
            content.frame(width: size.width, height: size.height)
        } else {
            content.frame(minWidth: 320, minHeight: 420)
        }
    }

    @ViewBuilder
    private func panePickerPresentation<Content: View>(
        _ content: Content
    ) -> some View {
        content
            .presentationCompactAdaptation(.sheet)
            .presentationDetents(
                PanePickerPresentationPolicy.compactSheet.detents
            )
            .presentationDragIndicator(
                PanePickerPresentationPolicy.compactSheet.dragIndicator
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
