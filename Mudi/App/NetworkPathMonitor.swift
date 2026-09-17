import Foundation
import Network

/// The subset of path state that can make an existing remote connection
/// stale. Keeping this value independent of Network.framework makes path
/// changes deterministic in model tests.
enum NetworkPathStatus: String, Equatable, Sendable {
    case satisfied
    case unsatisfied
    case requiresConnection
    case unknown
}

enum NetworkInterfaceKind: String, Equatable, Hashable, Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case other
}

struct NetworkPathSnapshot: Equatable, Sendable {
    let status: NetworkPathStatus
    let interfaces: Set<NetworkInterfaceKind>
    let isExpensive: Bool
    let isConstrained: Bool

    init(
        status: NetworkPathStatus,
        interfaces: Set<NetworkInterfaceKind>,
        isExpensive: Bool,
        isConstrained: Bool
    ) {
        self.status = status
        self.interfaces = interfaces
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    init(_ path: NWPath) {
        let status: NetworkPathStatus
        switch path.status {
        case .satisfied:
            status = .satisfied
        case .unsatisfied:
            status = .unsatisfied
        case .requiresConnection:
            status = .requiresConnection
        @unknown default:
            status = .unknown
        }

        var interfaces = Set<NetworkInterfaceKind>()
        if path.usesInterfaceType(.wifi) {
            interfaces.insert(.wifi)
        }
        if path.usesInterfaceType(.cellular) {
            interfaces.insert(.cellular)
        }
        if path.usesInterfaceType(.wiredEthernet) {
            interfaces.insert(.wiredEthernet)
        }
        if path.usesInterfaceType(.loopback) {
            interfaces.insert(.loopback)
        }
        if path.usesInterfaceType(.other) {
            // VPN/tailnet interfaces are reported by Network.framework as
            // other on the supported iOS versions.
            interfaces.insert(.other)
        }

        self.init(
            status: status,
            interfaces: interfaces,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    var logDescription: String {
        let ifaces = interfaces.map(\.rawValue).sorted().joined(separator: ",")
        return "status=\(status.rawValue) ifaces=[\(ifaces)] expensive=\(isExpensive) constrained=\(isConstrained)"
    }
}

/// A small seam around NWPathMonitor so the reconnect policy can be tested
/// without relying on simulator interface changes.
protocol NetworkPathMonitoring: AnyObject, Sendable {
    func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void)
    func cancel()
}

final class SystemNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "dev.mudi.mobile.network-path-monitor"
    )
    private var monitor: NWPathMonitor?

    func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            handler(NetworkPathSnapshot(path))
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor?.cancel()
        monitor = nil
    }
}
