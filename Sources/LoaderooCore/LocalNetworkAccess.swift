import Foundation
import Network

public struct LocalNetworkAccessRequired: LocalizedError, Equatable {
    let endpoint: NWEndpoint

    public var errorDescription: String? {
        "Allow Loaderoo in System Settings → Privacy & Security → Local Network."
    }

    public func waitForAccess() async -> Bool {
        await EndpointReachability.check(endpoint, waitForAccess: true) == .reachable
    }
}

enum EndpointReachability: Sendable {
    case reachable, localNetworkDenied, unavailable

    // URLSession reports both an offline Mac and local network denial as notConnectedToInternet.
    // Ask Network.framework about the specific endpoint without sending an HTTP request or API key.
    static func endpoint(for url: URL) -> NWEndpoint? {
        guard #available(macOS 15, *),
              let host = url.host(percentEncoded: false),
              let number = UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80)),
              let port = NWEndpoint.Port(rawValue: number) else { return nil }
        return .hostPort(host: .init(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))), port: port)
    }

    static func check(_ endpoint: NWEndpoint, waitForAccess: Bool = false) async -> Self {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let (results, continuation) = AsyncStream<Self>.makeStream()
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready: continuation.yield(.reachable)
            case .waiting where waitForAccess && connection?.currentPath?.unsatisfiedReason == .localNetworkDenied:
                return  // Network.framework retries this connection when the user grants access.
            case .waiting, .failed:
                continuation.yield(connection?.currentPath?.unsatisfiedReason == .localNetworkDenied
                                   ? .localNetworkDenied : .unavailable)
            case .cancelled: break
            default: return
            }
            continuation.finish()
        }
        let queue = DispatchQueue(label: "net.prdb.loaderoo.network-check")
        connection.start(queue: queue)
        if !waitForAccess {
            queue.asyncAfter(deadline: .now() + 2) { continuation.finish() }
        }
        defer { connection.cancel() }
        for await result in results { return result }
        return .unavailable
    }
}
