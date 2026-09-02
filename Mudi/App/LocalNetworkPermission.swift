import Foundation

/// The system-facing state used by the first-launch local-network gate.
///
/// The concrete iOS permission request is intentionally supplied by the app
/// layer so startup behavior can be exercised without invoking system APIs.
enum LocalNetworkPermissionStatus: Equatable, Sendable {
    case undetermined
    case denied
    case granted
}

protocol LocalNetworkPermissionGate: Sendable {
    func status() async -> LocalNetworkPermissionStatus
    func requestPermission() async -> LocalNetworkPermissionStatus
}
