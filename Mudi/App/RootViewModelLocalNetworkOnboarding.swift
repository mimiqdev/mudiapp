import Foundation

extension RootViewModel {
    /// Decides whether the first-launch local-network onboarding must run
    /// before the Host list opens. A persisted completion wins, then the
    /// injectable gate is consulted. Without a gate (tests, previews) the
    /// app never blocks startup.
    ///
    /// Accepted trade-off (review r2-f2): the passive production gate
    /// cannot detect a pre-existing grant in a fresh process, so upgrading
    /// installs with an unset flag see the explanation exactly once
    /// (Continue resolves instantly, without a dialog). A hosts/credential
    /// based migration would contradict the contract that a fresh install
    /// with a saved host still shows onboarding.
    func checkLocalNetworkPermission() async {
        guard isLocalNetworkOnboardingRequired == nil else { return }
        guard !preferences.hasCompletedLocalNetworkOnboarding else {
            isLocalNetworkOnboardingRequired = false
            return
        }
        guard let localNetworkPermissionGate else {
            isLocalNetworkOnboardingRequired = false
            return
        }
        let status = await localNetworkPermissionGate.status()
        guard !Task.isCancelled else { return }
        if status == .granted {
            markLocalNetworkOnboardingCompleted()
        } else {
            isLocalNetworkOnboardingRequired = true
        }
    }

    /// Continue action of the onboarding surface: triggers the iOS local
    /// network authorization, persists completion so later launches skip
    /// the flow, and opens the Host list regardless of the outcome. The
    /// in-flight flag is raised synchronously so a fast double-tap cannot
    /// start two concurrent permission probes.
    func completeLocalNetworkOnboarding() {
        guard isLocalNetworkOnboardingRequired == true,
              !isRequestingLocalNetworkPermission
        else { return }
        isRequestingLocalNetworkPermission = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRequestingLocalNetworkPermission = false }
            if let localNetworkPermissionGate {
                _ = await localNetworkPermissionGate.requestPermission()
            }
            markLocalNetworkOnboardingCompleted()
        }
    }

    private func markLocalNetworkOnboardingCompleted() {
        preferences.hasCompletedLocalNetworkOnboarding = true
        isLocalNetworkOnboardingRequired = false
        persistPreferences()
    }
}
