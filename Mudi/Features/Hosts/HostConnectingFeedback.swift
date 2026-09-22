import Foundation
import HerdrKit

/// Phase 10: the per-row connection feedback shown on the Hosts list.
///
/// This slice keeps one connect attempt at a time, so the coordinator's
/// connection state is attributed to exactly one owning row. The global
/// banner that used to show that state above the list is gone: every state is
/// presented on the owning Host row itself.
enum HostRowConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed
    case disconnected
}

extension HostRowConnectionState {
    /// Attributes the coordinator's single active connection state to one
    /// Host row. Only the owning row renders the state; every other row stays
    /// idle and connectable.
    ///
    /// A live model attempt wins for its whole duration: SSH is already up
    /// while Herdr discovery still runs, so the row must keep its connecting
    /// animation and Cancel affordance until the attempt actually settles.
    static func resolve(
        host: Host,
        connectingHostID: Host.ID?,
        stateOwnerHostID: Host.ID?,
        connectionState: ConnectionState
    ) -> HostRowConnectionState {
        if host.id == connectingHostID { return .connecting }
        guard host.id == stateOwnerHostID else { return .idle }
        switch connectionState {
        case .connected:
            return .connected
        case .failed:
            return .failed
        case .disconnected:
            return .disconnected
        case .idle, .connecting:
            // `.connecting` without a live model attempt is a control-plane
            // rebuild behind the terminal; the Hosts list has no row feedback
            // for it.
            return .idle
        }
    }
}

/// The visible progress/cancel/result contract for one Host row. It is a
/// value type so the row's rendering rules stay testable without a view.
struct HostRowConnectionPresentation: Equatable, Sendable {
    let state: HostRowConnectionState
    let showsProgress: Bool
    let showsCancel: Bool
    let canConnect: Bool
    let showsConnected: Bool
    let showsFailure: Bool
    let showsDisconnected: Bool
    let showsRetry: Bool

    var isConnecting: Bool {
        state == .connecting
    }

    static func resolve(
        state: HostRowConnectionState,
        showsCancel: Bool
    ) -> HostRowConnectionPresentation {
        switch state {
        case .idle:
            HostRowConnectionPresentation(
                state: .idle,
                showsProgress: false,
                showsCancel: false,
                canConnect: true,
                showsConnected: false,
                showsFailure: false,
                showsDisconnected: false,
                showsRetry: false
            )
        case .connecting:
            HostRowConnectionPresentation(
                state: .connecting,
                showsProgress: true,
                // The cancel affordance only exists while a connection is in
                // flight; an idle row never offers it even if a stale flag
                // survived a state change.
                showsCancel: showsCancel,
                canConnect: false,
                showsConnected: false,
                showsFailure: false,
                showsDisconnected: false,
                showsRetry: false
            )
        case .connected:
            HostRowConnectionPresentation(
                state: .connected,
                showsProgress: false,
                showsCancel: false,
                canConnect: false,
                showsConnected: true,
                showsFailure: false,
                showsDisconnected: false,
                showsRetry: false
            )
        case .failed:
            HostRowConnectionPresentation(
                state: .failed,
                showsProgress: false,
                showsCancel: false,
                canConnect: true,
                showsConnected: false,
                showsFailure: true,
                showsDisconnected: false,
                showsRetry: true
            )
        case .disconnected:
            HostRowConnectionPresentation(
                state: .disconnected,
                showsProgress: false,
                showsCancel: false,
                canConnect: true,
                showsConnected: false,
                showsFailure: false,
                showsDisconnected: true,
                showsRetry: true
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
