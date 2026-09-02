import HerdrKit
import SwiftUI

@MainActor
final class RootViewModel: ObservableObject {
    @Published private(set) var hosts: [Host] = []
    @Published private(set) var activeConnection: ActiveSSHConnection?
    @Published private(set) var herdrState: HerdrBrowserState?
    @Published private(set) var panePicker: PanePickerState?
    @Published private(set) var isPanePickerPresented = false
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
    private let panePickerScheduler: any PanePickerRefreshScheduling
    private var workflow: (any HerdrWorkflowCoordinating)?
    private var panePickerCoordinator: (any PanePickerCoordinating)?
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
        panePickerScheduler: any PanePickerRefreshScheduling = LivePanePickerRefreshScheduler(),
        rememberedPaneID: Pane.ID? = nil,
        rememberedPaneHostID: Host.ID? = nil
    ) {
        self.coordinator = coordinator
        self.workflowFactory = workflowFactory
        self.preferencesStore = preferencesStore
        self.panePickerScheduler = panePickerScheduler
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
            invalidatePanePickerPresentation()
            panePickerCoordinator = nil
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
                self.showLoadingPanePicker(for: host)
                let pickerCoordinator = self.makePanePickerCoordinator(
                    for: workflow,
                    transport: selectedTransport
                )
                let pickerState = try await pickerCoordinator.connect(to: host)
                guard self.isCurrentConnection(generation), !Task.isCancelled else {
                    await pickerCoordinator.stopRefresh()
                    await coordinator.disconnect()
                    return
                }
                self.workflow = workflow
                self.panePickerCoordinator = pickerCoordinator
                self.herdrState = await workflow.currentState()
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
                await self.applyPanePickerState(
                    pickerState,
                    workflow: workflow
                )
            } catch {
                guard let self, self.isCurrentConnection(generation) else { return }
                self.invalidatePanePickerPresentation()
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
                self.showLoadingPanePicker(for: host)
                let pickerCoordinator = self.makePanePickerCoordinator(
                    for: workflow,
                    transport: selectedTransport
                )
                let pickerState = try await pickerCoordinator.connect(to: host)
                guard self.isCurrentConnection(generation), !Task.isCancelled else {
                    await pickerCoordinator.stopRefresh()
                    await coordinator.disconnect()
                    return
                }
                self.workflow = workflow
                self.panePickerCoordinator = pickerCoordinator
                self.herdrState = await workflow.currentState()
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
                await self.applyPanePickerState(
                    pickerState,
                    workflow: workflow
                )
            } catch {
                guard let self, self.isCurrentConnection(generation) else { return }
                self.invalidatePanePickerPresentation()
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
        if isPanePickerPresented {
            selectPaneFromPicker(paneID)
            return
        }
        guard let workflow else { return }
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow] in
            let state = await workflow.selectPane(paneID)
            guard !Task.isCancelled else { return }
            await self?.applyWorkflowState(state, from: workflow)
        }
    }

    func openOrdinaryTerminal() {
        if isPanePickerPresented {
            selectOrdinaryTerminalFromPicker()
            return
        }
        guard let workflow else { return }
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow] in
            do {
                let state: HerdrBrowserState
                if let transition = workflow as? any HerdrExistingConnectionTerminalOpening {
                    state = try await transition.openOrdinaryTerminalWithoutReconnect()
                } else {
                    state = try await workflow.openOrdinaryTerminal()
                }
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
        openPanePickerFromTerminal()
    }

    /// Opens the shared picker without touching the already authenticated SSH
    /// bootstrap or the selected Mosh terminal session.
    func openPanePickerFromTerminal() {
        guard let workflow,
              let activeConnection,
              let pickerCoordinator = self.panePickerCoordinator,
              herdrState == .ordinaryTerminal || isAttachedState
        else { return }
        let generation = connectionGeneration
        let host = activeConnection.host
        let terminalContext: PanePickerTerminalContext
        if case let .attached(session, pane) = herdrState {
            terminalContext = .attached(
                PanePickerAttachedTerminal(
                    host: host,
                    session: session,
                    pane: pane
                )
            )
        } else {
            terminalContext = .ordinary(host: host)
        }
        Task { [weak self, workflow, pickerCoordinator, terminalContext] in
            await pickerCoordinator.synchronizeTerminalContext(terminalContext)
            let state = await pickerCoordinator.openPicker(from: .terminal)
            guard let self,
                  self.connectionGeneration == generation,
                  self.isCurrentWorkflow(workflow),
                  self.activeConnection?.host.id == host.id,
                  !Task.isCancelled
            else { return }
            await self.applyPanePickerState(state, workflow: workflow)
        }
    }

    /// Manual refresh delegates to the same state machine used by the
    /// scheduler. RootViewModel does not perform a second discovery or join.
    func refreshPanePicker() async {
        guard isPanePickerPresented,
              let pickerCoordinator = self.panePickerCoordinator,
              let workflow
        else { return }
        let state = await pickerCoordinator.refreshPicker()
        guard isPanePickerPresented,
              isCurrentWorkflow(workflow),
              !Task.isCancelled
        else { return }
        await applyPanePickerState(state, workflow: workflow)
    }

    func selectPaneFromPicker(_ paneID: Pane.ID) {
        guard isPanePickerPresented,
              let workflow,
              let pickerCoordinator = self.panePickerCoordinator
        else { return }
        let previousState = herdrState
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow, pickerCoordinator] in
            guard let self, !Task.isCancelled else { return }
            let state = await pickerCoordinator.selectPane(paneID)
            guard !Task.isCancelled,
                  self.isCurrentWorkflow(workflow),
                  self.isPanePickerPresented
            else { return }
            await self.applyPanePickerState(
                state,
                workflow: workflow,
                fallbackState: previousState
            )
            if case .panePicker = state {
                await pickerCoordinator.restartRefresh()
            }
        }
    }

    func selectOrdinaryTerminalFromPicker() {
        guard isPanePickerPresented,
              let workflow,
              let pickerCoordinator = self.panePickerCoordinator
        else { return }
        let previousState = herdrState
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow, pickerCoordinator] in
            guard let self, !Task.isCancelled else { return }
            let state = await pickerCoordinator.selectOrdinaryTerminal()
            guard !Task.isCancelled,
                  self.isCurrentWorkflow(workflow),
                  self.isPanePickerPresented
            else { return }
            await self.applyPanePickerState(
                state,
                workflow: workflow,
                fallbackState: previousState
            )
            if case .panePicker = state {
                await pickerCoordinator.restartRefresh()
            }
        }
    }

    /// Handles both the explicit close button and an interactive dismissal of
    /// the sheet/popover. A Host-origin picker owns its connection; a
    /// terminal-origin picker restores the context that was visible before it.
    func dismissPanePicker() {
        guard let picker = panePicker else {
            invalidatePanePickerPresentation()
            return
        }
        guard let pickerCoordinator = self.panePickerCoordinator else {
            invalidatePanePickerPresentation()
            if picker.origin == .host {
                returnToHosts()
            }
            return
        }
        let origin = picker.origin
        let workflow = self.workflow
        invalidatePanePickerPresentation()
        if origin == .host {
            returnToHosts()
            Task {
                await pickerCoordinator.dismissPicker()
            }
            return
        }
        guard let workflow else { return }
        Task { [weak self, workflow, pickerCoordinator] in
            let state = await pickerCoordinator.dismissPicker()
            guard let self,
                  self.isCurrentWorkflow(workflow),
                  !Task.isCancelled
            else { return }
            await self.applyPanePickerState(state, workflow: workflow)
        }
    }

    func suspendPaneControl() {
        invalidatePanePickerRefresh()

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
            guard panePicker != nil, isPanePickerPresented else { return }
            Task { [weak self] in
                await self?.panePickerCoordinator?.restartRefresh()
            }
            return
        }
        workflowTask?.cancel()
        workflowTask = Task { [weak self, workflow] in
            let state = await workflow.resumeAttachedControl()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.applyWorkflowState(state, from: workflow)
            guard !Task.isCancelled else { return }
            self.isPaneControlSuspended = false
            await self.panePickerCoordinator?.restartRefresh()
        }
    }

    /// Leaves the Herdr browser and returns to the saved-host list. The
    /// workflow is released before the SSH shell so an attached control
    /// session cannot outlive the host connection.
    func returnToHosts() {
        let workflow = self.workflow
        invalidatePanePickerPresentation()
        invalidateConnectionAttempt()
        self.panePickerCoordinator = nil
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
        invalidatePanePickerPresentation()
        invalidateConnectionAttempt()
        self.panePickerCoordinator = nil
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
    private func showLoadingPanePicker(for host: Host) {
        panePicker = PanePickerState(
            host: host,
            origin: .host,
            snapshot: HerdrSnapshot(sessions: []),
            isLoading: true
        )
        isPanePickerPresented = true
    }

    private var isAttachedState: Bool {
        if case .attached = herdrState { return true }
        return false
    }

    private func applyPanePickerState(
        _ state: PanePickerNavigationState,
        workflow: any HerdrWorkflowCoordinating,
        fallbackState: HerdrBrowserState? = nil
    ) async {
        guard isCurrentWorkflow(workflow), !Task.isCancelled else { return }

        switch state {
        case let .panePicker(picker):
            panePicker = picker
            isPanePickerPresented = true
            let wasAttached: Bool
            if let fallbackState {
                if case .attached = fallbackState {
                    wasAttached = true
                } else {
                    wasAttached = false
                }
            } else {
                wasAttached = isAttachedState
            }
            if let attached = picker.attachedTerminal, wasAttached {
                await applyWorkflowState(
                    .attached(session: attached.session, pane: attached.pane),
                    from: workflow
                )
                return
            }
            guard picker.origin == .terminal, fallbackState != nil else { return }
            // If rollback could not restore the old control, keep a usable
            // bootstrap terminal under the still-visible picker rather
            // than leaving a disconnected attached session on screen.
            await applyWorkflowState(.ordinaryTerminal, from: workflow)
        case let .terminal(.attached(attached)):
            await applyWorkflowState(
                .attached(session: attached.session, pane: attached.pane),
                from: workflow
            )
            invalidatePanePickerPresentation()
        case .terminal(.ordinary):
            await applyWorkflowState(.ordinaryTerminal, from: workflow)
            invalidatePanePickerPresentation()
        case .hosts, .legacyHerdrBrowser:
            invalidatePanePickerPresentation()
        }
    }

    private func makePanePickerCoordinator(
        for workflow: any HerdrWorkflowCoordinating,
        transport: ActiveTransport
    ) -> any PanePickerCoordinating {
        HerdrPanePickerCoordinator(
            discovery: RootPanePickerDiscovery(workflow: workflow),
            transport: RootPanePickerTransport(
                workflow: workflow,
                kind: transport
            ),
            scheduler: AnyPanePickerRefreshScheduler(panePickerScheduler)
        )
    }

    private func invalidatePanePickerRefresh() {
        guard let panePickerCoordinator = self.panePickerCoordinator else { return }
        panePickerCoordinator.invalidateRefreshImmediately()
        Task {
            await panePickerCoordinator.stopRefresh()
        }
    }

    private func invalidatePanePickerPresentation() {
        isPanePickerPresented = false
        panePicker = nil
        invalidatePanePickerRefresh()
    }

    private func beginConnection(for hostID: Host.ID) -> UUID {
        invalidatePanePickerPresentation()
        invalidateConnectionAttempt()
        panePickerCoordinator = nil
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
        if isPanePickerPresented,
           isAttachedState || herdrState == .ordinaryTerminal {
            switch state {
            case .empty, .sessions, .panes:
                // A terminal-origin picker keeps the terminal as its backing
                // surface even if an older browser callback reports a failed
                // or incomplete selection.
                return
            case .ordinaryTerminal, .attached:
                break
            }
        }

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
            guard let activeConnection else { return }
            lastPaneID = pane.id
            lastPaneHostID = activeConnection.host.id
            self.activeConnection = ActiveSSHConnection(
                host: activeConnection.host,
                session: terminalSession ?? activeConnection.session,
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
