import Foundation

/// Phase 10: the per-row connection feedback shown on the Hosts list.
///
/// This slice keeps one connect attempt at a time, so a row is either idle or
/// connecting. The state is published when the attempt starts, not when it
/// succeeds or fails, so the row reacts to a tap immediately.
enum HostRowConnectionState: Equatable, Sendable {
    case idle
    case connecting
}

/// The visible progress/cancel contract for one Host row. It is a value type
/// so the row's rendering rules stay testable without a view.
struct HostRowConnectionPresentation: Equatable, Sendable {
    let isConnecting: Bool
    let showsProgress: Bool
    let showsCancel: Bool
    let canConnect: Bool

    static func resolve(
        state: HostRowConnectionState,
        showsCancel: Bool
    ) -> HostRowConnectionPresentation {
        switch state {
        case .idle:
            HostRowConnectionPresentation(
                isConnecting: false,
                showsProgress: false,
                showsCancel: false,
                canConnect: true
            )
        case .connecting:
            HostRowConnectionPresentation(
                isConnecting: true,
                showsProgress: true,
                // The cancel affordance only exists while a connection is in
                // flight; an idle row never offers it even if a stale flag
                // survived a state change.
                showsCancel: showsCancel,
                canConnect: false
            )
        }
    }
}

/// The clock seam for the cancel-affordance threshold. The app sleeps on the
/// wall clock; tests inject a virtual clock so the default 5-second contract
/// never depends on real time.
protocol HostConnectingDelayScheduling: Sendable {
    func waitForCancelThreshold(_ duration: Duration) async throws
}

struct LiveHostConnectingDelayScheduler: HostConnectingDelayScheduling {
    func waitForCancelThreshold(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
