import Foundation

/// Finds HDHomeRun tuners on the local network with the UDP discovery broadcast (port 65001).
///
/// Nothing is sent until `discover()` is called; call it only when the user asks to find tuners. Each run opens
/// one UDP socket per broadcast-capable IPv4 interface (pinned with `IP_BOUND_IF`), sends a discover request
/// to the interface's subnet-directed broadcast and to `255.255.255.255`, resends once, collects replies for
/// the configured window and closes the sockets. Replies are de-duplicated by device ID.
///
/// Platform notes: a sandboxed macOS app needs `com.apple.security.network.server` as well as `network.client`, or the
/// replies are silently dropped; iOS and iPadOS need the managed multicast entitlement. The work runs off the main
/// actor and never blocks a thread: the sockets are non-blocking and the run sleeps between reads, so cancelling the
/// calling task ends it promptly.
public nonisolated struct HDHomeRunDiscoveryClient: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// How long to collect replies. The FLEX 4K answers within about 10 ms.
        public var window: Duration
        /// When to send the request a second time, or nil to send it once.
        public var resendAfter: Duration?
        /// Also send to `255.255.255.255` on each interface (and on an unbound socket when no interface has a
        /// directed broadcast address).
        public var includesLimitedBroadcast: Bool
        /// The pause between checks for replies.
        public var pollInterval: Duration

        public init(
            window: Duration = .milliseconds(1_500),
            resendAfter: Duration? = .milliseconds(500),
            includesLimitedBroadcast: Bool = true,
            pollInterval: Duration = .milliseconds(10)
        ) {
            self.window = window
            self.resendAfter = resendAfter
            self.includesLimitedBroadcast = includesLimitedBroadcast
            self.pollInterval = pollInterval
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Broadcasts a discover request and returns every tuner that answered, in the order they first answered.
    ///
    /// Returns an empty array when nobody answered. Throws `.cancelled` when the calling task is cancelled
    /// and `.localNetworkUnavailable` when not a single request could be sent.
    @concurrent
    public func discover() async throws(HDHomeRunClientError) -> [DiscoveredTuner] {
        guard !Task.isCancelled else { throw .cancelled }
        let run = DiscoveryRun(configuration: configuration, interfaces: IPv4InterfaceAddress.current())
        return try await run.execute()
    }
}

/// One discovery run: the open sockets and their targets. Lives only inside `discover()`.
nonisolated final class DiscoveryRun {
    private struct Endpoint {
        let socket: DiscoverySocket
        let targets: [UInt32]
    }

    private let configuration: HDHomeRunDiscoveryClient.Configuration
    private let endpoints: [Endpoint]
    private let openError: Int32
    private let request = TunerDiscoveryPacket.discoverRequest()
    private var collector = DiscoveredTunerCollector()
    private var buffer = [UInt8](repeating: 0, count: 4_096)

    init(configuration: HDHomeRunDiscoveryClient.Configuration, interfaces: [IPv4InterfaceAddress]) {
        self.configuration = configuration
        let limited = configuration.includesLimitedBroadcast ? [IPv4InterfaceAddress.limitedBroadcast] : []
        var endpoints: [Endpoint] = []
        var openError: Int32 = 0
        for interface in IPv4InterfaceAddress.broadcastTargets(for: interfaces) {
            guard let socket = DiscoverySocket(interfaceName: interface.name, interfaceIndex: interface.index) else {
                openError = errno
                continue
            }
            endpoints.append(Endpoint(socket: socket, targets: interface.broadcasts + limited))
        }
        if endpoints.isEmpty, !limited.isEmpty {
            if let socket = DiscoverySocket(interfaceName: nil, interfaceIndex: nil) {
                endpoints.append(Endpoint(socket: socket, targets: limited))
            } else {
                openError = errno
            }
        }
        self.endpoints = endpoints
        self.openError = openError
    }

    func execute() async throws(HDHomeRunClientError) -> [DiscoveredTuner] {
        guard sendRequests() else {
            let sendError = endpoints.lazy.map(\.socket.lastError).first { $0 != 0 }
            throw .localNetworkUnavailable(errno: sendError ?? openError)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + configuration.window
        var resendAt = configuration.resendAfter.map { start + $0 }
        while clock.now < deadline {
            drainReplies()
            if let due = resendAt, clock.now >= due {
                _ = sendRequests()
                resendAt = nil
            }
            do {
                try await Task.sleep(for: max(.zero, min(configuration.pollInterval, deadline - clock.now)))
            } catch {
                throw .cancelled
            }
        }
        drainReplies()
        return collector.tuners
    }

    /// Sends the request to every target. Returns true when at least one datagram went out.
    private func sendRequests() -> Bool {
        var sentAny = false
        for endpoint in endpoints {
            for target in endpoint.targets {
                let sent = endpoint.socket.send(request, to: target, port: TunerDiscoveryPacket.port)
                sentAny = sentAny || sent
            }
        }
        return sentAny
    }

    /// Reads every waiting datagram on every socket; anything that is not a valid reply is skipped.
    private func drainReplies() {
        for endpoint in endpoints {
            while let received = endpoint.socket.receive(into: &buffer) {
                guard received.sender != 0,
                      let reply = try? TunerDiscoveryPacket.parseReply(Array(buffer[0..<received.count])) else {
                    continue
                }
                collector.add(
                    reply,
                    from: IPv4InterfaceAddress.dottedQuad(received.sender),
                    interfaceName: endpoint.socket.interfaceName
                )
            }
        }
    }
}
