// swiftlint:disable file_length
import HerdrKit
import os
import SwiftUI

@MainActor
final class RootViewModel: ObservableObject {
    @Published private(set) var hosts: [Host] = []
    @Published internal(set) var activeConnection: ActiveSSHConnection?
    @Published internal(set) var herdrState: HerdrBrowserState?
    @Published var panePicker: PanePickerState?
    @Published var isPanePickerPresented = false
    @Published var isCreatingWorkspace = false
    @Published private(set) var hasLastPane = false
    @Published private(set) var hasMultipleHerdrSessions = false
    @Published private(set) var isTearingDown = false
    @Published var isPaneControlSuspended = false
    @Published internal(set) var connectionState: ConnectionState = .idle
    @Published internal(set) var activeTransport: ActiveTransport?
    @Published internal(set) var preferences = TerminalPreferences()
    /// `nil` while the local-network check runs, so Hosts cannot flash early.
    @Published internal(set) var isLocalNetworkOnboardingRequired: Bool?
    var isRequestingLocalNetworkPermission = false
    @Published var errorMessage: String?
    @Published var isTransparentlyReconnecting = false
    /// One reconnect attempt per scene interruption.
    var transparentReconnectAttemptsUsed = 0
    /// Per-host cache of the last discovery snapshot (stale-while-revalidate).
    var pickerSnapshotCache: [Host.ID: HerdrSnapshot] = [:]
    @Published var editor: HostEditorContext?
    @Published var hostKeyPrompt: HostKeyPrompt?
    /// Phase 10: the Host row currently showing a connect attempt. Published
    /// when the attempt starts - never as a reaction to a result - and
    /// cleared on success, failure, or cancel.
    @Published internal(set) var connectingHostID: Host.ID?
    /// Phase 10: the host whose attempt genuinely failed (connect failure or a
    /// network/transparent-reconnect failure). Sticky across the teardown that
    /// follows, so its row keeps the red warning and Retry. A deliberate
    /// return to Hosts never records a failure, and a new attempt clears it,
    /// so a deliberate leave presents the row as idle.
    @Published internal(set) var failedHostID: Host.ID?
    /// Phase 10: true once the connecting row outlived the cancel threshold.
    @Published internal(set) var showsConnectCancel = false
    /// The most recently started/selected address for the in-flight race.
    /// This is transient UI state; the saved Host order is never changed.
    @Published internal(set) var connectingAddress: HostAddress?
    @Published internal(set) var addressRaceProgress: HostAddressRaceProgress?

    /// Phase 10: how long a connect attempt may run before its Host row
    /// offers Cancel. The plan fixes the default at 5 seconds; tests inject a
    /// clock through the initializer.
    static let defaultConnectCancelThreshold = Duration.seconds(5)

    let coordinator: ApplicationCoordinator
    let preferencesStore: any PreferencesStore
    let localNetworkPermissionGate: (any LocalNetworkPermissionGate)?
    private let workflowFactory: any HerdrWorkflowFactory
    private let panePickerScheduler: any PanePickerRefreshScheduling
    private let connectCancelThreshold: Duration
    private let connectCancelScheduler: any HostConnectingDelayScheduling
    var workflow: (any HerdrWorkflowCoordinating)?
    var panePickerCoordinator: (any PanePickerCoordinating)?
    var pendingHostKeyDecision: CheckedContinuation<HostKeyDecision, Never>?
    var pendingHostKeyPromptID: UUID?
    private var stateTask: Task<Void, Never>?
    var connectionTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var teardownID: UUID?
    private var connectCancelThresholdTask: Task<Void, Never>?
    /// Bounded close behind a user cancel. A retry joins it before opening a
    /// fresh session so the retired attempt's teardown cannot race it.
    private var cancelCloseTask: Task<Void, Never>?
    private var cancelCloseID: UUID?
    var workflowTask: Task<Void, Never>?
    var workspaceCreationTask: Task<Void, Never>?
    var workspaceCreationID = UUID()
    var panePickerDismissalInProgress = false
    var panePickerDismissalWaiters: [CheckedContinuation<Void, Never>] = []
    var connectionGeneration = UUID()
    private var lastHostID: Host.ID?
    var lastPaneID: Pane.ID?
    private var lastPaneHostID: Host.ID?
    var baseSession: SSHShellSession?
    var baseTerminalSession: SSHShellSession?
    var isSceneInactive = false
    var isSceneBackgrounded = false
    var sceneLifecycleGeneration = UUID()
    var terminalSessionCloseSuppressed = false
    /// Identity of a terminal session whose close surfaced during a scene
    /// interruption (or while a reconnect was already in flight). The next
    /// activation consumes it to run the one-shot transparent recovery;
    /// cleared whenever the connection context changes or proves alive.
    var pendingTerminalCloseIdentity: ObjectIdentifier?
    /// Whether the terminal held keyboard focus. Covers background
    /// retakeovers that replace the terminal session and recreate the view,
    /// so focus can be restored on the new view.
    var terminalKeyboardFocusActive = false
    var networkPathRecovery: NetworkPathRecoveryState
    func terminalInputFocusDidChange(_ isFocused: Bool) {
        terminalKeyboardFocusActive = isFocused
    }
    init(
        coordinator: ApplicationCoordinator = ApplicationCoordinator(),
        workflowFactory: any HerdrWorkflowFactory = SSHHerdrWorkflowFactory(),
        preferencesStore: any PreferencesStore = UserDefaultsPreferencesStore(),
        localNetworkPermissionGate: (any LocalNetworkPermissionGate)? = nil,
        panePickerScheduler: any PanePickerRefreshScheduling = LivePanePickerRefreshScheduler(),
        networkPathMonitor: any NetworkPathMonitoring = SystemNetworkPathMonitor(),
        rememberedPaneID: Pane.ID? = nil,
        rememberedPaneHostID: Host.ID? = nil,
        connectCancelThreshold: Duration = RootViewModel
            .defaultConnectCancelThreshold,
        connectCancelScheduler: any HostConnectingDelayScheduling =
            LiveHostConnectingDelayScheduler()
    ) {
        self.coordinator = coordinator
        self.connectCancelThreshold = connectCancelThreshold
        self.connectCancelScheduler = connectCancelScheduler
        self.workflowFactory = workflowFactory
        self.preferencesStore = preferencesStore
        self.localNetworkPermissionGate = localNetworkPermissionGate
        self.panePickerScheduler = panePickerScheduler
        self.networkPathRecovery = NetworkPathRecoveryState(
            monitor: networkPathMonitor
        )
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
        networkPathRecovery.transparentTask?.cancel()
        networkPathRecovery.debounceTask?.cancel()
        networkPathRecovery.monitor.cancel()
        workflowTask?.cancel()
        workspaceCreationTask?.cancel()
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
            await coordinator.setAddressPromotionEnabled(
                preferences.isAddressPromotionEnabled
            )
            DiagnosticLogger.shared.configure(
                isDebugLoggingEnabled: preferences.isDebugLoggingEnabled,
                isSaveLogsEnabled: preferences.isSaveLogsEnabled
            )
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

    func updateThemeSelection(_ selection: TerminalThemeSelection) {
        preferences.themeSelection = selection
        persistPreferences()
    }

    func updateFontFamily(_ familyName: String) {
        preferences.fontFamily = familyName
        persistPreferences()
    }

    func updateDebugLoggingEnabled(_ isEnabled: Bool) {
        preferences.isDebugLoggingEnabled = isEnabled
        DiagnosticLogger.shared.configure(
            isDebugLoggingEnabled: isEnabled,
            isSaveLogsEnabled: preferences.isSaveLogsEnabled
        )
        persistPreferences()
    }

    func updateSaveLogsEnabled(_ isEnabled: Bool) {
        preferences.isSaveLogsEnabled = isEnabled
        DiagnosticLogger.shared.configure(
            isDebugLoggingEnabled: preferences.isDebugLoggingEnabled,
            isSaveLogsEnabled: isEnabled
        )
        persistPreferences()
    }

    func updateAddressPromotionEnabled(_ isEnabled: Bool) {
        preferences.isAddressPromotionEnabled = isEnabled
        let coordinator = self.coordinator
        Task {
            await coordinator.setAddressPromotionEnabled(isEnabled)
        }
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
        if failedHostID == host.id {
            failedHostID = nil
        }
        if deletesActiveConnection {
            terminalSessionCloseSuppressed = false
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
        beginConnectingFeedback(for: host.id, generation: generation)
        errorMessage = nil
        connectionState = .connecting
        let coordinator = self.coordinator
        let pendingTeardown = teardownTask
        let pendingRetire = networkPathRecovery.retireTask
        let pendingCancelClose = cancelCloseTask
        connectionTask = Task { [weak self, coordinator, pendingTeardown, pendingRetire, pendingCancelClose] in
            do {
                await pendingTeardown?.value
                // A roam retire cancelled by beginConnection may still be
                // inside its bounded bootstrap close; wait so it cannot
                // abort this fresh connect.
                await pendingRetire?.value
                // A cancelled attempt's bounded close must finish first too,
                // or its late teardown would close the fresh session.
                await pendingCancelClose?.value
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
                    },
                    progress: { [weak self] progress in
                        guard let self else { return }
                        await self.publishAddressRaceProgress(
                            progress,
                            generation: generation
                        )
                    }
                )
                guard let self,
                      self.isCurrentConnection(generation),
                      !Task.isCancelled
                else {
                    // A superseded task must not touch the coordinator: it may
                    // already be serving a newer attempt, and retiring or
                    // closing that is the invalidator's job (cancel/teardown/
                    // delete/transparent reconnect).
                    return
                }
                guard state == .connected,
                      let bootstrapSession = await coordinator.activeShellSession()
                else {
                    throw ConnectionError.connectionFailed
                }
                let actualHost = await coordinator.activeHost() ?? host
                let terminalSession = await coordinator.activeTerminalSession() ?? bootstrapSession
                let selectedTransport = await coordinator.activeTransport() ?? .ssh
                let workflow = await self.makeWorkflow(
                    for: bootstrapSession,
                    hostID: host.id,
                    host: actualHost
                )
                self.showLoadingPanePicker(for: actualHost)
                let pickerCoordinator = self.makePanePickerCoordinator(
                    for: workflow,
                    transport: selectedTransport
                )
                let pickerState = try await pickerCoordinator.connect(to: actualHost)
                guard self.isCurrentConnection(generation), !Task.isCancelled else {
                    // Stop this task's own discovery, but leave the coordinator
                    // alone for the same ownership reason.
                    await pickerCoordinator.stopRefresh()
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
                    host: actualHost,
                    session: terminalSession,
                    transport: selectedTransport
                )
                self.connectionState = state
                self.connectionTask = nil
                self.finishConnectingFeedback(generation: generation)
                await self.applyPanePickerState(
                    pickerState,
                    workflow: workflow
                )
            } catch {
                guard let self else { return }
                await self.handleConnectFailure(
                    hostID: host.id,
                    generation: generation,
                    error: error
                )
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
        beginConnectingFeedback(for: hostID, generation: generation)
        errorMessage = nil
        connectionState = .connecting
        let coordinator = self.coordinator
        let pendingTeardown = teardownTask
        let pendingRetire = networkPathRecovery.retireTask
        let pendingCancelClose = cancelCloseTask
        connectionTask = Task { [weak self, coordinator, pendingTeardown, pendingRetire, pendingCancelClose] in
            do {
                await pendingTeardown?.value
                // Like connect(): a roam retire cancelled by beginConnection
                // may still be inside its bounded close; wait so it cannot
                // abort this fresh reconnect.
                await pendingRetire?.value
                // Same for a cancelled attempt's bounded close.
                await pendingCancelClose?.value
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
                    },
                    progress: { [weak self] progress in
                        guard let self else { return }
                        await self.publishAddressRaceProgress(
                            progress,
                            generation: generation
                        )
                    }
                )
                // Ownership first: a superseded task must not touch the
                // coordinator - it may already be serving a newer attempt, and
                // the invalidator owns that cleanup.
                guard self.isCurrentConnection(generation),
                      !Task.isCancelled
                else { return }
                guard state == .connected,
                      let bootstrapSession = await coordinator.activeShellSession()
                else {
                    throw ConnectionError.connectionFailed
                }
                let actualHost = await coordinator.activeHost() ?? host
                let terminalSession = await coordinator.activeTerminalSession() ?? bootstrapSession
                let selectedTransport = await coordinator.activeTransport() ?? .ssh
                let workflow = await self.makeWorkflow(
                    for: bootstrapSession,
                    hostID: host.id,
                    host: actualHost
                )
                self.showLoadingPanePicker(for: actualHost)
                let pickerCoordinator = self.makePanePickerCoordinator(
                    for: workflow,
                    transport: selectedTransport
                )
                let pickerState = try await pickerCoordinator.connect(to: actualHost)
                guard self.isCurrentConnection(generation), !Task.isCancelled else {
                    // Stop this task's own discovery, but leave the coordinator
                    // alone for the same ownership reason.
                    await pickerCoordinator.stopRefresh()
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
                    host: actualHost,
                    session: terminalSession,
                    transport: selectedTransport
                )
                self.connectionState = state
                self.connectionTask = nil
                self.finishConnectingFeedback(generation: generation)
                await self.applyPanePickerState(
                    pickerState,
                    workflow: workflow
                )
            } catch {
                guard let self else { return }
                await self.handleConnectFailure(
                    hostID: hostID,
                    generation: generation,
                    error: error
                )
            }
        }
    }

    /// Publishes a genuine attempt failure for `hostID`.
    ///
    /// The coordinator state is read before anything is published and the
    /// generation is re-checked after that await, so a superseded attempt
    /// cannot clear a retry or mark its row as failed. The failure marker is
    /// set last so the row's red warning and Retry appear together with the
    /// failure message.
    private func handleConnectFailure(
        hostID: Host.ID,
        generation: UUID,
        error: Error
    ) async {
        guard isCurrentConnection(generation) else { return }
        let coordinatorState = await coordinator.connectionState()
        guard isCurrentConnection(generation) else { return }
        invalidatePanePickerPresentation()
        answerHostKeyPrompt(.reject)
        workflow = nil
        herdrState = nil
        activeConnection = nil
        activeTransport = nil
        baseSession = nil
        baseTerminalSession = nil
        connectionTask = nil
        errorMessage = error.localizedDescription
        connectionState = coordinatorState
        finishConnectingFeedback(generation: generation)
        failedHostID = hostID
    }

}

/// Phase 10: the Hosts-list connecting feedback. The row state is published
/// when the attempt starts and converges on success, failure, or cancel; the
/// cancel affordance appears only after the injectable threshold.
extension RootViewModel {
    /// The Host row that owns the coordinator's current connection state: the
    /// connecting host while an attempt is live, otherwise the last host that
    /// was connected to (its row carries failure/disconnection feedback).
    var connectionStateHostID: Host.ID? {
        connectingHostID ?? lastHostID
    }

    /// The presentation state for one Host row.
    func rowConnectionState(for host: Host) -> HostRowConnectionState {
        HostRowConnectionState.resolve(
            host: host,
            connectingHostID: connectingHostID,
            failedHostID: failedHostID,
            stateOwnerHostID: connectionStateHostID,
            connectionState: connectionState
        )
    }

    func rowConnectionPresentation(
        for host: Host
    ) -> HostRowConnectionPresentation {
        HostRowConnectionPresentation.resolve(
            state: rowConnectionState(for: host),
            showsCancel: showsConnectCancel
        )
    }

    /// Cancels the in-flight connect attempt behind the connecting Host row.
    ///
    /// The row returns to idle immediately. The retired attempt is rejected by
    /// attempt ID, and anything it already opened is closed with the Phase 9
    /// bounded-close budget, so a cancel cannot leave a half-open connection.
    /// A stale tap with no attempt in flight is a no-op and therefore cannot
    /// disturb an established session.
    func cancelConnect() {
        guard let hostID = connectingHostID else { return }
        let pendingConnection = connectionTask
        DiagnosticLogger.shared.log(
            level: .notice,
            category: "connection",
            "connect cancelled host=\(hostID.uuidString), retry allowed"
        )
        clearConnectingFeedback()
        errorMessage = nil
        failedHostID = nil
        invalidatePanePickerPresentation()
        invalidateConnectionAttempt()
        panePickerCoordinator = nil
        workflow = nil
        herdrState = nil
        hasLastPane = false
        hasMultipleHerdrSessions = false
        baseSession = nil
        baseTerminalSession = nil
        activeConnection = nil
        activeTransport = nil
        connectionState = .idle
        startCancelClose(awaiting: pendingConnection)
    }

    /// Publishes the connecting row and arms the cancel threshold.
    private func beginConnectingFeedback(
        for hostID: Host.ID,
        generation: UUID
    ) {
        connectingHostID = hostID
        connectingAddress = nil
        addressRaceProgress = nil
        showsConnectCancel = false
        connectCancelThresholdTask?.cancel()
        let threshold = connectCancelThreshold
        let scheduler = connectCancelScheduler
        connectCancelThresholdTask = Task { [weak self] in
            do {
                try await scheduler.waitForCancelThreshold(threshold)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.connectionGeneration == generation,
                  self.connectingHostID == hostID
            else { return }
            self.showsConnectCancel = true
        }
    }

    private func finishConnectingFeedback(generation: UUID) {
        guard connectionGeneration == generation else { return }
        clearConnectingFeedback()
    }

    private func clearConnectingFeedback() {
        connectingHostID = nil
        connectingAddress = nil
        addressRaceProgress = nil
        showsConnectCancel = false
        connectCancelThresholdTask?.cancel()
        connectCancelThresholdTask = nil
    }

    func publishAddressRaceProgress(
        _ progress: HostAddressRaceProgress,
        generation: UUID
    ) {
        guard connectionGeneration == generation,
              connectingHostID != nil
        else { return }
        addressRaceProgress = progress
        switch progress {
        case let .preferred(address, _), let .attempting(address, _), let .selected(address, _):
            connectingAddress = address
        case let .racing(addresses, _):
            connectingAddress = addresses.last
        case .failed:
            connectingAddress = nil
        }
    }

    /// Runs behind `cancelConnect()`: retire the attempt and bounded-close
    /// what it opened, then join the cancelled RootViewModel task with the
    /// same budget so an immediate retry cannot race a late teardown.
    private func startCancelClose(
        awaiting pendingConnection: Task<Void, Never>?
    ) {
        let id = UUID()
        let generation = connectionGeneration
        cancelCloseID = id
        let previousCancelClose = cancelCloseTask
        let coordinator = self.coordinator
        let task = Task { [weak self, coordinator, previousCancelClose, pendingConnection] in
            await previousCancelClose?.value
            await coordinator.cancelConnectionAttempt()
            _ = try? await runWithTimeout(
                Self.teardownCloseTimeout,
                operation: { await pendingConnection?.value },
                onAbort: {}
            )
            guard let self, self.cancelCloseID == id else { return }
            self.cancelCloseTask = nil
            self.cancelCloseID = nil
            // A retry bumps the generation; a late convergence must not reset
            // the fresh attempt's visible state.
            if self.connectionGeneration == generation {
                self.connectionState = .idle
            }
        }
        cancelCloseTask = task
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
    /// bootstrap or the selected Mosh terminal session. When a path change
    /// retired the SSH control plane while Mosh kept the terminal alive,
    /// opening the Picker is the moment the bootstrap is rebuilt; the
    /// terminal stays on the existing Mosh PTY throughout.
    func openPanePickerFromTerminal() {
        guard let workflow,
              let activeConnection,
              let pickerCoordinator = self.panePickerCoordinator,
              herdrState == .ordinaryTerminal || isAttachedState
        else { return }
        let host = activeConnection.host
        Task { [weak self, workflow, pickerCoordinator] in
            guard let self else { return }
            // A roam rebuild rolls connectionGeneration and swaps the
            // workflow/picker coordinator in place, so every post-rebuild
            // read must use the fresh model state, not the captured values.
            guard await self.rebuildSSHControlPlaneForPickerOpenIfNeeded(),
                  !Task.isCancelled
            else { return }
            guard let currentWorkflow = self.workflow,
                  let pickerCoordinator = self.panePickerCoordinator,
                  self.activeConnection?.host.id == host.id
            else { return }
            let generation = self.connectionGeneration
            let terminalContext: PanePickerTerminalContext
            if case let .attached(session, pane) = self.herdrState {
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
            await pickerCoordinator.synchronizeTerminalContext(terminalContext)
            let state = await pickerCoordinator.openPicker(from: .terminal)
            guard self.connectionGeneration == generation,
                  self.isCurrentWorkflow(currentWorkflow),
                  self.activeConnection?.host.id == host.id,
                  !Task.isCancelled
            else { return }
            await self.applyPanePickerState(state, workflow: currentWorkflow)
        }
    }

    /// Manual refresh delegates to the same state machine used by the
    /// scheduler. RootViewModel does not perform a second discovery or join.
    func refreshPanePicker() async {
        guard !isSceneInactive,
              isPanePickerPresented,
              let pickerCoordinator = self.panePickerCoordinator,
              let workflow
        else { return }
        let state = await pickerCoordinator.refreshPicker()
        guard !isSceneInactive,
              isPanePickerPresented,
              isCurrentWorkflow(workflow),
              !Task.isCancelled
        else { return }
        await applyPanePickerState(state, workflow: workflow)
    }

    func selectPaneFromPicker(_ paneID: Pane.ID) {
        guard !isCreatingWorkspace,
              isPanePickerPresented,
              let workflow,
              let pickerCoordinator = self.panePickerCoordinator
        else { return }
        let previousState = herdrState
        terminalSessionCloseSuppressed = true
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow, pickerCoordinator] in
            guard let self, !Task.isCancelled else { return }
            defer { self.terminalSessionCloseSuppressed = false }
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
        guard !isCreatingWorkspace,
              isPanePickerPresented,
              let workflow,
              let pickerCoordinator = self.panePickerCoordinator
        else { return }
        let previousState = herdrState
        terminalSessionCloseSuppressed = true
        cancelWorkflowTask()
        workflowTask = Task { [weak self, workflow, pickerCoordinator] in
            guard let self, !Task.isCancelled else { return }
            defer { self.terminalSessionCloseSuppressed = false }
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

    /// Applies a native presentation Binding change. UIKit can report a
    /// dismissal while a scene is becoming inactive; that is an interruption,
    /// not an explicit Close, and must not tear down the connected context.
    func panePickerPresentationBindingDidChange(
        _ isPresented: Bool,
        sceneIsActive: Bool
    ) {
        guard !isPresented,
              isPanePickerPresented,
              sceneIsActive,
              !isSceneInactive
        else { return }
        dismissPanePicker()
    }

    /// Starts an explicit or system-driven Picker dismissal. The synchronous
    /// presentation-state change prevents SwiftUI's Binding callback from
    /// starting a second teardown while the awaitable operation is running.
    func dismissPanePicker() {
        guard !panePickerDismissalInProgress else { return }
        panePickerDismissalInProgress = true
        isPanePickerPresented = false
        Task { [weak self] in
            await self?.performPanePickerDismissal()
            self?.finishPanePickerDismissal()
        }
    }

    /// Handles explicit Close and is also the awaitable boundary used by scene
    /// lifecycle code. A Host-origin Picker owns its connection; a
    /// terminal-origin Picker restores the context visible before it. Repeated
    /// callers wait for the first operation rather than tearing down twice.
    func dismissPanePickerAndWait() async {
        if panePickerDismissalInProgress {
            await withCheckedContinuation { continuation in
                panePickerDismissalWaiters.append(continuation)
            }
            return
        }
        panePickerDismissalInProgress = true
        isPanePickerPresented = false
        await performPanePickerDismissal()
        finishPanePickerDismissal()
    }

    private func performPanePickerDismissal() async {
        terminalSessionCloseSuppressed = false
        guard let picker = panePicker else {
            invalidatePanePickerPresentation()
            await panePickerCoordinator?.stopRefresh()
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
            _ = await pickerCoordinator.dismissPicker()
            return
        }
        guard let workflow else {
            await pickerCoordinator.stopRefresh()
            return
        }
        let state = await pickerCoordinator.dismissPicker()
        guard isCurrentWorkflow(workflow), !Task.isCancelled else { return }
        await applyPanePickerState(state, workflow: workflow)
        await pickerCoordinator.stopRefresh()
    }

    private func finishPanePickerDismissal() {
        panePickerDismissalInProgress = false
        let waiters = panePickerDismissalWaiters
        panePickerDismissalWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Leaves the Herdr browser and returns to the saved-host list. The
    /// workflow is released before the SSH shell so an attached control
    /// session cannot outlive the host connection.
    func returnToHosts() {
        terminalSessionCloseSuppressed = false
        terminalKeyboardFocusActive = false
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

    /// Leaves the terminal for the Host list because the connection failed.
    ///
    /// Unlike a deliberate `returnToHosts()`, the owning row must keep its
    /// failure feedback: `.disconnected` alone now presents as idle, so the
    /// failure is recorded explicitly before the teardown clears the context.
    func returnToHostsAfterFailure() {
        let failedHost = activeConnection?.host.id ?? lastHostID
        returnToHosts()
        guard let failedHost else { return }
        failedHostID = failedHost
    }

    func disconnect() {
        terminalSessionCloseSuppressed = false
        terminalKeyboardFocusActive = false
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
    func showLoadingPanePicker(for host: Host) {
        panePicker = PanePickerState(
            host: host,
            origin: .host,
            snapshot: HerdrSnapshot(sessions: []),
            isLoading: true
        )
        // Present regardless of the inactive flag: sheets persist across
        // scene transitions natively, and system alerts (Local Network,
        // Keychain) mark the scene inactive WITHOUT a scenePhase change -
        // suppressing here stranded the first-connect flow on
        // "Choose a terminal..." with no re-presenting path.
        isPanePickerPresented = true
    }

    private var isAttachedState: Bool {
        if case .attached = herdrState { return true }
        return false
    }

    /// TerminalScreen is ALWAYS Mosh when the host connected with Mosh,
    /// whether in an ordinary terminal or an attached Herdr pane.
    var isMoshDataPlaneMounted: Bool {
        activeConnection?.transport == .mosh
    }

    func applyPanePickerState(
        _ state: PanePickerNavigationState,
        workflow: any HerdrWorkflowCoordinating,
        fallbackState: HerdrBrowserState? = nil
    ) async {
        guard isCurrentWorkflow(workflow), !Task.isCancelled else { return }
        startNetworkPathMonitoring()

        switch state {
        case let .panePicker(picker):
            panePicker = picker
            // Same rule as showLoadingPanePicker: presentation is never
            // suppressed by the inactive flag; dismissal of an
            // interruption-driven sheet change stays guarded separately in
            // panePickerPresentationBindingDidChange.
            isPanePickerPresented = true
            if picker.message == nil, !picker.isLoading {
                pickerSnapshotCache[picker.host.id] = picker.snapshot
            }
            if isSceneInactive {
                panePickerCoordinator?.invalidateRefreshImmediately()
                await panePickerCoordinator?.stopRefresh()
            }
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

    func makePanePickerCoordinator(
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
        workspaceCreationID = UUID()
        workspaceCreationTask?.cancel()
        workspaceCreationTask = nil
        isCreatingWorkspace = false
        terminalSessionCloseSuppressed = false
        isPanePickerPresented = false
        panePicker = nil
        invalidatePanePickerRefresh()
    }

    func beginConnection(for hostID: Host.ID) -> UUID {
        terminalSessionCloseSuppressed = false
        terminalKeyboardFocusActive = false
        invalidatePanePickerPresentation()
        invalidateConnectionAttempt()
        panePickerCoordinator = nil
        networkPathRecovery.controlPlaneRebuild = .idle
        // A still-running roam retire must not close the fresh bootstrap:
        // cancel it and let the connect/teardown path join its completion.
        networkPathRecovery.retireTask?.cancel()
        if let lastPaneHostID, lastPaneHostID != hostID {
            lastPaneID = nil
            self.lastPaneHostID = nil
        }
        lastHostID = hostID
        failedHostID = nil
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
        // Navigation leaves and cancel both converge the row back to idle.
        clearConnectingFeedback()
        // Cancel the in-flight inner reconnect and the owned deferred
        // rebuild. Both self-finalize: the rebuild task restores .needed on
        // cancellation so Leave (which runs inside the teardown) can still
        // join it or re-run the bootstrap reconnect + TERM.
        networkPathRecovery.transparentTask?.cancel()
        networkPathRecovery.transparentTask = nil
        networkPathRecovery.transparentTaskID = nil
        networkPathRecovery.rebuildTask?.cancel()
        isTransparentlyReconnecting = false
        DiagnosticLogger.shared.log(
            level: .notice,
            category: "network-recovery",
            "reconnect cancelled by navigation overlay=false"
        )
        pendingTerminalCloseIdentity = nil
        stopNetworkPathMonitoring()
        workflowTask?.cancel()
        workflowTask = nil
        answerHostKeyPrompt(.reject)
    }

    private func isCurrentConnection(_ generation: UUID) -> Bool {
        connectionGeneration == generation
    }

    func applyWorkflowState(
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
        switch state {
        case .attached, .ordinaryTerminal:
            terminalSession = await workflow.terminalSession()
        case .empty, .sessions, .panes:
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
            if case .ordinaryTerminal = state,
               let terminalSession {
                baseTerminalSession = terminalSession
            }
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

    func isCurrentWorkflow(
        _ candidate: any HerdrWorkflowCoordinating
    ) -> Bool {
        guard let workflow else { return false }
        return ObjectIdentifier(workflow) == ObjectIdentifier(candidate)
    }

    private func cancelWorkflowTask() {
        workflowTask?.cancel()
        workflowTask = nil
    }

    /// Maximum budget to wait for channel teardown before abandoning the socket.
    static let teardownCloseTimeout = Duration.seconds(1)

    private func scheduleTeardown(
        workflow: (any HerdrWorkflowCoordinating)?
    ) {
        isTearingDown = true
        let teardownID = UUID()
        self.teardownID = teardownID
        let previousTeardown = teardownTask
        let generation = connectionGeneration
        let coordinator = self.coordinator
        let teardownStarted = ContinuousClock.now
        DiagnosticLogger.shared.log(
            level: .debug,
            category: "network-recovery",
            "teardown start"
        )
        let task = Task { [weak self, previousTeardown, workflow, coordinator, teardownID, teardownStarted] in
            // Navigation must not wait on a reconnect whose client ignores
            // task cancellation; retire the coordinator attempt first.
            await coordinator.cancelPendingConnection()
            await previousTeardown?.value
            // Leave needs a live SSH bootstrap to TERM the recorded
            // mosh-server pid. When a path change retired it while Mosh
            // stayed mounted, rebuild just enough control plane first.
            await self?.rebuildSSHControlPlaneForLeaveIfNeeded()
            await self?.executeTeardownDisconnect(
                workflow: workflow,
                started: teardownStarted
            )
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

    private func executeTeardownDisconnect(
        workflow: (any HerdrWorkflowCoordinating)?,
        started: ContinuousClock.Instant
    ) async {
        var teardownTimedOut = false
        let coordinator = self.coordinator
        // Navigation is never a preserving recovery attempt, even if it
        // races the short handoff between a control-plane close and its
        // replacement connection.
        await coordinator.clearTerminalSessionPreservationForAttempt()
        // Pane release may open a new SSH exec channel and complete a remote
        // control handshake. It must not compete with the short TCP-close
        // budget below; otherwise navigation can abandon release first.
        if let workflow {
            _ = await workflow.returnToBrowser()
        }
        do {
            try await runWithTimeout(
                Self.teardownCloseTimeout,
                operation: {
                    await coordinator.disconnectAndWait()
                },
                onAbort: {
                    await coordinator.forceDisconnectedAfterCloseTimeout()
                }
            )
        } catch {
            teardownTimedOut = true
        }
        let teardownMs = (ContinuousClock.now - started) / .milliseconds(1)
        if teardownTimedOut {
            DiagnosticLogger.shared.log(
                level: .notice,
                category: "network-recovery",
                "teardown timeout durationMs=\(teardownMs), abandoning stale coordinator"
            )
        } else {
            DiagnosticLogger.shared.log(
                level: .debug,
                category: "network-recovery",
                "teardown end durationMs=\(teardownMs)"
            )
        }
    }

    func makeWorkflow(
        for session: SSHShellSession,
        hostID: Host.ID,
        host: Host? = nil
    ) async -> any HerdrWorkflowCoordinating {
        let rememberedPaneID = lastPaneHostID == hostID ? lastPaneID : nil
        let resolvedHost = host ?? hosts.first { $0.id == hostID }
        let selectedTransport = await coordinator.activeTransport() ?? activeTransport ?? .ssh
        let moshTransport = coordinator.moshTransport
        let coordinator = self.coordinator
        let context = HerdrWorkflowContext(
            transport: selectedTransport,
            moshTransport: moshTransport,
            host: resolvedHost,
            credentialsProvider: { [weak coordinator, resolvedHost] in
                guard let coordinator, let resolvedHost else { return nil }
                return try await coordinator.credentials(for: resolvedHost)
            }
        )
        return await workflowFactory.makeWorkflow(
            for: session,
            rememberedPaneID: rememberedPaneID,
            context: context
        )
    }

    func persistPreferences() {
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
}
