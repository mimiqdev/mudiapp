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
        noteTransparentReconnectBudgetReset()
        await resumePaneControlNow()
        guard !Task.isCancelled else { return }
        // A close that surfaced during the interruption (ordinary terminal,
        // or a reconnect aborted mid-flight after its disconnect) left the
        // coordinator dead with the terminal mounted: run the same one-shot
        // recovery now that the budget has been re-armed.
        await recoverInterruptedTerminalAfterActivation()
        guard !Task.isCancelled else { return }
        await restartPanePickerRefreshIfPresent()
    }

    /// Activation-side recovery for a close that was suppressed by an
    /// interruption. Only fires when the pending close still matches the
    /// terminal session on screen; a successful resume clears the pending
    /// close itself (a live control proves it was stale).
    private func recoverInterruptedTerminalAfterActivation() async {
        guard let activeConnection,
              pendingTerminalCloseIdentity
                  == ObjectIdentifier(activeConnection.session)
        else {
            pendingTerminalCloseIdentity = nil
            return
        }
        pendingTerminalCloseIdentity = nil
        if case .attached = herdrState {
            await transparentControlPlaneReconnect(
                restoring: .rememberedPane
            )
        } else if herdrState == .ordinaryTerminal {
            await transparentControlPlaneReconnect(
                restoring: .ordinaryTerminal
            )
        }
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
              let activeConnection
        else { return }
        guard !terminalSessionCloseSuppressed else { return }
        let closedIdentity = sessionIdentity
            ?? ObjectIdentifier(activeConnection.session)
        guard ObjectIdentifier(activeConnection.session) == closedIdentity
        else { return }

        // An interruption (scene inactive, suspended control, or a
        // reconnect already in flight) hides the close: record it so the
        // next activation runs the one-shot recovery instead of leaving a
        // dead terminal mounted with a torn-down coordinator.
        if isSceneInactive
            || isPaneControlSuspended
            || isTransparentlyReconnecting {
            pendingTerminalCloseIdentity = closedIdentity
            return
        }

        guard let workflow,
              let pickerCoordinator = self.panePickerCoordinator
        else { return }

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
            await transparentControlPlaneReconnect(
                restoring: .ordinaryTerminal
            )
            return
        }

        // The closed control session must not remain the terminal context
        // for a terminal-origin Picker (normal shell exit). Recover through
        // the ordinary bootstrap terminal + shared Picker. Transport
        // failures after a scene interruption are handled by the
        // resumePaneControlNow path (transparent reconnect), not here.
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
            // The released control could not be retaken. After a scene
            // interruption the SSH base session is stale (NIOSSH write
            // probing cannot reliably distinguish dead from alive - TCP
            // writes are buffered), so ALWAYS attempt ONE transparent
            // reconnect. The one-shot budget prevents retry loops; a live
            // connection reconnects quickly, a dead one falls back to
            // Hosts with a localized message.
            isPaneControlSuspended = false
            await transparentControlPlaneReconnect(
                restoring: .rememberedPane
            )
            return
        }
        await applyWorkflowState(state, from: workflow)
        guard !Task.isCancelled else { return }
        isPaneControlSuspended = false
        // The control channel is live again: any recorded close was stale.
        pendingTerminalCloseIdentity = nil
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
