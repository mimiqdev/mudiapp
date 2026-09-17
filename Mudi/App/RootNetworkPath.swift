import Foundation
import HerdrKit
import os

/// Lifecycle of the deferred SSH control-plane rebuild after a Mosh roam.
/// A plain boolean cleared up front cannot express a failed or superseded
/// attempt, so the rebuild state is explicit and restored on failure.
enum MoshControlPlaneRebuild: Equatable, Sendable {
    /// The control plane is live or no roam is pending.
    case idle
    /// A roam retired the SSH bootstrap; the next Picker open or a Leave
    /// that needs a live bootstrap rebuilds it.
    case needed
    /// A deferred rebuild is currently running.
    case inProgress
}

struct NetworkPathRecoveryState {
    let monitor: any NetworkPathMonitoring
    var monitoringStarted = false
    var monitorGeneration = UUID()
    var lastPath: NetworkPathSnapshot?
    var changeGeneration = UUID()
    var attemptedGeneration: UUID?
    var changePending = false
    var debounceTask: Task<Void, Never>?
    var debounceTaskID: UUID?
    var transparentTask: Task<Void, Never>?
    var transparentTaskID: UUID?
    /// The tracked roam-retire task. Picker rebuild, Leave rebuild, new
    /// connects, and teardown all await it so a slow bootstrap close cannot
    /// abort a later attempt or wipe a freshly rebuilt session.
    var retireTask: Task<Void, Never>?
    var retireTaskID: UUID?
    /// A retire task superseded by a newer flap. The new retire joins it so
    /// a cancelled close cannot outlive the handle and abort a later
    /// rebuild or connect.
    var supersededRetireTask: Task<Void, Never>?
    /// The single owned deferred rebuild. It includes finalization, so any
    /// joiner (Picker open, Leave) observes the settled `.idle`/`.needed`
    /// result rather than racing a caller that finalizes after the inner
    /// reconnect task completes.
    var rebuildTask: Task<Bool, Never>?
    var rebuildTaskID: UUID?
    /// Set when a path flap arrives while a deferred rebuild is in flight.
    /// The rebuild owns the control plane during its handshake, so the roam
    /// must not spawn a concurrent bootstrap disconnect; the rebuild task
    /// retires the (now stale) bootstrap again when it finishes.
    var roamedDuringRebuild = false
    /// Deferred SSH control-plane rebuild state after a Mosh roam.
    var controlPlaneRebuild: MoshControlPlaneRebuild = .idle
    /// Read/write compatibility for the roam-pending check used by tests
    /// and simple callers.
    var controlPlaneNeedsRebuild: Bool {
        get { controlPlaneRebuild != .idle }
        set { controlPlaneRebuild = newValue ? .needed : .idle }
    }

    init(monitor: any NetworkPathMonitoring) {
        self.monitor = monitor
    }
}

@MainActor
extension RootViewModel {
    /// A short coalescing window prevents flapping path updates from
    /// producing a reconnect for every intermediate snapshot.
    static let networkPathReconnectDebounce = Duration.milliseconds(300)
    /// A satisfied path can be probed immediately; the probe is the guard
    /// against tearing down a connection that survived the path update.
    static let networkPathProbeTimeout = Duration.milliseconds(400)

    func startNetworkPathMonitoring() {
        guard !networkPathRecovery.monitoringStarted else { return }
        networkPathRecovery.monitoringStarted = true
        let monitorGeneration = UUID()
        networkPathRecovery.monitorGeneration = monitorGeneration
        networkPathRecovery.lastPath = nil
        networkPathRecovery.monitor.start { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.networkPathDidUpdate(
                    path,
                    monitorGeneration: monitorGeneration
                )
            }
        }
    }

    func stopNetworkPathMonitoring() {
        networkPathRecovery.monitoringStarted = false
        networkPathRecovery.monitorGeneration = UUID()
        networkPathRecovery.lastPath = nil
        networkPathRecovery.changeGeneration = UUID()
        networkPathRecovery.attemptedGeneration = nil
        networkPathRecovery.changePending = false
        networkPathRecovery.debounceTask?.cancel()
        networkPathRecovery.debounceTask = nil
        networkPathRecovery.debounceTaskID = nil
        networkPathRecovery.monitor.cancel()
    }

    /// Called by the monitor callback and exposed internally for deterministic
    /// model tests.
    func networkPathDidUpdate(_ path: NetworkPathSnapshot) {
        networkPathDidUpdate(
            path,
            monitorGeneration: networkPathRecovery.monitorGeneration
        )
    }

    private func networkPathDidUpdate(
        _ path: NetworkPathSnapshot,
        monitorGeneration: UUID
    ) {
        guard networkPathRecovery.monitoringStarted,
              monitorGeneration == networkPathRecovery.monitorGeneration
        else { return }

        let previousPath = networkPathRecovery.lastPath
        networkPathRecovery.lastPath = path
        guard let previousPath else {
            DiagnosticLogger.shared.log(
                level: .notice,
                category: "network-recovery",
                "path initial \(path.logDescription)"
            )
            return
        }
        let statusFlipped = (previousPath.status == .satisfied)
            != (path.status == .satisfied)
        let interfacesChanged = previousPath.interfaces != path.interfaces
        guard statusFlipped || interfacesChanged else {
            DiagnosticLogger.shared.log(
                level: .debug,
                category: "network-recovery",
                "path ignore \(path.logDescription)"
            )
            return
        }
        DiagnosticLogger.shared.log(
            level: .notice,
            category: "network-recovery",
            "path change from \(previousPath.logDescription) to \(path.logDescription)"
        )

        networkPathRecovery.changeGeneration = UUID()
        networkPathRecovery.attemptedGeneration = nil
        networkPathRecovery.debounceTask?.cancel()
        networkPathRecovery.debounceTask = nil
        networkPathRecovery.debounceTaskID = nil

        if isMoshDataPlaneMounted {
            // Mosh is the user-facing UDP data plane and roams on its own.
            // A path change must neither tear it down nor race an SSH
            // control-plane rebuild against the roam (the 2026-09-16 device
            // freeze came from exactly that race). Retire only the stale
            // TCP bootstrap in a tracked background task; the next Picker
            // open or a Leave that needs a live bootstrap rebuilds it.
            networkPathRecovery.changePending = false
            if networkPathRecovery.controlPlaneRebuild == .inProgress {
                // A deferred rebuild owns the SSH handshake right now. Do
                // NOT spawn a concurrent bootstrap disconnect (it would
                // request disconnect on the in-flight connect and then
                // close the retained Mosh session). Record the flap so the
                // rebuild retires the stale bootstrap when it finishes.
                networkPathRecovery.roamedDuringRebuild = true
                DiagnosticLogger.shared.log(
                    level: .notice,
                    category: "network-recovery",
                    "path roam during rebuild mosh=true deferred-retire"
                )
                return
            }
            // A fresh flap supersedes any still-running retire. The cancelled
            // handle is kept and joined by the new retire so its bounded close
            // cannot outlive the handle and abort a later rebuild or connect.
            let superseded = networkPathRecovery.retireTask
            superseded?.cancel()
            networkPathRecovery.supersededRetireTask = superseded
            networkPathRecovery.retireTask = nil
            networkPathRecovery.retireTaskID = nil
            networkPathRecovery.controlPlaneRebuild = .needed
            DiagnosticLogger.shared.log(
                level: .notice,
                category: "network-recovery",
                "path roam mosh=true retire=ssh-control overlay=false"
            )
            let retireTaskID = UUID()
            let generation = networkPathRecovery.changeGeneration
            networkPathRecovery.retireTaskID = retireTaskID
            networkPathRecovery.retireTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // Join the superseded retire first: its close may still be
                // inside the 1s timeout and must not overlap this one.
                await superseded?.value
                if self.networkPathRecovery.supersededRetireTask != nil {
                    self.networkPathRecovery.supersededRetireTask = nil
                }
                await self.retireStaleControlPlaneAfterMoshRoam(
                    generation: generation
                )
                if self.networkPathRecovery.retireTaskID == retireTaskID {
                    self.networkPathRecovery.retireTask = nil
                    self.networkPathRecovery.retireTaskID = nil
                }
            }
            return
        }

        networkPathRecovery.changePending = true
        scheduleNetworkPathReconnectIfNeeded()
    }

    /// Waits for any in-flight roam retire so its bounded bootstrap close
    /// cannot overlap a later picker/Leave rebuild or teardown.
    private func awaitPendingMoshRoamRetire() async {
        guard let retireTask = networkPathRecovery.retireTask else { return }
        await retireTask.value
    }

    /// Closes the SSH bootstrap after a Mosh roam without touching the
    /// mounted Mosh terminal session. No reconnect is attempted here: the
    /// rebuild is deferred to the next Picker open or to Leave. The
    /// baseSession cleanup is generation-guarded so a rebuild that already
    /// installed a fresh bootstrap is never wiped by a late retire.
    private func retireStaleControlPlaneAfterMoshRoam(
        generation: UUID
    ) async {
        guard !Task.isCancelled,
              networkPathRecovery.controlPlaneRebuild == .needed
        else { return }
        await closeBootstrapPreservingMosh(generation: generation)
        guard !Task.isCancelled,
              networkPathRecovery.changeGeneration == generation,
              networkPathRecovery.controlPlaneRebuild == .needed
        else { return }
        baseSession = nil
    }

    /// The bounded bootstrap close shared by the roam retire and by a
    /// rebuild that finished while a flap was pending. Cancellation and a
    /// superseding generation both skip the force-abort so a close that
    /// lost ownership cannot kill a newer bootstrap or the Mosh session.
    private func closeBootstrapPreservingMosh(generation: UUID) async {
        let closeStarted = ContinuousClock.now
        do {
            try await runWithTimeout(
                Self.reconnectCloseTimeout,
                operation: {
                    await self.coordinator.disconnectBootstrapAndWait(
                        preservingTerminalSession: true
                    )
                },
                onAbort: {}
            )
            await coordinator.clearTerminalSessionPreservationForAttempt()
        } catch {
            let closeMs = (ContinuousClock.now - closeStarted) / .milliseconds(1)
            // A cancelled close means a newer flap or a connect now owns the
            // shutdown; force-aborting here could kill that newer bootstrap.
            guard !Task.isCancelled,
                  networkPathRecovery.changeGeneration == generation
            else { return }
            DiagnosticLogger.shared.log(
                level: .notice,
                category: "network-recovery",
                "roam close timeout durationMs=\(closeMs), abandoning stale channel"
            )
            await coordinator.forceDisconnectedAfterCloseTimeout()
        }
    }

    /// Rebuilds the SSH control plane after a Mosh roam when the user opens
    /// the Picker. The rebuild is a single owned task that includes
    /// finalization: a failed, cancelled, or superseded attempt restores
    /// `.needed` so the next Picker open and Leave still retry, and a flap
    /// observed mid-handshake re-retires the stale bootstrap. Concurrent
    /// opens and Leave all join the same task rather than racing to claim
    /// `.needed`. Returns false when the rebuild cannot serve the Picker.
    func rebuildSSHControlPlaneForPickerOpenIfNeeded() async -> Bool {
        await runDeferredMoshControlPlaneRebuild()
    }

    /// Rebuilds the SSH bootstrap so Leave can TERM the recorded
    /// mosh-server pid after a roam retired the old one. Leave runs after
    /// navigation cleared the terminal context, so it cannot use the
    /// transparent reconnect (which needs a live activeConnection). It
    /// joins any in-flight deferred rebuild first, then does a
    /// coordinator-level bootstrap reconnect + TERM if still needed.
    func rebuildSSHControlPlaneForLeaveIfNeeded() async {
        // Join a picker-open rebuild that is still running. It
        // self-finalizes to .idle (success) or .needed (cancelled/failed).
        if networkPathRecovery.controlPlaneRebuild == .inProgress,
           let task = networkPathRecovery.rebuildTask {
            _ = await task.value
        }
        guard networkPathRecovery.controlPlaneRebuild == .needed
        else { return }
        await awaitPendingMoshRoamRetire()
        guard networkPathRecovery.controlPlaneRebuild == .needed,
              await coordinator.activeTransport() == .mosh
        else { return }
        networkPathRecovery.controlPlaneRebuild = .inProgress
        DiagnosticLogger.shared.log(
            level: .notice,
            category: "network-recovery",
            "leave rebuild launch mosh=true overlay=false"
        )
        do {
            let state = try await coordinator.reconnect(
                hostKeyDecision: { _ in .reject },
                preservingMoshSession: true
            )
            guard state == .connected,
                  let bootstrap = await coordinator.activeShellSession()
            else {
                throw ConnectionError.connectionFailed
            }
            await coordinator.moshTransport.leavePaneDaemon(using: bootstrap)
            if networkPathRecovery.controlPlaneRebuild == .inProgress {
                networkPathRecovery.controlPlaneRebuild = .idle
            }
        } catch {
            if networkPathRecovery.controlPlaneRebuild == .inProgress {
                networkPathRecovery.controlPlaneRebuild = .needed
            }
            DiagnosticLogger.shared.log(
                level: .error,
                category: "network-recovery",
                "leave rebuild failed error=\(error.localizedDescription)"
            )
        }
    }

    /// Owns the deferred control-plane rebuild. The first caller on a
    /// `.needed` state claims `.inProgress` and spawns the shared task;
    /// every later caller (concurrent Picker opens, Leave) joins that same
    /// task and observes the finalized result. A joined task that settled
    /// back to `.needed` (cancelled or superseded) is retried rather than
    /// returning a stale dead-control-plane result. Returns true when the
    /// control plane is live and the terminal context is intact.
    private func runDeferredMoshControlPlaneRebuild() async -> Bool {
        // Join an in-flight rebuild and observe its finalized result. If it
        // settled back to .needed (cancelled/superseded), fall through to
        // start one fresh attempt for this caller.
        if networkPathRecovery.controlPlaneRebuild == .inProgress,
           let task = networkPathRecovery.rebuildTask {
            let result = await task.value
            if result || networkPathRecovery.controlPlaneRebuild == .idle {
                return true
            }
        }
        if networkPathRecovery.controlPlaneRebuild == .idle {
            return true
        }
        await awaitPendingMoshRoamRetire()
        // Recheck after the join: a retire may have handed off to a rebuild
        // that already started, or cleared the need entirely.
        switch networkPathRecovery.controlPlaneRebuild {
        case .idle:
            return true
        case .inProgress:
            if let task = networkPathRecovery.rebuildTask {
                return await task.value
            }
            return networkPathRecovery.controlPlaneRebuild == .idle
        case .needed:
            break
        }
        guard isMoshDataPlaneMounted,
              networkPathReconnectRestoration() != nil
        else { return false }

        let rebuildTaskID = UUID()
        networkPathRecovery.rebuildTaskID = rebuildTaskID
        networkPathRecovery.controlPlaneRebuild = .inProgress
        DiagnosticLogger.shared.log(
            level: .notice,
            category: "network-recovery",
            "deferred rebuild launch mosh=true overlay=false"
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performDeferredMoshControlPlaneRebuild(
                rebuildTaskID: rebuildTaskID
            )
        }
        networkPathRecovery.rebuildTask = task
        return await task.value
    }

    /// The single deferred rebuild body. It runs the transparent reconnect,
    /// then finalizes the rebuild state itself so joiners always observe a
    /// settled result — never a `.inProgress` left dangling by a caller
    /// that resumed first.
    private func performDeferredMoshControlPlaneRebuild(
        rebuildTaskID: UUID
    ) async -> Bool {
        // Finalize the owned rebuild on EVERY exit — including a Leave that
        // cancelled this task mid-close. Only a still-current operation may
        // resolve the flag; a superseding connection that already changed
        // the state is left untouched.
        var succeeded = false
        var roamedAgain = false
        defer {
            if networkPathRecovery.rebuildTaskID == rebuildTaskID {
                networkPathRecovery.rebuildTask = nil
                networkPathRecovery.rebuildTaskID = nil
            }
            if networkPathRecovery.controlPlaneRebuild == .inProgress {
                // A cancelled or failed current operation restores .needed
                // so Leave still rebuilds the bootstrap to TERM the pid.
                networkPathRecovery.controlPlaneRebuild = (succeeded && !roamedAgain)
                    ? .idle
                    : .needed
            }
        }

        let restoration = networkPathReconnectRestoration() ?? .ordinaryTerminal
        await transparentControlPlaneReconnect(
            restoring: restoration,
            trigger: .networkPathChange
        )
        let controlPlaneLive = await coordinator.connectionState() == .connected
        succeeded = activeConnection != nil
            && !isTransparentlyReconnecting
            && controlPlaneLive

        // A flap observed during the handshake marks roamedDuringRebuild;
        // the roam could not disconnect the bootstrap concurrently, so the
        // rebuilt bootstrap is now stale. Retire it while still holding
        // .inProgress + rebuildTask so a Picker open or Leave that arrives
        // during the close joins THIS operation instead of starting a
        // competing handshake. The deferred finalizer publishes the settled
        // state only after the close finishes.
        roamedAgain = networkPathRecovery.roamedDuringRebuild
        networkPathRecovery.roamedDuringRebuild = false
        if roamedAgain && succeeded {
            DiagnosticLogger.shared.log(
                level: .notice,
                category: "network-recovery",
                "rebuild finished during flap; retiring stale bootstrap"
            )
            await closeBootstrapPreservingMosh(
                generation: networkPathRecovery.changeGeneration
            )
            if !Task.isCancelled,
               networkPathRecovery.controlPlaneRebuild == .inProgress {
                baseSession = nil
            }
        }
        return succeeded && !roamedAgain
    }

    /// Re-attempts a path change observed while the scene was backgrounded once
    /// activation has restored the foreground context.
    func scheduleNetworkPathReconnectIfNeeded() {
        guard networkPathRecovery.monitoringStarted,
              networkPathRecovery.changePending,
              !isSceneBackgrounded,
              activeConnection != nil,
              networkPathRecovery.attemptedGeneration
                  != networkPathRecovery.changeGeneration,
              let restoration = networkPathReconnectRestoration()
        else {
            if networkPathRecovery.changePending {
                DiagnosticLogger.shared.log(
                    level: .debug,
                    category: "network-recovery",
                    """
                    schedule skip bg=\(self.isSceneBackgrounded) \
                    inactive=\(self.isSceneInactive) \
                    connected=\(self.activeConnection != nil) \
                    herdr=\(self.herdrStateSummary)
                    """
                )
            }
            return
        }

        let generation = networkPathRecovery.changeGeneration
        let debounce = networkPathRecovery.lastPath?.status == .satisfied
            ? .zero
            : Self.networkPathReconnectDebounce
        let debounceTaskID = UUID()
        networkPathRecovery.debounceTask?.cancel()
        networkPathRecovery.debounceTaskID = debounceTaskID
        networkPathRecovery.debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.networkPathRecovery.debounceTaskID == debounceTaskID,
                  !self.isSceneBackgrounded,
                  self.networkPathRecovery.changePending,
                  self.networkPathRecovery.changeGeneration == generation,
                  self.networkPathRecovery.attemptedGeneration != generation,
                  self.networkPathRecovery.lastPath?.status == .satisfied,
                  !self.isTransparentlyReconnecting,
                  self.networkPathRecovery.transparentTask == nil
            else { return }

            DiagnosticLogger.shared.log(
                level: .debug,
                category: "network-recovery",
                "probe start timeout=400ms restoration=\(String(describing: restoration))"
            )
            let probeStarted = ContinuousClock.now
            let probeSucceeded = await self.probeExistingSSHControlSession()
            let probeMs = (ContinuousClock.now - probeStarted) / .milliseconds(1)
            DiagnosticLogger.shared.log(
                level: .debug,
                category: "network-recovery",
                "probe \(probeSucceeded ? "alive" : "dead") durationMs=\(probeMs)"
            )
            guard !Task.isCancelled,
                  self.networkPathRecovery.debounceTaskID == debounceTaskID,
                  !self.isSceneBackgrounded,
                  self.networkPathRecovery.changePending,
                  self.networkPathRecovery.changeGeneration == generation,
                  self.networkPathRecovery.attemptedGeneration != generation,
                  self.networkPathRecovery.lastPath?.status == .satisfied,
                  !self.isTransparentlyReconnecting,
                  self.networkPathRecovery.transparentTask == nil
            else { return }

            self.networkPathRecovery.debounceTask = nil
            self.networkPathRecovery.debounceTaskID = nil
            self.networkPathRecovery.attemptedGeneration = generation
            self.networkPathRecovery.changePending = false
            guard !probeSucceeded else {
                DiagnosticLogger.shared.log(
                    level: .notice,
                    category: "network-recovery",
                    "skip reconnect, session still alive"
                )
                return
            }
            DiagnosticLogger.shared.log(
                level: .notice,
                category: "network-recovery",
                "reconnect launch after dead probe"
            )
            self.launchTransparentControlPlaneReconnect(
                restoring: restoration,
                trigger: .networkPathChange
            )
        }
    }

    /// Probes only the SSH control plane used by SSH-only terminals. Mosh
    /// liveness belongs to its UDP data plane and must never be inferred from
    /// an SSH command on a path change.
    private func probeExistingSSHControlSession() async -> Bool {
        guard !isMoshDataPlaneMounted,
              let session = baseSession
                ?? baseTerminalSession
                ?? activeConnection?.session
        else { return false }

        do {
            _ = try await runWithTimeout(
                Self.networkPathProbeTimeout,
                operation: {
                    try await session.execute("true")
                },
                onAbort: {}
            )
            return true
        } catch {
            return false
        }
    }

    private func networkPathReconnectRestoration()
        -> TransparentReconnectRestoration? {
        switch herdrState {
        case .attached:
            .rememberedPane
        case .ordinaryTerminal:
            .ordinaryTerminal
        default:
            nil
        }
    }

    var herdrStateSummary: String {
        switch herdrState {
        case .attached(_, let pane):
            "attached(\(pane.id))"
        case .ordinaryTerminal:
            "ordinaryTerminal"
        case .panes(let session, _):
            "panes(\(session.id))"
        case .sessions(let list):
            "sessions(\(list.count))"
        case .empty:
            "empty"
        case nil:
            "nil"
        }
    }
}
