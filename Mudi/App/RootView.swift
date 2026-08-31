import HerdrKit
import SwiftUI

@MainActor
final class RootViewModel: ObservableObject {
    @Published private(set) var hosts: [Host] = []
    @Published private(set) var activeConnection: ActiveSSHConnection?
    @Published private(set) var herdrState: HerdrBrowserState?
    @Published private(set) var hasLastPane = false
    @Published private(set) var hasMultipleHerdrSessions = false
    @Published private(set) var isTearingDown = false
    @Published private(set) var isPaneControlSuspended = false
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var activeTransport: ActiveTransport?
    @Published private(set) var preferences = TerminalPreferences()
    @Published var errorMessage: String?
    @Published var editor: HostEditorContext?
    @Published var hostKeyPrompt: HostKeyPrompt?

    let coordinator: ApplicationCoordinator
    let preferencesStore: any PreferencesStore
    private let workflowFactory: any HerdrWorkflowFactory
    private var workflow: (any HerdrWorkflowCoordinating)?
    private var pendingHostKeyDecision: CheckedContinuation<HostKeyDecision, Never>?
    private var pendingHostKeyPromptID: UUID?
    private var stateTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var teardownID: UUID?
    private var workflowTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var lastHostID: Host.ID?
    private var lastPaneID: Pane.ID?
    private var lastPaneHostID: Host.ID?
    private var baseSession: SSHShellSession?
    private var baseTerminalSession: SSHShellSession?

    init(
        coordinator: ApplicationCoordinator = ApplicationCoordinator(),
        workflowFactory: any HerdrWorkflowFactory = SSHHerdrWorkflowFactory(),
        preferencesStore: any PreferencesStore = UserDefaultsPreferencesStore(),
        rememberedPaneID: Pane.ID? = nil,
        rememberedPaneHostID: Host.ID? = nil
    ) {
        self.coordinator = coordinator
        self.workflowFactory = workflowFactory
        self.preferencesStore = preferencesStore
        self.lastPaneID = rememberedPaneID
        self.lastPaneHostID = rememberedPaneHostID
        stateTask = Task { [weak self, coordinator] in
            let stream = await coordinator.connectionStateStream()
            for await state in stream {
                guard !Task.isCancelled else { return }
                self?.connectionState = state
            }
        }
    }

    deinit {
        stateTask?.cancel()
        connectionTask?.cancel()
        workflowTask?.cancel()
        pendingHostKeyDecision?.resume(returning: .reject)
    }

}

extension RootViewModel {
    func loadHosts() async {
        do {
            hosts = try await coordinator.loadHosts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPreferences() async {
        do {
            preferences = try await preferencesStore.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateAppearance(_ appearance: AppearancePreference) {
        preferences.appearance = appearance
        persistPreferences()
    }

    func updateFontSize(_ fontSize: Double) {
        preferences.fontSize = fontSize
        persistPreferences()
    }

    func addHost() {
        editor = HostEditorContext(host: nil, credentials: nil)
    }

    func edit(_ host: Host) {
        Task {
            do {
                let credentials = try await coordinator.credentials(for: host)
                editor = HostEditorContext(host: host, credentials: credentials)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelEditing() {
        editor = nil
    }

    func save(host: Host, credentials: SSHCredentials?) {
        editor = nil
        Task {
            do {
                try await coordinator.save(host)
                if let credentials {
                    try await coordinator.save(credentials, for: host)
                }
                hosts = try await coordinator.loadHosts()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ host: Host) {
        let deletesActiveConnection = lastHostID == host.id
            || activeConnection?.host.id == host.id
        if deletesActiveConnection {
            invalidateConnectionAttempt()
            workflow = nil
            herdrState = nil
            hasLastPane = false
            hasMultipleHerdrSessions = false
            baseSession = nil
            baseTerminalSession = nil
            lastPaneID = nil
            lastPaneHostID = nil
            activeConnection = nil
            activeTransport = nil
            lastHostID = nil
        }

        Task {
            do {
                try await coordinator.delete(host)
                hosts = try await coordinator.loadHosts()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

}

extension RootViewModel {
    func connect(to host: Host) {
        guard connectionTask == nil,
              teardownTask != nil
                || (connectionState != .connecting && connectionState != .connected)
        else { return }

        let generation = beginConnection(for: host.id)
        errorMessage = nil
        connectionState = .connecting
        let coordinator = self.coordinator
        let pendingTeardown = teardownTask
        connectionTask = Task { [weak self, coordinator, pendingTeardown] in
            do {
                await pendingTeardown?.value
                guard self?.isCurrentConnection(generation) == true,
                      !Task.isCancelled
                else { return }
                guard let credentials = try await coordinator.credentials(for: host) else {
                    throw MissingCredentialsError()
                }
                let state = try await coordinator.connect(
                    to: host,
                    credentials: credentials,
                    hostKeyDecision: { [weak self] fingerprint in
                        guard let self else { return .reject }
                        return await self.requestHostKeyDecision(
                            for: fingerprint,
                            generation: generation
                        )
                    }
                )
                guard let self,
                      self.isCurrentConnection(generation),
                      !Task.isCancelled
                else {
                    await coordinator.disconnect()
                    return
                }
                guard state == .connected,
                      let bootstrapSession = await coordinator.activeShellSession()
                else {
                    throw ConnectionError.connectionFailed
                }
                let terminalSession = await coordinator.activeTerminalSession() ?? bootstrapSession
                let selectedTransport = await coordinator.activeTransport() ?? .ssh
                let workflow = await self.makeWorkflow(
                    for: bootstrapSession,
                    hostID: host.id
                )
                let browserState: HerdrBrowserState
                do {
                    browserState = try await workflow.discover(on: host)
                } catch {
                    // A missing or incompatible Herdr installation must not
                    // take away the ordinary SSH terminal.
                    browserState = .empty
                }
                guard self.isCurrentConnection(generation), !Task.isCancelled else {
                    await coordinator.disconnect()
                    return
                }
                self.workflow = workflow
                self.herdrState = browserState
                self.hasLastPane = await workflow.hasRememberedPane()
                self.hasMultipleHerdrSessions = await workflow.hasMultipleSessions()
                self.baseSession = bootstrapSession
                self.baseTerminalSession = terminalSession
                self.activeTransport = selectedTransport
                self.activeConnection = ActiveSSHConnection(
                    host: host,
                    session: terminalSession,
                    transport: selectedTransport
                )
                self.connectionState = state
                self.connectionTask = nil
            } catch {
                guard let self, self.isCurrentConnection(generation) else { return }
                self.answerHostKeyPrompt(.reject)
                self.workflow = nil
                self.herdrState = nil
                self.activeConnection = nil
                self.activeTransport = nil
                self.baseSession = nil
                self.baseTerminalSession = nil
                self.connectionTask = nil
                self.connectionState = await coordinator.connectionState()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func reconnect() {
        guard connectionTask == nil,
              teardownTask != nil
                || (connectionState != .connecting && connectionState != .connected),
              let hostID = lastHostID
        else { return }

        let generation = beginConnection(for: hostID)
        errorMessage = nil
        connectionState = .connecting
        let coordinator = self.coordinator
        let pendingTeardown = teardownTask
        connectionTask = Task { [weak self, coordinator, pendingTeardown] in
            do {
                await pendingTeardown?.value
                guard self?.isCurrentConnection(generation) == true,
                      !Task.isCancelled
                else { return }
                let refreshedHosts = try await coordinator.loadHosts()
                guard let self,
                      self.isCurrentConnection(generation),
                      let host = refreshedHosts.first(where: { $0.id == hostID })
                else {
                    throw ConnectionError.connectionFailed
                }
                self.hosts = refreshedHosts

                let state = try await coordinator.reconnect(
                    hostKeyDecision: { [weak self] fingerprint in
                        guard let self else { return .reject }
                        return await self.requestHostKeyDecision(
                            for: fingerprint,
                            generation: generation
                        )
                    }
                )
                guard self.isCurrentConnection(generation),
                      !Task.isCancelled,
                      state == .connected,
                      let bootstrapSession = await coordinator.activeShellSession()
                else {
                    await coordinator.disconnect()
                    return
                }
                let terminalSession = await coordinator.activeTerminalSession() ?? bootstrapSession
                let selectedTransport = await coordinator.activeTransport() ?? .ssh
                let workflow = await self.makeWorkflow(
                    for: bootstrapSession,
                    hostID: host.id
                )
                let browserState: HerdrBrowserState
                do {
                    browserState = try await workflow.discover(on: host)
                } catch {
                    browserState = .empty
                }
                guard self.isCurrentConnection(generation), !Task.isCancelled else {
                    await coordinator.disconnect()
                    return
                }
                self.workflow = workflow
                self.herdrState = browserState
                self.hasLastPane = await workflow.hasRememberedPane()
                self.hasMultipleHerdrSessions = await workflow.hasMultipleSessions()
                self.baseSession = bootstrapSession
                self.baseTerminalSession = terminalSession
                self.activeTransport = selectedTransport
                self.activeConnection = ActiveSSHConnection(
                    host: host,
                    session: terminalSession,
                    transport: selectedTransport
                )
                self.connectionState = state
                self.connectionTask = nil
            } catch {
                guard let self, self.isCurrentConnection(generation) else { return }
                self.answerHostKeyPrompt(.reject)
                self.workflow = nil
                self.herdrState = nil
                self.activeConnection = nil
                self.activeTransport = nil
                self.baseSession = nil
                self.baseTerminalSession = nil
                self.connectionTask = nil
                self.connectionState = await coordinator.connectionState()
                self.errorMessage = error.localizedDescription
            }
        }
    }

}

extension RootViewModel {
    func selectSession(_ sessionID: HerdrSession.ID) {
        guard let workflow else { return }
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow] in
            let state = await workflow.selectSession(sessionID)
            guard !Task.isCancelled else { return }
            await self?.applyWorkflowState(state, from: workflow)
        }
    }

    func showHerdrSessions() {
        guard let workflow else { return }
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow] in
            let state = await workflow.showSessions()
            guard !Task.isCancelled else { return }
            await self?.applyWorkflowState(state, from: workflow)
        }
    }

    func selectPane(_ paneID: Pane.ID) {
        guard let workflow else { return }
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow] in
            let state = await workflow.selectPane(paneID)
            guard !Task.isCancelled else { return }
            await self?.applyWorkflowState(state, from: workflow)
        }
    }

    func openOrdinaryTerminal() {
        guard let workflow else { return }
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow] in
            do {
                let state = try await workflow.openOrdinaryTerminal()
                guard !Task.isCancelled else { return }
                await self?.applyWorkflowState(state, from: workflow)
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentWorkflow(workflow)
                else { return }
                self.errorMessage = nil
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentWorkflow(workflow)
                else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func restoreLastPane() {
        guard let workflow else { return }
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow] in
            let state = await workflow.restoreLastPane()
            guard !Task.isCancelled else { return }
            await self?.applyWorkflowState(state, from: workflow)
        }
    }

    func returnToHerdrBrowser() {
        guard let workflow else { return }
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow] in
            let state = await workflow.returnToBrowser()
            guard !Task.isCancelled else { return }
            await self?.applyWorkflowState(state, from: workflow)
        }
    }

    func suspendPaneControl() {
        guard case .attached = herdrState, let workflow else { return }
        isPaneControlSuspended = true
        Task { [weak self, workflow] in
            await workflow.suspendAttachedControl()
            guard let self, !Task.isCancelled else { return }
            self.isPaneControlSuspended = true
        }
    }

    func resumePaneControl() {
        guard isPaneControlSuspended, case .attached = herdrState, let workflow else {
            isPaneControlSuspended = false
            return
        }
        workflowTask?.cancel()
        workflowTask = Task { [weak self, workflow] in
            let state = await workflow.resumeAttachedControl()
            guard !Task.isCancelled else { return }
            await self?.applyWorkflowState(state, from: workflow)
            self?.isPaneControlSuspended = false
        }
    }

    /// Leaves the Herdr browser and returns to the saved-host list. The
    /// workflow is released before the SSH shell so an attached control
    /// session cannot outlive the host connection.
    func returnToHosts() {
        let workflow = self.workflow
        invalidateConnectionAttempt()
        self.workflow = nil
        herdrState = nil
        hasLastPane = false
        hasMultipleHerdrSessions = false
        baseSession = nil
        activeConnection = nil
        isPaneControlSuspended = false
        scheduleTeardown(workflow: workflow)
    }

    func disconnect() {
        let workflow = self.workflow
        invalidateConnectionAttempt()
        self.workflow = nil
        herdrState = nil
        hasLastPane = false
        hasMultipleHerdrSessions = false
        baseSession = nil
        baseTerminalSession = nil
        activeConnection = nil
        activeTransport = nil
        isPaneControlSuspended = false
        scheduleTeardown(workflow: workflow)
    }

}

extension RootViewModel {
    func requestHostKeyDecision(
        for fingerprint: String,
        generation: UUID
    ) async -> HostKeyDecision {
        guard connectionGeneration == generation,
              connectionState == .connecting
        else {
            return .reject
        }

        return await withCheckedContinuation { continuation in
            guard connectionGeneration == generation,
                  connectionState == .connecting
            else {
                continuation.resume(returning: .reject)
                return
            }
            pendingHostKeyDecision?.resume(returning: .reject)
            pendingHostKeyDecision = continuation
            let prompt = HostKeyPrompt(fingerprint: fingerprint)
            pendingHostKeyPromptID = prompt.id
            hostKeyPrompt = prompt
        }
    }

    func answerHostKeyPrompt(_ decision: HostKeyDecision, for promptID: UUID? = nil) {
        guard promptID == nil || promptID == pendingHostKeyPromptID else { return }
        guard let pendingHostKeyDecision else {
            hostKeyPrompt = nil
            pendingHostKeyPromptID = nil
            return
        }
        self.pendingHostKeyDecision = nil
        pendingHostKeyPromptID = nil
        hostKeyPrompt = nil
        pendingHostKeyDecision.resume(returning: decision)
    }

}

extension RootViewModel {
    private func beginConnection(for hostID: Host.ID) -> UUID {
        invalidateConnectionAttempt()
        if let lastPaneHostID, lastPaneHostID != hostID {
            lastPaneID = nil
            self.lastPaneHostID = nil
        }
        lastHostID = hostID
        workflow = nil
        herdrState = nil
        hasLastPane = false
        hasMultipleHerdrSessions = false
        baseSession = nil
        baseTerminalSession = nil
        activeConnection = nil
        activeTransport = nil
        connectionGeneration = UUID()
        return connectionGeneration
    }

    private func invalidateConnectionAttempt() {
        connectionGeneration = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        workflowTask?.cancel()
        workflowTask = nil
        answerHostKeyPrompt(.reject)
    }

    private func isCurrentConnection(_ generation: UUID) -> Bool {
        connectionGeneration == generation
    }

    private func applyWorkflowState(
        _ state: HerdrBrowserState,
        from workflow: any HerdrWorkflowCoordinating
    ) async {
        guard isCurrentWorkflow(workflow), !Task.isCancelled else { return }

        let rememberedPane = await workflow.hasRememberedPane()
        let multipleSessions = await workflow.hasMultipleSessions()
        let terminalSession: SSHShellSession?
        if case .attached = state {
            terminalSession = await workflow.terminalSession()
        } else {
            terminalSession = nil
        }

        guard isCurrentWorkflow(workflow), !Task.isCancelled else { return }
        hasLastPane = rememberedPane
        hasMultipleHerdrSessions = multipleSessions

        switch state {
        case let .attached(_, pane):
            guard let activeConnection,
                  let terminalSession
            else { return }
            lastPaneID = pane.id
            lastPaneHostID = activeConnection.host.id
            self.activeConnection = ActiveSSHConnection(
                host: activeConnection.host,
                session: terminalSession,
                terminalTitle: pane.terminalTitle,
                transport: activeConnection.transport
            )
            herdrState = state
        case .empty, .sessions, .panes, .ordinaryTerminal:
            if let activeConnection,
               let baseSession {
                self.activeConnection = ActiveSSHConnection(
                    host: activeConnection.host,
                    session: baseTerminalSession ?? baseSession,
                    transport: activeConnection.transport
                )
            }
            herdrState = state
        }
    }

    private func isCurrentWorkflow(
        _ candidate: any HerdrWorkflowCoordinating
    ) -> Bool {
        guard let workflow else { return false }
        return ObjectIdentifier(workflow) == ObjectIdentifier(candidate)
    }

    private func cancelWorkflowTask() {
        workflowTask?.cancel()
        workflowTask = nil
    }

    private func scheduleTeardown(
        workflow: (any HerdrWorkflowCoordinating)?
    ) {
        isTearingDown = true
        let teardownID = UUID()
        self.teardownID = teardownID
        let previousTeardown = teardownTask
        let generation = connectionGeneration
        let coordinator = self.coordinator
        let task = Task { [weak self, previousTeardown, workflow, coordinator, teardownID] in
            await previousTeardown?.value
            if let workflow {
                _ = await workflow.returnToBrowser()
            }
            await coordinator.disconnectAndWait()
            guard let self, self.teardownID == teardownID else { return }
            if self.connectionGeneration == generation {
                self.connectionState = await coordinator.connectionState()
            }
            self.isTearingDown = false
            self.teardownTask = nil
            self.teardownID = nil
        }
        teardownTask = task
    }

    private func makeWorkflow(
        for session: SSHShellSession,
        hostID: Host.ID
    ) async -> any HerdrWorkflowCoordinating {
        let rememberedPaneID = lastPaneHostID == hostID ? lastPaneID : nil
        return await workflowFactory.makeWorkflow(
            for: session,
            rememberedPaneID: rememberedPaneID
        )
    }

    private func persistPreferences() {
        let preferences = self.preferences
        let preferencesStore = self.preferencesStore
        Task { [weak self] in
            do {
                try await preferencesStore.save(preferences)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private struct MissingCredentialsError: LocalizedError {
        var errorDescription: String? {
            "No saved SSH credentials. Edit this host to add a password or private key."
        }
    }
}

struct HostKeyPrompt: Identifiable, Equatable {
    let id = UUID()
    let fingerprint: String
}

struct HostEditorContext: Identifiable {
    let id: UUID
    let host: Host?
    let credentials: SSHCredentials?

    init(host: Host?, credentials: SSHCredentials?) {
        id = host?.id ?? UUID()
        self.host = host
        self.credentials = credentials
    }
}

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
                            fontSize: model.preferences.fontSize
                        )
                    case let .attached(_, pane):
                        TerminalScreen(
                            host: activeConnection.host,
                            session: activeConnection.session,
                            title: activeConnection.terminalTitle ?? pane.terminalTitle,
                            transport: activeConnection.transport,
                            onDisconnect: model.disconnect,
                            onBackToBrowser: model.returnToHerdrBrowser,
                            fontSize: model.preferences.fontSize,
                            suppressConnectionErrors: model.isPaneControlSuspended
                        )
                    case .empty, .sessions, .panes:
                        HerdrBrowserView(
                            state: herdrState,
                            hasLastPane: model.hasLastPane,
                            canSwitchSessions: model.hasMultipleHerdrSessions,
                            onReturnToHosts: model.returnToHosts,
                            onSelectSession: model.selectSession,
                            onSelectPane: model.selectPane,
                            onShowSessions: model.showHerdrSessions,
                            onOpenOrdinaryTerminal: model.openOrdinaryTerminal,
                            onRestoreLastPane: model.restoreLastPane
                        )
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
}

struct ActiveSSHConnection {
    let host: Host
    let session: SSHShellSession
    let terminalTitle: String?
    let transport: ActiveTransport

    init(
        host: Host,
        session: SSHShellSession,
        terminalTitle: String? = nil,
        transport: ActiveTransport = .ssh
    ) {
        self.host = host
        self.session = session
        self.terminalTitle = terminalTitle
        self.transport = transport
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
