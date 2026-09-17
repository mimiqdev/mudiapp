import Foundation
import HerdrKit
import os

extension RootViewModel {
    private static let reconnectLog = Logger(
        subsystem: "dev.mudi.mobile", category: "transparent-reconnect"
    )

    static let transparentReconnectFailureMessage =
        "The connection to the server was lost and reconnection failed."

    enum TransparentReconnectError: Error {
        case unusableSession
    }
    /// Hard deadline for closing the retired session during transparent reconnect.
    static let reconnectCloseTimeout = Duration.seconds(1)
}

/// Which terminal context a transparent control-plane reconnect restores.
enum TransparentReconnectRestoration {
    /// Retake the remembered pane (attached terminal resume).
    case rememberedPane
    /// Restore the ordinary bootstrap terminal.
    case ordinaryTerminal
}

enum TransparentReconnectTrigger: Equatable, Sendable {
    case sceneInterruption
    case networkPathChange
}

/// Transparent control-plane reconnection after a scene interruption: when
/// the SSH base session died while the app was locked, one reconnect
/// attempt per interruption re-runs the bootstrap with saved Keychain
/// credentials and remembered-host-key acceptance (no interactive prompts),
/// rebuilds the workflow + picker coordinator, re-runs discovery, and
/// retakes the remembered pane when the fresh snapshot still has it.
///
/// Transparency contract: the attempt NEVER touches the UI-facing terminal
/// state. `beginConnection`/`showLoadingPanePicker` are deliberate
/// non-participants - nil-ing `herdrState`/`activeConnection` would flash
/// the Host list and presenting the Picker would cover the terminal. The
/// terminal page stays mounted with its last buffer under the Reconnecting
/// capsule; the fresh workflow/session/picker context is swapped in
/// atomically on success, and SwiftUI updates the terminal's session in
/// place (view identity follows the pane/host, not the session object).
/// Only a failure falls back to the Host list with a localized, human
/// message (raw NIOSSH/Swift errors never surface).
@MainActor
extension RootViewModel {
    var canAttemptTransparentReconnect: Bool {
        canAttemptTransparentReconnect(for: .sceneInterruption)
    }

    private func canAttemptTransparentReconnect(
        for trigger: TransparentReconnectTrigger
    ) -> Bool {
        guard !isTransparentlyReconnecting,
              activeConnection != nil
        else { return false }
        switch trigger {
        case .sceneInterruption:
            guard !isSceneInactive, !isSceneBackgrounded else { return false }
            return transparentReconnectAttemptsUsed == 0
        case .networkPathChange:
            guard !isSceneBackgrounded else { return false }
            return true
        }
    }

    private func isInterrupted(for trigger: TransparentReconnectTrigger) -> Bool {
        switch trigger {
        case .sceneInterruption:
            return isSceneInactive || isSceneBackgrounded
        case .networkPathChange:
            return isSceneBackgrounded
        }
    }

    /// Scene guard: every scene interruption grants exactly one attempt;
    /// every activation grants a fresh one so an interruption mid-reconnect
    /// retries on the next activation.
    func noteTransparentReconnectBudgetReset() {
        transparentReconnectAttemptsUsed = 0
    }

    /// Runs a transparent reconnect in an owned task so navigation can cancel
    /// it even when the caller is an unrelated lifecycle Task.
    func transparentControlPlaneReconnect(
        restoring restoration: TransparentReconnectRestoration,
        trigger: TransparentReconnectTrigger = .sceneInterruption
    ) async {
        guard networkPathRecovery.transparentTask == nil else { return }
        let operationID = beginTransparentControlPlaneReconnect(
            restoring: restoration,
            trigger: trigger
        )
        guard let task = networkPathRecovery.transparentTask else { return }
        await task.value
        if networkPathRecovery.transparentTaskID == operationID {
            networkPathRecovery.transparentTask = nil
            networkPathRecovery.transparentTaskID = nil
        }
    }

    /// Starts a path-driven reconnect after its debounce. Unlike the public
    /// async entry point this method does not wait for the operation.
    func launchTransparentControlPlaneReconnect(
        restoring restoration: TransparentReconnectRestoration,
        trigger: TransparentReconnectTrigger = .networkPathChange
    ) {
        guard networkPathRecovery.transparentTask == nil else { return }
        _ = beginTransparentControlPlaneReconnect(
            restoring: restoration,
            trigger: trigger
        )
    }

    private func beginTransparentControlPlaneReconnect(
        restoring restoration: TransparentReconnectRestoration,
        trigger: TransparentReconnectTrigger
    ) -> UUID {
        let operationID = UUID()
        networkPathRecovery.transparentTaskID = operationID
        networkPathRecovery.transparentTask = Task { @MainActor [weak self] in
            await self?.performTransparentControlPlaneReconnect(
                restoring: restoration,
                trigger: trigger,
                operationID: operationID
            )
        }
        return operationID
    }

    private func performTransparentControlPlaneReconnect(
        restoring restoration: TransparentReconnectRestoration,
        trigger: TransparentReconnectTrigger,
        operationID: UUID
    ) async {  // pi-lens-ignore: function_body_length
        defer {
            isTransparentlyReconnecting = false
            Self.networkRecoveryLog.notice("reconnect overlay=false")
            if networkPathRecovery.transparentTaskID == operationID {
                networkPathRecovery.transparentTask = nil
                networkPathRecovery.transparentTaskID = nil
                scheduleNetworkPathReconnectIfNeeded()
            }
        }
        guard canAttemptTransparentReconnect(for: trigger),
              !Task.isCancelled,
              let activeConnection
        else { return }
        if trigger == .sceneInterruption, networkPathRecovery.changePending {
            // A scene-driven recovery is already the one reconnect for the
            // path generation observed before activation. Do not schedule a
            // second path-driven recovery after this attempt succeeds.
            networkPathRecovery.attemptedGeneration =
                networkPathRecovery.changeGeneration
            networkPathRecovery.changePending = false
            networkPathRecovery.debounceTask?.cancel()
            networkPathRecovery.debounceTask = nil
            networkPathRecovery.debounceTaskID = nil
        }
        switch trigger {
        case .sceneInterruption:
            transparentReconnectAttemptsUsed += 1
        case .networkPathChange:
            break
        }
        let host = activeConnection.host
        let wasPickerPresented = isPanePickerPresented
        let pickerOrigin = panePicker?.origin ?? .terminal
        let preservesMoshSession = activeConnection.transport == .mosh
        isTransparentlyReconnecting = true
        Self.networkRecoveryLog.notice(
            "reconnect start trigger=\(String(describing: trigger), privacy: .public) mosh=\(preservesMoshSession) overlay=true"
        )
        let reconnectStarted = ContinuousClock.now

        errorMessage = nil
        // The reconnect supersedes any recorded close: it owns the recovery
        // from here (an abort re-records it below).
        pendingTerminalCloseIdentity = nil
        // Roll the generation and cancel in-flight work so stale callbacks
        // from the dead connection are rejected. Unlike beginConnection,
        // this deliberately keeps herdrState/activeConnection/baseSession
        // untouched: they are what keeps the terminal page mounted.
        connectionTask?.cancel()
        connectionTask = nil
        workflowTask?.cancel()
        workflowTask = nil
        answerHostKeyPrompt(.reject)
        connectionGeneration = UUID()
        let generation = connectionGeneration
        let onScreenSessionIdentity = ObjectIdentifier(activeConnection.session)
        let retiredPickerCoordinator = panePickerCoordinator

        // A user action that rolls the generation (back to Hosts, a new
        // connect) supersedes this attempt: bail without touching state.
        func isSuperseded() -> Bool {
            connectionGeneration != generation
        }

        // The coordinator still believes the stale connection is alive
        // (state .connected): tear it down before re-running the bootstrap,
        // otherwise reconnect's guards reject the attempt. Mosh owns a
        // separate data session, so preserve it while replacing only SSH
        // control.
        await retireStaleControlPlaneBeforeReconnect(
            preservesMoshSession: preservesMoshSession
        )

        guard !isInterrupted(for: trigger), !Task.isCancelled, !isSuperseded() else {
            // Mid-attempt interruption: the coordinator is now torn down
            // with the terminal still mounted - the next activation must
            // re-run the recovery (the budget is reset on activation).
            if !isSuperseded() {
                pendingTerminalCloseIdentity = onScreenSessionIdentity
            }
            return
        }
        guard !isSuperseded() else { return }

        Self.networkRecoveryLog.notice("connect start")
        let context = ReconnectAttemptContext(
            host: host,
            restoration: restoration,
            wasPickerPresented: wasPickerPresented,
            pickerOrigin: pickerOrigin,
            generation: generation,
            onScreenSessionIdentity: onScreenSessionIdentity,
            retiredPickerCoordinator: retiredPickerCoordinator,
            preservingMoshSession: preservesMoshSession,
            trigger: trigger
        )
        do {
            try await completeTransparentControlPlaneReconnect(using: context)
            let reconnectMs = (ContinuousClock.now - reconnectStarted) / .milliseconds(1)
            Self.networkRecoveryLog.notice(
                "reconnect success durationMs=\(reconnectMs)"
            )
        } catch {
            let reconnectMs = (ContinuousClock.now - reconnectStarted) / .milliseconds(1)
            Self.networkRecoveryLog.error(
                "reconnect failed durationMs=\(reconnectMs) error=\(error, privacy: .public)"
            )
            guard !isInterrupted(for: trigger),
                  !Task.isCancelled,
                  !isSuperseded()
            else { return }
            errorMessage = Self.transparentReconnectFailureMessage
            returnToHosts()
        }
    }

    private func retireStaleControlPlaneBeforeReconnect(
        preservesMoshSession: Bool
    ) async {
        Self.networkRecoveryLog.notice("close start mosh=\(preservesMoshSession)")
        let closeStarted = ContinuousClock.now
        var closeTimedOut = false
        do {
            try await runWithTimeout(
                Self.reconnectCloseTimeout,
                operation: {
                    if preservesMoshSession {
                        await self.coordinator.disconnectBootstrapAndWait()
                    } else {
                        await self.coordinator.disconnectAndWait()
                    }
                },
                onAbort: {}
            )
        } catch {
            closeTimedOut = true
        }
        let closeMs = (ContinuousClock.now - closeStarted) / .milliseconds(1)
        if closeTimedOut {
            Self.networkRecoveryLog.notice(
                "close timeout durationMs=\(closeMs), abandoning stale channel"
            )
            await coordinator.forceDisconnectedAfterCloseTimeout()
        } else {
            Self.networkRecoveryLog.notice("close end durationMs=\(closeMs)")
        }
    }

    private struct ReconnectAttemptContext {
        let host: Host
        let restoration: TransparentReconnectRestoration
        let wasPickerPresented: Bool
        let pickerOrigin: PanePickerOrigin
        let generation: UUID
        let onScreenSessionIdentity: ObjectIdentifier
        let retiredPickerCoordinator: (any PanePickerCoordinating)?
        let preservingMoshSession: Bool
        let trigger: TransparentReconnectTrigger
    }

    private func completeTransparentControlPlaneReconnect(
        using context: ReconnectAttemptContext
    ) async throws {  // pi-lens-ignore: function_body_length
        // Saved Keychain credentials; only the REMEMBERED host key is
        // accepted - an unknown or changed fingerprint fails the transparent
        // attempt instead of silently trusting it (no prompts on this path).
        let state = try await coordinator.reconnect(
            hostKeyDecision: { _ in .reject },
            preservingMoshSession: context.preservingMoshSession
        )
        guard state == .connected,
              let bootstrapSession = await coordinator.activeShellSession()
        else {
            throw TransparentReconnectError.unusableSession
        }
        let selectedTransport = await coordinator.activeTransport()
            ?? activeTransport ?? .ssh

        // Rebuild the workflow and the picker coordinator, then re-run
        // discovery over the fresh control plane.
        let workflow = await makeWorkflow(
            for: bootstrapSession,
            hostID: context.host.id
        )
        let pickerCoordinator = makePanePickerCoordinator(
            for: workflow,
            transport: selectedTransport
        )

        // A discovery failure stays inside the returned picker state as an
        // empty snapshot with a message; substitute the cached snapshot so
        // the user keeps the last-known layout (stale-while-revalidate).
        var pickerState = (try? await pickerCoordinator.connect(to: context.host))
            ?? cachedPanePickerState(for: context.host, origin: context.pickerOrigin)
        if case let .panePicker(picker) = pickerState,
           picker.message != nil,
           picker.snapshot.sessions.isEmpty {
            let cached = cachedPickerSnapshot(for: context.host)
            if !cached.sessions.isEmpty {
                pickerState = .panePicker(
                    PanePickerState(
                        host: picker.host,
                        origin: picker.origin,
                        snapshot: cached,
                        message: picker.message
                    )
                )
            }
        }
        guard !isInterrupted(for: context.trigger), !Task.isCancelled else {
            if connectionGeneration == context.generation {
                pendingTerminalCloseIdentity = context.onScreenSessionIdentity
            }
            return
        }
        guard connectionGeneration == context.generation else { return }

        // Atomic swap: publish the fresh control plane in one shot.
        // herdrState and activeConnection are NOT cleared here - the
        // terminal view keeps showing its last buffer until restoration
        // below swaps the session in place.
        self.workflow = workflow
        self.panePickerCoordinator = pickerCoordinator
        self.baseSession = bootstrapSession
        self.baseTerminalSession = await coordinator.activeTerminalSession()
            ?? bootstrapSession
        self.activeTransport = selectedTransport
        self.connectionState = state
        await context.retiredPickerCoordinator?.stopRefresh()
        if case let .panePicker(picker) = pickerState,
           picker.message == nil {
            pickerSnapshotCache[picker.host.id] = picker.snapshot
        }

        switch context.restoration {
        case .rememberedPane:
            await restoreRememberedPaneAfterReconnect(
                pickerState: pickerState,
                pickerCoordinator: pickerCoordinator,
                workflow: workflow,
                wasPickerPresented: context.wasPickerPresented,
                pickerOrigin: context.pickerOrigin,
                trigger: context.trigger
            )
        case .ordinaryTerminal:
            // The fresh bootstrap shell IS the ordinary terminal; applying
            // the state swaps the terminal's session in place.
            await applyWorkflowState(.ordinaryTerminal, from: workflow)
            if context.wasPickerPresented {
                await refreshPresentedPickerAfterReconnect(
                    terminalContext: .ordinary(host: context.host),
                    pickerOrigin: context.pickerOrigin,
                    pickerCoordinator: pickerCoordinator,
                    workflow: workflow,
                    trigger: context.trigger
                )
            }
        }

        // A picker that never surfaces must not keep a refresh timer running
        // against the new coordinator.
        if !isPanePickerPresented {
            await pickerCoordinator.stopRefresh()
        }
        pendingTerminalCloseIdentity = nil
    }

    /// Retakes the remembered pane over the fresh control plane when the
    /// fresh snapshot still has it, without presenting the Picker. A picker
    /// that was presented across the interruption stays presented and is
    /// refreshed over the new control plane; a gone pane or failed retake
    /// presents the picker (fresh or cached snapshot) for a manual choice.
    private func restoreRememberedPaneAfterReconnect(
        pickerState: PanePickerNavigationState,
        pickerCoordinator: any PanePickerCoordinating,
        workflow: any HerdrWorkflowCoordinating,
        wasPickerPresented: Bool,
        pickerOrigin: PanePickerOrigin,
        trigger: TransparentReconnectTrigger
    ) async {
        let retakeTarget: Pane.ID?
        if let lastPaneID,
           case let .panePicker(picker) = pickerState,
           picker.message == nil,
           panePickerLocation(in: picker.snapshot, paneID: lastPaneID)
            != nil {
            retakeTarget = lastPaneID
        } else {
            retakeTarget = nil
        }

        guard let paneID = retakeTarget else {
            await applyPanePickerState(pickerState, workflow: workflow)
            return
        }

        // selectPane works on the coordinator's internal picker state (the
        // sheet itself is not required), keeping the retake invisible.
        let result = await pickerCoordinator.selectPane(paneID)
        guard !isInterrupted(for: trigger), !Task.isCancelled else { return }
        guard case let .terminal(.attached(attached)) = result else {
            // The pane vanished mid-reconnect or the retake failed: the
            // picker carries the message for a manual choice.
            await applyPanePickerState(result, workflow: workflow)
            return
        }

        await applyWorkflowState(
            .attached(session: attached.session, pane: attached.pane),
            from: workflow
        )
        if wasPickerPresented {
            await refreshPresentedPickerAfterReconnect(
                terminalContext: .attached(attached),
                pickerOrigin: pickerOrigin,
                pickerCoordinator: pickerCoordinator,
                workflow: workflow,
                trigger: trigger
            )
        }
    }

    /// Re-syncs a picker that stayed presented across the interruption with
    /// the restored terminal context and the fresh snapshot. The sheet is
    /// never dismissed or re-presented; only its content is replaced.
    private func refreshPresentedPickerAfterReconnect(
        terminalContext: PanePickerTerminalContext,
        pickerOrigin: PanePickerOrigin,
        pickerCoordinator: any PanePickerCoordinating,
        workflow: any HerdrWorkflowCoordinating,
        trigger: TransparentReconnectTrigger
    ) async {
        await pickerCoordinator.synchronizeTerminalContext(terminalContext)
        let reopened = await pickerCoordinator.openPicker(from: pickerOrigin)
        guard !isInterrupted(for: trigger), !Task.isCancelled else { return }
        await applyPanePickerState(reopened, workflow: workflow)
    }

    /// Fallback presentation while the control plane is unavailable: the
    /// cached snapshot for the host, or an empty tree for a cold start.
    func cachedPanePickerState(
        for host: Host,
        origin: PanePickerOrigin
    ) -> PanePickerNavigationState {
        .panePicker(
            PanePickerState(
                host: host,
                origin: origin,
                snapshot: cachedPickerSnapshot(for: host)
            )
        )
    }

    func cachedPickerSnapshot(for host: Host) -> HerdrSnapshot {
        pickerSnapshotCache[host.id] ?? HerdrSnapshot(sessions: [])
    }
}
