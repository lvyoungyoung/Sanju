import Foundation
import Network

final class NetworkStatusMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "sanju.network.monitor")

    var currentDebugDescription: String {
        Self.debugDescription(for: monitor.currentPath)
    }

    func start(_ handler: @escaping @Sendable (_ isAvailable: Bool, _ debugDescription: String) -> Void) {
        monitor.pathUpdateHandler = { path in
            handler(path.status == .satisfied, Self.debugDescription(for: path))
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    private static func debugDescription(for path: NWPath) -> String {
        let interface: String
        if path.usesInterfaceType(.wifi) {
            interface = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            interface = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = "ethernet"
        } else if path.usesInterfaceType(.loopback) {
            interface = "loopback"
        } else if path.usesInterfaceType(.other) {
            interface = "other"
        } else {
            interface = "unknown"
        }

        let status: String
        switch path.status {
        case .satisfied:
            status = "satisfied"
        case .requiresConnection:
            status = "requiresConnection"
        case .unsatisfied:
            status = "unsatisfied"
        @unknown default:
            status = "unknown"
        }

        return "status=\(status), interface=\(interface), expensive=\(path.isExpensive), constrained=\(path.isConstrained)"
    }
}
