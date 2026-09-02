import HerdrKit
import SwiftUI

struct RootView: View {
    @StateObject private var model: RootViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSettingsPresented = false
    @State private var containerSize: CGSize = .zero

    init(model: RootViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    init(
        coordinator: ApplicationCoordinator = ApplicationCoordinator(),
        preferencesStore: (any PreferencesStore)? = nil,
        localNetworkPermissionGate: (any LocalNetworkPermissionGate)? = nil
    ) {
        _model = StateObject(
            wrappedValue: RootViewModel(
                coordinator: coordinator,
                preferencesStore: preferencesStore ?? UserDefaultsPreferencesStore(),
                localNetworkPermissionGate: localNetworkPermissionGate
            )
        )
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
                        onBackToHosts: model.returnToHosts,
                        settingsModel: model,
                        themeSelection: model.preferences.themeSelection,
                        fontFamily: model.preferences.fontFamily,
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
                        onBackToHosts: model.returnToHosts,
                        settingsModel: model,
                        themeSelection: model.preferences.themeSelection,
                        fontFamily: model.preferences.fontFamily,
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
            } else if model.isLocalNetworkOnboardingRequired == true {
                LocalNetworkPermissionOnboardingView(
                    onContinue: model.completeLocalNetworkOnboarding
                )
            } else if model.isLocalNetworkOnboardingRequired == nil {
                // The local-network gate has not decided yet; showing an
                // empty surface prevents the Host list from flashing before
                // the onboarding decision lands.
                ProgressView()
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
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
        ) { _ in
            // Balances the willResignActive hook: system alerts (Local
            // Network permission, Keychain prompts) resign active WITHOUT
            // a scenePhase transition, so scenePhase's .active onChange
            // may never fire and isSceneInactive would stay stuck.
            // sceneDidBecomeActive no-ops unless the flag is set.
            Task { await model.sceneDidBecomeActive() }
        }
        .task {
            await model.loadHosts()
            await model.loadPreferences()
            await model.checkLocalNetworkPermission()
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsView(model: model)
            }
            // An already-presented sheet does not re-resolve traits when the
            // presenting hierarchy switches to preferredColorScheme(nil);
            // anchoring the scheme here plus the window override below lets
            // Dark/Light→System refresh the open sheet immediately.
            .preferredColorScheme(model.preferences.appearance.colorScheme)
            .background(
                InterfaceStyleOverride(
                    colorScheme: model.preferences.appearance.colorScheme
                )
            )
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
        .overlay(alignment: .top) {
            if model.isTransparentlyReconnecting {
                Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.blue.opacity(0.85), in: Capsule())
                    .padding(.top, 60)
                    .accessibilityIdentifier("transparent-reconnect-overlay")
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: panePickerBinding) {
            if let state = model.panePicker {
                panePickerPresentation(
                    panePickerContentFrame(
                        PanePickerView(
                            state: state,
                            onDismiss: model.dismissPanePicker,
                            onRefresh: {
                                await model.refreshPanePicker()
                            },
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
            // iPad: centered sheet with a content-capped width; height is
            // driven by the medium/large detents.
            let width = PanePickerPresentationPolicy.popoverContentWidth(
                for: containerSize.width
            )
            content.frame(width: width)
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

extension AppearancePreference {
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
