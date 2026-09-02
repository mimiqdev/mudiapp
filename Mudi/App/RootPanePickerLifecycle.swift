import Foundation
import HerdrKit

extension RootViewModel {
    /// Marks the scene inactive without touching the presentation. iOS keeps
    /// the system sheet presented across backgrounding, so hiding and
    /// re-presenting it manually is unnecessary and previously raced the
    /// presentation Binding.
    func sceneWillResignActive() {
        guard !isSceneInactive else {
            panePickerCoordinator?.invalidateRefreshImmediately()
            return
        }
        isSceneInactive = true
        sceneLifecycleGeneration = UUID()
        panePickerCoordinator?.invalidateRefreshImmediately()
    }

    /// Stops Picker refresh and attached control after the scene interruption
    /// has hidden the system presentation. No Host teardown occurs here.
    func sceneDidEnterBackground() async {
        if !isSceneInactive {
            sceneWillResignActive()
        }
        let generation = sceneLifecycleGeneration
        await suspendPaneControlNow(for: generation)
    }

    /// Resumes the existing terminal context. The system sheet was never
    /// removed, so nothing has to be re-presented here.
    func sceneDidBecomeActive() async {
        guard isSceneInactive else { return }
        isSceneInactive = false
        sceneLifecycleGeneration = UUID()
        await resumePaneControlNow()
        guard !Task.isCancelled else { return }
        await restartPanePickerRefreshIfPresent()
    }

    /// Called by PanePickerView after its app-owned or item-driven content is
    /// mounted. The Picker state itself remains the presentation source; this
    /// callback only starts the refresh job after content is usable.
    func panePickerDidBecomeVisible() async {
        guard !isSceneInactive,
              isPanePickerPresented,
              panePicker != nil,
              panePickerCoordinator != nil
        else { return }

        await restartPanePickerRefreshIfPresent()
    }

    /// Handles normal completion of a terminal output stream. A Herdr
    /// control close is not an SSH transport error: recover through the
    /// shared Picker while the bootstrap context is still available.
    func handleTerminalSessionClosed(
        for sessionIdentity: ObjectIdentifier? = nil
    ) async {
        guard !isTearingDown,
              !isSceneInactive,
              !isPaneControlSuspended,
              !terminalSessionCloseSuppressed,
              let activeConnection,
              let workflow,
              let pickerCoordinator = self.panePickerCoordinator
        else { return }
        if let sessionIdentity,
           ObjectIdentifier(activeConnection.session) != sessionIdentity {
            return
        }

        if isPanePickerPresented {
            let hasAttachedTerminal: Bool
            if case .attached = herdrState {
                hasAttachedTerminal = true
            } else {
                hasAttachedTerminal = false
            }
            if panePicker?.origin == .terminal, hasAttachedTerminal {
                let host = activeConnection.host
                let generation = connectionGeneration
                guard await moveClosedAttachedTerminalToOrdinary(
                    workflow: workflow,
                    hostID: host.id,
                    generation: generation
                ) else { return }
                await pickerCoordinator.synchronizeTerminalContext(
                    .ordinary(host: host)
                )
                let pickerState = await pickerCoordinator.openPicker(
                    from: .terminal
                )
                guard connectionGeneration == generation,
                      isCurrentWorkflow(workflow),
                      isPanePickerPresented,
                      !Task.isCancelled
                else { return }
                await applyPanePickerState(
                    pickerState,
                    workflow: workflow
                )
            }

            let state = await pickerCoordinator.refreshPicker()
            guard isCurrentWorkflow(workflow), !Task.isCancelled else { return }
            switch state {
            case let .panePicker(picker) where picker.message == nil:
                await applyPanePickerState(state, workflow: workflow)
            case let .panePicker(picker):
                errorMessage = picker.message ?? Self.terminalConnectionLostMessage
                returnToHosts()
            default:
                errorMessage = Self.terminalConnectionLostMessage
                returnToHosts()
            }
            return
        }

        if herdrState == .ordinaryTerminal, activeTransport != .mosh {
            errorMessage = Self.terminalConnectionLostMessage
            returnToHosts()
            return
        }

        // The closed control session must not remain the terminal context for
        // a terminal-origin Picker. Otherwise dismissing that Picker restores
        // the dead pane, remounts TerminalScreen, and immediately opens the
        // Picker again. Recover through the ordinary bootstrap terminal.
        await recoverTerminalThroughPicker(workflow: workflow)
    }

    private func moveClosedAttachedTerminalToOrdinary(
        workflow: any HerdrWorkflowCoordinating,
        hostID: Host.ID,
        generation: UUID
    ) async -> Bool {
        let isAttached: Bool
        if case .attached = herdrState {
            isAttached = true
        } else {
            isAttached = false
        }
        guard isAttached else { return true }

        if let transition = workflow as? any HerdrExistingConnectionTerminalOpening {
            _ = try? await transition.openOrdinaryTerminalWithoutReconnect()
        }
        guard connectionGeneration == generation,
              isCurrentWorkflow(workflow),
              activeConnection?.host.id == hostID,
              !isSceneInactive,
              !Task.isCancelled
        else { return false }
        await applyWorkflowState(.ordinaryTerminal, from: workflow)
        return connectionGeneration == generation
            && isCurrentWorkflow(workflow)
            && activeConnection?.host.id == hostID
            && !isSceneInactive
            && !Task.isCancelled
    }

    private static let terminalConnectionLostMessage =
        "The SSH shell connection was lost."

    func suspendPaneControl() {
        Task { [weak self] in
            await self?.suspendPaneControlNow()
        }
    }

    func resumePaneControl() {
        Task { [weak self] in
            await self?.resumePaneControlNow()
        }
    }

    private func suspendPaneControlNow(for sceneGeneration: UUID? = nil) async {
        panePickerCoordinator?.invalidateRefreshImmediately()
        await panePickerCoordinator?.stopRefresh()

        guard case .attached = herdrState,
              let workflow,
              !isPaneControlSuspended
        else { return }
        if let sceneGeneration {
            guard sceneGeneration == sceneLifecycleGeneration,
                  isSceneInactive
            else { return }
        }
        isPaneControlSuspended = true
        await workflow.suspendAttachedControl()
        guard !Task.isCancelled else { return }
        if let sceneGeneration {
            guard sceneGeneration == sceneLifecycleGeneration,
                  isSceneInactive
            else { return }
        }
        isPaneControlSuspended = true
    }

    private func resumePaneControlNow() async {
        guard isPaneControlSuspended,
              case .attached = herdrState,
              let workflow
        else {
            isPaneControlSuspended = false
            await restartPanePickerRefreshIfPresent()
            return
        }

        workflowTask?.cancel()
        let state = await workflow.resumeAttachedControl()
        guard !Task.isCancelled else { return }
        guard case .attached = state else {
            // The released control could not be retaken — e.g. the
            // connection did not survive device auto-lock. Applying the
            // failed browser state would strand the UI on a dead
            // "Choose a terminal…" surface with no way out, so recover
            // through the shared Picker instead.
            isPaneControlSuspended = false
            await recoverTerminalThroughPicker(workflow: workflow)
            return
        }
        await applyWorkflowState(state, from: workflow)
        guard !Task.isCancelled else { return }
        isPaneControlSuspended = false
        await restartPanePickerRefreshIfPresent()
    }

    /// Moves a lost attached terminal back to the ordinary bootstrap
    /// terminal and presents the terminal-origin Picker with a refreshed
    /// snapshot. If the underlying connection is dead, the ordinary
    /// terminal's own close handling escalates to the Host list.
    private func recoverTerminalThroughPicker(
        workflow: any HerdrWorkflowCoordinating
    ) async {
        guard let activeConnection,
              let pickerCoordinator = self.panePickerCoordinator
        else { return }
        let host = activeConnection.host
        let generation = connectionGeneration
        errorMessage = nil

        guard await moveClosedAttachedTerminalToOrdinary(
            workflow: workflow,
            hostID: host.id,
            generation: generation
        ) else { return }

        let terminalContext = PanePickerTerminalContext.ordinary(host: host)
        await pickerCoordinator.synchronizeTerminalContext(terminalContext)
        let state = await pickerCoordinator.openPicker(from: .terminal)
        guard connectionGeneration == generation,
              isCurrentWorkflow(workflow),
              self.activeConnection?.host.id == host.id,
              !Task.isCancelled
        else { return }
        await applyPanePickerState(state, workflow: workflow)

        let refreshedState = await pickerCoordinator.refreshPicker()
        guard connectionGeneration == generation,
              isCurrentWorkflow(workflow),
              !Task.isCancelled
        else { return }
        switch refreshedState {
        case let .panePicker(picker) where picker.message == nil:
            await applyPanePickerState(
                .panePicker(picker),
                workflow: workflow
            )
        case let .panePicker(picker):
            errorMessage = picker.message ?? Self.terminalConnectionLostMessage
            returnToHosts()
        default:
            errorMessage = Self.terminalConnectionLostMessage
            returnToHosts()
        }
    }

    private func restartPanePickerRefreshIfPresent() async {
        guard !isSceneInactive,
              isPanePickerPresented,
              panePicker != nil,
              let pickerCoordinator = self.panePickerCoordinator
        else { return }
        await pickerCoordinator.restartRefresh()
    }
}
