import Foundation
import HerdrKit
import os

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
        networkPathRecovery.changePending = true
        networkPathRecovery.debounceTask?.cancel()
        networkPathRecovery.debounceTask = nil
        networkPathRecovery.debounceTaskID = nil
        scheduleNetworkPathReconnectIfNeeded()
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

            if self.isMoshDataPlaneMounted {
                // Mosh is the user-facing UDP data plane only for the ordinary
                // terminal. Its session must not be probed through SSH: a path
                // change is expected to retire only the TCP control plane while
                // Mosh roams independently.
                self.networkPathRecovery.debounceTask = nil
                self.networkPathRecovery.debounceTaskID = nil
                self.networkPathRecovery.attemptedGeneration = generation
                self.networkPathRecovery.changePending = false
                DiagnosticLogger.shared.log(
                    level: .notice,
                    category: "network-recovery",
                    "control-plane rebuild launch mosh=true overlay=false"
                )
                self.launchTransparentControlPlaneReconnect(
                    restoring: restoration,
                    trigger: .networkPathChange
                )
                return
            }

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
