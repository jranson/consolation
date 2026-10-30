import Foundation
import Network

/// Settings for `StreamRelayServer`. The app injects its service type, name and instance identifier.
public nonisolated struct StreamRelayServerConfiguration: Sendable, Hashable {
    /// The Bonjour service type to advertise, for example `_example-tv._tcp`. Nil serves without advertising.
    public var serviceType: String?
    /// The advertised instance name. Nil lets the system use the device's name.
    public var serviceName: String?
    /// This launch's identifier, published in the TXT record so the device's own browser can skip it.
    public var instanceID: String
    /// Clients streaming at once; more get 503.
    public var maxClients: Int
    /// Bytes a client may have waiting to be sent before it is dropped: about 2 s of a full 19.4 Mbps ATSC 1.0
    /// stream. A slow client never holds up the tuner or the other subscribers.
    public var maxQueuedBytes: Int
    /// How long a new connection may take to send its request head.
    public var requestTimeout: Duration
    /// Listens on the loopback interface only (tests).
    public var loopbackOnly: Bool

    public init(serviceType: String?, serviceName: String? = nil, instanceID: String, maxClients: Int = 4,
                maxQueuedBytes: Int = 5_000_000, requestTimeout: Duration = .seconds(5), loopbackOnly: Bool = false) {
        self.serviceType = serviceType
        self.serviceName = serviceName
        self.instanceID = instanceID
        self.maxClients = maxClients
        self.maxQueuedBytes = maxQueuedBytes
        self.requestTimeout = requestTimeout
        self.loopbackOnly = loopbackOnly
    }
}

/// Serves channels that are already open on this device to other devices on the local network, so a second
/// device watching the same channel shares this device's tuner instead of taking another one.
///
/// A plain HTTP/1.1 listener (`RelayRequest` describes the protocol) that advertises itself over Bonjour with a
/// `RelayAdvertisement`. It only accepts peers with local-network addresses (`RelayPeerPolicy`), serves at most
/// `maxClients` streams, and drops a client whose unsent backlog passes `maxQueuedBytes`. Every stream comes from
/// `attach`, which joins an upstream that is already open (`TunerBroker.attach(to:)`) and never tunes, so a relay
/// can never chain another relay.
public nonisolated final class StreamRelayServer: @unchecked Sendable {
    // @unchecked: every mutable property is only touched on `queue`.
    public typealias Attach = @Sendable (ChannelKey) async throws(HDHomeRunClientError) -> ChannelSubscription

    let configuration: StreamRelayServerConfiguration
    let queue = DispatchQueue(label: "HTTPMPEG2Kit.StreamRelayServer", qos: .userInitiated)
    private let attach: Attach
    private let onClientsChanged: (@Sendable (Int) -> Void)?

    private var listener: NWListener?
    private var channels: [ChannelKey] = []
    private var connections: [UInt64: RelayConnection] = [:]
    private var nextID: UInt64 = 0
    private var streaming = 0
    private var readyWaiter: CheckedContinuation<UInt16, any Error>?
    private var isStopped = false

    /// - Parameters:
    ///   - channels: the channels to advertise at first; `update(channels:)` changes them.
    ///   - attach: joins an open channel; throw `.unknownChannel` when it isn't open.
    ///   - onClientsChanged: the number of streaming clients, whenever it changes (on the server's queue).
    public init(configuration: StreamRelayServerConfiguration, channels: [ChannelKey] = [], attach: @escaping Attach,
                onClientsChanged: (@Sendable (Int) -> Void)? = nil) {
        self.configuration = configuration
        self.channels = channels
        self.attach = attach
        self.onClientsChanged = onClientsChanged
    }

    /// Starts listening (and advertising, when a service type is set). Returns the port once the listener is ready.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular]
        if configuration.loopbackOnly { parameters.requiredInterfaceType = .loopback }
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { waiter in
            queue.async { [self] in
                guard !isStopped, self.listener == nil else {
                    waiter.resume(throwing: CancellationError())
                    return
                }
                self.listener = listener
                readyWaiter = waiter
                listener.service = makeService()
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            }
        }
    }

    /// Changes the advertised channels.
    public func update(channels: [ChannelKey]) {
        queue.async { [self] in
            guard self.channels != channels else { return }
            self.channels = channels
            listener?.service = makeService()
        }
    }

    /// Stops advertising and listening, and ends every client's stream. The server can't be restarted.
    public func stop() {
        queue.async { [self] in
            isStopped = true
            listener?.cancel()
            listener = nil
            readyWaiter?.resume(throwing: CancellationError())
            readyWaiter = nil
            for connection in Array(connections.values) {
                connection.close()
            }
        }
    }

    /// Clients streaming now.
    public var clientCount: Int {
        queue.sync { streaming }
    }

    // MARK: - Connections (on `queue`)

    private func makeService() -> NWListener.Service? {
        guard let type = configuration.serviceType else { return nil }
        let advertisement = RelayAdvertisement(instanceID: configuration.instanceID, channels: channels)
        return NWListener.Service(name: configuration.serviceName, type: type,
                                  txtRecord: NWTXTRecord(advertisement.txtEntries))
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            readyWaiter?.resume(returning: listener?.port?.rawValue ?? 0)
            readyWaiter = nil
        case .failed(let error):
            readyWaiter?.resume(throwing: error)
            readyWaiter = nil
            listener?.cancel()
        case .cancelled:
            readyWaiter?.resume(throwing: CancellationError())
            readyWaiter = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        // Requests that never become streams (info, errors) close at once, so a few extra slots are enough.
        guard !isStopped, RelayPeerPolicy.isLocal(connection.endpoint),
              connections.count < configuration.maxClients + 4 else {
            connection.cancel()
            return
        }
        nextID &+= 1
        let relay = RelayConnection(id: nextID, connection: connection, queue: queue, server: self,
                                    maxQueuedBytes: configuration.maxQueuedBytes)
        connections[relay.id] = relay
        relay.start(timeout: configuration.requestTimeout)
    }

    /// A connection sent its request.
    func handle(_ request: RelayRequest, from relay: RelayConnection) {
        switch request {
        case .info:
            relay.respond(.success, contentType: "application/json", body: RelayInfo(channels: channels).encoded())
        case .stream(let channel):
            guard streaming < configuration.maxClients else {
                relay.respond(.unavailable)
                return
            }
            relay.isStreaming = true
            streaming += 1
            onClientsChanged?(streaming)
            let attach = attach
            Task.detached(priority: .userInitiated) { [queue] in
                do {
                    let subscription = try await attach(channel)
                    queue.async { relay.begin(subscription) }
                } catch {
                    queue.async { relay.respond(.notFound) }
                }
            }
        }
    }

    func connectionClosed(_ relay: RelayConnection) {
        guard connections.removeValue(forKey: relay.id) != nil else { return }
        if relay.isStreaming {
            streaming -= 1
            onClientsChanged?(streaming)
        }
    }
}
